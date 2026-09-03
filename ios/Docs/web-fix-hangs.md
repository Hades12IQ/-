# Firas AI — why it stalls and freezes

Read-only investigation, lens = **the freezes ("يعلك")** and the send stall.
Branch `night/capabilities-and-code-ui`, `app.js` 5,796,169 bytes (the deployed body).

Every number below was **measured**, not read. Method and instruments are in §7 so the next
person can re-run me. Where I looked hard and found nothing, I say so (§6) — three of my
starting hypotheses died and they are listed there rather than quietly dropped.

---

## 0. The one-paragraph answer

**The streaming stopped being streaming.** Chat answers no longer arrive over the SSE socket
they used to; they arrive by the browser **polling `/api/chat/job` every 350 → 700 → 1200 ms**
and, on every poll, **re-downloading the entire answer written so far**. Before the first poll
can even happen, the send path awaits **a full Pro-tier model completion** (the intent
classifier) plus **two `persistChat` round-trips**. So: press send → 1–3 s of nothing → text
appears in bursts → after 40 s the screen is frozen for **1.2 s at a time** between bursts.

That is complaints 1, 2, 8 and 9 in one mechanism, and it is a *regression* in exactly the sense
the owner reports: the durable-job rewrite (cloud-first, correct in intent) replaced a token
stream with a poll loop and nobody re-tuned the cadence or added a delta.

The client-side main-thread work is a **secondary** problem — real, worth fixing, but 10× smaller
than the above. The markdown/stream painter is genuinely fast (measured, §6.1); the expensive
client work is `renderHistory()` rebuilding the whole sidebar twice per turn.

---

## 1. CRITICAL — the send stall (`يوكف ويشتغل يرد`)

### 1.1 A Pro model completion is awaited before the answer request

`app.js:41569`, inside `streamAnswer`:

```js
  const turnKind = lastUserTurn
    ? await classifyTurnIntent(lastUserTurn.content, {
```

`classifyTurnIntent` → `_classifyTurn` (`app.js:4132`) → `callAgentText([...], "pro", signal)`
(`app.js:4273`). `callAgentText` (`app.js:38820`) is a real `fetch` to `CONFIG.BACKEND_URL` whose
SSE body is **drained to completion** before it returns.

**Measured:** the classifier system prompt is **8,162 characters ≈ 2,330 tokens**
(`scratchpad/promptsize.py`). It is sent with up to 6,000 characters of the user's message, to the
*Pro* tier, on **every single message**, and the answer request cannot start until it resolves.

The only fast path is `obviousProblemChat` (`app.js:4142`) — problem-set requests. "اشرح لي…",
"شنو يعني…", any ordinary question pays the full round-trip.

The code's own comment at `app.js:4122` concedes the cost: *"an ordinary member turn already fires
FIVE completions, and every second spent before the stream opens is subtracted from the
generation's own budget"*.

**Fix.** Stop blocking on it. Two moves, both cheap:

1. **Start the answer immediately and let the classifier race.** The classifier only *steers*
   (image / video / song / file / code). Move the `await` behind a `Promise.race` with a
   ~400 ms timer: if it has not answered by then, take the local `detectImageRequest` /
   `detectCodeRequest` / `detectFileRequest` verdict already in the file and open the stream.
   Keep the promise in `_turnIntentCache` so `turnRequirementsOf` still gets the real answer for
   the *next* turn.
2. **Warm it from the composer.** There is already a comment at `app.js:50592` saying "THE
   CLASSIFIER WARMS WHILE THEY TYPE" — verify that path actually fires on the same cache key
   (`(flags + product + text.slice(0,6000))`, `app.js:4158`). If the warm call keys on a different
   prefix than the send does, the cache misses and the warm-up buys nothing.

Replacement idea, at `app.js:41569`:

```js
  const _kindP = lastUserTurn ? _classifyTurn(lastUserTurn.content, ctx, signal) : null;
  const turnKind = lastUserTurn
    ? await Promise.race([
        _kindP.then((r) => r.kind),
        new Promise((r) => setTimeout(() => r(localTurnKindGuess(lastUserTurn.content, ctx)), 400)),
      ])
    : "chat";
```

