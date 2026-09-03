# Firas Code builds (`kind:"codebuild"`), Brain-ask jobs (`kind:"brainask"`) and the chat code box

Source of truth: `server.mjs` at the repo root (deployed Node server). Client behaviour is cited from
`app.js` only where the native client must reproduce it (the server has no knowledge of the code box).
All line numbers refer to the worktree at the time of writing (verified 2026-09-02 against
`server.mjs` and `app.js`). Arabic strings are verbatim.

Read together with `ios/Docs/server-chat-jobs-chats.md` (generic `/api/chat` stream, chat persistence,
`longdoc`/`longfile` kinds), `ios/Docs/server-brain.md` (Brain upload/search/whole; its §13 summarises
`brainask` and agrees with §3 here) and `ios/Docs/web-code-ux.md` (the Firas Code IDE; its §3/§10 overlap
with §2/§4 here and were cross-checked). This file covers only the two job kinds and the code deliverable
format, at implementation depth.

---

## 0. Executive summary (what an engineer gets wrong without this)

1. Both kinds ride the **durable chat-job queue**: `POST /api/chat/job` creates, `GET /api/chat/job?id=`
   polls, and the same worker (`runOneJob`, server.mjs:11767) dispatches on `rec.kind`
   (server.mjs:11854, 11856).
2. The server has **zero** knowledge of `firas-code` / `parseCodeMeta` / `codeMeta` (grep in server.mjs:
   no matches). The chat code box is 100% client-side: the client picks a raw-code system prompt, sends
   tier `ultra` with `nokb:true`, receives plain SSE tokens, and wraps the finished code in
   ```` ```firas-code {json}\n<code>\n``` ```` itself. The native app must do the same.
3. A code **build** produces exactly one fence: ```` ```firas-project\n{"name":..,"files":[{"path","content"}]}\n``` ````
   (server.mjs:11663). No preview HTML, no console/test output, no per-file streaming on the wire.
4. **Per-file progress is NOT observable through `GET /api/chat/job`** while the build runs on the
   single Fly machine: the poll is answered from the in-memory capture whose `_answer` stays `""` until
   the build finishes (server.mjs:11610 writes only the durable out node; 11663 sets `_answer` at the
   end; 12667-12702 serve `live._answer`). Expect `phase:"processing", text:""` for up to 2 h, then
   `phase:"completed"` with the full fence. The `"n/m"` progress string written at server.mjs:11611 is
   stored on the control record but never returned by any endpoint.
5. The web client does **not** currently send `kind:"brainask"` (grep in app.js: 0 matches);
   `brainAsk()` (app.js:86697) streams live via `/api/brain/whole` + `/api/brain/search`. The server
   kind is fully implemented and usable by the native app for a leave-and-come-back Brain answer.
6. `POST /api/chat/cancel` does **not** stop a codebuild or brainask job (only `longfile` honours the
   tombstone; server.mjs:12490-12494, 11903). It only suppresses the completion push.
7. Job ids are deterministic per owner + `cid` (server.mjs:733); resending the same `cid` returns the
   existing job instead of starting a second build (server.mjs:12568-12587).
8. `llmComplete` (server.mjs:7416-7460) **never throws** — every failure path returns `""`. So a model
   outage during a build does not produce an error string: the classifier falls back to `site` + the
   measured language, the planner falls back to a skeleton, empty files are skipped, and only when
   **every** file is empty does the job fail with `codebuild_empty`. For brainask the same outage is
   `brainask_empty`.
9. Guest brainask jobs all charge one shared **network** quota bucket (the worker's synthetic request
   has IP `127.0.0.1`, server.mjs:9379, 1256-1275): 480 guest Brain searches per day server-wide, on top
   of the per-guest 120. See §3.2.

---

## 1. The durable job queue (shared by both kinds)

### 1.1 Routes

| Route | Handler | Purpose |
|---|---|---|
| `POST /api/chat/job` | `handleChatJobStart` server.mjs:12531 | enqueue |
| `GET /api/chat/job?id=<jobId>` | `handleChatJobStatus` server.mjs:12658 | poll |
| `POST /api/chat/cancel` `{id}` | `handleChatCancel` server.mjs:12478 | stop (no effect on these kinds, see 1.8) |
| `GET /api/agent/job?id=<jobId>` | `handleAgentJobView` server.mjs:12100 | agent-shaped view of ANY job id |
| `GET /api/agent/job-stream?id=<jobId>` | `handleAgentJobStream` server.mjs:12183 | SSE push of the same view (see 1.9) |

Route table: server.mjs:13729-13731, 13752-13755. `/api/chat/job` exists only in server.mjs (not in the
legacy edge function). `/api/agent/start` and `/api/agent/poll` answer `410 {"error":"durable_agent_route_required"}` (13758-13760).

### 1.2 Auth

`callerOf(req)` (server.mjs:1314-1320): member session cookie `firas_session` (`COOKIE_NAME`, 1046) **or**
guest cookie `firas_guest` (`GUEST_COOKIE`, 1131; value must verify and start with `g_`, 1156-1161).
Neither → `401 {"error":"authentication required"}` (server.mjs:12538, 12661).
Guests are allowed for both kinds (the worker mints a guest cookie from the stored id, server.mjs:11835-11837).

### 1.3 Rate limits

- Enqueue: `chatjob:<callerId>` 60/min members, 30/min guests → `429 {"error":"too many requests"}` (server.mjs:12540).
- Poll: none on `GET /api/chat/job` (no `rateLimited` call in 12658-12715).
- SSE stream: `agent-job-stream:<owner>:<ip>` 90/min → `429 {"error":"rate_limited"}` (server.mjs:12189).

### 1.4 Enqueue validation, in order (server.mjs:12541-12587)

| Check | Failure |
|---|---|
| body read (limit `CHAT_BODY_LIMIT` = 25,000,000 chars, server.mjs:442) / JSON parse | `400 {"error":"invalid JSON body"}` (an over-limit body also lands here — `readBody` rejects, 1669-1676) |
| guest + (`kind:"agentrun"` or `product:"agent"`) | `403 {"ok":false,"error":"account_required","feature":"agent"}` |
| `messages` must be a non-empty array | `400 {"error":"messages required"}` |
| raw body string length > `JOB_PAYLOAD_MAX` = 600,000 (server.mjs:9330) | `413 {"error":"payload_too_large"}` |
| durable store read/write fails | `503 {"error":"storage_unavailable"}` (12570, 12650) |

Field normalisation when the control record is written (server.mjs:12562-12563, 12625-12646):

| Field | Rule |
|---|---|
| `chatId` | string, `.slice(0,64)`; stored only for members (`""` for guests, 12626) |
| `cid` | `[A-Za-z0-9_-]` only, ≤64; default `"j"` + 12 hex (12563). The web uses `uid()` = `Date.now().toString(36) + 6 base-36 chars` (app.js:2703) |
| `kind` | one of `longdoc, longfile, agentrun, codebuild, brainask`; anything else → `"chat"` (12629) |
| `product` | string ≤12 chars, default `"ai"` (used for the push copy: `"code"` / `"brain"`, server.mjs:1515-1519) |
| `task` | string ≤8000 (control record only — the worker re-reads the raw body, where `task` is **not** sliced, 11468/11707) |
| `title` | string ≤160 (unused by these two kinds) |
| `lang` | `"en"` if exactly `"en"`, else `"ar"` |
| `tier` | must be a key of `TIERS` (`mini`, `pro`, `ultra`, `max`; server.mjs:401-431), else `"pro"` |

Job id: `jobIdFor(ownerId, cid)` = `sha1(ownerId).hex[0..10] + "-" + jobKey(cid)` (server.mjs:731-733).
`jobKey` replaces `[.$#[\]/\s]` with `_` and cuts to 96.

### 1.5 Enqueue responses (server.mjs:12568-12587, 12655)

- New job: `200 {"ok":true,"jobId":"<id>","phase":"queued"}`
- Same `cid`, still running: `200 {"ok":true,"jobId","phase":"queued"|"processing"}` (no text)
- Same `cid`, finished: `200 {"ok":true,"jobId","phase":"completed","text","reasoning","surface":null|{},"progress":null}`
- Same `cid`, failed: `200 {"ok":false,"jobId","phase":"failed","error":"<string>"|"previous_attempt_failed","surface":null,"retryRequiresNewCid":true}`
  → the client must mint a **new** `cid` to retry.

### 1.6 Worker mechanics (server.mjs:9322-9333, 11767-11939, 11945-12001)

