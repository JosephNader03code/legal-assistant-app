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
| Search tool workflow "Smart Lawyer - Search Tool" | https://joe03.app.n8n.cloud/workflow/ySmFhCajtWfNI3XG |
| Website workflow "Smart Lawyer - Test Website" | https://joe03.app.n8n.cloud/workflow/sPTOi4r3hCBgsbvW |
| Supabase project | https://supabase.com/dashboard/project/rnjnozbptnqeskkyjqae |

## Repo layout

- `index.html`: the whole web app (vanilla JS, RTL Arabic, no build step). The same HTML is embedded in the n8n "Serve HTML" node, so update **both** when changing the UI.
- `docs/sql/auth.sql`: users, sessions, plans, quotas, `sl_api`, `sl_consume`, `sl_can_upload`.
- `docs/sql/routing_cache.sql`: model routing (`sl_route`, `sl_take`, `sl_lite`) and the semantic cache (`sl_cache_get` / `sl_cache_put`).
- `docs/sql/case_files.sql`: case-file extraction storage and the agent tools (`sl_case_facts`, `sl_read_doc`, `sl_keyword_search`).
- `docs/sql/feedback.sql`: 👍/👎 votes in `sl_feedback` (question, answer, rating, plan), one vote per answer (md5). Doubles as the future fine-tuning dataset: `select question, answer from sl_feedback where rating = 1 and kind = 'chat'`.
- `docs/sql/llm_router.sql`: model chain (`sl_llm`, `sl_llm_calls`, `sl_llm_pick`, `sl_llm_wait`, `sl_llm_fail`, `sl_llm_status`).
- `docs/sql/admin.sql`: admin dashboard API (`sl_admin`: admin_overview / admin_users / admin_user_log / admin_create_user / admin_update_user / admin_update_plans), `sl_clean_limits`.
- `docs/sql/search_log.sql`: search that survives Gemini outages (`sl_search` hybrid vector + Arabic full-text, circuit breaker `sl_embed_ok` / `sl_embed_trip`) and the request log (`sl_request_log`, `sl_log`, view `sl_daily_usage`, `sl_log_set_tokens`).
- `docs/backfill_tokens.py`: fills real token counts into `sl_request_log` from n8n execution data (run from a Claude session with the n8n MCP token).
- `docs/sql/history_maps.sql`: chat history API (`sl_api_ext`: sessions / history / delete_session) and case mind maps (`sl_map_take`, `sl_map_finish`, tables `sl_maps`, `sl_feature_usage`, column `sl_plans.daily_maps`).
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
Browser (index.html) ──POST /webhook/sl-api──▶ Website workflow ─▶ Postgres sl_api(action, body)   signup/login/me/logout/docs/sessions/history/delete_session/feedback/admin_*
                     ──POST /webhook/Chat────▶ Main workflow (chat)
                     ──POST /webhook/mindmap─▶ Main workflow (case mind map + timeline: token, sessionId, text)
                     ──POST /webhook/upload──▶ Main workflow (upload, multipart: data, filename, contentType, token, target=mine|public)