`localTurnKindGuess` must be **written from the existing detectors** — do not invent it; the
detectors that exist are `detectImageRequest`, `detectImageEditRequest`, `detectCodeRequest`,
`detectFileRequest`, `detectVideoRequest` (grep each before use).

### 1.2 Two awaited `persistChat` round-trips sit in front of the request

- `app.js:44570` in `sendMessage`: `if (!chat.serverId) await persistChat(chat).catch(() => {});`
- `app.js:42626` in `streamAnswer`: `if (CHAT_JOB && chat && !isGuest()) { try { await persistChat(chat); } catch (_) {} }`

The second one PUTs the **whole chat, all messages**, before the job is created. On a 40-turn
conversation that is a multi-hundred-KB upload on an Iraqi mobile uplink, in the critical path of
every message.

**Fix.** The reason for `app.js:42626` (comment above it) is that a browser dying mid-answer must
not lose the question. That is satisfied by sending the *question* rather than the *chat*: the job
body already carries `messages`, and `handleChatJobStart` already stores it (`jobInPutChecked`,
`server.mjs:12623`). Make this call fire-and-forget (`persistChat(chat).catch(() => {})` with no
`await`) and let the job record be the durable copy of the question. Keep `app.js:44570` awaited
only when `!chat.serverId` — it already is — but move it *above* `renderThread` so the round-trip
overlaps the paint instead of following it.

---

## 2. CRITICAL — the poll loop is why it "hangs" mid-answer

### 2.1 The cadence

`app.js:41241`, inside `fetchChatJob`:

```js
  const gap = () => { const e = Date.now() - pollStart; return e < 10000 ? 350 : (e < 40000 ? 700 : 1200); };
```

There is no token stream. `fetchChatJob` fabricates a `ReadableStream` whose `pull` polls
`GET /api/chat/job?id=` and enqueues whatever grew since last time (`app.js:41290–41297`).
The server confirms the design in its own words at `server.mjs:9317`: *"The client polls
GET /api/chat/job?id= for the growing text (a streaming-like feel)"*.

And the reveal controller does **not** smooth it out: `app.js:43513`

```js
const SMOOTH_STREAM_CHARACTER_REVEAL = false;
```

so `push()` paints the whole delta in one frame (`app.js:43597`). The visible result is: a burst,
then **1.2 seconds of a completely motionless screen**, then another burst. On a phone that is
indistinguishable from a hang. This is `يعلك`.

Add the network: the machine is `shared-cpu-1x` / **512 MB** in **`fra`** (`fly.toml`), serving
Iraq. A 250–400 ms real-world RTT means the *effective* gap is 600 ms early and **1.5–1.6 s** late.

**Fix (client, `app.js:41241`).** Poll fast and keep polling fast — the poll is served from process
memory (`jobLocal`, `server.mjs:12667`) at zero DB cost, so the server does not need the backoff:

```js
  const gap = () => { const e = Date.now() - pollStart; return e < 60000 ? 400 : 900; };
```

and re-enable paced reveal so a burst *draws* as motion rather than a jump: set
`SMOOTH_STREAM_CHARACTER_REVEAL = true` at `app.js:43513`. `smoothStreamBudget`
(`app.js:43500`) already returns `min(160, gap/8)` chars per 50 ms frame, which drains a 400-char
burst in ~5 frames (250 ms) instead of one — continuous motion between polls instead of
stop-motion. Measured cost of that extra painting: **negligible** (§6.1 — 79 ms of CPU for a
15,309-char answer across 60 frames).

### 2.2 Every poll re-downloads the entire answer — O(n²) bandwidth

`server.mjs:12684` (and the identical branch at `:12697`):

```js
        phase: "processing", text: live._answer || "", reasoning: live._reasoning || "", error: "", status: 0,
```

The full accumulated answer, every poll. The client then does `text.slice(sent)`
(`app.js:41296`) and throws the rest away.

