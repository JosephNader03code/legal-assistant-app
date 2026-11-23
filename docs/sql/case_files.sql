-- ============ Advanced extraction + retrieval for uploaded case files ============
create extension if not exists pg_trgm with schema extensions;

-- One row per uploaded file: full text (for complete reading) + structured facts.
create table if not exists sl_doc_profiles (
  id bigserial primary key,
  user_id text not null,
  file_name text not null,
  full_text text not null,
  profile jsonb,
  summary text,
  status text not null default 'extracting',   -- extracting | ready | failed
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, file_name)
);
alter table sl_doc_profiles enable row level security;

-- keyword (exact names, numbers, dates) search complements vector search
create index if not exists documents_content_trgm on documents using gin (content extensions.gin_trgm_ops);

create or replace function sl_doc_save_text(p_user text, p_file text, p_text text) returns jsonb
language sql security definer set search_path = public as $$
  insert into sl_doc_profiles (user_id, file_name, full_text, status)
  values (p_user, p_file, p_text, 'extracting')
  on conflict (user_id, file_name) do update
    set full_text = excluded.full_text, status = 'extracting', profile = null, summary = null, updated_at = now()
  returning jsonb_build_object('id', id)
$$;

create or replace function sl_doc_save_profile(p_user text, p_file text, p_profile jsonb, p_summary text) returns jsonb
language sql security definer set search_path = public as $$
  update sl_doc_profiles set profile = p_profile, summary = p_summary,
         status = case when p_profile is null then 'failed' else 'ready' end, updated_at = now()
   where user_id = p_user and file_name = p_file
  returning jsonb_build_object('saved', true, 'status', status)
$$;

-- Tool 1: everything extracted from the user's files (or one file)
create or replace function sl_case_facts(p_user text, p_file text) returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'file', file_name, 'status', status, 'summary', summary, 'facts', profile,
           'length_chars', length(full_text), 'parts', ceil(length(full_text) / 12000.0))
         order by created_at desc), '[]'::jsonb)
    from sl_doc_profiles
   where user_id = p_user
     and (coalesce(p_file, '') = '' or file_name ilike '%' || p_file || '%')
$$;

-- Tool 2: read a file completely, part by part (12,000 chars each)
create or replace function sl_read_doc(p_user text, p_file text, p_part int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d sl_doc_profiles; n int; k int := greatest(coalesce(p_part, 1), 1);
begin
  select * into d from sl_doc_profiles
   where user_id = p_user and (coalesce(p_file, '') = '' or file_name ilike '%' || p_file || '%')
   order by created_at desc limit 1;
  if d.id is null then return jsonb_build_object('error', 'file not found'); end if;
  n := ceil(length(d.full_text) / 12000.0);
  return jsonb_build_object('file', d.file_name, 'part', k, 'total_parts', n,
                            'text', substr(d.full_text, (k - 1) * 12000 + 1, 12000));
end $$;

-- Tool 3: exact keyword search (names, case numbers, amounts) in the user's files and the law library
create or replace function sl_keyword_search(p_user text, p_query text) returns jsonb
language sql security definer set search_path = public, extensions as $$
  with terms as (
    select t from regexp_split_to_table(trim(coalesce(p_query, '')), '\s+') t where length(t) >= 2
  ), hits as (
    select d.content, d.metadata->>'fileName' as file, d.metadata->>'userId' as owner,
           (select count(*) from terms where d.content ilike '%' || terms.t || '%') as matched
      from documents d
     where d.metadata->>'userId' in (p_user, 'public')
       and exists (select 1 from terms where d.content ilike '%' || terms.t || '%')
  )
  select coalesce(jsonb_agg(jsonb_build_object('file', file, 'source', case when owner = 'public' then 'law_library' else 'my_documents' end, 'text', content) order by matched desc), '[]'::jsonb)
    from (select * from hits order by matched desc limit 8) h
$$;

revoke all on function sl_doc_save_text(text, text, text), sl_doc_save_profile(text, text, jsonb, text),
  sl_case_facts(text, text), sl_read_doc(text, text, int), sl_keyword_search(text, text) from public, anon, authenticated;
select 'ok' as status;
