# Agent · Code · Brain — why they feel laggy and stuck

Read-only pass over `D:\Programming\Projects\FirasAI\app.js` (5,796,169 bytes) and
`D:\Programming\Projects\FirasAI\server.mjs` (807,839 bytes) on branch
`night/capabilities-and-code-ui`.

Every claim below carries a file and a line. Nothing here was run in a browser — this machine has
no live session against firasai.org — so per the house rule each finding is marked **READ** (traced
in the source, condition named) rather than **RAN**. Where I could not find a defect behind a
symptom, I say so instead of inventing one (§6).

---

## 0. The three flows, end to end

### Firas Agent (durable server mission)

```
runAgentAssistant()                       app.js:59545
  → chargeUsage("agent", chat._missionCid)
  → agentServerRun(chat, aiMsg, task…)    app.js:59406
      POST /api/chat/job  {kind:"agentrun"}
      localStorage "firas_job_<chatId>"  +  agJobRemember()      app.js:58615
      aiMsg.content = serializeAgentRun(initial); renderThread()
      → agWatchServerRun(chatId, jobId, cid, sid)                app.js:58697
  ← returns true
  → activeStreams.delete(chat.id); endStreaming(chat.id)         app.js:59762-59770
  → return                                                       app.js:59768

agWatchServerRun:
  connectStream()  →  EventSource /api/agent/job-stream          app.js:58930
     server: handleAgentJobStream                                server.mjs:12183
       publish(initial) immediately, then agentJobStreamSubscribe + 80 ms coalesce
       + 1250 ms fallback wake + sha256 dedupe of the whole payload
  onerror → startPolling(0) → runPoll every 700 ms while visible app.js:58906
  every snapshot → queueSnapshot → applySnapshot                 app.js:58767
```

The server side of the agent is genuinely good: the first snapshot is **immediate**
(`publish(initial)`, server.mjs:12277), frames are coalesced at 80 ms and de-duplicated by hash, a
`terminal` event closes the stream, and the client's `wakeViewer` (app.js:58962) debounces the
visibility/focus/online/pageshow burst into one authoritative catch-up. The problems are all on the
client's *repaint* side and in the *controls* around it.

Publish cadence in practice: `runAgentJob` → `agentTwinManus` polls Manus every
`MANUS_POLL_MS = 1500` (server.mjs:8516) and calls `publish("run")` on each tick
(server.mjs:10995-11001). `job.live` grows almost every tick, so the payload hash changes and
**a snapshot reaches the browser roughly once every 1.5 s for the whole mission** — 200 snapshots
for a five-minute mission, 1,200 for a thirty-minute one.

### Firas Code (server build)

```
Build pressed (home screen)               app.js:~61650
  createCodeProject(blank scaffold); cwState.renderedChat=""; renderAll()
  → codeServerBuild(liveChat, projName, desc, attCtx)            app.js:60529
      POST /api/chat/job {kind:"codebuild"}
      localStorage "firas_job_<chatId>" + cwJobRemember()
      → cwWatchServerBuild(chatId, jobId, name, sid)             app.js:60434
  ← true → showToast(cwPlanT().srvKeep); return                  app.js:61679

cwWatchServerBuild: while (< CW_JOB_MAX_MS)
   GET /api/chat/job?id=…                (first request is immediate — good)
   parse ```firas-project fence out of j.text
   codeSaveFiles(target, …)              app.js:60484  → persistChat() → network PUT
   if (activeChat()===target) { cwState.renderedChat=""; renderAll(); }   app.js:60486
   sleep 4000 ms
```

### Firas Brain (ask + import)

```
brainAsk(q)                               app.js:86712
  brainState.ctl = new AbortController()
  brainRenderThread(chat,{pending: thinking}); renderHistory()
  wholeKind = "" for an ordinary question  → NOT null            app.js:86779-86784
  → brainRenderThread(chat,{pending: LQ.wholeReading})           app.js:86786
  → await apiJson("/api/brain/whole", …)                         app.js:86789
        server: handleBrainWhole                                 server.mjs:8974
        corpus up to BRAIN_WHOLE_MAX_CHARS = 2,600,000 chars     server.mjs:9046
        → minimaxChat(…, {maxTokens: 8192})   ONE blocking call  server.mjs:9083
  … only if that declines does /api/brain/search + the streaming answer run

