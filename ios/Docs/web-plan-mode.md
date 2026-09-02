# Plan mode — web behaviour, defects, and the native state machine

Slice: the "تخطيط / Plan" response mode of Firas AI (product `ai` only). Sources are
`app.js` (client), `server.mjs` (API), `index.html`, `styles.css` at the worktree root. All line
numbers are from the current worktree and drift; grep the identifier when in doubt.

Owner's report: "plan mode is broken on the site". Section 6 lists every defect found by tracing
the code, with evidence. Section 7 gives the native state machine that must work even where the
site does not.

---

## 1. Where plan mode lives on the web

| Thing | Location | Notes |
|---|---|---|
| `MODES` registry | app.js:2364-2367 | exactly two keys: `"auto"`, `"plan"`. Each has `icon`, `label(l)`, `hint(l)` |
| Device pref | `LS_MODE = "firas_ai_mode"` app.js:2400; read app.js:3165-3166 (default `"auto"`, unknown value → `"auto"`) | **Global per device, not per chat.** |
| `setMode(key)` | app.js:15854-15859 | validates against `MODES`, sets `state.mode`, writes localStorage, rebuilds the composer pill, `csSyncBar()` |
| Composer pill | `index.html:782` `<div class="mode-select" id="modeSwitch">`; `buildModeSwitch` app.js:15752-15778; menu `buildModeMenu` app.js:15780-15805; open/close/keyboard 15807-15853 | trigger shows icon + label + caret, `title` = hint; menu `role="menu"`, items `role="menuitemradio"` with label + hint + check; ArrowUp/Down opens, Escape/Tab closes, Enter/Space picks. The pill is never hidden per product — `state.mode` is not reset when switching to Agent/Code/Brain (no such write exists; see D14) |
| Settings sheet row | `csModelSheet` app.js:19980, the row at 19997-20009 | row title `"أسلوب الردّ"` / `"Response style"`, value = current mode label; **tapping toggles** auto↔plan (no submenu) and closes the sheet |
| Compact pill (UI 2.0) | app.js:20103-20112 | `cs-pill__b` text = mode label |
| Voice call | app.js:49979-49980, restore 50077 | a call forces `state.mode = "auto"` and restores the previous mode at hang-up ("no plan-mode clarifying turns mid-call") |
| Assistant message tag | app.js:44577 `mode: state.mode` | stamped on every **assistant** placeholder at creation; user messages carry **no** mode (app.js:44480) |
| Persistence | client serializer app.js:3521 (`mode`) and 3527 (`askAnswered`); client sanitizer app.js:3573; server `sanitizeMessages` server.mjs:2455 (`askAnswered === true`), 2465 (`mode` string ≤ 20 chars) | both survive a normal client PUT and a reload |

### 1.1 i18n strings (verbatim)

| key | ar (app.js:597, 641-657) | en (app.js:1698, 1742-1758) |
|---|---|---|
| modeLabel | `النمط` | `Mode` |
| modeAuto | `تلقائي` | `Auto` |
| modeAutoHint | `ذكي ومباشر — يجيب فورًا.` | `Smart & direct — answers right away.` |
| modePlan | `تخطيط` | `Plan` |
| modePlanHint | `يسأل ويضع خطة، ثم ينفّذ بعد موافقتك.` | `Asks & plans first, then executes once you approve.` |
| planStart (pill label) | `ابدأ التنفيذ` | `Start` |
| planStartHint (pill title) | `موافقة على الخطة وبدء التنفيذ` | `Approve the plan and start executing` |
| planApproval (the user message the pill sends) | `ابدأ التنفيذ ونفّذ الخطة.` | `Go ahead and execute the plan.` |
| askRecommended (badge) | `موصى به` | `Recommended` |
| askContinue | `متابعة` | `Continue` |
| askBack | `السابق` | `Back` |
| askSubmit | `تأكيد الاختيارات` | `Confirm` |
| askStep | `سؤال` | `Question` |
| askExtraPlaceholder | `أو أضف تفصيلاً…` | `Or add a detail…` |
| askAnswered | `تم الإرسال` | `Sent` |
| askMyChoices (summary prefix) | `اختياراتي` | `My choices` |
| askPreparing (stream loader) | `جاري تحضير الأسئلة…` | `Preparing questions…` |
| settings row title | `أسلوب الردّ` (app.js:20000) | `Response style` |

Icons: `ICONS.modeAuto` is a lightning bolt, `ICONS.modePlan` is a clipboard with a check
(app.js:2347-2348). Pill uses `ICONS.play`.

---

## 2. What the client sends on a plan-mode turn

### 2.1 The request body (same endpoint as normal chat)

`buildMessages(tier, conversation, replyLang)` app.js:37837 returns
`[system, planSystem?, fileTurnSystem?, ...history]`. Then `streamAnswer` posts:

```json
{ "messages": [...], "tier": "pro|ultra|max|mini", "think": false, "cid": "<uid>", "product": "ai", "chatId": "<serverId or ''>", "nokb": false }
```
(app.js:42618). Route: `POST /api/chat/job` when `CHAT_JOB && chat && !chat.ephemeral && (isGuest() || chat.serverId)` (app.js:42651), else `POST /api/chat` (SSE). The job path is wrapped client-side into the same SSE frame shape (`data: {"choices":[{"delta":{"content":"…"}}]}` … `data: [DONE]`, app.js:41230-41232), so plan mode has no transport of its own.

Server auth for both routes: member session cookie **or** guest trial cookie, else `401 {"error":"authentication required"}` (server.mjs:12745-12747, 12538). Rate limits: `/api/chat` 120/min member, 30/min guest → `429 {"error":"too many requests, please slow down"}` (12754-12756); `/api/chat/job` 60/min member, 30/min guest → `429 {"error":"too many requests"}` (12540). Job start: `400 {"error":"messages required"}`, `413 {"error":"payload_too_large"}` (body over `JOB_PAYLOAD_MAX`; client then falls back to live streaming, app.js:42662), `503 {"error":"storage_unavailable"}`; success `200 {"ok":true,"jobId":"…","phase":"queued"}`; an idempotent re-POST with the same `cid` returns the existing job (`phase: "completed"|"queued"|"processing"|"failed"`, server.mjs:12569-12584). Poll `GET /api/chat/job?id=` → `{phase, text, reasoning, error, status, surface, progress}` (12658+).

The server does not know about plan mode at all (no `plan` handling in server.mjs). It prepends `IDENTITY_BLOCK` to the **first** system message (server.mjs:12911-12914) and merges the user's memory block into the **first** system message (12925-12928). Extra system messages pass through untouched.

### 2.2 The system messages (exact differences between Auto and Plan)

Base system (app.js:38139-38141), same first message in both modes **except**:

- In plan mode `planning === true` (app.js:37976) and `buildRule` + `engineerRule` (app.js:37904-37923) are **omitted** from the base system message: `… + imageRule + tikzRule + (planning ? "" : buildRule + engineerRule) + finishRule + userReqRule`.
- In plan mode a **second** system message `planSystem` is pushed right after the base system (app.js:38208).
- In plan mode the per-turn file guidance (`fileTurnSystem`, `fileGuidance(fmt)`) is **never** injected (app.js:38211: `if (fileTurnSystem && state.mode !== "plan")`).

`planSystem.content`, verbatim (app.js:38149-38182; it is one string, line breaks are `\n`):

```
You are in PLAN MODE. This OVERRIDES any other instruction about producing code, a website, a document, or a file directly. Do NOT produce the final deliverable yet — EVEN if the request is to build a website/app or make a file.
STEP 1 — CLARIFY WITH INTERACTIVE CHOICES: If anything truly matters and is ambiguous, do NOT ask in plain prose. Instead emit EXACTLY ONE fenced code block tagged `firas-ask` whose body is JSON in this schema:
```firas-ask
{ "intro": "optional short lead-in",
  "questions": [
    { "id": "storage", "question": "…?", "multi": false,
      "options": [
        { "label": "…", "recommended": true, "desc": "optional" },
        { "label": "…", "desc": "optional" } ] } ] }
```
RULES for firas-ask: include only the 1-4 questions that genuinely matter; each question has 2-5 options; set "multi":true for multi-select (checkboxes) or false/omit for single-select (radios); mark the single best option(s) with "recommended":true; "desc" and "intro" are optional; ALL text (question, label, desc, intro) MUST be in the user's language. Output ONLY the firas-ask block (a short sentence before it is allowed) — no plan and no prose questions in the same turn. Emit valid JSON only (no trailing commas, no comments).
STEP 2 — PLAN (think like a senior engineer / agent): After the user answers, give a clear, well-ORGANIZED plan — break the task into logical phases/sections and say what each contains (for a website: the sections & layout, the design/style direction, the key features, and the tech). Professional and concrete but skimmable (short numbered points). Write the plan as plain numbered PROSE — NEVER wrap the plan itself in a code fence (no ``` blocks) and do NOT write any actual code/content yet; invite the user to confirm or adjust. If nothing needed clarifying, skip step 1 and go straight to the plan.
STEP 3 — EXECUTE: ONLY once the user approves (e.g. said ابدأ/go/نفّذ) do you EXECUTE the FULL task to a high standard — for a website/app, deliver the COMPLETE, large, polished single-file build per the build rule (many sections, do not cut it short). Always reply in the user's language.
```

**The same `planSystem` is sent on every turn while the device is in plan mode** — the clarifying turn, the plan turn, the execute turn and every follow-up after delivery. The model alone decides which STEP it is in from the history. The client only changes *routing* on the execute turn (section 4).

Other plan-mode gates in `streamAnswer`:
- web search / silent search never runs in plan mode (app.js:42440);
- `problemOnlyTurn` (generated problem lists) disabled (42366);
- `codeFollowupSpec` returns null (2851);
- the 3-agent FILE pipeline never runs (42284 `if (fileFmt && state.mode !== "plan")`);
- image generation / image edit / code window run only when `planExecuting` (41605, 41734, 42172).

---

## 3. The `firas-ask` block — schema, parser, renderer

### 3.1 Wire format
One fenced block, info string `firas-ask`, JSON body. Client regex (app.js:29333):
`/```[ \t]*firas-ask[ \t]*\r?\n([\s\S]*?)```/i` — first block only; case-insensitive tag; tolerant of trailing spaces/CRLF; a **closing fence is required** (an unterminated block never parses → falls back to raw text).

### 3.2 Normalisation (`normalizeAskSpec`, app.js:29298-29326) — implement exactly

```
AskSpec { intro: String (default ""), questions: [AskQuestion] (1…4) }
AskQuestion { id: String (default "q<index>"), question: String (required, trimmed, non-empty),
              multi: Bool (default false), options: [AskOption] (2…5) }