**Measured amplification** (arithmetic over the real cadence in `gap()`):

| answer | duration | polls | bytes transferred | amplification |
|---|---|---|---|---|
| 3,000 chars | 25 s | ~55 | ~82 KB | **27×** |
| 20,000 chars | 90 s | ~110 | ~1.1 MB | **55×** |

Every byte of that is on the student's mobile data, on the critical path of the answer they are
waiting for, and each poll's `await p.json()` (`app.js:41293`) parses the whole thing again.

**Fix.** Add a `since` offset. Client, `app.js:41293`:

```js
          const p = await fetch("/api/chat/job?id=" + encodeURIComponent(jobId) +
                                "&since=" + sent + "&sinceR=" + sentR,
                                { credentials: "same-origin", signal, cache: "no-store" });
```

Server, `server.mjs:12684` and `:12697`, slice before sending and tell the client where it
started:

```js
        phase: "processing", from: since, text: (live._answer || "").slice(since),
        fromR: sinceR, reasoning: (live._reasoning || "").slice(sinceR), error: "", status: 0,
```

Client then appends when `j.from === sent`, and falls back to the current
`text.length > sent` full-replace logic when `j.from` is absent — which keeps an old client
working against a new server and vice versa. **Note the parity obligation:**
`netlify/edge-functions/api.js` has no `/api/chat/job` route at all (the client already handles
that with the 404→stream fallback at `app.js:42679`), so nothing to mirror there.

Also add `since` to the allow-list in `handleChatJobStatus` if it validates query keys the way
`handleChatJobFile` does at `server.mjs:12425` — grep before assuming.

### 2.3 A second, redundant polling loop runs on top of the first

`app.js:2681` `watchPendingAnswer` arms `setInterval(…, 5000)` while a chat owes an answer. Each
tick calls `refreshActiveChatOnReturn()` → `refreshChatFromServer(chat, { poll: true })`, and at
`app.js:2559`:

```js
  const tries = poll ? 16 : 1;                                // ~16 × 2.5s ≈ 40s, matches a slow render
```

That is a loop of **16 fetches of the entire chat** (`/api/chats/<sid>`, all messages) over 40 s —
running *concurrently with* the 350 ms job poll for the same answer. On a 40-turn conversation
that is another ~1.6 MB.

**Request rate per streaming user:** ~2.9/s (job poll, first 10 s) + 0.2/s (`watchPendingAnswer`)
+ 0.07/s (version watch, §3) ≈ **3.2 requests/second**. Thirty students in one classroom ⇒
**~90 req/s** against one shared-CPU 512 MB machine that is simultaneously running up to
`JOB_CONCURRENCY = 4` model generations (`server.mjs:9327`). That is the "many users say it's
slow and it hangs" complaint, mechanically.

**Fix.** `watchPendingAnswer` exists as a backstop for a *wedged* poll loop, not as a parallel
one. Gate it on the job poll being absent or stale: at `app.js:2686` it already reads
`localStorage.getItem("firas_job_" + chat.id)`. Invert that test — skip the refresh entirely when
an `activeStreams` entry for this chat still has a live `jobId`
(`activeStreams.get(chat.id).jobId`, set at `app.js:41221`), and raise the interval from 5000 to
20000. Also drop `tries` from 16 to 4 at `app.js:2559`.

---

## 3. MAJOR — a forever-timer hitting the server every 15 s per tab

`app.js:50820`, in `startVersionWatch`:

```js
  setInterval(check, 15000);
```

Never cleared, never backed off, and **not paused when the tab is hidden**. Every open tab —
including the twenty a classroom leaves in the background — fetches `/api/version` four times a
minute forever.

**Fix.** Two lines. Skip the check when `document.hidden`, and lengthen the period:

```js
  const check = async () => { if (document.hidden) return; … };
  setInterval(check, 60000);
```

plus a `document.addEventListener("visibilitychange", () => { if (!document.hidden) check(); })`
so a returning tab still learns about a deploy promptly.

---

## 4. MAJOR — `renderHistory()` rebuilds the whole sidebar twice per turn

