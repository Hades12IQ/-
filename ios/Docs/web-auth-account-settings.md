# Web client slice: auth, guest trial, account, settings, announcements, share

Native spec for the iOS/iPadOS rewrite. Derived from the deployed web client
(`app.js`, `index.html`, `firebase-config.js`) and the source-of-truth server
(`server.mjs`). Every line-number citation is `file:line` in the repo root at the
time of writing; line numbers drift, names do not.

Conventions used below:

- **member cookie** = `firas_session` (HttpOnly; issued by login/signup-verify/reset/Google).
- **guest cookie** = `firas_guest` (HttpOnly; issued by `POST /api/guest`).
- **none** = public, no cookie needed.
- Arabic strings are verbatim from the code. `ar:` / `en:` pairs are the two UI languages.
- Error bodies are always JSON `{ "error": "<string>" }` unless noted; the web client displays
  `data.message || data.error` when a status is present, and `authNetworkError` when the fetch
  itself threw (`app.js:46780-46788`).

---

## 0. Transport and session model (read this first)

### 0.1 Cookies, not tokens

There is **no bearer-token support anywhere in `server.mjs`**. `currentUser(req)` reads only the
`Cookie` header (`server.mjs:1098-1113`); `currentGuest(req)` likewise (`server.mjs:1156-1161`). A
grep for `authorization`/`bearer` finds only outbound calls to Google/APNs. The native app must
therefore use a cookie-persisting `URLSession` (shared `HTTPCookieStorage`) and send cookies on
every `/api/*` request. The existing `ios/FirasAI/Stores/SessionStore.swift` already works this way.

| Cookie | Set by | Attributes | Lifetime | Cleared by |
| --- | --- | --- | --- | --- |
| `firas_session` | `setSessionCookie` `server.mjs:1056-1066` | `HttpOnly; SameSite=Lax; Path=/; Max-Age=2592000` + `Secure` when `x-forwarded-proto: https` or `SECURE_COOKIES=1` (`server.mjs:1052-1054`) | 30 days | `POST /api/auth/logout`, `POST /api/auth/delete-account` (`clearSessionCookie` `server.mjs:1068-1071`) |
| `firas_guest` | `setGuestCookie` `server.mjs:1162-1169` | same flags, `Max-Age=604800` | 7 days | `DELETE /api/guest` (`server.mjs:2029-2033`) |

Cookie value = `<payload>.<hmac-sha256-hex>`; payload is `<userId>` or `<userId>|v<N>` where N is
the account's `sessVer` (`server.mjs:997-1051`). **Session revocation:** `bumpSessionVersion`
runs on password reset and password change (`server.mjs:2250, 2270`) — every other device's
cookie stops verifying (`currentUser` compares versions, `server.mjs:1111`). **Logout does NOT
bump the version** — it only clears this client's cookie (`server.mjs:2004-2007`). Rotating
`SESSION_SECRET` on the server logs everyone out.

A guest cookie value pasted into `firas_session` resolves to nothing (no DB user has a `g_` id).
When both cookies are present, the member wins (`callerOf`, `server.mjs:1314-1320`).

### 0.2 The global response handler (`apiJson`, `app.js:3216-3232`)

Every JSON call in the web client goes through one wrapper. Replicate its two side effects
centrally in the native API layer:

1. **`401` after boot ⇒ session expired** (`handleSessionExpired`, `app.js:3239-3250`).
   Only for a **member** (`state.user && !state.user.guest`), fires once per session: aborts all
   streams, clears user/chats, shows toast and returns to the auth screen.
   - toast ar: `انتهت جلستك. الرجاء تسجيل الدخول من جديد.`
   - toast en: `Your session expired. Please sign in again.`
   - A guest's 401s are ignored (members-only routes legitimately 401 a guest).
2. **`403` with body `{ error: "signin_required", feature?: "<name>" }` ⇒ open the sign-up
   upsell** (`openSignUpPrompt(data.feature || "")`, see §5.4). This is the single hook that
   drives every guest upsell. Server sites that emit it (`server.mjs`): image `3240, 3927, 5141,
   5219`; video `4739, 5310`; music `4879`; live call `6219` (`feature: "live"`); agent
   `7665, 8880`; brain `8345`; brain_whole `8977`. Some are streaming responses (`res.end(JSON)`),
   so the native SSE layer must also parse a non-2xx first frame for this shape.

The thrown error carries `.status` and `.data`; display precedence is
`data.message || data.error || "HTTP <status>"`.

### 0.3 `user` object (`publicUser`, `server.mjs:1424-1426`)

```json
{ "id": "uuid", "name": "Firas", "email": "x@y.z", "admin": false,
  "sub": { "plan": "free", "expiresAt": null, "daysLeft": null,
           "limits":    { "ai": -1, "code": -1, "agent": -1, "brain": -1 },
           "used":      { "ai": 3,  "code": 0,  "agent": 0,  "brain": 1 },
           "remaining": { "ai": -1, "code": -1, "agent": -1, "brain": -1 } } }
```

- `plan` ∈ `free | gold | diamond | unlimited` for members (`planOf`, `server.mjs:1361-1368`);
  all four have every limit `-1` = unlimited (`PLAN_LIMITS`, `server.mjs:1347-1352`). The site is
  free; paid tiers only survive for legacy records. `-1` in `remaining` means unlimited.
- `expiresAt` is epoch **milliseconds** or null; `daysLeft` is an integer or null.
- `admin` is true only when the email is in `ADMIN_EMAILS` (default `firasnozad@gmail.com`,
  `server.mjs:7533-7534`). It gates announcement authoring, the admin codes panel, and the KB.
- Guest variant (from `POST /api/guest`, `server.mjs:2017-2027`):
  `{ "id": "g_<24hex>", "name": "", "email": "", "guest": true, "admin": false, "sub": <guestSubInfo> }`
  where `guestSubInfo` (`server.mjs:1185-1194`) is
  `{ plan:"guest", expiresAt:null, daysLeft:null, limits:{ai:180,code:60,agent:24,brain:120}, used:{…}, remaining:{…} }`
  (limits from `GUEST_LIMITS`, env-overridable, `server.mjs:1133-1155`).
- `emailVerified` / `emailUnverified` / `provider` / `sessVer` are **never** sent to the client.

Existing Swift models in `ios/FirasAI/Models/AuthModels.swift` (`User`, `Subscription`,
`UsageCounts`, `SignupResponse`, `VerificationStatusResponse`, `GuestSessionResponse`,
`GoogleNativeAuthRequest`) already match these shapes.

### 0.4 Rate limiting (`rateLimited`, `server.mjs:1076-1088`)

In-memory sliding window per key; resets on server restart. All 429 bodies are
`{ "error": "<english string>" }`. Per-endpoint keys and limits are listed with each endpoint below.

---

## 1. Boot sequence and entry states (`init`, `app.js:79891-79966`)

Order on the web (what the native app must reproduce semantically):

1. Load device prefs from storage (`loadState`, `app.js:3152-3203`) with whitelisting.
2. Apply theme/UI2/font size/width/motion/enter-send/thinking/web-search/language/tier.
3. Deep links take over before the auth gate:
   - `/?verify=<token>` → `checkVerifyLink` (§3.5)
   - `/?reset=<token>&uid=<id>` → `checkResetLink` (§3.7)
   - Google redirect completion (web-only)
   - `/?share=<id>` → public read-only viewer (§10.3), no login.
4. Auth gate: `GET /api/auth/me`.
   - `200 {user}` → `bootApp(user)`.
   - `401` → if `firas_guest_active == "1"` in storage, `POST /api/guest` and boot as guest
     (`resumeGuestIfActive`, `app.js:79969-79983`); otherwise show the **landing**.
   - any other failure (network / 5xx) → show landing + toast: no `.status` ⇒ `authNetworkError`,
     else the server's `error` string.
5. `firas_had_session` = "1" is written on every boot and removed on logout; it only decides
   whether to play the MentronX intro animation before the `/api/auth/me` round trip
   (`app.js:47317-47323, 79944-79945`). Optional on native.

**First-launch consent gate** (`index.html:376-455`, key `firas_welcome_v1`): shown once to
everyone before anything else; a checkbox + "متابعة" button (disabled until checked).
Strings (Arabic only, no English version exists):

- Title: `أهلًا بك في فِراس AI`
- Lede: `منصّة ذكاء اصطناعي عربية أولًا من شركة مِنترونكس العراقية — مبنية للطلبة في العراق والعالم العربي.`
- Checkbox: `أوافق على شروط الاستخدام وسياسة الخصوصية.` (links `/terms`, `/privacy`)
- Button: `متابعة`
- Note: `قد يخطئ فِراس. تحقّق من المعلومات المهمة.`

**Cookie consent banner** (`index.html:564-571`, `app.js:46664-46695`, key
`firas_cookie_consent`): web-only, shown on the auth screen until a choice is saved. Values
`accepted` / `rejected`; nothing in the app reads the choice. Text ar:
`نستخدم الكوكيز لإبقائك مسجّل الدخول ولتحسين تجربتك. هل توافق؟` · buttons `أوافق` / `رفض`;
en: `We use cookies to keep you signed in and to improve your experience. Do you want to enable cookies?` · `Accept` / `Reject`. Not needed natively.

### bootApp (`app.js:47171-47216`)

