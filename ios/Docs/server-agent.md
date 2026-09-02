# Firas Agent — server contract for the native client

Source of truth: `server.mjs` (worktree root). All line numbers below are `server.mjs:<line>` unless the file is named. The web client (`app.js`) is cited only where it defines UI copy or a client-side behaviour the native app must reproduce or deliberately drop.

Read this once, top to bottom. Section 1 is the mental model; sections 3–8 are the wire contract; section 12 is the copy-paste recipe.

---

## 1. Mental model (what actually runs)

1. A mission is a **durable chat job** of `kind: "agentrun"`, created by `POST /api/chat/job` (`handleChatJobStart`, 12531). There is no dedicated "agent start" route any more — `/api/agent/start` and `/api/agent/poll` answer **410** `{"error":"durable_agent_route_required"}` (13758–13760).
2. The server worker (`runOneJob`, 11767 → `runAgentJob`, 11089 → `agentTwinManus`, 10820) hands the task to the owner's **Manus** account (`api.manus.ai/v2`, `MANUS_BASE` 8503). **There is no server-side fallback pipeline.** If Manus is unconfigured, refuses, or fails, the job ends in `phase: "fail"` with an error code (11097–11110). `agentPlanSteps` (10600) with its three-kind `research|write|solve` planner exists in the file but is **never called** on the agentrun path (grep: only its definition references it). The "phases/steps/tools search/fetch/python/verify/enhance/assemble/test" vocabulary belongs to the **browser's in-tab pipeline** in `app.js`, which the native app does not have and does not need.
3. Progress is a **snapshot**, not a token stream: the worker rebuilds a whole `surface` object every ~1.5 s (`MANUS_POLL_MS` 8517) from Manus's verbose message log and publishes it via `onProgress` (`publish`, 10996–11003). The native client reads the snapshot either by polling `GET /api/agent/job?id=` (12100) or by subscribing to `GET /api/agent/job-stream?id=` (SSE, 12183). Both return the same JSON object (`agentJobViewPayload`, 12055).
4. When the mission ends, the worker writes the final answer into the user's chat as an assistant message whose content is a ```` ```firas-agent ```` fence containing the same surface JSON (or plain text for a "conversation" reply) — 11077–11078, 11897–11900.
5. Credits: every signed-in account has a **daily** allowance (`MANUS_USER_CREDITS`, default **500**, 8509). A running mission **holds** `min(600, remaining)` credits (`MANUS_MAX_TASK` 8512, hold computed 10860) and settles against Manus's real `credit_usage` at the end (11024–11025, `settle` 10971–10993). Because the hold is normally the whole day's allowance, **only one mission per account can run at a time** — the second gets **409 `agent_busy`**.
6. Guests are refused everywhere on this path: `/api/usage/charge` → 403 `signin_required` (7664–7666); `/api/chat/job` → 403 `account_required` (12554–12556); worker → `account_required` (10822).

---

## 2. Endpoints at a glance

| Method | Route | Handler | Auth | Rate limit | Purpose |
| --- | --- | --- | --- | --- | --- |
| POST | `/api/usage/charge` | `handleUsageCharge` 7654 | member or guest cookie | none | Pre-flight quota gate (members: effectively a no-op, see §3) |
| POST | `/api/chat/job` | `handleChatJobStart` 12531 | member (guest → 403 for agent) | `chatjob:<callerId>` 60/min members, 30/min guests (12540) | Create the mission (idempotent by `cid`) |
| GET | `/api/agent/job?id=` | `handleAgentJobView` 12100 | member or guest cookie; must own the job | none | One snapshot |
| GET | `/api/agent/job-stream?id=` | `handleAgentJobStream` 12183 | same | `agent-job-stream:<owner>:<ip>` 90/min (12189) | SSE snapshots until terminal |
| GET | `/api/chat/job?id=` | `handleChatJobStatus` 12658 | same | none | Generic job status (raw surface, raw ctl error) — usable but §7 is the better view |
| GET | `/api/agent/artifact?id=&index=[&download=1]` | `handleAgentArtifact` 12419 | same | `agent-artifact:<owner>` 30/min (12432) | Download a file the agent produced |
| POST | `/api/chat/cancel` | `handleChatCancel` 12478 | member or guest cookie | none | **Does not stop an agent mission** (§9) |
| GET | `/api/agent/credits` | `handleManusCredits` 8960 | member or guest cookie | none | Credit ledger view |
| POST/GET | `/api/agent/start`, `/api/agent/poll` | — | — | — | **410 Gone** `{"error":"durable_agent_route_required"}` (13758) |

Auth cookies: member session `firas_session` (`COOKIE_NAME`, 1046; validated by `currentUser`, 1098, including session-version check); guest `firas_guest` (`GUEST_COOKIE`, 1131; `currentGuest`, 1156; ids start with `g_`). `callerOf` (1314) returns `{user, id, isGuest:false}` or `{id, isGuest:true}` or `{}`. Every handler above returns **401** `{"error":"authentication required"}` when `callerOf` yields nothing.

---

## 3. Pre-flight: `POST /api/usage/charge`

`handleUsageCharge` 7654–7681. The web client calls this before every mission (`chargeUsage`, app.js 46866; gate at app.js 59540–59560). The native app should keep the call for parity, but understand what it does:

Request body (JSON, ≤ 2 000 chars, 7658):

```json
{ "product": "agent", "cid": "<same cid you will use for /api/chat/job>" }
```

- `product` must be `"code"` or `"agent"` → else **400** `{"error":"invalid product"}` (7659–7660).
- Guest + `agent` → **403** `{"ok":false,"error":"signin_required","feature":"agent"}` (7664–7666).
- Member: `limitsFor(planOf(user)).agent` is **-1 for every plan** (`PLAN_LIMITS` 1349–1356 — "THE SITE IS FREE"), so the handler returns **200** `{"ok":true,"sub":<subInfo>}` immediately (7672) without counting anything. The `agentCids` idempotency array (7677–7679) is dead code under the current limits.
- `sub` shape (`subInfo`, 1386): `{plan:"free"|"gold"|"diamond"|"unlimited", expiresAt:number|null, daysLeft:number|null, limits:{ai,code,agent,brain}, used:{...}, remaining:{...}}` with `-1` meaning unlimited.

So for members the real gate is **credits**, enforced by `/api/chat/job` (§4) and the worker (§5). A 429 `{"error":"daily quota reached","quota":{product,used,limit,plan}}` (7678) cannot occur today but the client should still map it to the "credits" state (§11) rather than crash.

---

## 4. Start a mission: `POST /api/chat/job`

`handleChatJobStart` 12531–12656.

### 4.1 Request

Body is JSON read with `readBody(req, CHAT_BODY_LIMIT)` (25 MB, 442) but then rejected if the **raw string length** exceeds `JOB_PAYLOAD_MAX = 600_000` characters → **413** `{"error":"payload_too_large"}` (12559, 9330).

Fields the server reads for an agent mission (12561–12649):