brainUploadFile(file)                     app.js:85421
  onPhase = (phase,done,total) => { …; brainRenderRail(); }      app.js:85429-85432
  extractBrainPages()                     app.js:85292
     extractBrainPdfPages  (main thread, yields every 12 pages)  app.js:84764
     mapWithLimit(todo, 3, brainRasterizePage → brainOcrPage)    app.js:85347
```

---

## 1. CRITICAL — Firas Code tears the whole IDE down and rebuilds it every 4 seconds

**app.js:60486**

```js
                if (activeChat() === target) { cwState.renderedChat = ""; renderAll(); }
```

`cwState.renderedChat = ""` is the exact assignment that defeats the "already mounted" guard in
`renderCodeIDE`:

```js
  if (cwState.renderedChat === chat.id && root.querySelector(".cw")) { cwRelocalizeWorkspace(…); … return; }   // app.js:75359
  …
  cwState.renderedChat = chat.id; cwState.file = 0; cwState.cm = null; cwState.cmFallback = null;              // app.js:75361
  root.innerHTML = '<div class="cw cw--v3 cw--v5 cw--v6">…'                                                    // app.js:75365
  …
  cwState.cm = window.CodeMirror.fromTextArea(ta, {…})                                                         // app.js:75473
```

So on **every 4-second tick of a server build**, while the user is looking at the project:

- `renderAll()` (app.js:20128) runs `renderProductRail`, `csSyncBar`, `renderInspector`,
  `renderHistory` and fourteen `sync*` calls before it even reaches the Code branch.
- `renderCodeWorkspace()` → `renderCodeIDE()` blows away `root.innerHTML` and builds the whole
  workspace shell again.
- A **new CodeMirror instance** is created with `fromTextArea` (behind an `await ensureCodeMirror()`,
  so there is also a frame with a bare `<textarea>` on screen).
- `cwState.file = 0` — the user's file selection jumps back to the first file.
- The preview `<iframe>` is a brand-new element, so it reloads from scratch.
- The console pane, the tree, the dock and the map are all rebuilt; `cwDockFit` is re-scheduled.

Anything the user was doing — caret position, editor scroll, text selection, an open palette, a
scrolled console — is destroyed four times a minute for the whole build. This is the single most
"broken-looking" behaviour in the three products and matches the owner's «هيج يعلس، احس تهنيجه بي»
exactly.

**The repo already owns the correct mechanism and this call site bypasses it.** `cwLivePush(files,
owner)` (app.js:64020) exists for precisely this: it is visibility-gated (`cwLiveSchedule`,
app.js:64045), in-flight guarded, coalesces to the newest set, and repaints *only* the preview
iframe. It is used by the in-tab builder at app.js:63412 and by nothing else.

**Fix.** Replace app.js:60486 with the incremental path:

```js
                if (activeChat() === target) {
                  try { cwLivePush(proj.files, target.id); } catch (_) {}
                  const cwRoot = document.getElementById("codeWorkspace");
                  if (cwRoot && cwState.renderedChat === target.id) {
                    try { cwRenderTree(cwRoot, target); } catch (_) {}
                    try { cwUpdateStatus(cwRoot, target); } catch (_) {}
                  } else { cwState.renderedChat = ""; renderAll(); }
                }
```

`cwLivePush`, `cwRenderTree` and `cwUpdateStatus` all exist and are called elsewhere
(app.js:63412, 75458, 75351). The `else` keeps the old behaviour for the one case that genuinely
needs a mount (the project is not the rendered one yet). Anchor `if (activeChat() === target) {
cwState.renderedChat = ""; renderAll(); }` occurs **exactly once** in app.js.

---

## 2. CRITICAL — pressing Build in Firas Code shows a blank project and one toast

**app.js:61679**

```js
        if (served) { showToast(cwPlanT().srvKeep); return; }
