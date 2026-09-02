## xcodebuild exit status: 0 (run #12, commit a77e3d8acb551ca1b8cf28b1a4989a4ed48a4617)

### Errors
```
```

### Warnings (first 80)
```
ios/FirasAI/Features/Code/CodeEditorView.swift:316:17: warning: '@preconcurrency' on conformance to 'UITextViewDelegate' has no effect
ios/FirasAI/Features/Code/PreviewWebView.swift:637:17: warning: '@preconcurrency' on conformance to 'WKNavigationDelegate' has no effect
ios/FirasAI/Features/Code/PreviewWebView.swift:637:17: warning: '@preconcurrency' on conformance to 'WKScriptMessageHandler' has no effect
ios/FirasAI/Features/Code/PreviewWebView.swift:707:13: warning: '@preconcurrency' on conformance to 'WKURLSchemeHandler' has no effect
ios/FirasAI/Features/Media/MediaCreateForm.swift:224:57: warning: main actor-isolated property 'lang' can not be referenced from a Sendable closure
ios/FirasAI/Features/Media/MediaCreateForm.swift:226:42: warning: main actor-isolated property 'photoData' can not be referenced from a Sendable closure
ios/FirasAI/Features/Media/MediaCreateForm.swift:226:61: warning: main actor-isolated property 'palette' can not be referenced from a Sendable closure
ios/FirasAI/Features/Media/MediaCreateForm.swift:226:85: warning: main actor-isolated property 'palette' can not be referenced from a Sendable closure
ios/FirasAI/Features/Media/MediaCreateForm.swift:229:72: warning: main actor-isolated property 'palette' can not be referenced from a nonisolated context
ios/FirasAI/Features/Media/MediaCreateForm.swift:279:55: warning: main actor-isolated property 'lang' can not be referenced from a Sendable closure
ios/FirasAI/Features/Media/MediaCreateForm.swift:281:42: warning: main actor-isolated property 'photoData' can not be referenced from a Sendable closure
ios/FirasAI/Features/Media/MediaCreateForm.swift:281:61: warning: main actor-isolated property 'palette' can not be referenced from a Sendable closure
ios/FirasAI/Features/Media/MediaCreateForm.swift:281:85: warning: main actor-isolated property 'palette' can not be referenced from a Sendable closure
ios/FirasAI/Features/Media/MediaCreateForm.swift:284:72: warning: main actor-isolated property 'palette' can not be referenced from a nonisolated context
ios/FirasAI/Features/Settings/AnnouncementReader.swift:53:17: warning: no 'async' operations occur within 'await' expression
ios/FirasAI/Features/Voice/AudioSessionArbiter.swift:103:28: warning: 'allowBluetooth' was deprecated in iOS 8.0: renamed to 'AVAudioSession.CategoryOptions.allowBluetoothHFP'
ios/FirasAI/Features/Voice/AudioSessionArbiter.swift:91:61: warning: 'allowBluetooth' was deprecated in iOS 8.0: renamed to 'AVAudioSession.CategoryOptions.allowBluetoothHFP'
ios/FirasAI/Features/Voice/CallAudioGraph.swift:1:1: warning: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'AVFAudio'
ios/FirasAI/Features/Voice/CallAudioGraph.swift:121:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/CallAudioGraph.swift:123:18: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/CallAudioGraph.swift:133:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/CallAudioGraph.swift:173:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/CallAudioGraph.swift:175:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/CallAudioGraph.swift:610:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/CallAudioGraph.swift:613:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/CallAudioGraph.swift:690:20: warning: capture of 'input' with non-Sendable type 'AVAudioPCMBuffer' in a '@Sendable' closure
ios/FirasAI/Features/Voice/GeminiLiveTransport.swift:115:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/GeminiLiveTransport.swift:117:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/GeminiLiveTransport.swift:137:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/GeminiLiveTransport.swift:139:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/GeminiLiveTransport.swift:82:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/GeminiLiveTransport.swift:84:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:101:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:103:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:111:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:114:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:130:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:133:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:146:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:148:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:74:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:76:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
ios/FirasAI/Stores/CodeStore+Project.swift:133:47: warning: main actor-isolated static property 'nameCharacterCap' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
```

