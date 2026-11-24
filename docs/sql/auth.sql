create extension if not exists pgcrypto with schema extensions;

create table if not exists sl_plans (plan text primary key, daily_messages int not null, max_docs int not null);
-- the admin edits the limits from the dashboard, so re-running this file must not reset them
insert into sl_plans (plan, daily_messages, max_docs) values ('free', 6, 10), ('pro', 300, 30)
  on conflict (plan) do nothing;
alter table sl_plans add column if not exists daily_maps int not null default 1;
alter table sl_plans add column if not exists daily_timelines int not null default 1;
alter table sl_plans add column if not exists daily_uploads int not null default 1;
alter table sl_plans add column if not exists daily_drafts int not null default 0;   -- document drafting (drafts.sql)

create table if not exists sl_users (
  id uuid primary key default gen_random_uuid(),
  email text unique not null,
  password_hash text not null,
  full_name text,
  plan text not null default 'free' references sl_plans(plan),
  role text not null default 'user' check (role in ('user','admin')),
  created_at timestamptz default now()
);
create table if not exists sl_sessions (
  token text primary key,
  user_id uuid not null references sl_users(id) on delete cascade,
  expires_at timestamptz not null
);
create table if not exists sl_usage (
  user_id uuid references sl_users(id) on delete cascade,
  day date not null,
  messages int not null default 0,
  primary key (user_id, day)
);
-- per-user overrides set by the admin, e.g. {"daily_messages": 50, "daily_uploads": 3}; missing keys use the plan
alter table sl_users add column if not exists limits jsonb not null default '{}'::jsonb;
alter table sl_users add column if not exists disabled boolean not null default false;
alter table sl_users add column if not exists created_by uuid;
alter table sl_plans enable row level security;
alter table sl_users enable row level security;
alter table sl_sessions enable row level security;
alter table sl_usage enable row level security;

-- per-day counters of the other features (map, timeline, upload)
create table if not exists sl_feature_usage (
  user_id uuid not null references sl_users(id) on delete cascade,
  day date not null,
  feature text not null,
  n int not null default 0,
  primary key (user_id, day, feature)
);
alter table sl_feature_usage enable row level security;

-- effective limits of one user: plan limits, overridden by sl_users.limits; admins are unlimited
create or replace function sl_limits(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when u.role = 'admin'
    then jsonb_build_object('daily_messages', 100000, 'daily_maps', 100000, 'daily_timelines', 100000, 'daily_uploads', 100000, 'max_docs', 100000, 'daily_drafts', 100000)
    else jsonb_build_object('daily_messages', p.daily_messages, 'daily_maps', p.daily_maps, 'daily_timelines', p.daily_timelines,
                            'daily_uploads', p.daily_uploads, 'max_docs', p.max_docs, 'daily_drafts', p.daily_drafts) || coalesce(u.limits, '{}'::jsonb) end
  from sl_users u join sl_plans p on p.plan = u.plan where u.id = p_user
$$;

-- user profile + today's usage, or null (also null for a disabled account)
create or replace function sl_user_json(p_token text) returns jsonb
language sql security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object('id', u.id, 'email', u.email, 'name', u.full_name, 'plan', u.plan, 'role', u.role),
    'usage', jsonb_build_object(
      'used', coalesce((select messages from sl_usage where user_id = u.id and day = (now() at time zone 'Africa/Cairo')::date), 0),
      'limit', (l->>'daily_messages')::int,
      'max_docs', (l->>'max_docs')::int,
      'limits', l,
      'uploads_today', coalesce((select n from sl_feature_usage where user_id = u.id and day = (now() at time zone 'Africa/Cairo')::date and feature = 'upload'), 0),
      'docs', (select count(distinct metadata->>'fileName') from documents where metadata->>'userId' = u.id::text)))
  from sl_sessions s join sl_users u on u.id = s.user_id
       cross join lateral sl_limits(u.id) l
  where s.token = p_token and s.expires_at > now() and not u.disabled