```

The path above it (app.js:~61657) creates the project from `CW_BLANK_FILES` — a one-file
`index.html` that says «ابدأ البناء 👋» — and calls `renderAll()`. Then the build is handed to the
server and the function **returns**. There is no `cw-live` card, no plan board, no elapsed clock,
no "building" state on the workspace.

Compare the in-tab path, which mounts a full live card with a spinner, a task list and a Stop
button (`drawHead` / `cwTaskList`, app.js:63102-63122). The server path — the *default*, because
`codeServerBuild` is tried first (app.js:61670) — gets a toast that disappears in a few seconds and
a project that looks empty.

For the first ~30-60 seconds (before the first file fence lands) the user is looking at a blank
scaffold with nothing moving. They reasonably conclude it did not work. Then §1 starts flashing the
editor at them every 4 seconds.

**Fix.** Mount the existing `cw-live` block for the server path too, driven off
`cwWatchServerBuild`'s poll instead of the in-tab controller. Concretely: at app.js:61679 replace
the bare `return` with a call that creates the block (`let el = list.querySelector(".cw-live")` …
app.js:62717) in "server build" mode — headline `cwPlanT().srvKeep`, spinner on, Stop wired to
`POST /api/chat/cancel {id: jobId}` + `cwJobForget(chat.id, chat.serverId||"", jobId)` — and have
`cwWatchServerBuild` update its row count from `proj.files.length` on each tick. The Stop endpoint
already exists and is what `stopStreaming` uses (app.js:44029).

---

## 3. CRITICAL — a running Firas Agent mission has no Stop control anywhere

**app.js:59762-59770**

```js
  if (typeof agentServerRun === "function") {
    const started = await agentServerRun(chat, aiMsg, task, replyLang, tier);
    if (started) {
      const currentStream = activeStreams.get(chat.id);
      if (!currentStream || currentStream.controller === controller) {
        activeStreams.delete(chat.id);
        endStreaming(chat.id);
      }
      return;
    }
  }
```

`endStreaming` → `syncStreamingUi` (app.js:43944) reads `activeStreams.get(_ac.id)`; with the entry
deleted, `stoppable` is false and the composer button loses `is-stop`:

```js
    els.sendBtn.classList.remove("is-stop");   // app.js:43972
```

And `stopStreaming` (app.js:44005) returns immediately for the same reason — `const s =
activeStreams.get(chat.id)` is undefined, so nothing is aborted and `/api/chat/cancel` is never
posted (the `jid` block at app.js:44026 is reached, but the function has already been made
unreachable by the missing button).

Nor is there a stop inside the card: `buildAgentCard` (app.js:53329) draws the steer row
(app.js:53393) and the fc panel, and grep for a stop affordance in the agent card returns nothing.

So a mission that runs for twenty minutes, holds the user's credits reserved, and blocks every
further agent request with `agent_busy` (app.js:59432) **cannot be stopped by the user at all**.
The only way out is to wait. That reads as "it's hung".

**Fix.** Two parts.

1. Keep the composer's Stop alive for the mission. At app.js:59766 replace the delete with a
   viewer-only marker so `syncStreamingUi` still shows a stop:
   `activeStreams.set(chat.id, { aiMsg, jobId, agentJob: true });` and add an `agentJob` branch to
   `stopStreaming` that posts `/api/chat/cancel {id: s.jobId}` and then calls
   `agJobForget(chat.id, chat.serverId || "", s.jobId)` (app.js:58639 — it already stops the
   watcher through `_agRunStops`).
2. Add a Stop button to the fc panel header while `FC_LIVE_PHASES[st.phase]` is true, in
   `fcPanelEnsure`'s `<header class="fc__identity">` (app.js:56336) with the same handler. The
   Arabic label already exists: `STR.ar.stop = "إيقاف"` (app.js:441).

---

## 4. CRITICAL — a finished/evicted agent job leaves the card spinning and polls 700 ms for three hours

**app.js:58896-58906** (`runPoll`)

```js
      if (response.status === 403) { shutdown(true); return; }
      if (response.ok) {
        const data = await response.json();
        const job = data && data.job;
        if (job && epoch === streamEpoch) await queueSnapshot(job);
      }
    } catch (_) { }
    finally {
      …
      if (!closed && pollingFallback) schedulePoll(document.visibilityState === "visible" ? 700 : 5000);
    }
