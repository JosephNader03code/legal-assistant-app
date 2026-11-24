import json
SYS = r'''Reasoning: low
You are a senior Egyptian lawyer who DRAFTS legal documents in formal Egyptian legal Arabic (فصحى قانونية كما تكتب في المحاكم المصرية).
You receive: the document type, the client's facts, optional chat context and file summaries, and LEGAL SOURCES (exact texts from the law library).
Return ONLY one valid JSON object, no markdown fences, no text before or after:
{"known_facts": ["every concrete datum found in the client's facts, one per item, e.g. \"اسم المؤجر (الطالب): أحمد محمود علي\"، \"عنوان المستأجر: 12 شارع النصر...\"، \"تاريخ العقد: 1/1/2024\"، \"الأجرة الشهرية: 5000 جنيه\"، \"المبلغ المتأخر: 20000 جنيه\""],
 "title": "عنوان المستند",
 "sections": [{"heading": "عنوان القسم (أو \"\" لو مفيش)", "paragraphs": ["فقرة", "فقرة"]}],
 "legal_basis": [{"law": "اسم القانون كما في المصادر", "article": "رقم المادة أو \"\"", "note": "لماذا تنطبق (سطر)"}],
 "missing": ["بيانات ناقصة لازم المحامي يكملها (بحد أقصى 6)"]}
STRICT RULES:
- FIRST fill known_facts, THEN write the document using EVERY item of known_facts in its proper place (names, addresses, dates, amounts, contract details). A placeholder is allowed ONLY for data that is truly absent from the facts.
- Stay faithful to the facts: do not add events, notices or statements the client did not mention, and do not change who did what.
- Follow the standard structure of the requested type (see TYPE GUIDE). Formal, precise, complete sentences; no colloquial Arabic inside the document.
- NEVER invent names, national IDs, addresses, dates, amounts, case numbers, court names or session dates. Put a placeholder in square brackets instead, e.g. [اسم المدعى عليه]، [رقم الدعوى]، [تاريخ الجلسة]، [المبلغ بالأرقام والحروف]. Use the client's facts exactly when given.
- Cite an article number ONLY if that article appears in LEGAL SOURCES. If the right article is not in the sources, state the legal principle without a number and add "مراجعة السند القانوني وأرقام المواد" to missing.
- Never write a legal deadline (عدد أيام/شهور) unless it appears in LEGAL SOURCES.
- 3 to 8 sections. Keep it practical: a lawyer should be able to file it after filling the placeholders.'''
GUIDE = {
 "lawsuit": "صحيفة دعوى: ديباجة الإعلان (إنه في يوم [...] الموافق [...] بناءً على طلب السيد/ [...] المقيم [...] ومحله المختار مكتب الأستاذ/ [...] المحامي — أنا [...] محضر محكمة [...] قد انتقلت وأعلنت: السيد/ [...] مخاطبًا مع [...])، ثم \"الموضوع\" (الوقائع بتسلسل)، ثم \"الأسانيد القانونية\"، ثم \"الطلبات\" (بناءً عليه أنا المحضر سالف الذكر قد انتقلت وأعلنت المعلن إليه وكلفته الحضور أمام محكمة [...] الدائرة [...] بجلستها التي ستنعقد علنًا يوم [...] الموافق [...] من الساعة الثامنة صباحًا وما بعدها ليسمع الحكم بـ: ... مع إلزامه بالمصروفات ومقابل أتعاب المحاماة)، وتنتهي بـ \"ولأجل العلم\".",
 "notice": "إنذار رسمي على يد محضر: ديباجة الإعلان كاملة كقسم أول بدون عنوان: (إنه في يوم [...] الموافق [...] بناءً على طلب السيد/ <اسم الطالب> المقيم <عنوانه> ومحله المختار مكتب الأستاذ/ [...] المحامي، أنا [...] محضر محكمة [...] الجزئية قد انتقلت إلى حيث محل إقامة: السيد/ <اسم المعلن إليه> المقيم <عنوانه> مخاطبًا مع: [...])، ثم \"الموضوع\" (الوقائع)، ثم صيغة الإنذار (فإن الطالب ينذر المعلن إليه بضرورة ... خلال [المدة إن وُجدت في المصادر] من تاريخ استلامه هذا الإنذار، وإلا سيضطر الطالب لاتخاذ كافة الإجراءات القانونية ...)، وتنتهي بـ \"ولأجل العلم\".",
 "memo": "مذكرة دفاع: رأس المذكرة (محكمة [...] — الدائرة [...] — مذكرة بدفاع/ [...] (صفته) ضد/ [...] (صفته) في الدعوى رقم [...] لسنة [...] والمحدد لنظرها جلسة [...])، ثم \"الوقائع\"، ثم \"الدفاع\" (الدفوع الشكلية أولًا ثم الموضوعية، كل دفع في فقرة بعنوان)، ثم \"الطلبات\" (لذلك يلتمس ... الحكم بـ ...).",
 "lease": "عقد إيجار: إنه في يوم [...] الموافق [...] تحرر هذا العقد بين كل من: أولًا [...] (طرف أول مؤجر)، ثانيًا [...] (طرف ثانٍ مستأجر)، ثم \"التمهيد\"، ثم البنود مرقمة (البند الأول: التمهيد جزء لا يتجزأ ... العين المؤجرة، المدة، الأجرة وطريقة السداد، التأمين، الاستعمال، الصيانة، الإخلاء والفسخ، الاختصاص القضائي، عدد النسخ)، ثم التوقيعات.",
 "sale": "عقد بيع: إنه في يوم [...] تحرر هذا العقد بين: البائع والمشتري ببياناتهما، ثم \"التمهيد\" (وصف المبيع وحدوده ومصدر الملكية)، ثم البنود مرقمة (الثمن وطريقة سداده، التسليم، الضمان وخلو المبيع من الحقوق، المصروفات والتسجيل، الاختصاص، النسخ)، ثم التوقيعات.",
 "complaint": "بلاغ للنيابة العامة: السيد الأستاذ المستشار/ المحامي العام لنيابة [...] (أو وكيل النائب العام)، تحية طيبة وبعد، مقدمه لسيادتكم/ [...] ضد/ [...]، ثم \"الموضوع\" (الوقائع بالتواريخ)، ثم \"الوصف القانوني\"، ثم \"الطلبات\" (التحقيق وسؤال الشهود وضبط ... )، ثم \"وتفضلوا بقبول فائق الاحترام\" والتوقيع.",
 "poa_request": "طلب أو التماس رسمي لجهة: السيد/ [صفة المسؤول] [الجهة]، تحية طيبة وبعد، مقدمه/ [...]، ثم \"الموضوع\"، ثم \"الطلب\" بوضوح، ثم المرفقات إن وُجدت، ثم الختام والتوقيع.",
}
PROMPT = "const r = $('Draft Auth').first().json.r;\nconst SYS = " + json.dumps(SYS, ensure_ascii=False) + ";\nconst GUIDE = " + json.dumps(GUIDE, ensure_ascii=False) + r''';
let src = [];
try { const x = JSON.parse($input.first().json.response || '{}'); src = Array.isArray(x.results) ? x.results : []; } catch (e) { src = []; }
const sources = src.slice(0, 3).map((s, i) => '[' + (i + 1) + '] ' + (s.file || '') + '\n' + String(s.text || '').slice(0, 1200)).join('\n\n');
const user = 'نوع المستند: ' + r.type_name + '\nTYPE GUIDE: ' + (GUIDE[r.type] || '') +
  '\n\nوقائع العميل (كما كتبها):\n"""\n' + String(r.facts || '').slice(0, 3000) + '\n"""' +
  (r.context ? '\n\nسياق إضافي:\n"""\n' + String(r.context).slice(0, 4500) + '\n"""' : '') +
  '\n\nLEGAL SOURCES (استشهد بأرقام المواد منها فقط):\n' + (sources || '(لا توجد مصادر — لا تكتب أرقام مواد)') + '\n\nارجع JSON فقط.';
return [{ json: { sys: SYS, user, sources_text: sources } }];'''
PARSE = r'''// LLM JSON -> safe draft; flag any article number that is not in the retrieved sources
const a = $('Draft Auth').first().json.r;
const body = $('Draft Webhook').first().json.body || {};
const srcText = String($('Draft Prompt').first().json.sources_text || '').replace(/[٠-٩]/g, d => d.charCodeAt(0) - 0x660);
const raw = String($input.first().json.text || '');
let m = null;
try { const x = raw.match(/\{[\s\S]*\}/); m = JSON.parse(x ? x[0] : raw); } catch (e) { m = null; }
const s = (v, n) => String(v ?? '').replace(/[ \t]+/g, ' ').trim().slice(0, n);
const inSources = n => new RegExp('ماد[ةه]\\s*[\\(\\[]?\\s*' + n + '([^0-9]|$)').test(srcText);
const unverified = new Set();
const check = txt => String(txt).replace(/[٠-٩]/g, d => d.charCodeAt(0) - 0x660).replace(/(?:الماد[ةه]|ماد[ةه]|م\.)\s*[\(\[]?\s*(\d+)/g, (all, n) => { if (!inSources(n)) unverified.add(n); return all; });
let ok = false, draft = null;
if (m && Array.isArray(m.sections)) {
  const sections = m.sections.map(x => ({ heading: s(x.heading, 120), paragraphs: (Array.isArray(x.paragraphs) ? x.paragraphs : [x.paragraphs]).map(p => s(p, 3000)).filter(Boolean).slice(0, 30) }))
    .filter(x => x.paragraphs.length).slice(0, 12);
  sections.forEach(x => x.paragraphs.forEach(check));
  const legal_basis = (Array.isArray(m.legal_basis) ? m.legal_basis : []).map(b => {
    const art = s(b.article, 20).replace(/[٠-٩]/g, d => d.charCodeAt(0) - 0x660);
    const num = (art.match(/\d+/) || [])[0];
    return { law: s(b.law, 160), article: art, note: s(b.note, 300), verified: num ? inSources(num) : null };
  }).filter(b => b.law || b.article).slice(0, 10);
  ok = sections.length > 0;
  const missing = (Array.isArray(m.missing) ? m.missing : []).map(x => s(x, 200)).filter(Boolean).slice(0, 8);
  if (ok) draft = { type: 'draft', doc_type: a.type, type_name: a.type_name, title: s(m.title, 120) || a.type_name, sections, legal_basis,
                    known_facts: (Array.isArray(m.known_facts) ? m.known_facts : []).map(x => s(x, 200)).filter(Boolean).slice(0, 20),
                    unverified_articles: [...unverified].slice(0, 10), missing, request: s(body.facts, 600) };
}
return [{ json: {
  ok, draft, drafts_left: ok ? a.drafts_left : a.drafts_left + 1,
  error: ok ? undefined : 'failed',
  output: ok ? '' : 'معلش مقدرتش أصيغ المستند دلوقتي (المحاولة دي متحسبتش عليك).',
  llm_error: ok ? '' : String($input.first().json.error || 'failed: the model returned no valid document').slice(0, 400),
  _user: a.user_id, _key: a.session_key, _after: a.after_msg_id,
} }];'''
PG = "{ postgres: { id: '4BLPPc1P7mifOF9z', name: 'Postgres account' } }"
GROQ = "{ groqApi: { id: 'yMugb7f5MV9SNCC6', name: 'Groq account' } }"
B = "$('Draft Webhook').first().json.body"
LOG_COMMON = "token: " + B + "?.token, session: " + B + "?.sessionId, exec_id: $execution.id, question: String(" + B + "?.facts || '').slice(0, 4000), retry_of: (" + B + "?.retryOf || ''), meta: { doc_type: " + B + "?.docType, use_chat: " + B + "?.useChat === true }"
code = f"""import {{ workflow, node, trigger, ifElse, languageModel }} from '@n8n/workflow-sdk';
const PG = {PG};
const GROQ = {GROQ};
const hook = trigger({{ type: 'n8n-nodes-base.webhook', version: 2.2, config: {{ name: 'Draft Webhook', parameters: {{ httpMethod: 'POST', path: 'draft', responseMode: 'responseNode', options: {{ allowedOrigins: '*' }} }}, position: [0, 0] }} }});
const auth = node({{ type: 'n8n-nodes-base.postgres', version: 2.6, config: {{ name: 'Draft Auth', parameters: {{ operation: 'executeQuery', query: 'select sl_draft_take($1, $2, $3, $4, $5::boolean) as r',
  options: {{ queryReplacement: {json.dumps("={{ [ $json.body?.token ?? '', $json.body?.sessionId ?? '', $json.body?.docType ?? '', String($json.body?.facts ?? '').slice(0, 5000), $json.body?.useChat === true ] }}")} }} }}, credentials: PG, position: [220, 0] }} }});
const allowed = ifElse({{ version: 2.2, config: {{ name: 'Draft Allowed?', parameters: {{ conditions: {{ options: {{ caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 }},
  conditions: [ {{ id: 'c1', leftValue: '={{{{ $json.r.ok }}}}', rightValue: '', operator: {{ type: 'boolean', operation: 'true', singleValue: true }} }} ], combinator: 'and' }}, options: {{}} }}, position: [440, 0] }} }});
const denied = node({{ type: 'n8n-nodes-base.respondToWebhook', version: 1.5, config: {{ name: 'Respond Draft Denied', parameters: {{ respondWith: 'json', responseBody: '={{{{ {{ ok: false, error: $json.r.error, output: $json.r.output }} }}}}', options: {{}} }}, position: [660, 200] }} }});
const logDenied = node({{ type: 'n8n-nodes-base.postgres', version: 2.6, config: {{ name: 'Log Draft Denied', parameters: {{ operation: 'executeQuery', query: 'select sl_log($1::jsonb) as l',
  options: {{ queryReplacement: {json.dumps("={{ [ JSON.stringify({ " + LOG_COMMON + ", kind: 'draft_denied', error: $('Draft Auth').first().json.r?.error }) ] }}")} }} }}, credentials: PG, onError: 'continueRegularOutput', position: [880, 200] }} }});
const findLaw = node({{ type: 'n8n-nodes-base.executeWorkflow', version: 1.2, config: {{ name: 'Find Law', parameters: {{ source: 'database',
  workflowId: {{ __rl: true, mode: 'id', value: 'ySmFhCajtWfNI3XG', cachedResultName: 'Smart Lawyer - Search Tool' }},
  workflowInputs: {{ mappingMode: 'defineBelow', value: {{ query: '={{{{ $json.r.search_query }}}}', userId: '={{{{ $json.r.user_id }}}}', scope: 'library' }},
    matchingColumns: [], schema: [ {{ id: 'query', displayName: 'query', required: false, defaultMatch: false, display: true, canBeUsedToMatch: true, type: 'string' }},
      {{ id: 'userId', displayName: 'userId', required: false, defaultMatch: false, display: true, canBeUsedToMatch: true, type: 'string' }},
      {{ id: 'scope', displayName: 'scope', required: false, defaultMatch: false, display: true, canBeUsedToMatch: true, type: 'string' }} ],
    attemptToConvertTypes: false, convertFieldsToString: false }}, options: {{}} }}, onError: 'continueRegularOutput', position: [660, 0] }} }});
const prompt = node({{ type: 'n8n-nodes-base.code', version: 2, config: {{ name: 'Draft Prompt', parameters: {{ jsCode: {json.dumps(PROMPT, ensure_ascii=False)} }}, position: [880, 0] }} }});
const model = languageModel({{ type: '@n8n/n8n-nodes-langchain.lmChatGroq', version: 1, config: {{ name: 'Draft Model', parameters: {{ model: {json.dumps("={{ $('Draft Auth').first().json.r?.llm?.[0] || 'openai/gpt-oss-120b' }}")}, options: {{ temperature: 0.2, maxTokensToSample: 2500 }} }}, credentials: GROQ, position: [1040, 220] }} }});
const fallback = languageModel({{ type: '@n8n/n8n-nodes-langchain.lmChatGroq', version: 1, config: {{ name: 'Draft Model Fallback', parameters: {{ model: {json.dumps("={{ $('Draft Auth').first().json.r?.llm?.[1] || 'openai/gpt-oss-20b' }}")}, options: {{ temperature: 0.2, maxTokensToSample: 2500 }} }}, credentials: GROQ, position: [1200, 220] }} }});
const writer = node({{ type: '@n8n/n8n-nodes-langchain.chainLlm', version: 1.9, config: {{ name: 'Draft Writer', parameters: {{ promptType: 'define', text: '={{{{ $json.user }}}}', needsFallback: true,
  messages: {{ messageValues: [ {{ type: 'SystemMessagePromptTemplate', message: '={{{{ $json.sys }}}}' }} ] }} }},
  subnodes: {{ model: [model, fallback] }}, onError: 'continueRegularOutput', position: [1100, 0] }} }});
const parse = node({{ type: 'n8n-nodes-base.code', version: 2, config: {{ name: 'Draft Parse', parameters: {{ jsCode: {json.dumps(PARSE, ensure_ascii=False)} }}, position: [1320, 0] }} }});
const save = node({{ type: 'n8n-nodes-base.postgres', version: 2.6, config: {{ name: 'Draft Save', parameters: {{ operation: 'executeQuery', query: 'select sl_draft_finish($1::boolean, $2::uuid, $3, $4::int, $5::jsonb, $6::boolean) as s',
  options: {{ queryReplacement: {json.dumps("={{ [ $json.ok, $json._user, $json._key, $json._after, JSON.stringify($json.draft || {}), !!$('Draft Webhook').first().json.body?.retryOf ] }}")} }} }}, credentials: PG, onError: 'continueRegularOutput', position: [1540, 0] }} }});
const respond = node({{ type: 'n8n-nodes-base.respondToWebhook', version: 1.5, config: {{ name: 'Respond Draft', parameters: {{ respondWith: 'json',
  responseBody: {json.dumps("={{ { ok: $('Draft Parse').first().json.ok, type: 'draft', map: $('Draft Parse').first().json.draft, map_id: $('Draft Save').first().json.s?.id, drafts_left: $('Draft Parse').first().json.drafts_left, error: $('Draft Parse').first().json.error, output: $('Draft Parse').first().json.output } }}")}, options: {{}} }}, position: [1760, 0] }} }});
const log = node({{ type: 'n8n-nodes-base.postgres', version: 2.6, config: {{ name: 'Log Draft', parameters: {{ operation: 'executeQuery', query: 'select sl_log($1::jsonb) as l',
  options: {{ queryReplacement: {json.dumps("={{ [ JSON.stringify({ " + LOG_COMMON + ", kind: 'draft', input_chars: String(" + B + "?.facts || '').length, output_chars: JSON.stringify($('Draft Parse').first().json.draft || {}).length, sources_chars: String($('Draft Prompt').first().json.sources_text || '').length, error: $('Draft Parse').first().json.ok ? '' : $('Draft Parse').first().json.llm_error, answer: $('Draft Parse').first().json.ok ? String($('Draft Parse').first().json.draft?.title || '') : '', models: /(too many requests|rate limit|429)/i.test($('Draft Parse').first().json.llm_error || '') ? ($('Draft Auth').first().json.r?.llm || []) : [], llm_error: /(too many requests|rate limit|429)/i.test($('Draft Parse').first().json.llm_error || '') ? $('Draft Parse').first().json.llm_error : '' }) ] }}")} }} }}, credentials: PG, onError: 'continueRegularOutput', position: [1980, 0] }} }});
export default workflow('sl-drafting', 'Smart Lawyer - Drafting')
  .add(hook).to(auth).to(allowed.onTrue(findLaw.to(prompt).to(writer).to(parse).to(save).to(respond).to(log)).onFalse(denied.to(logDenied)));
"""
open('draftwf.js','w').write(code)