`app.js:19022`, in `renderHistory`:

```js
  const list = els.historyList;
  list.innerHTML = "";
```

Every row is destroyed and rebuilt from scratch. It is called **on every send**
(`app.js:44551`) and **on every finalize** (`app.js:43148`, inside `finalizeAi`), plus on every
title edit, pin and delete.

**Measured** (real Chrome, real `styles.css`, 200 conversations — `__probe2.js`, §7):

```
chatItemEl × 200 :  build 21.2 ms  +  insert/layout 19.7 ms  =  40.9 ms
```

That is desktop. A mid-range Android is 5–6× slower on DOM construction ⇒ **200–250 ms**, twice
per turn — before `renderFolders`, `renderResumeStrip`, `renderPinnedStrip`, `ctgBar` and `bsBar`,
which all run in the same pass. A quarter-second stutter on send and another on finalize is
exactly the kind of thing that reads as "مو سلس".

**Fix.** `renderThread` already solved this problem for turns — reconcile in place
(`app.js:22307–22323`, `turnNodeFor`). Do the same here:

1. Memoize the row. `chatItemEl(c, g)` is pure in `(c.id, c.title, c.pinned, c.updatedAt, g,
   state.lang)`. Cache the node on the chat object under a key built from those, exactly the way
   `turnNodeFor` keys its memo, and return the cached node when the key is unchanged.
2. Replace `list.innerHTML = ""` with the same insert-before reconcile loop `renderThread` uses,
   so an unchanged row is never touched.

The narrow version, if the full reconcile is too big a change for one patch: at the two hot call
sites only (`app.js:44551` and `app.js:43148`), replace the full `renderHistory()` with a targeted
`touchChatRow(chat)` that updates just that row's stamp and re-sorts it into position. Both call
sites exist only to reflect `updatedAt` ordering — they do not need the folders, the colour bar or
the resume strip rebuilt.

---

## 5. MEDIUM — redundant full-string re-scans on every streaming frame

`paintAnswerFrame` (`app.js:41640`) runs ~20×/s and re-scans the **entire answer so far** three
separate times, each time producing a result that is almost always identical to the last frame's:

| call | site | measured, desktop |
|---|---|---|
| `scrubBacktrackFull(shownAnswer)` | `app.js:41665` | 0.1 ms clean / **0.7 ms** when `BACKTRACK_RE` hits (17,925 chars) |
| `midStreamCodePromotion(shownAnswer)` | `app.js:41647` | **1.0 ms** at 86,754 chars |
| `splitSettledMarkdown` → `mdConstructsClosed` | `app.js:43723` / `43702` | **0.7 ms** at 25,268 chars with an open fence |

≈ **2.4 ms/frame** on desktop ⇒ **12–15 ms/frame** on a mid-range Android, ~25–30 % of the 50 ms
frame budget, spent recomputing yesterday's answer. It is not the freeze on its own, but it is the
tax that makes everything else's jank visible.

Three concrete fixes:

**5.1 `midStreamCodePromotion` — stop re-running it after it latches.** `app.js:41647`:

```js
    const autoBox = (codeReq || fileFmt) ? null : (midStreamCodePromotion(shownAnswer) || boxLatched);
```

`||` evaluates the left side first, so the full `promoteAnswerToCode` + `parseCodeMeta` chain
(6 full string copies plus a `code.split("\n")` at `app.js:6621`) runs on every frame *even after
the box is latched*. Re-order and throttle:

```js
    const autoBox = (codeReq || fileFmt) ? null
      : (boxLatched || ((shownAnswer.length - (aiMsg._promoAt || 0) > 2000)
          ? ((aiMsg._promoAt = shownAnswer.length), midStreamCodePromotion(shownAnswer))
          : null));
```

The gate is monotonic in practice (`boxLatched` never un-latches in this function), so re-checking
every 2,000 new characters instead of every frame changes nothing visible and removes ~95 % of the
calls. `_promoAt` is view state — delete it in `finalizeAi` beside the existing
`if (aiMsg._boxLatched) delete aiMsg._boxLatched;` at `app.js:43134`.

