-- ============ 1) Search that keeps working when Gemini embeddings are down ============
-- The agents' law_library / my_documents tools call the "Smart Lawyer - Search Tool" workflow:
--   breaker ok?  -> Gemini embedding (3072 dims, like the stored vectors) -> sl_search(query, vector, ...)
--   Gemini error -> sl_embed_trip(...) opens the breaker            -> sl_search(query, '', ...) keyword only
-- While the breaker is open Gemini is not called at all, so nothing hangs on 429 retries.

insert into sl_settings values ('embed_down_until', '1970-01-01T00:00:00Z'), ('embed_last_error', '')
  on conflict (key) do nothing;

create or replace function sl_embed_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value::timestamptz from sl_settings where key = 'embed_down_until'), '-infinity') < now()
$$;

-- per-minute limit: 2 minutes; anything else (daily free quota of 1000 requests, auth, outage): 30 minutes
create or replace function sl_embed_trip(p_err text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare mins int := case when coalesce(p_err, '') ~* '(per.?minute|PerMinute)' then 2 else 30 end;
begin
  update sl_settings set value = (now() + make_interval(mins => mins))::text where key = 'embed_down_until';
  update sl_settings set value = left(coalesce(p_err, ''), 500) where key = 'embed_last_error';
  return jsonb_build_object('tripped', true, 'minutes', mins);
end $$;

-- Arabic full-text index (stems ال / plurals reasonably well)
create index if not exists documents_content_fts on documents using gin (to_tsvector('arabic', content));

-- p_scope: 'library' (public laws) | 'mine' (the user's files) | 'both'; suffix '_lite' = free tier (fewer, shorter results).
-- Result size matters: Groq free = 8k tokens per minute AND per request, and every agent step re-sends all earlier results.
create or replace function sl_search(p_query text, p_vec text, p_user text, p_scope text, p_k int default 5) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  lite boolean := coalesce(p_scope, '') like '%\_lite';
  base text := regexp_replace(coalesce(p_scope, ''), '_lite$', '');
  k int := case when coalesce(p_scope, '') like '%\_lite' then 3 else 4 end;
  maxc int := case when coalesce(p_scope, '') like '%\_lite' then 900 else 1300 end;
  owners text[] := case base when 'mine' then array[p_user] when 'both' then array[p_user, 'public'] else array['public'] end;
  q text := left(coalesce(p_query, ''), 500);
  tsq tsquery; art text; res jsonb; has_vec boolean := coalesce(p_vec, '') not in ('', '[]'); v vector;
begin
  if has_vec then v := p_vec::vector; end if;
  -- OR of the meaningful words, each stemmed by the arabic config
  select string_agg(x, ' | ')::tsquery into tsq from (
    select plainto_tsquery('arabic', t)::text x
      from regexp_split_to_table(regexp_replace(q, '[^ء-ي٠-٩0-9A-Za-z]+', ' ', 'g'), '\s+') t
     where length(t) >= 3 and t not in ('على', 'علي', 'إلى', 'الى', 'التي', 'الذي', 'هذا', 'هذه', 'ذلك', 'وفي', 'عند', 'بعد', 'قبل', 'كان', 'يكون', 'ايه', 'إيه', 'عايز', 'ازاي', 'إزاي',
                   'مادة', 'المادة', 'ماده', 'قانون', 'القانون', 'رقم', 'لسنة', 'سنة')
  ) w where x <> '';
  art := substring(q from '(?:ماد[ةه]|م\.)\s*\(?\s*([0-9]+)');   -- "مادة 558" -> boost that article

  with vec as (
    select d.id, d.content, d.metadata, 1.0 + (1 - (d.embedding <=> v)) as score, 'vector' as how
      from documents d
     where has_vec and d.metadata->>'userId' = any(owners)
     order by d.embedding <=> v
     limit k
  ), kw as (
    select d.id, d.content, d.metadata,
           ts_rank_cd(to_tsvector('arabic', d.content), tsq, 1 | 32)
           + case when art is not null and d.content ~ ('ماد[ةه]\s*[\(\[]?\s*' || art || '([^0-9]|$)') then 10.0 else 0 end as score,
           'keyword' as how
      from documents d
     where d.metadata->>'userId' = any(owners)
       and ((tsq is not null and to_tsvector('arabic', d.content) @@ tsq)
            or (art is not null and d.content ~ ('ماد[ةه]\s*[\(\[]?\s*' || art || '([^0-9]|$)')))
     order by score desc
     limit case when has_vec then 2 else k end
  ), allr as (
    select distinct on (id) * from (select * from vec union all select * from kw) u order by id, score desc
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', metadata->>'fileName',
           'source', case when metadata->>'userId' = 'public' then 'law_library' else 'my_documents' end,
           'match', how, 'text', left(content, maxc)) order by score desc), '[]'::jsonb)
    into res from (select * from allr order by score desc limit k) top;

  return jsonb_build_object('mode', case when has_vec then 'vector+keyword' else 'keyword (Gemini embeddings unavailable)' end,
                            'results', res);