```

The server answers an unknown id with **HTTP 200 and `{ job: null }`**:

```js
  if (!ctl) return sendJson(res, 200, { job: null });   // server.mjs:12124
```

That happens whenever the control record is gone — the durable store lost it, the id is older than
the retention window, or the Fly machine was redeployed mid-mission (AGENTS.md: "a deploy returns
in-flight jobs to the queue"). The client then:

- takes no branch (`job` is falsy), so nothing repaints and nothing is said;
- has no miss counter — unlike `bgJobWatch`, which does keep one (`let misses = 0`, app.js:58500);
- re-schedules **every 700 ms while the tab is visible**;
- keeps going until `expiryTimer` fires at `AG_JOB_MAX_MS = 3 * 3600000` (app.js:58559, 58994).

Three hours at 700 ms is ≈ 15,400 requests for one dead job, on a single 512 MB instance, from a
user in Iraq on mobile data — while the card in front of them shows a spinner forever and no
message. (The card only turns into "stopped" on the *next* full render, via the `orphaned` branch
at app.js:53356, which nothing triggers on its own.)

This only engages once the SSE transport has failed at least once (`stream.onerror` → `startPolling(0)`,
app.js:58946), or when `applySnapshot` hits the `!target` + terminal branch (app.js:58787). SSE
through a mobile carrier proxy failing is exactly the "regressed / no longer smooth" complaint.

**Fix.** Two lines. At app.js:58896-58900 count null answers and give up honestly:

```js
      if (response.ok) {
        const data = await response.json();
        const job = data && data.job;
        if (job && epoch === streamEpoch) { nullMisses = 0; await queueSnapshot(job); }
        else if (!job && ++nullMisses >= 8) { agentWatchGiveUp(); shutdown(true); return; }
      }