AskOption { label: String (required, trimmed, non-empty), desc: String (default ""), recommended: Bool (default false) }
```
Rules: keep at most the first 4 questions; per question keep at most the first 5 options, options without a string label are dropped; a question with fewer than 2 surviving options or an empty question text is dropped; if no question survives the whole spec is `nil` (block is shown as raw text). Any JSON error → `nil`. Non-object entries are skipped, never fatal.

### 3.3 Streaming presentation
While streaming, `renderMarkdown` (app.js:7043-7118) replaces the block — closed **or still open to end-of-text** (`maskFirasAsk` app.js:3806-3816) — with the sentinel `U+E010 U+E011` and, after sanitising, with a static loader: three bouncing dots + `askPreparing`. The raw JSON is never shown. On finalize (`finalizeAi` app.js:43181-43183, and on every re-render `renderThread` app.js:23924-23926) `decorateFirasAsk` (29348-29389) swaps the loader for the interactive panel, or — if the JSON did not parse — re-renders the message with `{revealAsk:true}` so the loader can never get stuck.

### 3.4 The panel (`buildAskPanel`, app.js:29392-29569) — behaviour to reproduce
- Direction from `msg.lang` (`"ar"`→rtl, else ltr); strings from `STR[msg.lang]`.
- Optional intro paragraph.
- **Wizard: one question at a time.** Legend = (when >1 question) `askStep + " " + n + " / " + total` with Arabic-Indic digits in Arabic (`سؤال ١ / ٣`), then the question text.
- Single-select → radio group; `multi` → checkboxes. Options with `recommended:true` are **pre-checked** and show the `موصى به` badge. `desc` renders under the label.
- Footer: a one-line free-text field (placeholder `askExtraPlaceholder`) **visible only on the last step**; Back button hidden on step 0; Next button = `askContinue` + caret on non-last steps, `askSubmit` + check on the last step. Focus moves to the first option of each step.
- Submit builds the summary (3.5), sets `msg.askAnswered = true` (persisted), disables everything, relabels the button `askAnswered`, and sends the summary as a normal user message (`sendAskAnswer` 29592-29596: puts it in the composer and calls `sendMessage()`).
- If the summary is empty (nothing checked and no extra text) the tap is a silent no-op (29550).
- All taps are ignored while `state.streaming` is true (29548) — silently.
- Re-rendered as answered (all inputs disabled, no Back, no extra field, button `تم الإرسال`) when `msg.askAnswered` is true.

### 3.5 The answer summary (`buildAskSummary`, app.js:29573-29589) — exact format
For each question with ≥1 checked option: `<question with trailing ? or ؟ stripped>: <labels joined by "، " (ar) / ", " (en)>`. Parts are joined with `"؛ "` (ar) / `"; "` (en) and prefixed with `askMyChoices + " — "`. If the extra text is non-empty it is appended on a new line (or is the whole message when nothing was checked).

Example (ar): `اختياراتي — نوع الموقع: متجر إلكتروني؛ الألوان: أزرق داكن، ذهبي\nأريد قسم للتقييمات`
Example (en): `My choices — Site type: Online store; Colors: Navy, Gold\nAdd a reviews section`

This message is an ordinary user turn (`role:"user"`, `lang` from `detectLang`, no `mode`). The model sees it in history and (per STEP 2) writes the plan.

### 3.6 Other UI rules for a firas-ask message
- No Start pill (3.7) on it (`shouldShowPlanStart` returns false when `parseFirasAsk` succeeds, app.js:29646).
- Never a file card, even after a "…pdf" request (app.js:3127 `if (/^\s*```firas-(?!file)/.test(...)) return null`, 43192).
- The share-one-answer button is hidden for `^\s*```firas-ask` content (app.js:29181).
- Follow-up chips (`qreplyEl`) are suppressed for any `firas-` block and whenever the Start pill shows (app.js:26480-26491).
- Firas Agent (product `agent`) reuses the same panel for its own clarifying questions (`buildClarifyingQuestions` app.js:55960) — different pipeline, same renderer; out of this slice.

### 3.7 The Start pill (`planStartEl` app.js:29268-29285, `shouldShowPlanStart` 29640-29651)
Shown under a finalized assistant message iff: `msg.mode === "plan"` AND not `msg.offline` AND non-empty content AND no parseable firas-ask block AND **not** `precededByApproval(chat, index)`. (A fenced block inside the plan does NOT suppress it — deliberate, 29648-29650.) Appended at live finalize (43204-43209) and on every render (23950). Tapping: disabled + removed, then `approvePlan(lang)` (29597-29602) sends `STR[lang].planApproval` verbatim as a user message. Ignored silently while `state.streaming`.

### 3.8 Approval detection (`precededByApproval` app.js:29624-29634)
The reply at `index` is an *execution* reply iff `messages[index-1]` is a user message whose trimmed content is exactly `STR.ar.planApproval` or `STR.en.planApproval`, **or** matches
`/^(ابدأ|نفّذ|نفذ|go ahead|execute|start( executing)?|proceed)\b/i`. See defect D1 — the Arabic half of that regex can never match.

---

## 4. The execute turn (what routing changes)

`planExecuting = state.mode === "plan" && precededByApproval(chat, indexOf(aiMsg))` (app.js:41596). When true:

- **Code**: `codeTrigger` = the most recent user message for which `detectCodeRequest()` is truthy, else the last user message (41597-41599); `codeReq = detectCodeRequest(codeTrigger.content)` (41605-41607) → the answer streams into the code window and lands as a `firas-code` card.
- **Image**: `imgUser` = most recent user message with `detectImageRequest()` (41711-41713) — but `wantsImage` is computed from `turnKind`, which was classified from the **approval** message (41560-41566, 42170-42171). See D5.
- **File**: `fileFmt = isFileStreamReply(aiMsg, chat)` → `requestedFormatForAssistant` → returns the format of the **immediately preceding user message** only (3044-3052) = the approval sentence → `null`. See D4.
- `answer masking`: `isFileStreamReply` (3121-3139) masks a plan-mode reply as a file only when `msg.mode === "plan" && precededByApproval(...)` — which, per D4, never has a format to mask with.
- The model receives the same `planSystem` (STEP 3 applies) but **without** `buildRule`/`engineerRule` and without `fileGuidance`. See D3.

Turn-intent kinds the classifier can return (app.js:4102): `"chat","image","edit-image","video","pdf","docx","pptx","xlsx","csv","code"` (+ `"unavailable"` when the classifier call failed); it is pinned on the user message as `intent` (41567). The classifier is `_classifyTurn` (app.js:4132): a hidden **mini-tier model call** through `callAgentText` (app.js:38813) with a two-line `KIND=…/REQUIREMENTS=…` reply, cached per `(attachments|product|first 6000 chars)`; it runs on **every** turn including the approval sentence and the `اختياراتي — …` summary, so each plan-mode turn costs one extra model round-trip before the visible stream starts. Only `wantsGeneratedProblems` requests skip it (4143-4152).

---

## 5. Full trace of one plan-mode conversation on the web

1. User (device mode = plan) sends `سوي لي موقع لمطعم`. `userMsg = {role:"user", content, lang:"ar", tier}` (44480). `aiMsg = {role:"assistant", content:"", reasoning:"", tier, lang:"ar", mode:"plan"}` (44577).
2. Request = `[base system (no build/engineer rule), planSystem, user]`. Model emits `firas-ask`. While streaming the block is masked by the loader. At finalize the panel renders. No Start pill. `persistChat` PUTs the chat with `mode:"plan"`.
3. User taps through, hits `تأكيد الاختيارات` → `msg.askAnswered = true`, user message `اختياراتي — …` is sent. New `aiMsg.mode = "plan"`. Request = `[base, planSystem, user1, assistant(firas-ask JSON), user(summary)]`. Model writes the numbered plan in prose. Start pill appears (no ask block, previous user message is not an approval).
4. User taps `ابدأ التنفيذ` → user message `ابدأ التنفيذ ونفّذ الخطة.`. New `aiMsg.mode = "plan"`; `precededByApproval` true (exact string match) → `planExecuting` true → for a website, `codeTrigger` finds user1 → code window → `firas-code` card. No Start pill on this reply (preceded by approval).
5. Any later message in the same chat while the device is still in plan mode restarts at STEP 1 (the model may ask again).

Where it breaks in practice: steps 3→4 when the user **types** the approval instead of tapping (D1) or taps Start with a quote pill active (D13); step 4 for **file** and **image** plans (D4, D5) and for website plans the build is thin (D3); step 2/4 on tiers whose model ignores a second system message (D2); after a tab close/recovery on a phone (D6); a stray Start pill under Agent/Code deliverables when the device was left in Plan (D14); and no way out of the cycle after delivery (D12).

Verified by execution: the D1 regex was run under node against the exact source (`/^(ابدأ|نفّذ|نفذ|go ahead|execute|start( executing)?|proceed)\b/i`): every Arabic input returned `false`, including the pill's own sentence `ابدأ التنفيذ ونفّذ الخطة.` — that one is only caught by the exact-string comparison on the line above it (29632), which is why the pill works and typing does not.

---

## 6. Defects found (with evidence)

**D1 — Hand-typed Arabic approvals are never detected.** `precededByApproval` (app.js:29634) uses `\b` after Arabic words. JS `\b` is ASCII-only; Arabic letters are non-word characters, so `\b` after `ابدأ` needs a word/non-word transition that never exists. Verified with node against the exact regex: `"ابدأ"`, `"ابدأ التنفيذ"`, `"نفذ"`, `"نفّذ الخطة"`, `"يلا ابدأ"`, `"اي ابدأ"`, `"تمام"`, `"موافق"` → all `false`; `"go ahead"`, `"start"`, `"execute!"` → `true`. The same file warns about this at app.js:2727-2728 ("Arabic has no \b word boundary, so never wrap an Arabic token in \b — it would never match"). Consequence: a typed approval is treated as another planning turn — `planExecuting` false → no code window / no image / nothing masked, the model (which does read `ابدأ`) dumps the build as a fenced block in chat, and a second Start pill appears under the delivered build (`shouldShowPlanStart` deliberately does not suppress on `replyContainsDeliverable`, 29648-29650). Also the regex is anchored and has no Iraqi/colloquial vocabulary (`يلا`, `اي`, `ايه`, `تمام`, `ماشي`, `موافق`, `اوكي`, `كمل`, `سوي`, `نفذها`, `ابدي`, `يالله`, `زين`, `اي نفذ`).

**D2 — `planSystem` is a *second* system message and some engines ignore it.** Client pushes it as its own `{role:"system"}` (app.js:38208). server.mjs:12924-12926 states why memory is merged into the first system message instead: "some models (e.g. the coder model on Ultra) ignore a second system message." On those tiers plan mode is silently Auto: the model builds immediately; the reply still carries `mode:"plan"` so a Start pill appears under a finished deliverable. Probable, not measured. Provider evidence: only `streamAnthropic` joins every system row into one `system` field (server.mjs:6798); Gemini (6692, OpenAI-compatible endpoint 6564+), DeepSeek/NVIDIA (6703), OpenAI Pro (6961), OpenRouter (7107) and Cloudflare (7214) all forward the two `role:"system"` rows as-is, so whether STEP 1-3 is honoured is entirely up to the upstream model.

**D3 — The execute turn drops the build rules it is told to follow.** `planning = state.mode === "plan"` (app.js:37976) removes `buildRule`+`engineerRule` on *every* plan-mode turn, including the execute turn, while `planSystem` STEP 3 says "deliver the COMPLETE, large, polished single-file build **per the build rule**" (38180) — a rule that is no longer in the prompt. Result: short, thin builds after approval.

**D4 — File requests can never be delivered in plan mode.** (a) `requestedFormatForAssistant` (app.js:3044-3052) returns at the first user message above the reply — on the execute turn that is `ابدأ التنفيذ ونفّذ الخطة.` → `resolvedFileFormat` → `null`; (b) the file pipeline is hard-disabled in plan mode (42284 `state.mode !== "plan"`); (c) `fileGuidance` is never injected (38211). So a `سوي لي ملف PDF …` plan executes as plain chat markdown with no file card; the earlier clarifying/plan turns do have `fmt` but are exempt by design (3137).

**D5 — Image plans execute as text.** `wantsImage = turnKind === "image" || (turnKind === "unavailable" && detectImageRequest(imgUser.content))` (42170-42171) but `turnKind` was classified from the approval sentence (41560). `imgUser` correctly looks back to the original request (41711-41713) yet the gate reads the wrong turn, so the image branch is skipped unless the classifier failed.

**D6 — Durable paths drop `mode` (and `lang`).** `saveAssistantTurn` builds the stored row from `{role, content, reasoning, tier, lang, cid}` only (server.mjs:2518), called from the job worker (11900, 11915) and from the stream-disconnect save with `lang: ""` (13106). Guest recovery pushes `{role, content, reasoning, tier, lang}` (app.js:2620). A plan reply recovered after the tab closed (the normal case on a phone) has no `mode` → no Start pill, `isFileStreamReply` treats it as Auto, the regenerate fold (46373) treats it as a different kind. `askAnswered` is only ever written by the client PUT, so it survives only if the client got to persist. The recovery itself is wholesale: `refreshChatFromServer` replaces `chat.messages` with the server array when the server's last row is "better" (app.js:2565, called from `refreshActiveChatOnReturn` 2637 on every visibility/focus/pageshow and from a 5 s `watchPendingAnswer` timer 2686), so the local `mode` on that turn is discarded even when the client had it. Also `lang`: the job record stores `lang: payload.lang === "en" ? "en" : "ar"` (server.mjs:12633) and the chat body only carries `lang` for long documents (app.js:42629), so a worker-saved plan reply in an English chat is filed with `lang:"ar"`; the panel/pill fall back to `detectLang(content)` (29269, 29393) so this is cosmetic.

**D7 — Mode is device-global and read at reply time, not per conversation.** `aiMsg.mode = state.mode` (44577); `planExecuting` and all gates read `state.mode` (41596 etc.). Switching to Auto between the plan and the approval (or a voice call, 49980) removes `planSystem` from the execute request and makes `planExecuting` false; `codeFollowupSpec` returns null because the previous assistant turn was a plan, so a website build streams as chat text. Switching to Plan mid-chat re-plans every follow-up.

**D8 — `shouldShowPlanStart` reads `activeChat()` instead of the message's chat** (app.js:29644). `finalizeAi` passes only `aiMsg` (43204). If the user has switched chats while the answer streams, `indexOf` is `-1`, `precededByApproval` is false, and the delivery reply gets a Start pill.

**D9 — Silent no-ops.** Submit/Back/Start all return without feedback while `state.streaming` (29548, 29594, 29598, 29281); Submit with nothing selected and no text returns silently (29550).

**D10 — English false positives.** `^start\b`, `^execute\b`, `^proceed\b` match "start with the basics", "execute this Python", "proceed to explain …" and flip the turn into execution routing (code trigger looked up from the *original* request).

**D11 — Parser is fence-strict.** Only a ```` ```firas-ask ```` fence parses. A ```` ```json ```` fence with the same body, or a block with a missing closing fence, is shown as a code block with raw JSON and — because `parseFirasAsk` is null — a Start pill. The regex (29333) also demands a line break right after the tag (`firas-ask[ \t]*\r?\n`), so an info string such as ```` ```firas-ask json ```` or a fence indented inside a list item fails too. `decorateFirasAsk`'s fallback that looks for any `<pre>` containing `"questions":` (29376-29380) never helps: it only chooses *where* to mount the panel and runs after `parseFirasAsk` already returned null.

