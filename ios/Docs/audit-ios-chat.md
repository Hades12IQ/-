# Audit — iOS Chat group

Scope: `ios/FirasAI/Stores/ChatStore.swift` (1043 lines), `Models/ChatModels.swift` (381),
`Features/Chat/ChatScreen.swift` (471), `ChatComposer.swift` (218), `ChatMessageRow.swift` (274),
`AddContextSheet.swift` (1063), `ChatAttachmentProcessor.swift` (317), `ModelSelectionSheet.swift` (210),
`ChatStrings.swift` (79), `Chat.xcstrings`. Every file was read completely. Supporting files consulted:
`README.md`, `FirasAI.xcodeproj/project.pbxproj` (build settings block A1…32/33), `Networking/FirasAPI.swift`,
`Networking/APIClient.swift`, `DesignSystem/GlassSurface.swift`, `DesignSystem/FirasCompletionCue.swift`,
`DesignSystem/FirasActivityLabel.swift`, `DesignSystem/FirasTheme.swift` (PreferencesStore),
`Notifications/NotificationCoordinator.swift`, `Stores/SessionStore.swift`, `Features/Shell/FirasAppShell.swift`,
`App/FirasAIApp.swift`, `Resources/Info.plist`, `Resources/Localizable.xcstrings`.
Server truth: `server.mjs` — router :13725-13860, `handleChatJobStart` :12531, `handleChatJobStatus` :12658,
`handleChatCancel` :12478, `handleChat` :12740-13000, `sanitizeMessages` :2431, `saveAssistantTurn` :2513,
`handleUpdateChat` :2611, `runOneJob` :11767, `TIERS` :401, `hasImages` :465, `JOB_PAYLOAD_MAX` :9330.
Web truth: `app.js` `buildMessages` :37837-38215 and `MODELS` :27-135. Contract reports read:
`Docs/server-chat-jobs-chats.md`, `Docs/web-chat-ux.md` (§3-10, §15), `Docs/web-plan-mode.md` (§2, §7),
`Docs/web-voice-call-mic.md` (outline, §7). There is no `web-prompt-builder.md`; the prompt facts below come
from `app.js` directly.

Build context that matters for this group: `SWIFT_VERSION = 5.0`, `SWIFT_STRICT_CONCURRENCY = minimal`,
no `SWIFT_DEFAULT_ACTOR_ISOLATION` (so default **nonisolated**), `IPHONEOS_DEPLOYMENT_TARGET = 18.0`,
`TARGETED_DEVICE_FAMILY = 1,2`, `fileSystemSynchronizedGroups` (every file under `FirasAI/` is compiled —
including the **empty** `FirasAI/Prompting/` folder). No `UIBackgroundModes` in `Info.plist`.

---

## A. Inventory — what the group implements today

| Area | Implemented | Where |
| --- | --- | --- |
| Conversation list / open / create / delete for members | `GET /api/chats`, `GET /api/chats/:id`, `POST /api/chats` (deterministic `ios_<uuid>` clientId), `DELETE`; auto-opens the newest non-Agent/Code/Brain chat at launch | ChatStore :59-192 |
| Guest chat | one in-memory conversation (`guest-<uuid>`), never persisted beyond the active job record | ChatStore :925-935 |
| Send turn | trims text, strips `images`/`fileText` from history, appends user + assistant placeholder, provisional title = first 80 chars, spawns a store-owned `pollTask` | ChatStore :194-280 |
| Durable job | `PUT /api/chats/:id` (user turn) → optional `GET /api/search` context → `POST /api/chat/job {messages, tier, think, cid, product:"ai", chatId, lang}` with 2 retries on transport/5xx → poll `GET /api/chat/job?id=` at 350/700/1200 ms → `finish` (haptic cue, local-notification fallback, whole-array `PUT`, clear record) | ChatStore :355-530, :653-775 |
| Stop | before enqueue: local stop; after: `pollTask.cancel()` + `POST /api/chat/cancel` with 409/5xx retry, persisted `cancelRequested`, exponential retry loop | ChatStore :282-334, :496-621 |
| Resume after relaunch | `ActiveChatJobRecord` in `UserDefaults` (incl. the whole transcript) → `resumeActiveJob` merges the server copy by cid | ChatStore :300-353, :1001-1024 |
| Owner isolation | `loadedOwnerID` / `adoptCurrentOwnerIfNeeded` clears state on identity change without cancelling the server job | ChatStore :937-970 |
| Web search | client-driven; ≤6 rows formatted with the web's untrusted-data fence; inserted as a **user** message before the question; tier → `pro` unless `max`; system-note fallbacks | ChatStore :861-913 |
| Transcript UI | `ScrollView` + `LazyVStack`, plain `Text` for user/assistant/system rows, image-thumbnail grid + preview sheet, attachment chips, reasoning `DisclosureGroup`, failed/stopped captions, activity label while empty | ChatScreen :160-197, ChatMessageRow |
| Composer | vertical `TextField`, `+` (context) with count badge, model button, primary action Send / Stop / Call morph, `sendOnReturn` via `onSubmit` | ChatComposer |
| `+` sheet | camera, 8 recent photos, PhotosPicker (≤10), Files importer (≤5, pdf/text/code; Office refused), Media Studio rows (image/video/music), Brain shortcut, Web-search + Thinking toggles, dictation-language picker (no dictation exists) | AddContextSheet |
| Attachment processing | off-main detached tasks; images resized to 1568 px JPEG q0.82, then re-budgeted per image against a 380k-char job budget (720–1280 px, q0.48–0.74), 128 px thumbnails; PDF (≤80 pages) / text extraction ≤120k chars per file, 220k total; file text prepended to the user content at inference time only | ChatAttachmentProcessor |
| Model picker | four tiers with labels/taglines from the web `MODELS` table; a dead "Response style — Automatic" row | ModelSelectionSheet |
| Localisation | `Chat.xcstrings` en/ar (≈62 keys, ~10 unused), some user-facing strings hard-coded in Arabic inside ChatStore | ChatStrings, ChatStore |