| Constant | Value | Client consequence |
|---|---|---|
| tick | every 2,000 ms (11999); nothing is claimed until the DB is loaded (`dbReady`, 11771, 11946) | a fresh enqueue also triggers an immediate tick (12653-12654) |
| `JOB_CONCURRENCY` | 4 | a job may sit `queued` behind others |
| `JOB_STALE_MS` | 120,000 | a claim with no heartbeat for 2 min is re-queued — not a failure; heartbeats every 15 s (11796) and after every file (11611) |
| `JOB_MAX_ATTEMPTS` | 3 | a thrown error re-queues with `nextAt = now + attempts*5000` ms (5 s, then 10 s); after the 3rd attempt → `failed` (11929-11937) |
| `JOB_KEEP_MS` | 21,600,000 (6 h) | finished records are deleted after 6 h → `phase:"unknown"` (11956-11958) |
| `CODEBUILD_MAX_MS` | 7,200,000 (2 h) (11185) | build stops planning new files past this (11498) and skips remaining repairs (11629) |

Boot recovery (`jobBootRecover`, server.mjs:11983-11994): anything `processing` at boot is re-queued
without charging an attempt. A deploy mid-build therefore **restarts the build from scratch** (nothing
is checkpointed for codebuild). A shutdown while running hands the job back the same way (11925-11928).

Terminal handling (server.mjs:11866-11939):
- non-empty `cr._answer` → out node = `{text, reasoning, surface?}` (11896); for members with a
  `chatId`, `saveAssistantTurn` upserts an assistant message by `cid` into that chat (server.mjs:2513-2537,
  11900); control → `phase:"completed", error:"", status:0`; push sent unless `_cancelled` (11903); input deleted.
- `cr._status >= 400` (a refusal — only reachable for kind `chat`) → `failed`, `status` = HTTP code,
  `error` = refusal body (≤1000 chars) (11910-11921).
- thrown error → retry/fail as above with `error` = message or `"no_answer"` (11929-11938).

### 1.7 `GET /api/chat/job?id=` response (server.mjs:12658-12715)

Always `200` JSON unless: no identity → 401; job belongs to someone else → `403 {"error":"forbidden"}`.

Known job:

```json
{ "phase": "queued"|"processing"|"completed"|"failed",
  "text": "", "reasoning": "", "error": "", "status": 0,
  "surface": null, "progress": null }
```

Unknown job — the body is **only** `{"phase":"unknown"}` (12705; no `text`/`error` keys). Also returned
for a missing/empty `id`. Means: never existed, or aged past 6 h. Terminal.

- `progress` is only non-null for `longfile` (`longFileProgressView`, server.mjs:10313-10317) → always `null` here.
- `surface` is always `null` for these two kinds (neither sets `cr._agentSurface`).
- `status` is `0` except the refusal path (kind `chat`) and `499` for a cancelled longfile.
- Live path (12667-12702): while the worker holds the job in this process, `phase` is `"processing"`
  and `text` = in-memory `_answer`. For codebuild that is `""` until the end; for brainask it is the
  full answer at the end. The "suspicious" fallback (12680-12695) only changes the answer when the
  durable record is already terminal (zombie capture evicted); a build older than 60 s with no answer
  merely costs the server one control read per poll and still answers `processing`.
- Queued path: `text` is `""` (the out node is not read for a queued non-longfile job, 12708).
- Completed path: `text` = out node text (the fence / the answer), `reasoning` = `""`.
- Failed path: `error` string (see 2.7 / 3.4). `text` = whatever the out node holds. The out node is
  written empty at enqueue (12624) and is **never cleared between attempts**, so after a failure it can
  still carry a partial `firas-project` fence published by an earlier attempt's `onProgress`
  (11610, 11815-11825). The web watcher saves any parseable fence it sees regardless of phase
  (app.js:60468-60481, evaluated before the phase check at 60482); do the same.

### 1.8 Cancel (server.mjs:12478-12529)

`POST /api/chat/cancel` body `{"id":"<jobId>"}` (JSON ≤4,000 chars; `id` is stripped to
`[A-Za-z0-9_-]` ≤64). Responses: `400 {"error":"bad_request"}` (empty/invalid id or unparsable JSON —
`readJson` returns `null`, 1682-1689), `401 authentication required`, `403 {"error":"not_yours"}`,
`404 {"error":"unknown_job"}`, `409 {"error":"job_not_running"}` (any non-longfile job with no live
capture — i.e. queued, or finished), `200 {"ok":true,"stopped":true}`. A body over 4,000 chars makes
`readBody` reject, which the top-level handler turns into `500 {"error":"internal error"}` (13862-13864).
For a **live** codebuild/brainask it sets `cr._cancelled = true` and returns `stopped:true`, but the
worker never reads that flag for these kinds (`llmComplete` is called without a signal — 11237, 11314,
11529, 11589, 11642, 11757 — and `streamStopped` is only consulted by streaming engines, server.mjs:2762).
The build/answer still completes and is saved; the only effect is that the completion push is not sent
(11903). Do not offer a Stop button that promises to stop the server build; offer "stop watching" only.

### 1.9 Alternative push channel: `GET /api/agent/job-stream?id=` (server.mjs:12183-12290)

Works for any job id the caller owns (ownership via `agentJobLiveState`, 12078-12098). Before the
stream is committed, a failed initial snapshot is answered as plain JSON with that status (12198):
`404 {"error":"job_not_found"}`, `403 {"error":"forbidden"}`, `503 {"error":"storage_unavailable"}`,
`400 {"error":"bad_request"}` for an empty id. SSE frames (`agentJobStreamWrite`, 12175-12181):

```
retry: 3000

id: 1
event: snapshot
data: {"job":{"id":"…","phase":"run","presentation":"conversation","title":"","task":"…","lang":"ar","steps":[],"surface":null,"final":"","error":"","credits":null}}

id: 2
event: snapshot
data: {"job":{…,"phase":"done","final":"```firas-project\n{…}\n```"}}

id: 2.terminal
event: terminal
data: {"id":"…","phase":"done"}
```

Phase mapping (12161-12163): `completed|done → "done"`, `failed → "fail"`, `queued → "queued"`, else `"run"`.
`final` carries the out text only at `done` (12069). On `fail` the error is the generic `"task_failed"`
(12070) — the real error string is only on `GET /api/chat/job`. `credits` is the Manus credit view for
members, `null` for guests (12142). Keepalive comment `: keepalive` every 15 s (12284-12286);
`event: agent-error` `{"error":"…","retryable":<status>=500>}` then close on storage trouble (12253), or
`{"error":"stream_unavailable","retryable":true}` on an unexpected throw (12259). Frames are deduped by
sha256 of the body (12234-12236), so because the codebuild `_answer` is empty until the end the stream
stays silent until the terminal snapshot — still useful as a wake-up instead of polling. The connection
ends after the `terminal` frame (12239-12242).

---

## 2. `kind:"codebuild"` — Firas Code project build

### 2.1 Request the web client sends (app.js:60521-60548, `codeServerBuild`)

```json
POST /api/chat/job
{
  "kind": "codebuild",
  "task": "<brief, ≤6000 chars>",
  "name": "<project name, ≤80 chars>",
  "attach": "<text read of screenshots/documents, ≤24000 chars>",
  "lang": "ar" | "en",
  "tier": "pro",
  "cid": "<uid()>",
  "product": "code",
  "chatId": "<server chat id or \"\">",
  "messages": [ { "role": "user", "content": "<task + attach, concatenated with no separator>" } ]
}
```

- `messages` exists only to pass the queue's validation (and to feed an older server that does not
  know `attach`); the worker prefers `task` and falls back to the last `user` message
  (server.mjs:11466-11468). The web's `messages[0].content` is `task.slice(0,6000) + attach.slice(0,24000)` (app.js:60540).
- `attach` is sliced to 24,000 chars server-side (11475); the client cap `CW_ATT_JOB_MAX = 24000`
  (app.js:61304). Send text, never image bytes — the 600,000-char body ceiling refuses them.
- `task` is not sliced by the worker; the prompts slice it (see 2.3). Sending more than ~6,000 chars
  is wasted.
- `chatId`: the web client passes `chat.serverId || ""`, which is almost always `""` because the project
  chat's create POST is still in flight. If the native app passes a real project chat id, the server
  will **upsert an assistant message containing the `firas-project` fence into that chat by `cid`**
  (server.mjs:11900, 2513-2537) — that is a second copy next to the project's own `messages[0]`. Pass
  `""` unless you want that.
