-- ============ Problems users hit: admin alert -> resend -> user notification ============
-- Run after search_log.sql and admin.sql.
-- Flow: a chat / map turn fails -> sl_log() calls sl_issue_track() -> an open row in sl_issues (admin sees an alert).
-- The admin presses "resend": admin_issue_retry mints a 10-minute session (purpose 'retry') for that user; the browser sends
-- the same question with it and retryOf = issue id. That turn is not counted against the user's limits, it lands in the
-- user's own chat, and sl_log() marks the issue resolved and creates a notification the user's app shows.

alter table sl_sessions add column if not exists purpose text;   -- null = normal login, 'retry' = admin resend

create table if not exists sl_issues (
  id bigserial primary key,
  user_id uuid references sl_users(id) on delete cascade,
  nickname text,
  session_id text,                 -- the chat id shown in the UI ("s...")
  kind text not null,              -- free | pro | mindmap | timeline
  question text,
  error text,
  exec_id text,
  attempts int not null default 1,
  status text not null default 'open' check (status in ('open', 'retrying', 'resolved', 'dismissed')),
  answer text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid
);
create index if not exists sl_issues_status on sl_issues (status, created_at desc);
alter table sl_issues enable row level security;

create table if not exists sl_notifications (
  id bigserial primary key,
  user_id uuid not null references sl_users(id) on delete cascade,
  issue_id bigint references sl_issues(id) on delete set null,
  session_id text,
  title text not null,
  body text,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists sl_notifications_user on sl_notifications (user_id, created_at desc);
alter table sl_notifications enable row level security;

-- called by sl_log for every chat / map turn
create or replace function sl_issue_track(p_user uuid, p_name text, p_session text, p_kind text, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  failed boolean := coalesce(p->>'error', '') <> '';
  retry_of bigint := nullif(p->>'retry_of', '')::bigint;
  q text := left(coalesce(p->>'question', ''), 4000);
  iss sl_issues;
begin
  if p_user is null or p_kind not in ('free', 'pro', 'mindmap', 'timeline') then return; end if;
  if retry_of is not null then
    select * into iss from sl_issues where id = retry_of and user_id = p_user;
    delete from sl_sessions where token = coalesce(p->>'token', '') and purpose = 'retry';
    if iss.id is null then return; end if;
    if failed then
      update sl_issues set status = 'open', attempts = attempts + 1, error = left(p->>'error', 500), exec_id = p->>'exec_id', updated_at = now()
       where id = iss.id;
    else
      update sl_issues set status = 'resolved', answer = left(coalesce(p->>'answer', ''), 4000), exec_id = p->>'exec_id',
             resolved_at = now(), updated_at = now() where id = iss.id;
      insert into sl_notifications (user_id, issue_id, session_id, title, body)
      values (p_user, iss.id, iss.session_id,
              case when iss.kind = 'mindmap' then 'خريطتك الذهنية جهزت' when iss.kind = 'timeline' then 'الخط الزمني جهز' else 'وصل رد على سؤالك' end,
              left(iss.question, 140));
    end if;
    return;
  end if;
  if not failed then return; end if;
  -- the same question failing again in the same chat: one open issue, more attempts
  update sl_issues set attempts = attempts + 1, error = left(p->>'error', 500), exec_id = p->>'exec_id', updated_at = now()
   where user_id = p_user and session_id = p_session and question = q and status in ('open', 'retrying')
  returning * into iss;
  if iss.id is null then
    insert into sl_issues (user_id, nickname, session_id, kind, question, error, exec_id)
    values (p_user, p_name, nullif(p_session, ''), p_kind, q, left(p->>'error', 500), p->>'exec_id');
  end if;
end $$;

-- user actions: notifications (list + unread count), notifications_read {ids: [..]} or {all: true}
create or replace function sl_notif_api(p_action text, p jsonb, j jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := (j->'user'->>'id')::uuid;
begin
  if p_action = 'notifications' then
    return jsonb_build_object('ok', true,
      'unread', (select count(*) from sl_notifications where user_id = uid and read_at is null),
      'items', coalesce((select jsonb_agg(x order by (x->>'id')::bigint desc) from (
        select jsonb_build_object('id', id, 'title', title, 'body', body, 'session', session_id, 'at', created_at, 'read', read_at is not null) x
          from sl_notifications where user_id = uid order by id desc limit 20) t), '[]'::jsonb));
  elsif p_action = 'notifications_read' then
    update sl_notifications set read_at = now()
     where user_id = uid and read_at is null
       and (coalesce((p->>'all')::boolean, false)
            or id in (select (jsonb_array_elements_text(coalesce(p->'ids', '[]'::jsonb)))::bigint));
    return jsonb_build_object('ok', true);
  end if;
  return jsonb_build_object('ok', false, 'error', 'unknown action');
end $$;

-- admin actions (routed from sl_admin): admin_issues {status}, admin_issue_retry {id}, admin_issue_set {id, status}
create or replace function sl_issue_admin(p_action text, p jsonb, j jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  me uuid := (j->'user'->>'id')::uuid;
  iss sl_issues;
  t text;
  st text := coalesce(nullif(p->>'status', ''), 'open');
begin
  if p_action = 'admin_issues' then
    return jsonb_build_object('ok', true,
      'counts', (select jsonb_object_agg(status, n) from (select status, count(*) n from sl_issues group by status) c),
      'issues', coalesce((select jsonb_agg(x order by x->>'updated_at' desc) from (
        select jsonb_build_object('id', i.id, 'user_id', i.user_id, 'name', coalesce(i.nickname, split_part(u.email, '@', 1)), 'email', u.email,
                                  'plan', case when u.role = 'admin' then 'admin' else u.plan end, 'session', i.session_id, 'kind', i.kind,
                                  'question', i.question, 'error', i.error, 'exec_id', i.exec_id, 'attempts', i.attempts, 'status', i.status,
                                  'answer', left(i.answer, 600), 'created_at', i.created_at, 'updated_at', i.updated_at, 'resolved_at', i.resolved_at) x
          from sl_issues i left join sl_users u on u.id = i.user_id
         where case when st = 'all' then true when st = 'open' then i.status in ('open', 'retrying') else i.status = st end
         order by i.updated_at desc limit 100) q), '[]'::jsonb));

  elsif p_action = 'admin_issue_retry' then
    select * into iss from sl_issues where id = (p->>'id')::bigint;
    if iss.id is null then return jsonb_build_object('ok', false, 'error', 'المشكلة مش موجودة'); end if;
    if iss.status in ('resolved', 'dismissed') then return jsonb_build_object('ok', false, 'error', 'المشكلة دي اتقفلت'); end if;
    if iss.user_id is null or iss.session_id is null then return jsonb_build_object('ok', false, 'error', 'المستخدم أو الشات مش موجود'); end if;
    if exists (select 1 from sl_users where id = iss.user_id and disabled) then return jsonb_build_object('ok', false, 'error', 'حساب المستخدم موقوف'); end if;
    t := encode(gen_random_bytes(32), 'hex');
    delete from sl_sessions where user_id = iss.user_id and purpose = 'retry' and expires_at < now();
    insert into sl_sessions (token, user_id, expires_at, purpose) values (t, iss.user_id, now() + interval '10 minutes', 'retry');
    update sl_issues set status = 'retrying', updated_at = now() where id = iss.id;
    return jsonb_build_object('ok', true, 'token', t, 'session', iss.session_id, 'question', iss.question, 'kind', iss.kind);

  elsif p_action = 'admin_issue_set' then
    if st not in ('open', 'resolved', 'dismissed') then return jsonb_build_object('ok', false, 'error', 'حالة مش صحيحة'); end if;
    update sl_issues set status = st, updated_at = now(),
           resolved_at = case when st = 'open' then null else now() end, resolved_by = case when st = 'open' then null else me end
     where id = (p->>'id')::bigint
    returning * into iss;
    if iss.id is null then return jsonb_build_object('ok', false, 'error', 'المشكلة مش موجودة'); end if;
    return jsonb_build_object('ok', true);
  end if;
  return jsonb_build_object('ok', false, 'error', 'unknown action');
end $$;

revoke all on function sl_issue_track(uuid, text, text, text, jsonb), sl_notif_api(text, jsonb, jsonb), sl_issue_admin(text, jsonb, jsonb)
  from public, anon, authenticated;
select 'ok' as status;