end $$;

-- ============ 2) Request log: who used what, when the quota ran out, sessions, tokens ============
create table if not exists sl_request_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  day date not null default (now() at time zone 'Africa/Cairo')::date,
  user_id uuid references sl_users(id) on delete set null,
  nickname text,
  plan text,                       -- free | pro | admin
  session_id text,                 -- the chat id shown in the UI ("s...")
  kind text not null,              -- free | cached | pro | clarify | mindmap | timeline | denied_quota | denied_unauth | *_denied
  msg_no int,                      -- messages counted today after this request (sl_usage)
  msg_limit int,
  quota_hit boolean not null default false,
  input_chars int, output_chars int, sources_chars int, searches int,
  tokens_est int,                  -- estimate: characters / 3 with the prompts and the agent loop (see sl_log)
  tokens_in int, tokens_out int,   -- real numbers, backfilled from n8n execution data (sl_log_set_tokens)
  latency_ms int,
  model text, review text,
  embed_ok boolean,                -- was Gemini embedding available (else keyword search)
  exec_id text,                    -- n8n execution id
  error text
);
create index if not exists sl_request_log_day_user on sl_request_log (day, user_id);
create index if not exists sl_request_log_user_at on sl_request_log (user_id, at);
create index if not exists sl_request_log_exec on sl_request_log (exec_id);
alter table sl_request_log enable row level security;

