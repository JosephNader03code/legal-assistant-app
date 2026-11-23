-- ============ Quota-aware model routing ============
-- Each model's free-tier limits. "units" = estimated API calls one chat turn costs.
create table if not exists sl_models (
  id text primary key,
  provider text not null check (provider in ('gemini', 'openrouter')),
  quality int not null,            -- 1 = fastest/cheapest ... 5 = strongest
  rpm int not null,                -- requests per minute allowed
  rpd int not null,                -- requests per day allowed
  active boolean not null default true,
  pro_only boolean not null default false  -- slow models: keep free answers fast
);
alter table sl_models add column if not exists pro_only boolean not null default false;
update sl_models set pro_only = true where id = 'models/gemini-2.5-pro';
insert into sl_models (id, provider, quality, rpm, rpd) values
  ('models/gemini-3.1-flash-lite',       'gemini',     2, 15, 1000),
  ('models/gemini-3-flash-preview',      'gemini',     3,  5,   20),
  ('models/gemini-2.5-pro',              'gemini',     4,  5,   50),
  ('nvidia/nemotron-3-ultra-550b-a55b:free', 'openrouter', 3, 20, 50)
on conflict (id) do nothing;
alter table sl_models enable row level security;

create table if not exists sl_model_calls (
  id bigserial primary key,
  model text not null,
  units int not null,
  plan text,
  complexity text,
  at timestamptz not null default now()
);
create index if not exists sl_model_calls_model_at on sl_model_calls (model, at);
alter table sl_model_calls enable row level security;

-- Reserve quota on one model; returns true and logs the call when it fits.
-- Free users may only use 70% of a model's daily quota (30% reserved for Pro).
create or replace function sl_take(p_model text, p_units int, p_plan text, p_cx text) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  m sl_models;
  day_start timestamptz := date_trunc('day', now() at time zone 'America/Los_Angeles') at time zone 'America/Los_Angeles';
  used_min int; used_day int; cap int;
begin
  select * into m from sl_models where id = p_model and active;
  if m.id is null then return false; end if;
  perform pg_advisory_xact_lock(hashtext(p_model));
  select coalesce(sum(units) filter (where at > now() - interval '1 minute'), 0), coalesce(sum(units), 0)
    into used_min, used_day from sl_model_calls where model = p_model and at >= day_start;
  cap := case when p_plan = 'free' then floor(m.rpd * 0.7) else m.rpd end;
  if used_min + p_units > m.rpm or used_day + p_units > cap then return false; end if;
  insert into sl_model_calls (model, units, plan, complexity) values (p_model, p_units, p_plan, p_cx);
  return true;
end $$;

-- Circuit breaker: when no Gemini quota is left we return a model id that does not exist.
-- Gemini answers 404 instantly (no silent retries), so the agent falls back to OpenRouter at once
-- instead of hanging for minutes on 429 retries.
create or replace function sl_lite(p_units int, p_plan text default 'system') returns text
language sql security definer set search_path = public as $$
  select case when sl_take('models/gemini-3.1-flash-lite', p_units, p_plan, 'lite')
              then 'models/gemini-3.1-flash-lite' else 'models/quota-exhausted' end
$$;