$$;

create or replace function sl_new_session(p_user uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare t text := encode(gen_random_bytes(32), 'hex');
begin
  delete from sl_sessions where user_id = p_user and expires_at < now();
  insert into sl_sessions values (t, p_user, now() + interval '30 days');
  return t;
end $$;

-- single entry point for the website API
create or replace function sl_api(p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := lower(trim(coalesce(p->>'email', '')));
  v_pass text := coalesce(p->>'password', '');
  v_token text := coalesce(p->>'token', '');
  u sl_users;
  t text;
  j jsonb;
begin
  if p_action = 'signup' then
    if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'الإيميل مش صحيح'); end if;
    if length(v_pass) < 8 then return jsonb_build_object('ok', false, 'error', 'الباسورد لازم يكون 8 حروف على الأقل'); end if;
    if exists (select 1 from sl_users where email = v_email) then return jsonb_build_object('ok', false, 'error', 'الإيميل ده متسجل قبل كده، اعمل تسجيل دخول'); end if;
    insert into sl_users (email, password_hash, full_name)
      values (v_email, crypt(v_pass, gen_salt('bf', 10)), nullif(trim(coalesce(p->>'name', '')), ''))
      returning * into u;
    t := sl_new_session(u.id);
    return sl_user_json(t) || jsonb_build_object('token', t);
  elsif p_action = 'login' then
    select * into u from sl_users where email = v_email;
    if u.id is null or u.password_hash <> crypt(v_pass, u.password_hash) then
      return jsonb_build_object('ok', false, 'error', 'الإيميل أو الباسورد غلط');
    end if;
    if u.disabled then return jsonb_build_object('ok', false, 'error', 'الحساب ده موقوف. تواصل مع الإدارة.'); end if;
    t := sl_new_session(u.id);
    return sl_user_json(t) || jsonb_build_object('token', t);
  elsif p_action = 'me' then
    j := sl_user_json(v_token);
    if j is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
    return jsonb_set(j, '{usage,maps}', sl_maps_usage(j));   -- history_maps.sql
  elsif p_action in ('sessions', 'history', 'delete_session', 'feedback') then
    j := sl_user_json(v_token);
    if j is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
    return sl_api_ext(p_action, p, j);                         -- history_maps.sql
  elsif p_action in ('notifications', 'notifications_read') then
    j := sl_user_json(v_token);
    if j is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
    return sl_notif_api(p_action, p, j);                       -- issues.sql
  elsif p_action like 'admin\_%' then
    j := sl_user_json(v_token);
    if j is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
    if j->'user'->>'role' <> 'admin' then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
    return sl_admin(p_action, p, j);                           -- admin.sql
  elsif p_action = 'logout' then
    delete from sl_sessions where token = v_token;
    return jsonb_build_object('ok', true);
  elsif p_action = 'docs' then
    j := sl_user_json(v_token);
    if j is null then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
    return jsonb_build_object('ok', true,
      'mine', coalesce((select jsonb_agg(x order by x->>'file') from (
          select jsonb_build_object('file', metadata->>'fileName', 'chunks', count(*)) x
          from documents where metadata->>'userId' = j->'user'->>'id' group by metadata->>'fileName') q), '[]'::jsonb),
      'library', coalesce((select jsonb_agg(x order by x->>'file') from (
          select jsonb_build_object('file', metadata->>'fileName', 'chunks', count(*)) x
          from documents where metadata->>'userId' = 'public' group by metadata->>'fileName') q), '[]'::jsonb));
  end if;
  return jsonb_build_object('ok', false, 'error', 'unknown action');
end $$;

-- called by the chat workflow: auth + daily quota + count the message
create or replace function sl_consume(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare j jsonb; d date := (now() at time zone 'Africa/Cairo')::date;
  is_retry boolean := exists (select 1 from sl_sessions where token = p_token and purpose = 'retry');   -- admin resend (issues.sql)
begin
  j := sl_user_json(p_token);
  if j is null then return jsonb_build_object('ok', false, 'error', 'unauthorized', 'message', 'لازم تسجل دخول الأول.'); end if;
  if is_retry then
    return jsonb_build_object('ok', true, 'user_id', j->'user'->>'id',
      'plan', case when j->'user'->>'role' = 'admin' then 'pro' else j->'user'->>'plan' end,
      'remaining', (j->'usage'->>'limit')::int - (j->'usage'->>'used')::int);
  end if;
  if (j->'usage'->>'used')::int >= (j->'usage'->>'limit')::int then
    return jsonb_build_object('ok', false, 'error', 'quota', 'message',
      case when j->'user'->>'plan' = 'free'
        then 'خلصت رسايلك المجانية النهارده (' || (j->'usage'->>'limit') || ' رسالة). ارجع بكرة أو اشترك في Pro.'
        else 'وصلت للحد اليومي لحسابك. ارجع بكرة.' end);
  end if;
  insert into sl_usage (user_id, day, messages) values ((j->'user'->>'id')::uuid, d, 1)
    on conflict (user_id, day) do update set messages = sl_usage.messages + 1;
  return jsonb_build_object('ok', true,
    'user_id', j->'user'->>'id',
    'plan', case when j->'user'->>'role' = 'admin' then 'pro' else j->'user'->>'plan' end,
    'remaining', (j->'usage'->>'limit')::int - (j->'usage'->>'used')::int - 1);
end $$;

-- called by the upload workflow: who owns the file
create or replace function sl_can_upload(p_token text, p_target text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare j jsonb;
begin
  j := sl_user_json(p_token);
  if j is null then return jsonb_build_object('ok', false, 'error', 'لازم تسجل دخول الأول.'); end if;
  if p_target = 'public' then
    if j->'user'->>'role' <> 'admin' then return jsonb_build_object('ok', false, 'error', 'الرفع للمكتبة العامة للأدمن بس.'); end if;
    return jsonb_build_object('ok', true, 'owner_id', 'public');
  end if;
  if (j->'usage'->>'max_docs')::int = 0 then
    perform sl_upload_log(j, 'upload_denied', 'disabled');
    return jsonb_build_object('ok', false, 'error', 'رفع المستندات مش متاح لحسابك.');
  end if;
  if (j->'usage'->>'docs')::int >= (j->'usage'->>'max_docs')::int then
    perform sl_upload_log(j, 'upload_denied', 'max_docs');
    return jsonb_build_object('ok', false, 'error', 'وصلت للحد الأقصى لعدد المستندات (' || (j->'usage'->>'max_docs') || ').');
  end if;
  if (j->'usage'->>'uploads_today')::int >= (j->'usage'->'limits'->>'daily_uploads')::int then
    perform sl_upload_log(j, 'upload_denied', 'daily');
    return jsonb_build_object('ok', false, 'error',
      'خلص رفع المستندات النهارده (' || (j->'usage'->'limits'->>'daily_uploads') || ').'
      || case when j->'user'->>'plan' = 'free' then ' ارجع بكرة أو اشترك في Pro.' else ' ارجع بكرة.' end);
  end if;
  insert into sl_feature_usage (user_id, day, feature, n) values ((j->'user'->>'id')::uuid, (now() at time zone 'Africa/Cairo')::date, 'upload', 1)
    on conflict (user_id, day, feature) do update set n = sl_feature_usage.n + 1;
  perform sl_upload_log(j, 'upload', null);
  return jsonb_build_object('ok', true, 'owner_id', j->'user'->>'id');
end $$;



revoke all on function sl_api(text, jsonb), sl_consume(text), sl_can_upload(text, text), sl_user_json(text), sl_new_session(uuid),
  sl_limits(uuid) from public, anon, authenticated;

-- remove the fake test law used in the earlier end-to-end test
delete from documents where metadata->>'userId' = 'usr-claude-e2e';
select 'ok' as status;
