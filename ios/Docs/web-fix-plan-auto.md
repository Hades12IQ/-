# Plan mode and the Auto/Plan switch — verified defects and fixable findings

Owner: **"التخطيط والتلقائي… تخطيط ما يشتغل عدل"**.

Source of truth for every line number below: `D:\Programming\Projects\FirasAI\app.js`,
`server.mjs`, `styles.css`, `index.html` on branch `night/capabilities-and-code-ui` (the deployed
tree, 5 796 169 bytes of app.js). The earlier analysis at `ios/Docs/web-plan-mode.md` was written
against the worktree copy (5 795 204 bytes); its line numbers have drifted by roughly +6 to +8 in
the plan-mode region. **Every claim below was re-checked against the current file**, and the regex
claim was re-executed under node.

Verdict up front:

* **Plan mode is genuinely broken**, in eight separate places, and two of them are severe enough
  to burn the owner's Manus credits or to silently discard the user's own brief.
* **Auto mode itself is not broken.** `MODES`, `setMode`, the default, the localStorage
  round-trip and the Auto request path are all correct. What the owner experiences as "التلقائي"
  misbehaving is (a) not being able to *see* that the device is stuck in Plan, and (b) a blocking
  pro-tier classifier call in front of every turn that both modes pay for. Both are covered below
  (F12, F22) and neither is a defect in Auto's own logic. Saying otherwise would be inventing a
  bug; see `.claude/skills/defect-triage-honesty/SKILL.md`.

---

## 0. Where the feature lives right now (current line numbers)

| Thing | app.js | Note |
|---|---|---|
| `MODES` registry | 2364-2367 | exactly `auto`, `plan` |
| `LS_MODE = "firas_ai_mode"` | 2400; read 3165-3166 | **device-global**, not per chat |
| `buildModeSwitch` | 15752-15777 | composer pill |
| `buildModeMenu` | 15780-15805 | the dropdown |
| `setMode` | 15854-15860 | validate → `state.mode` → localStorage → rebuild pill |
| Settings-sheet row (UI 2.0) | 19997-20009 | `أسلوب الردّ` / `Response style` |
| `csSyncBar` model pill | 20075-20113 | `cs-pill__b` = mode label |
| `renderThread` → pill | 23950 | `if (shouldShowPlanStart(msg)) turn.appendChild(planStartEl(msg))` |
| `qreplyEl` suppression | 26491 | |
| `planStartEl` | 29268-29285 | |
| `normalizeAskSpec` | 29298-29326 | |
| `parseFirasAsk` | 29331-29346 | |
| `decorateFirasAsk` | 29348-29389 | |
| `buildAskPanel` | 29392-29566 | |
| `buildAskSummary` | 29570-29587 | |
| `sendAskAnswer` | 29589-29594 | |
| `approvePlan` | 29597-29602 | |
| `precededByApproval` | 29624-29634 | regex on **29633** |
| `shouldShowPlanStart` | 29640-29651 | |
| `planning` flag | 37983 | drops `buildRule`+`engineerRule` |
| `userReqRule` / `_reqs` | 38109-38118, `_lastU` 38038 | |
| `planSystem` | 38156-38193; pushed 38215 | second `role:"system"` row |
| `fileTurnSystem` gate | 38218 | never injected in plan |
| `turnKind` | 41568-41574 | classified from the **last** user message |
| `planExecuting` | 41603 | |
| `codeTrigger` / `codeReq` | 41604-41614 | |
| `imgUser` | 41718-41720 | |
| `wantsSong` | 41853-41854 | **no plan gate** |
| `wantsVideo` | 42040 | **no plan gate** |
| `wantsImage` | 42177-42179 | |
| file pipeline gate | 42291 | `fileFmt && state.mode !== "plan"` |
| `problemOnlyTurn` | 42373 | disabled in plan |
| web search gate | 42447 | `else if (state.mode !== "plan")` |
| `aiMsg.mode = state.mode` | 44584 | assistant rows only |
| Agent stamps `mode` | 59567, 59596, 59680, 59805, 59824, 59872, 59876 | **the leak in F4** |
| Voice call forces auto | 49986-49987; restore 50084 | direct assignment, no rebuild |
| server durable save | server.mjs 2513-2537 | **drops `mode`** |
| server `sanitizeMessages` | server.mjs 2455 (`askAnswered`), 2465 (`mode`) | keeps both on a client PUT |
| edge parity | netlify/edge-functions/api.js 1667, 1669 | keeps both |

---

## 1. Findings

### F1 — A hand-typed Arabic approval is never recognised (critical)

`app.js:29633`

```js
  return /^(ابدأ|نفّذ|نفذ|go ahead|execute|start( executing)?|proceed)\b/i.test(text);
```

JS `\b` is ASCII-only. Arabic letters are non-word characters, so a `\b` placed after an Arabic
token requires a word/non-word transition that cannot exist. Re-run under node against this exact
source on the current file:

```
"ابدأ"                          false
"ابدأ التنفيذ"                  false
"ابدأ التنفيذ ونفّذ الخطة."      false   ← the pill's OWN sentence
"نفذ"                           false
"نفّذ الخطة"                     false
"يلا ابدأ"  "اي ابدأ"  "تمام"  "موافق"  "اوكي"  "كمل"  "زين"   all false
"go ahead"  "start"  "execute!"  true
"start with the basics"  "execute this python please"  "proceed to explain…"  true
```

