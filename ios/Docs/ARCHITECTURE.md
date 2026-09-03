# Firas AI iOS — final architecture

Verdict: candidate A's skeleton (reliability core) with candidate B's screen inventory and richer job/plan
types grafted on. Everything below is decided. Frozen types live in `INTERFACES.md`; per-file work in
`plan/*.md`; batches and deletions in `FILE-PLAN.md`. Where this document and a report disagree, the
`server-*.md` contract wins for wire shapes and `design-brief.md` wins for look and copy.

Environment facts nobody may forget: Swift 5 mode, `SWIFT_STRICT_CONCURRENCY=minimal`, default
**nonisolated**, `ISOLATED_DEFAULT_VALUES=YES`, iOS 18.0 target, Xcode 26 on a GitHub runner, nobody
compiles locally, bundle id `org.firasai.FirasAI` (the sideload signer may rewrite it), no Apple team
(no APNs / App Groups / CallKit / iCloud / universal links), ZIPFoundation 0.9.20 is the only package
(kept — Brain Office extraction), synchronized root group (every `.swift` under `ios/FirasAI/` compiles —
deleted Codex files must really be deleted or their types collide with ours).

---

## 1. Modules (folders under `ios/FirasAI/`)

| Folder | Owns | Imports allowed |
|---|---|---|
| `App/` | `@main`, `AppEnvironment` (constructs every store once, in dependency order), `AppLifecycle` (scenePhase → stores), `AppRoute` + `Router`, `AppConfiguration` | everything |
| `Core/` | `DiskStore` actor, `NetworkMonitor`, `BackgroundExecutor`, `Deadline`/`Backoff`, `IDs`, `BidiText`, `ArabicText`, `Log` | Foundation only (+ SwiftUI for `LayoutDirection`) |
| `Networking/` | `APIClient` actor, `APIError`/`ServerError`, `LenientJSON`, `SSEParser`, `RequestBudget`, `Endpoints/*` (extensions on `APIClient`, one file per server slice), `GoogleOAuthProvider` | Core, Models |
| `Models/` | plain `Codable` structs/enums for every wire shape and every persisted shape; fence parsers | Foundation |
| `Localization/` | `LText`, `Strings` namespace (one `extension Strings { enum X }` per feature), `ArabicPlurals`, `ErrorPresenter` | Models |
| `DesignSystem/` | `FirasTheme` + `FirasPalette` tokens, `PreferencesStore`, `FirasGlass`, `SurfaceCard`, `FirasBackground`, `Typography`, `FirasMotion`, `Haptics`, `FirasSound`, `Components`, `ToastCenter`, brand views | Core, Models, Localization |
| `Jobs/` | `JobManager`, `JobPointerStore`, `JobWatcher`, `JobKindSpecs`, drivers (`ChatJobDriver`, `AgentJobDriver`, `MediaJobDriver`), `BackgroundRefresh` | Core, Networking, Models, Notifications |
| `Notifications/` | `NotificationManager`, `NotificationRouter`, `CompletionCue`, `FirasAppDelegate` | Core, Models, Localization, DesignSystem |
| `Prompting/` | `PromptCatalog` (other agent), `PromptBuilder`, `RequestClassifier`, `SearchContext`, `MessageSerializer`, `HistoryWindow`, `EngineFailureDetector`, `PlanCycle`, `AskSpec`, `ApprovalMatcher`, `AutoTitle` | Core, Models |
| `Rendering/` | Markdown block/inline parsers, `MarkdownView` (= `MarkdownRenderer` entry), `CodeBlockView`, `CodeHighlighter`, `TableBlockView`, `MathText`, `Cards/*`, `QuickReplies` | DesignSystem, Models, Localization |
| `Stores/` | `SessionStore`, `ChatStore` + `ConversationState` + `SendPipeline` + `StreamBuffer`, `DraftStore`, `GuestChatStore`, `GuestMigration`, `AgentStore`, `CodeStore` + `CodeProjectCache`, `BrainStore` + `BrainAsker`, `MediaStore`, `AnnouncementStore`, `MemoryStore`, `ImageCache` | all non-Feature folders |
| `Features/Shell,Chat,Agent,Code,Brain,Media,Voice,Auth,Settings/` | screens; `Features/Voice` also owns the call engine, dictation and TTS | everything |
| `Resources/` | `Info.plist`, assets, `FirasComplete.wav`, `*.lproj/InfoPlist.strings` | — |

Rules: a store never imports a Feature; a Feature never talks to `URLSession`; Models never import
SwiftUI; the iOS 26 glass symbols are spelled in `DesignSystem/FirasGlass.swift` and nowhere else
(`backgroundExtensionEffect` in `AppShell.swift`, `safeAreaBar` in `ChatScreen.swift` are the only other
`#available(iOS 26)` sites).

---

## 2. Foundation

