# Audit — Shell + Settings + Design system + Notifications (iOS)

Scope: `ios/FirasAI/Features/Shell/*`, `Features/Settings/*`, `Models/SettingsModels.swift`,
`DesignSystem/*`, `Notifications/*`, `App/FirasAIApp.swift` (read for context), `Resources/Info.plist`,
`FirasAI.entitlements`, `FirasAI.xcodeproj/project.pbxproj`, `Resources/Assets.xcassets`, the CI
workflow `.github/workflows/build-ios-ipa.yml`, and the server handlers these files call
(`server.mjs` router 13700-13860, `handlePushRegister/Unregister` 1455-1489,
`notifyDurableJobTerminal` 1627-1641, `handleChangeEmail` 2277, `handleChangePassword` 2257,
`handleDeleteAccount` 2315, `handleCreateChat`, `subInfo`). Contract docs consulted:
`Docs/server-misc.md` §14-15, `Docs/web-chat-ux.md` §2, §3.3, §6, §11, §14, §16.

Build context (verified in `project.pbxproj:291-293`): `SWIFT_VERSION = 5.0`,
`SWIFT_STRICT_CONCURRENCY = minimal`, no `SWIFT_DEFAULT_ACTOR_ISOLATION` (so default is
nonisolated), `IPHONEOS_DEPLOYMENT_TARGET = 18.0`, `TARGETED_DEVICE_FAMILY = "1,2"`,
`CODE_SIGN_ENTITLEMENTS = FirasAI/FirasAI.entitlements` (file is an empty dict — APNs removed on
purpose). CI builds unsigned on `macos-26` with `CODE_SIGNING_ALLOWED=NO`; the owner re-signs with a
free 7-day certificate. `PREVIOUS-BUILD.sha256` proves at least one green build with this tree.

Every finding below is stated as file:line · severity · category, then evidence, then the fix.

---

## 0. Executive summary

1. **Nothing can notify the user after they leave the app.** APNs is gone (correct decision — no
   paid team), but the replacement is a "local fallback" that only fires if the polling loop
   happens to observe completion while the process is still alive in the background. There is no
   `UIBackgroundModes`, no `beginBackgroundTask`, no `BGTaskScheduler`, no background `URLSession`.
   iOS suspends the app seconds after it leaves the foreground, so for any job longer than that
   grace the notification never arrives until the app is reopened. The owner's "notification when
   a job finishes" requirement is unmet by design, and the Settings copy promises the opposite.
2. **The code still tries to register with APNs**, so the moment a user enables notifications iOS
   returns "no valid aps-environment entitlement" and Settings paints a red error banner under the
   notifications panel, on every launch after sign-in.
3. **The voice call ends whenever the app backgrounds**: `Info.plist` has no `audio` background
   mode and `VoiceCallView` explicitly ends the call on `didEnterBackgroundNotification`. That is
   the mechanical cause of "the call kicks the user out".
4. **The completion cue withholds every finished result for 3 seconds** in the foreground
   (`FirasCompletionCue.prepareForReveal`), and has no sound at all; sound exists only inside the
   (currently unreachable) background notification. README's "sound + haptic before the reveal" is
   not what the code does.
5. **Glass is used on the wrong layer.** 44 `GlassSurface` call sites put Liquid Glass on content
   cards (settings panels, usage counters nested inside panels, activity pills, selected sidebar
   rows) stacked over a flat gradient. Glass over a flat colour reads as a frosted grey rectangle —
   that is why it "is not transparent enough". Meanwhile the one layer Apple intends glass for —
   the navigation bar — is explicitly hidden (`.toolbarBackground(.hidden)`) on every screen.
6. **Navigation is a hand-rolled iPhone drawer**, with no edge-swipe, no tab bar, and a "Recent"
   list whose rows do nothing on Agent/Code/Brain (they load into `ChatStore`, which those screens
   do not render). iPad uses `NavigationSplitView` correctly but with a custom sidebar button
   scheme that may double the system toggle.
7. **Themes are a faithful port** — all 6 × 16 tokens match `styles.css` exactly. Settings covers
   the web's five tabs. Account/security/backup flows match the server contract. These files are
   keepable with fixes.
8. Swift-5-mode risk is low in this group (every store/coordinator is explicitly `@MainActor`,
   views are MainActor via the `View` protocol). One `@concurrent` attribute is redundant and
   worth removing to avoid a CI cycle.

---

## 1. Inventory — what the group implements today

### Shell (`FirasAppShell.swift`, `ShellSidebar.swift`, `ShellStrings.swift`, `Shell.xcstrings`)
- Root switches on `horizontalSizeClass`: regular → `NavigationSplitView(columnVisibility:)` with
  `ShellSidebar` (270-360 pt, `.balanced`) + `detailView`; compact → `ZStack` of the detail plus a
  hand-rolled overlay drawer (scrim `Button` + `ShellSidebar` at `min(360, width-44)`, `.move(edge:
  .leading)` transition, `.snappy(0.30)`).
- `detailView` switches `ProductKind` (`ai`, `agent`, `code`, `brain`) to `ChatScreen`,
  `AgentScreen`, `CodeScreen`, `BrainScreen`, each of which owns its own `NavigationStack`.
- Sheets: `.settings` → `SettingsView`, `.authentication` → `AuthView`; `fullScreenCover` →
  `VoiceCallView`; `MentronXEntryView` overlay after auth/guest entry.
- Environment: `.tint(palette.accent)`, `.preferredColorScheme(theme.isLight ? .light : .dark)`,
  `.environment(\.locale, language.locale)`, **`.environment(\.layoutDirection, .leftToRight)`**
  (the whole shell is forced LTR; children re-apply RTL piecemeal — 30+ sites).
- Tasks: `session.restore()` once; `chatStore.loadConversations()` on identity change; notification
  routing on `pendingDestination` change (`routePendingNotification`).
- Sidebar: brand lockup + New chat + close; search field (title filter only); `List(.sidebar)` with
  Products section (4 rows) and Recent section (conversations filtered by product flags, swipe-to-
  delete without confirmation or undo); account footer (name/Guest, opens `AuthView`) + gear.
- Strings: `Shell.xcstrings` (en/ar) complete for every key `ShellStrings` uses.