-- p: {token, session, kind, exec_id, latency_ms, input_chars, output_chars, sources_chars, searches, model, review, error}
create or replace function sl_log(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u sl_users; pl sl_plans; used int; lim int; hist int := 0;
  k text := coalesce(p->>'kind', 'unknown');
  inp int := coalesce((p->>'input_chars')::int, 0);
  outp int := coalesce((p->>'output_chars')::int, 0);
  src int := coalesce((p->>'sources_chars')::int, 0);
  srch int := coalesce((p->>'searches')::int, 0);
  sid text := left(regexp_replace(coalesce(p->>'session', ''), '[^A-Za-z0-9_-]', '', 'g'), 64);
  est int;
begin
  select usr.* into u from sl_sessions s join sl_users usr on usr.id = s.user_id
   where s.token = coalesce(p->>'token', '') and s.expires_at > now();
  if u.id is not null then
    select * into pl from sl_plans where plan = u.plan;
    select messages into used from sl_usage where user_id = u.id and day = (now() at time zone 'Africa/Cairo')::date;
    lim := (sl_limits(u.id)->>'daily_messages')::int;
    select coalesce(sum(length(message->>'content')), 0) into hist from (
      select message from n8n_chat_histories where session_id = u.id::text || ':' || sid
       and jsonb_typeof(message->'content') = 'string' order by id desc limit 6) h;
  end if;
  -- token estimate (~3 Arabic characters per token). System prompts: free ~1.8k chars, pro expert ~4.5k, triage ~1.5k, reviewer ~2k.
  est := case
    when k = 'free'   then ceil(((1800 + hist + inp) * 2 + 7200 + outp) / 3.0)
    -- pro: x0.73 calibrated on a real execution (estimate 67k vs real 49k tokens, Nov 2026)
    when k = 'pro'    then ceil(0.73 * ((4500 + hist + inp) * (srch + 1) + src * greatest(srch, 1) * 0.6 + outp
                               + (1500 + inp) + case when p->>'review' in ('pass', 'fixed') then 2000 + outp + src else 0 end) / 3.0)
    when k = 'clarify' then ceil((2500 + inp + outp) / 3.0)
    when k in ('mindmap', 'timeline') then ceil((2000 + inp + outp) / 3.0)
    when k = 'draft' then ceil((3500 + inp + src + outp) / 3.0)
    else 0 end;
  insert into sl_request_log (user_id, nickname, plan, session_id, kind, msg_no, msg_limit, quota_hit,
                              input_chars, output_chars, sources_chars, searches, tokens_est, latency_ms,
                              model, review, embed_ok, exec_id, error)
  values (u.id, coalesce(nullif(u.full_name, ''), split_part(u.email, '@', 1)),
          case when u.role = 'admin' then 'admin' else u.plan end,
          nullif(sid, ''), k, coalesce(used, 0), lim, k = 'denied_quota',
          inp, outp, src, srch, est, nullif(p->>'latency_ms', '')::int,
          nullif(p->>'model', ''), nullif(p->>'review', ''), sl_embed_ok(), p->>'exec_id', nullif(p->>'error', ''));
  -- the models of this turn hit a rate limit: take them out of the chain for a while (llm_router.sql)
  if coalesce(p->>'llm_error', '') <> '' and jsonb_typeof(p->'models') = 'array' then
    perform sl_llm_fail(p->'models', p->>'llm_error');
  end if;
  -- a failed answer opens an issue for the admin; a successful resend resolves it and notifies the user (issues.sql)
  perform sl_issue_track(u.id, coalesce(nullif(u.full_name, ''), split_part(u.email, '@', 1)), sid, k, p);
  return jsonb_build_object('logged', true);
end $$;

-- uploads go to the request log too (admin dashboard: "who uploaded today")
create or replace function sl_upload_log(j jsonb, p_kind text, p_err text) returns void
language sql security definer set search_path = public as $$
  insert into sl_request_log (user_id, nickname, plan, kind, msg_no, msg_limit, error)
  values ((j->'user'->>'id')::uuid, coalesce(nullif(j->'user'->>'name', ''), split_part(j->'user'->>'email', '@', 1)),
          case when j->'user'->>'role' = 'admin' then 'admin' else j->'user'->>'plan' end, p_kind,
          (j->'usage'->>'uploads_today')::int + case when p_kind = 'upload' then 1 else 0 end,
          (j->'usage'->'limits'->>'daily_uploads')::int, p_err)
$$;

-- real token counts (run by a maintenance job / Claude session from n8n execution data)
create or replace function sl_log_set_tokens(p_exec text, p_in int, p_out int) returns int
language sql security definer set search_path = public as $$
  with u as (update sl_request_log set tokens_in = p_in, tokens_out = p_out where exec_id = p_exec returning 1)
  select count(*)::int from u
$$;

-- one row per user per day: how many messages, in how many chats, when the quota ran out, tokens
create or replace view sl_daily_usage as
select day, user_id, max(nickname) as nickname, max(plan) as plan,
       count(*) filter (where kind in ('free', 'cached', 'pro'))         as answers,
       count(*) filter (where kind = 'clarify')                          as clarify_turns,
       count(*) filter (where kind = 'cached')                           as cached_answers,
       count(*) filter (where kind = 'mindmap')                          as mind_maps,
       count(*) filter (where kind = 'timeline')                         as timelines,
       count(distinct session_id) filter (where kind not like '%denied%') as chats,
       max(msg_no)                                                       as messages_counted,
       max(msg_limit)                                                    as daily_limit,
       min(at) filter (where quota_hit)                                  as quota_hit_at,
       (select max(l2.msg_no) from sl_request_log l2 where l2.user_id = l.user_id and l2.day = l.day and l2.kind <> 'denied_quota'
           and l2.at < coalesce((select min(l3.at) from sl_request_log l3 where l3.user_id = l.user_id and l3.day = l.day and l3.quota_hit), 'infinity')) as messages_before_quota,
       count(*) filter (where quota_hit)                                 as blocked_attempts,
       min(at) as first_at, max(at) as last_at,
       sum(tokens_est)                                                   as tokens_est,
       sum(tokens_in) + sum(tokens_out)                                  as tokens_real,
       round(avg(latency_ms) filter (where kind in ('free', 'pro'))::numeric / 1000, 1) as avg_seconds,
       count(*) filter (where embed_ok = false and kind in ('free', 'pro')) as answers_with_keyword_search
  from sl_request_log l
 group by day, user_id;

revoke all on function sl_embed_ok(), sl_embed_trip(text), sl_search(text, text, text, text, int),
  sl_log(jsonb), sl_log_set_tokens(text, int, int), sl_upload_log(jsonb, text, text) from public, anon, authenticated;
revoke all on sl_daily_usage from anon, authenticated;
select 'ok' as status;