Not implemented anywhere in this group: system prompt, Markdown/code/math/card rendering, message actions
(copy/regenerate/versions/escalate/share/listen/export/continue), Auto/Plan mode, `firas-ask` panel, mic
dictation, SSE `/api/chat` fallback, `longdoc`/`longfile` kinds and `/api/chat/job/file`, AI auto-title,
per-chat drafts, per-conversation tier pin, tier badge on answers, drag-drop/paste on iPad, keyboard
shortcuts, guest history persistence, quota/limit copy, engine-failure sentence detection.

---

## B. Findings

Severity: **critical** = wrong answers / data loss / freeze / cannot ship; **major** = owner-visible gap or
correctness bug; **minor** = polish. Each item: file:line · category · evidence · fix.

### Critical

**C1. No system prompt is sent — the model gets only the server identity block.**
`ChatStore.swift:414-422` (`ChatJobRequest(messages: requestMessages …)`), `:972-986` (`inferenceMessages`
only merges `fileText`). `requestMessages` contains user/assistant turns and, when search is on, one
system *note*. Server `handleChat` (:12911-12914) prepends `IDENTITY_BLOCK` to the first system message or
unshifts one; nothing else. The web sends `buildMessages()` (`app.js:37837-38215`):
`MODELS[tier].persona + productRule + identityRule + langRule + mathRule + accuracyRule + NO_NEEDLESS_REFUSAL +
SCIENCE_RIGOR + NEVER_RAW_FILE_FORMAT + codeRule + genLevelRule + STEM_HARD_RULE + SUBJECT_HARD_RULE + imageRule +
tikzRule + buildRule + engineerRule + finishRule + userReqRule`, then `planSystem` and `fileTurnSystem`.
`ios/FirasAI/Prompting/` is an empty folder — the builder was planned and never written.
Category: contract-mismatch / missing-feature-vs-web. Consequence: iOS answers have no language rule, no
LaTeX/code-fence rules, no per-tier persona (Mini/Pro/Ultra/Max differ only by engine), no "you can draw",
no completeness-count rule, no build/engineer rules — this is a large part of "the app feels thin".
Fix: add `Prompting/FirasPromptBuilder.swift` porting `buildMessages` verbatim (tier persona table + rules as
`static let` strings; `genLevelRule`/`finishRule`/`problemListRule` computed from the last user message;
`fileGuidance(fmt)` when a file is requested; plan-mode text concatenated into the **same** system message per
`web-plan-mode.md §7.3`). `startAndPoll` sends `[system] + requestMessages`. Keep `IDENTITY_BLOCK` out (server
adds it).

