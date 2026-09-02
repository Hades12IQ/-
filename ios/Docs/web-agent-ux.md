# Firas Agent — mission screen, web behaviour and native spec

Slice: the Firas Agent UI in `app.js` (send path, durable hand-off, live mission card, credits,
sidebar indicators) and every server route it touches in `server.mjs`. Line numbers cite the
worktree at `D:\Programming\Projects\FirasAI\.claude\worktrees\firasai-ios-app-development-64ca7e`
(`app.js` ≈ 90k lines, `server.mjs` ≈ 13.9k lines). Arabic strings are verbatim.

---

## 0. Read this first — what is live and what is dead

The task brief named `runAgentTask`, `manusTryRun`, the in-tab pipeline, steering, `bgJob*`
and `AGENT_AUTORESUMED`. Most of that is **dead code in the current build**. Do not port it.

| Thing | Status | Evidence |
| --- | --- | --- |
| `runAgentAssistant` → `agentServerRun` (durable `/api/chat/job` kind `agentrun`) | **LIVE — the only mission path** | `app.js:59753-59763`: `agentServerRun` is awaited; on `true` the stream entry is released and the function `return`s. On `false` a "task_unavailable" card is written and the function `return`s at `app.js:59785`. |
| `runAgentTask` (30-kind in-tab planner/executor), `AGENT_STEER_LIVE.add` | **DEAD** — only caller is `app.js:59792`, which sits after the unconditional `return` at `59785`. | `app.js:59787-59792` |
| `manusTryRun` (`POST /api/agent/start`, `GET /api/agent/poll`) | **DEAD** — called only from `runAgentTask` (`app.js:57326`), and the server answers both routes with **410** `{ "error": "durable_agent_route_required" }` (`server.mjs:13758-13760`). | |
| Steer row (`agent-steer`, `agentSteerQueue/Take`, `AGENT_CORRECTIONS`) | **DEAD / never shown** — `steerShow` requires `!run.bg && AGENT_STEER_LIVE.has(chat.id)` (`app.js:53385-53386`); every current run is `bg: true` and nothing reachable adds to `AGENT_STEER_LIVE`. There is **no server API for steering**. A correction was a client-only prompt fold into the next in-tab step (`app.js:51707-51758`). | |
| `bgJobStart` → `POST /api/agent/job`, `LS_BG_JOBS` (`firas_ai_bg_jobs`), `bgJobWatch` 6 s poll, `bgJobsReattach` | **DEAD** — `server.mjs` has no `POST /api/agent/job` route (only `GET`, `server.mjs:13752`), so `bgJobStart` throws and returns `null`. Nothing writes `LS_BG_JOBS` any more; `bgJobsReattachNow` (`app.js:80003`) sweeps an always-empty table. | |
| `AGENT_AUTORESUMED` / auto-resume | **Effectively dead** — guarded by `!steerBg` (`app.js:53504`), i.e. only for legacy in-tab runs persisted before the durable path. | |
| Resume button | **LIVE but semantically "start a new mission"** — see §7.4. | |
| `bgJobToRun`, `agWatchServerRun`, `agJobsReattach`, `LS_AGENT_JOBS` (`firas_ai_agent_jobs`), `firas_job_<chatId>` | **LIVE** | `app.js:58437`, `58690`, `58990`, `58551` |
| Firas Computer panel (`fcPanelEnsure/fcPanelPatch`) | **LIVE** — this IS the mission card body. | `app.js:56322`, `56957` |
| Mission-watch corner panel (`missionWatch*`) | LIVE on desktop only; disabled ≤640 px, on UI 2.0, for guests and on the share page (`app.js:51833-51840`). Not needed natively. | |
| Credits chip + dialog (`acRow*`, `/api/agent/credits`) | **LIVE** | `app.js:16171-16384` |
| APNs push on terminal (`notifyDurableJobTerminal`) | **LIVE** on the server; the iOS app is the intended consumer. | `server.mjs:1627`, `1562` |

The server runs every mission on the owner's Manus subscription (`agentTwinManus`,
`server.mjs:10820`). The server-side planner with three kinds (`agentPlanSteps`,
`server.mjs:10600`) exists but is **not called** by `runAgentJob` (`server.mjs:11089-11112`):
a Manus failure becomes a failed job, it never falls back to a local pipeline.

**Legacy strings — recorded so nobody hunts for them, but NOT to be shipped natively** (they belong to
the dead in-tab path above):

- Steer row (`STR.agentSteer*`, `app.js:963-969`, `2046-2052`): `agentSteerPh` ar `صحّح مسار المهمة… تُطبَّق على الخطوة التالية` / en `Correct the mission… applies to the next step` · `agentSteerSend` ar `وجّه` / en `Steer` · `agentSteerQueued` ar `سيُطبَّق على الخطوة التالية:` / en `Will be applied to the next step:` · `agentSteerLate` ar `بدأت كل الخطوات — لم يعد بالإمكان توجيه هذه المهمة.` / en `Every step has already started — this mission can no longer be steered.` · `agentSteerBg` ar `هذه المهمة تعمل على الخادم — لا يمكن توجيهها من هنا.` / en `This mission is running on the server — it can't be steered from here.` · `agentSteerFull` ar `هناك توجيهات كافية في الانتظار — دعها تُطبَّق أولًا.` / en `Enough corrections are already waiting — let them land first.` · `agentSteerChipT` ar `توجيهك، طُبِّق على هذه الخطوة` / en `Your correction, applied to this step`. Queue: 4 corrections max, 600 chars each, consumed by the next in-tab step only (`agentSteerQueue/Take`, `app.js:51733-51757`). A server mission has no steering API at all; the honest native equivalent is "send a follow-up message after it finishes" (§7.4, §16).
- In-tab research loop tool rows (`run._loop`, `app.js:55675-55745`): tool `search` → ar `يبحث` / en `searching`; `fetch` → ar `يقرأ صفحة` / en `reading`; `python` → ar `يحسب` / en `computing`; `done` ends the loop. Empty results: ar `لا نتائج.` / en `No results.`; ar `الصفحة فارغة أو تعذّر فتحها.` / en `Empty or unreachable.` These rows never appear on a server-run card — the live activity feed is §8's `surface.events`.
- The ` ```firas-ask ` clarification card that `runAgentAssistant` still folds answers into (§2.2.1) is produced only by the dead in-tab planner; `server.mjs` never emits `firas-ask` (grep: zero hits), so a server mission never asks a question mid-run — it makes an assumption and continues (`MANUS_IDENTITY`, `server.mjs:8522-8529`).

---

## 1. Identity, auth and preconditions

- Member cookie: `firas_session` (`server.mjs:1046`). Guest cookie: `firas_guest` (`server.mjs:1131`).
  `callerOf(req)` → `{user, id, isGuest:false}` or `{id, isGuest:true}` or `{}` (`server.mjs:1314-1320`).
- **Agent missions are members-only.** Every gate refuses guests:
  - Client, before anything is pushed: `if (state.product === "agent" && isGuest()) { agentAccountRequiredPrompt(); return; }` (`app.js:44430-44433`). The draft and attachments stay in the composer.
  - `POST /api/usage/charge` with `product:"agent"` for a guest → **403** `{ ok:false, error:"signin_required", feature:"agent" }` (`server.mjs:7664-7666`).
  - `POST /api/chat/job` for a guest with `kind:"agentrun"` or `product:"agent"` → **403** `{ ok:false, error:"account_required", feature:"agent" }` (`server.mjs:12554-12556`).
  - Worker: `agentTwinManus` → `{ ok:false, error:"account_required" }` (`server.mjs:10822-10824`).
- Guest sign-up prompt (`openSignUpPrompt("agent")`, `app.js:47087-47120`), shown only if no `.guest-ov` is already open (`app.js:59392-59397`):
  - `guestFeatureTitle` ar `هذه الميزة تحتاج حسابًا` / en `This feature needs an account` (`app.js:697`, `1794`)
  - `guestFeatureBody` ar `أنشئ حسابًا مجانيًا لتفعيلها — يستغرق أقل من دقيقة.` / en `Create a free account to unlock it — it takes less than a minute.` (`698`, `1795`)
  - `guestUpgradeCta` ar `إنشاء حساب مجاني` / en `Create a free account` (`699`, `1796`)
  - `guestLater` ar `لاحقًا` / en `Later` (`715`, `1808`)
- An Agent conversation is an ordinary chat with `agent: true` (`app.js:13307`; `/api/chats` list rows carry `agent: !!c.agent`, `server.mjs:2545`). Its title is derived by `agentTitleFrom(firstUserText)` (`app.js:13366`: strips leading politeness/command verbs such as `ابحث`, `اكتب`, `سوّي`, `please`, `search`).
- Product constants: `PRODUCTS.agent = { name: "Firas Agent", tag: { ar: "وكيل ينفّذ المهام الكبيرة", en: "Executes big tasks" } }` (`app.js:59942`). Rail label ar `الوكيل` / en `Agent` (`app.js:19526-19527`). Composer placeholder in the Agent product ar `كلّف فِراس بمهمة صعبة` / en `Give Firas a hard task`; aria-label ar `مراسلة Firas Agent` / en `Message Firas Agent` (`app.js:59961-59964`). Attach button hint `agentAttachHint` ar `إرفاق ملفات وصور إلى المهمة` / en `Attach files and images to the mission`; drop label `agentDropToAttach` ar `أفلت الملفات هنا — يقرأها فِراس ضمن المهمة` / en `Drop files here — Firas reads them into the mission` (`app.js:197-198`, `1319-1320`).
- The Agent always runs on tier `"max"` — no tier picker (`app.js:44576`). `TIERS.max` exists on the server (`server.mjs:430`).

---

## 2. Send → mission lifecycle (what the web client does, in order)

1. **Composer send** (`app.js:44420-44470`):
   1. Guest → sign-up prompt, return (§1).
   2. **One mission at a time (client pre-check)**: `agAnyLiveJob()` (`app.js:58591-58601`) scans `LS_AGENT_JOBS` for any pointer younger than `AG_JOB_MAX_MS` (3 h). If one exists:
      - same chat → toast ar `المهمة الحالية قيد التنفيذ هنا. بقي النص الجديد محفوظًا.` / en `Your current task is already running here. Your new draft stays saved.`
      - other chat found → toast ar `توجد مهمة قيد التنفيذ؛ فُتحت لمتابعتها. بقي النص الجديد محفوظًا هنا.` / en `You already have a task running; opening it now. Your new draft stays saved here.` then `openChat(thatChat)` (draft saved first).
      - pointer but chat not in list → toast ar `توجد مهمة قيد التنفيذ. حدّث قائمة المحادثات لعرضها؛ بقي النص الجديد محفوظًا.` / en `You have a task running. Refresh the conversation list to find it; your new draft stays saved.`
      In every case the send is cancelled and the draft stays (`app.js:44437-44452`).
   3. Chat is created server-side first if needed (`await persistChat(chat)`, `app.js:44563`) so `chat.serverId` exists before the job is posted.
2. **`runAgentAssistant(chat, "max", lang, null, follow)`** (`app.js:59524`):
   1. `task` = last user message content. If the previous assistant message was a ` ```firas-ask ` clarification card, the original request is prefixed: `orig + "\n\n[إجابات المستخدم على أسئلة التوضيح — راعِها بدقة]:\n" + answers` (`app.js:59531-59536`).
   2. **Pre-charge** `chargeUsage("agent", chat._missionCid)` (`app.js:59545-59567`, `46866-46880`). `_missionCid = uid()` unless re-entering the same mission (clarification round-trip or `_missionFailed`). Outcomes:
      - `{ok:true}` → continue.
      - `{ok:false, quota.plan === "guest"}` or guest → refusal card `agentAccountRequiredRun` + sign-up prompt.
      - `{ok:false, quota}` → refusal card `agentQuotaLimitRun` (phase `credits`, error `credits_exhausted`, text from `quotaLimitText`, §9).
      - Network error → **fails open** (`{ok:true}`).
      - 401/403 → `{ok:false}`; guest gets the prompt.
      Note: server `PLAN_LIMITS.*.agent = -1` (unlimited) for every plan (`server.mjs:1347-1357`), so a member always receives **200** `{ ok:true, sub }` today; the 429 path is unreachable but the client still handles it.
   3. Context: `agentUserMemory()` (`GET /api/memory`), prior user turns (≤2500 chars), previous run title/final. Then: `task += "\n\n=== سياق المحادثة السابقة / PRIOR CONVERSATION CONTEXT ===\n" + history(≤3000)` and `task += "\n\n=== آخر نتيجة سُلّمت / LAST DELIVERED RESULT ===\n" + prevFinal(≤12000)` (`app.js:59746-59747`).
   4. An empty assistant placeholder `aiMsg` is pushed and rendered; `activeStreams.set(chat.id, {controller, aiMsg})`, `beginStreaming` (`app.js:59589-59598`).
   5. **Attachments** (§11) are read and folded into `task` while the card shows phase `read` (`app.js:59610-59650`).
   6. `agentServerRun(chat, aiMsg, task, lang, "max")` (§3). If it returns `true` the stream entry is dropped (`activeStreams.delete`, `endStreaming`) — **the composer Stop button disappears immediately; the tab is only a viewer from here**. If `false` → the "unavailable" card (§9.7) is written and persisted.