- `tier` is stored on the record only; the build always runs on `CODEBUILD_TIER` (see 2.3).
- `lang` is effectively ignored for the build (2.3); it is stored as `rec.lang` and used as the saved
  message's `lang`.
- `product:"code"` selects the push copy `مشروع فِراس كود` (server.mjs:1517, 1553); `rec.kind === "codebuild"` alone also does.

### 2.2 Web client's local scaffold (must be mirrored so a returning user sees the same thing)

Before enqueueing, the web creates the project chat with `CW_BLANK_FILES` (app.js:61128, 61642):
one file `index.html`:

```html
<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>مشروعي</title>
  <style>
    body{font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;background:#faf9f5;color:#1a1a18}
    h1{font-size:clamp(28px,6vw,48px)}
  </style>
</head>
<body>
  <h1>ابدأ البناء 👋</h1>
</body>
</html>
```

A project is a chat with `codeProj:true` whose `messages[0].content` is the `firas-project` fence and
`messages[1]` is the base64 `firas-code-chat` thread (app.js:60119, 60606-60618). When the queue accepts
the job the web shows the toast `srvKeep` and returns; when it refuses (non-OK status or no `jobId`) it
falls back to the in-tab builder (app.js:61661-61673).

### 2.3 What the worker does (`runCodeBuildJob`, server.mjs:11463-11666)

1. `desc = task || last user message` (trimmed, unsliced); empty → throws `codebuild_no_task` (11469).
2. `attach` (≤24,000) forms `brief = desc + "\n\nATTACHED CONTEXT — screenshots the user attached (read into words) and text extracted from their files. What you plan must MATCH it:\n" + attach` (11476-11478). `brief` goes to the planner; `desc` alone goes to the classifier; per-file prompts get `desc` and `attach` separately.
3. **Classify** (`codeClassify`, 11226-11287): one `llmComplete` call (tier `CODEBUILD_TIER` = `ultra`,
   `maxTokens: 200`, T=0, input `desc.slice(0,2000)`) returning `{"kind","lang","title"}`. Kinds:
   `game | app | dashboard | site | tool | mobile | desktop` (`CODE_KINDS`, 11198-11223); unknown/unparsable → `site`. Overrides:
   - Language is **measured** from `desc`: count `[؀-ۿ]` vs `[A-Za-z]`; if the sum ≥12 and one
     script outnumbers the other 3:1, that script wins regardless of the model (11255-11260). Otherwise
     the model's `ar|en` is used, else the larger count. So `body.lang` never decides the UI language (11486 only runs when `intent.lang` is empty, which cannot happen).
   - Decisive nouns force the kind (11270-11285), tested with `(^|[^\p{L}])(…)([^\p{L}]|$)` / `iu`, first hit wins:
     `لعبة|لعبه|العاب|ألعاب|game|arcade|platformer|shooter|puzzle` → `game`;
     `لوحة تحكم|لوحة معلومات|داشبورد|dashboard|analytics panel` → `dashboard`;
     `تطبيق (هاتف|جوال|موبايل|ايفون|أيفون|اندرويد|أندرويد)|ios|android|iphone|app store|play store` → `mobile`;
     `برنامج (كمبيوتر|حاسوب|ويندوز)|windows app|desktop app|electron|.exe` → `desktop`.
   - `title` ≤60 chars.
4. `name = body.name.slice(0,80) || intent.title || ("new project" | "مشروع جديد")` (11488).
5. **Plan** (`codePlanFiles`, 11289-11369): `llmComplete` (`maxTokens: 1500`, input `brief.slice(0,6000)` —
   so an attach only reaches the planner in whatever room the first 6,000 chars leave) asking for a JSON
   array `[{path, does}]`, 3-12 files (3-20 for mobile/desktop), at T=0.2 then once more at T=0 if
   unparsable; paths trimmed, leading slashes stripped, ≤120 chars, no `..`, `does` ≤200, capped at
   `CODEBUILD_MAX_FILES = 40` (11123); `index.html` is force-inserted at the front if missing (11336); a
   plan of <2 files gets a per-kind skeleton appended (11344-11367: game `styles.css, js/game.js, js/state.js`;
   dashboard `styles.css, js/data.js, js/charts.js, js/app.js`; mobile `styles.css, js/app.js, capacitor.config.json, package.json, README.md`;
   desktop `styles.css, js/app.js, main.js, package.json, README.md`; else `styles.css, js/app.js`).
   Stack contract: plain HTML/CSS/JS, no build step, one pinned CDN UMD allowed, Google Fonts / Font Awesome / picsum always allowed (11309-11312).
6. **Per file** (11497-11612), in plan order: `llmComplete` on tier `ultra` (models
   `glm-5.3:cloud, kimi-k2.7-code:cloud, glm-5.3-flash:cloud, minimax-m3:cloud, qwen3-coder:480b-cloud`,
   server.mjs:416), `maxTokens: CODEBUILD_FILE_TOKENS = 32000` (11130), T=0.4. System prompt = raw-file
   rules + `"UI text is in ENGLISH|ARABIC; if the UI language is Arabic the document must set lang=\"ar\" and dir=\"rtl\"."`
   + `CODE_KINDS[kind]` + (`VISUAL_POLICY` for `.html/.htm/.css` only, 11151, 11510) + `SIZE_MANDATE_WEB` (11173)
   + `CRAFT_MANDATE` (11183). User prompt = `desc.slice(0,4000)` + (`attach.slice(0,8000)`) + manifest
   + already-written list + `YOUR FILE` + `desc.slice(0,2000)` again (11518-11526). One wrapping markdown
   fence is stripped (11534). Empty output → file skipped (11535).
   Completeness check (`looksComplete`, 11561-11576), only for `.js/.mjs/.html/.htm/.css`: html must end
   with `</html>`; css must balance braces and end with `}`/`;`; js/mjs must parse via `new Function`
   after stripping `import`/`export`; other extensions are always "complete". Up to 3 continuation calls
   (T=0.2, shown the last 2,500 chars, 11579-11596) append the tail. Still incomplete: **.js/.mjs are
   dropped**, .html/.css are kept (11597-11607).
   After each kept file: `onProgress(fence-so-far)` to the durable out node and `progress:"k/n"` on the
   control record (11610-11611) — neither reaches the client while the job is live (§0.4).
7. `built` empty → throws `codebuild_empty` (11614).
8. **Wiring audit + one repair pass** (`codeAuditWiring`, 11374-11461; 11622-11660): missing local
   asset references in `<script|link|img|source|video|audio src|href>`, `getElementById`/`querySelector("#id")`
   with no matching id (ids the script assigns via `.id = "…"` are exempt), duplicate top-level
   `const|let|class|function` names across classic (non-module) scripts on one page. One finding per
   file; each flagged file is rewritten once (T=0.2, file shown ≤60,000 chars) and accepted only if the
   result is >50% of the original length. The audit re-runs and only logs.
9. Result: `cr._answer = "```firas-project\n" + JSON.stringify({name, files: built}) + "\n```"` (11663).
   `files` is `[{ "path": "index.html", "content": "<!DOCTYPE html>…" }, …]` in plan order (dropped
   files simply absent). There is **no** preview html, no console/test output, no `surface`.

Because `llmComplete` swallows every transport/model error (7416-7460: quota-limited keys rotate, other
errors `break` to the keyless fallback, and a failed fallback returns `""`), steps 3, 5, 6 and 8 never
throw; the per-file `catch` at 11531 is defensive only.

### 2.4 Parsing the deliverable

Final text is exactly one fence. Web parsers:

- Anchored (project chat `messages[0]`): `/^\s*```firas-project\s*\n([\s\S]*?)\n```\s*$/` then
  `JSON.parse`, valid only if `files` is a non-empty array (`parseProjectMeta`, app.js:50926-50930).
- Poll-tolerant (mid-text): `/```firas-project\s*\n([\s\S]*?)\n```/` (app.js:60468).

`JSON.stringify` never emits a raw newline (newlines inside file contents are the two characters `\n`),
so the JSON is one physical line and the first `\n```` ` ```` after it is always the real closing fence —
the non-greedy web regex and a "last fence" search give the same result. File contents may contain
backticks (harmless).

### 2.5 Web client save/caps the native app should match (`codeSaveFiles`, app.js:60566-60604)