**C2. Answers are rendered as plain `Text` — no Markdown, code, math, links, tables or cards.**
`ChatMessageRow.swift:158` (`Text(message.content)` for assistant), `:34` (user). `Text(String)` does not
parse Markdown; `**bold**`, `### h3`, ```` ```swift ````, `$$…$$`, `[1](url)` all print literally. The web
pipeline (`web-chat-ux.md §8.2-8.6`) renders Markdown + KaTeX (+mhchem) + highlight.js, `firas-code` /
`firas-file` / `firas-image` / `firas-ask` cards, a `plot` fence, and quick-reply chips. Once C1 lands the
model will be *told* to emit all of that.
Category: missing-feature-vs-web / visual-design. Fix: parse with Apple's `swift-markdown` (SPM) into block
views: paragraphs/lists/quotes via `AttributedString` (inline markdown), headings, tables (`Grid`), fenced
code as an LTR monospaced block with language label + Copy (+ Preview for HTML/SVG via `WKWebView`), math via
`SwiftMath` (`MathLabel`, iosMath fork) for `$…$`/`$$…$$` with plain-text fallback, fenced `firas-*` blocks
dispatched to cards (`firas-code`, `firas-file` → download via the client exporters or `/api/chat/job/file`,
`firas-image` → Media Studio, `firas-ask` → M4). Render streaming as settled-prefix + live-tail (parse the
prefix once, re-parse only the last block). Adding two SPM packages costs one CI cycle — pin versions.

**C3. `413 payload_too_large` is fatal: no SSE fallback, no history windowing, oversized job bodies.**
`ChatStore.swift:429-458` builds the job body from the **entire** conversation (`ChatMessage.encode` also
ships `tier`, `lang`, `files`, `imageThumbs`, `reasoning` on every row); `:464` `startChatJobWithRetry`;
`:607-617` `isRetryableStartError` returns `false` for 413 → `failBeforeStart` shows the raw string
"payload_too_large" and that chat can never send again. Server `JOB_PAYLOAD_MAX = 600_000` chars
(`server.mjs:9330`, check at :12560). The 380k-char budget in `ChatAttachmentProcessor.swift:56` covers only
*new* images/files, not history or thumbnails. The web falls back to `POST /api/chat` SSE on 413/404/501
(`server-chat-jobs-chats.md §2`); `FirasAPI` has no streaming call and `APIClient` has no `bytes(for:)` path.
Category: contract-mismatch / crash-of-feature. Fix: (a) `APIClient.stream(_:)` using
`URLSession.bytes(for:)` parsing `data:` lines (§1.7) and a `ChatStore` path that consumes it into the same
`apply/finish` pipeline (no job record; not resumable — matches the web); use it on 413/404/501 and for
image turns above ~500k; (b) encode outgoing rows with a slim `OutgoingChatMessage {role, content, images?}`
(server reads nothing else, `server-chat-jobs-chats.md §1.2`); (c) window the inference history (e.g. keep
the system message + last turns under 400k chars, always the last user turn) while still PUTting the full
array.

**C4. The finished answer is held back ≈3.2 s for a "flourish"; Stop during the hold destroys it.**
`FirasCompletionCue.swift:155-172` — two soft impacts then `Task.sleep(for: .seconds(3))`; called at the top
of `ChatStore.finish` (`:756-763`) **before** `reflect`. The terminal poll applies text with
`reflectImmediately: false` (`:722-727`, `:686-691`), so the last chunk — for short answers the *whole*
answer, because the server writes once at first token then every 2.5 s (`runOneJob` :11815-11831) — stays
hidden while the Stop button is still live. Tapping Stop in that window (`stop()` :318-334) cancels the
finish task, POSTs `/api/chat/cancel` on a completed job (server: 404 `unknown_job` or 409), enters
`retryPersistedCancellation` → `completeKnownCancellation` → the row is left `.stopped` with the old partial
text; the real answer appears only after a reload (it was saved by `saveAssistantTurn`).
Category: ux / freeze-or-main-thread (perceived) / crash-of-flow. The owner asked for a haptic *like Claude's
app* — a single tap as the answer lands, not a three-second pause. Fix: reflect terminal text immediately;
fire the haptic without awaiting (one `UIImpactFeedbackGenerator` `.soft` or `UINotificationFeedbackGenerator`
`.success`, ≤150 ms before the final reveal if you want "before completion"); make `stop()` a no-op once the
status is terminal; keep the consumed-key history.

**C5. Scroll yanks to the bottom on every poll tick and every visible row re-renders; thumbnails are re-decoded on the main thread each time.**
`ChatScreen.swift:186-195` + `:226-232`: `ChatScrollTrigger` includes `lastMessageLength`, so every `apply`
(up to ~3×/s) runs an animated `scrollTo(bottom)` — the reader cannot scroll up while streaming, which reads
as "the app freezes / kicks me". `ChatStore.reflect` (`:833-839`) replaces `selectedConversation` wholesale
each tick, so every visible `ChatMessageRow` body is re-evaluated; `ChatImageGrid.decodedImages`
(`ChatMessageRow.swift:103-109`) is a computed property that base64-decodes and `UIImage(data:)`-decodes every
thumbnail on the main thread on each of those evaluations; the assistant `Text` with
`.textSelection(.enabled)` re-lays out a growing 50k-char string each tick.
Category: freeze-or-main-thread / ux. Fix: track "user is at bottom" (iOS 18 `onScrollGeometryChange`, or
`onAppear/onDisappear` of the bottom anchor) and auto-scroll only then, with a "jump to latest" pill;
coalesce UI updates to ≤10 Hz (`apply` writes into a buffer, a 100 ms timer reflects); make rows diff-able
(`EquatableView` on `ChatMessageRow` or update a single message in place by index instead of replacing the
array); decode thumbnails once in `.task(id:)` off-main into `@State [UIImage]`; render the streaming row as
settled prefix + live tail (pairs with C2).

**C6. The poll loop never ends on 401/403 and has no backoff or ceiling on transport errors.**
`ChatStore.swift:696-748`: any thrown error increments `consecutiveFailures` (banner at 3) and the loop keeps
going every 1.2 s forever. A session-cookie expiry / `sessVer` bump (401) or a `403 forbidden` is thus
polled indefinitely until the identity changes; an offline device polls every 1.2 s for hours. The web stops
on 401/403 (`job_unowned`) and gives up after 20 non-OK (`server-chat-jobs-chats.md §3.2`).
Category: background-cloud-first / correctness. Fix: on 401 → clear state, keep the record, call
`session.restore()` and resume; on 403/404-with-body → terminal failure; transport errors → exponential
backoff (1.2 s → 30 s), suspend the loop while `scenePhase != .active` or offline (`NWPathMonitor`), resume
immediately on foreground; give up (keep the record, show "reconnect") after ~30 min of continuous failure.

### Major

**M1. The pre-start `PUT /api/chats/:id` ships full-resolution base64 images and extracted file text.**
`ChatStore.swift:369-381` (`durableMessages` from `conversation.messages`, which at `:268-276` carries
`images` + `fileText`). The server drops them (`sanitizeMessages` :2431-2505) but reads the body with
`readJson(req, 2_000_000)` (:2613) — over 2,000,000 chars the socket is destroyed → `failBeforeStart`. Ten
images at the 380k budget + thumbnails + a long history can cross it; it also triples memory
(`selectedConversation`, `record.messages`, the encoder). Category: contract-mismatch. Fix: a
`PersistedChatMessage` encoder emitting only the §5.2 whitelist (`role, content, tier, lang, reasoning, cid,
files, imageThumbs, mode, askAnswered, retryOf, retried, mergedFrom, alts, altAt`).

**M2. The final whole-array PUT is a snapshot from job start and can clobber the server.**
`ChatStore.swift:786-795` PUTs `record.messages` (captured at `:466-477`) and `record.title` (the 80-char
provisional title). Anything that changed server-side during the job — a rename or AI auto-title from the
web, a message added on another device, `retryOf/retried` the worker carried over — is overwritten; the
worker already upserted the assistant turn by cid (`saveAssistantTurn` :2513-2537). Category:
contract-mismatch. Fix: on finish, `GET /api/chats/:id`, merge by cid (server wins except the local
assistant row when longer), then PUT; or for members skip the PUT when the server copy already contains the
cid, and never PUT `title` at finish.

**M3. One job app-wide: sending, creating or deleting in any other chat is refused while a job runs.**
`ChatStore.swift:242-245` (`guard activeJobID == nil, pollTask == nil, !isSending`), `:123-126` (guest new),
`:169-172` (delete). The server queue is per owner+cid and durable, so nothing requires this. The web lets
other chats send (it only aborts *their* local streams). Category: ux / background-cloud-first. Fix:
`activeJobs: [conversationID: ActiveChatJobRecord]`, one poll task per job, `isSending(for:)`, persist an
array; the composer's Stop/Send state derives from the selected conversation.

**M4. Auto / Plan mode is absent.** No mode switch, no `planSystem`, no `firas-ask` parser/panel, no Start
pill, no `mode:"plan"/"auto"` stamping (fields exist in `ChatModels.swift:55,51` but nothing writes them).
Spec: `web-chat-ux.md §6`, `web-plan-mode.md §7` (state machine, concatenated system text, approval matcher,
deliverable routing). Category: missing-feature-vs-web (owner complaint). Fix: implement §7 after C1/C2; per-
conversation `planPhase`; the composer gets an Auto/Plan menu next to the model button.

**M5. Mic dictation is absent; the `+` sheet configures a dictation language for a feature that does not exist.**
`ChatComposer.swift` has no mic control (`ChatStrings.microphone` :6 unused); `FirasAPI` has no
`/api/transcribe`; `AddContextSheet.swift:404-447` shows "Dictation language". Web: `web-voice-call-mic.md
§7` (`POST /api/transcribe` with dialect hint, live-dictation fallback). Category: missing-feature-vs-web
(owner complaint). Fix: mic button in the action row (tap to start/stop, waveform meter), `AVAudioEngine`
16 kHz mono → WAV base64 → `/api/transcribe {audio, lang}`; on 503/offline fall back to
`SFSpeechRecognizer` (on-device for `en`/`ar-SA`); insert at the caret; hide the dialect row until then.

**M6. No message actions: copy, regenerate, versions, escalate to Max, share, listen, continue, export.**
`ChatMessageRow.swift` renders none of `web-chat-ux.md §9-10`; `alts/altAt/retryOf/retried` are decoded
(`ChatModels.swift:53-62`) but never shown, so a chat regenerated on the web loses its version pager here;
`ChatStrings.copy` (:78) unused; `textSelection(.enabled)` is the only copy path. Category: missing-feature-
vs-web. Fix: context menu + compact action row on assistant rows: Copy (Markdown), Regenerate (new cid; fold
into `alts` ≤5), Retry with Max (`retryOf` link + compare sheet), Share (`POST /api/share` → `/?share=<id>`),
Listen (`/api/tts` chunks ≤1300 chars, AVSpeechSynthesizer fallback), Continue when `answerLooksTruncated`,
Export (PDF via `ImageRenderer`, Markdown, text).

**M7. `think` is sent on Mini and the Thinking toggle is shown for Mini.**
`ChatScreen.swift:687` → `ChatStore.swift:417`; web sends `think && MODELS[tier].showThinking` (Mini =
false) and hides the toggle (`web-chat-ux.md §4`). Reasoning disclosure also ignores tier. Category:
contract-mismatch. Fix: `think = thinkingEnabled && tier != .mini`; disable the toggle with a footnote on
Mini; show the disclosure only when `tier.showThinking`.

**M8. Tier UX parity: dead "Response style" row, no tier badge on answers, no per-chat pin.**
`ModelSelectionSheet.swift:101-133` — a row with a chevron that does nothing. `ChatMessageRow` never shows
`message.tier` (web §8.2 badge; Ultra accent pill, Max purple). No `web §3.4` pin. Category: ux / visual-
design. Fix: delete the row or make it the Think/Search sub-page; add the badge + name row above assistant
text; optional pin stored per `serverChatID`.

**M9. Web search: no auto-trigger, no visible "searching" stage, no timeout.**
`ChatStore.swift:431-440` runs search only when the toggle is on (web also runs `needsWebSearch` /
silent search / i'rab, `web-chat-ux.md §5`); `api.webSearch` inherits the 45 s request timeout
(`APIClient.swift:62`) so a slow provider stalls the turn; `AssistantMessageRow.activityKind`
(`ChatMessageRow.swift:208-219`) keys off `message.mode`, which iOS never sets, so the label says "writing"
while searching. Category: missing-feature-vs-web / ux. Fix: 8 s (`withThrowingTaskGroup` race) for explicit,
1.5 s for silent; port the trigger regexes; a transient `jobPhase = .searching` drives the label.

**M10. Hard-coded Arabic user-facing strings and an untranslated "New chat" title.**
`ChatStore.swift:124, 160/170, 207, 211, 857, 1028, 1039` are Arabic literals shown regardless of UI
language; `:132, :251, :968` use the literal `"New chat"`, which `ChatNavigationTitle`
(`ChatScreen.swift:364-369`) displays as-is in the Arabic UI (`chat.new` exists in `Localizable.xcstrings`
but is unused here). Category: rtl-arabic / i18n. Fix: `String(localized:table:"Chat")` keys; treat the
server default title as "untitled" and display `chat.new`.

**M11. Quota / rate-limit / engine-failure answers are shown raw or as successes.**
`ChatStore.swift:1062-1071` `readableServerError` only unwraps `{"error"}`; 429 bodies
(`{"error":"guest daily limit reached","guest":true,"quota":{…}}`, `server.mjs:12882-12897`) render as the
English server string instead of `quotaLimitText` + sign-up CTA (`web-chat-ux.md §15`); the §1.8 engine-
failure sentences ("The Firas AI engine is busy…") arrive as `phase:"completed"`, are marked `.delivered`
(`:731-740`) and PUT into history — the web auto-retries once and never persists them. Category: ux /
contract-mismatch. Fix: decode `quota`/`guest`/`scope` → localized copy + Retry / Sign-up actions; match the
`busyRe` sentences → `.failed`, no PUT, one automatic retry with a new cid.

**M12. Provisional title is 80 raw chars and there is no AI auto-title.**
`ChatStore.swift:988-994`; web: 42 chars + "…" then `autoTitleChat` (`nomem:true, tier:"pro"`, 2-5 words,
`server-chat-jobs-chats.md §5.4`) and `PUT {title}` only. Category: missing-feature-vs-web. Fix: 42-char
provisional; after the first answer, run the title call (needs the C3 SSE client or a tiny job) and PUT
`{title}` unless the user renamed.

**M13. "New chat" creates a server record immediately and the app launches into the last chat.**
`ChatStore.swift:131-161` POSTs on every tap → empty "New chat" rows accumulate on the server and in the web
sidebar (web creates on first send); `:77-84` auto-selects the newest chat at launch. Category: ux /
contract-mismatch. Fix: create lazily in `send()` (the `selectedConversation == nil` path already exists);
launch on an unsaved local conversation.

**M14. The whole transcript (with base64 images) is persisted to `UserDefaults` on the main actor at every send.**
`ChatStore.swift:1005-1008` (`persist`), called at `:481`, `:1023`; decoded synchronously in `delete()`
`:168` and `stop()`. Multi-MB writes to the prefs plist hitch the main thread, and private photos land in an
unencrypted preferences file. Category: freeze-or-main-thread / security. Fix: persist only the pointer
(`ownerID, jobID, cid, conversationID, serverChatID, assistantMessageID, startedAt, cancelRequested`); members
re-fetch the transcript; guests keep it in a file under Application Support with `.completeFileProtection`.

**M15. Photo import decodes full originals; recent-photo thumbnails load synchronously on main.**
`AddContextSheet.swift:688-703` requests `.highQualityFormat`, `resizeMode: .none`, network allowed (a 48 MP
HEIC / iCloud original) and `ChatAttachmentProcessor.draftImage` (`:58-75`) does `UIImage(data:)` then draws
it — ≈200 MB peak per photo; `RecentPhotoTile.loadThumbnail` (`:844-861`) uses `isSynchronous = true` on the
main thread for each of 8 tiles. Category: freeze-or-main-thread / memory. Fix: `requestImage(for:targetSize:
1568², contentMode: .aspectFit)` (or `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`
for picker `Data`), and `isSynchronous = false` with the async handler updating `@State` on main.

**M16. Office documents are refused in chat although the app already has an extractor.**
`ChatAttachmentProcessor.swift:102-106` throws `unsupportedFile` for docx/pptx/xlsx; the web extracts them
client-side into `[Section n]/[Slide n]/[Sheet n]` blocks (`web-chat-ux.md §7.3`);
`Features/Brain/OfficeDocumentExtractor.swift` exists. Category: missing-feature-vs-web. Fix: call the
extractor here, keep the truncation notice.

**M17. Follow-up questions about an attached image go to a text model.**
`ChatStore.swift:260-263` strips `images` from every prior turn; the server routes vision only from the
*last* user message (`hasImages` :465); the web re-attaches the last images when the follow-up "refers to the
prior image" (`app.js:35906`). Category: contract-mismatch. Fix: keep the last turn's full images in memory
(never persisted) and re-attach them on a follow-up that matches the web regex, or offer "Ask about this
image" on the thumbnail.

**M18. Text direction follows the UI language, not the content; the shell, sheets and rows disagree.**
`ChatScreen.swift:83, 112, 117` force `layoutDirection` from `preferences.language` on the whole transcript
and composer, while `FirasAppShell.swift:47` fixes the shell LTR (as the web does). Result in Arabic UI: user
bubbles on the **left** (`.trailing` in RTL), assistant mark on the right, toolbar LTR; an English answer is
laid out as an RTL block; in the English UI an Arabic answer is LTR-aligned. `AddContextSheet.swift:214`
forces LTR on the sheet, `:923` re-forces per-language inside `ContextTextColumn`, dividers pad `.leading`
(`:947`) and chevrons are `chevron.forward` — three directions in one sheet. Web: shell LTR, every bubble
`dir` from its own content (`web-chat-ux.md` conventions; `app.js:22962, 23894`). Category: rtl-arabic. Fix:
keep the shell LTR; a `TextDirection.detect(_:)` (first strong Arabic/Hebrew scalar) per message drives
`.environment(\.layoutDirection)` + `.multilineTextAlignment` on that row only; user bubble anchored trailing
in the LTR shell (right) always; composer direction follows the draft (`syncComposerDir`); in the sheet pick
one direction per language and use `.leading` semantics consistently.

**M19. iPad: no keyboard shortcuts, no drop/paste, composer and transcript widths diverge.**
No `.keyboardShortcut` anywhere in the group (⌘N new, ⌘↩ send, ⌘. stop, ⌘K sidebar); no
`.dropDestination`/`.onPasteCommand` for images/files (web supports drag-drop and paste, §7.3);
`ChatComposer.swift:28-31` caps at 760 while the transcript uses `preferences.contentWidth.maxWidth` (980
when wide, `ChatScreen.swift:178`) so they misalign; `ChatNavigationTitle` caps at 260 pt; no `.hoverEffect`.
Category: ipad. Fix: shortcuts on the composer/toolbar, `dropDestination(for: Data.self)` on the screen with
the same processing path as the `+` sheet, tie the composer width to `contentWidth`, hover effects on the
circle buttons.

**M20. Activity/reasoning state is inverted during `think:true` jobs.**
Server streams `reasoning` before `text`; `AssistantMessageRow` (`ChatMessageRow.swift:155-179`) shows the
activity label only while `content.isEmpty`, keyed off `mode` (never set) → "writing" during thinking, then
a collapsed disclosure appears; when expanded, `Text(reasoning)` re-lays out every tick. Category: ux. Fix:
derive the label from `jobPhase` + `think`; a live "Thinking…" header with the reasoning tail, collapsing
when text starts.

### Minor

- **m1** `ChatMessageRow.swift:252` `ForEach(files, id: \.name)` — duplicate file names produce duplicate
  IDs. Use `Array(files.enumerated())` with `\.offset`. (crash-risk: none, layout undefined)
- **m2** `ChatMessageRow.swift:96` attached-image accessibility label is "Recent photo"; use "Attached image
  N". (accessibility)
- **m3** `Chat.xcstrings` dead keys: `context.sources`, `context.selectedLocally`, `context.backendRequired`,
  `context.unavailable`, `context.unavailable.detail`, `composer.microphone`, `message.copy`,
  `modelPicker.subtitle`; `composer.voiceUnavailable` ("waiting for the transcription service connection") is
  shown when `onStartCall` is nil (`ChatScreen.swift:325-333`) and is wrong copy. (ux)
- **m4** `ChatScreen.swift:119-128` error banner overlays the transcript with no auto-dismiss and no
  VoiceOver announcement; poll errors keep it until the next success. Add
  `AccessibilityNotification.Announcement` and auto-hide. (accessibility)
- **m5** `ChatMessageRow.swift:112-142` image preview has no pinch-zoom, share or save. Use `QLPreviewController`
  or a magnifying `ScrollView`. (ux)
- **m6** Drafts are one `@State draft` (`ChatScreen.swift:53`) shared across chats and lost on relaunch; web
  keeps per-chat drafts (§7.2). (missing-feature-vs-web)
- **m7** `ChatComposer.swift:35-48` — with `TextField(axis: .vertical)` the software keyboard's Return
  inserts a newline and `onSubmit` generally does not fire, so `sendOnReturn` likely never works on the
  soft keyboard (verify on device). Use `.onKeyPress(.return)` for hardware keyboards and detect a trailing
  `\n` in `onChange` when `sendOnReturn` is on. (ux)
- **m8** `ChatStore.swift:698-706` poll cadence 350 ms for 10 s = 30 requests per job start on cellular;
  500/1000/1500 ms is indistinguishable once C5's tail rendering exists. (ux/battery)
- **m9** `FirasActivityLabel` runs a 30 fps `TimelineView` for every `.sending` row (`FirasActivityLabel.swift:278`)
  on top of the tick re-renders. Fine alone; pair with C5. (freeze-or-main-thread)
- **m10** Guest history is not persisted (web keeps `firas_guest_chats`); a guest loses every chat on
  relaunch. (missing-feature-vs-web)
- **m11** `ChatStore.select` (`:100-115`) replaces the streaming placeholder with the server copy until the
  next tick (visible flash); reuse `mergedMessages` (`:951-963`). (ux)
- **m12** `preferences.fontScale` is bound in Settings but `FontScale.factor` is read nowhere — the "Reading
  size" preference is dead in chat. Apply via `.dynamicTypeSize` or a `ScaledMetric`. (ux)
- **m13** `ChatScreen.swift:246-253` / `ModelSelectionSheet.swift:140-144` — sleep-then-present/dismiss
  tasks are not tied to view lifetime; harmless but use `.task` or `presentationDismissed` hooks. (ux)
- **m14** `ChatWelcomeView` (`ChatScreen.swift:380-398`) shows a mark and one line; `chat.empty.subtitle`
  exists unused and the web shows suggestion chips (§12). (visual-design)
- **m15** `AddContextSheet.swift:706-718` `.textCase(.uppercase)` on section headings is a no-op in Arabic and
  the headings are forced LTR. (rtl-arabic)
- **m16** `ChatStore.swift:454-459` requests notification permission on the first job with no in-app
  pre-prompt explaining why; consistent with README but a one-line explainer sheet converts better. (ux)

### Visual design / Liquid Glass (owner: "mediocre", "glass not transparent enough")

- **V1** `GlassSurface.swift:22-27` uses `.regular` glass with an accent tint for everything (composer,
  cards, activity pill). For a floating composer over scrolling text the more transparent variant is
  `Glass.clear` (iOS 26; guard with `#available`), and the four action controls should live in one
  `GlassEffectContainer` with `.glassEffect(.regular.interactive())` per button instead of solid
  `Circle()` fills (`ChatComposer.swift:202-205`) sitting *on* glass — Apple's guidance is glass-on-glass is
  the one thing not to do, and that nesting is exactly what makes it read as a flat tinted card. On
  iOS 18–25 the fallback (`.ultraThinMaterial` + hairline, `:29-39`) is already the thinnest material; the
  opacity people see there comes from the near-uniform `FirasBackground` — there is nothing behind the glass
  to refract. Let the transcript scroll under the composer (it already does via `safeAreaInset`) and drop
  the `.padding` wrapper's solid feel by removing the tint on the composer.