3. **Watching**: `agWatchServerRun` (§5) drives the card via SSE with polling fallback until a terminal snapshot; then the chat is refreshed from the server, the pointer forgotten, and the sidebar repainted.

---

## 3. `agentServerRun` — creating the durable job (`app.js:59399-59515`)

Request: `POST /api/chat/job`, `credentials: same-origin`, JSON body:

```json
{
  "kind": "agentrun",
  "task": "<task text, sliced to 120000 chars>",
  "title": "<agentTitleFrom(task)>",
  "lang": "ar" | "en",
  "tier": "max",
  "cid": "<aiMsg.cid or uid()>",
  "product": "agent",
  "chatId": "<chat.serverId or \"\">",
  "messages": [{ "role": "user", "content": "<task, sliced to 120000>" }]
}
```

`cid` is the per-turn idempotency key: the server job id is `jobIdFor(ownerId, cid)` =
`sha1(ownerId).hex[0:10] + "-" + jobKey(cid)` where `jobKey` replaces `[.$#[\]/\s]` with `_` and
caps at 96 chars (`server.mjs:731-733`). The same `cid` re-posted returns the existing job (§4.2).

Client handling of the response (`app.js:59414-59478`):

| Response | Client behaviour |
| --- | --- |
| `!r.ok` and (`error` ∈ {`account_required`,`signin_required`} or status 401/403 while guest) | Writes `agentAccountRequiredRun` card, shows sign-up prompt, returns `true` (handled). |
| `409` `error:"agent_busy"` | Remembers `activeJob` (`agJobRemember(activeChatId||chat.id, jobId, cid, chatId)`, flat key, `agWatchServerRun`), `acRowSync(credits)`, writes a **blocked** card: `{ phase:"blocked", error:"agent_busy", activeChatId, steps:[], bg:true, final: ar "توجد مهمة أخرى قيد التنفيذ، ورصيدها محجوز مؤقتًا. افتح المهمة الجارية لمتابعتها." / en "Another task is still running and its credits are temporarily reserved. Open it to follow the work." }`. Toast: if the running chat is in the list → ar `فُتحت المهمة الجارية.` / en `Opening your running task.` and `openChat` after 350 ms; else ar `توجد مهمة قيد التنفيذ. حدّث قائمة المحادثات لعرضها.` / en `Another task is running. Refresh the conversation list to find it.` Returns `true`. |
| `429` `error:"credits_reserved"` or `"credits_exhausted"` | `held = credits.held`; `reserved = error==="credits_reserved" || held>0`. Card `{ phase: reserved ? "blocked" : "credits", error: reserved ? "credits_reserved" : error, activeChatId: activeJob.chatId, steps:[], bg:true, final }` where final = reserved ? ar `الرصيد محجوز مؤقتًا لمهمة سابقة، لذلك لم تُنشأ مهمة مكررة.` / en `Credits are temporarily reserved for an earlier task, so no duplicate task was created.` : ar `استُهلك رصيد اليوم. يتجدّد تلقائيًا في الموعد الموضّح أعلاه.` / en `Today's credits have been used. They refresh automatically at the time shown above.` The same text is shown as a toast. Returns `true`. |
| any other `!r.ok` (400, 413, 429 rate limit, 503) | Returns `false` → "unavailable" card (§9.7). |
| `ok` but no `jobId` | Returns `false`. |
| `ok` with `jobId` (phase `queued`, or an existing `completed`/`processing`/`failed` job) | Continues below. |

On success:
- `localStorage["firas_job_" + chat.id] = jobId` and also under `chat.serverId` (`app.js:59482-59485`).
- `aiMsg.cid = cid` (stamped on the message so a reattached watcher can find the turn; `serializeMessages` preserves it) (`app.js:59494`).
- `agJobRemember(chat.id, jobId, cid, chat.serverId)` (`app.js:59495`, table §6).
- Initial card persisted: `{ task(≤3000), title, phase:"run", presentation:"conversation", lang, mode:"answer", bg:true, jobId, steps:[], final:"", surface:{ startedAt: Date.now(), events:[], tools:[], says:[], files:[] } }` (`app.js:59496-59504`).
- `agWatchServerRun(chat.id, jobId, cid, chat.serverId)`.

---

## 4. Server API reference

### 4.1 `POST /api/usage/charge` (`server.mjs:7654-7681`)

Body (≤2000 bytes): `{ "product": "agent" | "code", "cid": "<≤64 chars [A-Za-z0-9_-]>" }`.

| Status | Body | Meaning |
| --- | --- | --- |
| 401 | `{ "error": "authentication required" }` | no member and no guest cookie |
| 400 | `{ "error": "invalid product" }` | |
| 403 | `{ "ok": false, "error": "signin_required", "feature": "agent" }` | guest + agent |
| 200 | `{ "ok": true, "sub": subInfo }` | unlimited plan (all plans today) or charged |
| 429 | `{ "error": "daily quota reached", "quota": { "product", "used", "limit", "plan" } }` | only if a limit ≥ 0 is ever configured |

`subInfo` = `{ plan, expiresAt, daysLeft, limits:{ai,code,agent,brain}, used:{…}, remaining:{…} }`
(`server.mjs:1386-1401`; `-1` = unlimited). Idempotent per `cid` (`q.agentCids`).

### 4.2 `POST /api/chat/job` with `kind:"agentrun"` (`server.mjs:12531-12656`)

Auth: member or guest cookie (guests are then refused for agent). Rate limit `chatjob:<id>` 60/min
for members, 30/min for guests (`server.mjs:12541`) → **429** `{ "error": "too many requests" }`. The raw
body is read up to `CHAT_BODY_LIMIT` = 25 MB (`server.mjs:442`) and then rejected at 600 000 chars (413 below).
`cid` is sanitised to `[A-Za-z0-9_-]` ≤ 64; when absent the server mints `"j" + 12 hex` (`server.mjs:12562`) —
never omit it natively, or the turn cannot be found again by `cid`.

| Status | Body | Cause |
| --- | --- | --- |
| 401 | `{ "error": "authentication required" }` | |
| 400 | `{ "error": "invalid JSON body" }` / `{ "error": "messages required" }` | |
| 403 | `{ "ok": false, "error": "account_required", "feature": "agent" }` | guest |
| 413 | `{ "error": "payload_too_large" }` | raw body > `JOB_PAYLOAD_MAX` = 600 000 chars (`server.mjs:9330`) |
| 503 | `{ "error": "storage_unavailable" }` | durable store down |
| 200 | `{ "ok": true, "jobId", "phase": "completed", "text", "reasoning", "surface", "progress" }` | same `cid` already finished |
| 200 | `{ "ok": true, "jobId", "phase": "queued" \| "processing" }` | same `cid` in flight |
| 200 | `{ "ok": false, "jobId", "phase": "failed", "error", "surface", "retryRequiresNewCid": true }` | same `cid` failed — mint a new `cid` to retry |
| 409 | `{ "error": "agent_busy", "activeJob": { "jobId", "chatId", "cid", "title" }, "credits": CreditView }` | another `agentrun` job of this user is `queued`/`processing` and holds a reservation (`server.mjs:12591-12616`) |
| 429 | `{ "error": "credits_reserved", "credits": CreditView }` | `manusRemaining(user) <= 0` at enqueue (`server.mjs:12617-12619`) |
| 200 | `{ "ok": true, "jobId", "phase": "queued" }` | accepted |

