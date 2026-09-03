# Server contract: chat streaming, durable chat jobs, chat storage, sharing

Source of truth: `server.mjs` (Node, zero deps) at the repo root. Every line number below is
`server.mjs:<line>` unless prefixed `app.js:`. `app.js` citations describe what the web client does
today (so the iOS client can match it) — the server never depends on them.

Auth vocabulary used throughout:

| Term | Meaning |
| --- | --- |
| **member cookie** | `firas_session=<signed>` (`COOKIE_NAME`, :1046). Resolved by `currentUser()` (:1098); rejected when the account's `sessVer` moved (logout-everywhere / password change). |
| **guest cookie** | `firas_guest=<signed>` (`GUEST_COOKIE`, :1131), id prefixed `g_`, 7-day Max-Age (`GUEST_COOKIE_MAX_AGE = 604_800`, :1132), minted by `POST /api/guest` (`handleGuestStart`, :2017). |
| **caller** | `callerOf(req)` (:1314) → `{user,id,isGuest:false}` for a member, `{id,isGuest:true}` for a guest, `{}` otherwise. |

All JSON error bodies are `{ "error": "<string>", ...extra }` written by `sendJson` (:1690). All
timestamps in chat records are ISO-8601 strings; all timestamps in job records are epoch **ms** numbers.

---

## 1. `POST /api/chat` — live SSE stream (`handleChat`, :12740–13110)

Route: :13732. `OPTIONS /api/chat` → 204 with `Allow: POST, OPTIONS`; any other method → 405 plain
text `method not allowed`.

### 1.1 Auth, rate limit, body

| Check | Result | Line |
| --- | --- | --- |
| No member cookie **and** no guest cookie | `401 {"error":"authentication required"}` | :12746 |
| Rate limit `chat:<callerId>`: **120/min member, 30/min guest** (`rateLimited` :1076 — sliding 60 s window of timestamps; the 121st/31st call inside any 60 s is refused) | `429 {"error":"too many requests, please slow down"}` | :12755 |
| Body not JSON, or body string longer than `CHAT_BODY_LIMIT = 25_000_000` **characters** (not bytes; :442, `readBody` :1646 counts JS string length; an over-limit body is `req.destroy()`ed, so the client may see a reset instead of a response) | `400 {"error":"invalid JSON body"}` | :12764 |
| `messages` missing / not an array / empty | `400 {"error":"body must include a non-empty \"messages\" array"}` | :12775 |

Note: the job worker re-enters this same function with a synthetic request (§3.6), so every rule
here also applies to durable jobs.

### 1.2 Request payload (all fields the server reads; anything else is ignored)

```json
{
  "messages": [ { "role": "system|user|assistant", "content": "…", "images": ["<base64>", "…"] } ],
  "tier": "mini|pro|ultra|max",
  "think": true,
  "cid": "turn-id-[A-Za-z0-9_-]{1,64}",
  "chatId": "<server chat id>",
  "product": "ai|code|agent|brain",
  "nomem": false,
  "nokb": false,
  "agent": false
}
```

| Field | Type / default | Server behaviour |
| --- | --- | --- |
| `messages` | array, required | Passed to the engine after the transforms in §1.4. Only `role`, `content`, `images` are read. `content` must be a string for text engines (Cloudflare rescue also tolerates an array of `{text}` parts, :311). |
| `messages[i].images` | array of strings | Each is a **raw base64** string or a `data:image/...;base64,` URL; `normalizeImage` (:446) strips the data-URL prefix, trims, and **drops** any single image whose base64 length > `MAX_IMAGE_B64_BYTES = 8_000_000` chars (:441). At most `MAX_IMAGES_PER_REQUEST = 10` images across the whole request (`buildVisionMessages`, :489 — a shared budget consumed in message order); the keyless last-resort vision engine takes only 3 (:13039). **Vision is decided by the LAST user message only** (`hasImages`, :465): if the last user message has a non-empty `images` array the request is a vision turn; otherwise **all** `images` on every message are stripped (`stripImages`, :477) and a text engine answers. MIME is sniffed from the base64 header (`b64Mime`, :6551: `/9j/`→jpeg, `iVBOR`→png, `R0lGOD`→gif, `UklGR`→webp, else jpeg). Web client caps at `MAX_IMAGES = 10` (app.js:35897) and sends raw base64 without prefix (app.js:44483); a text follow-up that refers to the earlier image silently re-attaches the previous `images` (app.js:44486). |
| `tier` | string, default `"pro"` | `TIERS[payload.tier] ? payload.tier : "pro"` (:12767). Unknown values silently become `pro`. User-facing tier names live in the web `MODELS` table (app.js:27): `mini` = `فِراس ميني` / `Firas Mini` (short `ميني`/`Mini`), `pro` = `فِراس برو` / `Firas Pro` (`برو`/`Pro`), `ultra` = `فِراس أولترا` / `Firas Ultra` (`أولترا`/`Ultra`), `max` = `فِراس ماكس` / `Firas Max` (`ماكس`/`Max`). `showThinking` is `false` for `mini`, `true` for the other three. |
| `think` | boolean, default `false` | Forwarded reasoning on/off. **Forced `false` on vision turns** (:12934). Engines still *ask* the model to think, but reasoning deltas are only *sent* when `think` is true (:2985, :3030, :6661, :7081, :7155, :7380). The web sends `think = userToggle && MODELS[tier].showThinking` (app.js:42624), so `mini` never sends `think:true`. |
| `cid` | string | Sanitised `replace(/[^A-Za-z0-9_-]/g,"").slice(0,64)` (:12772). Per-turn id: dedupes quota charging (§1.3) and is the key `saveAssistantTurn` upserts on. |
| `chatId` | string ≤64 | Only used by the (off-by-default) `DURABLE_CHAT=1` mode (`DURABLE_CHAT` const :2751, `res._durable` :12981). With the flag off — the deployed state — a client that disconnects mid-stream **aborts generation and nothing is saved** (`res.on("close")` :12953). Durability comes from `/api/chat/job` (§3). |
| `product` | `"ai"|"code"|"agent"|"brain"`, default `"ai"` | Selects the quota bucket (:12882 guest, :12888 member). Members: `brain` allowed; guests: `brain` coerces to `ai`. Any other string → `ai`. |
| `nomem` | boolean | "Internal helper call" (auto-title, agent steps, OCR, file pipeline). Effects: no `IDENTITY_BLOCK`, no memory injection, no KB, charged to the `internal` budget instead of the product budget, backtrack scrubber off, `res._helper=true` (engines skip hidden reasoning), and the Pro tier skips the paid OpenAI engine (:12860, :13000). |
| `nokb` | boolean | Skip knowledge-base injection (:12815). Irrelevant today: `KB_IN_CHAT` is off unless `KB_IN_CHAT=1` (:12814). The web sends `nokb: true` only on a Firas Code build turn (app.js:42624). |
| `agent` | boolean | Turns the backtrack scrubber off (`res._scrubBt = !nomem && !agent`, :12965). |

