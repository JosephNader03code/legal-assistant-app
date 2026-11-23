-- ============ 👍/👎 on answers (also the future fine-tuning dataset) ============
-- Run after history_maps.sql.
create table if not exists sl_feedback (
  id bigserial primary key,
  user_id uuid not null references sl_users(id) on delete cascade,
  session_id text not null,             -- full key "userId:sessionId"
  answer_hash text not null,            -- md5 of the answer text, one vote per answer
  rating smallint not null check (rating in (-1, 1)),
  kind text not null default 'chat',    -- chat | map
  question text,
  answer text not null,
  plan text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, session_id, answer_hash)
);
create index if not exists sl_feedback_rating on sl_feedback (rating, created_at);
alter table sl_feedback enable row level security;

-- p: {session, question, answer, rating: 1 | -1 | 0 (0 = remove the vote), kind}
create or replace function sl_feedback_set(j jsonb, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := (j->'user'->>'id')::uuid;
  key text := uid::text || ':' || left(regexp_replace(coalesce(p->>'session', ''), '[^A-Za-z0-9_-]', '', 'g'), 64);
  ans text := left(coalesce(p->>'answer', ''), 20000);
  r int := coalesce((p->>'rating')::int, 0);
begin
  if ans = '' then return jsonb_build_object('ok', false, 'error', 'missing answer'); end if;
  if r = 0 then
    delete from sl_feedback where user_id = uid and session_id = key and answer_hash = md5(ans);
    return jsonb_build_object('ok', true, 'rating', 0);
  end if;
  if r not in (-1, 1) then return jsonb_build_object('ok', false, 'error', 'bad rating'); end if;
  insert into sl_feedback (user_id, session_id, answer_hash, rating, kind, question, answer, plan)
  values (uid, key, md5(ans), r, case when p->>'kind' = 'map' then 'map' else 'chat' end,
          left(nullif(p->>'question', ''), 4000), ans,
          case when j->'user'->>'role' = 'admin' then 'admin' else j->'user'->>'plan' end)
  on conflict (user_id, session_id, answer_hash)
  do update set rating = excluded.rating, updated_at = now();
  return jsonb_build_object('ok', true, 'rating', r);
end $$;

revoke all on function sl_feedback_set(jsonb, jsonb) from public, anon, authenticated;
select 'ok' as status;