Stored control record fields (`server.mjs:12625-12646`): `task` ≤ 8000, `title` ≤ 160, `lang` `"en"`
else `"ar"`, `tier` (`TIERS[tier]` else `"pro"`), `kind`, `product` ≤ 12, `chatId` (members only),
`cid`, `phase:"queued"`, `attempts`, `maxAttempts: 3`.

Worker facts that shape the UI (`server.mjs:9323-9330`, `11945-11977`): `JOB_CONCURRENCY` 4,
`JOB_STALE_MS` 120 s (a job may go quiet ~2 min and resume — not a failure), `JOB_MAX_ATTEMPTS` 3,
`JOB_KEEP_MS` 6 h (afterwards `GET /api/agent/job` answers `{ "job": null }`). Tick every 2 s.

### 4.3 The Manus worker (`agentTwinManus`, `server.mjs:10820-11087`; `runAgentJob` `11089-11112`)

- Constants (`server.mjs:8501-8517`): `MANUS_USER_CREDITS` default **500/day**; `MANUS_MAX_TASK` 600 = the
  hold placed per task (`hold = min(600, remaining)`); `MANUS_POLL_MS` 1500 ms; `MANUS_MAX_MS` 30 min
  (`agentDeadlineAt = startedAt + 30 min`); reservation expiry 24 h.