- Keep at most **30 files**, `path` ≤120 chars, each `content` ≤60,000 chars, `name` ≤80; total
  payload (`JSON.stringify({name, files})`) must be ≤ `CW_PAYLOAD_MAX = 180,000` chars (app.js:60265).
  That cap was chosen against a server cut of 200,000 chars that **no longer applies**: `sanitizeMessages`
  now cuts a message at `MAX_CONTENT` = 1,000,000 chars (env `MAX_CONTENT`, server.mjs:2429, 2436; the
  comment at app.js:60265 and the note at 63287-63288 are stale). Keep 180,000 anyway so a project saved
  by the native app stays loadable by the web client (which would otherwise shrink it on its next save),
  and never exceed 1,000,000 — past that the closing fence is severed and the project reads as empty.
  The web shrinks the largest file by 20% repeatedly until it fits; if it still does not, it refuses and shows:
  - ar: `المشروع أكبر من حدّ الحفظ — لم يُحفظ. احذف أو صغّر أكبر ملف.`
  - en: `Project exceeds the save limit — not saved. Remove or shrink the largest file.`
- Refuse to save an empty file list over a chat whose messages have not loaded (60571-60574).
- Writes `messages[0].content = fence` (creates `messages[0]` as an assistant turn if the chat has none), bumps `updatedAt`, persists (60598-60602).

### 2.6 Web watcher behaviour to reproduce (`cwWatchServerBuild`, app.js:60426-60498; `cwJobsReattach` 60502-60512)

- Pointers: `localStorage["firas_job_<chatId>"] = jobId` (lights the sidebar/rail "still working"
  state) and table `firas_ai_code_jobs` `{ [chatId]: { jobId, name ≤80, sid, ts(start, never refreshed) } }`,
  ≤20 entries, oldest evicted (60282-60316). `sid` is the server chat id, learned on the first tick it appears (60465).
- Poll every 4 s, for at most `CW_JOB_MAX_MS = 2 h` (60283) from `ts`; on return events (boot +1.2 s,
  `visibilitychange`, `focus`, `pageshow`, `online`) re-attach idempotently; pointers older than 2 h are dropped without polling (60509).
