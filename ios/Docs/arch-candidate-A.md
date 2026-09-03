# Architecture candidate A — reliability first

Angle: design from the failure modes outward. Every screen sits on four things that must never lie:
the cookie jar, the job pointer table, the reattach loop, and the audio graph. Everything else is
SwiftUI on top. Sources: `ios/Docs/server-*.md`, `web-*.md`, `design-brief.md`, `audit-ios-*.md`.

Non-negotiables inherited from the environment: Swift 5 mode, `SWIFT_STRICT_CONCURRENCY=minimal`,
default **nonisolated**, `IsolatedDefaultValues` on, iOS 18 target, Xcode 26 on CI, nobody compiles
locally, no Apple team (no APNs / App Groups / CallKit / iCloud / associated domains), only
ZIPFoundation 0.9.20 as a package (kept — Office extraction in Brain needs it).

---

## 0. The eleven failure modes this design is built around

| # | Failure the owner sees | Root cause in the Codex app | Design answer (file) |
|---|---|---|---|
| 1 | "App freezes" on launch offline | `restore()` waits 180 s with `waitsForConnectivity`, then lands in limbo with no UI | `SessionStore` has an explicit `.unreachable` phase with Retry; boot calls use a 12 s budget (`RequestBudget.interactive`) |
| 2 | Member session dies silently (401 everywhere) | no central 401 hook | `APIClient` emits `.unauthorized` events → `SessionStore.handleUnauthorized()` (idempotent) |
| 3 | Job "still working" forever / product locked | poll loops without terminal set, deadline, 403 rule | one `JobManager` with a `JobKindDriver` per kind; every driver has terminal set + deadline + 403/404/unknown rules |
| 4 | No notification after leaving | no background execution | `BackgroundExecutor` (beginBackgroundTask around every watcher) + `BackgroundRefresh` (BGAppRefreshTask) + local notifications from `JobManager` |
| 5 | Finished answer held 3 s; Stop during hold loses it | `FirasCompletionCue` sleeps 3 s | `CompletionCue.fire()` is ≤ 150 ms and never awaited before applying terminal state |
| 6 | Scroll yank / re-render every tick | whole conversation replaced 3×/s | `StreamBuffer` coalesces to 10 Hz; rows are `Equatable`; autoscroll only when pinned to bottom |
| 7 | Call kicks the user out | AVFoundation ObjC exception (`play()` on stopped engine), no AEC, no setup deadline, background ends call | `CallAudioGraph` guards every engine call, VPIO on, `isEnding` latch; `CallEngine` deadlines every await; `UIBackgroundModes: audio` |
| 8 | 413 kills a chat forever | no SSE fallback, full history in job body | `HistoryWindow` (≤ 400 k chars) + `OutgoingMessage` slim encoder + `APIClient.stream` fallback |
| 9 | Private photos in UserDefaults, multi-MB plist writes on main | transcript persisted with images | `DiskStore` actor (Application Support, atomic, file protection); pointers only in `jobs.json`; images never persisted |
| 10 | Wrong language strings / English errors in Arabic UI | verbatim server strings, xcstrings+locale uncertainty | `L` string tables in Swift (§1.6) + `ServerErrorMapper` keyed on (status, code) |
| 11 | CI red for 15 min per typo | cleverness | §6 compile rules; one owner per file; frozen interfaces (§4) written first |

---

## 1. Folder layout under `ios/FirasAI` — every file, one owner each

Target 150–400 lines per file. Files marked **(keep)** exist today and compile; they are reshaped, not
rewritten from zero. Everything else is new. Delete `Notifications/PushRegistrationClient.swift`,
`Features/Chat/LiveVoiceController.swift`, `Networking/FirasAPI.swift` (replaced by `Endpoints/*`).

### App/
- `FirasAIApp.swift` **(keep)** — composition root: builds `AppEnvironment`, injects stores, `onOpenURL`, `scenePhase` → `AppLifecycle`.
- `AppEnvironment.swift` — one struct holding every store/service instance (constructed once, `@MainActor`); avoids 12 `.environment()` chains.
- `AppLifecycle.swift` — `@MainActor` object: `didBecomeActive` (session revalidate, `JobManager.resumeAll`, `NetworkMonitor` kick), `didEnterBackground` (persist drafts, `BackgroundRefresh.schedule`, `BackgroundExecutor.holdWhileJobs`).
- `AppConfiguration.swift` **(keep)** — base URL (https only), bundle facts, `isDebug`.
- `AppRoute.swift` — `enum AppRoute` (chat(id), agent(chatID), code(projectID), brain, studio(jobID?), settings(tab), auth, share(id)) + `Router` (`@Observable`, pending route, product selection).
- `FirasAppDelegate.swift` **(keep, trim)** — `UNUserNotificationCenter` delegate, `BGTaskScheduler.register` in `didFinishLaunching`. No APNs callbacks.

### Core/ (no SwiftUI imports; everything `Sendable`)
- `DiskStore.swift` — `actor DiskStore`: JSON read/write under Application Support, atomic write, `.completeFileProtection`, excluded from backup; keyed by owner id.
- `NetworkMonitor.swift` — `NWPathMonitor` wrapper, `@Observable @MainActor` `isOnline`, `AsyncStream<Bool>` for actors.
- `BackgroundExecutor.swift` — `beginBackgroundTask/endBackgroundTask` scope helper: `func hold(name:) -> BackgroundHold` (auto-expires, never leaks).
- `BackgroundRefresh.swift` — BGAppRefreshTask id `$(PRODUCT_BUNDLE_IDENTIFIER).jobs`: `register()`, `schedule(after:)`, handler = `JobManager.refreshOnce(budget: 20 s)`.
- `Clock.swift` — `Backoff` (exponential with cap), `Deadline`, `withDeadline(seconds:) throws` (task-group race — the only allowed pattern for "never hang").
- `IDs.swift` — `cid()` (16 chars `[A-Za-z0-9_-]`), `clientChatID()` (`ios_<uuid>`), sanitisers matching server regexes.
- `BidiText.swift` — `firstStrongDirection(_:) -> LayoutDirection?`, Arabic normalisation (tashkeel/tatweel/hamza), Arabic-Indic digit formatting.
- `Log.swift` — `os.Logger` categories; `Log.net/jobs/call/ui`; redaction of tokens and cookie values.
- `Haptics.swift` — prepared generators; `Haptics.selection/light/medium/success/error`; foreground-only guard.

### Networking/
- `APIClient.swift` **(keep, extend)** — `actor APIClient`: shared cookie jar, `RequestBudget`, JSON in/out, `stream` (SSE), `download(to:)`, 401 event bus, `+` query encoding.
- `APIError.swift` — `APIError` + `ServerError` (decoded `{error, quota, guest, feature, limit, used, windowMin, freesInMin, activeJob, credits, retryRequiresNewCid, scope}` — every field optional).
- `LenientJSON.swift` — `JSONValue` enum, `KeyedDecodingContainer` helpers (`lenientInt`, `lenientBool`, `lenientString`), `LenientDecoder` that never throws on unknown enum raw values.
- `SSEParser.swift` — byte-stream → `SSEFrame(event:, data:, id:)`; buffers partial lines; tolerates `: keepalive`, CRLF, `[DONE]`.
- `RequestBudget.swift` — `enum RequestBudget { interactive(12 s), poll(30 s), upload(300 s), download(resource 0/idle 60 s), stream(idle 300 s) }` → `URLRequest.timeoutInterval` + per-budget `URLSession`.
- `Endpoints/AuthEndpoints.swift` — login/signup/verify-status/verify-signup/resend/forgot/reset/me/logout/google-native/guest start+end/change-*/delete.
- `Endpoints/ChatEndpoints.swift` — `/api/chats*`, `/api/chat` (stream), `/api/chat/job` start/status/cancel/file, `/api/search`, `/api/share`, `/api/translate`.
- `Endpoints/AgentEndpoints.swift` — `/api/usage/charge`, `/api/agent/job`, `/api/agent/job-stream` (SSE), `/api/agent/artifact`, `/api/agent/credits`.
- `Endpoints/BrainEndpoints.swift` — `/api/brain/docs|doc|search|passage|whole`, `brainask` job start.
- `Endpoints/MediaEndpoints.swift` — image/video/music job start+status, file download, `/api/image/quota`, `/api/video/quota`, `/api/image/edit`.
- `Endpoints/VoiceEndpoints.swift` — `/api/live/token`, `/api/transcribe`, `/api/tts`.
- `Endpoints/AccountEndpoints.swift` — `/api/memory*`, `/api/announcements`, `/api/redeem`.
- `GoogleOAuthProvider.swift` **(keep)** — PKCE via `ASWebAuthenticationSession(url:callback:)`; `nonisolated presentationAnchor` fix.

