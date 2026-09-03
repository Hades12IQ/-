# Architecture candidate B — experience + parity first

Angle: build from the Claude-app feel and the website's full inventory outward, then rest each screen on
exactly one store. Sources: `design-brief.md` (structure, tokens, copy), the six `audit-ios-*.md`
(what survives), the `server-*.md` contracts (every endpoint and error code), `web-plan-mode.md §7`.
Where the brief and an audit disagree, the brief wins (it is the owner's north star); the two
disagreements are called out in §7. Everything below is decided; nothing is "consider".

Hard constraints honoured throughout: iOS 18 target, Xcode 26 on CI only, Swift 5 mode,
`SWIFT_STRICT_CONCURRENCY=minimal`, default nonisolated, `ISOLATED_DEFAULT_VALUES=YES`, no team
(no APNs / App Groups / CallKit / iCloud), ZIPFoundation 0.9.20 is the only package, synchronized root
group (any `.swift` under `ios/FirasAI/` compiles — including leftovers, so **deleted files must
actually be deleted**, §5 batch 0).

---

## 1. Folder layout — every file, one owner, one line

Sizes are targets (150–400 lines). `(keep)` = existing file survives with the listed edits;
`(rewrite)` = same name, new body; everything else is new. `Owner` slots are numbered 1–20 for
parallel assignment in §5.

### App/
| File | Responsibility |
|---|---|
| `FirasAIApp.swift` (keep, extend) | `@main`; builds `AppContainer`; injects stores via `.environment`; `scenePhase` → `container.applicationDidBecomeActive()/didEnterBackground()`; `.onOpenURL` → `DeepLinkRouter`. |
| `AppContainer.swift` | `@MainActor final class AppContainer` owning every store in dependency order (`api → session → jobs → chat/agent/code/brain/media → voice → prefs/router`). The only place stores are constructed. |
| `AppDelegate.swift` (rename of `FirasAppDelegate`) | `UNUserNotificationCenter` delegate, `BGTaskScheduler.register("org.firasai.FirasAI.jobs")` in `didFinishLaunching`. No APNs callbacks. |
| `AppConfiguration.swift` (keep) | Base URL (`FIRAS_API_BASE_URL`, https only). |
| `DeepLinkRouter.swift` | `?verify=`, `?reset=&uid=`, `?share=` URLs and `NotificationDestination` → `ShellRouter` actions. |
| `EnvironmentKeys.swift` | `\.palette`, `\.lang`, `\.motionOn`, `\.readingWidth` environment keys + `View.firasEnvironment(prefs:)`. |

### Core/Networking/
| File | Responsibility |
|---|---|
| `APIClient.swift` (rewrite around the existing actor) | One `URLSession` (cookie jar `HTTPCookieStorage.shared`, `.always`), `request/requestJSON/stream/downloadToFile/uploadJSONLong`; per-call `RequestBudget` timeouts; `Cache-Control: no-cache` + `.reloadIgnoringLocalCacheData` on GETs. |
| `APIError.swift` | `APIError` + `ServerError` (lenient envelope: `error, quota, guest, scope, feature, limit, used, remaining, windowMin, freesInMin, activeJob, credits, retryRequiresNewCid, maxPages, chars, cap`); plain-text bodies become `.code = body`. |
| `SSEParser.swift` | Byte-stream → frames `{event?, id?, data}`; buffers partial lines; ignores comments; tolerates malformed JSON per frame. |
| `QueryEncoding.swift` | `percentEncodedQueryItems` with `+&=` escaped (fixes `C++`). |
| `FirasAPI.swift` (keep struct, gut methods) | `nonisolated struct FirasAPI { let client: APIClient }`; all methods live in the extension files below. |
| `Endpoints/AuthEndpoints.swift` | login, signup, verify-status, resend-code, forgot, reset, me, logout, change-email/password, delete, google-native, guest start/end, redeem. |
| `Endpoints/ChatEndpoints.swift` | chats list/get/create/update/delete, `chatStream` (SSE `/api/chat`), search, fetch, translate, share create/get/delete, memory get/delete. |
| `Endpoints/JobEndpoints.swift` | `/api/chat/job` start/status/cancel/file(+part), `/api/agent/job`, `/api/agent/job-stream` (SSE), `/api/agent/artifact` (download), `/api/agent/credits`, `/api/usage/charge`. |
| `Endpoints/BrainEndpoints.swift` | docs, doc add, doc delete, search, passage, whole. |
| `Endpoints/MediaEndpoints.swift` | image/video/music job start+status, image quota, image edit, video quota, image/video/music file downloads. |
| `Endpoints/VoiceEndpoints.swift` | live token, transcribe (+probe), tts (returns `Data` + content-type). |
| `Endpoints/MiscEndpoints.swift` | announcements, version. |

### Core/Models/
| File | Responsibility |
|---|---|
| `CommonModels.swift` (keep) | `ModelTier` (drop the two `@MainActor`s; add `showThinking`, `shortName`, `tokenCap` 4000/16000/16000/24000), `ProductKind` (+ `.studio`), `AppAPIValue`. |
| `AuthModels.swift` (keep, prune) | `User`, `Subscription`, DTOs; delete Firebase/OAuth-exchange DTOs. |
| `ChatModels.swift` (keep) | `ChatMessage`, `ChatSummary`, `ChatConversation`, `ChatJob*`; add `ChatJobPhase.unknown.isTerminal == true` **for non-chat kinds only** (see `JobKinds`). |
| `ChatWireModels.swift` | `OutgoingChatMessage {role, content, images?}`, `PersistedChatMessage` (§5.2 whitelist), `ChatStreamRequest`. |
| `JobModels.swift` | `JobKind` (chat, longdoc, longfile, agentrun, codebuild, brainask, image, video, music), `JobPointer`, `JobSnapshot`, `JobTerminal`. |
| `AgentModels.swift` (keep) | + `AgentFile.artifactIndex` parsed from `url`, `AgentBusyResponse`, `AgentFence` parser. |
| `CodeModels.swift` (keep) | + `CodeChatThread` (`firas-code-chat` base64 JSON in `messages[1]`), `validatedForSave()` caps 30/120/60 000/180 000. |
| `BrainModels.swift` (keep) | + `near: Bool?`, lenient `kind/unit`, `BrainWholeRequest/Response`, `BrainAskJobRequest`. |
| `MediaModels.swift` (rename of MediaStudioModels) | requests (+video `image`), quota, `MediaCreation` with **relative** filename, presets 1024², 1024×1536, 1536×1024. |
| `VoiceModels.swift` | `LiveToken {provider, token, model, voice?, maxMs, guest, startWithinMs}`, `TranscribeResponse`, `DictationDialect` (14 server keys + BCP-47 + label). |
| `FenceModels.swift` | `FirasFence` enum: `.code(CodeMeta, body)`, `.file(FileMeta)`, `.image/.video/.music(MediaMeta)`, `.agent(AgentSurface)`, `.project(CodeProject)`, `.ask(AskSpec)`, `.sources([Source])`; single `parse(fenceName:body:)`. |
| `AnnouncementModels.swift` | `Announcement` + the built-in launch post (verbatim from `brand/announcement-launch.json`, id `builtin_launch`). |

### Core/Session/
| File | Responsibility |
|---|---|
| `SessionStore.swift` (rewrite lifecycle, keep calls) | phases, `restore()` with 15 s budget + retry on active/online, `handleUnauthorized()`, `revalidateIfStale()`, verification polling 3 s, forgot/reset, `onGuestBecameMember` hook. |
| `AuthErrorMapper.swift` | `(status, ServerError, URLError?) → L` table (credentials, emailTaken, tooManyAttempts, offline, serverBusy, Google cases). |
| `GoogleOAuthProvider.swift` (keep) | F17 fix: `nonisolated presentationAnchor` + `callback: .customScheme`. |
| `GuestMigration.swift` | After sign-up from guest: POST each local guest chat, toast `تم نقل محادثاتك إلى حسابك ✓`, `DELETE /api/guest`. |

### Core/Jobs/
| File | Responsibility |
|---|---|
| `JobManager.swift` | The registry: `start/attach/reattachAll/cancel/forget/snapshot(for:)`; one `JobPoller` per pointer; publishes `JobEvent` via `AsyncStream` to stores; owns the completion cue call. |
| `JobPointerStore.swift` | `jobs.json` in Application Support (`.completeFileProtection`); pointer only, never transcripts. |
| `JobPoller.swift` | One loop per pointer: cadence from `JobKinds`, backoff 1.2→30 s on transport, suspend when `scenePhase != .active` (except inside the background grace), 401 → `session.handleUnauthorized` and pause, 403/404 → terminal-forget, three `unknown` polls rule, per-kind deadline. |
| `JobKinds.swift` | Per-kind adapter table: status endpoint, cadence, deadline (chat 15 min, longfile 6 h, agentrun 3 h, codebuild 2 h, brainask 10 min, image/video 20 min, music 10 min), terminal rule, `cancelable`, notification copy key. |
| `AgentJobStream.swift` | SSE `/api/agent/job-stream` reader (`snapshot/terminal/agent-error`), reconnect 1→15 s, falls back to polling. |
| `BackgroundRefresh.swift` | `beginBackgroundTask` while any pointer exists (ends at expiry); submits `BGAppRefreshTaskRequest` (earliest +60 s) on background; handler polls each pointer once, posts local notifications for terminal ones, resubmits. |
| `JobNotifications.swift` | `UNUserNotificationCenter` permission (asked after the first accepted job, with a one-line explainer), category `FIRAS_JOB_COMPLETE`, server-verbatim copy table, thread id `firas-<product>-<chatId|jobId>`, `NotificationDestination` decode. |
| `CompletionCue.swift` (rewrite of FirasCompletionCue) | `prepare()` on terminal poll; `fire(kind:)` = soft impact 0.32 → 160 ms → 0.48 → 140 ms → return; `.error` notification haptic on failure; optional `done.caf`; foreground-only; consumed-key history; Reduce Motion → single `.success` (never skip). |

### Core/Storage/
| File | Responsibility |
|---|---|
| `LocalStore.swift` | Generic JSON file store under `Application Support/FirasAI/`, atomic writes off-main, `excludedFromBackup` for media. |
| `DraftStore.swift` | Per chat + `new:<product>` drafts, 400 ms debounce, LRU 30, 20 000 chars. |
| `GuestChatStore.swift` | Guest conversations on disk, 7-day TTL (matches the guest cookie), owner = guest id. |
| `ChatMetaStore.swift` | Device-local colour tags, folders, "seen announcement ts", pinned-message ids, private notes. |
| `MediaAssetRepository.swift` (keep, fix) | Relative filenames, delete on trim, `.playback`-ready URLs. |

### Core/Prompting/
| File | Responsibility |
|---|---|
| `PromptCatalog.swift` (other agent) | Verbatim web rules; `systemPrompt(tier:product:mode:lang:think:requestKind:)`. |
| `PromptBuilder.swift` | Assembles `[system] + searchContext(user) + windowed history + last user`; plan-mode concatenation (§7.3 of plan doc); `fileGuidance(fmt)`; `nomem` helper prompts (auto-title, keyword expansion, image spec). |
| `RequestClassifier.swift` | Intent of the last user message: `chat / code / file(fmt, explicitPages?) / image / imageEdit / video / music / longdoc / longfile / irab`; ports `LONGDOC_RE`, `parseExplicitPageCount`, `detectCodeRequest`, media triggers. |
| `SearchContextBuilder.swift` | `needsWebSearch` / `benefitsFromSilentSearch` regexes, 8 s / 1.5 s budgets, ≤6 rows, nonce fence, the "no live results" system note, tier downgrade to `pro` on explicit search. |
| `MessageSerializer.swift` | `outgoing(from:)` (slim), `persisted(from:)` (whitelist), image re-attach rule for follow-ups. |
| `HistoryWindow.swift` | Keeps system + last turns under 400 000 chars (always the last user turn); returns `didTrim`. |
| `EngineFailureDetector.swift` | `busyRe` sentences + empty stream → failure; one automatic retry with a new cid. |
| `PlanCycle.swift` | `PlanPhase` enum + transitions (plan doc §7.2), snapshot mode per conversation, derive-on-load (§7.5). |
| `AskSpec.swift` | `firas-ask` parse + `normalizeAskSpec` + summary formatter (§3.2/3.5), also accepts a `json` fence with `questions`. |
| `ApprovalMatcher.swift` | §7.6 matcher (normalised Arabic prefixes, English whole-message forms, >6 words = revision). |

### Core/Text/
| File | Responsibility |
|---|---|
| `BidiDirection.swift` | `firstStrong(_:) → LayoutDirection?`; `View.bidiIsland(for:fallback:)`. |
| `ArabicNumerals.swift` | `ar-IQ-u-nu-arab` formatting for counts/quotas/timer; `latinTimer(seconds)` LTR. |
| `ArabicPlurals.swift` | Six-form table helper `L.count(n, zero:one:two:few:many:other:)`. |
| `TextNormalizer.swift` | tashkeel/tatweel strip, hamza/ya/ta-marbuta folding (used by approval matcher, Brain routing, search). |
| `TeXUnicode.swift` | Port of the web's `texToUnicode` for inline math fallback. |

### Core/Markdown/
| File | Responsibility |
|---|---|
| `MarkdownDocument.swift` | `enum MDBlock` (paragraph, heading, list, quote, table, code, hr, fence(FirasFence), mathDisplay, html-ish raw) + `MarkdownDocument.parse(_:)`; `IncrementalParser` (settled prefix frozen, live tail re-parsed). |
| `MarkdownBlockParser.swift` | Line scanner → blocks; open fences / open `$$` stay raw until closed. |
| `MarkdownInline.swift` | Inline → `AttributedString` (bold, italic, code, links, strikethrough) via `AttributedString(markdown:options:.inlineOnlyPreservingWhitespace)` after math protection. |
| `MathScanner.swift` | The **one** scanner: protects `$$…$$`, `$…$`, `\(…\)`, `\[…\]` with PUA sentinels; currency guard (`$5 for tea`). |
| `CodeHighlighter.swift` | Tiny tokenizer (keyword/string/comment/number/tag/attr) for html/css/js/ts/json/py/swift/bash → `AttributedString` with the web's editor skin colours. |
| `FenceRouter.swift` | ```` ```firas-* ```` and `plot` fences → `FirasFence`; unknown fence → code block. |

### DesignSystem/
| File | Responsibility |
|---|---|
| `FirasTheme.swift` (keep, extend) | Six palettes (exact) + derived tokens `accentSoft, accentRing, glassTint, glassWash, glassStroke, glassShadow, userFill, userInk, userEdge, userSheen, maxTierText, maxTierBg, planGold, planDiamond, callBackground, codeWarn, codeOk, tag*`; `PreferencesStore` (+ `uiSoundsEnabled`, `responseMode`, 14-key dialect; language default from device). |
| `FirasGlass.swift` (rewrite of GlassSurface) | `enum FirasGlass.Level { chrome, floating, sheet }`; `View.firasGlass(_:in:)`; iOS 26 `Glass.clear.tint().interactive()` + wash + 0.5 pt stroke; iOS 18 `.ultraThinMaterial.opacity(0.62)` over `surface.opacity(0.28)`; Reduce Transparency → solid. |
| `FirasBackground.swift` | Ground + accent radial + bottom darkening + static grain tile (opacity per theme). |
| `FirasMotion.swift` | `standard`, `sheet`, `drawerFlick`, `composer`, `tierPop`, `reveal`; `motionOn` gate; reduced-motion pulse. |
| `FirasType.swift` | Text styles, `assistantProse(lang)` line spacing, `firasTracking()` (Latin only), mono. |
| `FirasHaptics.swift` | `send, stop, select, attach, toolStep, error, undo, callConnect, recordStart/Stop`; prepared generators; foreground gate. |
| `FirasSound.swift` | `send.caf`, `done.caf` via two preloaded `AVAudioPlayer`s, `.ambient`, skipped while `CallEngine.isActive`. |
| `FirasLayout.swift` | Radii (24 composer, 20 bubble, 9 card, 7 nested), spacing scale, `readingColumn(width:pref:)`. |
| `SurfaceCard.swift` | Opaque `surface` card with hairline + `shadow-sm`; the **only** card container (no glass). |
| `ToastCenter.swift` | `@Observable` queue; 3.2 s; one optional action; `.floating` capsule above the composer; VoiceOver announcement. |
| `SkeletonView.swift` | Shimmer rows (transcript 3-row, sidebar, tiles). |
| `EmptyStateView.swift` | Title/sub/optional button; the five sidebar states. |
| `FirasActivityLabel.swift` (keep, fix) | Sweep via `phaseAnimator`; reduced motion → 1.5 s opacity pulse. |
| `FirasBrandMark.swift` (keep) | Mark + wordmark. |
| `MentronXEntryView.swift` (keep, shorten) | ≤ 1.2 s, tap to skip, first run + cold auth only. |

### Strings/
| File | Responsibility |
|---|---|
| `L.swift` | `struct L: Sendable { let ar: String; let en: String; func callAsFunction(_ lang: AppLanguage) -> String }` + `L.fmt(_:args:)` + environment access. |
| `CommonStrings.swift`, `ShellStrings.swift`, `ChatStrings.swift`, `ComposerStrings.swift`, `ActionStrings.swift`, `QuotaStrings.swift`, `AgentStrings.swift`, `CodeStrings.swift`, `BrainStrings.swift`, `MediaStrings.swift`, `VoiceStrings.swift`, `SettingsStrings.swift`, `AuthStrings.swift`, `NotificationStrings.swift` | One `enum XStrings { static let key = L(ar:en:) }` per feature; Arabic verbatim from the web STR tables cited in the reports; `[new]` copy from the brief. |

### Features/Shell/
| File | Responsibility |
|---|---|
| `AppShell.swift` (rewrite of FirasAppShell) | Root LTR shell; `horizontalSizeClass` switch: regular → `NavigationSplitView(columnVisibility:)` + `backgroundExtensionEffect` on iOS 26; compact → detail + `CompactDrawer`; presents Settings / Auth / Call / Announcements / SignUpPrompt from `ShellRouter`. |
| `ShellRouter.swift` | `@Observable`: `product`, `selectedChatID`, `sheet`, `isCallPresented`, `pendingDestination`, `open(chatID:product:)`, `newChat(product:)`. |
| `CompactDrawer.swift` | Overlay drawer `min(360, max(286, w−44))`, `.floating` glass, 30 % scrim, 20 pt edge-swipe, `@GestureState` offset, momentum projection, `.isModal`. |
| `SidebarView.swift` | Header (lockup, bell + dot, close), product switcher, new-chat prominent row, search field, shelves, history, usage, guest slot, account pill. |
| `SidebarProductSwitcher.swift` | Five rows with live-dot/count from `JobManager.activeCount(product:)`. |
| `SidebarHistoryList.swift` | Pinned + date groups, colour stripe, live dot, swipe pin/delete (7 s undo, deferred DELETE), context menu, inline rename. |
| `SidebarSearch.swift` | Title filter; ≥3 chars searches loaded message text (`msgHits`). |
| `SidebarAccountPill.swift` | Avatar initial, name, settings gear, sign-out. |
| `KeyboardCommands.swift` | `⌘N ⌘K ⌘↩ esc ⌘, ⌘1…5 ⌘⇧M ⌘⇧C` as `.keyboardShortcut` modifiers on a hidden command layer. |

### Features/Onboarding/ and Features/Auth/
| File | Responsibility |
|---|---|
| `ConsentView.swift` | First-run consent (verbatim copy), checkbox never pre-ticked, `متابعة` prominent. |
| `LandingView.swift` | Guest CTA, sign-in link, seven feature cards, no counters. |
| `AuthView.swift` (keep shell, redesign fields) | Email/password/Google, glass fields on 26, forgot link, terms link. |
| `VerificationCard.swift` | 3 s status polling while visible, resend with 30 s countdown. |
| `ForgotPasswordSheet.swift` | forgot → "check inbox"; reset form from deep link. |
| `SignUpPromptSheet.swift` | Feature-keyed upsell (`image/video/music/live/agent/brain/brain_whole/share`) with the web's verbatim texts. |

### Features/Chat/
| File | Responsibility |
|---|---|
| `ChatStore.swift` (keep skeleton, refactor) | Conversation list (members via server, guests via `GuestChatStore`), lazy create on first send, `send()`, `stop()`, regenerate/escalate/continue, auto-title, per-conversation `ConversationState` map, merge-on-finish by cid. |
| `ConversationState.swift` | Per-chat live state: streaming buffer (coalesced to ≤10 Hz), `jobID`, `phase` (`idle/searching/thinking/streaming/completing`), `PlanCycle`, error strip, outbox. |
| `SendPipeline.swift` | The one send path: classify → attachments → search → prompt → job-or-stream decision (413/404/501 → SSE; images → SSE) → PUT user turn → start → attach poller. |
| `ChatScreen.swift` (keep frame) | `NavigationStack`, toolbar (sidebar, tier pill, new chat, gallery), `safeAreaBar`/`safeAreaInset` composer, sheets, drop/paste. |
| `TranscriptView.swift` | `ScrollView + LazyVStack`, at-bottom tracking (`onScrollGeometryChange`), autoscroll only at edge, jump chip, skeleton, per-row `EquatableView`. |
| `WelcomeView.swift` | Halo + mark + greeting (time + first name), Agent variant. |
| `TierPill.swift`, `TierPickerSheet.swift` | Principal pill; medium sheet with four rows, badges, response-style card. |
| `ModePill.swift` | `تلقائي/تخطيط` menu, hints. |
| `Composer/ComposerView.swift` | Two-row `.floating` glass, radius 24, `GlassEffectContainer(spacing: 12)`, send/stop morph, phone/mic, disclaimer line. |
| `Composer/ComposerField.swift` | `TextField(axis:.vertical)` 1–6 lines, direction re-evaluation while typing, Return vs `⌘↩`, `.onKeyPress`. |
| `Composer/AttachmentTray.swift` | Thumbs 64 pt, chips with kind tag, reading/truncated states. |
| `Composer/LengthMeter.swift` | chars·tokens, near/over thresholds by tier cap, 200 000 hard cut. |
| `Composer/SlashMenu.swift` | Four quick commands anchored above the field. |
| `Composer/AddSheet.swift` (rename of AddContextSheet, fix) | Camera / Photos / Files, tools toggles (search, thinking hidden on Mini, dialect), Brain OCR row. |
| `Composer/AttachmentProcessor.swift` (keep) | ImageIO downsample, Office via extractor, budgets aware of history. |
| `Composer/DictationBar.swift` | Replaces row 2 while recording: cancel, waveform (32 bars), timer, dialect chip, done. |
| `Messages/UserTurnView.swift` | Trailing bubble, `userFill` gradient, sheen, 12-line clamp, image grid, chips, copy menu. |
| `Messages/AssistantTurnView.swift` | Header (mark, FIRAS, tier badge), retry strip, thinking disclosure, body, cards, start pill, quick replies, actions. |
| `Messages/ThinkingDisclosure.swift` | `التفكير` chevron; live "thinking…" header while reasoning streams. |
| `Messages/StreamingBodyView.swift` | Settled blocks + live tail `Text` + 2 pt caret. |
| `Messages/MessageActionsRow.swift` | Four ghost buttons + `المزيد`; copy feedback. |
| `Messages/MessageContextMenu.swift` | The web's long-press order (§7.7 brief). |
| `Messages/VersionPager.swift` | `‹ 2/3 ›` over `alts`. |
| `Messages/QuickReplies.swift` | Chips from headings/bullets. |
| `Messages/PlanStartPill.swift` | `ابدأ التنفيذ` prominent capsule. |
| `Messages/AskPanelView.swift` | `firas-ask` wizard (stepper, radio/check, recommended badge, extra field, submit → summary). |
| `Markdown/MarkdownBodyView.swift` | `[MDBlock]` → SwiftUI blocks; direction per paragraph; headings spacing per brief. |
| `Markdown/CodeBlockView.swift` | LTR mono, language label, copy, preview button when previewable, 14-line fade in cards. |
| `Markdown/TableBlockView.swift` | `Grid` inside horizontal `ScrollView`. |
| `Markdown/MathBlockView.swift` | `WKWebView` island with bundled KaTeX for display math; height via JS; cached per block hash; ≤6 live islands. |
| `Markdown/InlineMathText.swift` | Inline `$…$` → `TeXUnicode` fallback in serif-ish mono. |
| `Cards/CodeCard.swift`, `Cards/FileCard.swift`, `Cards/ImageCard.swift`, `Cards/VideoCard.swift`, `Cards/SongCard.swift`, `Cards/LongFileCard.swift`, `Cards/AgentSummaryCard.swift`, `Cards/SourcesCard.swift` | One card per fence; image ≤420 pt r20; video 16:9 `AVPlayer`; song full-width; longfile progress + preview/export; agent card → opens the mission; sources list. |
| `CodeViewerSheet.swift` | Full-screen `معاينة/الكود` (Claude artifact pattern) with sandboxed `WKWebView`. |
| `LongFileViewer.swift` | Fetch manifest + parts (sha256 verified), page reader, export via `ExportController`. |
| `ShareController.swift` | `POST /api/share` (whole/one), URL `https://firasai.org/?share=<id>`, share sheet, 20-share cap copy. |
| `ExportController.swift` | Markdown / text / PDF (`ImageRenderer` of `MarkdownBodyView`) / image; file → share sheet. |
| `AutoTitle.swift` | 42-char provisional; `nomem` title call after first answer; PUT `{title}` unless renamed. |

### Features/Agent/
| File | Responsibility |
|---|---|
| `AgentStore.swift` (rewrite engine) | Agent chats (`agent:true`), create chat before enqueue, `chatId` passed, credits fetch, 409/429 typed, follow-ups with prior context, resume (new cid), export. |
| `AgentScreen.swift` | Chat shell variant: welcome + templates strip, composer (always visible), credits chip. |
| `MissionCard.swift` | The living card: spine, header/status pill/elapsed, speech line, plan, timeline, files, result, footer actions; blocked/credits states. |
| `MissionTimeline.swift` | `events[]` rows by tool kind, sources group, `live[]` disclosure; diff by id for animation. |
| `MissionFiles.swift` | Image grid + document list; cookie download → `QLPreviewController`; share after download. |
| `ArtifactViewer.swift` | `QLPreviewController` wrapper + sandboxed `WKWebView` for html/md/json. |
| `CreditsSheet.swift` | `remaining/allowance`, held, resetAt (Arabic-Indic). |

### Features/Code/
| File | Responsibility |
|---|---|
| `CodeStore.swift` (rewrite around project = chat) | Projects = `codeProj` chats (guests local), scaffold `CW_BLANK_FILES`, build job (`chatId:""`, attach ≤24 000, no charge, no think), land fence into `messages[0]`, thread in `messages[1]`, snapshots/undo. |
| `CodeProjectRepository.swift` (keep) | Offline cache keyed by server chat id (or local id for guests). |
| `CodeLauncherView.swift` | Hero, create card, project grid (2/3–4 columns), delete. |
| `CodeWorkspaceView.swift` | iPhone `TabView` (Files/Code/Preview/AI) + build strip accessory; iPad three columns. |
| `FileNavigator.swift` | Folders collapsed, icons by extension, swipe rename/delete, `+`. |
| `CodeEditorView.swift` | `UIViewRepresentable UITextView` (smart quotes off, ascii keyboard, mono 13, gutter, active line), 900 ms commit debounce, `⌘S ⌘F ⌘/`. |
| `CodeEditorTheme.swift` | Dark/light skins (web hex values). |
| `PreviewWebView.swift` | `WKWebView` non-persistent store, `firas-proj://` scheme handler, console hook `WKScriptMessageHandler`, navigation policy, device presets, auto-reload. |
| `ConsoleView.swift` | Level chips, filter, clear, `أصلحه بالذكاء`. |
| `CodeAIBar.swift` | Command bar, `@` mentions, attachments. |
| `CodeAskAI.swift` | `cwAskAI` routing via SSE `/api/chat` (`nomem`, tier pro/max), `file:` blocks + `DELETE:` lines, placeholder guard, continuation. |
| `DiffReviewSheet.swift` | Per-file checkboxes, apply with snapshot. |
| `CodeExport.swift` | ZIP (ZIPFoundation), share link, open in Safari (temp file). |

### Features/Brain/
| File | Responsibility |
|---|---|
| `BrainStore.swift` (rewrite, keep splitter) | Library, guests allowed, `ocr:0` unless server vision, pins/off-set persisted, page range, `brainNb` chats as threads. |
| `BrainAsker.swift` | Web routing §14.2 (whole → harvest → compare → quiz/overview/outline → reasoning → default → bilingual retry → overview fallback), grounding block, SSE stream, citation cleanup, sources fence; `brainask` durable job for long asks. |
| `BrainScreen.swift` | Ask thread (chat shell) + sources chip row; iPad three columns. |
| `BrainLibrarySheet.swift` | Hero, add, rows with phases/progress, OCR toggle, quota line, errors. |
| `SourceChipsRow.swift` | Active/pinned chips, range chip, `المصادر` button. |
| `PassageReaderSheet.swift` | before/hit/after, `فتح المصدر`, copy. |
| `CitationChip.swift` | `[Sn]` capsule. |
| `BrainImportPipeline.swift` | Extraction orchestration: OCR trigger rule, cap 300 pages/stride, 2–3 concurrent, progress `reading/ocr/uploading`, cancel, `beginBackgroundTask` around upload. |
| `BrainDocumentExtractor.swift` (keep, fix) | Vision language guard, 3 000/`page` text blocks, 1256 decoding, O(n) chunking. |
| `OfficeDocumentExtractor.swift` (keep, fix) | Selective entry extraction, rels-ordered slides/sheets. |

### Features/Media/
| File | Responsibility |
|---|---|
| `MediaStore.swift` (keep core, fix) | Creations as conversation turns (user message + fence), jobs via `JobManager`, deadlines, download-to-file, quota, upsell for guests. |
| `MediaStudioScreen.swift` (rewrite) | `TabView` `المكتبة/إنشاء`; iPad grid + inspector. |
| `MediaLibraryGrid.swift` | 3/5-column grid of fences across chats, sticky conversation headers, skeleton tiles, "still rendering" accessory. |
| `MediaCreateForm.swift` | Kind picker, prompt, per-kind controls, quota panel. |
| `MediaViewer.swift` | Full-screen: pinch zoom, `AVPlayer` (local file), song player, save/share/open-in-chat/edit/regenerate. |
| `MediaPromptPipeline.swift` | Image English rewrite + shape inference, video rewrite + first frame (JPEG ≤2048 px), music style tags + lyric author (`STYLE:` line), regenerate = changed input. |
| `SongPlayer.swift` | Single `AVPlayer`, `.playback`, scrubber, LTR elapsed/total, pauses TTS. |

### Features/Call/ and Features/Voice/
| File | Responsibility |
|---|---|
| `CallEngine.swift` | `@MainActor` controller: ladder (OpenAI → Gemini → three-hop), phases, two clocks, mute, barge-in setting, teardown checklist, background continuation (`audio` mode), local notification on background end. |
| `RealtimeTransport.swift` | `protocol RealtimeTransport` + `RealtimeEvent` enum. |
| `OpenAIRealtimeTransport.swift` | WebSocket GA vocabulary (§8 of voice report), 20 s ping, session.created assert, 24 kHz PCM, transcripts → captions, truncate on barge-in. |
| `GeminiLiveTransport.swift` (keep protocol, fix) | Verbatim instruction, `tools`, setupComplete 10 s, 1008/1011 cooldown, reduced-setup retry. |
| `CallAudioGraph.swift` | AVAudioSession + VPIO + converter + ordered `AsyncStream<Data>` + Float32 player queue + observers (config change, route, interruption). |
| `EchoGuard.swift` | RMS floor/×3/3 frames/350 ms hangover + silence substitution (Gemini rung). |
| `ThreeHopCall.swift` | record → transcribe → chat (auto, think off, tier ≤ pro, `callSys`) → TTS. |
| `CallScreen.swift` | `fullScreenCover`, name/timer, orb, status/caption, consent card, controls in `GlassEffectContainer(spacing: 20)`, retry, iPad scaling, `esc`/space shortcuts. |
| `OrbView.swift` | `TimelineView(.animation)` + `Canvas` (or `colorEffect` shader), 176 pt, no halo, brightness-only under reduced motion. |
| `DictationRecorder.swift` | AVAudioEngine tap → 16 kHz mono PCM16, 300 s cap, level stream, auto-finish on background. |
| `WAVEncoder.swift` | RIFF header + base64 (standard alphabet, no line breaks). |
| `DictationController.swift` | `POST /api/transcribe {audio, format:"wav", lang}`; probe cached per launch; 503/offline → `SFSpeechRecognizer` (`auto` → `ar-SA`); append with one space; strings for short/empty/failed/denied. |
| `DialectPickerSheet.swift` | 14 radio rows with flags. |
| `ListenController.swift` | Single speaker token; `callSpeakable` clean; chunk ≤1 300 on `.!?؟،؛\n`; `POST /api/tts` → `AVAudioPlayer` by content-type; 16-entry cache; 429 → `AVSpeechSynthesizer` from the failed chunk; refuse during a call. |

### Features/Settings/ and Features/Share/
| File | Responsibility |
|---|---|
| `SettingsSheet.swift` (rewrite container) | iPhone `NavigationStack + List` with five sections pushing pages; iPad split; large detent / `.presentationSizing(.form)`. |
| `AccountSettingsView.swift` (keep, fix) | Identity hero, plan card copy, change email/password, danger zone, redeem code, guest CTA; error mapping. |
| `AppearanceSettingsView.swift` | Theme grid (3-swatch tiles, ring, 0.25 s colour animation), text size, width, motion, language. |
| `ChatSettingsView.swift` | Default tier rows, response style, thinking (hidden on Mini), web search, send-on-return, sharpen. |
| `VoiceSettingsView.swift` | Call voice, dialect (14), UI sounds. |
| `DataSettingsView.swift` (keep, fix) | Backup export/import (dated filename, partial report), clear prefs, notifications section (truthful copy), About. |
| `MemorySettingsView.swift` | `GET/DELETE /api/memory` list with per-row delete. |
| `AnnouncementsSheet.swift`, `AnnouncementReader.swift` | Bell feed (builtin merged, pinned first), reader with inline `AVPlayer`. |
| `ChatBackupDocument.swift` (keep) | Drop `@concurrent`. |
| `SharedChatView.swift` | Renders `GET /api/share?id=` JSON read-only with the CTA (deep link target). |

Deleted in batch 0: `Notifications/PushRegistrationClient.swift`, `Notifications/NotificationCoordinator.swift`
(replaced by `Core/Jobs/JobNotifications.swift`), `DesignSystem/GlassSurface.swift`,
`DesignSystem/FirasCompletionCue.swift`, all `Features/*/…Strings.swift` + `*.xcstrings` (replaced by
`Strings/`), `Features/Chat/LiveVoiceController.swift`, `VoiceCallView.swift`, `Stores/*` (moved),
`ExportOptions.plist`, `export-ipa.sh`, `IPA-EXPORT.md`. `Resources/Localizable.xcstrings` stays only
for `InfoPlist` usage strings.

Resources added: `Resources/KaTeX/` (katex.min.js, katex.min.css, mhchem.min.js, fonts), `Resources/Sounds/send.caf`,
`done.caf`, `Resources/Prompts/` nothing (prompts are Swift). `Info.plist`: `UIBackgroundModes: [audio, fetch, processing]`,
`BGTaskSchedulerPermittedIdentifiers: [org.firasai.FirasAI.jobs]`, `NSSpeechRecognitionUsageDescription`,
`UIApplicationSceneManifest` (multi-window), `ITSAppUsesNonExemptEncryption=false`, launch colour `#262624`.

---

## 2. Foundation design

### 2.1 APIClient
- One `actor APIClient` (existing shape) over a single `URLSession` with `HTTPCookieStorage.shared`,
  `httpCookieAcceptPolicy = .always`, `httpShouldSetCookies = true`. Cookies (`firas_session` 30 d,
  `firas_guest` 7 d, host-only, Secure) persist to disk by the system jar — no custom jar. All three
  audio/media/oauth helpers reuse this client; **no second `URLSession` anywhere** except the WebSocket
  session inside a transport (invalidated on teardown) and the `URLSessionDownloadTask` session below.
- `RequestBudget`: `.interactive` (15 s), `.poll` (30 s, `waitsForConnectivity`), `.stream` (resource
  20 min, idle handled by SSE consumer), `.upload` (resource 10 min), `.download` (resource 30 min).
  Set via `URLRequest.timeoutInterval` + separate sessions for `.stream/.download` only.
- Lenient JSON: every response body is first tried as `ServerError` (all-optional); non-2xx →
  `APIError.server(status, ServerError)`; `Content-Type: text/plain` bodies → `ServerError(code: body)`.
  Success decoding uses a `JSONDecoder` with `keyDecodingStrategy = .useDefaultKeys` and models whose
  optional fields are all `Optional` — never crash on a missing key. `APIError.decoding` carries
  `String(describing: DecodingError)` for `os.Logger` in DEBUG.
- `stream(_ request) -> AsyncThrowingStream<SSEFrame, Error>` built on `URLSession.bytes(for:)`; the
  consumer applies a 5-minute idle timeout (`withThrowingTaskGroup` race) and cancels the task to stop.
- `downloadToFile(path:budget:) async throws -> (URL, HTTPURLResponse)` using `session.download(for:)`
  (async, iOS 15+); the cookie rides on the request; caller moves the temp file. Used for agent
  artifacts, video/music files, longfile parts are JSON (normal request).
- GETs add `Cache-Control: no-cache` and `cachePolicy = .reloadIgnoringLocalCacheData`.
- 401 handling is **not** in the client: stores call `session.handleUnauthorized()` when they get
  `.server(401, _)` while `session.isAuthenticated` (guests get the sign-up prompt instead).

### 2.2 Models
Keep the existing `nonisolated struct … : Codable, Sendable` style. Rules: every server-optional field is
`Optional`; enums that decode server strings have a lenient `init(from:)` with a fallback case; ids are
`String`; timestamps are `String` (chats, ISO) or `Double` (jobs, ms). `ChatMessage` keeps its client-only
fields (`images`, `fileText`, `state`) and `MessageSerializer` decides what leaves the device.

### 2.3 SessionStore
```
phase: restoring | offline(retryAt) | guest | awaitingVerification(pid,email) | authenticated | signedOut
```
- `restore()`: `GET /api/auth/me` with `.interactive`; 401 → `POST /api/guest`; transport error →
  `.offline`, banner with Retry, auto-retry on `scenePhase == .active` and on `NWPathMonitor` satisfied;
  5xx ×3 → guest path.
- `handleUnauthorized()`: idempotent; only while `.authenticated`; toast `انتهت جلستك…`; `JobManager.pauseAll()`;
  → `establishGuestSession()`; router shows Auth.
- `revalidateIfStale()` on active when last `/me` > 10 min.
- Verification: `VerificationCard` runs a 3 s `.task(id:)` loop; resend with countdown; `verifySignup(token:)`
  reachable from `DeepLinkRouter`.
- `onGuestBecameMember: ((String) -> Void)?` fires from `applyAuthenticatedUser` when the previous phase was
  `.guest`; `GuestMigration` posts local chats then `DELETE /api/guest`.
- No shared `isWorking`; each operation has its own `SettingsOperation` state (existing enum, keep).

### 2.4 JobManager (cloud-first spine)
- **Pointer** = `{id, kind, ownerID, cid, product, chatID?, conversationID, assistantMessageID?, projectID?,
  creationID?, title, startedAt, lastPhase, cancelRequested, lang}`. Persisted as an array in `jobs.json`
  on every change; never the transcript.
- `start(kind:request:context:) async throws -> JobPointer` — for chat kinds posts `/api/chat/job`; for
  media posts the media job route; stores the pointer **before** returning; then `attach(pointer)`.
- `attach(_:)` spawns a `JobPoller` (one `Task` per pointer, stored in a dictionary keyed by job id).
  Poller emits `JobEvent.progress(JobSnapshot)` (throttled ≤10 Hz for growing `text`) and
  `JobEvent.terminal(JobTerminal)`; stores subscribe via `manager.events(for: pointerID)` (`AsyncStream`)
  or the broadcast `manager.allEvents`.
- Cadence (`JobKinds`): chat 500 ms → 1 s (10 s) → 1.5 s; longfile 3 s; agentrun SSE first then 1.25 s/5 s
  bg; codebuild 4 s; brainask 2 s; image 2→6 s; video/music 3→8 s. Background grace: `beginBackgroundTask`
  named `firas.jobs` opened on `didEnterBackground` while pointers exist, cadence ×2, closed at expiry.
- Terminal rules: `completed/done` → terminal success; `failed/fail` → failure (refusal when `status ≥ 400`
  with JSON `error`; `cancelled/499` → silent); `unknown` ×3 → treat as failed for chat kinds *unless the
  chat already carries the cid* (member re-GET), terminal immediately for codebuild/brainask; `{job:null}`
  ×2 → terminal for agent; media `running` past deadline → `timeout` (pointer kept for one later check);
  401 → pause + `session.handleUnauthorized`; 403/404 → forget silently; 20 consecutive transport errors
  → sleep 60 s and keep (never spin).
- `reattachAll()` on launch (after identity), on `scenePhase == .active`, on connectivity restored, and
  from `BackgroundRefresh`. Owner mismatch (pointer `ownerID != session.identityID`) → keep on disk,
  do not poll.
- `cancel(_:)`: chat/longfile → `POST /api/chat/cancel`; agent/codebuild/brainask/media → **no server
  cancel exists**; the UI must not offer Stop (agent shows "cannot be stopped", media shows nothing).
- `forget(_:)` removes the pointer; stores call it **after** landing the result (land-before-forget).
- Completion: when a terminal event arrives and the app is active, `CompletionCue.fire(success:)` runs
  **before** the store publishes the final state (≈300 ms), then the store reveals; when inactive,
  `JobNotifications.post(pointer, terminal)` schedules the local notification with the server's verbatim
  copy and the `FirasComplete` sound; tapping routes through `DeepLinkRouter` to the chat/product.
- `BackgroundRefresh`: registered at launch; submitted whenever the app backgrounds with pointers; the
  handler calls `reattachAll(oneShot: true)` with a 20 s ceiling, posts notifications, calls
  `task.setTaskCompleted`, resubmits. Expectation set in copy: "usually within minutes" — never "instantly".

### 2.5 Design system
- Tokens: §6 of the brief lands in `FirasPalette` verbatim (base + derived). Views read
  `@Environment(\.palette)`; nobody writes `.opacity(0.05)` inline.
- Glass: `FirasGlass.Level` with the exact recipe of brief §2.3–2.4; `.floating` is `Glass.clear` +
  `glassTint` + wash overlay + 0.5 pt stroke on iOS 26; the iOS 18 fallback layers `.ultraThinMaterial.opacity(0.62)`
  over `surface.opacity(0.28)`. `.sheet` = `Glass.regular.tint(glassTint)`; sheets never set a solid
  `presentationBackground` on iOS 26. Content (cards, bubbles, editor) is `SurfaceCard` — opaque.
  Composer controls sit *inside* the composer's `GlassEffectContainer(spacing: 12)`.
- Typography: system font only; `FirasType.prose(lang)` = `.body` + `lineSpacing(9)` Arabic / `6` Latin;
  `.firasTracking()` applies `-0.3` only when the string has no Arabic scalar; Arabic never `.light`.
- Spacing/radii in `FirasLayout`; motion in `FirasMotion` (house spring 0.35/0.85); haptics vocabulary
  in `FirasHaptics` (brief §5.1) with `prepare()` calls from the poller on `completing`.
- Sound: `FirasSound.play(.send|.done)` only when `prefs.uiSoundsEnabled && !CallEngine.isActive`,
  `.ambient` category, volume 0.6.

### 2.6 Navigation
- iPhone: `AppShell` = `ZStack { detail; CompactDrawer }` where detail is the selected product's screen,
  each owning its `NavigationStack`. Drawer is interactive (edge swipe, drag, momentum). No bottom tab bar
  at the root; `TabView` only inside Code and Media Studio (`tabBarMinimizeBehavior(.onScrollDown)` on 26).
- iPad: `NavigationSplitView(columnVisibility:)` `.balanced`, sidebar 270–360, detail gets
  `backgroundExtensionEffect()` on 26; `.toolbar(removing: .sidebarToggle)` is applied and our own
  toggle kept (settles audit F31 deterministically).
- Shell is **fixed LTR** (`.environment(\.layoutDirection, .leftToRight)` once at the root); RTL exists
  only in bidi islands (`bidiIsland(for:)`) — brief decision 2, parity with the web.
- `ShellRouter` is the single navigation source; screens never present sheets from stores.

### 2.7 Localization — `L` struct, not a String catalog
Decision: **no `.xcstrings`, no `LocalizedStringResource`** for app copy. Reasons that matter for blind
compiles: (1) the in-app language switch must be deterministic — `Text(LocalizedStringResource)` following
`\.locale` is undocumented (audit F11) and cannot be verified without a device; (2) a missing key is a
runtime blank, a wrong `L` is a compile error; (3) Arabic verbatim strings live next to their English in
one diff-able place; (4) plurals need the six Arabic forms, which the catalog UI makes painful and the
`ArabicPlurals` helper makes explicit. Views read `@Environment(\.lang)` and call `ChatStrings.send(lang)`.
Number formatting goes through `ArabicNumerals`. `InfoPlist.strings` stays for OS-facing usage strings.

### 2.8 Prompt building, serialization, windowing
- `PromptBuilder.build(conversation:state:prefs:classification:searchContext:) -> [OutgoingChatMessage]`:
  `[system: PromptCatalog.systemPrompt(...) (+ planSystem / execute note / fileGuidance concatenated into
  the SAME system message)] + [user: searchContext]? + HistoryWindow(previous turns) + last user (with
  `fileText` prepended and `images` attached; follow-up re-attach rule)`. `think = prefs.thinkingEnabled &&
  tier.showThinking && !hasImages`. Tier: explicit search downgrades non-max to `pro`; call three-hop caps at `pro`.
- `MessageSerializer.persisted` emits exactly `role, content, tier, lang, reasoning, cid, files, imageThumbs,
  mode, askAnswered, retryOf, retried, mergedFrom, alts, altAt` (never `images`/`fileText`).
- Job vs stream: job for every persisted chat turn (members with server id, all guests) unless the last
  user message has images or the body exceeds ~550 000 chars → SSE `/api/chat`; 413/404/501 on start → SSE.
  Temporary (ephemeral) chats always stream.
- Windowing: keep the system message + trailing turns while `totalChars ≤ 400 000`; PUT always sends the
  full local array.

### 2.9 Markdown / math / code (decided)
Native block renderer, no packages. `MarkdownDocument.parse` produces `[MDBlock]`; `IncrementalParser`
re-parses only the unsettled tail (last block boundary) during streaming so long answers do not re-layout.
Inline markdown via `AttributedString(markdown:)` after `MathScanner` has replaced math with sentinels.
Display math (`$$…$$`, `\[…\]`) renders in `MathBlockView` (a `WKWebView` island loading bundled KaTeX
+ mhchem from `Resources/KaTeX/`, theme CSS injected, height reported by `evaluateJavaScript`, result cached
by content hash; at most 6 live islands, others show the Unicode fallback until scrolled near). Inline
math uses `TeXUnicode` (parity with the web's `.math-fallback`). Code blocks are native `Text` with
`CodeHighlighter`. Fences route to cards via `FenceRouter`. Links open `SFSafariViewController`; artifact
links (`/api/agent/artifact?…`) open `ArtifactViewer`. This trades exact KaTeX inline parity for a
scroll that never stutters; the owner's Iraqi-student math use case is served by display math being exact.

### 2.10 Plan mode
`PlanCycle` per conversation exactly as `web-plan-mode.md §7`: `PlanPhase` (`none, awaitingAnswers, awaitingApproval,
executing, delivered`), mode snapshotted at cycle start, `AskSpec` parse (also `json` fence), `ApprovalMatcher`
consulted only in `awaitingApproval`, execute turn routes the **origin** request through `RequestClassifier`
(file/image/code/plain), assistant messages stamped `mode`, derive-on-load, never evaluated for Agent/Code/Brain,
paused during a call. The composer's mode pill writes `prefs.responseMode`; the cycle reads its snapshot.

### 2.11 Call engine
Ladder and protocol per `audit-ios-voice.md §D` (adopted verbatim): mint `{voice}` → `openai` transport
(session.created within 12 s, assert persona + semantic VAD, 24 kHz PCM, greeting `response.create`,
captions from transcripts, barge-in `conversation.item.truncate`) → on failure mint `{prefer:"gemini", voice}`
within 90 s → Gemini transport (setupComplete 10 s, tools, cooldowns) → `ThreeHopCall`. Audio graph:
session configured off-main **after** the mint; `setVoiceProcessingEnabled(true)` before reading the input
format; ordered `AsyncStream<Data>` for mic frames; Float32 24 kHz player; `isEnding` latch; observers for
configuration change / route / interruption (`.ended` resumes). Two clocks (hard `max(60 s, maxMs) − 1.5 s`,
idle 45 s). `UIBackgroundModes: audio` keeps the call alive when the user leaves; the screen re-syncs from
controller state on return; ending in the background posts a local notification. Forces `auto`, `think=false`,
tier ≤ `pro` for the three-hop rung; restores at hang-up. Diagnostics `{engine, model, reason}` toast for members.

### 2.12 Dictation and TTS
`DictationRecorder` (AVAudioEngine tap → 16 kHz mono PCM16, 300 s cap, level stream) → `WAVEncoder` →
`DictationController.transcribe(lang:)` (`/api/transcribe`, probe cached per launch, 700 ms / 1 500 B minimum,
503 or offline → `SFSpeechRecognizer` with the dialect's BCP-47, `auto → ar-SA`) → appends to the draft with
one space, never auto-sends; auto-finish on background; `.start/.stop` haptics. Shared by Chat, Agent,
Brain composers. `ListenController` per audit M3; pauses `SongPlayer`; refuses during a call.

---

## 3. Screens — what shows, which store, which endpoints

| Screen | Shows (brief §) | Store(s) | Endpoints |
|---|---|---|---|
| Consent / Landing / MentronX | first-run copy, guest CTA, sign-in | `SessionStore` | `POST /api/guest` |
| Auth / Verification / Forgot | fields, Google, code polling, resend, forgot/reset | `SessionStore` | `auth/login, signup, verify-status, resend-code, forgot, reset, google-native` |
| Sign-up prompt sheet | feature-keyed upsell | `ShellRouter` | — |
| Chat (Firas AI) §7.1 | welcome, transcript, composer, tier pill, mode pill, actions, cards, toasts, error strips | `ChatStore`, `ConversationState`, `JobManager`, `DraftStore` | `chats*`, `chat/job*`, `chat` (SSE), `search`, `fetch`, `share`, `translate`, `chat/job/file` |
| Tier picker §7.4 | four rows + response style | `PreferencesStore` | — |
| Add sheet §7.3.2 | camera/photos/files, tools, dialect | `AttachmentProcessor`, `PreferencesStore` | — |
| Dictation bar §7.14 | waveform, timer, dialect chip | `DictationController` | `transcribe` |
| Code viewer sheet | preview/code segmented | — | — |
| Long-file viewer | pages, progress, export | `ChatStore` | `chat/job/file` (+parts) |
| Sidebar §7.2 | switcher, new chat, search, shelves, history groups, usage, guest slot, account pill, bell | `ChatStore`, `AgentStore`, `CodeStore`, `BrainStore`, `MediaStore`, `JobManager`, `ChatMetaStore` | `chats` (list/put pinned/title/delete), `announcements` |
| Agent §7.8 | mission card, credits chip, templates | `AgentStore`, `JobManager` | `usage/charge`, `chat/job` (agentrun), `agent/job`, `agent/job-stream`, `agent/artifact`, `agent/credits`, `chats*` |
| Code launcher/workspace §7.9 | create card, grid, Files/Code/Preview/AI, build strip, console, diff review | `CodeStore`, `JobManager` | `chat/job` (codebuild), `chat` (SSE edits), `chats*`, `share` |
| Brain §7.10 | ask thread, chips row, library sheet, passage reader, citations | `BrainStore`, `BrainAsker`, `JobManager` | `brain/docs, doc, search, passage, whole`, `chat` (SSE nomem), `chat/job` (brainask), `chats*` |
| Media Studio §7.11 | library grid, create form, viewer, quota | `MediaStore`, `JobManager`, `ChatStore` | `image/job, image/quota, image/edit, image?key`, `video/job, video/quota, video/file`, `music/job, music/file`, `chats*` |
| Call §7.13 | orb, status, captions, controls, consent, retry | `CallEngine` | `live/token`, three-hop: `transcribe`, `chat`, `tts` |
| Settings §7.15 | five sections; memory; announcements; about | `PreferencesStore`, `SessionStore`, `ChatStore` (backup) | `auth/change-*`, `delete-account`, `redeem`, `memory`, `announcements`, `version`, `chats` (backup) |
| Announcements §7.18 | feed + reader | `AnnouncementsStore` (inside `MiscEndpoints` + `ChatMetaStore` seen-ts) | `announcements`, `translate` (members) |
| Shared chat (deep link) | read-only transcript + CTA | — | `share?id=` |

Every error code in `server-*.md` is represented by a row in `QuotaStrings`/`XStrings` and a mapping in the
owning store's `message(for:)`; `signin_required`/`account_required` always open `SignUpPromptSheet(feature)`;
a `quota` object always renders the quota text (guest vs member); plain per-minute 429s render the "slow down"
line; `not_configured` hides the feature for the launch.

---

## 4. Frozen Swift interfaces (foundation)

```swift
// Strings/L.swift
struct L: Sendable, Hashable {
    let ar: String; let en: String
    init(ar: String, en: String)
    func callAsFunction(_ lang: AppLanguage) -> String
    func fmt(_ lang: AppLanguage, _ args: CVarArg...) -> String        // String(format:)
}
enum ArabicPlurals { static func count(_ n: Int, _ lang: AppLanguage, zero: L, one: L, two: L, few: L, many: L, other: L) -> String }

// Core/Networking/APIError.swift
nonisolated struct ServerError: Decodable, Sendable, Equatable {
    var code: String?            // "error"
    var quota: QuotaInfo?; var guest: Bool?; var scope: String?; var feature: String?
    var limit: Int?; var used: Int?; var remaining: Int?; var windowMin: Int?; var freesInMin: Int?
    var activeJob: AgentActiveJob?; var credits: AgentCredits?; var retryRequiresNewCid: Bool?
    var maxPages: Int?; var chars: Int?; var cap: Int?
    var isQuota: Bool { quota != nil }
    var isSignInRequired: Bool { code == "signin_required" || code == "account_required" }
}
nonisolated enum APIError: Error, Sendable {
    case invalidURL, invalidResponse
    case transport(URLError)
    case server(status: Int, error: ServerError)
    case decoding(String)
    var status: Int? { get }; var serverError: ServerError? { get }
    var isUnauthorized: Bool { status == 401 }
}

// Core/Networking/APIClient.swift
nonisolated enum RequestBudget: Sendable { case interactive, poll, stream, upload, download }
nonisolated struct SSEFrame: Sendable { let event: String?; let id: String?; let data: String }
actor APIClient {
    init(configuration: AppConfiguration)
    func get<R: Decodable & Sendable>(_ path: String, query: [String: String] = [:], budget: RequestBudget = .interactive) async throws -> R
    func send<R: Decodable & Sendable, B: Encodable & Sendable>(_ method: HTTPMethod, _ path: String, body: B, budget: RequestBudget = .interactive) async throws -> R
    func sendVoid<B: Encodable & Sendable>(_ method: HTTPMethod, _ path: String, body: B) async throws
    func raw(_ method: HTTPMethod, _ path: String, body: Data?, contentType: String?, budget: RequestBudget) async throws -> (Data, HTTPURLResponse)
    func stream<B: Encodable & Sendable>(_ path: String, body: B) -> AsyncThrowingStream<SSEFrame, Error>
    func streamGET(_ path: String, query: [String: String]) -> AsyncThrowingStream<SSEFrame, Error>
    func downloadToFile(_ path: String, query: [String: String] = [:]) async throws -> (url: URL, filename: String, mime: String?)
}
nonisolated struct FirasAPI: Sendable { let client: APIClient; init(client: APIClient) }   // methods in Endpoints/*

// Core/Models/JobModels.swift
nonisolated enum JobKind: String, Codable, Sendable { case chat, longdoc, longfile, agentrun, codebuild, brainask, image, video, music
    var product: ProductKind { get }; var isChatQueue: Bool { get } }
nonisolated struct JobPointer: Codable, Sendable, Identifiable, Equatable {
    let id: String; let kind: JobKind; let ownerID: String; let cid: String; let product: ProductKind
    var chatID: String?; var conversationID: String; var assistantMessageID: String?
    var projectID: String?; var creationID: String?; var title: String; let startedAt: Date
    var lastPhase: String; var cancelRequested: Bool; var lang: String
}
nonisolated struct JobSnapshot: Sendable, Equatable {
    let pointerID: String; let phase: String; let text: String; let reasoning: String
    let progress: ChatJobProgress?; let surface: AppAPIValue?; let agent: AgentJob?; let mediaKey: String?
}
nonisolated enum JobTerminal: Sendable, Equatable {
    case completed(JobSnapshot)
    case refused(status: Int, error: ServerError)        // quota/rate/auth captured by the worker
    case failed(code: String)                             // engine gave up / brainask_* / codebuild_*
    case cancelled
    case expired                                          // unknown / null / deadline
    case unauthorized, forbidden
}
nonisolated enum JobEvent: Sendable { case progress(JobSnapshot), terminal(pointerID: String, JobTerminal) }

// Core/Jobs/JobManager.swift
@MainActor @Observable final class JobManager {
    init(api: FirasAPI, session: SessionStore, prefs: PreferencesStore, notifications: JobNotifications)
    private(set) var pointers: [JobPointer]
    func activePointers(product: ProductKind? = nil) -> [JobPointer]
    func pointer(forConversation id: String) -> JobPointer?
    func startChatQueueJob(_ request: ChatJobRequest, pointer draft: JobPointer) async throws -> JobPointer
    func startMediaJob(kind: JobKind, request: MediaJobRequest, pointer draft: JobPointer) async throws -> JobPointer
    func attach(_ pointer: JobPointer)
    func reattachAll(oneShot: Bool = false) async
    func cancel(_ pointerID: String) async -> Bool
    func forget(_ pointerID: String)
    func pauseAll(); func resumeAll()
    func events(for pointerID: String) -> AsyncStream<JobEvent>
    var allEvents: AsyncStream<JobEvent> { get }
    func applicationDidBecomeActive(); func applicationDidEnterBackground()
}
nonisolated struct JobKindSpec: Sendable {
    let kind: JobKind; let cadence: [(after: TimeInterval, interval: TimeInterval)]
    let deadline: TimeInterval; let cancelable: Bool; let unknownIsTerminal: Bool
}
enum JobKinds { static func spec(_ kind: JobKind) -> JobKindSpec }

// Core/Jobs/CompletionCue.swift
@MainActor enum CompletionCue {
    static func prepare()
    static func fire(key: String, success: Bool, prefs: PreferencesStore) async   // returns after ≈300 ms; no-op if consumed/inactive
}
// Core/Jobs/JobNotifications.swift
@MainActor final class JobNotifications {
    func requestPermissionIfNeeded(explainer: Bool) async -> Bool
    func post(pointer: JobPointer, terminal: JobTerminal, lang: AppLanguage)
    func postCallEnded(reason: L, lang: AppLanguage)
    var onDestination: ((NotificationDestination) -> Void)?
}

// Core/Session/SessionStore.swift
@MainActor @Observable final class SessionStore {
    nonisolated enum Phase: Equatable, Sendable { case restoring, offline, guest, awaitingVerification(pid: String, email: String), authenticated, signedOut }
    private(set) var phase: Phase; private(set) var user: User?; private(set) var guestID: String?
    var identityID: String? { get }; var isAuthenticated: Bool { get }; var isGuest: Bool { get }
    var errorMessage: L?
    var onGuestBecameMember: ((_ previousGuestID: String) -> Void)?
    func restore() async
    func applicationDidBecomeActive() async
    func handleUnauthorized()
    func login(email: String, password: String) async
    func signup(name: String, email: String, password: String) async
    func pollVerification() async -> Bool
    func resendVerification() async
    func verifySignup(token: String) async
    func forgotPassword(email: String) async -> Bool
    func resetPassword(uid: String, token: String, password: String) async -> Bool
    func signInWithGoogle(using provider: GoogleOAuthProvider) async
    func continueAsGuest() async
    func logout() async
    func refreshAccount() async
    func changeEmail(currentPassword: String, newEmail: String) async -> Bool
    func changePassword(currentPassword: String, newPassword: String) async -> Bool
    func deleteAccount(currentPassword: String) async -> Bool
    func redeem(code: String) async -> Bool
}

// DesignSystem/FirasGlass.swift
enum FirasGlass { enum Level { case chrome, floating, sheet } }
extension View {
    func firasGlass(_ level: FirasGlass.Level, in shape: AnyShape = AnyShape(Capsule())) -> some View
    func surfaceCard(radius: CGFloat = 9) -> some View
    func bidiIsland(for text: String, fallback lang: AppLanguage) -> some View
    func forceLTR() -> some View
    func readingColumn() -> some View
}
enum FirasMotion { static let standard, sheet, composer, tierPop, reveal: Animation; static let drawerFlick: Animation }
@MainActor enum FirasHaptics { static func send(); static func stop(); static func select(); static func attach(); static func toolStep(); static func error(); static func undo(); static func callConnected(); static func recordStart(); static func recordStop(); static func prepareCompletion() }
@MainActor final class FirasSound { static let shared: FirasSound; func play(_ s: Sound, prefs: PreferencesStore); enum Sound { case send, done } }
@MainActor final class ToastCenter: Observable { func show(_ text: String, action: (title: String, run: () -> Void)? = nil, duration: TimeInterval = 3.2) }

// Core/Text/BidiDirection.swift
nonisolated enum BidiDirection { static func firstStrong(_ s: String) -> LayoutDirection?; static func isArabicDominant(_ s: String) -> Bool }
nonisolated enum ArabicNumerals { static func count(_ n: Int, _ lang: AppLanguage) -> String; static func timer(_ seconds: Int) -> String /* LTR "m:ss" */ }

// Core/Prompting
nonisolated enum RequestKind: Sendable, Equatable { case chat, code, file(format: String, explicitPages: Int?), image, imageEdit, video, music, longdoc, longfile(format: String, pages: Int), irab }
nonisolated enum RequestClassifier { static func classify(_ text: String, hasImages: Bool, lang: AppLanguage) -> RequestKind }
nonisolated struct PromptInput: Sendable { let tier: ModelTier; let product: ProductKind; let mode: ResponseMode; let lang: AppLanguage; let think: Bool; let kind: RequestKind; let planPhase: PlanPhase; let searchContext: String?; let history: [ChatMessage]; let lastUser: ChatMessage }
nonisolated enum PromptBuilder { static func build(_ input: PromptInput) -> (messages: [OutgoingChatMessage], tier: ModelTier, think: Bool) }
nonisolated enum SearchContextBuilder {
    enum Trigger { case none, silent, explicit }
    static func trigger(for text: String, toggleOn: Bool, hasImages: Bool) -> Trigger
    static func query(from text: String) -> String                     // ≤280
    static func format(_ results: [WebSearchResult], lang: AppLanguage) -> String
    static func noResultsNote(_ lang: AppLanguage) -> String
}
nonisolated enum MessageSerializer { static func outgoing(_ m: ChatMessage, reattachImages: [String]?) -> OutgoingChatMessage; static func persisted(_ m: ChatMessage) -> PersistedChatMessage }
nonisolated enum HistoryWindow { static func window(_ history: [ChatMessage], budgetChars: Int = 400_000) -> (kept: [ChatMessage], trimmed: Bool) }
nonisolated enum EngineFailureDetector { static func isFailure(_ answer: String) -> Bool }
nonisolated enum ResponseMode: String, Codable, Sendable { case auto, plan }
nonisolated enum PlanPhase: Equatable, Sendable { case none, awaitingAnswers(askMessageID: String), awaitingApproval(planMessageID: String), executing(originID: String), delivered(originID: String) }
nonisolated struct PlanCycle: Sendable, Equatable {
    var phase: PlanPhase; var snapshotMode: ResponseMode; var askRounds: Int
    mutating func userSent(_ m: ChatMessage, liveMode: ResponseMode) -> PlanTurnKind      // .clarifyOrPlan / .execute(origin) / .revision / .auto
    mutating func assistantFinished(_ m: ChatMessage, ask: AskSpec?)
    static func derive(from messages: [ChatMessage]) -> PlanCycle
}
nonisolated struct AskSpec: Codable, Sendable, Equatable { struct Question: Codable, Sendable, Equatable { let id: String; let text: String; let options: [Option]; let multi: Bool; let recommended: [String] }; struct Option: Codable, Sendable, Equatable { let id: String; let label: String }; let questions: [Question]
    static func parse(_ markdown: String) -> AskSpec?; func summary(answers: [String: [String]], extra: String, lang: AppLanguage) -> String }
nonisolated enum ApprovalMatcher { static func isApproval(_ text: String) -> Bool }

// Core/Markdown
nonisolated indirect enum MDBlock: Sendable, Equatable, Identifiable { case paragraph(AttributedString), heading(level: Int, AttributedString), list(ordered: Bool, items: [[MDBlock]]), quote([MDBlock]), table(header: [AttributedString], rows: [[AttributedString]]), code(lang: String?, String), rule, mathDisplay(String), fence(FirasFence), raw(String); var id: String { get } }
nonisolated struct MarkdownDocument: Sendable, Equatable { let blocks: [MDBlock]; static func parse(_ markdown: String, lang: AppLanguage) -> MarkdownDocument }
nonisolated struct IncrementalParser: Sendable { init(lang: AppLanguage); mutating func append(_ full: String) -> (settled: [MDBlock], tail: String) }
nonisolated enum FirasFence: Sendable, Equatable { case code(CodeMeta, String), file(FileMeta), image(MediaMeta), video(MediaMeta), music(MediaMeta), agent(AgentJob), project(CodeProject), ask(AskSpec), sources([BrainSource]), plot(String)
    static func parse(name: String, body: String) -> FirasFence? }

// Features/Chat
@MainActor @Observable final class ChatStore {
    init(api: FirasAPI, session: SessionStore, jobs: JobManager, prefs: PreferencesStore, drafts: DraftStore, guestStore: GuestChatStore, toasts: ToastCenter)
    private(set) var summaries: [ChatSummary]; private(set) var conversations: [String: ChatConversation]
    private(set) var states: [String: ConversationState]
    var selectedID: String?
    func loadConversations() async; func open(_ id: String) async; func newConversation(product: ProductKind) -> String
    func send(text: String, attachments: [PreparedAttachment], in conversationID: String) async
    func stop(in conversationID: String) async
    func regenerate(messageID: String, in id: String, tier: ModelTier?) async
    func continueAnswer(messageID: String, in id: String) async
    func submitAsk(answers: [String: [String]], extra: String, askMessageID: String, in id: String) async
    func approvePlan(in id: String) async
    func rename(_ id: String, title: String) async; func pin(_ id: String, _ pinned: Bool) async; func delete(_ id: String) async   // 7 s undo inside
    func share(conversationID: String, messageCID: String?) async -> URL?
    func applicationDidBecomeActive() async
}
@MainActor @Observable final class ConversationState {
    enum Phase: Equatable { case idle, searching, thinking, streaming, completing, failed(L) }
    var phase: Phase; var jobPointerID: String?; var plan: PlanCycle; var liveText: String; var liveReasoning: String
    var errorStrip: L?; var outbox: String?; var isAtBottom: Bool
}
```

Other stores follow the same shape (`@MainActor @Observable final class XStore`, `init(api:session:jobs:prefs:toasts:)`,
`func applicationDidBecomeActive() async`, `func message(for: Error) -> L`). Their method lists are the
screen rows of §3; they are not frozen here because they do not cross owner boundaries.

---

## 5. Implementation batches

**Batch 0 — foundation (must exist first; 5 owners, ~3 CI cycles).**
1. `Strings/L.swift` + `CommonStrings`, `QuotaStrings`, `NotificationStrings`; `Core/Text/*`. (owner 1)
2. `Core/Networking/*` incl. all `Endpoints/*` against the frozen signatures; `Core/Models/*` additions. (owner 2)
3. `Core/Session/*`. (owner 3)
4. `Core/Jobs/*` incl. `BackgroundRefresh`, `JobNotifications`, `CompletionCue`; `Core/Storage/*`. (owner 4)
5. `DesignSystem/*` (`FirasTheme` derived tokens, `FirasGlass`, motion, type, haptics, sound, cards, toast) +
   `App/*` + `Features/Shell/*` skeleton (router, shell, drawer, sidebar with placeholder detail). (owner 5)
   Batch 0 also deletes the files listed in §1 and lands `Info.plist` changes. The build must be green with
   the old feature screens temporarily replaced by placeholders — this is the one batch that cannot run in
   parallel with anything.

**Batch 1 — chat core (parallel, 8 owners, after batch 0 compiles).**
6. `Core/Prompting/*` (except PlanCycle/AskSpec/Approval) + `AutoTitle`. 7. `Core/Markdown/*` + `MathBlockView` +
KaTeX resources. 8. `ChatStore` + `ConversationState` + `SendPipeline`. 9. `ChatScreen`, `TranscriptView`, `WelcomeView`,
`TierPill/Picker`, `ModePill`. 10. `Composer/*` + `AddSheet` + `AttachmentProcessor` fixes. 11. `Messages/*` +
`Cards/*` (image/video/song cards consume `MediaAssetRepository`). 12. `PlanCycle`, `AskSpec`, `ApprovalMatcher`,
`AskPanelView`, `PlanStartPill`. 13. `Voice/Dictation*`, `DialectPickerSheet`, `ListenController`, `DictationBar`.

**Batch 2 — products (parallel, 7 owners).**
14. Agent (`AgentStore`, `MissionCard`, `MissionTimeline`, `MissionFiles`, `ArtifactViewer`, `CreditsSheet`, `AgentJobStream`).
15. Code store + launcher + workspace shell + `CodeProjectRepository`. 16. `CodeEditorView`, `CodeEditorTheme`, `FileNavigator`,
`CodeExport`. 17. `PreviewWebView`, `ConsoleView`, `CodeAIBar`, `CodeAskAI`, `DiffReviewSheet`. 18. Brain (store, asker,
screen, library, chips, passage, import pipeline, extractor fixes). 19. Media (store, studio, grid, form, viewer, pipeline,
song player). 20. Call (`CallEngine`, transports, audio graph, echo guard, three-hop, `CallScreen`, `OrbView`).

**Batch 3 — polish (parallel, any free owner).** Settings pages, Memory, Announcements, Share/Export controllers,
`SharedChatView`, `KeyboardCommands`, Onboarding/Auth screens, `LongFileViewer`, `CodeViewerSheet`, iPad layouts, hover effects.

Rule for every batch: an owner may only edit files they own plus their feature's `XStrings.swift`; shared
files (`FirasTheme`, `APIError`, `JobModels`, `FenceModels`) change only through the batch-0 owner with a
one-line request. Each batch ends with one CI run; a red run is fixed by the owner of the failing file only.

---

## 6. Compile-risk rules (each one has cost a cycle somewhere)

1. Every `View`, `App`, store and controller that touches UI state is explicitly `@MainActor` or a `View`.
   Never rely on inference; never mark a model or enum `@MainActor` (drop the two on `ModelTier`).
2. `nonisolated` on types is allowed (SE-0449, Xcode 26). Do **not** use `@concurrent`, `nonisolated(nonsending)`,
   `sending`, `~Copyable`, macros, or `#Preview` blocks (previews are compiled on CI; one bad preview is a red build).
3. Top-level and default argument values must be nonisolated (`ISOLATED_DEFAULT_VALUES=YES` makes a
   `@MainActor` default an error at nonisolated call sites): no `= PreferencesStore()` defaults; pass explicitly.
4. iOS 26 API only inside `if #available(iOS 26, *)` and only in `FirasGlass`, `AppShell`, `ChatScreen` (safeAreaBar,
   scrollEdgeEffect, navigationSubtitle), `CodeWorkspaceView`/`MediaStudioScreen` (tabBarMinimizeBehavior,
   tabViewBottomAccessory), `CallControls`/`ComposerView` (`GlassEffectContainer`). Everything else uses iOS 18 API.
   `Glass.clear` existence is unverified on the runner: `FirasGlass` wraps it in one function so a failure is a
   one-line fix (`.regular` untinted).
5. No new SwiftPM packages. ZIPFoundation stays pinned; `Package.resolved` untouched.
6. `Codable` models: all server-optional fields `Optional`; no `enum` without a lenient decoder; no `Date` decoding
   strategies (server sends strings/ms numbers); test-by-reading against the contract tables.
7. Avoid generic gymnastics: no `some View` returned from `if #available` branches without `@ViewBuilder`; no
   `AnyShape` except through `FirasGlass`'s parameter; no `Result` builders of our own.
8. `Task {}` inside stores inherits `@MainActor`; heavy work goes to `Task.detached` and returns values — never
   touch `@Observable` state from the detached body.
9. `UIViewRepresentable` coordinators are `@MainActor` classes; delegate methods that the SDK declares nonisolated
   (ASWebAuthentication, WKScriptMessageHandler, AVAudioNodeTapBlock) use `MainActor.assumeIsolated` or hop with `Task { @MainActor in }`.
10. `String(format:)` with `Int` uses `%ld`; `Duration` range patterns are avoided (plain comparisons).
11. Every file compiles alone: no cross-file `private`, no `fileprivate` extensions relied on elsewhere, no
    file-scope `let` that depends on another file's initialisation order.
12. Names are unique across the target (synchronized group = one module): prefix helper types with the feature
    (`CodeEditorTheme`, `MediaViewer`, `BrainSourceRow`) — batch 0 deletes old files precisely to avoid duplicates.

---

## 7. What is left out, and why

- **Bottom tab bar on iPhone** (audit F6) — the brief's Claude-shaped drawer wins; a real tab bar would
  demote the chat and duplicate the product switcher.
- **RTL-mirrored shell** (audit F10) — fixed LTR + bidi islands is the web's contract and the brief's decision 2.
- **APNs, App Groups, CallKit, iCloud, associated domains** — impossible without a team. Consequences accepted:
  notifications arrive via BG refresh (minutes, not seconds) or the 30 s grace; the call does not survive an
  incoming cellular call; `?verify/?reset/?share` links only work through the custom URL scheme when the web
  pages add it — until then the app shows the manual paths (verification polling, forgot sheet, paste-a-link).
- **Sign in with Apple** — needs an entitlement and a server route; deferred until a team exists.
- **Server long-poll (`wait=1`) for background `URLSession` delivery** — the strongest push-less design, but it is
  a server change and this plan is client-only; noted for the owner.
- **Exact inline KaTeX parity** — inline math uses Unicode fallback; display math is exact. No `\ce{}` inline.
- **Python run, "Firas Computer", steering, save-as-template, fix-what's-left, per-chat tier pin, folders UI** —
  low value natively or no server API; folders/tags kept as data only.
- **Web's ~40 k-char system prompt trimmed or not** — not decided here; `PromptCatalog` is the other agent's
  file and `PromptBuilder` sends whatever it returns.
- **Any redesign of server contracts** — the app matches `server-*.md` as-is, including the quirks (media `running`
  forever, agent cancel is cosmetic, `remaining` = 0 during a mission, `nomem` internal budget for guests).
