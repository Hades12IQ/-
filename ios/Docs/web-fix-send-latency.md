# The send path — where the seconds go

**Scope of this pass:** everything that happens in `app.js` between the user pressing send and the
first token of the answer appearing, plus the server side of the durable job path in `server.mjs`.
Read-only investigation. Line numbers are against `D:\Programming\Projects\FirasAI\app.js`
(5,796,169 bytes, branch `night/capabilities-and-code-ui`) and
`D:\Programming\Projects\FirasAI\server.mjs`.

**Honesty note, per `.claude/skills/defect-triage-honesty`:** every count and every ordering claim
below is derived from reading the code and can be checked against the cited line. I did **not** take
wall-clock measurements against the live site or `:1988` in this pass — no timing number below is
measured, and where I say "seconds" I say what produces them, not how many. Two things the owner
complained about turned out **not** to have a defect behind them and are recorded as such in §7.

---

## 1. The answer to the owner's own diagnosis

> «من اريد ارسل رسالة يوكف ويشتغل يرد» — he blames the server round-trip of the durable job.

**He is partly right, and he is pointing at the second-largest item, not the largest.**

The durable job genuinely inserts work between send and first token: one extra client round trip
(`POST /api/chat/job`), three sequential Firebase writes inside that POST, three more sequential
Firebase reads when the worker claims the job, a four-slot queue, and a poll cadence that quantises
the first visible text to a 350 ms boundary. That is real and it is all removable or shrinkable.

But the single biggest serial item on the path is **not** the job. It is this line:

```js
// app.js:41569
  const turnKind = lastUserTurn
    ? await classifyTurnIntent(lastUserTurn.content, {
```

`classifyTurnIntent` → `_classifyTurn` (app.js:4130) → `callAgentText([...], "pro", signal)`
(app.js:4168) → `POST /api/chat` with `nomem:true`. It is **a complete cloud LLM completion that
must finish before the request that generates the answer is dispatched**. Its system prompt is
**10,076 characters** (measured on the file: ≈2,500 tokens of prefill) and `callAgentText` reads the
SSE stream to `[DONE]` before returning (app.js:38834–38845). Because `nomem:true` disables the Pro
path on the server (`server.mjs:12998`, `!payload.nomem`), it lands on the Ollama cloud ladder —
`glm-5.2:cloud` etc. (`server.mjs:405`). So every single turn pays one full remote prefill+generate
before the user's own turn is even sent.

There is one fast path out of it (`obviousProblemChat`, app.js:4139) and it only covers
"give me N problems". `مرحبا`, `اشرح لي نظرية فيثاغورس`, `لخص هذا النص` — all of them pay.

**So the honest verdict for him:** the stall is not one thing. On a plain send in an existing chat
there are **five client→server round trips and six server→Firebase round trips, all strictly
serialized, before the generating call goes out** — and one of those five round trips is itself a
whole model completion. The job queue is two of the five. Removing the job queue alone would make
sending noticeably better and still leave the largest blocker standing.

---

## 2. The round trips, counted

### 2.1 Plain text send, signed-in member, **existing** chat

Each row must finish before the next begins.

| # | Awaited call | Where | What it costs |
|---|---|---|---|
| 0 | `renderThread(chat, true)` (sync) | app.js:44575 | main thread, full thread reconcile + 9 `sync*` passes (app.js:22276) |
| 1 | `POST /api/chat` — the turn classifier | app.js:41569 → 4168 → 38823 | **1 RTT + a full cloud completion**, 10,076-char system prompt |
| 2 | `GET /api/search` — the *silent* web search | app.js:42478 | up to **1500 ms**, and only if it returns nothing is it free |
| 3 | `PUT /api/chats/<serverId>` — the whole transcript | app.js:42626 → 3474 | 1 RTT, body is `serializeMessages(chat.messages)` — **grows with the conversation**; up to 3 attempts × 6 s timeout |
| 4 | `POST /api/chat/job` | app.js:41211 | 1 RTT; server does 3 sequential Firebase writes (server.mjs:12625–12652) |
| 5 | `GET /api/chat/job?id=` — first poll, no pre-sleep | app.js:41284 | 1 RTT; returns `phase:"queued"`, no text |
| 6 | worker claim: `jobCtlPatchChecked` + `jobCtlGetChecked` + `jobInGetChecked` | server.mjs:11772, 11773, 11787 | **3 more sequential Firebase RTTs** |
| 7 | upstream generation starts | server.mjs:12988+ | |
| 8 | first text reaches the browser | app.js:41264 (`gap()`) | quantised to the next **350 ms** poll |