### Settings (`SettingsView.swift`, `AccountSettingsView.swift`, `DataSettingsView.swift`, `PreferenceSettingsViews.swift`)
- `SettingsView`: regular → `NavigationSplitView` (list of 5 destinations + detail); compact →
  `TabView` with 5 tabs, each a `NavigationStack`. `.presentationSizing(.page)`. Re-applies theme,
  locale, and **language-based** layout direction.
- Destinations: Account, Appearance, Chat, Voice, Data — the same five tabs as the web.
- Account: identity panel (initial avatar, name, admin pill, email LTR, refresh spinner), plan panel
  (plan icon/name, days left, 4 usage counters with progress), security panel (change email, change
  password, sign out), danger panel (delete account). Sheets for change email / change password /
  delete (password optional, double-confirm alert). Guest → sign-in CTA. `.refreshable` →
  `session.refreshAccount()`.
- Appearance: 6-theme grid (`ThemeCell` swatch = ground/accent/surface/text dots, matches the web's
  swatch idea), text size (sm/md/lg), reading width (normal/wide), language (ar/en), motion
  (full/reduced). Accessibility sizes swap segmented pickers for vertical lists.
- Chat: default tier grid (mini/pro/ultra/max), thinking, web search, send-on-return, sharpen images.
- Voice: call voice menu (cedar/ash/verse/echo/ballad — matches `CALL_VOICES`), dictation dialect
  (auto/arabic/english — the web has 14).
- Data: export/import JSON backup (`fileExporter` / `fileImporter`, web-compatible `{app, format,
  exportedAt, chats}`), clear device preferences (confirmation), notifications panel (status +
  enable/open-settings + error banner), About (version, hardcoded 3-row "What's new" sheet),
  "local only" note.
- Shared components: `SettingsGlassStack` (`GlassEffectContainer(spacing: 16)` on iOS 26),
  `SettingsPanel` (GlassSurface r=24 tint 0.055), `SettingsToggleRow`, `SettingsValueRow`,
  `SettingsDivider`, `SettingsNoticeBanner`, `SettingsSubmitButton` (`.glassProminent`/`.glass` on
  26, bordered fallbacks), `LocalPreferencesNote`.

### Models (`SettingsModels.swift`, `ChatBackupDocument.swift`)
- Account request/response structs for `/api/auth/change-email` (`{current,email}` →
  `{ok,user}`), `/api/auth/change-password` (`{current,password}`), `/api/auth/delete-account`
  (`{current}`) — field names verified against `server.mjs:2257-2330`.
- `FirasChatBackup` (format 1, ≤50 MB, ≤500 chats, per-chat ≤2000 user/assistant messages, strings
  clipped) + `FirasChatBackupEntry` + `ChatMessage.sanitizedForImport`.
- `FirasChatBackupDocument: FileDocument` (pretty JSON) and `ChatBackupFileReader.read` (security-
  scoped, size-checked, `@concurrent`).

### Design system (`FirasTheme.swift`, `GlassSurface.swift`, `FirasCompletionCue.swift`, `FirasActivityLabel.swift`, `MentronXEntryView.swift`, `FirasBrandMark.swift`)
- `FirasTheme` × 6 with `FirasPalette` (16 tokens) — hex-for-hex identical to `styles.css`
  11-391 (verified all six blocks). `AppLanguage`, `FontScale` (0.92/1/1.10 — **factor is never
  applied anywhere**), `ContentWidth` (760/980, applied on 5 screens), `MotionPreference`,
  `CallVoice`, `DictationDialect`. `PreferencesStore` (`@MainActor @Observable`, UserDefaults keys
  `theme, lang, tier, fontSize, width, webSearch, thinking, motion, enterSend, imageSharpening,
  callVoice, dictationLanguage`), defaults dark / **Arabic regardless of device locale** / pro.
- `GlassSurface`: iOS 26 → `.glassEffect(.regular.tint(accent.opacity(t)), in: .rect(r))`;
  else `.ultraThinMaterial` + hairline; Reduce Transparency → flat surface. `GlassIconButton`
  (unused, 0 call sites). `FirasBackground`: flat bg + radial accent glow + vertical gradient.
- `FirasCompletionCue.prepareForReveal`: foreground-only; dedupes by `product:job` in UserDefaults
  (256 entries); skipped under Reduce Motion; soft impact 0.32 → 160 ms → 0.48 → **3 s sleep** →
  returns. No sound.
- `FirasActivityLabel`: icon + shimmering text on a 30 fps `TimelineView` (thinking/writing/
  searching/building).
- `MentronXEntryView`: ~3.9 s stroke animation of the MentronX mark + "BY MentronX", played on
  every auth/guest entry.
- `FirasBrandMark`: Canvas "F" mark (32×44 design grid) + "Firas AI" wordmark.

### Notifications (`NotificationCoordinator.swift`, `PushRegistrationClient.swift`, `FirasAppDelegate.swift`)
- `NotificationCoordinator.shared` (`@MainActor @Observable`): permission tracking, APNs token
  persistence/registration against `/api/push/register|unregister` (`PushRegistrationClient`, own
  `URLSession` sharing the cookie jar), notification category `FIRAS_JOB_COMPLETE`, tap routing
  (`NotificationDestination` decoded from `userInfo.firas.*` — same shape as the server payload in
  `server-misc.md §15.4`), and `scheduleLocalFallbackIfNeeded` (local `UNNotificationRequest`, sound
  `FirasComplete.wav`, thread id, hard-coded ar/en copy). Permission is requested only after a
  durable job is accepted (`ChatStore:455`, `AgentStore:397`, `CodeStore:542`,
  `MediaStudioStore:339`) or from Settings.
- `FirasAppDelegate`: sets `UNUserNotificationCenter.delegate`, forwards APNs callbacks, presents
  foreground banners `[.banner, .list, .sound]`.

