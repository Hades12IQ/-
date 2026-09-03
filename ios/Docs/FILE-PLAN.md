# FILE-PLAN — batches, owners, deletions, CI notes

Read order for every engineer: `ARCHITECTURE.md` (whole) → `INTERFACES.md` (your types and every
type you call) → `plan/<your folder>.md` → the report headings it cites. Owner = folder (one owner
per file; the plan files name sub-owners where a folder is split). Paths are relative to
`ios/FirasAI/`.

## Batch 0 — foundation (must be green before Batch 1 starts; 9 owners; expect 2–3 CI cycles)

Deletes the Codex files listed below, then lands:

| Owner | Files |
|---|---|
| App (stub) | `App/AppConfiguration.swift`, `App/AppRoute.swift`, `App/FirasAIApp.swift` (stub), `Features/Shell/RootView.swift` (stub) |
| Core | `Core/DiskStore.swift`, `Core/NetworkMonitor.swift`, `Core/BackgroundExecutor.swift`, `Core/Deadline.swift`, `Core/IDs.swift`, `Core/BidiText.swift`, `Core/ArabicText.swift`, `Core/Log.swift` |
| Networking | `Networking/RequestBudget.swift`, `Networking/APIError.swift`, `Networking/LenientJSON.swift`, `Networking/SSEParser.swift`, `Networking/APIClient.swift`, `Networking/GoogleOAuthProvider.swift`, `Networking/Endpoints/AuthEndpoints.swift`, `Networking/Endpoints/ChatEndpoints.swift`, `Networking/Endpoints/JobEndpoints.swift`, `Networking/Endpoints/AgentEndpoints.swift`, `Networking/Endpoints/BrainEndpoints.swift`, `Networking/Endpoints/MediaEndpoints.swift`, `Networking/Endpoints/VoiceEndpoints.swift`, `Networking/Endpoints/AccountEndpoints.swift` |
| Models | `Models/CommonModels.swift`, `Models/AuthModels.swift`, `Models/ChatModels.swift`, `Models/ChatWireModels.swift`, `Models/JobModels.swift`, `Models/AgentModels.swift`, `Models/CodeModels.swift`, `Models/BrainModels.swift`, `Models/MediaModels.swift`, `Models/VoiceModels.swift`, `Models/FenceModels.swift`, `Models/AccountModels.swift`, `Models/SettingsModels.swift` |
| Localization | `Localization/LText.swift`, `Localization/Strings+Errors.swift`, `Localization/Strings+Notify.swift`, `Localization/ErrorPresenter.swift` |
| DesignSystem | `DesignSystem/FirasTheme.swift`, `DesignSystem/PreferencesStore.swift`, `DesignSystem/FirasGlass.swift`, `DesignSystem/FirasBackground.swift`, `DesignSystem/SurfaceCard.swift`, `DesignSystem/Typography.swift`, `DesignSystem/FirasMotion.swift`, `DesignSystem/Haptics.swift`, `DesignSystem/FirasSound.swift`, `DesignSystem/Components.swift`, `DesignSystem/ToastCenter.swift`, `DesignSystem/FirasActivityLabel.swift`, `DesignSystem/FirasBrandMark.swift`, `DesignSystem/MentronXEntryView.swift` |
| Session | `Stores/SessionStore.swift` |
| Jobs + Notifications | `Jobs/JobKindSpecs.swift`, `Jobs/JobPointerStore.swift`, `Jobs/JobWatcher.swift`, `Jobs/ChatJobDriver.swift`, `Jobs/AgentJobDriver.swift`, `Jobs/MediaJobDriver.swift`, `Jobs/JobManager.swift`, `Jobs/BackgroundRefresh.swift`, `Notifications/NotificationManager.swift`, `Notifications/NotificationRouter.swift`, `Notifications/CompletionCue.swift`, `Notifications/FirasAppDelegate.swift` |
| Prompting | `Prompting/PromptBuilder.swift`, `Prompting/RequestClassifier.swift`, `Prompting/SearchContext.swift`, `Prompting/MessageSerializer.swift`, `Prompting/HistoryWindow.swift`, `Prompting/EngineFailureDetector.swift`, `Prompting/AutoTitle.swift`, `Prompting/PlanCycle.swift`, `Prompting/AskSpec.swift`, `Prompting/ApprovalMatcher.swift` (+ `Prompting/PromptCatalog.swift` from the other agent) |
| Rendering | `Rendering/MarkdownBlocks.swift`, `Rendering/MarkdownInline.swift`, `Rendering/MathScanner.swift`, `Rendering/MathText.swift`, `Rendering/CodeHighlighter.swift`, `Rendering/MarkdownRenderer.swift`, `Rendering/MarkdownView.swift`, `Rendering/CodeBlockView.swift`, `Rendering/TableBlockView.swift` |