### 2.1 APIClient (`Networking/APIClient.swift`)
- One `actor APIClient` over three `URLSession`s (interactive+poll, upload, download) that all share
  `HTTPCookieStorage.shared` (`httpCookieAcceptPolicy = .always`, `httpShouldSetCookies = true`).
  Cookies are the only credential (`firas_session` 30 d, `firas_guest` 7 d); never read, copy, trim or
  store them; never Keychain. `waitsForConnectivity = false` everywhere; offline comes from
  `NetworkMonitor`, never from a stall.
- `RequestBudget` → `timeoutInterval`: `.interactive` 12 s, `.poll` 30 s, `.upload` 300 s,
  `.download` 60 s idle, `.stream` 300 s idle (re-armed per SSE frame by the consumer).
- Every API `GET` sets `.reloadIgnoringLocalCacheData` (server sends no `Cache-Control`).
- `+` in query values is percent-encoded (server decodes `+` as space; `C++` bug).
- Non-2xx → `APIError.http(status:server:raw:)`; the body is decoded leniently into `ServerError`
  (every field optional); plain-text bodies (`auth required`, `not found`, `rate limited`) keep `raw`.
  A 401 additionally yields on `client.unauthorized` (`AsyncStream<Void>`), consumed only by
  `SessionStore` (guests ignore it: a guest 401 means "sign up", not "expired").