Sets `state.user`, re-arms the session-expiry guard, applies identity, hides landing/auth,
renders the welcome screen, **migrates guest chats if the new user is a member** (§5.6), fetches
chats, reattaches background jobs, and fires `fetchAnnouncements()` for the unread dot (§9.1).

---

## 2. Landing screen (logged-out hero) — `index.html:477-501`, strings `app.js:672-745 / 1770-1835`

| Element | ar | en |
| --- | --- | --- |
| `landingAbout` | `أربعة منتجات بحساب واحد: محادثة، ووكيل ينفّذ المهام الطويلة خطوة بخطوة، وبيئة برمجة كاملة داخل المتصفح، ومكتبة تقرأ ملفاتك وتجيب منها — مع رقم الصفحة، حتى تتحقّق بنفسك.` | `Four products, one account: chat, an agent that works through long tasks step by step, a full development environment in the browser, and a library that reads your own files and answers from them — with the page number, so you can check it yourself.` |
| `landingStart` (primary CTA → guest trial, `startGuestSession`) | `ابدأ الآن — بدون حساب` | `Get Started — no account` |
| `landingSignIn` (→ auth screen, login mode) | `لديك حساب؟ تسجيل الدخول` | `Already have an account? Sign in` |
| `landingGuestHint` | `ادخل فورًا وجرّب فِراس. سجّل لاحقًا لحفظ محادثاتك.` | `Jump straight in and try Firas. Sign up later to save your chats.` |
| `landingScale` (4 marks) | AI `محادثة` · Agent `مهام كبيرة` · Code `برمجة` · Brain `وثائقك` | AI `Chat` · Agent `Big tasks` · Code `Building` · Brain `Your documents` |
| `landingFeaturesTitle` | `لماذا فِراس AI؟` | `Why Firas AI?` |
| `landingFeaturesSub` | `منصّة ذكاء اصطناعي متكاملة، تتحدّث العربية والإنجليزية بطلاقة — كل ما تحتاجه في مكان واحد.` | `A complete AI platform — fluent in Arabic and English, with everything you need in one place.` |

`landingFeatures` (7 cards, icon key → title / desc), ar then en:

1. spark — `أربعة نماذج ذكية` / `«ميني» للسرعة، و«برو» للمهام اليومية، و«أولترا» للأسئلة الصعبة والبرمجة، و«ماكس» الأقوى للأسئلة الصعبة والتحليل العميق في كل المجالات.` — `Four smart models` / `“Mini” for speed, “Pro” for everyday tasks, “Ultra” for hard questions & coding, and “Max” — the strongest for hard questions & deep analysis across every field.`
2. code — `فِراس Code — برمجة كاملة بالمتصفح` / `بيئة تطوير حقيقية داخل التطبيق: مشاريع متعددة الملفات، ومعاينة حيّة — صِف فكرتك ويبنيها فِراس.` — `Firas Code — a full in-browser IDE` / `A real dev environment inside the app: multi-file projects and live preview — describe your idea and Firas builds it.`
3. devices — `فِراس Agent — وكيل المهام الكبيرة` / `يخطّط وينفّذ خطوة بخطوة ويراجع عمله بنفسه، ثم يسلّمك ملفات ومشاريع كاملة جاهزة للتسليم.` — `Firas Agent — for big tasks` / `Plans, executes step by step, reviews its own work, then hands you complete, ready-to-submit files and projects.`
4. brain — `فِراس Brain — يجيب من ملفاتك أنت` / `ارفع كتبك ومحاضراتك وامتحاناتك — بصيغها المختلفة، حتى المصوّرة — واسأل. الجواب يأتي من داخل ملفك مع اسم الملف ورقم الصفحة، تضغط عليه فيفتح لك النص نفسه.` — `Firas Brain — answers from your own files` / `Upload your books, lectures and past papers — any format, including scans — and ask. The answer comes from inside your file, with the filename and page number; click it and the passage itself opens.`
5. file — `ملفات وامتحانات جاهزة` / `يولّد PDF وWord وExcel وPowerPoint بخطوط عربية أنيقة — وأسئلة مع حلولها بتنسيق ورقة امتحان حقيقية.` — `Ready files & exam papers` / `Generates PDF, Word, Excel and PowerPoint with elegant Arabic fonts — plus questions with solutions in a real exam-paper layout.`
6. search — `بحث الويب المباشر` / `يجلب معلومات حديثة من الإنترنت ويجيبك مع ذكر المصادر القابلة للنقر.` — `Live web search` / `Pulls fresh information from the internet and answers with clickable sources.`
7. bulb — `وضع التفكير` / `تحليل أعمق ودقّة أعلى عند تفعيله — مثالي للأسئلة المعقّدة والمسائل المنطقية.` — `Thinking mode` / `Deeper analysis and higher accuracy when enabled — ideal for complex, logical problems.`

Image note: badge `تجريبي` / `Beta`; title `ميزة توليد الصور` / `Image generation`; body
`أُطلقت حديثًا وما زالت قيد التطوير، لذا قد تتحسّن النتائج تدريجيًا. الحدّ الحالي: ٥ صور في اليوم لكل مستخدم. جرّبها بكتابة «اصنع لي صورة…» داخل المحادثة.` /
`Recently launched and still under active development, so results will keep improving. Current limit: 5 images per day per user. Try it by typing “create an image of…” in the chat.`
(The "5 per day" claim is landing copy; the actual image quota is owned by the media slice.)

---

## 3. Auth screen (`index.html:504-560`, `app.js:46440-46600, 46696-46790`)

One card, four modes (`authMode`): `login` (default), `signup`, `verify`, `reset`.
Layout: brand logo (tap = back to landing, `#authBackLogo`), title, subtitle, **Google button +
"or" divider** (hidden in verify/reset), form fields, links, error (`role=alert`), note
(`role=status`), submit, switch row.

### 3.1 Strings (`app.js:850-954` ar, `1939-2043` en)

| key | ar | en |
| --- | --- | --- |
| authSignupTitle | `أنشئ حسابك` | `Create your account` |
| authLoginTitle | `مرحبًا بعودتك` | `Welcome back` |
| authSignupSubtitle | `ابدأ المحادثة مع فِراس.` | `Start your conversation with Firas.` |
| authLoginSubtitle | `سجّل الدخول لمتابعة محادثاتك.` | `Log in to continue your conversations.` |
| authName | `الاسم` | `Name` |
| authEmail | `البريد الإلكتروني` | `Email` |
| authPassword | `كلمة المرور` | `Password` |
| authSignupBtn | `إنشاء حساب` | `Create account` |
| authLoginBtn | `تسجيل الدخول` | `Log in` |
| authToLogin (switch text in signup) | `لديك حساب بالفعل؟` | `Already have an account?` |
| authToSignup (switch text in login) | `ليس لديك حساب؟` | `Don't have an account?` |
| authToLoginBtn | `تسجيل الدخول` | `Log in` |
| authToSignupBtn | `إنشاء حساب` | `Sign up` |
| authGenericError | `تعذّر إتمام العملية. حاول مرة أخرى.` | `Something went wrong. Please try again.` |
| authNetworkError | `تعذّر الاتصال بالخادم. تحقّق من اتصالك.` | `Couldn't reach the server. Check your connection.` |
| authForgot | `نسيت كلمة المرور؟` | `Forgot password?` |
| authForgotNeedEmail | `اكتب بريدك الإلكتروني أولاً.` | `Enter your email first.` |
| authForgotSent | `إذا كان البريد مسجّلاً، أرسلنا له رابط إعادة التعيين. تحقّق من بريدك (وصندوق الـ Spam).` | `If that email is registered, we sent a reset link. Check your inbox (and Spam).` |
| authResetTitle | `تعيين كلمة مرور جديدة` | `Set a new password` |
| authResetSubtitle | `اختر كلمة مرور جديدة لحسابك.` | `Choose a new password for your account.` |
| authResetBtn | `تعيين كلمة المرور` | `Set password` |
| authNewPassword | `كلمة المرور الجديدة` | `New password` |
| authResetDone | `تم تغيير كلمة المرور — سجّل الدخول الآن.` | `Password changed — sign in now.` |
| authResetInvalid | `الرابط غير صالح أو منتهي. اطلب رابطاً جديداً.` | `The link is invalid or expired. Request a new one.` |
| authVerifyTitle | `📧 تفقّد بريدك الإلكتروني` | `📧 Check your email` |
| authVerifySubtitle (+ " " + email) | `أرسلنا رابط التأكيد إلى` | `We sent a verification link to` |
| authVerifyWaiting | `افتح الرابط من بريدك واضغط الزر — وسيكتمل الدخول هنا تلقائياً (حتى لو فتحته من جهاز آخر). تحقّق من صندوق الوارد والـ Spam.` | `Open the link from your email and tap the button — this device will finish automatically (even if you open it on another device). Check your inbox and Spam.` |
| authVerifyBad | `رابط التأكيد غير صالح أو منتهي. أعد التسجيل من جديد.` | `The verification link is invalid or expired. Please sign up again.` |
| authResend | `إعادة إرسال الرابط` | `Resend link` |
| authBack | `‹ الرجوع لتسجيل الدخول` | `‹ Back to sign in` |
| authResendOk (toast) | `📧 أرسلنا رابطاً جديداً إلى بريدك` | `📧 We sent a new link to your email` |
| authResendWait | `انتظر قليلاً قبل إعادة الإرسال` | `Please wait before resending` |
| authCodeResent (note) | `أرسلنا رابطاً جديداً إلى بريدك.` | `We sent a new link to your email.` |
| authGoogle | `المتابعة عبر Google` | `Continue with Google` |
| authOr | `أو` | `or` |
| authGoogleError | `تعذّر تسجيل الدخول عبر Google. حاول مرة أخرى.` | `Couldn't sign in with Google. Please try again.` |
| authGoogleUnavailable | `تسجيل الدخول عبر Google غير متاح حاليًا.` | `Google sign-in is unavailable right now.` |
| authGoogleCancelled (defined, **unused** — cancel is silent) | `تم إلغاء تسجيل الدخول.` | `Sign-in cancelled.` |