Batch 0 exit criterion: the app boots to the stub `RootView`, `SessionStore.restore()` runs, and CI
is green with every Codex feature file deleted. `AppEnvironment` does not exist yet — the stub
`FirasAIApp` constructs `PreferencesStore` and `SessionStore` inline (temporary, replaced in Batch 2).

## Batch 1 — feature stores + screens (parallel; ~14 owners; each depends only on Batch 0)

| Owner | Files |
|---|---|
| Chat store | `Stores/ChatStore.swift`, `Stores/ConversationState.swift`, `Stores/SendPipeline.swift`, `Stores/StreamBuffer.swift`, `Stores/DraftStore.swift`, `Stores/GuestChatStore.swift`, `Stores/GuestMigration.swift`, `Stores/ImageCache.swift` |
| Chat screen | `Features/Chat/ChatScreen.swift`, `Features/Chat/TranscriptView.swift`, `Features/Chat/WelcomeView.swift`, `Features/Chat/TierPill.swift`, `Features/Chat/TierPickerSheet.swift`, `Features/Chat/ModePill.swift`, `Features/Chat/UserTurnView.swift`, `Features/Chat/AssistantTurnView.swift`, `Features/Chat/ThinkingDisclosure.swift`, `Features/Chat/MessageActionsRow.swift`, `Features/Chat/MessageContextMenu.swift`, `Features/Chat/VersionPager.swift`, `Features/Chat/PlanStartPill.swift`, `Features/Chat/AskPanelView.swift`, `Localization/Strings+Chat.swift` |
| Composer | `Features/Chat/ComposerView.swift`, `Features/Chat/ComposerField.swift`, `Features/Chat/AttachmentTray.swift`, `Features/Chat/LengthMeter.swift`, `Features/Chat/SlashMenu.swift`, `Features/Chat/AddContextSheet.swift`, `Features/Chat/ChatAttachmentProcessor.swift`, `Features/Chat/DictationBar.swift` |
| Chat viewers | `Features/Chat/CodeViewerSheet.swift`, `Features/Chat/LongFileViewer.swift`, `Features/Chat/SharedChatView.swift`, `Features/Chat/ShareController.swift`, `Features/Chat/ExportController.swift`, `Rendering/QuickReplies.swift`, `Rendering/Cards/CodeCard.swift`, `Rendering/Cards/FileCard.swift`, `Rendering/Cards/LongFileCard.swift`, `Rendering/Cards/ImageCard.swift`, `Rendering/Cards/VideoCard.swift`, `Rendering/Cards/SongCard.swift`, `Rendering/Cards/AgentCard.swift`, `Rendering/Cards/SourcesCard.swift` |
| Agent | `Stores/AgentStore.swift`, `Features/Agent/AgentScreen.swift`, `Features/Agent/MissionCard.swift`, `Features/Agent/MissionTimeline.swift`, `Features/Agent/MissionFiles.swift`, `Features/Agent/ArtifactViewer.swift`, `Features/Agent/CreditsSheet.swift`, `Localization/Strings+Agent.swift` |
| Code A | `Stores/CodeStore.swift`, `Stores/CodeProjectCache.swift`, `Features/Code/CodeLauncherView.swift`, `Features/Code/CodeWorkspaceView.swift`, `Features/Code/FileNavigator.swift`, `Features/Code/CodeExport.swift`, `Localization/Strings+Code.swift` |
| Code B | `Features/Code/CodeEditorView.swift`, `Features/Code/CodeEditorTheme.swift`, `Features/Code/PreviewWebView.swift`, `Features/Code/ConsoleView.swift`, `Features/Code/CodeAIBar.swift`, `Features/Code/CodeAskAI.swift`, `Features/Code/DiffReviewSheet.swift` |
| Brain A | `Stores/BrainStore.swift`, `Stores/BrainAsker.swift`, `Features/Brain/BrainScreen.swift`, `Features/Brain/BrainThreadView.swift`, `Features/Brain/BrainAnswerView.swift`, `Features/Brain/SourceChipsRow.swift`, `Features/Brain/CitationChip.swift`, `Localization/Strings+Brain.swift` |
| Brain B | `Features/Brain/BrainLibrarySheet.swift`, `Features/Brain/PassageReaderSheet.swift`, `Features/Brain/BrainImportPipeline.swift`, `Features/Brain/BrainDocumentExtractor.swift`, `Features/Brain/OfficeDocumentExtractor.swift` |
| Media | `Stores/MediaStore.swift`, `Features/Media/MediaStudioScreen.swift`, `Features/Media/MediaLibraryGrid.swift`, `Features/Media/MediaCreateForm.swift`, `Features/Media/MediaViewer.swift`, `Features/Media/MediaPromptPipeline.swift`, `Features/Media/SongPlayer.swift`, `Features/Media/MediaAssetRepository.swift`, `Localization/Strings+Media.swift` |
| Voice A (engine) | `Features/Voice/AudioSessionArbiter.swift`, `Features/Voice/CallAudioGraph.swift`, `Features/Voice/CallEngine.swift`, `Features/Voice/ThreeHopCall.swift` |
| Voice B (transports) | `Features/Voice/CallTransport.swift`, `Features/Voice/OpenAIRealtimeTransport.swift`, `Features/Voice/GeminiLiveTransport.swift`, `Features/Voice/EchoGuard.swift` |
| Voice C (screen + speech) | `Features/Voice/CallScreen.swift`, `Features/Voice/OrbView.swift`, `Features/Voice/DictationRecorder.swift`, `Features/Voice/WAVEncoder.swift`, `Features/Voice/DictationController.swift`, `Features/Voice/DialectPickerSheet.swift`, `Features/Voice/TTSPlayer.swift`, `Localization/Strings+Voice.swift` |
| Auth | `Features/Auth/ConsentView.swift`, `Features/Auth/LandingView.swift`, `Features/Auth/AuthView.swift`, `Features/Auth/VerificationCard.swift`, `Features/Auth/ForgotPasswordSheet.swift`, `Features/Auth/SignUpPromptSheet.swift`, `Localization/Strings+Auth.swift` |
| Settings | `Stores/AnnouncementStore.swift`, `Stores/MemoryStore.swift`, `Features/Settings/SettingsView.swift`, `Features/Settings/AccountSettingsView.swift`, `Features/Settings/AppearanceSettingsView.swift`, `Features/Settings/ChatSettingsView.swift`, `Features/Settings/VoiceSettingsView.swift`, `Features/Settings/DataSettingsView.swift`, `Features/Settings/NotificationSettingsView.swift`, `Features/Settings/MemorySettingsView.swift`, `Features/Settings/AnnouncementsSheet.swift`, `Features/Settings/AnnouncementReader.swift`, `Features/Settings/ChatBackupDocument.swift`, `Localization/Strings+Settings.swift` |