- `403` → forget the pointer immediately (another account's job, 60448). Network error → keep trying.
- No matching project chat while the chat list is loaded and healthy for >15 consecutive ticks (60 s) → forget (60456-60459). An unloaded/failed chat list never counts.
- On any parseable fence in `text` → save files (dedupe by identical fence text; unparseable bytes are remembered so they are not re-tried, 60468-60481).
- Terminal phases: `completed | done | failed | unknown` (60482). If files were seen but not yet saved, keep
  retrying the save up to 15 × 4 s before forgetting (60487). Then announce (`cwAnnounceBuildDone`, 60374-60394; `ok` = files actually landed):
  - in the project, success: `خلص بناء المشروع ✅` / `Project build finished ✅`
  - elsewhere, success: `«{name}» صار جاهزًا في فراس كود` / `"{name}" is ready in Firas Code`, action `افتحه` / `Open it` (9 s); name cut to 40 chars
  - failure (any terminal phase with nothing saved): `تعثّر بناء «{name}» على الخادم — افتحه وجرّب من جديد` / `"{name}" didn't finish building on the server — open it and try again`
  - handoff accepted: `يُبنى على الخادم — غادِر الصفحة إن شئت، ستجده جاهزًا حين تعود` / `Building on the server — leave if you like, it'll be here when you're back`
  (all from `cwPlanT`, app.js:62634-62638; also `planning: "يخطّط للمعمارية…"` / `Planning architecture…`, `building: "يبني"` / `Building`,
  `finishing: "يجمع الملفات…"` / `Assembling files…`, `cancel: "إيقاف"` / `Stop`, `of: "من"` / `of`, `done: "✓"`).
- Queue refused and in-tab fallback also failed: `لم يكتمل الإنشاء — أعد المحاولة، أو أضِف تفاصيل للوصف` /
  `Build didn't complete — retry, or add more detail to your description` (61683); engine unreachable:
  `تعذّر الاتصال بمحرّك الذكاء — أعد المحاولة` / `AI engine unavailable — retry` (61694).

### 2.7 Error codes for codebuild (the `error` field of a `failed` status)

| `error` | Origin | Meaning / UI |
|---|---|---|
| `codebuild_no_task` | 11469 | neither `task` nor a user message — client bug; retried 3× (5 s, 10 s apart) before `failed` |
| `codebuild_empty` | 11614 | every planned file came back empty — in practice "the model tier is down"; retried 3× (up to 3 full builds) |
| `no_answer` | 11932-11933 | worker ended with an empty answer and no error message (not reachable from `runCodeBuildJob`, which always sets `_answer` or throws) |
| `payload_missing` | 11791 | input record vanished (storage); no retry |
| `user_not_found` | 11786 | member account deleted mid-job; no retry |
| `previous_attempt_failed` | 12583 | enqueue response only, when the stored `error` is empty |
| any other string | 11858 | `e.message` of an unexpected throw (storage helpers). Not produced by model failures — `llmComplete` never throws (§0.8) |

Show the user the `srvFail` copy above for any of these and offer a rebuild with a **new `cid`**.

### 2.8 Follow-up edits and "Improve" are NOT server jobs

`codeServerBuild` is called exactly once, from the create-project flow (app.js:61661-61662). Edits to an
existing project (`cwPlanBuild(name, files, request, isEdit=true, …)`, app.js:63309; call sites 62247,
62470, 76009) and Improve (`cwRunImprove`, 62523) run in the tab against the live model endpoints and
pass the current files in the prompt (`cwPlan`, 63256-63308: per-file bodies ≤1,200 chars each within a
9,000-char budget, files named in the request first, plan of 1-6 changed files + `dels`,
`CW_PLAN_MAX_FILES = 8`, 62631, planner tier `max`). There is no `codebuild` payload for "previous
files"; a native follow-up edit must either re-implement the in-tab planner or send a fresh `codebuild`
whose `task` describes the change and whose `attach` carries the current files as text (≤24,000 chars,
of which the planner sees at most what fits in 6,000 with the task, and each file prompt sees 8,000) —
the server will then produce a **complete new project**, not a diff.

### 2.9 Previews

The server ships nothing runnable. The web previews a project by inlining local css/js into
`index.html` in a sandboxed iframe (`projPreviewHtml`, app.js:50934) and offers a single-file preview
for html/svg/markdown/json/css/js and runs Python in-browser (`canPreviewCode` 35555, `openCodePreview`
35711). A native client should render `index.html` in a `WKWebView` with the project files served from
a local base URL.

---

## 3. `kind:"brainask"` — Brain answer that survives leaving

### 3.1 Request

```json
POST /api/chat/job
{
  "kind": "brainask",
  "task": "<question, ≤4000 chars used>",
  "docIds": ["<brain doc id>", …],
  "lang": "ar" | "en",
  "cid": "<uid()>",
  "product": "brain",
  "tier": "pro",
  "chatId": "<server chat id or \"\">",
  "messages": [ { "role": "user", "content": "<question>" } ]
}
```

- `q = task || last user message` (server.mjs:11705-11707); empty → throws `brainask_no_question` (11708).
  `handleBrainSearch` uses `q.slice(0,4000)` (9110) and the answer prompt uses `q.slice(0,4000)` (11754).
- `docIds`: array, first 20 kept (11709); inside the search only ids matching `brainIdOk` =
  `/^[A-Za-z0-9_-]{1,64}$/` (8037, 9112) survive, and unknown ids simply match nothing. An empty list
  searches the caller's **whole** corpus (9135-9136).
- `lang`: `"en"` only if exactly `"en"`, else Arabic (11710).
- `product:"brain"` matters for the push copy (`بحث فِراس برين`); `tier` is not used by the answer (11757-11759 pass no tier → `TIERS.pro` model, 7434).
- A member `chatId` gets the answer upserted into that chat as an assistant turn keyed by `cid` (11900).

### 3.2 What the worker does (`runBrainAskJob`, server.mjs:11702-11765)

1. Retrieval through the real `handleBrainSearch` (server.mjs:9103-9173) with a synthetic request
   (`makeCaptureReq`, 9369-9385) carrying the owner's freshly minted cookie and headers
   `{cookie, "content-type":"application/json", "x-forwarded-for":"127.0.0.1"}` (11856), `socket.remoteAddress`
   `127.0.0.1` (9379); body `{"q","docIds","k":10,"cid":rec.cid}` (11715). Inside the search:
   - `brainCaller` → `403 {"error":"signin_required","feature":"brain"}` if no identity (8343-8346; cannot happen here, the cookie is minted).
   - rate limit `brain:q:<id>` 120/min → `429 {"error":"too many requests"}` (9105).
   - **quota charge happens here** (9114-9134). Guests: `guestChargeWithReq` (1306-1310) charges the
     per-cookie bucket `GUEST_LIMITS.brain = 120/day` (1146) and then the per-IP bucket
     `120 × GUEST_IP_MULTIPLIER 4 = 480/day` (1256-1275). `clientIp` trusts `x-forwarded-for` only with
     `TRUST_PROXY=1` and otherwise reads `socket.remoteAddress` (1087-1095) — both are `127.0.0.1` for
     every worker request, so **all guest brainask jobs on the server share one network bucket of 480
     searches per day**. Either denial → `429 {"error":"guest daily limit reached","guest":true,"quota":{"product":"brain","used","limit":120|480,"plan":"guest"[,"scope":"network"]}}`
     (1286, 1272-1273). Members: all plans `brain:-1` = unlimited (1353-1356), never denied. The same
     `cid` is idempotent for `RETRY_WINDOW_MS` = 120 s (1213, 1225-1238, 9128), so the worker's three
     attempts do not triple-charge.
   - no docs → `{"hits":[],"docs":0,"mode":"none"}` (9137); page-range scoping is not applied (the job sends none).
   - hits: `kbSearchIn(docs, q, 10, 0.18, true)` + neighbour expansion, each
     `{score, text, docId, title, kind, unit:"page"|"slide"|…, page, label, ci}` (9171-9172).
2. A non-2xx search response is thrown as `"brain_search_<status>:<error>"`, e.g.
   `brain_search_429:guest daily limit reached` (11720-11724). Only `parsed.error` is carried — the
   `quota` object (and its `scope`) is lost. It is retried up to 3 attempts by the generic worker, then
   `failed` with that string. A throw from inside `handleBrainSearch` itself (storage) is not wrapped and
   surfaces as its own message, also retried.
3. No hits (or unparsable search body) → the job **completes** with a canned answer (11727-11732):
   - ar: `ما لكيت شي بملفاتك يجاوب على هذا السؤال.`
   - en: `I could not find anything in your files that answers this.`
4. Excerpts are numbered `[n] (<title ≤60> — <label>)\n<text>` with `label = h.label || ("page "|"slide ") + (page ?? "?")`,
   packed into a 24,000-char budget in hit order, stopping at the first block that does not fit
   (11736-11746). All empty → completes with `المقاطع المسترجعة فارغة.` / `The retrieved excerpts were empty.` (11747).
5. One `llmComplete` (no tier → `TIERS.pro` model, 7434; `BRAINASK_TOKENS = 3000` env-overridable, 11700;
   T=0.2) with a system prompt requiring Arabic or English, every claim to cite the page label exactly
   as written in parentheses, e.g. `(page 42)` / `(صفحة ٤٢)` when the label is Arabic, never to fill
   gaps from own knowledge, never a `#`/`##` heading (11749-11753). Empty → throws `brainask_empty` (11760).
6. `cr._answer = demoteHeadings(answer)` (any `#`/`##` outside code fences becomes `###`, server.mjs:10589-10592),
   then `onProgress` publishes it once (11762). Delivered as plain markdown; there is no `sources`
   array — citations are inline text only. There is no `[Sn]` numbering here (that is the live web
   path); Brain's coverage bar cannot be fed from this answer unless the client re-parses `(page N)` /
   `(صفحة N)` labels or re-runs `/api/brain/search` with the same `cid` (free within 120 s for a guest, always free for a member).

### 3.3 Status / result

`GET /api/chat/job?id=` → `phase:"processing", text:""` until the single model call returns (a few
seconds to ~1 min), then `phase:"completed", text:"<markdown answer>"`. `surface` and `progress` are `null`.

### 3.4 Error codes for brainask

| `error` | Origin | UI |
|---|---|---|
| `brainask_no_question` | 11708 | client bug |
| `brainask_empty` | 11760 | model returned nothing after 3 attempts — "try again" |
| `brain_search_429:guest daily limit reached` | 11721 + 1286 / 1272 | guest daily Brain ceiling (120 per guest, or the shared 480 network bucket) — show the sign-up upsell |
| `brain_search_429:too many requests` | 11721 + 9105 | 120 searches/min for this identity |
| `brain_search_403:signin_required` | 11721 + 8345 | cannot happen (cookie is minted) — treat as auth error |
| `no_answer`, `payload_missing`, `user_not_found` | as in 2.7 | |
| any other string | 11858 | a throw inside `handleBrainSearch` (storage); retried 3× |

### 3.5 Web parity note

The web's `brainAsk` never uses this kind; it goes `POST /api/brain/whole {q, docIds, cid, mode}` first
(members only, app.js:86754, 86774), then `POST /api/brain/search` (86844, 86904) + a live `/api/chat`
stream with `nomem:true` (app.js:86697-86960). `brainask` on the server is therefore a **superset that
is safe to use** but has no in-product precedent for UI states; expect a single non-streaming answer.

---

## 4. Code deliverable inside ORDINARY chat (the code box)

Nothing on the server distinguishes a code turn. The native client must reproduce the web's client-side
routing, prompt, transport flags, live rendering and persisted format.

### 4.1 Deciding that a turn is code (app.js:2733-2871)

Regex constants, verbatim (all `/i`):

- `ASKS_TO_LEARN` (2733-2734): `(?:[أا]ريد|[أا]بي|بدي|عايز|عاوز|ودي|محتاج|[أا]حتاج|[أا]بغى)\s*(?:[أا]ن\s*)?(?:[أا]عرف|[أا]فهم|[أا]تعلم|تعلم|معرف[ةه]|فهم)|كيف\s*(?:[أا])?(?:سوي|عمل|بني|صنع|كتب|اسوي|اعمل|ابني)|يعني\s*[إا]يه|شنو\s*يعني|\bhow\s+(?:do|can|to|would)\b|\bi\s+want\s+to\s+(?:know|learn|understand)\b|\bi\s+need\s+to\s+(?:know|learn|understand)\b|\bwhat\s+(?:is|are|does)\b|\bteach\s+me\b|\blearn\s+(?:about|how)\b`
- `CODE_BUILD_VERBS` (2743-2744): `(اصنع|إصنع|اعمل|إعمل|سو[يّ]?ي?|سويي|ابن[يي]|أبني|اكتب|أكتب|انشئ|أنشئ|صم[مّ]|[أا]ريد|[أا]بي|بدي|عايز|عاوز|بغيت|ودي|محتاج|[أا]حتاج|ابغى|أبغى|generate|create|make|build|write|develop|design|implement|code\s+me|build\s+me|i\s+want|i\s+need)`
- `CODE_HARD` (2746-2747): `\bhtml\b|\bcss\b|\bjavascript\b|vanilla\s*js|كود|\bcode\b|سكربت|سكريبت|\bscript\b|<!doctype|\bc\+\+|\bcpp\b|\bjava\b|\bc#|csharp|\brust\b|\bgolang\b|\bkotlin\b|\bswift\b|\bphp\b|\btypescript\b|\bpython\b|بايثون|برنامج|برمجة|سي\s*بلس\s*بلس|جافا`
- `CODE_SOFT` (2749-2750): `موقع|\bwebsite\b|web\s*site|web\s*page|webpage|صفحة\s*ويب|landing\s*page|single[-\s]?file`
- `CODE_SPEC` (2752-2753): `single[-\s]?file\s*(html|website|web\s*site|site|page|web\s*page)|<!doctype\s*html|(ملف|صفحة|موقع|كود)\s*html|html\s*(file|website|site|page)|سنكل\s*فايل|single\s*html`
- `CODE_DOC_OVERRIDE` (2755-2756): `powerpoint|pptx|بوربوينت|باوربوينت|عرض\s*تقديمي|شرائح|سلايد|\bpdf\b|بي\s*دي\s*اف|excel|xlsx|اكسل|[إاأ]ي?كس[يى]?ل|\bword\b|docx|وورد|(?:ملف|مستند|بصيغة|صيغة)\s*ورد|\bcsv\b`
- `CODE_GENERIC` (2765-2766): `\bprogram\b|\bapp(?:lication)?\b|\bfunction\b|\bclass\b|\balgorithm\b|\bsnippet\b|\bgame\b|\bCLI\b|\bAPI\b|\bendpoint\b|\bregex\b|\bquery\b|\b(?:bash|shell)\b|\bdashboard\b|\bplatform\b|\bportfolio\b|\blanding\s*page\b|\bstore\b|\bstorefront\b|\be-?commerce\b|\bblog\b|تطبيق|دالة|خوارزمية|لعبة|متجر|منص[ةه]|لوح[ةه]\s*تحكم|داشبورد|بورتفوليو|صفح[ةه]\s*هبوط|مدون[ةه]`
- `DOC_NOUN` (2770-2771): `\b(report|summary|essay|book|ebook|guide|manual|paper|article|letter|cv|resume|story|outline|notes?|memo|thesis|brochure|worksheet)\b|تقرير|ملخّ?ص|مقال|كتاب|دليل|بحث|رسالة|سيرة\s*ذاتية|قصة|مذكرة|أطروحة|كرّاس|ورقة\s*عمل`
- `DRAW_REQUEST` (2798): `\b(draw|sketch)\b|ارسم|إرسم|ارسملي|ارسم\s*لي|رسم\s*بياني|رسم\s*دالة|رسم\s*شكل|رسم\s*مثلث|رسم\s*دائرة|رسمة|رسمه|مخطّط|مخطط`
- `DRAW_AS_APP` (2799): `website|web\s*app|web\s*page|\bpage\b|\bsite\b|interactive|canvas|\bhtml\b|\bcss\b|javascript|\bjs\b|\bgame\b|موقع|صفحة|تطبيق|تفاعل|لعبة`

`detectCodeRequest(text)` (2800-2837), in order: `null` if `CODE_DOC_OVERRIDE`; `null` if `DRAW_REQUEST`
and not `DRAW_AS_APP` and not `CODE_SPEC`; spec if `CODE_SPEC`; `null` if `ASKS_TO_LEARN`; `null` if no
`CODE_BUILD_VERBS`; `null` if `DOC_NOUN` and none of `CODE_SPEC|CODE_GENERIC|CODE_SOFT|\bcode\b|كود|\bscript\b|سكر[يى]?بت|سكريبت|<!doctype`;
spec if `CODE_HARD|CODE_SOFT|CODE_GENERIC`; else `null`.

Spec (`codeSpecFromText`, 2775-2792) on the lower-cased text — a web-ish word
(`\bhtml\b|website|web\s*site|web\s*page|موقع|صفحة|<!doctype`) forces HTML; otherwise first match:

| trigger | `lang` | `ext` | `label` | `filename` |
|---|---|---|---|---|
| `\bpython\b|بايثون` | `python` | `py` | `Python` | `script.py` |
| `\bc\+\+|\bcpp\b|سي\s*بلس\s*بلس|سي\+\+` | `cpp` | `cpp` | `C++` | `main.cpp` |
| `\bjava\b` or `جافا`, not `javascript|جافا\s*سكر|جافاسكربت` | `java` | `java` | `Java` | `Main.java` |
| `\bc#|c\s*sharp|csharp|سي\s*شارب` | `csharp` | `cs` | `C#` | `Program.cs` |
| `\brust\b|راست` | `rust` | `rs` | `Rust` | `main.rs` |
| `\bgolang\b|لغة\s*go` | `go` | `go` | `Go` | `main.go` |
| `\bkotlin\b|كوتلن` | `kotlin` | `kt` | `Kotlin` | `Main.kt` |
| `\bswift\b|سويفت` | `swift` | `swift` | `Swift` | `main.swift` |
| `\bphp\b` | `php` | `php` | `PHP` | `index.php` |
| `\btypescript\b` | `typescript` | `ts` | `TypeScript` | `main.ts` |
| `\bcss\b|stylesheet` | `css` | `css` | `CSS` | `styles.css` |
| `\bjavascript\b|vanilla\s*js|\bnode(?:\.js)?\b|جافا\s*سكر|جافاسكربت` or `\bjs\b` | `javascript` | `js` | `JavaScript` | `script.js` |
| default | `html` | `html` | `HTML` | `index.html` |

Follow-up (`codeFollowupSpec`, 2850-2870): never in plan mode (2851); if the most recent assistant turn
parses as `firas-code` and the user message is not `CODE_DOC_OVERRIDE`/a file request, and is not an
explanation (`(اشرح|وضّح|فسّر|ما\s*معنى|شنو\s*يعني|شرح|\bexplain\b|what\s+does|how\s+does\s+it|why\s+is)` without `CODE_BUILD_VERBS`),
and matches `detectCodeRequest` or `CODE_FOLLOWUP` (2843-2844:
`عدّل|عدل|تعديل|عدّله|عدله|غيّر|غير|بدّل|بدل|أضف|اضف|اضيف|ضيف|احذف|أصلح|اصلح|صحّح|صحح|كمّل|كمل|كمّله|كمله|أكمل|اكمل|استمر|واصل|زِد|زد|حسّن|حسن|طوّر|طور|اجعل|اجعله|خلّي|خلي|أعد|اعد\s*كتابة|نفس\s*الكود|لا\s*يعمل|ما\s*يعمل|لا\s*يشتغل|ما\s*يشتغل|مايشتغل|مو\s*شغال|مش\s*شغال|معطّ?ل|خربان|توقف|يعلق|علق|فيه?\s*(?:خطأ|مشكلة|باگ|باق)|خطأ|مشكلة|edit|modif|chang|updat|\badd\b|remov|delet|\bfix\b|continu|improv|refactor|append|extend|rewrit|make\s+it|same\s+code|keep\s+going|\bbug\b|\berror\b|broken|crash(?:es|ed)?|doesn'?t\s+work|does\s+not\s+work|not\s+work(?:ing)?|won'?t\s+(?:work|run|start|open|load)|nothing\s+happens|stopped\s+working|\bstuck\b`),
reuse the previous `{lang, ext, label, filename}`.

### 4.2 Request to the server (app.js:42397-42439, 42624)

- Prior assistant `firas-code` turns are **unwrapped to raw code** before sending (42400-42403).
- `requestMessages = [{role:"system", content: codeSystemPrompt(spec)}, ...conversation]`, `requestTier = "ultra"`, `aiMsg.think = false` (42404-42417).
- **Silent fresh-facts search** (42424-42438): if the last user message has no images and
  `siteNeedsFreshFacts(text)` (41009-41013: text ≥12 chars and matches `FRESH_FACT_SIGNALS` =
  `\b(latest|newest|current(?:ly)?|up[\s-]?to[\s-]?date|this\s+(?:year|season|month)|today'?s|202[6-9]|price[sd]?|pricing|cost|spec(?:ification)?s?|release[sd]?|launch(?:ed)?|version|standings?|schedule|fixtures?|rankings?|statistics|market|exchange\s*rate|weather|news)\b` /i
  or `FRESH_FACT_SIGNALS_AR` = `أحدث|احدث|الأحدث|الجديدة?|الحالي[ةه]?|حالياً|هسه|هذا\s*(?:العام|الموسم|الشهر)|سعر|أسعار|اسعار|التسعير|تكلفة|مواصفات|إصدار|اصدار|نسخة|ترتيب\s*الفرق|جدول\s*المباريات|مواعيد|تصنيف|إحصائيات|احصائيات|أخبار|اخبار|الطقس|سعر\s*الصرف|٢٠٢[٦-٩]`, 41005-41008),
  the client runs `fetchWebSearch(text, 3500 ms)` and, if it returns hits, inserts
  `{role:"user", content: formatSearchContext(hits, lang)}` (41141) immediately after the system prompt.
  No badge, no spinner; a failed or slow lookup is ignored. Otherwise no web search and no thinking.
- Body: `{ "messages": [...], "tier": "ultra", "think": false, "cid": "<uid>", "product": "ai",
  "chatId": "<serverId or \"\">", "nokb": true }` (42624; `think` is `aiMsg.think && rtModel.showThinking` = false).
  `nokb` suppresses knowledge-base injection without suppressing history saving (server.mjs:12815-12817;
  the injection is anyway off unless `KB_IN_CHAT=1`, 12814). Sent to `POST /api/chat` (live SSE) or, for
  a saved chat, to `POST /api/chat/job` with `kind` omitted (→ `"chat"`) and polled by `fetchChatJob`
  (app.js:41202-41290): poll gaps 350 ms for the first 10 s, 700 ms until 40 s, then 1,200 ms; `401`/`403`
  on a poll → stop (`job_unowned`); >20 consecutive failed polls → give up (`job_unreachable`); growth of
  `text`/`reasoning` is re-emitted as SSE deltas and `data: [DONE]` at a terminal phase. The turn is
  charged like any other chat turn (see the chat-jobs report).

`codeSystemPrompt(spec)` (app.js:6664-6729) returns these lines joined by `\n` (`label` = spec.label,
`YEAR` = current year; `[html]` lines when `spec.lang === "html"`, `[else]` otherwise):

```
You are an elite senior software engineer. Produce a COMPLETE, production-quality <label> deliverable as ONE single self-contained file.

STRICT OUTPUT RULES:
- Output ONLY the raw <label> source code for that one file — nothing else.
- Do NOT wrap the code in Markdown code fences (no triple backticks), and do NOT add any explanation, preamble, or closing remarks.
- Never use placeholders like "continue here", "...", "rest of the code", "TODO", or any truncation. Write the ENTIRE file to completion, however long it needs to be.
[html] - For HTML: put ALL your OWN HTML, CSS and JavaScript INSIDE this one file (inline <style> and <script>) — no companion .css/.js files, and no framework you were not asked for. Third-party LIBRARIES are the exception, governed by the CDN rule below: reach for one only when the task genuinely needs it (real 3D, charts, physics, maps), never for styling or convenience.
[else] - Keep everything in this single file; avoid external dependencies unless the user explicitly asks.
[html] - BUILD IN ORDER and BUDGET your output so you REACH THE END: <head> + a FOCUSED <style> (only the CSS the sections actually need — do NOT over-expand or pad the CSS), then the COMPLETE <body> with EVERY section, then <script>, then </html>. The document MUST end with </html>. NEVER spend your whole budget on CSS and stop before the <body>.
[else] - Structure the file so it is COMPLETE and ends properly with every block/function closed.
- Write clean, well-organized, professional code with helpful comments and consistent formatting.
- Follow EVERY requirement in the user's request precisely. Prefer more complete over shorter.
- THE CURRENT YEAR IS <YEAR>. Any copyright line, footer, changelog, date, "last updated" or example date you write MUST use <YEAR> — never a year from your training data. A footer reading "© <YEAR-3>" is a defect.
- Make it genuinely INTERACTIVE, not a static mockup: buttons, links, tabs, menus, forms, sliders and modals must all actually work in the page, wired with real JavaScript. Nothing may be decorative — if it looks clickable it must do something.
[html] - HEAVY LIBRARIES ARE ALLOWED AND EXPECTED WHEN THE TASK NEEDS THEM. If the request needs real 3D, data-visualisation, physics or mapping (Three.js, D3, Chart.js, Cannon, Leaflet…), load it from a CDN with a PINNED version — e.g. <script src="https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.min.js"></script>, or an importmap + `import * as THREE from 'three'` for ES modules. Naming a library in the request IS explicit permission. Never fake a 3D scene with CSS/divs when a real WebGL one was asked for, and never hand-roll a renderer.
[else] - Use the language's standard library; add a dependency only if the task genuinely needs one.
[html] - IF THE REQUEST NAMES A FRAMEWORK OR TOOLCHAIN THAT CANNOT RUN FROM A SINGLE FILE (Next.js, React, Vue, Svelte, TypeScript, React Three Fiber, Tailwind config, npm packages, a build step), DO NOT emit that code — it would produce a blank page. Translate it into the equivalent that runs when the file is opened directly, and deliver EVERY feature that was asked for: React Three Fiber → Three.js from a CDN; JSX/TSX → plain DOM or template literals; TypeScript → JavaScript; Tailwind → real CSS in the <style>; npm imports → CDN or importmap. Keep the design, the interactions and the feature list intact. Never mention what you dropped, never apologise, and never explain the substitution — just ship the working file.
[else] - If the request names tooling that does not fit one file, deliver the equivalent that runs as written.
[html] - ON A LARGE BRIEF, SPEND THE BUDGET IN THIS ORDER: (1) the centrepiece the request is actually about, fully working and beautiful — if it is a globe it must really render in WebGL, really rotate, really respond to drag/zoom/click; (2) the surrounding UI and layout with the stated visual language (glassmorphism, lighting, motion) done properly; (3) the secondary panels and data views; (4) nice-to-haves. Cut depth from (3) and (4) before you ever cut quality from (1). Fifteen half-finished sections is a failure; one stunning working centrepiece with fewer side panels is a success. Every feature you DO include must be real.
[else] - On a large brief, make the core capability genuinely work before adding breadth.
[html] - USE REAL DATA, not lorem ipsum: real country names, real capitals, real coordinates, plausible figures. Placeholder content in a finished-looking UI reads as broken. If an API key would be required, generate a rich embedded dataset in the file instead — never call an API that needs a secret, and never leave a fetch() that will fail.
[else] - Use realistic sample data rather than placeholders.
- Begin your response immediately with the first character of the code (e.g. <!DOCTYPE html>).
```

### 4.3 Wire format of the stream (server.mjs:2767-2797, `sseWrite`)

Each token: `data: {"choices":[{"delta":{"content":"<text>"}}]}\n\n` (a `reasoning` key appears in
`delta` for thinking models); end: `data: [DONE]\n\n`. The content is raw source — no fence — unless the
model disobeys, which is why the client strips one leading/trailing fence (`stripCodeFences`, app.js:6495-6500).

### 4.4 Live rendering while streaming (app.js:6732-6769, 6901-6924, `renderLiveCodeInto`)

- The card appears from the first frame with header `filename` + `label` + live line count
  (`codeLineCountText`, 6544-6547: Arabic `arDigits(n) + " سطر"`, English `n + " lines"`) and the writing
  indicator `يكتب الكود…` / `Writing code…`; body is `dir="ltr"`; append only the new tail; auto-follow only when
  the reader was within 28 px of the bottom.
- When the router did NOT flag the turn but the answer is ≥200 chars and opens with a fence after at most
  one ≤160-char line, `midStreamCodePromotion` (6653-6662) virtually closes the fence and runs the same
  gates as finalize (`promoteAnswerToCode`), boxing it anyway; once boxed it stays boxed (`boxLatched`).

### 4.5 Finalize and persist (app.js:42784-42844, 42950-42970)

1. Checkpoint first (42784-42801): `aiMsg.content` is written as the `firas-code` fence around
   `sanitizeContinuation(tidyCodeArtifact(answer, lang))` and persisted before any animation.
   `tidyCodeArtifact` (6522-6535) strips fences and cuts an HTML document to the first `<!doctype`/`<html`
   … last `</html>`; `sanitizeContinuation` (38978-38982) removes leaked `firas-code` meta (`cleanCodeBody`,
   38971-38976), every remaining ```` ``` ```` and the `ALREADY_COMPLETE` sentinel.
2. If `!codeLooksComplete(code, lang)` (38890-38929: html must end `</html>`; for `js|javascript|jsx|mjs|cjs|ts|typescript|tsx|java|c|h|cc|cpp|hpp|cs|go|rust|rs|php|swift|kt|kotlin|scala|dart|css|scss|sass|less|json`
   all three bracket families must balance after blanking strings/comments/regex and the text must end
   in `} ) ; ] >` or a comment; other languages reject only a dangling operator, opener, keyword, `:` or `\`),
   run `autoCompleteCode` (39056-39133): ≤16 rounds, stop at 900,000 chars, context bounded to 140,000
   (head 2,000 + tail), each round streams on tier `ultra` with `codeContinueSystemPrompt` (38984-38995) +
   prior turns (assistant code unwrapped, last 4,000 chars) + `{role:"assistant", content: code}` +
   `codeContinueUserMsg` (39025-39030) + a state hint (`codeProgressHint`, 39034-39047, prefixed
   `الخطوة التالية المطلوبة: ` / `Required next step: `), joined by `joinCodeContinuation` (39000-39022:
   seam-overlap up to 4,000 chars and restart de-dup); two consecutive no-progress rounds stop it. Status
   text `يُكمل تلقائيًا…` / `Auto-completing…` (42835).
3. For html > 6,000 chars that is complete and has <600 chars of inline script,
   `enhanceCodeInteractivity` (39140-39177) runs once on tier `ultra` and inserts one `<script>` before
   `</body>`; status `يطوّر التفاعلية والجافاسكربت…` / `Enhancing interactivity…` (42841).
4. Persist as `` ```firas-code `` + `JSON.stringify({filename, lang, ext, label})` + `\n` + code + `\n` + `` ``` `` (42843-42844).
5. Stop pressed mid-stream: keep the partial inside the same wrapper (42952-42954) so "Continue" works;
   a latched/promoted box keeps its partial via `midStreamCodePromotion` (42961-42964); if nothing streamed, drop the placeholder turn (42945-42948).
6. When the router missed but the answer is one whole fenced artifact (`promoteAnswerToCode`,
   6584-6638): exactly one fence; surrounding prose ≤160 chars and ≤12% of the code (unless the box was
   already latched, in which case prose is kept as `meta.intro`/`meta.outro`); the block is a whole HTML
   page, a whole SVG, or a known language (`PROMOTE_EXT`, 6577-6583) with ≥900 chars and ≥30 lines.
   Result meta: `filename:"index.<ext>"`, `lang`, `ext`, `label` (`HTML` or upper-cased lang).
7. Busy-engine sentence as the whole reply (`busyRe`, 42771) → one automatic retry with
   `يُعيد المحاولة تلقائيًا…` / `Retrying automatically…` (42777).

### 4.6 Persisted format and parser (app.js:6548-6559)

```
```firas-code {"filename":"index.html","lang":"html","ext":"html","label":"HTML"}
<code…>
```
```

Regex: `/^```firas-code[ \t]+(\{[\s\S]*?\})[ \t]*\r?\n([\s\S]*)\r?\n```[ \t]*$/` — anchored to the
whole message; greedy body so backticks inside the code are fine; the meta JSON must not contain `}`
followed by whitespace+newline before its real end (it never does — it is one line). `meta.code` is
the captured body. Optional meta keys: `intro`, `outro` (markdown rendered above/below the card,
`appendCodeCard` 6774-6785). `cleanCodeBody` (38971-38976) strips any leaked `` ```firas-code {…} `` line
or bare `{"filename":…,"lang":…,"ext":…,"label":…}` object from a body.

