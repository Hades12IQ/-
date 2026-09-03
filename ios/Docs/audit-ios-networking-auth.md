# Audit — Networking + Session + Auth (iOS)

Scope: `ios/FirasAI/Networking/APIClient.swift`, `FirasAPI.swift`, `GoogleOAuthProvider.swift`,
`Stores/SessionStore.swift`, `Features/Auth/AuthView.swift`, `Models/AuthModels.swift`,
`Models/CommonModels.swift`, `App/AppConfiguration.swift`, `App/FirasAIApp.swift`.
Server truth: `server.mjs` (router `13787-13860`, auth handlers `1859-2335`, cookies `1046-1195`,
Google native `13555-13720`). Contract reports consulted: `Docs/server-misc.md` §0.2, §10, §13, §14,
§16; `Docs/web-chat-ux.md` §1.2-1.5.

Build settings that matter (`FirasAI.xcodeproj/project.pbxproj:280-293`): `SWIFT_VERSION = 5.0`,
`SWIFT_STRICT_CONCURRENCY = minimal`, no `SWIFT_DEFAULT_ACTOR_ISOLATION` (so default is
**nonisolated**), `IPHONEOS_DEPLOYMENT_TARGET = 18.0`, `TARGETED_DEVICE_FAMILY = "1,2"`. CI
(`.github/workflows/build-ios-ipa.yml`) builds Release for `generic/platform=iOS` with code signing
off, `SWIFT_TREAT_WARNINGS_AS_ERRORS` is not set, so warnings do not fail the build.
`FirasAI/FirasAI.entitlements` is an **empty dict** (no `aps-environment`, no associated domains).

---

## A. Inventory — what this group implements today

| Area | Implemented | Notes |
| --- | --- | --- |
| Transport | `actor APIClient` over one `URLSession` (`default` config, `HTTPCookieStorage.shared`, accept-policy `.always`, `waitsForConnectivity = true`, request timeout 45 s, resource timeout 180 s). JSON in/out, `{error}` envelope decoding for non-2xx, binary `download` with `Content-Disposition` filename parsing. | No background session, no retry, no request cancellation API beyond Swift task cancellation, no progress. |
| Endpoint facade | `FirasAPI` (nonisolated struct wrapping the actor) with 40 methods covering auth (login, signup, verify-status, verify-signup, me, logout, change-email, change-password, delete-account, google-native, firebase, google exchange), guest start/end, chats CRUD + backup/import, chat job start/status/cancel, agent job status + artifact, usage charge, brain docs/doc/search/passage, web search, image/video/music job start/status + file download. | 33 distinct server paths are referenced app-wide (grep). `/api/auth/firebase`, `/api/oauth/google/exchange`, `/api/auth/verify-signup`, `DELETE /api/guest` are wired but **never called by any view or store** (dead paths). |
| Session | `@MainActor @Observable SessionStore` with phases `restoring / guest / awaitingVerification / authenticated`; `restore()` = `GET /api/auth/me` → 401 → `POST /api/guest`; login, signup → pending verification (manual "I verified" poll of `/api/auth/verify-status`), Google native sign-in, continue-as-guest, logout, refresh, change email/password, delete account, chat backup export/import. Push registration hooks (`NotificationCoordinator.sessionDidAuthenticate/sessionDidEnd/unregisterCurrentDevice`). | One shared `isWorking` flag serialises every operation. No "session expired" entry point for other stores. No foreground re-validation. |
| Google | `GoogleOAuthProvider` — `ASWebAuthenticationSession` + custom-scheme redirect, S256 PKCE, `state`, `nonce`, `prompt=select_account`, `scope=openid email profile`; result posted to `POST /api/auth/google-native {code, code_verifier, nonce}`. | Client id / redirect / callback scheme match `server.mjs:13563-13564` byte-for-byte; `Info.plist` registers the scheme. |
| Auth UI | `AuthView` sheet: brand header, sign-in / sign-up segmented mode (stacked at accessibility sizes), Google button, email/password/(name, confirm) fields, inline error banner, "Continue as guest", verification card (email + manual check + back), signed-in card (Done). Localized via `Localizable.xcstrings` (23 `auth.*` keys, en + ar). Sets its own `\.locale` / `\.layoutDirection` / colour scheme / `.presentationSizing(.form)`. | No forgot-password, no resend link, no terms/privacy link, no Sign in with Apple, no sign-out on this screen. |
| Models | `User` (id, name, email, admin, sub, guest?), `Subscription` (plan lenient-decoded, `expiresAt: Double?` ms, daysLeft?, limits/used/remaining `UsageCounts` with `Int`s incl. `-1`), request/response DTOs for every auth call, `AppAPIValue` JSON enum, `ModelTier` mini/pro/ultra/max with ar/en labels + taglines, `ProductKind` ai/code/agent/brain. | Shapes match `publicUser`/`subInfo`/`guestSubInfo` (`server.mjs:1386-1426`, `1185-1193`). |
| App root | `FirasAIApp` builds `FirasAPI(.live)`, `SessionStore`, five feature stores, `NotificationCoordinator.shared`, `MentronXEntryCoordinator`; injects via `.environment`. `AppConfiguration.live` reads `FIRAS_API_BASE_URL` (https only, or http localhost) with fallback `https://firasai.org`. | No `onOpenURL`, no `scenePhase` handling, no universal links. |

