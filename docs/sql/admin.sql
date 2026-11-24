-- ============ Admin dashboard API (sl_api actions "admin_*", admins only) ============
-- Run last: auth.sql, routing_cache.sql, case_files.sql, history_maps.sql, feedback.sql, search_log.sql, admin.sql

-- one-time defaults for the plan limits (afterwards the admin edits them from the dashboard)
do $$ begin
  if not exists (select 1 from sl_settings where key = 'plan_defaults_v2') then
    update sl_plans set daily_messages = 6, daily_maps = 1, daily_timelines = 1, daily_uploads = 1, max_docs = 10 where plan = 'free';
    update sl_plans set daily_maps = 8, daily_timelines = 8, daily_uploads = 20 where plan = 'pro';
    insert into sl_settings values ('plan_defaults_v2', 'applied');
  end if;
end $$;

-- admin's verdict on a user's question (👍 good question / 👎 not useful); the text is copied so it survives a deleted chat
create table if not exists sl_question_review (
  msg_id int primary key,              -- n8n_chat_histories.id of the human message
  user_id uuid references sl_users(id) on delete cascade,
  session_id text not null,
  question text not null,
  rating smallint not null check (rating in (-1, 1)),
  reviewed_by uuid,
  at timestamptz not null default now()
);
create index if not exists sl_question_review_user on sl_question_review (user_id, at);
alter table sl_question_review enable row level security;