- **V2** `ModelSelectionSheet.swift:58`, `AddContextSheet.swift:212` set `presentationBackground(palette.background)`
  → opaque sheets; the glass cards inside have no depth and iOS 26's sheet glass is suppressed. Use the
  default or `.presentationBackground(.thinMaterial)`.
- **V3** `ChatMessageRow.swift:40-47` user bubble = `palette.surface` + 1 pt border (web: accent-deep fill,
  white ink, top sheen, 20 pt radius); assistant turn has no name/tier badge row, no stream caret; system
  rows are grey boxes. Adopt the web tokens (`--user-fill`, `--user-ink`) from `FirasPalette`.
- **V4** `ChatScreen.swift:86` `.toolbarBackground(.hidden)` removes the iOS 26 navigation-bar glass, so the
  title floats over text with no legibility treatment; on 26 leave the default.
- **V5** `ModelTierRow` icons are generic SF symbols on a tinted square; the web uses zap/bolt/star/crown with
  Ultra accent and Max purple. Mirror the badges.

### Compile risk under Swift 5 mode + minimal concurrency + default nonisolated

No blocking issue found in this group. Verified reasoning:
- Every `View` struct inherits `@MainActor` from the `View` protocol (`@MainActor @preconcurrency protocol
  View` in the iOS 18+ SDK), so `Task {}` inside `ChatScreen.send()` (`:286-315`), `AddContextSheet`
  import tasks (`:553-680`) and `ModelSelectionSheet.select` still run on the main actor and their `@State`
  mutations are safe.