Cookie persistence check: **works**. `HTTPCookieStorage.shared` persists cookies that carry `Max-Age`
(`firas_session` 30 d, `firas_guest` 7 d, both host-only for `firasai.org`, `Secure` on Fly) to disk
across launches; `LiveVoiceController` and `PushRegistrationClient` build their own sessions but point at
the same shared jar, so the three clients share identity. `Set-Cookie … Max-Age=0` on logout /
delete-account is honoured by the jar (cookie removed).

Guest flow check: **correct against the server**. `restore()` maps `401 {"error":"not authenticated"}`
from `/api/auth/me` to `POST /api/guest`, which reuses an existing valid guest cookie (idempotent,
`server.mjs:2017-2027`), so the same `g_…` id and daily meter survive relaunches. After login the
stale guest cookie stays in the jar; the server's `callerOf` prefers the member cookie (`server-misc.md`
§0.2), so that is harmless.

Google flow check: **correct against `handleGoogleNativeAuth`**. Verifier is 43 base64url chars (matches
`/^[A-Za-z0-9._~-]{43,128}$/`), nonce 43 chars (matches `/^[A-Za-z0-9_-]{16,256}$/`), code is bounded,
server exchanges with the same `redirect_uri`, verifies `aud`, `azp`, `iss`, `exp`, `nonce`,
`email_verified`, then issues the ordinary session cookie. The app never receives a Google token.

---

## B. Findings

Severity: **critical** (blocks use / data loss), **major** (owner-visible defect or missing web parity),
**minor** (polish / hygiene). Categories as requested.

### B1. Session lifecycle

**F1 — major — freeze-or-main-thread / ux — `SessionStore.swift:41-62`, `FirasAppShell.swift:59-62`**
Evidence: `restore()` catches any non-401 error by setting `phase = .restoring` and `errorMessage`, but
the only caller (`FirasAppShell.task`) runs once on appear and the shell never renders
`session.errorMessage` (only `AuthView` and the Settings views do). With `waitsForConnectivity = true`
and `timeoutIntervalForResource = 180` (`APIClient.swift:61-63`) an offline launch sits silently for up to
three minutes, then lands in a permanent limbo: `identityID == nil`, `isGuest == false`,
`isAuthenticated == false`, chats never load, sends go out without any cookie and get 401. The owner's
"the app freezes" report matches this exactly (no spinner, no error, nothing tappable that helps).
Fix: (1) treat `.restoring` as a real UI state in the shell — a branded splash with a "تعذّر الاتصال…
أعد المحاولة" banner bound to `session.errorMessage` and a Retry button; (2) re-run `restore()` on
`scenePhase == .active` and when `NWPathMonitor` reports connectivity, guarded by `phase == .restoring`;
(3) for the bootstrap call use a short timeout (`timeoutIntervalForResource` ≈ 15 s) or a per-request
`URLRequest.timeoutInterval` and do not `waitsForConnectivity` on it; (4) if `/api/auth/me` fails with
5xx/503 (server restart) fall through to the guest path after N retries rather than staying in limbo.