**Total before the generating call is dispatched: 5 client RTTs + 6 Firebase RTTs + 1 full model
completion.**

`turnRequirementsOf` (app.js:41582) is genuinely free — it awaits the same cached promise, exactly as
its comment claims. Verified: `_turnIntentCache` stores the promise, not the value (app.js:4288).

### 2.2 Plain text send, signed-in member, **brand-new** chat

Everything above, **plus**:

- `await persistChat(chat)` → `POST /api/chats` (app.js:44584). A 6th serial client RTT.
- `autoTitleChat(chat, firstTitleText)` (app.js:44540) fires a **second** full `callAgentText(…,
  "pro")` completion (app.js:13432) concurrently. It is not awaited, so it does not block directly —
  but it contends with the classifier for the same Ollama pool and the same per-caller rate budget,
  and the classifier is the thing the answer is waiting on.
- Step 3's `PUT` is then **redundant**: the `POST /api/chats` at 44584 already persisted the user
  message; the only thing the `PUT` adds is an empty assistant placeholder.

### 2.3 Guest send

`isGuest()` short-circuits `persistChat` to `persistChatNow` → `guestSaveChats()` (app.js:47013),
which runs **synchronously on the main thread**: `state.chats.filter(...).slice(0, 60).map(...
serializeMessages ...)` then one `JSON.stringify` and one `localStorage.setItem` of up to ~5 MB.
`chat.serverId` is never set for a guest, so `if (!chat.serverId) await persistChat(chat)`
(app.js:44584) means **every guest send pays that full-store serialize before `runAssistant` is
even called**. Guests are the majority of first-time users in Iraq.

### 2.4 The live-stream path, for comparison

`useJob` is false (app.js:42663) for an ephemeral chat, or a member whose chat has no `serverId`, or
after a job failure. Then it is `streamFetch()` → `POST /api/chat` → `handleChat` → upstream
(app.js:42685). **One round trip.** Rows 3–6 of the table vanish, and the first token arrives as
soon as the model emits it instead of on a 350 ms poll boundary.

This is the shape the owner remembers as "it used to be smooth". `CHAT_JOB = true` (app.js:41203)
turned every signed-in turn onto the slower path.

---

## 3. The durable-job path, in detail

### 3.1 Time-to-first-possible-text

`POST /api/chat/job` (server.mjs `handleChatJobStart`) does, in order:
`jobInPutChecked` → `jobOutPutChecked` → `jobCtlPutChecked` (server.mjs:12625–12652). With Firebase
configured (`fbEnabled()`, server.mjs:567) each is a separate authenticated HTTPS request from Fly to
the RTDB (`fbReq`, server.mjs:715). Three, serial, before the 200 comes back.

Then `jobTick()` is called inline (server.mjs:12654) — good, this is why the claim is normally
**not** waiting for the 2-second interval. But `jobTick` opens with:

```js
// server.mjs:11946
  if (!dbReady || jobShuttingDown || jobTickBusy || jobRunning.size >= JOB_CONCURRENCY) return;
```

Two ways that inline call silently does nothing:

1. **`jobTickBusy`** — another tick is mid-`jobCtlAll()`. `jobCtlAll()` is a `GET` of the **entire**
   `firasjobs/ctl` node (server.mjs:816), which under `JOB_KEEP_MS = 6 * 3600_000` (server.mjs:9329)
   holds every job record from the last six hours for every user. Two concurrent sends and one of
   them is deferred to the next 2-second tick.
2. **`jobRunning.size >= JOB_CONCURRENCY`** with `JOB_CONCURRENCY = 4` (server.mjs:9328). The slot is
   held for the **whole generation** (`jobRunning.set` at server.mjs:11742 area / `finally` delete in
   `jobTick`). **The fifth concurrent user on the site waits for one of the first four answers to
   finish.** That is exactly "بطيء كلش و يعلك مرات" — it is not slow, it is *queued*, and it looks
   identical from the outside.

Then `runOneJob` (server.mjs:11767) does three more serial Firebase round trips before touching the
model: `jobCtlPatchChecked` (claim), `jobCtlGetChecked` (verify the claim), `jobInGetChecked` (fetch
the body).

### 3.2 The poll is O(n²) in bandwidth

The status handler returns the **entire accumulated answer on every poll**:

```js
// server.mjs:12686 (and again at 12699)
        phase: "processing", text: live._answer || "", reasoning: live._reasoning || "", …
```

The client only keeps the delta (`text.slice(sent)`, app.js:41290) — but the bytes were already
transferred. At `gap()` = 350 ms for the first 10 s, 700 ms to 40 s, 1200 ms after (app.js:41264), a
30-second, 10,000-character answer costs roughly 60–90 polls averaging ~5,000 characters each:
**hundreds of kilobytes to deliver ten**. On the live SSE path the same answer costs 10 KB and one
request. On a phone on Iraqi mobile data this is a first-order cost, and it gets worse the longer
the answer is — which is why long answers "hang".

The credit where it is due: the memory fast path (`jobLocal`, server.mjs:12667) means the poll is
served with zero staleness and zero DB reads, so the *content* is live. The 2.5-second durable-write
throttle in `onProgress` (server.mjs:11812) does **not** hold the reader back. That part is correct.

### 3.3 No timeout on either job request

```js
// app.js:41211
  const start = await fetch("/api/chat/job", { … signal });
// app.js:41284
          const p = await fetch("/api/chat/job?id=" + encodeURIComponent(jobId), { credentials: "same-origin", signal, cache: "no-store" });
```

Neither carries a timeout. `signal` fires only on Stop or the 15-minute guard (app.js:41543). The
code itself acknowledges the failure mode — *"a poll fetch parked on a torn-down iOS socket"*
(app.js:41254) — and handles it only for the Stop button. A parked poll leaves the turn frozen with
the Stop button lit and no error, forever. That is a literal reading of «يعلك».

---

## 4. What blocks the UI thread while the user waits

| Item | Where | Verdict |
|---|---|---|
| `guestSaveChats()` — up to 5 MB serialize + `localStorage.setItem` | app.js:47013, reached from app.js:44584 | **Real block**, every guest send |
| `renderThread` twice per send (sendMessage + runAssistant) | app.js:44575, 44605 | Reconciled + turn-cached; 9 `sync*` passes each. Minor. |
| `syncStreamingUi` → `liveChatIds()` walking all of `localStorage` | app.js:19553, 43944 | **Not** per token — called on stream start/end and navigation only. Not a defect. |
| `paintStreamingMarkdown` | app.js:43813 | Incremental and well cached. **Not** a defect. |
| Per-frame full-string scans at 20 fps: `stripProbSigVisualBlock` + `scrubBacktrackFull` + `splitSettledMarkdown` | app.js:43816, 41667, 43821 | O(n) per frame → O(n²) per reply. Secondary, real on low-end Android. |

---

## 5. Slow / flaky connection