- `ChatStore`, `PreferencesStore`, `NotificationCoordinator`, `FirasCompletionCue` are explicitly
  `@MainActor`; `ChatAttachmentProcessor` is explicitly `nonisolated` and uses `Task.detached`; the
  file-scope `private nonisolated struct ActiveChatJobRecord` (`ChatStore.swift:4`) relies on SE-0449
  (`nonisolated` on types), which the Xcode 26 compiler accepts in `-swift-version 5`.
- `CameraCaptureView.Coordinator` (`AddContextSheet.swift:1040`) gets `@MainActor` from the UIKit delegate
  protocols; `RecentPhotoTile.loadThumbnail`'s non-`@Sendable` completion inherits the view's isolation and
  runs synchronously (`isSynchronous = true`) — fine today, but if M15 flips it async, mark the handler body
  `Task { @MainActor in image = result }`.
- `ModelTier.label(language:)` / `tagline` are `@MainActor` on a `nonisolated enum` (`CommonModels.swift:96-104`);
  all call sites are views. OK.
- `@preconcurrency import` on Photos/PDFKit/UIKit is harmless in minimal mode.
Watch-outs when applying the fixes: new SPM packages (swift-markdown, SwiftMath) must be added to the
pbxproj `packageReferences` and the target's `packageProductDependencies` by hand; any new `Task.detached`
closure that touches `UIImage`/`CIContext` must stay inside the detached body (as `sharpened` does).