| Field | Type | Required | Server handling |
| --- | --- | --- | --- |
| `kind` | `"agentrun"` | yes | Only `longdoc|longfile|agentrun|codebuild|brainask` honoured; anything else becomes an ordinary chat turn (12629) |
| `product` | `"agent"` | yes (send both) | Stored `.slice(0,12)` (12630). The guest guard checks `kind==="agentrun" || product==="agent"` (12554) |
| `task` | string | yes | Stored on the control record `.slice(0,8000)` (12631); the worker reads the **full** string from the stored payload (`body.task`, 11093–11094), falls back to the last `role:"user"` message content |
| `title` | string | recommended | `.slice(0,160)` (12632); becomes `surface.title` (10693) |
| `messages` | `[{role:"user", content:<task>}]` | **yes** | Must be a non-empty array or **400** `{"error":"messages required"}` (12557). Send one user message whose `content` is the task |
| `cid` | string `[A-Za-z0-9_-]{1,64}` | strongly recommended | Idempotency key; the job id is derived from it (12562–12563). If omitted the server mints `"j"+12 hex` and you cannot retry safely |
| `chatId` | string ≤ 64 | yes for members who want the answer filed into a chat | Must be the **server** chat id (`chat.serverId` in app.js 59410). Stored only for members (12627). Without it the answer is never written to chat history (11898) |
| `lang` | `"ar"` \| `"en"` | recommended | Anything but `"en"` → `"ar"` (12633). Controls Manus `locale` and Arabic/English "Files:" label |
| `tier` | string | optional | Any key of `TIERS`, else `"pro"` (12627). Not used by the Manus path; stored on the chat turn |

Attachments: **there is no `attachments` field** — `runAgentJob` reads only `body.task`, `body.messages` and `body.lang` (11090–11096). The web client folds file text / vision output into the `task` string before posting (`agentServerRun`, app.js 59399–59412 posts `task` and `messages[0].content` both sliced to 120 000 chars; the folding happens in `runAgentAssistant`, app.js 59605–59650). The three section headers it appends, verbatim, in this order:

1. `=== خلاصة الملف المرفق (كل المتطلبات والأرقام — اعمل بها) / ATTACHED FILE BRIEF (every requirement and figure — work from it) ===` + brief ≤ 3 500 chars (59627)
2. `=== محتوى الصورة/الصور المرفقة (مصدر) / ATTACHED IMAGE CONTENT (source) ===` + vision text ≤ 30 000 (59633; a "rebuild this design" variant beginning `=== مرجع بصري مرفق — …` exists at 59632)
3. `=== محتوى ملف مرفق (مصدر — ابنِ المطلوب منه) / ATTACHED FILE CONTENT (source — build from it) ===` + raw file text ≤ 60 000 (59648)

A native client that wants attachments must do the same (extract text / describe images client-side or via other endpoints, then append to `task`). Note the worker trims what reaches Manus to `first 6000 + "\n\n[…]\n\n" + last 1600` chars when the task exceeds 7 800 (10883–10885), so anything past ~6 000 chars is mostly wasted.

Job id (`jobIdFor`, 733): `sha1(ownerId).hex.slice(0,10) + "-" + jobKey(cid)`, e.g. `3f9a1c2b4d-j1a2b3c4d5e6`. `jobKey` (731) replaces `[.$#[\]/\s]` with `_` and truncates to 96.

### 4.2 Response matrix

Order of checks as executed:

| Status | Body | Cause (line) |
| --- | --- | --- |
| 401 | `{"error":"authentication required"}` | no cookie (12538) |
| 429 | `{"error":"too many requests"}` | rate limit (12540) |
| 400 | `{"error":"invalid JSON body"}` | unreadable/unparseable body (12541–12542) |
| 403 | `{"ok":false,"error":"account_required","feature":"agent"}` | guest with agentrun/agent (12554–12556) |
| 400 | `{"error":"messages required"}` | (12557) |
| 413 | `{"error":"payload_too_large"}` | raw > 600 000 chars (12559) |
| 503 | `{"error":"storage_unavailable"}` | durable store read failed (12570) |
| 200 | `{"ok":true,"jobId":"<id>","phase":"completed","text":"<final answer>","reasoning":"","surface":<surface or null>,"progress":null}` | same `cid` already finished (12572–12578) |
| 200 | `{"ok":true,"jobId":"<id>","phase":"queued"\|"processing"}` | same `cid` still running (12580) |
| 200 | `{"ok":false,"jobId":"<id>","phase":"failed","error":"<ctl.error or "previous_attempt_failed">","surface":<surface or null>,"retryRequiresNewCid":true}` | same `cid` previously failed — **mint a new cid to retry** (12581–12587). `ctl.error` here is usually the JSON string `{"error":"<code>"}` (see §5.5); `surface` is the **internal** surface (upstream file URLs), do not render its `files` |
| 503 | `{"error":"storage_unavailable"}` | reservation scan failed (12604–12606) |
| **409** | `{"error":"agent_busy","activeJob":{"jobId":"<id>","chatId":"<serverChatId or "">","cid":"<cid>","title":"<≤160 chars>"},"credits":<credits>}` | another agentrun by this user is `queued` or `processing` and holds a reservation (12591–12616) |
| **429** | `{"error":"credits_reserved","credits":<credits>}` | `manusRemaining(user) <= 0` — allowance spent or still held by an earlier (possibly unsettled) reservation (12617–12619) |
| 503 | `{"error":"storage_unavailable"}` | enqueue write failed (12648–12650) |
| **200** | `{"ok":true,"jobId":"<id>","phase":"queued"}` | success (12655) |

`<credits>` is the `manusCreditView` object, §10.

Important subtlety: the 409 scan iterates `ledger.reservations` (12594), and a reservation is created **by the worker** when it claims the job (10859–10866), not at enqueue. Two POSTs with different cids fired before the worker claims the first will both be accepted (200 queued); the second then fails inside the worker with `agent_busy` (10854) and surfaces as `phase:"fail", error:"agent_busy"` on `/api/agent/job`. Treat both shapes as the same "blocked" state (§11).

### 4.3 What gets stored (control record, 12624–12646)

`{id, uid, isGuest:false, chatId, cid, tier, kind:"agentrun", product:"agent", task(≤8000), title(≤160), lang, format:"", pages:0, progress:null, phase:"queued", error:"", status:0, attempts:0, maxAttempts:3, claimedBy:null, heartbeat:0, nextAt:0, createdAt, updatedAt, finishedAt:0}`. The worker later adds `agentHold, agentSettled, agentSpent, agentState, agentDeadlineAt, startedAt, upstreamTaskId, createAttemptAt, createError`.

Control-record `phase` values: `queued` → `processing` → `completed` | `failed`. (`done` is accepted as a synonym of `completed` in readers, 12079/12123.) Finished records are deleted after `JOB_KEEP_MS = 6 h` (9329, 11956–11958) — after that `GET /api/agent/job` returns `{"job":null}` and the stream returns 404.

Worker knobs: `JOB_CONCURRENCY = 4` (9328), `JOB_STALE_MS = 120 s` (9324), `JOB_MAX_ATTEMPTS = 3` (9323), tick every 2 s (11999), boot recovery re-queues anything left `processing` (11983).

---

## 5. Worker path (what happens after 200 queued)

### 5.1 Dispatch

`runOneJob` (11767) claims the record (`phase:"processing"`, 11772), heartbeats every 15 s (11794), creates an in-memory capture `cr` (`makeCaptureRes`, 9338) registered in `jobLocal` (11815), and calls `runAgentJob(rec, payload, cr, onProgress)` (11853). `onProgress` (11800–11813) fires `agentJobStreamNotify(id)` (788) on every publish and writes `out/{id}` at most every 2.5 s (first write immediate).

