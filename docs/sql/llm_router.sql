-- ============ Model chain: when one model is out of quota, the work moves to the next ============
-- Every Groq model has its OWN free quota (8k tokens/min, 1000 requests/day), so spreading turns over several
-- models multiplies capacity. Before each turn sl_route() asks sl_llm_pick() for the first two models of a chain
-- that still have room this minute (primary + fallback of the agent). A model that answered 429 is skipped for a
-- while (sl_llm_fail, called from sl_log). The admin dashboard shows the chain and its health.
-- Run after routing_cache.sql and search_log.sql.

create table if not exists sl_llm (
  id text primary key,                 -- model id at the provider
  provider text not null default 'groq',
  rank_main int,                       -- position in the "main" chain (answers, tools); null = not in it
  rank_light int,                      -- position in the "light" chain (triage, intake questions, review)
  tpm int not null,                    -- tokens per minute
  rpd int not null,                    -- requests per day
  tpd int,                             -- tokens per day (Groq free: gpt-oss 200k); null = unknown / not tracked
  active boolean not null default true,
  down_until timestamptz not null default '-infinity',
  last_error text,
  fails int not null default 0
);
alter table sl_llm add column if not exists tpd int;
alter table sl_llm add column if not exists last_fail_at timestamptz;
alter table sl_llm enable row level security;
insert into sl_llm (id, provider, rank_main, rank_light, tpm, rpd) values
  ('openai/gpt-oss-120b', 'groq', 1, null, 8000, 1000),
  ('qwen/qwen3.8-27b',    'groq', 2, 2,    8000, 1000),
  ('openai/gpt-oss-20b',  'groq', 3, 1,    8000, 1000),
  ('allam-2-7b',          'groq', null, 3, 6000, 7000)   -- Arabic, 4k context, no tools: light chain only
on conflict (id) do nothing;
-- limits measured from Groq's own 429 messages (Nov 2026): qwen TPM is 7000; gpt-oss models have 200k tokens/day
update sl_llm set tpm = 7000 where id = 'qwen/qwen3.8-27b' and tpm = 8000;
update sl_llm set tpd = 200000 where id in ('openai/gpt-oss-120b', 'openai/gpt-oss-20b') and tpd is null;

create table if not exists sl_llm_calls (
  id bigserial primary key,
  model text not null,
  tokens int not null,
  at timestamptz not null default now()
);
create index if not exists sl_llm_calls_model_at on sl_llm_calls (model, at);
alter table sl_llm_calls enable row level security;