**5.2 `scrubBacktrackFull` — only rescan the tail.** `app.js:36808` already has a fast path
(`if (!BACKTRACK_RE.test(text)) return text`), so a clean answer is cheap. The expensive case is
an answer that *did* backtrack once: from then on every frame pays 0.7 ms re-splitting the whole
thing into sentences. Cache on the painter: keep `{src, out}` on `aiMsg._scrubMemo` and skip the
work when `src` is a prefix of the new text **and** the new suffix contains no `BACKTRACK_RE`
match — then return `memo.out + suffix`.

**5.3 `mdConstructsClosed` — hoist the two string copies.** `app.js:43705–43706`:

```js
  const noFence = head.replace(/```[\s\S]*?```|~~~[\s\S]*?~~~/g, "");
  if ((noFence.match(/\$\$/g) || []).length % 2) return false;      // inside display math
```

`head` is a *prefix* that only grows, and `splitSettledMarkdown` (`app.js:43733`) can call this
once per blank-line boundary in a single frame. Make the four parity counts incremental: cache
`{len, fences, dollars, inlineMath, ticks}` on the `mdEl` alongside `_streamCache` and, when the
new `head` starts with the cached one, count only the added suffix. Same answers, O(delta) instead
of O(n) — and it removes the two whole-string `.replace()` allocations per call.

---

## 6. What I checked and did NOT find (do not re-hunt these)

These are ruled out **by observation**, not by reading.

**6.1 The streaming markdown painter is fast.** I drove the *real* `paintStreamingMarkdown` +
`scrubBacktrackFull` + `typesetMath` (real marked, real DOMPurify, real KaTeX) over a growing
Arabic answer with inline and display math in the loaded app:

```
chars   frames  paint med / max / total   math med / max / total   CPU total
1,529     59     0.30 / 11.2 /  42 ms      0.20 / 5.3 /  15 ms       57 ms
3,824     60     0.50 /  1.0 /  29 ms      0.20 / 0.7 /  12 ms       41 ms
7,649     60     0.60 /  3.2 /  40 ms      0.20 / 0.6 /  14 ms       53 ms
15,309    60     1.10 /  1.6 /  59 ms      0.40 / 0.5 /  20 ms       79 ms
```

**79 ms of total main-thread CPU for a 15,309-character answer.** The incremental reconcile
(`reconcileStreamNode`, `app.js:43774`) works. KaTeX during streaming is not a problem. Do not
"optimise the renderer" — the number is already there.

**6.2 No catastrophic-backtracking regex exists.** I extracted every regex *literal* in `app.js`
(`scratchpad/rescan.py`) and filtered for nested-quantifier shapes `(…[+*]…)[+*]` and `)[+*][+*]`.
**Six candidates, all false positives** (five were `/` in prose or string concatenation; the real
one, `/\bFiras(?:\s+Firas)+\b/gi` at `app.js:56146`, is linear). The big Arabic alternations are
alternations, not nested quantifiers — O(n·k), not exponential. I could not construct a blow-up
input.

**6.3 `liveChatIds()` is no longer the problem.** Measured against a synthetic store
(`__probe2.js`): **0.4 ms at 808 localStorage keys**, 0.0 ms at 108. It is also no longer called
per stream tick — `paintRailBadges` runs from `syncStreamingUi` and a handful of job-completion
sites (`app.js:19160, 41471, 41479, 43946, 58663, 59362, 60497`), not from the paint loop. The
comments at `app.js:2413/2432/41229` describing it as a per-tick sweep are **stale**; the fix
already landed.

**6.4 No layout thrash from the scroll path.** With a real 60-turn thread in the real scroller
(scrollHeight 42,320 px), `scrollToBottom()` and `updateScrollBtn()` both measured **0.0 ms**
median (`__probe3.js`). Chrome's incremental layout absorbs it. The `el.scrollTo` +
`requestAnimationFrame` pattern at `app.js:35860` is fine.