There is **no** `lang`, `search`, `attachments`, or `files` field on `/api/chat`. Language is
whatever the messages are written in. Attached documents are sent by the web client as *extracted
text inside `content`* (app.js:44494 `fileText`), never as a separate field. Web search is
**client-driven** (§1.6).

### 1.3 Quotas and charging (in order, before any engine runs)

1. **Max daily cap** (:12830–12838): only if `TIERS[tier].capped` — `max.capped === false` (:432) and
   `MAX_DAILY_LIMIT = -1` (:3218), so this never fires. Shape if it ever did:
   `429 {"error":"daily Max limit reached","limit":N,"used":N,"remaining":0}`.
2. **`nomem` + member** (:12860): charged to `PLAN_LIMITS[plan].internal` — all plans (`free`, `gold`,
   `diamond`, `unlimited`) are `-1` for every product (unlimited, :1347–1352), so no 429 today. Shape:
   `429 {"error":"daily quota reached","quota":{"product":"internal","used":N,"limit":N,"plan":"free"}}`.
3. **`nomem` + guest** (:12872): `guestChargeWithReq(..., "internal", cid, messages)` against
   `GUEST_LIMITS.internal = 300/day` (:1151).
4. **Real turn + guest** (:12880): product bucket `ai` (180/day), `code` (60), `agent` (24) —
   `GUEST_LIMITS` :1133–1152 (also `brain: 120`, `voice: 120` for other endpoints), env-overridable
   (`GUEST_DAILY_AI` etc.). Denial body:
   `429 {"error":"guest daily limit reached","guest":true,"quota":{"product":"ai","used":180,"limit":180,"plan":"guest"}}`
   or, when the **per-IP network bucket** (`GUEST_IP_MULTIPLIER = 4` × the cookie limit, :1256–1277) is
   spent, the same with `"limit": 720, "scope": "network"`. Idempotent: same `cid` **and** same
   last-user-message hash within `RETRY_WINDOW_MS = 120 s` (:1213) is not charged twice
   (`isRepeatCharge`, :1225; agent uses `MISSION_WINDOW_MS = 45 min` (:1214) and cid alone).
5. **Real turn + member** (:12886): `limitsFor(planOf(user))[product]` — always `-1` today, so the
   counters increment for statistics only and no 429 can occur. Shape if a limit were set:
   `429 {"error":"daily quota reached","quota":{"product":"ai","used":N,"limit":N,"plan":"free"}}`.

UI wording the web uses for a quota 429 (`quotaLimitText`, app.js:6464): guests get
`STR.guestLimitReached` — ar `"انتهت رسائلك المجانية لهذا اليوم كضيف. أنشئ حسابًا مجانيًا للحصول على حدّ أعلى بكثير."`,
en `"You have used today's free guest messages. Create a free account for a much higher limit."` —
and a sign-up prompt. Members get
`"🚦 بلغت الحدّ اليومي من ${name} (${lim}/يوم). يتجدّد تلقائيًا بعد منتصف الليل.\n\nفِراس مجاني بالكامل — هذا السقف موجود ليبقى المحرّك متاحًا للجميع، وهو مرتفع لدرجة أن الاستخدام الطبيعي لا يبلغه."`
with `name` ∈ {`رسائل فِراس AI`, `طلبات فِراس Code`, `مهام فِراس Agent`, `أسئلة فِراس Brain`}.
A plain rate-limit 429 (no `quota` key) renders `"طلبات كثيرة بسرعة — انتظر لحظة ثم حاول مجددًا."` /
`"Too many requests too fast — wait a moment and try again."` (app.js:42715).

### 1.4 Server-side message transforms (what the model actually sees)

Applied in this order, mutating the `messages` array (:12911–12935):

1. **Identity** (unless `nomem`): `IDENTITY_BLOCK` (:12720) is **prepended** to the first `system`
   message, or a new system message is unshifted if none exists (:12911). The client's own persona
   prompt (web: `buildMessages`, app.js:37837) is therefore *not* required for identity, but the web
   sends its full system prompt anyway (persona, language rule, LaTeX rules, etc.).
2. **Memory** (member, not `nomem`): `memoryBlock(user)` (:7406) appended to the first system message.
3. **Vision routing**: `vision = hasImages(messages)`; `think = vision ? false : !!payload.think`;
   messages become `buildVisionMessages` (Ollama shape with raw base64) or `stripImages`.