**F2 — major — contract-mismatch / ux — `SessionStore.swift` (missing method), all stores**
Evidence: the web client centralises "a 401 after boot means the session died" in
`apiJson → handleSessionExpired()` (`app.js:3221`, `3239-3251`): abort streams, clear user, toast
`انتهت جلستك. الرجاء تسجيل الدخول من جديد.`, show auth. The server revokes cookies on password change /
reset / logout-everywhere via `sessVer` (`server.mjs:1098-1117`) and the cookie expires after 30 days.
On iOS nothing observes a member 401: `ChatStore.loadConversations` just sets its own `errorMessage`
(`ChatStore.swift:85-88`), `SessionStore` keeps `phase == .authenticated`, push stays registered, and
every screen shows a signed-in shell whose every call fails. Fix: add
`func handleUnauthorized(source:)` to `SessionStore` (idempotent, ignored while `.guest`/`.restoring`,
sets a localized `sessionExpired` notice, calls `NotificationCoordinator.sessionDidEnd()`, then
`establishGuestSession()`); have `APIClient` surface 401 distinctly (it already does via
`APIError.httpStatus(401, _)`) and have each store's `message(for:)` call the hook when
`session.isAuthenticated`. Also re-validate with `/api/auth/me` on `scenePhase == .active` when the last
check is older than ~10 minutes.

**F3 — major — missing-feature-vs-web / ux — `AuthView.swift:565-636`, `SessionStore.swift:135-157`**
Evidence: the web polls `/api/auth/verify-status` every 3 s while the verification card is visible
(`app.js:46551-46573`) so the device signs in the moment the emailed link is opened anywhere; it also
offers "resend link" (`/api/auth/resend-code`, `app.js:46577-46600`) with a 30 s countdown. iOS shows
a static card and requires the user to tap "تحققت من بريدي" (`AuthView.swift:604-625`); there is no
resend. The emailed link (`https://firasai.org/?verify=TOKEN`, `server.mjs:1884`) opens Safari, not the
app (no associated domains, no `onOpenURL`), so the user signs in on the website and must come back and
tap. Fix: `.task(id: pendingSignup?.pid)` loop in `VerificationCard` polling every 3 s (stop on
`verified`, `gone`, `expired`, or when the view disappears), resume the loop on `scenePhase == .active`;
add `resendVerification(email:)` to `FirasAPI` (`POST /api/auth/resend-code {email}`) with the same
countdown; optionally add `webcredentials:`/`applinks:firasai.org` associated domains + `onOpenURL` that
calls the already-written `session.verifySignup(token:)` (`SessionStore.swift:159-171`, currently dead).

**F4 — major — missing-feature-vs-web — `AuthView.swift` (absent), `FirasAPI.swift` (absent)**
Evidence: the server has `POST /api/auth/forgot {email}` and `POST /api/auth/reset {uid, token,
password}` (`server.mjs:13827-13828`; web UI `app.js:46626-46740`). iOS has no "نسيت كلمة المرور؟" link,
no request/reset screens, and no deep-link handling for `?reset=&uid=`. A member who forgets a password
has no in-app recovery. Fix: add `forgotPassword(email:)` and `resetPassword(uid:token:password:)` to
`FirasAPI`; add a `ForgotPasswordSheet` (email → "check your inbox") and a reset form reachable from a
universal link; until universal links exist, at least the forgot request is one screen.