-- returns ["primary", "fallback"] for a chain and reserves p_tokens on the primary
create or replace function sl_llm_pick(p_chain text, p_tokens int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  picked text[] := '{}';
  m record;
begin
  perform pg_advisory_xact_lock(hashtext('sl_llm_pick'));
  for m in
    select l.id, l.tpm, l.rpd,
           coalesce((select sum(tokens) from sl_llm_calls c where c.model = l.id and c.at > now() - interval '1 minute'), 0) as used_min,
           (select count(*) from sl_llm_calls c where c.model = l.id and c.at > date_trunc('day', now())) as used_day,
           coalesce((select sum(tokens) from sl_llm_calls c where c.model = l.id and c.at > now() - interval '24 hours'), 0) as tokens_day,
           l.tpd
      from sl_llm l
     where l.active and l.down_until < now()
       and case when p_chain = 'light' then l.rank_light is not null else l.rank_main is not null end
     order by case when p_chain = 'light' then l.rank_light else l.rank_main end
  loop
    if m.used_min + least(p_tokens, m.tpm) <= m.tpm and m.used_day < m.rpd
       and (m.tpd is null or m.tokens_day + p_tokens <= m.tpd) then picked := picked || m.id; end if;
    exit when array_length(picked, 1) = 2;
  end loop;
  -- not enough free capacity: fill with the least-loaded models that are up or only briefly paused (per-minute limit);
  -- a model paused for its DAILY limit (down > 2 minutes) is never used while another one exists
  if coalesce(array_length(picked, 1), 0) < 2 then
    picked := picked || array(
      select l.id from sl_llm l
       where l.active and not (l.id = any(picked)) and l.down_until < now() + interval '2 minutes'
         and case when p_chain = 'light' then l.rank_light is not null else l.rank_main is not null end
       order by (l.down_until < now()) desc,
                coalesce((select sum(tokens) from sl_llm_calls c where c.model = l.id and c.at > now() - interval '1 minute'), 0),
                case when p_chain = 'light' then l.rank_light else l.rank_main end
       limit 2 - coalesce(array_length(picked, 1), 0));
  end if;
  if coalesce(array_length(picked, 1), 0) = 0 then picked := array['openai/gpt-oss-120b', 'openai/gpt-oss-20b']; end if;
  if array_length(picked, 1) = 1 then picked := picked || picked[1]; end if;
  insert into sl_llm_calls (model, tokens) values (picked[1], greatest(p_tokens, 1));
  delete from sl_llm_calls where at < now() - interval '2 days';
  return to_jsonb(picked);
end $$;

-- seconds to wait before a turn so that some model of the chain has room for p_tokens (a tiny queue: when every
-- model is full, waiting a few seconds is better than failing). 0 = go now; capped at 20 s (a waiting run holds one of
-- n8n Cloud's concurrent-execution slots).
create or replace function sl_llm_wait(p_chain text, p_tokens int) returns int
language sql stable security definer set search_path = public as $$
  with m as (
    select l.id, l.tpm, l.down_until,
           coalesce((select sum(tokens) from sl_llm_calls c where c.model = l.id and c.at > now() - interval '1 minute'), 0) as used,
           (select min(at) from sl_llm_calls c where c.model = l.id and c.at > now() - interval '1 minute') as oldest
      from sl_llm l
     where l.active and case when p_chain = 'light' then l.rank_light is not null else l.rank_main is not null end
  )
  select case
    when exists (select 1 from m where down_until < now() and used + least(p_tokens, tpm) <= tpm) then 0
    else least(20, greatest(1, ceil(coalesce(
      (select min(case when down_until > now() then extract(epoch from down_until - now())
                       else 60 - extract(epoch from now() - oldest) + 1 end) from m), 0))))::int
  end
$$;

-- a model answered "too many requests": skip it for 1 minute (per-minute limit) or 30 minutes (daily limit)
-- Per-minute errors are normal under load: 65 s. 30 minutes only when the daily quota is (nearly) gone: the message says so,
-- or the tokens we routed to this model in the last 24 h reach 85% of its daily limit.
create or replace function sl_llm_fail(p_models jsonb, p_err text) returns void
language sql security definer set search_path = public as $$
  update sl_llm set
    down_until = greatest(down_until, now() + case when coalesce(p_err, '') ~* '(per day|tokens per day|requests per day|TPD|RPD|daily)'
                                or (tpd is not null and coalesce((select sum(tokens) from sl_llm_calls c where c.model = sl_llm.id
                                                                   and c.at > now() - interval '24 hours'), 0) >= tpd * 0.85)
                              then interval '30 minutes' else interval '65 seconds' end),   -- never shortens a longer pause
    last_error = left(p_err, 300), fails = fails + 1, last_fail_at = now()
  where id in (select jsonb_array_elements_text(coalesce(p_models, '[]'::jsonb)))
$$;

-- health of every model, for the admin dashboard
create or replace function sl_llm_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', l.id, 'provider', l.provider, 'rank_main', l.rank_main, 'rank_light', l.rank_light, 'active', l.active,
           'up', l.down_until < now(), 'down_until', case when l.down_until > now() then l.down_until end,
           'last_error', l.last_error, 'fails', l.fails, 'tpm', l.tpm, 'tpd', l.tpd,
           'tokens_day', coalesce((select sum(tokens) from sl_llm_calls c where c.model = l.id and c.at > now() - interval '24 hours'), 0),
           'tokens_min', coalesce((select sum(tokens) from sl_llm_calls c where c.model = l.id and c.at > now() - interval '1 minute'), 0),
           'calls_today', (select count(*) from sl_llm_calls c where c.model = l.id and c.at > date_trunc('day', now())))
         order by coalesce(l.rank_main, 99), coalesce(l.rank_light, 99)), '[]'::jsonb)
  from sl_llm l
$$;

revoke all on function sl_llm_pick(text, int), sl_llm_wait(text, int), sl_llm_fail(jsonb, text), sl_llm_status() from public, anon, authenticated;
select 'ok' as status;