`persistChatRequest` gives each attempt a 6-second abort timer (app.js:3448) and
`persistChatNow` retries **three** times with 900 ms / 1800 ms backoff (app.js:3502). Worst case for
one `persistChat`: **6 + 0.9 + 6 + 1.8 + 6 ≈ 20.7 seconds**, fully awaited, at app.js:42626 — and
again at app.js:44584 on a new chat. During all of it the user sees their own message and a
"typing…" label (app.js:43315) and nothing else. The send has not been dispatched.

`persistChat` also serialises behind any persist already running for that chat (the
`_persistWanted` / `_persistRunner` ladder, app.js:3415–3441) — so a send can additionally wait out
the **previous** turn's finalize PUT.

---

## 6. The fixes, in the order I would land them

Every anchor below was checked with `str.count(...) == 1` against the current file.

### F1 — Take the classifier off the critical path for obvious chat turns
*Anchor (app.js, unique):* `  if (obviousProblemChat) {`
Extend the existing local fast path with a second, narrower one, `obviousPlainChat`: no attachment,
no prior image, `ctx.product !== "code"`, and the message contains **none** of the ten non-chat
kinds' vocabulary in either language (the classifier's own worked-example list is the source:
`أغنية|اغنية|غنيلي|نشيد|لحن|song|sing|صورة|بوستر|شعار|رسم|image|logo|poster|فيديو|مقطع|video|clip|
ملف|وورد|بوربوينت|عرض|اكسل|جدول بيانات|pdf|docx|pptx|xlsx|csv|موقع|تطبيق|برنامج|صفحة|website|web app|
app|code|script`). Return `{kind:"chat", requirements:""}` synchronously. A message with none of
those words cannot be any of the ten non-chat kinds, so the false-negative cost is bounded; the
false-positive cost is zero. This removes a whole cloud completion from the front of most turns.

### F2 — Start the persist at send time so it overlaps the classifier
*Anchor A (app.js:44584, unique):* `if (!chat.serverId) await persistChat(chat).catch(() => {});`
→ `chat._sendPersist = persistChat(chat).catch(() => {});` (no `await`; and start it for an
**existing** chat too, since step 3 needs it either way).
*Anchor B (app.js:42626, unique):*
`if (CHAT_JOB && chat && !isGuest()) { try { await persistChat(chat); } catch (_) {} }`
→ `if (CHAT_JOB && chat && !isGuest()) { try { await (chat._sendPersist || persistChat(chat)); } catch (_) {} chat._sendPersist = null; }`
Same durability guarantee (the transcript is on the server before the job is queued), one fewer
serial round trip, and what remains hides behind the classifier's latency.

### F3 — Poll deltas instead of the whole answer
*Client anchor (app.js:41284, unique):* the poll `fetch("/api/chat/job?id=" …)` — append
`"&from=" + sent`.
*Server anchor (server.mjs, unique):* `async function handleChatJobStatus(req, res) {` — read
`from` from the query and return `text.slice(from)` plus a `textLen` field; the client already
tracks `sent` and already only appends the delta (app.js:41290). Both `phase:"processing"` returns
(server.mjs:12686 and 12699) and the DB return (12712) need the same slice; anchor them via
`const suspicious = live.writableEnded ||` (unique) and the function head to avoid the duplicate.
Turns hundreds of KB into tens.

### F4 — Give every job request a timeout
*Anchors (app.js, both unique):* `  const start = await fetch("/api/chat/job", {` and the poll
`fetch` at 41284. Wrap each in the same pattern `persistChatRequest` already uses (app.js:3447): a
local `AbortController` + `setTimeout`, combined with the outer `signal`. 10 s for the POST, 8 s per
poll — a timed-out poll already falls into the `bad++` retry branch (app.js:41295) and simply polls
again, which is exactly the right behaviour. This is the fix for the frozen-with-Stop-lit hang.