The pill works only because of the exact-string comparison one line above (`29631`). Everything a
real Iraqi user types — `ابدأ`, `يلا`, `تمام`, `زين`, `اي نفذ`, `كمل`, `موافق` — falls through.
The file already warns about this at `app.js:2727-2728` ("Arabic has no \b word boundary, so never
wrap an Arabic token in \b — it would never match").

Consequence chain: `precededByApproval` false → `planExecuting` false (41603) → no code window, no
image, no file, `planSystem` still says *"Do NOT produce the final deliverable yet"* → the model
(which does read `ابدأ`) dumps the build as a fenced block in chat → and because
`shouldShowPlanStart` deliberately does not suppress on `replyContainsDeliverable` (29647-29650), a
**second** `ابدأ التنفيذ` pill appears under the finished build. That is exactly "تخطيط ما يشتغل عدل".

**Fix.** Replace the whole heuristic line with a normalising matcher. Anchor: the two lines

```js
  // Loose heuristic for hand-typed approvals.
  return /^(ابدأ|نفّذ|نفذ|go ahead|execute|start( executing)?|proceed)\b/i.test(text);
```

Replacement idea — add a helper `isApprovalPhrase(text)` immediately above `precededByApproval`
and call it here:

```js
function isApprovalPhrase(raw) {
  let s = String(raw || "")
    .replace(/[\u064B-\u0652\u0640]/g, "")        // tashkeel + tatweel
    .replace(/[أإآ]/g, "ا").replace(/ى/g, "ي").replace(/ة/g, "ه")
    .replace(/[.!?؟…،,]+\s*$/g, "")
    .trim().toLowerCase();
  if (!s) return false;
  if (s.split(/\s+/).length > 6) return false;    // long = a revision, not an approval
  const AR = ["ابدا","ابدا التنفيذ","ابدي","نفذ","نفذها","نفذ الخطه","كمل","كملها","سوي","سويها",
              "يلا","يلا ابدا","يالله","تمام","تمام نفذ","تمام ابدا","ماشي","موافق","اوكي","اوك",
              "اي","ايه","ايوه","زين","اكيد","طبعا","اتفقنا","ممتاز نفذ","خلص","هيه"];
  if (AR.some((a) => s === a || s.startsWith(a + " "))) return true;
  const EN = ["go ahead","go","start","start executing","execute","execute the plan","proceed",
              "do it","yes","ok","okay","approved","looks good","lgtm","build it","make it"];
  return EN.includes(s);
}
```

Two properties matter: Arabic prefixes are matched with an explicit `" "` separator instead of
`\b` (so `ابدأها` does not match), and English becomes **whole-message** membership instead of a
prefix — which also fixes F15.

---

### F2 — On the execute turn the client still tells the model "do NOT produce the deliverable yet" (critical)

`app.js:38156-38193` builds `planSystem`, `app.js:38215` pushes it. It is byte-identical on every
plan-mode turn: the clarify turn, the plan turn, **the execute turn**, and every follow-up.

Its first sentence is:

> "You are in PLAN MODE. This OVERRIDES any other instruction about producing code, a website, a
> document, or a file directly. Do NOT produce the final deliverable yet — EVEN if the request is
> to build a website/app or make a file."

Nothing anywhere in `streamAnswer` or `buildMessages` amends it when `planExecuting` is true.
`planExecuting` is computed at **41603**, inside `streamAnswer`, *after* `buildMessages` has
already been called for the head (`buildMessages` runs at 42370). The client changes only
**routing** on the execute turn; the **prompt** still forbids delivering. The model must infer
from history that STEP 3 applies, and STEP 3 is the last of three steps buried in a ~2 kB block
that opens with an override instruction telling it not to deliver.

This is the single most likely cause of the owner's report, because it fails the *same way on
every engine*: after approval the model re-states the plan, or asks one more question, or writes a
thin version. It also compounds F1 — when the approval is not detected, nothing about the request
changes at all.

**Fix.** In `buildMessages`, make the plan system message aware of the phase. Anchor: the
declaration line

```js
  const planSystem = state.mode === "plan" ? {
```

and the closing of that object, currently

```js
      "large, polished single-file build per the build rule (many sections, do not cut it " +
      "short). Always reply in the user's language.",
  } : null;
```

Replacement idea: compute the phase from the conversation the function was already handed
(`conversation` is the parameter at 37837 — no new state, no plumbing):

```js
  const _planExec = state.mode === "plan" && (() => {
    const u = [...conversation].reverse().find((m) => m && m.role === "user");
    return !!(u && isApprovalPhrase(String(u.content || "").trim()));
  })();
```

then append to `planSystem.content` when `_planExec`:

```
"\n\nTHE USER HAS ALREADY APPROVED THE PLAN ABOVE. You are now in STEP 3 and STEP 1/STEP 2 no longer apply: produce the COMPLETE final deliverable NOW, in this one reply, following the plan and the user's answers exactly. Do not ask any question, do not emit a firas-ask block, do not restate the plan, do not ask for approval again."
```

Note this deliberately reuses `isApprovalPhrase` from F1 so the prompt and the routing agree about
what an approval is. Ship F1 first; F2 depends on it.

---

### F3 — The durable server save deletes `mode`, so a recovered plan loses its Start pill (critical)

`server.mjs:2518`:

```js
  const msg = sanitizeMessages([{ role: "assistant", content: text, reasoning: reasoning || "", tier, lang, cid }])[0];
```

`saveAssistantTurn` rebuilds the row from six fields. The next lines (2523-2528) explicitly carry
`retryOf` and `retried` across from the row being replaced, precisely because a blind rebuild
"drops everything the client had already filed against that turn" — but **`mode` and `askAnswered`
were not added to that carry-over list**. `sanitizeMessages` itself does keep both (2455, 2465), so
this is purely the rebuild losing them.

The worker calls it at `server.mjs:11900` and `11915`; the stream-disconnect path at `13106`
(with `lang: ""`).

On the client the loss becomes visible through `refreshChatFromServer` (`app.js:2537`), whose
adopt-if-better rule replaces the array wholesale at **2568**:

```js
        chat.messages = msgs; chat.title = full.title || chat.title; chat._loadFailed = false;
```

It is called from `refreshActiveChatOnReturn` (2637) on every visibility/focus/pageshow and from
`flushResumeQueue` (2588) — i.e. **every time an Iraqi student comes back to the tab on a phone**.
The guest path is the same shape: `recoverGuestJobOnReturn` pushes
`{ role, content, reasoning, tier, lang }` at `app.js:2616` with no `mode`.

Result after any background/return cycle: `msg.mode` is `undefined` → `shouldShowPlanStart` returns
false at its first line (29641) → the plan is on screen with **no way to approve it except typing,
which F1 then rejects**. `isFileStreamReply` (3137) also stops treating the turn as plan-mode, and
the regenerate fold (46381) reads it as a different kind.

**Fix (two anchors, both required).**

1. `server.mjs`, inside `saveAssistantTurn`, anchor:

```js
    if (prev && prev.retryOf) msg.retryOf = prev.retryOf;
    if (prev && prev.retried) msg.retried = true;
```

append:

```js
    if (prev && typeof prev.mode === "string" && prev.mode) msg.mode = prev.mode;
    if (prev && prev.askAnswered === true) msg.askAnswered = true;
```

2. That only helps when a client PUT already created the row. For the tab-closed case the job
   record must carry the mode. `saveAssistantTurn`'s signature already takes `lang`; add a `mode`
   argument passed from `rec.mode`, stored when the job is started (`server.mjs:12633` is where the
   job record already normalises `lang` — the same place takes `mode`), and set it on `msg` before
   the upsert. Client side, `app.js:42618`'s request body (the `{messages, tier, think, cid,
   product, chatId, nokb}` object) gains `mode: state.mode`. Keep parity with
   `netlify/edge-functions/api.js`.

---

### F4 — The Start pill leaks into Firas Agent and spends Manus credits (critical)

`shouldShowPlanStart` (`app.js:29640-29651`) checks four things — `msg.mode === "plan"`, not
`offline`, non-empty content, no parseable `firas-ask`, not preceded by an approval. **It never
asks which product the message belongs to.**

`state.mode` is device-global (2400) and no code path resets it on a product switch. Firas Agent
stamps its own assistant rows with it at `app.js:59567, 59596, 59680, 59805, 59824, 59872, 59876`
(`mode: state.mode`). `renderThread` appends the pill for **any** message that passes, at
`app.js:23950`, and the branch chain above it (23904-23923) has no early return for agent/deck/
project/code cards — `turn.classList.add("msg-ai--agent-run")` at 23905 and then execution falls
straight through to 23950. `styles.css:1793-1815` has no rule hiding `.plan-start` under
`.msg-ai--agent-run`.

So: leave the device in Plan, run a mission, and a finished Firas Agent run card, a deck, a project
bundle or a Firas Code file gets an `ابدأ التنفيذ` pill under it. Tapping it calls `approvePlan`
(29597) → `sendMessage()` → `runAssistant` → `chat.agent` is true (44583) → `runAgentAssistant` →
`chargeUsage("agent", …)` at 59559. **A stray tap starts a whole new Manus mission and bills the
100-credit per-user ledger for the sentence "ابدأ التنفيذ ونفّذ الخطة."**

Worse: `styles.css:1344-1345` hides the mode selector on the Agent surface
(`.product-agent #modeSwitch, .product-agent #toolsMenu { display: none !important; }`), so the
user cannot even see, let alone turn off, the mode that is producing the pill.