-- Pick the models for one chat turn.
-- Objective: highest quality for complex questions, cheapest/fastest for simple ones.
-- Constraints: every Gemini call is counted against per-minute and per-day quotas.
create or replace function sl_route(p_plan text, p_text text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  t text := coalesce(p_text, '');
  score int := 0;
  cx text;
  main_units int := case when p_plan = 'pro' then 6 else 3 end;   -- agent loop calls
  m record;
  chosen text; lite text; why text := 'ok';
  orm text;
begin
  if length(t) > 150 then score := score + 1; end if;
  if (select count(*) from regexp_matches(t, '(دعوى|دعوي|عقد|طعن|استئناف|نقض|تعويض|ميراث|ورث|مادة|حكم|قضية|محكمة|إنذار|انذار|فسخ|بطلان|تقادم|شيك|إيصال|ايصال|جنحة|جناية|نفقة|حضانة|طلاق|خلع)', 'g')) >= 2 then score := score + 1; end if;
  if (length(t) - length(replace(t, '؟', ''))) + (length(t) - length(replace(t, '?', ''))) >= 2 then score := score + 1; end if;
  cx := case when p_plan = 'pro' or score >= 2 then 'complex' when score = 1 then 'medium' else 'simple' end;

  for m in
    select * from sl_models where provider = 'gemini' and active and (p_plan = 'pro' or not pro_only)
    order by case when cx = 'complex' then -quality when cx = 'medium' then abs(quality - 3) else quality end
  loop
    if sl_take(m.id, main_units, p_plan, cx) then chosen := m.id; exit; end if;
  end loop;
  if chosen is null then chosen := 'models/quota-exhausted'; why := 'gemini_quota_exhausted_using_openrouter'; end if;

  -- Pro also runs triage + reviewer on flash-lite (2 calls)
  lite := case when p_plan = 'pro' then sl_lite(2, p_plan) else 'models/gemini-3.1-flash-lite' end;

  select id into orm from sl_models where provider = 'openrouter' and active order by quality desc limit 1;
  return jsonb_build_object('gemini', chosen, 'lite', lite,
                            'openrouter', coalesce(orm, 'nvidia/nemotron-3-ultra-550b-a55b:free'),
                            'complexity', cx, 'reason', why);
end $$;

-- ============ Semantic answer cache (free tier) ============
create table if not exists sl_cache (
  id bigserial primary key,
  question text not null,
  answer text not null,
  embedding vector(768) not null,
  plan text not null default 'free',
  hits int not null default 0,
  created_at timestamptz not null default now(),
  last_hit_at timestamptz
);
create index if not exists sl_cache_embedding_idx on sl_cache using hnsw (embedding vector_cosine_ops);
alter table sl_cache enable row level security;

create table if not exists sl_settings (key text primary key, value text not null);
insert into sl_settings values ('cache_threshold', '0.92'), ('cache_ttl_days', '7') on conflict (key) do nothing;
alter table sl_settings enable row level security;

-- Look up a cached answer. Skipped when the session already has history
-- (follow-up questions depend on context and must not be served from cache).
create or replace function sl_cache_get(p_vec text, p_session text, p_plan text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  th float := (select value::float from sl_settings where key = 'cache_threshold');
  ttl int := (select value::int from sl_settings where key = 'cache_ttl_days');
  best record;
begin
  if p_plan <> 'free' then return jsonb_build_object('hit', false, 'reason', 'not_free'); end if;
  if p_vec is null or p_vec = '' or p_vec = '[]' then return jsonb_build_object('hit', false, 'reason', 'no_embedding'); end if;
  if exists (select 1 from n8n_chat_histories where session_id = p_session) then
    return jsonb_build_object('hit', false, 'reason', 'has_history');
  end if;
  select id, question, answer, 1 - (embedding <=> p_vec::vector) as sim into best
    from sl_cache where plan = p_plan and created_at > now() - make_interval(days => ttl)
    order by embedding <=> p_vec::vector limit 1;
  if best.id is not null and best.sim >= th then
    update sl_cache set hits = hits + 1, last_hit_at = now() where id = best.id;
    return jsonb_build_object('hit', true, 'answer', best.answer, 'sim', round(best.sim::numeric, 4), 'matched', best.question);
  end if;
  return jsonb_build_object('hit', false, 'reason', 'miss', 'sim', round(coalesce(best.sim, 0)::numeric, 4), 'nearest', best.question);
end $$;

create or replace function sl_cache_put(p_question text, p_answer text, p_vec text, p_plan text, p_lookup jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if coalesce(p_lookup->>'reason', '') <> 'miss' or p_vec is null or p_vec in ('', '[]')
     or length(coalesce(p_answer, '')) < 80 or p_answer like 'معلش حصلت مشكلة%' then
    return jsonb_build_object('saved', false);
  end if;
  insert into sl_cache (question, answer, embedding, plan) values (p_question, p_answer, p_vec::vector, p_plan);
  return jsonb_build_object('saved', true);
end $$;

-- library changed -> cached answers may be outdated
create or replace function sl_cache_clear() returns int
language sql security definer set search_path = public as $$
  with d as (delete from sl_cache returning 1) select count(*)::int from d
$$;

revoke all on function sl_take(text, int, text, text), sl_lite(int, text), sl_route(text, text), sl_cache_get(text, text, text), sl_cache_put(text, text, text, text, jsonb), sl_cache_clear() from public, anon, authenticated;

select 'ok' as status;