### Models/ (all `struct … : Codable, Sendable, Hashable`, decoded leniently)
- `User.swift` **(keep as AuthModels)** — `User`, `Subscription`, `UsageCounts`, plan enum (unknown → `.free`).
- `ChatModels.swift` **(keep, extend)** — `ChatMessage`, `Conversation`, `PersistedChatMessage` (server whitelist), `OutgoingMessage {role, content, images?}`, `ChatSummary`, `ModelTier` (drop `@MainActor`), `ProductKind`, `ResponseMode`.
- `JobModels.swift` — `JobKind`, `JobPhase`, `JobPointer`, `ChatJobStatus`, `ChatJobStart`, `LongFileProgress`, `LongFileSurface`, `FileArtifactManifest/Part`.
- `AgentModels.swift` **(keep)** — `AgentJobView`, `AgentSurface`, `AgentEvent`, `AgentFile (+artifactIndex from url)`, `AgentCredits`, `AgentBusy`.
- `CodeModels.swift` **(keep)** — `CodeProject`, `CodeFile`, `firas-project` fence parser, caps (30 files / 60 k / 180 k).
- `BrainModels.swift` **(keep, extend)** — docs/hits (`near: Bool?`), whole-answer, lenient `kind/unit`.
- `MediaModels.swift` **(keep as MediaStudioModels)** — `MediaKind`, `MediaCreation` (relative filename), requests with `image` first frame, presets fixed (3:4, 21:9).
- `VoiceModels.swift` — `LiveToken {provider, token, model, voice?, maxMs, guest, startWithinMs}`, `DictationDialect` (14 server keys), `CallVoice`, `TTSRequest`.
- `SettingsModels.swift` **(keep)** — account DTOs, backup format.
- `Fences.swift` — parsers for ```` ```firas-ask / firas-code / firas-file / firas-image / firas-video / firas-music / firas-agent / firas-project ```` blocks (first-fence, tolerant of `json` tag when phase expects ask).
- `Announcement.swift` — announcement record + built-in launch post.

### Session/
- `SessionStore.swift` **(rewrite lifecycle, keep calls)** — phases, restore with budget, guest/member, `handleUnauthorized`, revalidate on active, `didTransitionGuestToMember`, per-operation `isWorking` flags.
- `AuthErrorMapper.swift` — (status, server code) → `L` key; login-500 → "wrong credentials or Google account".
- `GuestMigration.swift` — after sign-in: local guest chats → `POST /api/chats` (concurrency 3, per-chat failure tolerated) → `DELETE /api/guest`.

### Jobs/ (the reliability core)
- `JobManager.swift` — `@MainActor @Observable`: pointer table, one `JobWatcher` per pointer, `start/attach/cancel/forget/resumeAll/refreshOnce`, terminal fan-out to stores, local notification + cue.
- `JobPointerStore.swift` — `jobs.json` via `DiskStore`; ≤ 40 pointers, per-owner, drops expired.
- `JobWatcher.swift` — the loop: cadence by kind and scene phase, `Backoff`, 401/403/404/unknown rules, deadline, offline pause, `BackgroundHold` while active.
- `JobKindDriver.swift` — `protocol JobKindDriver` + `ChatJobDriver` (chat/longdoc/longfile), `AgentJobDriver` (SSE first, poll fallback), `CodeBuildDriver`, `BrainAskDriver`, `MediaJobDriver`.
- `JobEvents.swift` — `JobEvent` enum published through `AsyncStream` and `JobObserver` protocol (stores subscribe per pointer).

### Notifications/
- `NotificationCoordinator.swift` **(rewrite)** — permission state, `postJobTerminal(pointer:phase:)` with server-verbatim copy in `L.notify`, category `FIRAS_JOB_COMPLETE`, sound `FirasComplete.wav`, dedupe by job id.
- `NotificationRouter.swift` — `userInfo` → `AppRoute` (same nested `firas.*` keys as the server); handles cold-start tap.
- `CompletionCue.swift` — haptic (`.success` or soft impact 0.5) + optional `done.caf` via `AVAudioPlayer .ambient`; ≤ 150 ms; skipped while a call is active; consumed-key history.

### DesignSystem/
- `FirasTheme.swift` **(keep, extend)** — six palettes + derived tokens (`glassTint/Wash/Stroke`, `userFill/Ink/Edge`, `accentSoft/Ring`, `maxTier*`, `callBackground`), `PreferencesStore` (defaults: dark / device-language→ar unless `en` / pro).
- `FirasGlass.swift` — `enum FirasGlass.Level {chrome, floating, sheet}` + `ViewModifier` with `#available(iOS 26)` branch and iOS 18 material fallback; the only place `glassEffect` is spelled.
- `Surfaces.swift` — `SurfaceCard` (opaque `surface` + hairline + shadow), `FirasBackground` **(keep)**, `UserBubbleShape`.
- `Typography.swift` — `FirasFont` text styles, `lineSpacing(for direction)`, `Text.firasTracking()` (Latin only), mono.
- `Motion.swift` — `FirasMotion.standard/sheet/composer/pop`, `motionOn` environment key (Reduce Motion ∧ preference).
- `Components.swift` — `Pill`, `IconButton` (44 pt), `Toast` + `ToastCenter`, `SkeletonRow`, `ActivityLabel` **(keep, 1 animation not TimelineView)**, `LiveDot`.
- `BrandMark.swift` **(keep)** — mark + wordmark.
- `MentronXEntryView.swift` **(keep, ≤ 1.2 s, tap to skip)**.

### Localization/
- `L.swift` — `struct LString { ar, en }`, `enum L` namespaces, `AppLanguage` resolution from `PreferencesStore`.
- `L+Shell.swift`, `L+Chat.swift`, `L+Auth.swift`, `L+Agent.swift`, `L+Code.swift`, `L+Brain.swift`, `L+Media.swift`, `L+Voice.swift`, `L+Settings.swift`, `L+Errors.swift`, `L+Notify.swift` — verbatim web strings per feature (one owner each).

### Prompting/
- `PromptCatalog.swift` (other agent; assumed `enum PromptCatalog` with `systemPrompt(tier:product:mode:lang:think:requestKind:)`).
- `PromptBuilder.swift` — assembles the **single** system message per turn: catalog + plan-mode text (§2.8) + file guidance + search-empty note; never the identity block.
- `MessageSerializer.swift` — `outgoing(conversation:) -> [OutgoingMessage]`, `persisted(conversation:) -> [PersistedChatMessage]`, merge-by-cid.
- `HistoryWindow.swift` — keeps system + last turns under 400 k chars (always the last user turn; images only on the last user turn; re-attach previous images on image-follow-up regex).
- `RequestClassifier.swift` — `RequestKind` (chat/image/edit/video/pdf/docx/pptx/xlsx/csv/code/longdoc/longfile) from regexes ported verbatim (`LONGDOC_RE`, `parseExplicitPageCount`, `detectCodeRequest`, `detectImageRequest`, `needsWebSearch`, `benefitsFromSilentSearch`).
- `SearchContext.swift` — `/api/search` call with 8 s / 1.5 s budgets, `formatSearchContext` (nonce fence), tier downgrade rule.

### Rendering/ (Markdown, code, math, cards)
- `MarkdownBlocks.swift` — block splitter → `[MDBlock]` (heading, paragraph, list, quote, code, table, hr, math, fence(firas-*)); streaming-safe (open fence = plain text).
- `MarkdownInline.swift` — inline → `AttributedString` via `AttributedString(markdown:options:.inlineOnlyPreservingWhitespace)` + link/inline-code/inline-math post-pass.
- `MarkdownView.swift` — renders `[MDBlock]`; settled prefix cached, live tail re-parsed; per-block bidi island.
- `CodeBlockView.swift` — LTR mono, language label, copy, horizontal scroll, `HighlightLite` (keywords/strings/comments for html/css/js/ts/py/swift/json/sh).
- `MathText.swift` — `texToUnicode` port; inline + display in an LTR island; `MathWebView.swift` (KaTeX island) is **not** in v1 (§7).
- `TableView.swift` — `Grid` inside `ScrollView(.horizontal)`.
- `Cards/AskCard.swift` — `firas-ask` wizard (state in `PlanMachine`).
- `Cards/CodeCard.swift`, `Cards/FileCard.swift`, `Cards/MediaCards.swift` (image/video/music), `Cards/AgentCard.swift`, `Cards/ProjectCard.swift`.
- `QuickReplies.swift` — chips from headings/bullets.