- `stream(...)` = `URLSession.bytes(for:)` + `SSEParser` → `AsyncThrowingStream<SSEFrame, Error>`;
  cancelling the task closes the socket (that *is* the server's stop for a live `/api/chat` stream).
- `download(...)` uses `session.download(for:)` to a temp URL; caller moves it. Video/music/artifacts
  are never held as `Data`.
- Endpoint helpers are `extension APIClient` in `Networking/Endpoints/*.swift`; they encode exactly
  the fields the contract lists and nothing else.

### 2.2 Models
- Plain `struct … : Codable, Equatable, Sendable` (the existing `nonisolated` prefix is harmless and
  may stay). Every server-optional field is `Optional`. Enums decoded from server strings implement
  `init(from:)` with a documented fallback (`JobPhase.unknown`, `PlanKind.free`, `BrainUnit.page`,
  `ChatRole.unknown`, `AgentJobPhase.run`). Job timestamps are ms `Double`; chat timestamps ISO
  `String`; never a `Date` decoding strategy.
- `ChatMessage` keeps client-only fields (`images`, `fileText`, `status`, `intent`); `MessageSerializer`
  decides what leaves the device: `OutgoingMessage {role, content, images?}` on the wire,
  `PersistedMessage` (the `sanitizeMessages` whitelist: `role, content, tier, lang, reasoning, cid,
  files, imageThumbs, mode, askAnswered, retryOf, retried, mergedFrom, alts, altAt`) on PUT.
- `ProductKind` gains `.studio` (native-only; never sent to the server — `MediaStore` sends `product:"ai"`).

### 2.3 SessionStore
```
phase: booting → member(User) | guest(User) | signedOut | awaitingVerification(pid, email) | unreachable(lastKnown: User?)
```
- `restore()`: `GET /api/auth/me` (`.interactive`). 200 → member. 401 → if the local `guestActive` flag
  is set `POST /api/guest` → guest, else `.signedOut`. Transport error / 5xx → `.unreachable(lastKnown)`:
  the shell still renders the last product from local caches with a banner + Retry; `NetworkMonitor`
  flipping online re-runs `restore()`. Nothing waits more than 12 s; nothing blocks the first frame.
- `handleUnauthorized()`: idempotent, only while `.member`; sets `sessionExpiredNotice`, calls
  `JobManager.suspend(owner:)`, clears member caches, `POST /api/guest`, router shows Auth.
- `applicationDidBecomeActive()`: re-validate `/me` when the last check is > 10 min old (guests skip).
- Each operation has its own `isWorking` flag (`login`, `signup`, `restore`, `google`, `forgot`,
  `changeEmail`, …) so a stuck restore never disables Sign in.
- Verification: 3 s `verify-status` poll while the card is visible, resend with a 30 s countdown,
  stops on `verified | gone | expired` and on background.
- Guest → member: `onGuestBecameMember(previousGuestID)` fires; `GuestMigration` POSTs local guest
  chats (3 concurrent, per-chat failures tolerated), toasts, then `DELETE /api/guest` fire-and-forget.
- Google: `GoogleOAuthProvider` (PKCE via `ASWebAuthenticationSession`, kept) → `POST /api/auth/google-native`.
  Firebase and `/api/oauth/google/exchange` are deleted.

### 2.4 JobManager (the cloud-first spine)
One manager, one on-disk pointer table (`jobs.json`, ≤ 40 pointers, per owner), one `JobWatcher`
task per pointer, one `JobKindDriver` per kind. **Stores never poll on their own.**

| kind | start | status | terminal | deadline | cadence fg → bg | cancel |
|---|---|---|---|---|---|---|
| chat, longdoc | `POST /api/chat/job` | `GET /api/chat/job?id=` | `completed`/`failed`; `unknown`×3 | 30 min / 6 h | 0.35 s (10 s) → 0.7 s (40 s) → 1.2 s; bg 5 s | `POST /api/chat/cancel` (409 for a queued chat = stop locally) |
| longfile | same | same + `GET /api/chat/job/file` | same; `status 499` = cancelled (silent) | 6 h | 2 s; bg 10 s | cancel tombstones |
| agentrun | same (`kind:"agentrun"`, `chatId` required) | SSE `GET /api/agent/job-stream` → poll `GET /api/agent/job` | `done`/`fail`; `{job:null}`×2; 403/404 | 3 h | SSE; poll 0.7 s; bg 5 s | none — UI never offers Stop |
| codebuild | same (`chatId:""`) | `GET /api/chat/job?id=` | `completed`/`failed`/`unknown` (immediate) | 2 h | 4 s; bg 10 s | none |
| brainask | same | same | `completed`/`failed`; `unknown` immediate | 30 min | 3 s; bg 10 s | none |
| image | `POST /api/image/job` | `GET /api/image/job?id=` | `done`/`fail` | 20 min | 2 s → 5 s; bg 10 s | none |
| video | `POST /api/video/job` | `GET /api/video/job?id=` | `done`/`fail` | 20 min | 2.5 s → 6 s; bg 15 s | none |
| music | `POST /api/music/job` | `GET /api/music/job?id=` | `done`/`fail` | 10 min | 2 s → 6 s; bg 15 s | none |

Watcher rules (all kinds): (1) pause while offline, resume on online or `.active` with one immediate
read; (2) transport errors → `Backoff(1.2 s … 30 s)`, 20 consecutive → keep pointer, mark
`.reconnecting`, retry every 30 s until deadline — never spin; (3) 401 → `SessionStore.handleUnauthorized()`
and suspend (pointer kept, resumes after re-auth of the same owner); 403 → forget silently; 404 with a
body → terminal failed; (4) deadline → terminal `.expired` (media: keep for one later check —
the server answers `running` forever for a lost id); (5) terminal delivery order: `JobObserver.job(_:didFinish:)`
on the main actor first → the store lands the result and returns `true` → `CompletionCue.fire()` (app
active) or `NotificationManager.postJobTerminal` (inactive) → `forget`. **Land before forget**;
codebuild retries landing 15 × 4 s; (6) `didEnterBackground` → each live watcher takes a
`BackgroundHold` (~30 s more polling, cadence ×2) and `BackgroundRefresh.schedule(after: 60 s)` is
submitted while the table is non-empty; the BG handler runs `JobManager.refreshOnce(budget: 20 s)`
(one read per pointer, notifications for terminals, resubmit if anything is live); (7) `start` is
keyed by `cid`: a replayed start answering `completed` lands directly; `failed + retryRequiresNewCid`
mints a new cid only on user retry; (8) pointers carry `ownerID`; on identity change other owners'
watchers are suspended, never cancelled server-side; (9) growing `text` is published ≤ 10 Hz.

Refusals inside a job (`phase:"failed"`, `status ≥ 400`, `error` = JSON string) are decoded into a
`ServerError` and delivered as `JobTerminal.refused` — same `ErrorPresenter` path as a live 429.

### 2.5 Notifications without APNs (`Notifications/`)
- Permission is requested after the first accepted job, behind a one-line explainer sheet; the
  Settings copy says "usually within minutes" — never "instantly".
- `NotificationManager.postJobTerminal(pointer:terminal:lang:)` posts a local notification with the
  server's **verbatim** copy table (`server-auth-session-account.md §6.6`; `Strings.Notify`), sound
  `FirasComplete.wav`, category `FIRAS_JOB_COMPLETE`, `thread-id = firas-<product>-<chatId|jobId>`
  (≤ 64), `userInfo = {firas: {type:"job-terminal", product, jobId, phase, chatId?, mediaKind?}}` —
  the same nested keys the server's APNs payload uses. Dedupe by `pointer.notified`.
- `NotificationRouter.route(userInfo:) -> AppRoute?` handles taps including cold start; `Router.pendingRoute`
  is consumed once by `AppShell`.
- Call ending in the background posts `postCallEnded(reason:)`.

### 2.6 CompletionCue and haptics
`CompletionCue.prepare()` when a watcher sees the first terminal read; `CompletionCue.fire(key:success:)`
= soft impact 0.32 → 160 ms → 0.48 → 140 ms → return (≈ 300 ms total, **never** the Codex 3 s hold);
failure = `.error` notification haptic; optional `done.caf` on the same frame; foreground only; never
during a call; never twice per key; Reduce Motion → a single `.success`. The store paints the final
state on the frame after `fire` returns; streamed text is already on screen before the cue starts.
`Haptics` vocabulary (send light 0.6 on bubble insert, stop medium 0.5, selection for chips/tier/mode/
drawer snap, attach light, toolStep light 0.35, error, undo success, call start/stop, record start/stop)
per `design-brief.md §5.1`; generators prepared before the moment; no haptic in the background.

### 2.7 Design system and the six themes
- `FirasPalette` = 16 base tokens (already exact in `FirasTheme.swift`) + derived tokens. Views read
  `prefs.palette`; nobody writes `.opacity(0.05)` inline.
- Base tokens (hex):

| token | light `نهاري` | dark `ليلي` | black `أسود` | midnight `نيلي` | graphite `كربوني` | amber `عنبري` |
|---|---|---|---|---|---|---|
| background | FAF9F5 | 262624 | 000000 | 0F1522 | 171719 | 1B1713 |
| backgroundSubtle / surfaceSunken | F0EEE6 | 1F1E1D | 0A0A0A | 0A0E19 | 101012 | 141110 |
| surface | FFFFFF | 30302E | 161616 | 182133 | 202023 | 241F19 |
| sidebar | F5F4EE | 1F1E1D | 000000 | 0A0E19 | 101012 | 141110 |
| textPrimary | 1A1A18 | ECEAE3 | F2F2F0 | E6ECF5 | ECECEE | F0E7D8 |
| textSecondary | 6B6A63 | A6A39A | ABABA6 | 9FACC2 | A5A5AA | B3A793 |
| textMuted | 6E6C64 | 9A978E | 8C8C87 | 8695AE | 8B8B90 | 9C907C |
| border | E6E4DA | 3A3A36 | 232323 | 232E44 | 2A2A2E | 332C23 |
| borderStrong | D8D6CB | 46453F | 343432 | 33405A | 3A3A3F | 453C30 |
| accent | 237A68 | 57AE9C | 5FBBA7 | 5AA9E6 | 57AE9C | D9A05B |
| accentHover | 1A6253 | 6BC0AE | 74CFBB | 7CBEF0 | 6BC0AE | E8B475 |
| accentDeep | 14544A | 2F6F62 | 2F6F62 | 2C6394 | 2F6F62 | 8A6234 |
| onAccent | FFFFFF | 1F1E1D | 000000 | 0A0E19 | 101012 | 1B1713 |
| success | 2E7D5B | 4BA784 | 4BA784 | 4BA784 | 4BA784 | 8FBF6F |
| error | B3261E | E06A60 | E06A60 | E06A60 | E06A60 | E06A60 |

- Derived tokens (add to `FirasPalette`):

| derived | light | dark | black | midnight | graphite | amber |
|---|---|---|---|---|---|---|
| accentSoft | accent @ .08 | accent @ .14 | accent @ .15 | accent @ .15 | accent @ .14 | accent @ .15 |
| accentRing | accent @ .40 | accent @ .45 | accent @ .45 | accent @ .45 | accent @ .45 | accent @ .45 |
| glassTint | accent @ .035 | accent @ .05 | accent @ .05 | accent @ .05 | accent @ .05 | accent @ .045 |
| glassWash | black @ .025 | white @ .04 | white @ .06 | white @ .04 | white @ .04 | white @ .035 |
| glassStroke | black @ .08 | white @ .10 | white @ .14 | white @ .10 | white @ .10 | white @ .09 |
| glassShadow (r24 y8) | black @ .08 | black @ .18 | black @ .30 | black @ .20 | black @ .20 | black @ .20 |
| userFill | 2A6055 | 2F6D60 | 2E6C5F | 2B5F8E | 2E6C5F | 866032 |
| userInk / userEdge / userSheen | FFFFFF / accent @ .40 / white @ .16 | same | same | same | same | same |
| maxTierText / maxTierDot / maxTierBg | 7C3AED / 8B5CF6 / (139,92,246) @ .13 | A78BFA / 8B5CF6 / same | as dark | as dark | as dark | as dark |
| planGold / planDiamond | B8862A / 3E7CB1 | D8B45A / 8FB4E0 | as dark | as dark | as dark | as dark |
| callGround (behind radial accent @ .26 light / .30 dark) | background | 14201D | 000000 | background | background | background |
| codeWarn / codeOk | B3261E / 2E7D5B | E3B341 / 6FC48B | E3B341 / 6FC48B | E0B45C / 6FC48B | DDB45F / 77C191 | E8B552 / 7CC596 |
| grainOpacity | .030 | .042 | 0 | .035 | .030 | .050 |

  Theme names ar `نهاري / ليلي / أسود / نيلي / كربوني / عنبري`, en `Light / Dark / Black / Midnight /
  Graphite / Amber`; settings swatch = `[background, surface, accent]`; only `light` is a light family
  (`preferredColorScheme`). Colour tags (fixed): red C0503F, amber B0842C, green 4E8A46, teal 2E8A82,
  blue 4A72B8, purple 8A5FB0.
- Glass: exactly three levels via `FirasGlass.Level`: `.chrome` (system bars — no modifier on 26,
  `.toolbarBackground(.ultraThinMaterial)` on 18; never `.toolbarBackground(.hidden)`), `.floating`
  (composer, drawer, dictation bar, floating chips, orb controls: iOS 26 `Glass.clear.tint(glassTint).interactive()`
  + `glassWash` overlay (`.plusLighter` on dark, `.normal` on light) + 0.5 pt `glassStroke`; iOS 18
  `.ultraThinMaterial.opacity(0.62)` over `surface.opacity(0.28)` + 1 pt stroke + wash), `.sheet`
  (`Glass.regular.tint(glassTint)`; iOS 18 `.ultraThinMaterial` + `surface.opacity(0.55)`; sheets never
  set a solid `presentationBackground` on 26). Reduce Transparency → solid `surface` + stroke, same
  radii. Cards, bubbles, code blocks, editor are opaque `SurfaceCard`. Never nest two `.floating`
  surfaces — chips live inside the composer's `GlassEffectContainer(spacing: 12)`. `Glass.clear` is
  spelled in one function so a CI rejection is a one-line fallback to `.regular`.
- Radii: composer 24 continuous, chips `Capsule`, cards 9 (nested 7), user bubble 20 with the
  bottom-trailing corner 7. Shadows per the table above; cards `.black.opacity(0.05) r3 y1`.
- Typography: system font only; assistant prose `.body` 17 pt with `lineSpacing` 9 (Arabic) / 6 (Latin);
  Arabic never tracked/kerned/light; mono for code/timers/ids; Arabic-Indic digits for counts via
  `ArabicText.count`, Latin LTR digits for timers/ids.
- Motion: `FirasMotion.standard = .spring(response: 0.35, dampingFraction: 0.85)`, `.sheet` 0.42/0.86,
  `.drawerFlick = .interactiveSpring(0.32/0.78)` (the only overshoot), `.composer` 0.28/0.9, `.tierPop`
  0.3/0.7, `.reveal` 0.4/0.85 + `.opacity.combined(with: .offset(y: 6))`. `motionOn = prefs.motionEnabled
  && !reduceMotion`; when off: 120 ms fades, busy indicators become a 1.5 s opacity pulse — never frozen.
- Sound: `send.caf`/`done.caf` optional (off by default, `prefs.uiSoundsEnabled`), `.ambient`, volume 0.6,
  skipped while a call is active. Missing asset = silent no-op, never a crash.

### 2.8 Navigation
- Fixed-LTR shell (`.environment(\.layoutDirection, .leftToRight)` once in `AppShell`); RTL only in
  bidi islands (`View.bidiIsland(for:fallback:)` decides from the first strong character: message
  bodies, composer field, titles, card text). Never re-apply per screen.
- iPhone: `AppShell = ZStack { detail; scrim; CompactDrawer }`; detail = the selected product's screen
  in its own `NavigationStack`; drawer width `min(360, max(286, w−44))`, `.floating` glass, 30 % scrim,
  20 pt edge swipe with `@GestureState` + momentum projection (`translation + velocity × 0.998/(1−0.998)/1000`,
  open if > width/2). No root tab bar; `TabView` only inside Code (Files/Code/Preview/AI) and Studio.
- iPad (`horizontalSizeClass == .regular`): `NavigationSplitView(columnVisibility:)` `.balanced`,
  sidebar 270–360, system sidebar toggle kept (no custom pair), `backgroundExtensionEffect()` on the
  detail on 26; Code three columns; Brain three columns (library / thread / passage inspector); Studio
  grid + `.inspector` form; settings `.presentationSizing(.form)`; tier picker as `.popover` with
  `.presentationCompactAdaptation(.sheet)`; keyboard shortcuts `⌘N ⌘K ⌘↩ esc ⌘, ⌘1…5 ⌘⇧M ⌘⇧C`;
  `.dropDestination(for: Data.self)` on the chat; windows < 320 pt fall back to the iPhone layout.
- `Router` (`@MainActor @Observable`) is the single navigation source: `product`, `selectedConversationID`,
  `sheet: AppSheet?`, `cover: AppCover?`, `pendingRoute: AppRoute?`. Screens never present sheets from
  stores. `onOpenURL` handles `?share=`, `?verify=`, `?reset=&uid=` via the custom scheme only.

### 2.9 Localization
No `.xcstrings`, no `LocalizedStringResource` for app copy (undocumented `\.locale` behaviour, JSON
build-phase errors, no plural support for six Arabic forms). `struct LText { ar, en }` values in
`enum Strings` namespaces (`Strings.Chat.send(lang)`), one `extension Strings { enum X }` file per
feature, Arabic verbatim from the web STR tables cited in the reports. `AppLanguage` default: device
language `en*` → `.english`, else `.arabic`. Plurals through `ArabicPlurals.count`. Numbers through
`ArabicText.count`/`timer`. `InfoPlist.strings` stays for OS usage descriptions. Never interpolate
`\(…)` inside an Arabic literal that also contains `"`; use `LText.fmt` (`String(format:)`, `%@`/`%ld`).

### 2.10 Prompt building
`PromptBuilder.build(PromptInput) -> (messages: [OutgoingMessage], tier: ModelTier, think: Bool)`:
one system message = `PromptCatalog.systemPrompt(tier:product:mode:lang:think:requestKind:)` +
plan-cycle addendum (§2.12) + `fileGuidance(fmt)` when the request is a file and the turn is not a
clarify/plan turn + the search-empty note when the toggle was on and results were empty. Never the
identity block (the server prepends it). Search context (when run) is a `user` message right after
the system message; explicit search downgrades any tier but `max` to `pro`. `HistoryWindow` keeps
system + trailing turns ≤ 400 000 chars, always the last user turn; `images` only on the last user
turn (re-attached on the web's image-follow-up regex); `fileText` merged into `content` at send only.
`think = prefs.thinkingEnabled && tier.showThinking && !hasImages`. Job vs stream: job for every
persisted turn (member with server id, every guest) unless the last user turn has images or the body
> 550 000 chars → `POST /api/chat` SSE; 413/404/501 on job start → SSE fallback. User turn is PUT
(whitelist) **before** the job starts; on completion members `GET /api/chats/:id` and merge by `cid`
(no PUT when the server already holds the assistant turn); never PUT `title` at finish; guests local
only. `EngineFailureDetector` (busy sentences / empty) → `.failed`, no persist, one automatic retry
with a new cid. Title: 42-char provisional, then `AutoTitle` via `POST /api/chat {nomem:true, tier:"pro"}`.

### 2.11 Rendering
Hand-written block scanner (`MarkdownBlocks.split`) → `[MDBlock]`; inline via Foundation
`AttributedString(markdown:options: .inlineOnlyPreservingWhitespace)` after `MathScanner` protects
`$$…$$`, `$…$`, `\(…\)`, `\[…\]` with PUA sentinels (currency guard `$5 for tea`). Streaming: the
settled prefix (all blocks but the last) is cached by block index; only the tail re-parses on each
≤ 10 Hz tick; an open fence or open `$$` renders as plain text until closed. Math v1 = `MathText`
(port of the web's `texToUnicode`) in an LTR mono island — correct glyphs, not typeset layout; a KaTeX
web view is explicitly deferred (a `WKWebView` per equation in a `LazyVStack` is a freeze risk and the
assets cannot be verified on CI). Code = native `Text` + `CodeHighlighter` tokenizer (html/css/js/ts/
json/py/swift/bash), LTR, copy, Preview for html/svg in a sandboxed non-persistent `WKWebView`.
`firas-*` fences → `FirasFence.parse` → `Rendering/Cards/*`. Links → `SFSafariViewController`;
artifact links → `ArtifactViewer`. Rows are `Equatable` on `(id, content.count, reasoning.count,
status, altAt)`; `StreamBuffer` mutates the last message in place; parsed blocks cached per message id
in an `NSCache`; thumbnails decoded once off-main in `ImageCache`; full images never persisted.

### 2.12 Plan mode (`PlanCycle`, chat product only)
```
enum PlanPhase { none, awaitingAnswers(askMessageID), awaitingApproval(planMessageID), executing(originID), delivered(originID) }
```
Mode is a device preference **snapshotted onto the conversation** when a cycle starts. System text
per turn is concatenated into the single system message: clarify/plan turns = base without build
rules + `planSystem`; execute turn = base with build rules + `planSystem` + the EXECUTE note; after two
ask rounds append the forced-plan sentence (texts from `PromptCatalog`). Transitions exactly
`web-plan-mode.md §7.2`; `ApprovalMatcher` (§7.6: Arabic normalised prefixes without `\b`, English
whole-message only, > 6 words = revision) consulted only in `awaitingApproval`; execute routing resolves
the deliverable from the **origin** user message via `RequestClassifier` (file → file path + guidance,
image → image job, code → code card, else prose). Assistant messages in a cycle stamped `mode:"plan"`,
else `"auto"`; phase derived on load (§7.5). Submit/Start turns carry no quote or attachments. Never
evaluated for Agent/Code/Brain; a call pauses the cycle. `AskSpec.parse` also accepts a `json` fence
with `questions` when the phase expects an ask.

### 2.13 Call engine (`Features/Voice/CallEngine.swift`)
Phases `idle → preparing → minting → connecting → connected(listening|thinking|speaking) → ending → ended(reason) | failed(reason)`.
Start (every await inside `withDeadline`): record permission → `POST /api/live/token {voice}` →
`CallAudioGraph.prepare` **off-main** (`AudioSessionArbiter.acquire(.call)` → `.playAndRecord/.voiceChat/[.allowBluetoothHFP]`
(+ `.defaultToSpeaker`) → `setActive(true)` → `inputNode.setVoiceProcessingEnabled(true)` **before**
reading formats → `AVAudioConverter` to Int16 mono at the provider rate (24 kHz OpenAI / 16 kHz Gemini)
→ 100 ms tap → ordered `AsyncStream<Data>` → Float32 24 kHz player → `engine.start()`) → transport
`connect` (must reach `.ready`: OpenAI `session.created` with the "You are Firas" instructions and
`semantic_vad`, Gemini `setupComplete` within 10 s) → greeting. Ladder: `openai` → mint again
`{prefer:"gemini", voice}` within 90 s → `gemini` (tools `googleSearch` unless the model is in the
persisted no-search list; 1008/1011 with tools → retry without tools; early close < 8 s → one
reduced-setup retry; 1008/1011 without tools → 10-min cooldown) → `ThreeHopCall` (record → transcribe
→ chat with `callSys`, mode auto, think off, tier ≤ pro → TTS). Two engines never answer one question.
Runtime: mic frames sent in order (zeros while gated/muted); OpenAI mic gate from `response.created`
to 280 ms after `response.done` (20 s safety reopen), `sendPing` every 20 s while gated, barge-in
(setting, default off) = stop player + `conversation.item.truncate`; Gemini `EchoGuard` even with
VPIO. Two clocks: hard `max(60 s, maxMs) − 1.5 s`, idle 45 s from `lastVoiceAt`; guest cap ends with
the verbatim guest sentence. Every `scheduleBuffer/play` runs on the graph's serial queue **and**
checks `engine.isRunning && !isEnding`. Observers: configuration change (rebuild + restart), route
change (re-query formats, hide speaker toggle on BT/headphones), interruption (`.began` pause,
`.ended + shouldResume` restart). `UIBackgroundModes: audio`; nothing ends the call on background; a
background end posts a local notification. Teardown `end()` idempotent, `isEnding` first: timers →
player stop + drop queue → tap removed, stream finished → `engine.stop()` → socket closed → session
released off-main (`.notifyOthersOnDeactivation`) → handles nulled → `.ended`. `AudioSessionArbiter`
is the only object calling `setCategory/setActive` (priority call > record > playback > uiSound).

### 2.14 Dictation and TTS
`DictationRecorder`: `AudioSessionArbiter.acquire(.record)`, engine tap → converter → 16 kHz Int16 mono
→ `WAVEncoder` (RIFF header, base64 standard alphabet, no line breaks); 300 s cap; ≥ 700 ms and
≥ 1 500 bytes to send; background → auto-finish; level stream drives the 32-bar waveform.
`DictationController.transcribe`: `POST /api/transcribe {audio, format:"wav", lang: dialect.serverKey}`;
503 / offline → `SFSpeechRecognizer(locale: dialect.bcp47)` (`auto` → `ar-SA`); result **appends** to
the draft with one space, never auto-sends; shared by Chat, Agent, Brain composers.
`TTSPlayer`: `callSpeakable` cleaning → chunks ≤ 1 300 on `.!?؟،؛\n` → `POST /api/tts {text, lang,
gender:"male"}` → sniff `RIFF`/MP3 → `AVAudioPlayer` under `.playback`; 16-entry cache; 429 →
`AVSpeechSynthesizer` from the failed chunk (`listenLocal` toast; `listenNoVoiceAr` when no Arabic
voice); refused during a call (`listenBusy`); one speaker token across screens; pauses `SongPlayer`.

### 2.15 Error code → user string policy (`Localization/ErrorPresenter.swift`)
`ErrorPresenter.present(_ error: Error, feature: FeatureKey?, lang:) -> ErrorAction` decides
**by status and code, never by the server's sentence**:

| Condition | Action |
|---|---|
| `URLError` offline/timeout/host | `.toast(Strings.Errors.offline)` (`تعذّر الاتصال بالخادم. تحقّق من اتصالك.`) |
| `DeadlineError` | `.toast(Strings.Errors.timeout)` |
| 401, member | `.sessionExpired` (SessionStore already reacted) |
| 401, guest | `.signUpPrompt(feature ?? .generic)` |
| 403 `signin_required` / `account_required` (+`feature`) | `.signUpPrompt(feature)` — image copy for `image`, generic otherwise |
| 403 `not_yours` / `forbidden` | `.silent` (job forgotten) |
| 409 `agent_busy` (`activeJob`, `credits`) | `.blockedAgent(activeJob, credits)` |
| 429 with `quota` | guest plan → `.signUpPrompt` + `guestLimitReached` (network scope → `guestNetworkLimit`); member → `.toast(quotaText(product, limit))` verbatim 🚦 sentence with Arabic-Indic `lim` |
| 429 `credits_reserved` / `credits_exhausted` | `.creditsBlocked(credits)` |
| 429 `daily_limit` (`limit`) | media daily string with `limit` |
| 429 `rate_window` (`freesInMin`) | media window string with `freesInMin` |
| 429 `site_media_ceiling` | media busy-today string |
| 429 plain / `rate_limited` / `too many requests` / `too many attempts` | `.toast(Strings.Errors.tooFast)` |
| 400 auth field errors (`name is required`, `a valid email…`, `password must be…`) | field message keyed by which substring matched; else `Strings.Auth.invalid` |
| 400 `هذا الحساب يسجّل عبر Google…` (change-*) | `.toast(Strings.Auth.googleAccount)` |
| 400 `bad_image` / 413 `image_too_large` | `.toast(Strings.Media.badImage)` and retry text-only for video |
| 500 on login | `Strings.Auth.credentialsOrGoogle` (server's valid-input trap) |
| 501 / 503 `not_configured` (+`feature`) | hide the feature (`.hideFeature(feature)`) |
| 503 `storage_unavailable` / `no_engine` / `capacity` / `agent_unavailable` | `.toast(Strings.Errors.serverBusy)` + retry affordance |
| 503 on `/api/transcribe` or `/api/tts` | on-device fallback, no toast |
| any other 4xx/5xx | `.toast(Strings.Errors.generic)`; the raw server code is logged, shown only in DEBUG |

Arabic UI never shows an English server sentence; English UI never shows an Arabic one. Every
row above has an `LText`. Agent/codebuild/brainask `error` codes map through the tables in
`server-agent.md §5.5`, `server-code-brainask.md §2.7/§3.4` to `Strings.Agent/Code/Brain` copy.

---

## 3. COMPILE-RISK RULES (each violation costs a 15-minute CI cycle)

1. Swift 5 mode. Every `@Observable` store is `@MainActor final class`; services are `actor` or
   `final class: Sendable` with an internal serial queue; models are plain `Codable` structs/enums.
   Never mark a model/enum method `@MainActor` (drop the two on `ModelTier`).
2. No force unwrap, no `try!`, no `as!`, no `fatalError` outside `#if DEBUG`. `AVAudioFormat(…)`
   results are `guard let`.
3. iOS 26 API only inside `if #available(iOS 26, *)` and only in `FirasGlass.swift`, `AppShell.swift`,
   `ChatScreen.swift`, `CodeWorkspaceView.swift`/`MediaStudioScreen.swift` (`tabBarMinimizeBehavior`),
   `ComposerView.swift`/`CallScreen.swift` (`GlassEffectContainer`). Every such branch has a complete
   iOS 18 fallback so deleting the 26 branch is a one-line fix. `Glass.clear` lives in one function.
4. Prefer APIs that exist since iOS 17: `@Observable`, `AttributedString(markdown:)`, `Regex`,
   `URLSession.bytes/download(for:)`, `NavigationSplitView`, `onScrollGeometryChange` (18),
   `.sensoryFeedback` (17). Uncertain symbols (`ToolbarSpacer`, `navigationSubtitle`) are not used.
5. No third-party dependencies; ZIPFoundation stays pinned; `Package.resolved` untouched.
6. All copy via `Strings`/`LText`; no `LocalizedStringKey`, no `String(localized:)`, no `.xcstrings`.
7. Never block the main thread: extraction, image decode, WAV encode, JSON of large chats, ZIP → `Task.detached`
   or an actor; results hop back; detached bodies never touch `@Observable` state. No `sleep`, no
   semaphores, no `DispatchGroup.wait`.
8. Every network call goes through `APIClient` (endpoint extensions). The only other sockets are the
   WebSocket inside a call transport and `ASWebAuthenticationSession`.
9. No invented modifiers: only SwiftUI APIs that appear in Apple docs for the stated OS; when in doubt,
   compose with `overlay/background/clipShape`.
10. Isolation: `Task {}` inside a `@MainActor` store inherits the actor; delegate callbacks the SDK
    declares nonisolated (`ASWebAuthenticationPresentationContextProviding`, `WKScriptMessageHandler`,
    `AVAudioNodeTapBlock`, `UNUserNotificationCenterDelegate`) hop with `Task { @MainActor in }` or
    `MainActor.assumeIsolated`. No `@concurrent`, `nonisolated(nonsending)`, `sending`, `~Copyable`,
    typed throws, custom macros, `#Preview` blocks, `nonisolated(unsafe)`, global mutable `var`.
11. `ISOLATED_DEFAULT_VALUES=YES`: default arguments and stored-property initialisers must not call
    `@MainActor` code (`= PreferencesStore()` in a nonisolated context is an error) — pass explicitly.
12. `Codable` synthesis only for flat DTOs whose keys match; lenient DTOs implement `init(from:)` by
    hand with `LenientJSON` helpers; no property-wrapper decoders; no `Date` decoding strategies.
13. View bodies < 80 lines, split into subviews (the type checker times out on CI more than locally);
    `@ViewBuilder` on any function returning `some View` with branches; `AnyShape` only through
    `FirasGlass`'s parameter.
14. Regexes ported from JS: never `\b` next to Arabic (use `(?![\p{L}\p{N}_])`); lookbehind only in
    Swift `Regex` literals, never in `NSRegularExpression` strings.
15. AVFoundation: `player.play()`/`scheduleBuffer` only inside `CallAudioGraph`; `setCategory/setActive`
    only inside `AudioSessionArbiter`.
16. `Info.plist` identifiers are computed at runtime from `Bundle.main.bundleIdentifier`
    (`BackgroundRefresh.identifier = "\(bundleID).jobs"`) and the plist uses
    `$(PRODUCT_BUNDLE_IDENTIFIER).jobs`.
17. Every file compiles alone: no cross-file `private`/`fileprivate` reliance, no file-scope `let`
    depending on another file's initialisation, unique type names across the target (feature-prefixed
    helpers: `CodeEditorTheme`, `BrainSourceRow`, `MediaViewer`).
18. One owner per file; frozen signatures in `INTERFACES.md` are appended to, never changed, without
    the architect updating that file first. `String(format:)` with `Int` uses `%ld`.
