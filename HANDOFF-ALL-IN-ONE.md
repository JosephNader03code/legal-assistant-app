# مستشارك القانوني — Handoff for new sessions

Egyptian legal assistant: a multi-agent chatbot (free tier for the public, Pro tier for lawyers) built on **n8n Cloud + Supabase (Postgres + pgvector)** with a static web UI. Read this file first; it replaces re-reading old chats.

## Links

| What | Where |
|---|---|
| Web app (served by n8n) | https://joe03.app.n8n.cloud/webhook/lawyer-app |
| Web app (GitHub Pages, **owner must enable Pages**: Settings → Pages → branch `main` / root) | https://josephnader03code.github.io/legal-assistant-app/ |
| Repo (this) | https://github.com/JosephNader03code/legal-assistant-app |
| n8n instance | https://joe03.app.n8n.cloud |
| Main workflow "Agents to Apps - RAG Systems" | https://joe03.app.n8n.cloud/workflow/Urs8CLRcjtJbkZ8G |
| Website workflow "Smart Lawyer - Test Website" | https://joe03.app.n8n.cloud/workflow/sPTOi4r3hCBgsbvW |
| Supabase project | https://supabase.com/dashboard/project/rnjnozbptnqeskkyjqae |

## Repo layout

- `index.html`: the whole web app (vanilla JS, RTL Arabic, no build step). The same HTML is embedded in the n8n "Serve HTML" node, so update **both** when changing the UI.
- `docs/sql/auth.sql`: users, sessions, plans, quotas, `sl_api`, `sl_consume`, `sl_can_upload`.
- `docs/sql/routing_cache.sql`: model routing (`sl_route`, `sl_take`, `sl_lite`) and the semantic cache (`sl_cache_get` / `sl_cache_put`).
- `docs/sql/case_files.sql`: case-file extraction storage and the agent tools (`sl_case_facts`, `sl_read_doc`, `sl_keyword_search`).
- `docs/ws_fetch.py`: downloads law texts from Arabic Wikisource.
- `docs/clean_law.py`: normalizes Arabic law text and splits it into upload parts at article boundaries.

## How a session gets access

- **n8n.** Use the n8n MCP server: `POST https://joe03.app.n8n.cloud/mcp-server/http` (JSON-RPC, `Authorization: Bearer <token>`).
  - Get the token in n8n → Settings → Instance-level MCP.
  - Save it with `request_credential` (host `joe03.app.n8n.cloud`). **Never paste tokens in chat.** The old token was exposed in chat and should be rotated.
  - Useful MCP tools:
    - Workflows: `get_workflow_details`, `update_workflow` (operations: addNode / setNodeParameter / addConnection / renameNode…), `publish_workflow`.
    - Executions: `execute_workflow`, `get_workflow_execution`, `search_workflow_executions`.
    - Building: `create_workflow_from_code` (Workflow SDK), `list_credentials`.
  - **After every `update_workflow`, call `publish_workflow`.** Production webhooks run the published version.
- **SQL on Supabase.** There's no direct DB access from the container. Run SQL through a temporary n8n workflow (Manual Trigger → Postgres node, credential `Postgres account`), execute it with `execute_workflow`, then `archive_workflow`.
- **Cloud environment.** Use `smart-lawyer`. Its allowed hosts are joe03.app.n8n.cloud, manshurat.org (connection resets), cc.gov.eg, ar.wikisource.org, www.wipo.int, wipolex-res.wipo.int and lawyeregypt.net.
- **n8n credentials** (by name/ID; the secrets stay in n8n):

| Name | Type | ID |
|---|---|---|
| Postgres account | postgres | `4BLPPc1P7mifOF9z` |
| Joseph Acc | supabaseApi | `9lJ4e97toAVD8DfM` |
| Google Gemini(PaLM) Api account | googlePalmApi | `i9njv9iHB5rBBqeX` |
| OpenRouter account | openRouterApi | `NS4OhkqZyM2bHsex` |
| Groq account | groqApi | `yMugb7f5MV9SNCC6` |
| OpenAI account | openAiApi | `3zH1WRmnEu8PvbrM` (unused) |

  Credentials can't be created through MCP. The owner adds them in n8n's UI.

## Architecture

```
Browser (index.html) ──POST /webhook/sl-api──▶ Website workflow ─▶ Postgres sl_api(action, body)   signup/login/me/logout/docs
                     ──POST /webhook/Chat────▶ Main workflow (chat)
                     ──POST /webhook/upload──▶ Main workflow (upload, multipart: data, filename, contentType, token, target=mine|public)
```