### Stores/
- `ChatStore.swift` **(keep skeleton, refactor)** — conversations, select/create-lazy/delete(undo 7 s)/rename/pin, send pipeline, per-conversation live state, guest local history.
- `ChatTurnPipeline.swift` — one turn: attachments → classify → search → prompt → persist user turn → job start (or stream) → observe → finish/merge; owns the 413/404 fallback and busy-sentence retry.
- `StreamBuffer.swift` — accumulates `text/reasoning`, publishes at ≤ 10 Hz, `<think>` splitter.
- `DraftStore.swift` — per-chat drafts (LRU 30, 20 k chars), saved 400 ms after typing and on background.
- `AgentStore.swift` **(rewrite engine)** — mission = `agent:true` chat; start/attach/resume; credits; artifacts index-from-URL.
- `CodeStore.swift` **(rewrite around project = chat)** — projects as `codeProj` chats + `CodeProjectCache`; build job; in-IDE edits via stream.
- `BrainStore.swift` **(rewrite)** — library, import phases, ask pipeline (whole → search → grounding stream), `brainask` job for long asks.
- `MediaStore.swift` **(keep core, fix)** — creations → conversation fences; deadlines; download-to-file; audio session.
- `AnnouncementStore.swift` — feed + unseen dot; `MemoryStore.swift` — `/api/memory` view/clear + fire-and-forget learn.
- `ImageCache.swift` — `actor` + `NSCache<NSString, UIImage>`; decode off-main once; disk cache by media key.

### Voice/
- `CallEngine.swift` — `@MainActor @Observable` state machine (§2.10): ladder, deadlines, two clocks, phases, diagnostics.
- `CallAudioGraph.swift` — AVAudioSession + AVAudioEngine (VPIO, converter, player, mic `AsyncStream<Data>`), all guarded.
- `CallTransport.swift` — `protocol CallTransport` + `CallEvent`.
- `OpenAIRealtimeTransport.swift` — WS to `wss://api.openai.com/v1/realtime`, GA vocabulary, mic gate, truncate.
- `GeminiLiveTransport.swift` **(keep protocol code)** — setup frame with verbatim instruction, tools, reduced-setup retry, cooldown memory.
- `EchoGuard.swift` — RMS floor / silence substitution for the Gemini rung.
- `ThreeHopCall.swift` — record → transcribe → chat (call system prompt) → TTS; used when no live engine mints.
- `DictationRecorder.swift` — 16 kHz mono WAV recorder (`AVAudioEngine` tap → `AVAudioConverter`), 300 s cap, level stream.
- `TranscribeService.swift` — server `/api/transcribe` (`format:"wav"`, dialect key) with `SFSpeechRecognizer` fallback on 503/offline.
- `ListenController.swift` — TTS: chunk ≤ 1 300 on `.!?؟،؛\n`, `/api/tts`, WAV/MP3 sniff, 16-entry cache, 429 → `AVSpeechSynthesizer` from failed chunk, one speaker token.
- `AudioSessionArbiter.swift` — the only object that calls `AVAudioSession.setCategory/setActive`; owners: call > listen > ui-sound.

### Features/Shell/
- `RootView.swift` — switches `SessionStore.phase`: intro → landing/auth → shell; `.unreachable` banner + Retry.
- `AppShell.swift` **(keep geometry)** — size-class switch: iPhone `ZStack` detail + drawer; iPad `NavigationSplitView`; fixed-LTR root; sheets/covers routed by `Router`.
- `Drawer.swift` — floating-glass drawer, edge-swipe, momentum projection, scrim.
- `Sidebar.swift` **(rewrite)** — product switcher (5), new chat, search, pinned/date groups, live dot, swipe pin/delete(undo), rename, account pill, bell.
- `ProductSwitcher.swift`, `HistoryList.swift`, `AccountPill.swift` — sidebar pieces.
- `ToastHost.swift` — bottom floating toast with one action.

### Features/Chat/
- `ChatScreen.swift` **(keep frame)** — toolbar (drawer, tier pill, new), transcript scroll, composer inset, scroll-to-bottom chip, banners.
- `TranscriptView.swift` — `LazyVStack` of `MessageRow` (Equatable), pinned-to-bottom tracking, skeleton, welcome.
- `MessageRow.swift` — dispatch user/assistant/system; per-row bidi island; tier badge; reasoning disclosure; action row; versions pager.
- `UserBubble.swift`, `AssistantHeader.swift`, `MessageActions.swift` (copy/regenerate/listen/export/share/retry-with-max/continue).
- `Composer.swift` **(rewrite)** — two rows, tray, mode pill, mic, call, send/stop morph, length meter, Return handling, drop/paste.
- `AttachmentTray.swift`, `AddContextSheet.swift` **(keep, fix)**, `AttachmentProcessor.swift` **(keep; ImageIO downsample, Office via extractor)**.
- `ModelPickerSheet.swift` **(keep, trim)**, `ModePicker.swift`, `SlashMenu.swift`.
- `PlanMachine.swift` — per-conversation plan state machine (§2.8) + approval matcher.
- `ShareSheet.swift` — `POST /api/share` → `https://firasai.org/?share=<id>` → system share.
- `ExportService.swift` — Markdown/text/PDF (`ImageRenderer`) of one answer.

### Features/Agent/
- `AgentScreen.swift` **(keep shell)** — chat shell with mission card; composer always visible; blocked/credits states.
- `MissionCard.swift` — header/status/elapsed, speech line, plan disclosure, event timeline, sources, files grid.
- `ArtifactViewer.swift` — `QLPreviewController` wrapper for downloaded artifacts; share via `download=1`.
- `AgentCredits.swift` — chip + sheet (`remaining/allowance`, held, resetAt).

### Features/Code/
- `CodeLauncher.swift` — hero, name/brief, attachments, recent projects (chats + cache).
- `CodeWorkspace.swift` — iPhone `TabView` (Files/Code/Preview/AI); iPad three columns.
- `CodeEditor.swift` — `UITextView` representable (smart quotes off, mono, gutter, `HighlightLite`), debounced commit.
- `CodePreview.swift` — `WKWebView` with `WKURLSchemeHandler` (`firas-proj://`), non-persistent store, nav policy, console hook.
- `CodeConsole.swift`, `CodeFileList.swift`, `CodeAIBar.swift` (in-tab edits via `/api/chat` stream, diff review), `CodeDiffSheet.swift`, `CodeExport.swift` (ZIP via ZIPFoundation + share link).
- `CodeProjectCache.swift` — offline cache keyed by server chat id (guest: local only).

### Features/Brain/
- `BrainScreen.swift` **(rewrite)** — library rail (sheet on iPhone, column on iPad), ask thread, composer with scope/summarize/compare chips.
- `BrainLibrary.swift`, `BrainThread.swift`, `BrainAnswerView.swift` (`[Sn]` chips + sources fence), `PassageReader.swift` **(keep)**.
- `BrainImportFlow.swift` — phases reading/ocr/uploading with progress + Stop; `BackgroundHold` around upload.
- `BrainDocumentExtractor.swift` **(keep, fix OCR trigger/cap/stride/concurrency)**, `OfficeDocumentExtractor.swift` **(keep, selective extraction)**.
- `BrainAsker.swift` — routing (whole/harvest/compare/quiz/overview/reason/extract), bilingual retry, citation cleanup.

### Features/Media/
- `StudioScreen.swift` — fifth product: `TabView` library/create (iPad: grid + inspector).
- `StudioCreateForm.swift`, `StudioLibraryGrid.swift`, `MediaViewer.swift` (full-screen image/video/music with scrubber), `MediaPromptPipeline.swift` (English rewrite, shape inference, music tags/lyrics via `/api/chat nomem`).

### Features/Call/
- `CallScreen.swift` **(keep skeleton)** — orb, status, captions, mute/end/speaker, Retry, guest-cap copy, iPad sizing.
- `CallOrb.swift` — `Canvas`/`TimelineView` at 30 fps only when `motionOn`; no glass inside the animated layer.

### Features/Voice/
- `DictationOverlay.swift` — replaces composer row 2; waveform, timer, dialect chip, cancel/done.
- `DialectPicker.swift` — 14 dialects.

### Features/Auth/
- `LandingView.swift`, `ConsentView.swift`, `AuthView.swift` **(keep shell)**, `VerifyEmailView.swift` (3 s poll, resend 30 s), `ForgotPasswordView.swift`.

### Features/Settings/
- `SettingsView.swift` **(rewrite container)** — iPhone `NavigationStack` list, iPad split; five sections.
- `AccountSettings.swift` **(keep, fix)**, `AppearanceSettings.swift`, `ChatSettings.swift`, `VoiceSettings.swift`, `DataSettings.swift` **(keep, fix)**, `NotificationSettings.swift`, `AnnouncementsSheet.swift`, `MemorySettings.swift`, `ChatBackupDocument.swift` **(keep, drop `@concurrent`)**.

