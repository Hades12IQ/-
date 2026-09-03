# Firas Brain — web client behaviour and native spec

Source of truth: `server.mjs` (routes at 13762 and 13804–13808; handlers at 7974–9204, 11702–11765) and `app.js` (the Brain product occupies 80794–90045). Every claim below cites `file:line`. Arabic strings are copied verbatim.

The existing Codex-written Swift (`ios/FirasAI/Stores/BrainStore.swift`, `Models/BrainModels.swift`, `Features/Brain/*`) implements only "upload → keyword search → passage sheet". It has no grounded answer, no citations, no scope, no pins, no compare, and several constants diverge from the web (see §17). Treat this document, not that code, as the contract.

---

## 0. Glossary

| Term | Meaning | Where |
| --- | --- | --- |
| **kind** | `"pdf" \| "docx" \| "pptx" \| "xlsx" \| "text" \| "image"`. Anything else the server coerces to `"text"`. | server.mjs:8000, 8417 |
| **unit** | `"page" \| "slide" \| "sheet" \| "section"`. Unknown → `"page"`. pdf/image/text → page, pptx → slide, xlsx → sheet, docx → section. | server.mjs:8001, 8418; app.js:85262 |
| **page record** | `{ p: Int (1-based), text: String, l?: String (label ≤80) }` — what the client POSTs. | app.js:80805; server.mjs:8306 |
| **chunk** | `{ t, p, l? }` — ~700-char piece cut *inside* one page record by the server. Never crosses a page. | server.mjs:8306–8329 |
| **ci** | Chunk index into `doc.chunks`. The address `/api/brain/passage` opens. Always a real index (scoped views are unmapped before response). | server.mjs:8274–8290 |
| **hit** | Retrieval result carrying provenance (see §4.4). | server.mjs:7851–7885 |
| **source pointer** | `{ n, d, t, u, p, l, c, s }` — the lean form persisted in the answer's `firas-sources` fence. | app.js:86653 |
| **cid** | Client-minted request id (`[A-Za-z0-9_-]{1,64}`); makes the per-answer charge idempotent. | server.mjs:9110–9133 |
| **brainNb** | Chat flag: this conversation belongs to Brain's own list. | server.mjs:2595; app.js:13308 |

---

## 1. Identity and auth

| Endpoint | Member (`firas_session` cookie, server.mjs:1046) | Guest (`firas_guest` cookie, server.mjs:1131, 7-day Max-Age) | Nobody |
| --- | --- | --- | --- |
| `GET /api/brain/docs` | 200 | 200 (`guest:true`) | 403 `{error:"signin_required", feature:"brain"}` |
| `POST /api/brain/doc` | 200 | 200 | 403 same |
| `DELETE /api/brain/doc` | 200 | 200 | 403 same |
| `POST /api/brain/search` | 200 | 200 | 403 same |
| `GET /api/brain/passage` | 200 | 200 | 403 same |
| `POST /api/brain/whole` | 200 | **403** `{error:"signin_required", feature:"brain_whole"}` | **401** `{error:"authentication required"}` |
| `POST /api/chat` (OCR, query expansion, answer stream) | 200 | 200 | 401 |

`brainCaller` (server.mjs:8343) → `callerOf` (server.mjs:1314): member first, else guest, else `{}` → 403.

Client: `apiJson` (app.js:3216) has a **global** hook — any response with status 403 and `data.error === "signin_required"` opens the sign-up overlay (`openSignUpPrompt(feature)`, app.js:47087). Text of that overlay (feature ≠ "image"):

- ar title `هذه الميزة تحتاج حسابًا`, body `أنشئ حسابًا مجانيًا لتفعيلها — يستغرق أقل من دقيقة.`, CTA `إنشاء حساب مجاني`, later `لاحقًا` (app.js:697–715)
- en title `This feature needs an account`, body `Create a free account to unlock it — it takes less than a minute.`, CTA `Create a free account`, later `Later` (app.js:1794–1808)

A 401 after boot for a *member* triggers `handleSessionExpired` (toast `انتهت جلستك. الرجاء تسجيل الدخول من جديد.` / `Your session expired. Please sign in again.`, app.js:3236–3250); guests ignore 401.

A guest's library is stored server-side under the guest id (server.mjs:8331–8342). Clearing the cookie loses it; guest libraries are swept after **14 days** of inactivity (`BRAIN_GUEST_TTL_DAYS`, disk mode only, server.mjs:8340, 8372).

---

## 2. Limits and quotas (all authoritative numbers)

### 2.1 Server constants

| Constant | Value | Applies to | Cite |
| --- | --- | --- | --- |
| `BRAIN_MAX_DOCS` | 20 documents | members | server.mjs:7995 |
| `BRAIN_GUEST_MAX_DOCS` | 3 documents | guests | server.mjs:8341 |
| `BRAIN_PAGES_DAILY` (members) | −1 (unlimited) on every plan | ingest pages/day | server.mjs:8008 |
| `BRAIN_GUEST_PAGES_DAILY` | 120 distinct pages/day | guests | server.mjs:8342 |
| `BRAIN_MAX_CHUNKS_PER_DOC` | 12,000 | per document | server.mjs:7996 |
| `BRAIN_MAX_CHARS_PER_DOC` | 8,000,000 | per document | server.mjs:7997 |
| `BRAIN_MAX_PAGES_PER_REQ` | 1,200 **records** per POST | per POST | server.mjs:7998 |
| `BRAIN_BODY_LIMIT` | 24,000,000 bytes | POST /api/brain/doc | server.mjs:7999 |
| search body cap | 200,000 bytes | POST /api/brain/search | server.mjs:9109 |
| whole body cap | 100,000 bytes | POST /api/brain/whole | server.mjs:8981 |
| `BRAIN_VISION_DAILY` | `GEMINI_KEYS.length × 500` (env override) — site-wide OCR page budget | reported as `limits.visionLeft` | server.mjs:8023–8035 |
| `BRAIN_OVERVIEW_CHARS` | 48,000 chars | overview sample budget | server.mjs:8149 |
| `BRAIN_WHOLE_MAX_CHARS` | 2,600,000 chars (env) | whole-document corpus | server.mjs:9046 |
| chat `MAX_IMAGES_PER_REQUEST` | 10 | images per /api/chat call | server.mjs:440 |
| chat `MAX_IMAGE_B64_BYTES` | 8,000,000 | per image | server.mjs:441 |
| chat `CHAT_BODY_LIMIT` | 25,000,000 | /api/chat body | server.mjs:442 |

`BRAIN_VISION_DAILY` = `GEMINI_KEYS.length × GEMINI_RPD_PER_KEY` (env; `GEMINI_RPD_PER_KEY` default 500) unless `BRAIN_VISION_DAILY` is set; the counter is **in memory only** (`_brainVision`, server.mjs:8026) — a server restart re-grants the day's budget, and `limits.visionLeft` is what the client reads before deciding how many pages to OCR (§6.2 step 3).

### 2.2 Rate limits (`rateLimited`, sliding window, server.mjs:1076)

| Key | Max / window | Response | Cite |
| --- | --- | --- | --- |
| `brain:add:<id>` | 60 / 60 s | 429 `{error:"too many requests"}` | server.mjs:8411 |
| `brain:q:<id>` (search) | 120 / 60 s | 429 `{error:"too many requests"}` | server.mjs:9105 |
| `brainwhole:<id>` | 6 / 60 s | 429 `{error:"rate_limited"}` | server.mjs:8979 |
| `chat:<id>` | member 120 / 60 s, guest 30 / 60 s | 429 `{error:"too many requests, please slow down"}` | server.mjs:12754 |

### 2.3 Daily answer quota ("brain" product)

Charged **once per answer at `/api/brain/search` and `/api/brain/whole`**, never on `/api/chat` (the answer streams with `nomem:true`, which is unmetered for members) — server.mjs:9114–9133, 8990–9012.

- Members: `PLAN_LIMITS.*.brain = -1` on every plan → no ceiling; counter still increments (server.mjs:1353–1356). Member idempotency: `quota.last.brain === cid` (server.mjs:9128).
- Guests: `GUEST_LIMITS.brain = 120/day` per cookie (server.mjs:1146) **and** `120 × 4 = 480/day` per hashed IP (`GUEST_IP_MULTIPLIER = 4`, server.mjs:1256–1278; network bucket charged first). Guest idempotency: `isRepeatCharge` (server.mjs:1225) keys on `reqHash(cid, messages)` within `RETRY_WINDOW_MS = 120_000` (server.mjs:1213) — but **both Brain endpoints call `guestChargeWithReq(req, c.id, "brain", cid)` with no `messages`** (server.mjs:8999, 9121), so the hash is `sha256(cid + NUL + "")` — `reqHash` joins `cid`, a U+0000 separator and the last user message, which here is absent (server.mjs:1215–1223) — and the rule degrades to *same cid within 120 s, whatever the body*. A guest cid therefore must be fresh per turn (the web mints `uid()` per turn) and may be reused freely by the fallback searches inside that turn.
- Guest `nomem` helper calls (OCR, query expansion) draw on `GUEST_LIMITS.internal = 300/day` (server.mjs:1152, 12867). Members: `internal = -1`.
- Days roll at Baghdad local midnight: `serverDay` with `QUOTA_TZ_OFFSET_MINUTES = 180` (server.mjs:3196–3204).

429 bodies:

```json
{"error":"daily quota reached","quota":{"product":"brain","used":120,"limit":120,"plan":"free"}}
{"error":"guest daily limit reached","guest":true,"quota":{"product":"brain","used":120,"limit":120,"plan":"guest"}}
{"error":"guest daily limit reached","guest":true,"quota":{"product":"brain","used":480,"limit":480,"plan":"guest","scope":"network"}}
```

### 2.4 Client-side constants (app.js:80825–80872 unless noted)

| Constant | Value | Purpose |
| --- | --- | --- |
| `BRAIN_MAX_UPLOAD_CHARS` | 700,000 chars per POST | part splitting |
| `BRAIN_MAX_RECORDS_PER_POST` | 1,000 records per POST (server rejects >1,200) | app.js:85372 |
| `BRAIN_OCR_CONCURRENCY` | 3 parallel vision calls | |
| `BRAIN_OCR_MAX_PAGES` | 300 vision pages per document | |
| `BRAIN_TEXT_PAGE_MIN` | 40 non-whitespace chars — below this a page is "scanned" | |
| `BRAIN_ARABIC_MIN_QUALITY` | 0.62 — below this the page is re-read with vision | |
| `BRAIN_OCR_EDGE` | 2,200 px longest edge for document pages (chat vision uses 1,568) | |
| `BRAIN_RASTER_SCALE` | 2.8 pdf.js scale, capped by the edge | |
| JPEG quality | 0.85, raw base64 without `data:` prefix | app.js:84797, 85290 |
| `BRAIN_PIN_MAX` | 40 pinned ids | app.js:81242 |
| ask box `maxlength` | 4,000 chars | app.js:87203 |
| history sent to the model | last 8 non-system messages | app.js:87021 |
| `BRAIN_HARVEST_*` | batch 18,000 chars, overlap 3,500, concurrency 6, retries 3, max 54 batches, max 50,000 chunks | app.js:85612–85644 |

---

## 3. Data shapes

### 3.1 Document meta (`brainMetaOf`, server.mjs:8061)

```json
{"id":"bdm1x2y3z4abcdef01","title":"كتاب الأحياء.pdf","kind":"pdf","unit":"page",
 "pages":187,"indexed":185,"ocr":12,"chunks":2140,"chars":1452000,"ts":1756800000000}
```

- `id`: `"bd" + base36 time + 8 hex` (server.mjs:8038); validated by `/^[A-Za-z0-9_-]{1,64}$/` (server.mjs:8037).
- `pages`: distinct page numbers ingested (sum over parts); `indexed`: pages that produced ≥1 chunk; `ocr`: pages the client reported as vision-read; `ts`: ms epoch of last write (list sorted by `ts` desc, server.mjs:8089).

### 3.2 Hit (search result), server.mjs:7871–7877, 8199–8205

```json
{"matched":3,"score":1.84,"text":"…≤700 chars…","docId":"bd…","title":"كتاب الأحياء.pdf",
 "kind":"pdf","unit":"page","page":42,"label":"","ci":517}
```

- `matched` present only on ranked hits (absent on overview/all/neighbour hits).
- `near: true` marks a neighbour pulled in by `brainExpandNeighbours` (score = parent × 0.30/d forward, × 0.22/d backward).
- `page` is `0` for a chunk with no page (never happens for client-produced records since `p` is forced ≥1, server.mjs:8309).

### 3.3 Source pointer (persisted inside the answer), app.js:86653–86660

```json
{"n":1,"d":"bd…","t":"كتاب الأحياء.pdf","u":"page","p":42,"l":"","c":517,"s":"first 400 chars of the hit text"}
```

Encoded as a trailing fence on `msg.content`:

```
<answer markdown>

```firas-sources
[{"n":1,"d":"…","t":"…","u":"page","p":42,"l":"","c":517,"s":"…"}]
```
```