### 5.2 `runAgentJob` (11089–11110)

- Parses the stored payload; `task = body.task || last user message content`; empty → throws `agentrun_no_task` (11095) → generic retry (3 attempts, backoff `attempts*5000` ms, 11928–11934) → `phase:"failed", error:"agentrun_no_task"`.
- Calls `agentTwinManus`. On `{ok:true}` returns. On `{deferred:true}` sets `cr._deferred` → record goes back to `queued` with `nextAt = now + 60 s`, `agentState:"reconciling"`, attempts unchanged (11878–11884).
- Otherwise builds a **fail surface** with `error = code` and sets `cr._status`/`cr._body` (11100–11109):

| worker error code | HTTP status recorded in `ctl.status` |
| --- | --- |
| `credits_exhausted`, `credits_reserved` | 429 |
| `agent_busy` | 409 |
| `account_required` | 403 |
| everything else (`agent_unavailable`, `agent_start_unconfirmed`, `capacity`, `task_failed`, `deliverable_missing`, `empty_result`) | 503 |

`ctl.error` becomes the string `{"error":"<code>"}` (11917, from `cr._body`), `ctl.phase = "failed"`, a push notification is sent (11918), and if `chatId` is set the fail fence is saved to the chat (11914–11916).

### 5.3 `agentTwinManus` (10820–11087) — the mission engine

Pre-checks → error codes: no `MANUS_API_KEY` → `agent_unavailable` (10821); guest uid → `account_required` (10822); user not found → `account_required` (10824).

Reservation (under a per-user lock, `withAgentUserLock` 10606):
- another reservation exists for this user → `agent_busy` (10854)
- `manusRemaining(user) <= 0` → `credits_exhausted` (10858)
- site-wide Manus balance below the hold → `capacity` (10861)
- else `hold = min(MANUS_MAX_TASK=600, remaining)`; `ledger.reservations[jobId] = {hold, day, at, state:"held", expiresAt: now+24h}`; `ledger.held += hold` (10859–10866). Patches ctl with `agentHold, agentSettled:false, startedAt, agentDeadlineAt = startedAt + MANUS_MAX_MS (30 min, 8518)`.

Task creation (`POST /task.create`, 10889–10901): body `{message:{content: MANUS_IDENTITY + task[, enable_skills:[…] when env MANUS_SKILLS is set]}, agent_profile:"manus-1.6", locale:"ar"|"en", interactive_mode:false, hide_in_task_list:true, share_visibility:"private"}`. `MANUS_IDENTITY` (8522–8530) forces the "Firas Agent, built by Mentronx in Iraq" persona and forbids naming the provider. A create failure that is a definite 4xx releases the hold and returns `agent_unavailable` (10925–10939); a timeout/5xx/malformed success marks the reservation `state:"unknown"` and returns `agent_start_unconfirmed` (10908–10923) — **the job fails and the hold stays for up to 24 h** (reservation `expiresAt` 10864, pruned in `manusLedger` 8577–8581), which is why a user can then see `credits_reserved` on the next attempt.

Polling loop (11008–11079): every `MANUS_POLL_MS = 1500` ms it reads `/task.listMessages?verbose=true&limit=200`, narrates into the in-memory `job` via `manusNarrate` (8671), publishes `"run"`, then reads `/task.detail`. While `status` is `running`/`waiting` it loops until `agentDeadlineAt`; past the deadline it returns `{error:"reconciling", deferred:true}` (11019) → requeue in 60 s and **poll again later, indefinitely** — there is no hard timeout that fails the mission. Any exception in the loop also returns `reconciling` (11081–11086).

Terminal:
- `settle(spent)` first (11024–11025), then `status === "error"` → publish `fail`/`task_failed` (11028–11030).
- Final read of the last 50 messages (11033–11035); if that read fails the job is **deferred** as `reconciling` (11038–11040) rather than finished. The newest `assistant_message.content` is the **final answer** (11043–11045), else the last `says` line.
- Files: every collected file gets a same-origin URL `/api/agent/artifact?id=<jobKey>&index=<i>` (`agentArtifactPath` 10716); upstream URLs inside the final text are replaced by those (11051); files not mentioned in the text are appended as a Markdown list under `**الملفات:**` (Arabic) or `**Files:**` (English) (11055–11058).
- If the task asked for a presentation — `wantsPpt` (11059) is exactly `/\bpptx?\b|powerpoint|slide(?:s|\s*deck)?|presentation|keynote|باوربوينت|بوربوينت|سلايد(?:ات)?|شرائح?|عرض\s*تقديمي/i` tested against the **full task string** (so an attached file that merely mentions "slides" triggers it) — and no file whose url/name ends in `.ppt/.pptx/.pps/.ppsx` or whose MIME matches `slide|presentation|powerpoint|ppt` was produced (11060–11065) → `fail`/`deliverable_missing` (11066–11068).
- No text and no files → `fail`/`empty_result` (11070–11072).
- Success: `publish("done", final)`; `cr._answer = final`; `cr._chatAnswer = presentation === "conversation" ? final : agentJobFence(surface)` (11074–11077).

### 5.4 Completion bookkeeping (`runOneJob`, 11890–11905)

`out/{id} = {text: final, reasoning:"", surface}`; `saveAssistantTurn(user, chatId, cid, cr._chatAnswer, …)` upserts the assistant message **by `cid`** (2513–2519); `ctl.phase = "completed", status:0`; APNs push `job-terminal` (§10.4); input record deleted.

### 5.5 Error code reference (all sources)

| code | Where it is produced | Native UI state |
| --- | --- | --- |
| `account_required` | 12554 (403 at start), 10822/10824 (worker) | blocked → sign-in prompt |
| `signin_required` | 7664 (`/api/usage/charge` 403) | blocked → sign-in prompt |
| `agent_busy` | 12609 (409 at start), 10854 (worker, ctl.status 409) | blocked → open the running mission |
| `credits_reserved` | 12618 (429 at start) | blocked (hold from an earlier mission) |
| `credits_exhausted` | 10858 (worker, 429) | credits (daily allowance spent) |
| `capacity` | 10861 (worker, 503) | fail, retry later |
| `agent_unavailable` | 10821, 10939 (worker, 503) | fail, retry later |
| `agent_start_unconfirmed` | 10841, 10923 (worker, 503) | fail; hold may persist ≤ 24 h |
| `task_failed` | 11029 (worker, 503); also the default `error` string for any failed job on `/api/agent/job` (12073) | fail |
| `deliverable_missing` | 11067 | fail (asked for a deck, none produced) |
| `empty_result` | 11071 | fail |
| `agentrun_no_task` | 11095 → generic retry → `ctl.error` plain string | fail |
| `no_answer` | 11932 generic worker fallback | fail |
| `storage_unavailable` | 12570/12606/12650; view 12110/12127/12131; stream | transient → retry the request |
| `job_not_found` | stream snapshot 12157 (404) | job expired/unknown → stop watching |
| `forbidden` | 12084/12095/12125/12159/12447/12458 (403) | not the owner → stop watching |
| `rate_limited` | 12190 (stream), 12432 (artifact) | back off |
| `durable_agent_route_required` | 13759 (410 on legacy routes) | never call those routes |