### Chat flow (main workflow)

`Chat Webhook` → `Edit Fields` (chatInput, sessionId, token) → `Auth & Quota` (`sl_consume(token)`: auth + daily limit + count) → `Allowed?`
- **Denied:** `Respond Denied` returns `{ok:false, error:'unauthorized'|'quota', output}`.
- **Allowed:**
  1. `Route Model` (`sl_route(plan, text)`)
  2. `Set User` sets chatInput, sessionId = `userId:sessionId`, userId, plan, remaining, gemini_model, gemini_lite, or_model, complexity.
  3. `Is Pro?` sends the request down one of two paths.

**Free path:**
1. `Embed Question`: Gemini `gemini-embedding-001`, 768 dimensions, called by HTTP.
2. `Cache Lookup`: `sl_cache_get`.
3. `Cache Hit?`
   - **Hit:** `Respond Cached`, then `Cache Memory Write`, which writes the turn into `n8n_chat_histories`.
   - **Miss:** `Free Agent` (tool `law_library`, memory `Free Chat Memory`) → `Free Finalize` → `Respond Free` → `Cache Save`.

**Pro path:**
1. `Triage Agent` returns JSON with intent, legal_area, key_facts, missing_info and search_queries.
2. `Parse Triage`.
3. `AI Agent`, the Expert:
   - Tools: `law_library`, `my_documents`, `case_facts`, `read_document`, `keyword_search`.
   - Memory: `Postgres Chat Memory`.
   - On error it routes to `Backup AI Agent`.
4. `Prepare Review` collects the draft plus the retrieved sources.
5. `Needs Review?`: the review runs only if the draft cites 📚 and there were searches.
6. `QA Reviewer Agent` returns `PASS` or a corrected answer.
7. `Finalize` → `Respond to Chat`.

Response JSON: `{ok, output, plan, remaining, intent?, legal_area?, review?: pass|fixed|skipped|failed, answeredBy?, cached?, model?, complexity?}`.

### Upload flow

1. `Webhook` (path `upload`) → `Extract Fields`. Mimetype and filename come from the binary when the body lacks them.
2. `Switch` (pdf / csv / txt, otherwise `Respond Unsupported`) → extract node → `Code in JavaScript` (Arabic normalization, 8k slices).
3. `Upload Auth` (`sl_can_upload(token, target)`) → `Upload Allowed?` → `Attach Owner` (userId = user id, or `public` for the library).
4. `Supabase Vector Store` (table `documents`):
   - Embeddings: Gemini default embedding model.
   - Splitter: chunk 1800, overlap 150.
   - Metadata: `userId`, `fileName`.
5. `Respond to Webhook1`.
6. **Advanced extractor** (private uploads only):
   1. `Is Private Upload?`
   2. `Save Full Text` (`sl_doc_save_text`) and reserve flash-lite quota with `sl_lite`.
   3. `Split Sections` (10k chars each).
   4. `Case Extractor`: LLM per section, exhaustive JSON with verbatim quotes.
   5. `Merge Facts`: deterministic code merge, so nothing gets dropped.
   6. `Case Summary` (LLM) → `Save Profile` into `sl_doc_profiles`.

### Models (current)

| Agent | Primary | Fallback |
|---|---|---|
| Free Agent | Groq `openai/gpt-oss-120b` | OpenRouter `nvidia/nemotron-3-ultra-550b-a55b:free` |
| Triage | Groq `openai/gpt-oss-20b` | OpenRouter |
| Expert (AI Agent) | Groq `openai/gpt-oss-120b` | OpenRouter |
| QA Reviewer | OpenRouter | Groq `gpt-oss-20b` |
| Case Extractor / Summary | Gemini flash-lite (`$('Save Full Text').first().json.lite`) | OpenRouter |
| Backup AI Agent | Alibaba DeepSeek via n8n gateway credits | — |

- The OpenRouter node's model is the expression `$('Set User').first().json.or_model`.
- Groq free limits are **8k tokens per minute per model**. Pro RAG turns often exceed that and fall back to OpenRouter.
- OpenRouter free allows about 50 requests a day without credits.
- Gemini's free tier silently throttles: calls hang 10–500 s with no error. The n8n Gemini node has no timeout or retry setting, which is why Groq is primary.
- `sl_route` and `sl_models` still do quota accounting and the Gemini circuit breaker (`models/quota-exhausted` makes Gemini return 404 instantly, so the fallback kicks in). Groq isn't in `sl_models` yet.

### Database (Supabase, schema public)

