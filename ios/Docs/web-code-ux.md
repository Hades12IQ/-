# Firas Code — web client UX and protocol spec for the native port

Scope: the Firas Code product (the in-browser IDE, product key `code`) and the chat-side code deliverable box in Firas AI. Sources are the deployed files at the repo root: `app.js` (client), `server.mjs` (the only API source of truth), `styles.css`, and the STR tables inside `app.js`. Every claim carries a `file:line` citation; strings are copied verbatim (Arabic first where the table is `ar ? {...} : {...}`).

Read this together with the other slices: `/api/chat` SSE transport and the ordinary chat job path belong to the chat slice; Firas Computer (the agent that drives the preview) is only summarised here because it lives inside the Code preview pane.

---

## 0. Ten facts to get right before writing any Swift

1. A **project is a chat** with `codeProj: true`. `messages[0]` is an assistant message whose whole content is a ```` ```firas-project ```` fence around `{ name, files:[{path,content}] }`; `messages[1]` is the Firas Code chat thread, a ```` ```firas-code-chat ```` fence around **base64(JSON)**. There is no other server-side representation (`app.js:60119-60127`, `60562-60606`, `60609-60657`).
2. A **build is a server job**: `POST /api/chat/job` with `kind: "codebuild"`, then `GET /api/chat/job?id=` every 4 s. The job publishes the growing project as the SAME ```` ```firas-project ```` fence in `text`; the client parses it and PUTs the files into the chat itself. The worker never writes the files into the chat (`chatId` is sent as `""`) (`app.js:60521-60560`, `60426-60500`; `server.mjs:11463-11667`).
3. Terminal phases for this queue are exactly `completed` (also accept `done`), `failed`, `unknown`. `unknown` = no record (expired after `JOB_KEEP_MS` = 6 h) and is terminal (`server.mjs:9329`, `12708`; `app.js:60480`).
4. Do not forget the job pointer until the files have **landed** in the project; the web retries the landing up to 15 × 4 s after the phase turned terminal (`app.js:60484-60489`).
5. The build ceiling is 2 h on both sides: `CODEBUILD_MAX_MS` (`server.mjs:11185`) and `CW_JOB_MAX_MS` (`app.js:60283`). A pointer older than that is dropped at reattach.
6. Members are **unmetered** for Code (`PLAN_LIMITS.*.code = -1`, `server.mjs:1347-1357`). Guests get 60 Code units/day per cookie and 4× that per IP (`server.mjs:1133-1147`, `1256-1300`). On the web the server build path does **not** charge a unit; only in-IDE AI edits, Improve, the in-tab fallback builder and Firas Computer call `POST /api/usage/charge` (`app.js:75926`, `62533`, `63611`, `61009`).
7. Files cap: 30 files, 120-char paths, 60 000 chars per file at save time, and the whole `firas-project` JSON must fit in `CW_PAYLOAD_MAX` = 180 000 chars or the save is refused with a toast (`app.js:60265`, `60573-60598`). The server independently cuts any message at `MAX_CONTENT` = 1 000 000 chars (`server.mjs:2429`).
8. The preview is one self-contained HTML document built by `projPreviewHtml`: local `<link href=*.css>` becomes `<style>`, local `<script src=*.js>` becomes inline `<script>`, module scripts get an import map to blob: URLs, CDN refs are left alone (`app.js:50933-51027`). A console hook script is prepended so `console.*`, `error` and `unhandledrejection` arrive as `postMessage({__fcw:1,...})` (`app.js:60736`).
9. Follow-up edits are NOT a job: `cwAskAI` runs in the tab against `POST /api/chat` with `nomem:true, think:false`, tier `"max"` (or `"pro"` for questions), and expects the model to answer with ```` ```file:relative/path ```` blocks plus `DELETE:`/`RENAME:` lines; the client parses, shows a diff with checkboxes, and applies on approval (`app.js:75888-76189`, `76312-76512`, `61729-61812`).
10. The chat-side code card is a different renderer: a single file persisted as ```` ```firas-code {json}\n<code>\n``` ```` (`app.js:6550-6558`), streamed live, with Copy / Download / Preview / Continue and a wrap toggle (`app.js:6732-6925`).

---

## 1. Data model

### 1.1 Project chat

Created client-side (`app.js:60659-60665`):

```js
{ id: uid(), serverId: null, title: String(name || "مشروع").slice(0, 80), codeProj: true,
  createdAt: Date.now(), updatedAt: Date.now(), messages: [] }
```

Persisted via the ordinary chat API (`app.js:3452-3480`; `server.mjs:2555-2625`):

| Call | Body / response |
| --- | --- |
| `POST /api/chats` (create) | `{ clientId, title, messages, pinned, agent, codeProj: true, brainNb }` → `201 { id, title, createdAt, updatedAt }`. `clientId` must match `^[A-Za-z0-9_-]{8,120}$` and yields the deterministic id `"c_" + clientId` (retry-safe). 409 `{ error: "chat limit reached; delete some conversations" }` at `MAX_CHATS_PER_USER`. |
| `PUT /api/chats/:id` | same body; only `title`, `messages`, `pinned` are honoured — **product flags are never updated after creation** (`server.mjs:2600-2603`, `2618-2622`). |
| `GET /api/chats` | `[{ id, title, updatedAt, pinned, agent, codeProj, brainNb }]` — **no messages**; the client stores `messages: null` and lazy-loads (`app.js:3376-3386`). |
| `GET /api/chats/:id` | `{ id, title, messages }` (`server.mjs:2548-2553`). |
| `DELETE /api/chats/:id` | `{ ok: true }`. |

All four require the member cookie (401 `{ error: "not authenticated" }`). Guests never call them: a guest's projects live only in device storage (`app.js:3358-3367`, `3461`).

Server-side `sanitizeMessages` keeps per message only `role` (≤20), `content` (≤`MAX_CONTENT` 1 000 000), `tier`, `lang`, `files[].name`, `askAnswered`, `cid`, `retryOf`, `retried`, `mode`, `mergedFrom`, and caps the list at `MAX_MESSAGES` = 2000 (`server.mjs:2417-2470`). `reasoning` is not on that whitelist — do not rely on it surviving.

### 1.2 `messages[0]` — the files fence

Exact serialisation written by `codeSaveFiles` (`app.js:60562-60606`):

```
```firas-project
{"name":"<≤80 chars>","files":[{"path":"index.html","content":"<!DOCTYPE html>…"}]}
```
```

Rules enforced before the write:
- `files.slice(0, 30)`, `path.slice(0, 120)`, `content.slice(0, 60000)`.
- While `JSON.stringify(payload).length > 180000` (`CW_PAYLOAD_MAX`): shrink the **largest** file to 80 % of its length, up to 400 passes, stop when the largest is under 200 chars.
- Still too big → refuse and toast `"المشروع أكبر من حدّ الحفظ — لم يُحفظ. احذف أو صغّر أكبر ملف."` / `"Project exceeds the save limit — not saved. Remove or shrink the largest file."`
- Refuse to save an empty file list over a chat whose `messages` is `null` (not yet loaded) — that once destroyed a real project (`app.js:60563-60570`). An empty project is legal only when the user deleted every file on a loaded chat.
- Message shape when creating: `{ role: "assistant", content, reasoning: "", lang: state.lang }`.

Parser (`app.js:50926-50930`): `/^\s*```firas-project\s*\n([\s\S]*?)\n```\s*$/` on the whole message, `JSON.parse`, requires `files` to be a non-empty array. `codeFilesOf(chat)` returns `{ name: p.name || chat.title || "project", files }` or `{ name: chat.title || "project", files: [] }` (`app.js:60260-60264`).