---

## 6. The SURFACE — exact schema

Two producers, one shape:
- `agentJobSurface` (10661–10714) builds the **internal** surface on the capture (`cr._agentSurface`) and in `out/{id}.surface`. Its `surface.files[].url` are the **upstream Manus URLs** — never shown to clients.
- `agentPublicSurface` (10724–10814) rebuilds a client-safe copy: every upstream URL is replaced by the same-origin artifact route, every string is re-sliced, and `presentation` is recomputed. **Everything a client ever receives passes through this function** (view 12056, fence 10817).

### 6.1 Top level (public)

```json
{
  "v": 1,
  "id": "3f9a1c2b4d-j1a2b3c4d5e6",
  "presentation": "task",
  "task": "…≤4000 chars…",
  "title": "…≤160 chars…",
  "phase": "run",
  "lang": "ar",
  "mode": "answer",
  "steps": [ { "title": "…≤180…", "s": "todo|run|done|fail", "kind": "write", "out": "" } ],
  "final": "…≤100000 chars, markdown…",
  "error": "…≤60 chars, one of the codes above or empty…",
  "surface": {
    "startedAt": 1756800000000,
    "endedAt": 0,
    "events": [ … ],
    "tools": [ … ],
    "says": [ "…" ],
    "files": [ … ],
    "live": [ "…" ]
  }
}
```

- `phase` ∈ `run | done | fail | queued` (public copy, ~10797). `steps` are all forced to `s:"done"` when phase is `done` (10669).
- `steps[].kind` is always `"write"` on the server path (10667) and `out` is always `""` — the server never produces per-step text; the deliverable is `final`. Do not build a per-step detail view around `out`.
- `presentation` = `"task"` iff `steps.length || tools.length || files.length || events.some(kind ∈ tool|file|browser)` (10693 internal, ~10795 public); otherwise `"conversation"` (a greeting or a direct answer). For `conversation` render `final` as an ordinary assistant bubble, no plan card.
- Caps: `steps` ≤ 20, `events` last 60, `tools` last 30, `says` last 12 (900 chars each), `files` ≤ 20, `live` last 30 (500 chars each) — see `agentPublicSurface` 10724–10814; `final` ≤ 100 000 (10678), `task` ≤ 4 000 (10698), `title` ≤ 160 (10699).
- **Provider scrubbing**: every string that reaches the surface passes `firasSurfaceText` (8654–8659), which rewrites `/manus/gi` → `Firas` and `مانوس` → `فِراس`. This also hits the user's own `task`/`title` if they contain that word. Do not "correct" it client-side; upstream URLs on a `manus.*` host are additionally dropped from `events[].url` (`firasEventUrl` 8661–8669).

### 6.2 `surface.events[]` (10761–10773, produced by `manusNarrate` 8671–8815)

| field | type | values |
| --- | --- | --- |
| `id` | string ≤120 | Manus message id or `timestamp:type` |
| `kind` | `"status"` \| `"message"` \| `"tool"` | `"plan"` events are filtered out of the public copy (10657–10660); plan rows are represented only by `steps` |
| `text` | string ≤900 | display line; tool lines look like `⚙️ Firas Browser: <arg>` (8752) |
| `name` | string ≤60 | tool name; browser-ish tools are renamed `"Firas Browser"` (8747) |
| `arg` | string ≤420 | tool argument summary |
| `toolKind` | `"browser"` \| `"tool"` \| `""` | (8746) |
| `action` | string ≤100 | tool action verb if Manus provided one |
| `status` | string ≤40 | for `status` events: Manus `agent_status` (`running`, `stopped`, `error`…); for tools: tool status; `"error"` for `error_message` events (8804) |
| `url` | string ≤600 | https URL extracted from a browser tool arg, never a `manus.*` host (8662–8670); artifact URLs are rewritten to `/api/agent/artifact?…` |
| `step` | int | index into `steps` the event belongs to, or `-1` |
| `at` | int ms | event timestamp |

Filtered out before you see them (`agentSurfaceUsefulEvent` 10650): "decorative" tools whose action/name is `suggestions|follow_ups|quick_actions|suggested_prompts…` (10630–10637) and status lines that are pure boilerplate such as `Firas Agent is running`, `يعمل`, `اكتمل`, `تم الانتهاء` (10639–10648).

### 6.3 `surface.tools[]` (10775–10781)

`{ name:≤60, arg:≤220, toolKind:"browser"|"tool"|"", action:≤100, url:≤600 }` — the "tool strip". Same decorative filter.

### 6.4 `surface.says[]`

Strings ≤900 chars: the agent's own assistant messages/explanations in order (8706–8713, 8795–8800). On `phase:"done"` a line identical to `final` is removed (10786). Boilerplate lines removed.

### 6.5 `surface.files[]` (10744–10748)

`{ name:≤120, type:≤120 (MIME as reported upstream, may be ""), url:"/api/agent/artifact?id=<jobKey>&index=<i>" }`. Only files whose upstream URL is `https://` get an entry (10738–10741); the `index` is the position in the **internal** file list, so indices can have gaps — always use the `url` as given, never recompute it.

### 6.6 `surface.live[]`

Strings ≤500: the raw narration log (status + message + tool lines) after filtering boilerplate and anything already represented by a hidden event (10788–10794). Use it for an "activity log" disclosure; `events` is the structured version of the same data.

### 6.7 `surface.startedAt / endedAt`

ms epoch. `endedAt` is `0` until `done`/`fail` (10706). Elapsed time = `now − startedAt`.

---

## 7. `GET /api/agent/job?id=<jobId>` — one snapshot

`handleAgentJobView` 12100–12139. Query param `id` is passed through `jobKey` (12104); missing → **400** `{"error":"bad_request"}`.

Response **200**:

```json
{ "job": <AgentJobView> }
```

or **200** `{"job":null}` when no record exists (expired after 6 h, or never created) — 12128.

`AgentJobView` (`agentJobViewPayload`, 12055–12076):

| field | type | source |
| --- | --- | --- |
| `id` | string | job id |
| `phase` | `"queued"` \| `"run"` \| `"done"` \| `"fail"` | live capture ⇒ always `"run"` (12114); else mapped from ctl (`completed|done`→`done`, `failed`→`fail`, `queued`→`queued`, anything else→`run`, 12122–12124) |
| `presentation` | `"task"` \| `"conversation"` | from the public surface, else `"task"` iff steps non-empty (12060–12061) |
| `title` | string | surface.title → ctl.title → `""` |
| `task` | string | surface.task → ctl.task → `""` |
| `lang` | `"ar"` \| `"en"` | surface → ctl → `"ar"` |
| `steps` | `AgentStep[]` | public surface steps; if no surface yet, parsed from `## ` headings in the text (never on the Manus path) → `[]` |
| `surface` | object \| `null` | §6 inner `surface` object (`startedAt … live`) — **not** the whole public surface; `null` before the first publish |
| `final` | string | `out.text` only when `phase === "done"`, else `""` (12072) |
| `error` | string | only when `phase === "fail"`: `surface.error` or `"task_failed"` (12073); `""` otherwise |
| `credits` | object \| `null` | `manusCreditView(user)` (§10.1) for members, `null` for guests (12106) |

