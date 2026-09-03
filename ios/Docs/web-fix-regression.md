# "متراجع هواي" — bisect-by-reading of the web client

Read-only pass. Branch `night/capabilities-and-code-ui` (HEAD `4b0ed4a`) is what is deployed;
the working tree carries ~14,800 uncommitted lines on top of it that are **not** live.
Every claim below carries a file:line and a measurement or a quotation from the code.

Two words govern the whole report:

* **DEPLOYED** — the defect is in a commit at or before `4b0ed4a`, so the students are living
  with it right now. These explain the owner's complaints.
* **PENDING** — the defect is only in the uncommitted working tree. It is not the cause of
  today's complaints, but it must not ship as written.

---

## The headline measurement

`git cat-file -s` on `app.js` and `styles.css` at each commit of the "capabilities" band:

| commit | date | app.js | styles.css |
|---|---|---|---|
| `354a39b` | 2026-08-27 | 2,320,736 | 495,923 |
| `55eee79` | 2026-08-29 | 3,909,371 | 962,455 |
| `7fe4237` | 2026-08-29 | 4,153,478 | 1,026,305 |
| `3104a36` | 2026-08-29 | 4,451,589 | 1,075,969 |
| `c806fa3` | 2026-08-29 | 4,707,737 | 1,132,115 |
| `92d72a9` | 2026-08-29 | 5,037,572 | 1,204,982 |
| `201f7ad` | 2026-08-29 | 5,291,899 | 1,244,671 |
| `4b0ed4a` | 2026-08-30 | 5,496,215 | 1,263,060 |
| working tree | today | 5,796,169 | 1,406,510 |

**In three days the first-load payload went from 2.82 MB to 6.76 MB — 2.4x.**
`55eee79` alone ("A night of capabilities") added 31,765 lines to `app.js` and 8,382 to
`styles.css` in one commit: `app.js` +68 %, `styles.css` +94 % overnight.

There is no build step and no code splitting: `index.html:318` loads the whole 5.5 MB as one
classic `<script defer>`, and `index.html:271` loads the whole 1.26 MB stylesheet
render-blocking in `<head>`. gzip (server.mjs:13302, level 6) takes app.js to roughly 1.1 MB on
the wire, but **parse + compile is not compressed**: 5.5 MB of JavaScript is one unbreakable
main-thread task of roughly 2–5 s on the mid-range Android phones this product is for. That is
"خلي فتحه سريع وتحميله قوي" and it is the largest single reason the app "تراجع".

Nothing below is bigger than this. Everything below is fixable in an afternoon; this one is not,
and it is the one that has to be planned.

---

## 1. DEPLOYED — every message waits on a 6,906-character classifier, on the expensive tier

**`app.js:41568`** (deployed: `39475`), inside `streamAnswer`:

```js
  const turnKind = lastUserTurn
    ? await classifyTurnIntent(lastUserTurn.content, { … }, signal)
    : "chat";
```

Nothing about the answer starts until this returns. The composer clears, the turn placeholder
appears, and then the app sits still. That is exactly the owner's first sentence:
**«من اريد ارسل رسالة يوكف ويشتغل يرد»** — send, it stops, then it works and answers.

Two commits made it worse, both on 2026-08-30, three days before he complained.