Batch 1 files take `env: AppEnvironment` in their initialisers per `INTERFACES.md`; `AppEnvironment`
lands in Batch 2, so Batch 1 owners may add a **temporary** `App/AppEnvironment.swift` stub only if
the Batch 2 owner has not yet landed it — coordinate: the App owner lands `AppEnvironment.swift`
first in Batch 1's CI run with placeholder stores wired to Batch 0 types (the file is his either way).

## Batch 2 — entry, shell, wiring, plist (3 owners)

| Owner | Files |
|---|---|
| App | `App/FirasAIApp.swift` (final), `App/AppEnvironment.swift` (final wiring + observer registration), `App/AppLifecycle.swift` |
| Shell | `Features/Shell/RootView.swift` (final), `Features/Shell/AppShell.swift`, `Features/Shell/CompactDrawer.swift`, `Features/Shell/SidebarView.swift`, `Features/Shell/SidebarProductSwitcher.swift`, `Features/Shell/SidebarHistoryList.swift`, `Features/Shell/SidebarSearch.swift`, `Features/Shell/SidebarAccountPill.swift`, `Features/Shell/KeyboardCommands.swift`, `Features/Shell/ToastHostView.swift`, `Localization/Strings+Shell.swift` |
| Resources | `Resources/Info.plist`, `Resources/ar.lproj/InfoPlist.strings`, `Resources/en.lproj/InfoPlist.strings`, optional `Resources/Sounds/send.caf`, `Resources/Sounds/done.caf` |

`Info.plist` keys added in Batch 2: `UIBackgroundModes` `[audio, fetch, processing]`,
`BGTaskSchedulerPermittedIdentifiers` `[$(PRODUCT_BUNDLE_IDENTIFIER).jobs]`,
`NSSpeechRecognitionUsageDescription`, `ITSAppUsesNonExemptEncryption` = false,
`UIApplicationSceneManifest` (multi-scene), second `CFBundleURLSchemes` entry `firasai`.

## Deletions (Batch 0, before anything compiles)