- **`documents`** (id, content, metadata jsonb, embedding vector): the RAG store.
  - Library rows have `metadata.userId = 'public'`.
  - Private rows have userId = sl_users.id.
  - Function `match_documents`; trigram index on content.
- **`n8n_chat_histories`**: LangChain memory, session_id = `userId:sessionId`.
- **`sl_plans`**: free has 20 messages a day and 0 docs; pro has 300 a day and 30 docs. Admins are unlimited.
- **`sl_users`**: plan free|pro, role user|admin, bcrypt via pgcrypto.
- **`sl_sessions`**: 30-day tokens.
- **`sl_usage`**: per-day message counter in Africa/Cairo time.
- **`sl_models`, `sl_model_calls`**: routing.
- **`sl_cache`**: vector(768) HNSW. `sl_settings` holds cache_threshold 0.92 and cache_ttl_days 7.
- **`sl_doc_profiles`**: user_id, file_name, full_text, profile jsonb, summary, status.
- RLS is enabled on all `sl_*` tables with no policies. Only the n8n Postgres role (which bypasses RLS) uses them. The functions are `security definer`, with execute revoked from anon and authenticated.
- Promote a user: `update sl_users set plan='pro'` (or `role='admin'`) `where email='…';`

### Accounts

- **Joseph Nader:** admin + pro.
- **`library-bot@legal-assistant.local`:** admin, used to upload the library. Its password only existed in the old session, so reset it with SQL if you need it.
- There are 5 other real user accounts.

## Law library (921 chunks, `userId=public`)

| fileName | Source | Notes |
|---|---|---|
| القانون المدني رقم 131 لسنة 1948 (WIPO - معدل حتى 1970) | wipolex-res.wipo.int eg026ar.pdf | PDF needed `clean_law.py --fix-kaf` (ك rendered as آ, article numbers bidi-reversed). 1093 articles. |
| قانون العقوبات رقم 58 لسنة 1937 | ar.wikisource "نصوص قانون العقوبات (eg)" | amendments only to 1981 |
| قانون العمل رقم 14 لسنة 2025 | ar.wikisource | |
| قانون المرافعات المدنية والتجارية رقم 13 لسنة 1968 | ar.wikisource | |
| قانون رقم 1 لسنة 2000 - إجراءات التقاضي في الأحوال الشخصية | ar.wikisource | |
| قانون إيجار الأماكن رقم 49 لسنة 1977 | ar.wikisource | |
| قانون التأمينات الاجتماعية والمعاشات رقم 148 لسنة 2019 | ar.wikisource | |
| قانون البناء الموحد رقم 119 لسنة 2008 | ar.wikisource | |

**Missing (TODO):** these are the most important ones to add.
- Old-rent law 164/2025: lawyeregypt.net/?p=31926 links to its PDF page.
- Rent law 4/1996.
- Personal status laws 25/1920 and 25/1929 (manshurat.org/node/12369).
- The new Criminal Procedure Law.
- Constitution 2014.
- An up-to-date penal code (manshurat.org/node/14677, amended to 2021).

manshurat.org resets connections from the container.

**Adding a law:**
1. Fetch it (`ws_fetch.py` for Wikisource, `pdftotext -layout` for a PDF).
2. Run `clean_law.py IN OUT`.
3. POST each part to `/webhook/upload` with an admin token, `target=public` and a descriptive `filename`. Space the parts about 25 s apart for the embedding quota.

## UI notes (index.html)

- Screens:
  - Auth screen (login / sign-up).
  - Chat with suggestion chips (different for free and pro).
  - Usage meter and plan badge.
  - Documents drawer: upload for pro, a "public library" checkbox for admins, and the list of own and library files.
  - Pro upsell modal.
- Self-contained markdown renderer. No CDN, because cdnjs was blocked in testing.
- The token lives in `localStorage`. On the n8n-served page (a sandboxed iframe, origin `null`) it falls back to the URL hash `#s=…`, so prefer GitHub Pages.
- The API base is `https://joe03.app.n8n.cloud/webhook` unless the page is served from n8n.

## Measured performance (Nov 2026)

| Case | Time |
|---|---|
| Free | about 1.4 s (Groq), cache hit about 0.8 s |
| Pro | 16–39 s (Groq hits its token-per-minute limit, then OpenRouter takes over) |
| Case extraction (1 section) | about 30 s, in the background after the upload response |

## Open items / next steps

1. Owner: enable GitHub Pages, and rotate the n8n MCP token.
2. Speed up Pro:
   - Groq Dev Tier (higher TPM), or $10 of OpenRouter credit (about 1000 requests a day).
   - Or move Pro to a paid Gemini key.