---

## C. Owner complaints — checked against this group

| Complaint | Finding |
| --- | --- |
| Design mediocre, glass not transparent | V1-V5, C2 (raw markdown), M8 (no tier badge). Root causes: `.regular` tinted glass with solid buttons nested inside, opaque sheet backgrounds, no Markdown. |
| Code / Agent / Brain thin | Not this group, but chat never renders `firas-code`/`firas-file` cards (C2), the Brain row in `+` only switches product (`AddContextSheet.swift:108-127`; web has "Ask elsewhere → Brain/Agent"), and no system prompt (C1) means code answers have no fence/engineer rules. |
| Backend/APIs not fully used | Unused by chat: `POST /api/chat` SSE (C3), `/api/transcribe` (M5), `/api/tts` (M6), `/api/share` (M6), `/api/translate`, `/api/memory` (view/clear memory), `/api/fetch` (URL reading), `/api/images`, job kinds `longdoc`/`longfile` + `GET /api/chat/job/file` (the server can write a 10-page PDF; iOS returns prose), image-from-chat routing to `/api/image/job`. |
| Call kicks the user out / app freezes | Call view is another group; from here: C5 (scroll yank every tick), C4 (3 s hold with Stop live), M3 (global send lock), M14/M15 (main-thread blobs and full-size decodes) all read as "freezing". |
| Must keep working after leaving the app | Verified: the poll task is store-owned and nothing in `ChatScreen` cancels it (no `onDisappear`); the record survives relaunch; the server job continues regardless. Gaps: C6 (401 loop), no `scenePhase` hook to re-poll on return (the suspended task resumes by itself, so acceptable), no `beginBackgroundTask` around the final PUT (safe — the worker already saved the turn). |
| Notification when a job finishes + haptic before completion | APNs routing exists (`NotificationCoordinator`, `FirasAppShell.routePendingNotification` → `chatStore.select`); local fallback only when inactive and unregistered (`:238-257`). Haptic: implemented as two soft impacts then a **3 s** hold of the answer (C4) — not the Claude behaviour asked for. |
| Mic dictation | Missing (M5); a dictation-language picker exists for nothing. |
| Auto / Plan modes | Missing (M4). |
| mini / pro / ultra / max | Present in the picker with the web's names/taglines; Think not gated on Mini (M7), no badge/pin (M8), dead "Response style" row. |
| Professional on iPhone AND iPad | M19 (shortcuts/drop/paste/widths), M18 (direction), V1-V4. |