### F5 — Separate the interactive lane from the long-job lane
*Anchor (server.mjs, unique):* `const JOB_CONCURRENCY = 4;`
Four slots shared between ordinary chat turns and `longdoc` / `longfile` / `agentrun` / `codebuild`
means one 10-minute document build eats a quarter of the site's chat capacity. Add
`JOB_CHAT_CONCURRENCY` (say 12) counted separately for `kind === "chat"`, and keep 4 for the heavy
kinds; guard at `if (!dbReady || jobShuttingDown || jobTickBusy || jobRunning.size >= JOB_CONCURRENCY) return;`
(server.mjs:11946, unique) by splitting the count per kind.

### F6 — Do not let `jobTickBusy` swallow a brand-new job's claim
*Anchor (server.mjs:12654, unique):* `  jobTick();   // start now rather than waiting for the next tick`
Replace with a direct `runOneJob(durableRec)` guarded by the concurrency check, so the new job never
depends on winning a race with a full `jobCtlAll()` scan. The periodic tick stays for recovery and
pruning.

### F7 — Move the silent web search off the pre-answer path
*Anchor (app.js:42478, unique):* `const results = await fetchWebSearch(query, silentSearch ? 1500 : 8000);`
The inclusion rule `worldly` (app.js, anchor `const worldly = /[A-Z][a-z]{2,}/.test(s)`) fires on any
capitalised English word ≥3 letters and on the Arabic nouns `نظرية|تاريخ|كتاب|عالم|مرض|علاج|دولة|
مدينة|جامعة` — i.e. on most of what a student asks. Either (a) drop `نظرية|تاريخ|كتاب|عالم` and the
bare-capital rule from `worldly`, or (b) for `silentSearch` only, do not await: start the fetch,
dispatch the generating request immediately, and inject the results into a *follow-up* turn if they
land. (a) is the one-line version.

### F8 — Defer `autoTitleChat` until after the answer starts
*Anchor (app.js, unique):* `if (!firstFileFmt) autoTitleChat(chat, firstTitleText);`
Wrap in `setTimeout(..., 0)` is not enough — it needs to be after the generating request is
dispatched, so move the call into `runAssistant` after `beginStreaming(chat.id)`, or gate it on the
first token. It currently contends with the classifier for the same pool on exactly the turn where
latency is most visible (a brand-new chat).

### F9 — Keep `guestSaveChats` off the send path
*Anchor (app.js:44584, same line as F2's anchor A):* for a guest, the localStorage write does not
need to complete before `runAssistant`. Schedule it (`setTimeout(..., 0)` or an idle callback) and
keep the synchronous write only for `pagehide`, which is the reason the comment at app.js:3411 gives
for it being synchronous in the first place — that reason applies to the unload path, not to send.

---

## 7. Complaints with no defect behind them (on this path)

- **The streaming paint is not the problem.** `paintStreamingMarkdown` (app.js:43813) reuses settled
  DOM, appends only newly-closed blocks, and reconciles the live tail. `syncStreamingUi` is not
  called per token. If the app feels janky mid-answer, on this evidence it is the 350 ms poll
  quantisation and the poll payload size (F3), not the renderer.
- **The 2.5-second durable-write throttle does not hold the reader back.** `handleChatJobStatus`
  serves from `jobLocal` memory (server.mjs:12667), which carries `_answer` live. The throttle only
  governs how often the answer is checkpointed to storage.
- **`KB_IN_CHAT` is off unless the env var is `"1"`** (server.mjs:12814), so the synchronous
  `kbSearch` scan over every chunk (server.mjs:7920) is not currently on the path. Worth watching if
  it is ever turned on — it is a blocking CPU scan on the single 512 MB machine's event loop.
- **Song generation exists and works.** The pipeline is at app.js:41855–42046 (lyric author →
  `firas-music` fence). It only ever fires when `turnKind === "song"`, or when the classifier was
  *unreachable* and `songAskedPlainly` matches (app.js:41839). So «سوالي كلمات ما سوة اغنية» is a
  **classifier verdict** defect, not a missing feature — and it is downstream of the same call F1
  touches. Out of scope for this pass; flagged for whoever owns the classifier prompt.
