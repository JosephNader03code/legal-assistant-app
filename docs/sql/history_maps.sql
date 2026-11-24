-- ============ Chat history + case mind maps / timelines ============
-- Run after auth.sql, routing_cache.sql and case_files.sql.

-- prefix search "userId:%" on the LangChain memory table
create index if not exists n8n_chat_histories_session_pattern
  on n8n_chat_histories (session_id varchar_pattern_ops, id);

-- daily mind-map quota per plan (free = 2/day). Change with: update sl_plans set daily_maps = N where plan = 'free';
alter table sl_plans add column if not exists daily_maps int not null default 1;  -- values are edited from the admin dashboard

create table if not exists sl_feature_usage (
  user_id uuid not null references sl_users(id) on delete cascade,
  day date not null,
  feature text not null,
  n int not null default 0,
  primary key (user_id, day, feature)
);
alter table sl_feature_usage enable row level security;

-- generated maps, shown again when an old chat is reopened
create table if not exists sl_maps (
  id bigserial primary key,
  user_id uuid not null references sl_users(id) on delete cascade,
  session_id text not null,          -- full key "userId:sessionId"
  after_msg_id int not null default 0, -- last chat-history id when the map was made (for ordering)
  data jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists sl_maps_session on sl_maps (session_id, id);
alter table sl_maps enable row level security;

-- clean chat text: drop the Pro triage notes appended to the human message
create or replace function sl_clean_msg(p_text text) returns text
language sql immutable set search_path = public as $$
  select trim(split_part(coalesce(p_text, ''), E'\n\n---\n[ملاحظات داخلية', 1))
$$;

-- history actions, called from sl_api
create or replace function sl_api_ext(p_action text, p jsonb, j jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid text := j->'user'->>'id';
  sid text := left(regexp_replace(coalesce(p->>'session', ''), '[^A-Za-z0-9_-]', '', 'g'), 64);
  key text := uid || ':' || sid;
begin
  if p_action = 'sessions' then
    -- chats from the LangChain memory, plus chats that only hold a mind map
    return jsonb_build_object('ok', true, 'sessions', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.sid, 'title', x.title, 'count', x.n, 'maps', x.maps))
      from (
        select coalesce(c.sid, m.sid) as sid, coalesce(c.title, m.title) as title,
               coalesce(c.n, 0) as n, coalesce(m.maps, 0) as maps
        from (select split_part(h.session_id, ':', 2) as sid,
                     count(*) filter (where h.message->>'type' = 'human') as n,
                     left((array_agg(sl_clean_msg(h.message->>'content') order by h.id)
                            filter (where h.message->>'type' = 'human'))[1], 90) as title
                from n8n_chat_histories h
               where h.session_id like uid || ':%'
               group by h.session_id
               order by max(h.id) desc
               limit 150) c
        full join (select split_part(session_id, ':', 2) as sid, count(*) as maps,
                          '🗺️ ' || left((array_agg(data->>'title' order by id))[1], 80) as title
                     from sl_maps where user_id = uid::uuid group by session_id) m on m.sid = c.sid
      ) x
      where x.n > 0 or x.maps > 0), '[]'::jsonb));
  elsif p_action = 'history' then
    if sid = '' then return jsonb_build_object('ok', false, 'error', 'missing session'); end if;
    return jsonb_build_object('ok', true, 'session', sid,
      'messages', coalesce((
        select jsonb_agg(m order by m->>'k') from (
          select jsonb_build_object('k', lpad(h.id::text, 12, '0') || 'a',
                                    'role', case when h.message->>'type' = 'human' then 'user' else 'bot' end,
                                    'text', sl_clean_msg(h.message->>'content'),
                                    'rating', (select f.rating from sl_feedback f where f.user_id = uid::uuid and f.session_id = key
                                                and f.answer_hash = md5(left(sl_clean_msg(h.message->>'content'), 20000)))) m
            from n8n_chat_histories h
           where h.session_id = key
             and h.message->>'type' in ('human', 'ai')
             and jsonb_typeof(h.message->'content') = 'string'
             and coalesce(h.message->>'content', '') <> ''
          union all
          select jsonb_build_object('k', lpad(mp.after_msg_id::text, 12, '0') || 'b' || lpad(mp.id::text, 12, '0'),
                                    'role', 'map', 'map', mp.data,
                                    'rating', (select f.rating from sl_feedback f where f.user_id = uid::uuid and f.session_id = key
                                                and f.answer_hash = md5(left('map:' || mp.id, 20000))), 'map_id', mp.id)
            from sl_maps mp where mp.session_id = key) q), '[]'::jsonb));
  elsif p_action = 'feedback' then
    return sl_feedback_set(j, p);                              -- feedback.sql
  elsif p_action = 'delete_session' then
    if sid = '' then return jsonb_build_object('ok', false, 'error', 'missing session'); end if;
    delete from n8n_chat_histories where session_id = key;
    delete from sl_maps where session_id = key;
    return jsonb_build_object('ok', true);
  end if;
  return jsonb_build_object('ok', false, 'error', 'unknown action');