**a. The tier.** `a39075a` ("The classifier was answering \"song\" and my parser was throwing it
away") flipped `"mini"` → `"pro"` at **`app.js:4273`**. Its own commit message says
*"a stronger tier costs a fraction of a second and nothing else"*. It costs more than that:
`server.mjs:341-342` (TIERS) shows what the two tiers actually are —

* mini → `gemma4:cloud, qwen3.5:35b-cloud, gpt-oss:120b-cloud`
* pro → `glm-5.2:cloud, deepseek-v4-flash:cloud, gpt-oss:120b-cloud`

A small fast model was swapped for a large one on the single call that blocks every turn.

**b. The prompt.** Measured by extracting the string literal at each revision:

| commit | classifier system prompt | tier |
|---|---|---|
| `33932fd` (2026-08-23, as introduced) | 2,556 chars | mini |
| `2be3d54` (2026-08-30) | 4,307 chars | mini |
| `f4cf738` (2026-08-30) | 5,806 chars | **pro** |
| `99076cd` (2026-08-30) → HEAD | **6,906 chars** | **pro** |

`f4cf738` added the worked examples, `99076cd` added the video boundary. **2.7x the prompt on a
strictly more expensive model, on the one call that stands between pressing send and seeing a
word.**

**c. And it is not even the only one.** In the deployed build a *second* blocking model call runs
right after it — **`head:app.js:39718`**:

```js
    const mediaIntent = (imgUser && !imgHasAttachments && … )
      ? await classifyMediaIntent(imgUser.content, signal) : "none";
```

gated by `MEDIA_MAYBE` (`app.js:4057`), which matches `اريد|اعطني|هات|خلي|اصنع|اعمل|سوي|i want|
give me|can you|make|create` — practically every student sentence. So an ordinary Arabic question
pays **two sequential model round trips before the first token.**

### Fix

Three changes, in order of value.

1. **Revert the tier.** `app.js:4273`. Anchor on the two lines together (`], "pro", signal);`
   occurs 8 times in the file):
   ```
   It was defensible on mini at nine kinds of visibly different shapes; it is not now. */
         ], "pro", signal);
   ```
   → `], "mini", signal);`, and rewrite the comment above it to say why (the tier is on the
   blocking path; correctness came from the worked examples in `f4cf738`, not from the model
   size). If `mini` proves genuinely worse on the song/video boundary, the honest answer is a
   *shorter* pro prompt, not a longer one.

2. **Cap the stall.** `app.js:41568`. Race the classifier against a deadline instead of awaiting
   it unbounded:
   ```js
   const turnKind = lastUserTurn
     ? await Promise.race([
         classifyTurnIntent(lastUserTurn.content, ctx, signal),
         new Promise((r) => setTimeout(() => r("unavailable"), 1200)),
       ])
     : "chat";
   ```
   `"unavailable"` is already the designed fallback and every consumer handles it
   (`app.js:41791` mediaIntent, `41854` song, `42040` video, `42178` image), so this degrades to
   the pre-classifier behaviour rather than to nothing. `turnRequirementsOf` at `41581` awaits the
   same cached promise and must be given the same guard or it re-introduces the wait.

3. **Delete the second call.** The working tree already does this correctly at `app.js:41791` —
   `turnKind === "video" || turnKind === "image" ? turnKind : (turnKind === "unavailable" ? await
   classifyMediaIntent(…) : "none")`. That hunk should be cherry-picked and shipped on its own; it
   is a pure latency win with no behaviour change.

---

## 2. DEPLOYED — the streaming painter re-measures the whole message on every frame

**`app.js:43818`** (deployed: `41145`):

```js
function paintStreamingMarkdown(mdEl, src, lang) {
  …
  const live = paintStreamingMarkdownInner(mdEl, visible);
  try { autoDirBlocks(mdEl, lang || state.lang); } catch (_) {}
  return live;
}
```

`autoDirBlocks` (`app.js:87907`) does this, to the **entire** message tree, on **every** paint
frame (~18–20 fps):

```js
  md.querySelectorAll("p, h1, h2, h3, h4, h5, h6, ul, ol, li, blockquote, table, td, th, pre")
    .forEach((el) => {
      const t = el.textContent || "";
      const ar = (t.match(/[؀-ۿ]/g) || []).length;
      const la = (t.match(/[A-Za-z]/g) || []).length;
      el.setAttribute("dir", ar || la ? (la > ar * 1.5 ? "ltr" : "rtl") : fallback);
    });
```

For a 200-block answer that is, per frame: 200 `textContent` materialisations (each concatenating
a whole subtree into a fresh string), 400 global regex scans, and 200 `setAttribute("dir", …)`
writes. `setAttribute` dirties style **even when the value is unchanged**, so this forces a full
style recalculation and layout of the message on every frame, and the cost grows with the answer:
the longer Firas talks, the jerkier it gets. That is «بطيء كلش و يعلك مرات».

`git log -S` names the commit: **`354a39b` (2026-08-27), "A settings panel that breathes, six
themes, …"**. Its hunk is precisely this wrapper:

```
+function paintStreamingMarkdown(mdEl, src) {
+  const live = paintStreamingMarkdownInner(mdEl, src);
+  try { autoDirBlocks(mdEl, state.lang); } catch (_) {}
+  return live;
 }
+function paintStreamingMarkdownInner(mdEl, src) {
```

Before it, nothing walked the settled DOM per frame. The whole point of
`paintStreamingMarkdownInner` — stated in its own comments — is that settled blocks are never
touched again. This wrapper touches all of them, every frame, and quietly undid that work.

### Fix

The inner painter already **returns the nodes it created or reconciled this frame**. Direct the
walk at those, and never at a settled block twice:

* At `app.js:43818`, replace the whole-tree call with a per-node pass over `live` plus a one-shot
  marker so a reconciled node is only re-measured when its text actually changed:
  ```js
  const live = paintStreamingMarkdownInner(mdEl, visible);
  try { live.forEach((n) => autoDirBlocks(n, lang || state.lang)); } catch (_) {}
  ```
  `autoDirBlocks` uses `querySelectorAll` from its argument, which does not include the argument
  itself — so give it a `dirOne(el, lang)` helper that stamps `el` and then its descendants, or
  pass a wrapper. Grep before you write: `autoDirBlocks` is called at `7549`, `27290`, `32819`,
  `43818`, `87833`; only `43818` is on the per-frame path and only it may change.
* Inside `autoDirBlocks`, skip the write when it changes nothing:
  ```js
  const want = ar || la ? (la > ar * 1.5 ? "ltr" : "rtl") : fallback;
  if (el.getAttribute("dir") !== want) el.setAttribute("dir", want);
  ```
  That alone removes the per-frame relayout even if the traversal stays.

Secondary, same frame: `splitSettledMarkdown` (`app.js:43723`) regex-scans and `slice`s the whole
accumulated answer each frame, and `scrubBacktrackFull` (`app.js:36808`, called at the paint site as `scrubBacktrackFull(shownAnswer)`)
re-splits the whole answer into sentence units on every frame once a backtrack phrase has ever
appeared. Both are O(n) per frame → O(n²) per reply. Worth a follow-up, not worth blocking on.

---

## 3. DEPLOYED — the durable job poll re-downloads the whole answer three times a second

Client, **`app.js:41282`**:

```js
const p = await fetch("/api/chat/job?id=" + encodeURIComponent(jobId), { … });
…
if (text.length > sent)   { controller.enqueue(frame({ content:   text.slice(sent)   })); sent  = text.length; }
if (reasoning.length > sentR) { controller.enqueue(frame({ reasoning: reasoning.slice(sentR) })); sentR = reasoning.length; }
```

Server, **`server.mjs:12684`** and **`12698`**:

```js
return sendJson(res, 200, {
  phase: "processing", text: live._answer || "", reasoning: live._reasoning || "", …
});
```

The client sends **no offset**; the server returns the **full accumulated answer and the full
accumulated reasoning** on every poll, and the client throws the prefix away. The poll cadence is
`app.js:41241`: `350 ms` for the first 10 s, then 700 ms, then 1200 ms.

Cost: for an answer of N characters polled P times the wire carries ~N·P/2 bytes. A 30 KB answer
over ~60 polls is roughly **900 KB down instead of 30 KB**, on a connection in Iraq, plus a
`JSON.stringify` of the whole growing answer three times a second per active user on a **single
512 MB Fly instance** (`fly.toml`, autostop off, background jobs inside the web process). Twenty
students answering at once is sixty full-answer serialisations per second. This is a plausible
mechanism for «يعلك مرات» — the freeze is the box, not the browser.

### Fix

Add an offset to the contract; both halves are three lines.

* Server `handleChatJobStatus` (`server.mjs:12662`): read
  `const from = Math.max(0, parseInt(url.searchParams.get("from") || "0", 10) || 0);` and
  `const fromR = …("fromR")`, then slice both memory branches (`12684`, `12698`) and the durable
  branch, returning `text: (live._answer || "").slice(from)` plus an explicit
  `textLen` / `reasoningLen` so the client can keep its own counters honest.
* Client `fetchChatJob` (`app.js:41282`): append `"&from=" + sent + "&fromR=" + sentR`, and treat
  the returned strings as deltas (`sent += text.length`).
* Keep the old shape working when `from` is absent — `netlify/edge-functions/api.js` is a mirror
  and an un-updated edge must not break (`dual-backend-parity`).

---

## 4. DEPLOYED — the server reads 5.5 MB from disk on every static request, then throws it away

**`server.mjs:13447`**:

```js
    let data = await readFile(filePath);
    …
    data = gzipFor(filePath + (seoRoute ? "|" + seoRoute : ""), data, statSync(filePath).mtimeMs);
```

`gzipFor` (`server.mjs:13302`) caches the **compressed** buffer keyed by mtime — but the raw
`readFile` happens **first, unconditionally**. So every single request for `app.js` allocates a
fresh 5.5 MB Buffer and every request for `styles.css` allocates 1.26 MB, purely to hand them to a
function that ignores them and returns a cached buffer.

On a 512 MB instance, thirty simultaneous cold visitors is ~200 MB of transient buffer churn and
the GC pauses that come with it. The comment above `gzipFor` says *"this is a Map lookup on every
request after the first"* — the gzip is; the read is not.

### Fix

Move the cache check ahead of the read. In the same function, keyed the same way:

```js
    const ext = path.extname(filePath).toLowerCase();
    const wantsGzip = GZIP_TYPES.has(ext) &&
      String(req.headers["accept-encoding"] || "").includes("gzip");
    const mtimeMs = statSync(filePath).mtimeMs;
    const cacheKey = filePath + (seoRoute ? "|" + seoRoute : "");
    const hit = wantsGzip ? _gzipCache.get(cacheKey) : null;
    let data = (hit && hit.mtime === mtimeMs) ? hit.buf : await readFile(filePath);
```
and skip the SEO rewrite / stamping / gzip entirely on a hit (the cached buffer already carries
all three). Guard `statSync` in the same try/catch shape the file already uses so an unstattable
path still falls through to the current behaviour.

**Related, PENDING:** the ETag block at **`server.mjs:13513`** SHA-1s the entire response body on
every request —

```js
      etag = 'W/"' + data.length.toString(16) + "-" +
             crypto.createHash("sha1").update(data).digest("hex").slice(0, 16) + '"';
```

— and then `13517` discards it for any `?v=` URL, which is *every* `app.js` and `styles.css`
request, because the server stamps those versions itself at `13470`. This is new in the working
tree (HEAD has no sha1 here). Ship it with `if (!versioned) { … }` around the hash, and cache the
tag next to the gzip buffer so it is computed once per file version, not once per request.

---

## 5. DEPLOYED — the call button really is missing: UI 2.0 hides it the moment you type

**`styles.css:13997`**:

```css
:root[data-ui="2"] .composer__actions:has(.composer__send:not(:disabled)) .composer__call {
  display: none;
}
```

and, above it at `13970-13972`, the phone icon is swapped for a waveform while the box is empty.
So under UI 2.0 the phone glyph **never appears at all**: empty box → a waveform on a filled
accent circle (reads as "voice input", not "call"); any text in the box → the control is gone
outright. **«ميزة المكالمة ما موجود زرها»** is literally true.

`git log -S` names it: **`55eee79`**, the same night. The rule's own comment argues the case
("a half-typed message and a voice call are two different intentions"), which is a defensible
*design* — but it was shipped with no affordance that says a call exists, so the feature became
invisible to the people who had been using it.

UI 2.0 is opt-in (`app.js:3179`, `state.ui2 = localStorage.getItem(LS_UI2) === "1"`, default off),
so this hits only readers who turned it on — the owner among them.

**Second, unconditional cause, not a regression.** `app.js:50100`:

```js
  if (!(callSRAvailable() || callMicAvailable())) { els.callBtn.style.display = "none"; return; }
```

`callSRAvailable` (`48151`) needs `SpeechRecognition`/`webkitSpeechRecognition`; `callMicAvailable`
(`48153`) needs `navigator.mediaDevices && getUserMedia && MediaRecorder`. In the Facebook,
Instagram and TikTok in-app browsers — how a large share of students in Iraq open a link — and in
Firefox, one or both are absent and the button silently disappears with nothing said. Being honest:
this has always been true, so it is not the regression, but it is the other half of the complaint
and it is worth fixing in the same pass.

### Fix

* `styles.css:13997` — delete the `display: none` rule, and instead shrink the call button to the
  secondary treatment while Send is live (drop the accent fill, keep the 40 px target). Keep the
  icon a **phone** in both states: `styles.css:13970` should be `.ico-wave { display:none }`
  unconditionally under `[data-ui="2"]`, or the wave should be added *beside* the phone, never
  instead of it.
* `app.js:50100` — replace the silent hide with a disabled button carrying a reason, the way the
  Listen button already does (see `c806fa3`, "a Listen button that says why it can't speak"):
  keep it visible, `disabled`, and on click show
  `"المكالمة تحتاج متصفح كامل — افتح الموقع في كروم أو سفاري"` /
  `"Calls need a full browser — open the site in Chrome or Safari"`. A button that explains itself
  is not a missing feature; a button that vanishes is.

---

## 6. DEPLOYED — Plan mode is told not to deliver, on the turn it is supposed to deliver

**`app.js:38156`**, in `buildMessages`:

```js
  const planSystem = state.mode === "plan" ? {
    role: "system",
    content:
      "You are in PLAN MODE. This OVERRIDES any other instruction about producing " +
      "code, a website, a document, or a file directly. Do NOT produce the final " +
      "deliverable yet — EVEN if the request is to build a website/app or make a file.\n" +
```

`buildMessages` is synchronous and has no notion of approval. `streamAnswer` computes
`planExecuting` at **`app.js:41603`** (`state.mode === "plan" && precededByApproval(...)`) and
uses it for the code branch (`41612`), the image branch (`42179`) and the media branches
(`41794`) — **but never passes it to `buildMessages`**. So after the reader presses ابدأ, the
execution request still carries "Do NOT produce the final deliverable yet". The model gets
contradictory orders and does what the loudest instruction says: it plans again. That is
«التخطيط والتلقائي… تخطيط ما يشتغل عدل».

Two more consequences of the same omission:

* **`app.js:38218`** — `if (fileTurnSystem && state.mode !== "plan") head.push(fileTurnSystem);`
  The file-format guidance is withheld on the execution turn too. The comment above it says the
  file is built *"only after the user approves"* — but nothing re-enables it after approval,
  because `state.mode` is still `"plan"`.
* **`app.js:42291`** — `if (fileFmt && state.mode !== "plan") {` gates the entire document
  pipeline. **In Plan mode, asking for a PDF and approving the plan can never produce a PDF.**
  The code/image/video branches all account for `planExecuting`; only the file branch does not.
  That asymmetry is what makes this an oversight rather than a decision.

Not a recent regression — it predates the band — but it is the whole of complaint 5 and it is
three small edits.

### Fix

* Give `buildMessages` the flag. Its signature is `buildMessages(tier, conversation, replyLang)`
  (`app.js:38036`); add a fourth `planExecuting` argument, default `false`. In it:
  `const planSystem = (state.mode === "plan" && !planExecuting) ? { … } : null;` and
  `if (fileTurnSystem && (state.mode !== "plan" || planExecuting)) head.push(fileTurnSystem);`
* At the call site, `app.js:42371`
  (`let requestMessages = buildMessages(aiMsg.tier, convo, replyLang);`), pass `planExecuting` —
  it is already in scope from `41603`.
* `app.js:42291`: `if (fileFmt && (state.mode !== "plan" || planExecuting)) {`
* There is a second copy of the plan prompt to watch for: grep `PLAN MODE` before editing, and
  check `netlify/edge-functions/api.js` for parity.

Also worth a line of code: `state.mode` is read **live** at answer time, not snapshotted at send.
Because the classifier (finding 1) now holds the turn for seconds, a reader who taps send in Plan
and switches the pill to Auto within that window gets an Auto answer. Snapshot the mode onto
`aiMsg` in `sendMessage` and read it from there.

---

## 7. DEPLOYED — the song feature has exactly one gate, and it is the same fragile call

**`app.js:41853`**:

```js
    const wantsSong = turnKind === "song"
      || (turnKind === "unavailable" && songAskedPlainly(_songAsk));
```

If the branch runs, the reader gets a `firas-music` fence and a player (`app.js:42032`). If it
does not, the ordinary chat path answers — and the answer to "اصنعلي اغنية" from a chat model is
**lyrics**. That is precisely the owner's report:
**«كلتله اصنعلي اغنية سوالي كلمات ما سوة اغنية»**.

The plain-language rescue `songAskedPlainly` (`app.js:41833`) is correct — `اصنع` matches inside
`اصنعلي`, `اغنية` matches `SONG_NOUN` — but it is reachable **only** when the classifier failed
outright. When the classifier answers the wrong word, the feature does not degrade, it disappears,
and it disappears behind a plausible-looking reply. The classifier's own prompt makes the wrong
word easy to reach: it teaches `"Write me lyrics" with no music asked for is chat`.

I am not going to claim a mechanical bug here; the code does what its comments say it does. The
defect is that a two-line model reply is a single point of failure for a whole feature.

### Fix

Let the unmistakable ask override a `chat` verdict — but only the unmistakable half of it, so
"غنيلي شنو معناها" (which matches `SING`) stays a question:

```js
    const songNounAndMake = /(أغنية|اغنية|أغاني|اغاني|\bsong\b|\bsongs\b)/i.test(_songAsk) &&
      /(اعمل|أعمل|اصنع|أصنع|سوّ?ي|ألّ?ف|اكتب\s*لي|اكتبلي|ولّ?د|عطني|أعطني|\bmake\b|\bwrite\b|\bcreate\b|\bgenerate\b)/i.test(_songAsk);
    const wantsSong = turnKind === "song"
      || (turnKind === "unavailable" && songAskedPlainly(_songAsk))
      || (turnKind === "chat" && songNounAndMake);
```

Reuse the `SONG_NOUN` / `MAKE` constants already declared inside `songAskedPlainly` by lifting
them out of the closure rather than retyping them — do not create a third copy of these regexes.

---

## 8. PENDING — the new smooth-stream reveal repaints when nothing changed

Working tree only. `streamAnswer`'s render batching was replaced (`app.js:41692-41700`):

```js
  const answerReveal    = makeSmoothStreamReveal(paintAnswerFrame,    { isPaintable: revealPaintable, interval: 50 });
  const reasoningReveal = makeSmoothStreamReveal(paintReasoningFrame, { isPaintable: revealPaintable, interval: 34 });
  const scheduleRender = () => {
    if (finalized) return;
    answerReveal.push(answer, !!fileFmt);
    if (wantThinking) reasoningReveal.push(reasoning);
  };
```

Character pacing is switched off (`SMOOTH_STREAM_CHARACTER_REVEAL = false`, `app.js:43512`), and
the disabled branch of `push` (`app.js:43596-43605`) **lost the equality guard the enabled branch
has**:

```js
    if (!SMOOTH_STREAM_CHARACTER_REVEAL) {
      target = next;
      stableEnd = target.length;
      end = target.length;
      dirty = true;
      needsPaint = true;
      schedule();                 // one frame per received chunk; never pace characters
      return;
    }
    …
    if (next === target && !instant) {          // ← the guard, only on the live branch
      if (needsPaint && canPaint()) { dirty = true; schedule(); }
      return;
    }
```

So a reasoning-only chunk — where `answer` has not changed by one character — still sets
`dirty`/`needsPaint`, still ticks, and still runs a full `paintAnswerFrame`: markdown re-render,
`typesetMath` over the returned nodes, and `scrollToBottom`. The old code had exactly this guard
and said why:

> `} else if (answer !== lastRenderedAnswer) {`
> `// Only rebuild the body when the ANSWER text actually changed — a burst of`
> `// "thinking" tokens alone must not re-parse/re-typeset the whole message.`

That guard was deleted in this rewrite. Second, both reveals call `scrollToBottom`
(`app.js:41670` and `app.js:41688`), which reads `el.scrollHeight` — a forced synchronous layout — so with thinking on
the two independent timers force up to ~49 layouts per second instead of ~18.

Thinking is off by default (`app.js:3189`), which is why this is a "do not ship" rather than a
"this is what he is feeling".

### Fix

In `makeSmoothStreamReveal`, `app.js:43596`, restore the guard at the top of the disabled branch:

```js
    if (!SMOOTH_STREAM_CHARACTER_REVEAL) {
      if (next === target && !instant) {
        if (needsPaint && canPaint()) { dirty = true; schedule(); }
        return;
      }
      target = next; stableEnd = end = target.length;
      dirty = true; needsPaint = true; schedule();
      return;
    }
```

And in `streamAnswer`, drop `scrollToBottom()` from `paintReasoningFrame` (the answer frame
already scrolls, and the thinking panel scrolls its own `.thinking__inner`).

---

## 9. PENDING — `index.html` now boots the shell in RTL, and the app flips it to LTR

Working tree, **`index.html:2`**:

```diff
-<html lang="ar" dir="ltr" data-theme="dark">
+<html lang="ar" dir="rtl" data-theme="dark">
```

`applyShellLang` (`app.js:13684`) hard-codes the opposite, and says why:

```js
  // LAYOUT DIRECTION IS FIXED (LTR) and NEVER follows the language — the sidebar,
  // buttons and whole shell stay put; only the TEXT + font change with language.
  html.dir = "ltr";
```

It is called on boot at `app.js:79939`. `styles.css` is built on that promise in at least a dozen
places that name it explicitly — `12274` (*"applyShellLang hard-codes html.dir=\"ltr\" and only
per-element dir carries RTL"*), `15146`, `16247`, `16330`, `16618`, `17544`, `17968`.

Consequence: the static shell in `index.html` (sidebar, topbar, composer, auth screen) paints
**mirrored** from first paint until `app.js` — 5.8 MB, deferred — finishes parsing and boots, then
snaps back. On the phones this product targets that is a visible several-second wrong-way layout
followed by a full reflow, on every cold load. A returning reader who has already dismissed the
welcome overlay sees the whole thing.

### Fix

Revert `index.html:2` to `dir="ltr"`. The new welcome screen is the only part that genuinely wants
RTL, and it should say so on itself, not on the document: add `dir="rtl"` to
`<main id="seoIntro" class="fw">` (`index.html:~370`). That gets the crawler-readable Arabic
intro laid out correctly without breaking the promise every stylesheet rule in the file depends
on.

---

## 10. DEPLOYED, small — the tab reloads itself under the reader

**`app.js:50803`**:

```js
function startVersionWatch() {
  …
      if (pending && (typeof activeStreams === "undefined" || activeStreams.size === 0)) {
        try { showToast(state.lang === "ar" ? "يتم تحديث Firas…" : "Updating Firas…"); } catch (_) {}
        setTimeout(() => location.reload(), 700);
      }
  …
  setInterval(check, 15000);
}
```

Every open tab polls `/api/version` every 15 s forever and **reloads itself 700 ms after a
deploy**, with no way to decline. A reload is a fresh 6.76 MB parse. During a day of frequent
deploys, a reader gets yanked mid-sentence and then waits several seconds on a phone. It is not
the main cause of anything, but it is a real "it froze" event with an obvious trigger.

### Fix

Do not reload; offer it. Replace the `setTimeout(location.reload)` with a persistent toast/pill
carrying an action (`"تحديث"` / `"Update"`), and reload only on click. If an automatic reload is
kept for stale sessions, gate it on `document.hidden === true` **and** an idle threshold, never on
a foreground tab. While at it, stop the interval once `pending` is true — the version cannot
un-change, and the poll has nothing left to learn.

---

## What to do first

1. **Finding 1a** — one-token revert of `"pro"` → `"mini"` at `app.js:4273`. Largest
   perceived-latency win per character changed, and it directly answers «يوكف ويشتغل يرد».
2. **Finding 2** — the `autoDirBlocks` per-frame walk. Largest jank win, one call site.
3. **Finding 4** — `readFile` before the gzip cache. Largest server-stability win, five lines.
4. **Finding 3** — offset the job poll. Largest bandwidth win, and it is the exact path the owner
   himself blamed.
5. **Finding 5** — give the call button back.
6. **Findings 6, 7** — Plan mode and songs; these are correctness, not speed, and each is small.
7. **Findings 8, 9** — before the working tree ships, not after.
8. **The headline** — plan the split of `app.js`/`styles.css`. Nothing in this list moves the
   6.76 MB, and the 6.76 MB is why he says «متراجع هواي».

## Honest non-findings

* The hard-coded `app.js?v=v57` / `styles.css?v=v45` in `index.html` look like a violation of the
  house rule, but `server.mjs:13470` rewrites both to the file mtime at serve time. Harmless.
* `callAgentText` sends `nomem: true`, and `server.mjs:13004` excludes `nomem` calls from the paid
  Pro key. The classifier's move to `"pro"` costs latency, **not money**. The commit message's
  claim was wrong about the cost but right about the account.
* The 250 ms Firas Code timers (`cwTbTick`, `cwRunBarPaint`) each touch one text node and stop
  themselves; they are not a jank source.
* I found no defect behind complaint 6 (Agent/Code/Brain "هيج يعلس") that is specific to those
  three products. What they share with chat is the 6.76 MB payload, the 1.26 MB stylesheet's
  restyle cost, and the same streaming painter — findings 2 and the headline. I would rather say
  that than invent a fourth cause.
