-- ============ Document drafting (صياغة مستندات) ============
-- Workflow "Smart Lawyer - Drafting" (POST /webhook/draft). Drafts are stored in sl_maps with data.type = 'draft',
-- so chat history, 👍/👎 and the issues/resend flow work for them like for mind maps.
-- Run after auth.sql, history_maps.sql, llm_router.sql, issues.sql.

update sl_plans set daily_drafts = 10 where plan = 'pro' and daily_drafts = 0
  and not exists (select 1 from sl_settings where key = 'drafts_defaults_v1');
insert into sl_settings values ('drafts_defaults_v1', 'applied') on conflict (key) do nothing;

-- allowed document types and their Arabic names
create or replace function sl_draft_types() returns jsonb
language sql immutable as $$
  select '{"lawsuit": "صحيفة دعوى", "notice": "إنذار على يد محضر", "memo": "مذكرة دفاع", "lease": "عقد إيجار",
           "sale": "عقد بيع", "complaint": "بلاغ / شكوى للنيابة العامة", "poa_request": "طلب أو التماس"}'::jsonb
$$;

-- auth + daily draft quota + context (chat + uploaded files) + model pick
create or replace function sl_draft_take(p_token text, p_session text, p_type text, p_facts text, p_use_chat boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  j jsonb := sl_user_json(p_token);
  d date := (now() at time zone 'Africa/Cairo')::date;
  is_retry boolean := exists (select 1 from sl_sessions where token = p_token and purpose = 'retry');
  uid uuid; used int; lim int; key text; chat text := ''; docs text := ''; last_id int;
  tname text := sl_draft_types()->>coalesce(p_type, '');
begin
  if j is null then return jsonb_build_object('ok', false, 'error', 'unauthorized', 'output', 'لازم تسجل دخول الأول.'); end if;
  if tname is null then return jsonb_build_object('ok', false, 'error', 'bad_type', 'output', 'نوع المستند مش معروف.'); end if;
  uid := (j->'user'->>'id')::uuid;
  lim := (sl_limits(uid)->>'daily_drafts')::int;
  select coalesce(n, 0) into used from sl_feature_usage where user_id = uid and day = d and feature = 'draft';
  used := coalesce(used, 0);
  if not is_retry and lim = 0 then
    return jsonb_build_object('ok', false, 'error', 'upgrade', 'output', 'صياغة المستندات متاحة في Pro ✦');
  end if;
  if not is_retry and used >= lim then
    return jsonb_build_object('ok', false, 'error', 'quota', 'output', 'وصلت للحد اليومي لصياغة المستندات (' || lim || '). ارجع بكرة.');
  end if;
  if length(coalesce(trim(p_facts), '')) < 15 and not coalesce(p_use_chat, false) then
    return jsonb_build_object('ok', false, 'error', 'empty', 'output', 'اكتب الوقائع وبيانات الأطراف (أو اختار "استخدم وقائع المحادثة") عشان أقدر أصيغ المستند.');
  end if;

  key := uid::text || ':' || left(regexp_replace(coalesce(p_session, ''), '[^A-Za-z0-9_-]', '', 'g'), 64);
  if coalesce(p_use_chat, false) then
    select coalesce(string_agg(case when t = 'human' then 'العميل/المستخدم: ' else 'المستشار: ' end || c, E'\n\n' order by id), ''), max(id)
      into chat, last_id
      from (select id, message->>'type' t, left(sl_clean_msg(message->>'content'), 2000) c
              from n8n_chat_histories
             where session_id = key and message->>'type' in ('human', 'ai')
               and jsonb_typeof(message->'content') = 'string' and coalesce(message->>'content', '') <> ''
             order by id desc limit 10) x;
    select coalesce(string_agg('ملف: ' || file_name || E'\n' || left(coalesce(summary, left(full_text, 2500)), 2500), E'\n\n'), '')
      into docs
      from (select * from sl_doc_profiles where user_id = uid::text order by created_at desc limit 2) f;
  end if;
  select coalesce(last_id, max(id), 0) into last_id from n8n_chat_histories where session_id = key;

  if not is_retry then
    insert into sl_feature_usage (user_id, day, feature, n) values (uid, d, 'draft', 1)
      on conflict (user_id, day, feature) do update set n = sl_feature_usage.n + 1;
  end if;
  return jsonb_build_object('ok', true, 'user_id', uid, 'session_key', key, 'after_msg_id', coalesce(last_id, 0),
    'type', p_type, 'type_name', tname, 'drafts_left', greatest(lim - used - 1, 0),
    'llm', sl_llm_pick('long', 7000),
    'search_query', left(tname || ' ' || regexp_replace(coalesce(p_facts, ''), '\s+', ' ', 'g'), 300),
    'facts', left(coalesce(p_facts, ''), 5000),
    'context', left(case when chat <> '' then 'المحادثة:' || E'\n' || chat || E'\n\n' else '' end ||
                    case when docs <> '' then 'ملخصات ملفات القضية المرفوعة:' || E'\n' || docs else '' end, 9000));
end $$;

-- save the draft (into sl_maps, type 'draft') or give the quota back when generation failed
create or replace function sl_draft_finish(p_ok boolean, p_user uuid, p_key text, p_after int, p_data jsonb, p_retry boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_ok then return sl_map_save(p_user, p_key, p_after, p_data); end if;
  if not coalesce(p_retry, false) then
    update sl_feature_usage set n = greatest(n - 1, 0)
     where user_id = p_user and day = (now() at time zone 'Africa/Cairo')::date and feature = 'draft';
  end if;
  return jsonb_build_object('saved', false, 'refunded', not coalesce(p_retry, false));
end $$;

revoke all on function sl_draft_take(text, text, text, text, boolean), sl_draft_finish(boolean, uuid, text, int, jsonb, boolean)
  from public, anon, authenticated;
select 'ok' as status;