### Resources/
- `Info.plist` — add `UIBackgroundModes: [audio, fetch]`, `BGTaskSchedulerPermittedIdentifiers: [$(PRODUCT_BUNDLE_IDENTIFIER).jobs]`, `NSSpeechRecognitionUsageDescription`, `UIApplicationSceneManifest` (multi-scene), launch colour `#262624`.
- `FirasComplete.wav` **(keep)**, `done.caf`, `send.caf` (optional).
- Remove all `.xcstrings` and `.lproj` string tables (§1.6). Keep `InfoPlist.strings` for usage descriptions.

File count ≈ 135; ~20 engineers can own 6–7 files each with no shared file.

### 1.6 Localization decision: Swift string tables, not String catalogs

`enum L` with `LString(ar:en:)` values resolved through `PreferencesStore.language`. Reasons, all
compile-safety: (a) `.xcstrings` is JSON compiled by a build phase — one stray comma is a 15-minute red
build with a cryptic error; (b) the in-app language switch must not depend on whether
`Text(LocalizedStringResource)` honours `.environment(\.locale)` (audit shell F11: undocumented);
(c) verbatim web Arabic is pasted as Swift literals and greppable; (d) plurals are a `func` with the
six Arabic forms, not a stringsdict. Cost: no Xcode localisation tooling — acceptable for two languages
owned by one team. Every string used by notifications and errors also lives here, so copy is identical
in-app and in banners.

---

## 2. Foundation design

### 2.1 APIClient

- One `actor APIClient` over three `URLSession`s (interactive/poll, upload, download) all pointing at
  `HTTPCookieStorage.shared` (`httpCookieAcceptPolicy = .always`, `httpShouldSetCookies = true`).
  Cookies are the only credential; `Max-Age` is honoured by the jar; never read, copy, trim or
  re-encode cookie values; never store them in Keychain. Every API `GET` uses
  `.reloadIgnoringLocalCacheData`.
- `waitsForConnectivity = false` everywhere; offline is detected by `NetworkMonitor`, not by a 45 s stall.
- Budgets: `RequestBudget` (§1) sets `timeoutInterval`; downloads use `URLSession.download(for:)` to a
  temp file, then the caller moves it (never `Data` for video/music; images may use `data`).
- Error surface: non-2xx → `APIError.http(status, ServerError?, rawText)`; JSON body decoded with
  `LenientDecoder` into `ServerError`; plain-text bodies (`auth required`, `not found`, `rate limited`)
  keep `rawText`. 401 additionally publishes `client.unauthorized` (an `AsyncStream<Void>`) that
  `SessionStore` consumes; guests ignore it.