Other structured fences a native renderer must recognise and never treat as prose (app.js:6588, 3124):
`firas-project`, `firas-code-chat` (base64 JSON `{turns:[{role,text,n,applied,ts}]}` at project
`messages[1]`, 60609-60618), `firas-image`, `firas-agent`, `firas-deck`, `firas-ask`, `firas-file`.

### 4.7 Card actions and copy (app.js:6787-6894, 39182-39240)

- `نسخ` / `Copy` → toast `تم نسخ الكود` / `Code copied`, failure `تعذّر النسخ` / `Copy failed`.
- `تحميل` / `Download` → file named `meta.filename`, MIME from `codeMime(ext)` (6537-6543).
- `معاينة` / `Preview` only when `canPreviewCode(lang, code)`; a freshly finished complete HTML document
  auto-opens the preview once (`opts.fresh`, 6859-6863), never on a history re-render.
- `لفّ الأسطر` / `Wrap` ⇄ `لا تلفّ` / `No wrap` (default wrapped when any line > 140 chars; remembered in `localStorage["firas_code_wrap"]`).
- `كمّل` / `Continue`, plus the foot hint `الكود غير مكتمل؟` / `Code cut off?` with `كمّل الكود` /
  `Continue code`. `continueCode` refuses while a stream is active:
  `انتظر حتى ينتهي الرد الحالي` / `Wait for the current reply to finish`; already complete:
  `الكود مكتمل بالفعل ✅` / `Already complete ✅`; while continuing the header shows `يُكمل الكود…` / `Continuing…` (39240).