**D12 — No exit from the cycle.** `planSystem` is sent on every turn while the device is in plan mode, so after delivery a small follow-up ("غيّر اللون") is answered with STEP 1 questions again.

**D13 — A quote pill contaminates the approval/summary text.** `sendMessage` builds the outgoing content as `quotePrefix() + typed` (app.js:44421, `quotePrefix` 22793). Both `sendAskAnswer` (29589) and `approvePlan` (29597) put their text in the composer and call `sendMessage()`, so if the user had selected a passage to quote before tapping Submit/Start, the message becomes `«quoted passage» … ابدأ التنفيذ ونفّذ الخطة.` — the exact-string match in `precededByApproval` fails and the turn is not an execution turn.

**D14 — The Start pill leaks into other products.** `state.mode` is device-global and never reset by a product switch; the Agent pipeline stamps `mode: state.mode` on its own assistant rows (app.js:59560, 59589, 59673, 59798, 59817, 59865, 59869) and `renderThread` appends the pill for **any** message that passes `shouldShowPlanStart` (23950), which checks only `msg.mode === "plan"`, non-empty content, no `firas-ask` block and no preceding approval. With the device in Plan mode, a finished Firas Agent run card, a deck, a project bundle or a Firas Code file therefore gets an `ابدأ التنفيذ` pill under it; tapping it sends the approval sentence into the Agent chat as a new mission. `styles.css:1793-1815` has no rule hiding `.plan-start` under `.msg-ai--agent-run`.