**Fix.** Two independent guards; do both.

1. `app.js`, `shouldShowPlanStart`, anchor:

```js
function shouldShowPlanStart(msg) {
  if (!msg || msg.mode !== "plan" || msg.offline) return false;
```

insert after that line:

```js
  /* Plan mode is a feature of the ai chat product only. state.mode is device-global and the
     Agent stamps it onto its own rows, so without this an approval pill lands under a finished
     mission and tapping it bills a whole new Manus run. */
  const _c = activeChat();
  if (state.product !== "ai" || (_c && _c.agent)) return false;
  if (/^\s*```firas-(agent|deck|project|code|image|file)/.test(msg.content || "")) return false;
```

(`state.product`, `activeChat`, `chat.agent` all exist — 20087 uses this exact pair.)

2. `app.js`, `runAgentAssistant` and its siblings: stop stamping a chat-product field on agent
   rows. Anchor each of the seven `mode: state.mode,` occurrences in the 59560-59880 range and
   replace with `mode: "auto",`. This is the durable half — it also fixes rows already in the
   database only going forward, which is why guard 1 is still needed.

---

### F5 — The execute turn is classified from the word "ابدأ", so the deliverable and the user's own requirements are both lost (critical)

`app.js:41568-41574`:

```js
  const lastUserTurn = [...convo].reverse().find((m) => m.role === "user");
  const turnKind = lastUserTurn
    ? await classifyTurnIntent(lastUserTurn.content, {…}, signal)
    : "chat";
```

`lastUserTurn` on the execute turn is the approval sentence. Everything downstream that reads
`turnKind` therefore reads a verdict about `"ابدأ التنفيذ ونفّذ الخطة."`, which is `"chat"`:

* **Images** — `app.js:42177-42179`:
  ```js
    const wantsImage = turnKind === "image" ||
      (turnKind === "unavailable" && detectImageRequest(imgUser.content));
  ```
  `imgUser` (41718-41720) *correctly* looks back to the original request when `planExecuting`, but
  the gate reads the wrong turn. So an approved image plan produces an essay. Perversely it works
  only when the classifier is **down** (`"unavailable"`).

* **The user's brief** — `app.js:38038` `_lastU`, `38109` `_reqs`, `38110` `userReqRule`. The
  requirements are pinned to the last user message (41580-41589). On the execute turn that is the
  approval → `requirements` is `""` → `userReqRule` is the empty string. The rule whose own text
  says *"THESE OUTRANK EVERY RULE ABOVE"* is dropped on the exact turn that builds the deliverable.
  "exactly 20 problems", "titled X", "no repetition" — all silently gone at the moment they matter.

Only the **code** path was given the look-back treatment (`codeTrigger`, 41604-41606), which is why
website plans are the one kind of plan that mostly works.

**Fix.** Introduce one origin message and classify *that* on the execute turn. Anchor
`app.js:41568`:

```js
  const lastUserTurn = [...convo].reverse().find((m) => m.role === "user");
  const turnKind = lastUserTurn
```

Replacement idea — hoist `planExecuting` above the classifier (it currently sits at 41603, below;
it only needs `chat`, `aiMsg` and `precededByApproval`, all in scope by 41560), then:

```js
  const _planExecEarly = state.mode === "plan" && precededByApproval(chat, chat.messages.indexOf(aiMsg));
  const lastUserTurn = [...convo].reverse().find((m) => m.role === "user");
  /* THE ORIGIN, NOT THE APPROVAL. "ابدأ التنفيذ" is not a request for anything; classifying it
     hands every router the verdict "chat" and throws away the conditions the user actually set. */
  const originTurn = _planExecEarly
    ? ([...convo].reverse().find((m) => m.role === "user" && !isApprovalPhrase(String(m.content || "").trim())) || lastUserTurn)
    : lastUserTurn;
  const turnKind = originTurn ? await classifyTurnIntent(originTurn.content, {…}, signal) : "chat";