**6.5 `autoDirBlocks` is small, but its unconditional write is still worth fixing.** Measured
0.80 ms/frame on a 200-block / 44,519-char answer, 0.1–0.3 ms on a realistic 48-paragraph one;
a memoised variant that skips unchanged blocks measured 0.000 ms. It is called per frame from
`paintStreamingMarkdown` (`app.js:43818`) and writes `dir` on every block whether or not it
changed (`app.js:87929`). Cheap fix, small win — worth folding into §5 rather than its own patch:
compare before writing, and count Arabic/Latin with a `charCodeAt` loop instead of two `.match(/…/g)`
calls that allocate one string per matching character.

```js
    const want = ar || la ? (la > ar * 1.5 ? "ltr" : "rtl") : fallback;
    if (el.getAttribute("dir") !== want) el.setAttribute("dir", want);
```

**6.6 MutationObservers are bounded.** All 11 are either one-shot (`tclampWatchContent` at
`app.js:7442`, capped at 3 runs), `childList`-only on a container that changes once per turn
(`app.js:16931–16932`, debounced 200 ms), or scoped to a Firas Code panel. None observe `subtree`
on the thread, so none fire per streaming frame.

**6.7 Timers are mostly conditional.** 19 `setInterval` sites; 16 are armed only while a feature
is live (mic, call, read-aloud queue, mission watch, code run bar) and clear themselves. The two
unconditional ones are `startVersionWatch` (§3) and the job worker on the server side. `boot`
long-task measured **74 ms** on desktop (one long task, warm cache) — meaningful on Android
(~400 ms) but not the multi-second freeze; that is a §3-of-someone-else's-report problem.

---

## 7. How to re-run me

Everything above was measured against the real files, two ways.

**Node, for pure functions.** Extract the exact line range from `app.js` and benchmark:

```
python -c "src=open(r'D:\Programming\Projects\FirasAI\app.js',encoding='utf-8').read().split('\n'); \
           open('promo.js','w',encoding='utf-8').write('\n'.join(src[6549:6662]))"
node promo.js
```

**Real browser, for anything touching the DOM.** Serve the repo statically (no secrets needed —
`app.js` loads and every top-level `function` lands on `window`; the API 404s are harmless):

```js
// scratchpad/serve2.mjs — 12-line static server on :1992, root = the repo
```

then in the page:

```js
document.getElementById('appShell').hidden = false;   // else nothing has layout and every timing reads 0
const src = await (await fetch('/__probe2.js')).text(); eval(src);
```

The probe scripts used are `scratchpad/probe1.js` (streaming pipeline), and `__probe2.js` /
`__probe3.js` (sidebar rows, localStorage sweep, per-frame scans, scroll cost) — both written to
the repo root to be served, and **both deleted afterwards**; `git status` is clean of them.

Caveats I am obliged to state: every millisecond above is **desktop Chrome on a fast machine**.
Where I extrapolate to "a mid-range Android" I say so and use a 5–6× factor, which is a
*convention*, not a measurement — nobody has run this on the target hardware, and that is the
single most valuable measurement still missing. All timings are medians of n≥20 except the
streaming pipeline (n=60 frames per size). Theme = dark, direction = Arabic content in an LTR
shell, auth = signed-out (the shell was force-unhidden).

---

## 8. Order to fix in

1. **§1.1** classifier off the critical path — biggest single win on "press send, nothing happens".
2. **§2.1** poll cadence + re-enable paced reveal — turns stop-motion back into streaming.
3. **§2.2** `since` offset on the poll — kills the O(n²) mobile-data burn.
4. **§2.3 + §3** stop the two redundant polling loops — takes ~40 % off the request rate that is
   flattening the 512 MB machine when a class is online.
5. **§4** sidebar reconcile — removes the quarter-second stutter twice per turn.
6. **§5** per-frame rescans + **§6.5** — the polish pass.

1–4 are latency and cost nothing in risk; 5–6 are main-thread and want `patch-script-authoring`
discipline because they touch `paintAnswerFrame` and `renderHistory`, both of which sibling
patches like to move.