Not a defect but easily mistaken for one: the loader/mask stage (`maskFirasAsk`, sentinel `U+E010U+E011`) and the markdown/DOMPurify pipeline work; `FORBID_TAGS` includes `input`, but the panel is built with DOM APIs after sanitising, so it renders.

---

## 7. Native state machine (iOS) — implement this, not the web

### 7.1 Model
Keep the web's message shape so history round-trips with the server unchanged:
```
ChatMessage { role: "user"|"assistant"; content: String; tier: String?; lang: "ar"|"en";
              reasoning: String?; cid: String?; mode: "auto"|"plan"? (assistant only);
              askAnswered: Bool? ; intent: String? (client-only) }
```
Add a **per-conversation** `planPhase` (client-side; may also be derived on load — see 7.5):
```
enum PlanPhase { none, awaitingAnswers(askMessageID), awaitingApproval(planMessageID), executing(originID), delivered(originID) }
```
`originID` = the id of the user message that started the cycle (the actual request). Mode selection stays a device preference (`firas_ai_mode`, `"auto"` default) but **snapshot it onto the conversation when a cycle starts** and use the snapshot, not the live toggle, until the cycle ends (fixes D7).

### 7.2 States and transitions

| State | Trigger | What the client sends | Next |
|---|---|---|---|
| `none`, mode = plan | user sends request R | user turn R; system = `[base ⊕ planSystem]` (7.3) | wait for reply |
| reply parsed as AskSpec | — | nothing; render panel; `phase = awaitingAnswers` | — |
| reply has no AskSpec | — | render prose + Start pill; `phase = awaitingApproval` | — |
| `awaitingAnswers` | Submit | user turn = summary (3.5); mark `askAnswered=true` on the ask message; system `[base ⊕ planSystem]` | reply → AskSpec again? → stay `awaitingAnswers` (allowed, cap at 2 rounds then force plan via 7.3c); else `awaitingApproval` |
| `awaitingAnswers` | user types instead | treat as free-text answer: same as Submit with the typed text | same |
| `awaitingApproval` | Start pill | user turn = `planApproval` string for the reply's `lang`; `phase = executing(originID)`; system = `[base(WITH build/engineer rules) ⊕ planSystem ⊕ EXECUTE note]` (7.3b) + deliverable guidance (7.4) | reply → `delivered` |
| `awaitingApproval` | user types approval (7.6 matcher) | same as Start pill, keeping the user's own words as the turn content | `executing` |
| `awaitingApproval` | user types anything else | it is a revision request: system `[base ⊕ planSystem]`; reply → `awaitingApproval` again (new pill) | — |
| `executing` | reply finalized | route by 7.4; no Start pill; `phase = delivered` | — |
| `delivered` | user sends follow-up | **Auto semantics** for this turn: no `planSystem`, build/engineer rules included, `codeFollowupSpec`-style continuation of the delivered artefact. A new cycle starts only if the message is itself a new build/file/image request (classifier kind ∉ {chat}) **or** the user re-arms plan mode. (fixes D12) | `none` or new cycle |
| any | user toggles mode to Auto mid-cycle | keep the cycle (snapshot); show a one-line note that this conversation finishes its plan first | — |
| any | voice call starts | pause the cycle (web forces Auto for the call); resume phase after hang-up | — |