```

and pin `intent`/`requirements` onto `originTurn` instead of `lastUserTurn` at 41575 and 41580, so
`_lastU` in `buildMessages` still finds them — or, cleaner, also change `_lastU` (38038) to prefer a
message carrying `requirements`. Delete the now-redundant `planExecuting` at 41603 and reuse
`_planExecEarly`.

---

### F6 — A file plan can never be executed (major)

Three independent blocks, all in the same path:

1. `app.js:3044-3052`, `requestedFormatForAssistant` returns at the **first** user message above the
   reply:
   ```js
       if (m.role === "user") return resolvedFileFormat(m);
   ```
   On the execute turn that message is the approval. `resolvedFileFormat` (3034) reads
   `m.intent`, which F5 already set to `"chat"` → `turnIntentIsDocument("chat")` is false → `null`.
2. `app.js:42291` — `if (fileFmt && state.mode !== "plan")` hard-disables the 3-agent file pipeline
   for every plan-mode turn, execute included.
3. `app.js:38218` — `if (fileTurnSystem && state.mode !== "plan") head.push(fileTurnSystem)`; the
   per-format guidance is never injected.

So `سوي لي ملف PDF عن…` in Plan mode: asks questions, writes a plan, and then the approval produces
plain chat markdown with no file card and no download. In Auto the same request works. The
`isFileStreamReply` masking rule (3137) is written to mask *only* the execution reply — but per (1)
there is never a format to mask with, so that branch is dead code today.

**Fix.** With F5 landed, (1) resolves itself if `requestedFormatForAssistant` skips approvals.
Anchor `app.js:3050`:

```js
    if (m.role === "user") return resolvedFileFormat(m);
```

replace with:

```js
    if (m.role !== "user") continue;
    /* An approval is not a request. Walk past it to the message that actually named a format. */
    if (isApprovalPhrase(String(m.content || "").trim())) continue;
    return resolvedFileFormat(m);