- `stream(_ request) -> AsyncThrowingStream<SSEFrame, Error>`: `URLSession.bytes(for:)` +
  `SSEParser`; idle deadline 300 s re-armed per frame; cancellation closes the connection (that is the
  server's stop for a live stream).
- `+` in query values is percent-encoded (`percentEncodedQueryItems`); server decodes `+` as space.
- Decoding failure attaches `String(describing: DecodingError)` to the error and logs it in DEBUG.

### 2.2 Models and lenient decoding

- Every DTO field that the server may omit or reshape is optional with a default in `init(from:)` via
  `LenientDecoder` helpers; enums with raw values decode unknown → a documented fallback
  (`ChatJobPhase.unknown`, `SubscriptionPlan.free`, `BrainUnit.page`).
- `ChatJobPhase` terminal set: `completed, done, failed, fail, unknown` (unknown is terminal after 3
  consecutive reads on chat kinds, immediately for codebuild).
- Job record timestamps are ms epoch (`Double`), chat timestamps ISO strings — two different decoders,
  never one.
- `PersistedChatMessage` encodes only `role, content, tier, lang, reasoning, cid, files(names), imageThumbs(≤6), mode, askAnswered, retryOf, retried, mergedFrom, alts, altAt`.
- `OutgoingMessage` encodes only `role, content, images` (raw base64, no prefix).

### 2.3 SessionStore

```
phase: .booting → (.member(User) | .guest(User) | .signedOut | .unreachable(lastKnown: Phase?))
```
- `restore()`: `GET /api/auth/me` with `RequestBudget.interactive`; 200 → member; 401 → if the
  local "guestActive" flag is set `POST /api/guest` → guest, else `.signedOut`; transport error / 5xx
  → `.unreachable(lastKnown)`; the shell renders the last known product read-only (local cache) with
  a banner + Retry; `NetworkMonitor.isOnline` flipping true re-runs `restore()`.
- `handleUnauthorized()`: only when `.member`; sets `sessionExpiredNotice`, cancels watchers owned by
  that user (`JobManager.suspend(owner:)`), clears member caches, tries `POST /api/guest` (guest
  chats stay local), shows Auth.
- `applicationDidBecomeActive()`: revalidate `/me` if last check > 10 min; guests skip.
- Login/signup/reset each have their own `isWorking` flag; a stuck `restore()` never blocks `login()`.
- After sign-in from guest: `GuestMigration.run()` then `DELETE /api/guest` (fire-and-forget).
- Verification: 3 s poll of `/api/auth/verify-status` while the screen is visible; stops on
  `verified/gone/expired` and when backgrounded.

### 2.4 JobManager

One manager, one pointer table, one watcher per pointer. Stores never poll on their own.

```
JobPointer { id (jobId), kind, ownerID, cid, conversationID (local), serverChatID?, title,
             startedAt, deadline, lastPhase, lastText.count, cancelRequested, notified, mediaKind?, mediaKey?, projectID? }
```
Kinds and their drivers:

| kind | status endpoint | terminal | deadline | cadence fg / bg | cancel | notes |
|---|---|---|---|---|---|---|
| chat, longdoc | `GET /api/chat/job?id=` | completed/failed; unknown×3 | 30 min (longdoc 6 h) | 0.5 s→1.2 s / 5 s | `POST /api/chat/cancel` (409 for queued chat = stop locally) | text/reasoning grow; 401 → suspend+session; 403 → forget |
| longfile | same + `GET /api/chat/job/file` | same; `status 499` = cancelled | 6 h | 2 s / 10 s | cancel tombstones | `progress` object drives the file card |
| agentrun | SSE `/api/agent/job-stream` → fallback `GET /api/agent/job` | `done/fail`, `job:null`×2, 403/404 | 3 h | SSE / 5 s poll | none (server has no stop) | credits ride on snapshots |
| codebuild | `GET /api/chat/job?id=` | completed/failed/unknown(immediate) | 2 h | 4 s / 10 s | none | `text` empty until done; land fence before forget (15 retries) |
| brainask | `GET /api/chat/job?id=` | completed/failed | 30 min | 3 s / 10 s | none | queued+error = retry pending, not final |
| image | `GET /api/image/job?id=` | done/fail | 20 min | 2 s→5 s / 10 s | none | `running` forever for unknown ids → deadline is the only exit |
| video | `GET /api/video/job?id=` | done/fail | 20 min | 2.5 s→6 s / 15 s | none | same |
| music | `GET /api/music/job?id=` | done/fail | 10 min | 2 s→6 s / 15 s | none | 404 on file after done = failure |

Watcher rules (all kinds):
1. Pause while `!isOnline`; resume immediately on online or on `scenePhase == .active` (one
   authoritative poll at once).
2. Transport errors → `Backoff(1.2 s … 30 s)`; 20 consecutive non-OK → keep the pointer, mark
   `.reconnecting`, keep trying at 30 s until deadline.
3. 401 → `SessionStore.handleUnauthorized()`, watcher suspended (pointer kept; resumes after re-auth
   of the same owner). 403 → forget. 404 with body → terminal failed.
4. Deadline reached → terminal `.expired` (kept in UI as "reconnect" with Retry-new-cid).
5. Terminal → `JobEvent.terminal(pointer, result)` to the owning store **on the main actor first**,
   then `CompletionCue.fire()` (foreground) or `NotificationCoordinator.postJobTerminal` (not active),
   then `forget`. Forget happens only after the store acknowledges it has landed the result
   (`JobObserver.didLand`) — land-before-forget.
6. Foreground/background: `didEnterBackground` → each active watcher gets a `BackgroundHold`
   (~30 s of extra polling; enough for most chat/image jobs) and `BackgroundRefresh.schedule(after: 60 s)`
   is submitted whenever the table is non-empty. The BG handler runs `refreshOnce`: one status read per
   pointer, posts notifications for terminals, resubmits if anything is still live, always completes
   within 20 s (task-group with deadline).
7. Idempotency: `start` is keyed by `cid`; a replayed start answering `completed` lands the result
   directly; `failed + retryRequiresNewCid` mints a new cid on user retry only.
8. Ownership: every pointer carries `ownerID`; on identity change watchers for other owners are
   suspended (never cancelled server-side); the table is filtered per owner.

Local notifications without APNs: posted only from (5)/(6); copy from `L.notify` (server-verbatim
table); `userInfo` = `{firas: {type, product, jobId, phase, chatId?, mediaKind?}}`;
`thread-id = firas-<product>-<chatId|jobId>`; dedupe by job id in `jobs.json` (`notified`). Permission
is requested after the first accepted job, with a one-line explainer sheet.

Completion haptic + sound: `CompletionCue.fire(kind:)` = `generator.prepare()` when the watcher sees
the first terminal read, then `.success` (long jobs) or soft impact 0.5 (chat) **on the frame before**
the store applies the terminal state; optional `done.caf` via `.ambient` on the same frame; never
while `CallEngine.isActive`; never in background; never twice per job.

### 2.5 Design system

- Tokens: `FirasPalette` (16 base + derived glass/user/tier tokens from `design-brief §6`); the six
  themes are the exact `styles.css` hexes already in `FirasTheme.swift`.
- Glass: exactly three levels via `FirasGlass` — `.chrome` (system bars, untouched; never
  `.toolbarBackground(.hidden)`), `.floating` (composer, drawer, chips, call controls:
  iOS 26 `Glass.clear.tint(glassTint).interactive()` + wash overlay + 0.5 pt stroke; iOS 18
  `.ultraThinMaterial.opacity(0.62)` over `surface.opacity(0.28)` + 1 pt stroke), `.sheet`
  (`Glass.regular.tint`; iOS 18 material). Content cards, bubbles, code blocks are **opaque**
  `SurfaceCard`. Never nest two `.floating` surfaces — chips live inside the composer's
  `GlassEffectContainer`. `Glass.clear` is wrapped in one `#available` in one file; if CI rejects the
  symbol, that file alone changes to `.regular` untinted.
- Typography: system font only; text styles; Arabic never tracked; assistant prose 17 pt with
  `lineSpacing` 9 (RTL) / 6 (LTR); mono for code/timers; Arabic-Indic digits for counts via
  `ar-IQ-u-nu-arab`, Latin digits + LTR for timers/ids.
- Spacing: 16 pt gutters, 32 pt between turns (40 iPad), reading column 760/980.
- Motion: `FirasMotion.standard = .spring(response: 0.35, dampingFraction: 0.85)`; reduced motion →
  120 ms fades; busy indicators become opacity pulses, never frozen.

### 2.6 Navigation

- iPhone: `AppShell` = `ZStack { detail; scrim; Drawer }`. Detail = the selected product's screen,
  each in its own `NavigationStack`. Drawer opens by toolbar button or 20 pt edge drag (`@GestureState`,
  interruptible, momentum projection). Sheets: settings, model picker, add-context, announcements,
  share; `fullScreenCover`: call, auth/landing. Products: `ai, agent, code, brain, studio`.
- iPad: `NavigationSplitView(columnVisibility:)` with `Sidebar` (270–360 pt) + detail; `.toolbar(removing: .sidebarToggle)` **not** used — we keep the system toggle and drop the custom pair.
  Keyboard shortcuts per `design-brief §8`; `.dropDestination(for: Data.self)` on chat.
- Root is fixed LTR (`.environment(\.layoutDirection, .leftToRight)` once in `AppShell`); islands
  (message bodies, composer field, titles, cards) use `BidiText.firstStrongDirection`. No per-screen
  re-application.
- `Router` holds `selectedProduct`, `selectedConversationID`, `pendingRoute`; notification taps and
  `onOpenURL` (`?share=`, `?verify=`, `?reset=&uid=` — only reachable if the user pastes/opens via the
  custom scheme; universal links are out of scope) write `pendingRoute`, `AppShell` consumes it once.

### 2.7 Prompt building, serialization, windowing

- `PromptBuilder.system(for turn:)` returns **one** system string:
  `PromptCatalog.systemPrompt(tier:product:mode:lang:think:requestKind:)` + (plan text per §2.8) +
  (`fileGuidance(fmt)` when `RequestKind` is a file and not a plan clarify/plan turn) + (search-empty note
  when the toggle was on and results were empty). Never the identity block (server prepends it).
- Search context (when run) is inserted as a `user` message right after the system message; explicit
  search downgrades any tier but `max` to `pro` for that request.
- `HistoryWindow.build(conversation, budget: 400_000)`: walk from the end, include turns until the
  char budget is hit; always the last user turn; `images` only on the last user turn (or re-attached
  previous images when the follow-up matches the web's image-reference regex); `fileText` merged into
  content at send time only.
- Job body vs stream: `OutgoingMessage` array; if the encoded body > 550 k chars or the last user
  turn has images → `POST /api/chat` stream directly; 413/404/501 on job start → stream fallback.
- Persist: user turn PUT (whitelist) **before** job start; on completion, member: `GET /api/chats/:id`,
  if the server copy already holds an assistant message with this `cid` → no PUT; else merge by cid and
  PUT. Never PUT `title` at finish. Guest: local only.
- Engine-failure sentences (`busyRe`) and empty results → `.failed`, no persist, one automatic retry
  with a new cid.
- Titles: 42-char provisional; after the first answer `POST /api/chat {nomem:true, tier:pro}` title
  prompt (verbatim) via stream, then `PUT {title}` unless renamed.

### 2.8 Plan mode state machine (`PlanMachine`, chat product only)

```
enum PlanPhase { none, awaitingAnswers(askID), awaitingApproval(planID), executing(originID), delivered(originID) }
```
- Mode is a device preference but is **snapshotted onto the conversation** when a cycle starts.
- System text per turn (concatenated into the single system message — some engines ignore a second
  system message): clarify/plan turns = `base_without_build_rules + "\n\n" + planSystem`; execute turn =
  `base_with_build_rules + planSystem + EXECUTE note`; after two ask rounds append the forced-plan
  sentence. Texts verbatim from `PromptCatalog`.
- Transitions per `web-plan-mode.md §7.2`; approval matcher §7.6 (Arabic normalised, no `\b`, English
  whole-message only, > 6 words = revision); consulted only in `awaitingApproval`.
- Execute routing resolves the deliverable from the **origin** user message (`RequestClassifier`),
  never from the approval sentence: file → file path with guidance; image → image job; code → code card.
- Assistant messages in a cycle are stamped `mode:"plan"`, else `"auto"`. Phase is derived on load
  (§7.5) so web-written chats behave. Submit/Start turns never carry a quote or attachments. Never
  evaluated for agent/code/brain conversations. Voice call pauses the cycle.

### 2.9 Markdown, code, math (decided)

- No new SPM package. Blocks are split by a hand-written scanner (`MarkdownBlocks`, ~250 lines);
  paragraphs/list items/quotes use Foundation's `AttributedString(markdown:)` (iOS 15+) with
  `.inlineOnlyPreservingWhitespace`; headings, tables, code, hr, fences are native views.
- Streaming: the settled prefix (all blocks before the last one) is parsed once and cached by block
  index; only the tail block re-parses on each 10 Hz tick. An open fence or open `$$` renders as plain
  text until closed.
- Code: `CodeBlockView` with `HighlightLite` (a tokenizer, no regex catastrophes; ≤ 8 languages);
  LTR; copy; HTML/SVG blocks get a Preview button (sandboxed `WKWebView`, non-persistent, no
  navigation).
- Math v1: `MathText` — the web's `texToUnicode` port (superscripts/subscripts/greek/fractions/roots
  as Unicode, `\frac{a}{b}` → `a⁄b`, unknown macros left as-is) rendered in an LTR mono island with a
  subtle `bgSubtle` background. Correct glyphs, not typeset layout. KaTeX-in-WKWebView is deferred
  (§7) because a web view per equation inside a `LazyVStack` is the freeze risk this candidate
  exists to avoid.
- Links open `SFSafariViewController`; `firas-*` fences dispatch to `Rendering/Cards/*`.

### 2.10 Call engine (never freezes, never crashes)

`CallEngine` (`@MainActor`) phases: `idle → preparing → minting → connecting → connected(listening|thinking|speaking) → ending → ended(reason) | failed(reason)`.

Start sequence, every await bounded by `withDeadline`:
1. `AVAudioApplication.requestRecordPermission()` (no deadline; system UI).
2. `POST /api/live/token {voice}` (`interactive` budget). Decode `LiveToken`.
3. `CallAudioGraph.prepare(sampleRate: provider == .openai ? 24_000 : 16_000)` **off-main**
   (`Task.detached`): `AudioSessionArbiter.acquire(.call)` → `setCategory(.playAndRecord, .voiceChat, [.allowBluetoothHFP] (+ .defaultToSpeaker when speaker))` → `setActive(true)` →
   `inputNode.setVoiceProcessingEnabled(true)` **before** reading formats → `AVAudioConverter`
   (hardware → Int16 mono target rate) → tap 100 ms → `AsyncStream<Data>(bufferingNewest 8)` →
   player node on `standardFormat(24_000, 1)` Float32 → `engine.prepare(); engine.start()`.
4. Transport `connect(deadline: 12 s)` → must yield `.ready` (`session.created` with
   `instructions` starting "You are Firas" and `semantic_vad`; Gemini `setupComplete` within 10 s) else
   teardown and next rung.
5. Ladder: `openai` → on failure mint again `{prefer:"gemini", voice}` within 90 s → `gemini` (with
   `tools:[googleSearch]` unless the model is in the persisted no-search list; 1008/1011 with tools →
   retry without tools; early close < 8 s → one reduced-setup retry; 1008/1011 without tools → 10-min
   Gemini cooldown) → `ThreeHopCall`. Record `CallDiagnostics {engine, model, reason}`.
6. Greeting `response.create` (OpenAI) once ready; phase → connected.

Runtime:
- One consumer task sends mic frames in order (zeros while gated/muted so server VAD sees a
  continuous stream); level published ≤ 20 Hz.
- Every `player.scheduleBuffer/play` runs on the graph's serial queue **and** checks
  `engine.isRunning && !isEnding`; an ObjC exception path is therefore unreachable.
- Observers: `AVAudioEngineConfigurationChange` → rebuild player connection + tap, restart;
  `routeChange` → re-query formats, hide speaker toggle on BT/headphones;
  `interruption .began` → pause + gate; `.ended + shouldResume` → `setActive(true)`, `engine.start()`.
- Two clocks: hard `max(60 s, maxMs) − 1.5 s`; idle 45 s from `lastVoiceAt` (mic RMS > 0.02,
  `speech_started/stopped`, `response.done`, every output delta). Guest cap ends with the verbatim
  guest sentence.
- OpenAI: mic gate closed from `response.created` until 280 ms after `response.done`, 20 s safety
  reopen; barge-in (setting, default off) = stop player, drop queue, `conversation.item.truncate`.
  Gemini: `EchoGuard` even with VPIO; `interrupted` → flush.
- `sendPing` every 20 s on OpenAI while gated.
- Background: `UIBackgroundModes: audio`; nothing ends the call on `didEnterBackground`; a call that
  ends in the background posts a local notification with the reason.
- Teardown (`end()` idempotent, `isEnding` first): cancel timers → stop player, drop queue → remove
  tap, finish stream → `engine.stop()` → close socket, invalidate session → `AudioSessionArbiter.release`
  (`setActive(false, .notifyOthersOnDeactivation)` off-main) → null handles → publish `.ended`.
- Call forces `mode = auto`, `think = false`, tier ≤ `pro` on the three-hop rung; restored at end.

### 2.11 Dictation and TTS

- `DictationRecorder`: `AudioSessionArbiter.acquire(.record)`, `AVAudioEngine` tap → `AVAudioConverter`
  to 16 kHz Int16 mono → WAV (RIFF header written by us); 300 s cap; ≥ 700 ms and ≥ 1 500 bytes to
  send; background → auto-finish. Level stream drives the waveform.
- `TranscribeService.transcribe(wav:, dialect:)`: `POST /api/transcribe {audio: base64 (standard
  alphabet, no line breaks), format:"wav", lang: dialect.rawValue}`; 503 / offline →
  `SFSpeechRecognizer(locale: dialect.bcp47)` on-device if available; result **appends** to the draft
  with one space, never auto-sends. `NSSpeechRecognitionUsageDescription` added.
- `ListenController`: `callSpeakable` cleaning → chunks ≤ 1 300 → `POST /api/tts {text, lang, gender:"male"}`
  → sniff `RIFF`/MP3 → `AVAudioPlayer` under `AudioSessionArbiter.acquire(.playback)`; 429 → device
  voice from the failed chunk (voice picked before speaking; `listenNoVoiceAr` when none); refused while
  a call is active; single speaker token across screens.

### 2.12 Memory with long chats

- `Conversation` in memory holds `[ChatMessage]` with `content`, `reasoning`, `imageThumbs` (≤ 6 small
  data URLs); full-resolution `images` live only in `PendingAttachments` for the turn being sent and are
  dropped after the request is built.
- `ImageCache` decodes thumbnails once, off-main, keyed by hash; rows read `UIImage` from the cache.
- Rows are `Equatable` on `(id, content.count, reasoning.count, status, altAt)`; `StreamBuffer` mutates
  the last message in place (by id) instead of replacing the array.
- Large chats (2 000 messages) render in `LazyVStack`; `MarkdownView` caches parsed blocks per message
  id in an `NSCache` (cost = char count) so scrolling back never re-parses.
- `DiskStore` writes conversation caches per chat file (not one big file); guest history file under
  Application Support with a 7-day TTL matching the guest cookie.

---

## 3. Screens — what they show, which store/endpoints back them

| Screen | Shows | Store → endpoints |
|---|---|---|
| Root / Landing / Consent | intro, landing, consent (first run) | `SessionStore` → `/api/auth/me`, `/api/guest` |
| Auth / Verify / Forgot | email+password, Google, verify polling + resend, forgot | `SessionStore` → login, signup, verify-status, resend-code, forgot, google-native |
| Chat | transcript, composer, tier pill, mode pill, search/think toggles, scroll chip, quota/offline strips | `ChatStore` + `ChatTurnPipeline` + `JobManager` → `/api/chats*`, `/api/chat/job*`, `/api/chat`, `/api/search`, `/api/share`, `/api/memory/learn` |
| Sidebar / Drawer | products (live dots), new chat, search, pinned + date groups, account pill, bell | `ChatStore` (summaries), `JobManager` (live dots), `AnnouncementStore` → `GET /api/chats`, `PUT {pinned|title}`, `DELETE`, `/api/announcements` |
| Model picker / Mode picker / Add sheet | tiers (Think hidden on mini), auto/plan, camera/photos/files, web-search/think/dialect | `PreferencesStore`, `AttachmentProcessor` |
| Plan card / Ask card | wizard, Start pill | `PlanMachine` (in `ChatStore`) |
| Message actions | copy, regenerate (alts), retry with Max, listen, share, export, continue | `ChatStore`, `ListenController`, `ShareSheet` → `/api/share`, `/api/tts` |
| Long file card | progress stages, page count, preview/export | `ChatStore` → `GET /api/chat/job/file` (manifest + parts, sha256 verified) |
| Agent | mission card, credits chip, blocked/credits states, composer | `AgentStore` + `JobManager(AgentJobDriver)` → `/api/usage/charge`, `POST /api/chat/job kind:agentrun chatId`, `/api/agent/job-stream`, `/api/agent/job`, `/api/agent/artifact`, `/api/agent/credits`, `POST /api/chats {agent:true}` |
| Code launcher / workspace | recents (codeProj chats), build progress (indeterminate + srvKeep), files/editor/preview/console/AI bar | `CodeStore` + `JobManager(CodeBuildDriver)` → `POST /api/chats {codeProj:true}`, `POST /api/chat/job kind:codebuild chatId:""`, `GET /api/chats/:id`, `PUT`, `/api/chat` stream (edits), `/api/share` |
| Brain | library rail, import phases, ask thread with `[Sn]`, passage reader, scope chips | `BrainStore` → `/api/brain/docs|doc|search|passage|whole`, `/api/chat nomem` stream, `POST /api/chat/job kind:brainask` (long asks, members) |
| Studio | library grid, create form (kind, prompt, aspect/seconds, first frame), viewer | `MediaStore` + `JobManager(MediaJobDriver)` → `/api/{image,video,music}/job`, file endpoints, `/api/image/quota`, `/api/video/quota`; creations written as fences into a conversation |
| Call | orb, status, captions, mute/end/speaker, retry | `CallEngine` → `/api/live/token`, OpenAI/Gemini sockets, (`/api/transcribe`, `/api/chat`, `/api/tts` on three-hop) |
| Dictation overlay | waveform, timer, dialect chip | `DictationRecorder`, `TranscribeService` → `/api/transcribe` |
| Settings (5) | account/plan/security/danger; themes/size/width/motion/language; default tier/mode/think/search/enter; call voice/dialect/ui sounds; backup/notifications/memory/about | `SessionStore`, `PreferencesStore`, `MemoryStore`, `NotificationCoordinator` → change-*, delete, `/api/memory`, `/api/redeem` |
| Announcements | pinned + newest, reader with video | `AnnouncementStore` → `GET /api/announcements` |

Quota/limit copy (all screens): `ServerErrorMapper` turns 429 `{quota}` into the guest/member
sentences, `scope:"network"` variant, plain 429 into the "too fast" line, 403 `signin_required` into
the sign-up sheet per feature; `agent_busy`/`credits_reserved` into blocked cards; media `rate_window`
prints `freesInMin`.

---

## 4. Frozen Swift interfaces (write these first; nobody changes a signature without the architect)

```swift
// Core
actor DiskStore {
    static let shared: DiskStore
    func read<T: Decodable & Sendable>(_ type: T.Type, at relativePath: String) async throws -> T?
    func write<T: Encodable & Sendable>(_ value: T, at relativePath: String) async throws
    func delete(at relativePath: String) async
    func fileURL(_ relativePath: String) -> URL
}
@MainActor @Observable final class NetworkMonitor { var isOnline: Bool; var updates: AsyncStream<Bool> }
struct BackgroundHold: Sendable { func end() }
enum BackgroundExecutor { @MainActor static func hold(name: String) -> BackgroundHold }
enum BackgroundRefresh { static let identifier: String; @MainActor static func register(handler: @escaping @Sendable () async -> Bool); static func schedule(after: TimeInterval) }
struct Backoff: Sendable { init(initial: Double, max: Double, factor: Double = 1.7); mutating func next() -> Double; mutating func reset() }
func withDeadline<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T   // throws DeadlineError
enum IDs { static func cid() -> String; static func clientChatID() -> String; static func sanitizedCid(_: String) -> String }
enum BidiText { static func direction(of: String) -> LayoutDirection?; static func normalizeArabic(_: String) -> String; static func arabicIndic(_: Int) -> String }

// Networking
enum RequestBudget: Sendable { case interactive, poll, upload, download, stream }
struct SSEFrame: Sendable { let event: String?; let data: String; let id: String? }
struct ServerError: Decodable, Sendable {  // every field optional
    let error: String?; let feature: String?; let guest: Bool?; let quota: QuotaInfo?; let scope: String?
    let limit: Int?; let used: Int?; let windowMin: Int?; let freesInMin: Int?
    let activeJob: AgentActiveJob?; let credits: AgentCredits?; let retryRequiresNewCid: Bool?
}
enum APIError: Error, Sendable { case http(status: Int, server: ServerError?, raw: String), transport(URLError), decoding(String), offline, cancelled, deadline }
actor APIClient {
    init(configuration: AppConfiguration)
    nonisolated let unauthorized: AsyncStream<Void>
    func json<T: Decodable & Sendable>(_ method: String, _ path: String, query: [String: String]? = nil, body: (any Encodable & Sendable)? = nil, budget: RequestBudget = .interactive, as: T.Type) async throws -> T
    func raw(_ method: String, _ path: String, query: [String: String]? = nil, body: (any Encodable & Sendable)? = nil, budget: RequestBudget = .interactive) async throws -> (Data, HTTPURLResponse)
    func stream(_ method: String, _ path: String, body: (any Encodable & Sendable)?) -> AsyncThrowingStream<SSEFrame, Error>
    func download(_ path: String, query: [String: String]? = nil, to destination: URL) async throws -> HTTPURLResponse
}

// Models (selected)
enum JobKind: String, Codable, Sendable { case chat, longdoc, longfile, agentrun, codebuild, brainask, image, video, music }
enum JobPhase: String, Codable, Sendable { case queued, processing, completed, failed, unknown, expired }
struct JobPointer: Codable, Sendable, Identifiable {
    let id: String; let kind: JobKind; let ownerID: String; let cid: String
    var conversationID: String?; var serverChatID: String?; var projectID: String?
    var title: String; let startedAt: Date; var deadline: Date
    var lastPhase: JobPhase; var cancelRequested: Bool; var notified: Bool
    var mediaKind: MediaKind?; var mediaKey: String?
}
struct ChatJobStatus: Decodable, Sendable { let phase: JobPhase; let text: String; let reasoning: String; let error: String?; let status: Int?; let surface: JSONValue?; let progress: LongFileProgress? }
struct OutgoingMessage: Encodable, Sendable { let role: String; let content: String; let images: [String]? }
struct PersistedChatMessage: Codable, Sendable { /* server whitelist only */ }
struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    let id: String; var role: Role; var content: String; var reasoning: String?; var tier: ModelTier?; var lang: String?
    var cid: String?; var mode: String?; var askAnswered: Bool?; var files: [FileChip]; var imageThumbs: [String]
    var alts: [Alt]?; var altAt: Int?; var retryOf: RetryLink?; var retried: Bool?; var mergedFrom: String?
    var status: DeliveryStatus  // client-only: .delivered, .streaming, .failed(String), .stopped, .queuedOffline
}
struct LiveToken: Decodable, Sendable { let provider: String; let token: String; let model: String; let voice: String?; let maxMs: Int; let guest: Bool; let startWithinMs: Int }

// Session
@MainActor @Observable final class SessionStore {
    enum Phase: Equatable { case booting, member(User), guest(User), signedOut, unreachable(lastKnown: User?) }
    var phase: Phase; var user: User? { get }; var identityID: String? { get }; var isMember: Bool { get }; var isGuest: Bool { get }
    var sessionExpiredNotice: Bool
    func restore() async
    func applicationDidBecomeActive() async
    func handleUnauthorized() async
    func continueAsGuest() async throws
    func login(email: String, password: String) async throws
    func signup(name: String, email: String, password: String) async throws -> PendingSignup
    func pollVerification(pid: String) async throws -> Bool
    func signInWithGoogle(anchor: ASPresentationAnchor) async throws
    func forgotPassword(email: String) async throws
    func logout() async
    var onGuestBecameMember: ((_ previousGuestID: String) async -> Void)?
}

// Jobs
protocol JobObserver: AnyObject, Sendable {
    @MainActor func job(_ pointer: JobPointer, didUpdate status: JobStatusUpdate)   // text/reasoning/progress/snapshot
    @MainActor func job(_ pointer: JobPointer, didFinish result: JobResult) async -> Bool  // return true when landed (forget allowed)
}
enum JobResult: Sendable { case completed(text: String, reasoning: String, surface: JSONValue?), failed(ServerError?, message: String), cancelled, expired, forgotten }
@MainActor @Observable final class JobManager {
    var pointers: [JobPointer] { get }
    func isLive(conversationID: String) -> Bool
    func liveCount(product: ProductKind) -> Int
    func register(_ observer: any JobObserver, for kind: JobKind)
    func start(_ pointer: JobPointer) async
    func attach(_ pointer: JobPointer)             // reattach after relaunch / notification
    func cancel(jobID: String) async
    func forget(jobID: String) async
    func resumeAll(owner: String) async
    func suspend(owner: String)
    func refreshOnce(budget seconds: Double) async -> Bool   // BG task entry
}
protocol JobKindDriver: Sendable {
    var kind: JobKind { get }
    func cadence(elapsed: TimeInterval, background: Bool) -> Double
    func deadline(from start: Date) -> Date
    func fetch(_ pointer: JobPointer, client: APIClient) async throws -> DriverRead   // .running(update) | .terminal(JobResult) | .unknown
    func cancel(_ pointer: JobPointer, client: APIClient) async throws
}

// Notifications
@MainActor @Observable final class NotificationCoordinator {
    var authorization: UNAuthorizationStatus
    func requestIfNeeded() async
    func postJobTerminal(_ pointer: JobPointer, phase: JobPhase, language: AppLanguage) async
    func postCallEnded(reason: String, language: AppLanguage) async
}
enum CompletionCue { @MainActor static func prepare(); @MainActor static func fire(jobID: String, success: Bool) }

// Voice
enum CallEvent: Sendable { case ready, speechStarted, speechStopped, responseCreated, audio(Data), transcript(String, own: Bool), responseDone, interrupted, closed(code: Int?, reason: String), error(String) }
protocol CallTransport: Sendable {
    var events: AsyncStream<CallEvent> { get }
    func connect(token: LiveToken, language: AppLanguage) async throws   // returns after .ready or throws
    func send(pcm16: Data) async
    func truncate(playedMs: Int) async
    func close() async
}
@MainActor @Observable final class CallEngine {
    enum Phase: Equatable { case idle, preparing, connecting, listening, thinking, speaking, ending, ended(String), failed(String) }
    var phase: Phase; var level: Float; var isMuted: Bool; var speakerOn: Bool; var caption: String; var diagnostics: CallDiagnostics?
    var isActive: Bool { get }
    func start(voice: CallVoice, language: AppLanguage) async
    func toggleMute(); func toggleSpeaker() async
    func end(reason: String) async
}
final class CallAudioGraph: @unchecked Sendable {   // serial queue inside
    func prepare(targetRate: Double, speaker: Bool) async throws -> AsyncStream<Data>
    func schedule(pcm16: Data) ; func flushPlayback() -> Int  // returns played ms
    func setGated(_: Bool); func setMuted(_: Bool)
    func teardown() async
}
enum AudioSessionArbiter { enum Owner { case call, record, playback, uiSound }; static func acquire(_: Owner) async throws; static func release(_: Owner) async }
@MainActor @Observable final class ListenController { var speakingMessageID: String?; func toggle(messageID: String, text: String, lang: String) async; func stop() }
final class DictationRecorder: Sendable { func start() async throws -> AsyncStream<Float>; func stop() async throws -> Data /* WAV */; func cancel() async }

// Prompting / rendering
enum PromptBuilder { static func system(turn: TurnContext, catalog: PromptCatalog.Type = PromptCatalog.self) -> String }
enum HistoryWindow { static func outgoing(_ conversation: Conversation, system: String, searchContext: String?, budget: Int = 400_000) -> [OutgoingMessage] }
enum MessageSerializer { static func persisted(_: Conversation) -> [PersistedChatMessage]; static func merge(local: [ChatMessage], server: [ChatMessage]) -> [ChatMessage] }
enum MarkdownBlocks { static func split(_ markdown: String, streaming: Bool) -> [MDBlock] }
struct MarkdownView: View { init(markdown: String, streaming: Bool, language: AppLanguage, onFence: (FirasFence) -> AnyView?) }
@MainActor @Observable final class PlanMachine { var phase: PlanPhase; func systemAddendum(for turn: TurnContext) -> String; func classifyUserSend(_ text: String) -> PlanTurnKind; func didFinalize(assistant: ChatMessage); static func derive(from messages: [ChatMessage]) -> PlanPhase }

// Localization
struct LString: Sendable { let ar: String; let en: String; func callAsFunction(_ l: AppLanguage) -> String }
enum L { enum chat {}; enum shell {}; enum auth {}; enum agent {}; enum code {}; enum brain {}; enum media {}; enum voice {}; enum settings {}; enum errors {}; enum notify {} }
```

Conventions: stores are `@MainActor @Observable final class`; services are `actor` or
`final class: Sendable` with an internal serial queue; models are `struct: Codable, Sendable`;
no `@concurrent`, no `nonisolated(unsafe)`, no global mutable `var`.

---

## 5. Implementation batches

**Batch 0 — foundation (serial, one owner each, must compile green before anything else, 1–2 CI cycles)**
`Core/*`, `Networking/APIClient|APIError|LenientJSON|SSEParser|RequestBudget`, `Models/*` (all),
`Localization/L.swift` + empty namespaces, `Session/SessionStore` (phases + restore only),
`Jobs/*` (manager + `ChatJobDriver`), `Notifications/*`, `DesignSystem/*`, `App/*`, `Prompting/*`
(builder against `PromptCatalog`), `Features/Shell/RootView|AppShell` rendering a placeholder chat.
Rule: no feature UI in this batch; the app boots, restores session, shows the drawer skeleton.

**Batch 1 — chat is the product (parallel, ~8 owners)**
`Rendering/*` (markdown/code/math/cards), `Stores/ChatStore|ChatTurnPipeline|StreamBuffer|DraftStore`,
`Features/Chat/*` (screen, transcript, rows, composer, sheets), `Endpoints/Chat|Auth`,
`Features/Auth/*`, `Features/Shell/Sidebar|Drawer`, `L+Chat|Shell|Auth|Errors|Notify`,
`Features/Settings/*` (all five), `AnnouncementStore`.

**Batch 2 — the other products and voice (parallel, ~10 owners; each depends only on Batch 0)**
`Jobs/AgentJobDriver` + `AgentStore` + `Features/Agent/*`; `CodeBuildDriver` + `CodeStore` +
`Features/Code/*`; `BrainStore` + `BrainAsker` + `Features/Brain/*`; `MediaJobDriver` + `MediaStore`
+ `Features/Media/*`; `Voice/CallEngine|CallAudioGraph|OpenAIRealtimeTransport|GeminiLiveTransport|EchoGuard`
+ `Features/Call/*`; `Voice/DictationRecorder|TranscribeService` + `Features/Voice/*`;
`Voice/ListenController`; `Features/Chat/PlanMachine` + `Cards/AskCard`; `ShareSheet|ExportService`;
`MemoryStore|GuestMigration`.

**Batch 3 — hardening and iPad (parallel)**
`ThreeHopCall`, `BrainImportFlow` background hold, `CodeAIBar/DiffSheet/Export`, `MediaPromptPipeline`,
`MediaViewer`, keyboard shortcuts + drop targets, `CallOrb` shader, long-file card, announcements
reader, `HighlightLite` languages, notification explainer sheet, accessibility announcements.

Each batch ends with one adversarial review pass against the server contracts before deploy
(the harness gates prove it compiles, not that it is right).

---

## 6. Compile-risk rules (every violation costs 15 minutes)

1. **Only APIs that exist on iOS 18 SDK or are wrapped in `if #available(iOS 26, *)`** — and the
   iOS 26 symbols are spelled in exactly one file each (`FirasGlass.swift`, `AppShell.swift` for
   `backgroundExtensionEffect`, `ChatScreen.swift` for `safeAreaBar/scrollEdgeEffectStyle`). If a
   symbol is uncertain (`Glass.clear`, `ToolbarSpacer`, `navigationSubtitle`), the fallback branch must
   be complete so deleting the iOS 26 branch is a one-line fix.
2. Isolation: stores `@MainActor`; anything touched from a `Task.detached`, an audio tap, or a
   `URLSession` delegate is an `actor` or a `Sendable` struct. Never mark an enum/struct method
   `@MainActor` "just in case". `nonisolated` on types is allowed but unnecessary — omit.
3. No `@concurrent`, no `Task { @concurrent in }`, no `sending` parameters, no typed throws
   (`throws(E)`), no `~Copyable`, no macros beyond `@Observable`, no `#Preview` blocks (they compile
   on CI and fail on missing environment).
4. SwiftUI `View` bodies: no closures capturing `inout`, no `if let` inside `ViewBuilder` with
   `where`, keep bodies < 80 lines and split into subviews (the type checker times out on CI more
   often than locally).
5. `Codable` synthesis only for flat DTOs; every lenient DTO writes `init(from:)` by hand using
   `LenientDecoder` helpers — no `@propertyWrapper` decoders.
6. Foundation `AttributedString(markdown:)` and `Regex` literals are allowed; `NSRegularExpression`
   patterns copied from the web must be tested for `\b` on Arabic (never) and `(?<…)` lookbehinds
   (allowed in `Regex`, not in JS-ported strings).
7. AVFoundation: never call `player.play()` / `scheduleBuffer` outside `CallAudioGraph`; never
   `setActive` outside `AudioSessionArbiter`; format initialisers (`AVAudioFormat(…)!`) only with the
   two known-good argument sets.
8. `Info.plist` keys are build-setting substituted (`$(PRODUCT_BUNDLE_IDENTIFIER).jobs`) — the
   sideload signer may rewrite the bundle id; `BackgroundRefresh.identifier` must be computed from
   `Bundle.main.bundleIdentifier` at runtime, never hard-coded.
9. No new SPM packages; ZIPFoundation stays pinned at 0.9.20 (`Package.resolved` untouched).
10. Every file compiles alone: no file-private extensions on types owned by another file; shared
    helpers go in `Core/` with a single owner.
11. Strings: Arabic literals in Swift source are fine; never put `\(…)` interpolation inside an Arabic
    literal that also contains `"` — use `String(format:)` with `%@`.
12. One owner per file; the frozen interfaces in §4 are appended-to, never changed, without the
    architect updating this document first.

---

## 7. Left out, and why

- **APNs / silent push / CallKit / App Groups / iCloud / Sign in with Apple / universal links** — need
  a paid team; the design replaces push with foreground watchers + background holds + BGAppRefresh +
  local notifications; deep links via the existing custom scheme only.
- **Background long-poll `URLSession` (server `wait=1`)** — the best no-APNs wake-up, but it needs a
  `server.mjs` change; listed as the first follow-up once the server can hold a status request ~25 s.
- **WebRTC for OpenAI Realtime** — WebSocket carries the same minted session with no dependency.
- **swift-markdown / SwiftMath / KaTeX WebView** — no new packages; v1 math is Unicode-approximate
  (`MathText`); a KaTeX `WKWebView` island is a Batch 4 file behind a flag once bundled assets exist.
- **Firas Code full IDE parity** (find/replace, snapshots, diff history, Python run, device presets)
  — v1 ships editor with smart-quotes off, preview with scheme handler, console, AI bar; the rest is
  Batch 3+.
- **Brain parity extras** (harvest sweep, compare, quiz routing) — v1 routes whole → search →
  grounding stream; the routing table exists in `BrainAsker` with `extract/overview/reason` only.
- **Media prompt pipelines** (English rewrite, lyric author) — Batch 3; v1 sends the typed text and
  labels the music field honestly.
- **UI sounds** default off; `send.caf`/`done.caf` optional assets.
- **Multiple windows on iPad** — plist manifest added (cheap), no per-window state work.
- **Folders/colour tags/saved shelves** in the sidebar — device-local on the web; not v1.
- **Firebase auth path and `/api/oauth/google/exchange`** — deleted; `google-native` only.