The server does **not** add the tier persona, language rule, or math rules — those are client
responsibility (see the prompts analyst's report).

### 1.5 Engine ladder (which engine answers; from `handleChat` :12988–13085 and `TIERS` :401–432)

| Tier | Primary chain | `num_predict` | temp |
| --- | --- | --- | --- |
| `mini` | Ollama ladder `gemma4:cloud → qwen3.5:35b-cloud → gpt-oss:120b-cloud`; `fallbackModel qwen3-coder:480b-cloud` | 16384 | 0.5 |
| `pro` (default) | **OpenAI Pro** first when `OPENAI_PRO_API_KEY` set and not `nomem`/vision (:13000); else Ollama `glm-5.2:cloud → deepseek-v4-flash:cloud → gpt-oss:120b-cloud`; fallback `qwen3-coder:480b-cloud` | 131072 | 0.7 |
| `ultra` (Firas Code) | Ollama `glm-5.3:cloud → kimi-k2.7-code:cloud → glm-5.3-flash:cloud → minimax-m3:cloud → qwen3-coder:480b-cloud`; fallback `gpt-oss:120b-cloud` | 131072 | 0.35 |
| `max` (Agent) | Ollama `glm-5.3-flash:cloud → glm-5.3:cloud → kimi-k3:cloud → nemotron-3-ultra:cloud → qwen3-coder:480b-cloud` → NVIDIA DeepSeek → Gemini → Anthropic → OpenRouter (:13007–13016); fallback `gpt-oss:120b-cloud` | 131072 | 0.5 |
| vision (any tier) | Gemini vision (`GEMINI_API_KEY`) → local Ollama `qwen2.5vl:7b` (one cold-start retry after 1.2 s) → keyless pollinations with ≤3 images | — | — |

Rescue chain for every non-vision tier when the primary wrote **zero bytes** (:13043–13082):
Gemini (not for max) → Cloudflare strong/fast model → OpenRouter (not for max) → tier
`fallbackModel` on Ollama → keyless pollinations `streamFallback` (:7306). Engines only fall through
if nothing was written, so a stream never splices two engines. **The stream never tells the client
which engine answered** — no header, no frame field.

Timeouts: idle (silence) `UPSTREAM_IDLE_MS = 300 s`, re-armed on every emitted frame; hard ceiling
`UPSTREAM_MAX_MS = 1800 s` (:58–59). First-byte deadlines per engine (e.g. `OLLAMA_FIRST_BYTE_MS`
45 s) are internal.

### 1.6 Web search / grounding — NOT in the stream

`/api/chat` performs no search. The web client (app.js:42440–42480) decides before sending:
`state.webSearch` toggle **or** `needsWebSearch(text)` (app.js:41015, explicit intent regexes) →
visible "Searching the web…" (`"يبحث في الإنترنت…"`) badge, 8 s budget; otherwise
`benefitsFromSilentSearch` → silent, 1.5 s budget. It calls
**`GET /api/search?q=<≤300 chars>`** (`handleWebSearch`, :6035; the web itself slices `q` to 280
before sending, app.js:41038; member or guest cookie; rate `search:<callerId>` 30/min;
`401 {"results":[],"error":"auth"}`, `429 {"results":[],"error":"rate"}`, `400 {"results":[]}` for an
empty `q`) which returns
`200 {"q":"…","results":[{"title":"≤300","url":"https://…","snippet":"≤500"}], "via":"serper|brave|tavily|gemini|ddg|none"}`
(`searchRow`, :5859; chain :6022). The client keeps ≤6 rows, formats them with
`formatSearchContext` (app.js:41141 — Arabic/English header instructing `[1] [2]` citations and a
`### المصادر` / `### Sources` section, an untrusted-data rule, and a per-request nonce fence
`----UNTRUSTED-WEB-<NONCE>----` … `----END-UNTRUSTED-WEB-<NONCE>----`), and inserts it as a
**`role:"user"`** message right after the system message (app.js:42480). An explicit (non-silent,
non-i'rab) search downgrades **any tier other than `max`** to `pro` for that request
(`if (!isIrab && !silentSearch && requestTier !== "max") requestTier = "pro"`, app.js:42488) — so
`mini` and `ultra` both become `pro`; a silent search never changes the tier. Vision turns never
search. When the toggle is on but the search returns nothing, the web appends a system note
`"تنبيه: لم تُرجع نتائج بحث ويب لهذا السؤال؛ أجب من معرفتك العامة وأخبر المستخدم أنه لم تتوفر نتائج ويب حيّة."`
(en: `"Note: no live web results were found for this query; answer from general knowledge and tell the user that no live web results were available."`, app.js:42493).
The model's "sources" are just Markdown in the answer; there is no source event.

### 1.7 SSE wire format (`sseInit` :2643, `sseWrite` :2767, `sseDone` :2799)

Response headers: `200`, `Content-Type: text/event-stream; charset=utf-8`,
`Cache-Control: no-cache, no-transform`, `Connection: keep-alive`, `X-Accel-Buffering: no`.
Headers are sent **after** all the 4xx checks above, so an error is always a JSON response and a
stream is always 200 (even when the answer is an engine-failure sentence — see 1.8).

Only three kinds of line ever appear. No `event:`, `id:`, `retry:` or comment lines; no custom
tool/search/status/file events.

```
data: {"choices":[{"delta":{"content":"مرحباً! "}}]}\n\n
data: {"choices":[{"delta":{"reasoning":"The user greets me…"}}]}\n\n
data: {"choices":[{"delta":{"content":"…","reasoning":"…"}}]}\n\n      ← both keys possible in one frame (:2790, Ollama emits content+thinking together)
data: [DONE]\n\n
```

- `delta.content` — answer text, already passed through the backtrack scrubber when
  `res._scrubBt` (plain chat only; can hold ~56 chars back and release later, :2818).
- `delta.reasoning` — thinking text; only present when `think:true`. Some engines put
  `<think>…</think>` inside `content` instead; the web client splits it out (`makeThinkSplitter`, app.js:41614).
- A frame never has an empty delta (`sseWrite` returns without writing, :2783).
- `[DONE]` is always the final line; the connection then ends. Deltas may be large (the pollinations
  fallback buffers the whole answer and emits it as one frame, :7380).
- Client must buffer partial lines across chunks, ignore non-`data:` lines, and tolerate malformed JSON.

### 1.8 Engine-failure answers (streamed as content, HTTP 200)

When every engine fails the stream still completes with one of these exact strings as the only
content, then `[DONE]`. The web treats a whole answer matching them as a failure and auto-retries
once (`busyRe`, app.js:42771:
`/^(The Firas AI (?:vision )?engine is (?:busy|unavailable|offline)[\s\S]{0,80}?|Something went wrong with the Firas AI engine\.) ?(Please )?[Tt]ry again\.?\s*(shortly\.?)?\s*$/`);
iOS should do the same and never persist them as a turn.

| Text (verbatim) | Line |
| --- | --- |
| `تعذّر الوصول إلى محرك Firas AI حالياً — يرجى المحاولة مرة أخرى بعد لحظات.\n\nThe Firas AI engine is unavailable right now. Please try again.` | :7336 |
| `محرك Firas AI مشغول حالياً — يرجى المحاولة مرة أخرى بعد لحظات.\n\nThe Firas AI engine is busy right now. Please try again.` | :7344 |
| `The Firas AI engine is busy right now. Please try again.` | :7387 |
| `Something went wrong with the Firas AI engine. Please try again.` (thrown handler) | :13095 |
| `تعذّر إكمال القائمة بسرعة حالياً — أعد المحاولة بعد لحظات.\n\nThe list could not be completed quickly right now. Please try again in a moment.` (problem-list turns only) | :356–362 |

An empty stream (`[DONE]` with no content) is also a failure; the web throws `"empty stream"`
(app.js:42766).

### 1.9 Stopping a live stream

Close the HTTP connection. `res.on("close")` aborts the upstream (:12953). There is no cancel
endpoint for a non-job stream (`POST /api/chat/cancel` only knows job ids, §3.5).

---

## 2. Durable chat jobs — overview

The queue (`/api/chat/job`) exists only in `server.mjs` (not in the Netlify edge mirror). The web
client uses it for **every** ordinary turn of a persisted chat (`CHAT_JOB = true`, app.js:41196;
`useJob` app.js:42646): member with a `serverId`, or any guest; never for a temporary
(`ephemeral`) chat. The turn is then *polled*, and the poll is converted into the same SSE shape as
§1.7 (`fetchChatJob`, app.js:41202). Falls back to the live stream on **413** (payload too large —
image turns), **404/501** (no queue on this backend), or a thrown non-abort error (app.js:42655–42680).
A non-OK start response other than those (e.g. 429) is handled exactly like a non-OK `/api/chat`
response.

Constants (:9322–9330, :9519–9532, :9413–9418):

| Constant | Value | Client meaning |
| --- | --- | --- |
| `JOB_PAYLOAD_MAX` | 600 000 chars of raw JSON body | above → `413 {"error":"payload_too_large"}`; use `/api/chat` instead |
| `JOB_CONCURRENCY` | 4 | a job may sit in `queued` |
| `JOB_STALE_MS` | 120 s | a runner whose heartbeat stopped is re-queued (not failed) — tolerate 2 min of silence |
| `JOB_MAX_ATTEMPTS` | 3 | then `failed` |
| `JOB_KEEP_MS` | 6 h | after a terminal phase the record is deleted; status then answers `{"phase":"unknown"}` |
| `LONGFILE_KEEP_MS` | ≥ 6 h | long-file queue records; the artifact meta/parts survive forever |
| `LONGDOC_MAX_MS` | 6 h | long document wall-clock cap |
| `LONGFILE_MAX_PAGES` | 10 000 | |
| `LONGFILE_BATCH_PAGES` | 2 (env 1–4) | pages per durable part |
| `LONGFILE_SLICE_MS` | 8 min | a long file runs in slices, re-queuing itself with `nextAt = now + LONGFILE_DEFER_MS (5 s)` between them (:10440–10446, :11856) — expect brief `queued` phases mid-run |

Job id: `jobIdFor(ownerId, cid) = sha1(ownerId).hex.slice(0,10) + "-" + jobKey(cid)` (:728–729),
where `jobKey` replaces `[.$#[\]/\s]` with `_` and caps at 96 chars. **Idempotent per owner+cid.**

---

## 3. Job endpoints

### 3.1 `POST /api/chat/job` — start (`handleChatJobStart`, :12531–12656)

Auth: member **or** guest cookie; else `401 {"error":"authentication required"}`.
Rate limit `chatjob:<callerId>`: **60/min member, 30/min guest** → `429 {"error":"too many requests"}`.
Body: same JSON as `/api/chat` (§1.2) plus the job fields below; read with `CHAT_BODY_LIMIT`;
unparsable → `400 {"error":"invalid JSON body"}`.

Extra body fields:

| Field | Type | Notes |
| --- | --- | --- |
| `kind` | `"chat"` (default) \| `"longdoc"` \| `"longfile"` \| `"agentrun"` \| `"codebuild"` \| `"brainask"` | Anything else → `"chat"` (:12617). `agentrun`/`codebuild`/`brainask` belong to other slices; only `chat`, `longdoc`, `longfile` are documented here. |
| `cid` | string | Sanitised as in §1.2; if empty the server mints `"j"+12hex` (:12563) — **always send one**, or retries create duplicate jobs. |
| `chatId` | string ≤64 | Where the finished assistant turn is filed (members only; guests get `chatId:""`, :12615). Must be a chat the user owns, else the save is a silent no-op. |
| `product` | string ≤12, default `"ai"` | |
| `task` | string ≤8000 | `longdoc`/`longfile`/`brainask`: the brief; falls back to the last user message. |
| `title` | string ≤160 | Stored on the job (used by push copy). |
| `lang` | `"en"` else `"ar"` | Stored as `rec.lang`; becomes the saved assistant turn's `lang` (default **`"ar"`**). |
| `sections` | integer | `longdoc` only: 3…`LONGDOC_MAX_SECTIONS` (120), default 40 (:9476). Web sends `max(6, min(240, round(pages/4)))` (app.js:41512). |
| `format` / `fileFormat` | `"pdf"` \| `"docx"` (`"word"`, `"doc"` → `docx`; leading `.` stripped) | `longfile` only (`normalizeLongFileRequest`, :9541). |
| `pages` / `pageCount` / `targetPages` | integer 1…10000 | `longfile` only. **Physical** pages: a PDF's page 1 is the cover, so a 1-page PDF is cover-only; DOCX has no cover page (:10381). |

Validation order and errors:

| Condition | Response | Line |
| --- | --- | --- |
| `kind:"longfile"` with bad format | `400 {"error":"longfile_format_invalid"}` | :9547 |
| `kind:"longfile"` with pages <1 or >10000 | `400 {"error":"longfile_pages_invalid","maxPages":10000}` | :9548 |
| guest and (`kind:"agentrun"` or `product:"agent"`) | `403 {"ok":false,"error":"account_required","feature":"agent"}` | :12556 |
| `messages` missing/empty | `400 {"error":"messages required"}` | :12558 |
| raw body length > 600 000 | `413 {"error":"payload_too_large"}` | :12560 |
| storage read/write failed | `503 {"error":"storage_unavailable"}` | :12571, :12645 |
| `agentrun` while another agent job is active | `409 {"error":"agent_busy","activeJob":{jobId,chatId,cid,title},"credits":{…}}` | :12602 |
| `agentrun` with no Manus credit | `429 {"error":"credits_reserved","credits":{…}}` | :12611 |

Idempotency (:12570–12588) — if a job with the same owner+cid exists:

```json
// still running
{ "ok": true, "jobId": "<id>", "phase": "queued" | "processing" }
// already finished (a stored phase of "completed" OR the legacy "done" both answer "completed" here)
{ "ok": true, "jobId": "<id>", "phase": "completed", "text": "…", "reasoning": "…", "surface": null|{…}, "progress": null|{…} }
// failed earlier — must start a NEW cid to retry
{ "ok": false, "jobId": "<id>", "phase": "failed", "error": "<string>", "surface": null|{…}, "retryRequiresNewCid": true }
```

Success (new job): `200 {"ok":true,"jobId":"<id>","phase":"queued"}` (:12655). The worker tick is
kicked immediately; the loop otherwise runs every 2 s (:12000).

The server stores the raw body verbatim (`in/<id>`) and creates the control record (:12613–12633):
`{id, uid, isGuest, chatId, cid, tier, kind, product, task, title, lang, format, pages, progress,
phase:"queued", error:"", status:0, attempts:0, maxAttempts:3, claimedBy:null, heartbeat:0,
nextAt:0, createdAt, updatedAt, finishedAt:0}`. `tier` falls back to `"pro"` when unknown.

**The user turn is NOT saved by the job.** Only the assistant turn is (§3.6). The web client PUTs
the chat (including the new user message) *before* starting the job (app.js:42618 `await
persistChat(chat)`). iOS must do the same or the answer lands in history without its question.

### 3.2 `GET /api/chat/job?id=<jobId>` — status/poll (`handleChatJobStatus`, :12658–12711)

Auth: member or guest → else `401 {"error":"authentication required"}`. No rate limit of its own.
`id` is passed through `jobKey`.

Response (always 200 unless auth/ownership fails):

```json
{
  "phase": "queued" | "processing" | "completed" | "failed" | "unknown",
  "text": "<answer so far, or full answer>",
  "reasoning": "<thinking so far>",
  "error": "",            // failed: error string (may be a JSON string — see below)
  "status": 0,            // failed-by-refusal: the HTTP status handleChat would have returned (401/429/…)
  "surface": null | { … },   // longfile / agent surface object
  "progress": null | { … }   // longfile progress object (§4.2); null for every other kind
}
```

- Served from **memory** while this process is running the job (:12668–12704) — `text` grows
  token-by-token; `phase` is always `"processing"` there. Zombie guard: if the in-memory capture
  looks wrong (its stream already ended, or it has produced no text/reasoning/surface for > 60 s
  since it was born) the server consults the durable record; when that record is terminal the
  capture is evicted and the saved answer is served instead (:12680–12703).
- Otherwise from the store: `queued` (no `out` read except longfile — so `text` is `""` while queued),
  `processing` (stale claim, throttled snapshot — `out` is written on first token then at most every
  2.5 s, :11815–11831), or terminal.
- `403 {"error":"forbidden"}` if the job belongs to someone else.
- `{"phase":"unknown"}` (nothing else) when the id has no record — expired (>6 h) or never existed.
  The web requires **three consecutive** `unknown` polls before treating it as terminal
  (`fetchChatJob`, app.js:41294).
- A **refusal** (quota/rate/auth inside `handleChat`) becomes `phase:"failed"`, `status:<http>`,
  `error:"<the JSON body handleChat wrote, ≤1000 chars>"` (:11924–11930), e.g.
  `error: "{\"error\":\"guest daily limit reached\",\"guest\":true,\"quota\":{…}}"`. The web parses
  `error` as JSON and shows `quotaLimitText` if it has a `quota` key, else `e.error`; a non-JSON
  `error` renders nothing and the generic engine-error path speaks (app.js:41296–41305).
  Refusals are **not retried**. Engine failures are retried up to 3 attempts with backoff
  `attempts*5000 ms`; `error` then holds the last message or `"no_answer"` (:11940–11947).
  Other terminal `error` values: `user_not_found` (member deleted), `payload_missing`.
  Cancelled longfile: `status:499, error:"cancelled"`.

Web poll cadence (`gap()`, app.js:41234): first poll immediately, then every **350 ms for the first
10 s, 700 ms until 40 s, then 1200 ms**; gives up after 20 consecutive non-OK responses; stops on
401/403 (`job_unowned`). On return-to-foreground it re-polls up to 16 × 2.5 s
(`recoverGuestJobOnReturn` app.js:2602 for guests, reading the job by the id remembered in
`localStorage["firas_job_<chatId>"]`; `refreshChatFromServer` app.js:2537 for members via
`GET /api/chats/:id`, adopting the server copy only when its last assistant message is longer, or it
has more messages, or the local last turn is not an assistant turn). The background-jobs skill
recommends an unhurried interval for anything long; the growing `text` gives the streaming feel,
not a faster poll.

A separate SSE channel exists — `GET /api/agent/job-stream?id=` (:12183; frames written by
`agentJobStreamWrite` :12175 as `id: <seq>\nevent: <name>\ndata: {…}\n\n` with names `snapshot`
(:12238), `terminal` `{id, phase}` (:12240), `agent-error` `{error, retryable}` (:12253); `retry: 3000`
(:12212); `: keepalive` every 15 s (:12285); rate `agent-job-stream:<uid>:<ip>` 90/min). It
works for any job id the caller owns but its payload is the *agent* view (`agentJobViewPayload`);
see the agent report before relying on it for chat jobs.

### 3.3 Terminal states and what to display

| `phase` | Meaning | Text |
| --- | --- | --- |
| `completed` | answer saved to `out` (and to the chat for members) | `text` is the full answer; for `longfile` it is the compact `firas-file` reference (§4.3) |
| `failed` + JSON `error` | refusal | show the quota/rate message |
| `failed` + `"cancelled"` / `status:499` | user pressed Stop | nothing (partial text was discarded) |
| `failed` + other | engine gave up after 3 attempts | generic engine error; allow retry with a new cid |
| `unknown` | record gone | if the chat already has the answer (member: re-GET the chat) fine; else treat as failed |

### 3.4 Push notification on completion (`notifyDurableJobTerminal`, :1627)

Members only (never guests), only when APNs is configured and the user registered a device
(`POST /api/push/register`, :13836 — see the auth/push report). Payload (:1562):

```json
{ "aps": { "alert": {"title":"…","body":"…"}, "sound": "FirasComplete.wav", "category": "FIRAS_JOB_COMPLETE",
           "thread-id": "firas-<product>-<chatId|jobId>" },
  "firas": { "type": "job-terminal", "product": "<product>", "jobId": "<id>", "phase": "completed"|"failed", "chatId": "<chatId if any>" } }
```

Arabic copy: `"<name> اكتملت"` / `"اضغط لعرض النتيجة."`; failure `"<name> لم تكتمل"` /
`"اضغط لعرض التفاصيل أو المحاولة مجدداً."` (:1548–1556). Collapse id = job id.

### 3.5 `POST /api/chat/cancel` — stop a job (`handleChatCancel`, :12478–12529; route :13755)

Auth: member or guest → else 401. Body `{"id":"<jobId>"}` (≤4000 chars; id sanitised
`[A-Za-z0-9_-]{1,64}` — the `-` in job ids is preserved). Responses:

| Case | Response |
| --- | --- |
| missing id | `400 {"error":"bad_request"}` |
| job running **in this process** | sets `_cancelled` (generation stops at the next chunk; longfile also writes a durable `cancelledAt`) → `200 {"ok":true,"stopped":true}` |
| running job owned by someone else | `403 {"error":"not_yours"}` |
| not running locally, no record | `404 {"error":"unknown_job"}` |
| record owned by someone else | `403 {"error":"not_yours"}` |
| record is not a queued/processing **longfile** | `409 {"error":"job_not_running"}` (a queued plain chat job cannot be cancelled before it starts) |
| queued/processing longfile | tombstoned: `phase:"failed", status:499, error:"cancelled"` → `200 {"ok":true,"stopped":true}` |

After a cancel of a plain chat job the worker sees `_cancelled`, the capture ends; whatever
`_answer` had accumulated is still **published and saved** if non-empty (the `answer` branch at
:11888 does not check `_cancelled` for non-longfile kinds; only the push notification is
suppressed, :11904). Only longfile discards partial output. Aborting the *poll* never stops the job.

### 3.6 Worker (`runOneJob`, :11767–11948) — what gets saved

1. Claims the record (`phase:"processing"`, heartbeat every 15 s).
2. Builds a synthetic request with a **freshly minted cookie for the owner** (member `firas_session`
   with current `sessVer`, or `firas_guest`) and the stored body (:11840–11843), then for
   `kind:"chat"` calls `handleChat(creq, cr)` — so auth, rate limit (`chat:` bucket), quota
   charging, identity/memory injection and the full engine chain are identical to the live stream.
   The rate limit means a job start counts against both `chatjob:` and `chat:` buckets.
3. `cr` is a capture response (`makeCaptureRes`, :9338): `sseWrite` appends to `_answer` /
   `_reasoning` (post-scrub, byte-identical to what a live client would render); `sendJson` refusals
   are captured as `_status` + `_body`.
4. On finish with non-empty `answer.trim()` (:11888):
   - `out/<id>` ← `{text: _answer, reasoning: _reasoning, surface?}` (`jobOutPut`, :838).
   - member with `chatId` → `saveAssistantTurn(user, chatId, cid, _chatAnswer || _answer, _reasoning, tier, lang, strict)`.
   - `ctl` ← `phase:"completed", status:0, error:""`; push notification; input body deleted.
5. Refusal (`_status >= 400`) → `phase:"failed", status, error:<body>`; no retry.
6. Otherwise retry/backoff or `failed` after 3 attempts. Server shutdown/redeploy re-queues without
   counting an attempt (`jobBootRecover`, :11983).

`saveAssistantTurn` (:2513–2537): finds the chat by `id` **and** `userId` (foreign chat → silent
no-op `chat_missing`; never creates a chat). Builds one sanitised message
`{role:"assistant", content, reasoning, tier, lang, cid}`; if an assistant message with the same
`cid` already exists it is **replaced in place** (carrying over `retryOf`/`retried`), else
**appended**; trims to the **last** `MAX_MESSAGES = 2000`; bumps `updatedAt`. Because the upsert is
keyed by `cid`, a later client PUT containing the same `cid` on its assistant message does not
duplicate the turn — so the iOS client must put the job's `cid` on the assistant message it stores.

---

## 4. Long-form kinds

### 4.1 `kind:"longdoc"` (`runLongDocJob`, :9467–9516)

Triggered by the web when the ask matches `LONGDOC_RE` (app.js:41507:
`/موسوعة|كتاب\s*(ضخم|كامل|شامل)|مرجع\s*شامل|\d{3,4}\s*صفح|مئات\s*الصفح|آلاف\s*الصفح|encyclopedia|mega\s*book|comprehensive\s*(book|reference)|\d{3,4}\s*pages?|hundreds\s*of\s*pages/i`).
The server plans `sections` chapter titles, writes each with `llmComplete`, and grows `text` as
`"## <title>\n\n<body>"` blocks joined by `"\n\n"` (`#`/`##` inside bodies are demoted to `###`).
`progress` in the status response is **null** for longdoc (the ctl `progress` string `"n/total"`
is not exposed). Result is plain Markdown; saved to the chat like any turn. Errors:
`longdoc_no_task`, `longdoc_empty`.

### 4.2 `kind:"longfile"` — exact-page PDF/DOCX written as durable parts (:9519–10490)

Web trigger (app.js:42285): the user asked for a `pdf`/`docx` file **with an explicit page count**
(`explicitFilePages = parseExplicitPageCount(lastUserTurn.content)`, app.js:41588 / :30219 —
Latin/Arabic-Indic digits + "pages"/"صفحة"), in a non-ephemeral chat (member with `serverId`, or
any guest). Body sent:

```json
{ "kind":"longfile", "format":"pdf", "pages":12, "targetPages":12, "prompt":"<task>", "task":"<task ≤16000>",
  "messages":[{"role":"user","content":"<task>"}], "tier":"pro", "think":false, "lang":"ar",
  "cid":"<cid>", "product":"ai", "chatId":"<serverId or ''>" }
```

Pipeline: plan (`longFileMakePlan`, JSON `{filename,title,subtitle,theme,template,sections:[{title,focus}]}`,
themes `teal|navy|burgundy|emerald|royal|amber|slate|minimal|dark|midnight`, templates
`academic|ministry|corporate|magazine`) → write body pages in batches of `LONGFILE_BATCH_PAGES`
(each page 250–400 Arabic words / 350–550 English words, validated: `page_sequence`, `page_title`,
`page_size` (400–6000 visible chars), `page_machinery`, `page_duplicate`, question-bank rules) →
each batch committed as **part `p000000`, `p000001`, …** (`{version:1, partIndex, startPage,
endPage, records:[{pageNumber,title,markdown}], sha256, createdAt}`) → final QA → completion.
Question-bank mode (`longFileQuestionBankRequest`, :9566) is inferred from the task text and adds
`<!-- FIRAS_QUESTION_START:… -->` markers inside `markdown` that renderers must strip
(app.js:30067 `stripFirasQuestionMarkers`).

**Progress object** (`longFileProgressSurface`, :10258–10285) — returned as `progress` on start,
status and file endpoints:

```json
{ "stage": "queued"|"planning"|"writing"|"qa"|"complete"|"cancelled",
  "pagesDone": 3, "pagesTotal": 12, "targetPages": 12,
  "bodyPagesDone": 2, "bodyPagesTotal": 11, "coverPages": 1,
  "currentPage": 4, "currentTitle": "…",
  "partsDone": 1, "partsTotal": 6, "percent": 25,
  "resumeAvailable": true, "complete": false, "cancelled": false,
  "completedPages": 3, "requestedPages": 12, "resumePartIndex": 1, "nextBodyPageOrdinal": 3 }
```

The initial ctl record's `progress` (stage `queued`) has only the first 14 keys (:12622–12627).
Web progress copy (app.js:41348): planning `"يخطط هيكل الملف…"`, writing `"يكتب صفحات الملف…"`,
final `"يراجع ويجمّع الملف…"`, each followed by `" done / total"`.

**Surface object** (`out.surface`, also `surface` in status): `{version:1, kind:"longfile",
artifactId, format, pageCount, contentPageCount, coverPages, batchSize, taskHash, questionBank,
meta:{filename,title,subtitle,theme,template,pageCount,contentPageCount,coverPages},
plan:{meta,sections}, progress:{…}, manifest:{requestedPages,completedPages,partsDone,partsTotal,complete,resumePartIndex}, …progress fields spread}`.

Runtime errors surface as `error` strings prefixed `longfile_` (e.g. `longfile_no_task`,
`longfile_page_batch_invalid_<page>_<issue>`, `longfile_final_qa_<issue>`,
`longfile_question_commit_<issue>`).

### 4.3 How the finished file is represented in the answer (`longFileReference`, :9724)

The **completed** job's `text` — and the assistant turn saved to the chat — is exactly:

````
```firas-file
{"filename":"…","title":"…","subtitle":"…","theme":"teal","template":"academic","pageCount":12,"contentPageCount":11,"coverPages":1,"format":"pdf","artifactId":"<jobId>","artifactVersion":1,"artifactParts":6,"artifactEndpoint":"/api/chat/job/file?id=<urlencoded jobId>"}
```

# <title>

> أصبح المستند الكامل المكوّن من 12 صفحة جاهزًا للمعاينة والتصدير.
````

(English note: `The complete 12-page document is ready for preview and export.`). The page bodies
are **not** in the chat; the client must fetch parts to preview/export. The web recognises a ready
reference with `longFileRefReady` (app.js:41371: fence present, `artifactId`, `artifactEndpoint`,
`pageCount`, `format ∈ {pdf,docx}`) and accepts `artifactEndpoint` only if it matches
`/^\/api\/chat\/job\/file\?id=[A-Za-z0-9%._~-]{6,240}$/` (`normalizeFileMeta`, app.js:30318) and
resolves on the same origin to pathname `/api/chat/job/file` (`longFileArtifactUrl`, app.js:30096).

Non-durable files (xlsx/pptx/csv, or pdf/docx without an explicit page count) are produced by the
**browser** from a model answer that starts with the same ```` ```firas-file {meta} ```` fence
(`metaBlockString`, app.js:38440; meta fields `filename,title,subtitle,theme,accent?,template?,
slideCount?,pageCount?`) followed by the document Markdown — that pipeline is client-side and
belongs to the file-generation report. Code deliverables use ```` ```firas-code {"filename","lang","ext","label"}\n<code>\n``` ```` (app.js:42768).

### 4.4 `GET /api/chat/job/file?id=<jobId>[&part=N]` (`handleChatJobFile`, :10491–10578; route :13729)

Auth: member or guest; ownership by the artifact's permanent meta (`firasartifacts/<id>/meta`) or
the job record. Works **after** the 6 h queue TTL because meta+parts are permanent.

Manifest (no `part`):

```json
{ "ok": true, "phase": "completed"|"processing"|"queued"|"failed"|"unknown",
  "artifact": { "artifactId":"<id>", "artifactVersion":1, "format":"pdf", "pageCount":12, "coverPages":1, "bodyPages":11,
                "partsDone":6, "partsTotal":6, "completedPages":12, "complete":true, "questionBank":false,
                "meta": { "filename":"…","title":"…","subtitle":"…","theme":"teal","template":"academic","pageCount":12,"contentPageCount":11,"coverPages":1 } },
  "partsUrl": "/api/chat/job/file?id=<id>&part={part}" }
```

Part (`part` = `^\d{1,6}$`, 0-based):

```json
{ "ok": true, "artifactId":"<id>", "part":0, "partsTotal":6, "startPage":2, "endPage":3,
  "records":[ {"pageNumber":2,"title":"…","markdown":"…"}, {"pageNumber":3,"title":"…","markdown":"…"} ],
  "sha256":"<64 hex>",
  "text":"<!-- FIRAS_PAGE:2 -->\n\n## …\n\n…\n\n<!-- FIRAS_PAGE_BREAK -->\n\n<!-- FIRAS_PAGE:3 -->\n\n## …\n\n…" }
```

`text` for `part > 0` is prefixed with `"<!-- FIRAS_PAGE_BREAK -->\n\n"` (:10217). Body pages of a
PDF start at page 2 (cover is page 1); DOCX starts at 1. Integrity: `sha256` =
SHA-256 of `JSON.stringify(records.map(r => [r.pageNumber, String(r.title||""), String(r.markdown||"")]))`
as UTF-8, lowercase hex (:10094) — the web recomputes it for every part (`longFileRecordsSha256`,
app.js:30105; mismatch → `"artifact part checksum mismatch"`, app.js:30181) and rejects any
manifest/part mismatch. Client-side reassembly (app.js:30193): `"<!-- FIRAS_PAGE:n -->\n## title\n\nmarkdown"`
per page joined by `"\n\n<!-- FIRAS_PAGE_BREAK -->\n\n"`, prefixed by the meta fence.

Errors: `401 authentication required`, `400 bad_request` (no id), `404 unknown_artifact`,
`403 forbidden`, `400 not_a_longfile`, `409 {"error":"artifact_not_ready","phase":"…"}`,
`400 bad_part`, `404 part_not_ready` (index ≥ `partsDone` or missing), `500 artifact_part_corrupt`.

---

## 5. Chat storage — `/api/chats` (:2411–2641; routes :13841–13855)

**Members only.** Every handler answers `401 {"error":"not authenticated"}` for guests or no cookie
(guest history lives on-device in the web app). Bodies are read with `readJson(req, 2_000_000)`
(:1682): over 2 000 000 characters `readBody` rejects (`"body too large"`) **and** destroys the
socket, so the client sees either a connection reset or the top-level handler's
`500 {"error":"internal error"}` (:13860); non-JSON → `400 {"error":"invalid JSON body"}`.
`persist()` rewrites the whole DB on every write — expect 0.3–3 s on large accounts. Unknown
methods on `/api/chats` or `/api/chats/:id` → 405 plain text `method not allowed`; `:id` is
`decodeURIComponent`ed (:13849).

### 5.1 Full chat record (server-side; `handleCreateChat` :2557–2609)

```json
{ "id": "c_<clientId>" | "<uuid>", "userId": "<uid>", "clientId": "<if given>",
  "title": "≤200 chars, default \"New chat\"",
  "messages": [ …sanitised messages… ],
  "pinned": false, "agent": false, "codeProj": false, "brainNb": false,
  "createdAt": "<ISO>", "updatedAt": "<ISO>" }
```

There is **no** `folder`, `product`, `intent`, or per-message `ts` on the server. Folders,
colour tags and drafts are device-local in the web app. The product is the trio of booleans
(`agent` = Firas Agent chat, `codeProj` = Firas Code project, `brainNb` = Firas Brain notebook), set
**only at creation** — `PUT` never changes them (:2595).

### 5.2 Message schema (`sanitizeMessages`, :2431–2505) — the only fields that survive a write

| Field | Type / bound | Notes |
| --- | --- | --- |
| `role` | string ≤20, default `"user"` | any string accepted |
| `content` | string ≤`MAX_CONTENT` = 1 000 000 chars, default `""` | may contain `firas-file` / `firas-code` fences |
| `tier` | string ≤20 | `mini|pro|ultra|max` in practice |
| `lang` | string ≤5 | `ar`/`en` |
| `reasoning` | string ≤1 000 000 | assistant thinking |
| `cid` | string ≤64 | per-turn id (must match the job cid) |
| `files` | `[{name ≤200}]`, ≤12 | attachment chips (names only; a bare string is accepted and wrapped) |
| `imageThumbs` | `[string ≤300 000]`, ≤6 | small data-URL thumbnails; full images are **never** stored |
| `mode` | string ≤20 | e.g. `"plan"` |
| `askAnswered` | `true` only | plan-mode panel answered |
| `retryOf` | `{cid ≤64, tier ≤20}` | stronger-model retry link |
| `retried` | `true` only | |
| `mergedFrom` | string ≤120 | merge seam |
| `alts` | `[{content, reasoning?, tier?, lang?}]`, kept only if ≥2, max 5 | answer versions; `altAt` clamped to range, default last |

Dropped on write: `images`, `fileText`, `ts`, `intent`, `offline`, `think`, `attachments`, anything
else. Array capped to the **first** `MAX_MESSAGES = 2000` on PUT/POST (`slice(0,2000)`), the
**last** 2000 in `saveAssistantTurn`. The web client's `serializeMessages` (app.js:3507) sends
exactly: `role, content, tier, lang, reasoning, mode?, mergedFrom?, cid?, askAnswered?, alts?/altAt?,
retryOf?, retried?, imageThumbs?, files?`.

### 5.3 Endpoints

**`GET /api/chats`** (:2539) → `200` array sorted by `updatedAt` desc (string compare of ISO):
`[{"id","title","updatedAt","pinned":bool,"agent":bool,"codeProj":bool,"brainNb":bool}]`. No
messages, no `createdAt`. The web filters by the three flags into the three product sidebars and
lazy-loads messages on open (app.js:3372).

**`POST /api/chats`** (:2557) body `{clientId?, title?, messages?, pinned?, agent?, codeProj?, brainNb?}`:
- `clientId` matching `/^[A-Za-z0-9_-]{8,120}$/` makes the id deterministic `"c_"+clientId`; a
  repeat POST with the same `clientId` returns the **existing** record with `201` (safe retry).
- New chat when the user already has `MAX_CHATS_PER_USER = 1000` →
  `409 {"error":"chat limit reached; delete some conversations"}`.
- → `201 {"id","title","createdAt","updatedAt"}`.

**`GET /api/chats/:id`** (:2549) → `200 {"id","title","messages":[…]}` (no flags, no dates);
`404 {"error":"not found"}` (also for another user's chat).

**`PUT /api/chats/:id`** (:2611) — **merge of top-level keys, full replace of `messages`**:
- `title` (string) → replaced (≤200), bumps `updatedAt`.
- `messages` (array) → **whole array replaced** with the sanitised copy, bumps `updatedAt`. Omit the
  key to leave messages untouched; sending `[]` erases them.
- `pinned` (boolean) → set **without** bumping `updatedAt` (pin must not reorder the list).
- Anything else ignored (product flags cannot change).
- → `200 {"ok":true}`; `404 {"error":"not found"}`.
The web uses PUT `{clientId,title,messages,pinned,agent,codeProj,brainNb}` for every save
(`persistChatNow`, app.js:3465 — 6 s timeout per request, 3 attempts, newer saves supersede older
ones), `{title[,messages]}` for a rename (`renameChatOnServer`, app.js:19341), and `{pinned}` alone
for a pin toggle (app.js:19307). Because PUT replaces the array, a client must always send its
complete local copy — and must include the job `cid` on the assistant turn so the worker's upsert
and the client's PUT converge on one message.

**`DELETE /api/chats/:id`** (:2629) → `200 {"ok":true}`; `404 {"error":"not found"}`. Immediate and
permanent (the web's 7 s undo — `UNDO_MS = 7000`, app.js:13456 — is client-side only: the DELETE is
merely scheduled).

### 5.4 Auto-title — client-side

The server never titles a chat (default `"New chat"`). The web (`autoTitleChat`, app.js:13411) calls
`POST /api/chat` with `{messages:[system, user(first message ≤500 chars)], tier:"pro", think:false, nomem:true}`
(`callAgentText`, app.js:38813), system prompt verbatim:
`"Generate a SHORT, specific title (2–5 words, ≤40 chars) for a chat starting with the user's message. Use the SAME language as the message. Return ONLY the title — no surrounding quotes, no trailing punctuation, no 'Title:' prefix."`,
strips quotes / `Title:` prefix, caps at 60 chars, validates (`validAutoChatTitle`, app.js:13355),
skips if the user renamed meanwhile, then `PUT /api/chats/:id {title, messages}` via
`renameChatOnServer` (guests: local save only). Agent chats and file requests use local heuristics
instead (`agentTitleFrom`, `fileChatTitleFrom`). Temporary chats are never titled. Because the
call is `nomem:true`, it is charged to the `internal` budget (guest: 300/day) and never gets the
identity block or memory.

---

## 6. Public share links — `/api/share` (:9207–9312; routes :13811–13813)

**`POST /api/share`** (`handleShareCreate`, :9217) — members only (`401 {"error":"auth required"}`;
the web never calls it as a guest and shows `openSignUpPrompt("share")` instead, app.js:79687;
guest toast for a chat with no messages: `"افتح محادثة فيها رسائل أولًا"`). Rate limit `share:<uid>` **5/min** →
`429 {"error":"too many requests"}`. Body (`readBody` default 2 000 000 chars; non-JSON →
`400 {"error":"invalid JSON"}`):

```json
{ "chatId": "<server chat id>", "msg": 3, "cid": "<turn cid>" }   // msg/cid optional
```

- Whole-chat share: omit `msg`. Snapshot = first 400 messages, each reduced to
  `{role:"user"|"assistant", content ≤200 000, lang? ≤8, tier? ≤16, imageThumbs? (≤10 data:image/ URLs ≤200 000 each)}`,
  plus `title` (≤200).
- Single-answer share: send `msg` (index) and, when known, `cid` — **`cid` outranks the index**;
  the target must be an assistant message with non-empty content, else `404 {"error":"not found"}`.
  The snapshot holds **only that one message**, `title:""`, and `one:1`.
- `chatId` not owned → `404 {"error":"not found"}`.
- Re-sharing the same chat (or the same single answer) returns the **existing** id
  (`200 {"ok":true,"id":"<existing>"}`) and refreshes its `ts`.
- More than `SHARES_PER_USER_MAX = 20` distinct shares →
  `409 {"error":"لقد وصلت إلى الحد الأقصى للمشاركات (20). احذف مشاركة قديمة أولاً."}`.
- → `200 {"ok":true,"id":"s<base36 ms><10 hex>"}`.

Share URL: **`https://firasai.org/?share=<id>`** (web: `location.origin + "/?share=" + r.id`,
app.js:79703). The page is `index.html` rendering `checkShareLink` (app.js:79807) — a read-only view
with a "Try Firas AI free" / `"جرّب فِراس مجانًا"` CTA. No server-rendered HTML exists; iOS should
either open the URL in Safari or render the JSON below itself.

**`GET /api/share?id=<id>`** (`handleShareGet`, :9296) — **public, no auth**; id is stripped to
`[a-zA-Z0-9]`. → `200 {"id","title":"","messages":[{role,content,lang?,tier?,imageThumbs?}],"ts":<ms>,"one":0|1}`;
`404 {"error":"not found"}`. Render `imageThumbs` only when they start with `data:image/`.

**`DELETE /api/share?id=<id>`** (`handleShareDelete`, :9302) — members only; owner or admin.
→ `200 {"ok":true}` (also when the id no longer exists); `403 {"error":"not yours"}`.

Related but out of scope here: `POST /api/usage/charge` (`{product:"code"|"agent", cid}`, :7654) is
the pre-charge the web makes before a Code build or Agent mission; plain chat is charged inside
`handleChat` only.

---

## 7. Implementation checklist for the native client

1. Chat turn for a signed-in user: `PUT /api/chats/:id` with the user message → `POST /api/chat/job`
   with `{messages, tier, think, cid, product:"ai", chatId}` → poll `GET /api/chat/job?id=` and render
   growing `text`/`reasoning` → on `completed`, store the assistant turn with the same `cid`,
   `tier`, `lang` → `PUT` the full array. On `413`/`404` fall back to `POST /api/chat` SSE.
2. Guest turn: same, without `chatId`; the finished answer lives only on the job for 6 h.
3. Image turns: always `POST /api/chat` (jobs will 413); last user message carries `images`.
4. Treat §1.8 sentences and empty streams as failures; retry once.
5. Remember `jobId` per chat on-device; on foreground re-poll the job (guest) or re-GET the chat
   (member) and adopt the server copy only when it is longer/newer.
6. Never expect `progress` for anything but `longfile`; never expect an engine name.