---

## D. Keep / rewrite verdict per file

| File | Verdict | Why |
| --- | --- | --- |
| `Stores/ChatStore.swift` | **Keep skeleton, refactor ~40 %** | The job lifecycle (idempotent start by cid, stop-before-enqueue, persisted pointer, owner guards, cancel retry) is careful and matches the server contract. Change: multi-job map (M3), prompt injection (C1), SSE fallback + slim encoders + windowing (C3/M1), terminal 401/403 + backoff (C6), pointer-only persistence (M14), merge-on-finish (M2), remove the reveal hold (C4), localized strings (M10), quota/engine-failure handling (M11), 42-char title + auto-title (M12), lazy create (M13), search timeout/auto (M9), image re-attach (M17). |
| `Models/ChatModels.swift` | **Keep** | Faithful to `sanitizeMessages`; decoder ids are stable. Add `OutgoingChatMessage`, `PersistedChatMessage`, `planPhase`/`AskSpec`, `ChatJobPhase.searching` (client-only). |
| `Features/Chat/ChatScreen.swift` | **Keep frame, rewrite `conversation`** | `NavigationStack` + `safeAreaInset` composer + sheet routing is right. Rewrite scrolling/diffing (C5), add drop/paste/shortcuts (M19), banner a11y (m4), per-chat drafts (m6), welcome (m14). |
| `Features/Chat/ChatComposer.swift` | **Rewrite** | Needs mic (M5), mode menu (M4), inline attachment tray (today only a count badge; web §7.3 shows thumbnails/chips), length meter, `GlassEffectContainer` (V1), width tie-in (M19), Return handling (m7). Keep the `ViewThatFits` idea and the send/stop/call morph. |
| `Features/Chat/ChatMessageRow.swift` | **Rewrite** | Markdown/code/math/cards (C2), per-row direction (M18), tier badge + actions + versions (M6/M8), cached thumbnails (C5), streaming tail (C5/M20). |
| `Features/Chat/AddContextSheet.swift` | **Keep, fix** | Photo strip / camera / files flows and the generation-guarded async imports are solid. Fix RTL forcing (M18), ImageIO downsampling and async thumbnails (M15), Office via `OfficeDocumentExtractor` (M16), hide the dictation row until M5, opaque sheet background (V2). |
| `Features/Chat/ChatAttachmentProcessor.swift` | **Keep** | Correct off-main design, sane budgets. Add ImageIO downsample, Office extraction, and make `maximumJobContextCharacters` account for history (C3). |
| `Features/Chat/ModelSelectionSheet.swift` | **Keep, trim** | Remove/wire "Response style", gate Think on Mini, web badges (M8/V5), drop opaque background (V2). |
| `Features/Chat/ChatStrings.swift` + `Chat.xcstrings` | **Keep** | Prune dead keys (m3), add keys for M10/M11/M4/M5/M6, fix `composer.voiceUnavailable`. |

---

## E. Open questions for the owner / lead

1. Send the web's full ~40k-character system prompt verbatim on every turn (exact parity, higher token
   cost) or a trimmed native variant that keeps persona/language/math/code/accuracy and drops the
   problem-generation manuals unless the message asks for problems?
2. Math rendering: `SwiftMath` (native, fast, no mhchem) vs a per-message `WKWebView` with bundled KaTeX
   (exact parity incl. `\ce{}`, heavy in long chats). Each SPM add costs a CI cycle.
3. For members, should iOS stop doing the final whole-array PUT and trust `saveAssistantTurn`?
4. Where should guest history live (file under Application Support, 7-day TTL matching the guest cookie)?
5. `Glass.clear` for the composer — confirm on a device that legibility over Arabic body text is acceptable
   with the theme palettes; otherwise `.regular` untinted + `GlassEffectContainer`.