end $$;

-- today's usage of each visual feature, for the "me" action: {limit, map, timeline}
-- (the mind map and the timeline are separate features, each with its own daily_maps quota)
drop function if exists sl_map_take(text, text, text);
drop function if exists sl_map_refund(uuid);
drop function if exists sl_map_finish(boolean, uuid, text, int, jsonb);
create or replace function sl_maps_usage(j jsonb) returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'limit', (sl_limits((j->'user'->>'id')::uuid)->>'daily_maps')::int,
    'limit_timeline', (sl_limits((j->'user'->>'id')::uuid)->>'daily_timelines')::int,
    'map', coalesce((select n from sl_feature_usage where user_id = (j->'user'->>'id')::uuid
                      and day = (now() at time zone 'Africa/Cairo')::date and feature = 'map'), 0),
    'timeline', coalesce((select n from sl_feature_usage where user_id = (j->'user'->>'id')::uuid
                      and day = (now() at time zone 'Africa/Cairo')::date and feature = 'timeline'), 0))
$$;

-- visual webhook: auth + daily quota of the requested feature + gather the case context
-- p_type: 'mindmap' (feature 'map') | 'timeline' (feature 'timeline')
create or replace function sl_map_take(p_token text, p_session text, p_text text, p_type text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  j jsonb := sl_user_json(p_token);
  d date := (now() at time zone 'Africa/Cairo')::date;
  feat text := case when p_type = 'timeline' then 'timeline' else 'map' end;
  what text := case when p_type = 'timeline' then 'الخط الزمني' else 'الخريطة الذهنية' end;
  uid uuid; used int; lim int; is_pro boolean;
  key text; chat text; docs text := ''; last_id int;
begin
  if j is null then return jsonb_build_object('ok', false, 'error', 'unauthorized', 'output', 'لازم تسجل دخول الأول.'); end if;
  uid := (j->'user'->>'id')::uuid;
  is_pro := j->'user'->>'plan' = 'pro' or j->'user'->>'role' = 'admin';
  lim := (sl_limits(uid)->>(case when feat = 'timeline' then 'daily_timelines' else 'daily_maps' end))::int;
  select coalesce(n, 0) into used from sl_feature_usage where user_id = uid and day = d and feature = feat;
  used := coalesce(used, 0);
  if used >= lim and not exists (select 1 from sl_sessions where token = p_token and purpose = 'retry') then
    return jsonb_build_object('ok', false, 'error', 'quota', 'type', feat, 'output',
      case when is_pro then 'وصلت للحد اليومي لـ' || what || ' (' || lim || ' مرات). ارجع بكرة.'
           else 'خلص استخدامك المجاني لـ' || what || ' النهارده (' || case lim when 1 then 'مرة واحدة' when 2 then 'مرتين' else lim || ' مرات' end || '). ارجع بكرة أو اشترك في Pro.' end);
  end if;

  key := uid::text || ':' || left(regexp_replace(coalesce(p_session, ''), '[^A-Za-z0-9_-]', '', 'g'), 64);
  select string_agg(case when t = 'human' then 'المستخدم: ' else 'المستشار: ' end || c, E'\n\n' order by id), max(id)
    into chat, last_id
    from (select id, message->>'type' t, left(sl_clean_msg(message->>'content'), 2500) c
            from n8n_chat_histories
           where session_id = key and message->>'type' in ('human', 'ai')
             and jsonb_typeof(message->'content') = 'string' and coalesce(message->>'content', '') <> ''
           order by id desc limit 12) x;
  -- summaries of the user's uploaded case files (any plan that can upload)
  begin
    select coalesce(string_agg('ملف: ' || file_name || E'\n' || left(coalesce(summary, left(full_text, 3000)), 3000), E'\n\n'), '')
      into docs
      from (select * from sl_doc_profiles where user_id = uid::text order by created_at desc limit 2) f;
  end;
  if coalesce(trim(p_text), '') = '' and coalesce(chat, '') = '' and docs = '' then
    return jsonb_build_object('ok', false, 'error', 'empty', 'type', feat, 'output', 'اكتب وقائع القضية الأول (أو اسأل عنها في المحادثة) وبعدين اطلب ' || what || '.');
  end if;

  if not exists (select 1 from sl_sessions where token = p_token and purpose = 'retry') then   -- admin resend is free (issues.sql)
    insert into sl_feature_usage (user_id, day, feature, n) values (uid, d, feat, 1)
      on conflict (user_id, day, feature) do update set n = sl_feature_usage.n + 1;
  end if;
  return jsonb_build_object('ok', true, 'user_id', uid, 'session_key', key, 'after_msg_id', coalesce(last_id, 0),
    'type', case when feat = 'timeline' then 'timeline' else 'mindmap' end,
    'llm', sl_llm_pick('main', 4000),                          -- llm_router.sql
    'plan', case when is_pro then 'pro' else 'free' end, 'maps_left', lim - used - 1,
    'context', left(
      case when coalesce(trim(p_text), '') <> '' then 'طلب/وقائع من المستخدم الآن:' || E'\n' || left(p_text, 4000) || E'\n\n' else '' end ||
      case when coalesce(chat, '') <> '' then 'المحادثة:' || E'\n' || chat || E'\n\n' else '' end ||
      case when docs <> '' then 'ملخصات ملفات القضية المرفوعة:' || E'\n' || docs else '' end, 12000));
end $$;

create or replace function sl_map_save(p_user uuid, p_key text, p_after int, p_data jsonb) returns jsonb
language sql security definer set search_path = public as $$
  insert into sl_maps (user_id, session_id, after_msg_id, data) values (p_user, p_key, coalesce(p_after, 0), p_data)
  returning jsonb_build_object('saved', true, 'id', id)
$$;

-- a failed generation should not burn the user's quota
create or replace function sl_map_refund(p_user uuid, p_type text) returns void
language sql security definer set search_path = public as $$
  update sl_feature_usage set n = greatest(n - 1, 0)
   where user_id = p_user and day = (now() at time zone 'Africa/Cairo')::date
     and feature = case when p_type = 'timeline' then 'timeline' else 'map' end
$$;

-- called once per generation: save the result, or give the quota back when generation failed
create or replace function sl_map_finish(p_ok boolean, p_user uuid, p_key text, p_after int, p_data jsonb, p_type text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_ok then return sl_map_save(p_user, p_key, p_after, p_data); end if;
  perform sl_map_refund(p_user, p_type);
  return jsonb_build_object('saved', false, 'refunded', true);
end $$;

-- a clarifying-questions turn does not count against the daily message quota
create or replace function sl_unconsume(p_user uuid) returns void
language sql security definer set search_path = public as $$
  update sl_usage set messages = greatest(messages - 1, 0)
   where user_id = p_user and day = (now() at time zone 'Africa/Cairo')::date
$$;

-- true when this chat already has turns (the clarifying step only runs on a chat's first message)
create or replace function sl_has_history(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from n8n_chat_histories where session_id = p_key)
$$;

revoke all on function sl_clean_msg(text), sl_maps_usage(jsonb), sl_api_ext(text, jsonb, jsonb), sl_map_take(text, text, text, text),
  sl_map_save(uuid, text, int, jsonb), sl_map_refund(uuid, text), sl_unconsume(uuid), sl_has_history(text),
  sl_map_finish(boolean, uuid, text, int, jsonb, text) from public, anon, authenticated;
select 'ok' as status;