Decode with `/```firas-sources\s*([\s\S]*?)```/` (app.js:86660). Strip both fences for display/copy (`brainStripSources`, app.js:86677). The compare marker fence is `"\n\n```firas-cmp\n{\"i\":0}\n```\n\n"` (app.js:86683).

**Why a fence:** `sanitizeMessages` (server.mjs:2431) and `serializeMessages` (app.js:3507) whitelist message fields; a `sources` property would be dropped. Persisted message fields: `role, content, tier, lang, reasoning, mode?, mergedFrom?, cid?, askAnswered?, alts?…` (app.js:3507–3540; server.mjs:2431–2470). `MAX_CONTENT` per message is 1,000,000 chars (server.mjs:2429).

---

## 4. Endpoints

### 4.1 `GET /api/brain/docs` (server.mjs:8394–8407)

Response 200:

```json
{"docs":[…meta…],"guest":false,
 "limits":{"docs":20,"pagesPerDay":-1,"visionLeft":5988},
 "used":{"docs":4,"pagesToday":0}}
```

Guest example: `"guest":true,"limits":{"docs":3,"pagesPerDay":120,"visionLeft":…}`. `pagesToday` is today's ingest count for the caller. Client (`brainFetchDocs`, app.js:85394): on non-403 failure toast `تعذّر تحميل المحادثات.` / `Couldn't load conversations.` (app.js:956, 2045); sets `loaded = true` on every path.

### 4.2 `POST /api/brain/doc` (server.mjs:8409–8473)

Request (client construction at app.js:85428–85431):

```json
{"title":"كتاب الأحياء.pdf","kind":"pdf","unit":"page",
 "pages":[{"p":1,"text":"…"},{"p":2,"text":"…","l":"optional label"}],
 "ocr":12}
```

- Part 1 carries `ocr` (Int, vision-read page count for the *whole* document) and no `docId`.
- Parts 2..n carry `"docId":"<id from part 1>"` and **no** `ocr` (server adds `p.ocr` on every call — resending it double-charges the site vision budget, server.mjs:8466–8468).
- `title` ≤200 (server slices; default `"Untitled"`); `kind` outside the set → `"text"`; `unit` outside the set → `"page"`.
- Each `p` is coerced `max(1, floor(Number(p)))`; each `l` sliced to 80.
- pptx is chunked line-wise (`brainSplitLines`), everything else sentence-wise (`kbSplitText(text, 700, 12)`); a page whose entire text falls under the 12-char floor is kept as one chunk anyway (server.mjs:8313–8322).

Response 200:

```json
{"ok":true,"id":"bd…","title":"…","chunks":312,"total":312,"doc":{…meta…}}
```

Errors, in server order:

| Status | Body | Meaning | Client UI (app.js:85438–85446) |
| --- | --- | --- | --- |
| 403 | `{error:"signin_required",feature:"brain"}` | no identity | sign-up overlay (global) |
| 429 | `{error:"too many requests"}` | >60 POSTs/min | falls to generic: `تعذّرت قراءة الملف — too many requests` |
| 413 | `{error:"too_large"}` | body > 24 MB or JSON parse failure | `الملف كبير جدًا` / `File too large` |
| 400 | `{error:"no pages"}` | empty `pages` | generic readFail |
| 413 | `{error:"too_large"}` | >1,200 records | tooLarge |
| 400 | `{error:"invalid id"}` | bad `docId` | generic |
| 404 | `{error:"not found"}` | `docId` unknown | generic |
| 429 | `{error:"limit",limit:"docs",max:20}` | library full (checked only when no `docId`) | `وصلت الحد الأقصى للمستندات` / `Document limit reached` |
| 429 | `{error:"limit",limit:"pages",used:118,max:120,guest:true}` | daily ingest pages (distinct `p` in this POST) | `وصلت حدّ الصفحات اليومي` / `Daily page limit reached` |
| 413 | `{error:"too_large",limit:"chunks"}` | doc would exceed 12,000 chunks | tooLarge |
| 413 | `{error:"too_large",limit:"chars"}` | doc would exceed 8,000,000 chars | tooLarge |

**Order matters:** the page charge (`brainChargePages`) is applied and persisted *before* the chunk/char ceilings are checked (server.mjs:8447–8460), so a 413 on the size ceiling has already consumed the guest's daily pages for that part. Also note the doc-count check happens per fresh upload, so a document that is mid-upload (continuation parts) is never refused.

### 4.3 `DELETE /api/brain/doc?id=<id>` (server.mjs:8475–8481)

200 `{ok:true}`; 400 `{error:"invalid id"}`; 502 `{error:"storage failed"}` (delete did not happen — the document will reappear). Client (`brainDeleteDoc`, app.js:85454) swallows errors, removes the id from the local `off` set, refetches, re-renders. There is **no confirmation dialog** on the web (row `✕` deletes immediately).

### 4.4 `POST /api/brain/search` (server.mjs:9103–9173)

Request fields:

| Field | Type | Default / limits | Notes |
| --- | --- | --- | --- |
| `q` | String | sliced to 4,000 | may be `""` in `all`/`overview` modes |
| `k` | Int | 8; clamped 1..12 | ranked mode only |
| `docIds` | [String] | `[]` = all docs | invalid ids silently dropped |
| `cid` | String | `""` | idempotent charge key |
| `mode` | `"all"` \| `"overview"` \| absent | absent = ranked search | |
| `offset`, `limit` | Int | 0; 400 clamped 1..1500 | `all` mode only |
| `fromPage`, `toPage` | Int ≥1 | none | page window; swapped if reversed; either alone is fine (`toPage` alone = 1..to) |

Processing order: rate limit → body cap → **charge** → load corpus → filter `docIds` → **scope by page window** → mode.

Responses (all 200):

```json
{"hits":[…],"docs":2,"mode":"search"}                 // ranked: kbSearchIn(k, floor 0.18, keepDigits) + neighbours radius 2, cap k+20
{"hits":[],"docs":0,"mode":"none"}                    // no matching documents (deleted / wrong ids)
{"hits":[],"docs":2,"mode":"range_empty","range":{"from":40,"to":70}}   // window excluded everything
{"hits":[…],"docs":2,"mode":"overview"}               // even stride sample ≤48,000 chars
{"hits":[…],"total":2140,"offset":0,"mode":"all"}     // corpus in document order, paged
```

Errors: 403 signin_required; 429 `{error:"too many requests"}` (120/min); 413 `{error:"too_large"}`; 429 quota bodies from §2.3.

Important: `mode:"none"` is what a deleted document returns — the client treats zero hits as "nothing found", but callers that cache (formula sheet) deliberately do not cache a `none` result (app.js:84005–84016).

### 4.5 `POST /api/brain/whole` (server.mjs:8974–9101) — members only

Request: `{"q":"…≤4000","docIds":[…] (or "docs"),"cid":"…","mode":"outline"|"quiz"|"harvest"|"compare"|"" ,"fromPage":40,"toPage":70}`.

Responses:

```json
{"answer":"…markdown with [page 42] markers…","docs":1,"pieces":2140,"chars":1450000,"mode":"whole","kind":"outline"}
{"answer":"","docs":0,"mode":"none"}
{"answer":"","docs":1,"mode":"range_empty","range":{"from":40,"to":70}}
```

Errors: 401 `{error:"authentication required"}`; 403 `{error:"signin_required",feature:"brain_whole"}` (guest); 503 `{error:"not_configured",feature:"brain_whole"}` (no MiniMax key); 429 `{error:"rate_limited"}` (6/min); 400 `{error:"invalid JSON body"}` / `{error:"bad_request"}` (empty q); 413 `{error:"too_large",chars:3100000,cap:2600000}`; 502 `{error:"engine_failed"}`; 429 quota (§2.3).

Non-streaming; the server sends the *entire* corpus as `[page N] text` lines to MiniMax (`MINIMAX_MODEL` default `MiniMax-M3`, maxTokens 8192, temperature 0.3; server.mjs:6891–6900, 9083–9095). The answer cites with bracketed markers `[page 42]` (or the doc's unit word). The system prompt is server-side (server.mjs:9081–9095); the client never sends it.

### 4.6 `GET /api/brain/passage?doc=<id>&i=<ci>&w=<0..5>` (server.mjs:9175–9204)

```json
{"docId":"bd…","title":"…","kind":"pdf","unit":"page","page":42,"label":"","ci":517,
 "text":"…the cited chunk…",
 "before":[{"ci":515,"t":"…"},{"ci":516,"t":"…"}],
 "after":[{"ci":518,"t":"…"},{"ci":519,"t":"…"}]}
```

`w` default 2. Neighbours stop at a page boundary (same `page` only). 400 `{error:"invalid id"}`; 404 `{error:"not found"}` (doc gone or `ci` out of range). Client always calls with `w=2` (app.js:90040).

### 4.7 `POST /api/chat` as used by Brain

Brain never sends `product:"brain"` on the wire. The two helpers (`callAgentText` app.js:38813, `streamAgentText` app.js:38858) POST to `CONFIG.BACKEND_URL = "/api/chat"` (app.js:16):

```json
{"messages":[{"role":"system","content":"…"},{"role":"user","content":"…","images":["<raw base64 jpeg>"]}],
 "tier":"pro","think":false,"nomem":true}
```

- `tier`: `"mini"|"pro"|"ultra"|"max"`; unknown → `"pro"` (server.mjs:12767). Brain uses `"pro"` for OCR, harvest, exam and the answer stream (or `"mini"` when the user's global tier is mini), `"mini"` for query expansion.
- `nomem:true` = internal helper: never saved to a chat, never charged to the product meter (members), charged to `internal` for guests (`guestChargeWithReq(req, guestId, "internal", payload.cid, payload.messages)`, server.mjs:12877), and the admin knowledge base is never injected (server.mjs:12780–12790, 12857–12872). Nobody (no cookie at all) → 401 `{error:"authentication required"}` (server.mjs:12741–12745).
- The server **does** recognise `product:"brain"` on `/api/chat` even though the web never sends it: it is one of the conditions that skips KB injection (`payload.product !== "brain"`, server.mjs:12817 — moot under `nomem`), and for a *member, non-nomem* call it selects the `brain` quota bucket (server.mjs:12889; the adjacent comment saying Brain is member-only is stale — for a guest non-nomem call `product:"brain"` falls through to the `ai` bucket, 180/day). Native rule: keep every Brain helper call `nomem:true` and do not add `product:"brain"` without it, or a member's `quota.brain` is incremented a second time per answer. A `nokb:true` flag also exists to suppress KB injection explicitly (server.mjs:12817).
- `images`: array of raw base64 strings (no `data:` prefix) on a **user** message; vision is decided by the latest user message only (server.mjs:462–470); ≤10 images/request, each ≤8 MB base64. Brain sends exactly **one image per request** because overflow is silently dropped (app.js:85327–85329).
- Response: `text/event-stream`, OpenAI-style deltas (server.mjs:2793, 2811):

```
data: {"choices":[{"delta":{"content":"يُعرَّف "}}]}

data: {"choices":[{"delta":{"content":"التناضح"}}]}

data: [DONE]
```

The client concatenates `choices[0].delta.content`, stops at `[DONE]`, and treats the finished text as an **error** if `isEngineBusyText` matches (empty, or <400 chars matching `/(engine|vision engine)\s+is\s+(busy|off|offline|unavailable|idle)|جميع\s*المحركات|المحرك\s*مشغول|غير\s*متاح\s*(حالي|الآن)|حاول\s*(مرة\s*أخرى|لاحق|ثاني)|try\s+again\s+shortly/i`, app.js:38846–38850) → `Error("engine-unavailable")`. An aborted stream keeps its partial text on `err.__partial`.

### 4.8 Server-side "brainask" job (server.mjs:11702–11765) — available, unused by the web

`POST /api/chat/job` accepts `kind:"brainask"` (server.mjs:12629) with `{messages|task, docIds (≤20), lang:"ar"|"en", cid}`. The worker calls `handleBrainSearch` with `k:10`, builds numbered excerpts (24,000-char budget), asks `llmComplete` (3,000 tokens, temp 0.2) with a citation-required system prompt, and stores `cr._answer` (headings demoted). Empty hits → `ما لكيت شي بملفاتك يجاوب على هذا السؤال.` / `I could not find anything in your files that answers this.` (server.mjs:11729–11731). Grep of app.js shows the web client never uses it; it is a candidate for a native "answer survives backgrounding" path, but it lacks the `firas-sources` fence, page-window, overview/quiz/harvest modes, and the client-side citation renumbering — the native app would have to reconstruct sources from the answer's `(page N)` labels. Background-jobs details belong to the jobs analyst.

### 4.9 Chats

A Brain conversation is an ordinary chat with `brainNb:true`. The flag is written **only** on `POST /api/chats` (server.mjs:2595–2597); `handleUpdateChat` never writes product flags, so a chat created without it can never become a Brain notebook. Client stamps `chat.brainNb = true` before the first persist (app.js:86718) and lists chats by `c.brainNb` when the product is Brain (app.js:15932). Title: first 42 chars of the question + `…` (`titleFrom`, app.js:13327), then `autoTitleChat`. Messages pushed: `{role:"user", content:q, lang, tier}` and `{role:"assistant", content:<answer + fence>, lang, tier}` (app.js:86720, 86732).

---

## 5. Library UI (rail)

Source: `renderBrainWorkspace` (app.js:87147), `brainRenderRail` (app.js:87472–87662).

### 5.1 Strings (app.js:80920–81203). Arabic left, English right.

| Key | ar | en |
| --- | --- | --- |
| heroT | `اسأل ملفاتك` | `Ask your files` |
| heroP | `ارفع ملفاتك واسأل عنها — كل معلومة في الجواب موثّقة بالصفحة اللي جات منها.` | `Upload your documents and ask — every claim in the answer is cited to the page it came from.` |
| sources | `المصادر` | `Sources` |
| srcHead | `مصادرك` | `Your sources` |
| add | `إضافة ملفات` | `Add files` |
| addHint | `PDF، Word، PowerPoint، Excel، نصوص، وصور` | `PDF, Word, PowerPoint, Excel, text and images` |
| noSrc | `ما في مصادر بعد` | `No sources yet` |
| noSrcHint | `ارفع أول ملف لتبدأ` | `Upload your first file to begin` |
| ask | `اسأل عن ملفاتك…` | `Ask about your files…` |
| askNoSrc | `ارفع ملفًا أولًا` | `Upload a file first` |
| send | `إرسال` | `Send` |
| stop | `إيقاف` | `Stop` |
| page / slide / sheet / section | `صفحة` / `شريحة` / `ورقة` / `قسم` | `p.` / `slide` / `sheet` / `section` |
| indexing / reading / ocr | `يفهرس` / `يقرأ` / `يقرأ الصفحات المصوّرة` | `Indexing` / `Reading` / `Reading scanned pages` |
| uploading / done | `يرفع` / `تمّت الفهرسة` | `Uploading` / `Indexed` |
| ocrToggle | `اقرأ بالرؤية (أدق للملفات العربية والمصوّرة — أبطأ)` | `Read with vision (better for Arabic & scanned files — slower)` |
| dropHere | `أفلت الملفات هنا` | `Drop files here` |
| unsupported | `نوع ملف غير مدعوم` | `Unsupported file type` |
| readFail | `تعذّرت قراءة الملف` | `Couldn't read the file` |
| noText | `ما لقيت نص في هذا الملف` | `No readable text in this file` |
| limitDocs | `وصلت الحد الأقصى للمستندات` | `Document limit reached` |
| limitPages | `وصلت حدّ الصفحات اليومي` | `Daily page limit reached` |
| usageDocs / usagePages | `المستندات` / `صفحات اليوم` | `Documents` / `Pages today` |
| usageFull | `امتلأت المكتبة — احذف مستندًا لإضافة غيره` | `Library is full — delete a document to add another` |
| tooLarge | `الملف كبير جدًا` | `File too large` |
| offHint | `مستبعد من البحث` | `excluded from search` |
| ocrCap(n,total) | `قرأت ${n} صفحة مصوّرة من ${total} — الباقي بقي بنصّه المستخرج` | `Read ${n} of ${total} scanned pages — the rest kept their extracted text` |
| ocrPartial(n,total) | `توقّفت الرؤية عند ${n}/${total} — حُفِظ ما قُرئ والباقي بنصّه المستخرج` | `Vision stopped at ${n}/${total} — kept what it read; the rest use their extracted text` |
| visionOut | `حصة القراءة بالرؤية انتهت اليوم — الملف انفهرس بنصّه المستخرج فقط` | `Today's vision budget is spent — the file was indexed from its extracted text only` |
| pinLbl / pinAdd / pinDrop / pinClear | `مثبّت` / `ثبّت هذا المستند` / `إزالة التثبيت` / `إزالة التثبيت عن الكل` | `Pinned` / `Pin this document` / `Unpin` / `Clear all pins` |
| pinWhy | `المستند المثبّت يبقى داخل البحث في كل محادثة، والملفات الجديدة تبقى خارجه حتى تضمّها بنفسك.` | `A pinned source stays in the search in every chat; files added later stay out of it until you add them yourself.` |
| sum / sumTip | `لخّص المستند` / `خريطة للمستند: أقسامه بترتيبها وأهم ما في كل قسم، وكل نقطة موثّقة بصفحتها` | `Summarize` / `A map of the document: its sections in order and what each one says, every point cited to its page` |
| sumAsk(n) | n>1 `لخّص لي هذي المستندات` else `لخّص لي هذا المستند` | `Summarize these documents` / `Summarize this document` |
| OCR-all-empty toast (app.js:85358–85360) | `تعذّرت قراءة هذا الملف الآن — محرّك القراءة مشغول. جرّب رفعه مجددًا بعد دقائق.` | `Could not read this file right now — the reading engine is busy. Try uploading again in a few minutes.` |

Kind tags (`brainKindTag`, app.js:81209): `PDF`, `DOC`, `PPT`, `XLS`, `IMG`, `TXT` — never translated.

### 5.2 Layout and behaviour

- **Top bar**: title `heroT`; count `"<active>/<total>"` (active = docs not in `off`); buttons (hidden when nothing active): Formulas, Tables, Summarize (app.js:87498–87506). Formulas and Tables are additionally withheld for guests and below 900 px (`brainFmlOffered` app.js:84031, `brainTablesOffered` app.js:82767); Summarize is offered to everyone with ≥1 active doc. Summarize and the Compare chip are `disabled` while `asking`; Tables is deliberately not.
- **Rail header**: `srcHead` + count `"<docs>/<limits.docs>"` (bare count when `limits.docs` missing); class `is-full` when `docs ≥ cap`, `is-near` when `docs == cap−1`; tooltip lines joined by ` · `: `المستندات: 18/20`, `صفحات اليوم: 40/120` (only when `pagesPerDay > 0`, i.e. guests), `usageFull` when full (app.js:87511–87529).
- **Upload control**: file input `accept=".pdf,application/pdf,.docx,.pptx,.xlsx,.xlsm,.txt,.md,.markdown,.csv,.tsv,.json,.xml,.yml,.yaml,.html,.htm,.tex,.srt,.vtt,.log,image/*"`, multiple (app.js:87175); "Read with vision" checkbox (`forceOcr`, memory only); status line = busy items `"<phase> <done>/<total> · <name>"` joined by ` — `, else `addHint` (app.js:87534–87537). Drag-and-drop over the whole workspace shows `dropHere`.
- **Busy row** (per in-flight file): `···` icon, name, meta `"<phase> <done>/<total>"`, progress bar `done/total` (app.js:87549–87561).
- **Empty rail**: files icon + `noSrc` + `noSrcHint`. **Empty thread**: brain icon + `heroT` + `heroP` (app.js:87563–87570, 87700–87708).
- **Document row** (app.js:87572–87660): kind tag · title · meta `"<pages> <unitLabel>" + (ocr ? " · OCR <ocr>" : "") + (off ? " · " + offHint : "")`; classes `is-active`/`is-off`/`is-pinned`; buttons: Terms (only when the device has a term list for it, with count), Coverage (only after a citation landed), Plan, Exam, Pin, Delete `✕`. Row tap toggles selection **unless pinned** (pinned rows ignore the tap). Delete has no confirm.
- **Selection model** (`brainState.off`, app.js:81213–81226): the persisted set is *excluded* ids (`localStorage["firas_brain_sel"]`); a new document arrives selected — unless any pin is live (§5.3). `brainActiveDocIds()` = docs not in `off`, rail order. Default is "all documents".
- Phone (≤900 px): the rail becomes a collapsible horizontal strip, collapsed by default (app.js:87446–87470); Plan/Exam/Formulas/Tables/Coverage buttons are withheld below 900 px (app.js:82226, 83106, 84031, 82767, 84456).
- **Composer** (`brainBindView`, app.js:87306–87470; `brainRenderThread` head, app.js:87664–87690):
  - `<textarea maxlength="4000" rows="1">`; auto-grows to **160 px** max (`brainSyncAsk`, app.js:87248); `dir` follows the **typed content's** language (`detectLang`) and falls back to the UI language when empty; `text-align: start`.
  - Placeholder is `ask` when `brainState.docs.length > 0`, else `askNoSrc` — keyed on the *library* size, not the active count (an all-deselected library still shows `ask`; sending then toasts `noSrc`).
  - **Enter inserts a newline. Ctrl/Cmd+Enter sends.** (Deliberate parity with the main composer — a touch keyboard has no Shift.) **Escape** while `asking` aborts. The Send button doubles as **Stop** (`is-stop`, label `stop`) while `asking` and is never disabled.
  - Compare is read **at send time** (`brainCmpOn()`), not remembered from the chip press.
  - Mic button: the app's single shared dictation recorder pointed at this textarea (`micUse(brainMicTarget(root))`, app.js:87261, 87409–87433) — same `/api/transcribe` path, 5-minute cap, long-press (450 ms) / right-click opens the dialect menu, a second tap while recording finishes it. Hidden when `micSupported()` is false. Tooltip/aria from the **main** table: `micLabel` `إدخال صوتي` / `Voice input`, `micHint` `إدخال صوتي — اضغط مطوّلًا لاختيار اللهجة` / `Voice input — long-press to pick a dialect` (app.js:199–200, 1321–1322). Details belong to the voice/mic analyst.
  - Workspace root `dir` = UI language (app.js:87160); file picker `change` clears `value` before processing so the same file can be re-picked.

### 5.2a Thread rendering (`brainRenderThread`, app.js:87664–87925)

- Empty thread (no messages, no pending) → hero (brain icon + `heroT` + `heroP`).
- Every turn gets `data-turn="<index>"` (message search / jump parity with chat).
- **User turn**: bubble `dir` from `m.lang || detectLang(content)`; text clamped to **12 lines** with a "show more" control (`tclamp capLines:12`, state keyed on a hash of the question so it survives re-renders); hover copy button (`copy` label, toast `copied`/`copyFail`); the same long-press/right-click copy menu as chat (`attachCopyMenu`).
- **Assistant turn**: body `dir` from the answer's language; content = `brainStripSources(m.content)` rendered as Markdown, then `autoDirBlocks` sets `dir` per block (`p, h1–h6, ul, ol, li, blockquote, table, td, th, pre`): LTR only when Latin letters > 1.5 × Arabic letters, else RTL, else the language fallback; then math typeset; then `[Sn]` → chips (§11.1); sources block (§11.2) under the body; copy bar (§11.3) only when not streaming. A comparison (`brainCmpSplit` → exactly 2 parts) renders a two-column grid (`turn--cmp`) with one shared sources block.
- **Pending notice**: appended as an extra `turn--ai fb-pending` block with the notice text; progress ticks retitle that one node.
- **Scroll**: the thread is rebuilt on each render; it follows the tail only if the reader was already within 80 px of the bottom, otherwise the previous `scrollTop` is restored (do not jump on progress updates).
- Streaming paints one live `.md` node (`brainPaintStream`), with a bounded "reveal" animation at 50 ms (`brainEnsureStreamReveal`, app.js:87947); a one-piece answer (whole read, harvest end) is revealed through the same path (`streamBlank`).

### 5.2b Brain strings that live in the main `STR` table (not `brainT()`)

| Key | ar | en | Where used |
| --- | --- | --- | --- |
| `PRODUCTS.brain.name` | `Firas Brain` | `Firas Brain` | product switcher (app.js:59946) |
| `PRODUCTS.brain.tag` | `اسأل ملفاتك — بإجابات موثّقة بالصفحة` | `Ask your files — answers cited by page` | product switcher subtitle |
| wordmark suffix | `Brain` | `Brain` | shell wordmark `Firas Brain` (app.js:59957) |
| landing product chip | `{ name: "Brain", desc: "وثائقك" }` | `{ name: "Brain", desc: "Your documents" }` | app.js:725, 1818 |
| landing feature card | title `فِراس Brain — يجيب من ملفاتك أنت`, desc `ارفع كتبك ومحاضراتك وامتحاناتك — بصيغها المختلفة، حتى المصوّرة — واسأل. الجواب يأتي من داخل ملفك مع اسم الملف ورقم الصفحة، تضغط عليه فيفتح لك النص نفسه.` | title `Firas Brain — answers from your own files`, desc `Upload your books, lectures and past papers — any format, including scans — and ask. The answer comes from inside your file, with the filename and page number; click it and the passage itself opens.` | app.js:737, 1826 |
| `emptyHistoryBrain` | `لا توجد محادثات بعد — ارفع ملفاتك واسأل عنها، والإجابة تجيك موثّقة بالصفحة.` | `No conversations yet — upload your files and ask; every answer cites its page.` | history sidebar empty state when product = brain (app.js:440, 1547, 19093) |
| `askXBrainD` | `يجيب من ملفاتك المختارة، بإجابة موثّقة بالصفحة` | `Answers from your selected files, and names the page` | "Ask elsewhere" menu row for Brain (app.js:402, 1509) |
| `askXNoDocs` | `لا ملف مختار في فِراس Brain — افتحه واختر ملفًا أولًا` | `No file is selected in Firas Brain — open it and pick one first` | app.js:404, 1511 |
| `continueBusy` | `انتظر حتى ينتهي الرد الحالي` | `Wait for the current reply to finish` | cross-product handoff while Brain is busy (app.js:433, 1540) |
| `chatsLoadError` | `تعذّر تحميل المحادثات.` | `Couldn't load conversations.` | `/api/brain/docs` non-403 failure (app.js:956, 2045) |
| `guestFeatureTitle` / `guestFeatureBody` / `guestUpgradeCta` / `guestLater` / `guestLimitReached` | see §1 and §8 | | sign-up overlay |

Chat-list product filter: a Brain notebook is listed only when `state.product === "brain"` (`c.brainNb`, app.js:15932); `newChat` stamps `brainNb: state.product === "brain"` (app.js:13308).

### 5.3 Pins (app.js:81241–81356)

- `localStorage["firas_brain_pin"]` = array of ids, capped 40. Reconciled on every rail render (`brainApplyPins`): pins for deleted docs are dropped; pinned docs are forced *into* selection; while ≥1 pin is live, any document not seen before **arrives excluded** (`pinSeen` is memory-only, seeded on the first render after `/docs` succeeded and non-empty).
- Pin chip above the composer: shows the single pinned title (dir follows the title's language) or the count with `pinLbl`; tooltip = titles joined by `، ` (ar) / `, ` + newline + `pinWhy`; tapping it clears **all** pins (does not re-include what they held out).

---

## 6. Upload and extraction pipeline

`brainUploadFile` (app.js:85406–85448) → `extractBrainPages` (app.js:85277–85370) → `brainSplitPages` (app.js:85373–85392) → POST parts.

### 6.1 Kind detection (`brainKindOf`, app.js:85252)

1. `file.type === "application/pdf"` or name ends `.pdf` → pdf
2. name ends `.docx` → docx; `.pptx` → pptx; `.xlsx`/`.xlsm` → xlsx (extension only — MIME is unreliable)
3. `file.type` starts `image/` → image
4. `isTextFile` (app.js:35919): MIME `text/*` or matches `/(json|xml|javascript|typescript|csv|yaml|x-sh|x-python)/i`, or name matches `CODE_EXT` → text
5. else → `null` → toast `unsupported`, nothing uploaded.

Legacy `.doc/.ppt/.xls` are **not** supported. Title = `file.name` sliced to 200 (falls back to `"document"`).

### 6.2 Per-kind extraction (all produce `[{p, text, l?}]`)

Libraries (all CDN, loaded on first use): pdf.js **3.11.174** from cdnjs (`loadPdfJs`, app.js:35981–35982, worker set), mammoth **1.8.0** and JSZip **3.10.1** from jsDelivr (`brainLib`, app.js:84827–84836). The whole file is read into memory (`file.arrayBuffer()` / `file.text()`); there is no client-side byte cap before the read.

**PDF** (app.js:84749–84763, 85296–85369):
1. Text layer per page via pdf.js `getTextContent` (progress tick every 3 pages, yields to the event loop every 12), reassembled by `brainJoinTextItems` (app.js:84659): group items into lines by baseline (|Δy| ≤ max(2, 0.5·h)), order each line by x (right-to-left when Arabic chars > Latin chars in that line), insert a space only when the horizontal gap > max(1, 0.18·h); then `brainRejoinWrapped` (app.js:84712) joins a line to the next only when it reaches the measured text-block edge in its own reading direction (tol = max(2, 4 % width)), does not end in `[.!?؟۔:;…»”"')\]]`, and the next line does not start like a new item (`/^\s*([A-Z][a-z]|[-*•·]|\d+[.)])/`); hyphen at end of line is removed on join. If <60 % of lines have measurable widths the join is skipped entirely.
2. Vision candidates: `force` (checkbox) OR non-whitespace length < 40 OR `brainArabicQuality(text) < 0.62`. `brainArabicQuality` (app.js:84627): returns 1 if <60 Arabic chars; otherwise starts at 1 and subtracts min(0.55, 3.5·share of single-letter Arabic words), min(0.20, per-1k-chars count of `اا` / 25), min(0.15, per-1k count of `/ا[بتثجحخدذرزسشصضطظعغفقكمنهوي]ل/` / 25), and 0.15 if common function words (`في|من|على|عن|الى|إلى|التي|الذي|هذا|هذه|كان|قال|هو|هي|ما|لا`) are < 2 % of words.
3. Budget: `cap = min(300, limits.visionLeft ?? 300)`. If candidates > cap, pick an **even stride** across the document (not a prefix). Toasts: none affordable → `visionOut`; partial → `ocrCap(todo, scanned)`.
4. OCR each candidate page: rasterize at scale `min(2.8, max(1, 2200/max(w,h)))`, white background, JPEG 0.85, base64; POST to `/api/chat` (§4.7) with tier `"pro"` via the non-streaming `callAgentText`, 3 in flight, **no abort signal** (`brainOcrPage(b64, p, lang, null)` — an upload cannot be cancelled once started); a page whose OCR returns empty (or throws — `brainOcrPage` swallows every error into `""`) keeps its text-layer text. A thrown pass keeps what finished and toasts `ocrPartial(done, todo)`.
5. If **no page** has ≥20 non-whitespace chars after all that → toast the "engine busy" string and abort the upload (`Error("ocr_all_empty")`, app.js:85354–85363) — the document is *not* indexed.
6. Returns `{pages, ocr: <count of pages whose text came from vision>}`.

OCR prompts (app.js:84813–84825), system:
- ar: `أنت محرّك OCR دقيق. انسخ كل ما في صورة الصفحة نسخًا حرفيًّا كاملًا — كل عنوان وفقرة وجدول ومعادلة (الرياضيات بـ LaTeX) وكل رقم، بالترتيب نفسه. لا تلخّص ولا تشرح ولا تترجم ولا تضف شيئًا من عندك. إن كانت الصفحة فارغة فلا تُخرج شيئًا. أعطِ النص المستخرَج فقط.`
- en: `You are a precise OCR engine. Transcribe EVERYTHING on this page image completely and verbatim — every heading, paragraph, table, equation (math in LaTeX) and number, in the original order. Do not summarize, explain, translate or add anything. If the page is blank, output nothing. Output ONLY the transcribed text.`
- user (with the image): ar `انسخ نص هذه الصفحة (رقم ${pageNum}).` / en `Transcribe the text of this page (page ${pageNum}).`
- Language = UI language (`state.lang`).

**Image** (app.js:85285–85293): one page, always OCR (downscale to 2,200 edge, JPEG 0.85), `ocr = text ? 1 : 0`. Phase shows `ocr 0/1 → 1/1`.

**DOCX** (app.js:84904–84942, unit `section`): mammoth → HTML; walk top-level blocks with `brainBlockText` (tables → rows joined `"\n"`, cells joined `" | "`; `ul/ol` → `- `/`n. ` items, nested lines indented two spaces; inline runs buffered, `<br>` ends a line). A `<h1>`–`<h3>` closes the current section (if non-empty) and its text (≤80) becomes the label `l` of the next; a section longer than 4,000 chars is cut at the last `\n`, `. `, `? `, `! `, `؟ `, `۔ ` after position 2,000 (else hard cut) and the continuation keeps the label. Fallback: one page of `textContent`.

**PPTX** (app.js:84944–85081, unit `slide`): slides in **presentation order** (`ppt/presentation.xml` `sldIdLst` resolved through `_rels/presentation.xml.rels`, fallback file-number order); shapes whose placeholder type is `sldNum|dt|ftr` are dropped; one line per `<a:p>` (runs concatenated with nothing between them, `<a:br/>` → space); tables first: one line per row, cells `" | "`, trailing empty cells trimmed; speaker notes (found through the slide's own `.rels` → `notesSlide`) appended after a blank line and the literal label `[ملاحظات المحاضر · Speaker notes]`; label `l` = title/ctrTitle placeholder text (≤80).

**XLSX** (app.js:85083–85250, unit `sheet`): sheets in workbook order via `xl/_rels/workbook.xml.rels`; shared strings with all `<t>` runs joined; booleans `TRUE/FALSE`; formula cells use cached `<v>`; numeric cells whose style is a date format (built-ins 14–22, 45–47, or a custom code with `dmyhs` after stripping literals/brackets/escapes) become `YYYY-MM-DD[ HH:MM[:SS]]` (1900/1904 epochs, Excel's phantom 29-Feb-1900 handled); rows rebuilt from cell references so empty cells stay empty, joined `" | "`, leading space stripped; limits per sheet 20,000 rows / 200,000 cells / 450,000 chars (+ `… [+N more rows not indexed]`), whole workbook 3,000,000 chars; each sheet emitted as several records of ≤700 chars, all with the same `p` = sheet index (1-based) and `l` = sheet name, header line repeated in every part when `header.length × 3 ≤ 700`, a trailing part <60 chars folded into the previous.

**Text** (app.js:85268, unit `page`): fixed 3,000-char blocks, `p` = block number — deliberately dumb so the same file always cites the same block.

### 6.3 Splitting into POSTs (`brainSplitPages`, app.js:85373)

Group consecutive records sharing a `p` (a sheet's parts) and never split a group. Start a new part when adding the group would exceed 700,000 chars **or** 1,000 records. Empty-text records are removed first (`useful`); if none remain → toast `noText`, nothing uploaded.

### 6.4 Phases shown per file (busy row)

`reading` (PDF text layer, ticks every 3 pages) → `ocr d/t` (only when vision runs) → `uploading` (+ ` i/n` when >1 part) → on success toast `${done} · ${title}`; on failure see §4.2 table. Files are processed **sequentially**; `forceOcr` is read once per file.

---

## 7. Ask flow (`brainAsk`, app.js:86697–87145)

### 7.1 Preconditions and turn setup

- Ignored when `q` is empty or a turn is running. If no active docs → toast `noSrc`.
- `cid = uid()` once per turn, shared by the whole-doc call and every search (idempotent charge across fallbacks).
- `lang = detectLang(q)` = `"ar"` if `/[؀-ۿ]/` matches else `"en"` (app.js:2707). Notices follow the **question's** language (`brainTL`), not the UI.
- Page window and its label are captured once (`brainScopeBody()`, `brainScopeLabel()`), so a selection change mid-turn cannot change half the turn.
- Pending notice `thinking` (`يبحث في مصادرك…` / `Searching your sources…`) shown immediately.

### 7.2 Decision tree (in code order)

```
outline  = opts.outline            (Summarize button; never sniffed from text)
compare  = opts.compare            (Compare chip; only honoured when exactly 2 docs active)

wholeKind = guest ? null
          : (compare && 2 docs) ? null
          : outline ? "outline"
          : brainIsQuizQuery(q) ? "quiz"
          : brainIsHarvestQuery(q) ? "harvest"
          : ""                                          // plain question still goes whole-first

if wholeKind != null:                                   // MEMBERS ONLY
    notice wholeReading ("يقرأ المستند كاملًا…" / "Reading the whole document…")
    POST /api/brain/whole {q, docIds, cid, mode: wholeKind, fromPage?, toPage?}
    on 429-with-quota → throw (rendered as quota text)
    on abort → throw
    on any other failure (503/413/502/network/6-per-min 429) → fall through
    if mode == "range_empty" → answer = rangeEmpty(label); return
    if answer non-empty → answer = whole.answer (no sources fence; coverage marked from [page N] markers when exactly 1 doc); return

if !outline && brainIsHarvestQuery(q) → brainHarvest (§7.6); answer = harvested || (scope ? rangeEmpty : noHits); return
if compare && 2 docs → compare path (§7.7); return

quiz      = !outline && brainIsQuizQuery(q)
overview  = !quiz && brainIsOverviewQuery(q)
reasoning = !overview && !quiz && brainIsReasoningQuery(q)
found = (overview||quiz||outline) ? search{q, mode:"overview"} : search{q, k: reasoning ? 12 : 8}
rangeEmpty = found.mode == "range_empty"
if !outline && !overview && !quiz && !rangeEmpty && hits.length < 2:
    notice searching ("يوسّع البحث بلغتين…" / "Widening the search across languages…")
    expanded = brainExpandQuery(q)        // /api/chat tier mini, nomem
    retry search{q: expanded, k: 8}; keep if more hits
if hits.length == 0 && !rangeEmpty: hits = search{q, mode:"overview"}; overview = true
if hits empty → answer = rangeEmpty ? rangeEmpty(label) : noHits
else stream answer with grounding block mode = outline ? "outline" : quiz ? "quiz" : overview ? "overview" : reasoning ? "reason" : "extract"
```

Note the guest-vs-member asymmetry: **members answer whole-document-first for every plain question** (a deliberate product choice at app.js:86735–86755); guests never touch `/api/brain/whole` because its 403 would pop the sign-up overlay on every question (app.js:86754–86761).

### 7.3 Query classifiers (regexes normalise: strip harakat/tatweel, `[آأإٱ]→ا`, `ى→ي`, `ة→ه`)

- `brainIsOverviewQuery` (app.js:85535–85569): for s < 120 chars, STRONG verb `^(?:اشرحلي|اشرح|وضحلي|وضح|لخصلي|لخص|ملخص|اعطني|عطني|نظره\s*عامه|راجع|استعرض|احكيلي|تكلم\s*عن|اقرا)(?![؀-ۿ])` with a document noun `(ملف|مستند|وثيقه|عرض|بريزنتيشن|برزنتيشن|سلايد|شرايح|شريحه|بحث|كتاب|ورقه|محتوي|مذكره|تقرير|كل\s*شي|كله|كلها)` **or** s ≤ 20 chars; WEAK opener `^(?:ماهو|ما\s*هو|ماهي|ما\s*هي|وش|شنو|ايش|عن\s*ماذا|عن\s*ايش|محتوي|فكره)` only with a document noun; English `\b(summar(?:y|ise|ize)|overview|tl;?dr|explain|walk me through|what(?:'s| is) (?:this|it) about|main (?:points|ideas)|key (?:points|takeaways)|outline|gist|go over)\b`; bare `^(?:لخص|اشرح|اشرحلي|وضح|ملخص|summar(?:y|ise|ize)|overview|explain)\s*[.!؟?]*$`.
- `brainIsHarvestQuery` (app.js:85571–85586): Arabic VERB `(استخرج|اجمع|اكتب\s*لي|اعطني|عطني|سو?ي\s*لي|جهز|رتب|اسرد|عدد|حط\s*لي|طلع\s*لي|استخرجلي)` + THING `(تعريف|تعاريف|تعليل|تعاليل|فراغ|فراغات|سؤال|اسئله|مسائل|مساله|قاعده|قواعد|قانون|قوانين|مصطلح|مصطلحات|امثله|مثال|ملاحظ|نقاط|خلاصات)` + (SCOPE `(كل|كافه|جميع|شامل|كامل|الكل|بالكامل|من\s*الاول\s*(?:الى|ل)\s*الاخر)` or a definite plural `(?:^|\s)(?:التعاريف|التعاليل|الفراغات|الاسئله|القوانين|القواعد|المصطلحات)(?![؀-ۿ])`); English `\b(extract|list|collect|gather|compile|give me|write out|pull out)\b` + `\b(all|every|each|complete|full|entire|exhaustive)\b` + `\b(definition|definitions|term|terms|rule|rules|law|laws|question|questions|blank|blanks|example|examples|formula|formulae|formulas|concept|concepts)\b`.
- `brainIsQuizQuery` (app.js:86485–86493): refuses `\b(?:answer|solve)\s+(?:the\s+)?(?:questions?|exercises?)\b|جاوب|أجب|اجب|حلّ?\s*(?:لي\s*)?(?:ال)?(?:أسئلة|اسئلة|السؤال|التمارين)`; matches VERB `(?:سوّ?ي|سويلي|اعمل|إعمل|اعملي|جهّ?ز|حضّ?ر|طلّ?ع|اطلع|اكتب|أنشئ|انشئ|اصنع|ولّ?د|صمّ?م|هات|جيب|أعطني|اعطني|اعطيني|ابي|أبي|بدي|عايز|عاوز|بغيت|أريد|اريد|محتاج|make|create|generate|write|prepare|build|produce|design|give\s*me|i\s*want|i\s*need)` within 45 non-punctuation chars of NOUN `(?:أسئلة|اسئلة|أسالة|اسالة|سؤال|اختبار|امتحان|كويز|فحص|تمارين|تمرين|بطاقات|questions?|quiz(?:zes)?|exam|test|mcqs?|flash\s*cards?|worksheet)`, or `\b(?:quiz|test)\s+me\b|اختبرني|امتحنّ?ي|امتحني|اسألني|اسالني`. (Not normalised.)
- `brainIsReasoningQuery` (app.js:86432–86450): `(?:^|\s)(?:علل|علّل|عللي|ما\s*سبب|السبب|لماذا|ليش|لماذه|عرف|عرّف|عرفلي|تعريف|ما\s*المقصود|ما\s*معني|معني|مفهوم|ما\s*الفرق|الفرق\s*بين|قارن|اعرب|اعربلي|اعراب|استنتج|طبق|كيف\s*نعرف|كيف\s*اعرف|متي\s*نستعمل|متي\s*يكون|اعطني\s*مثال|مثال\s*علي|وضح\s*بمثال)(?![؀-ۿ])` or `\b(define|definition|what is meant by|why (?:is|are|does|do)|reason for|explain why|difference between|compare|derive|how do (?:i|we) (?:know|tell)|give an example|worked example)\b`.
- JavaScript `\b` never matches next to Arabic letters — every Arabic anchor uses `(?![؀-ۿ])`. Reproduce this in NSRegularExpression (`\b` is Unicode-aware there, so behaviour will differ slightly; prefer the explicit lookahead).

### 7.4 Bilingual expansion (`brainExpandQuery`, app.js:86454–86469)

`/api/chat` tier `"mini"` (always mini, regardless of the user's tier), non-streaming `callAgentText`, **no abort signal**, system: `You expand a user's question into SEARCH KEYWORDS for a keyword-matching index. Output ONLY space-separated keywords and short phrases — no sentences, no punctuation, no explanation. Give them in BOTH Arabic and English regardless of the question's language, because the documents may be in either. Include obvious synonyms and the technical/domain term for each concept. Maximum 40 words total.` User = q (≤500). Result: newlines → spaces, ≤600 chars; search query = `q + " " + keywords`. Any failure → original q.

### 7.5 Streaming the answer

- `messages = [{role:"system", content: brainGroundingBlock(hits, lang, mode)}, ...last 8 non-system chat messages]` — assistant history has its fences stripped (app.js:87021–87025).
- `streamAgentText(messages, tier === "mini" ? "mini" : "pro", signal, onDelta)`; paint uses a smooth reveal (50 ms interval, app.js:87947).
- After the stream: `ensureChatItemCount` (app.js:40434) may append missing numbered items when the question asked for N ≥ 3 items — one repair round with the same tier (optional for native).
- **Citation renumbering** (app.js:87050–87062): collect `[S(\d+)]` in first-citation order, keep only cited hits (else the first 3), renumber to `[S1..Sn]`, drop markers with no matching hit (replace with `""`), trim, then append `brainEncodeSources(kept)`.
- Coverage (`brainReadMark`) and term list (`brainGlossHarvest`, skipped for outline) are updated from the decoded sources.

### 7.6 Harvest sweep (`brainHarvest`, app.js:86163–86430)

1. Pull the corpus: loop `POST /api/brain/search {q, docIds, mode:"all", offset, limit:1500, fromPage?, toPage?}` until `hits.length == 0` or `all.length >= total` or offset ≥ 50,000. Empty → `""`.
2. Batch by page, ≤18,000 fresh chars per batch, each batch after the first re-opened with the previous batch's tail (≤3,500 chars, whole chunks); at most 54 batches used.
3. Per batch, contiguous chunks from the same page+title are welded with a single space; pages are emitted as `"(ص N — title)\n" + text` (en `"(p. N — title)"`), or, when the previous page did not end in `[.!?؟۔:؛]["'”»)\]]?\s*$`, inline as `" ⟨ص N⟩ " + text` (en `⟨p. N⟩`).
4. 6 batches in flight, each `/api/chat` tier `"pro"` with the system prompt below and user = the batch body; up to 3 retries with backoff (429 → 8 s·(try+1)+jitter; else 1.2 s·2^try+jitter).
5. Progress notice `harvesting(done,total)` = `يمسح المستند… ${d}/${t}` / `Sweeping the document… ${d}/${t}`; partial output streamed after every finished batch (document order preserved).
6. Assemble: drop `NONE` batches, join `"\n\n"`, `brainCompleteHarvest` (fills clipped items from the corpus), `brainMergeDuplicateItems` (same heading → one entry, variants `(١)(٢)`, pages merged).
7. Footnotes appended (italic): failed batches — ar `_(تعذّرت ${n} دفعة من ${total} (رقم ${span}) — الأجزاء المقابلة من المستند غير مشمولة أعلاه. أعد إرسال الطلب لاستكمالها.)_` / en `_(${n} of ${total} batches failed (${span}) — those parts of the document are NOT included above. Send the request again to retry them.)_`; batch cap — ar `_(توقّف عند ${used} دفعة من ${all} — المستند أطول من حدّ الاستخراج الواحد.)_` / en `_(stopped after ${used} of ${all} batches — the document exceeds one extraction run.)_`; corpus cap — ar `_(قُرئ ${got} مقطعًا من ${total} — المكتبة أكبر من أن تُمسح دفعة واحدة. قلّل عدد الملفات المحدَّدة لتغطيتها كاملة.)_` / en `_(read ${got} of ${total} passages — the library is larger than one sweep. Narrow the selected files to cover all of it.)_`.
8. A harvest answer carries **no** sources fence and no `[Sn]` (page refs are inline `(ص N)`).

Harvest target names (`brainHarvestTarget`, app.js:85588–85610), first match wins: تعليل → `التعاليل (الأسباب)`/`reasons / justifications`; فراغ → `أسئلة الفراغات`/`fill-in-the-blank items`; سؤال → `الأسئلة`/`questions`; قانون → `القوانين`/`formulas / laws`; قاعدة → `القواعد`/`rules`; مثال → `الأمثلة`/`examples`; مصطلح → `المصطلحات`/`terms`; تعريف → `التعاريف`/`definitions`; default `العناصر المطلوبة`/`the requested items`.

Harvest system prompt, Arabic (app.js:86260–86271; `${target}` substituted):

```
أنت مستخرِج نصوص، لا ملخِّص ولا مُعيد صياغة. من المقاطع المعطاة، استخرج **كل** ${target} الواردة فيها، كاملةً غير منقوصة.
١) انسخ نص كل عنصر **حرفيًا** كما ورد، بلا إعادة صياغة ولا اختصار ولا شرح من عندك.
٢) **أين ينتهي العنصر — وهذه أهمُّ قاعدة هنا.** ابدأ من أوّل كلمة في العنصر، واستمرّ في النسخ حتّى تبلُغ أوّلَ حدٍّ من هذه الحدود الثلاثة وحدَها: (أ) بدايةُ العنصر التّالي؛ (ب) عنوانٌ جديد في الكتاب أو انتقالٌ صريح إلى موضوع آخر؛ (ج) نهايةُ المقاطع المعطاة. وكلُّ ما وقع قبل ذلك الحدّ فهو من العنصر ويجب نسخُه: الشروط والقيود والاستثناءات والصيغة الرياضية وخطوات التفسير والمثال المرافق.
٣) **وليست هذه حدودًا:** النقطةُ في آخر الجملة الأولى ليست حدًّا، ورأسُ السطر ليس حدًّا، وانتقالُ الصفحة أو المقطع ليس حدًّا، وطولُ العنصر ليس حدًّا. التوقّف عند أوّل جملة خطأ.
٤) **الجوابُ الطويل هو الجواب الصحيح هنا.** قد يبلُغ آلاف الكلمات، وهذا متوقّع ومطلوب. والقِصَرُ في هذا الطلب علامةُ نقص. وإذا شككتَ في جملةٍ أهي من العنصر أم لا، **فاضممها**.
٥) «حرفيًا» تصف كيف تنسخ لا كم تنسخ، والنسخ متّصل من أوّله إلى آخره: ممنوع «…» وممنوع «إلخ» وممنوع «(بقيّة النص في الكتاب)» وممنوع تخطّي جملة داخل العنصر.
٦) إن كان العنصر ممتدًّا على أكثر من مقطع أو صفحة، **صِلْ أجزاءه في نصٍّ واحد متّصل** ولا تكرّره مجزّأً. ورقمُ الصفحة يتبع العنصر لا العكس: لا تقطع عنصرًا لتجعل لكلّ نصفٍ صفحةً نظيفة. وعلامةُ «⟨ص N⟩» داخل السطر تعني أنّ الصفحة N تبدأ هنا **والكلامُ مستمرٌّ من قبلها**: تجاوزها واقرأ ما قبلها وما بعدها جملةً واحدة، ثمّ استعمل «(ص N–M)» في الاستشهاد.
٧) إن ورد للمصطلح نفسه أكثر من صياغة، **اجمعها تحت عنوان واحد** مرقّمةً (١) (٢)، كلٌّ منها كاملة غير منقوصة.
٨) **الشكل، حرفيًّا:** سطرٌ فيه المصطلح/العنوان بخطٍّ عريض **وحده على سطره** لا شيء معه، ثمّ في السطر التّالي النصّ حرفيًّا، ثمّ في آخره «(ص N)» أو «(ص N–M)» إن امتدّ على صفحات، ثمّ سطرٌ فارغ واحد قبل العنصر التّالي. **لا** تبدأ سطرًا من النصّ بـ ** ، و**لا** ترقّم العناصر ولا تجعلها قائمةً بشُرَط أو نقاط (أمّا القوائم التي في الكتاب نفسه فتُنسخ كما هي داخل النصّ).
٩) إن لم يرد في هذه المقاطع أي عنصر، أخرج كلمة واحدة فقط: NONE
١٠) **لا** تكتب مقدمة ولا خاتمة ولا عناوين أقسام ولا اعتذارًا ولا أي سطر عن غياب عنصر. العناصر فقط.
```

English (app.js:86272–86283):

```
You are a text EXTRACTOR, not a summarizer and not a paraphraser. From the passages given, extract **every** ${target} they contain, complete and unabridged.
1) Copy each item **verbatim** as written — no paraphrase, no shortening, no added explanation.
2) **WHERE AN ITEM ENDS — this is the most important rule here.** Start at the item's first word and keep copying until you reach the FIRST of these three boundaries, and only these: (a) the start of the NEXT item; (b) a new heading in the book, or an explicit change of subject; (c) the end of the passages given. Everything before that boundary belongs to the item and must be copied: the conditions, the constraints, the exceptions, the mathematical form, the steps of the explanation, and the worked example that goes with it.
3) **These are NOT boundaries:** the full stop at the end of the first sentence is not a boundary, a line break is not a boundary, a page or passage break is not a boundary, and the item's length is not a boundary. Stopping at the first sentence is an error.
4) **A LONG ANSWER IS THE CORRECT ANSWER HERE.** It may run to thousands of words, and that is expected and wanted. Brevity in this request is a sign of loss. If you are unsure whether a sentence belongs to the item, **include it**.
5) "Verbatim" describes HOW you copy, not HOW MUCH, and the copy is contiguous from its first word to its last: no "…", no "etc.", no "(rest of the text in the book)", and never skip a sentence inside an item.
6) If an item spans several passages or pages, **join its parts into one continuous text**; never emit it twice in fragments. The page number follows the item, not the reverse: never split an item so that each half gets a clean single-page reference. An inline "⟨p. N⟩" mark means page N begins there **and the sentence continues across it**: read straight through it as one sentence, then cite the span as "(p. N–M)".
7) If the same term has more than one formulation, **group them under one heading**, numbered (1) (2), each one complete and unabridged.
8) **THE FORMAT, exactly:** a line with the term/heading in bold **alone on that line** with nothing else on it, then the verbatim text on the following line, then "(p. N)" at its end — or "(p. N–M)" if it spans pages — then one blank line before the next item. Do **not** start a line of the text with **, and do **not** number the items or turn them into a bulleted or dashed list (lists that are in the book itself are copied as they stand inside the text).
9) If these passages contain none, output exactly one word: NONE
10) Write **no** preamble, no closing remark, no section headings, no apology, and no line noting an absence. Items only.
```

### 7.7 Compare (two documents, app.js:86875–86960)

- Armed by the chip (§10); executed only when exactly 2 docs are active at send time.
- For each doc i: notice `cmpWorking(i+1, 2)` (`يقرأ المستند… ${d}/${t}` / `Reading document… ${d}/${t}`); `POST /api/brain/search {q, k:8, docIds:[id], cid: cid + "-" + i, fromPage?, toPage?}`; empty → overview retry; still empty → column text `rangeEmpty(label)` or `noHits`.
- Stream with grounding mode `"extract"`, tier pro/mini. Column i content = `brainCmpMark(i) + "### " + title + "\n\n" + answer`. Citations kept per column then **renumbered to continue** the previous column's numbering; sources merged into one list.
- Column error handling: if no column stands yet the error propagates; otherwise the column shows `quotaLimitText` (429+quota) or `engineFail`. Abort keeps the partial column (+ `stopped`) and breaks.
- Rendering: a message whose stripped body splits into exactly 2 parts at `firas-cmp` fences renders as a two-column grid with one shared sources list (app.js:87787–87815).

### 7.8 Stop, errors and the finally block (app.js:87087–87145)

- Stop button = `brainState.ctl.abort()` (also Escape in the ask box). An aborted stream keeps its partial text and appends `stopped` (`\n\n_(أُوقف الشرح)_` / `\n\n_(stopped)_`); an aborted whole read with nothing shown renders just `_(أُوقف الشرح)_`.
- Catch mapping (question language):
  - 429 with `data.quota` → `quotaLimitText(lang, quota)` (§8).
  - 403 → `noHits` (quirk: a guest hitting a members-only path reads "nothing found").
  - abort → partial + `stopped`.
  - anything else with partial text → partial + `\n\n_` + `engineFail` + `_`; else `engineFail` (`تعذّر الوصول للمحرّك. حاول مرة أخرى.` / `Couldn't reach the engine. Please try again.`).
- Finally: if the assistant message has content → `updatedAt`, persist chat, finish the reveal, re-render thread (sources block + copy bar), refresh history; `asking=false`, `ctl=null`.

### 7.9 Other strings used in the thread

`noHits` `ما لقيت في مصادرك شيئًا يجاوب على هذا السؤال.` / `I couldn't find anything in your sources that answers this.`; `rangeEmpty(r)` `لا يوجد شيء في هذا النطاق (الصفحات ${r}). وسّع النطاق أو أزله لتشمل بقية المستند.` / `There is nothing in that range (pages ${r}). Widen it or remove it to search the rest of the document.`; `gone` `المقطع لم يعد متاحًا (حُذف المصدر).` / `This passage is no longer available (the source was deleted).`; `matchHint` `أقرب سطر لسؤالك` / `Closest to your question`; copy bar: `copy` `نسخ الكل`/`Copy all`, `copyRefs` `نسخ مع الصفحات`/`Copy with pages`, `copied` `تم النسخ`/`Copied`, `copyFail` `تعذّر النسخ`/`Couldn't copy`, `toPdf` `تحويل إلى PDF`/`Convert to PDF`, `pdfTheme` `هوية المستند`/`Document identity`.

Cross-product handoff (`askXToBrain`, app.js:26896): if Brain is busy → `انتظر حتى ينتهي الرد الحالي` / `Wait for the current reply to finish`; if no active docs → `لا ملف مختار في فِراس Brain — افتحه واختر ملفًا أولًا` / `No file is selected in Firas Brain — open it and pick one first`; else the question is armed for 15 s and asked on the next Brain render.

---

## 8. Quota / limit text (`quotaLimitText`, app.js:6464–6480)

- Guest (`quota.plan === "guest"` or `isGuest()`): returns `STR.guestLimitReached` — ar `انتهت رسائلك المجانية لهذا اليوم كضيف. أنشئ حسابًا مجانيًا للحصول على حدّ أعلى بكثير.` / en `You have used today's free guest messages. Create a free account for a much higher limit.` — and opens the sign-up overlay after 200 ms.
- Member: product name for `brain` = `أسئلة فِراس Brain` / `Firas Brain questions`; text ar:

```
🚦 بلغت الحدّ اليومي من ${name} (${lim}/يوم). يتجدّد تلقائيًا بعد منتصف الليل.

فِراس مجاني بالكامل — هذا السقف موجود ليبقى المحرّك متاحًا للجميع، وهو مرتفع لدرجة أن الاستخدام الطبيعي لا يبلغه.
```

en: `🚦 You've reached today's limit of ${name} (${lim}/day). It resets automatically after midnight.\n\nFiras is completely free — this ceiling only keeps the engine available for everyone, and it is set high enough that ordinary use never reaches it.` (`lim` uses Arabic-Indic digits in ar.)

---

## 9. Grounding prompts (`brainGroundingBlock`, app.js:86495–86651) — verbatim

Passages block, every mode: `body = hits.map((h,i) => "[S"+(i+1)+"] " + title + " — " + unitLabel(unit) + " " + page + (label ? " ("+label+")" : "") + "\n" + text).join("\n\n")`, appended after `المقاطع:` (ar) / `PASSAGES:` (en) plus a blank line. `unitLabel` uses the **UI** language table (`صفحة`/`p.` etc.).

### 9.1 Shared rule blocks

`BRAIN_NO_EMPTY_RULE_AR` (app.js:85481–85496):

```
• عند جمع عناصر (تعاريف، قوانين، أمثلة، مسائل): **اذكر ما وجدته فقط**. إن لم يرد عنصر في مقطع ما فتجاوزه بصمت — **ممنوع** تكتب سطرًا مثل «(لا يوجد تعريف في هذه الصفحة)» أو «غير مذكور». السطر الفارغ ليس نتيجة، وتكراره يفسد الجواب.
• التنسيق: لكل عنصر سطر عنوانه **المصطلح** بخط عريض، وتحته التعريف مباشرةً بلا كلمة «تعريف:» ولا «المصطلح:»، ثم مرجعه [S1]. لا تضع فاصلًا أفقيًا بين العناصر ولا عنوانًا لكل صفحة على حدة — اجمع عناصر الصفحة الواحدة تحت بعضها.
• في النهاية لا تكتب اعتذارًا عن نقص المقاطع إلا إذا لم تجد ولا عنصرًا واحدًا.
• لا ترفض سؤالًا بسبب موضوعه. ما دامت المقاطع تغطّيه — تطوّر، تكاثر، عمر الأرض، تشريح، تاريخ، مقارنة أديان — فأجب عنه علميًا وباحترام. الرفض هنا يخذل طالبًا يقرأ كتابه المقرّر، ولا يحمي أحدًا. القيد الوحيد يبقى المصادر: أجب مما في المقاطع، لا مما في رأيك.
```

`BRAIN_NO_EMPTY_RULE_EN` (app.js:85497–85509):

```
• When collecting items (definitions, rules, examples, problems): **list only what you found**. If a passage contains none, skip it silently — you are **forbidden** to emit lines like "(no definition in this page)" or "not present". An absence is not a result, and repeating it ruins the answer.
• Formatting: one entry per item — the **term** in bold on its own line, the definition directly underneath with no "Term:" or "Definition:" labels, then its reference [S1]. No horizontal rules between entries and no per-page heading; group items from the same page together.
• Do not close with an apology about limited passages unless you found nothing at all.
• Never refuse a question because of its topic. If the passages cover it — evolution, reproduction, the age of the Earth, anatomy, history, comparative religion — answer it scientifically and respectfully. Refusing here fails a student holding their own textbook and protects no one. The only constraint remains the sources: answer from the passages.
```

`BRAIN_ORDINAL_RULE_AR` (app.js:85511–85518):

```
• إذا طلب المستخدم عنصرًا مرقّمًا (التمرين الثاني، السؤال 3، الفقرة الرابعة): انتبه — أرقام العناوين كثيرًا ما تكون مزخرفة في الأصل فلا تظهر في النص المستخرج. ابحث عن الرقم صراحةً؛ فإن لم تجده فالعناصر ترد بترتيبها، فعُدّ **نصوص التكليف** (استخرج، عيّن، اجعل، كوّن، بيّن، أعرب…) من بداية القسم وخذ الذي يوافق الترتيب المطلوب — وانتبه أن التكليف الأول وجوابه قد يكونان في نفس الصفحة قبل التكليف الثاني.
• ابدأ جوابك بنقل **نص التكليف** الذي اعتمدته حرفيًا (مثال: «عيّن التوكيد ونوعه وإعرابه…») ليتأكد المستخدم أنك أخذت العنصر الصحيح. وإن بقي الترتيب ملتبسًا فقل ذلك صراحةً واعرض ما وجدته — **لا تقدّم جواب عنصر آخر وكأنه المطلوب**.
```

`BRAIN_ORDINAL_RULE_EN` (app.js:85519–85527):

```
• If the user asks for a NUMBERED item (the second exercise, question 3, part four): be careful — those heading numbers are often decorative in the original and never reach the extracted text. Look for the number explicitly; if it is absent the items still appear in order, so count the **instruction lines** (extract, identify, form, state, parse…) from the start of the section and take the one at the requested position — note that the first instruction AND its answer may both sit above the second instruction on the same page.
• Open your answer by quoting the **instruction line** you used, verbatim, so the user can confirm you took the right item. If the ordering stays ambiguous, say so plainly and show what you found — **never present another item's answer as though it were the one asked for**.
```

(Each bullet above ends with `\n` in the source; the blocks are concatenated as-is.)

### 9.2 `extract` mode (default). Composition: `rules + "\n\n" + "المقاطع:" + "\n\n" + body`

Arabic rules (app.js:86630–86639):

```
أنت «فِراس برين». أجب **حصريًا** من المقاطع المرقّمة أدناه، وهي مقتطفات من ملفات رفعها المستخدم نفسه.
• لا تستعمل أي معلومة من خارج هذه المقاطع، ولا تخمّن، ولا تُكمل من معرفتك العامة.
• ذيّل كل جملة أو معلومة بمرجعها هكذا: [S1]، أو [S2][S3] إن جاءت من أكثر من مقطع.
• إن كانت المقاطع لا تحتوي الإجابة، قل ذلك صراحةً في جملة واحدة ولا تؤلّف شيئًا.
• اكتب بلغة سؤال المستخدم مهما كانت لغة المستند، منظّمًا وواضحًا، بلا مقدمات عن «المقاطع» أو «المصادر المرفقة».
• إذا كان المصدر يحوي جدولًا، أعد إنتاجه كـ **جدول Markdown حقيقي** (بأسطر | ... | ...) بنفس الأعمدة والصفوف والترتيب. **ممنوع** تضعه داخل كتلة كود (```) وممنوع تصفّه بمسافات — المسافات تنهار ويضيع الجدول.
<BRAIN_ORDINAL_RULE_AR><BRAIN_NO_EMPTY_RULE_AR>• لا تكتب قسم مصادر في النهاية — الواجهة تعرضه تلقائيًا.
```

English (app.js:86640–86648):

```
You are Firas Brain. Answer EXCLUSIVELY from the numbered passages below, which are excerpts from files the user uploaded.
• Use nothing outside these passages. Do not guess, and do not fill gaps from general knowledge.
• End every sentence or claim with its reference, like [S1], or [S2][S3] when it draws on more than one.
• If the passages do not contain the answer, say so plainly in one sentence and invent nothing.
• If the source contains a table, reproduce it as a **real Markdown table** (| ... | ... | rows) with the same columns, rows and order. You are **forbidden** to put it inside a code fence (```) or to align it with spaces — spacing collapses and the table is destroyed.
<BRAIN_ORDINAL_RULE_EN><BRAIN_NO_EMPTY_RULE_EN>• Reply in the user's language whatever the document's language is, organized and clear, with no preamble about “the passages” or “attached sources”.
• Do NOT write a sources section at the end — the interface renders one automatically.
```

### 9.3 `reason` mode. Composition: `rs + "\n" + NO_EMPTY + "\n" + "المقاطع:" + "\n\n" + body`

Arabic (app.js:86577–86589):

```
أنت «فِراس برين»، وأمامك مقاطع من ملفات المستخدم. هذا السؤال يطلب **فهمًا وتطبيقًا**، لا نقلًا.

**المطلوب منك:**
• استخرج القاعدة أو التعريف من المقاطع، ثم **طبّقه واستنتج الجواب**. التفكير مطلوب هنا لا ممنوع.
• إن كان التعريف موزّعًا على أكثر من موضع، **اجمعه في تعريف واحد متماسك** بأسلوبك.
• في التعليل: اذكر القاعدة أولًا، ثم اربطها بالحالة خطوة بخطوة حتى يظهر السبب.
• في الإعراب: أعرِب فعلًا وفق قواعد الملف، ولا تكتفِ بنقل قاعدة عامة.
• أعطِ مثالًا من الملف إن وُجد؛ وإن لم يوجد فصُغْ مثالًا **على القاعدة نفسها** وقل إنه توضيحي.

**الحدّ الذي لا يُتجاوز:**
• كل **قاعدة أو معلومة** تبني عليها لازم تكون من المقاطع، وتذيّلها بمرجعها هكذا [S1].
• الاستنتاج مسموح، لكن **لا تأتِ بقاعدة من خارج الملفات**.
• إن تجاوزت ما هو منصوص، قلها صراحةً: (استنتاج مبني على [S2]).
• إن لم تكفِ المقاطع فعلًا، قل ما الذي ينقص بالضبط بدل رفض الإجابة.
• اكتب بلغة السؤال، منظّمًا. ولا تكتب قسم مصادر — الواجهة تعرضه تلقائيًا.
```

English (app.js:86590–86602):

```
You are Firas Brain. The passages below come from the user's files, and this question asks you to **understand and apply**, not to quote.

**What is expected:**
• Find the rule or definition in the passages, then **apply it and work the answer out**. Reasoning is required here, not forbidden.
• If a definition is spread across several places, **assemble it into one coherent definition** in your own words.
• For a "why": state the rule first, then connect it to the case step by step until the reason is visible.
• For parsing or analysis: actually perform it using the file's rules; do not restate a general rule and stop.
• Use an example from the file if there is one; if not, construct one **on the same rule** and label it illustrative.

**The line you may not cross:**
• Every **rule or fact** you build on must come from the passages, cited as [S1].
• Inference is allowed, but **never import a rule from outside the files**.
• When you go beyond what is stated, say so plainly: (inference based on [S2]).
• If the passages genuinely fall short, say exactly what is missing instead of refusing.
• Reply in the question's language, organized. Do NOT write a sources section — the interface renders one.
```

### 9.4 `overview` mode. Composition: `ovRules + "\n\n" + "المقاطع:" + "\n\n" + body` (ORDINAL and NO_EMPTY are embedded inside `ovRules`)

Arabic (app.js:86612–86622):

```
أنت «فِراس برين». المقاطع أدناه مقتطفات موزّعة على كامل ملفات المستخدم (من أولها إلى آخرها)، وليست نتائج بحث موجّهة.

**طريقة الشرح — إلزامية:**
• امشِ على المستند **بالترتيب من أوله إلى آخره**، ولا تقفز ولا ترتّب المحتوى من عندك.
• قسّمه إلى أقسام بعناوين فرعية (`##`) حسب أقسامه الحقيقية، واذكر أرقام الصفحات/الشرائح في العنوان.
• تحت كل عنوان اشرح **كل** ما ورد في تلك الصفحات: الأرقام، التواريخ، الأسماء، القيم، النتائج، التفاصيل الطبية أو التقنية — بجُمل كاملة تشرح المعنى، لا برؤوس أقلام مبتورة.
• **ممنوع** تختصر المستند في بضع نقاط أو تكتفي بالعناوين. إن كان المستند طويلًا فالجواب لازم يكون طويلًا بنفس القدر. لا تتوقّف في المنتصف ولا تقل «وهكذا» أو «إلخ».
• لا تحذف شيئًا لأنك رأيته «غير مهم» — المستخدم طلب الشرح، والقرار له لا لك.

**القواعد الثابتة:**
• كل ما تقوله لازم يكون من هذه المقاطع فقط. لا تضف معلومة من خارجها ولا تخمّن.
• ذيّل كل معلومة بمرجعها هكذا: [S1]، أو [S2][S3] إن جاءت من أكثر من مقطع.
• إن كان المطلوب غير موجود في المقاطع، قل ذلك صراحةً — لكن لا تقل «لم أجد» لمجرد أن الصياغة مختلفة.
• إذا كان المصدر يحوي جدولًا، أعد إنتاجه كـ **جدول Markdown حقيقي** (بأسطر | ... | ...) بنفس الأعمدة والصفوف والترتيب. **ممنوع** تضعه داخل كتلة كود (```) وممنوع تصفّه بمسافات — المسافات تنهار ويضيع الجدول.
<BRAIN_ORDINAL_RULE_AR><BRAIN_NO_EMPTY_RULE_AR>• اكتب بلغة سؤال المستخدم مهما كانت لغة المستند. لا تكتب قسم مصادر في النهاية — الواجهة تعرضه تلقائيًا.
```

English (app.js:86623–86634):

```
You are Firas Brain. The passages below are excerpts sampled across the ENTIRE set of the user's files, first page to last — not targeted search results.

**How to explain — mandatory:**
• Walk the document **in its own order, front to back**. Do not skip around or re-organize it into your own scheme.
• Break it into sections with `##` sub-headings that follow the document's real sections, and put the page/slide numbers in each heading.
• Under each heading explain **everything** those pages contain — figures, dates, names, values, findings, the clinical or technical detail — in full sentences that convey the meaning, not clipped bullet fragments.
• You are **forbidden** to compress the document into a handful of points or to list only headings. A long document demands a correspondingly long answer. Never stop halfway and never write "and so on" or "etc."
• Do not drop anything because you judged it unimportant — the user asked to be walked through it; that call is theirs, not yours.

**Standing rules:**
• Everything you say must come from these passages only. Add nothing from outside them and do not guess.
• End every claim with its reference, like [S1], or [S2][S3] when it draws on more than one.
• If something asked for genuinely is not in the passages, say so — but do not claim you found nothing merely because the wording differs.
• If the source contains a table, reproduce it as a **real Markdown table** (| ... | ... | rows) with the same columns, rows and order. You are **forbidden** to put it inside a code fence (```) or to align it with spaces — spacing collapses and the table is destroyed.
<BRAIN_ORDINAL_RULE_EN><BRAIN_NO_EMPTY_RULE_EN>• Reply in the user's language whatever the document's language. Do NOT write a sources section — the interface renders one.
```

### 9.5 `outline` mode (Summarize button). Composition: `ol + "\n" + NO_EMPTY + "\n" + "المقاطع:" + "\n\n" + body`

Arabic (app.js:86608):

```
أنت «فِراس برين». المقاطع أدناه عيّنة مأخوذة من **كامل** مستندات المستخدم بترتيبها، من أول صفحة إلى آخرها. المطلوب **خريطة للمستند**: ماذا فيه، بأي ترتيب، وأين. ليس شرحًا مطوّلًا ولا جوابًا عن سؤال.

**الشكل — إلزامي:**
• ابدأ بسطر واحد فقط: ما هو هذا المستند وموضوعه ومداه. سطر واحد بلا عنوان.
• ثم امشِ على المستند **بترتيبه هو**، وقسّمه إلى أقسامه الحقيقية كما وردت فيه لا كما ترتّبها أنت.
• كل قسم عنوان `##` فيه اسم القسم ثم نطاق صفحاته بين قوسين، هكذا: `## اسم القسم (ص 4-9)`. استعمل وحدة المصدر نفسها كما جاءت في المقاطع (صفحة / شريحة / ورقة)، وخذ الأرقام من المقاطع — **لا تخترع رقمًا**.
• تحت كل عنوان من 2 إلى 5 نقاط، كل نقطة جملة كاملة تحمل **معلومة فعلية**: رقم، اسم، تعريف، نتيجة، خطوة، قرار. ممنوع النقاط الفارغة مثل «يتناول هذا القسم عدة مواضيع»، وممنوع إعادة كتابة العنوان بصياغة ثانية وعدّها نقطة.
• ذيّل كل نقطة بمرجعها هكذا [S1]، أو [S2][S3] إن جاءت من أكثر من مقطع.
• اختم بعنوان `## أهم ما في المستند` وتحته من 3 إلى 6 نقاط: الخلاصات التي لو قرأها أحد وحدها لعرف المستند. وكل واحدة بمرجعها.

**الحدود:**
• لا تُدخل شيئًا من خارج المقاطع ولا تخمّن. إن كان قسم لم تصل منه إلا إشارة، اذكره بعنوانه وقل إن تفاصيله لم ترد، ولا تملأ الفراغ من عندك.
• العيّنة موزّعة على المستند كله: **ممنوع** ينتهي الملخّص عند أول ثلث لأن مقاطعه بدت أغزر. آخر المستند له أقسام مثل أوّله.
• اختصر **داخل** النقطة، لا بحذف أقسام. عدد الأقسام يتبع المستند لا صبرك.
• إن كان في المصدر جدول مهم، قل في نقطة واحدة ماذا يعرض وما أعمدته — ولا تعِد إنتاجه هنا.
• اكتب بلغة طلب المستخدم مهما كانت لغة المستند. ولا تكتب قسم مصادر — الواجهة تعرضه تلقائيًا. ولا مقدمة ولا خاتمة.
```

English (app.js:86609):

```
You are Firas Brain. The passages below are a sample drawn from the **whole** of the user's documents, in order, first page to last. What is wanted is a **map of the document**: what is in it, in what order, and where. Not a long explanation, and not an answer to a question.

**Format — mandatory:**
• Open with a single line: what this document is, its subject, its extent. One line, no heading.
• Then walk the document **in its own order**, split into its real sections as the document has them, not into a scheme of your own.
• Each section gets a `##` heading carrying its name and then its page range in parentheses, like `## Section name (pp. 4-9)`. Use the source's own unit as the passages give it (page / slide / sheet), and take the numbers from the passages — **never invent one**.
• Under each heading put 2 to 5 bullets, each a full sentence carrying a **real fact**: a figure, a name, a definition, a finding, a step, a decision. No empty bullets like “this section covers several topics”, and never restate the heading in other words and count it as a bullet.
• End every bullet with its reference, like [S1], or [S2][S3] when it draws on more than one.
• Close with a `## What matters most` heading and 3 to 6 bullets under it: the takeaways someone could read alone and still know the document. Each one cited.

**Limits:**
• Nothing from outside the passages, and no guessing. If only a mention of a section reached you, name the section and say its detail is not in the passages rather than filling the gap yourself.
• The sample spans the entire document: the outline is **forbidden** to stop at the first third because those passages looked richer. The end of the document has sections just as the beginning does.
• Compress **inside** a bullet, never by dropping sections. The number of sections follows the document, not your patience.
• If the source holds an important table, say in one bullet what it shows and what its columns are — do not reproduce it here.
• Write in the language of the user's request whatever the document's language. Do NOT write a sources section — the interface renders one. No preamble, no closing remark.
```

### 9.6 `quiz` mode. Composition: `qz + "\n" + NO_EMPTY + "\n" + "المقاطع:" + "\n\n" + body`

Arabic (app.js:86527–86546):

```
أنت «فِراس برين»، وأنت الآن **تؤلّف أسئلة** من ملفات المستخدم — لا تُجيب عن سؤال.

**التغطية (أهم قاعدة):**
• المقاطع أدناه مأخوذة من **كامل** المستند بترتيبه. وزّع أسئلتك عليها **كلها** بالتساوي: من أوله ووسطه وآخره.
• ممنوع تكديس الأسئلة على صفحة أو فصل واحد لأنه بدا أغزر. إن كانت المقاطع تغطي عشرة مواضع، فلازم أسئلتك تلمس عشرتها.
• قبل أن تكتب، حدّد بصمت المواضيع الرئيسية في المقاطع، ثم اسحب سؤالًا (أو أكثر) من كل موضوع.

**صياغة السؤال:**
• كل سؤال **لازم تكون إجابته موجودة صراحةً في المقاطع**. لا تسأل عمّا لا تستطيع الإجابة عنه منها.
• اجعل السؤال قائمًا بذاته: من يقرأه دون رؤية المقطع يفهم المطلوب. ممنوع «حسب النص أعلاه» أو «ما المذكور في الفقرة».
• نوّع الأنماط: اختيار من متعدد بأربعة بدائل (أ/ب/ج/د) — وتكون المشتّتات **معقولة** ومن نفس المجال لا عشوائية — وصح/خطأ، وأكمل الفراغ، وإجابة قصيرة، وسؤال تطبيقي/تحليلي يطلب الربط لا الحفظ.
• درّج الصعوبة: يبدأ سهلًا وينتهي بأصعبها.
• ممنوع سؤالان يقيسان نفس المعلومة بصياغتين.

**الشكل:**
• رقّم الأسئلة **1..N متسلسلة** عبر الورقة كلها، ولا تعيد الترقيم عند تغيير النمط.
• إن طلب المستخدم عددًا محدّدًا فالتزم به **حرفيًا**؛ عدّ أسئلتك قبل أن تنهي.
• بعد آخر سؤال اكتب `## نموذج الإجابة`، ثم لكل سؤال بالترتيب: الإجابة الصحيحة + سطر تعليل واحد + مرجعه هكذا [S1].
• لا تكتب قسم مصادر — الواجهة تعرضه تلقائيًا. ولا مقدمة ولا خاتمة.
```

English (app.js:86547–86566):

```
You are Firas Brain, and right now you are **authoring questions** from the user's files — not answering one.

**Coverage (the rule that matters most):**
• The passages below are sampled across the **whole** document in order. Spread your questions over **all** of them — beginning, middle and end.
• Never cluster on one page or chapter because it looked richer. If the passages touch ten places, your questions must touch ten places.
• Before writing, silently list the main topics present, then draw at least one question from each.

**Writing each question:**
• Every question's answer **must be explicitly present in the passages**. Never ask what they cannot answer.
• Make it self-contained: someone who cannot see the passage still understands what is being asked. No "according to the text above".
• Vary the types: multiple choice with four options (A–D) whose distractors are **plausible and from the same domain**, true/false, fill-in-the-blank, short answer, and an applied/analytical item that requires connecting ideas rather than recall.
• Grade the difficulty: start accessible, end with the hardest.
• Never ask the same fact twice in different words.

**Format:**
• Number the questions **1..N continuously** across the whole paper; never restart when the type changes.
• If the user named a count, honour it **exactly**; count your questions before you finish.
• After the last question write `## Answer Key`, then for each question in order: the correct answer + one line of justification + its citation as [S1].
• Do NOT write a sources section — the interface renders one. No preamble, no closing remark.
```

---

## 10. Scope, pins and compare chips (composer row)

### 10.1 Page range (`brainState.range`, app.js:81358–81477)

- Memory only, keyed to the exact active selection (`docIds.join(",")`); any change of selection/pins/library drops it silently. Never persisted.
- Chip label: `scope` (`الصفحات` / `Pages`) when off; when on, `scopePages` (`صفحة` / `pp.`) + value `"from-to"` or `"from+"` (always rendered as an isolated LTR numeric run) + `✕`. Tooltip `scopeHint` `حصر البحث في صفحات معيّنة` / `Limit the search to a page range`. Popover: hint, two plain-text numeric fields (placeholders `من`/`إلى`, `from`/`to`, `maxlength=6`, `inputmode=numeric`), Apply (`تطبيق` / `Apply`), Enter applies, Escape closes, outside click closes; `✕` title `إزالة النطاق` / `Remove range`.
- Digit folding (`brainScopeDigits`): U+0660–0669 and U+06F0–06F9 → ASCII. Values: both empty → cleared; reversed → swapped; `from` only → `{from, to:0}` (= to the end); `to` only → `{from:1, to}`.
- Wire form (`brainScopeBody`): `{fromPage: from}` plus `toPage` when `to > 0`. Rides on: every ask search (first, bilingual retry, overview fallback), whole-doc, harvest, compare, tables. **Not** on: plan, formula sheet (whole-book by design), exam (own fields).
- `mode:"range_empty"` → `rangeEmpty(label)` text in the thread; no retries.

### 10.2 Compare chip (app.js:81479–81560)

- Hidden when the library has < 2 documents; otherwise shows `cmp` (`قارن مستندين` / `Compare two`), tooltip `cmpTip` (`اسأل سؤالًا واحدًا وشوف جواب كل مستند لحاله بمصادره` / `Ask one question and see each document answer it on its own, with its own citations`).
- Tap with ≠ 2 active docs → toast `cmpTwo` (`اختر مستندين بالضبط من القائمة، ثم اسأل سؤالك` / `Select exactly two documents in the list, then ask your question`); with 2 → armed, toast `cmpOn` (`المقارنة مفعّلة — سؤالك الجاي يروح للمستندين` / `Compare is on — your next question goes to both documents`). The flag self-clears the moment the active count ≠ 2; disabled while asking.

### 10.3 Summarize button — sends `sumAsk(n)` with `{outline:true}`; a set page range applies.

---

## 11. Citations and the passage viewer

### 11.1 In-text chips (`brainDecorateCitations`, app.js:87993–88027)

After Markdown rendering, every text node (outside `code`/`pre`) containing `[S\d+]` is split; each `[Sn]` with a matching source becomes a button showing `n`, title attribute `"${t} — ${unitLabel(u)} ${p}"`, tap → passage viewer. Markers with no matching source are removed, not shown.

### 11.2 Sources block (`brainSourcesBlock`, app.js:89487–89515)

Heading `sources`; one row per pointer: number, title, snippet (`s` ≤160 chars), `"${unitLabel(u)} ${p}" + (l ? " · " + l : "")`; tap → viewer. Rendered under the answer (under both columns for a comparison).

### 11.3 Copy bar (`brainCopyBar`, app.js:89401–89485)

- `copy`: visible text with `\s*[Sn]` removed + `\n\n` + (`المصادر:` for non-en / `Sources:` for en) + lines `"${n}. ${t} — ${unitLabel(u)} ${p}"`.
- `copyRefs` (only when sources exist): `[Sn]` replaced by ` (${unitLabel(u)} ${p})` + the same tail.
- `toPdf`: print/save flow (rasterised, unbranded, ten themes; `brainExportPrint`/`brainExportPdf`, app.js:88042+, 89247). Native: use `UIPrintInteractionController`/share sheet with the rendered attributed text — the web's theme picker is optional.

### 11.4 Passage viewer (`brainOpenPassage(src, asked?)`, app.js:89968–90045)

- Overlay title `t`, subtitle `"${unitLabel(u)} ${p}" + (l ? " · " + l : "")`, close `✕`, Escape closes, tap outside closes.
- Loads `GET /api/brain/passage?doc=${d}&i=${c}&w=2`; renders `before[]` paragraphs (context style), the hit paragraph, `after[]`; scrolls the hit to centre. On any failure renders `s` (the stored snippet) or, if empty, `gone`.
- `brainMarkAnswerSpans(body, question)` (app.js:89674) highlights, deterministically and offline, the 1–2 sentences whose folded term set best overlaps the question (distinct-term coverage, terms present in most sentences ignored, floor scales with question length, ties → nothing). The question comes from the caller (exam/term list) or the chat turn that produced the citation (`brainQuestionForSource`, app.js:89650). Tooltip on the mark: `matchHint`.
- Citation panel toggle (`cite` `اقتباس` / `Citation`): APA and MLA strings built from the file name (`brainCiteStrings`, app.js:89873–89906): title = name minus extension/underscores; year = a 4-digit 19xx/20xx at the start or end of the name (never mid-name, never a span) else `citeNd` (`د.ت` / `n.d.`); medium via `citeMedium(kind)` (`ملف PDF`, `مستند Word`, `عرض PowerPoint`, `جدول Excel`, `صورة`, `ملف نصي`, `مستند` / `PDF file`, `Word document`, `PowerPoint presentation`, `Excel spreadsheet`, `Image`, `Text file`, `Document`); access date = document `ts` formatted `ar-u-ca-gregory-nu-latn` / `en-GB` (only when no year); location = `citeP` (`ص` / `p.`) + page, or the unit label for slide/sheet. Rows: `citeRef` (`المرجع` / `Reference`) and `citeIn` (`داخل النص` / `In-text`), each with `citeCopy` (`نسخ` / `Copy`). Hint `citeHint`: `اقتباس جاهز لتقريرك، مبني على اسم الملف وصفحته — راجعه قبل التسليم.` / `A ready citation for your report, built from the file's own name and page — check it before you hand it in.`

---

## 12. Secondary panels (all device-local except their one retrieval call)

| Panel | Trigger | Data call | Storage key | Notes |
| --- | --- | --- | --- | --- |
| Terms (`gloss`) | row button, shown only when the device has entries | none — harvested from each answer's question terms + cited snippets (`brainGlossHarvest`, app.js:81736) | `firas_brain_gloss` (≤8 docs, ≤30 terms/doc, ≤3 new terms/turn, ≤80,000 bytes) | Entry = term + defining sentence (≤180) + source pointer + question (≤100); tap opens the passage with that question. |
| Study plan (`plan`) | row button (members, ≥900 px) | `POST /api/brain/search {q:"", docIds:[id], cid:"plan"+id, mode:"overview"}` (no page window) | `firas_brain_plan` (≤4 docs, cache) | Splits heading spans across N days (1..30; default from span count); "Refine with Firas" sends `planAsk(title, planSpan(days), body)` as a Brain question; "Limit questions to this day's pages" sets the scope chip → toast `planScoped(r)`. |
| Exam (`exam`) | row button (members, ≥900 px) | `POST /api/brain/search {q:"", docIds:[id], cid: uid(), mode:"overview", fromPage?, toPage?}` then `/api/chat` tier pro with `brainExamPrompt(sample(hits,20), count, ar)` (each passage sliced to `BRAIN_EXAM_HIT_CHARS = 900`, app.js:83090; prompt at app.js:83156–83197 demands JSON only) | none | Defaults count 10 (4..20), minutes 10 (..90), range 1..pages (app.js:83364–83365); JSON `{questions:[{q, choices[4], answer, s, why}]}`; parse drops questions without a resolvable `s`; < min(4,count) usable → `examFail`; `range_empty` → `examEmpty`; missed questions link to their passage with the question text; clock `brainExamClock` renders `"MM:SS"` in ASCII digits inside an LTR-isolated span (app.js:83112). |
| Tables (`tbl`) | top-bar button (members, ≥900 px — `brainTablesOffered`, app.js:82767) | `POST /api/brain/search {q:"", docIds, cid: hash, mode:"all", offset:0, limit:1500, fromPage?, toPage?}` | none | Deterministic table detection over chunk lines (separators ` \| `, tabs, etc.; ≥3 rows; ≥70 % column agreement); CSV copy/download; "Open the page" → passage. |
| Formulas (`fml`) | top-bar button, exactly 1 active doc, members, ≥900 px | paged `mode:"all"` sweep, `limit:1500`, same `cid:"fml"+id` for all pages | `firas_brain_fml` (≤4 docs, cache) | Deterministic equation line detection; dedup with occurrence counts; not scoped by the page window. |
| Coverage (`cov`) | row button after the first citation | none | `firas_brain_read` (docId → sorted cited pages; in the settings KEEP set) | Bar of cited runs, `covPct`, `covSeen(n,total,unit)`, widest gaps with "limit questions to this range" arrows. Fed by every answer's sources and by `[page N]` markers of a single-doc whole read (app.js:86784–86807). |

These are additive; the native MVP can ship without them (recommended order: coverage → terms → exam → plan → tables → formulas).

---

## 13. Device persistence keys (web) and their native equivalent

| Key | Content | Native |
| --- | --- | --- |
| `firas_brain_sel` | JSON array of **excluded** doc ids | `@AppStorage`/UserDefaults per account id (keep excluded semantics so a new doc arrives selected) |
| `firas_brain_pin` | JSON array of pinned ids (≤40) | UserDefaults; apply the §5.3 reconciliation on every library load |
| `firas_brain_gloss`, `firas_brain_plan`, `firas_brain_fml`, `firas_brain_read` | see §12 | Application Support JSON files or SwiftData; only `read` is "content" |
| memory only | `range`, `cmp`, `forceOcr`, `pinSeen`, `busy`, `asking`, `ctl` | `@Observable` store state |

Guest identity note: everything above is keyed by device, not by account, on the web; a native app should namespace by the session's identity id.

---

## 14. Guest behaviour summary

- May upload (3 docs, 120 distinct pages/day), search, read passages; each answer costs one of 120/day (+480/day per network).
- Never calls `/api/brain/whole` (client skips it; server would 403 → sign-up overlay).
- OCR/expansion helper calls draw on `internal` 300/day and the 30/min chat rate limit; harvest concurrency 6 will hit 30/min — the web relies on 429 retries with 8 s backoff.
- The rail/top bar hide Plan/Exam/Formulas/Tables for guests (`brainPlanOffered`/`brainExamOffered`/`brainFmlOffered`/`brainTablesOffered`, app.js:82226, 83106, 84031, 82767); Coverage, Terms, Summarize, Compare, pins and the page range are allowed.
- Guest identity is minted by `POST /api/guest` at boot (`startGuestSession` app.js:46958, `resumeGuestIfActive` app.js:79984, `refreshUser` app.js:46849); Brain itself never mints it. A member session (`firas_session`) always wins over the guest cookie (`callerOf`, server.mjs:1314).
- Library is lost when the guest cookie is lost; swept after 14 idle days.
- The `docs` counter shows `n/3`; the rail tooltip shows `صفحات اليوم: used/120`.

---

## 15. Native implementation spec

### 15.1 What runs on-device vs server

| Step | Web | Native recommendation |
| --- | --- | --- |
| PDF text layer | pdf.js + custom line reassembly | **On-device**: PDFKit. `PDFPage.string` returns text in PDFKit's reading order; for Arabic textbooks verify against the §6.2 quality gate. If ordering is poor, rebuild lines from `PDFSelection`s per line (`page.selection(for: rect)` / `selectionForLine(at:)`) using the same baseline-grouping + RTL ordering + gap rule. Keep the wrapped-line rejoin rule. |
| Scanned/garbled page OCR | `/api/chat` vision (Gemini/Ollama), 3 in flight, site-wide daily budget | **On-device first**: `VNRecognizeTextRequest` (`.accurate`, `recognitionLanguages ["ar","en-US"]`, `usesLanguageCorrection true`) on a 2,200-px render (`PDFPage.thumbnail`/`draw(with:to:)`). Free, offline, unmetered. Fall back to server vision only when Vision returns fewer than ~20 characters on a page that visibly has ink, and only within `limits.visionLeft`. Keep the even-stride selection and the 300/document cap for the server path. |
| Image kind | server vision | On-device Vision, same request. |
| DOCX/PPTX/XLSX | JSZip/mammoth in the browser | **On-device**: existing `OfficeDocumentExtractor` (ZIPFoundation) — but bring it to parity with §6.2 (heading sections, 4,000-char sentence-aware split, table/list rendering, slide order via rels, notes label, dropped placeholders, shared-string runs, date styles, 700-char row groups with repeated header, runt fold). |
| Text | 3,000-char blocks, unit page | On-device; match 3,000 and unit `page` (current Swift uses 12,000 and `section` — see §17). |
| Chunking/indexing, retrieval, passage, whole-doc read, answer generation, query expansion | server | Server, unchanged (§4). Query expansion could later move to Apple Foundation Models but keep parity now. |
| Classifiers, grounding block assembly, citation renumbering, sources fence, copy text, cite strings, answer-span highlight, coverage, terms, plan splitting, tables, formulas | client JS | Port to Swift as pure functions (all deterministic; regexes in §7.3 must use explicit Arabic lookaheads). |

The `ocr` field semantics: on the server `ocr` is (a) shown in the rail meta and (b) **charged against the site-wide Gemini budget** (`brainVisionCharge`, server.mjs:8468). Pages OCR'd on-device must **not** be reported in `ocr` (send only pages that went through server vision), or the shared `visionLeft` will be decremented for work the server never did. Track on-device OCR count locally if you want the "OCR n" badge (see open questions).

### 15.2 Suggested Swift architecture

- `BrainLibraryStore` (@Observable, @MainActor): `docs`, `limits`, `used`, `guest`, `excluded: Set<String>`, `pins: Set<String>`, `pinSeen`, `busy: [UploadProgress]`, `range: PageRange?` (keyed by `activeIDs.joined(",")`), `compareArmed`, `forceOCR`; `activeDocIDs` = docs order minus excluded; `applyPins()` on every load exactly as §5.3.
- `BrainExtractor` (nonisolated, `Task.detached`): returns `ExtractedDocument { title, kind, unit, pages:[PageRecord], serverOCRPages:Int }`; reports phases `reading(done,total)`, `ocr(done,total)`, `uploading(part,parts)`.
- `BrainUploader`: `splitParts(pages)` (700,000 chars / 1,000 records, groups intact), sequential POSTs, `ocr` on part 1 only, error mapping of §4.2; one file at a time.
- `BrainAsker` (actor): implements §7 exactly — `cid` per turn, whole-first for members, harvest/compare/quiz/overview/reasoning branches, bilingual retry, overview fallback, streaming via the shared SSE client with `nomem:true`, item-count repair optional, renumber + encode sources, abort semantics, error mapping. Emits `pending(String)` notices and `delta(String)` updates; final assistant content includes the fence.
- `BrainAnswerView`: Markdown → `AttributedString`; replace `[Sn]` with tappable inline chips (custom attribute + `onOpenURL`-style handling, e.g. `firas-cite://n`); sources list; copy bar; two-column layout when `brainCmpSplit` yields 2 parts.
- `PassageSheet`: §11.4 (before/hit/after, highlight, cite panel, deleted-source fallback).
- Chat persistence: reuse the app's chat store with `brainNb:true` at creation; product list filter `brainNb`.
- Notices/strings: port the `brainT()` table verbatim into `Brain.xcstrings` (ar/en), keeping the `(n,total)`-style functions as format strings with Arabic agreement rules where the web has them (`tblCut`, `tblSwept`, `fmlTimes`, `fmlN`, `planSpan`, `tblDocs`).

### 15.3 Behavioural parity checklist

1. New document → selected unless a pin is live (then excluded). Pinned rows ignore taps.
2. Range chip drops itself when the selection changes; ranges never persist.
3. Members: whole-doc call first for plain/outline/quiz/harvest questions; guests never call it.
4. One `cid` per turn across whole → search → retry → overview.
5. Keep partial answers on abort/disconnect; never replace shown text with `engineFail` — append it.
6. 403 during ask → `noHits`; 429+quota → quota text (guest → sign-up).
7. Harvest and whole answers carry no sources fence; retrieval answers always do (cited hits, else first 3).
8. Passage viewer must work offline-ish: fall back to `s`, then `gone`.
9. `ocr` only for server-vision pages; never resend on continuation parts.
10. Sequential uploads; a file with zero usable text is not uploaded (`noText`); a PDF whose every page came back empty from OCR is refused with the "engine busy" toast.
11. Only the whole-doc call and the answer stream carry the abort signal on the web; the `/api/brain/search` calls, query expansion and upload OCR do not (they run to completion, then the already-aborted stream throws immediately). Web quirk worth *not* reproducing: Stop pressed during the search phase yields an assistant message whose body is empty and whose fence holds the first 3 hits (app.js:87033–87066) — native should render `stopped` and drop the fence when nothing was written.
12. `k` = 12 for reasoning-classified questions, 8 otherwise; the bilingual retry always uses `k: 8`; compare columns use `k: 8`.

---

## 16. Whole-document and job prompts (server-side, for reference only)

`/api/brain/whole` system prompt (server.mjs:9083–9094; `task` is one of `BRAIN_WHOLE_MODES[mode]` at 9058–9078 or empty):

```
You are reading an ENTIRE document set that is present in full below — not excerpts. Answer using all of it.
<task line, if any>
CITE EVERY CLAIM with the bracketed page marker it came from, exactly as written, e.g. [page 42]. An uncited claim is worthless to a student who has to check it.
If the documents do NOT answer the question, say so plainly and say what they do cover instead. Never fill a gap from your own knowledge — the point of reading this material is that the answer comes from THIS material.
Because you can see everything at once, you may compare distant parts, notice where the text contradicts or refines itself, and say what is absent. That is what you are here for.
Answer in Arabic.            // when q contains Arabic; else "Answer in the language of the question."
```

User: `"QUESTION:\n" + q + "\n\nDOCUMENTS:\n" + corpus` where corpus = per doc `"\n\n===== <title> =====\n"` then `"\n[<unit> <page>] <chunk text>"` per chunk. Client-side coverage parses `/\[\s*(?:page|slide|sheet|section|صفحة|شريحة|ورقة|قسم)\s*([0-9٠-٩]+)\s*\]/gi` from the answer (app.js:86795).

`brainask` job system prompt (server.mjs:11746–11750):

```
You answer ONLY from the numbered excerpts given to you, writing in ARABIC|ENGLISH. Every factual claim must cite the excerpt it came from using its page label exactly as written, like (<first label>). If the excerpts do not contain the answer, say so plainly — never fill the gap from your own knowledge. Do not invent page numbers. NEVER emit a level-1 (#) or level-2 (##) heading.
```

---

## 17. Divergences in the existing Swift code (must fix before parity)

Files: `ios/FirasAI/Features/Brain/BrainDocumentExtractor.swift`, `ios/FirasAI/Features/Brain/OfficeDocumentExtractor.swift`, `ios/FirasAI/Stores/BrainStore.swift`, `ios/FirasAI/Models/BrainModels.swift`, `ios/FirasAI/Features/Brain/BrainScreen.swift`, `BrainStrings.swift`, `Brain.xcstrings`.

| Item | Current `ios/` | Web contract |
| --- | --- | --- |
| Text kind unit / block | `unit: .section`, `chunkText(clean, limit: 12_000)` (BrainDocumentExtractor.swift:151–158) | `unit: "page"`, fixed 3,000-char blocks (app.js:85268) |
| PDF OCR trigger | `page.string` trimmed, OCR only when `text.count < 12`; thumbnail 1,600×2,200 (BrainDocumentExtractor.swift:92–95) | non-whitespace < 40 **or** Arabic quality < 0.62, or force toggle; 2,200-px longest edge |
| PDF page text cap | `prefix(60_000)` per page (BrainDocumentExtractor.swift:111, 138) | none client-side (server caps per doc) |
| Empty pages | pages with empty text are dropped before upload (`guard !text.isEmpty`) | same effect (`useful` filter, app.js:85422) — fine |
| `ocr` reported | `ocrPages` counts **on-device Vision** pages (BrainDocumentExtractor.swift:92–104); sent on part 1 only (BrainStore.swift:89 — correct) | must count only *server*-vision pages (§15.1) |
| Part limits | 680,000 chars / 950 records; **throws** `APIError.invalidRequest("One citable page or sheet is too large to upload safely.")` if one page group reaches either (BrainStore.swift:204–226) | 700,000 / 1,000; never throws — an oversized group simply becomes its own part (app.js:85373–85392) |
| Search | `resultCount: 20` (server clamps to 12), `cid: stableIdentifier()`, `mode: .search`; no overview/expansion fallback, no answer generation (BrainStore.swift:150–160) | §7 |
| Selection | empty set = all docs (`selectedDocumentIDs.isEmpty ? nil : …`) | excluded-set semantics; pins |
| Guests | store refuses unless `session.isAuthenticated` (BrainStore.swift:33, 53, 104, 132) with its own string `سجّل الدخول لإضافة المصادر إلى فِراس Brain.` / `Sign in to add sources to Firas Brain.` — not a web string | guests are first-class (§14) |
| Strings | own ad-hoc ar/en (`BrainStrings.swift`, `Brain.xcstrings`) | port `brainT()` verbatim (§5.1, §7.9, §10, §11, Appendix A) |
| Office extractors | present (OfficeDocumentExtractor.swift) — parity with §6.2 unverified in this pass | §6.2 |

---

## 18. Open questions

1. Should the native app report on-device OCR pages anywhere? The server has no field for "OCR'd locally"; sending them in `ocr` mis-charges the shared vision budget. Options: send `ocr:0` and show a local badge, or ask for a new server field.
2. PDFKit's Arabic text ordering for ligature-broken fonts has not been measured against `brainJoinTextItems`; the §6.2 quality gate should be run on real Iraqi textbooks before deciding whether to bypass `PDFPage.string`.
3. `ensureChatItemCount` (app.js:40434) is shared chat machinery; whether the native chat port implements it decides whether Brain gets it.
4. The `brainask` durable job (§4.8) is unused on the web; using it natively would give background-safe answers but loses the fence/renumbering/mode logic unless the server is extended.
5. The exam score line reuses `qzScoreLine` from the Agent quiz (Arabic count agreement) — that function belongs to the agent analyst's slice; `brainExamClock` (app.js:83112) is just `"MM:SS"` in ASCII digits.
6. `guestChargeWithReq` on the Brain endpoints omits `messages` (§2.3). If the server is ever fixed to pass the body, a native client that reuses one cid across the whole-doc call and the search fallback with *different* `q` strings would start being charged twice; today it is not.

---

## Appendix A — remaining `brainT()` keys, verbatim (app.js:80920–81203)

Everything not already quoted in §5.1, §7.9, §10 and §11. Function-valued keys are shown as their JS expression so the Arabic agreement rules are preserved exactly; `n`/`d`/`t`/`total`/`r`/`k`/`unit`/`title`/`days`/`body` are the arguments.

**Coverage panel**

| Key | ar | en |
| --- | --- | --- |
| cov | `التغطية` | `Coverage` |
| covTip | `الصفحات اللي جا منها جواب في هذا المستند` | `The pages of this document that answers have actually cited` |
| covHint | `الجزء المملوء من الشريط صفحات وصلك منها جواب فعلًا، والباقي ما مرّيت عليه بعد. اضغط السهم جنب أي نطاق ليصير هو مجال أسئلتك الجاية.` | `The filled part of the bar is pages an answer has actually cited; the rest you have not reached yet. The arrow beside a range makes it the window your next questions search.` |
| covPct(n) | `n + "٪"` | `n + "%"` |
| covSeen(n,total,unit) | `"وصلك جواب من " + n + " " + unit + " من أصل " + total` | `n + " of " + total + " " + unit + " have been cited"` |
| covGaps | `ما وصلته بعد` | `Not reached yet` |
| covGapGo | `احصر الأسئلة بهذا النطاق` | `Limit questions to this range` |
| covAll | `ما بقي شيء — كل صفحة بهذا المستند جا منها جواب مرّة على الأقل.` | `Nothing left — every page here has been cited at least once.` |

**Tables panel**

| Key | ar | en |
| --- | --- | --- |
| tbl | `الجداول` | `Tables` |
| tblTip | `الجداول اللي بالمستندات المختارة — اقرأها كجدول وحمّلها CSV` | `The tables in your selected documents — read as a table, saved as CSV` |
| tblHint | `الصفوف كما هي بالملف نفسه، بلا أي تخمين من نموذج. جداول Word وPowerPoint وExcel والصفحات المقروءة بالرؤية تظهر هنا؛ والجدول داخل نص PDF مستخرَج غالبًا انضغطت أعمدته وقت الاستخراج فما نلقاه. وإذا كان نطاق الصفحات مفعّلًا ينطبق هنا أيضًا.` | `The rows exactly as the file stores them, nothing guessed by a model. Word, PowerPoint and Excel tables and pages read with vision all come through here; a table inside a PDF’s own extracted text usually lost its columns during extraction, so it cannot be found. A page range, if one is set, applies here too.` |
| tblDocs(n) | `n === 2 ? "جداول مستندين" : n <= 10 ? "جداول " + n + " مستندات" : "جداول " + n + " مستندًا"` | `"Tables in " + n + " documents"` |
| tblReading | `يقرأ المستندات…` | `Reading the documents…` |
| tblFail | `تعذّرت قراءة المستندات. أغلق وحاول مرة أخرى.` | `Couldn’t read the documents. Close this and try again.` |
| tblEmpty | `ما لقيت جدولًا بصفوف واضحة. إذا كان الملف PDF مصوّرًا، أعد رفعه مع «اقرأ بالرؤية» ورح تظهر جداوله.` | `No table with clear rows here. If the file is a scanned PDF, re-upload it with “Read with vision” and its tables will come through.` |
| tblCut(n,total) | `"يعرض " + (n === 1 ? "صفًا واحدًا" : n === 2 ? "صفين" : n <= 10 ? n + " صفوف" : n + " صفًا") + " من أصل " + total` | `"Showing " + n + " of " + total + " rows"` |
| tblSwept(n,total) | `"مسحت " + (n === 1 ? "مقطعًا واحدًا" : n === 2 ? "مقطعين" : n <= 10 ? n + " مقاطع" : n + " مقطعًا") + " من أصل " + total + " — احصر الصفحات لتوصل للباقي"` | `"Scanned " + n + " of " + total + " passages — set a page range to reach the rest"` |
| tblMany(n,total) | `"يعرض " + n + " جدولًا من أصل " + total` | `"Showing " + n + " of " + total + " tables"` |
| tblPage | `افتح الصفحة` | `Open the page` |
| tblCopy | `نسخ CSV` | `Copy CSV` |
| tblSave | `تنزيل CSV` | `Download CSV` |
| tblSaved | `تم تنزيل الملف` | `File downloaded` |

**PDF export**

| Key | ar | en |
| --- | --- | --- |
| pdfWorking | `يجهّز الـ PDF…` | `Building the PDF…` |
| pdfDone | `تم تنزيل الـ PDF` | `PDF downloaded` |
| pdfFail | `تعذّر إنشاء الـ PDF` | `Couldn't build the PDF` |
| pdfEmpty | `ما في محتوى لتصديره — الجواب فارغ أو تعذّر استخراجه. أعد إرسال الطلب.` | `Nothing to export — the answer is empty or the extraction failed. Send the request again.` |

**Citation panel (in addition to §11.4)**

| Key | ar | en |
| --- | --- | --- |
| citeAcc(d) | `"استُرجع في " + d` | `"Retrieved " + d` |
| citeAccM(d) | `"تاريخ الاطلاع " + d` | `"Accessed " + d` |

APA reference = `[name + ".", "(" + y + ").", "[" + medium + "].", accA ? citeAcc(accA) + "." : ""]` joined by spaces; APA in-text = `"(" + [name, y, loc].join(sep) + ")"`; MLA reference = `[name + ".", year ? year + "." : "", medium + ".", accM ? citeAccM(accM) + "." : ""]`; MLA in-text = `"(" + [name, page].join(" ") + ")"`; `sep` = `، ` (ar) / `, ` (en) (app.js:89873–89906).

**Formula sheet**

| Key | ar | en |
| --- | --- | --- |
| fml | `المعادلات` | `Formulas` |
| fmlTip | `ورقة معادلات: كل معادلة في المستند مع صفحتها، بلا تكرار` | `A formula sheet: every equation in the document with its page, deduplicated` |
| fmlOne | `اختر مستندًا واحدًا بالضبط من القائمة، ثم اضغط المعادلات` | `Select exactly one document in the list, then press Formulas` |
| fmlHint | `منقولة حرفيًا من سطور المستند نفسه — ما في معادلة من نموذج. ونطاق الصفحات ما ينطبق هنا: الورقة تمسح المستند كله.` | `Copied verbatim from the document's own lines — no equation here is written by a model. The page range does not apply: the sheet sweeps the whole document.` |
| fmlReading | `يمسح المستند…` | `Sweeping the document…` |
| fmlEmpty | `ما لقيت معادلات في هذا المستند.` | `I found no equations in this document.` |
| fmlFail | `تعذّر مسح المستند. أغلق وحاول مرة أخرى.` | `Couldn't sweep the document. Close this and try again.` |
| fmlCopy | `نسخ الورقة` | `Copy sheet` |
| fmlTimes(n) | `"تتكرر " + (n === 2 ? "مرتين" : n <= 10 ? n + " مرات" : n + " مرة") + " في المستند"` | `"Appears " + n + " times in the document"` |
| fmlCap(n) | `"عُرضت أول " + n + " معادلة فقط — المستند فيه أكثر."` | `"Showing the first " + n + " only — the document has more."` |
| fmlN(n) | `n === 1 ? "معادلة واحدة" : n === 2 ? "معادلتان" : n <= 10 ? n + " معادلات" : n + " معادلة"` | `n === 1 ? "1 formula" : n + " formulas"` |

**Term list**

| Key | ar | en |
| --- | --- | --- |
| gloss | `المصطلحات` | `Terms` |
| glossDrop | `إزالة من القائمة` | `Remove from the list` |
| glossTip | `المصطلحات اللي سألت عنها في هذا المستند` | `Terms you asked about in this document` |
| glossHint | `المصطلحات اللي سألت عنها وهذا المستند يعرّفها. اضغط أي واحد ليفتح المقطع الذي عرّفه.` | `The terms you asked about that this document defines. Open one to go back to the passage that defined it.` |

**Exam**

| Key | ar | en |
| --- | --- | --- |
| exam | `اختبار` | `Exam` |
| examTip | `اختبرني في صفحات تختارها — وكل خطأ يرجّعك إلى صفحته` | `Test yourself on pages you pick — every miss takes you back to its page` |
| examHint | `الأسئلة تُؤلَّف من صفحات هذا المستند وحده. الدرجة ليست المقصد — كل سؤال تخطئ فيه يفتح لك المقطع اللي يغطيه.` | `The questions are written from this document's own pages. The score is not the point — every question you miss opens the passage that covers it.` |
| examCount | `عدد الأسئلة` | `Questions` |
| examMins | `الوقت بالدقائق` | `Minutes` |
| examLess | `أقل` | `Fewer` |
| examMore | `أكثر` | `More` |
| examStart | `ابدأ الاختبار` | `Start the exam` |
| examBuilding | `يؤلّف الأسئلة من صفحاتك…` | `Writing questions from your pages…` |
| examFail | `تعذّر تأليف اختبار من هذي الصفحات. جرّب نطاقًا أوسع.` | `Couldn't build an exam from these pages. Try a wider range.` |
| examEmpty | `ما في صفحات مفهرسة بهذا النطاق.` | `No indexed pages in that range.` |
| examQnum | `رقم السؤال` | `Question number` |
| examClock | `الوقت المتبقّي` | `Time left` |
| examBack | `السابق` | `Previous` |
| examNext | `التالي` | `Next` |
| examFinish | `أنهِ وصحّح` | `Finish and mark` |
| examTimeUp | `انتهى الوقت — صُحّحت الورقة كما هي.` | `Time's up — the sheet was marked as it stood.` |
| examReview | `ارجع إلى هذي المقاطع` | `Go back to these passages` |
| examAllRight | `أصبت في كل الأسئلة — ما في شيء ترجع له.` | `Every answer was right — nothing to go back to.` |
| examYours | `إجابتك` | `You chose` |
| examRight | `الصحيح` | `Correct` |
| examSkipped | `بلا إجابة` | `No answer` |
| examOpen | `افتح المقطع` | `Open the passage` |
| examAgain | `اختبار جديد` | `New exam` |
| examClose | `إغلاق` | `Close` |

**Study plan**

| Key | ar | en |
| --- | --- | --- |
| plan | `خطة مذاكرة` | `Study plan` |
| planTip | `قسّم هذا المستند على أيام — كل يوم صفحاته وعناوينه` | `Split this document across days — each day its pages and its headings` |
| planHint | `التقسيم من عناوين المستند نفسه وأرقام صفحاته — ما في تخمين من نموذج. غيّر عدد الأيام وتنقسم الخطة من جديد.` | `Built from the document's own headings and page numbers — nothing here is guessed by a model. Change the number of days and it re-splits.` |
| planDays | `عدد الأيام` | `Days` |
| planLess | `يوم أقل` | `One day fewer` |
| planMore | `يوم أكثر` | `One day more` |
| planDay(n) | `"اليوم " + n` | `"Day " + n` |
| planReading | `يقرأ بنية المستند…` | `Reading the document's structure…` |
| planFail | `تعذّرت قراءة بنية المستند. أغلق وحاول مرة أخرى.` | `Couldn't read the document's structure. Close this and try again.` |
| planEmpty | `ما في صفحات مفهرسة بهذا المستند تنبني منها خطة.` | `This document has no indexed pages to build a plan from.` |
| planCopy | `نسخ الخطة` | `Copy plan` |
| planRefine | `حسّنها بفِراس` | `Refine with Firas` |
| planRefineOff | `ضمّ هذا المستند للبحث أولًا حتى تقدر تحسّن الخطة` | `Add this document back to the search before refining the plan` |
| planScope | `احصر الأسئلة بصفحات هذا اليوم` | `Limit questions to this day's pages` |
| planScoped(r) | `"صار البحث محصورًا بالصفحات " + r` | `"Questions are now limited to pages " + r` |
| planSpan(n) | `n === 1 ? "يوم واحد" : n === 2 ? "يومين" : n <= 10 ? n + " أيام" : n + " يومًا"` | `n === 1 ? "1 day" : n + " days"` |
| planAsk(title,days,body) | `"هذي خطتي لدراسة «" + title + "» على " + days + ":\n" + body + "\n\nراجعها من محتوى المستند: سمِّ كل يوم بعنوانه، وقول شنو يُدرس فيه، وحرّك القطع إذا واحد منها وقع بمنتصف موضوع."` | `"Here is my plan for studying “" + title + "” over " + days + ":\n" + body + "\n\nCheck it against the document: name each day, say what it covers, and move a cut if one of them lands in the middle of a topic."` |

`brainT().ar` is `true`/`false` (a convenience flag, not a string). `brainTL(lang)` returns the same table for the given message language (app.js:80915).