The existing Swift `CodeProject.decode(fromJobText:)` in `ios/FirasAI/Models/CodeModels.swift` already finds the last `\n```` fence; keep that (file contents legitimately contain backtick fences).

### 1.3 `messages[1]` — the Firas Code chat thread

`CW_THREAD_TAG = "firas-code-chat"` (`app.js:60609`). Content:

```
```firas-code-chat
<base64 of JSON {"turns":[{"role":"user"|"ai","text":"…","n":0,"applied":false,"ts":1720000000000}]}>
```
```

- base64 is `btoa(unescape(encodeURIComponent(json)))` (UTF-8) (`app.js:60610-60611`).
- Keep the last 40 turns; each `text` ≤ `CW_TURN_MAX` 90 000; encoded body must be ≤ `CW_THREAD_BUDGET` 120 000 chars — drop oldest turns first, never the newest; if a single turn is still too big, trim its text by 30 % per pass (`app.js:60629-60650`).
- Never create `messages[1]` before `messages[0]` exists (`app.js:60632`).
- `n` = number of files the AI turn changed (drawn as a chip: `n + " ملف"` / `n + " file"`/`" files"`), `applied` is unused by the UI today.
- Writes chain through a per-chat promise so PUTs cannot reorder (`app.js:60649`).

### 1.4 Device-local state (web `localStorage` keys)

| Key | Purpose | Cite |
| --- | --- | --- |
| `firas_ai_product` | last product (`"code"`) | `app.js:2403` |
| `firas_job_<chatId>` | flat "this chat has a live job" pointer (value = jobId); swept by `liveChatIds()` to light sidebar/rail badges | `app.js:60543`, `19553` |
| `firas_ai_code_jobs` (`LS_CODE_JOBS`) | `{ [chatId]: { jobId, name(≤80), sid, ts } }`, max 20 entries evicted by `ts` | `app.js:60282-60316` |
| `firas_cw_device` / `firas_cw_autoreload` / `firas_cw_orient` | preview device (`mobile|tablet|desktop`), auto-reload (`"0"` = off), orientation (`"l"`/`"p"`) | `app.js:65669`, `65688-65697` |
| `firas_cw_prefs_v1` | editor prefs JSON (≤400 chars) | `app.js:68265`, `68377-68404` |
| `firas_cw_ig_v1` | indent guides on/off (`"0"` = off; missing = on) | `app.js:67653`, `67684` |
| `firas_cw_qf_v1` | quick-fix state | `app.js:66505` |
| `firas_cw_split_v1` | pane seam sizes | `app.js:70193` |
| `firas_cw_find_v1` | find/replace prefs (case, whole word, scope) | `app.js:71635` |
| `firas_cw_outline_v1` | outline panel open/closed | `app.js:72191` |
| `firas_cw_runs` | last run verdict per target, 60 records | `app.js:64749-64751` |
| `firas_code_snaps_v1` | version-history snapshots: per project max 20, auto every 90 s while editing with ≥20 s gap, store budget 900 000 chars | `app.js:77792`, `77809`, `77896-77903` |
| `firas_code_clog_v1` | AI change log: max 20 rows, 60 000 chars body cap, 900 000 store cap | `app.js:78318` |
| `firas_code_wrap` | chat code-card wrap toggle (`"1"`/`"0"`) | `app.js:6810` |

---

## 2. Home screen (project launcher)

Rendered by `renderCodeHome` when no `codeProj` chat is active (`app.js:61534-61727`). Layout, top to bottom:

1. **Hero**: brand mark, `<h1>` `heroT` = `"Firas Code"`, paragraph `"اكتب ما تريد بناءه، ويبنيه فِراس لك — تطبيق كامل يعمل، أو ابدأ بمشروع فارغ"` / `"Describe what to build and Firas builds it — a complete working app, or start blank"` (`app.js:61556-61558`). Under it, `cwHeroStage` draws a slow-drifting marquee of up to 9 file rows harvested round-robin from the user's projects (one file per project per pass, 3 passes); fewer than 3 real rows → skeleton variant; caption `stageCap` `"ملفات من مشاريعك"` / `"Files from your projects"`, row action `stageOpen` `"افتح المشروع"` / `"Open project"` (`app.js:61141-61300`).
2. **Create card**:
   - name input `maxlength=60`, placeholder `"اسم المشروع (اختياري)"` / `"Project name (optional)"`.
   - description textarea `rows=4 maxlength=1500`, placeholder `"صف تطبيقك… مثال: لعبة ثعبان احترافية بلوحة نتائج، أو متجر ملابس بسلة تسوّق تعمل وتصميم أنيق داكن"` / `"Describe your app… e.g. a polished Snake game with a scoreboard, or a clothing store with a working cart and elegant dark design"`.
   - attachment button (paper-clip icon) labelled `attach` `"أرفق صورة أو ملف"` / `"Attach an image or file"`; hidden `<input type=file multiple>` with accept list `CW_ATT_ACCEPT` (`app.js:61302`): `image/*,application/pdf,.pdf,.docx,.pptx,.xlsx,.xlsm,.txt,.md,.markdown,.csv,.tsv,.json,.jsonl,.xml,.yml,.yaml,.html,.htm,.css,.scss,.less,.js,.jsx,.mjs,.cjs,.ts,.tsx,.py,.java,.c,.h,.cpp,.cc,.hpp,.cs,.go,.rs,.rb,.php,.swift,.kt,.kts,.sql,.sh,.bash,.zsh,.ini,.toml,.cfg,.conf,.env,.log,.tex,.srt,.vtt,.rtf,.svg,text/*`. Drop veil label `attDrop` `"أفلت الملفات هنا"` / `"Drop files here"`. The tray reuses the chat composer's thumbnails/file chips (`app.js:61316-61366`).
   - actions: `"مشروع فارغ"` / `"Blank project"` and `"ابنِ بالذكاء"` + `" ✨"` / `"Build with AI"` + `" ✨"`.
3. **Your projects grid**: heading `"مشاريعك"` / `"Your projects"`; while chats are loading, 4 shimmer cards; up to 12 project buttons showing `</>`, the title (fallback `"مشروع"` / `"project"`), `n + " ملف"` / `n + " files"` (n is 0 for chats whose messages are not loaded yet), and a `✕` delete control titled `"حذف"` / `"Delete"`. Empty state: `"لا مشاريع بعد — أنشئ أول مشروع بالأعلى"` / `"No projects yet — create your first above"` (`app.js:61538-61552`).

Behaviour:

- **Blank**: name = typed name, else `titleFrom(description)` if a description exists, else `"مشروع جديد"` / `"new-project"`; creates the project with `CW_BLANK_FILES` (one `index.html`, `app.js:61128`) and opens the IDE.
- **Build with AI** (`cwRunBuild`, `app.js:61596-61717`):
  1. `desc` = trimmed description, or if empty and attachments exist, `attGo` `"نفّذ ما تُظهره المرفقات على المشروع."` / `"Apply what the attachments show to this project."`; empty → behaves like Blank.
  2. If images are still being read: toast `attRead` `"يقرأ المرفقات…"` / `"Reading the attachments…"` and stop.
  3. Button goes disabled with spinner + `"يبني مشروعك…"` / `"Building…"`; retry state is `"↻ "` + `"أعد المحاولة"` / `"Retry"`.
  4. Project name = manual name, else `cwDeriveName(desc)` (first clause, strips lead-ins like `build|create|make|…|ابنِ|اصنع|أنشئ|…`, strips `موقع|تطبيق|صفحة|برنامج`, caps at 48 chars on a word boundary), else `"مشروع جديد"` / `"new-project"` (`app.js:61565-61594`).
  5. Attachments are converted to **text** first (`cwTakeAttach(desc, CW_ATT_JOB_MAX=24000)`, §6.4) because the job record must stay small.
  6. The project is created immediately with the blank scaffold and the IDE is shown, so a checkpoint has somewhere to land (`app.js:61614-61626`).
  7. `codeServerBuild(chat, name, desc, attCtx)` (§3). On success the only feedback is a toast `srvKeep` `"يُبنى على الخادم — غادِر الصفحة إن شئت، ستجده جاهزًا حين تعود"` / `"Building on the server — leave if you like, it'll be here when you're back"` (`app.js:62636`).
  8. If the queue refused (any non-OK status or no `jobId`), fall back to the in-tab builder `cwGenerateProject` (§3.6). Its failure toasts: no files → `"لم يكتمل الإنشاء — أعد المحاولة، أو أضِف تفاصيل للوصف"` / `"Build didn't complete — retry, or add more detail to your description"`; thrown → `"تعذّر الاتصال بمحرّك الذكاء — أعد المحاولة"` / `"AI engine unavailable — retry"`.
- **Open project**: must load the chat first (`GET /api/chats/:id`) before mounting the IDE — mounting against `messages: null` produced an empty autosave that overwrote the real project (`app.js:61718-61726`).
- **Delete**: `confirm("حذف هذا المشروع نهائيًا؟" / "Delete this project permanently?")` then `deleteChat(id)`.

---

## 3. Building a project on the server

### 3.1 Request — `POST /api/chat/job`

Exact body the web sends (`app.js:60521-60545`):

```json
{
  "kind": "codebuild",
  "task": "<description, sliced to 6000 chars>",
  "name": "<project name, sliced to 80>",
  "attach": "<attachment text, sliced to 24000>",
  "lang": "ar" | "en",
  "tier": "pro",
  "cid": "<uid(): Date.now().toString(36) + 6 random base36 chars>",
  "product": "code",
  "chatId": "",
  "messages": [ { "role": "user", "content": "<task + attach>" } ]
}
```

- `lang` = UI language; the server only uses it as a tie-breaker (§3.4).
- `chatId` is `chat.serverId || ""`, which is `""` at build time on the web (the create POST has not returned). Send `""`: the files are landed by the client, not the worker (see §3.5 on why a non-empty `chatId` would append an assistant turn).
- `messages` must be a non-empty array or the server answers 400; its content is redundant with `task` and only exists for older servers.
- `attach` was made its own field so the 6000-char `task` cut cannot eat it (`app.js:60528-60534`).

Server handling (`server.mjs:12531-12656`):

| Condition | Status / body |
| --- | --- |
| no member cookie AND no guest cookie | `401 { error: "authentication required" }` |
| rate limit `chatjob:<callerId>` — 60/min member, 30/min guest | `429 { error: "too many requests" }` |
| body not JSON | `400 { error: "invalid JSON body" }` |
| `messages` missing/empty | `400 { error: "messages required" }` |
| raw body > `JOB_PAYLOAD_MAX` 600 000 chars | `413 { error: "payload_too_large" }` |
| durable store failure | `503 { error: "storage_unavailable" }` |
| same owner + same `cid` already **completed** | `200 { ok:true, jobId, phase:"completed", text, reasoning, surface, progress }` |
| same cid queued/processing | `200 { ok:true, jobId, phase }` |
| same cid failed | `200 { ok:false, jobId, phase:"failed", error, surface, retryRequiresNewCid:true }` |
| accepted | `200 { ok:true, jobId, phase:"queued" }` |

`jobId = sha1(ownerId).hex.slice(0,10) + "-" + cid` with `cid` sanitised to `[A-Za-z0-9_-]{≤64}` (`server.mjs:731-733`, `12571-12572`). Treat it as opaque; pass it back verbatim. The stored record has `kind: "codebuild"`, `product: "code"`, `tier` (`TIERS[tier] ? tier : "pro"` — it is not what builds the code; the builder uses `CODEBUILD_TIER`), `lang`, `task` (≤8000), `name` is NOT stored on the record — it travels in the input payload and is read by the worker (`server.mjs:12626-12647`, `11488`).

Guests are allowed (only `agentrun` is refused for guests with `403 { ok:false, error:"account_required", feature:"agent" }`, `server.mjs:12549-12551`).

### 3.2 Poll — `GET /api/chat/job?id=<jobId>`

Auth: member or guest cookie; `401 { error: "authentication required" }` otherwise. Wrong owner → `403 { error: "forbidden" }` (`server.mjs:12658-12717`).

Response (always 200 for a known/unknown id):

```json
{ "phase": "queued" | "processing" | "completed" | "failed",
  "text": "<growing ```firas-project fence or empty>",
  "reasoning": "",
  "error": "",            // failed: reason string or the refusing HTTP body (≤1000 chars)
  "status": 0,            // failed after an HTTP refusal: that status code; 499 = cancelled (longfile only)
  "surface": null,
  "progress": null }
```

- No record → `{ "phase": "unknown" }` (also after `JOB_KEEP_MS` 6 h).
- While `processing` the answer is served from memory on the worker machine; `text` is the last published fence. Progress writes are throttled: first non-empty write immediately, then at most every 2.5 s (`server.mjs:11803-11823`). The `progress` field on the control record is `"built/planned"` (e.g. `"3/7"`) but it is NOT returned by this endpoint (only `longfile` progress objects are) — derive progress by counting `files` in the parsed fence.
- A job can go quiet for up to `JOB_STALE_MS` = 120 s while a stale claim is re-queued; that is not a failure (`server.mjs:9324`, `11963`).
- Retries: up to `JOB_MAX_ATTEMPTS` = 3 with backoff `attempts × 5 s`; then `failed` with `error` = the thrown message or `"no_answer"` (`server.mjs:11929-11938`). Known failure strings: `"codebuild_no_task"`, `"codebuild_empty"`, `"no_answer"`, `"user_not_found"`, `"payload_missing"`.
- Concurrency `JOB_CONCURRENCY` = 4; a queued job may wait behind others (`server.mjs:9328`).

### 3.3 The client poll loop (port `cwWatchServerBuild`, `app.js:60426-60500`)

Pseudocode of the exact behaviour:

```
remember pointers: localStorage["firas_job_"+chat.id] = jobId; LS_CODE_JOBS[chat.id] = {jobId, name, sid: chat.serverId||"", ts: start}
loop every 4000 ms while (now - start) < 2h:
  r = GET /api/chat/job?id=jobId (cache: no-store)
  if r.status == 403: forget pointers, stop          // someone else's job on a shared device
  if fetch threw: continue                            // a dropped poll is not a failure
  target = project chat found by chat.id OR serverId (either name)   // cwJobChat
  if no target:
     if chats list is loaded and healthy: orphan++; if orphan > 15: forget, stop
     continue
  orphan = 0
  if target.serverId != sid: sid = target.serverId; re-remember pointer with sid
  m = /```firas-project\s*\n([\s\S]*?)\n```/.exec(r.text)   // NOTE: non-greedy first-fence match
  if m and (raw != lastFence or !savedOnce):
     proj = JSON.parse(raw); if proj.files non-empty:
        sawFiles = true
        ensure target.messages is loaded (GET /api/chats/:sid if null; guests: only if already loaded)
        codeSaveFiles(target, name || proj.name || target.title, proj.files); savedOnce = true; lastFence = raw
        if the project is on screen: re-render the IDE
     else lastFence = raw   // do not re-attempt identical unparseable bytes
  if phase in (completed, done, failed, unknown):
     if sawFiles and !savedOnce and ++retry <= 15: sleep 4 s; continue   // files seen but not landed yet
     forget pointers; repaint badges; announce(target, savedOnce); stop
```

Caveat to reproduce faithfully: the web's fence regex is non-greedy and would stop at the first ```` \n``` ```` inside a file body; the Swift decoder already searches backwards for the last fence, which is stricter and correct — keep the Swift behaviour.

Announcement (`cwAnnounceBuildDone`, `app.js:60374-60399`): `ok` means files actually landed, not merely that the phase turned.
- project on screen and ok → toast `srvDone` `"خلص بناء المشروع ✅"` / `"Project build finished ✅"`.
- ok elsewhere → `srvReady` `"«{name}» صار جاهزًا في فراس كود"` / `"\"{name}\" is ready in Firas Code"` with an action `srvOpen` `"افتحه"` / `"Open it"` (9 s), name truncated to 40 chars, `{name}` replaced by split/join not regex.
- not ok → `srvFail` `"تعثّر بناء «{name}» على الخادم — افتحه وجرّب من جديد"` / `"\"{name}\" didn't finish building on the server — open it and try again"`.

Reattach (`cwJobsReattach`, `app.js:60502-60513`): on boot (1200 ms after init), `visibilitychange` (visible), `focus`, `pageshow`, `online`; idempotent through a `Set` keyed by chat id; drops malformed records and records older than 2 h. Native equivalent: `scenePhase == .active`, app launch, and network-path-satisfied.

Push: for **members** the server sends an APNs alert on `completed`/`failed` with `aps.alert = { title: "مشروع فِراس كود اكتملت", body: "اضغط لعرض النتيجة." }` / `{ "Firas Code project is ready", "Tap to view the result." }`; failure: `{ "مشروع فِراس كود لم تكتمل", "اضغط لعرض التفاصيل أو المحاولة مجدداً." }` / `{ "Firas Code project could not finish", "Tap to view details or try again." }`; sound `FirasComplete.wav`, category `FIRAS_JOB_COMPLETE`, custom key `firas: { type:"job-terminal", product:"code", jobId, phase }` — **no `chatId`** for a code build, so the app must resolve the project from its own jobId→project table (`server.mjs:1515-1520`, `1551-1580`, `1627-1633`). Guests get no push.

### 3.4 What the server does with the job (`runCodeBuildJob`, `server.mjs:11463-11667`)

Knowing this lets the UI narrate honestly (the web's build console rows, §3.7):

1. `desc = body.task || last user message`; empty → throws `codebuild_no_task`. `attach = body.attach.slice(0, 24000)`; the brief passed to the planner is `desc + "\n\nATTACHED CONTEXT — screenshots the user attached (read into words) and text extracted from their files. What you plan must MATCH it:\n" + attach`.
2. **Classify** (`codeClassify`, `11226-11287`): one call on `CODEBUILD_TIER` ("ultra") returning `{ kind: game|app|dashboard|site|tool|mobile|desktop, lang: ar|en, title }`. The request overrules the model: if Arabic vs Latin letter counts are ≥12 total and one is >3× the other, that script wins; decisive nouns (`لعبة|game|…` → game, `لوحة تحكم|dashboard` → dashboard, `تطبيق هاتف|ios|android|…` → mobile, `برنامج ويندوز|electron|.exe|…` → desktop) override the kind. Default kind `site`. Project name = `body.name || title || ("new project" | "مشروع جديد")`.
3. **Plan** (`codePlanFiles`, `11289-11370`): JSON array `[{path, does}]`, 3–12 files (3–20 for mobile/desktop), always exactly one `index.html`, ≤`CODEBUILD_MAX_FILES` 40, paths cleaned (`^[/\\]+` stripped, `..` rejected, ≤120). Second try at temperature 0 if unparsable; if fewer than 2 files, a per-kind skeleton is added (game: `styles.css, js/game.js, js/state.js`; dashboard: `styles.css, js/data.js, js/charts.js, js/app.js`; mobile/desktop: `styles.css, js/app.js, capacitor.config.json|main.js, package.json, README.md`; default: `styles.css, js/app.js`).
4. **Write files one by one** (`11496-11612`): each file is one completion with `maxTokens: CODEBUILD_FILE_TOKENS` 32 000 at temperature 0.4; a wrapping code fence is stripped; `.js/.mjs/.html/.css` are checked for completeness (`</html>` at end; balanced `{}` and ends with `;` or `}`; JS parses via `new Function` after stripping `import/export`), and up to 3 continuations are appended. An unparseable JS file is **dropped**; a truncated HTML/CSS is kept. After **each** file the job publishes `` "```firas-project\n" + JSON.stringify({ name, files: built }) + "\n```" `` (`11610`) and patches `progress: built/plan`.
5. `built.length == 0` → throws `codebuild_empty`.
6. **Wiring audit + repair** (`codeAuditWiring`, `11376-11461`; repair `11621-11660`): missing local asset references, ids looked up by scripts but not defined, duplicate top-level declarations across classic scripts; one repair call per offending file (accepted only if ≥50 % of the original length); audit runs again and only logs.
7. Final `text` = the same fence with the repaired `built` (`11663`). Timing: every phase is bounded by `CODEBUILD_MAX_MS` 2 h.

The prompts embed the design contract (`VISUAL_POLICY`, `SIZE_MANDATE_WEB`, `CRAFT_MANDATE`, `server.mjs:11146-11184`) — nothing the client needs to replicate.

### 3.5 Why `chatId` must be `""`

`runOneJob` calls `saveAssistantTurn(user, rec.chatId, rec.cid, answer, …)` whenever a member job has a `chatId` (`server.mjs:11901-11902`). For a code build that would append/replace an assistant message carrying the raw `firas-project` fence into the project chat — a third message the IDE never reads and the sidebar would show as an extra turn. The web avoids it by sending `""`. Do the same.

### 3.6 In-tab fallback builder (web only; optional for native)

If the queue answers anything but `200 + jobId` (404/501 = no queue on this deploy, 413, 429, 503, network), the web builds in the tab (`cwGenerateProject`, `app.js:63603-63722`): charges one Code unit (`chargeUsage("code", uid())`), classifies web vs native (`cwClassifyProject`, tier `mini`, `app.js:63574-63601`), routes games to `cwDevelopGame`, other web projects to `cwDevelopProject` (§7), else a single-shot whole-project prompt expecting ```` ```file:path ```` blocks. This path needs a DOM sandbox (iframe probes for runtime errors and a11y) and 25–40 model calls; a native port can reasonably replace it with "the build service is unavailable — try again" as long as the server path exists (it does on server.mjs; the Netlify mirror has no queue).

### 3.7 Build progress narration (what the web shows while building)

Server builds show only the toast in §2 step 7 plus the live preview strip (§5.4) and the file tree filling in as checkpoints land. The **in-tab** builder narrates six tasks in the Chat tab as a task board (`cwStepUILive`, `app.js:62956-63200`), in this order and with these labels (`cwT`): `tlBrief` `"قراءة الطلب"`/`"Read the brief"`, `tlKind` `"تحديد ما سيُبنى"`/`"Decide what to build"`, `tlPlan` `"تخطيط الملفات"`/`"Plan the files"`, `tlWrite` `"كتابة الملفات"`/`"Write the files"`, `tlWire` `"فحص الترابط"`/`"Check the wiring"`, `tlFix` `"الإصلاح"`/`"Repair"`. Sub-labels: kind row = `cwKindTxt` → `"لعبة"`/`"Game"`, `"موقع ويب"`/`"Web app"`, `"برنامج"`/`"Program"`, joined with `" · "` and the language name or `tlOwnLang` `"بالعربية"`/`"in English"`; edit runs say `tlEdit` `"تعديل على مشروع قائم"`/`"An edit to an existing project"`. Write row counts files with Arabic agreement (`cwFilesTxt`: 1 `ملف`, 2 `ملفان`, 3–10 `ملفات`, 11+ `ملفًا`) and bytes via `cwSizeTxt` (`B`/`KB`/`MB`, one decimal). Wire row: `tlClean` `"كل شيء موصول"`/`"Everything is wired up"` or `tlFound` `"ما يحتاج إصلاحًا: {n}"`/`"{n} to fix"`. Headline states: `planning` `"يخطّط للمعمارية…"`/`"Planning architecture…"`, `building` `"يبني"`/`"Building"` + `" i/n · path"`, `finishing` `"يجمع الملفات…"`/`"Assembling files…"`; Stop button `cwLiveT.stop` `"إيقاف"`/`"Stop"`; Retry `"إعادة المحاولة"`/`"Retry"`; resume `cwResumeT`: label `"استئناف"`/`"Resume"`, hint `"يكمل من الملف {done+1} من {total}"`/`"continues at file {done+1} of {total}"`, `"أُوقف عند {done}/{total}"`/`"Stopped at {done}/{total}"`. The same six-task board is a good native model for the server build too: brief → kind → plan → write (n/N from the fence) → wire → done.

---

## 4. Quota — `POST /api/usage/charge`

Body `{ product: "code", cid: "<≤64 [A-Za-z0-9_-]>" }` (`app.js:46866-46880`; `server.mjs:7653-7685`).

| Caller | Result |
| --- | --- |
| no cookie at all | `401 { error: "authentication required" }` |
| guest, product code | charged against `GUEST_LIMITS.code` = 60/day per cookie and 240/day per IP; repeat `cid` is free; over → `429 { error: "guest daily limit reached", guest: true, quota: { product:"code", used, limit, plan:"guest" } }` (IP bucket adds `scope:"network"`); ok → `200 { ok:true, sub: <guest sub info> }` |
| member | `limitsFor(plan).code` is `-1` for every plan → `200 { ok:true, sub }` without counting |
| guest + product agent | `403 { ok:false, error:"signin_required", feature:"agent" }` (not relevant to Code) |

Client contract (`chargeUsage`): 429 → `{ ok:false, quota }`; 401/403 → `{ ok:false }` and, for a guest, open the sign-up prompt; network error → `{ ok:true }` (fail open). Toast on refusal in cwAskAI / cwGenerateProject: `"بلغت حدّك اليومي من فِراس Code (" + limit + "/يوم). فعّل اشتراكًا للمزيد."` / `"Daily Firas Code limit reached (" + limit + "/day). Redeem a plan for more."`; the Improve button's copy ends `"Activate a subscription for more."` in English (`app.js:62537`).

Web charge sites: every AI edit request (`cwAskAI`, before any model call, but after the document-redirect check), Improve, the in-tab build, and each Firas Computer run (`cid = "computer:" + session`). **Not** the server build. Also note `POST /api/chat` itself charges guests per turn unless `nomem:true` (`server.mjs:12878-12886`), and all IDE helper calls send `nomem:true`.

---

## 5. The IDE workspace

### 5.1 Layout (`renderCodeIDE`, `app.js:75338-75461`; CSS `styles.css:5845-5945`)

Desktop: a full-height column — top bar → `.cw-main` grid `200px | 1.1fr | 1fr` (file rail | editor | right pane) → attachment tray → AI command bar → status bar → diff overlay (absolute, covers the workspace). ≤860 px the grid collapses to a single visible pane chosen by a bottom nav (`data-mob`): `files | code | preview | ai`; the AI pane hides the main grid and expands the textarea to ≥120 px; the status bar is hidden ≤860 and shows only the save pill ≤640 (`styles.css:6743-6770`, `6806-6867`). ≤640 px: bar scrolls horizontally, file-count hidden, device segment hidden, editor font 14.5/1.7, inputs 16 px (iOS zoom guard), safe-area insets on bar/nav. Coarse pointers get ≥40–52 px targets (`styles.css:6790-6805`). Phone = viewport ≤640 (`cwIsPhone`, `app.js:69832`).

Bottom nav labels (`cwT`): `mobFiles` `"الملفات"`/`"Files"`, `mobCode` `"الكود"`/`"Code"`, `mobPreview` `"المعاينة"`/`"Preview"`, `mobAI` `"الذكاء"`/`"AI"`. Default pane `code`; switching to `preview` also selects the Preview tab and refreshes; `ai` selects the Chat tab and focuses the input (`app.js:75672-75683`).

Top bar, in order (`app.js:75350-75395`): Home (`home` `"الرئيسية"`/`"Home"`), brand mark, project title (`dir=auto`), file count `n + " ملفات"`/`n + " files"`, spacer, then buttons: Run/Refresh (`run` `"تشغيل"`/`"Run"`; the label is `runPy` `"تشغيل"`/`"Run"` when the selected file is Python — same Arabic, `cwSyncRunBtn` `app.js:65289`), **Improve** (primary; `cwImproveT.label` `"حسّن المشروع"`/`"Improve project"`, tooltip `"شغّل المشروع، افحصه فعليًا، ثم طوّره جولة بعد جولة"`/`"Run the project, actually inspect it, then improve it round after round"`), History (`cwSnapT.history` `"السجل"`/`"History"`, title `"سجل النسخ"`/`"Version history"`), New file (`addFile` `"ملف جديد"`/`"New file"`), Find (`cwFindT.title` `"بحث"`/`"Find"`), Outline (`cwOutlineT.title` `"الرموز"`/`"Outline"`, toggle), Share (`share` `"مشاركة"`/`"Share"`), ZIP (`zip` `"ZIP"`), then Preferences (`cwPrefsT.btn` `"تفضيلات"`/`"Preferences"`) added by `cwPrefsMountBtn`, and Focus mode (`zen` `"تركيز"`/`"Focus"`). The dock groups them under three tooltip-rail headings: `cwDockRun` `"تشغيل وتطوير"`/`"Run & improve"`, `cwDockEdit` `"تحرير وتنقّل"`/`"Edit & navigate"`, `cwDockOut` `"السجل والتصدير"`/`"History & export"`; overflow menu `cwDockMore` `"أدوات أخرى"`/`"More tools"`, hint `"أدوات لم يعد لها متّسع في الشريط"`/`"Tools that no longer fit in the bar"` (`app.js:683-687`, `1780-1784`).

Right pane tabs (`app.js:75409-75414`): `preview` `"معاينة"`/`"Preview"`, `console` `"كونسول"`/`"Console"`, `chatTab` `"دردشة"`/`"Chat"`, plus a trash button `clearCon` `"مسح"`/`"Clear"`. The console tab shows a red dot (`has-errors`) when an error row arrives while it is not open; the Problems tab (`cwProbT.tab` `"المشاكل"`/`"Problems"`) is mounted by `cwProbMount` on desktop only.

### 5.2 File rail (`cwRenderTree`, `app.js:73472-73614`)

- Header `"الملفات"`/`"Files"` + count.
- Files are listed in **project order** (no sorting); a folder heading row is inserted the first time a directory appears, showing the directory path, the count of files in it, and a `+` (`cwFileOpsT.newFile` `"ملف جديد هنا"`/`"New file here"`). Folders collapse in memory only (`cwCollapsed`, not persisted).
- File row: colour badge from `CW_FILE_BADGE` (`app.js:73440`: html/htm `#e34c26 "<>"`, css `#8b5cf6 "#"`, js/mjs `#f7df1e "JS"`, jsx `#f7df1e "JX"`, … default `#9aa0a6 "·"`), basename only (full path as tooltip), size `max(1, round(chars/1024)) + "K"`, and a `✕` (`delF` `"حذف"`/`"delete"`) that asks `delFileC` `"حذف الملف؟"`/`"Delete this file?"`; deleting selects file 0 and refreshes the preview.
- Selecting a file commits the editor buffer first (`cwCommitEdit`) then loads the file.
- Context menu (`cwCtxItems`, `app.js:74946`) titles `ctxFileTitle` `"إجراءات الملف"`/`"File actions"`, `ctxDirTitle` `"إجراءات المجلد"`/`"Folder actions"`; items from `cwFileOpsT`: `rename` `"إعادة تسمية"`/`"Rename"`, `duplicate` `"تكرار"`/`"Duplicate"`, `del` `"حذف"`/`"Delete"`, `move` `"نقل (تغيير المسار)"`/`"Move (change path)"`, `newFolder` `"مجلد جديد"`/`"New folder"`, `newFile` `"ملف جديد هنا"`/`"New file here"`, `ctxNewHere` `"ملف جديد في هذا المجلد"`/`"New file in this folder"`, `ctxCopyPath` `"نسخ المسار"`/`"Copy path"` (→ `ctxCopied` `"نُسخ المسار ✓"`/`"Path copied ✓"`, `ctxCopyFail` `"تعذّر النسخ"`/`"Copy failed"`), `ctxFold` `"طيّ المجلد"`/`"Collapse folder"`, `ctxUnfold` `"فتح المجلد"`/`"Expand folder"`.
- Prompts/toasts (`app.js:73974-74062`): `renameTitle` `"المسار الجديد:"`/`"New path:"`, `moveTitle` `"المسار/المجلد الجديد لـ"`/`"New path / folder for"`, `newFolderTitle` `"اسم المجلد الجديد:"`/`"New folder name:"`, `newFileTitle` `"اسم الملف الجديد:"`/`"New file name:"`, `exists` `"المسار مستخدم بالفعل"`/`"That path is already taken"`, `capFull` `"بلغت الحد (30 ملفًا)"`/`"File limit reached (30)"`, `badName` `"اسم غير صالح"`/`"Invalid name"`, `renamed` `"أُعيدت التسمية ✓"`/`"Renamed ✓"`, `duplicated` `"تكرّر الملف ✓"`/`"Duplicated ✓"`, `moved` `"انتقل الملف ✓"`/`"Moved ✓"`, `folderMade` `"أُنشئ المجلد ✓"`/`"Folder created ✓"`, `copySuffix` `"-نسخة"`/`"-copy"`. New file from the bar: prompt `fileName` `"اسم الملف (مثل js/tools.js)"`/`"File name (e.g. js/tools.js)"`, duplicate → `"الملف موجود"`/`"File exists"`.
- Path sanitiser `cwSanitizePath`: trim, strip leading `/`, collapse `//`, replace `[^\w./ -]+` with `-`, cap 120, strip leading/trailing `-` (`app.js:73979`). A new folder is materialised as `<folder>/.gitkeep` (or `keep2.txt`…) because folders are implicit.
- Drag-and-drop move with reference rewriting (`cwDnd*`, `app.js:74132-74860`) and strings `cwDndT`: `toNew` `"إلى مجلد جديد…"`/`"To a new folder…"`, `toRoot` `"إلى الجذر"`/`"To the root"`, `movedTo` `"نُقل {n} إلى {d}"`/`"Moved {n} to {d}"`, `refsFixed` `"وحُدِّثت الإشارات"`/`"references updated"`, `undo` `"تراجع"`/`"Undo"`, `undone` `"أُلغي النقل ✓"`/`"Move undone ✓"`, `same` `"الملف في مكانه أصلًا"`/`"Already there"`, `intoSelf` `"لا يمكن نقل مجلد داخل نفسه"`/`"A folder cannot move inside itself"`, `taken` `"الوجهة فيها ملف بالاسم نفسه: {f}"`/`"The destination already has a file called {f}"`, `refuse` `"لم يُنقل — {r}"`/`"Not moved — {r}"`, `whyPy` `"{a} يستورد {b} كوحدة بايثون"`/`"{a} imports {b} as a Python module"`, `whyDyn` `"{a} يبني المسار وقت التشغيل: {b}"`/`"{a} builds the path at run time: {b}"`, counts `file1` `"ملفًا واحدًا"`/`"1 file"`, `file2` `"ملفين"`/`"2 files"`, `file3` `"{n} ملفات"`/`"{n} files"`, `file11` `"{n} ملفًا"`/`"{n} files"`.

### 5.3 Editor

- CodeMirror 5.65.16 from cdnjs with modes `xml`, `javascript`, `css`, `htmlmixed`, `python` (`app.js:60677-60694`); falls back to a plain `<textarea>`. Mode by extension (`cwModeFor`, `app.js:60695-60704`): `html/htm → htmlmixed`, `js/mjs/jsx → javascript`, `json → javascript(json)`, `css`, `py → python`, `xml/svg → xml`, else none. Native: highlight at least HTML, CSS, JS, JSON, Python, XML/SVG, Markdown.
- Editor is always `direction: ltr` even in the Arabic UI (`app.js:75463`).
- Human language labels (`cwLangLabel`, `app.js:66464`): html/htm `HTML`, css `CSS`, js/mjs/jsx `JavaScript`, json `JSON`, py `Python`, xml `XML`, svg `SVG`, md `Markdown`, txt `Text`, ts/tsx `TypeScript`, else `EXT.toUpperCase()` or `Text`.
- **Save/preview timing** (`app.js:75485-75519`): on every change set the save pill to `editing`; commit to the project (and PUT) after 900 ms idle; preview: if the active file is `.css` and auto-reload is on, push the stylesheet live into the running page immediately and schedule a full reload in 2500 ms; otherwise reload in 700 ms (`cwMaybeAutoPreview` honours the auto-reload toggle). Auto-snapshot is scheduled on every change (90 s, ≥20 s apart).
- `cwCommitEdit` (`app.js:66386-66401`): no-op when the buffer equals the stored content; otherwise writes the file, saves, updates the row size, optionally refreshes the preview, sets the pill to `saved`.
- **Open-file tabs** (`cwRenderTabs`, `app.js:65883-65961`; port of 21st.dev "Code block"): shown only when ≥2 files are open; basename + badge; close `✕` (`tabClose` `"إغلاق التبويب"`/`"Close tab"`); a copy button copies the **editor buffer** (`tabCopy` `"نسخ محتوى الملف"`/`"Copy file contents"`, → `tabCopied` `"نُسخ"`/`"Copied"` for 2 s). Closing the active tab lands on the left neighbour, else the right. Tabs store paths, never indices; scoped per project (`cwState.open/openFor`).
- **Breadcrumb** above the editor (desktop >860 only; `cwCrumbRender`, `app.js:66178`): folders muted, leaf strong; a folder crumb filters the rail (`crumbDir` `"تصفية الشجرة على هذا المجلد"`/`"Filter the tree to this folder"`), root crumb `crumbRoot` `"كل ملفات المشروع"`/`"All project files"`, overflow `crumbMore` `"مجلدات مطوية"`/`"Folded-away folders"`, copy path `crumbCopy`/`crumbCopied` `"نسخ المسار"`/`"نُسخ المسار"` — `"Copy path"`/`"Path copied"`.
- **Status bar** (`cwStatusBar`/`cwUpdateStatus`, `app.js:68749-68815`, `69303-69348`), left to right: position `T.ln + " " + line + ", " + T.col + " " + col` (`"سطر 5، عمود 7"` style via `ln` `"سطر"`/`"Ln"`, `col` `"عمود"`/`"Col"`), total lines `n + " " + cwPlLines(n)` (Arabic: 0/1/100s `سطر`, 2 `سطران`, 3–10 `أسطر`, 11–99 `سطرًا`), selection (hidden until non-empty) `sel` `"محدد"`/`"sel"` + chars [+ ` · ` lines], language label, size (`cwFmtSize`), runtime error count (hidden at 0), spacer, indent `"2 مسافات"`/`"2 spaces"` or `tabs` `"جدولة"`/`"Tab"` + width, encoding (turns red on U+FFFD), EOL (read-only), and the save pill with states `saved` `"محفوظ"`/`"Saved"`, `editing` `"تعديل…"`/`"Editing…"`, `saving` `"حفظ…"`/`"Saving…"`. Tooltips (STR): `cwStatPosTip` `"موضع المؤشر — اضغط للانتقال إلى سطر"`/`"Cursor position — click to go to a line"`, `cwStatLangTip` `"لغة الملف — اضغط لتبديل الملفات أو تنفيذ أمر"`/`"File language — click to switch file or run a command"`, `cwStatSizeTip` `"حجم الملف — اضغط لفتح اللقطات"`/`"File size — click for project snapshots"`, `cwStatProbsTip` `"أخطاء التشغيل — اضغط لعرضها في الكونسول"`/`"Runtime errors — click to see them in the console"`, `cwStatIndentTip` `"مقدار الإزاحة — اضغط لتغييره"`/`"Indent width — click to change it"`, `cwStatEolTip` `"نهايات الأسطر في هذا الملف"`/`"Line endings in this file"`, `cwStatSaveTip` `"حالة الحفظ — اضغط للحفظ الآن"`/`"Save state — click to save now"`. Popovers: go-to-line (`popGoto` `"الانتقال إلى سطر"`/`"Go to line"`, placeholder `gotoPh` `"سطر أو سطر:عمود"`/`"line or line:column"`, `go` `"انتقل"`/`"Go"`), document statistics (`popStats` `"إحصاءات المستند"`/`"Document statistics"`: `stLines` `"الأسطر"`/`"Lines"`, `stBlank` `"أسطر فارغة"`/`"Blank lines"`, `stWords` `"الكلمات"`/`"Words"`, `stChars` `"الأحرف"`/`"Characters"`, `stBytes` `"البايتات"`/`"Bytes"`, `stLongest` `"أطول سطر"`/`"Longest line"`, `stIndent` `"إزاحة الملف المكتشفة"`/`"Indent this file uses"`, `useIndent` `"طابق إزاحة الملف"`/`"Match the file’s indent"`), encoding (`popEnc` `"الترميز ونهايات الأسطر"`/`"Encoding and line endings"`, `encName` `"الترميز"`/`"Encoding"`, `encBom` `"علامة ترتيب البايت"`/`"Byte-order mark"`, `encEol` `"نهايات الأسطر"`/`"Line endings"`, `encNon` `"أحرف غير لاتينية"`/`"Non-ASCII characters"`, `encBad` `"أحرف تالفة"`/`"Damaged characters"`, `findNon` `"التالي غير اللاتيني"`/`"Next non-ASCII"`, `findBad` `"التالي التالف"`/`"Next damaged"`, `none` `"لا يوجد المزيد"`/`"Nothing more to find"`, `eolNote` `"المحرر يوحّد نهايات الأسطر على LF عند الفتح، لذلك هذه قراءة وليست مفتاحًا."`/`"The editor normalises line endings to LF on open, so this is a reading and not a switch."`).
- **Editor preferences** (`cwPrefsT`/`cwPrefsClamp`, `app.js:68273-68375`): stored as `{ fs, tab, spc, wrap, num, ws, cur }`; clamp: `fs` 10–22 else default (13 on a narrow <760 px viewport, otherwise the stylesheet's 13 px), `tab` 2|4|8 (default 2), `spc` 1 (spaces) default, `wrap` default on when narrow, `num` on, `ws` `off|trail|all`, `cur` `line|block|under`. Labels: `title` `"تفضيلات المحرّر"`/`"Editor preferences"`, `sub` `"تُحفظ على هذا الجهاز وتنطبق على كل مشاريعك"`/`"Kept on this device, and used by every project you open"`, `fs` `"حجم الخط"`/`"Font size"` (`"قياس الشيفرة داخل المحرّر"`/`"How large the code is drawn"`), `tab` `"عرض الإزاحة"`/`"Indent width"` (`"كم مسافة يساوي التاب الواحد"`/`"How many columns one tab is worth"`), `spc` `"إزاحة بمسافات"`/`"Indent with spaces"` (`"مفتاح Tab يُدخل مسافات بدل محرف تاب"`/`"Tab inserts spaces instead of a tab character"`), `wrap` `"لفّ الأسطر"`/`"Word wrap"` (`"السطر الطويل ينزل بدل شريط تمرير أفقي"`/`"Long lines fold instead of scrolling sideways"`), `num` `"أرقام الأسطر"`/`"Line numbers"` (`"العمود على حافة المحرّر"`/`"The gutter down the edge of the editor"`), `ws` `"إظهار المسافات"`/`"Show whitespace"` (`"نقطة مكان كل مسافة، وخط مكان التاب"`/`"A dot for every space, a rule across every tab"`; options `wsOff` `"بلا"`/`"Off"`, `wsTrail` `"آخر السطر"`/`"Trailing"`, `wsAll` `"الكل"`/`"All"`), `cur` `"شكل المؤشّر"`/`"Cursor"` (`"خط رفيع، أو مربّع، أو شرطة تحت الحرف"`/`"A thin caret, a block, or an underline"`; `curLine` `"خط"`/`"Line"`, `curBlock` `"مربّع"`/`"Block"`, `curUnder` `"شرطة"`/`"Underline"`), `on` `"مفعّل"`/`"On"`, `off` `"معطّل"`/`"Off"`, `reset` `"إرجاع الافتراضي"`/`"Reset to defaults"`, `resetDone` `"رجعت التفضيلات إلى الافتراضي"`/`"Editor preferences reset"`, `done` `"تمّ"`/`"Done"`, `close` `"إغلاق"`/`"Close"`, `btnH` `"تفضيلات المحرّر — الخط والإزاحة واللفّ"`/`"Editor preferences — size, indent and wrap"`, `smaller` `"خط أصغر"`/`"Smaller"`, `bigger` `"خط أكبر"`/`"Larger"`.
- Other editor surfaces (all 21st.dev ports, §11) that a first native release can defer: minimap (`mapTitle` `"خريطة الملف"`/`"Document overview"`, ≥200 lines only, desktop), indent guides + bracket pairs (`cwIgT.lbl` `"الخطوط"`/`"Guides"`), multiple cursors (`cwMcT` counts `"مؤشر واحد"`, `"مؤشران"`, `"{n} مؤشرات"`, `"{n} مؤشرًا"`, `"{n} مؤشر"` / `"1 cursor"`, `"2 cursors"`, `"{n} cursors"`), change gutter vs last snapshot (`cwGutT`: `gut` `"شريط التغييرات"`/`"Change gutter"`, `add` `"مضاف"`/`"Added"`, `chg` `"معدّل"`/`"Changed"`, `del` `"محذوف"`/`"Removed"`, `revert` `"استرجاع المقطع"`/`"Revert hunk"`, `reverted` `"استُرجع المقطع ✓"`/`"Hunk reverted ✓"`, `next` `"التغيير التالي — Alt+G"`/`"Next change — Alt+G"`), quick fixes (`cwQfT.title` `"إصلاحات سريعة"`/`"Quick fixes"`, `apply` `"طبّق"`/`"Apply"`, `create` `"أنشئ الملف"`/`"Create file"`, `ignore` `"تجاهل"`/`"Ignore"`, `all` `"طبّق كل الإصلاحات"`/`"Apply every fix"`, `done` `"طُبّق الإصلاح ✓"`/`"Fix applied ✓"`, `stale` `"تغيّر الملف بعد الفحص — أُعيد الفحص ولم يُكتب شيء"`/`"The file moved after the scan — rescanned, nothing was written"`, `empty` `"لا مشاكل يمكن للمحرّر إثباتها في هذا المشروع."`/`"Nothing the editor can prove is wrong in this project."`), outline (`cwOutlineT`: `filterPh` `"صفِّ الرموز…"`/`"Filter symbols…"`, `none` `"لا رموز في هذا الملف"`/`"No symbols in this file"`, `noKind` `"المخطط يقرأ ملفات JavaScript وCSS وHTML"`/`"The outline reads JavaScript, CSS and HTML files"`, kinds `fn` `"دالة"`/`"function"`, `cls` `"صنف"`/`"class"`, `method` `"دالة داخل صنف"`/`"method"`, `sel` `"محدِّد"`/`"selector"`, `at` `"قاعدة @"`/`"at-rule"`, `id` `"معرّف عنصر"`/`"element id"`, `h` `"عنوان"`/`"heading"`), find/replace (`cwFindT`: `findPh` `"ابحث عن…"`/`"Find…"`, `replacePh` `"استبدل بـ…"`/`"Replace with…"`, `inFile` `"هذا الملف"`/`"This file"`, `inAll` `"كل الملفات"`/`"All files"`, `matchCase` `"مطابقة حالة الأحرف"`/`"Match case"`, `wholeWord` `"كلمة كاملة"`/`"Whole word"`, `replaceAll` `"استبدال الكل"`/`"Replace all"`, `none` `"لا نتائج"`/`"No results"`, `empty` `"اكتب كلمة للبحث عنها"`/`"Type something to search for"`, `capped` `"القائمة مختصرة — والاستبدال يشمل كل النتائج"`/`"List truncated — replace still covers every match"`, `tooBig` `"الاستبدال سيتجاوز حدّ حجم المشروع — لم يُنفَّذ"`/`"Replacing would exceed the project size limit — nothing was changed"`, `undone` `"رجعت الملفات كما كانت ✓"`/`"Files put back ✓"`, results `n` + (1 `" نتيجة"`, 2 `" نتيجتان"`, ≤10 `" نتائج"`, else `" نتيجة"`) + `" في "` + f + (1 `" ملف"`, 2 `" ملفان"`, ≤10 `" ملفات"`, else `" ملفًا"`)).
- **Version history** (`cwSnapT`, `app.js:77794`): `title` `"سجل النسخ"`/`"Version history"`, `snapNow` `"احفظ نسخة"`/`"Snapshot"`, `saved` `"حُفظت نسخة ✓"`/`"Snapshot saved ✓"`, `manual` `"يدوي"`/`"manual"`, `auto` `"تلقائي"`/`"auto"`, `restore` `"استرجاع"`/`"Restore"`, `restored` `"استُرجعت النسخة ✓"`/`"Version restored ✓"`, `confirm` `"استرجاع هذه النسخة سيستبدل الملفات الحالية (تُحفظ نسخة تلقائية أولًا). متابعة؟"`/`"Restoring this version replaces the current files (an auto-snapshot is saved first). Continue?"`, `empty` `"لا نسخ بعد — عدّل مشروعك أو اضغط «احفظ نسخة»."`/`"No snapshots yet — edit your project or press \"Snapshot\"."`, `delAll` `"مسح السجل"`/`"Clear history"`, `delAllC` `"مسح كل النسخ لهذا المشروع؟"`/`"Clear all snapshots for this project?"`, `current` `"الحالية"`/`"current"`, `firstPt` `"أول نقطة حفظ"`/`"First save point"`, `noChg` `"لا شيء تغيّر عن النقطة السابقة"`/`"Nothing changed since the point below"`, `today` `"اليوم"`/`"Today"`, `yday` `"أمس"`/`"Yesterday"`, `vsCur` `"مقابل الحالية"`/`"vs current"`, `noRoom` `"لا مساحة في هذا المتصفح — حُذفت أقدم النقاط"`/`"No room left in this browser — the oldest save points were dropped"`, relative times `now` `"الآن"`/`"just now"`, `"قبل {n} د"`/`"{n}m ago"`, `"قبل {n} س"`/`"{n}h ago"`, `"قبل {n} يوم"`/`"{n}d ago"`. Snapshot record `{ id, ts, kind: "manual"|"auto", name, files, sig(djb2), label(≤80) }`; a snapshot equal to the previous signature is skipped. Compare two versions (`cwCmpT.title` `"مقارنة نسختين"`/`"Compare versions"`, `identical` `"النسختان متطابقتان — لا ملف اختلف بينهما."`/`"The two versions are identical — no file differs."`, `busy` `"الذكاء يشتغل على ملفاتك الآن — أنهِ ذلك أولًا."`/`"The AI is working on your files — finish that first."`). Change log (`cwClogTitle` `"سجل التغييرات"`/`"Change log"`, `cwClogT.empty` `"لا تغييرات بعد — اطلب من الذكاء تعديلًا على مشروعك وسيُسجَّل هنا."`/`"No changes yet — ask the AI for an edit and it is recorded here."`, `srcAi` `"الذكاء"`/`"AI"`, `srcImprove` `"التطوير"`/`"Improve"`, `undone` `"متراجَع عنه"`/`"undone"`, `noSum` `"تعديل بلا وصف"`/`"Untitled edit"`).
- **Keyboard** (desktop; from `cwKbdGroups`, `app.js:76932-77003`, and the workspace/CodeMirror handlers `app.js:75470-75484`, `75694-75730`): Ctrl/Cmd+S save+refresh (toast `saved` `"حُفظ ✓"`/`"Saved ✓"`), Ctrl/Cmd+Enter run, Ctrl/Cmd+K or P palette, Ctrl/Cmd+F find in file, Ctrl/Cmd+Shift+F find all, Alt+O outline, Alt+↑/↓ previous/next file, Shift+F10 row menu, `?` shortcut sheet, `@` file mention in the AI bar, Ctrl+. quick fix, Ctrl+D / Ctrl+Shift+D / Ctrl+Shift+L multi-cursor, Shift+Alt+↑/↓ cursor above/below, Shift+Alt+I split, Ctrl+Shift+K delete line, Esc collapse; tree: ↑↓, ←→ fold, Home/End, `*` open all, Enter/Space open, Ctrl+A/X/V select-cut-drop, Esc clear. Useful on iPad with a hardware keyboard; not required on phone.

### 5.4 Preview pane

**Assembly** (`projPreviewHtml(proj, entryPath)`, `app.js:50933-51027`) — reproduce exactly:

1. Entry = `entryPath` if it matches a file (paths normalised by stripping `./` and leading `/`), else the first `index.html`/`index.htm` at any depth, else the first `*.html`; none → return `null` (preview shows the empty state).
2. Asset lookup `findAsset(ref, ext)`: exact normalised path → case-insensitive path → same basename in any directory → the only file of that extension in the project.
3. Replace every `<link … href="X.css" …>` (optionally followed by `</link>`) whose href is **not external** (`^(https?:)?//` or `^data:`) with `<style>\n<content>\n</style>` when resolvable; otherwise leave the tag.
4. Module support: if the HTML has `<script type="module">` or an importmap, every local `.js/.mjs` file is registered as a Blob URL (with its own local import specifiers rewritten to `@firasmod/<path>` keys); an author importmap is merged (local targets → blob URLs), or a fresh `<script type="importmap">` is injected after `<head>`. Bare specifiers (`three`, `react`) are untouched.
5. Replace `<script … src="X.js|mjs" …></script>` (non-external, resolvable) with an inline `<script>` — `type="module"` preserved with rewritten specifiers; classic scripts inlined verbatim. External (CDN) scripts stay.
6. The document is then wrapped by `cwComputerInject(html)` = `CW_CONSOLE_HOOK + CW_COMPUTER_HOOK` prepended (`app.js:60809-60815`) and set as `srcdoc`.

**Native mapping**: `WKWebView.loadHTMLString(html, baseURL: nil)`. Blob URLs are not usable for an import map in a file-less document; use `data:text/javascript;base64,` URLs for module entries (equivalent semantics) or a `WKURLSchemeHandler` (`firas-proj://`) that serves the project files by path — the second also makes `fetch("data/x.json")` and `<img src="assets/…">` work, which the web preview cannot. Keep step 3/5 inlining for classic scripts so behaviour matches the web.

**Sandbox**: web iframe `sandbox="allow-scripts allow-modals allow-pointer-lock allow-popups allow-forms allow-downloads"` — **no** `allow-same-origin`, so `localStorage`, cookies, service workers and popups-to-app are unavailable to previewed code (`app.js:75427`, and the note the fix prompt sends, `app.js:76641`). In WKWebView use a non-persistent `WKWebsiteDataStore`, block navigation away from the document (`decidePolicyFor`: allow only `about:blank`/the loaded document and `#anchors`; open external `http(s)` links in Safari), and give the preview its own process pool.

**Console hook** protocol (`CW_CONSOLE_HOOK`, `app.js:60736`) → `WKScriptMessageHandler` named e.g. `fcw`:

```json
{ "__fcw": 1, "t": "log"|"warn"|"error"|"info", "m": "<args joined by space, objects JSON.stringify(…).slice(0,300), whole line slice(0,600)>",
  "file": "", "line": 0, "col": 0, "stack": "<≤1200>" }   // file/line/col/stack only for window.error / unhandledrejection ("Promise: <reason>")
```

It also listens for `{ __fcwCss: 1, path, text }` and swaps in a `<style id="fcw-live-<encodeURIComponent(path)>">`, disabling any sibling `<style data-fcw-path=path>` — this is the live-CSS push (`cwPushLiveCss`, `app.js:63724`). Native: `evaluateJavaScript` the same message.

Client side of a console message (`cwWireConsoleListener`, `app.js:60738-60783`): append a row `.cw-conrow--<t>`; if a Python run currently owns the console, do not show the row (still count it); on `error`, push the message into `cwState.liveErrors` (dedup, max 30, ≤600 chars) which the fix loop and the "fix console errors" palette action read; mark the console tab with the dot; push a deck card (§5.5).

**Refresh** (`cwRefreshPreview`, `app.js:64178-64232`): ends any live-build strip; picks the entry page (Firas Computer's page selector, else default); if `null` shows the empty state (`cwePrevT` `"لا شيء لعرضه بعد"`/`"Nothing to preview yet"`, `cwePrevD` `"المعاينة تحتاج صفحة HTML واحدة على الأقل. أنشئ index.html أو اطلب من فِراس أن يبنيها لك."`/`"A preview needs at least one HTML page. Create an index.html, or ask Firas to build it for you."`, buttons `cweNewHtml` `"أنشئ index.html"`/`"Create index.html"` (creates a starter with `lang/dir` from the UI language, title `"صفحتي"`/`"My page"`, `<h1>` `"مرحبًا"`/`"Hello"`, `app.js:63883-63920`) and `cweAsk` `"اطلب من فِراس"`/`"Ask Firas"`); otherwise a stand-in document `"أضف ملف index.html للمعاينة"`/`"Add an index.html to preview"` is never reached in practice. Clears the console (unless Python owns it), removes the error dot, starts the run clock, resets runtime problems, then loads.

**Live build strip** (`cwLive*`, `app.js:63981-64175`): while an in-tab build lands files one by one, the preview repaints from the merged set at most one paint at a time, only when the pane is visible, with reduced permissions (`sandbox="allow-scripts"`) and **without** the console hook; unresolved local `<link>`/`<script src>` tags are stripped (`cwLiveStrip`) so a half-built page does not 404; a badge `livePrev` `"يُبنى الآن"`/`"Building"` (tooltip `livePrevHint` `"معاينة حيّة — كل ملف يظهر لحظة اكتماله"`/`"Live preview — every file shows the moment it lands"`) sits in the chrome; a set older than 180 s is abandoned. For the server build the same visual is achieved by refreshing after each checkpoint that lands.

**Chrome strip** (`app.js:75418`, `65780-65844`): three dots + address `preview + " · localhost"` initially, then `cwPrevAddr` = `geom + " · " + label` where geom is `"localhost"` (desktop) or `"390 × 844"` (+ `" · 87%"` when scaled) with `dir=ltr`. Device segment (`CW_DEVICES`, `app.js:65683`): `mobile` 390×844 bezel 11 (`"جوال"`/`"Mobile"`), `tablet` 834×1112 bezel 15 (`"لوحي"`/`"Tablet"`), `desktop` fluid (`"سطح"`/`"Desktop"`; tooltip `"سطح المكتب"`). Controls (`cwPrevT`): auto-reload toggle `auto` `"تحديث تلقائي"`/`"Auto"` (tooltips `autoOn` `"التحديث التلقائي مُفعّل"`/`"Auto-reload on"`, `autoOff` `"التحديث التلقائي مُعطّل"`/`"Auto-reload off"`), rotate (`cwRotT.toLand` `"دوّر للوضع الأفقي"`/`"Rotate to landscape"`, `toPort` `"دوّر للوضع العمودي"`/`"Rotate to portrait"`; hidden on desktop), reload `reload` `"إعادة تحميل المعاينة"`/`"Reload preview"`, open in new tab `newtab` `"فتح في تبويب جديد"`/`"Open in new tab"` (failure toasts `"أضف ملف index.html أولًا"`/`"Add an index.html first"`, `"اسمح بالنوافذ المنبثقة"`/`"Allow pop-ups to open the tab"`, `"تعذّر فتح التبويب"`/`"Couldn't open the tab"`). On a phone the pane IS the device: no chassis, segment hidden (`app.js:65717-65720`).

**Run status strip** (`cwRunBar*`, `app.js:64500-64620`; port of 21st.dev "Status"): states `idle|run|ok|warn|fail` with labels `rbIdle` `"لم يُشغّل بعد"`/`"Not run yet"`, `rbRun` `"يشتغل…"`/`"Running…"`, `rbOk` `"يعمل"`/`"Working"`, `rbWarnOk` `"يعمل مع تحذيرات"`/`"Works, with warnings"`, `rbFail` `"فشل التشغيل"`/`"Run failed"`, counters `rbErrs` `"أخطاء"`/`"errors"`, `rbWarns` `"تحذيرات"`/`"warnings"`, `rbTime` `"زمن آخر تشغيل"`/`"Last run time"`, `rbRerun` `"أعد التشغيل"`/`"Re-run"`, `rbOpen` `"افتح الكونسول"`/`"Open the console"`. Verdict: fail if the run returned not-ok or any error row; warn if any warn row; else ok. The clock closes on the iframe `load` event; a run shorter than 200 ms never repaints (auto-reload flicker guard). Duration format `cwRunBarMs`: `<1000` → `"412ms"`, `<10000` → `"2.3s"`, else `"12s"`. Task bar (`cwTb*`) additionally lists every runnable target (`index.html` pages and `.py` files) with `tbPick` `"اختر ما يُشغّل"`/`"Choose what to run"`, `tbNone` `"لا شيء يُشغّل هنا — أضف ملف index.html أو ملف بايثون"`/`"Nothing to run here — add an index.html or a .py file"`, `tbNever` `"لم يُشغّل"`/`"Not run"`.

### 5.5 Console pane

- Rows (`cwConRow`, `app.js:64473-64485`): classes `log|warn|error|info|ok|run`; colours on `#141412`: text `#c9c7bf`, error `#ff8a80`, warn `#ffd54f`, info/run `#81d4fa`, ok `#8fd694` (`styles.css:5889-5901`); mono 12px, LTR, `white-space: pre-wrap`. App-authored rows (`msg=true`) use `dir=auto` so Arabic sentences read correctly.
- Toolbar (`cwConsoleUiInit`, `app.js:64266-64466`; port of 21st.dev "Interactive Logs Table"): level chips with counts `conAll` `"الكل"`/`"All"`, `conErr` `"أخطاء"`/`"Errors"`, `conWarn` `"تحذيرات"`/`"Warnings"`, `conLog` `"سجل"`/`"Logs"`; text filter `conFind` `"تصفية المخرجات…"`/`"Filter output…"`; clock toggle `conTime` `"إظهار وقت كل سطر"`/`"Show a clock on every line"` (timestamp is a `data-t` attribute, never row text); empty states `cweConT` `"الكونسول ساكن"`/`"The console is quiet"`, `cweConD` `"شغّل المشروع أو نفّذ ملف بايثون، وستنزل السطور هنا واحدًا تلو الآخر."`/`"Run the project or execute a Python file and the lines land here one after another."` with `cweRun` `"شغّل المشروع"`/`"Run the project"` + Ask Firas; filtered-out state `conNone` `"لا يوجد سطر يطابق التصفية."`/`"No line matches the filter."`. Filtering hides rows; it never removes them.
- Console owner: `cwState.conOwner` is `"py"` after a Python run (so an auto-reload of the preview must not clear the traceback) and returns to `"preview"` on an explicit Run press, Clear, or when the selection moves off a `.py` file (`app.js:64203-64206`, `65621`, `65296-65300`).
- Notification deck (`cwDeck*`, `app.js:65325-65600`; port of 21st.dev "Toast"; desktop only, max 4 cards): `cwDeckPrevT` `"حُدّثت المعاينة"`/`"Preview reloaded"` + `cwDeckPrevD` `"أُعيد بناء الصفحة من ملفاتك كما هي الآن."`/`"The page was rebuilt from your files as they stand now."` with `cwDeckOpenTab` `"افتحها في تبويب"`/`"Open in a tab"`; `cwDeckPyT` `"جارٍ تشغيل بايثون…"`/`"Running Python…"`, `cwDeckPyOkT` `"انتهى التشغيل"`/`"Run finished"`, `cwDeckPyErrT` `"توقّف التشغيل عند خطأ"`/`"Run stopped at an error"`; `cwDeckErrT` `"أخطاء في الصفحة"`/`"Errors on the page"` with actions `cwDeckConsole` `"افتح الكونسول"`/`"Open the console"` and `cwDeckFix` `"أصلِح بالذكاء"`/`"Fix it with AI"` which prefills the AI bar with `cwDeckFixAsk` `"التطبيق قيد التشغيل يُسجّل هذه الأخطاء — جد السبب عبر الملفات وأصلحه:"`/`"The running app logs these errors — find the cause across the files and fix it:"` + the error lines; close `cwDeckClose` `"إخفاء الإشعار"`/`"Dismiss notification"`.
- Problems panel (`cwProbT`, desktop): tab `"المشاكل"`/`"Problems"`, `check` `"افحص المشروع"`/`"Check the project"`, `recheck` `"أعد الفحص"`/`"Check again"`, `checking` `"يفحص…"`/`"Checking…"`, `clear` `"أفرغ أخطاء التشغيل"`/`"Clear runtime errors"`, `idleT` `"لم يُفحص المشروع بعد"`/`"This project has not been checked"`, `idleD` `"اضغط «افحص المشروع» ليُقرأ كل ملف، وتُجمع أخطاء التشغيل والمراجع المكسورة في مكان واحد."`/`"Press “Check the project” to read every file and gather the runtime errors and broken references in one place."`, `emptyT` `"ما في شيء مكسور"`/`"Nothing is broken"`, `emptyD` `"الفحص الأخير ما لقى خطأ تشغيل، ولا ملفًا يرفض أن يُقرأ."`/`"The last check found no runtime error, and no file that refuses to parse."`, sources `srcRun` `"تشغيل"`/`"runtime"`, `srcParse` `"تحليل"`/`"parse"`, `srcLint` `"مراجعة"`/`"review"`, `approx` `"سطر تقريبي: المعاينة تدمج الملفات في صفحة واحدة، فرقم سطرها لا يخصّ ملفك. هذا أوّل موضع لهذا الرمز في الملف."`/`"Approximate line: the preview merges your files into one page, so its line number is not yours. This is the first place that symbol appears in the file."`, counts (Intl.PluralRules): `errZero` `"لا أخطاء"`, `errOne` `"خطأ واحد"`, `errTwo` `"خطآن"`, `errFew` `"{n} أخطاء"`, `errMany` `"{n} خطأً"`, `errOther` `"{n} خطأ"` / `"no errors"`, `"1 error"`, `"2 errors"`, `"{n} errors"`; warnings `"لا تحذيرات"`, `"تحذير واحد"`, `"تحذيران"`, `"{n} تحذيرات"`, `"{n} تحذيرًا"`, `"{n} تحذير"` / `"no warnings"`, `"1 warning"`, `"2 warnings"`, `"{n} warnings"`.

### 5.6 Running Python (`cwRunPython`, `app.js:65604-65667`)

- Target rule (`cwPyEntry`, `app.js:64234-64243`): the selected file if it is `.py`; else if the project has any HTML the button previews instead; else `main.py|app.py|run.py|__main__.py` at any depth, else the first `.py`.
- Runs `runPythonInSandbox(code, 15000, { files, filename })` (`app.js:51333-51355`): Pyodide 0.26.2 in a Worker; every project `.py` is written to `/home/pyodide/_firas_proj` so sibling imports resolve; third-party imports (anything outside `PY_STDLIB` = `os sys re math random json datetime time collections itertools functools typing string decimal fractions statistics heapq bisect copy abc enum dataclasses pathlib io csv hashlib base64 textwrap unicodedata calendar pprint operator struct array queue threading asyncio contextlib warnings traceback argparse __future__` and the project's own modules) are refused up front. Result `{ ok, out(≤4000), err(≤2000) }` or `{ skipped:true, reason: "thirdparty"|"engine" }`.
- Console script: clear; `run` row `pyStart + " " + path` (`"تشغيل main.py"` / `"Running main.py"`); button label `pyBusy` `"يشغّل…"`/`"Running…"`; skipped → `warn` row `pyEngine` `"تعذّر تحميل محرّك بايثون. تحقّق من اتصالك بالإنترنت ثم أعد المحاولة."`/`"Couldn't load the Python engine. Check your connection and try again."` or `pyThird` `"هذا السكربت يستورد مكتبة خارجية غير متوفّرة داخل المتصفح — المتاح هنا مكتبة بايثون القياسية فقط (math, json, re, datetime, collections …)."`/`"This script imports a third-party library, which isn't available in the browser — only the Python standard library runs here (math, json, re, datetime, collections …)."` and the run is marked failed; stdout → `log` row; traceback → `error` row with `<exec>` frames and the sandbox directory prefix stripped, or `pyTimeout` `"أُوقف السكربت بعد تجاوزه الحدّ الزمني (١٥ ثانية) — غالبًا حلقة لا تنتهي. صفحتك ومشروعك بخير، والتشغيل التالي يحتاج ثوانيَ إضافية لإعادة تشغيل المحرّك."`/`"Stopped after passing the 15-second limit — usually an endless loop. Your page and project are fine; the next run needs a few extra seconds to restart the engine."`; no output → `info` `pyEmpty` `"(انتهى التنفيذ بلا مخرجات)"`/`"(finished with no output)"`; success → `ok` row `pyDone + " " + secs + "s"` (`"انتهى التنفيذ في 0.8s"` / `"Finished in 0.8s"`).
- Native: there is no Pyodide in WKWebView without loading it from the CDN inside the web view (feasible: load `https://cdn.jsdelivr.net/pyodide/v0.26.2/full/pyodide.js` in a hidden WKWebView and call it — ~10 MB download, needs the same `PY_STDLIB` gate and a 15 s watchdog). If deferred, hide Run for `.py` and show `pyEngine`.

### 5.7 Firas Computer (summary only)

A control drawer inside the preview pane that lets the model drive the previewed page through a fixed bridge (`CW_COMPUTER_HOOK`, `app.js:60785`; `cwComputerRun`, `app.js:60998-61038`): snapshot → model returns one JSON action (`snapshot|click|input|focus|key|scroll|waitFor|done`) on tier `max` via `agentCall` → bridge executes → 10 steps max (`CW_COMPUTER_STEPS`), charged once per run (`chargeUsage("code", "computer:"+session)`). Strings: `compTitle` `"حاسوب فِراس"`/`"Firas Computer"`, `compReady` `"جاهز للتحكم"`/`"Ready for control"`, `compRunning` `"ينفّذ المهمة"`/`"Running task"`, `compStopped` `"متوقف"`/`"Stopped"`, `compPage` `"صفحة المعاينة"`/`"Preview page"`, `compIdle` `"بانتظار مهمة"`/`"Waiting for a task"`, `compTask` `"اكتب ما تريد اختباره داخل المعاينة"`/`"Describe what to test inside the preview"` (textarea `maxlength=1200`), `compTaskLabel` `"مهمة حاسوب فراس"`/`"Firas Computer task"`, `compGo` `"ابدأ"`/`"Start"`, `compStop` `"إيقاف"`/`"Stop"`, `compNote` `"التحكم يعمل داخل المعاينة فقط ويحتاج بقاء هذه الصفحة مفتوحة."`/`"Control works only inside this preview and requires this page to remain open."`, `compActivity` `"النشاط"`/`"Activity"`, `compActivityTitle` `"سجل نشاط حاسوب فِراس"`/`"Firas Computer activity"`, `compActivityClose` `"طيّ النشاط"`/`"Collapse activity"`, `compNoPage` `"لا توجد صفحة HTML"`/`"No HTML page"`, `compQuota` `"تم الوصول إلى الحد اليومي"`/`"Daily limit reached"`, `compFail` `"تعذرت المهمة"`/`"Task failed"`, `compDone` `"اكتملت المهمة"`/`"Task completed"`, `compLimit` `"تم الوصول إلى حدّ الخطوات"`/`"Step limit reached"`, log labels `compSnapshot` `"ملاحظة الواجهة"`/`"Observed interface"`, `compClick` `"تنفيذ نقرة"`/`"Executed click"`, `compInput` `"تنفيذ إدخال نص"`/`"Executed text input"`, `compFocus` `"تنفيذ تركيز"`/`"Executed focus"`, `compKey` `"تنفيذ مفتاح"`/`"Executed key"`, `compScroll` `"تنفيذ تمرير"`/`"Executed scroll"`, `compWait` `"رصد نتيجة الانتظار"`/`"Observed wait result"`. Defer for v1 unless the agent slice covers it.

---

## 6. AI command bar — follow-up edits

### 6.1 Composer (`app.js:75432-75439`, `75732-75797`)

- Paper-clip (same accept list as the home screen), textarea `rows=1 maxlength=1200 dir=auto`, placeholder `aiPh` `"اطلب تعديلًا على المشروع…"`/`"Ask for a project change…"`, submit `aiGo` `"نفّذ"`/`"Run"`. On a phone Enter sends and Shift+Enter inserts a newline; the textarea auto-grows.
- `@` mention popup: typing `@token` at the caret shows up to 8 fuzzy matches over project paths/basenames; Enter/Tab inserts `@path ` (`app.js:75746-75801`).
- Submit: ask = text, or if empty and attachments are staged, `attGo`; empty → ignore. Still reading images → toast `attRead`. Commit the editor. Push the user turn into the thread as `ask + (attN ? "\n\n" + attIn.replace("{n}", attN) : "")` where `attIn` = `"— مرفقات: {n}"`/`"— attachments: {n}"`. Disable the bar, set the button to `working` `"يفكر ويعدّل…"`/`"Thinking & editing…"`, record `cwState.pending = { since }` so the Chat tab draws a live bubble `threadLive` `"يفكر ويعدّل…"`/`"Thinking & editing…"` + `threadLiveFor` `"منذ {n}ث"`/`"{n}s so far"` (seconds recomputed at every repaint).
- Attachments → `cwTakeAttach(ask, CW_ATT_MAX=60000, onStage)` (§6.4).
- Result handling: `quotaBlocked` → nothing more (the toast already spoke); `answer` → push AI turn and reveal it with a typewriter; no changes → toast + AI turn `nothing` `"لا تغييرات مقترحة"`/`"No changes proposed"`; changes → open the diff overlay and push an AI turn `summary || applied` with `n = changes.length`; thrown → toast + AI turn `aiFail` `"تعذّر التعديل — جرّب ثانية"`/`"Couldn't edit — try again"`. Input is cleared only on success.

Chat tab (`cwRenderThread`, `app.js:76224-76311`): empty state `threadEmpty` `"ابدأ محادثة مع فراس — اطلب تعديلًا أو ميزة وسيظهر الحوار هنا."`/`"Start a conversation with Firas — ask for a change or a feature and the dialogue shows up here."` plus a chip `"اشرح لي هذا المشروع"`/`"Explain this project"` that submits exactly that phrase; turn labels `youLbl` `"أنت"`/`"You"`, `aiLbl` `"فراس"`/`"Firas"`; AI turns show a `n ملف`/`n file(s)` chip; user turns echo `@file` references as chips (unmatched ones muted with title `"لا ملف يطابق"`/`"no file matches"`). Scroll pins to the bottom only when the reader was already there.

### 6.2 Routing inside `cwAskAI(chat, instruction, attached)` (`app.js:75888-76189`)

`req = instruction.slice(0, 24000)`; the attachment text `att` is appended only where a model reads the request, never to the routing regexes.

1. **Document redirect** — if `req` mentions a document format (`/\b(pdf|word|docx|powerpoint|pptx|excel|xlsx|csv|slides?|deck|presentation|report|whitepaper|ebook|booklet|brochure)\b|ملف|مستند|وثيقة|تقرير|عرض\s*تقديمي|شرائح|بوربوينت|وورد|اكسل|كتيّ?ب|بحث/i`) the intent classifier runs with `{ product: "code" }`; a document verdict returns the answer `codeDeliverableRedirectText` (no charge): `"هذا طلب **مستند**، لا مشروع برمجي — وفِراس كود يبني مواقع وتطبيقات فقط، فلو نفّذتُه هنا لخرجت لك ملفات HTML بدل ما طلبت.\n\nافتح **فِراس AI** من مبدّل المنتجات في الأعلى، والصق الطلب نفسه هناك — يبنيه مستندًا حقيقيًا قابلًا للتحميل."` / `"This is a **document** request, not a software project — and Firas Code only builds sites and apps, so running it here would hand you HTML files instead of what you asked for.\n\nOpen **Firas AI** from the product switcher above and paste the same request there; it will build it as a real, downloadable document."` (`app.js:75880-75886`).
2. **Charge** one Code unit (§4); refusal → `{ changes:[], dels:[], quotaBlocked:true }`.
3. **Question** (`cwIsQuestion`, `app.js:75820-75838`): an edit verb (`add|change|edit|modify|delete|remove|create|make|build|fix|repair|improve|refactor|rename|move|update|implement|convert|replace|split|extract|style|set|write|generate|redesign` or Arabic `أضف|اضف|أضيف|اضيف|نضيف|ضيف|غيّر|غير|تغيير|عدّل|عدل|تعديل|احذف|امسح|حذف|اصنع|اعمل|سوّي|سوي|أنشئ|انشئ|اجعل|خلّي|خلي|صلّح|صلح|أصلح|اصلح|إصلاح|حسّن|حسن|تحسين|طوّر|طور|تطوير|انقل|بدّل|بدل|استبدل|لوّن|لون|اكتب|ولّد|ولد|أعد تصميم|اعد تصميم|قسّم|قسم`, each anchored so it does not match inside a longer Arabic word) always wins; otherwise a question word (`explain|what|why|how does|…|اشرح|إشرح|وضّح|وضح|فسّر|فسر|لخّص|لخص|ما هو|ما هي|ماهو|ماهي|شنو|شلون|كيف يعمل|كيف تعمل|وين|أين|لماذا|ليش|ما الفرق|ما وظيفة|عرّفني|عرفني|نبذة|من يستدعي`) or a trailing `?`/`؟`. Answered read-only by `cwAnswerAboutProject` on tier `pro` with every file body sliced to 12 000 chars (total ≤90 000); any leaked ```` ```file: ```` blocks / `DELETE:` lines are stripped from the answer (`app.js:75841-75878`).
4. **Game** (`cwIsGameRequest`, `app.js:61857`): the agentic game developer (in-tab, iframe-verified, up to 8 rounds / 18 min) — summary `"بنيت اللعبة وطوّرتها ✓"`/`"Built & developed the game ✓"`.
5. **Improve** (`cwIsImproveRequest`, `app.js:62277`: ≤190 chars, matches `طوّر|حسّن|جمّل|قوّي|اجعله أفضل|أفضل|احترافي|كمّل|وسّع|أكمل|زد|ارفع مستوى|improve|enhance|polish|refine|better|upgrade|make it (nicer|prettier|better|professional)|professional|expand|extend|continue (developing|building)|keep (going|developing)|develop (it|this|further)|iterate` and not a narrow target `هذا السطر|هذه الدالة|هذا الزر|this line|this function|only the|فقط ال`) on a web project → `cwDevelopProject` (§7); summary `"طوّرت المشروع فعليًا: شغّلته وفحصته عبر {rounds} جولة — بقيت {left} ملاحظة"` or `"… — يعمل نظيفًا ✓"` / `"Actually developed it: run and inspected over {rounds} round(s) — {left} item(s) still open"` or `"… — running clean ✓"`.
6. **Bigger change** → plan-then-build (`cwPlanBuild` with `isEdit=true`, `app.js:63309-63536`): triggered when a split verb (`split|extract|move|decompose|separate|modular|استخراج|تقسيم|قسّم|تجزئة|فصل|نقل|إلى ملفات|إلى مكوّنات`) is present, or the project has ≥2 files and the request is >60 chars and mentions `page|صفحة|feature|ميزة|section|قسم|refactor|إعادة هيكلة|redesign|إعادة تصميم|multi|متعدد|dark mode|وضع ليلي` or any `CODE_FOLLOWUP` verb. The architect returns JSON `{ title, notes, steps:[{file, does}], dels }` (≤8 files); the entry `.html` is built first, then the rest in two staggered lanes; each file gets up to 6 continuations; a stopped run is parked for Resume.
7. **Single-shot surgical edit** (default): one call on tier `max` with the system prompt at `app.js:76056` (contract summarised in §6.3) and the user message `"PROJECT: " + name + "\n\nCURRENT FILES:\n" + files + "\n\nUSER REQUEST:\n" + req + att + refBlock` where files = `"===== path (FOCUS)? =====\n" + content.slice(0, 15000)` joined, total ≤90 000, `@`-mentioned files floated first with `"FOCUS FILES — the user @-referenced these; make the change here unless the request clearly needs other files: …"`; a rename request adds `"REFERENCES TO UPDATE — the symbol \"X\" appears in ALL these files; rename it in EVERY one and output each changed file:\n• path: n refs (id, class, selector, import, symbol, path)"`.
   - Continuation: while the parse reports an unterminated ```` ```file: ```` block and the body is not complete (`codeLooksComplete`), up to 4 rounds of `"You are FINISHING the file `path` from a response that was cut off. Continue from the EXACT last character …"` with the last 8000 chars; then the fence is closed.
   - Placeholder guard: emitted files containing `TODO|FIXME`, `... rest of`, `rest of the code`, `goes here`, `your code here`, `continue here`, `omitted for brevity`, `remains the same`, a comment that is only `...`, `keep existing`, `placeholder content` trigger ONE repair call that re-emits only those files; accepted only if markers strictly decrease and the file keeps ≥50 % of its length.
   - `summary` = the first line before the first fence, ≤220 chars.
   - Every changed `.html/.css/.js` that still fails `codeLooksComplete` gets up to 6 more continuations.
   - Returns `{ changes:[{path, content}], dels:[path], summary }`.

### 6.3 The file-block output contract (`cwParseFileBlocks`, `app.js:61729-61812`)

The model is told: `"STRICT OUTPUT FORMAT: first ONE short summary line in the user's language that NAMES exactly which file(s) it will touch and why …; then for EVERY added or modified file exactly one fenced block:\n```file:relative/path.ext\n<the COMPLETE new file content>\n```\nTo delete a file output a line: DELETE: relative/path.ext"`. Parser rules:

- Block regex ```` /```file:([^\n]+)\n([\s\S]*?)```/g ````; path trimmed, leading `/` stripped, ≤120; a trailing `\n` is removed from the body; a **blank** body for a file that already has content is ignored; a repeated path overwrites the earlier body.
- A trailing unterminated block is returned as `open: { path, content }` with `tailPath`.
- `DELETE: path` lines (own line) delete existing files only.
- `RENAME: old -> new` lines, or a DELETE + a new file with the same basename, are renames: content is carried over and every reference to the old path (`"old"`, `'./old'`, `` `/old` `` and the bare basename inside quotes/parens/slashes) is rewritten across all surviving files.
- Returns `{ files, changes, dels, open, tailPath }`.
- `cwEnsureViewport` injects `<meta name="viewport" content="width=device-width,initial-scale=1">` into any full HTML document missing it (`app.js:63544-63555`).

### 6.4 Attachments → text (`cwTakeAttach`, `app.js:61498-61530`)

- Images: one vision call on tier `pro` with up to `MAX_IMAGES` = 10 base64 images and the system prompt at `app.js:61461-61474` ("Produce a SPEC precise enough to rebuild what you see … EVERY visible string of text transcribed VERBATIM …"), user text `"The developer's request, for CONTEXT ONLY — do not answer it, only describe the images:\n" + ask.slice(0,800) + "\n\nDescribe every attached image, one clearly headed section per image."`. Failure → toast `attNone` `"ما قدرت أقرأ الصور المرفقة — الطلب ماشٍ بدونها"`/`"Couldn’t read the attached images — continuing without them"`. The spec is wrapped as `"\n\nATTACHED SCREENSHOT(S) — N image(s) the user attached, read by a vision model into words. This is the VISUAL TARGET: what you build or change must match it, including the exact text strings and the reading direction.\n" + spec`.
- Documents (already extracted text): `"ATTACHED FILE(S) — the user attached these to this request. Read them and build or edit to match.\n\n"` (+ a note about `[Slide n]`/`[Section n]`/`[Sheet n]` location markers for Office files) + `"===== FILE: name =====\n" + text + "\n===== END FILE: name ====="` blocks.
- Total capped at `cap` (24 000 for the job, 60 000 in-IDE, floor 2000) with the suffix `"\n[… attachment truncated to fit this request's budget]"`. The tray is cleared after consumption.

### 6.5 Diff review overlay (`cwShowDiff`, `app.js:76312-76512`)

- Items = changes (kind `new` if the path does not exist, else `edit`) + dels (`del`); pure no-op edits are dropped (byte-equal); none left → toast `nothing`.
- Header: `diffT` `"مراجعة التعديلات"`/`"Review changes"`, the summary, totals `"{n} ملفات · +A −D"` / `"{n} files · +A −D"`.
- One `<details>` per file, open by default when ≤2 items, with a checkbox (checked except deletions), badge `newF` `"جديد"`/`"new"`, `editF` `"تعديل"`/`"edit"`, or `"🗑 " + delF`, the path (`dir=ltr`), and `+a −d` (`dir=ltr`, omitted when zero). Body: LCS line diff (`cwLineDiff`, ≤1200 lines per side, unchanged runs >8 folded to 3 + `⋯ n ⋯` + 3); beyond 1200 lines or for a new file, the whole content (first 4000 chars + `…`) under `replaceAll` `"استبدال كامل للملف"`/`"Full file replacement"`; deletion shows `delF`.
- Actions: `apply` `"تطبيق المحدد"`/`"Apply selected"` + `(n)` (disabled at 0), `cancel` `"إلغاء"`/`"Cancel"`.
- Apply: auto-snapshot labelled `summary || "AI edit"`; mutate files; save; add a change-log row; replace the overlay with a 6-second bar `"طُبّقت التعديلات ✓"`/`"Applied ✓"` + `"↺ تراجع"`/`"↺ Undo"`; toast `applied` `"طُبّقت التعديلات ✓"`/`"Changes applied ✓"`; refresh tree/editor/preview. Undo restores the pre-apply files (after another auto-snapshot) and toasts `"تراجَعت عن التعديل ✓"`/`"Edit undone ✓"`.
- After apply, if HTML/JS changed: a silent verify pass runs the page in a hidden sandbox (`testHtmlInSandbox`, `lintProject`) and, on findings, one or two fix calls on tier `max` with the chip `"يتأكد أنّ الصفحة تعمل…"`/`"Making sure the page runs…"` then `"يصلح الصفحة…"`/`"Fixing the page…"`, toasting `"صُلّحت الصفحة لتعمل ✓"`/`"Page fixed to run ✓"` (games: `"صُلّحت اللعبة لتعمل ✓"`/`"Game fixed to run ✓"`). Native may skip this pass; if implemented, snapshot first because it bypasses the review.

### 6.6 Transport for every in-IDE model call

`callAgentText` / `streamAgentText` (`app.js:38813-38885`): `POST /api/chat` with body `{ messages, tier: <"mini"|"pro"|"ultra"|"max">, think: false, nomem: true }`, `credentials: same-origin`; response is an OpenAI-style SSE stream (`data: {"choices":[{"delta":{"content":"…"}}]}` … `data: [DONE]`); a 200 body that is an "engine busy" notice (`isEngineBusyText`, `app.js:38843-38848`) is treated as a failure. `agentCall` wraps it with 3 attempts (900 ms × attempt backoff), an idle watchdog, and keeps the best partial ≥`AGENT_PARTIAL_MIN` on the last failure (`app.js:53708-53735`). `nomem:true` skips history/KB injection and, for members, quota; guests are charged an `internal` unit per call (`server.mjs:12870-12877`).

---

## 7. Improve button (`cwRunImprove` → `cwDevelopProject`, `app.js:62523-62573`, `62394-62507`)

Toast `busy` `"يطوّر المشروع فعليًا…"`/`"Really improving the project…"`; no files → `noFiles` `"لا يوجد مشروع لتطويره بعد."`/`"No project to improve yet."`. Brief = `title + " — " + ("طوّر هذا المشروع وحسّنه واجعله أكثر اكتمالًا واحترافية" | "improve and complete this project, make it more professional")`. Loop up to `CW_APP_ROUNDS` = 4 rounds / 540 s: observe (runtime errors from a hidden sandbox run, DOM a11y probe, a regex critique), score `errs×12 + a11y×3 + missing + (big ? 0 : 4)`, stop when clean or when a round changed nothing measurable, else plan-build an edit against the goal list; keep the best-scoring version; final scoring pass never ships a regression. Outcomes: thrown → `failed` `"تعذّر إكمال التطوير — المحرّك لم يستجب. جرّب مرة أخرى."`/`"Could not finish improving — the engine did not respond. Try again."`; nothing changed → `none` `"المشروع نظيف — لا شيء يستحق التغيير الآن ✓"`/`"Project is clean — nothing worth changing ✓"`; changed → snapshot, change-log row `"تطوير — {rounds} جولات"`/`"Improve — {rounds} rounds"`, save, and `cwToastReport`: `"فُحص المشروع وشُغِّل فعليًا عبر {rounds} جولات — لا أخطاء متبقية ✓"`/`"Built, run and improved over {rounds} rounds — no issues left ✓"`, `"طُوّر عبر {rounds} جولات — بقيت {left} ملاحظة"`/`"Improved over {rounds} rounds — {left} item(s) still open"`, `"فُحص المشروع وشُغِّل — يعمل نظيفًا ✓"`/`"Project run and checked — clean ✓"`, `"فُحص المشروع — {left} ملاحظة لم تُعالَج"`/`"Project checked — {left} item(s) not resolved"`, or `done` `"طُوّر المشروع ✓"`/`"Project improved ✓"`. This loop needs a sandboxed runner; native can implement observe via the preview WKWebView (collect `__fcw` errors after load) or ship Improve as a plain plan-build edit.

---

## 8. Share

`shareActiveChat` (`app.js:79686-79713`) behind the bar's Share button (which commits the editor first, `app.js:75627-75639`): guests → sign-up prompt; `persistChat` first (a project gets its `serverId` here); `POST /api/share { chatId: serverId }` → `{ id }`; link `origin + "/?share=" + id`; copy to clipboard and open the share sheet. Toasts: `"ينشئ رابط المشاركة…"`/`"Creating share link…"`, `"تم نسخ رابط المشاركة ✓"`/`"Share link copied ✓"`, failure `"تعذّر إنشاء الرابط — تأكد من تسجيل الدخول واتصالك ثم أعد المحاولة"`/`"Couldn't create the link — check you're signed in and online, then retry"`. Server (`server.mjs:9217-9262`): member cookie required (`401 { error:"auth required" }`), rate limit 5/min (`429 { error:"too many requests" }`), unknown chat `404 { error:"not found" }`, re-sharing the same chat returns the same id, account cap 20 links → 409 (the chat slice has the exact body; the UI uses `shareOneCap` `"وصلت إلى الحد الأقصى لروابط المشاركة في حسابك"`/`"You've reached the share-link limit on your account"` and `shareOneBusy` `"طلبات كثيرة بسرعة — انتظر دقيقة ثم أعد المحاولة"`/`"Too many requests — wait a minute, then try again"` for 409/429). `GET /api/share?id=` returns `{ id, title, messages, ts, one }` and the public page renders the `firas-project` message with `buildProjectCard` (`app.js:79860-79885`, `51509-51560`): `📁` + name + `"{n} ملفات · {kb} KB"`/`"{n} files · {kb} KB"`, buttons `"▶ معاينة مباشرة"`/`"▶ Live preview"`, `"⬇ تنزيل الفولدر (ZIP)"`/`"⬇ Download folder (ZIP)"`, `"⚡ افتح بفراس كود"`/`"⚡ Open in Firas Code"`, then a collapsible row per file (`📄 path  {kb} KB ▾`).

---

## 9. Download as ZIP (`app.js:75640-75649`, `50818-50851`)

Folder name = project name with `[^\w؀-ۿ .-]+` → space, whitespace → `-`, trimmed of `-`, fallback `"project"` (Arabic letters are kept). Entries are `folder + "/" + path`; ZIP uses the **store** method, version 20, general-purpose flag `0x0800` (UTF-8 names), CRC-32, one local header + central directory + EOCD; text is UTF-8 encoded, an entry may carry raw `bytes`. File name `folder + ".zip"`, MIME `application/zip`. `downloadBlob` falls back to a "tap to save" toast (`"الملف جاهز — اضغط للحفظ"`/`"Your file is ready — tap to save"`, `"حفظ"`/`"Save"`) on in-app browsers (`app.js:29838-29876`). Native: write the zip to a temp URL and present `UIActivityViewController` / `fileExporter`; `Compression`/`ZIPFoundation`-free implementation is ~60 lines (store method only).

---

## 10. Chat-side code deliverable (Firas AI product)

### 10.1 When a chat turn becomes a code build

`detectCodeRequest(text)` (`app.js:2800-2836`) returns a spec or null:
- null if `CODE_DOC_OVERRIDE` (`powerpoint|pptx|بوربوينت|باوربوينت|عرض تقديمي|شرائح|سلايد|pdf|بي دي اف|excel|xlsx|اكسل|…|word|docx|وورد|(ملف|مستند|بصيغة|صيغة) ورد|csv`) matches;
- null for a drawing request (`DRAW_REQUEST` `draw|sketch|ارسم|إرسم|ارسملي|ارسم لي|رسم بياني|رسم دالة|رسم شكل|رسم مثلث|رسم دائرة|رسمة|رسمه|مخطّط|مخطط`) unless app words appear;
- spec immediately if `CODE_SPEC` (`single-file (html|website|site|page|web page)|<!doctype html|(ملف|صفحة|موقع|كود) html|html (file|website|site|page)|سنكل فايل|single html`);
- null if `ASKS_TO_LEARN` (`أريد أعرف|أفهم|أتعلم|كيف أسوي|يعني إيه|شنو يعني|how do/can/to|i want to know/learn/understand|what is/are/does|teach me|learn about`);
- otherwise needs a build verb `CODE_BUILD_VERBS` (`اصنع|إصنع|اعمل|إعمل|سوي|سويي|ابني|أبني|اكتب|أكتب|انشئ|أنشئ|صمم|أريد|اريد|أبي|ابي|بدي|عايز|عاوز|بغيت|ودي|محتاج|أحتاج|احتاج|ابغى|أبغى|generate|create|make|build|write|develop|design|implement|code me|build me|i want|i need`), then not a document noun (`DOC_NOUN` `report|summary|essay|book|ebook|guide|manual|paper|article|letter|cv|resume|story|outline|notes?|memo|thesis|brochure|worksheet|تقرير|ملخّص|مقال|كتاب|دليل|بحث|رسالة|سيرة ذاتية|قصة|مذكرة|أطروحة|كرّاس|ورقة عمل`) without a code artifact word, and finally one of `CODE_HARD` (`html|css|javascript|vanilla js|كود|code|سكربت|سكريبت|script|<!doctype|c++|cpp|java|c#|csharp|rust|golang|kotlin|swift|php|typescript|python|بايثون|برنامج|برمجة|سي بلس بلس|جافا`), `CODE_SOFT` (`موقع|website|web site|web page|webpage|صفحة ويب|landing page|single-file`), or `CODE_GENERIC` (`program|app(lication)|function|class|algorithm|snippet|game|CLI|API|endpoint|regex|query|bash|shell|dashboard|platform|portfolio|landing page|store|storefront|e-commerce|blog|تطبيق|دالة|خوارزمية|لعبة|متجر|منصة|لوحة تحكم|داشبورد|بورتفوليو|صفحة هبوط|مدونة`).

Spec (`codeSpecFromText`, `app.js:2775-2794`), first match wins unless the text is "webby" (`html|website|web site|web page|موقع|صفحة|<!doctype`): python → `{lang:"python",ext:"py",label:"Python",filename:"script.py"}`; c++ → `cpp/main.cpp`; java (not javascript) → `java/Main.java`; c# → `csharp`/`cs`/`Program.cs`; rust → `rs/main.rs`; golang → `go/main.go`; kotlin → `kt/Main.kt`; swift → `swift/main.swift`; php → `index.php`; typescript → `ts/main.ts`; css → `styles.css`; javascript/node/js → `javascript`/`js`/`script.js`; default `{lang:"html",ext:"html",label:"HTML",filename:"index.html"}`.

Follow-ups (`codeFollowupSpec`, `app.js:2850-2870`): if the last assistant turn is a code card and the new message is not a document/explanation request but matches `detectCodeRequest` or `CODE_FOLLOWUP` (`عدّل|عدل|تعديل|غيّر|غير|بدّل|بدل|أضف|اضف|اضيف|ضيف|احذف|أصلح|اصلح|صحّح|صحح|كمّل|كمل|أكمل|اكمل|استمر|واصل|زِد|زد|حسّن|حسن|طوّر|طور|اجعل|اجعله|خلّي|خلي|أعد|اعد كتابة|نفس الكود|لا يعمل|ما يعمل|لا يشتغل|ما يشتغل|مايشتغل|مو شغال|مش شغال|معطّل|خربان|توقف|يعلق|علق|فيه خطأ|فيه مشكلة|خطأ|مشكلة|edit|modif|chang|updat|add|remov|delet|fix|continu|improv|refactor|append|extend|rewrit|make it|same code|keep going|bug|error|broken|crash|doesn't work|does not work|not working|won't work/run/start/open/load|nothing happens|stopped working|stuck`), reuse the previous card's `{lang, ext, label, filename}`.

### 10.2 Request body for a code turn (`app.js:42397-42416`, `42624`)

`requestMessages = [{ role:"system", content: codeSystemPrompt(spec) }, ...convo]` where every earlier assistant code card is unwrapped to its raw `code`; `tier: "ultra"`; `think: false`; `nokb: true`; `product: "ai"`; `cid`; `chatId`. Members with a `serverId` and guests go through `POST /api/chat/job` (kind `"chat"`, same body) and poll; otherwise plain `POST /api/chat` SSE (`app.js:42646-42675`). A brief that needs fresh facts gets a web-search context message inserted after the system prompt. `codeSystemPrompt` (`app.js:6664-6731`) demands ONE raw self-contained file, no fences, no placeholders, the current year in footers, real interactivity, pinned CDN libraries when the brief needs them, and to begin with the first character of code.

### 10.3 Streaming and finalising

- Every frame: `renderLiveCodeInto(mdEl, answerSoFar, spec, lang)` (`app.js:6901-6925`) — strip code fences, append only the new tail to the `<code>` node, update the line counter, follow the newest line only if the reader was within 28 px of the bottom.
- Mid-stream promotion (`midStreamCodePromotion`, `app.js:6653-6662`): when the turn was NOT routed as code but the answer opens with a fence within the first line (≤160 chars of preamble), the same gates as `promoteAnswerToCode` are evaluated on a virtually-closed fence every frame; once boxed the decision latches.
- Finalize (`app.js:42784-42845`): `code = sanitizeContinuation(tidyCodeArtifact(answer, lang))` (HTML: trim to `<!doctype`…`</html>`); if `!codeLooksComplete(code, lang)` run `autoCompleteCode` (up to 16 rounds, ≤900 000 chars, head+tail context ≤140 000, status `"يُكمل تلقائيًا…"`/`"Auto-completing…"`); for HTML >6000 chars run `enhanceCodeInteractivity` (`"يطوّر التفاعلية والجافاسكربت…"`/`"Enhancing interactivity…"`); persist `` "```firas-code " + JSON.stringify({filename, lang, ext, label}) + "\n" + code + "\n```" ``.
- Stop mid-stream keeps the partial as a card (Continue available); nothing streamed → the empty turn is removed (`app.js:42941-42960`).
- Promotion at finalize (`promoteAnswerToCode`, `app.js:6585-6644`): exactly one fenced block, prose around it ≤160 chars and ≤12 % of the code (unless the box was already latched → prose kept in `meta.intro`/`meta.outro` and rendered above/below the card), and the block is a whole HTML page (`<!doctype html` or `<html>…</html>`), a whole `<svg>`, or ≥900 chars / ≥30 lines in a known language (`PROMOTE_EXT` map `app.js:6578`). Never applied to a file/document turn or a turn already carrying a `firas-*` fence.

### 10.4 `parseCodeMeta` (`app.js:6550-6558`)

Regex over the whole content: ```` /^```firas-code[ \t]+(\{[\s\S]*?\})[ \t]*\r?\n([\s\S]*)\r?\n```[ \t]*$/ ```` → `meta = JSON.parse(m[1]); meta.code = m[2]`. Fields: `filename`, `lang`, `ext`, `label`, optional `intro`, `outro`. `cleanCodeBody` strips a leaked ```` ```firas-code {…} ```` header or a bare `{"filename":…,"label":…}` object from a body (`app.js:38971-38976`).

### 10.5 The card (`buildCodeCard` / `wireCodeActions`, `app.js:6732-6900`)

- `dir=ltr` always. Header: three dots, `filename`, `label`, line count `arDigits(n) + " سطر"` / `n + " lines"` (`app.js:6544-6547`), then actions. While streaming the actions area shows only `"يكتب الكود…"`/`"Writing code…"` (continuing: `"يُكمل الكود…"`/`"Continuing…"`).
- Actions when finished: wrap toggle (`"لفّ الأسطر"`/`"Wrap"` ↔ `"لا تلفّ"`/`"No wrap"`; default wrapped when the longest line >140 chars; remembered in `firas_code_wrap`), **Preview** `"معاينة"`/`"Preview"` only when `canPreviewCode(lang, code)` (kinds: html/htm/xhtml, svg, md/markdown, json, css, js/javascript/mjs, py/python, plus sniffing `<svg>` or HTML structure), **Copy** `"نسخ"`/`"Copy"` (toasts `"تم نسخ الكود"`/`"Code copied"`, `"تعذّر النسخ"`/`"Copy failed"`), **Download** `"تحميل"`/`"Download"` (blob with `codeMime(ext)` — `html text/html, css text/css, js text/javascript, py text/x-python, json application/json, txt text/plain, cpp text/x-c++src, c text/x-csrc, java text/x-java-source, cs text/plain, rs text/rust, go text/x-go, php application/x-httpd-php, ts text/typescript, kt text/x-kotlin, swift text/x-swift`, else `text/plain`), **Continue** `"كمّل"`/`"Continue"`. Footer bar: `"الكود غير مكتمل؟"`/`"Code cut off?"` + `"كمّل الكود"`/`"Continue code"`.
- A freshly finished, complete HTML document auto-opens the full-screen preview once (`opts.fresh`), never on re-render of history (`app.js:6849-6857`).
- Preview panel (`openCodePreview`/`openHtmlPreview`, `app.js:35711-35800`): title `previewTitle` `"معاينة HTML"`/`"HTML preview"`, tools `previewRefresh` `"تحديث"`/`"Refresh"` and `previewOpen` `"فتح في تبويب جديد"`/`"Open in new tab"` (only for genuine HTML); iframe `sandbox="allow-scripts allow-modals allow-popups allow-forms allow-pointer-lock allow-downloads"`; fragments are wrapped by `ensureHtmlDocument` (`app.js:35449`); SVG on a chequerboard; Markdown rendered in the parent; JSON pretty-printed with `"JSON صالح · valid JSON"` or the parse error; Python opens immediately with `"يشغّل بايثون… · running Python…"` then swaps in the run result.
- Continue (`continueCode`, `app.js:39182-39290`): refuses while a stream is active (`"انتظر حتى ينتهي الرد الحالي"`/`"Wait for the current reply to finish"`); already complete → `"الكود مكتمل بالفعل ✅"`/`"Already complete ✅"`; otherwise streams on tier `ultra` with `[system: codeContinueSystemPrompt(meta), ...prior turns (code unwrapped), assistant: code, user: codeContinueUserMsg]` where the user message is `"هذا الملف ({label}) توقّف قبل أن يكتمل وهو ناقص. أكمله من حيث توقّف بالضبط وأنهِه بالكامل (أغلق كل الوسوم والأقواس؛ ولِلـHTML أكمل <style> و</head> و<body> كاملًا والسكربتات وانتهِ بـ </html>). أخرج فقط بقية الكود الخام، دون إعادة أي سطر موجود ودون أي شرح أو علامات ```."` / `"This {label} file stopped before completing and is INCOMPLETE. Continue from exactly where it stops and finish it fully (close every tag/bracket; for HTML complete <style>, </head>, the full <body> and scripts, and end with </html>). Output ONLY the remaining raw code, never re-output an existing line, no commentary or ``` fences."`; the tail is merged with `joinCodeContinuation` (seam overlap up to 4000 chars, restart detection). Toasts `"تم إكمال الكود ✅"`/`"Code continued ✅"`, `"تعذّر الإكمال — اضغط «كمّل» مرة أخرى"`/`"Couldn't continue — click Continue again"`, `"تعذّر إكمال الكود، حاول مجددًا"`/`"Couldn't continue — try again"`.
- `codeLooksComplete(code, lang)` (`app.js:38890-38932`): HTML → ends with `</html>`; otherwise strip strings/comments/regex, require balanced `{}`, `()`, `[]`; C-family/CSS/JSON must end with `}`, `)`, `;`, `]`, `>` or a comment; other languages reject a trailing `\`, dangling operator, opened bracket, a trailing keyword (`and|or|not|in|is|if|elif|else|for|while|return|import|from|def|class|with|as|lambda|then|do|case|select|where|join`) or a trailing `:`.

### 10.6 Agent → Code bridge

Any `firas-project` card in chat (Agent deliverables, shared pages) offers `"⚡ افتح بفراس كود"`/`"⚡ Open in Firas Code"` → `openProjectInFirasCode(proj)` creates a new project chat from the files, switches product, and toasts `"انفتح المشروع في فراس كود ⚡"`/`"Opened in Firas Code ⚡"` (`app.js:60667-60676`).

---

## 11. The 21st.dev ports (what the commits actually shipped)

Commit `92d72a9` ("Nine surfaces Firas Code did not have, ported into its own idiom from 21st.dev") plus `1755fca` (three more) and earlier work; each is a **model** port, not code (the site has no build step). Surfaces already present before that commit: tabs, dock, breadcrumbs, context menu, find/replace with regex, folding, fuzzy open (command palette), change log, diff view, split panes, focus mode. The nine: Problems panel, local-history timeline (Version history UI over existing snapshots), Editor preferences, Minimap, Multiple cursors + column selection, Indent guides + bracket-pair depth, Quick fixes, File tree drag-and-drop reorganisation, Run bar / task bar. The three that followed: change gutter, status bar, keyboard-shortcut sheet. Named references in code comments: "Code block" (ayushmxxn) → open-file tabs; "Flexnative Breadcrumb" (felipemenezes098) → breadcrumb; "Great UI Mobile Mockup" (saurabh-2607) → device chassis; "Interactive Logs Table" (#10635) → console toolbar; "Status" (#25395, diceui) → run status pill; "Toast" (#24297, cnippet.dev) → notification deck; "Toolbar Dock" (ruixen.ui, #14092) → top-bar dock with a sliding tooltip rail; "Edit Tool" (@serafimcloud, #12385) → quick-fix card; edwinvakayil/file-tree (#19150) → tree filter + roving keyboard; "empty state with marquee" → home shelf and empty console/preview blocks.

Native priority: tabs, breadcrumb (iPad), device chassis, console toolbar, run status pill, notification deck (or system toasts), version history, change log, diff review. Defer: minimap, multi-cursor, indent guides, quick fixes, DnD, keyboard sheet, Problems panel, Firas Computer.

---

## 12. Native Code screen — minimum spec (what must be on screen)

1. **Launcher**: hero + create card (name ≤60, description ≤1500, attachments, Blank / Build with AI) + project grid with delete; strings in §2.
2. **Workspace** (phone: four-pane bottom nav Files/Code/Preview/AI; iPad: three columns 200 / 1.1fr / 1fr): top bar with Run, Improve (or hidden if not implemented), History, New file, Find, Share, ZIP; file rail (§5.2); editor with syntax highlighting, LTR, 900 ms autosave, `saved/editing/saving` pill; right pane with Preview / Console / Chat tabs and the clear button; AI bar with `@` mentions and attachments; diff review sheet (§6.5).
3. **Preview** in `WKWebView` assembled exactly per §5.4 with the console hook as a `WKScriptMessageHandler`, device presets (390×844, 834×1112, fluid) with rotate, auto-reload toggle (700 ms / CSS live push 2500 ms), reload, open in Safari (write the assembled document to a temp file), run status pill, empty state with "Create index.html".
4. **Console** with level chips + counts, filter, clock toggle, clear, colours in §5.5, and the error buffer that feeds "Fix it with AI".
5. **Build**: `POST /api/chat/job` exactly as §3.1, poll per §3.3 (4 s, 2 h ceiling, 5-miss tolerance, land-before-forget), pointer persisted per project (jobId, name, serverId, startedAt), reattach on foreground/launch/online, APNs deep link handling by jobId, checkpoints landed via `PUT /api/chats/:id` messages[0], toasts per §3.3.
6. **Edits**: `cwAskAI` routing per §6.2 (at least: document redirect, question, single-shot surgical edit with continuation + placeholder guard); thread persisted in `messages[1]` per §1.3.
7. **Share / ZIP** per §8–9.

---

## 13. Open questions and risks for the port

- `phase: "done"` is accepted by the web but never emitted by the code queue; keep accepting it.
- The `progress` field of the poll response is `null` for code builds; file-count progress must be derived from the fence.
- Python execution and the in-tab Improve/game loops depend on a browser sandbox; decide whether to run Pyodide inside a hidden WKWebView or ship without Run-for-Python and Improve.
- Module import maps use blob: URLs on the web; WKWebView needs data: URLs or a scheme handler.
- Guest projects are device-local on the web; the native app must not attempt `/api/chats` for guests and must keep the job pointer keyed by the local project id.
- `chatId` in the build request must stay `""`; sending a real id makes the worker append a raw fence as an assistant turn.
- The existing `CodeStore.swift` charges a Code unit before enqueueing; the web does not for server builds. Harmless for members (unmetered), but it consumes one of a guest's 60 daily units.