- Refusal codes returned by the worker (become `job.error` and the job's `failed` status):
  `agent_unavailable` (no key / confirmed 4xx create), `account_required`, `agent_busy` (another reservation
  exists), `credits_exhausted`, `capacity` (site balance below the hold), `agent_start_unconfirmed`
  (create timed out — hold kept 24 h, never recreated), `task_failed` (upstream status `error`),
  `deliverable_missing` (task asked for pptx/slides but no `.pptx` file arrived, `server.mjs:11059-11069`),
  `empty_result`. `reconciling` is **not** terminal: the job is re-queued with `nextAt = now+60 s` and
  `agentState:"reconciling"` (`server.mjs:11878-11885`) — the client just keeps seeing `run`/`queued`.
- HTTP status recorded on the failed job (`server.mjs:11107-11110`): `credits_exhausted`/`credits_reserved` → 429,
  `agent_busy` → 409, `account_required` → 403, everything else 503. `ctl.error` is the JSON string
  `{"error":"<code>"}`; the **public** `error` the viewer reads is `surface.error` (§4.4).
- The task text sent upstream is prefixed with `MANUS_IDENTITY` (`server.mjs:8522-8529`) and, when
  > 7800 chars, trimmed to the first 6000 + `"\n\n[…]\n\n"` + last 1600 (`server.mjs:10886-10887`).
- Progress: every poll calls `publish("run")` → `onProgress` → `agentJobStreamNotify` immediately and a
  throttled durable write (first write immediate, then ≥2.5 s apart) (`server.mjs:11802-11826`).
- Completion: final answer = first `assistant_message.content` (else last `says`); upstream file URLs are
  rewritten to `/api/agent/artifact?id=<jobId>&index=<i>`; files not linked in the text are appended as
  `**الملفات:**` / `**Files:**` + `- [name](url)` lines (`server.mjs:11046-11058`). Then
  `cr._chatAnswer = presentation === "conversation" ? final : agentJobFence(surface)`.
- Filing: `jobOutPut(text, reasoning, surface)` → `saveAssistantTurn(user, chatId, cid, chatAnswer, …)`
  (upsert by `cid`, `server.mjs:2513-2537`) → `ctl.phase = "completed"` → APNs push (§13)
  (`server.mjs:11890-11906`). A failed job with `_status ≥ 400` also files its fence into the chat
  (`server.mjs:11910-11921`).
- Credits: reserved before create, settled against `credit_usage` after; `ledger.jobs` keeps 80 entries.
  Daily reset at Baghdad-local midnight (`QUOTA_TZ_OFFSET_MINUTES` default 180, `server.mjs:3196`, `8614-8620`).

### 4.4 `GET /api/agent/job?id=<jobId>` (`server.mjs:12100-12139`)

Auth: member or guest cookie. 400 `{ "error": "bad_request" }` without `id`. 403 `{ "error": "forbidden" }`
if not the owner. 503 `{ "error": "storage_unavailable" }`. Unknown/expired id → **200** `{ "job": null }`.

Response `{ "job": AgentJobView }`:

```json
{
  "id": "<jobId>",
  "phase": "queued" | "run" | "done" | "fail",
  "presentation": "task" | "conversation",
  "title": "…", "task": "…", "lang": "ar" | "en",
  "steps": [ { "title": "…", "s": "done"|"run"|"todo"|"fail", "kind": "write", "out": "…" } ],
  "surface": {
    "startedAt": 1725000000000, "endedAt": 0,
    "events": [ { "id", "kind": "status"|"message"|"tool"|"file"|"plan", "text", "name", "arg",
                  "toolKind": "browser"|"tool"|"", "action", "status", "url", "step": -1, "at" } ],
    "tools":  [ { "name", "arg", "toolKind", "action", "url" } ],
    "says":   [ "…" ],
    "files":  [ { "name", "type", "url": "/api/agent/artifact?id=…&index=0" } ],
    "live":   [ "…" ]
  } | null,
  "final": "<markdown, only when phase === \"done\">",
  "error": "<code, only when phase === \"fail\"; defaults to \"task_failed\">",
  "credits": CreditView | null
}
```

Phase mapping from the control record (`server.mjs:12127-12129`): `completed|done → "done"`,
`failed → "fail"`, `queued → "queued"`, anything else → `"run"`. A live in-memory capture always
reports `"run"`. `steps` come from `surface.steps`, else `live._agentSteps` (never actually set anywhere in
`server.mjs` — only read at `12058`), else `## ` headings split from the text (`agentStepsFromMarkdown`,
`server.mjs:12042-12050`; for a Manus run the live text is the `live` lines joined, so this yields `[]`).
Bounds (`agentPublicSurface`,
`server.mjs:10724-10814`): steps ≤ 20 (`title` ≤ 180, `out` ≤ 100 000), events last 60 (plan-kind and
boilerplate rows are filtered out; `text` ≤ 900, `arg` ≤ 420, `url` ≤ 600), tools last 30, says last 12
(≤ 900 each, boilerplate and the final text itself dropped), files last 20 (`name`/`type` ≤ 120), live last
30 (≤ 500). `presentation` is recomputed: `"task"` iff steps or tools or files or a tool/file/browser event
exist, else `"conversation"`. Every file `url` is an authenticated same-origin artifact path — upstream
signed URLs never reach the client.

**How the surface is derived from Manus** (`manusNarrate`, `server.mjs:8670-8800`; `agentJobSurface`,
`server.mjs:10660-10715`) — what each `events[]` row means:

| Upstream message | `kind` | `text` | other fields |
| --- | --- | --- | --- |
| `status_update` | `status` | `brief · description` (deduped) | `status` = upstream `agent_status` (e.g. `running`, `stopped`, `error`) |
| `assistant_message` / `explanation` | `message` | the content | also pushed to `says` (last 16 kept, ≤ 900 each); `assistant_message.attachments[]` → `files` `{ name: filename ≤120, url, type: content_type }` |
| `tool_used` | `tool` | `⚙️ <name>: <arg ≤180>` | `toolKind` = `"browser"` when `name/action/arg` match `/browser\|search\|web\|browse\|navigate\|open_url\|click\|read_page\|بحث\|تصفح/i`, else `"tool"`; `name` = `"Firas Browser"` for browser-ish tools, else the upstream tool name (≤ 60); `arg` = `brief · description · param` (≤ 420); `action` ≤ 100; `status` from upstream; `url` only for browser-ish tools and never a `manus.*` host |
| `plan_update` / `new_plan_step` | `plan` | `📋 title · title …` | rebuilds `steps` (≤ 20, titles ≤ 140); **filtered out of the public `events`** |
| `error_message` | `status` | the content | `status: "error"` |

Every event carries `step` = the current plan index (−1 when no plan) and `at` (upstream timestamp).
`live[]` is the same text, one line per event (last 40 kept, ≤ 500). Step status words from upstream are
normalised: `/done|complete/` → `done`, `/fail|error/` → `fail`, `/run|doing|progress|current|active/` → `run`,
else `todo`; **when the job reaches `done` every step is forced to `done`** (`server.mjs:10666`). Step `kind`
is always `"write"` and `out` is always `""` on a server run.

Filters applied before anything is public (`server.mjs:10631-10658`): tool/browser events whose action/name is
`suggestions|follow_ups|quick_actions|suggested_prompts…` are dropped (`agentSurfaceDecorativeTool`); `status`
events whose text is pure lifecycle boilerplate (en `running|working|processing|thinking|starting|finished|done|complete…`,
ar `قيد التشغيل|يعمل|يعالج|بدأ|انتهى|اكتمل|مكتمل|تم الانتهاء`, optionally prefixed `Firas Agent`) are dropped
(`agentSurfaceStatusBoilerplate`); `says` lines that are boilerplate, or equal to the final text once done, are dropped.
Provider names are rewritten server-side (`manus` → `Firas`, `مانوس` → `فِراس`, `firasSurfaceText`, `server.mjs:8654-8659`).

`CreditView` (`server.mjs:8621-8629`):
`{ "remaining": n, "allowance": 500, "used": n, "held": n, "resetAt": "<ISO>", "period": "daily", "configured": bool }`.

### 4.5 `GET /api/agent/job-stream?id=<jobId>` — SSE (`server.mjs:12183-12290`)

- Auth as above. Rate limit `agent-job-stream:<owner>:<ip>` **90/min** → 429 `{ "error": "rate_limited" }`.
- The first snapshot is computed **before** headers are committed; a non-200 becomes a plain JSON error
  with that status: 404 `{ "error": "job_not_found" }`, 403 `forbidden`, 503 `storage_unavailable`.
- Headers: `Content-Type: text/event-stream; charset=utf-8`, `Cache-Control: no-store, no-cache, must-revalidate, no-transform`,
  `Connection: keep-alive`, `Content-Encoding: identity`, `X-Accel-Buffering: no`, `X-Content-Type-Options: nosniff`
  (`server.mjs:12210-12217`). First line `retry: 3000`. Keep-alive comment `: keepalive` every 15 s.
- Frames (`agentJobStreamWrite`, `server.mjs:12175-12181`):

```
id: 1
event: snapshot
data: {"job":{ …AgentJobView… }}

id: 7.terminal
event: terminal
data: {"id":"<jobId>","phase":"done"}

event: agent-error
data: {"error":"stream_unavailable","retryable":true}
```

  `snapshot` is sent only when the payload's SHA-256 changed; `terminal` follows the last snapshot and the
  server then ends the response. `agent-error` also ends the response (`retryable` = status ≥ 500).
- Server wake sources: every `jobCtlPatch`/progress callback (`agentJobStreamNotify`) coalesced 80 ms, plus a
  1250 ms fallback timer. So the stream ticks roughly every 1.5 s while Manus is polled.

### 4.6 `GET /api/agent/artifact?id=<jobId>&index=<n>[&download=1]` (`server.mjs:12419-12476`)

- Auth: owner only. Query keys other than `id`, `index`, `download` → 400. `id` must match
  `^[A-Za-z0-9_-]{1,96}$`, `index` `^\d{1,3}$`. Rate limit `agent-artifact:<owner>` **30/min** → 429.
- 403 `forbidden`; 404 `artifact_not_found` (unknown job or index); 502 `artifact_unavailable`
  (upstream fetch failed, > 32 MB, > 30 s, redirect loop); 503 `storage_unavailable`.
- 200 streams the bytes with `Content-Type` sniffed from upstream/extension (html/js/svg are forced to
  octet-stream), `Content-Disposition: inline` for pdf, images, audio, video, text, json — `attachment`
  otherwise or when `download=1`; `filename*=UTF-8''…` carries the Arabic name; `Cache-Control: private, no-store`;
  CSP `sandbox`. Cookies are required — use the app's URLSession with the session cookie, never `WKWebView`
  without it.

### 4.7 `GET /api/agent/credits` (`server.mjs:8960-8972`)

401 without any cookie. Guest → 200 `{ "remaining": 0, "allowance": 500, "used": 0, "held": 0, "resetAt", "period": "daily", "configured", "guest": true, "locked": true }`.
Member → `CreditView`.

### 4.8 `POST /api/chat/cancel` `{ "id": "<jobId>" }` (`server.mjs:12478-12529`) — read §12 before using

### 4.9 Gone

`POST /api/agent/start`, `GET /api/agent/poll` → 410 `{ "error": "durable_agent_route_required" }`.
`POST /api/agent/job` → no route (falls to the generic 404).

---

## 5. The watcher: `agWatchServerRun(chatId, jobId, cid, sid)` (`app.js:58690-58987`)

Native equivalent: one `MissionWatcher` actor per `jobId`.

- **Idempotent per job**: a second call for a running job only pokes `wake()` (`app.js:58692-58696`).
- Terminal test: `phase ∈ {done, completed, fail, failed, stopped, cancelled, canceled}` (`58717-58719`).
- **Transport**: `EventSource("/api/agent/job-stream?id=…")` (`58923`). On `snapshot` → parse `data.job || data`,
  bump `streamEpoch`, reset `reconnectDelay` to 1000, stop polling, queue the snapshot. If terminal → close the
  source. On `onerror` → close, `startPolling(0)`, `scheduleReconnect()` with delay doubling 1 s → 15 s cap
  (`58911-58916`). No `EventSource` → polling only.
- **Polling fallback** (`58875-58910`): `GET /api/agent/job?id=` with `cache: "no-store"`; **700 ms** while
  visible, **5000 ms** while hidden; 403 → `shutdown(true)`; a poll response is discarded if a stream snapshot
  arrived meanwhile (epoch check).
- **Return from background** (`58960-58976`, `58736-58742`): `visibilitychange` → visible calls `wakeViewer()`
  (80 ms debounce): epoch++, abort in-flight poll, close source, `startPolling(0)`, reconnect the stream.
  Going hidden reschedules the fallback poll at 5 s. `pagehide` → `shutdown(false)` (stop watching, **keep the pointer**).
- **Expiry**: `setTimeout(() => shutdown(true), AG_JOB_MAX_MS - (now - pointer.ts))`, `AG_JOB_MAX_MS = 3 h`
  (`58552`, `58982-58985`). `shutdown(true)` forgets the pointer.
- **`applySnapshot(job)`** (`58761-58867`), serialised through a promise chain:
  1. If this device no longer holds a pointer for `jobId` → `shutdown(false)`.
  2. Resolve the conversation under either id (`jobChatById(chatId, sid)`, `58566-58570`) but only when the chat
     list is loaded and healthy; while it is missing, a terminal snapshot keeps polling every 3 s; after 15 s of
     "chat not found" with a loaded list → `shutdown(true)`.
  3. Adopt a newly assigned `serverId` into the pointer and write `firas_job_<serverId>`.
  4. Terminal & messages not loaded → `refreshChatFromServer(target)`; locate the message by `cid` (fallback: last
     assistant message); if still missing, refresh once more.
  5. `run = bgJobToRun(job)` (§6.2). Message content becomes **plain `final` text** when
     `terminal && phase === "done" && final && presentation === "conversation"`, otherwise
     `serializeAgentRun(run)` (the ` ```firas-agent ` fence) (`58832-58834`).
  6. Non-terminal: patch the existing panel in place (`agPatchServerPanel`) or re-render the thread at most every
     10 s; `missionWatchSync`; `renderHistory()` if changed; `acRowSync(job.credits)` (`58842-58852`).
  7. Terminal: `persistChat`, repaint if that chat is still on screen (never yank the user elsewhere),
     `missionWatchEnd`, `settleStreaming`, `renderHistory`, `shutdown(true)` → `agJobForget(chatId, sid, jobId)`
     which removes both flat keys, both pointer rows and repaints rail/sidebar (`58632-58657`).
- **Reattach** (`agJobsReattach`, `58990-59002`): for each pointer row: malformed → forget; older than 3 h → forget;
  dedupe by `jobId`; else `agWatchServerRun`. Called 1.2 s+ after boot once chats are fetched (`app.js:47204`) and on
  `visibilitychange`→visible, `online`, `focus`, `pageshow` (`app.js:50757-50778`).

---

## 6. Client state and data shapes

### 6.1 Pointers (`app.js:58551-58657`)

- `localStorage["firas_ai_agent_jobs"]` = `{ "<chatId>": { "jobId", "cid", "sid", "ts" } }`, duplicated under
  `sid` when known; **20 rows max** (`AG_JOB_MAX_PTRS`), oldest `ts` evicted; `ts` = mission start, never refreshed.
- `localStorage["firas_job_<chatId>"] = jobId` (and under `serverId`) — the cheap broadcast swept by
  `liveChatIds()` (`app.js:19553-19573`) for sidebar/rail indicators (§10).
- `jobPtrSweep()` (`app.js:59323-59355`) runs last on every return hook: a flat `firas_job_<id>` key whose id is
  neither a known chat id/serverId, nor a key/`sid` in any pointer table, nor an active stream is deleted, and the
  rail/sidebar is repainted. Native: prune indicator state for chats that no longer exist.
- Native: persist `{jobId, cid, chatId, serverChatId, startedAt}` in a bounded table (UserDefaults/SwiftData),
  keyed by chat; treat any row older than 3 h as dead.

### 6.2 `bgJobToRun(job)` — the adapter the card is drawn from (`app.js:58437-58485`)

```
phase:  queued → "run"; completed → "done"; processing|exec → "run"; failed → "fail"; else unchanged
steps:  { title, kind: step.kind || "write", s: done|run|fail|todo, out }
        (a lone placeholder step titled "بدء المهمة وتجهيز الخطة" / "Starting the task and preparing the plan"
         with no surface work is dropped)
error:  job.error
held:   job.credits.held
reservationBlock = error ∈ {agent_busy, credits_reserved} || (error === credits_exhausted && held > 0)
  → phase "blocked", steps []
error === credits_exhausted (no hold) → phase "credits", steps []
final:  when phase ∈ {fail, blocked, credits} the localized failure text (§9.5), else job.final
activeChatId: job.activeChatId || job.activeJob?.chatId
bg: true, jobId: job.id, surface: job.surface || {}, credits: job.credits
stats: { startedAt: surface.startedAt, endedAt: surface.endedAt, steps, done }
```

The server never sends `blocked`/`credits` phases; they are **client-derived** from `error`.

### 6.3 The persisted card: ` ```firas-agent ` fence

A mission message's `content` is `"```firas-agent\n" + JSON + "\n```"` (`serializeAgentRun`, `app.js:51599-51686`;
server twin `agentJobFence` → `agentPublicSurface`, `server.mjs:10816-10818`). Parse with `parseAgentMeta`
semantics (`app.js:51576-51598`): strip the fence, `JSON.parse`; if that fails (truncated by the ~200 K content
cap) brace-match the first complete top-level object. A message that does **not** start with the fence is an
ordinary markdown answer (the `"conversation"` presentation writes plain `final` text).

Fields the native parser must accept (all optional except `steps`):

| Field | Type / bound | Source |
| --- | --- | --- |
| `task` | string ≤ 3000 (client) / ≤ 4000 (server) | |
| `title` | string ≤ 160 | |
| `phase` | `read plan run verify enhance assemble test done stopped blocked credits fail` (client) ; `run done fail queued` (server) | |
| `lang` | `"ar"` \| `"en"` | |
| `mode` | `"answer"` (server always) \| `doc` \| `project` \| `codefile` (legacy) | |
| `steps[]` | `{ title ≤200, kind, file, s, out ≤15000 (client) / ≤100000 (server), fix?, produces?, table? }` | |
| `final` | markdown ≤ 40000 (client) / ≤ 100000 (server) | |
| `stats` | `{ startedAt, endedAt, files, lines, searches, images, fixes, visual, checks, elapsed, score }` (legacy in-tab runs; server runs carry none) | |
| `error` | string ≤ 80 (`agent_busy credits_reserved credits_exhausted account_required task_unavailable task_failed …`) | |
| `jobId`, `activeChatId` | strings ≤ 100 | |
| `presentation` | `"conversation"` \| `"task"` ≤ 40 | |
| `bg` | `true` when server-side | |
| `qaOpen`, `done`, `doneOpen` | string arrays (legacy) | |
| `surface` | `{ startedAt, endedAt, events[≤48], tools[≤24], says[≤10], files[≤16], live[] }` — same element shapes as §4.4 | |
| `v`, `id` | server fence only | |

Step `kind` values a legacy card may carry (labels, `TOOL_LABEL`, `app.js:52490-52493`; emoji `KIND_IC`, `52497`):
ar `research بحث · write كتابة · solve حلّ مسائل · draw رسم بياني · code برمجة · design تصميم · compute حساب · cite توثيق · table جدول بيانات · timeline مسار زمني · checklist قائمة مهام · compare مقارنة · cards بطاقات مراجعة · outline مخطط تفصيلي · translate ترجمة · steps خطوات عملية · glossary مسرد المصطلحات · formula اشتقاق خطوة بخطوة · risks المخاطر · budget جدول تكاليف · quiz اختبار قصير · map خريطة مفاهيم · sources قائمة المصادر · translate_pair ترجمة متقابلة · checklist_review تدقيق المتطلبات · decision قرار · proof برهان · dataset مجموعة بيانات · critique مراجعة نقدية · schedule جدول زمني`;
en `Research · Writing · Solving · Charting · Code · Design · Compute · Citations · Data table · Timeline · Checklist · Comparison · Flashcards · Outline · Translation · How-to steps · Glossary · Derivation · Risks · Cost breakdown · Quiz · Concept map · Sources · Side by side · Requirements check · Decision · Proof · Dataset · Critique · Schedule`.
Server-produced runs always use `"write"`. Unknown kinds → render as `write`.

### 6.4 What the server files into the chat (`saveAssistantTurn`, `server.mjs:2513-2537`)

On a terminal job the worker upserts one assistant message into the chat identified by the job's `chatId`,
matched by `cid` (`server.mjs:11892-11896`, failed jobs `11912-11914`):
`{ "role": "assistant", "content": "<plain final markdown | ```firas-agent fence>", "reasoning": "", "tier": "max", "lang": "ar"|"en", "cid": "<cid>" }`
(`retryOf`/`retried` carried over if the row already had them). A chat keeps at most `MAX_MESSAGES` = 2000
messages (`server.mjs:2417`). The chat is never created here — if `chatId` was empty or foreign the filing is a
silent no-op, so **always create the chat first** (§2.1.3). The `/api/chats` list row is
`{ id, title, updatedAt, pinned, agent, codeProj, brainNb }` (`server.mjs:2545`); `agent: true` puts the
conversation in the Agent list.

---

## 7. The mission card — what is drawn (`buildAgentCard`, `app.js:53322-53646`)

Order inside the card (`div.agent-card.agent-card--flow`, `+is-done` when done):

1. **Firas Computer panel** (`fcPanelEnsure` / `fcPanelPatch`, §8) — always present; it is the header, plan, activity, sources and files.
2. Steer row — never rendered for server runs (§0).
3. **Task report chips** (only `phase === "done"` and `stats.files || stats.lines`, i.e. legacy runs) (`53458-53477`): label ar `تقرير المهمة` / en `Task report`; chips `📄 N ملف`/`📄 N files`, `📝 N سطر`/`lines`, `🔎 N بحث ويب`/`searches`, `🖼️ N صورة`/`images`, `🧪 N إصلاح تشغيل`/`runtime fixes`, `👁️ N إصلاح بصري`/`visual fixes`, `∫ N تدقيق`/`checks`, `⏱️ N د`/`Nm` or `N ث`/`Ns`, `🏅 الجودة N/10`/`Quality N/10`.
4. **Resume** (`53482-53487`): shown when `(phase === "stopped" || (phase === "fail" && !blockedByActive)) && steps.some(s => s.s !== "done")`, where `blockedByActive = error ∈ {agent_busy, credits_reserved} || error === "credits_exhausted"`. Label ar `▶ استئناف المهمة` / en `▶ Resume task`. Action `resumeAgentRun` → `runAgentAssistant(chat, "max", lang, null, true)` (`59517-59522`) — **charges and starts a brand-new durable mission from the chat's last user message**; nothing is resumed server-side. (Auto-resume strings, legacy only: `▶ يستأنف من حيث توقّف…` / `▶ Resuming where it stopped…`; toast `أُكمل المهمة من حيث توقّفت` / `Picking the task up where it stopped`.)
5. **Open running task** (`53521-53532`): when `reservationBlock && run.activeChatId`. Label ar `فتح المهمة الجارية ←` / en `Open running task →`. Opens `jobChatById(activeChatId)`; if absent, toast ar `حدّث قائمة المحادثات حتى تظهر المهمة.` / en `Refresh the conversation list to find the task.`
6. **Fix what's left** (`53546-53562`, legacy `qaOpen` only): ar `🛠 أصلح ما تبقّى (N)` / en `🛠 Fix what's left (N)`; sends a new user message `أصلح هذه الملاحظات تحديدًا في ما سلّمته، ولا تغيّر أي شيء آخر يعمل:\n1) …` / `Fix exactly these findings in what you delivered, and change nothing else that works:\n1) …`.
7. **Export Markdown** (`53576-53601`): when `!error && phase ∉ LIVE_PHASES && (a done step has output || final)`. Label `agentExportMd` ar `⬇ تصدير Markdown` / en `⬇ Export Markdown`; tooltip `agentExportMdT` ar `احفظ المهمة كاملة — الخطة وكل خطوة مع مخرجاتها والمصادر — بملف Markdown واحد` / en `Save the whole task — the plan, every step with its output, and the sources — as one Markdown file`; toast `agentExportDone` ar `تم تنزيل ملف المهمة ✓` / en `Task file downloaded ✓`. File name = title or task, 80 chars, `.md`. Document layout (`agentRunMarkdown`, `52976-53105`; labels `AGENT_MD_L`, `52940-52959`): `# <title>`; italic meta line `صُدِّر من فِراس Agent · <phase label> · الخطوات: done/total · <date>`; `## المهمة` (task as `> ` quote); `## الخطة` (`- [x] 1. title — kind`); `## الخطوات` with `### الخطوة N — title`, italic `kind · file · لم تُنفَّذ/تعثّرت`, body (headings nested down); `## النتيجة`; `## المصادر` (URLs harvested from outputs unless a `cite` step exists); untitled fallback `مهمة فِراس Agent` / `Firas Agent task`; empty step `لا مخرجات لهذه الخطوة.` / `This step produced no output.`
8. **Save as template** (`53607-53629`): `phase === "done" && steps.length && agentTplUiOk()`. Strings `atplSave` ar `🔖 احفظ كقالب` / en `🔖 Save as template`; `atplSaveT` ar `احفظ خطة هذه المهمة — خطواتها وأنواعها فقط — لتبدأ منها مهمة جديدة لاحقًا` / en `Keep this mission's plan — its steps and their kinds only — to start a new mission from later`; `atplName` ar `سمِّ هذا القالب:` / en `Name this template:`; `atplSaved` ar `حُفِظ القالب ✓` / en `Template saved ✓`; `atplFull` ar `عندك ٨ قوالب — احذف واحدًا قبل أن تحفظ غيره` / en `You already have 8 templates — delete one before saving another`; `atplFail` ar `تعذّر حفظ القالب` / en `Couldn't save the template`. (Templates are device-local; a server run's plan is all `write` steps, so this is low value natively.)
9. **Final result** (`53630-53644`): label ar `النتيجة` / en `Result`, markdown body (`renderMarkdown` + KaTeX), direction by text. Links whose `href` exactly equals one of `surface.files[].url` open the in-app artifact viewer instead of navigating (`fcBindFinalArtifactLinks`, `56779-56796`).

Display normalisation before drawing (`53324-53352`): `completed → done`, `cancelled|canceled → stopped`; a `bg` run in phase `fail` with no `error`, whose `final` matches the legacy refusal texts (`تعذّر إكمال المهمة`, `فِراس ايجينت غير متاح`, `The task could not be completed`, `Firas Agent is temporarily unavailable`) or with empty final and no step output, is shown as `error: "task_unavailable"` with no steps. A run in a live phase with **no viewer attached** (`LIVE_PHASES = {read, plan, run, running, verify, enhance, assemble, test}`) is displayed as `stopped` with running steps demoted to `todo` (`orphaned`), which is what makes the Resume button appear on a reload without a pointer.

---

## 8. Firas Computer panel — the live body of the card (`app.js:56086-57024`)

Structure (`fcPanelEnsure`, `56322-56349`): `section.fc.fc--stream[aria-busy]` →
`header.fc__identity` (brand mark, name, status pill `role=status aria-live=polite`, `time.fc__clock` LTR) →
`div.fc__speech` (hidden until there is a `says` line) → `p.fc__mission` (title, hidden when speech exists) →
`div.fc__flow`.

State fed to it (`agentRunSurfaceState`, `57006-57024`): `{ phase, missionTitle: run.title, startedAt, endedAt,
plan: steps[{title,s,kind,file,out,table,fix}], events, tools, says, files, live }`.

- **Status pill** (`fcPhaseLabel`, `56292-56301`, copy `FC_COPY`): `done|completed` → ar `اكتملت المهمة` / en `Task completed`; `fail|failed` → `تعذّر إكمال المهمة` / `Task could not be completed`; `blocked` → `مهمة أخرى قيد التنفيذ` / `Another task is running`; `credits` → `استُهلك رصيد اليوم` / `Daily credits used`; `stopped|cancelled|canceled` → `توقفت المهمة` / `Task stopped`; `plan` → `يُجهّز خطة العمل` / `Preparing the plan`; anything else → `قيد التنفيذ` / `In progress`. Panel classes `is-done`, `is-fail`; `aria-busy` true while `phase ∈ FC_LIVE_PHASES`.
- **Clock**: `m:ss` from `startedAt` (`fcFmtElapsed`), ticking every second while live; frozen at `endedAt` after (`56974-56987`).
- **Speech**: the **last** `says` line, typed in with a smooth reveal (34 ms cadence; finish window 560 ms live / 260 ms terminal) (`fcSpeechPatch`, `56916-56955`). When speech is empty the mission title is shown instead.
- **Flow** (`fcFlowPatch`, `56857-56904`) — rebuilt only when a signature of phase/plan/events/files changes; open/closed state of each `<details>` is remembered per key and focus is restored:
  1. **Plan group** (`fcTaskPatch`, `56439-56482`): a `<details>` titled `خطة التنفيذ` / `Execution plan` with count `done / total` (LTR). Default open while live and (phase `plan` or a step is `run`). Each step is a nested `<details class="fc__plan-step is-<s>">` with the step title and a meta word: `N أحداث`/`N events` when events are bucketed to that step (by `event.step` index), else `run` → `جارٍ الآن`/`In progress`, `done` → `تم`/`Done`, `fail` → `تعذّر`/`Failed`, `todo` → `لاحقًا`/`Up next`. Default open when `run`. Body (lazy, `fcFillPlanBody`, `56405-56437`): a `table` payload → table; `checklist` kind → checklist; else if `out` → label `الناتج`/`Output` + markdown; else the last 8 bucketed events as paragraphs; else `يعمل Firas Agent على هذه الخطوة الآن…` / `Firas Agent is working on this step now…` (running) or `ستظهر تفاصيل هذه الخطوة عند بدء تنفيذها.` / `Details will appear when this step starts.`
  2. **Global events** — events whose `step` is not a valid plan index (or all events when there is no plan). Events come from `surface.events` (rows with any of `text|name|action|url`, last **100**), falling back to `surface.live` lines (last **40**, as kind `activity`, bucketed to the currently running step, else the last done step), then `surface.tools` (last 30, as kind `tool`) (`fcTaskEvents`, `56396-56403`; `fcFlowPatch`, `56860-56863`). The newest event gets class `is-new` the first time it is seen (per-view `seen` set) — the native cue for an "appear" animation on exactly one row. `kind` normalisation (`fcEventKind`, `56203-56208`): `plan`, `file`, `message|say → say`, `tool`, else `activity`. A `say` event renders as a prose paragraph (skipped if it equals the current speech line). Others render as `<details class="fc__event is-<type> is-active|is-fail|is-done is-new">`: icon by `fcToolType` (`56210-56220`: `search`, `browser`, `read`, `click`, `file`, `generate`, `write`, `tool` — regex over `toolKind/name/action/text`, Arabic included: `بحث`, `تصفح`, `قراءة`, `نقر`, `ملف`, `صورة`, `كتابة`…); title by `fcActivityTitle` (`56250-56285`: maps verbs to `يبحث`/`Searching`, `يبحث في المصادر الأكاديمية`/`Searching scholarly literature`, `يتصفّح`/`Browsing`, `يفتح المصدر`/`Opening the source`, `يقرأ المصدر`/`Reading the source`, `ينشئ الملف`/`Creating a file`, `يكتب`/`Writing`; cross-language unknown action codes → `ينفّذ الإجراء`/`Running an action`; file rows keep the file name); image events → `يتم صنع الصور بواسطة Firas AI` / `Images are being created by Firas AI` (running) or `صُنعت الصور بواسطة Firas AI` / `Images were created by Firas AI`; hint = `arg` ≤ 120; status word `جارٍ الآن`/`In progress` for the last event while live, `تعذّر`/`Failed` when `status` matches `fail|error`, else `تم`/`Done`. Body: detail text (`arg||text||action` ≤ 900) or `اكتمل هذا الإجراء ضمن تنفيذ المهمة.` / `This action was completed as part of the task.`, plus `فتح المصدر ↗` / `Open source ↗` link when `url` is http(s) and not a `manus` host.
  3. **Sources group** (`fcSourcesPatch`, `56528-56564`): unique event URLs → `<details>` `المصادر`/`Sources` with count; last 12 as `hostname` + label ≤ 180, open in a new tab.
  4. **Files** (`fcFilesPatch`, `56798-56855`): only same-origin URLs are trusted (`fcSafeFileUrl`). Images (`image/*` or png/jpg/webp/gif/svg) → media grid cards with caption `صُنعت هذه الصورة بواسطة Firas AI` / `This image was created by Firas AI`, tapping opens the image viewer. Other files → `<details>` `الملفات والمخرجات` / `Files and outputs` with count; each is a button `فتح الملف: <name>` / `Open file: <name>` → `openAgentArtifactViewer` (`56737-56774`): PDF rendered with pdf.js (first 30 pages, note `تم عرض أول ٣٠ صفحة. نزّل الملف لعرضه كاملًا.` / `The first 30 pages are shown. Download the file to view all pages.`), html/markdown/json in a sandboxed iframe, text/code as `<pre>`, anything else → `هذا النوع متاح للتنزيل.` / `This file type is available to download.`; 20 MB cap → `حجم الملف كبير للمعاينة؛ يمكنك تنزيله.` / `This file is too large to preview; you can download it.`; failure → `تعذّر فتح هذا الملف داخل Firas Agent.` / `This file could not be opened inside Firas Agent.`; loading `جارٍ فتح الملف…` / `Opening the file…`; buttons `تنزيل الملف`/`Download file`, close `إغلاق`/`Close`.
- Provider scrubbing: every string passes `fcSurfaceText` (`56135-56144`) which rewrites provider names (manus/openai/claude/gemini/… and Arabic spellings) to `Firas`/`فِراس`; URLs whose host contains `manus` are dropped. The server already does this (`firasSurfaceText`, `server.mjs:8654-8659`) — replicate at least the URL rule natively.
- The Arabic/English choice for panel chrome follows the **UI language** (`fcUiAr` → `state.lang`), not the run's language; content direction is per string (`detectLang`).

Full `FC_COPY` (`app.js:56086-56119`), ar / en:
`name` Firas Agent / Firas Agent · `working` قيد التنفيذ / In progress · `planning` يُجهّز خطة العمل / Preparing the plan · `done` اكتملت المهمة / Task completed · `failed` تعذّر إكمال المهمة / Task could not be completed · `stopped` توقفت المهمة / Task stopped · `blocked` مهمة أخرى قيد التنفيذ / Another task is running · `credits` استُهلك رصيد اليوم / Daily credits used · `plan` خطة التنفيذ / Execution plan · `sources` المصادر / Sources · `files` الملفات والمخرجات / Files and outputs · `activity` سجل التنفيذ / Execution log · `search` البحث في الويب / Searching the web · `browser` تصفّح صفحة / Browsing a page · `read` قراءة مصدر / Reading a source · `click` التفاعل مع الصفحة / Interacting with the page · `write` كتابة المحتوى / Writing content · `generate` إنشاء محتوى / Creating content · `file` إنشاء ملف / Creating a file · `tool` تنفيذ إجراء / Running an action · `running` جارٍ الآن / In progress · `waiting` لاحقًا / Up next · `actionSearch` يبحث / Searching · `actionAcademicSearch` يبحث في المصادر الأكاديمية / Searching scholarly literature · `actionBrowse` يتصفّح / Browsing · `actionOpen` يفتح المصدر / Opening the source · `actionRead` يقرأ المصدر / Reading the source · `actionFile` ينشئ الملف / Creating a file · `actionWrite` يكتب / Writing · `actionFallback` ينفّذ الإجراء / Running an action · `completed` تم / Done · `failedShort` تعذّر / Failed · `events` أحداث / events · `openSource` فتح المصدر / Open source · `noDetail` اكتمل هذا الإجراء ضمن تنفيذ المهمة. / This action was completed as part of the task. · `stepNow` يعمل Firas Agent على هذه الخطوة الآن… / Firas Agent is working on this step now… · `stepLater` ستظهر تفاصيل هذه الخطوة عند بدء تنفيذها. / Details will appear when this step starts. · `result` الناتج / Output · `input` المدخل / Input · `imageCreating` يتم صنع الصور بواسطة Firas AI / Images are being created by Firas AI · `imageCreated` صُنعت الصور بواسطة Firas AI / Images were created by Firas AI · `imageAttribution` صُنعت هذه الصورة بواسطة Firas AI / This image was created by Firas AI · `openFile` فتح الملف / Open file · `downloadFile` تنزيل الملف / Download file · `viewerLoading` جارٍ فتح الملف… / Opening the file… · `viewerFailed` تعذّر فتح هذا الملف داخل Firas Agent. / This file could not be opened inside Firas Agent. · `viewerTooLarge` حجم الملف كبير للمعاينة؛ يمكنك تنزيله. / This file is too large to preview; you can download it. · `unsupported` هذا النوع متاح للتنزيل. / This file type is available to download.

`AGENT_PHASE_LABEL` (`app.js:51687-51700`, used by the Markdown export and the corner panel):
`read` يقرأ المرفقات… / Reading attachments… · `plan` يخطّط… / Planning… · `run` ينفّذ… / Executing… · `verify` يراجع نفسه… / Self-reviewing… · `enhance` يطوّر ويوسّع… / Enhancing… · `assemble` يجمّع النتيجة… / Assembling… · `test` يختبر ويصلّح… / Testing & fixing… · `done` اكتملت المهمة / Task complete · `stopped` أُوقفت / Stopped · `blocked` مهمة أخرى قيد التنفيذ / Another task is running · `credits` استُهلك رصيد اليوم / Daily credits used · `fail` تعثّرت / Failed.

---

## 9. Every error/refusal and what the UI says

| # | Condition | Card phase / error | Text shown (ar / en) | Cite |
| --- | --- | --- | --- | --- |
| 9.1 | Guest tries to send | none (draft kept) | sign-up dialog (§1) | `app.js:44430` |
| 9.2 | Guest reaches the job route or charge | `blocked` / `account_required` | `سجّل الدخول أو أنشئ حسابًا مجانيًا لبدء هذه المهمة. طلبك ما زال محفوظًا.` / `Sign in or create a free account to start this task. Your request is still saved.` | `app.js:59366-59377` |
| 9.3 | `409 agent_busy` at enqueue, or a failed job with `error:"agent_busy"` | `blocked` / `agent_busy` | `توجد مهمة أخرى قيد التنفيذ، ورصيدها محجوز مؤقتًا. افتح المهمة الجارية لمتابعتها.` / `Another task is still running and its credits are temporarily reserved. Open it to follow the work.` + toast (§3) + button "Open running task" | `app.js:59437-59439`, `58462-58465` |
| 9.4 | `429 credits_reserved` | `blocked` / `credits_reserved` | `الرصيد محجوز مؤقتًا لمهمة سابقة، لذلك لم تُنشأ مهمة مكررة.` / `Credits are temporarily reserved for an earlier task, so no duplicate task was created.` (also toast) | `app.js:59463-59466`, `58469-58471` |
| 9.5 | `credits_exhausted` (no hold) | `credits` / `credits_exhausted` | `استُهلك رصيد اليوم. يتجدّد تلقائيًا في الموعد الموضّح أعلاه.` / `Today's credits have been used. They refresh automatically at the time shown above.` | `app.js:59464-59466`, `58466-58468` |
| 9.6 | Daily mission quota (`/api/usage/charge` 429; unreachable today) | `credits` / `credits_exhausted` | `🚦 بلغت الحدّ اليومي من مهام فِراس Agent (N/يوم). يتجدّد تلقائيًا بعد منتصف الليل.\n\nفِراس مجاني بالكامل — هذا السقف موجود ليبقى المحرّك متاحًا للجميع، وهو مرتفع لدرجة أن الاستخدام الطبيعي لا يبلغه.` / `🚦 You've reached today's limit of Firas Agent tasks (N/day). It resets automatically after midnight.\n\nFiras is completely free — this ceiling only keeps the engine available for everyone, and it is set high enough that ordinary use never reaches it.` | `app.js:6464-6482`, `59379-59390` |
| 9.7 | Enqueue refused for any other reason (400/413/429 rate/503/network) | `fail` / `task_unavailable`, one failed step | step `تعذّر بدء المهمة` / `Task could not be started`; final `الخدمة غير متاحة مؤقتًا. لم تُحوَّل المهمة إلى أداة أخرى؛ أعد المحاولة.` / `Firas Agent is temporarily unavailable. Nothing was handed to another tool; please retry.` | `app.js:59764-59774` |
| 9.8 | Job `fail` with any other code (`task_failed`, `deliverable_missing`, `empty_result`, `agent_unavailable`, `agent_start_unconfirmed`, `capacity`, `no_answer`) | `fail` / `<code>` | `تعذّر إكمال المهمة. لم تُحوَّل إلى أداة أخرى؛ أعد المحاولة.` / `The task could not be completed right now. It was not switched to another tool; you can retry.` + Resume button (§7.4) | `app.js:58459-58461` |
| 9.9 | Watcher gives up: 3 h expiry (`shutdown(true)` → `agJobForget`), 15 s with the chat missing from a loaded list, or a 403 | The pointer is dropped, so on the next render the card has no viewer and the `orphaned` rule (§7) applies: phase shown as `stopped` (`توقفت المهمة` / `Task stopped` pill), running steps demoted to `todo`, Resume button visible. No toast. (The corner panel is **not** ended by `agWatchServerRun`; only the dead `bgJobStop` did that.) | — | `app.js:58982-58985`, `58778-58784`, `58887`, `53342-53346` |
| 9.10 | Legacy in-tab Manus 429 toasts (dead) | — | `انتهى رصيدك اليومي من Firas Agent. يتجدد تلقائيًا غدًا.` / `Your daily Firas Agent credits are used up. They refresh tomorrow.`; `site_credits`: `رصيد الوكيل انتهى مؤقتًا — جرّب بعد قليل.` / `Agent capacity is used up right now — try shortly.` | `app.js:57188-57195` |

The web never surfaces the raw code (`task_failed`, `deliverable_missing`…) to the user. Native may map
`deliverable_missing` and `empty_result` to more specific copy, but only §9.8's sentence exists today.

---

## 10. Sidebar / rail live indicators (`app.js:19553-19649`)

- `liveChatIds()` = chat ids with a `firas_job_` key ∪ keys/sids in the agent and long-file pointer tables ∪ chats with an in-tab stream.
- Sidebar row: class `is-working` + a leading dot `.chat-item__live` with `aria-label`/`title` ar `ما زالت تشتغل` / en `still working` (`paintLiveRows`, `19599-19618`). Repainted by `paintRailBadges()` on every stream start/stop and on `agJobForget`.
- Product rail (UI 2.0 only): `.rail__busy` dot on the Agent item; text = count when > 1; tooltip `Firas Agent — مهمة تشتغل الآن` / `N مهام تشتغل الآن` / `running now` / `N running` (`19628-19647`).
- UI 2.0 inspector shows the plan as a fixed timeline: heading ar `خطوات المهمة` / en `Mission steps`, `done/total`, progress bar, numbered rows (`✓` done, `!` fail, Arabic-Indic digits in Arabic UI), tapping scrolls to the card (`inspectorSteps`, `19747-19793`).
- Mission-watch corner panel strings (desktop only; keep for parity if a compact "now playing" bar is built): `mwLabel` ملخّص المهمة الجارية / Live mission summary · `mwOpen` افتح المهمة / Open the mission · `mwLast` آخر ما أُنجز / Just finished · `mwFold` اطوِ الملخّص / Collapse · `mwUnfold` افرد الملخّص / Expand · `mwHide` أخفِ حتى تنتهي المهمة / Hide until the mission ends · `mwElapsed` الزمن المنقضي / Elapsed · `mwSteps` الخطوات المنجزة / Steps finished (`app.js:972-979`, `2053-2060`). It keeps the last 3 finished steps in completion order, shows `done/total`, an `m:ss` clock and holds 30 s after the end (`51819-51821`).

---

## 11. Attachments allowed for a mission

- Composer input `#fileInput` accept (`index.html:730`): `image/*, application/pdf, .pdf, .docx, .pptx, .xlsx, .xlsm, .txt, .md, .markdown, .csv, .tsv, .json, .jsonl, .xml, .yml, .yaml, .html, .htm, .css, .scss, .js, .jsx, .mjs, .cjs, .ts, .tsx, .py, .java, .c, .h, .cpp, .cc, .hpp, .cs, .go, .rs, .rb, .php, .swift, .kt, .sql, .sh, .bash, .ini, .toml, .env, .log, .tex, .srt, .vtt, text/*`, multiple.
- Limits (`app.js:35897-35916`): `MAX_IMAGES` 10, images downscaled client-side to `MAX_EDGE` 1568 px (thumb 256 px persisted), `MAX_FILES` 5, `MAX_FILE_CHARS` 120 000 per file, `MAX_TOTAL_FILE_CHARS` 300 000. PDF/Office/text are extracted to text on the device (`fileText`).
- **Nothing binary reaches the job.** `agentMissionAttachments` (`55886-55903`) takes `images` and `fileText` from the last user message (or the one before a clarification card). Then (`app.js:59610-59650`):
  1. Card shows phase `read` (`يقرأ المرفقات…`).
  2. `fileText.length ≥ 4000` → `agentAttachRead` (`app.js:55916-55930`) asks the chat model for a dense brief via `callAgentText(messages, "pro", signal)` (`app.js:38813-38820`): `POST CONFIG.BACKEND_URL` = `/api/chat` (`app.js:16`), body `{ "messages": [{role:"system",content:<reader prompt>},{role:"user",content:…}], "tier": "pro", "think": false, "nomem": true }`, response read as OpenAI-style SSE `data: {"choices":[{"delta":{"content":…}}]}` lines until `[DONE]`. The user turn is ar `المهمة التي سينفّذها الوكيل: <task ≤400>\n\nالملف/الملفات المرفقة:\n<text ≤60000>` / en `The task the agent will carry out: …\n\nThe attached file(s):\n…`; the brief is requested in the reply language. An empty stream or an "engine busy" notice throws and the brief is silently skipped (`""`). Appended as `\n\n=== خلاصة الملف المرفق (كل المتطلبات والأرقام — اعمل بها) / ATTACHED FILE BRIEF (every requirement and figure — work from it) ===\n` + brief ≤ 3500.
  3. Images → `agentVisionRead` (`app.js:55866-55878`, same call with the images carried inline as `images` on the user message; user text ar `اقرأ الصورة/الصور المرفقة (هذه مرجع لطلب المستخدم: <task ≤300>).` / en `Read the attached image(s) (reference for the user's request: <task ≤300>).`). If the task looks like a build request (`wantsBuild` regex: `موقع|صفحة|واجهة|تطبيق|مثل هذا|نفس التصميم|أعِد بناء|clone|rebuild|website|landing|page|app|ui|design|screenshot…`) → `\n\n=== مرجع بصري مرفق — المستخدم أرفق تصميمًا/لقطة شاشة؛ أعِد بناءه في كود حقيقي بأقصى تطابق (نفس التخطيط والألوان والمكوّنات والنصوص) / ATTACHED VISUAL REFERENCE — REBUILD it in real code as closely as possible (same layout, colors, components, copy): ===\n` + ≤ 12000; else `\n\n=== محتوى الصورة/الصور المرفقة (مصدر) / ATTACHED IMAGE CONTENT (source) ===\n` + ≤ 30000.
  4. Raw file text last: `\n\n=== محتوى ملف مرفق (مصدر — ابنِ المطلوب منه) / ATTACHED FILE CONTENT (source — build from it) ===\n` + ≤ 60000.
- The resulting `task` is sliced to 120 000 chars in the POST; the server keeps `task` ≤ 8000 in the control record but passes the full body to the worker (`runAgentJob` reads `body.task`), which trims > 7800 chars to 6000 + tail 1600 before Manus (§4.3). Native should apply the same folding so behaviour matches.

---

## 12. Stop / cancel — the honest state

- Once `agentServerRun` succeeds the stream entry is dropped (`app.js:59756-59761`), so the composer Stop button is gone and **the web client offers no way to stop a running mission**. Closing the app never stops work (by design, `server.mjs:12026-12031`).
- `POST /api/chat/cancel { id }` (`server.mjs:12478-12529`): 401; 400 `bad_request`; if the job is running in this process → sets `cr._cancelled = true`, 200 `{ ok:true, stopped:true }`; else 404 `unknown_job`, 403 `not_yours`, or 409 `job_not_running` for non-`longfile` jobs. **For `agentrun` the flag is never consulted by the Manus loop**: the only reader of `_cancelled` is `streamStopped(res)` (`server.mjs:2762-2765`), which the chat engines call per chunk, and the durable `cancelledAt` tombstone is honoured only for `kind:"longfile"` (`server.mjs:10321-10328`, `11843`, `11864`); `agentTwinManus` (`10820-11087`) calls neither. So the task runs to completion, its answer is still filed into the chat, and the only effect is that the terminal APNs push is suppressed (`server.mjs:11903`). Do not present a Stop control natively unless a real cancel is added server-side (open question).
- Two "stop" verbs exist client-side: stop watching (`shutdown(false)`, keeps the pointer — used on `pagehide`) versus forget (`shutdown(true)`).

---

## 13. Push notifications on terminal (server, `server.mjs:1515-1641`)

For `kind:"agentrun"` (product `agent`) on `completed`/`failed`, members with registered APNs devices receive:

```json
{ "aps": { "alert": { "title": "…", "body": "…" }, "sound": "FirasComplete.wav",
           "category": "FIRAS_JOB_COMPLETE", "thread-id": "firas-agent-<chatId>" },
  "firas": { "type": "job-terminal", "product": "agent", "jobId": "<jobId>", "phase": "completed"|"failed", "chatId": "<chatId>" } }
```

Copy by device language (`apnsLocalizedCopy`, `server.mjs:1553-1562`): ar completed `مهمة وكيل فِراس اكتملت` / `اضغط لعرض النتيجة.`; ar failed `مهمة وكيل فِراس لم تكتمل` / `اضغط لعرض التفاصيل أو المحاولة مجدداً.`; en completed `Firas Agent mission is ready` / `Tap to view the result.`; en failed `Firas Agent mission could not finish` / `Tap to view details or try again.` `thread-id` is `"firas-agent-" + chatId` sliced to 64 chars; `apns-collapse-id` = job id (≤ 64). A job without `chatId` carries `firas.jobId` but no `chatId` key (`server.mjs:1567-1571`). Never sent to guests (`rec.isGuest` → return, `server.mjs:1628`), when the owner cancelled (`_cancelled`, `11903`), or when APNs is unconfigured. The mission screen must be deep-linkable by `chatId` (+ `jobId`).

---

## 14. Credits view (`app.js:16165-16384`)

- Chip mounted next to the "new chat" top-bar button; **visible only in the Agent product**, hidden on the share page, hidden when `configured === false`. Fetches `GET /api/agent/credits` (`no-store`); repaints from any `credits` object carried by job snapshots/409/429 bodies (`acRowSync(known)`); retries every 5 s on invalid data; re-fetches 1.5 s after `resetAt`.
- Chip label: default ar `كريديت` / en `credits`; while `held > 0`: ar `متاح · مهمة قيد التنفيذ` / en `available · task running` (class `is-held`); guest/locked: ar `بعد التسجيل` / en `after sign-in` (class `is-locked`, value shows the allowance). Value = `remaining` (or allowance when locked) formatted with `ar-IQ-u-nu-arab` (Arabic-Indic digits) in Arabic UI. Busy state ar `جارٍ تحديث الرصيد` / en `Updating credits` with `…`. aria-label ar `رصيد Firas Agent: <left> من <all>، <held> محجوز لمهمة جارية، اضغط للتفاصيل` / en `Firas Agent credits: <left> of <all>, <held> reserved for active work, open details`; locked ar `<all> كريديت يوميًا بعد تسجيل الدخول، اضغط للتفاصيل` / en `<all> daily credits after sign-in, open details`; title ar `عرض تفاصيل الرصيد اليومي` / en `View daily credit details`.
- Dialog (`openAgentCreditsPanel`, `16208-16281`): eyebrow `Firas Agent`; title ar `رصيدك اليومي` / en `Your daily credits` (locked: `رصيدك بعد تسجيل الدخول` / `Credits after sign-in`); balance label `المتبقّي` / `Remaining` (locked `يُفعّل للحساب` / `Activated for your account`), value, `من <allowance>` / `of <allowance>` (locked `يوميًا` / `daily`); progress bar aria `الرصيد اليومي المتبقي` / `Remaining daily credits`; stats `المستخدم اليوم` / `Used today`, `محجوز لمهمة جارية` / `Reserved for active work`, `موعد التجديد` / `Next refresh` with `يتجدد بعد N س M د` / `Refreshes in Nh Mm` (fallback `يتجدد يوميًا` / `Refreshes daily`); button `إضافة رصيد` / `Add credits` → toast `هذه الميزة تحت التطوير حاليًا.` / `This feature is currently under development.`; note ar `يتجدد الرصيد تلقائيًا كل يوم، وما يحتاج منك أي إجراء.` / en `Credits refresh automatically every day; no action is needed.` (locked: `سجّل الدخول حتى يتفعّل رصيدك اليومي وتحفظ مهامك بين أجهزتك.` / `Sign in to activate your daily credits and keep tasks across devices.`); close `إغلاق` / `Close`.
- Legacy in-tab cost line (dead): `كلفة المهمة: N · المتبقّي: M` / `Cost: N · remaining: M` (`app.js:57302-57305`).

---

## 15. Native mission screen — spec

**Model** (Swift, Codable):
- `AgentJobView` exactly as §4.4 (make every field optional with defaults; `phase` as a `String`-backed enum with an `unknown` case).
- `MissionRun` = the client adapter (§6.2) plus `presentation`, `credits`, `activeChatId`.
- `AgentFence` parser for ` ```firas-agent ` messages (§6.3) with the brace-match fallback; any assistant message not starting with the fence is markdown.

**Flow**:
1. Send (Agent chat): member check → local "one live mission" check (§2.1.2, same toasts) → ensure server chat → charge (`/api/usage/charge`, fail-open on transport error, 403 → sign-in) → fold attachments (§11) → `POST /api/chat/job` (§3) → handle 409/429/403/other exactly as §3 → persist pointer (§6.1) → start `MissionWatcher`.
2. `MissionWatcher(jobId, chatId, serverChatId, cid)`: SSE via `URLSession` bytes stream on `/api/agent/job-stream` (parse `id:`/`event:`/`data:` frames, honour `retry`, reconnect 1 s→15 s doubling), polling fallback on `/api/agent/job` at 0.7 s foreground / 5 s background, wake on `scenePhase == .active`, expiry 3 h after `startedAt`, terminal phases §5. On terminal: refresh the chat from `/api/chats/<id>` (the server has already filed the turn by `cid`), drop the pointer, post a local update to the conversation list. On `403` stop and drop; on `{job:null}` keep counting toward expiry.
3. Reattach all pointers on launch (after the chat list loads) and on foreground; dedupe by `jobId`; drop rows > 3 h.

**Screen** (one message cell that grows into a card):
- Header: brand mark · `Firas Agent` · status pill (§8 mapping; `role=status`-equivalent accessibility announcement) · elapsed `m:ss` (LTR).
- Speech line (last `says`, animate in) or mission title.
- Plan disclosure group (`خطة التنفيذ` · `done / total`), rows with status word, expandable output (markdown, tables, checklists).
- Activity list (events, §8) with kind icons, status word, detail + "open source" link; sources group; files: image grid with attribution, document list opening an in-app viewer (QuickLook/PDFKit for PDF; WKWebView with `sandbox` semantics for html/markdown/json; plain text otherwise) fetched **with the session cookie** from `/api/agent/artifact`; share/save via `download=1`.
- Result section `النتيجة` / `Result` (markdown + math) when `final` exists; links that equal a file URL open the viewer.
- Footer actions: `▶ استئناف المهمة` (new mission from the last user message; only for `stopped`/`fail` with unfinished steps and not blocked), `فتح المهمة الجارية ←` (blocked with `activeChatId`), `⬇ تصدير Markdown` (build §7.7 layout, share sheet). Omit steer, template, fix-what's-left.
- Blocked/credits states: no steps, the sentence from §9, and the credits chip.
- Conversation list: "still working" dot per chat (§10), Agent tab badge with count.
- Credits chip in the Agent tab bar with the dialog of §14; Arabic-Indic digits in Arabic UI.
- Push: handle `firas.type == "job-terminal"` → open chat `chatId`, trigger an immediate snapshot fetch.

**Behavioural rules to keep**: never shorten rendered text on an older snapshot (`app.js:58835` writes only when changed; legacy guard at `background-jobs-browser` §10); never write into a chat whose messages have not loaded; forget the pointer only after the turn has landed; one viewer per job; the tab/app is a viewer, the server owns the work.

---

## 16. Open questions for the server owner

1. No real cancel for `agentrun` (§12). Should `POST /api/chat/cancel` call Manus `task.stop` and mark the job `failed/cancelled`, releasing the hold?
2. `Resume` re-runs the last user message as a new mission and charges a new hold; is a true server-side resume (same `upstreamTaskId`) wanted?
3. `/api/usage/charge` is a no-op for members (all limits `-1`); the native app could skip it, but the guest 403 is a useful early gate — keep the call?
4. Job `error` codes `deliverable_missing`/`empty_result`/`capacity` have no user copy beyond the generic failure sentence (§9.8).
5. `steps` from the server are always `kind:"write"`; the 30-kind label table matters only for legacy in-tab runs persisted in chats.
6. `JOB_KEEP_MS` is 6 h while the client pointer TTL is 3 h — fine, but a mission deferred with `reconciling` more than 3 h after start becomes unwatchable on the device until the chat is reopened (the turn is still filed).