**F5 — major — ux — `FirasAppShell.swift:188-191, 192-195`, `AuthView.swift:41-45, 638-674`**
Evidence: the sidebar account pill and every `onOpenProfile` open `.authentication`, which for a
signed-in member renders `AuthenticatedCard` — "تم تسجيل دخولك / Done" — and nothing else: no
sign-out, no plan/usage meter, no account actions. `auth.signOut` exists in `Localizable.xcstrings` but
is unused; sign-out lives three taps away under Settings → Account. Fix: when
`session.isAuthenticated`, route the profile affordance to `AccountSettingsView` (or make the
signed-in state of `AuthView` a real account card: avatar/initial, name, email, plan badge from
`user.sub.plan`, usage rows from `used/limits` with `-1` rendered as "بلا حدّ", Sign out, Manage account).

**F6 — minor — ux — `SessionStore.swift:298-317`, `FirasAPI.swift:181-183`, web `app.js:47132-47153`**
Evidence: after sign-up/login from a guest session the web migrates local guest chats to the account
(`POST /api/chats` each) then `DELETE /api/guest`; iOS never calls `endGuestSession()` and has no
migration hook in `applyAuthenticatedUser`. Whether guest chats survive is the chat group's call, but the
session layer offers no event for it. Fix: emit `didTransitionGuestToMember(previousGuestID:)` (or an
`onAuthenticated` callback) from `applyAuthenticatedUser` and call `endGuestSession()` after migration.

**F7 — minor — ux — `SessionStore.swift:145-150`**
Evidence: hard-coded Arabic strings (`انتهت صلاحية رابط التحقق…`) are shown regardless of
`PreferencesStore.language`; the English UI gets Arabic here while every other auth string is
localized through xcstrings. Fix: move both to `Localizable.xcstrings` keys and resolve through the
active language (pass `language` into `SessionStore` or return an enum the view localizes).

### B2. Error mapping (Arabic)