- `codeContinueUserMsg` (39025-39030), Arabic verbatim:
  `هذا الملف (<label>) توقّف قبل أن يكتمل وهو ناقص. أكمله من حيث توقّف بالضبط وأنهِه بالكامل (أغلق كل الوسوم والأقواس؛ ولِلـHTML أكمل <style> و</head> و<body> كاملًا والسكربتات وانتهِ بـ </html>). أخرج فقط بقية الكود الخام، دون إعادة أي سطر موجود ودون أي شرح أو علامات ```.`
  (`<label>` falls back to `كود` when missing). English: `This <label> file stopped before completing and is INCOMPLETE. Continue from exactly where it stops and finish it fully (close every tag/bracket; for HTML complete <style>, </head>, the full <body> and scripts, and end with </html>). Output ONLY the remaining raw code, never re-output an existing line, no commentary or ``` fences.`
- `codeContinueSystemPrompt(meta)` (38984-38995) lines: `You are FINISHING a single <label> file that was cut off mid-output and is INCOMPLETE.` / `You are given the user's request and the code written SO FAR (the last assistant message). It ends abruptly.` / `Output ONLY the missing remainder — the characters immediately AFTER the existing code — so that (existing + your output) is ONE complete, valid file.` / `STRICT RULES:` / `- Continue from the EXACT last character. Do NOT restart, do NOT repeat or re-output any line that already exists, do NOT summarize.` / `- Output ONLY raw <label> source. No explanations, no Markdown code fences, no new ```firas-code blocks, no JSON metadata.` / `- Finish the file COMPLETELY: close every open tag/bracket/string. For HTML, finish <style>, </head>, the full <body> markup and scripts, and end with </html>.`

---

## 5. Push notification for these jobs (server.mjs:1515-1579, 1627-1641)

Sent only for members (`rec.isGuest` or no `uid` → no push, 1628), only on `completed`/`failed`, only
when APNs env is configured (1629-1630), to every bound device, with `apns-collapse-id` = job id
(`[A-Za-z0-9_-]` ≤64, 1635). Payload (`apnsPayload`, 1562-1579):

```json
{ "aps": { "alert": { "title": "...", "body": "..." },
           "sound": "FirasComplete.wav",
           "category": "FIRAS_JOB_COMPLETE",
           "thread-id": "firas-<product>-<chatId|jobId>" },
  "firas": { "type": "job-terminal", "product": "code"|"brain", "jobId": "<id>",
             "phase": "completed"|"failed", "chatId": "<only if set>" } }