### Resources / project
- `Info.plist`: display name, Google OAuth URL scheme, `FIRAS_API_BASE_URL`, ATS local networking,
  camera/mic/photo usage strings (localized via `en.lproj`/`ar.lproj/InfoPlist.strings`),
  `UILaunchScreen` = colour only (`LaunchBackground` #1F2024), orientations. **No**
  `UIBackgroundModes`, `BGTaskSchedulerPermittedIdentifiers`, `UIApplicationSceneManifest`,
  `ITSAppUsesNonExemptEncryption`, `NSSpeechRecognitionUsageDescription`.
- Assets: `AppIcon` (1024 light/dark/tinted PNGs, RGB no alpha, generated by
  `tools/generate_assets.py` — a flat "F" on #14201D), `AccentColor` (#57AE9C), `LaunchBackground`.
  `FirasComplete.wav` (16-bit mono 44.1 kHz PCM, 104 KB) at `Resources/` root; `Resources/Sounds/`
  is an empty untracked directory.
- `project.pbxproj`: single target, `PBXFileSystemSynchronizedRootGroup` = `FirasAI/` with
  membership exceptions for `FirasAI.entitlements` and `Resources/Info.plist` (correct — otherwise
  Info.plist would be copied as a resource), ZIPFoundation 0.9.20, `objectVersion = 77`.
  `ExportOptions.plist` still says `app-store-connect` (dead: the pipeline is unsigned + sideload).

---

## 2. Findings

### 2.1 Critical

**F1 · `Notifications/NotificationCoordinator.swift:191`, `:303` · critical · background-cloud-first / ux**
Evidence: `UIApplication.shared.registerForRemoteNotifications()` is called from
`requestAuthorizationIfNeeded` (Settings "Enable notifications", and after every durable job start)
and from `refreshPermissionAndRegisterIfPossible` (every `sessionDidAuthenticate`, i.e. every
launch and sign-in). `FirasAI.entitlements` is `{}`. Without `aps-environment` iOS calls
`application(_:didFailToRegisterForRemoteNotificationsWithError:)` with "no valid 'aps-environment'
entitlement string found for application"; `FirasAppDelegate.swift:27` forwards it to
`didFailToRegisterForRemoteNotifications` → `registrationError = error.localizedDescription` →
`DataSettingsView.swift:93-95` renders it as a red `SettingsNoticeBanner`. Result: a permanent
error banner under Notifications for every signed-in user, in English regardless of language.
Fix: delete the APNs path — `deviceToken`, `registrationTask`, `registerCurrentTokenIfPossible`,
`unregisterCurrentDevice`, `didRegister/didFail…`, `PushRegistrationClient.swift` entirely, the
two `UIApplicationDelegate` callbacks, and the `hasConfirmedRemoteRegistration` gate (now always
false, so it is dead weight). If you want to keep the code for a future paid team, wrap it in
`#if FIRAS_APNS` and never call `registerForRemoteNotifications()` unless the flag is on.

**F2 · `Notifications/NotificationCoordinator.swift:238-282` + `Resources/Info.plist` (no `UIBackgroundModes`) · critical · background-cloud-first**
Evidence: the only path that produces a "job finished" notification is
`scheduleLocalFallbackIfNeeded`, called from each store's `finish` when its polling loop observes a
terminal phase (`ChatStore:743`, `AgentStore:302`, `CodeStore:466/490`, `MediaStudioStore:468/538`).
It guards `applicationState != .active`. But nothing keeps the process alive after the user leaves:
no `UIApplication.beginBackgroundTask`, no `BGTaskScheduler` (grep across `FirasAI/` finds none),
no `URLSessionConfiguration.background`, no `UIBackgroundModes`. iOS suspends the app within a few
seconds of `didEnterBackground`; the poll `Task.sleep` simply pauses. Therefore: a 5-minute agent
mission, a code build, or a video job started before the user switches apps produces **no
notification** — the user finds out only when they reopen Firas. The Settings footer
(`settings.notifications.footer`: "Firas keeps server jobs running after you leave and alerts you
with the Firas sound when results are ready") promises exactly this and is currently untrue on
the client side (server jobs do keep running — that part is fine).
Fix (layered, cheapest first):
1. Wrap every store's polling loop in `UIApplication.shared.beginBackgroundTask(withName:)` /
   `endBackgroundTask` while a job pointer exists. Buys ~30 s (iOS-dependent) — enough for most chat
   answers and image jobs; also lets `scheduleLocalFallbackIfNeeded` actually run.
2. Add `UIBackgroundModes: [fetch, processing]` and `BGTaskSchedulerPermittedIdentifiers:
   ["org.firasai.FirasAI.jobs"]` to `Info.plist`; register a `BGAppRefreshTask` in
   `FirasAppDelegate.didFinishLaunching`; on `didEnterBackground` with any persisted job pointer,
   `BGTaskScheduler.shared.submit(BGAppRefreshTaskRequest(...earliestBeginDate: now+60s))`. The
   handler polls `GET /api/chat/job?id=` / `/api/agent/job?id=` / media `*/job?id=` once per
   pointer, posts the local notification for terminal ones, and resubmits. iOS decides timing
   (often 15 min+, tuned by usage) — imperfect but it is the only sanctioned wake-up without APNs.
3. Strongest without APNs: a background `URLSession` download task per job against a **long-poll**
   variant of the status route (server change: `GET /api/chat/job?id=…&wait=1` holds the response
   up to ~25 s or until terminal, then the server-side job loop already exists — see
   `handleChatJobStatus`). The system wakes the app on completion of each download regardless of
   suspension; the delegate re-issues the next long-poll and posts the local notification on
   terminal. This is how mail clients get near-real-time delivery without push. It needs one small
   server addition (README's "no web file changed" would have to bend for `server.mjs`).
4. Whatever the transport, remove the false-promise footer copy until it is true, and post the
   local notification with the server's verbatim copy table (§15.4) so both paths read identically.

**F3 · `Resources/Info.plist` (no `UIBackgroundModes: audio`) + `Features/Chat/VoiceCallView.swift:63-65` · critical · background-cloud-first / ux ("the call kicks the user out")**
Evidence: `LiveVoiceController.configureAudioSession()` sets `.playAndRecord`/`.voiceChat` but the
plist declares no `audio` background mode, so the audio session is suspended the moment the app
backgrounds or the screen locks. `VoiceCallView` additionally subscribes to
`UIApplication.didEnterBackgroundNotification` and calls `controller.handleInterruption()` which is
`await end()` (`LiveVoiceController`) — the call is torn down deliberately on any background
transition (notification banner tap, control-centre, incoming iMessage reply, screen lock). The
user returns to a dead call screen.
Fix: add `<key>UIBackgroundModes</key><array><string>audio</string></array>`; delete the
`didEnterBackground` → `end()` handler; keep the `AVAudioSession.interruptionNotification` handler
but handle `.ended` with `.shouldResume` by restarting the engine instead of ending; keep the
WebSocket alive (it will, under the audio mode). The "app freezes" half of the complaint is inside
`LiveVoiceController` (voice group) — this group only owns the plist and the view's lifecycle hooks.

### 2.2 Major

**F4 · `DesignSystem/FirasCompletionCue.swift:53-58` · major · ux (completion cue)**
Evidence: after the two haptic pulses the function sleeps **3 s** (`Task.sleep(for: .seconds(3))`)
before returning, and every store `guard await FirasCompletionCue.prepareForReveal(...)` before it
applies the terminal state (`ChatStore.finish:721`, `AgentStore:291`, `CodeStore:446/482`,
`MediaStudioStore:453`). A finished chat answer, agent mission, code build or media file is held
back three seconds in the foreground. There is no sound in the foreground; `FirasComplete.wav` is
referenced only by `UNNotificationSound` (background, and per F2 practically unreachable). The
"sound + haptic before the final reveal" in README.md:29-30 is inaccurate. Also
`UIAccessibility.isReduceMotionEnabled` (line 35) suppresses haptics entirely — Reduce Motion is
not a haptics preference and Claude's app fires haptics regardless.
Fix: the Claude-style cue is "one soft haptic as the last token lands, then the result". Replace
the two-pulse + 3 s choreography with: `prepare()` when the poll sees `phase.isTerminal`, a single
`.impactOccurred(intensity: 0.5)` (or `.notificationOccurred(.success)` for long jobs), then reveal
immediately. If a foreground sound is wanted, play `FirasComplete.wav` through `AVAudioPlayer`
with `.ambient` category and honour the ringer switch; order = haptic first, sound in the same
frame, reveal at once. Drop the Reduce Motion gate; keep the `applicationState == .active` gate
and the dedupe history.

**F5 · `DesignSystem/GlassSurface.swift:349-356` (and its 44 call sites) · major · visual-design (glass "not transparent enough")**
Evidence: glass is applied as the *background of content cards*: every `SettingsPanel`, every
`UsageCounter` (nested inside a `SettingsPanel` → glass inside glass, which Apple's HIG explicitly
says not to do), `FirasActivityLabel`, `SidebarSelectionSurface` (glass inside a `List` row),
`MediaStudioScreen.creationCard`, sheets in `AccountSettingsView` (r=24 tint 0.06). Everything sits
on `FirasBackground`, a flat colour with a faint radial glow. Liquid Glass refracts *what scrolls
behind it*; over a flat colour it has nothing to refract, so it renders as a milky slab — hence
"not transparent". The accent `tint(opacity 0.025-0.08)` adds a coloured film that reduces
transparency further. Meanwhile the layer Apple designed glass for is switched off: every product
screen calls `.toolbarBackground(.hidden, for: .navigationBar)` (`ChatScreen:86`,
`AgentScreen:36`, `CodeScreen:71`, `BrainScreen:38`, `MediaStudioScreen:75`), so the iOS 26 glass
navigation bar never appears, and the iOS 18-25 fallback is `.ultraThinMaterial` + hairline —
already the thinnest material, so nothing more can be done there.
Fix (this is the single biggest lever on "the design is mediocre"):
1. Content cards → opaque `palette.surface` with `palette.border` hairline and the web's
   "machined plate" shadow scale (`--shadow-xs/sm/md`), exactly like the website. No glass.
2. Glass only on floating controls that overlap scrolling content: the composer bar, the tab
   bar/nav bar (stop hiding `toolbarBackground`; let the system glass bar sit over the thread),
   the scroll-to-bottom pill, the voice-call controls. Group them in one `GlassEffectContainer`.
3. Where you do want glass to read *very* transparent (composer over the thread), use the more
   transparent variant `Glass.clear` (iOS 26 SDK; verify it compiles on the runner's Xcode 26 —
   if not, `.regular` with **no tint** and `.interactive()`), and make sure content actually
   scrolls under it (`safeAreaInset` + `.scrollEdgeEffectStyle(.soft, for: .bottom)`).
4. Remove the accent tint from all `GlassSurface` uses (tint is for prominent actions only).
5. Keep `reduceTransparency` fallbacks as they are.

**F6 · `Features/Shell/FirasAppShell.swift:88-120` · major · ux / visual-design (iPhone navigation)**
Evidence: on iPhone the four products are reachable only through a custom overlay drawer (no
edge-swipe to open, no drag-to-dismiss, a scrim `Button`, `allowsHitTesting` toggling). Agent, Code
and Brain are two taps away and invisible — the reason they feel "thin" at the shell level. There
is no tab bar, no iOS 26 floating glass tab bar, no search role.
Fix: `TabView` with `Tab("Firas AI", systemImage:) { … }` × 4 + `Tab(role: .search)` for chat
search, `.tabViewStyle(.sidebarAdaptable)` (iOS 18) so iPad gets a real sidebar and iPhone a tab
bar automatically, `.tabBarMinimizeBehavior(.onScrollDown)` on iOS 26 for the glass bar, and the
conversation list becomes the first screen of the Firas AI tab (or a `TabSection` of recent chats
in the iPad sidebar). This deletes the drawer, the scrim, `compactSidebarPresented`, and the
`showsSidebarButton` plumbing in four screens.

**F7 · `Features/Shell/ShellSidebar.swift:143-150`, `:264-269` · major · ux (dead taps)**
Evidence: `filteredConversations` shows the product's own conversations (`agent`, `codeProj`,
`brainNb` flags). Tapping one calls `chatStore.select(id)` which loads the conversation into
`ChatStore.selectedConversation` — but the visible detail for `.agent/.code/.brain` is
`AgentScreen/CodeScreen/BrainScreen`, none of which render `ChatStore`. The tap dismisses the
drawer and nothing changes on screen. "New chat" (line 271) also always flips to `.ai`.
Fix: route by product — `agentStore.open(chatID)` / `codeStore.openProject(chatID)` /
`brainStore.openNotebook(chatID)` (those stores need an open-by-server-id entry point; today they
resume by pointer only), or hide the Recent section for products that cannot open a history item
yet. Make "New" product-aware.

**F8 · `Features/Shell/ShellSidebar.swift:155-167` · major · ux / missing-feature-vs-web (delete without undo)**
Evidence: `swipeActions(allowsFullSwipe: true)` → `chatStore.delete(id)` immediately; no
confirmation and no undo. The web deletes with a 7 s undo toast (`deleteChat`, web-chat-ux §11).
A full swipe on iPhone is a common accidental gesture.
Fix: either `confirmationDialog` before delete, or optimistic removal + undo toast with the
server `DELETE` deferred 7 s (mirror the web).

**F9 · `Features/Shell/ShellSidebar.swift` (whole) · major · missing-feature-vs-web**
Evidence vs web-chat-ux §11: no pin/unpin (`PUT /api/chats/:id {pinned}`), no rename (`PUT {title}`),
no pinned group, no date groups (today/yesterday/7d/30d/older), no "still working" live dot
(the app has the job pointers to drive it), no message-text search (`≥3` chars), no folders/tags
(device-local on the web, easy to port), no duplicate/merge, no usage row. Search is title-only.
Fix: implement pin, rename (context menu + swipe leading), date grouping and the live dot first —
they need only existing `PUT /api/chats/:id` and the stores' pointers. Folders/tags are optional.

**F10 · `Features/Shell/FirasAppShell.swift:47` · major · rtl-arabic**
Evidence: `.environment(\.layoutDirection, .leftToRight)` at the root, then 30+ `.environment(\.
layoutDirection, preferences.language.layoutDirection)` re-applications in children. System chrome
stays LTR in Arabic: the drawer slides from the left, `swipeActions(edge: .trailing)` is on the
right, navigation back chevrons point left, the split-view sidebar is on the left, sheet toolbar
`cancellationAction` is on the left, `Label` icons precede text. The web is a fixed-LTR shell by
design (`rtl-layout-mechanics` skill), but native Arabic iOS apps mirror; an Arabic-first product
that does not mirror on iOS looks like a port. `SettingsView.swift:26` does mirror, so Settings
and the shell disagree with each other.
Fix: apply `layoutDirection` from `preferences.language` once at the root, and force `.leftToRight`
only on genuinely LTR content (email field, version string, code, URLs — those sites already
exist). Delete the per-screen re-applications.

**F11 · `Features/Shell/FirasAppShell.swift:46`, `SettingsView.swift:25` · major · rtl-arabic (in-app language switch)**
Evidence: the in-app language is applied via `.environment(\.locale, Locale("ar"|"en"))`. This
reliably re-resolves `Text(LocalizedStringKey)` (all `"settings.*"` keys). It is **not
guaranteed** for `Text(LocalizedStringResource)` (used by every feature's `*Strings.swift` tables:
Shell, Activity, Chat, Agent, Code, Brain, Media) — `LocalizedStringResource` carries its own
`locale` defaulting to `.current`, and whether SwiftUI overrides it from the environment is
undocumented. If it does not, an English device with the app set to Arabic shows Arabic settings
and English sidebar/product/activity strings. It also does not affect `InfoPlist.strings`,
notification copy, `UNNotification` titles, or `confirmationDialog` system buttons.
Fix: verify on the first device build (set device English, app Arabic, open the sidebar). If mixed:
either construct resources with `LocalizedStringResource(key, table:, locale: preferences.language
.locale)` via a helper, or follow the platform norm — drop the in-app switch and honour the device
language (`CFBundleAllowMixedLocalizations` not needed; both `.lproj` exist). Also default
`PreferencesStore.language` from `Locale.preferredLanguages` rather than hard-coding `.arabic`
(`FirasTheme.swift:226`).

**F12 · `Models/SettingsModels.swift` / `FirasTheme.swift:193-199` + `Features/Chat/AddContextSheet.swift:51-77` · major · missing-feature-vs-web (dictation)**
Evidence: `DictationDialect` = automatic / arabic / english. The web's `MIC_LANGS` has 14 entries
(auto, msa, iraqi, gulf, egyptian, levant, maghrebi, en, fr, tr, de, es, ur, fa) and the dialect is
sent to `POST /api/transcribe` (web-voice-call-mic §7.2). `AddContextSheet` defines a second,
private `DictationLanguage` enum bound to the same `"dictationLanguage"` UserDefaults key — two
sources of truth for one setting.
Fix: one `DictationDialect` with the web's 14 raw values (same strings the server expects), used by
both Settings and the composer; menu picker (not segmented) once there are 14.

**F13 · `Features/Settings/SettingsView.swift:61-81` · major · ux / ipad (Settings container)**
Evidence: on iPhone Settings is a `TabView` inside a sheet — a 5-tab bar at the bottom of a modal.
No Apple app does this; on iOS 26 the tab bar floats as a second glass slab inside the sheet. Each
tab root is `.navigationBarTitleDisplayMode(.large)` inside a `.page` sheet, so the large title
consumes ~100 pt of a short modal. On iPad `NavigationSplitView` inside a `.page` sheet is fine.
Fix: iPhone → `NavigationStack { List { … } }` grouped like system Settings (sections push detail
pages), `.presentationDetents([.large])`, inline titles. Keep the split view on iPad.

**F14 · `DesignSystem/FirasTheme.swift:152-165` (`FontScale.factor`) · major · accessibility / missing-feature-vs-web**
Evidence: `fontScale` is persisted and pickable in Appearance, but `factor` is read nowhere
(grep: only `Settings/` and `FirasTheme.swift`). The setting does nothing.
Fix: either apply `.dynamicTypeSize(...)` offsets / `.environment(\.sizeCategory)` shifted by one
step, or remove the setting and point users to Dynamic Type (the honest native answer).

**F15 · `Features/Settings/AccountSettingsView.swift` (error surface) + `Stores/SessionStore.swift:341-345` · major · contract-mismatch / ux**
Evidence: `handleChangeEmail/Password/DeleteAccount` return Arabic error strings
(`"كلمة المرور غير صحيحة"`, `"هذا البريد مستخدم بالفعل"`, `"هذا الحساب يسجّل عبر Google"`, …).
The web maps by HTTP status in English mode (`errMsg`, app.js:45695-45702: 403 → "Incorrect
password", 409 → "already in use", 400 → invalid/short). iOS shows the raw Arabic server string
inside an English UI. Google-only accounts (no `passHash`) get a 400 for both change-email and
change-password but the rows are still offered.
Fix: map 400/403/409 to localized keys in `SessionStore.message(for:)` for these three calls; hide
or disable the email/password rows when the account has no password (needs a server flag —
`publicUser` does not expose one; open question below).

### 2.3 Minor

**F16 · `Features/Settings/ChatBackupDocument.swift:29` · minor · compile-risk**
`@concurrent` is a Swift 6.2 attribute whose purpose is to opt out of the
`NonisolatedNonsendingByDefault` upcoming feature — which is *not* enabled here. In Swift 5 mode a
`nonisolated` async function already runs off the caller's actor, so the attribute is redundant.
It should compile with the Xcode 26 toolchain, but it is the only construct in this group that
depends on a 6.2-era feature and each miss costs a CI cycle. Fix: delete the attribute. (Note for
the voice group: `LiveVoiceController.swift:428` has `Task { @concurrent in }` — same remark.)

**F17 · `Notifications/NotificationCoordinator.swift:372-409` · minor · contract-mismatch / rtl-arabic**
Local copy is hard-coded in Swift and diverges from the server table (media: server says
`صورتك جاهزة` / "Your image is ready"; app says `صورة فِراس اكتملت` / "Firas image is ready"). Since
local notifications are now the only channel, move the strings to `Localizable.xcstrings` and copy
the server table verbatim (server-misc §15.4).

**F18 · `Notifications/NotificationCoordinator.swift:112`, `:196-202` · minor · rtl-arabic**
`preferredLanguageCode` is persisted under an APNs key and updated only via
`requestAuthorizationIfNeeded(preferredLanguageCode:)`; changing the language in Settings does not
call `updatePreferredLanguage`, so notification copy can lag the UI language. Fix: derive from
`PreferencesStore.language` at schedule time.

**F19 · `Features/Shell/FirasAppShell.swift` (no `scenePhase`) · minor · background-cloud-first**
Only `MediaStudioScreen` re-runs `resumeIfNeeded` on `.active`. Chat/Agent/Code resume on view
appearance only; conversations reload only when identity changes. After a long suspension the
sidebar list and job states are stale until the next poll tick. Fix: in the shell,
`.onChange(of: scenePhase)` → `.active`: `chatStore.loadConversations()` (cheap `GET /api/chats`),
`agentStore/codeStore/mediaStudioStore.resumeIfNeeded()`, and re-check `pendingDestination`.

**F20 · `Features/Settings/DataSettingsView.swift:120-125` · minor · ux**
Export default filename `Firas-AI-backup` (no date); the web writes `firas-chats-YYYYMMDD.json`.
Fix: match the web.

**F21 · `Networking/FirasAPI.swift:233-251` (import loop, called from `DataSettingsView`) · minor · contract-mismatch**
Import POSTs up to 500 chats sequentially; `handleCreateChat` returns `409 chat limit reached` at
`MAX_CHATS_PER_USER`, and `readJson(req, 2_000_000)` rejects a single chat > 2 MB (a 2000-message
chat with 200 k-char messages easily exceeds it). The loop throws on the first failure and the UI
shows a generic error with no partial count. Fix: continue on per-chat failure, report
`imported/total`, and pre-check size per entry.

**F22 · `Features/Settings/DataSettingsView.swift:66-96` · minor · ux (copy + placement)**
Notifications live under "Data" with the footer discussed in F2. Fix: own "Notifications" section
in the Settings list; copy that states what the app actually does.

**F23 · `Features/Settings/DataSettingsView.swift:380-434` (`WhatsNewSheet`) · minor · missing-feature-vs-web**
Hard-coded three rows. The web's "See what's new" opens `/api/announcements` (server-misc §9) and
the bell/notify dot in the topbar shows unread announcements. iOS never calls `/api/announcements`,
`/api/memory`, `/api/redeem`, `/api/share`, `/api/version`, `/api/agent/credits` (grep: zero
call sites) — part of the owner's "backend not fully used". Fix: announcements feed for What's
new + a bell in the shell; memory viewer/clear in Settings → Data; redeem-code field in the plan
panel; share sheet on conversations.

**F24 · `Features/Settings/AccountSettingsView.swift:180-205` · minor · ux**
All four usage counters render "Unlimited" for every member today (`PLAN_LIMITS` are `-1`,
server-misc §13.2) — four identical tiles of text. Fix: collapse to one line when everything is
unmetered; show counters only for metered plans/guests.

**F25 · `Resources/Info.plist` · minor · ipad**
No `UIApplicationSceneManifest` → no multiple windows / Stage Manager side-by-side on iPad, which
"professional on iPad" users expect (two chats, or Code next to Chat). Fix: add the manifest with
`UIApplicationSupportsMultipleScenes = true`; the SwiftUI `WindowGroup` already supports it. Also
consider `ITSAppUsesNonExemptEncryption = false` (harmless now, required if the app ever goes to
TestFlight).

**F26 · `Resources/Assets.xcassets/LaunchBackground.colorset` + `Info.plist UILaunchScreen` · minor · visual-design**
Launch is a blank #1F2024 (blue-grey) — matches none of the six themes (dark is warm #262624) and
is dark even for light-theme users; no mark. Fix: `#262624`, plus `UIImageName` with the F mark
(and a light variant via appearance).

**F27 · `Resources/Assets.xcassets/AppIcon.appiconset` · minor · visual-design**
Flat 2-tone "F" PNG. On iOS 26 legacy PNG icons are wrapped in a system glass slab; a proper
Liquid Glass icon needs an Icon Composer `.icon` file (layers: background, stem, beams) added to
the asset catalog — Xcode 26 supports it and it costs nothing at runtime. The tinted variant is a
grey "F" on dark instead of the recommended grayscale-on-transparent.

**F28 · `DesignSystem/MentronXEntryView.swift:266-302` · minor · ux**
~3.9 s unskippable brand animation after every sign-in / guest entry. Fix: ≤1.2 s, tap to skip,
never on warm relaunch (already the case) — and consider showing it only on first install.

**F29 · `DesignSystem/FirasActivityLabel.swift:162` · minor · freeze-or-main-thread (perf)**
`TimelineView(.animation(minimumInterval: 1/30))` + `GeometryReader` + gradient mask re-evaluates
the view 30×/s for the whole streaming duration, on every visible activity label. Fix: a single
`withAnimation(.linear(duration: 1.65).repeatForever(autoreverses: false))` offset, or
`.phaseAnimator`.

**F30 · `DesignSystem/GlassSurface.swift:371-410` (`GlassIconButton`) · minor · dead code**
Zero call sites. Delete.

**F31 · `Features/Shell/FirasAppShell.swift:83`, `ShellSidebar.swift:52-61` · minor · ipad**
`NavigationSplitView` adds its own sidebar toggle to the detail column on iPad; the app also draws
its own "open sidebar" button when `columnVisibility == .detailOnly` and an "X" in the sidebar
header. Risk of two toggles side by side, and the X duplicates the system collapse gesture. Verify
on the first iPad build; if doubled, remove the custom pair (or `.toolbar(removing: .sidebarToggle)`
if you keep the custom one).

**F32 · `Features/Shell/FirasAppShell.swift:95-117` · minor · accessibility**
The drawer is not marked `.accessibilityAddTraits(.isModal)`; VoiceOver can still reach the detail
even though it is `accessibilityHidden` — fine — but focus is not moved into the drawer on open.
Moot if F6 replaces the drawer.

**F33 · `Features/Settings/PreferenceSettingsViews.swift:66-121` · minor · ux vs web**
The Thinking toggle is shown regardless of tier; on the web `applyThinkAvailability()` hides Think
on Mini (`showThinking` false). Fix: disable/hide when `tier == .mini`.

**F34 · `DesignSystem/FirasTheme.swift:27-78` · minor · visual-design**
Palette omits `accentSoft`, `accentRing`, the plan colours (`--plan-gold #D8B45A`, `--plan-diamond
#8FB4E0`), Max purple (`#8b5cf6` / `#7c3aed` / dark badge `#a78bfa`) and the six tag hues. The tier
picker and plan panel currently approximate them with `accent.opacity(0.12)`. Fix: add the tokens
(web-chat-ux §16).

**F35 · `ExportOptions.plist` / `export-ipa.sh` / `IPA-EXPORT.md` · minor · security / hygiene**
Describe an App Store Connect export with a Developer Team the owner does not have; contradicts
the workflow (unsigned + sideload). Delete or rewrite to the Sideloadly flow so nobody runs it.

### 2.4 Verified OK (no finding)
- Six themes: all 96 token values identical to `styles.css` (light 11-188, dark 196-235, black
  248-283, midnight 286-319, graphite 322-355, amber 358-391). Names/order match `THEMES`.
- `Localizable.xcstrings`: all 161 keys used by this group exist with both `en` and `ar`; file is
  valid UTF-8 (3 043 Arabic code points); `Shell.xcstrings` and `Activity.xcstrings` complete.
- Account contract: request bodies `{current,email}`, `{current,password}`, `{current}` match
  `server.mjs:2257-2330`; `ChangeEmailResponse {ok,user}` matches; delete-account password optional
  matches `if (user.passHash && …)`; change-password re-issues the cookie and the shared jar keeps
  the session.
- Backup format: `{app:"Firas AI", format:1, exportedAt, chats:[{title,pinned,agent,codeProj,
  messages}]}` matches `bsExport`/settings export (app.js:18399, 46137); `brainNb` optional so web
  files import. `handleCreateChat` accepts `clientId,title,messages,pinned,agent,codeProj,brainNb`.
- Subscription decoding matches `subInfo` (`plan, expiresAt, daysLeft, limits, used, remaining`).
- Notification payload decode matches server-misc §15.4 (`firas.type/product/jobId/phase/chatId/
  mediaKind`) — useful if APNs ever returns.
- `FirasComplete.wav` is at the bundle root (synchronized group copies `Resources/*`), 16-bit PCM
  < 30 s — valid for `UNNotificationSound`. `Resources/Sounds/` is empty and untracked, so no
  duplicate-resource build error.
- pbxproj: exceptions exclude `Info.plist` and the entitlements from the copy phase (correct);
  `.lproj` and `.xcstrings` are handled by the synchronized group; ZIPFoundation pinned; Swift 5 +
  minimal concurrency as intended. No `DEVELOPMENT_TEAM` (CI passes an empty one) — correct for
  unsigned builds.
- Swift 5 mode / default nonisolated: `PreferencesStore`, `NotificationCoordinator`,
  `MentronXEntryCoordinator`, `FirasCompletionCue`, `FirasAppDelegate` are explicitly `@MainActor`;
  `PushRegistrationClient` is an actor; models are `nonisolated` + `Sendable`; SwiftUI views get
  MainActor from the `View` protocol. `Task { … }` closures inherit MainActor. Nothing here needs
  a new `@MainActor` annotation. `FileDocument`'s `Sendable` requirement is satisfied
  (`FirasChatBackup` is Sendable).
- Dynamic Type: text styles everywhere; segmented pickers degrade to lists at accessibility sizes;
  44-pt hit targets on icon buttons; no `.dynamicTypeSize` caps.
- Security: no secrets in plist beyond the public Google client id; backup reader bounds size and
  uses security-scoped access; delete-account is double-confirmed; cookie session shared only with
  same-origin `URLSession`s.

---

## 3. Keep / rewrite verdict per file

| File | Verdict | Why |
|---|---|---|
| `Features/Shell/FirasAppShell.swift` | **Rewrite** | Drawer-based iPhone nav (F6), forced LTR root (F10), no scenePhase (F19), notification routing is the only part worth keeping (move to a small `NotificationRouter`). Replace with `TabView(.sidebarAdaptable)`. |
| `Features/Shell/ShellSidebar.swift` | **Rewrite** | Dead taps on 3 of 4 products (F7), delete without undo (F8), missing pin/rename/groups/live dot (F9). Row views (`ProductSidebarRow`, `ConversationSidebarRow`) can be salvaged as `TabSection`/list rows. |
| `Features/Shell/ShellStrings.swift` + `Shell.xcstrings` | Keep | Complete, both languages. |
| `Features/Settings/SettingsView.swift` | **Rewrite container, keep components** | iPhone `TabView`-in-sheet (F13); `SettingsPanel/ToggleRow/ValueRow/SubmitButton/NoticeBanner` are fine once `GlassSurface` is swapped for a flat surface (F5). |
| `Features/Settings/AccountSettingsView.swift` | Keep, fix | Contract correct; add status→message mapping (F15), collapse unmetered counters (F24), redeem code (F23). |
| `Features/Settings/DataSettingsView.swift` | Keep, fix | Export/import flow correct; notifications section copy + placement (F2, F22), filename (F20), partial-import reporting (F21), announcements-backed What's new (F23). |
| `Features/Settings/PreferenceSettingsViews.swift` | Keep, fix | Theme grid is good; 14 dialects (F12), Think on Mini (F33). |
| `Features/Settings/ChatBackupDocument.swift` | Keep, fix | Remove `@concurrent` (F16). |
| `Models/SettingsModels.swift` | Keep | Matches server; add per-chat size guard (F21). |
| `DesignSystem/FirasTheme.swift` | Keep, extend | Palette exact; add missing tokens (F34); apply or remove `FontScale` (F14); default language from device (F11). |
| `DesignSystem/GlassSurface.swift` | **Rewrite** | Wrong layer for glass (F5); delete `GlassIconButton` (F30); keep `FirasBackground`. Replace with `SurfaceCard` (opaque) + a `FloatingGlassBar` used by composer/tab/nav only. |
| `DesignSystem/FirasCompletionCue.swift` | **Rewrite** | 3 s hold, no sound, Reduce-Motion gate (F4). ~40 lines: haptic on terminal, optional foreground sound, dedupe. |
| `DesignSystem/FirasActivityLabel.swift` | Keep, fix | Replace 30 fps TimelineView (F29). |
| `DesignSystem/MentronXEntryView.swift` | Keep, shorten | F28. |
| `DesignSystem/FirasBrandMark.swift` | Keep | Fine. |
| `Notifications/NotificationCoordinator.swift` | **Rewrite** | Half the file is APNs plumbing that now only produces an error banner (F1); the local path needs a background-execution strategy (F2), server-verbatim copy (F17), language from preferences (F18). Keep `NotificationDestination` and the routing API. |
| `Notifications/PushRegistrationClient.swift` | **Delete** (or `#if FIRAS_APNS`) | No paid team; server sends silently no-op without APNs env anyway. |
| `Notifications/FirasAppDelegate.swift` | Keep, trim | Drop the two APNs callbacks; add `BGTaskScheduler.register` (F2). |
| `Resources/Info.plist` | Keep, extend | Add `UIBackgroundModes` (audio; fetch/processing if BGTasks), `BGTaskSchedulerPermittedIdentifiers`, scene manifest (F25), launch image (F26). |
| `FirasAI.entitlements` | Keep empty | Correct for the free-cert path; the sideload signer supplies its own. |
| `FirasAI.xcodeproj/project.pbxproj` | Keep | Settings are right for the CI pipeline. |
| `Assets.xcassets` | Keep, improve | Icon Composer `.icon` (F27), launch colour (F26). |
| `ExportOptions.plist`, `export-ipa.sh`, `IPA-EXPORT.md` | Delete/rewrite | Contradict the unsigned pipeline (F35). |

---

## 4. Owner's complaints — checked against this group

| Complaint | Verdict in this group | Where |
|---|---|---|
| Design is mediocre; glass not transparent enough | **Confirmed.** Glass on content cards over a flat background, nested glass, tinted glass, nav-bar glass hidden. Hand-rolled drawer instead of native tab/sidebar chrome. Blank launch screen, flat icon. | F5, F6, F13, F26, F27 |
| Code / Agent / Brain are thin | Partly a shell problem: they are hidden behind a drawer, their history rows are dead, and "New" always goes to AI. The screens' own depth is another group's audit. | F6, F7 |
| Backend/APIs not fully used | In this group: `/api/announcements`, `/api/memory`, `/api/redeem`, `/api/share`, `/api/version`, `/api/agent/credits` never called; push register/unregister called but useless. Account/backup APIs are fully used. | F1, F23 |
| The call kicks the user out and the app freezes | Kick-out confirmed here: no `audio` background mode + explicit end-on-background. Freeze is inside `LiveVoiceController` (voice group). | F3 |
| Must keep working after leaving the app | Server side yes (durable jobs); client polls resume on return. But nothing runs while suspended, and no notification reaches the user. | F2, F19 |
| Notification when a job finishes + haptic before completion like Claude | Notification: unreachable without background execution (F2) and APNs error banner (F1). Haptic: present but followed by a 3 s hold and no sound; Reduce Motion disables it. | F1, F2, F4 |
| Mic dictation | Settings offers 3 dialects vs 14 on the web, duplicated enum. Mic implementation itself is the chat group. | F12 |
| Auto/Plan modes | Not in Settings and not in the shell; the web persists `firas_ai_mode` and exposes it in the composer. Nothing in this group references a mode. (Chat group owns the composer.) | — |
| mini/pro/ultra/max | Tier picker present in Settings → Chat and persisted (`tier`); matches the web's four ids. Think-on-Mini rule missing. | F33 |
| Professional on iPhone AND iPad | iPad: split view is right, sidebar toggle possibly doubled, no multi-window. iPhone: drawer nav, tab-bar-in-sheet settings. RTL not mirrored. | F6, F10, F13, F25, F31 |

---

## 5. Recommended order of work for this group

1. F1 (delete APNs path) + F3 (audio background mode, stop ending the call) — one PR, no design risk.
2. F4 (completion cue) — small, immediately felt.
3. F2 step 1 (`beginBackgroundTask` around polls) + local notification copy (F17/F18) — gets
   most chat/image completions notified; then F2 step 2/3 as a follow-up with the server long-poll.
4. F5 (glass on the right layer) + F6 (TabView) + F13 (Settings container) + F10 (RTL) — the
   design rewrite; do it together because they share the navigation chrome.
5. F7/F8/F9 sidebar behaviour, F12 dialects, F14 font scale, F15 error mapping, F23 announcements.
6. F16 (`@concurrent`) can ride along with any PR.

---

## 6. Open questions (cannot be settled from source alone)

- Does `Text(LocalizedStringResource)` follow `.environment(\.locale)` on iOS 18/26? Determines
  whether the in-app language switch produces mixed-language screens (F11). Test on the first
  device build with device=English, app=Arabic.
- Does `Glass.clear` exist in the Xcode 26 GA SDK on the runner (it appeared during the iOS 26
  betas)? If not, use `.regular` untinted.
- Does the free-certificate signer (Sideloadly/AltStore) rewrite `PRODUCT_BUNDLE_IDENTIFIER`? If
  so, `BGTaskSchedulerPermittedIdentifiers` and the `UNNotificationCategory` still work (they are
  app-relative), but a bundle-id-bound Google OAuth iOS client might not.
- Should the server add a long-poll (`wait=1`) variant of the job status routes to make background
  `URLSession` delivery possible (F2 step 3)? It is the only near-real-time option without APNs.
- `publicUser` does not say whether an account has a password; hiding change-email/password for
  Google-only accounts needs a `hasPassword` field (F15).
- Does `NavigationSplitView`'s automatic sidebar toggle appear next to the custom one on iPad (F31)?