3. Add Groq to `sl_models` so routing also accounts for Groq usage.
4. Add the missing laws (see above). When the library changes, call `select sl_cache_clear();`.
5. UI:
   - Show extraction status and summary for each file (`sl_doc_profiles`); this needs a new `sl_api` action `profile`.
   - Delete-file action.
6. Payments / self-serve Pro upgrade (currently manual SQL).
7. OR follow-ups once there's real usage data:
   - Tune plan limits (LP on `sl_usage`).
   - Queueing / priority under load.
   - Calibrate `cache_threshold`.
   - Grid-search RAG params (chunk size, topK) on a labelled question set.


---

# Appendix: full source files

Recreate any file below by copying its block. SQL: run in order `auth.sql`, then `routing_cache.sql`, then `case_files.sql` (Supabase SQL editor, or a temporary n8n Postgres node).

## `docs/sql/auth.sql`

```sql
create extension if not exists pgcrypto with schema extensions;

create table if not exists sl_plans (plan text primary key, daily_messages int not null, max_docs int not null);
insert into sl_plans values ('free', 20, 0), ('pro', 300, 30)
  on conflict (plan) do update set daily_messages = excluded.daily_messages, max_docs = excluded.max_docs;

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
alter table sl_plans enable row level security;
alter table sl_users enable row level security;
alter table sl_sessions enable row level security;
alter table sl_usage enable row level security;

-- user profile + today's usage, or null
create or replace function sl_user_json(p_token text) returns jsonb
language sql security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'ok', true,
    'user', jsonb_build_object('id', u.id, 'email', u.email, 'name', u.full_name, 'plan', u.plan, 'role', u.role),
    'usage', jsonb_build_object(
      'used', coalesce((select messages from sl_usage where user_id = u.id and day = (now() at time zone 'Africa/Cairo')::date), 0),
      'limit', case when u.role = 'admin' then 100000 else p.daily_messages end,
      'max_docs', case when u.role = 'admin' then 100000 else p.max_docs end,
      'docs', (select count(distinct metadata->>'fileName') from documents where metadata->>'userId' = u.id::text)))
  from sl_sessions s join sl_users u on u.id = s.user_id join sl_plans p on p.plan = u.plan
  where s.token = p_token and s.expires_at > now()
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
    t := sl_new_session(u.id);
    return sl_user_json(t) || jsonb_build_object('token', t);
  elsif p_action = 'me' then
    j := sl_user_json(v_token);
    return coalesce(j, jsonb_build_object('ok', false, 'error', 'unauthorized'));
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
begin
  j := sl_user_json(p_token);
  if j is null then return jsonb_build_object('ok', false, 'error', 'unauthorized', 'message', 'لازم تسجل دخول الأول.'); end if;
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
  if (j->'usage'->>'max_docs')::int = 0 then return jsonb_build_object('ok', false, 'error', 'رفع المستندات الخاصة متاح في Pro بس.'); end if;
  if (j->'usage'->>'docs')::int >= (j->'usage'->>'max_docs')::int then return jsonb_build_object('ok', false, 'error', 'وصلت للحد الأقصى لعدد المستندات.'); end if;
  return jsonb_build_object('ok', true, 'owner_id', j->'user'->>'id');
end $$;

revoke all on function sl_api(text, jsonb), sl_consume(text), sl_can_upload(text, text), sl_user_json(text), sl_new_session(uuid) from public, anon, authenticated;

-- remove the fake test law used in the earlier end-to-end test
delete from documents where metadata->>'userId' = 'usr-claude-e2e';
select 'ok' as status;

```

## `docs/sql/routing_cache.sql`

```sql
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

```

## `docs/sql/case_files.sql`

```sql
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

```

## `docs/ws_fetch.py`