```

`thread-id` is cut to 64 chars (1575). Copy is chosen by the device's registered language
(`device.language === "ar"`, 1522), `names = { ai: "إجابة فِراس", agent: "مهمة وكيل فِراس", code: "مشروع فِراس كود", brain: "بحث فِراس برين" }` (1553):
- completed: title `<name> اكتملت`, body `اضغط لعرض النتيجة.` (1556)
- failed: title `<name> لم تكتمل`, body `اضغط لعرض التفاصيل أو المحاولة مجدداً.` (1557)

English (1554, 1558-1560): `Firas Code project is ready` / `Tap to view the result.`;
`Firas Code project could not finish` / `Tap to view details or try again.`; `Firas Brain search is ready` /
`Firas Brain search could not finish`.

`product` is derived from `rec.kind` first (`codebuild`→`code`, `brainask`→`brain`), then `rec.product` (1515-1520).

---

## 6. Native implementation checklist

- Enqueue with a fresh `cid` per build/ask (`[A-Za-z0-9_-]{1,64}`); keep `{chatId(local), jobId, name, ts(start)}`
  in persistent storage; poll `GET /api/chat/job?id=` every 4 s (build) / 2 s (ask), or subscribe to
  `/api/agent/job-stream` and fall back to polling; tolerate 2 min of silence; treat
  `completed|failed|unknown` as terminal; forget the pointer only after the files are saved locally, and
  drop any pointer older than 2 h without polling.
- For a build, expect **no incremental text**. Show an indeterminate "building on the server" state with
  the `srvKeep` copy; do not promise per-file progress.
- On any poll whose `text` contains a parseable fence — including `failed` — save the files. On
  `completed`, parse with the poll-tolerant regex, enforce the 30-file / 60,000-char / 180,000-char caps
  before writing `messages[0]` of the project chat, and never write an empty file list over an unloaded chat.
- On `failed` with nothing saved, map `error` to the `srvFail` copy; a retry must use a new `cid`.
- Pass `chatId:""` for codebuild unless you want the server to also append the fence as a chat message.
- For the chat code box, replicate `codeSystemPrompt`, send `tier:"ultra"`, `think:false`, `nokb:true`,
  optionally the silent fresh-facts search block, strip fences, wrap the result as `firas-code` with
  `{filename, lang, ext, label}`, and keep "Continue".
- Guests: allowed for both kinds; Brain retrieval charges the guest daily Brain allowance (120 per guest
  plus a server-wide 480 network bucket) at the time the search runs inside the job, not at
  `POST /api/chat/job`; the failure reaches the client as `error:"brain_search_429:guest daily limit reached"`.