```

Then relax (2) and (3) to allow the execute turn, mirroring the image/code gates that already read
`(state.mode !== "plan" || planExecuting)`:

* 42291 → `if (fileFmt && (state.mode !== "plan" || planExecuting)) {`
* 38218 → the gate needs the same `_planExec` computed for F2:
  `if (fileTurnSystem && (state.mode !== "plan" || _planExec)) head.push(fileTurnSystem);`

---

### F7 — `planSystem` is a second `role:"system"` row, which several engines weight differently (major, unmeasured)

`app.js:38215`:

```js
  const head = [system];
  if (planSystem) head.push(planSystem);
```

`server.mjs:12924-12926` states the house knowledge in its own comment, about memory:

> "Merge memory INTO the first system message (not a separate one) — some models (e.g. the coder
> model on Ultra) ignore a second system message."

Provider survey in `server.mjs`: only `streamAnthropic` collapses them —
`server.mjs:6798` `const system = messages.filter((m) => m.role === "system").map(…).join("\n\n");`.
Gemini (6689-6696, through the OpenAI-compatible endpoint `_geminiStream` 6564),
DeepSeek/NVIDIA (6703), OpenAI Pro (6961), OpenRouter (7107) and Cloudflare (7214) all forward the
two `role:"system"` rows untouched. Whether STEP 1-3 is honoured is then entirely up to the
upstream model, and on a tier where it is not, plan mode is silently Auto — the model builds
immediately, the reply still carries `mode:"plan"`, and a Start pill appears under a finished
deliverable (which F1 then makes un-approvable).

I have not measured which engines ignore it. The fix is safe either way and costs nothing.

**Fix.** Concatenate instead of pushing. Anchor `app.js:38215`:

```js
  const head = [system];
  if (planSystem) head.push(planSystem);
```

replace with:

```js
  const head = [system];
  /* CONCATENATED, NOT PUSHED. server.mjs merges the memory block into the FIRST system message for
     exactly this reason (see its comment at the memoryBlock injection): several engines weight a
     second system row far below the first, and on those tiers plan mode silently became Auto. */
  if (planSystem) head[0] = { role: "system", content: String(system.content || "") + "\n\n" + planSystem.content };
```

The server still prepends `IDENTITY_BLOCK` (12913) and appends memory (12927) to that same message,
which is fine.

---

### F8 — Submit and Start are contaminated by a quote pill, an attachment, or the user's draft (major)

`app.js:29589-29602`:

```js
function sendAskAnswer(summary, lang) {
  if (state.streaming) return;
  els.input.value = summary;
  autoGrow(); updateSendState();
  sendMessage();
}
…
function approvePlan(lang) {
  if (state.streaming) return;
  els.input.value = STR[lang] ? STR[lang].planApproval : t().planApproval;
  autoGrow(); updateSendState();
  sendMessage();
}
```

Both hijack the composer. `sendMessage` (`app.js:44424`) then reads:

```js
  const text = typed ? (quotePrefix() + typed) : "";
```

Three distinct losses:

* **Quote pill** — if the user had selected a passage of the plan to quote before tapping Start, the
  outgoing message becomes `«…quoted passage…»\n\nابدأ التنفيذ ونفّذ الخطة.`. The exact-string
  comparison in `precededByApproval` (29631) fails and, after F1, the prefix also defeats a
  starts-with matcher. The turn is not an execution turn.
* **Attachments** — `pendingImages`/`pendingFiles` (44427, 44429) ride along, so a file attached
  while reading the plan is re-sent with the approval.
* **The draft** — `els.input.value = …` destroys whatever the user had typed, with no undo. That
  alone reads as "not smooth".

**Fix.** Give both functions their own send path instead of borrowing the composer. Anchors are the
two function bodies above. Replacement idea — a shared helper placed next to them:

```js
/** Send ONE exact sentence as its own user turn: no quote prefix, no attachments, and the
    reader's draft left exactly where it was. */
function sendPlanTurn(text) {
  if (state.streaming || !String(text || "").trim()) return;
  const draft = els.input.value;
  const hadQuote = (typeof _quoteStack !== "undefined") && _quoteStack.length;
  try { quoteClear(); } catch (_) {}
  els.input.value = text;
  autoGrow(); updateSendState();
  sendMessage();
  /* The draft goes back the moment sendMessage has read the box. sendMessage clears it itself,
     so this restores rather than duplicates. */
  setTimeout(() => { if (!els.input.value) { els.input.value = draft; autoGrow(); updateSendState(); } }, 0);
}
```

`quoteClear` and `_quoteStack` both exist (`quotePrefix` at 22793 reads `_quoteStack`;
`sendMessage` calls `quoteClear()` at 44468). Verify both names before writing the patch.

---

### F9 — The choice panel marks itself "تم الإرسال" before the send has actually happened (major)

`app.js:29546-29559`:

```js
    const summary = buildAskSummary(groups, extra.value, lang);
    if (!summary) return;
    msg.askAnswered = true;
    panel.classList.add("is-answered");
    nextBtn.disabled = true;
    …
    nextBtn.innerHTML = `<span>${escapeHtml(S.askAnswered)}</span>…`;
    sendAskAnswer(summary, lang);
```

and `planStartEl` at 29278-29282:

```js
    btn.disabled = true;
    wrap.remove();
    approvePlan(lang);
```

Both commit the UI state change **before** calling `sendMessage`, and `sendMessage` has five
early-return paths after that point: `activeChatIsStreaming()` (44432), the Agent-guest gate
(44437), the live-Agent-job gate (44446), and `dfxAskGate(text)` (44467). Any of them leaves the
panel locked at `تم الإرسال` — or the pill gone — with nothing sent and no way back except a
re-render.

The realistic combination is with F4: a **guest** taps the leaked Start pill inside an Agent chat →
the pill is already removed from the DOM → `sendMessage` hits the Agent-guest gate and opens the
sign-up prompt → the pill never comes back.

`dfxAskGate` (37813) is a plausible second trigger for the Submit case: the summary
`اختياراتي — نوع المسائل: تفاضل؛ العدد: ١٠` can satisfy `wantsGeneratedProblems`, in which case the
message is held in the composer for a difficulty choice while the panel already says it was sent.
I have not reproduced this one; it depends on `wantsGeneratedProblems` and `dfxSubject`.

**Fix.** Make `sendMessage` report whether it sent, and commit the UI only on success. `sendMessage`
is `async` and currently returns `undefined` on every path; add `return false;` at each early return
and `return true;` at the end (anchor the final `await runAssistant(chat, state.tier, lang, undefined, true);`).
Then in the panel:

```js
    const ok = await sendAskAnswer(summary, lang);   // sendAskAnswer returns sendMessage()'s result
    if (!ok) return;                                  // nothing changed; the panel stays live
    msg.askAnswered = true;
    …
```

and in `planStartEl`, only `wrap.remove()` after `approvePlan` resolves truthy; otherwise
`btn.disabled = false`.

---

### F10 — Song and video requests bypass plan mode entirely (major)

Every other media router in `streamAnswer` carries the plan gate:

* edit-image `app.js:41741` — `(state.mode !== "plan" || planExecuting)`
* media intent `app.js:41793` — same
* image `app.js:42179` — same
* code `app.js:41612` — same
* file `app.js:42291` — `state.mode !== "plan"`

**Song and video do not.**

```js
41853:    const wantsSong = turnKind === "song"
41854:      || (turnKind === "unavailable" && songAskedPlainly(_songAsk));
41855:    if (wantsSong) {
…
42040:    const wantsVideo = turnKind === "video" || (turnKind === "unavailable" && mediaIntent === "video");
42041:    if (wantsVideo) {
```

Both branches sit **above** the image branch, so in Plan mode a song or video request runs its
pipeline immediately — no questions, no plan, no approval. The mode pill says تخطيط and the app
behaves as Auto. That is not a crash, but it is precisely the class of inconsistency that makes a
user say the switch does nothing.

**Fix.** Anchor `app.js:41855`:

```js
    if (wantsSong) {
```
→
```js
    if (wantsSong && (state.mode !== "plan" || planExecuting)) {
```

and `app.js:42041`:

```js
    if (wantsVideo) {
```
→
```js
    if (wantsVideo && (state.mode !== "plan" || planExecuting)) {
```

Both `state.mode` and `planExecuting` are in scope at those lines (`planExecuting` is declared at
41603). Note this is only correct **after F5**, because until then `turnKind` on the execute turn is
`"chat"` and `wantsSong`/`wantsVideo` would be false anyway — the gate would turn "works, but
ignores plan mode" into "never works". **Ship F5 and F10 together, in that order.**

---

### F11 — There is no exit from the plan cycle, and homework requests are collateral (major)

`planSystem` is attached whenever `state.mode === "plan"` (38156). Nothing looks at whether a
deliverable has already been handed over. After a build lands, `غيّر اللون` starts STEP 1 again.

Two named side effects make this hurt more than it should:

* `app.js:2851`, `codeFollowupSpec`:
  ```js
  if (!Array.isArray(convo) || state.mode === "plan") return null;
  ```
  so a follow-up edit cannot continue inside the same code box — it leaks into chat as a new plan.
* `app.js:42373`, `problemOnlyTurn`:
  ```js
  const problemOnlyTurn = state.mode !== "plan" && wantsGeneratedProblems(_speedText) && …
  ```
  the compact problem-list prompt is disabled in Plan. For a student who left Plan on, **every
  `اعطني ١٠ مسائل تفاضل` becomes a questionnaire** instead of ten problems, and it arrives with the
  full ~38 kB house prompt instead of the compact one. This is the most common shape of request
  this product serves, and it is the most likely single explanation for
  "متراجع هواي… استخدامه صاير مو سلس".

**Fix (smallest safe version).** In `buildMessages`, skip `planSystem` when the previous assistant
turn was already an execution reply. Anchor the `planSystem` declaration line at 38156 and gate it:

```js
  /* A DELIVERED PLAN IS A FINISHED PLAN. Without this, every small follow-up after the build
     restarts STEP 1 and the reader is asked four questions to change a colour. */
  const _planDelivered = (() => {
    const i = conversation.map((m) => m && m.role).lastIndexOf("assistant");
    if (i < 1) return false;
    const u = conversation[i - 1];
    return !!(u && u.role === "user" && isApprovalPhrase(String(u.content || "").trim()));
  })();
  const planSystem = (state.mode === "plan" && !_planDelivered) ? { … } : null;
```

Also relax the two collateral gates so a delivered cycle behaves like Auto: 2851 →
`if (!Array.isArray(convo)) return null;` guarded by a delivered check passed in, and 42373 →
`const problemOnlyTurn = wantsGeneratedProblems(_speedText) && …` (drop the mode clause entirely —
a problem list has no plan to make, and `planSystem` will simply be ignored for it).

---

### F12 — On a phone the user cannot tell which mode is on (major)

`styles.css:3100-3112`:

```css
@media (max-width: 420px) {
  …
  .mode-select__trigger .mode-name { display: none; }
```

Under 420 CSS px — which covers most phones actually in use in Iraq — the composer pill is
**icon-only**. The two icons are `ICONS.modeAuto` (a lightning bolt) and `ICONS.modePlan` (a
clipboard with a check) at 15px (`styles.css:2849`), and `.mode-select__trigger` has **no
plan-specific colour**: reviewing `styles.css:2833-2857`, the only state rules are `:hover` and
`[aria-expanded="true"]`. Two small monochrome glyphs at 15px in a crowded composer is not a mode
indicator.

Add to that:
* `state.mode` is device-global and permanent (`LS_MODE`, 2400) — once set, it survives every
  reload, every chat and every product until the user finds the pill again.
* No message in the thread is marked as a plan-mode reply. There is no badge, no tint, nothing.
* Under UI 2.0 the composer pill is removed entirely (`styles.css:13928`
  `:root[data-ui="2"] .composer__bar .mode-select { display: none; }`) and replaced by
  `cs-pill__b` (20105-20110) — which *does* carry the word, so UI 2.0 is actually better here.

This is why the owner's users are in Plan mode without knowing it, and why they report the product
as regressed rather than as "I picked a mode".

**Fix.** Three cheap changes.

1. `styles.css:3110` — delete `.mode-select__trigger .mode-name { display: none; }` and instead
   shorten the label the way the tier strip already does (`styles.css:3101-3102` uses
   `content: attr(data-short)`). Even at 420px, `تخطيط` is 5 glyphs.
2. Give the trigger a state class. In `buildModeSwitch` (`app.js:15759-15769`), anchor
   `trigger.className = "mode-select__trigger";` → `trigger.className = "mode-select__trigger" + (cur.key === "plan" ? " is-plan" : "");`
   and add `styles.css`: `.mode-select__trigger.is-plan { color: var(--color-accent); border-color: color-mix(in srgb, var(--color-accent) 55%, var(--color-border-hairline)); background: var(--color-accent-soft); }`
3. Mark the reply. In `aiTurnEl`, anchor `if (shouldShowPlanStart(msg)) turn.appendChild(planStartEl(msg));`
   (23950) and add above it `if (msg.mode === "plan") turn.classList.add("msg-ai--plan");`, then a
   quiet left/right rule in `styles.css` near `.plan-start` (1793).

---

### F13 — The settings row promises a submenu and silently flips the mode instead (major)

`app.js:19997-20009`:

```js
    const cur = MODES[state.mode] || MODES.auto;
    body.appendChild(csCard([
      csRow({
        title: ar ? "أسلوب الردّ" : "Response style",
        value: cur.label(L),
        chevron: true,
        onClick: () => {
          try { setMode(state.mode === "auto" ? "plan" : "auto"); } catch (_) {}
          csSyncBar();
          close();
        },
      }),
    ]));
```

`chevron: true` is the affordance every other row in this sheet uses for "opens a submenu" —
"لغة الإملاء" (20066-20072) and "إضافة ملفات" (20025-20028) both use it and both open something.
This one **toggles and closes the sheet**. A user tapping it to look at the options ends up in Plan
mode and the sheet is gone before they can read what happened. That is a plausible mechanism for
how a whole population of users ends up in Plan without having chosen it.

**Fix.** Replace the single row with two check rows, exactly like the tier rows directly above it
(19984-19992 already build `csRow({ title, sub, check, onClick })` from a registry). Anchor the
`body.appendChild(csCard([ csRow({ title: ar ? "أسلوب الردّ" …` block and replace with:

```js
    body.appendChild(csCard(Object.values(MODES).map((m) => csRow({
      title: m.label(L),
      sub: m.hint(L),
      check: m.key === state.mode,
      onClick: () => { try { setMode(m.key); } catch (_) {} csSyncBar(); close(); },
    }))));
```

`csRow`'s `check` and `sub` options are both already used two lines above, so nothing new is
invented.

---

### F14 — `shouldShowPlanStart` asks the wrong conversation (major)

`app.js:29644`:

```js
  const chat = activeChat();
  const index = chat && Array.isArray(chat.messages) ? chat.messages.indexOf(msg) : -1;
  if (precededByApproval(chat, index)) return false; // this is the delivery reply
```

`finalizeAi` calls it at 43211 with only `aiMsg` — it has `chat` right there in scope but does not
pass it. If the user switched conversations while the answer streamed (the normal case: streams are
tied to the chat, not the view — 44581's comment says so explicitly), `indexOf` is `-1`,
`precededByApproval(chat, -1)` returns false at its `index < 1` guard, and **the delivery reply gets
an approval pill**. Tapping it re-sends the approval and re-runs the whole build.

**Fix.** Thread the chat through. Anchor the signature `function shouldShowPlanStart(msg) {` →
`function shouldShowPlanStart(msg, chatArg) {`, and the body line
`const chat = activeChat();` → `const chat = chatArg || activeChat();`. Then update the three call
sites to pass it: `app.js:23950` (`shouldShowPlanStart(msg, chat)` — `chat` is the parameter of the
render function), `app.js:43211` (`shouldShowPlanStart(aiMsg, chat)`), and `app.js:26491` inside
`qreplyEl`, which has no chat — give `qreplyEl` the same optional second argument or leave it, since
a wrong answer there only costs a chip row.

---

### F15 — English false positives flip ordinary questions into execution routing (major)

Same regex, `app.js:29633`. `^start\b`, `^execute\b`, `^proceed\b`, `^go ahead\b` are **prefix**
matches. Verified under node on the current source:

```
"start with the basics"          true
"execute this python please"     true
"proceed to explain the next part" true
```

Any of these, typed as the message before an assistant reply in a plan-mode chat, makes
`precededByApproval` true → `planExecuting` true (41603) → `codeTrigger` is looked up from a
*different, earlier* message (41604-41606) and the turn is routed to the code window for a request
the user never made. The mirror image of F1: Arabic never matches, English matches too much.

**Fix.** Covered by F1's `isApprovalPhrase`: English becomes whole-message membership
(`EN.includes(s)`) with a ≤6-word cap. `"start with the basics"` is 4 words but is not in the list,
so it correctly returns false.

---

### F16 — Web search is off on every plan turn, including the execute turn (minor)

`app.js:42447`:

```js
    } else if (state.mode !== "plan") {
```

The entire search block — explicit toggle, `needsWebSearch`, i'rab lookup and the silent factual
search — is skipped for all plan-mode turns. Suppressing it during clarify/plan is reasonable.
Suppressing it on the **execute** turn is not: an approved "اعمل لي تقرير عن…" is built entirely
from the model's own memory, while the same request in Auto gets live results. (The code branch has
its own narrow `siteNeedsFreshFacts` lookup at 42431, so websites are partly exempt.)

**Fix.** Anchor `app.js:42447` → `} else if (state.mode !== "plan" || planExecuting) {`.

---

### F17 — The execute turn is missing the build rules its own prompt cites (minor→major, narrow)

`app.js:37983`:

```js
  const planning = state.mode === "plan";
```

used at 38148:

```js
        : model.persona + … + tikzRule+ (planning ? "" : buildRule + engineerRule) + finishRule + userReqRule,
```

`buildRule` and `engineerRule` are omitted on **every** plan-mode turn, while `planSystem` STEP 3
(38190-38192) instructs: *"deliver the COMPLETE, large, polished single-file build **per the build
rule** (many sections, do not cut it short)"* — a rule that is no longer in the prompt.

Honest scope: for a **website** execute turn this does not bite, because `codeReq` (41612) rebuilds
the request from scratch at 42411 — `requestMessages = [{ role: "system", content: codeSystemPrompt(codeReq) }, ...codeConvo]`
— discarding the base system and `planSystem` entirely. The damage is confined to execute turns
that stay in chat: reports, essays, study plans, long documents. Those are exactly the turns F6
already prevents from becoming files, so the two compound into "the plan executes as a short chat
answer".

**Fix.** With F2's `_planExec` in hand, anchor `app.js:37983`:

```js
  const planning = state.mode === "plan";
```
→
```js
  /* Only the CLARIFY and PLAN turns drop the build rules. The execute turn is a build, and
     planSystem's STEP 3 explicitly tells the model to follow "the build rule" — which used to
     have been removed from the prompt by the time it read that sentence. */
  const planning = state.mode === "plan" && !_planExec;
```

`_planExec` must be declared above line 37983 for this (it is currently proposed near 38156 for F2 —
move the declaration up, it only needs `conversation`, which is the function parameter).

---

### F18 — Every rejected tap is silent (minor)

`app.js:29542` (Back), `29548` (Next/Submit), `29550` (`if (!summary) return;`), `29591`
(`sendAskAnswer`), `29598` (`approvePlan`), `29279` (the pill) all `return` with no feedback while
`state.streaming` is true or when nothing is selected. `state.streaming` is correctly scoped to the
active chat (`syncStreamingUi`, 43959: `state.streaming = !!activeStreams.get(activeChat().id)`), so
this is not a stuck-flag bug — it is purely a dead-button bug: the user taps `تأكيد الاختيارات`
while an answer is still writing and nothing at all happens.

**Fix.** `showToast(t().streaming)` at each guard (`t().streaming` exists — `syncStreamingUi` uses
it at 43965), and disable `nextBtn` when `buildAskSummary` would return `""` (recompute on every
input `change` event on the panel).

---

### F19 — The ask parser is fence-strict (minor)

`app.js:29332`:

```js
  const m = content.match(/```[ \t]*firas-ask[ \t]*\r?\n([\s\S]*?)```/i);
```

Requires the literal tag `firas-ask` and a line break immediately after it. A ```` ```json ```` fence
with the identical body, an info string like ```` ```firas-ask json ````, or a fence indented inside
a list item all fail → `parseFirasAsk` returns null → `decorateFirasAsk` (29356-29368) reveals raw
JSON to the user **and** `shouldShowPlanStart` then shows a Start pill over it.

The system is partly self-healing: `maskFirasAsk`'s open-form regex (`app.js:3813`,
`/```[ \t]*firas-ask[ \t]*[\s\S]*$/i`) has no newline requirement, so the loader still appears and
the reveal path fires. Nothing gets permanently stuck. But the interactive panel is lost.

The `<pre>` fallback at 29373-29379 does not help: it only picks *where* to mount the panel and runs
after `parseFirasAsk` has already returned null.

**Fix.** Anchor 29332 and widen to a two-stage parse: try the strict regex first, then
`/```[ \t]*(?:firas-ask|json)[^\n]*\r?\n([\s\S]*?)```/i`, and hand each candidate body to
`normalizeAskSpec` — which already returns `null` for anything without a valid `questions` array, so
a genuine `json` block cannot be misread as an ask panel. Keep `maskFirasAsk` in step or the loader
and the parser will disagree about which block was hidden.

---

### F20 — A voice call mutates `state.mode` without rebuilding the pill (minor)

`app.js:49986-49987`:

```js
  call.prevMode = state.mode;
  if (state.mode !== "auto") { state.mode = "auto"; }  // no plan-mode clarifying turns mid-call
```

and the restore at `50084`:

```js
  if (call.prevMode && MODES[call.prevMode]) state.mode = call.prevMode;
```

Both assign `state.mode` directly rather than through `setMode` (15854), so `buildModeSwitch` never
runs and the composer pill keeps whatever label it had. During the call the call screen covers the
composer so nothing is visible, and `callEnd` restores correctly — so the practical impact is
limited to a call that ends through a path that does not reach `callEnd` (a thrown error), after
which the session runs Auto while the pill and localStorage both say تخطيط until the next reload.
`state.tier` and `state.think` on the adjacent lines (49993-49994) have exactly the same shape.

**Fix.** Anchor `50084` and add `try { buildModeSwitch(); csSyncBar(); } catch (_) {}` after the
three restores, and wrap the call-open assignment the same way. Do not route through `setMode` — it
writes localStorage, and a call must not change the user's saved preference.

---

### F21 — `askAnswered` is only persisted by the next turn (minor)

`app.js:29550` sets `msg.askAnswered = true` on the in-memory message and never calls `persistChat`.
The flag reaches the server only when the *next* turn finalizes and PUTs the array
(`serializeMessages` at 3527 does carry it, and both backends keep it — server.mjs:2455,
api.js:1667). A user who submits and immediately closes the tab comes back to the panel asking the
same questions again; answering twice re-runs the plan.

**Fix.** Anchor the submit handler's `msg.askAnswered = true;` (29550) and add
`try { persistChat(activeChat()); } catch (_) {}` — but only after F9's success check, so a send
that never happened is not persisted as answered.

---

### F22 — Both modes pay a blocking, un-timed pro-tier model call before the first token (minor here, major for the speed lens)

`app.js:41568-41573` awaits `classifyTurnIntent` before anything is streamed.
`_classifyTurn` (4132) calls `callAgentText(…, "pro", signal)` (4273) — deliberately `"pro"`, not
`"mini"`, per its own comment at 4269-4272. `callAgentText` (38820) has **no timeout of its own**;
it is bounded only by `streamAnswer`'s 900 000 ms abort (41543). The cache (4160) is keyed on the
first 6000 chars, so it never helps a fresh message. `turnRequirementsOf` (41582) awaits the same
promise, so it is free.

This belongs to the speed lens, but it is worth recording here for one plan-specific reason: **on a
plan-mode clarify or plan turn the verdict is used by nothing.** Every consumer of `turnKind`
(41610, 41742, 41791, 42177) is gated on `state.mode !== "plan" || planExecuting`, and after F10 so
are song and video. Only `requirements` is read. So Plan mode pays a full pro-tier round trip in
front of a turn whose routing it cannot affect — which is exactly the stall the owner describes
("من اريد ارسل رسالة يوكف ويشتغل يرد").

**Fix (for the speed lens to own).** Race the classifier against a short budget:
`Promise.race([classifyTurnIntent(…), new Promise((r) => setTimeout(() => r("unavailable"), 2500))])`.
`"unavailable"` is already the designed degradation — every consumer has an `unavailable` fallback
branch (41854, 42040, 42178). Anchor `app.js:41569-41574`.

---

### F23 — `shouldShowPlanStart` is O(n) per message, called twice per message per render (minor)

`app.js:29643-29645` runs `parseFirasAsk(msg.content)` (a regex over the whole answer) and
`chat.messages.indexOf(msg)` (a linear scan) for every assistant message. `renderThread` calls it
once at 23950 and again inside `qreplyEl` at 26491 — so a 200-message thread does 400 full-array
scans and 400 regexes per render. Not the cause of any reported bug, but it is free to fix and this
render path is on the owner's jank list.

**Fix.** In `aiTurnEl`, compute it once and pass the result down; `qreplyEl` already receives `msg`
and can take a boolean. And short-circuit `parseFirasAsk` behind the existing
`content.indexOf("firas-ask") === -1` early-out (which is already there at 29332 — the real cost is
the `indexOf` on the array, which F14's `chatArg` plus the `index` already computed in `aiTurnEl`
removes entirely).

---

## 2. What the prior analysis got right, and what changed

Verified unchanged and still true: D1 (F1), D2 (F7), D4 (F6), D5 (F5), D6 (F3), D7, D8 (F14),
D9 (F18), D10 (F15), D11 (F19), D12 (F11), D13 (F8), D14 (F4). Every line number in that document
has drifted by +6 to +8 in the 29xxx and 38xxx ranges and by +7 in the 41xxx-44xxx range.

Corrections and additions:

* **D3 was overstated.** The claim "the execute turn drops the build rules" is true of the prompt
  but does not affect website builds, because the code branch (42411) replaces the entire request
  with `codeSystemPrompt(codeReq)`. Restated honestly as F17.
* **New: F2** — nothing tells the model that STEP 3 has begun. The prior document noted in passing
  that `planSystem` is identical on every turn; it did not draw the conclusion that the execute turn
  ships an active "do NOT produce the deliverable" instruction. This is likely the largest single
  cause of the owner's complaint.
* **New: F5's second half** — `userReqRule` (38109) is also computed from the approval sentence, so
  the user's explicit conditions are dropped on the deliverable turn. Not in the prior document.
* **New: F10** — `wantsSong` (41853) and `wantsVideo` (42040) have no plan gate at all, unlike every
  other router. Not in the prior document.
* **New: F11's second half** — `problemOnlyTurn` (42373) is disabled in Plan, which turns every
  homework request into a questionnaire. Not in the prior document, and it is the finding most
  likely to explain "متراجع هواي".
* **New: F12, F13** — the discoverability half. The prior document listed where the controls are but
  did not test whether a user can see which mode is on (they cannot, under 420px) or whether the
  settings row can flip the mode by accident (it can).
* **New: F9** — the panel/pill commit their UI state before the send is known to have happened.
* **New: F3's exact mechanism** — the prior document said `saveAssistantTurn` "drops mode"; the
  precise fix is that its existing `prev.retryOf` / `prev.retried` carry-over block (server.mjs
  2523-2528) simply needs `mode` and `askAnswered` added, plus the job record carrying `mode` for
  the tab-closed case.
* **New: F4's cost** — tapping the leaked pill in an Agent chat calls `chargeUsage("agent", …)`
  (59559). The prior document noted the leak; it did not note that it spends Manus credits.

## 3. Is Auto broken?

No. Traced end to end and found nothing:

* `MODES` (2364) has exactly the two keys; `state.mode` is read at 3165-3166 with an unknown value
  normalised to `"auto"`; `setMode` (15854) validates against `MODES` before writing.
* Every gate in `streamAnswer` is written as `state.mode !== "plan"` or
  `(state.mode !== "plan" || planExecuting)`, so Auto is the unrestricted path by construction —
  there is no Auto-only branch that can fail.
* `aiMsg.mode = state.mode` (44584) stamps `"auto"`, `shouldShowPlanStart` returns false on its
  first line, `isFileStreamReply`'s plan clause (3137) is skipped, `codeFollowupSpec` (2851) runs.
* The regenerate fold's mode comparison (46381) treats a missing `mode` as `"auto"`, which is the
  correct reading for every row written before the field existed.

The one real cost Auto carries is F22, and it is shared with Plan. Everything else the owner
attributes to "التلقائي" is F12 and F13: users are in Plan without knowing it, so Auto's behaviour
is what they are *missing*, not what is broken.

## 4. Suggested order

1. **F1** — the approval matcher. Everything downstream (F2, F5, F6, F11, F15) depends on
   `isApprovalPhrase` existing.
2. **F5**, then **F10** together — classify from the origin, then gate song/video.
3. **F2** and **F17** — the execute-turn prompt.
4. **F4** and **F14** — stop the pill appearing where it must not.
5. **F3** — the durable round trip (server.mjs + edge parity + the job record).
6. **F8**, **F9** — the send path.
7. **F6**, **F16**, **F11** — file execution, search, exit.
8. **F12**, **F13**, **F18** — the visible half.
9. **F7**, **F19**, **F20**, **F21**, **F22**, **F23**.

All app.js/server.mjs/styles.css edits go through the patch-script method in `AGENTS.md`
(`assert s.count(a) == 1`, dry-run, `node --check`). Several of these findings touch the same
functions — F1/F2/F11/F17 all edit `buildMessages`, F5/F10 both edit `streamAnswer`'s classifier
region — so anchor precisely and re-read the file between patches; see
`.claude/skills/patch-script-authoring/SKILL.md` on anchor drift.