-- keep only known limit keys with sane integer values; '' / null removes the override
create or replace function sl_clean_limits(p jsonb) returns jsonb
language sql immutable set search_path = public as $$
  select coalesce(jsonb_object_agg(k, least(greatest((v #>> '{}')::numeric, 0), 100000)::int), '{}'::jsonb)
    from jsonb_each(coalesce(p, '{}'::jsonb)) e(k, v)
   where k in ('daily_messages', 'daily_maps', 'daily_timelines', 'daily_uploads', 'max_docs')
     and (v #>> '{}') ~ '^\s*[0-9]+\s*$'
$$;

create or replace function sl_admin(p_action text, p jsonb, j jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  me uuid := (j->'user'->>'id')::uuid;
  d date := (now() at time zone 'Africa/Cairo')::date;
  v_email text := lower(trim(coalesce(p->>'email', '')));
  v_id uuid;
  u sl_users;
  r jsonb;
begin
  -- ---------- overview: tiles, 14-day series, today's lists ----------
  if p_action = 'admin_overview' then
    return jsonb_build_object('ok', true,
      'today', d,
      'users', jsonb_build_object(
        'total', (select count(*) from sl_users),
        'free', (select count(*) from sl_users where plan = 'free' and role <> 'admin'),
        'pro', (select count(*) from sl_users where plan = 'pro' and role <> 'admin'),
        'admins', (select count(*) from sl_users where role = 'admin'),
        'disabled', (select count(*) from sl_users where disabled),
        'new_today', (select count(*) from sl_users where (created_at at time zone 'Africa/Cairo')::date = d),
        'new_7d', (select count(*) from sl_users where created_at > now() - interval '7 days')),
      'activity', jsonb_build_object(
        'active_today', (select count(*) from sl_usage where day = d and messages > 0),
        'messages_today', (select coalesce(sum(messages), 0) from sl_usage where day = d),
        'uploads_today', (select coalesce(sum(n), 0) from sl_feature_usage where day = d and feature = 'upload'),
        'uploaders_today', (select count(*) from sl_feature_usage where day = d and feature = 'upload' and n > 0),
        'maps_today', (select coalesce(sum(n), 0) from sl_feature_usage where day = d and feature = 'map'),
        'timelines_today', (select coalesce(sum(n), 0) from sl_feature_usage where day = d and feature = 'timeline'),
        'quota_users_today', (select count(distinct user_id) from sl_request_log where day = d and quota_hit),
        'failed_today', (select count(*) from sl_request_log where day = d and kind in ('free', 'pro') and error is not null),
        'answers_today', (select count(*) from sl_request_log where day = d and kind in ('free', 'pro', 'cached')),
        'cached_today', (select count(*) from sl_request_log where day = d and kind = 'cached'),
        'clarify_today', (select count(*) from sl_request_log where day = d and kind = 'clarify'),
        'keyword_today', (select count(*) from sl_request_log where day = d and kind in ('free', 'pro') and embed_ok = false),
        'avg_seconds_today', (select round(avg(latency_ms)::numeric / 1000, 1) from sl_request_log where day = d and kind in ('free', 'pro') and error is null),
        'tokens_est_today', (select coalesce(sum(tokens_est), 0) from sl_request_log where day = d),
        'likes_7d', (select count(*) from sl_feedback where rating = 1 and created_at > now() - interval '7 days'),
        'dislikes_7d', (select count(*) from sl_feedback where rating = -1 and created_at > now() - interval '7 days'),
        'open_issues', (select count(*) from sl_issues where status in ('open', 'retrying')),
        'good_questions', (select count(*) from sl_question_review where rating = 1),
        'bad_questions', (select count(*) from sl_question_review where rating = -1)),
      'series', (select jsonb_agg(jsonb_build_object('day', g.day,
                    'messages', coalesce((select sum(messages) from sl_usage where day = g.day), 0),
                    'active', (select count(*) from sl_usage where day = g.day and messages > 0),
                    'uploads', coalesce((select sum(n) from sl_feature_usage where day = g.day and feature = 'upload'), 0)) order by g.day)
                   from (select generate_series(d - 13, d, interval '1 day')::date as day) g),
      'top_today', coalesce((select jsonb_agg(x order by (x->>'messages')::int desc) from (
          select jsonb_build_object('id', us.id, 'name', coalesce(nullif(us.full_name, ''), split_part(us.email, '@', 1)), 'email', us.email,
                                    'plan', case when us.role = 'admin' then 'admin' else us.plan end,
                                    'messages', g.messages, 'limit', (sl_limits(us.id)->>'daily_messages')::int) x
            from sl_usage g join sl_users us on us.id = g.user_id
           where g.day = d and g.messages > 0 order by g.messages desc limit 8) t), '[]'::jsonb),
      'recent_dislikes', coalesce((select jsonb_agg(x) from (
          select jsonb_build_object('at', f.created_at, 'name', coalesce(nullif(us.full_name, ''), split_part(us.email, '@', 1)),
                                    'question', left(f.question, 200), 'answer', left(f.answer, 300)) x
            from sl_feedback f join sl_users us on us.id = f.user_id
           where f.rating = -1 order by f.created_at desc limit 5) t), '[]'::jsonb),
      'llm', sl_llm_status(),
      'search', jsonb_build_object('gemini_ok', sl_embed_ok(),
                                   'down_until', (select value from sl_settings where key = 'embed_down_until')),
      'plans', (select jsonb_agg(to_jsonb(pl) order by pl.plan) from sl_plans pl));

  -- ---------- users table ----------
  elsif p_action = 'admin_users' then
    return jsonb_build_object('ok', true, 'users', coalesce((select jsonb_agg(x order by (x->>'last_active') desc nulls last, x->>'created_at' desc) from (
      select jsonb_build_object(
        'id', us.id, 'email', us.email, 'name', us.full_name, 'plan', us.plan, 'role', us.role, 'disabled', us.disabled,
        'created_at', us.created_at, 'overrides', us.limits, 'limits', sl_limits(us.id),
        'messages_today', coalesce((select messages from sl_usage where user_id = us.id and day = d), 0),
        'messages_7d', coalesce((select sum(messages) from sl_usage where user_id = us.id and day > d - 7), 0),
        'maps_today', coalesce((select n from sl_feature_usage where user_id = us.id and day = d and feature = 'map'), 0),
        'timelines_today', coalesce((select n from sl_feature_usage where user_id = us.id and day = d and feature = 'timeline'), 0),
        'uploads_today', coalesce((select n from sl_feature_usage where user_id = us.id and day = d and feature = 'upload'), 0),
        'docs', (select count(distinct metadata->>'fileName') from documents where metadata->>'userId' = us.id::text),
        'chats_today', (select count(distinct session_id) from sl_request_log where user_id = us.id and day = d and session_id is not null),
        'quota_hit_today', exists (select 1 from sl_request_log where user_id = us.id and day = d and quota_hit),
        'chats', (select count(distinct session_id) from n8n_chat_histories where session_id like us.id::text || ':%'),
        'last_active', greatest((select max(at) from sl_request_log where user_id = us.id),
                                (select (max(day)::timestamp at time zone 'Africa/Cairo') from sl_usage where user_id = us.id and messages > 0))) x
      from sl_users us) t), '[]'::jsonb));

  -- ---------- one user's recent activity ----------
  elsif p_action = 'admin_user_log' then
    v_id := nullif(p->>'id', '')::uuid;
    return jsonb_build_object('ok', true, 'log', coalesce((select jsonb_agg(x order by x->>'at' desc) from (
      select jsonb_build_object('at', at, 'kind', kind, 'session', session_id, 'msg_no', msg_no, 'msg_limit', msg_limit,
                                'seconds', round(latency_ms::numeric / 1000, 1), 'tokens', coalesce(tokens_in + tokens_out, tokens_est),
                                'error', error, 'keyword', embed_ok = false) x
        from sl_request_log where user_id = v_id order by id desc limit 60) t), '[]'::jsonb));

  -- ---------- create a user ----------
  elsif p_action = 'admin_create_user' then
    if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'الإيميل مش صحيح'); end if;
    if length(coalesce(p->>'password', '')) < 8 then return jsonb_build_object('ok', false, 'error', 'الباسورد لازم يكون 8 حروف على الأقل'); end if;
    if exists (select 1 from sl_users where email = v_email) then return jsonb_build_object('ok', false, 'error', 'الإيميل ده متسجل قبل كده'); end if;
    if coalesce(p->>'plan', 'free') not in (select plan from sl_plans) then return jsonb_build_object('ok', false, 'error', 'باقة مش معروفة'); end if;
    insert into sl_users (email, password_hash, full_name, plan, role, limits, created_by)
    values (v_email, crypt(p->>'password', gen_salt('bf', 10)), nullif(trim(coalesce(p->>'name', '')), ''),
            coalesce(p->>'plan', 'free'), case when p->>'role' = 'admin' then 'admin' else 'user' end,
            sl_clean_limits(p->'limits'), me)
    returning * into u;
    return jsonb_build_object('ok', true, 'id', u.id);

  -- ---------- edit a user (plan, role, limits, disable, name, password) ----------
  elsif p_action = 'admin_update_user' then
    v_id := nullif(p->>'id', '')::uuid;
    select * into u from sl_users where id = v_id;
    if u.id is null then return jsonb_build_object('ok', false, 'error', 'المستخدم مش موجود'); end if;
    if v_id = me and ((p ? 'role' and p->>'role' <> 'admin') or coalesce((p->>'disabled')::boolean, false)) then
      return jsonb_build_object('ok', false, 'error', 'مينفعش تشيل صلاحية الأدمن من نفسك أو توقف حسابك.');
    end if;
    if p ? 'plan' and p->>'plan' not in (select plan from sl_plans) then return jsonb_build_object('ok', false, 'error', 'باقة مش معروفة'); end if;
    if p ? 'password' and length(coalesce(p->>'password', '')) > 0 and length(p->>'password') < 8 then
      return jsonb_build_object('ok', false, 'error', 'الباسورد لازم يكون 8 حروف على الأقل');
    end if;
    update sl_users set
      full_name = case when p ? 'name' then nullif(trim(coalesce(p->>'name', '')), '') else full_name end,
      plan = coalesce(nullif(p->>'plan', ''), plan),
      role = case when p ? 'role' then case when p->>'role' = 'admin' then 'admin' else 'user' end else role end,
      disabled = coalesce((p->>'disabled')::boolean, disabled),
      limits = case when p ? 'limits' then sl_clean_limits(p->'limits') else limits end,
      password_hash = case when length(coalesce(p->>'password', '')) >= 8 then crypt(p->>'password', gen_salt('bf', 10)) else password_hash end
    where id = v_id;
    if coalesce((p->>'disabled')::boolean, false) or length(coalesce(p->>'password', '')) >= 8 then
      delete from sl_sessions where user_id = v_id;   -- log the user out everywhere
    end if;
    return jsonb_build_object('ok', true);

  -- ---------- one user's chats ----------
  elsif p_action = 'admin_user_chats' then
    v_id := nullif(p->>'id', '')::uuid;
    return jsonb_build_object('ok', true, 'chats', coalesce((select jsonb_agg(x order by (x->>'last_id')::int desc) from (
      select jsonb_build_object(
        'id', split_part(h.session_id, ':', 2),
        'questions', count(*) filter (where h.message->>'type' = 'human'),
        'last_id', max(h.id),
        'title', left((array_agg(sl_clean_msg(h.message->>'content') order by h.id) filter (where h.message->>'type' = 'human'))[1], 90),
        'good', (select count(*) from sl_question_review r where r.session_id = h.session_id and r.rating = 1),
        'bad', (select count(*) from sl_question_review r where r.session_id = h.session_id and r.rating = -1)) x
        from n8n_chat_histories h
       where h.session_id like v_id::text || ':%'
       group by h.session_id
      having count(*) filter (where h.message->>'type' = 'human') > 0
       order by max(h.id) desc limit 200) t), '[]'::jsonb));

  -- ---------- messages of one chat, with the admin's rating on each question and the user's 👍/👎 on each answer ----------
  elsif p_action = 'admin_user_messages' then
    v_id := nullif(p->>'id', '')::uuid;
    return jsonb_build_object('ok', true, 'messages', coalesce((select jsonb_agg(x order by (x->>'msg_id')::int) from (
      select jsonb_build_object(
        'msg_id', h.id,
        'role', case when h.message->>'type' = 'human' then 'user' else 'bot' end,
        'text', sl_clean_msg(h.message->>'content'),
        'review', (select r.rating from sl_question_review r where r.msg_id = h.id),
        'user_rating', case when h.message->>'type' = 'ai' then
            (select f.rating from sl_feedback f where f.user_id = v_id and f.session_id = h.session_id
                and f.answer_hash = md5(left(sl_clean_msg(h.message->>'content'), 20000))) end) x
        from n8n_chat_histories h
       where h.session_id = v_id::text || ':' || left(regexp_replace(coalesce(p->>'session', ''), '[^A-Za-z0-9_-]', '', 'g'), 64)
         and h.message->>'type' in ('human', 'ai')
         and jsonb_typeof(h.message->'content') = 'string' and coalesce(h.message->>'content', '') <> '') t), '[]'::jsonb));

  -- ---------- rate a user's question: 1 good, -1 not useful, 0 remove ----------
  elsif p_action = 'admin_rate_question' then
    select z.r into r from (select h.id, h.session_id, h.message from n8n_chat_histories h
                           where h.id = (p->>'msg_id')::int and h.message->>'type' = 'human') q
      cross join lateral (select jsonb_build_object('id', q.id, 'session', q.session_id, 'text', sl_clean_msg(q.message->>'content'))) z(r);
    if r is null then return jsonb_build_object('ok', false, 'error', 'الرسالة مش موجودة'); end if;
    if coalesce((p->>'rating')::int, 0) = 0 then
      delete from sl_question_review where msg_id = (r->>'id')::int;
      return jsonb_build_object('ok', true, 'rating', 0);
    end if;
    if (p->>'rating')::int not in (-1, 1) then return jsonb_build_object('ok', false, 'error', 'تقييم مش صحيح'); end if;
    insert into sl_question_review (msg_id, user_id, session_id, question, rating, reviewed_by)
    values ((r->>'id')::int, nullif(split_part(r->>'session', ':', 1), '')::uuid, r->>'session', r->>'text', (p->>'rating')::int, me)
    on conflict (msg_id) do update set rating = excluded.rating, reviewed_by = excluded.reviewed_by, at = now();
    return jsonb_build_object('ok', true, 'rating', (p->>'rating')::int);

  -- ---------- users' problems (issues.sql) ----------
  elsif p_action in ('admin_issues', 'admin_issue_retry', 'admin_issue_set') then
    return sl_issue_admin(p_action, p, j);

  -- ---------- edit the plan limits ----------
  elsif p_action = 'admin_update_plans' then
    update sl_plans pl set
      daily_messages  = coalesce(least(greatest((x->>'daily_messages')::int, 0), 100000), pl.daily_messages),
      daily_maps      = coalesce(least(greatest((x->>'daily_maps')::int, 0), 100000), pl.daily_maps),
      daily_timelines = coalesce(least(greatest((x->>'daily_timelines')::int, 0), 100000), pl.daily_timelines),
      daily_uploads   = coalesce(least(greatest((x->>'daily_uploads')::int, 0), 100000), pl.daily_uploads),
      max_docs        = coalesce(least(greatest((x->>'max_docs')::int, 0), 100000), pl.max_docs)
    from jsonb_array_elements(coalesce(p->'plans', '[]'::jsonb)) x
    where pl.plan = x->>'plan';
    return jsonb_build_object('ok', true, 'plans', (select jsonb_agg(to_jsonb(pl) order by pl.plan) from sl_plans pl));
  end if;
  return jsonb_build_object('ok', false, 'error', 'unknown action');
exception when invalid_text_representation or numeric_value_out_of_range then
  return jsonb_build_object('ok', false, 'error', 'قيمة مش صحيحة');
end $$;

revoke all on function sl_admin(text, jsonb, jsonb), sl_clean_limits(jsonb) from public, anon, authenticated;
select 'ok' as status;