**F8 — major — rtl-arabic / ux — `SessionStore.swift:341-346`, `APIClient.swift:161-165, 168-175`**
Evidence: `message(for:)` returns the server's `error` string verbatim. For auth those are English:
`invalid email or password` (`server.mjs:1996`), `email already registered` (`1874`), `name is
required`, `a valid email is required`, `password must be at least 8 characters` (`1871-1873`),
`too many attempts, please wait a minute` (`1860`, `1981`, `13675`), `google authentication failed`
(`13688-13690`), `google unavailable`, `invalid oauth parameters`, while account-management errors are
Arabic (`كلمة المرور الحالية غير صحيحة`, `هذا الحساب يسجّل عبر Google…`, `2262-2287`). Transport errors
use `URLError.localizedDescription`, which follows the **device** language, not the app's. Result: an
Arabic UI shows English login errors and an English UI shows Arabic account errors. (The website has the
same verbatim behaviour, so this is parity, but it is the first thing a new user sees.) Fix: add an
`AuthErrorMapper` keyed on `(statusCode, serverError)` → xcstrings key: 401 login → `auth.error.credentials`
("البريد أو كلمة المرور غير صحيحة"), 409 → `auth.error.emailTaken`, 429 → `auth.error.tooManyAttempts`,
400 name/email/password → the matching field message, 502/503 → `auth.error.serverBusy`, `URLError`
`.notConnectedToInternet/.timedOut/.cannotFindHost` → `auth.error.offline` ("تعذّر الاتصال بالخادم.
تحقّق من اتصالك." — the web's `authNetworkError`, `app.js:927`); fall back to the server text only for
unknown codes. Keep the server's Arabic strings for the Google-account cases (they are already Arabic)
but add English equivalents.

**F9 — minor — ux — `AuthView.swift:465-487`**
Evidence: after `signInWithGoogle` any error is replaced by the generic `auth.google.error`. That hides
actionable server answers: 409 "account exists but the address was never confirmed — sign in with your
password" (`server.mjs:13695-13699`), 429 rate-limit, 502 "google unavailable". Fix: keep the
`session.errorMessage` (mapped through F8) and only use `auth.google.error` for `GoogleOAuthError`
cases.

**F10 — minor — accessibility — `AuthView.swift:676-705`**
Evidence: `AuthErrorBanner` appears via transition but is never announced; VoiceOver users do not hear
why the sign-in button did nothing. Fix: on change of `session.errorMessage` post
`AccessibilityNotification.Announcement(message).post()`, and give the banner
`.accessibilityAddTraits(.updatesFrequently)` or move focus with `@AccessibilityFocusState`.

### B3. Networking / transport

**F11 — major — background-cloud-first — `APIClient.swift:57-64`, `FirasAIApp.swift` (absent)**
Evidence: one foreground `URLSessionConfiguration.default`; no `background(withIdentifier:)` session,
no `BGAppRefreshTask`/`BGProcessingTask` registration anywhere in the app, no `beginBackgroundTask`.
The server does keep jobs running (cloud-first is honoured server-side), but the moment iOS suspends
the app every in-flight poll/download dies with `URLError.cancelled`/`networkConnectionLost` and no
progress is observed until the next foreground. Media downloads (`download(path:)` reads the whole
body into memory, `APIClient.swift:110-137`) cannot survive suspension either. Fix: (1) keep the
foreground actor for JSON, but add a `URLSession.background` for `/api/agent/artifact`,
`/api/video/file`, `/api/music/file`, `/api/image?key=` with a delegate that hands finished files to the
stores; (2) register a `BGAppRefreshTask` that runs one status poll per active durable job and posts a
local notification if the server push is not configured (entitlements are empty today, so APNs never
registers); (3) on `scenePhase == .active` the stores already resume — make `APIClient` expose a
`connectivityDidChange` hook so a resumed poll does not wait 45 s to fail.

**F12 — minor — freeze-or-main-thread / ux — `APIClient.swift:61-63`**
Evidence: the same 45 s / 180 s / `waitsForConnectivity` applies to a 2 KB login POST, a 30 MB base64
Brain upload, a 3 s job poll, and a multi-megabyte video download. Interactive calls wait far too long
when offline (see F1); large uploads/downloads on slow cellular can exceed 180 s and abort mid-transfer.
Fix: per-call budgets — `URLRequest.timeoutInterval` 15 s for auth/guest/me, 30 s for polls, and a
separate session (or `timeoutIntervalForResource = 0`/hours) for uploads and media downloads; keep
`waitsForConnectivity` only on polls.

**F13 — minor — contract-mismatch — `APIClient.swift:192-194`**
Evidence: `URLComponents.queryItems` does not percent-encode `+` in values; the server parses with
`URL.searchParams`, which decodes `+` as a space. A web search for `C++` reaches the server as `C  `.
Fix: build the query string with `components.percentEncodedQueryItems` and encode values using a
`CharacterSet.urlQueryAllowed.subtracting("+&=")`.

**F14 — minor — ux — `APIClient.swift:145-149`, `PushRegistrationClient.swift:125-129`**
Evidence: every decoding failure is collapsed to "The server response did not match the expected
format." — the underlying `DecodingError` (which key, which type) is discarded, so a schema drift on
the server is undebuggable from a device and costs a CI cycle to reproduce. Fix: keep the user-facing
string but attach `String(describing: error)` in a `debugDescription` field on `APIError.decoding` and
log it (`os.Logger`) in DEBUG.

**F15 — minor — ux — `FirasAPI.swift:220-237`**
Evidence: `makeChatBackup` fetches every conversation sequentially (N+1, `try?` swallowing failures
silently). 200 chats × ~300 ms = a minute-long spinner with no progress. Fix: `withTaskGroup` with
concurrency 4, a progress callback for `DataSettingsView`, and report the count of chats that failed.

### B4. Google / OAuth

**F16 — minor — security / hygiene — `FirasAPI.swift:24-36, 42-65`, `AuthModels.swift:400-422`,
`SessionStore.swift:85-97`**
Evidence: `signInWithFirebaseIDToken` and `exchangeGoogleAuthorizationCode` are unreachable (no
Firebase SDK is linked — the only package is ZIPFoundation, `project.pbxproj:352-366`) and the latter
targets `/api/oauth/google/exchange`, which the server labels "compatibility endpoint for early native
builds… new builds use /api/auth/google-native so the raw ID token never returns to the app"
(`server.mjs:13704-13705`). Leaving a raw-ID-token path compiled into the binary invites its reuse.
Fix: delete both methods, their DTOs and `SessionStore.signInWithFirebaseIDToken`.

**F17 — minor — compile-risk — `GoogleOAuthProvider.swift:221-225`, `145-148`**
Evidence: `presentationAnchor(for:)` is `@MainActor` (class isolation) but satisfies a nonisolated
requirement of `ASWebAuthenticationPresentationContextProviding`; under Swift 5 mode this is a warning
("main actor-isolated instance method cannot be used to satisfy nonisolated requirement… error in
Swift 6"), not an error, and CI does not treat warnings as errors — so it builds, but it is a latent
break for the next mode switch. The `ASWebAuthenticationSession(url:callbackURLScheme:)` initializer is
deprecated since iOS 17.4 (warning). Fix: `nonisolated func presentationAnchor(for:) -> ASPresentationAnchor
{ MainActor.assumeIsolated { presentationAnchorProvider() } }` and use
`ASWebAuthenticationSession(url:callback: .customScheme(configuration.callbackScheme))`.

**F18 — major — missing-feature-vs-web / ux — `AuthView.swift` (absent), server (absent)**
Evidence: the app offers Google as a third-party login and nothing else. App Store Review Guideline
4.8 requires an equivalent privacy-preserving option (Sign in with Apple) whenever a third-party login
is offered. The current CI produces an unsigned sideload IPA, so this does not block *today's*
distribution, but it blocks any TestFlight/App Store path and it is the sign-in most iPhone users
expect. Fix: add `ASAuthorizationAppleIDProvider` flow on the client and a server route
`POST /api/auth/apple {identityToken, nonce}` mirroring `handleGoogleNativeAuth` (verify against
`https://appleid.apple.com/auth/keys`, `aud` = bundle id, nonce check, link by email). Needs the
`com.apple.developer.applesignin` entitlement.

**F19 — minor — visual-design — `AuthView.swift:516-518`**
Evidence: the Google button draws a bold "G" in the accent colour instead of the Google "G" mark.
Google's brand rules allow either the official logo asset or plain text without a fake glyph.
Fix: embed the official multicolour "G" as an asset (SVG → PDF in Assets), or use the text-only
"المتابعة باستخدام Google" without the letter.

### B5. Models / decoding

**F20 — minor — contract-mismatch — `AuthModels.swift:370-377`**
Evidence: OK against the server — `expiresAt` is `Double?` (ms epoch or `null`), `daysLeft` `Int?`,
`limits/used/remaining` `Int` (server sends `-1` for unmetered members, `PLAN_LIMITS`
`server.mjs:1347-1357`). Nothing renders `-1` specially in this group; whichever view shows the meter
must map `-1` → "بلا حدّ". `SubscriptionPlan` unknown → `.free` is a good leniency choice. No change
needed here; recorded so the settings group does not "fix" it into a crash.

**F21 — minor — compile-risk / hygiene — `CommonModels.swift:590-598`**
Evidence: `ModelTier.label(language:)` and `tagline(language:)` are marked `@MainActor`, presumably
because `AppLanguage` was MainActor-inferred under the old default. `AppLanguage` is a plain
`Sendable` enum (`FirasTheme.swift:136`), so the annotation now needlessly forbids calling these from a
nonisolated context (a `Task.detached` building rows, a `nonisolated` formatter). Fix: drop `@MainActor`
from both.

**F22 — minor — hygiene — every model file**
Evidence: `nonisolated` on top-level structs/enums (SE-0449) is accepted by the Swift 6.2 compiler in
5.0 mode and is now redundant with the project default. Harmless; keep it if the project may return to
default-MainActor, otherwise remove for noise.

### B6. App root / configuration

**F23 — major — missing-feature-vs-web — `FirasAIApp.swift:270-313`, `FirasAI.entitlements`**
Evidence: no `onOpenURL`, no `applinks:`/`webcredentials:` associated domains. Consequences: the
verification and reset e-mails open Safari (F3/F4); shared chats `?share=<id>` open the website; password
AutoFill cannot associate saved `firasai.org` credentials with the app (so the sign-in form gets no
saved-password suggestions). Fix: add associated domains (`applinks:firasai.org`,
`webcredentials:firasai.org`) + AASA on the server (`/.well-known/apple-app-site-association`, served by
`serveStatic`), and `.onOpenURL` routing `?verify=`, `?reset=&uid=`, `?share=`.

**F24 — minor — ux — `FirasAIApp.swift`, `SessionStore.swift`**
Evidence: no `@Environment(\.scenePhase)` at the root; only `MediaStudioScreen` observes it. Session
re-validation and the F1 retry have nowhere to hang. Fix: root-level `.onChange(of: scenePhase)` that
calls `session.applicationDidBecomeActive()` (retry restore if `.restoring`; revalidate `/me` if stale).

**F25 — minor — security — `AppConfiguration.swift:231-246`, `Info.plist:34-41`**
Evidence: OK — https enforced, `http` only for localhost, ATS `NSAllowsLocalNetworking` only. No
`NSAllowsArbitraryLoads`. Nothing to fix; recorded as verified.

### B7. Compile-risk sweep for the Swift 5 / nonisolated switch (this group)

Verified as safe without edits:
- `SessionStore`, `GoogleOAuthProvider`, `PreferencesStore`, `NotificationCoordinator`,
  `MentronXEntryCoordinator` carry explicit `@MainActor`.
- `FirasAIApp` inherits MainActor from `App`; `AuthView`/`FirasRootView` from `View`
  (both protocols are `@MainActor` in the iOS 18+ SDK), so their `Task { … }` closures and
  `@State` mutations stay on the main actor.
- `FirasAPI.init(configuration:)` is `@MainActor` and every caller (App init, `SessionStore.init`
  default argument) is MainActor.
- `APIClient` is an actor; `PushRegistrationClient` is an actor; models are `Sendable`.

Watch items: F17 (warning today), F21 (unneeded isolation), and any future caller of
`ModelTier.label(language:)` from a nonisolated context.

---

## C. Keep / rewrite verdict per file

| File | Verdict | Why |
| --- | --- | --- |
| `Networking/APIClient.swift` | **Keep, extend** | Correct cookie handling, clean error envelope, safe filename parsing. Add per-call timeouts (F12), query encoding (F13), decoding diagnostics (F14), a background session for media (F11). |
| `Networking/FirasAPI.swift` | **Keep, prune + extend** | Paths/fields match the server for every live call. Delete the two dead Google/Firebase methods (F16); add forgot/reset/resend (F3, F4), `redeem`, `agent/credits`, `memory`, `share`, `translate`, `transcribe`, `tts`, `image/edit`, `image/quota`, `brain/whole`, `chat/job/file` — the "backend not fully used" complaint is real: 33 of ~70 routes are reachable from the app. |
| `Networking/GoogleOAuthProvider.swift` | **Keep** | Correct PKCE/state/nonce, cancellation-safe continuation, matches server constants. Apply F17 (small). |
| `Stores/SessionStore.swift` | **Rewrite the lifecycle, keep the calls** | The API calls are right; the state machine is not: limbo on transport failure (F1), no session-expiry hook (F2), manual verification (F3), no foreground revalidation (F24), Arabic hard-codes (F7), verbatim server errors (F8), no guest→member transition event (F6). Replace the single `isWorking` flag with per-operation state so a stuck `restore()` cannot block `login()`. |
| `Features/Auth/AuthView.swift` | **Keep the shell, redesign the content** | Solid form mechanics (focus order, RTL email field, accessibility-size selector, form sizing on iPad). Missing forgot/resend/Apple/terms (F3, F4, F18), wrong signed-in state (F5), generic Google errors (F9), unannounced errors (F10), fake "G" (F19). Visually: the glass card is fine but the fields are opaque `surfaceSunken` slabs inside it — on iOS 26 use `.glassEffect(.regular.interactive())` for fields and buttons so the card reads as glass, not a grey form. |
| `Models/AuthModels.swift` | **Keep, prune** | Matches `publicUser`/`guestSubInfo`. Remove the Firebase/Google-exchange DTOs (F16). |
| `Models/CommonModels.swift` | **Keep** | `ModelTier` mini/pro/ultra/max already modelled with Arabic labels. Drop the two `@MainActor`s (F21). |
| `App/AppConfiguration.swift` | **Keep** | Correct and minimal. |
| `App/FirasAIApp.swift` | **Keep, extend** | Composition root is fine; add `onOpenURL`, `scenePhase`, background-task registration (F11, F23, F24). |

---

## D. Owner's complaints — what this group can answer

| Complaint | Finding |
| --- | --- |
| Design mediocre / glass not transparent enough | Auth sheet uses `GlassSurface(tintStrength: 0.07)` (translucent) but fills every field and the Google button with opaque `palette.surface`/`surfaceSunken` (`AuthView.swift:527-529, 718-721`), which is what makes the card read as a flat form. Owned mostly by the DesignSystem group; the fix in this file is F19 + material/glass fields. |
| Code, Agent, Brain are thin | Not this group, but the facade confirms it: no `/api/agent/credits`, `/api/agent/job-stream`, `/api/brain/whole`, `/api/chat/job/file`, `/api/translate`, `/api/transcribe`, `/api/tts`, `/api/image/edit` in `FirasAPI`. |
| Backend/APIs not fully used | Confirmed: ~33 of ~70 routes wired; auth alone is missing forgot, reset, resend-code, redeem, Apple. Two wired auth routes are dead code. |
| The call kicks the user out and the app freezes | The "kicked out / frozen" symptom has a session-layer cause in F1 (limbo with no UI after a failed or slow `/me`) and F2 (silent member 401 leaves a dead shell). The voice-call specifics are the voice group's. |
| Things must keep working after leaving the app | Server side is cloud-first; client side has no background session, no BGTask, no APNs entitlement (F11, empty entitlements). |
| Notification when a job finishes, haptic before completion | `SessionStore` correctly registers/unregisters push on auth changes, but `aps-environment` is absent from `FirasAI.entitlements`, so `didRegisterForRemoteNotifications` never fires in a signed build — push cannot work until the entitlement (and a signing profile with Push) exists. |
| Mic dictation, Auto/Plan modes, mini/pro/ultra/max | `ModelTier` exists with the four tiers and Arabic copy (`CommonModels.swift:546-599`). Dictation/modes are other groups. |
| Professional on iPhone and iPad | Auth sheet uses `.presentationSizing(.form)` and accessibility-size layout — good. The signed-in "profile" that is really a sign-in screen (F5) and English error text in the Arabic UI (F8) are the two things a first-time user hits on both devices. |

---

## E. Open questions

1. Does the production server run with `TRUST_PROXY=1`? If not (per `server-misc.md` §14) every iOS guest
   shares one "network" bucket and guests will see `scope:"network"` 429s that the app currently shows
   verbatim.
2. Will the app ever ship through TestFlight/App Store? If yes, F18 (Sign in with Apple) and F23
   (associated domains) become blocking and need server work (`/api/auth/apple`, AASA file).
3. Are guest chats meant to migrate on sign-up (web does)? Decides whether F6 is a hook or a full feature.
4. Should the auth error copy follow the web's verbatim-server-string behaviour (parity) or the mapped
   localized table in F8? Recommendation: mapped, because iOS has no toast to soften it.