Unused legacy keys (a 6-digit code UI that no longer exists — the code field `#authCode` is
always hidden, `app.js:46466, 46493, 46523`): `authVerifyBtn`, `authCode` (`رمز التحقق (٦ أرقام)`),
`authCodeInvalid`, `authCodeWrong`. **Signup verification is link-based, not code-based.**

Inline validation strings (not in STR):
- Password too short (signup and reset, checked client-side before the request): ar
  `كلمة المرور يجب أن تكون ٨ أحرف على الأقل.` en `Password must be at least 8 characters.` (`app.js:46727, 46764`)
- Empty required fields → `authGenericError` (`app.js:46759`).
- Signup success toast: ar `📧 أرسلنا إيميل التأكيد إلى <email>` en `📧 Verification email sent to <email>` (`app.js:46775`).

### 3.2 Mode layouts (`renderAuthCopy`, `app.js:46449-46527`)

| mode | visible | hidden |
| --- | --- | --- |
| login | email, password (`autocomplete=current-password`), Google + divider (if configured), `authForgot` link, submit `authLoginBtn`, switch row (`authToSignup` + `authToSignupBtn`) | name, code, resend, back |
| signup | name (required), email, password (`new-password`), Google + divider, submit `authSignupBtn`, switch row (`authToLogin` + `authToLoginBtn`) | forgot, code, resend, back |
| verify | title/subtitle+email, note `authVerifyWaiting`, `authResend`, `authBack` | every field, submit, Google, divider, switch row |
| reset | title/subtitle, password field relabelled `authNewPassword` (`new-password`), submit `authResetBtn`, `authBack` | name, email, code, Google, divider, forgot, resend, switch row |

`authBack` (inside `wireAuth`, `app.js:47563-47571`): clears reset/verify tokens, stops polling, clears the password
field, returns to `login`.

### 3.3 `POST /api/auth/login` (`server.mjs:1978-2002`) — auth: none

Body `{ "email": string, "password": string }` (email trimmed + lowercased server-side).

| status | body | UI |
| --- | --- | --- |
| 200 | `{ "user": <user> }` + `Set-Cookie: firas_session` | `bootApp(user)` |
| 400 | `{ "error": "invalid JSON body" }` | show `error` |
| 401 | `{ "error": "invalid email or password" }` | show `error` (server string; no localized map on the web — the native app may map 401 to a localized "wrong email or password") |
| 429 | `{ "error": "too many attempts, please wait a minute" }` — keys `auth:<ip>` 12/min and `login:<email>` 6/min | show `error` |

### 3.4 `POST /api/auth/signup` (`server.mjs:1859-1891`) — auth: none

Body `{ "name": string, "email": string, "password": string }`.
Server validation, in order: name trimmed, max 80, required → `400 {error:"name is required"}`;
email must match `^[^\s@]+@[^\s@]+\.[^\s@]+$` and ≤200 → `400 {error:"a valid email is required"}`;
password < 8 → `400 {error:"password must be at least 8 characters"}`; > 200 →
`400 {error:"password is too long"}`; existing email → `409 {error:"email already registered"}`;
rate `auth:<ip>` 12/min → 429 as above.

Success `200 { "ok": true, "pending": true, "email": "<lowercased>", "pid": "<32hex>" }`.
**No account exists yet and no cookie is set.** The server emails a link
`<APP_URL>/?verify=<token>` (subject `تأكيد حسابك — Firas AI`, button `تأكيد الحساب وبدء الاستخدام`,
valid 15 min = `VERIFY_TTL_MS`, `server.mjs:2045`). If no mail provider is configured the link is
only logged server-side.

Client on `pending` (`app.js:46772-46778`): store `_verifyEmail`, `_verifyPid`, switch to
`verify` mode, toast, start polling.

### 3.5 Verify flow

**Polling** (`startVerifyPolling`, `app.js:46553-46571`): every **3 s**,
`POST /api/auth/verify-status` body `{ "pid": string }` (`server.mjs:1920-1939`, rate
`vstatus:<ip>` 60/min → `429 {error:"too many requests"}`; `400 {error:"missing pid"}`):

| response | meaning | web behaviour |
| --- | --- | --- |
| `{ "verified": false }` | link not opened yet | keep polling |
| `{ "verified": false, "gone": true }` | pending record no longer exists (already completed elsewhere and cleaned, or restarted) | web keeps polling silently; native should stop and show `authVerifyBad` |
| `{ "verified": false, "expired": true }` | 15 min passed | same — native should stop and show `authVerifyBad` |
| `{ "verified": true, "user": <user> }` + `Set-Cookie` | link opened on any device | stop, `bootApp(user)` |

Polling stops when mode leaves `verify`. Errors are swallowed (keep polling).

**Link opened on this device** (`checkVerifyLink`, `app.js:46604-46626`): URL `/?verify=<token>` →
`POST /api/auth/verify-signup` body `{ "token": string }` (`server.mjs:1893-1918`, rate
`verify:<ip>` 30/min):

| status | body | UI |
| --- | --- | --- |
| 200 | `{ "ok": true, "user": <user> }` + cookie | `bootApp(user)`; idempotent — reopening the same link signs in again |
| 400 | `{ "error": "رابط غير صالح" }` (no token) / `{ "error": "الرابط غير صالح أو منتهي — أعد التسجيل" }` / `{ "error": "تعذّر التأكيد — أعد التسجيل" }` | show `authVerifyBad` |
| 409 | `{ "error": "email already registered" }` | note: ar `حسابك مُفعّل بالفعل — سجّل الدخول.` en `Your account is already active — please sign in.` |
| 429 | `{ "error": "too many attempts, please wait a minute" }` | ar `محاولات كثيرة — انتظر دقيقة ثم افتح الرابط مجدداً.` en `Too many attempts — wait a minute and reopen the link.` |