```

### Chat flow (main workflow)

`Chat Webhook` → `Edit Fields` (chatInput, sessionId, token) → `Auth & Quota` (`sl_consume(token)`: auth + daily limit + count) → `Allowed?`
- **Denied:** `Respond Denied` returns `{ok:false, error:'unauthorized'|'quota', output}`.
- **Allowed:**
  1. `Route Model` (`sl_route(plan, text)`)
  2. `Set User` sets chatInput, sessionId = `userId:sessionId`, userId, plan, remaining, gemini_model, gemini_lite, or_model, complexity.
  3. **Clarifying questions** (first message of a chat only): `Clarify Gate` (`sl_has_history`) → `First Turn?` (skipped when the chat has history or the body has `noClarify: true`) → `Clarifier` (Groq `gpt-oss-120b`, intake agent, JSON `{ask, intro, questions:[{q, options[]}]}`, Egyptian dialect) → `Parse Clarify` → `Ask First?`
     - **Ask:** `Save Clarify` writes the turn into `n8n_chat_histories` and gives the message back with `sl_unconsume` → `Respond Clarify` returns `{ok, clarify:true, intro, questions, output}`. The UI shows clickable options plus a free-text field, then sends `سؤالي: … إجاباتي على أسئلتك: …` as the next message. «جاوب على طول» sends `noClarify`.
     - **No questions:** continues to `Is Pro?` (`Restore User` passes the `Set User` data through).
  4. `Is Pro?` sends the request down one of two paths.

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

### Search (law_library / my_documents tools)

Both agent tools are **Call Workflow tools** → "Smart Lawyer - Search Tool" (inputs `query`, `userId`, `scope` = library | mine):
`Embeddings Up?` (`sl_embed_ok()`) → `Use Gemini?` → `Embed Query` (Gemini `gemini-embedding-001`, 3072 dims like the stored vectors, 7 s timeout, error output) → `Search` (`sl_search(query, vector, user, scope)`: top-5 vector + top-3 Arabic full-text, deduped).
- Gemini error → `Trip Breaker` (`sl_embed_trip`: 2 min for a per-minute limit, 30 min otherwise) → `Search` with no vector (keyword only: 3 results, 1400 chars each).
- While the breaker is open Gemini is not called at all. The free tier is **1000 embedding requests per day**.
- `sl_search` boosts an exact "مادة N" match. Keyword quality is good for formal wording (triage rewrites the question), weaker for dialect.
- Uploads still need Gemini embeddings (the Supabase Vector Store node); they fail while the quota is exhausted.

### Request log

Every chat / map request writes one row to `sl_request_log` (Postgres nodes `Log Denied`, `Log Clarify`, `Log Cached`, `Log Free`, `Log Pro`, `Log Map`, `Log Map Denied`, all after the response so they add no latency): nickname (full name or email prefix), plan, chat id, kind, today's message number and limit, `quota_hit`, chars, `tokens_est`, latency, model, review, `embed_ok`, n8n `exec_id`, error.
- `tokens_est` = characters / 3 with the prompts and the agent loop (pro × 0.73, calibrated on one real execution: 67k estimated vs 49k real).
- Real tokens: n8n stores `tokenUsage` per LLM call in the execution data, which the workflow cannot read. `python3 docs/backfill_tokens.py EXEC_ID…` prints `sl_log_set_tokens(...)` calls. To automate it, add an n8n API credential and a scheduled workflow.
- Daily report: `select * from sl_daily_usage where day = current_date order by last_at desc;` (answers, chats, maps, when the quota was hit and after how many messages, blocked attempts, tokens, avg seconds, answers made with keyword search).

### Mind map / timeline flow (main workflow, group "Case mind map + timeline")

The mind map and the timeline are **two separate features** (body `type: 'mindmap' | 'timeline'`), each with its own daily quota (`sl_feature_usage.feature` = `map` / `timeline`).

`Map Webhook` (path `mindmap`) → `Map Auth` (`sl_map_take(token, sessionId, text, type)`: auth, daily map quota, builds the context from the last 12 chat turns + the user's text + for Pro the 2 latest `sl_doc_profiles` summaries, max 12k chars) → `Map Allowed?` → `Map Prompt` (picks the system prompt for the type) → `Map Builder` (Groq `gpt-oss-120b`, fallback OpenRouter; strict JSON) → `Map Parse` (sanitizes / limits size; **drops any deadline duration that is not literally in the case material**, because the model invents them) → `Map Save` (`sl_map_finish`: saves to `sl_maps`, or refunds the quota when generation failed) → `Respond Map`.

Response: `{ok, type, map: {type, request, title, mindmap?: {label, children[]}, timeline?: [{date, event, kind: fact|procedure|deadline|next, note}], missing[]}, map_id, maps_left}`. Quota: `sl_plans.daily_maps` per feature (free 2 / pro 8 per day each, Cairo time; admins unlimited). The UI draws the mind map as SVG itself (no library, PNG/SVG download) and the timeline as a list (copy as text, print). Buttons 🧠 and 🕒 in the composer; messages containing "mind map / خريطة ذهنية" or "خط زمني / تايم لاين" are routed automatically. Maps saved before the split contain both and are shown with tabs.

### Chat history

Built on `n8n_chat_histories` (session_id `userId:sessionId`, where the client sessionId is `'s' + Date.now().toString(36)`, so the UI derives the date from it). `sl_clean_msg` strips the Pro triage notes from stored human messages. Note: for Pro, memory stores the Expert's draft, not the QA-corrected final answer. Saved maps are merged into `history` by `after_msg_id`.

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

### Models (current): a chain, picked per turn

`sl_route` returns `llm: {main: [primary, fallback], light: [primary, fallback]}` and `wait` (seconds). The Groq model nodes take their model from it:
- `LLM Main` / `LLM Main Fallback` → Free Agent and Expert (AI Agent). `LLM Light` / `LLM Light Fallback` → Triage, Clarifier (and QA fallback). `Groq Map Model` / `Map Model Fallback` → maps (picked in `sl_map_take`).
- Chains (`sl_llm`, edit with SQL): main = `gpt-oss-120b` → `qwen/qwen3.8-27b` → `gpt-oss-20b`; light = `gpt-oss-20b` → `qwen3.8-27b` → `allam-2-7b` (Arabic, 4k context, no tools).
- `sl_llm_pick` takes the first models with room this minute (TPM) and today (TPD for gpt-oss = 200k), reserving the turn's estimated tokens (free 6.5k, pro 8k, light 1.5k/5k, map 4k).
- When nothing has room, `Models Busy?` → `Wait For Capacity` (≤ 20 s, it holds an n8n concurrency slot) before answering.
- Log nodes report rate-limited models; `sl_llm_fail` pauses them 65 s, or 30 min near the daily limit; a pause is never shortened.
- `maxTokensToSample` is sized per role (free 1200, pro 2500, light 1000, map 2500) because **Groq counts max_tokens against the per-minute limit up front**; 4096 made every second call fail.
- Search results are smaller for free (`*_lite` scope: 3 × 900 chars) and pro (4 × 1300); AI Agent maxIterations 8. Free Agent does not retry (retries caused 40+ calls per question).
- QA Reviewer: OpenRouter, fallback `LLM Light`. Backup AI Agent: DeepSeek via n8n gateway credits. Case Extractor / Summary: Gemini flash-lite → OpenRouter.

**Measured limits (Groq free, Nov 2026):** gpt-oss-120b / 20b 8k TPM, 200k TPD, 1000 RPD; qwen3.8-27b 7k TPM; allam 6k TPM. One free answer ≈ 6.5k tokens (2–3 calls, each re-sending the earlier search results), so the free tier serves roughly **3 answers a minute and ~70–100 a day** across the chain. The admin dashboard shows the chain's health. More capacity: Groq Dev Tier, $10 OpenRouter credit, or another provider key (e.g. Cerebras free tier) added as a credential + chain entries.

### Database (Supabase, schema public)

- **`documents`** (id, content, metadata jsonb, embedding vector): the RAG store.
  - Library rows have `metadata.userId = 'public'`.
  - Private rows have userId = sl_users.id.
  - Function `match_documents`; trigram index on content.
- **`n8n_chat_histories`**: LangChain memory, session_id = `userId:sessionId`.
- **`sl_plans`** (edited from the admin dashboard): daily_messages, daily_maps, daily_timelines, daily_uploads, max_docs. Defaults: free 6 / 1 / 1 / 1 / 10, pro 300 / 8 / 8 / 20 / 30. Admins are unlimited.
- **`sl_users.limits`** (jsonb): per-user overrides of any of those keys; `sl_limits(user_id)` returns the effective limits and everything (chat, maps, uploads, log) uses it. **`sl_users.disabled`** blocks login and kills sessions.
- **`sl_users`**: plan free|pro, role user|admin, bcrypt via pgcrypto.
- **`sl_sessions`**: 30-day tokens.
- **`sl_usage`**: per-day message counter in Africa/Cairo time.
- **`sl_models`, `sl_model_calls`**: routing.
- **`sl_cache`**: vector(768) HNSW. `sl_settings` holds cache_threshold 0.92 and cache_ttl_days 7.
- **`sl_doc_profiles`**: user_id, file_name, full_text, profile jsonb, summary, status.
- RLS is enabled on all `sl_*` tables with no policies. Only the n8n Postgres role (which bypasses RLS) uses them. The functions are `security definer`, with execute revoked from anon and authenticated.
- Users, plans and limits are managed from the **admin dashboard** in the web app (avatar menu → 📊 لوحة التحكم, admins only): overview tiles + 14-day chart, users list with today's activity and filters, create user, edit plan / role / limits / disable / reset password, per-user activity log, plan limits editor.
- Free users can upload too now (daily_uploads); the Free Agent has the `my_documents` tool. Uploads are counted in `sl_feature_usage` (feature `upload`) and logged in `sl_request_log` (kind `upload` / `upload_denied`).

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
| Clarifying questions | about 2 s |
| Mind map / timeline | about 3.5–7.5 s |

**Capacity (the real bottleneck):** see "Models" above. A Pro answer needs ~40–50k tokens, more than one free Groq model allows per minute, so Pro mostly ends on the DeepSeek backup.

**Known issue (Nov 23 2026, mitigated by the breaker):** Gemini embeddings (`gemini-embedding-001`) returned 429 during testing, so `law_library` / `my_documents` search failed and Pro fell back to OpenRouter / DeepSeek (60–180 s). Needs a paid Gemini key or another embedding provider.

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
   - Done (Nov 2026): chat-history drawer, case mind map + timeline, 👍/👎 on every answer and map, admin dashboard.
6. Payments / self-serve Pro upgrade (currently manual SQL).
7. OR follow-ups once there's real usage data:
   - Tune plan limits (LP on `sl_usage`).
   - Queueing / priority under load.
   - Calibrate `cache_threshold`.
   - Grid-search RAG params (chunk size, topK) on a labelled question set.