Every assistant message created during a cycle is stamped `mode:"plan"`; assistant messages outside a cycle are stamped `mode:"auto"` (matches what the web writes so a chat opened on the web keeps behaving).

### 7.3 Exact system messages per turn
Because of D2, **concatenate** plan instructions into the FIRST system message instead of sending a second one; the server will still prepend `IDENTITY_BLOCK` and append memory to that same message, which is fine.

a. Clarify / plan turns (`none`→ask, `awaitingAnswers`, `awaitingApproval` revisions):
`base_without_build_rules + "\n\n" + planSystem` where `planSystem` is the verbatim text in 2.2 and `base_without_build_rules` is the web's base system with `buildRule`/`engineerRule` omitted (exactly what the web does today, app.js:38139-38141 with `planning=true`).

b. Execute turn:
`base_WITH_build_rules + "\n\n" + planSystem + "\n\nThe user has APPROVED the plan above. You are now in STEP 3: execute the FULL deliverable now, in one reply, following the agreed plan and the user's answers exactly. Do not ask anything, do not restate the plan."`
(`base_WITH_build_rules` = the web's Auto-mode system message, i.e. `planning=false`.) This restores the build rule STEP 3 refers to (D3).

c. Forced-plan turn (after two ask rounds): append `"\n\nDo NOT ask further questions; assume the recommended options and give the plan now (STEP 2)."`

### 7.4 Deliverable routing on the execute turn (fixes D4/D5)
Resolve the deliverable from the **origin request** (`originID`), never from the approval sentence:
- classify `origin.content` once (the same intent classifier the app uses for Auto; kinds in 4.); cache it on the message as `intent`.
- `pdf|docx|pptx|xlsx|csv` → run the normal file path exactly as Auto would for that origin message (include `fileGuidance(fmt)` in the system message, mask the stream with the file loader, show the file card). The web never does this in plan mode; iOS must.
- `image` → run the image job with `origin` as the prompt source (guest → the same account-required refusal Auto shows).
- `code` (or `detectCodeRequest(origin)` truthy) → code window/card, spec from `origin`.
- otherwise → plain streamed answer.
The answer message of the execute turn is stamped `mode:"plan"` and is **never** given a Start pill.

### 7.5 Deriving phase on load (a chat written by the web or recovered after a background job)
Walk messages from the end:
1. last assistant message has a parseable AskSpec and `askAnswered != true` → `awaitingAnswers`.
2. last assistant message has `mode == "plan"` (or the conversation's stored snapshot says plan), no AskSpec, and the user message before it is **not** an approval (7.6) → `awaitingApproval` (show pill).
3. last assistant message's preceding user message is an approval → `delivered`.
4. else `none`.
Treat a missing `mode` on an assistant message as `"auto"` (web semantics, app.js:46373), but fall back to the conversation snapshot when the row came from a durable save (D6): if the previous assistant message in the same chat is `mode:"plan"` and there was no Auto turn in between, treat the recovered row as plan.

### 7.6 Approval matcher (replaces the web regex)
Match after trimming, stripping tashkeel (U+064B–U+0652), tatweel, and trailing punctuation `.!؟?…`, lower-casing Latin, normalising `أ إ آ → ا`:
- exact: `ابدأ التنفيذ ونفّذ الخطة.` / `Go ahead and execute the plan.` (normalised forms).
- Arabic starts-with (no `\b`; use `(?![\p{L}\p{N}_])` after the token, as verified: `ابدأ`, `ابدأ التنفيذ`, `نفذ`, `نفّذ الخطة` match; `ابدأها` does not): `ابدا`, `ابدي`, `نفذ`, `نفذها`, `نفذ الخطة`, `كمل`, `سوي`, `سويها`, `يلا`, `يلا ابدا`, `يالله`, `تمام`, `تمام ابدا`, `ماشي`, `موافق`, `اوكي`, `اوك`, `اي`, `ايه`, `ايوه`, `زين`, `اكيد`, `طبعا`, `اتفقنا`, `ممتاز نفذ`, `تمام نفذ`, `ابدأ التنفيذ`.
- English whole-message forms only (not prefix — fixes D10): `go ahead`, `go`, `start`, `start executing`, `execute`, `execute the plan`, `proceed`, `do it`, `yes`, `ok`, `okay`, `approved`, `looks good`, `lgtm`, `build it`.
- Anything longer than ~6 words that is not one of the exact strings is a **revision**, not an approval.
Only consult the matcher while `phase == awaitingApproval`.

### 7.7 Rendering rules to keep (parity)
- Stream loader for an ask block (closed or open fence) with `askPreparing`; never show the JSON.
- On finalize, malformed block → show the raw markdown (no stuck loader); additionally (D11) accept a ```` ```json ```` fence or bare JSON whose top level has a `questions` array as an AskSpec when `phase` expects one.
- Panel: wizard, recommended pre-selected with badge, extra field on last step, `تأكيد الاختيارات` on last step, `تم الإرسال` when answered, disabled while streaming — but **show** a toast (`t().streaming` equivalent) instead of a silent no-op (D9); disable Submit when nothing is selected and the extra field is empty.
- Start pill: accent-filled pill, play icon + `ابدأ التنفيذ`, placed above the message action row; hide follow-up chips under a message that has a pill or an ask block; hide "share one answer" for ask messages; never a file card under an ask message.
- Summary/approval turns are ordinary user bubbles (the web shows them as typed text). Send them as **their own** message: never prepend a pending quote/selection or attachments to a Submit/Start turn — clear or keep the draft aside (D13).
- Plan mode is a feature of the `ai` chat product only. The pill, the ask panel and `planPhase` must never be evaluated for Agent, Code or Brain conversations, and switching product must not carry the cycle over (D14). Stamp `mode` only on messages the chat product creates.
- The pill and the panel are decided from the message's **own** conversation, never from "whatever conversation is on screen" (D8).

### 7.8 Field limits and misc constants
- `MAX_MESSAGES`/`MAX_CONTENT` on the server bound stored rows; `mode` ≤ 20 chars, `cid` ≤ 64 (server.mjs:2455-2465).
- The client caps outgoing images per job (413 → live stream fallback); plan-mode turns with attachments should skip the job path exactly like Auto.
- Stream timeout on the client is 15 min (app.js:41535); the server bounds each call at ~5 min.

---

## 8. Open questions for the owner
1. Should plan mode be a per-conversation setting in the native app (recommended, 7.1) rather than the device-global toggle the web has?
2. On the execute turn for file plans, the web has no behaviour to copy; 7.4 proposes running the Auto file pipeline with the origin request. Confirm the file path analyst's spec is the one to reuse.
3. Whether the Ultra coder engine really ignores a second system message (D2) can only be confirmed live; the concatenation in 7.3 is safe either way.