Native: register `https://firasai.org/?verify=…` as a universal link so the emailed button opens
the app; fall back to the web page (which signs that browser in — the app's poll then completes).

**Resend** (`handleResendCode`, `app.js:46575-46603`): `POST /api/auth/resend-code`
body `{ "email": string }` (`server.mjs:1941-1962`). Always `200 {ok:true}` (anti-enumeration),
`429 {error:"too many requests, wait a minute"}` at `resend:<ip>` 4/min. Web: button disabled,
toast `authResendOk`, note `authCodeResent`, button label becomes `authResend + " (30)"` counting
down 30 s (Arabic digits in ar UI); on 429 toast `authResendWait` and re-enable after 5 s.

### 3.6 Forgot password (`handleForgotPassword`, `app.js:46627-46645`)

Requires email in the field, else error `authForgotNeedEmail`. `POST /api/auth/forgot` body
`{ "email": string }` (`server.mjs:2215-2231`): always `200 {ok:true}`; `429 {error:"too many requests"}`
at `forgot:<ip>` 6/min. Mail is sent only for **password** accounts (Google accounts get nothing,
silently). Link `/?reset=<token>&uid=<userId>`, TTL 30 min (`RESET_TTL_MS`). Web shows
`authForgotSent` note **regardless of outcome**.

### 3.7 Reset password (`checkResetLink`, `app.js:46647-46657`; submit `app.js:46718-46740`)

Mode `reset` when URL has `reset` + `uid`. Submit: client-side min 8, then
`POST /api/auth/reset` body `{ "uid": string, "token": string, "password": string }`
(`server.mjs:2232-2255`, rate `reset:<ip>` 10/min):

| status | body |
| --- | --- |
| 200 | `{ "ok": true, "user": <user> }` + **cookie set (the server signs the user in and revokes all other sessions)** |
| 400 | `{ "error": "password must be at least 8 characters" }` / `{ "error": "password is too long" }` / `{ "error": "invalid or expired link" }` |
| 429 | `{ "error": "too many requests" }` |

Web quirk: on 200 it ignores the cookie/user, returns to `login` mode and shows the note
`authResetDone`. Native may boot directly from the returned `user`. On error: show
`data.message || data.error || authResetInvalid`.

### 3.8 Google sign-in

**Web** (`app.js:47218-47315, 47478-47530`): Firebase JS SDK 10.12.2 lazy-loaded from gstatic,
`GoogleAuthProvider` + `signInWithPopup` (redirect fallback), then `user.getIdToken()` →
`POST /api/auth/firebase` `{ "idToken": string }` (`server.mjs:2334-2400`). Button shown only when
`window.FIREBASE_CONFIG` has `apiKey`, `authDomain`, `projectId` (`firebase-config.js`; project
`firas-ai`, apiKey `AIzaSyDoRqmC70HTAgvZuFa1m9aOg9eBMyWSUeA`, authDomain = site host on deploy).
Firebase popup errors map: `auth/popup-closed-by-user`, `auth/cancelled-popup-request`,
`auth/user-cancelled` → silent; `auth/popup-blocked` → `authGoogleUnavailable`; other →
`authGoogleError`.

`/api/auth/firebase` responses: `200 {user}`; `501 {error:"social sign-in not configured"}`;
`400 {error:"invalid JSON body"}`; `401 {error:"invalid token"}`; `409 {error:"An account with this email already exists. Please sign in with your password, or verify your email first."}`
(unverified Firebase token against an existing account); `409 {error:"An account with this email already exists but the address was never confirmed. Please sign in with your password."}`
(account whose email was changed via change-email); `403 {error:"email verification required for this account"}`;
`429` `auth:<ip>` 12/min. Name precedence: token `name` → body `name` → email local-part (≤80).

**Native (use this)** — `POST /api/auth/google-native` (`server.mjs:13561-13707`), already
implemented in `ios/FirasAI/Networking/GoogleOAuthProvider.swift` + `SessionStore.signInWithGoogle`:

- Client ID `237562309958-p0njbmb5imqcfd6fk728ccr6lhesq03e.apps.googleusercontent.com`; redirect
  `com.googleusercontent.apps.237562309958-p0njbmb5imqcfd6fk728ccr6lhesq03e:/oauth2redirect`
  (single slash after the colon — must be byte-identical in authorize and token calls); scope
  `openid email profile`; `prompt=select_account`; PKCE S256; `state` + `nonce`.
- Body `{ "code": string(8..8192), "code_verifier": string matching ^[A-Za-z0-9._~-]{43,128}$, "nonce": string matching ^[A-Za-z0-9_-]{16,256}$ }`, JSON ≤ 20,000 chars.
- Server exchanges the code with Google (no client secret), verifies the OIDC id_token
  (RS256 via JWKS, `aud`/`azp` = client id, `iss` accounts.google.com, `nonce` match,
  `email_verified === true`), links by email or creates `{provider:"google"}`.
- Responses: `200 {user}` + cookie; `400 {error:"invalid JSON body"}` / `{error:"invalid oauth parameters"}`;
  `502 {error:"google unavailable"}`; `401 {error:"google authentication failed"}`;
  `409` the "never confirmed" message above; `429 {error:"too many attempts, please wait a minute"}` (`auth:google:<ip>` 12/min).
- User cancelling `ASWebAuthenticationSession` → silent (no error UI), matching the web.
- `/api/oauth/google/exchange` (`server.mjs:13711-13730`) is a compatibility endpoint returning the
  raw `{id_token}`; do not use it in new builds.

### 3.9 Google-account limitations that the account UI must respect

A user created via Google has no password (`passHash` absent). Consequences:
change-password → `400 هذا الحساب يسجّل عبر Google ولا يملك كلمة مرور`; change-email →
`400 هذا الحساب يسجّل عبر Google`; delete-account skips the password check entirely
(`server.mjs:2263, 2284, 2321`); forgot-password sends nothing. **The `user` object does not say
which kind of account it is** — the client can only learn it from those 400s. The native
Account tab should either show these forms and surface the server message, or hide them after the
first such 400 for the session. (Open question below.)

---

## 4. Identity in the shell

`applyUserIdentity` (`app.js:46792-46805`): display name = guest ? `guestName` :
`name.trim() || email.split("@")[0] || "Firas"`; avatar = first character uppercased or `F`.
Sidebar account pill (`index.html:629-640`): avatar, name, settings button (title `الإعدادات` /
`Settings`), logout button (title `تسجيل الخروج` / `Log out`).

**Logout** (`logout`, `app.js:46824-46842`): if guest → `exitGuest` (§5.7). Otherwise, no
confirmation: remove `firas_had_session`, `POST /api/auth/logout` (`server.mjs:2004-2007`,
`200 {ok:true}`, clears cookie), broadcast to other tabs, clear user/chats, abort streams, show
landing. Device prefs are kept.

**refreshUser** (`app.js:46843-46862`): guests re-`POST /api/guest`; members `GET /api/auth/me`.
Used after redeem/quota events.

---

## 5. Guest trial

### 5.1 Start (`startGuestSession`, `app.js:46958-46988`)

`POST /api/guest` (`server.mjs:2017-2027`) — auth: none (idempotent; reuses a valid guest cookie).

| status | body |
| --- | --- |
| 200 | `{ "guest": true, "user": <guest user> }` + `Set-Cookie: firas_guest` (7 days) |
| 200 | `{ "guest": false, "user": <member user> }` when a member cookie is present (no guest minted) |
| 429 | `{ "error": "too many requests" }` — `guest:<ip>` 20/min |

Client writes `firas_guest_active = "1"` then `bootApp`. On failure: show the auth screen and toast
(`authNetworkError` when no status, else the server `error`).

### 5.2 What a guest can and cannot do

- Can: chat (`ai`), Code builds (`code`), Brain questions (`brain`), voice, read announcements,
  open Settings (reduced Account tab, §6.1), export/import backup, clear device data.
- Cannot (server returns `403 signin_required`): image/video/music generation, live call,
  Agent missions (`usage/charge` refuses `agent` for guests, `server.mjs:7665`), Brain whole-book.
- Members-only routes that return **401** (not 403) for guests, which the client must gate
  **before calling** (the web checks `isGuest()` first): memory, share (`app.js:79680, 79713`),
  KB, redeem (`app.js:45364`), plans page.
- Chats live in device storage only (`firas_guest_chats`, max 60, `guestSaveChats`
  `app.js:47009-47040`); the server stores nothing for a guest.

### 5.3 Daily guest quota (server-authoritative)

`GUEST_LIMITS` (`server.mjs:1133-1155`): `ai` 180, `code` 60, `agent` 24, `brain` 120, `internal`
300, `voice` 120 per day (day = UTC+`QUOTA_TZ_OFFSET_MINUTES`, default 180 = Baghdad,
`server.mjs:3196-3198`). A parallel per-network bucket is ×4 (`GUEST_IP_MULTIPLIER`). Denial body
(`server.mjs:1286` cookie bucket, `server.mjs:1272` network bucket), status **429**:

```json
{ "error": "guest daily limit reached", "guest": true,
  "quota": { "product": "ai", "used": 180, "limit": 180, "plan": "guest", "scope": "network"? } }
```

Client (`quotaLimitText`, `app.js:6464-6480`): when `quota.plan === "guest"` or the caller is a
guest, show `guestLimitReached` **and** open the upsell 200 ms later:
- ar `انتهت رسائلك المجانية لهذا اليوم كضيف. أنشئ حسابًا مجانيًا للحصول على حدّ أعلى بكثير.`
- en `You have used today's free guest messages. Create a free account for a much higher limit.`

Member 429 (`{error:"daily quota reached", quota:{product,used,limit,plan}}`) is unreachable
today (all limits −1) but the text exists:
ar `🚦 بلغت الحدّ اليومي من {name} ({lim}/يوم). يتجدّد تلقائيًا بعد منتصف الليل.\n\nفِراس مجاني بالكامل — هذا السقف موجود ليبقى المحرّك متاحًا للجميع، وهو مرتفع لدرجة أن الاستخدام الطبيعي لا يبلغه.`
with `name` ∈ ai `رسائل فِراس AI` · code `طلبات فِراس Code` · agent `مهام فِراس Agent` · brain `أسئلة فِراس Brain` (fallback `الرسائل`);
en `🚦 You've reached today's limit of {name} ({lim}/day). It resets automatically after midnight.\n\nFiras is completely free — this ceiling only keeps the engine available for everyone, and it is set high enough that ordinary use never reaches it.`
with `Firas AI messages` · `Firas Code requests` · `Firas Agent tasks` · `Firas Brain questions` (fallback `messages`).

`POST /api/usage/charge` (`server.mjs:7654-7683`) — auth: member or guest cookie. Body
`{ "product": "code"|"agent", "cid": string }`. `200 {ok:true, sub}`; `400 {error:"invalid product"}`;
`401 {error:"authentication required"}`; `403 {ok:false,error:"signin_required",feature:"agent"}`
for guests; `429` guest denial body above. Client (`chargeUsage`, `app.js:46866-46881`) fails
**open** on network errors and treats 401/403 as blocked (opens upsell for guests).

### 5.4 Upsell modal (`openSignUpPrompt(feature)`, `app.js:47087-47121`)

Dialog with brand mark, title, body, primary CTA, secondary "later". `feature === "image"`
selects the image copy; everything else the generic copy.

| key | ar | en |
| --- | --- | --- |
| guestImageTitle | `توليد الصور يحتاج حسابًا` | `Image generation needs an account` |
| guestImageBody | `أنشئ حسابًا مجانيًا خلال ثوانٍ لتوليد الصور، وحفظ محادثاتك، ورفع حدّك اليومي.` | `Create a free account in seconds to generate images, save your chats, and raise your daily limit.` |
| guestFeatureTitle | `هذه الميزة تحتاج حسابًا` | `This feature needs an account` |
| guestFeatureBody | `أنشئ حسابًا مجانيًا لتفعيلها — يستغرق أقل من دقيقة.` | `Create a free account to unlock it — it takes less than a minute.` |
| guestUpgradeCta | `إنشاء حساب مجاني` | `Create a free account` |
| guestLater | `لاحقًا` | `Later` |

CTA → `goSignUpFromGuest` (`app.js:47125-47130`): save guest chats, show auth screen in
**signup** mode. Escape / backdrop tap closes.

### 5.5 Guest affordances in the shell (`renderGuestUi`, `app.js:47060-47084`)

- `<html class="is-guest">`; a slot above the account pill with note `guestLocalNote`
  (ar `محادثاتك كضيف محفوظة على هذا الجهاز فقط.` en `Guest chats are stored on this device only.`)
  and the bilingual pill: main `signUpNow` (ar `سجّل الآن` / en `Sign up now`) with alt line
  `signUpNowEn` (ar table: `Sign up now`; en table: `سجّل الآن`) — i.e. both languages are always
  shown, primary in the UI language.
- Account name shows `guestName` (ar `ضيف` / en `Guest`); `guestBadge` (`وضع الضيف` / `Guest mode`).

### 5.6 Migration on sign-in (`migrateGuestChats`, `app.js:47133-47153`; called from `bootApp`)

For every local guest chat with messages: `POST /api/chats` body
`{ title, messages: serializeMessages(...), pinned, agent, codeProj }` (chat endpoints are the
chat slice's spec). Then remove `firas_guest_chats` + `firas_guest_active` and
`DELETE /api/guest`. Toast `guestMigrated`: ar `تم نقل محادثاتك إلى حسابك ✓` en
`Your chats were moved to your account ✓`. Runs on **every** member sign-in path (email, Google,
verify link) and is one-shot because the store is cleared.

### 5.7 Exit guest (`exitGuest`, `app.js:47156-47169`)

`window.confirm(guestExitConfirm)`: ar `سيتم مسح محادثات الضيف من هذا الجهاز. متابعة؟` (`app.js:718`); en
`Guest chats on this device will be cleared. Continue?`. On OK: `DELETE /api/guest`
(`200 {ok:true}`), clear both storage keys, clear state, show landing. Label `guestExit`:
ar `الخروج من وضع الضيف` en `Exit guest mode`.

---

## 6. Settings panel (`openSettingsPanel`, `app.js:45603-46320`)

Modal card: title `الإعدادات` / `Settings`, subtitle `إدارة حسابك وأمانه` / `Manage your account & security`,
close button (aria `إغلاق` / `close`). **Tabs** (`app.js:45768-45770`): `الحساب`/`Account`,
`المظهر`/`Appearance`, `المحادثة`/`Chat`, `الصوت`/`Voice`, `البيانات`/`Data`; a sixth
`المفاتيح`/`Keyboard` only when a hardware keyboard map is available (never on phones — omit on
iPhone; consider iPad with hardware keyboard). Strings for this panel live in a local `tx`
object, not the global STR table (`app.js:45613-45683`).

### 6.1 Account tab

Order: hero → plan card → change email → change password → danger zone. For a **guest** the hero
is followed by only the guest card (`app.js:45942-45947, 45957`).

**Hero** (`app.js:45762-45766`): avatar initial, eyebrow `الحساب` / `Account`, name, email (LTR).
Guest name = `ضيف` / `Guest`, email empty.

**Plan card** (`subCardHtml`, `app.js:45330-45352`): header `الاشتراك` / `Plan`; chip
`✦ مجاني بالكامل` / `✦ Free — everything included`; body
ar `كل مزايا فِراس متاحة للجميع مجانًا. يحصل كل حساب على ٥٠٠ كريديت في Firas Agent تتجدد يوميًا.`
en `Every Firas feature is available free. Each account receives 500 Firas Agent credits refreshed daily.`
No meters, no redeem button, no expiry (the redeem/plans UI is unreachable — §11). Admin only:
button `إدارة أكواد التفعيل` / `Manage redeem codes` → `openAdminCodesPanel` (`app.js:45472`).

**Change email** (`app.js:45868-45877`, submit `46247-46263`): header `تغيير البريد الإلكتروني` /
`Change email`; fields `البريد الجديد` / `New email` (email, LTR), `كلمة المرور الحالية` /
`Current password`; button `حفظ البريد` / `Save email`; working label `جارٍ…` / `Working…`.
Client check: empty email → ar `أدخل البريد الجديد` en `Enter the new email`.
`POST /api/auth/change-email` body `{ "email": string, "current": string }` (`server.mjs:2277-2313`,
auth: member; rate `acct:<userId>` 10/min):

| status | server `error` (Arabic, shown verbatim in ar UI) | en UI (mapped by status, `errMsg` `app.js:45689-45697`) |
| --- | --- | --- |
| 200 `{ok:true, user}` | — | toast `تم تحديث البريد ✓` / `Email updated ✓`; update identity |
| 400 | `هذا الحساب يسجّل عبر Google` · `أدخل بريداً صالحاً` · `هذا هو بريدك الحالي` | `Enter a valid email` |
| 403 | `كلمة المرور غير صحيحة` | `Incorrect password` |
| 409 | `هذا البريد مستخدم بالفعل` | `That email is already in use` |
| 401 / 429 / other | `not authenticated` / `too many requests` | `Something went wrong, please try again` (ar `حدث خطأ، حاول مجدداً`) |

Side effect: the account is flagged `emailUnverified` — Google sign-in into that address is
refused thereafter (§3.8 409). No verification mail is sent for the new address.

**Change password** (`app.js:45878-45887`, submit `46266-46282`): header `تغيير كلمة المرور` /
`Change password`; fields `كلمة المرور الحالية` / `Current password`, `كلمة المرور الجديدة` /
`New password` with hint `٨ أحرف على الأقل` / `at least 8 characters`; button `حفظ كلمة المرور` /
`Save password`. Client check <8 → ar `كلمة المرور 8 أحرف على الأقل` en `Password must be 8+ characters`.
`POST /api/auth/change-password` body `{ "current": string, "password": string }`
(`server.mjs:2257-2275`, member, `acct:` 10/min):

| status | server `error` | en UI |
| --- | --- | --- |
| 200 `{ok:true}` + **new cookie** (all other devices revoked) | — | toast `تم تغيير كلمة المرور ✓` / `Password changed ✓` |
| 400 | `هذا الحساب يسجّل عبر Google ولا يملك كلمة مرور` · `كلمة المرور يجب أن تكون 8 أحرف على الأقل` · `كلمة المرور طويلة جداً` | `Password must be at least 8 characters` |
| 403 | `كلمة المرور الحالية غير صحيحة` | `Incorrect password` |

**Danger zone** (`app.js:45915-45931`, wiring `46284-46300`): header `منطقة الخطر` / `Danger zone`;
text `حذف الحساب يمسح جميع محادثاتك نهائياً ولا يمكن التراجع عنه.` /
`Deleting your account erases all your conversations permanently. This can't be undone.`;
button `حذف حسابي` / `Delete my account` reveals a two-step box:
`للتأكيد، أدخل كلمة مرورك ثم اضغط «حذف نهائي».` / `To confirm, enter your password then tap “Delete permanently”.`,
password input (placeholder = current-password label), buttons `إلغاء` / `Cancel` and
`حذف نهائي` / `Delete permanently`.
`POST /api/auth/delete-account` body `{ "current": string }` (`server.mjs:2315-2332`, member,
`acct:` 10/min): `200 {ok:true}` + cookie cleared → toast `تم حذف حسابك` / `Your account was deleted`,
then reload (native: return to landing); `403 {error:"كلمة المرور غير صحيحة"}` (en `Incorrect password`).
Deletes the user record, all chats, and Brain documents. Google accounts: password ignored.

**Guest card** (`app.js:45942-45947`): header `أنت تتصفّح كضيف` / `You’re browsing as a guest`;
body ar `محادثاتك محفوظة على هذا الجهاز وحده، ولا يوجد حساب بعد — فلا بريد ولا كلمة مرور ولا حذف حساب هنا. أنشئ حسابًا مجانيًا وتنتقل محادثاتك إليه كما هي.`
en `Your conversations are saved on this device only, and there is no account yet — so there is no email, no password and no account to delete here. Create a free account and these chats move into it exactly as they are.`;
button `أنشئ حسابًا مجانيًا` / `Create a free account` → close panel, `goSignUpFromGuest`.

### 6.2 Appearance tab (order: UI 2.0 → Theme → Text size → Reading width → Motion → Language)

| Row | Type / values | Default | Storage key (device) | Apply | Labels |
| --- | --- | --- | --- | --- | --- |
| New look / UI 2.0 | switch | off | `firas_ai_ui2` `"1"/"0"` | `applyUi2` `app.js:14103-14124` (`data-ui="2"` on html) | header `المظهر الجديد` / `New look`; label `واجهة 2.0` / `UI 2.0`; hint ar `شريط دائم للمنتجات الأربعة، ولوحة جانبية تعرض خطوات الوكيل ومصادر البرين مع أرقام صفحاتها — نفس كل الميزات بالضبط` en `a permanent rail for all four products, plus a pinned panel showing Agent steps and Brain sources with their page numbers — every feature unchanged`. **Web-layout-only; not applicable natively.** |
| Theme | 6 tiles (radio) | `dark` | `firas_ai_theme` (whitelisted, `app.js:3170-3171`) | `applyTheme` `app.js:14063-14078` (`data-theme`, `theme-color` meta) | header `الثيم` / `Theme` + hint `ستة أمزجة` / `six moods` |
| Text size | segmented sm/md/lg | `md` | `firas_ai_fontsize` | `applyFontSize` `app.js:14133-14138` | `حجم النص` / `Text size`; `صغير` `متوسط` `كبير` / `Small` `Medium` `Large` |
| Reading width | segmented normal/wide | `normal` | `firas_ai_width` | `applyWidth` `app.js:14087-14092` | `عرض القراءة` / `Reading width`; `عادي` `واسع` / `Normal` `Wide` |
| Motion | segmented on/off | `on` | `firas_ai_motion` `"on"/"off"` | `applyMotionPref` `app.js:15015-15020`; effective = pref AND OS reduce-motion | `الحركة` / `Motion`; `كاملة` `مخفّفة` / `Full` `Reduced` |
| Interface language | segmented ar/en | from device language: `en` if `navigator.language` starts with `en`, else `ar` | `firas_ai_lang`; picking here also sets `firas_ai_lang_explicit="1"` | `setUiLang` `app.js:13741-13748` → `applyShellLang` `app.js:13684-13725`; toast `تم تغيير لغة الواجهة ✓` / `Interface language changed ✓`; panel reopens to relabel | `لغة الواجهة` / `Interface language`; options `العربية` / `English` (same in both tables) |

Language semantics: until the user picks explicitly, the shell language **auto-follows the
language of the latest user message** in the active chat (`syncShellLangFromChat`,
`app.js:13753-13763`). Once explicit, never auto-switches. The web shell layout is **fixed LTR**
regardless of language (`app.js:13704-13708`); only text and fonts change. (Native decision
needed — see open questions.)

**THEMES registry** (`app.js:2464-2483`): `id`, ar/en name, dark flag, status-bar colour,
swatch [ground, surface, accent], and the preview palette used for sandboxed HTML previews.

| id | ar | en | dark | meta | swatch |
| --- | --- | --- | --- | --- | --- |
| `light` | `نهاري` | `Light` | no | `#FAF9F5` | `#FAF9F5` `#FFFFFF` `#237A68` |
| `dark` | `ليلي` | `Dark` | yes | `#262624` | `#262624` `#30302E` `#57AE9C` |
| `black` | `أسود` | `Black` | yes | `#000000` | `#000000` `#161616` `#5FBBA7` |
| `midnight` | `نيلي` | `Midnight` | yes | `#0F1522` | `#0F1522` `#182133` `#5AA9E6` |
| `graphite` | `كربوني` | `Graphite` | yes | `#171719` | `#171719` `#202023` `#57AE9C` |
| `amber` | `عنبري` | `Amber` | yes | `#1B1713` | `#1B1713` `#241F19` `#D9A05B` |

Full `pv` palettes (bg/surface/text/muted/accent/hair/bad/ok): light `#FAF9F5/#FFFFFF/#1A1A18/#6B6A63/#237A68/#E6E4DA/#B4483A/#4A7A2E`;
dark `#262624/#30302E/#ECEAE3/#A6A39A/#57AE9C/#3A3A36/#E5877A/#8FBF6F`;
black `#000000/#161616/#F2F2F0/#8C8C87/#5FBBA7/#232323/#E5877A/#8FBF6F`;
midnight `#0F1522/#182133/#E6ECF5/#8695AE/#5AA9E6/#232E44/#E5877A/#8FBF6F`;
graphite `#171719/#202023/#ECECEE/#8B8B90/#57AE9C/#2A2A2E/#E5877A/#8FBF6F`;
amber `#1B1713/#241F19/#F0E7D8/#9C907C/#D9A05B/#332C23/#E5877A/#8FBF6F`.
There is no "follow system" option on the web; the theme icon in the card header is a moon for
dark themes and a sun for light.

### 6.3 Chat tab (order: Default model → Reply behaviour → Images)

| Row | Type / values | Default | Storage | Apply | Labels |
| --- | --- | --- | --- | --- | --- |
| Default model | segmented `mini` / `pro` / `ultra` / `max` | `pro` (`CONFIG.DEFAULT_TIER`, `app.js:16`) | `firas_ai_tier` | `setTier` `app.js:15337-15363`; toast `تم تعيين النموذج الافتراضي ✓` / `Default model set ✓` | header `النموذج الافتراضي` / `Default model` + hint `للمحادثات الجديدة` / `for new conversations`; option labels = `MODELS[k].short`: `ميني` `برو` `أولترا` `ماكس` / `Mini` `Pro` `Ultra` `Max` (`app.js:33, 58, 84, 113`) |
| Deep thinking | switch (mirrors composer tools chip) | **off** | `firas_ai_think` `"true"/"false"`; absent = off (three-state read, `app.js:3190-3193`) | `setThink` `app.js:15196-15201`; hidden/refused on Mini, refused on Max (`applyThinkAvailability`) | header `سلوك الردّ` / `Reply behaviour`; `التفكير العميق` / `Deep thinking`; hint `أبطأ وأدقّ في المسائل الصعبة` / `slower, more careful on hard questions` |
| Web search | switch (mirror) | off | `firas_ai_websearch` `"true"/"false"` | `setWebSearch` `app.js:15210-15214` | `البحث في الويب` / `Web search`; hint `يبحث قبل كلّ ردّ` / `searches before every reply` |
| Send with Enter | switch | off | `firas_ai_enter_send` `"1"/"0"` | `applyEnterSend` `app.js:14126-14132` | `الإرسال بمفتاح Enter` / `Send with Enter`; hint `و Shift+Enter لسطر جديد` / `Shift+Enter for a new line`. (Hardware-keyboard only; iPad-relevant.) |
| Sharpen pictures automatically | switch | off | `firas_ai_img_sr` `"1"/"0"` | `applyImgSr` `app.js:14095-14098` (on-device upscaler) | header `الصور` / `Images`; `شحذ الصور تلقائيًّا` / `Sharpen pictures automatically`; hint `شبكة تعمل على جهازك — ثانية أو اثنتان، وبلا أي كلفة` / `a network on your own device — a second or two, and free` |

There are **no sound or haptic settings** on the web.

### 6.4 Voice tab (order: Call voice → Dictation dialect)

**Call voice** (`app.js:45855-45861, 46108-46109`; data `app.js:48302-48314`): header
`صوت المكالمة` / `Call voice` + hint `يُطبَّق على مكالمتك القادمة` / `applies to your next call`;
`<select dir="ltr">` of `CALL_VOICES = ["cedar","ash","verse","echo","ballad"]` (OpenAI realtime,
masculine), values shown as-is; note `أصوات المكالمة المباشرة. جرّب حتى تجد الأقرب إلى أذنك.` /
`Live-call voices. Try a few until one sounds right.` Default `cedar`; key `firas_call_voice`
(whitelisted on read). Setter `firasSetCallVoice` toasts
ar `صوت المكالمة: <name> — يُطبَّق على المكالمة القادمة` en `Call voice: <name> — applies to the next call`.
(The legacy Gemini `firas_live_voice` / `LIVE_VOICES`, default `Charon`, is console-only and not
in the UI, `app.js:48316-48330`.)

**Dictation dialect** (`app.js:45862-45866, 46113-46114`; data `app.js:47582-47598`, setter
`47683-47692`): header `لهجة الإملاء` / `Dictation dialect` + hint `حين تُملي كلامك نصّاً` /
`when you speak instead of type`; `<select>` over `MIC_LANGS`; default `auto`; key
`firas_ai_mic_lang`. Picker title elsewhere: `micLangTitle` `لغة الإملاء` / `Dictation language`.

| key | flag | ar | en | short ar / en |
| --- | --- | --- | --- | --- |
| `auto` | 🌐 | `تلقائي — يتعرّف على لغتك من كلامك` | `Auto — detects your language` | `تلقائي` / `Auto` |
| `msa` | 📖 | `العربية الفصحى` | `Arabic (Fus'ha)` | `فصحى` / `MSA` |
| `iraqi` | 🇮🇶 | `عراقية` | `Iraqi Arabic` | `عراقية` / `Iraqi` |
| `gulf` | 🇸🇦 | `خليجية` | `Gulf Arabic` | `خليجية` / `Gulf` |
| `egyptian` | 🇪🇬 | `مصرية` | `Egyptian Arabic` | `مصرية` / `Egyptian` |
| `levant` | 🇸🇾 | `شامية` | `Levantine Arabic` | `شامية` / `Levantine` |
| `maghrebi` | 🇲🇦 | `مغاربية` | `Maghrebi Arabic` | `مغاربية` / `Maghrebi` |
| `en` | 🇺🇸 | `الإنجليزية` | `English` | `English` / `English` |
| `fr` | 🇫🇷 | `الفرنسية` | `French` | `Français` / `French` |
| `tr` | 🇹🇷 | `التركية` | `Turkish` | `Türkçe` / `Turkish` |
| `de` | 🇩🇪 | `الألمانية` | `German` | `Deutsch` / `German` |
| `es` | 🇪🇸 | `الإسبانية` | `Spanish` | `Español` / `Spanish` |
| `ur` | 🇵🇰 | `الأردية` | `Urdu` | `اردو` / `Urdu` |
| `fa` | 🇮🇷 | `الفارسية` | `Persian` | `فارسی` / `Persian` |

### 6.5 Data tab (order: Conversations → Storage → About)

**Conversations** (`app.js:45888-45897`, export `46154-46181`, import `46183-46214`): header
`المحادثات` / `Conversations`; note `احفظ محادثاتك في ملف احتياطي، أو استعدها لاحقاً.` /
`Save your chats to a backup file, or restore them later.`; buttons `تصدير نسخة` / `Export backup`
and `استيراد من ملف` / `Import file`.

- Export: skips ephemeral chats; if none → toast `لا توجد محادثات لتصديرها` / `No conversations to export`.
  Fetches each chat's messages via `GET /api/chats/<id>` when not loaded. Writes
  `{ "app": "Firas AI", "format": 1, "exportedAt": "<ISO>", "chats": [ { "title", "pinned", "agent", "codeProj", "messages": [...] } ] }`
  as `firas-chats-YYYYMMDD.json`. Labels: `جارٍ التصدير…` / `Exporting…`; success toast
  `تم تصدير محادثاتك ✓` / `Chats exported ✓`; failure `حدث خطأ، حاول مجدداً` / `Something went wrong, please try again`.
  (The existing `ios/FirasAI/Models/SettingsModels.swift` `FirasChatBackup` matches this format
  and adds `brainNb`.)
- Import: JSON file; invalid or no `chats` → `ملف النسخة غير صالح` / `Invalid backup file`;
  confirm `استيراد المحادثات من هذا الملف؟ ستُضاف إلى قائمتك.` / `Import conversations from this file? They'll be added to your list.`;
  up to 500 chats, title trimmed ≤120 (fallback "new chat" string), messages sanitized, each
  created via `persistChat` (POST `/api/chats`). Labels `جارٍ الاستيراد…` / `Importing…`,
  success `تم استيراد المحادثات ✓` / `Chats imported ✓`.

**Storage** (`app.js:45899-45904`, `46217-46240`): header `التخزين` / `Storage`; note for members
`يمسح تفضيلات هذا الجهاز فقط — محادثاتك محفوظة في حسابك.` / `Clears this device's preferences only — your chats live safely in your account.`;
for guests `يمسح تفضيلات هذا الجهاز فقط — محادثاتك كضيف محفوظة على هذا الجهاز ولن تُمسح.` /
`Clears this device’s preferences only — your guest chats live on this device and are kept.`;
button `مسح بيانات الجهاز` / `Clear device data`; confirm
`مسح تفضيلات هذا الجهاز وإعادة التحميل؟ محادثاتك لن تُحذف.` / `Clear this device's preferences and reload? Your chats won't be deleted.`
Removes every `firas_*` device key **except** user-authored content: guest chats/flag, folders,
tags, pins, notes, shelf, voice note, scratchpads, Brain pin/glossary/read position. Then reloads.
Native equivalent: reset preferences only (theme, language, tier, toggles, mic lang, call voice,
announcement-seen, drafts, job pointers), keep chats and user content.

**About** (`app.js:45906-45913`, `46223-46240`): header `عن التطبيق` / `About`; row `الإصدار` /
`Version` filled from `GET /api/version` (`server.mjs:6538-6546`, auth: none, returns
`{ "version": <newest mtime ms of app.js/index.html/styles.css> }`; displayed as the number, or
`"1.0"` on failure); button `عرض آخر التحديثات` / `See what's new` → closes settings and opens the
announcements panel. Native should show the bundle version instead; `/api/version` is a web
cache-buster, not a product version. There are no other links (no privacy/terms links in the
panel; those only appear on the first-launch consent gate).

There is **no "delete all chats"** action and **no memory section** in the settings panel.

---

## 7. Memory ("what Firas remembers") — endpoints exist, **no UI entry point on the web**

`openMemoryViewer` (`app.js:44630-44667`) is defined but only called from itself (verified by
grep: two hits, both inside the function). Nothing in `index.html` or the tools menu opens it.
Memory is written passively after each member turn (`learnMemory`, `app.js:44606-44628`, skipped
for guests and temporary chats) via `POST /api/memory/learn` `{ "user": ≤4000 chars, "assistant": ≤2000 }`
→ `200 {ok, added, total}` (`server.mjs:7462-7511`, member, `mem:<userId>` 60/min; facts ≤140
chars each, cap `MEMORY_MAX = 60`, `server.mjs:7404`; a new `Label: value` replaces older facts with
the same label).

If the native app exposes a memory screen (recommended — the strings are ready):

- `GET /api/memory` → `200 { "memory": [string] }`; `401 {error:"authentication required"}` for guests (gate client-side → upsell `feature:"memory"`).
- `DELETE /api/memory` → clears all; `DELETE /api/memory?i=<index>` removes one; both return `200 { "ok": true, "memory": [...] }` (`server.mjs:7517-7527`).
- Strings (`app.js:44636-44650`): title `ما يتذكّره فراس عنك` / `What Firas remembers about you`;
  subtitle `أستخدمها لتخصيص ردودي. خاصة بك وحدك.` / `Used to personalize my replies. Private to you.`;
  empty `ما حفظت معلومات عنك بعد — كل ما نتحدّث، أتعلّم وأتذكّر أكثر.` / `Nothing saved about you yet — I learn and remember more as we chat.`;
  footer count `<n> معلومة` / `<n> item(s)`; `مسح الكل` / `Clear all`; per-item delete aria `حذف` / `delete`.

---

## 8. Announcements ("site updates")

### 8.1 Data (`GET /api/announcements`, `server.mjs:7690-7698`) — auth: member **or guest** cookie

`200 { "announcements": [ { "id", "title", "body", "titleEn", "bodyEn", "image", "video", "pinned", "ts", "by", "editedTs"? } ], "admin": bool }`
(pinned first, then newest, max 50). `401 {error:"authentication required"}` with no cookie at all.
`image` is a data-URL (`data:image/(png|jpeg|webp);base64,`) or http(s) URL; `video` is
`/media/<name>.(mp4|webm)` (same-origin, so prefix the API base) or an https URL. `ts` = epoch ms.

Client merges a **built-in launch post** that ships in code (`BUILTIN_ANNOUNCEMENTS`,
`app.js:44692-44726`): `id:"builtin_launch"`, `pinned:true`, `by:"Firas"`, `ts: Date.UTC(2026,7,5)`
(= 2026-08-05), `video:"/media/firas-trailer.mp4"`, title
`فِراس AI — منصة عربية واحدة، أربعة منتجات` / titleEn `Firas AI — one Arabic-first platform, four products`,
and the full Arabic/English bodies at `app.js:44703-44725` (copy verbatim from the file; they are
paragraphs separated by `\n\n`). It is shown even offline and is never editable/deletable.
A server record with the same id replaces it.

### 8.2 Unread dot (`updateNotifyBadge`, `app.js:44756-44762`)

Key `firas_ann_seen` = newest `ts` seen. Unread = any announcement with `ts > seen`. Shown as a
dot (no count) on the topbar bell (`#notifyBtn`, title `تحديثات الموقع`, `index.html:695-698`).
Fetched on every `bootApp`. Opening the panel sets seen = max ts.

### 8.3 Panel (`openAnnouncementsPanel`, `app.js:44906-45090`)

Show the panel immediately with a spinner, then fill (the tap must never appear dead). Header
`تحديثات Firas AI` / `Firas AI updates`, subtitle `آخر أخبار وتحديثات المنصّة.` /
`Latest platform news & updates.`; list rows: thumbnail (if image), badges `مثبّت` / `Pinned` and
`فيديو` / `Video`, title (fallback `تحديث` / `Update`), body, date+time (`toLocaleDateString` +
`toLocaleTimeString`, joined with ` · `). Empty: `لا توجد تحديثات بعد.` / `No updates yet.`

### 8.4 Reader (`openAnnouncementReader`, `app.js:45094-45225`)

Full-screen: language toggle `الأصل`/`Original` · `عربي` · `EN`; video (no autoplay, inline,
metadata preload) or image (tap → lightbox); title; date (+ ` · مُعدّل` / ` · edited` when
`editedTs`); body. Authored `titleEn/bodyEn` seed the EN view; Arabic originals seed the عربي
view; otherwise `POST /api/translate` `{ "title", "body", "to": "ar"|"en" }` → `{ "title", "body" }`
(`server.mjs:3118-3135`, **member only**, `translate:<userId>` 40/min; 28 s client timeout).
Failure toast `تعذّرت الترجمة، حاول مجدداً` / `Translation failed, please try again`. Guests get a
401 here → same toast.

### 8.5 Admin (only when `admin: true`; owner's phone will use it)

Compose form (`app.js:44930-44957`): `عنوان التحديث (عربي)` / `Update title (Arabic)` (≤200),
`نص التحديث…` / `What’s new…` (≤4000), `العنوان بالإنجليزية (اختياري)` / `Title in English (optional)`,
`النص بالإنجليزية (اختياري)` / `Body in English (optional)`, video path
`مسار الفيديو، مثال: /media/firas-trailer.mp4` / `Video path, e.g. /media/firas-trailer.mp4`,
`إضافة صورة` / `Add image` (downscaled to ≤1280px JPEG q0.82 data URL, server cap 600,000 chars →
`413 {error:"image too large"}`), `تثبيت في الأعلى` / `Pin to top`, `نشر` / `Publish`
(`يُنشر…` / `Publishing…`). `POST /api/announcements` `{ title, body, titleEn, bodyEn, image, video, pinned }`
→ `200 {ok, announcement}`; `400 {error:"empty announcement"}`; `403 {error:"admins only"}`.
Toasts `تم النشر ✓` / `Published ✓`, `فشل النشر` / `Publish failed`; validations
`مسار الفيديو غير صالح — استخدم /media/اسم-الملف.mp4` / `Invalid video path — use /media/name.mp4`,
`اكتب شيئاً أولاً` / `Add some content first`.
`مسح كل التحديثات` / `Clear all updates` → confirm `سيتم حذف <n> تحديثاً نهائياً. لا يمكن التراجع.` /
`This permanently deletes <n> update(s). This cannot be undone.` → `DELETE /api/announcements?all=1`
→ `{ok, removed, ids}`; toast `تم حذف <n>` / `Deleted <n>`. `المكتبة المرجعية` / `Reference library`
opens the admin KB manager (out of scope).
Reader admin actions: `تعديل` / `Edit` → editor (`app.js:45219-45283`: `تعديل التحديث` / `Edit update`,
`تغيير الصورة` / `Replace image`, `حذف الصورة` / `Remove image`, `حفظ` / `Save`, `يُحفظ…` / `Saving…`,
`PATCH /api/announcements` `{ id, title, body, image? }` where `image:""` removes) and `حذف` / `Delete`
(confirm `حذف هذا التحديث؟` / `Delete this update?`, `DELETE /api/announcements?id=<id>` → `{ok:true}`,
toast `تم الحذف` / `Deleted`, `فشل الحذف` / `Delete failed`).

---

## 9. Share chat

### 9.1 Entry points

- Topbar button `#shareChatBtn` (title `مشاركة المحادثة`, `index.html:690-692`) → `shareActiveChat`
  (`app.js:79686-79714`).
- Per-answer "share this answer" action → `shareOneAnswer(msg)` (`app.js:79715-79760`), labels
  `shareOne` `شارك هذه الإجابة` / `Share this answer`, hint `رابط لهذه الإجابة وحدها — بقيّة المحادثة تبقى عندك` /
  `A link to this answer alone — the rest of the chat stays with you`.
- Guests: both call `openSignUpPrompt("share")` first.

### 9.2 Create — `POST /api/share` (`server.mjs:9217-9294`) — auth: member; rate `share:<userId>` 5/min

Body: whole chat `{ "chatId": "<server chat id>" }`; single answer
`{ "chatId": "<server id>", "msg": <index>, "cid": "<message cid or \"\">" }` (`cid` outranks
`msg`; assistant turns only). The chat must be saved server-side first (`persistChat`).

| status | body |
| --- | --- |
| 200 | `{ "ok": true, "id": "s<base36><10hex>" }` (re-sharing the same chat/answer returns the same id) |
| 401 | `{ "error": "auth required" }` |
| 404 | `{ "error": "not found" }` (chat not yours / message not an assistant turn) |
| 409 | `{ "error": "لقد وصلت إلى الحد الأقصى للمشاركات (20). احذف مشاركة قديمة أولاً." }` — 20 shares per user |
| 429 | `{ "error": "too many requests" }` |

Link = `<origin>/?share=<id>` (production `https://firasai.org/?share=<id>`).

Web UX: toast `ينشئ رابط المشاركة…` / `Creating share link…` (or `shareOneWait`
`ينشئ رابط الإجابة…` / `Creating the answer link…`); copy to clipboard immediately; toast
`تم نسخ رابط المشاركة ✓` / `Share link copied ✓` (or `shareOneCopied` `تم نسخ رابط الإجابة ✓` /
`Answer link copied ✓`); then the share sheet. Errors: whole-chat → single toast
`تعذّر إنشاء الرابط — تأكد من تسجيل الدخول واتصالك ثم أعد المحاولة` /
`Couldn't create the link — check you're signed in and online, then retry`; single-answer maps
429 → `shareOneBusy` (`طلبات كثيرة بسرعة — انتظر دقيقة ثم أعد المحاولة` / `Too many requests — wait a minute, then try again`),
409 → `shareOneCap` (`وصلت إلى الحد الأقصى لروابط المشاركة في حسابك` / `You've reached the share-link limit on your account`),
else `shareOneFail`. No-messages guard: `افتح محادثة فيها رسائل أولًا` / `Open a chat with messages first`.

### 9.3 Share sheet (`openShareSheet`, `app.js:79763-79795`)

Bottom sheet: title `رابط المشاركة` / `Share link`; read-only link (LTR, tap selects); button
`تم النسخ ✓` / `Copied ✓` when auto-copied else `📋 نسخ الرابط` / `📋 Copy link`; OS share button
`مشاركة عبر التطبيقات` / `Share via apps…` (`navigator.share({title:"Firas AI", url})`); note:
whole chat `أي شخص يملك الرابط يستطيع قراءة هذه المحادثة.` / `Anyone with the link can read this conversation.`,
single answer `shareOneNote` `من يفتح الرابط يقرأ هذه الإجابة وحدها، ولا يرى بقيّة المحادثة.` /
`Whoever opens the link reads this answer only — the rest of the conversation isn't there.`
Copy failure: `حدّد الرابط وانسخه يدويًا` / `Select the link & copy manually`. Natively: one
`ShareLink`/`UIActivityViewController` covers copy + apps.

### 9.4 Read — `GET /api/share?id=<id>` (`server.mjs:9296-9301`) — auth: **none**

`200 { "id", "title", "messages": [ { "role": "user"|"assistant", "content", "lang"?, "tier"?, "imageThumbs"?: [dataURL] } ], "ts", "one": 0|1 }`;
`404 {error:"not found"}`. Web viewer (`checkShareLink`, `app.js:79807-79889`): header brand +
CTA `جرّب فِراس مجانًا` / `Try Firas AI free` (direction from the snapshot's script, not the UI
language); eyebrow for single answers `shareOneEyebrow` `إجابة واحدة من محادثة` /
`One answer from a conversation`; missing → `هذا الرابط غير موجود أو حُذف.` /
`This shared chat doesn't exist or was removed.`; renders cards (agent/deck/project/image/code)
and markdown+math. Only `data:image/` thumbs are rendered (remote URLs dropped). Native: handle
`/?share=` universal links with a read-only viewer reusing the chat renderer.

### 9.5 Delete — `DELETE /api/share?id=<id>` (`server.mjs:9302-9309`) — member

`200 {ok:true}` (also when the id does not exist); `403 {error:"not yours"}` unless owner/admin.
**No web UI exists to list or delete shares.** The 20-cap error tells users to delete one, so a
native "my share links" list would need a listing endpoint that does not exist (open question).

---

## 10. Redeem codes / plans (legacy, unreachable from member UI)

`openRedeemModal` (`app.js:45363-45418`) and `openSubscriptionsPage` (`app.js:45421+`) are kept
only for the admin panel; the free-site plan card has no button to them (`app.js:45354-45360`).
For completeness, `POST /api/redeem` `{ "code": string }` (`server.mjs:7542-7580`, member;
`redeem:<userId>` 8/min and `redeemip:<ip>` 20/min): codes normalized to `[A-Z0-9]` ≤40, format
`FIRAS` + 12 chars; `200 {ok:true, sub}`; `400 invalid code`; `404 code not found`;
`403 code disabled` / `code not for this account`; `410 code expired`; `409 code fully used` /
`you already redeemed this code`; `429`. Client status map ar/en at `app.js:45392-45395`.
Recommendation: do not build this natively.

---

## 11. Storage keys the native app should mirror (device-scoped, never synced)

| key | values | owner |
| --- | --- | --- |
| `firas_ai_theme` | theme id | §6.2 |
| `firas_ai_lang` / `firas_ai_lang_explicit` | `ar`/`en` / `"1"` | §6.2 |
| `firas_ai_fontsize` / `firas_ai_width` / `firas_ai_motion` / `firas_ai_ui2` | see §6.2 | |
| `firas_ai_tier` | `mini|pro|ultra|max` | §6.3 |
| `firas_ai_think` / `firas_ai_websearch` | `"true"/"false"` | §6.3 |
| `firas_ai_enter_send` / `firas_ai_img_sr` | `"1"/"0"` | §6.3 |
| `firas_call_voice` / `firas_ai_mic_lang` | §6.4 | |
| `firas_guest_active` / `firas_guest_chats` | `"1"` / JSON array | §5 |
| `firas_had_session` | `"1"` | §1 (optional) |
| `firas_ann_seen` | epoch ms | §8.2 |
| `firas_welcome_v1` | `"1"` | §1 consent gate |
| `firas_cookie_consent` | `accepted|rejected` | web-only |

All reads are whitelisted; unknown values fall back to the default (`loadState`).

---

## 12. Open questions for the native team

1. **RTL layout.** The web shell is deliberately fixed LTR with Arabic text inside
   (`app.js:13704-13708`). A native app would normally mirror layout for Arabic. Decide whether
   to follow the platform (recommended) or reproduce the web's fixed LTR.
2. **Google-account detection.** `user` carries no `provider`; the Account tab cannot know
   whether to show password forms until a 400 comes back (§3.9). Either accept the server
   message as the UX or ask for a `provider` field in `publicUser` (server change).
3. **Reset link completion.** The server signs the user in on `POST /api/auth/reset`; the web
   discards that and asks for a fresh login. Choose one (booting directly is simpler and correct).
4. **Verify-status `gone`/`expired`.** The web keeps polling silently; the native app should
   stop and show `authVerifyBad` — confirm.
5. **Memory screen.** Endpoints and strings exist but the web has no entry point (§7). Ship it
   natively or leave it hidden?
6. **Share management.** No listing endpoint exists; the 20-link cap is only discoverable by
   hitting it (§9.5).
7. **Universal links.** `/?verify=`, `/?reset=…&uid=`, `/?share=` must be claimed by the app
   (`apple-app-site-association`) for the emailed buttons and shared links to open natively.
8. **`/api/version`.** Meaningless natively; show the bundle version in About.