Error responses: **401** no cookie; **403** `{"error":"forbidden"}` (someone else's job, 12084/12095/12125); **503** `{"error":"storage_unavailable"}` (12110/12127/12131 — also returned when the record is terminal but `out/{id}` cannot be read, 12133; treat as transient and retry).

Zombie handling (`agentJobLiveState`, 12078–12098): an in-memory capture that has no runner or whose stream ended is cross-checked against the durable record and evicted if the record is terminal — you may see one `run` snapshot followed by `done` even after the worker finished; always trust the latest.

Polling cadence used by the web client: 700 ms while visible, 5 s hidden (app.js 58900); stops on `phase ∈ {done, fail}` (`isTerminal`, app.js 58717–58719, also accepts `completed|failed|stopped|cancelled|canceled`). The native app should prefer §8 and poll only as a fallback.

---

## 8. `GET /api/agent/job-stream?id=<jobId>` — SSE

`handleAgentJobStream` 12183–12291. Same auth/ownership rules as §7, checked **before** headers are committed (12194–12197), so failures arrive as ordinary JSON with status 400/401/403/404/429/503 (`{"error":"bad_request"|"authentication required"|"forbidden"|"job_not_found"|"rate_limited"|"storage_unavailable"}`). Rate limit 90 connections/min per owner+IP (12189).

Headers (12199–12206): `Content-Type: text/event-stream; charset=utf-8`, `Cache-Control: no-store, no-cache, must-revalidate, no-transform`, `Connection: keep-alive`, `Content-Encoding: identity`, `X-Accel-Buffering: no`, `X-Content-Type-Options: nosniff`. First bytes: `retry: 3000\n\n` (12212).

Frames (`agentJobStreamWrite`, 12175–12181): `id: <n>\nevent: <name>\ndata: <json>\n\n`. Keepalive comment `: keepalive\n\n` every 15 s (12284–12286).

Event types:

1. `snapshot` — `data` = `{"job": <AgentJobView>}` exactly as §7. Sent immediately on connect (12277), then whenever the snapshot's SHA-256 changes (12230–12239); wake-ups come from `agentJobStreamNotify` on every progress publish/ctl patch, coalesced to one read per 80 ms (12266–12272), plus a 1 250 ms fallback timer (12283). `id` is a monotonic sequence number per connection.
2. `terminal` — `data` = `{"id":"<jobId>","phase":"done"|"fail"}`, `id` = `<seq>.terminal` (12240). The server closes the connection right after. Sent only when the durable record is terminal (`snapshot.terminal`), never for a live capture — so a `snapshot` with `phase:"done"` is always followed by a `terminal` frame.
3. `agent-error` — `data` = `{"error":"<code>","retryable":true|false}` (no `id`), then the connection closes (12253, 12259). `retryable` is `status >= 500`; a `{"error":"stream_unavailable","retryable":true}` means an exception while reading.

Literal example of a full session:

```
retry: 3000

id: 1
event: snapshot
data: {"job":{"id":"3f9a1c2b4d-j1a2b3c4d5e6","phase":"queued","presentation":"conversation","title":"خطة مذاكرة للفيزياء","task":"سوّي لي خطة مذاكرة…","lang":"ar","steps":[],"surface":null,"final":"","error":"","credits":{"remaining":500,"allowance":500,"used":0,"held":0,"resetAt":"2026-09-02T21:00:00.000Z","period":"daily","configured":true}}}

id: 2
event: snapshot
data: {"job":{"id":"3f9a1c2b4d-j1a2b3c4d5e6","phase":"run","presentation":"task","title":"خطة مذاكرة للفيزياء","task":"…","lang":"ar","steps":[{"title":"تحليل المنهج","s":"run","kind":"write","out":""},{"title":"توزيع الأسابيع","s":"todo","kind":"write","out":""}],"surface":{"startedAt":1756800000000,"endedAt":0,"events":[{"id":"msg_1","kind":"tool","text":"⚙️ Firas Browser: search · منهج الفيزياء السادس العلمي","name":"Firas Browser","arg":"search · منهج الفيزياء السادس العلمي","toolKind":"browser","action":"search","status":"","url":"","step":0,"at":1756800012000}],"tools":[{"name":"Firas Browser","arg":"search · منهج الفيزياء السادس العلمي","toolKind":"browser","action":"search","url":""}],"says":[],"files":[],"live":["⚙️ Firas Browser: search · منهج الفيزياء السادس العلمي"]},"final":"","error":"","credits":{"remaining":0,"allowance":500,"used":0,"held":500,"resetAt":"2026-09-02T21:00:00.000Z","period":"daily","configured":true}}}

: keepalive

id: 9
event: snapshot
data: {"job":{"id":"3f9a1c2b4d-j1a2b3c4d5e6","phase":"done","presentation":"task","title":"…","task":"…","lang":"ar","steps":[{"title":"تحليل المنهج","s":"done","kind":"write","out":""},{"title":"توزيع الأسابيع","s":"done","kind":"write","out":""}],"surface":{"startedAt":1756800000000,"endedAt":1756800240000,"events":[…],"tools":[…],"says":[…],"files":[{"name":"study-plan.pdf","type":"application/pdf","url":"/api/agent/artifact?id=3f9a1c2b4d-j1a2b3c4d5e6&index=0"}],"live":[…]},"final":"# خطة المذاكرة\n\n…\n\n**الملفات:**\n- [study-plan.pdf](/api/agent/artifact?id=3f9a1c2b4d-j1a2b3c4d5e6&index=0)","error":"","credits":{"remaining":463,"allowance":500,"used":37,"held":0,"resetAt":"2026-09-02T21:00:00.000Z","period":"daily","configured":true}}}

id: 9.terminal
event: terminal
data: {"id":"3f9a1c2b4d-j1a2b3c4d5e6","phase":"done"}
```

Client behaviour to copy from `agWatchServerRun` (app.js 58690–58990): on `onerror` fall back to polling §7 immediately and reconnect with exponential backoff 1 s → 15 s; on app foreground/`online` do one authoritative poll and rebuild the stream; treat `phase ∈ {done, fail}` as terminal (app.js 58717–58719 also accept `completed|failed|stopped|cancelled`); give up after `AG_JOB_MAX_MS = 3 h` since the pointer's start (app.js 58552, 58984). `URLSession` with `URLSessionDataDelegate` streaming is sufficient — the server never uses `Last-Event-ID`.

---

## 9. Generic status and cancel

### 9.1 `GET /api/chat/job?id=`

`handleChatJobStatus` 12658–12712 returns `{phase:"processing"|"queued"|"completed"|"failed"|"unknown", text, reasoning, error, status, surface, progress:null}` (`progress` is `null` for every non-longfile job, `longFileProgressView` 10313–10317). For agentrun `surface` is the **internal** surface object with upstream URLs replaced? — **No**: it returns `live._agentSurface` / `out.surface` raw (12685, 12712), i.e. the internal object whose `surface.files[].url` are upstream Manus URLs. While the record is `queued` (including the `reconciling` re-queue) it does not read `out/` at all, so `surface` is `null` and `text` is `""` (12708). Prefer §7/§8, which sanitise and keep the surface across the re-queue. If you must use this route, ignore `surface.files` and re-derive from `/api/agent/job`. `error` here is `ctl.error` — the JSON string `{"error":"agent_busy"}` for worker refusals (11917). No cookie → 401; not the owner → 403 `{"error":"forbidden"}`; unknown id → 200 `{"phase":"unknown"}`.

### 9.2 `POST /api/chat/cancel` — not a stop for missions

`handleChatCancel` 12478–12529. Body `{"id":"<jobId>"}` (≤4 000 chars; id filtered to `[A-Za-z0-9_-]`, ≤64 — note the job id is at most 10+1+64 chars so it fits).

- Job in memory (claimed by this process): sets `cr._cancelled = true`, returns **200** `{"ok":true,"stopped":true}` (12489–12496). **`agentTwinManus` never reads `_cancelled`** (only `streamStopped` 2762 for chat captures and the longfile path do). The Manus task keeps running, the job completes normally, the answer is still written to chat; the only effect is that the completion **push notification is suppressed** (11903).
- Job not in memory: only `longfile` jobs can be cancelled while queued; anything else → **409** `{"error":"job_not_running"}` (12507–12509); unknown id → **404** `{"error":"unknown_job"}`; other owner → **403** `{"error":"not_yours"}`.

The web client accordingly never offers "Stop" for a server mission; the native app should not either (or label it honestly as "stop watching").

### 9.3 Steering

There is **no server-side steering**. `agentSteerQueue/Take` (app.js 51733–51753) only feed the in-tab pipeline; for a server mission the web card shows `agentSteerBg` = `"هذه المهمة تعمل على الخادم — لا يمكن توجيهها من هنا."` / `"This mission is running on the server — it can't be steered from here."` (app.js 967 / 2050, used at 53419). The native app has nothing to implement here. Nothing in `server.mjs` matches `steer` in an agent context (grep confirmed: only two prose comments at 5873 and 6235).

---

## 10. Credits and the Manus ledger

### 10.1 `manusCreditView(user)` (8621–8629) — the `credits` object

```json
{
  "remaining": 463,
  "allowance": 500,
  "used": 37,
  "held": 0,
  "resetAt": "2026-09-02T21:00:00.000Z",
  "period": "daily",
  "configured": true
}
```

- `allowance` = `MANUS_USER_CREDITS` (env, default **500**, 8509).
- `remaining = max(0, allowance − used − held)` (8598–8601).
- `held` = sum of unexpired reservations (`manusLedger`, 8571–8597). A running mission holds `min(600, remaining)` — with the default allowance that is **everything**, so `remaining` reads **0 while a mission runs** (see the example in §8). Show "held" as "reserved for the running task", not as "spent".
- `used` = settled spend today. Ledger day rolls at Baghdad-local midnight (`serverDay`, 3197; `QUOTA_TZ_OFFSET_MINUTES` default 180, 3196); `resetAt` is the next local midnight as ISO-8601 UTC (`manusResetAt`, 8614–8620). A reservation survives the day roll (8583–8586).
- `configured` = whether `MANUS_API_KEY` is set; `false` means every mission will fail with `agent_unavailable` — disable the composer.

### 10.2 `GET /api/agent/credits` (8960–8972)

- Member → **200** `manusCreditView(user)`.
- Guest → **200** `{"remaining":0,"allowance":500,"used":0,"held":0,"resetAt":"…","period":"daily","configured":true|false,"guest":true,"locked":true}`.
- No cookie → **401**.

The web client refreshes this on the account row (`app.js 16312`). `credits` also rides on every `/api/agent/job` snapshot and on 409/429 bodies from `/api/chat/job`, so a dedicated fetch is only needed for the idle state.

### 10.3 Legacy in-memory Manus route (dead)

`handleManusStart` (8877), `handleManusPoll` (8932) and `manusRunJob` (8817) are still defined but unreachable — the router returns **410** before them (13758–13760). Their response shapes (`{ok, jobId, title, credit, remaining}` / `{phase, answer, files, live, startedAt, plan, tools, says, events, credits, error, credit, remaining}`) must **not** be implemented. `manusTryRun` in app.js 57176 is the equally dead client half.

### 10.4 Push notification on completion (`notifyDurableJobTerminal` 1627, `apnsPayload` 1562)

Sent to every registered device of the owner when the job reaches `completed` or `failed` (not when cancelled-suppressed). Payload:

```json
{
  "aps": { "alert": { "title": "مهمة وكيل فِراس اكتملت", "body": "اضغط لعرض النتيجة." },
           "sound": "FirasComplete.wav", "category": "FIRAS_JOB_COMPLETE",
           "thread-id": "firas-agent-<chatId or jobId>" },
  "firas": { "type": "job-terminal", "product": "agent", "jobId": "<jobId>", "phase": "completed"|"failed", "chatId": "<chatId, only if set>" }
}
```

Copy (`apnsLocalizedCopy` 1521–1561; Arabic only when the registered device's `language === "ar"`, everything else gets English): Arabic name `مهمة وكيل فِراس`; completed → title `مهمة وكيل فِراس اكتملت`, body `اضغط لعرض النتيجة.`; failed → title `مهمة وكيل فِراس لم تكتمل`, body `اضغط لعرض التفاصيل أو المحاولة مجدداً.`. English: `Firas Agent mission is ready` / `Tap to view the result.`; `Firas Agent mission could not finish` / `Tap to view details or try again.`. `thread-id` is truncated to 64 chars (1575). `apns-collapse-id` = job id filtered to `[A-Za-z0-9_-]` ≤ 64 (1635), `apns-priority: 10`, `apns-push-type: alert`. Product is derived by `durableNotificationProduct` (1515): `kind === "agentrun" || product === "agent"`. Not sent for guests, when APNs is unconfigured, or when the owner has no registered devices (1627–1634).

---

## 11. Rendering the mission natively

### 11.1 Phase → card state

Combine `phase` and `error` exactly as `bgJobToRun` does (app.js 58437–58482). Two rules from that function to copy first:

- **Placeholder plan**: if the surface has no work yet (`events`, `tools`, `says`, `files`, `live` all empty) and the only step is titled exactly `Starting the task and preparing the plan` or `بدء المهمة وتجهيز الخطة`, hide the checklist (58452). That row is Manus's boot plan, not a real step.
- **Blocked vs credits**: `held = credits.held`; `blocked` when `error ∈ {agent_busy, credits_reserved}` or (`credits_exhausted` and `held > 0`); `credits` when `credits_exhausted` and `held == 0`. Both clear the steps (58456–58458).

| snapshot | card state | header label (app.js `AGENT_PHASE_LABEL` 51687–51700) |
| --- | --- | --- |
| `phase:"queued"` | running (spinner, no steps yet) | `ينفّذ…` / `Executing…` (web maps queued→run) |
| `phase:"run"`, `presentation:"conversation"`, no surface work | running | `يخطّط…` / `Planning…` is the web's `plan` label; either is acceptable |
| `phase:"run"`, `presentation:"task"` | running with checklist | `ينفّذ…` / `Executing…` |
| `phase:"done"` | done; render `final` as Markdown (+ file chips) | `اكتملت المهمة` / `Task complete` |
| `phase:"fail"`, `error ∈ {agent_busy, credits_reserved}` or (`credits_exhausted` and `credits.held > 0`) | **blocked** (no steps, no resume) | `مهمة أخرى قيد التنفيذ` / `Another task is running` |
| `phase:"fail"`, `error:"credits_exhausted"` (held = 0) | **credits** | `استُهلك رصيد اليوم` / `Daily credits used` |
| `phase:"fail"`, other | failed (offer "try again" = new cid) | `تعثّرت` / `Failed` |

Additional web-only labels you may reuse: `يقرأ المرفقات…` / `Reading attachments…` (while you pre-process attachments locally), `أُوقفت` / `Stopped`.

### 11.2 Failure copy (verbatim, app.js 58459–58471 and 59436–59466)

| error | Arabic | English |
| --- | --- | --- |
| `agent_busy`, or `credits_exhausted` with `held > 0` | `توجد مهمة أخرى قيد التنفيذ، ورصيدها محجوز مؤقتًا. افتح المهمة الجارية لمتابعتها.` | `Another task is still running and its credits are temporarily reserved. Open it to follow the work.` |
| `credits_exhausted` | `استُهلك رصيد اليوم. يتجدّد تلقائيًا في الموعد الموضّح أعلاه.` | `Today's credits have been used. They refresh automatically at the time shown above.` |
| `credits_reserved` | `الرصيد محجوز مؤقتًا لمهمة سابقة، لذلك لم تُنشأ مهمة مكررة.` | `Credits are temporarily reserved for an earlier task, so no duplicate task was created.` |
| `account_required` / `signin_required` (app.js 59373–59374) | `سجّل الدخول أو أنشئ حسابًا مجانيًا لبدء هذه المهمة. طلبك ما زال محفوظًا.` | `Sign in or create a free account to start this task. Your request is still saved.` |
| any other failure (default, 58459–58461) | `تعذّر إكمال المهمة. لم تُحوَّل إلى أداة أخرى؛ أعد المحاولة.` | `The task could not be completed right now. It was not switched to another tool; you can retry.` |
| toast on 409 when the running chat is known (app.js 59446) | `فُتحت المهمة الجارية.` | `Opening your running task.` |
| toast on 409 when it is not (app.js 59449) | `توجد مهمة قيد التنفيذ. حدّث قائمة المحادثات لعرضها.` | `Another task is running. Refresh the conversation list to find it.` |

On **409** navigate to `activeJob.chatId` (server chat id) when present and attach to `activeJob.jobId`.

### 11.3 Progress recipe

- **Checklist**: `steps[]` → rows with `s` (`todo` grey, `run` animated, `done` tick, `fail` cross). Titles are already in the user's language (Manus plan titles, `firasSurfaceText`-scrubbed, 10662–10668).
- **Now doing**: the last `events[]` entry with `kind:"tool"` (name + arg; `toolKind:"browser"` gets a globe glyph and `url` becomes a tappable link) or the last `says[]` line.
- **Agent voice**: `says[]` as quoted bubbles under the checklist.
- **Activity log** (collapsed): `live[]` in order.
- **Files**: `files[]` chips → `GET` the `url` with the session cookie (§12.4). Also parse Markdown links in `final` that start with `/api/agent/artifact?` — the same files.
- **Elapsed**: `now − surface.startedAt`.
- **Credits row**: `credits.remaining / credits.allowance`, "reserved" = `credits.held`, reset at `credits.resetAt`.
- Diff snapshots by `events[].id` to animate only new rows; the server already de-duplicates events by id (8683–8685).

### 11.4 Chat history

A completed mission appears in `GET /api/chats/<id>` messages as `{role:"assistant", cid:"<cid>", content:"```firas-agent\n<json>\n```", reasoning:"", tier, lang}` (`saveAssistantTurn` 2513–2536 → `sanitizeMessages` 2431–2456, which keeps `role, content, tier, lang, cid` plus optional `files, askAnswered, retryOf, retried, mode`). The JSON is exactly `agentPublicSurface` (§6.1 incl. `v`, `mode`, `steps`, `final`, `surface`). Parse rule from `parseAgentMeta` (app.js 51576–51599): strip the fence, `JSON.parse`, require `steps` to be an array; if the fence was truncated by the 1 000 000-char content cap (`MAX_CONTENT` 2429 — far larger than any surface), brace-match the first object. For `presentation:"conversation"` the content is **plain Markdown**, not a fence (11076). A failed mission (worker refusal, §5.2) is also written as a fence with `phase:"fail"` and `error` set (11106, 11914–11916), so history can carry a blocked/credits card.

Web-authored blocks (in-tab missions, `serializeAgentRun` app.js 51599–51684) carry extra fields (`stats`, `qaOpen`, `done`, `bg`, `jobId`, `activeChatId`, `steps[].file/fix/produces/table`, `steps[].out` ≤ 15 000 chars) and thirty step kinds. Per `.claude/skills/agent-step-kinds/SKILL.md`, twenty-one of those kinds are **shaped**: their `out` is a ```` ```firas-<kind> ```` fence containing JSON, not Markdown — `timeline, checklist, compare, cards, outline, translate, steps, glossary, formula, risks, budget, quiz, map, sources, translate_pair, checklist_review, decision, proof, dataset, critique, schedule`. (`table` keeps its rows in `steps[].table = {cols, rows}` instead.) The native renderer should: render `out` as Markdown for `write`/`research`/`solve`/`code` and any unknown kind; for a shaped kind, detect the fence and either draw a card or fall back to a plain code block — never show raw JSON as prose. Never try to *resume* such a run natively — the web's Resume button restarts an in-tab pipeline that does not exist on the server (app.js 59518–59522 resumes by starting a **new** durable mission via `runAgentAssistant`). `.claude/skills/agent-planning-prompts/SKILL.md` was read and concerns how to write engineering plans for this repo; it has no bearing on the wire contract.

---

## 12. Copy-paste recipe for the native client

### 12.1 Start

```
cid = 12–24 chars from [A-Za-z0-9_-], persisted with the draft before any request

POST /api/usage/charge            {"product":"agent","cid":cid}
  403 signin_required → sign-in sheet, stop
  429 → "credits" card with quota text, stop
  other non-2xx → proceed anyway (web client fails open, app.js 46878)

POST /api/chat/job
{
  "kind": "agentrun", "product": "agent",
  "task": task, "title": firstLineOf(task) ≤ 160,
  "messages": [ { "role": "user", "content": task } ],
  "cid": cid, "chatId": serverChatId, "lang": "ar"|"en", "tier": "pro"
}
  200 {ok:true, jobId, phase:"queued"}         → persist {chatId, jobId, cid, startedAt}, watch
  200 {ok:true, jobId, phase:"queued"|"processing"} (replay) → watch
  200 {ok:true, phase:"completed", text, surface} → render done directly
  200 {ok:false, phase:"failed", retryRequiresNewCid:true} → failed card; next attempt = new cid
  409 agent_busy                               → blocked card, open activeJob.chatId, watch activeJob.jobId
  429 credits_reserved                         → blocked card
  403 account_required                         → sign-in sheet
  413 / 400 / 503                              → error toast (503 retry later)
```

### 12.2 Watch

Open `GET /api/agent/job-stream?id=<jobId>`; on every `snapshot` replace the model; on `terminal` or `agent-error` close; on transport error poll `GET /api/agent/job?id=` every 0.7 s (foreground) / 5 s (background) and retry the stream with backoff. Stop when `job.phase ∈ {done, fail}` or `job == null` (expired) or HTTP 403/404. Persist the pointer under the chat so a relaunch reattaches; forget it on terminal or after 3 h.

### 12.3 Refresh credits

Read `credits` off the snapshot; call `GET /api/agent/credits` only when no mission is being watched.

### 12.4 Download a file

`GET /api/agent/artifact?id=<jobId>&index=<n>[&download=1]` with the session cookie (`handleAgentArtifact` 12419–12476):

- Query keys other than `id`, `index`, `download` → **400** (12425–12427). `id` must match `^[A-Za-z0-9_-]{1,96}$`, `index` must be `^\d{1,3}$`.
- Rate limit 30/min per owner → **429** `{"error":"rate_limited"}` (12433).
- **404** `{"error":"artifact_not_found"}` when the job or the file index does not exist; **403** `{"error":"forbidden"}` when not the owner; **503** storage; **502** `{"error":"artifact_unavailable"}` when the upstream fetch fails (timeout 30 s, max 32 MiB, 12052–12053, https only, private IPs blocked, ≤ 3 redirects).
- Success **200** with `Content-Type` (upstream MIME, or by extension; HTML/JS/SVG are downgraded to `application/octet-stream`, 12307–12321), `Content-Length`, `Content-Disposition: inline|attachment; filename="firas-artifact-<n+1>.<ext>"; filename*=UTF-8''<percent-encoded original name>` (12300–12305 — note the fallback filename is 1-based while `index` is 0-based; `attachment` when `download=1` or the type is not in the inline allow-list at 12462: `application/pdf`, `image/(png|jpeg|gif|webp|avif|bmp|tiff|x-icon)`, `audio/(mpeg|wav|ogg|mp4)`, `video/(mp4|webm|ogg)`, `text/(plain|markdown|csv)`, `application/json`), `Cache-Control: private, no-store`, `X-Content-Type-Options: nosniff`, a sandboxing CSP, `Cross-Origin-Resource-Policy: same-origin`, `Referrer-Policy: no-referrer`, `Accept-Ranges: none`. The body is the file bytes (buffered server-side, no range support — do not send `Range` headers; use a plain `URLSession` data task, not a background download with resume).

---

## 13. Constants

| name | value | line |
| --- | --- | --- |
| `MANUS_USER_CREDITS` | 500 (env) | 8509 |
| `MANUS_MAX_TASK` | 600 (env) — hold ceiling | 8512 |
| `MANUS_POLL_MS` | 1 500 ms | 8517 |
| `MANUS_MAX_MS` | 1 800 000 ms (30 min) before the job is parked as `reconciling` | 8518 |
| `MANUS_HTTP_MS` | 45 000 ms per upstream call | 8531 |
| `MANUS_PROFILE` | `manus-1.6` | 8504 |
| `AGENTRUN_MAX_STEPS` | 40 (unused on this path) | 10594 |
| `JOB_PAYLOAD_MAX` | 600 000 chars | 9330 |
| `JOB_KEEP_MS` | 6 h | 9329 |
| `JOB_MAX_ATTEMPTS` | 3 | 9323 |
| `JOB_STALE_MS` | 120 s | 9324 |
| `JOB_CONCURRENCY` | 4 | 9328 |
| `AGENT_ARTIFACT_MAX_BYTES` | 32 MiB | 12052 |
| `AGENT_ARTIFACT_TIMEOUT_MS` | 30 s | 12053 |
| reservation `expiresAt` | 24 h | 10863 |
| ctl `task` cap / surface `task` cap | 8 000 / 4 000 chars | 12631 / 10698 |
| `final` cap | 100 000 chars | 10678 |
| SSE keepalive / fallback tick / coalesce | 15 s / 1 250 ms / 80 ms | 12284 / 12283 / 12272 |

---

## 14. Gotchas the port must handle

1. **Cancel is cosmetic.** `/api/chat/cancel` does not stop a Manus mission (§9.2). Do not promise "Stop".
2. **`remaining` is 0 during a run** because the hold equals the whole daily allowance; show `held` as reserved, not spent (§10.1).
3. **Two 409 shapes.** At start (`409` body with `activeJob`) and in-flight (`phase:"fail", error:"agent_busy"` on the snapshot with no `activeJob`). Both are "blocked".
4. **`error` on a failed snapshot is a bare code; on `/api/chat/job` it is the JSON string `{"error":"code"}`.** Parse accordingly if you ever use the generic route.
5. **Missions can outlive 30 min** — after `agentDeadlineAt` the job flips between `processing` and `queued` (`agentState:"reconciling"`) every ~60 s until Manus finishes; the snapshot `phase` may read `queued` mid-mission. Keep the checklist visible.
6. **`credits` is `null` for guests** and `surface` is `null` before the first publish; `final` is empty until `done`.
7. **The 6-hour retention.** After that `GET /api/agent/job` → `{"job":null}` and the stream → 404; rely on the chat message for history.
8. **`steps[].out` is always empty on the server path**; `kind` is always `"write"`. The web's rich step cards do not apply.
9. **Artifact URLs are relative and cookie-authenticated**; never hand them to a share sheet without downloading first, and never re-derive `index` from the array position.
10. **Idempotency needs a stable `cid`**; a retry with a new cid after a lost response starts (and bills) a second mission.
11. **`chatId` must be the server id**; otherwise the answer is only reachable via the job for 6 h.
12. **Existing Swift code** (Codex-written, verify before trusting):
    - `ios/FirasAI/Models/AgentModels.swift` matches §7's field names exactly (`AgentJob`, `AgentActivity`, `AgentCredits`, `AgentEvent`, `AgentTool`, `AgentFile`, `AgentJobEnvelope{job?}`) and maps `completed|failed|processing|exec` synonyms in `AgentJobPhase`.
    - `ios/FirasAI/Networking/FirasAPI.swift`: `startChatJob` 260, `chatJobStatus` 269, `cancelChatJob` 279, `agentJobStatus(id:)` 289 (returns `envelope.job`, i.e. `nil` on `{"job":null}`), `agentArtifact(jobID:index:download:)` 300, `chargeUsage(product:cid:)` 315. `ChatJobRequest` (`ios/FirasAI/Models/ChatModels.swift` 251) encodes `messages, tier, think, cid, product, chatId, kind, lang, task, title, …`; `ChatJobKind.agentRun = "agentrun"` (216–220).
    - `AgentStore.enqueueAndPoll` (`ios/FirasAI/Stores/AgentStore.swift` 199–269) charges then posts `ChatJobRequest(… product: .agent, kind: .agentRun, languageCode, task, title)` — consistent with §4 **except that it never passes `chatId`** (defaults to `""`), so on the current iOS build a finished mission is never filed into any chat and is lost after the 6-hour retention (§4.1 `chatId` row). The port must pass the server chat id. `poll` (271+) polls `GET /api/agent/job` only; §8 SSE is not yet used. `AgentStore.finalText` (82–97) tries to unwrap a ```` ```firas-agent ```` fence from `job.final`, which the server never puts there (`final` is plain text; the fence only goes to chat history) — harmless but unnecessary.
13. **Skills read for this slice**: `.claude/skills/agent-step-kinds/SKILL.md` (client step vocabulary, §11.4) and `.claude/skills/agent-planning-prompts/SKILL.md` (repo planning discipline, not product behaviour). Neither changes anything in §3–§10.