`Networking/FirasAPI.swift`, `Notifications/PushRegistrationClient.swift`,
`Notifications/NotificationCoordinator.swift`, `DesignSystem/GlassSurface.swift`,
`DesignSystem/FirasCompletionCue.swift`, `DesignSystem/Activity.xcstrings`,
`Models/MediaStudioModels.swift`, `Stores/MediaStudioStore.swift`, `Stores/ChatStore.swift`*,
`Stores/AgentStore.swift`*, `Stores/CodeStore.swift`*, `Stores/BrainStore.swift`*,
`Features/Chat/ChatMessageRow.swift`, `Features/Chat/ChatComposer.swift`,
`Features/Chat/ModelSelectionSheet.swift`, `Features/Chat/LiveVoiceController.swift`,
`Features/Chat/VoiceCallView.swift`, `Features/Chat/ChatStrings.swift`, `Features/Chat/Chat.xcstrings`,
`Features/Chat/ChatScreen.swift`*, `Features/Chat/AddContextSheet.swift`*,
`Features/Chat/ChatAttachmentProcessor.swift`*, `Features/Agent/AgentScreen.swift`*,
`Features/Agent/AgentStrings.swift`, `Features/Agent/Agent.xcstrings`, `Features/Code/CodeScreen.swift`,
`Features/Code/CodeStrings.swift`, `Features/Code/Code.xcstrings`, `Features/Brain/BrainScreen.swift`*,
`Features/Brain/BrainStrings.swift`, `Features/Brain/Brain.xcstrings`,
`Features/Brain/BrainDocumentExtractor.swift`*, `Features/Brain/OfficeDocumentExtractor.swift`*,
`Features/Media/MediaStudioScreen.swift`*, `Features/Media/MediaStrings.swift`, `Features/Media/Media.xcstrings`,
`Features/Settings/SettingsView.swift`*, `Features/Settings/AccountSettingsView.swift`*,
`Features/Settings/DataSettingsView.swift`*, `Features/Settings/PreferenceSettingsViews.swift`,
`Features/Settings/ChatBackupDocument.swift`*, `Features/Shell/FirasAppShell.swift`,
`Features/Shell/ShellSidebar.swift`, `Features/Shell/ShellStrings.swift`, `Features/Shell/Shell.xcstrings`,
`Features/Auth/AuthView.swift`*, `Resources/Localizable.xcstrings`; at `ios/`: `ExportOptions.plist`,
`export-ipa.sh`, `IPA-EXPORT.md`.

\* = "keep" files whose old body references deleted types. They are removed from the tree in Batch 0
so the foundation compiles, and their Batch 1 owner recreates them at the same path from the old body
(git history) reshaped to the interfaces. Kept as-is through Batch 0 (they compile against Batch 0
types): `App/AppConfiguration.swift`, `Networking/GoogleOAuthProvider.swift`, `Models/*` (reshaped by
the Models owner), `DesignSystem/FirasTheme.swift`, `DesignSystem/FirasActivityLabel.swift`,
`DesignSystem/FirasBrandMark.swift`, `DesignSystem/MentronXEntryView.swift`,
`Notifications/FirasAppDelegate.swift`, `Stores/SessionStore.swift` (rewritten by the Session owner),
`Resources/*` except `Localizable.xcstrings`.

## File count

Batch 0: 4 + 8 + 14 + 13 + 4 + 14 + 1 + 12 + 10 (+1 PromptCatalog) + 9 = **90**.
Batch 1: 8 + 15 + 8 + 14 + 8 + 7 + 7 + 8 + 5 + 9 + 4 + 4 + 8 + 7 + 14 = **126**.
Batch 2: 3 + 11 + 3 (+2 optional sounds) = **17**.
Total Swift + resource files: **233** (Swift ≈ 215).

## CI / verification notes

- Workflow: `.github/workflows/build-ios-ipa.yml` (Xcode 26, unsigned archive). One red run is fixed
  only by the owner of the failing file; nobody "helps" by touching another owner's file.
- Before pushing a batch, each owner greps their files for the forbidden list: `try!`, `as!`,
  `!.`/`!)` force unwraps, `@concurrent`, `#Preview`, `LocalizedStringKey`, `String(localized`,
  `.xcstrings`, `glassEffect` outside the allowed files, `setActive(` outside `AudioSessionArbiter`,
  `URLSession.shared`, `sleep(`, `DispatchSemaphore`, `Task.sleep(for: .seconds(3))`.
- Symbol collisions are the top blind-compile risk with a synchronized group: every new type name is
  checked with `grep -rn "struct <Name>\|class <Name>\|enum <Name>" ios/FirasAI` before creation.
- Each batch ends with one adversarial review against `server-*.md` before deploy (the harness proves
  it compiles, not that it is right): cadence/terminal rules, whitelist fields, cookie handling,
  ladder order, Info.plist keys.
- Runtime smoke on a sideloaded device: boot offline (banner + Retry, no hang), guest chat job leaves
  the app and returns (notification + cue), call start/end twice in a row (no crash), dictation append,
  theme switch across all six, iPad split view + `⌘N`.