### Log tail (last 120 lines)
```
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:111:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
        lock.lock()
             ^
Foundation.NSLock.lock:2:11: note: 'lock()' declared here
open func lock()}
          ^
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:114:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
        lock.unlock()
             ^
Foundation.NSLock.unlock:2:11: note: 'unlock()' declared here
open func unlock()}
          ^
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:130:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
        lock.lock()
             ^
Foundation.NSLock.lock:2:11: note: 'lock()' declared here
open func lock()}
          ^
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:133:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
        lock.unlock()
             ^
Foundation.NSLock.unlock:2:11: note: 'unlock()' declared here
open func unlock()}
          ^
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:146:14: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
        lock.lock()
             ^
Foundation.NSLock.lock:2:11: note: 'lock()' declared here
open func lock()}
          ^
ios/FirasAI/Features/Voice/OpenAIRealtimeTransport.swift:148:14: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
        lock.unlock()
             ^
Foundation.NSLock.unlock:2:11: note: 'unlock()' declared here
open func unlock()}
          ^
ios/FirasAI/Stores/CodeStore+Project.swift:133:47: warning: main actor-isolated static property 'nameCharacterCap' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
        let name = String(project.name.prefix(nameCharacterCap))
                                              ^
ios/FirasAI/Stores/CodeStore.swift:95:16: note: static property declared here
    static let nameCharacterCap = 80
               ^

LinkAssetCatalog ios/FirasAI/Preview\ Content/Preview\ Assets.xcassets /Users/runner/work/-/-/ios/FirasAI/Resources/Assets.xcassets (in target 'FirasAI' from project 'FirasAI')
    cd ios
    builtin-linkAssetCatalog --thinned FirasAI.build/Release-iphoneos/FirasAI.build/assetcatalog_output/thinned --thinned-dependencies /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/assetcatalog_dependencies_thinned --thinned-info-plist-content /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/assetcatalog_generated_info.plist_thinned --unthinned /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/assetcatalog_output/unthinned --unthinned-dependencies /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/assetcatalog_dependencies_unthinned --unthinned-info-plist-content /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/assetcatalog_generated_info.plist_unthinned --output /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app --plist-output /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/assetcatalog_generated_info.plist
note: Emplaced Release-iphoneos/FirasAI.app/Assets.car (in target 'FirasAI' from project 'FirasAI')
note: Emplaced Release-iphoneos/FirasAI.app/AppIcon60x60@2x.png (in target 'FirasAI' from project 'FirasAI')
note: Emplaced Release-iphoneos/FirasAI.app/AppIcon76x76@2x~ipad.png (in target 'FirasAI' from project 'FirasAI')

ProcessInfoPlistFile Release-iphoneos/FirasAI.app/Info.plist /Users/runner/work/-/-/ios/FirasAI/Resources/Info.plist (in target 'FirasAI' from project 'FirasAI')
    cd ios
    builtin-infoPlistUtility ios/FirasAI/Resources/Info.plist -producttype com.apple.product-type.application -genpkginfo /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app/PkgInfo -expandbuildsettings -format binary -platform iphoneos -additionalcontentfile /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/assetcatalog_generated_info.plist -scanforprivacyfile /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app/ZIPFoundation_ZIPFoundation.bundle -requiredArchitecture arm64 -o /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app/Info.plist

SwiftDriverJobDiscovery normal arm64 Compiling AppConfiguration.swift, AppEnvironment.swift, AppLifecycle.swift, AppRoute.swift, FirasAIApp.swift, ArabicText.swift, BackgroundExecutor.swift, BidiText.swift, Deadline.swift, DiskStore.swift, IDs.swift, Log.swift, NetworkMonitor.swift, Components.swift, FirasActivityLabel.swift, FirasBackground.swift, FirasBrandMark.swift, FirasGlass.swift, FirasMotion.swift, FirasSound.swift, FirasTheme.swift, Haptics.swift, MentronXEntryView.swift, PreferencesStore.swift, SurfaceCard.swift, ToastCenter.swift, Typography.swift, AgentScreen.swift, AgentScreen+Composer.swift, AgentScreen+Rows.swift, ArtifactViewer.swift, CreditsSheet.swift, MissionCard.swift, MissionCard+Parts.swift, MissionFiles.swift, MissionTimeline.swift, AuthView.swift, AuthView+Fields.swift, ConsentView.swift, ForgotPasswordSheet.swift, LandingView.swift, SignUpPromptSheet.swift, VerificationCard.swift, BrainAnswerView.swift, BrainDocumentExtractor.swift, BrainImportPipeline.swift, BrainLibrarySheet.swift, BrainScreen.swift, BrainThreadView.swift, CitationChip.swift, OfficeDocumentExtractor.swift, OfficeDocumentExtractor+Sheets.swift, OfficeDocumentExtractor+XML.swift, PassageReaderSheet.swift, SourceChipsRow.swift, AddContextSheet.swift, AskPanelView.swift, AssistantTurnView.swift, AssistantTurnView+Fences.swift, AttachmentTray.swift, ChatAttachmentProcessor.swift, ChatScreen.swift, CodeViewerSheet.swift, ComposerField.swift, ComposerView.swift, ComposerView+Attachments.swift, ComposerView+Controls.swift, ComposerView+Strings.swift, DictationBar.swift, ExportController.swift, LengthMeter.swift, LongFileViewer.swift, MessageActionsRow.swift, MessageActionsRow+Actions.swift, MessageContextMenu.swift, ModePill.swift, PlanStartPill.swift, ShareController.swift, SharedChatView.swift, SlashMenu.swift, ThinkingDisclosure.swift, TierPickerSheet.swift, TierPill.swift, TranscriptView.swift, UserTurnView.swift, VersionPager.swift, WelcomeView.swift, CodeAIBar.swift, CodeAskAI.swift, CodeEditorTheme.swift, CodeEditorView.swift, CodeExport.swift, CodeLauncherView.swift, CodeUIStrings.swift, CodeWorkspacePanes.swift, CodeWorkspaceView.swift, ConsoleView.swift, DiffReviewSheet.swift, FileNavigator.swift, PreviewWebView.swift, PreviewWebView+Assembler.swift, MediaAssetRepository.swift, MediaCreateForm.swift, MediaCreateForm+Quota.swift, MediaLibraryGrid.swift, MediaPromptPipeline.swift, MediaPromptPipeline+Lyrics.swift, MediaStudioScreen.swift, MediaViewer.swift, SongPlayer.swift, AccountSettingsView.swift, AccountSettingsView+Actions.swift, AnnouncementReader.swift, AnnouncementsSheet.swift, AppearanceSettingsView.swift, ChatBackupDocument.swift, ChatSettingsView.swift, DataSettingsView.swift, DataSettingsView+Backup.swift, MemorySettingsView.swift, NotificationSettingsView.swift, SettingsView.swift, SettingsView+Components.swift, SettingsView+Controls.swift, VoiceSettingsView.swift, AppShell.swift, CompactDrawer.swift, KeyboardCommands.swift, RootView.swift, SidebarAccountPill.swift, SidebarHistoryList.swift, SidebarProductSwitcher.swift, SidebarSearch.swift, SidebarView.swift, ToastHostView.swift, AudioSessionArbiter.swift, CallAudioGraph.swift, CallEngine.swift, CallEngine+Support.swift, CallEngine+ThreeHop.swift, CallScreen.swift, CallTransport.swift, DialectPickerSheet.swift, DictationController.swift, DictationRecorder.swift, EchoGuard.swift, GeminiLiveTransport.swift, OpenAIRealtimeTransport.swift, OrbView.swift, ThreeHopCall.swift, TTSPlayer.swift, TTSPlayer+Speakable.swift, WAVEncoder.swift, AgentJobDriver.swift, BackgroundRefresh.swift, ChatJobDriver.swift, JobKindSpecs.swift, JobManager.swift, JobPointerStore.swift, JobWatcher.swift, MediaJobDriver.swift, ErrorPresenter.swift, LText.swift, Strings+Agent.swift, Strings+Auth.swift, Strings+Brain.swift, Strings+Chat.swift, Strings+Code.swift, Strings+Errors.swift, Strings+Media.swift, Strings+Notify.swift, Strings+Settings.swift, Strings+Shell.swift, Strings+Voice.swift, AccountModels.swift, AgentJob+Fence.swift, AgentModels.swift, AuthModels.swift, BrainModels.swift, BrainSource+Ask.swift, ChatModels.swift, ChatWireModels.swift, CodeModels.swift, CommonModels.swift, FenceModels.swift, JobModels.swift, MediaModels.swift, SettingsModels.swift, VoiceModels.swift, AccountEndpoints.swift, AgentEndpoints.swift, AuthEndpoints.swift, BrainEndpoints.swift, ChatEndpoints.swift, JobEndpoints.swift, MediaEndpoints.swift, VoiceEndpoints.swift, APIClient.swift, APIError.swift, GoogleOAuthProvider.swift, LenientJSON.swift, RequestBudget.swift, SSEParser.swift, CompletionCue.swift, FirasAppDelegate.swift, NotificationManager.swift, NotificationRouter.swift, ApprovalMatcher.swift, AskSpec.swift, AutoTitle.swift, EngineFailureDetector.swift, HistoryWindow.swift, MessageSerializer.swift, PlanCycle.swift, PromptBuilder.swift, PromptCatalog.swift, RequestClassifier.swift, RequestClassifier+Patterns.swift, SearchContext.swift, AgentCard.swift, CodeCard.swift, FileCard.swift, ImageCard.swift, LongFileCard.swift, SongCard.swift, SourcesCard.swift, VideoCard.swift, CodeBlockView.swift, CodeHighlighter.swift, MarkdownBlocks.swift, MarkdownBlocks+Lines.swift, MarkdownInline.swift, MarkdownRenderer.swift, MarkdownView.swift, MathScanner.swift, MathText.swift, QuickReplies.swift, TableBlockView.swift, AgentStore.swift, AgentStore+Attachments.swift, AgentStore+Mission.swift, AnnouncementStore.swift, BrainAsker.swift, BrainAsker+Citations.swift, BrainAsker+Grounding.swift, BrainStore.swift, BrainStore+Job.swift, BrainStore+Selection.swift, ChatStore.swift, ChatStore+Copy.swift, ChatStore+Persistence.swift, CodeProjectCache.swift, CodeStore.swift, CodeStore+Project.swift, ConversationState.swift, DraftStore.swift, GuestChatStore.swift, GuestMigration.swift, ImageCache.swift, MediaStore.swift, MediaStore+Creating.swift, MediaStore+Landing.swift, MemoryStore.swift, SendPipeline.swift, SendPipeline+Landing.swift, SendPipeline+Turn.swift, SessionStore.swift, SessionStore+Account.swift, StreamBuffer.swift, GeneratedAssetSymbols.swift (in target 'FirasAI' from project 'FirasAI')

SwiftDriver\ Compilation\ Requirements FirasAI normal arm64 com.apple.xcode.tools.swift.compiler (in target 'FirasAI' from project 'FirasAI')
    cd ios
    builtin-Swift-Compilation-Requirements -- /Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -module-name FirasAI -O -whole-module-optimization @FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.SwiftFileList -enable-bare-slash-regex -enable-upcoming-feature IsolatedDefaultValues -enable-experimental-feature DebugDescriptionMacro -sdk /Applications/Xcode_26.6.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk -target arm64-apple-ios18.0 -g -module-cache-path /Users/runner/Library/Developer/Xcode/DerivedData/ModuleCache.noindex -Xfrontend -serialize-debugging-options -swift-version 5 -I /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos -F /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/PackageFrameworks -F /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos -emit-localized-strings -emit-localized-strings-path /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64 -c -num-threads 3 -Xcc -ivfsstatcache -Xcc /Users/runner/Library/Developer/Xcode/DerivedData/SDKStatCaches.noindex/iphoneos26.5-23F81a-688ef53f1462e2c8f657fdc38a81448fee66e23052a0157c865c76b268046726.sdkstatcache -output-file-map /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI-OutputFileMap.json -use-frontend-parseable-output -save-temps -no-color-diagnostics -explicit-module-build -module-cache-path /Users/runner/work/_temp/FirasAI-Intermediates/SwiftExplicitPrecompiledModules -clang-scanner-module-cache-path /Users/runner/Library/Developer/Xcode/DerivedData/ModuleCache.noindex -sdk-module-cache-path /Users/runner/Library/Developer/Xcode/DerivedData/ModuleCache.noindex -serialize-diagnostics -emit-dependencies -emit-module -emit-module-path /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.swiftmodule -validate-clang-modules-once -clang-build-session-file /Users/runner/Library/Developer/Xcode/DerivedData/ModuleCache.noindex/Session.modulevalidation -Xcc -I/Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/swift-overrides.hmap -emit-const-values -Xfrontend -const-gather-protocols-file -Xfrontend /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI_const_extract_protocols.json -Xcc -iquote -Xcc /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/FirasAI-generated-files.hmap -Xcc -I/Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/FirasAI-own-target-headers.hmap -Xcc -I/Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/FirasAI-all-non-framework-target-headers.hmap -Xcc -ivfsoverlay -Xcc /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI-fc84bd83fe7ce609ee81d14ecf17a26c-VFS-iphoneos/all-product-headers.yaml -Xcc -iquote -Xcc /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/FirasAI-project-headers.hmap -Xcc -I/Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/include -Xcc -I/Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/DerivedSources-normal/arm64 -Xcc -I/Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/DerivedSources/arm64 -Xcc -I/Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/DerivedSources -emit-objc-header -emit-objc-header-path /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI-Swift.h -working-directory /Users/runner/work/-/-/ios -no-emit-module-separately-wmo

SwiftMergeGeneratedHeaders FirasAI.build/Release-iphoneos/FirasAI.build/DerivedSources/FirasAI-Swift.h /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI-Swift.h (in target 'FirasAI' from project 'FirasAI')
    cd ios
    builtin-swiftHeaderTool -arch arm64 FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI-Swift.h -o /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/DerivedSources/FirasAI-Swift.h

Copy Release-iphoneos/FirasAI.swiftmodule/arm64-apple-ios.swiftmodule /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.swiftmodule (in target 'FirasAI' from project 'FirasAI')
    cd ios
    builtin-copy -exclude .DS_Store -exclude CVS -exclude .svn -exclude .git -exclude .hg -resolve-src-symlinks -rename FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.swiftmodule /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.swiftmodule/arm64-apple-ios.swiftmodule

Copy Release-iphoneos/FirasAI.swiftmodule/arm64-apple-ios.swiftdoc /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.swiftdoc (in target 'FirasAI' from project 'FirasAI')
    cd ios
    builtin-copy -exclude .DS_Store -exclude CVS -exclude .svn -exclude .git -exclude .hg -resolve-src-symlinks -rename FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.swiftdoc /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.swiftmodule/arm64-apple-ios.swiftdoc

Copy Release-iphoneos/FirasAI.swiftmodule/arm64-apple-ios.abi.json /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.abi.json (in target 'FirasAI' from project 'FirasAI')
    cd ios
    builtin-copy -exclude .DS_Store -exclude CVS -exclude .svn -exclude .git -exclude .hg -resolve-src-symlinks -rename FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.abi.json /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.swiftmodule/arm64-apple-ios.abi.json

Copy Release-iphoneos/FirasAI.swiftmodule/Project/arm64-apple-ios.swiftsourceinfo /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.swiftsourceinfo (in target 'FirasAI' from project 'FirasAI')
    cd ios
    builtin-copy -exclude .DS_Store -exclude CVS -exclude .svn -exclude .git -exclude .hg -resolve-src-symlinks -rename FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.swiftsourceinfo /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.swiftmodule/Project/arm64-apple-ios.swiftsourceinfo

Ld Release-iphoneos/FirasAI.app/FirasAI normal (in target 'FirasAI' from project 'FirasAI')
    cd ios
    /Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -Xlinker -reproducible -target arm64-apple-ios18.0 -isysroot /Applications/Xcode_26.6.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk -Os -LEagerLinkingTBDs/Release-iphoneos -L/Users/runner/work/_temp/FirasAI-Build/Release-iphoneos -F/Users/runner/work/_temp/FirasAI-Intermediates/EagerLinkingTBDs/Release-iphoneos -F/Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/PackageFrameworks -F/Users/runner/work/_temp/FirasAI-Build/Release-iphoneos -filelist /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.LinkFileList -Xlinker -rpath -Xlinker /usr/lib/swift -Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -dead_strip -Xlinker -object_path_lto -Xlinker /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI_lto.o -Xlinker -dependency_info -Xlinker /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI_dependency_info.dat -fobjc-link-runtime -L/Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphoneos -L/usr/lib/swift -Xlinker -add_ast_path -Xlinker /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.swiftmodule @/Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI-linker-args.resp -Wl,-no_warn_duplicate_libraries -o /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app/FirasAI -Xlinker -add_ast_path -Xlinker /Users/runner/work/_temp/FirasAI-Intermediates/ZIPFoundation.build/Release-iphoneos/ZIPFoundation.build/Objects-normal/arm64/ZIPFoundation.swiftmodule @/Users/runner/work/_temp/FirasAI-Intermediates/ZIPFoundation.build/Release-iphoneos/ZIPFoundation.build/Objects-normal/arm64/ZIPFoundation-linker-args.resp

CopySwiftLibs Release-iphoneos/FirasAI.app (in target 'FirasAI' from project 'FirasAI')
    cd ios
    builtin-swiftStdLibTool --copy --verbose --scan-executable Release-iphoneos/FirasAI.app/FirasAI --scan-folder /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app/Frameworks --scan-folder /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app/PlugIns --scan-folder /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app/SystemExtensions --scan-folder /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app/Extensions --platform iphoneos --toolchain /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.6.109.0.t05Obr/Metal.xctoolchain --toolchain /Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain --destination /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app/Frameworks --strip-bitcode --strip-bitcode-tool /Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/bitcode_strip --emit-dependency-info /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/SwiftStdLibToolInputDependencies.dep --filter-for-swift-os --back-deploy-swift-span
Ignoring --strip-bitcode because --sign was not passed

ExtractAppIntentsMetadata (in target 'FirasAI' from project 'FirasAI')
    cd ios
    /Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor --toolchain-dir /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.6.109.0.t05Obr/Metal.xctoolchain --module-name FirasAI --sdk-root /Applications/Xcode_26.6.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk --xcode-version 17F113 --platform-family iOS --deployment-target 18.0 --bundle-identifier org.firasai.FirasAI --output Release-iphoneos/FirasAI.app --target-triple arm64-apple-ios18.0 --binary-file /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app/FirasAI --dependency-file /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI_dependency_info.dat --stringsdata-file /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/ExtractedAppShortcutsMetadata.stringsdata --source-file-list /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.SwiftFileList --metadata-file-list /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/FirasAI.DependencyMetadataFileList --static-metadata-file-list /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/FirasAI.DependencyStaticMetadataFileList --swift-const-vals-list /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/Objects-normal/arm64/FirasAI.SwiftConstValuesFileList --compile-time-extraction --deployment-aware-processing --validate-assistant-intents --no-app-shortcuts-localization
2026-09-02 20:38:33.848 appintentsmetadataprocessor[5123:19013] Starting appintentsmetadataprocessor export
2026-09-02 20:38:33.861 appintentsmetadataprocessor[5123:19013] warning: Metadata extraction skipped. No AppIntents.framework dependency found.

GenerateDSYMFile Release-iphoneos/FirasAI.app.dSYM /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app/FirasAI (in target 'FirasAI' from project 'FirasAI')
    cd ios
    /Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/dsymutil Release-iphoneos/FirasAI.app/FirasAI -o /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app.dSYM

AppIntentsSSUTraining (in target 'FirasAI' from project 'FirasAI')
    cd ios
    /Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsnltrainingprocessor --infoplist-path Release-iphoneos/FirasAI.app/Info.plist --temp-dir-path /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/ssu --bundle-id org.firasai.FirasAI --product-path /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app --extracted-metadata-path /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app/Metadata.appintents --metadata-file-list /Users/runner/work/_temp/FirasAI-Intermediates/FirasAI.build/Release-iphoneos/FirasAI.build/FirasAI.DependencyMetadataFileList --source-file /Users/runner/work/_temp/FirasAI-Build/Release-iphoneos/FirasAI.app/Info.plist --archive-ssu-assets
2026-09-02 20:38:33.926 appintentsnltrainingprocessor[5124:19014] Parsing options for appintentsnltrainingprocessor
2026-09-02 20:38:33.928 appintentsnltrainingprocessor[5124:19014] Starting AppIntents SSU YAML Generation
2026-09-02 20:38:33.936 appintentsnltrainingprocessor[5124:19014] No AppShortcuts found - Skipping.

RegisterExecutionPolicyException Release-iphoneos/FirasAI.app (in target 'FirasAI' from project 'FirasAI')
    cd ios
    builtin-RegisterExecutionPolicyException Release-iphoneos/FirasAI.app

Validate Release-iphoneos/FirasAI.app (in target 'FirasAI' from project 'FirasAI')
    cd ios
    builtin-validationUtility Release-iphoneos/FirasAI.app -validate-for-store -shallow-bundle -infoplist-subpath Info.plist

Touch Release-iphoneos/FirasAI.app (in target 'FirasAI' from project 'FirasAI')
    cd ios
    /usr/bin/touch -c Release-iphoneos/FirasAI.app

** BUILD SUCCEEDED **

```