```python
# Fetch Arabic Wikisource pages (and their subpages) as plain text. Usage: ws_fetch.py OUTDIR "Title|slug" ...
import sys, json, re, html, urllib.request, urllib.error, urllib.parse, os, time
API = "https://ar.wikisource.org/w/api.php"
def get(params):
    q = API + "?" + urllib.parse.urlencode({**params, "format": "json"})
    req = urllib.request.Request(q, headers={"User-Agent": "legal-library-builder/1.0"})
    for i in range(6):
        try: return json.load(urllib.request.urlopen(req, timeout=60))
        except urllib.error.HTTPError as e:
            if e.code != 429: raise
            time.sleep(10 * (i + 1))
    raise RuntimeError("rate limited")
def page_text(title):
    d = get({"action": "parse", "page": title, "prop": "text", "redirects": 1})
    h = d["parse"]["text"]["*"]
    h = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", h, flags=re.S)
    h = re.sub(r'<div class="(printfooter|mw-references-wrap|ws-noexport|headertemplate)[^"]*".*?</div>', " ", h, flags=re.S)
    h = re.sub(r"<br\s*/?>|</p>|</li>|</h\d>|</tr>|</div>", "\n", h)
    t = html.unescape(re.sub(r"<[^>]+>", "", h))
    t = re.sub(r"\[\s*عدل\s*\]", "", t)
    return re.sub(r"\n\s*\n+", "\n\n", t).strip()
def subpages(title):
    out, cont = [], {}
    while True:
        d = get({"action": "query", "list": "allpages", "apprefix": title + "/", "apnamespace": 0, "aplimit": 500, **cont})
        out += [p["title"] for p in d["query"]["allpages"]]
        if "continue" not in d: return out
        cont = d["continue"]
outdir = sys.argv[1]
for arg in sys.argv[2:]:
    title, slug = arg.split("|")
    parts = [page_text(title)]
    subs = subpages(title)
    def key(t):
        m = re.search(r"(\d+)\s*$", t); return (0, int(m.group(1))) if m else (1, t)
    for s in sorted(subs, key=key):
        try: parts.append("\n\n" + s.split("/", 1)[1] + "\n" + page_text(s)); time.sleep(1.5)
        except Exception as e: print("skip", s, e)
    text = "\n".join(parts)
    open(os.path.join(outdir, slug + ".txt"), "w").write(text)
    print(f"{slug}: {len(text)} chars, {len(subs)} subpages, articles~{len(re.findall(r'(?:^|\n)\s*(?:ال)?مادة', text))}")

```

## `docs/clean_law.py`

```python
# Normalize Arabic law text and split into upload parts at article boundaries.
# Usage: clean_law.py IN.txt OUTPREFIX [--fix-kaf] [--part-chars N]
import sys, re, unicodedata
src, out = sys.argv[1], sys.argv[2]
fix_kaf = "--fix-kaf" in sys.argv
part_chars = int(sys.argv[sys.argv.index("--part-chars") + 1]) if "--part-chars" in sys.argv else 24000
t = open(src, encoding="utf-8").read()
t = unicodedata.normalize("NFKC", t)
t = re.sub(r"[​-‏‪-‮⁦-⁩﻿]", "", t)
t = t.replace("ـ", "")
t = re.sub(r"[ً-ْٰ]", "", t)
t = re.sub(r"[٠-٩]", lambda m: str(ord(m.group()) - 0x660), t)
if fix_kaf:
    # this PDF renders ك as آ; keep the few real آ words
    keep = r"(?:آخر|الآخر|آخرين|آخرون|الآخرين|آخره|الآن|آثار|الآثار|آجل|آلات|الآلات|آلة|الآلة|القرآن|آبار)"
    t = re.sub(keep, lambda m: m.group().replace("آ", "\x00"), t)
    t = t.replace("آ", "ك").replace("\x00", "آ")
if fix_kaf:
    # bidi-reordered numbering: "مادة (1) – 87" -> "مادة 87 - (1)", "مادة – 86" -> "مادة 86 -"
    t = re.sub(r"مادة\s*\(\s*(\d+)\s*\)\s*[–\-]\s*(\d+)", r"مادة \2 - (\1)", t)
    t = re.sub(r"مادة\s*[–\-]\s*(\d+)", r"مادة \1 -", t)
lines = [re.sub(r"[ \t]+", " ", l).strip() for l in t.split("\n")]
t = "\n".join(lines)
t = re.sub(r"\n{3,}", "\n\n", t)
# blank line before each article so the splitter keeps articles whole
t = re.sub(r"\n\s*((?:ال)?مادة\s*[\(\[]?\s*\d+)", r"\n\n\1", t)
t = re.sub(r"\n{3,}", "\n\n", t).strip()
blocks = re.split(r"\n\n", t)
parts, cur = [], ""
for b in blocks:
    if len(cur) + len(b) > part_chars and cur:
        parts.append(cur); cur = ""
    cur += b + "\n\n"
if cur.strip(): parts.append(cur)
for i, p in enumerate(parts, 1):
    open(f"{out}.part{i:02d}.txt", "w", encoding="utf-8").write(p)
arts = re.findall(r"(?:^|\n)(?:ال)?مادة\s*[\(\[]?\s*(\d+)", t)
print(f"{out}: {len(t)} chars, {len(parts)} parts, articles {len(arts)} (max {max(map(int, arts)) if arts else 0})")

```