```

with `let nullMisses = 0;` declared beside `let pollBusy = false;` (app.js:58718) and
`agentWatchGiveUp` writing a real message into the turn — reuse the shape `bgJobToRun` already
produces for a failure (app.js:58469, `failed` string, Arabic verbatim:
`"تعذّر إكمال المهمة. لم تُحوَّل إلى أداة أخرى؛ أعد المحاولة."`).

And back the cadence off: replace the two `schedulePoll(document.visibilityState === "visible" ? 700
: 5000)` sites (app.js:58879 and app.js:58906 — the anchor text appears on two lines, so include
the surrounding `if (!closed && pollingFallback) ` prefix to make app.js:58906 unique) with a
backoff, e.g. `Math.min(8000, 1500 * Math.pow(1.4, backoffN++))` reset to 0 on any real snapshot.
1.5 s matches the server's own Manus poll (server.mjs:8516), so nothing is lost by slowing down.

---

## 5. CRITICAL — every Firas Brain question makes a blocking, non-streaming, un-timed whole-corpus call first

**app.js:86779-86789**

```js
    const wholeKind = (typeof isGuest === "function" && isGuest()) ? null
      : (compare && docIds.length === 2) ? null
      : outline ? "outline"
      : brainIsQuizQuery(q) ? "quiz"
      : brainIsHarvestQuery(q) ? "harvest"
      : "";
    if (wholeKind !== null) {
      brainRenderThread(chat, { pending: LQ.wholeReading });
      let whole = null;
      try {
        whole = await apiJson("/api/brain/whole", { … });
```

For an ordinary signed-in question `wholeKind` is `""` — **not** `null` — so the whole-document read
runs on the default path for every question.

Server side (server.mjs:8974-9099):

```js
  const CAP = Number(process.env.BRAIN_WHOLE_MAX_CHARS || 2_600_000);   // server.mjs:9046
  …
  const out = await minimaxChat([ …, { role: "user", content: "QUESTION:\n" + q + "\n\nDOCUMENTS:\n" + corpus } ],
                                { maxTokens: 8192, temperature: 0.3 });   // server.mjs:9083
```

Three things make this feel hung rather than slow:

1. **It does not stream.** `minimaxChat` (server.mjs, `/text/chatcompletion_v2`) reads the whole
   response with `await r.json()` and `handleBrainWhole` returns one `sendJson`. Up to 8,192 output
   tokens over a 2.6-million-character prompt arrive as a single blob. The user watches a static
   notice — `LQ.wholeReading` — with nothing moving, for however long that takes. The streaming
   retrieval path underneath it (`/api/brain/search` → `brainPaintStream`, app.js:86877) is what
   the user *used to* see.
2. **There is no timeout anywhere on the chain.** `minimaxChat` is called without a `signal`
   (server.mjs:9083), and `minimaxChat`'s own `fetch` passes `signal` straight through — undefined.
   On the client, `apiJson` (app.js) has no `AbortSignal.timeout` either; only the user's Stop
   (`brainState.ctl`) can end it. If MiniMax stalls, the question stalls with no upper bound.
3. **It is charged and retried invisibly.** Every decline (`503 no key`, `413 too_large`, `502`,
   network) is swallowed at app.js:86807 (`whole = null;`) and the retrieval path then runs — so the
   user pays the full whole-read latency *and then* waits for the real answer.

**Fix.** Three changes, in order of value:

1. Put a hard deadline on the whole read so the streaming fallback can take over. At app.js:86789
   pass a race signal alongside the user's:
   `signal: brainState.ctl.signal` → wrap the call so it rejects after ~25 s and falls into the
   existing `catch (wErr) { … whole = null; }` (which already routes to retrieval). Something as
   small as `const wt = setTimeout(() => brainWholeAbort.abort(), 25000)` with a second controller
   combined via a listener on `brainState.ctl.signal`.
2. Mirror it on the server: `server.mjs:9083` → pass
   `{ maxTokens: 8192, temperature: 0.3, signal: AbortSignal.timeout(Number(process.env.BRAIN_WHOLE_TIMEOUT_MS || 90000)) }`.
   `minimaxChat` already accepts and forwards `signal`, and its `catch` already returns `null`,
   which `handleBrainWhole` turns into a clean 502 the client treats as a decline.
3. Give the wait a shape. `LQ.wholeReading` is a fixed sentence; add an elapsed clock or a
   progress line to the pending row so it reads as work rather than as a freeze. The panel clock
   already exists in the agent's fc panel (`fcFmtElapsed`, used at app.js:56990) and can be reused.

---

## 6. MAJOR — Firas Brain rebuilds its entire source rail once per page of an import

**app.js:85429-85432**

```js
  const onPhase = (phase, done, total) => {
    const b = brainState.busy.get(tempId);
    if (b) { b.phase = phase; b.done = done; b.total = total; brainRenderRail(); }
  };
```

`onPhase` is called from `extractBrainPdfPages` every 3 pages (app.js:84772) and from the OCR pass
**once per page** (app.js:85353). For a 300-page scanned Arabic textbook (`BRAIN_OCR_MAX_PAGES = 300`,
app.js:80863) that is ~100 + up to 300 ≈ **400 calls**.

Each call runs the whole of `brainRenderRail` (app.js:87487):

- `brainApplyPins`, `brainGlossPrune`, `brainPlanPrune`, `brainFmlPrune`, `brainReadPrune` — five
  sweeps over the library;
- `brainSyncSum`, `brainSyncTbl`, `brainSyncFml`, `brainRenderScope`, `brainRenderCmp`,
  `brainRenderPins`;
- `mAutoAnimate(list); list.innerHTML = "";` (app.js:87554-87555) followed by a fresh
  `document.createElement` tree **for every document in the library** — each row carrying six
  buttons and its listeners (app.js:87517-87534).

The `mAutoAnimate` + `innerHTML = ""` combination is the worst part: auto-animate sees every row
removed and re-added on every tick, so it animates the entire list 400 times during an import that
is already competing with `page.render` and `canvas.toDataURL` on the main thread.

And **only one thing actually changed** on those ticks: the `.fb-up__status` text and the busy row's
`.fb-src__meta` / `.fb-src__bar-fill` (app.js:87548, 87565-87567).

**Fix.** Add a narrow painter beside `brainRenderRail` and call it from `onPhase`:

```js
function brainRenderBusy() {
  const root = document.getElementById("brainWorkspace");
  if (!root || !root.querySelector(".fb")) return;
  const L = brainT(), busy = [...brainState.busy.values()];
  const st = root.querySelector(".fb-up__status");
  if (st) st.textContent = busy.length
    ? busy.map((b) => b.phase + (b.total ? " " + b.done + "/" + b.total : "") + " · " + b.name).join(" — ")
    : L.addHint;
  const rows = root.querySelectorAll(".fb-rail__list .fb-src.is-busy");
  busy.forEach((b, i) => {
    const row = rows[i]; if (!row) return;
    const meta = row.querySelector(".fb-src__meta");
    if (meta) meta.textContent = b.phase + (b.total ? " " + b.done + "/" + b.total : "");
    const fill = row.querySelector(".fb-src__bar-fill");
    if (fill) fill.style.width = (b.total ? Math.round((b.done / b.total) * 100) : 0) + "%";
  });
  if (rows.length !== busy.length) brainRenderRail();   // a row arrived or left — full paint once
}
```

Then app.js:85431 becomes
`if (b) { b.phase = phase; b.done = done; b.total = total; brainRenderBusy(); }`.
The full `brainRenderRail()` calls at app.js:85428 (start) and app.js:85462 (finally) stay as they
are, so the row still appears and disappears correctly. Anchor is unique.

---

## 7. MAJOR — the whole sidebar is rebuilt on every agent snapshot

**app.js:58858**, inside `applySnapshot`:

```js
      if (changed) { try { renderHistory(); } catch (_) {} }
```

`changed` is `message.content !== next` (app.js:58842), and `next` is
`serializeAgentRun(run)` — which changes on essentially every snapshot, because
`agentJobSurface` folds the growing `job.live` / `job.events` arrays into the payload
(server.mjs:11085-11114) and the server publishes on every 1.5 s Manus tick.

`renderHistory` (app.js:19014) is a full teardown: `list.innerHTML = ""` (app.js:19023), then
`ephReattach`, `ctgBar`, `productChats()`, a sort, `bsBar`, `renderResumeStrip`, `renderFolders`,
`renderPinnedStrip`, and a `chatItemEl(c, …)` element tree **per conversation**. For a student with
40-80 conversations that is 40-80 subtrees discarded and rebuilt every 1.5 seconds for the entire
mission — plus it resets the sidebar's scroll anchoring and destroys any selection in it.

Nothing in the sidebar actually needs that: only this one row's timestamp moved.

**Fix.** Throttle it, and only for a live (non-terminal) snapshot. Replace app.js:58858 with:

```js
      if (changed) {
        if (terminal) { try { renderHistory(); } catch (_) {} }
        else {
          const now = Date.now();
          if (!view.lastHistoryAt || now - view.lastHistoryAt > 5000) {
            view.lastHistoryAt = now;
            try { renderHistory(); } catch (_) {}
          }
        }
      }
```

`view` is already in scope (it is the `_agRunViews` record created at app.js:58705) and already
carries a sibling throttle field, `lastFallbackAt` (app.js:58704, used at app.js:58850-58853), so
this follows an existing pattern rather than inventing one. Anchor occurs exactly once.

---

## 8. MAJOR — the agent panel's activity flow is destroyed and rebuilt on every change

**app.js:56881**, inside `fcFlowPatch`:

```js
  if (flow.dataset.sig === sig && flow.dataset.lang === (ar ? "ar" : "en")) return;
  const focusKey = view.focusInside ? view.focusKey : "";
  flow.dataset.sig = sig;
  flow.dataset.lang = ar ? "ar" : "en";
  flow.replaceChildren();
  fcTaskPatch(el, st, ar, flow, view);
```

The signature gate is real and does suppress no-op patches. But the signature is computed by
`JSON.stringify` over up to **100 events** (`fcTaskEvents` → `structured.slice(-100)`,
app.js:56414) on *every* call, and any single new activity line invalidates it — which is what
happens on essentially every 1.5 s tick. Then `replaceChildren()` throws away every node and
`fcBuildEvent` rebuilds all of them.

Two consequences the user sees:

- **Text selection inside the panel is impossible** during a mission. Every 1.5 s the nodes the
  selection anchors to are gone. Reading a tool argument or a source URL off a running mission is
  not possible; you have to wait for it to finish.
- The `<details>` open-state *is* preserved (`fcRememberDisclosure`, app.js:56357) and focus is
  restored (app.js:56905-56909), which is why this reads as flicker rather than as data loss.

The DOM is **not** unbounded, contrary to the concern in the brief: `fcTaskEvents` caps at 100
(app.js:56414), `serializeAgentRun` caps events at 48 / tools at 24 / says at 10 (app.js:51652-51660),
and `agentJobSurface` caps at 60/30/20 server-side (server.mjs:11095-11101). A four-hour mission
does not grow the card without limit. I checked and could not make that claim stand up.

**Fix.** Key the rebuild per event instead of wholesale. Give each built node
`node.dataset.evKey = <the same tuple the sig uses for that event>`, then in `fcFlowPatch` diff the
key list against the children already present and only append/remove/patch the difference. The
smallest useful version: keep `flow.replaceChildren()` for the case where the *set* of keys changed
by more than an append, and take the fast path — append only the new tail — when the existing keys
are a prefix of the new ones. Newest events are appended at the end (app.js:56888-56901), so the
prefix case is the overwhelmingly common one.

---

## 9. MAJOR — Firas Code PUTs the entire project to the server every 4 seconds during a build

**app.js:60484**

```js
                try { codeSaveFiles(target, name || proj.name || target.title || "", proj.files); } catch (_) {}
```

`codeSaveFiles` (app.js:60574) ends in `persistChat(chat)` (app.js:60609), which for a signed-in
user is a network PUT of the whole conversation. The project fence is capped at
`CW_PAYLOAD_MAX = 180000` chars (app.js:60273).

The guard above it — `if (raw && (raw !== lastFence || !savedOnce))` (app.js:60477) — only skips
*byte-identical* fences. A server build publishes files incrementally, so `raw` changes on nearly
every tick, and the client uploads up to 180 KB every 4 seconds for the whole build. On a mobile
link in Iraq that is both the perceived stall and a real cost.

**Fix.** Coalesce the durable write. Keep writing the files into `chat.messages[0]` on every tick
(that is what the workspace reads) but debounce the `persistChat` call — e.g. add an optional third
state to `codeSaveFiles` or, less invasively, at app.js:60484 write through a wrapper that calls
`codeSaveFiles` at most once every 20 s **plus** unconditionally on the terminal tick (the branch at
app.js:60490, `j.phase === "completed" | "done" | "failed" | "unknown"`). `persistChat` already
serialises writes per chat (app.js:3410-3444), so the risk is latency, not ordering.

---

## 10. MINOR/MAJOR — several thousand lines of unreachable agent code ship on every load

**app.js:59792** is an unconditional `return;` at the end of `runAgentAssistant`:

```
59768:       return;                 // inside `if (started) { … }`
59790:   if (activeChat() === chat) renderThread(chat);
59791:   renderHistory();
59792:   return;
59794:   try {
59799:     const run = await runAgentTask(chat, aiMsg, task, replyLang, controller.signal, rerenderCard, ctx, resumeRun);
```

Everything after line 59792 is dead. That makes the following unreachable in production:

- `runAgentTask` (app.js:57323) — the entire in-tab planner/executor pipeline, with its planner
  prompts, mode detection, image gathering, QA loop and deliverable builders;
- `manusTryRun` (app.js:57183) — including its `MANUS_POLL_MS = 5000` loop whose **first poll waits
  a full 5 seconds before it asks anything** (app.js:57273: `await new Promise((res) =>
  setTimeout(res, MANUS_POLL_MS));` sits *before* the fetch). That is the "the first poll is not
  immediate" defect the brief asks about — it is real, but it is in dead code, so fixing it changes
  nothing a user sees;
- `rerenderCard` (app.js:59696) and therefore the `node.innerHTML = ""` + `buildAgentCard` wipe that
  the brief expected to find on the hot path. **It is not on the hot path.** The live path patches
  in place through `agPatchServerPanel` → `fcPanelPatch` (app.js:58678). I am reporting this as a
  non-finding rather than dressing it up.
- `agentLiveSet` / `mountAgentLivePanel` (app.js:57044-57064) — only reachable through
  `manusTryRun` and `restoreActiveAgentPanel` (app.js:22323), the latter of which needs an
  `activeStreams` entry with `agentView.remote`, which only `agentLiveSet` sets. So
  `restoreActiveAgentPanel` is a no-op in production too.

That is a large slice of a 5.8 MB file parsed on every cold load, on the owner's own complaint list
(«خلي فتحه سريع وتحميله قوي»).

**Fix.** This is a decision, not a patch: either delete the dead pipeline (large, risky, needs the
owner's call because it is the documented fallback for a Manus outage), or make the fallback real
by replacing app.js:59792's `return;` with a condition — e.g. run the in-tab pipeline only when
`agentServerRun` returned false *and* the failure was not a refusal (`account_required`,
`agent_busy`, `credits_*`). Today the code says "Firas Agent is temporarily unavailable" and stops
(the `unavailable` object at app.js:59772), while a working fallback sits two lines below it.
Whichever way it goes, one of the two branches should stop shipping.

---

## 11. MINOR — a Brain import cannot be cancelled

`brainOcrPage(b64, pg.p, lang, null)` (app.js:85348) — the signal argument is literally `null`. The
busy row rendered at app.js:87557-87569 has a name, a phase, a meta line and a progress bar, and no
button at all. `brainState.ctl` exists but belongs to `brainAsk` (app.js:86745), not to the import.

So a user who drops a 300-page PDF by mistake, or realises they picked the wrong file, has no way to
stop three concurrent vision calls per page from spending their daily budget. Reloading the tab is
the only exit — and, because the import is entirely in-tab (there is no `/api/brain/job`), reloading
throws away everything already extracted. This also puts Brain's import outside the standing
cloud-first rule, but that is a product decision rather than a defect I can patch.

**Fix.** Give `brainUploadFile` its own `AbortController`, store it on the busy record
(`brainState.busy.set(tempId, { name, phase, done, total, ctl })`, app.js:85427), pass
`ctl.signal` down through `extractBrainPages` → `brainOcrPage` (which already accepts a `signal`
parameter — app.js:84829 — and currently receives `null`), and render an `✕` in the busy row
alongside the existing one on document rows (`fb-src__x`, app.js:87534).

---

## 12. What I looked for and did NOT find

Recorded so nobody re-runs this hunt:

- **`buildAgentCard` / `rerenderCard` wiping the node on every tick.** True of the code, false of
  production — that path is behind the dead `return` at app.js:59792 (§10). The live agent path
  patches in place.
- **Unbounded DOM growth on a long mission.** Bounded at every layer: 100 (client render), 48/24/10
  (client serialise), 60/30/20 (server surface). See §8.
- **A non-immediate first poll on the live paths.** `agWatchServerRun` opens SSE and the server
  `publish(initial)`s immediately (server.mjs:12277); `cwWatchServerBuild`'s loop body fetches
  before its first sleep (app.js:60449 vs 60501); `agJobsReattach` and `cwJobsReattach` are wired to
  boot, `visibilitychange`, `online`, `focus` and `pageshow` (app.js:50763-50787, 47206-47211).
  The only 5-second-before-first-poll bug is in dead code (§10).
- **Pointer tables growing without bound.** `AG_JOB_MAX_PTRS = 20` with an oldest-first eviction
  (app.js:58560, 58632-58636); `CW_JOB_MAX_MS` sweep in `cwJobsReattach` (app.js:60515).
- **A failure that produces silence.** Mostly not: `bgJobToRun` synthesises an Arabic failure
  message for every error code (app.js:58467-58483), `manusTryRun`'s 429 explains itself
  (app.js:57192-57200), and `extractBrainPages` refuses loudly when every OCR page came back empty
  (app.js:85374-85383). The one genuine silence is §4 — `{job:null}` produces nothing at all,
  forever.

---

## Suggested order of work

1. §1 — one line, removes the worst visible breakage in Firas Code.
2. §4 — two small edits, removes a forever-spinner and a 15,000-request storm.
3. §5 — a timeout on both ends of the Brain whole-read; the largest single "it hangs" in Brain.
4. §3 — restore a Stop for agent missions.
5. §6, §7, §9 — the throttles. Cheap, and they are what turn «يعلس» into «سلس».
6. §2 — the Code build progress card; more work than the rest, biggest perceived-quality win.
7. §8, §11, §10 — in that order.
