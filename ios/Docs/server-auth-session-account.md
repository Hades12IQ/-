# server-auth-session-account — authentication, session, guest, account, entitlements, push

Source of truth: `server.mjs` at the repo root (the Fly deployment behind `https://firasai.org`).
Every citation below is `server.mjs:<line>` unless another file is named. Where the web client's
behaviour is quoted it is `app.js:<line>`; existing native code is `ios/FirasAI/...`. Nothing here
is inferred from comments alone — where a comment and the code disagree, the code wins and the
disagreement is called out. Arabic strings are copied byte-for-byte from the source.

Scope of this slice: the two cookies and how they are minted/verified/revoked; `callerOf` /
`currentUser` / `currentGuest`; every `/api/auth/*` endpoint; `/api/oauth/google/exchange`;
`/api/guest`; `/api/push/*` and the APNs sender; `/api/redeem`, `/api/usage/charge`,
`/api/max/quota`, `/api/memory*`, `GET /api/announcements`; `publicUser` / `subInfo` / `planOf` /
`limitsFor` / `PLAN_LIMITS` / `GUEST_LIMITS`; the router order; and what a non-browser client
(URLSession) must know about cookies, CORS and CSRF.

---

## 0. Transport facts for a native client (read this first)

### 0.1 Base URL, router, methods
* Base: `https://firasai.org` (`ios/FirasAI/Resources/Info.plist` key `FIRAS_API_BASE_URL`;
  `ios/FirasAI/App/AppConfiguration.swift` falls back to the same value and only allows `http`
  for `localhost` / `127.0.0.1` / `::1`).
* Router: `http.createServer` at `13723`. `route = req.url.split("?")[0]` (`13725`) — exact
  string match, no trailing-slash tolerance, query string ignored for matching.
* Order matters only in two places for this slice: nothing in this slice is shadowed, but note
  `/api/chat` handles `OPTIONS` (`13734-13738`, `204` + `Allow: POST, OPTIONS`); every other
  `OPTIONS` falls through to `404 not found` (`13860-13861`). A native app never preflights, so
  this is irrelevant unless someone proxies through a WebView.
* The auth block is `13819-13838` (signup, verify-signup, verify-status, resend-code, login,
  firebase, google-native, oauth/google/exchange, forgot, reset, change-password, change-email,
  delete-account, logout, me, push/register, push/unregister, guest POST/DELETE). Entitlement and
  account-ish routes live earlier: `/api/max/quota` `13776`, `/api/redeem` `13779`,
  `/api/usage/charge` `13784`, `/api/memory` GET/DELETE `13786-13787`, `/api/memory/learn` `13788`,
  `/api/announcements` GET `13789`, `/api/version` `13816`.
* Wrong method on a known path is NOT a 405 here — it falls through: a `GET` on
  `/api/auth/login` reaches `serveStatic` and returns **200 `text/html` (index.html)**. Detect
  mistakes by `Content-Type`, never by status alone.
* Any handler that throws → `500 {"error":"internal error"}` if headers were not sent
  (`13862-13867`). See §0.5 for the two ways this slice can produce a 500 on valid input.

### 0.2 Cookies — the only credential
There is no bearer token, no `Authorization` header, no API key. Identity is one of two signed
cookies, both minted by the server and opaque to the client.

| | Member session | Guest trial |
| --- | --- | --- |
| Name | `firas_session` (`1046`) | `firas_guest` (`1131`) |
| Value | `encodeURIComponent(<payload>.<hmac>)` where payload = `<uuid>` or `<uuid>\|v<N>` (`997-1013`, `1056-1066`) | `encodeURIComponent(g_<24 hex>.<hmac>)` (`1154`, `1162-1170`) |
| HMAC | SHA-256 over the payload with `SESSION_SECRET` env or `DB.secret` (`930-932`, `1008-1013`) | same secret, same function (`1165`) |
| Attributes | `HttpOnly; SameSite=Lax; Path=/; Max-Age=2592000` (30 days, `1047`) `+ ; Secure` when `SECURE_COOKIES=1` or `x-forwarded-proto: https` (`1052-1054`) | `HttpOnly; SameSite=Lax; Path=/; Max-Age=604800` (7 days, `1132`) `+ ; Secure` same rule |
| `Domain` | **never set** → host-only cookie for `firasai.org` | never set |
| Cleared by | `POST /api/auth/logout` (`2004-2007`), `POST /api/auth/delete-account` (`2331`) — `Max-Age=0` (`1068-1071`) | `DELETE /api/guest` (`2029-2033`) |

* `fly.toml:17` sets `SECURE_COOKIES = "1"` and `force_https = true`, so in production both cookies
  are always `Secure`. URLSession will only send them over `https://` — the app must never
  fall back to `http://firasai.org`.
* **URLSession's default cookie jar works unmodified.** `HTTPCookieStorage.shared` stores
  host-only cookies with `Path=/` and replays them on every request to the same host. `HttpOnly`
  and `SameSite` are browser concepts and are ignored by CFNetwork. The existing app already does
  `configuration.httpCookieStorage = HTTPCookieStorage.shared; httpCookieAcceptPolicy = .always;
  httpShouldSetCookies = true` (`ios/FirasAI/Networking/APIClient.swift:57-60`).
* The value contains `%7C` (a URL-encoded `|`) once the session version is > 0. `parseCookies`
  (`1033-1044`) runs `decodeURIComponent` on the way in, so the client must send the value
  **exactly as received**. Never decode-then-re-encode, never trim, never lowercase.
* **Only one `Set-Cookie` header per response.** `res.setHeader("Set-Cookie", …)` overwrites, so a
  response never sets both cookies and never clears one while setting the other. Consequence:
  signing in as a member does NOT clear an existing `firas_guest` cookie; both stay in the jar and
  `callerOf` prefers the member (`1314-1320`). Call `DELETE /api/guest` after a successful sign-in
  if you want the jar clean (the web does this after migrating guest chats, `app.js:47151`).
* **There is no server-side session table and no expiry inside the payload.** `Max-Age` is
  enforced only by the client's jar. A cookie value that the client keeps sending after 30 days
  still verifies. The only things that invalidate a session are (a) a `sessVer` bump (§1.2),
  (b) `SESSION_SECRET` / `DB.secret` changing, (c) the user record disappearing. Do **not** store
  the cookie in Keychain and replay it forever; let the jar expire it and re-authenticate.
* **The session cookie is re-issued (fresh 30-day `Max-Age`) only by**: login, verify-signup,
  verify-status (success), firebase, google-native, reset, change-password. `GET /api/auth/me`
  does NOT refresh it. A device that never logs in again loses the cookie after 30 days and must
  show the sign-in screen when `/api/auth/me` returns 401.

### 0.3 CORS / CSRF / origin checks
* `grep Access-Control` → 0 hits. No CORS headers anywhere. Irrelevant for URLSession.
* `grep headers.origin|headers.referer|csrf|x-requested-with` → the only reference to `Origin` is
  the comment at `2176` explaining that it is deliberately **ignored** (`resetAppBase`, `2195-2206`).
  **Nothing rejects a request for lacking/misstating `Origin`, `Referer`, `User-Agent` or any
  custom header.** A native app needs no special headers beyond `Content-Type: application/json`
  on bodies (and even that is not checked — `readJson` just parses, `1682-1689`).
* There is no CSRF token. `SameSite=Lax` is the only browser-side CSRF defence, and it does not
  apply to a native client.

### 0.4 Response envelope conventions
* `sendJson` (`1691-1695`) → `Content-Type: application/json; charset=utf-8`, **no `Cache-Control`**.
  Use `.reloadIgnoringLocalCacheData` on every API `GET` (`/api/auth/me`, `/api/memory`,
  `/api/announcements`, `/api/version`) so `URLCache` can never serve a stale identity.
* Errors are `{ "error": "<string>" }`. Some add `ok:false`, `feature`, `quota`, `guest:true`
  (exact shapes per endpoint below). Success bodies are NOT uniform: login / me / firebase /
  google-native return `{ user }` (no `ok`); verify-signup / reset / change-email return
  `{ ok:true, user }`; logout / change-password / delete-account / push return `{ ok:true }`.
* The **401 body string differs by endpoint** — `not authenticated` (me, change-password,
  change-email, delete-account), `authentication required` (memory, push, redeem, usage/charge,
  announcements), `{ok:false,error:"auth required"}` (max/quota). Branch on the status code, not
  the string.
* Some messages are Arabic (change-password, change-email, delete-account, verify-signup), some
  English. The web client shows the server string verbatim in Arabic mode and maps by status in
  English mode (`app.js:45692-45699`). The app should map by status too (tables in §5).

### 0.5 Body reading and the two "valid input → 500" traps
* `readBody(req, limit)` (`1646-1680`) counts **JS string length (UTF-16 units), not bytes**
  (deliberate, comment `1662-1665`). Exceeding the limit destroys the socket and rejects with
  `body too large`, which the handler does not catch → `500 {"error":"internal error"}` (or a
  dropped connection). Per-endpoint limits are in each section; none is small enough to matter for
  auth bodies except `usage/charge` (2 000) and `push/*` / `redeem` (4 000).
* `readJson` returns `null` on unparseable JSON; handlers that check it return
  `400 {"error":"invalid JSON body"}` / `"invalid JSON"`; handlers that do not check it
  (forgot, reset, change-*, delete-account, verify-*, resend) treat it as `{}`.
* **Password login against a Google-created account returns 500, not 401.** `handleLogin`
  (`1978-2002`) finds the user by email and calls `verifyPassword(password, user.salt,
  user.passHash)` with both `undefined` (accounts from `handleFirebaseAuth` / `handleGoogleNativeAuth`
  have no `salt`/`passHash`, `2393-2400`, `13696`). `crypto.scrypt(password, undefined, …)`
  throws `ERR_INVALID_ARG_TYPE` synchronously inside the Promise executor (`946-980`), the promise
  rejects, the handler throws, the router answers `500 {"error":"internal error"}`. Verified with
  Node 24 (`ERR_INVALID_ARG_TYPE`). The app must treat a 500 from `/api/auth/login` as "wrong
  credentials or this email signs in with Google", not as a server outage. `handleChangePassword`
  / `handleChangeEmail` guard this case (`2264`, `2284`); `handleLogin` does not.

### 0.6 Rate limiter (`rateLimited`, `1076-1086`) and the proxy caveat
* In-memory sliding window per key; the current request is pushed before the comparison
  (`arr.length > max`), so the **(max+1)th** request inside the window is the first refusal.
  Resets on every deploy/restart. Map capped at 5 000 keys (`1080-1083`).
* `clientIp` (`1087-1095`) uses `X-Forwarded-For` **only when `TRUST_PROXY=1`**; otherwise
  `req.socket.remoteAddress`. `fly.toml` does not set `TRUST_PROXY`; it is not documented in
  `DEPLOY-ENV.md`. The repo's own playbook (`.claude/skills/guest-quota-design/SKILL.md:148-155`)
  says it is *required* on Fly and to check with `fly ssh console -C "printenv TRUST_PROXY"`.
  **If it is unset in production, every `*:<ip>` bucket below is shared by the whole site** (12
  sign-in attempts per minute for all users combined, one network-scoped guest allowance for
  everyone). See Open Questions.
* Buckets touched by this slice (window is always 60 s):

| Key | max/min | Endpoints |
| --- | --- | --- |
| `auth:<ip>` | 12 | signup `1860`, login `1980`, firebase `2336` (shared bucket) |
| `auth:google:<ip>` | 12 | google-native `13675`, oauth/google/exchange `13707` |
| `login:<email>` | 6 | login `1988` (per target account) |
| `verify:<ip>` | 30 | verify-signup `1894` |
| `vstatus:<ip>` | 60 | verify-status `1921` (the web polls every 3 s = 20/min/device) |
| `resend:<ip>` | 4 | resend-code `1942` |
| `guest:<ip>` | 20 | `POST /api/guest` `2022` (only when no member cookie) |
| `forgot:<ip>` | 6 | forgot `2216` |
| `reset:<ip>` | 10 | reset `2233` |
| `acct:<userId>` | 10 | change-password `2260`, change-email `2280`, delete-account `2318` |
| `redeem:<userId>` + `redeemip:<ip>` | 8 + 20 | redeem `7545-7546` |
| `mem:<userId>` | 60 | memory/learn `7465` |
| `push:<userId>` | 30 | push/register `1458`, push/unregister `1481` (shared) |

  429 bodies: `{"error":"too many attempts, please wait a minute"}` (signup/login/firebase/google/
  redeem), `{"error":"too many requests"}` (verify-status, guest, forgot, reset, acct, push),
  `{"error":"too many requests, wait a minute"}` (resend), `{"error":"rate limited"}` (memory).
  `GET /api/auth/me`, `POST /api/auth/logout`, `DELETE /api/guest`, `GET /api/memory`,
  `GET /api/announcements`, `/api/usage/charge`, `/api/max/quota` have **no** limiter.

---

## 1. Session mechanics (what the cookie actually proves)

### 1.1 Signing and verifying
* `sessionPayload(id, ver)` (`997-999`): `ver > 0` → `"<id>|v<ver>"`, else the bare id (byte-for-byte
  backward compatible with pre-versioning cookies).
* `signUserId(userId, ver)` (`1008-1013`): `payload + "." + hex(HMAC-SHA256(secret, payload))`.
* `verifySessionValue(value)` (`1015-1031`): splits on the **last** `.`, constant-time compares the
  MAC, returns the payload string or `null`. Used for both cookies.
* `sessionParts(payload)` (`1001-1007`): splits on the last `|v` → `{ id, ver }` (`ver` 0 if absent).
* `sessionSecret()` (`930-932`): `process.env.SESSION_SECRET || DB.secret`. `DB.secret` is generated
  once at boot if missing and persisted (`669`). The boot log warns when `SESSION_SECRET` is
  unset (`13903`); `DEPLOY-ENV.md:27` lists it as a required Fly secret.

### 1.2 Revocation = session version (`sessVer`)
* `currentUser(req)` (`1098-1113`): parse cookie → verify MAC → split → find user by id →
  **reject unless `(user.sessVer || 0) === ver`**. A cookie minted before a bump is dead.
* `bumpSessionVersion(user)` (`1116-1120`) is called by: `handleReset` (`2250`),
  `handleChangePassword` (`2272`). It is **not** called by logout, delete-account, change-email
  or google/firebase sign-in. There is no "sign out everywhere" endpoint; the only way a user can
  kill other devices is to change or reset the password.
* Both of those endpoints then call `setSessionCookie` so the *calling* device stays signed in
  (`2252`, `2274`). **The app must accept the `Set-Cookie` on those two responses**, otherwise its
  own session is dead on the next request. The jar does this automatically.
* `setSessionCookie` (`1056-1066`) always signs with the account's *current* `sessVer`.
* `sessVer` is never exposed to the client (`publicUser`, `1424-1426`).

### 1.3 Identity resolution helpers
* `currentUser(req)` → member record or `null` (`1098-1113`).
* `currentGuest(req)` (`1156-1161`) → `{ id:"g_…", guest:true }` or `null`. A guest value pasted
  into `firas_session` resolves to nothing (no user has a `g_` id); a member value pasted into
  `firas_guest` fails the `startsWith("g_")` check.
* `callerOf(req)` (`1314-1320`) → `{ user, id, isGuest:false }` | `{ id, isGuest:true }` | `{}`.
  **Member wins when both cookies are present.**
* Three auth tiers used in the tables below: **member** (`currentUser` must resolve; a guest gets
  401), **member-or-guest** (`callerOf` must have an id), **none**.

---

## 2. Guest identity (`firas_guest`)

* Id: `"g_" + 24 hex` (`1154`). Cookie life 7 days from mint; **`POST /api/guest` on an existing
  valid guest does NOT re-issue the cookie** (`2024-2025`), so the 7 days are not sliding.
* Guest records live in `DB.guests[id]` keyed by id, one record per server-day
  (`guestRecord`, `1172-1183`): `{ day, ai, code, agent, brain, brainPages, agentCids, last, seen }`.
  Stale days are pruned when the map exceeds 5 000 keys.
* `GUEST_LIMITS` (`1133-1153`), env-overridable (`GUEST_DAILY_*`), **code defaults**:

| product | default | note |
| --- | --- | --- |
| `ai` | 180 | chat turns |
| `code` | 60 | Code builds (charged via `/api/usage/charge` or `/api/chat` product `code`) |
| `agent` | 24 | defined, but guests are refused Agent everywhere (`7664-7666`, `8880`, `12554`) |
| `brain` | 120 | Brain answers |
| `internal` | 300 | `nomem:true` helper calls (`12877`) |
| `voice` | 120 | TTS / transcribe / live (`5714-5717`) |

  `DEPLOY-ENV.md:103-108` still lists the OLD numbers (60/20/8/40/40/100) — the code tripled them
  on 2026-08-06 (comment `1139-1143`). The code wins.
* **Network bucket** (`guestChargeIp`, `1256-1278`): a second counter keyed on
  `"ip_" + HMAC(secret, clientIp)` with cap `limit × 4` (`GUEST_IP_MULTIPLIER`, `1256`). Charged
  *before* the cookie bucket (`1291-1294`), so minting a fresh guest cookie does not reset anything.
  Subject to the `TRUST_PROXY` caveat in §0.6.
* **Idempotent retries** (`isRepeatCharge`, `1225-1243`): a charge is skipped when the same
  `cid` + same last-user-message hash arrives within 120 s (`RETRY_WINDOW_MS`, `1213`); for
  `agent` the `cid` alone matches within 45 min (`MISSION_WINDOW_MS`, `1214`). `cid` is sanitised
  to `[A-Za-z0-9_-]{0,64}` (`1283`). Send a stable per-turn `cid` on every retry.
* Denial bodies (always HTTP 429):
  * per-cookie: `{"error":"guest daily limit reached","guest":true,"quota":{"product":"ai","used":180,"limit":180,"plan":"guest"}}` (`1286`)
  * per-network: same plus `"scope":"network"` inside `quota` and `limit` = cap×4 (`1273-1274`)
* Web UI on either: shows `guestLimitReached` and opens the sign-up prompt (`app.js:6464-6468`):
  * ar: `انتهت رسائلك المجانية لهذا اليوم كضيف. أنشئ حسابًا مجانيًا للحصول على حدّ أعلى بكثير.`
  * en: `You have used today's free guest messages. Create a free account for a much higher limit.`
* `guestSubInfo(id)` (`1185-1196`) — the guest's `sub` object, same shape as a member's:
  `{ plan:"guest", expiresAt:null, daysLeft:null, limits:{ai,code,agent,brain}, used:{…}, remaining:{…} }`
  (no `voice`/`internal` keys; `remaining` is `max(0, limit-used)`).
* **What a guest may reach** (every `callerOf` site, `1314` callers): `/api/chat` and
  `/api/chat/job*` (`12532`, `12659`, `12742`, `10492`, `12479`), `/api/tts` & `/api/transcribe`
  (`5732`, `6313`), `/api/live/token` (`6213`, bounded), `/api/search` / `/api/images` /
  `/api/fetch` / `/api/imgproxy` (`6039`, `6369`, `6508`, `6479`), `/api/usage/charge` for `code`
  only (`7655`), `GET /api/announcements` (`7692`), Brain (`8344` and `8975` — read the Brain
  report), Agent job views (`12101`, `12184`, `12420`).
* **What a guest is refused with `403 {"error":"signin_required","feature":"<f>"}`**: `image`
  (`3240`, `3927`, `5141`, `5219`), `video` (`4739`, `5310`), `music` (`4879`), `agent`
  (`7665`, `8880`, `12554`), `brain_whole` (`8977`), `live` only when *no* identity at all (`6219`).
  The web funnels every such 403 through one sign-up sheet (`app.js:3222-3225`, `47087-47120`):
  * title (image): `توليد الصور يحتاج حسابًا` / `Image generation needs an account`
  * body (image): `أنشئ حسابًا مجانيًا خلال ثوانٍ لتوليد الصور، وحفظ محادثاتك، ورفع حدّك اليومي.` / `Create a free account in seconds to generate images, save your chats, and raise your daily limit.`
  * title (other): `هذه الميزة تحتاج حسابًا` / `This feature needs an account`
  * body (other): `أنشئ حسابًا مجانيًا لتفعيلها — يستغرق أقل من دقيقة.` / `Create a free account to unlock it — it takes less than a minute.`
  * CTA: `إنشاء حساب مجاني` / `Create a free account` · dismiss: `لاحقًا` / `Later`
* Guests get **401** (not 403) from every member-only route that uses `currentUser` directly:
  `/api/auth/me`, `/api/memory*`, `/api/push/*`, `/api/redeem`, `/api/max/quota`, `/api/chats*`,
  `/api/share`, change-*/delete. The web ignores 401 for guests (`handleSessionExpired`,
  `app.js:3239-3244`) — the app must not treat a guest's 401 as "session expired".
* Guest chats are **never stored server-side**; the web keeps them in `localStorage`
  (`firas_guest_chats`, `app.js:46893`) and migrates them via `POST /api/chats` after sign-up
  (`app.js:47130-47152`). The app needs its own local store for guest conversations.

---

## 3. User record, plans, entitlements

### 3.1 The user record (server-side; fields the app never sees are marked ✗)
Created at `1906` (email), `2393-2400` (firebase), `13696` (google):
`{ id: uuid, name, email, passHash ✗, salt ✗, emailVerified ✗, emailUnverified ✗, provider ✗ ("firebase"|"google"|absent), createdAt, sessVer ✗, sub ✗, quota ✗, memory ✗, apnsDevices ✗, reset ✗, imgDay/imgCids ✗, maxDay/maxCids ✗ }`.

### 3.2 `publicUser(u)` (`1424-1426`) — the ONLY user shape the app receives
```json
{ "id": "<uuid>", "name": "Firas", "email": "x@y.z", "admin": false, "sub": { …subInfo… } }
```
* `admin` = email ∈ `ADMIN_EMAILS` (env, default `firasnozad@gmail.com`; `7534-7535`).
* **`provider` is not exposed.** The app cannot know whether an account has a password until it
  tries: change-password/change-email answer `400 هذا الحساب يسجّل عبر Google…`; login answers 500
  (§0.5). Design the account screen to tolerate that (show the forms; map the 400 to a
  "this account signs in with Google" hint).
* Guest variant (`2026`): `{ "id":"g_…", "name":"", "email":"", "guest":true, "admin":false, "sub":{…guestSubInfo…} }`.
  Members never carry a `guest` key.

### 3.3 `subInfo(user)` (`1386-1400`)
```json
{ "plan": "free", "expiresAt": null, "daysLeft": null,
  "limits":    { "ai": -1, "code": -1, "agent": -1, "brain": -1 },
  "used":      { "ai": 3,  "code": 0,  "agent": 0,  "brain": 1  },
  "remaining": { "ai": -1, "code": -1, "agent": -1, "brain": -1 } }
```
* `plan` ∈ `"free" | "gold" | "diamond" | "unlimited"` for members, `"guest"` for guests.
* `expiresAt` is epoch **milliseconds** or `null` (always `null` for `unlimited` and `free`
  without a `sub`); `daysLeft` = `ceil((expiresAt-now)/86400000)` clamped ≥ 0, or `null`.
* `-1` means unmetered (`remaining` is `-1` whenever the limit is `-1`).
* `used` counts today's turns (server-day, §3.6) even though nothing is limited.

### 3.4 `PLAN_LIMITS` / `limitsFor` / `planOf`
* `PLAN_LIMITS` (`1347-1357`): **every plan is `{ ai:-1, code:-1, agent:-1, brain:-1, internal:-1, voice:-1 }`**.
  The site is free and unmetered for members (comment `1335-1346`). The `internal` key budgets
  `nomem:true` helper calls and `voice` budgets TTS/STT — both also `-1`.
* `limitsFor(plan)` (`1358`): `PLAN_LIMITS[plan] || PLAN_LIMITS.free`.
* `planOf(user)` (`1361-1368`): `"unlimited"` if `sub.plan === "unlimited"`; `"gold"`/`"diamond"`
  only while `!expiresAt || now <= expiresAt`; anything else → `"free"`. An expired timed plan
  silently reads as `free`, data untouched.
* `quotaRollDay(user)` (`1376-1384`) resets `user.quota` to
  `{ day, ai:0, code:0, agent:0, brain:0, brainPages:0, agentCids:[], last:{} }` on a new day.
* The web's plan copy (`app.js:45281-45300`, `CLIENT_PLANS`) — names only, the feature lists there
  are stale marketing text: ar `المجانية` / `Gold` / `Diamond` / `غير محدودة`; en `Free` / `Gold` /
  `Diamond` / `Unlimited`. The web no longer shows redeem/plans buttons to members
  (`app.js:45352-45358`); only the admin sees "Manage redeem codes" (`إدارة أكواد التفعيل`).

### 3.5 Member daily counters that still exist (for the record)
* `IMAGE_DAILY_LIMIT` default **8** images per member per server-day (`3187`; the comment above
  it says "DEFAULT 5" — the code says 8; env wins, `-1` = unmetered). Charged in the image
  routes only when bytes come back (media slice). `MAX_DAILY_LIMIT` default `-1` (`3218`;
  `handleMaxQuota` always reports capacity). `DEPLOY-ENV.md:101-102` (5 / 10) is stale.
* `internal` and `voice` counters are incremented only when their limit is ≥ 0 (`12862-12869`,
  `5719-5724`) — i.e. never, in the current config.

### 3.6 The "day"
`serverDay()` (`3197-3204`) = UTC date after shifting by `QUOTA_TZ_OFFSET_MINUTES` (default 180 =
UTC+3, Baghdad; `3196`). Guest allowances therefore reset at 00:00 Asia/Baghdad, not at the
device's local midnight.

---

## 4. Endpoint reference — authentication

Notation: **Auth** = who may call; **RL** = rate-limit bucket (§0.6); **Body cap** = `readJson`
string-length limit. All requests are JSON `POST` unless stated. All 200 bodies are exact.

### 4.1 `POST /api/auth/signup` — `handleSignup` (`1859-1891`)
* Auth: none. RL: `auth:<ip>` 12. Body cap: 100 000.
* Request: `{ "name": string, "email": string, "password": string }`
  * `name` → `trim().slice(0,80)`; empty → `400 {"error":"name is required"}` (`1869`).
  * `email` → `trim().toLowerCase()`; must match `EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/` (`1697`)
    and `length ≤ 200` → else `400 {"error":"a valid email is required"}` (`1870`).
  * `password` `< 8` → `400 {"error":"password must be at least 8 characters"}`; `> 200` →
    `400 {"error":"password is too long"}` (`1871-1872`). No other complexity rule.
  * existing account → `409 {"error":"email already registered"}` (`1873`).
  * `400 {"error":"invalid JSON body"}` on bad JSON.
* Effect: **no account yet.** Hash stored in `DB.pending[email]` with `token` (48 hex), `pid`
  (32 hex), `exp = now + 15 min` (`VERIFY_TTL_MS`, `2045`), and an email is sent with the link
  `<base>/?verify=<token>` (`1886-1888`; subject `تأكيد حسابك — Firas AI`). A second signup for
  the same email overwrites the pending record.
* 200: `{ "ok": true, "pending": true, "email": "<normalised email>", "pid": "<32 hex>" }` — **no
  cookie**.
* If no mail provider is configured the link is only logged server-side (`1888`); the client
  cannot tell. The email copy (`verifyEmailHtml`, `2099-2107`): heading `تأكيد بريدك الإلكتروني`,
  button `تأكيد الحساب وبدء الاستخدام`, note `الرابط صالح لمدة 15 دقيقة. إذا لم تطلب إنشاء حساب، تجاهل هذه الرسالة.`
* Web UI after 200 (`app.js:46766-46774`): switches to the passive "verify" screen and starts
  polling §4.3 every 3 s; toast `📧 أرسلنا إيميل التأكيد إلى <email>` / `📧 Verification email sent to <email>`.
  Screen strings: title `📧 تفقّد بريدك الإلكتروني` / `📧 Check your email`; subtitle
  `أرسلنا رابط التأكيد إلى` / `We sent a verification link to`; note
  `افتح الرابط من بريدك واضغط الزر — وسيكتمل الدخول هنا تلقائياً (حتى لو فتحته من جهاز آخر). تحقّق من صندوق الوارد والـ Spam.` /
  `Open the link from your email and tap the button — this device will finish automatically (even if you open it on another device). Check your inbox and Spam.`;
  buttons `إعادة إرسال الرابط` / `Resend link`, `‹ الرجوع لتسجيل الدخول` / `‹ Back to sign in`.
* Web pre-validation (`app.js:46744-46756`): empty field → `تعذّر إتمام العملية. حاول مرة أخرى.` /
  `Something went wrong. Please try again.`; short password →
  `كلمة المرور يجب أن تكون ٨ أحرف على الأقل.` / `Password must be at least 8 characters.`.
  Server errors are shown verbatim (`err.data.error`); network failure →
  `تعذّر الاتصال بالخادم. تحقّق من اتصالك.` / `Couldn't reach the server. Check your connection.`

### 4.2 `POST /api/auth/verify-signup` — `handleVerifySignup` (`1893-1918`)
The device that *opens the emailed link* calls this (web: `checkVerifyLink`, `app.js:46604-46621`).
* Auth: none. RL: `verify:<ip>` 30. Body cap: 100 000.
* Request: `{ "token": "<48 hex from ?verify=>" }`.
* Errors: empty token → `400 {"error":"رابط غير صالح"}`; unknown or expired (record deleted) →
  `400 {"error":"الرابط غير صالح أو منتهي — أعد التسجيل"}`; email registered meanwhile →
  `409 {"error":"email already registered"}`; internal → `400 {"error":"تعذّر التأكيد — أعد التسجيل"}`.
* Success creates the user (`1906-1910`: `emailVerified:true`, `createdAt` ISO), marks the pending
  record `verified` (kept until §4.3 or the sweep at `1968-1976`, which drops it 60 s after `exp`),
  fires the English welcome email, **sets `firas_session`**, returns
  `200 { "ok": true, "user": <publicUser> }`. Re-opening the same link within the TTL is
  idempotent (same user, fresh cookie; `1902-1903`).
* Web UI: 409 → note `حسابك مُفعّل بالفعل — سجّل الدخول.` / `Your account is already active — please sign in.`;
  429 → `محاولات كثيرة — انتظر دقيقة ثم افتح الرابط مجدداً.` / `Too many attempts — wait a minute and reopen the link.`;
  anything else → `رابط التأكيد غير صالح أو منتهي. أعد التسجيل من جديد.` / `The verification link is invalid or expired. Please sign up again.`

### 4.3 `POST /api/auth/verify-status` — `handleVerifyStatus` (`1920-1939`)
The device that *submitted the signup* polls this with its `pid`.
* Auth: none. RL: `vstatus:<ip>` 60. Body cap: 100 000.
* Request: `{ "pid": "<32 hex>" }`; empty → `400 {"error":"missing pid"}`.
* 200 bodies (always 200 once the pid is present):
  * `{ "verified": false }` — still waiting.
  * `{ "verified": false, "expired": true }` — 15 min passed; pending record deleted. Restart signup.
  * `{ "verified": false, "gone": true }` — no such pending record (already consumed, swept, or
    server restarted with a file DB). After a successful poll this is what every later poll
    returns, so stop polling on success.
  * `{ "verified": true, "user": <publicUser> }` **+ `Set-Cookie: firas_session`**. The pending
    record is deleted in the same call (`1933`), so exactly one poller ever gets this.
* Cross-device: the link can be opened on any device (Safari on the same phone counts). The app
  should poll every 3–5 s while the verify screen is visible and stop when backgrounded (60/min
  per IP; see §0.6 for why that may be site-wide).
* The web then boots straight into the app (`app.js:46560-46569`).

### 4.4 `POST /api/auth/resend-code` — `handleResendCode` (`1941-1964`)
* Auth: none. RL: `resend:<ip>` 4 → `429 {"error":"too many requests, wait a minute"}`. Body cap: 100 000.
* Request: `{ "email": string }`. **Always `200 {"ok":true}`** (anti-enumeration), whether or not a
  pending record exists. Rotates the token and resets `exp` to +15 min (old link dies).
* Web UI: toast `📧 أرسلنا رابطاً جديداً إلى بريدك` / `📧 We sent a new link to your email`, note
  `أرسلنا رابطاً جديداً إلى بريدك.` / `We sent a new link to your email.`, button disabled 30 s;
  429 → `انتظر قليلاً قبل إعادة الإرسال` / `Please wait before resending`.

### 4.5 `POST /api/auth/login` — `handleLogin` (`1978-2002`)
* Auth: none. RL: `auth:<ip>` 12 AND `login:<email>` 6. Body cap: 100 000.
* Request: `{ "email": string, "password": string }` (email normalised as in signup).
* `401 {"error":"invalid email or password"}` for unknown email OR wrong password (generic on
  purpose). `400 {"error":"invalid JSON body"}`. **`500 {"error":"internal error"}` when the email
  belongs to a Google-only account** (§0.5).
* Accepts both scrypt (`{salt, passHash}`) and migrated PBKDF2 (`passHash = "pbkdf2$…"`) hashes (`946-980`).
* 200: `{ "user": <publicUser> }` + `Set-Cookie: firas_session` (no `ok` key). No `sessVer` bump
  — other devices stay signed in.
* Web UI: shows the server `error` string verbatim; login screen strings: title `مرحبًا بعودتك` /
  `Welcome back`, subtitle `سجّل الدخول لمتابعة محادثاتك.` / `Log in to continue your conversations.`,
  button `تسجيل الدخول` / `Log in`, forgot `نسيت كلمة المرور؟` / `Forgot password?`, Google
  `المتابعة عبر Google` / `Continue with Google`, divider `أو` / `or`, switch `ليس لديك حساب؟` /
  `Don't have an account?` → `إنشاء حساب` / `Sign up`.

### 4.6 `POST /api/auth/logout` — `handleLogout` (`2004-2007`)
* Auth: none required (works without a cookie). No RL. Empty body fine.
* Always `200 {"ok":true}` + `Set-Cookie: firas_session=; …Max-Age=0` (`2005`). Does not bump `sessVer`;
  does not touch `firas_guest`. Call `POST /api/push/unregister` **before** logout (the register
  routes need the cookie; `ios/FirasAI/Notifications/NotificationCoordinator.swift:141-143` already
  models this).

### 4.7 `GET /api/auth/me` — `handleMe` (`2009-2013`)
* Auth: member. No RL. `401 {"error":"not authenticated"}` for guests and anonymous.
* 200: `{ "user": <publicUser> }`. Does not refresh the cookie. This is the boot call
  (`app.js:79947`); the web plays the entrance only after it succeeds and shows the landing on 401.
  For a guest the web uses `POST /api/guest` instead (`app.js:79984`, `46845-46851`).

### 4.8 `POST /api/guest` — `handleGuestStart` (`2017-2027`)
* Auth: none. RL: `guest:<ip>` 20 (skipped when a member cookie is present). Empty body.
* Member cookie present → `200 { "guest": false, "user": <publicUser> }` (no cookie change).
* Valid guest cookie present → `200 { "guest": true, "user": {guest shape §3.2} }`, **no
  `Set-Cookie`** (idempotent resume, same quota).
* Neither → mints `g_…`, `Set-Cookie: firas_guest`, same 200 body.
* The web calls this to resume a trial when `/api/auth/me` is 401 and a local flag says a trial
  was active (`app.js:79975-79987`); the app should keep an equivalent "guest active" flag and
  not show the landing page while it is set. Sidebar name for a guest: `ضيف` / `Guest`; badge
  `وضع الضيف` / `Guest mode`; note `محادثاتك كضيف محفوظة على هذا الجهاز فقط.` /
  `Guest chats are stored on this device only.`

### 4.9 `DELETE /api/guest` — `handleGuestEnd` (`2029-2033`)
* Auth: none. No RL. `200 {"ok":true}` + clears `firas_guest`. Does not delete the server-side
  guest counters (the network bucket keeps counting anyway).
* Web confirm text: `سيتم مسح محادثات الضيف من هذا الجهاز. متابعة؟` / `Guest chats on this device will be cleared. Continue?`;
  menu item `الخروج من وضع الضيف` / `Exit guest mode`; after migration toast
  `تم نقل محادثاتك إلى حسابك ✓` / `Your chats were moved to your account ✓`.

### 4.10 `POST /api/auth/google-native` — `handleGoogleNativeAuth` (`13674-13703`) — the iOS path
Native Google sign-in: the app runs the OAuth authorization-code flow in `ASWebAuthenticationSession`
against the **iOS** client, then hands the one-time code to the server; the server exchanges it
(no client secret exists for an installed app), verifies the Google OIDC ID token locally and
issues the ordinary `firas_session` cookie. The raw ID token never reaches the app.
* Constants (`13563-13565`):
  * `GOOGLE_IOS_CLIENT_ID = "237562309958-p0njbmb5imqcfd6fk728ccr6lhesq03e.apps.googleusercontent.com"`
  * `GOOGLE_IOS_REDIRECT  = "com.googleusercontent.apps.237562309958-p0njbmb5imqcfd6fk728ccr6lhesq03e:/oauth2redirect"` (**single slash** after the colon — must be byte-identical in the authorize URL and the exchange)
  * JWKS: `https://www.googleapis.com/oauth2/v3/certs` (cached per `Cache-Control: max-age`, 10 s fetch timeout, `13566-13601`).
  * These match `ios/FirasAI/Networking/GoogleOAuthProvider.swift:14-18` and the URL scheme in
    `ios/FirasAI/Resources/Info.plist:14-17`.
* What the app must do on its side (mirrors `GoogleOAuthProvider.authorize`,
  `GoogleOAuthProvider.swift:66-104`, `120-146`): open
  `https://accounts.google.com/o/oauth2/v2/auth?client_id=<id>&redirect_uri=<redirect>&response_type=code&scope=openid%20email%20profile&code_challenge=<S256(verifier)>&code_challenge_method=S256&state=<random>&nonce=<random>&prompt=select_account`;
  on callback check `state`, read `code`; treat `error=access_denied` as cancel.
  **The `nonce` must be sent raw** to Google and raw to Firas — Google echoes it verbatim in the
  ID token and the server compares with `===` (`13631`). Do not SHA-256 it (that is Apple's
  convention, not Google's).
* Auth: none. RL: `auth:google:<ip>` 12. Body cap: 20 000.
* Request: `{ "code": string, "code_verifier": string, "nonce": string }` — validated by
  `googleOAuthParams` (`13664-13672`): `8 ≤ code.length ≤ 8192`,
  `code_verifier` ~ `^[A-Za-z0-9._~-]{43,128}$`, `nonce` ~ `^[A-Za-z0-9_-]{16,256}$`; else
  `400 {"error":"invalid oauth parameters"}`. Bad JSON → `400 {"error":"invalid JSON body"}`.
* Server exchange (`13636-13662`): `POST https://oauth2.googleapis.com/token` with
  `client_id, code, code_verifier, redirect_uri, grant_type=authorization_code`, 10 s timeout.
  Network failure → `502 {"error":"google unavailable"}`; non-2xx or no `id_token` →
  `401 {"error":"google authentication failed"}` (Google's own error body is never forwarded).
* ID-token checks (`verifyGoogleOidcIdToken`, `13603-13634`) — any failure →
  `401 {"error":"google authentication failed"}`: RS256 with a `kid` found in the JWKS; `aud ===`
  client id; `azp`, if present, `===` client id; `iss` ∈ {`https://accounts.google.com`,
  `accounts.google.com`}; `exp > now-300`; `iat ≤ now+300`; `nonce === body.nonce`; non-empty
  `sub`; **`email_verified === true`**; email matches `EMAIL_RE` and ≤ 200.
* Account resolution (`13689-13700`): lookup by lower-cased email across *all* providers.
  * existing account with `emailUnverified` (set by change-email, §4.16) →
    `409 {"error":"An account with this email already exists but the address was never confirmed. Please sign in with your password."}`
  * existing account otherwise (password or Firebase) → **linked**, signed in.
  * no account → created as `{ id, name, email, provider:"google", createdAt }` with
    `name = payload.name.trim().slice(0,80) || email local-part`.
* 200: `{ "user": <publicUser> }` + `Set-Cookie: firas_session`.
* Web strings the app can reuse for failures: `تعذّر تسجيل الدخول عبر Google. حاول مرة أخرى.` /
  `Couldn't sign in with Google. Please try again.`; cancelled `تم إلغاء تسجيل الدخول.` /
  `Sign-in cancelled.`; unavailable `تسجيل الدخول عبر Google غير متاح حاليًا.` /
  `Google sign-in is unavailable right now.`
* Existing native client: `FirasAPI.signInWithGoogleNative` (`ios/FirasAI/Networking/FirasAPI.swift:66-99`)
  and `GoogleNativeAuthRequest` (`ios/FirasAI/Models/AuthModels.swift:83-98`, keys `code`,
  `code_verifier`, `nonce`) already match this contract exactly.

### 4.11 `POST /api/oauth/google/exchange` — `handleGoogleOAuthExchange` (`13706-13721`) — legacy
* Same RL bucket and validation as 4.10 minus `nonce`; request `{ "code", "code_verifier" }`;
  returns `200 { "id_token": "<Google OIDC JWT>" }` and **does not sign anyone in**. Kept for
  "early native builds" (comment `13704-13705`) and the Capacitor shell, which then fed the token
  to Firebase (`app.js:47332-47340`). **Do not use it in the rewrite** — it hands a bearer token
  to the app for no benefit; `FirasAPI.exchangeGoogleAuthorizationCode` (`FirasAPI.swift:42-64`)
  can be deleted.

### 4.12 `POST /api/auth/firebase` — `handleFirebaseAuth` (`2334-2397`) — the web's Google path
* Auth: none. RL: `auth:<ip>` 12. Body cap: 100 000.
* Request: `{ "idToken": "<Firebase ID token>", "name"?: string }`.
* Verification (`1793-1857`): RS256 against `securetoken@system.gserviceaccount.com` x509 certs;
  `aud === "firas-ai"` (`FIREBASE_PROJECT_ID`, `1711`; public config in `firebase-config.js`),
  `iss === "https://securetoken.google.com/firas-ai"`, exp/iat/auth_time with 300 s skew, `sub`,
  valid email. `email_verified` is NOT required for a *new* account.
* Errors: `501 {"error":"social sign-in not configured"}` (unreachable with the default project
  id), `400 {"error":"invalid JSON body"}`, `401 {"error":"invalid token"}`,
  `409 {"error":"An account with this email already exists. Please sign in with your password, or verify your email first."}`
  (token not `email_verified` but email exists), `409 {"error":"An account with this email already exists but the address was never confirmed. Please sign in with your password."}`
  (`emailUnverified`), `403 {"error":"email verification required for this account"}` (unverified
  token trying to create an admin email).
* 200: `{ "user": <publicUser> }` + cookie. New accounts get `provider:"firebase"`.
* Only relevant if the app embeds the Firebase SDK; the native path (4.10) is preferred and
  needs no SDK. Existing `FirasAPI.signInWithFirebaseIDToken` (`FirasAPI.swift:24-37`) targets this.

### 4.13 `POST /api/auth/forgot` — `handleForgot` (`2215-2231`)
* Auth: none. RL: `forgot:<ip>` 6 → `429 {"error":"too many requests"}`. Body cap: 100 000.
* Request: `{ "email": string }`. **Always `200 {"ok":true}`** (anti-enumeration).
* Only accounts with `passHash` get an email (`2220`): token 64 hex, `user.reset = { hash:
  sha256(token), exp: now+30 min }` (`2223`; `RESET_TTL_MS`, `2044`), link
  `<base>/?reset=<token>&uid=<userId>` (`2225`), subject `إعادة تعيين كلمة المرور — Firas AI`,
  heading `إعادة تعيين كلمة المرور`, button `تعيين كلمة مرور جديدة`, note
  `الرابط صالح لمدة 30 دقيقة. إذا لم تطلب هذا، تجاهل الرسالة وكلمة مرورك تبقى كما هي.` (`2207-2214`).
* Web UI: needs an email first → `اكتب بريدك الإلكتروني أولاً.` / `Enter your email first.`; after
  the call (success OR error) → `إذا كان البريد مسجّلاً، أرسلنا له رابط إعادة التعيين. تحقّق من بريدك (وصندوق الـ Spam).` /
  `If that email is registered, we sent a reset link. Check your inbox (and Spam).`

### 4.14 `POST /api/auth/reset` — `handleReset` (`2232-2255`)
* Auth: none. RL: `reset:<ip>` 10. Body cap: 100 000.
* Request: `{ "uid": "<userId>", "token": "<64 hex>", "password": string }`.
* Errors: `400 {"error":"password must be at least 8 characters"}`, `400 {"error":"password is too long"}`
  (> 200), `400 {"error":"invalid or expired link"}` (unknown uid, no pending reset, expired, or
  hash mismatch).
* Success: new scrypt hash, `reset` deleted, **`sessVer` bumped (every other device signed out)**,
  `Set-Cookie: firas_session` for this device, `200 { "ok": true, "user": <publicUser> }`.
* Web UI (reset mode of the auth card): title `تعيين كلمة مرور جديدة` / `Set a new password`,
  subtitle `اختر كلمة مرور جديدة لحسابك.` / `Choose a new password for your account.`, field
  `كلمة المرور الجديدة` / `New password`, button `تعيين كلمة المرور` / `Set password`; success note
  `تم تغيير كلمة المرور — سجّل الدخول الآن.` / `Password changed — sign in now.` (the web ignores the
  cookie it just received and goes back to login mode, `app.js:46726-46733`); failure →
  server string or `الرابط غير صالح أو منتهي. اطلب رابطاً جديداً.` / `The link is invalid or expired. Request a new one.`
* Deep link: the emailed link opens `https://firasai.org/?reset=…&uid=…` in Safari (the app has
  no associated-domains entitlement — `ios/FirasAI/FirasAI.entitlements` is empty). If the app
  adds universal links later it must read both `reset` and `uid` query params. A reset done in
  Safari invalidates the app's session → next `/api/auth/me` is 401 → show sign-in.

### 4.15 `POST /api/auth/change-password` — `handleChangePassword` (`2257-2276`)
* Auth: member → `401 {"error":"not authenticated"}`. RL: `acct:<uid>` 10 → `429 {"error":"too many requests"}`. Body cap: 100 000.
* Request: `{ "current": string, "password": string }`.
* Errors (status → server string → web English mapping `app.js:45692-45699`):
  * `400 {"error":"هذا الحساب يسجّل عبر Google ولا يملك كلمة مرور"}` (no `passHash`) → en `Password must be at least 8 characters` (the web mis-maps this 400; the app should show a "this account signs in with Google" message instead)
  * `400 {"error":"كلمة المرور يجب أن تكون 8 أحرف على الأقل"}` → en `Password must be at least 8 characters`
  * `400 {"error":"كلمة المرور طويلة جداً"}` (> 200)
  * `403 {"error":"كلمة المرور الحالية غير صحيحة"}` → en `Incorrect password`
* Success: new hash, **`sessVer` bumped, cookie re-issued for this device**, `200 {"ok":true}`.
  Web toast `تم تغيير كلمة المرور ✓` / `Password changed ✓`; local pre-check
  `كلمة المرور 8 أحرف على الأقل` / `Password must be 8+ characters`.

### 4.16 `POST /api/auth/change-email` — `handleChangeEmail` (`2277-2314`)
* Auth: member. RL: `acct:<uid>` 10. Body cap: 100 000.
* Request: `{ "current": string, "email": string }` (email normalised).
* Errors: `400 {"error":"هذا الحساب يسجّل عبر Google"}` (no password); `400 {"error":"أدخل بريداً صالحاً"}`
  (en `Enter a valid email`); `403 {"error":"كلمة المرور غير صحيحة"}` (en `Incorrect password`);
  `400 {"error":"هذا هو بريدك الحالي"}`; `409 {"error":"هذا البريد مستخدم بالفعل"}` (en `That email is already in use`).
* Success: `user.email` replaced, **`emailUnverified = true`** and `emailVerified` deleted
  (`2310-2311`) — from now on a Google sign-in with that address is refused with the 409 in 4.10 /
  4.12 until the user signs in with the password. No verification email is sent. No cookie
  change. `200 { "ok": true, "user": <publicUser> }`. Web toast `تم تحديث البريد ✓` / `Email updated ✓`.

### 4.17 `POST /api/auth/delete-account` — `handleDeleteAccount` (`2315-2332`)
* Auth: member. RL: `acct:<uid>` 10. Body cap: 100 000.
* Request: `{ "current": string }`. For a password account a wrong/empty password →
  `403 {"error":"كلمة المرور غير صحيحة"}`. **Google-only accounts are deleted without any
  password** (`2321` guards on `user.passHash`).
* Effect: user record removed (memory, quota, sub, apnsDevices, reset go with it), `DB.chats` for
  the user removed, Brain library removed (`brainRemoveUser`, `2326`), cookie cleared (`2328`).
  Not removed: durable job records, public share snapshots, redeem-code `usedBy` entries.
* `200 {"ok":true}`. Web toast `تم حذف حسابك` / `Your account was deleted`, then reload.
* Web copy on the guest account tab (the app should mirror the idea — guests have nothing to
  delete): `أنت تتصفّح كضيف` / `You’re browsing as a guest`;
  `محادثاتك محفوظة على هذا الجهاز وحده، ولا يوجد حساب بعد — فلا بريد ولا كلمة مرور ولا حذف حساب هنا. أنشئ حسابًا مجانيًا وتنتقل محادثاتك إليه كما هي.` /
  `Your conversations are saved on this device only, and there is no account yet — so there is no email, no password and no account to delete here. Create a free account and these chats move into it exactly as they are.`

---

## 5. Endpoint reference — entitlements, misc account

### 5.1 `POST /api/redeem` — `handleRedeem` (`7542-7581`)
* Auth: member → `401 {"error":"authentication required"}`. RL: `redeem:<uid>` 8 AND
  `redeemip:<ip>` 20 → `429 {"error":"too many attempts, please wait a minute"}`. Body cap: 4 000.
* Request: `{ "code": string }` → `normCode` (`1404`): uppercase, strip everything but `A-Z0-9`,
  cap 40 (so `FIRAS-XXXX-XXXX-XXXX` and `firas xxxx…` both work). `< 5` chars → `400 {"error":"invalid code"}`.
* Errors: `404 {"error":"code not found"}`, `403 {"error":"code disabled"}`,
  `410 {"error":"code expired"}`, `409 {"error":"code fully used"}`,
  `403 {"error":"code not for this account"}` (bound to another user),
  `409 {"error":"you already redeemed this code"}`.
* Success (`7561-7580`; `user.sub` written at `7569`): `user.sub = { plan: code.type, expiresAt, since: now, code }` where
  `type ∈ gold|diamond|unlimited`; gold/diamond expire after `durationDays` (default 30) and
  **stack** on an active same-plan expiry; unlimited → `expiresAt:null`. Code `uses`/`usedBy`
  updated. `200 { "ok": true, "sub": <subInfo> }`.
* Web strings by status (`app.js:45389-45392`): 400 `أدخل كودًا صالحًا` / `Enter a valid code`;
  404 `كود غير موجود` / `Code not found`; 403 `هذا الكود غير متاح لحسابك` / `This code isn't available for your account`;
  409 `سبق تفعيل هذا الكود أو انتهت مرّاته` / `Already redeemed or fully used`; 410 `انتهت صلاحية الكود` / `Code has expired`;
  429 `محاولات كثيرة، انتظر قليلًا` / `Too many attempts, wait a minute`; other
  `تعذّر التفعيل، حاول مجددًا` / `Couldn't activate, please try again`; success toast
  `تم تفعيل اشتراكك ✓` / `Subscription activated ✓`. Modal: `تفعيل كود اشتراك` / `Redeem a code`,
  `أدخل الكود لتفعيل خطتك فورًا` / `Enter your code to activate your plan instantly`, placeholder
  `مثال: FIRAS-XXXX-XXXX-XXXX`, button `تفعيل` / `Activate`.
* Since every plan is unmetered, redeeming changes only the label. The web hides the entry point
  for members; it is optional for the app.

### 5.2 `POST /api/usage/charge` — `handleUsageCharge` (`7654-7681`)
Pre-charges one unit of `code` (per build) or `agent` (per mission) *before* the client starts the
work; the chat/job routes charge the other products themselves.
* Auth: member-or-guest → `401 {"error":"authentication required"}`. No RL. Body cap: **2 000**.
* Request: `{ "product": "code" | "agent", "cid": string }` (anything else →
  `400 {"error":"invalid product"}`; `cid` sanitised to `[A-Za-z0-9_-]{0,64}`).
* Guest + `agent` → `403 { "ok": false, "error": "signin_required", "feature": "agent" }`.
* Guest + `code` → charged against `GUEST_LIMITS.code` (60/day) with the network bucket;
  denial `429 {"error":"guest daily limit reached","guest":true,"quota":{…}}` (§2); success
  `200 { "ok": true, "sub": <guestSubInfo> }`.
* Member: `limitsFor(plan)[product]` is `-1` → **returns immediately** `200 { "ok": true, "sub": <subInfo> }`
  without touching counters (`7673`). The 429 path (`{"error":"daily quota reached","quota":{product,used,limit,plan}}`)
  is unreachable in the current config.
* Web behaviour worth copying (`app.js:46866-46880`): 429 → block and show the quota text; 401/403
  → block and open the sign-up prompt (never treat as "charged"); network failure → **fail open**.
* Existing native: `FirasAPI.chargeUsage` + `UsageChargeResponse { ok, sub }` (`FirasAPI.swift:319-328`,
  `ChatModels.swift:366-369`) match.

### 5.3 `POST /api/max/quota` — `handleMaxQuota` (`3227-3231`)
* Auth: member (guest → 401 too). No RL. Body ignored.
* `401 { "ok": false, "error": "auth required" }`; `200 { "ok": true, "limit": 0, "used": 0, "remaining": -1 }`
  (hard-coded: Max is unmetered). The web calls it before a Max-tier turn (`app.js:6442`); the app
  can skip it or use it as a cheap "am I still signed in" probe.

### 5.4 `GET /api/announcements` — `handleAnnouncementsGet` (`7690-7698`)
* Auth: member-or-guest → `401 {"error":"authentication required"}`. No RL.
* `200 { "announcements": [ …≤50 ], "admin": bool }` — pinned first, then `ts` desc.
* Item (`7716`): `{ id, title, body, titleEn, bodyEn, image, video, pinned, ts, by, editedTs? }`
  — `title`/`body` Arabic (≤200 / ≤4000), `titleEn`/`bodyEn` English (may be `""`), `image` is
  `""`, an `https://` URL or a `data:image/(png|jpeg|jpg|webp);base64,` URI (≤600 000 chars),
  `video` is `""`, `/media/<name>.mp4|webm` (relative — prefix the base URL) or an `https://…mp4|webm`
  URL, `ts`/`editedTs` epoch ms, `by` display name. Writes are admin-only (`7699-7760`).

### 5.5 Memory — `/api/memory` (`7404-7527`)
Private per-user facts the model is told about the user. Member-only (guests → 401).
* `GET /api/memory` → `200 { "memory": [ "Name: Ali", "From Iraq", … ] }` (`7512-7516`); strings
  ≤ 140 chars, at most 60 (`MEMORY_MAX`, `7404`).
* `DELETE /api/memory` → clears all; `DELETE /api/memory?i=<index>` → removes one (out-of-range
  index is a silent no-op). `200 { "ok": true, "memory": [ …remaining ] }` (`7517-7527`).
* `POST /api/memory/learn` (`7462-7511`): RL `mem:<uid>` 60 → `429 {"error":"rate limited"}`;
  body cap 200 000 (raw `readBody`; bad JSON → `400 {"error":"invalid JSON"}`). Request
  `{ "user": string (≤4000 used), "assistant": string (≤2000) }`. Empty `user` →
  `200 {"ok":true,"added":0}`. Otherwise runs **three parallel LLM extractions** (`7482-7484`) —
  several seconds — and returns `200 { "ok": true, "added": n, "total": m }`. A new `Label: value`
  fact replaces an older fact with the same label (`7495-7503`). Fire-and-forget after a turn; never
  block the UI on it (the web does not await it, `app.js:44622`, `59879`).

### 5.6 `GET /api/version` — `handleVersion` (`6538-6546`)
* Auth: none. `200 { "version": <int, newest mtime ms of app.js/index.html/styles.css> }`. Web-only
  reload trigger; meaningless for the app.

---

## 6. Push notifications (APNs)

### 6.1 Server configuration (`apnsConfiguration`, `1491-1498`)
All four env vars must be set or **every push is silently skipped** (`1630`): `APNS_TEAM_ID`,
`APNS_KEY_ID`, `APNS_BUNDLE_ID` (used as `apns-topic`, must equal the app's bundle id),
`APNS_PRIVATE_KEY` (`\n`-escaped PEM, ES256 provider token cached 50 min, `1499-1514`). None of
them appears in `fly.toml`/`DEPLOY-ENV.md`; whether they are set on Fly is an open question.

### 6.2 `POST /api/push/register` — `handlePushRegister` (`1455-1477`)
* Auth: member → `401 {"error":"authentication required"}` (guests cannot register). RL:
  `push:<uid>` 30 (shared with unregister) → `429 {"error":"too many requests"}`. Body cap: 4 000.
* Request: `{ "token": "<hex>", "environment": "sandbox" | "production", "language": "ar" | "en" }`
  * `token` (`apnsTokenValue`, `1435-1439`): trimmed, **lower-cased**, `32 ≤ len ≤ 512`, even
    length, `^[a-f0-9]+$` → else `400 {"error":"invalid device token"}`. Send the device token as
    hex (`Data.map { String(format: "%02x", $0) }.joined()`).
  * `environment` anything else → `400 {"error":"invalid APNs environment"}`. Debug builds →
    `sandbox`; TestFlight/App Store → `production`.
  * `language`: `"ar"` or anything else (stored as `"en"`). Decides the copy of every push to that
    device (§6.5). Re-register when the user changes the app language.
* Effect (`1440-1454`, `1466-1476`): per-user list, deduped by token, newest first, **max 8
  devices**, entries older than 180 days dropped on every write. `200 {"ok":true}`.
* Re-register on every launch/token change; the server never prunes tokens APNs reports as dead.

### 6.3 `POST /api/push/unregister` — `handlePushUnregister` (`1478-1490`)
* Same auth/RL/cap. Request `{ "token": "<hex>" }`. `200 {"ok":true}` even if the token was not
  registered. Call it **before** `POST /api/auth/logout` and before delete-account is optional
  (the user record — and its devices — is deleted anyway).

### 6.4 When a push is sent — `notifyDurableJobTerminal(rec, outcome)` (`1627-1642`)
* Only for **members** (`rec.isGuest` / missing `rec.uid` → nothing), only on `"completed"` or
  `"failed"`, only if APNs is configured, to every bounded device in parallel with an 8 s timeout
  each (`1580-1626`). Failures are ignored; no retry.
* Triggers: durable chat-job worker — payload missing (`11792`), completed (`11903`, skipped
  when the user pressed Stop), refused ≥ 400 (`11918`), retries exhausted (`11935`); media jobs
  via `notifyMediaJobTerminal` (`4720-4728`, image/video/music, `product:"ai"`). Live streaming
  `/api/chat` answers never push.
* `product` (`durableNotificationProduct`, `1515-1520`): `rec.kind === "agentrun"` or
  `product === "agent"` → `"agent"`; `codebuild`/`code` → `"code"`; `brainask`/`brain` → `"brain"`;
  everything else (`chat`, `longdoc`, `longfile`, media) → `"ai"`. Job `kind`/`product` come from
  the job-start payload (`12629-12630`).
* Headers (`1604-1613`): `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration: 0`
  (deliver now or drop), `apns-collapse-id` = `rec.id` sanitised to `[A-Za-z0-9_-]{≤64}`, host by
  device `environment` (`api.push.apple.com` / `api.sandbox.push.apple.com`).

### 6.5 Payload (`apnsPayload`, `1562-1579`) — use the same keys for LOCAL notifications
```json
{
  "aps": {
    "alert": { "title": "إجابة فِراس اكتملت", "body": "اضغط لعرض النتيجة." },
    "sound": "FirasComplete.wav",
    "category": "FIRAS_JOB_COMPLETE",
    "thread-id": "firas-ai-<chatId or jobId or 'job'>"
  },
  "firas": {
    "type": "job-terminal",
    "product": "ai",
    "jobId": "<rec.id>",
    "phase": "completed",
    "chatId": "<rec.chatId>",
    "mediaKind": "image"
  }
}
```
* `thread-id` = `("firas-" + product + "-" + (chatId || jobId || "job")).slice(0, 64)`.
* `firas.chatId` present only when the job has one (members' chat jobs; media jobs have none).
  `firas.mediaKind` present only for `image` / `video` / `music`.
* `phase` ∈ `"completed" | "failed"`; `product` ∈ `"ai" | "agent" | "code" | "brain"`.
* No `badge`, no `content-available`, no `mutable-content`, no `interruption-level`.
* The sound file `FirasComplete.wav` must be bundled (it is: `ios/FirasAI/Resources/FirasComplete.wav`).
* Existing native decoder `NotificationDestination.decode` (`NotificationCoordinator.swift:47-73`)
  reads exactly these nested keys (plus flat `firas_*` fallbacks the server never sends) and its
  `userInfo` builder (`35-45`) emits the same shape for local notifications — keep it.

### 6.6 Localized copy (`apnsLocalizedCopy`, `1521-1561`) — verbatim, keyed by the DEVICE's registered language
Media (`mediaKind` set), Arabic:

| kind | completed | failed |
| --- | --- | --- |
| image | `صورتك جاهزة` / `اضغط لعرض الصورة وحفظها أو مشاركتها.` | `تعذر إنشاء الصورة` / `اضغط لعرض التفاصيل أو المحاولة مجددا.` |
| video | `فيديوك جاهز` / `اضغط لمشاهدة الفيديو وحفظه أو مشاركته.` | `تعذر إنشاء الفيديو` / `اضغط لعرض التفاصيل أو المحاولة مجددا.` |
| music | `أغنيتك جاهزة` / `اضغط للاستماع إلى الأغنية وحفظها أو مشاركتها.` | `تعذر إنشاء الأغنية` / `اضغط لعرض التفاصيل أو المحاولة مجددا.` |

Media, English: `Your image is ready` / `Tap to view, save, or share it.`; `Your image could not be created` /
`Tap to view details or try again.`; `Your video is ready` / `Tap to watch, save, or share it.`;
`Your video could not be created` / …; `Your song is ready` / `Tap to listen, save, or share it.`;
`Your song could not be created` / ….

Non-media, Arabic: names `ai` → `إجابة فِراس`, `agent` → `مهمة وكيل فِراس`, `code` → `مشروع فِراس كود`,
`brain` → `بحث فِراس برين`; completed → title `<name> اكتملت`, body `اضغط لعرض النتيجة.`; failed →
title `<name> لم تكتمل`, body `اضغط لعرض التفاصيل أو المحاولة مجدداً.`

Non-media, English: `Firas answer` / `Firas Agent mission` / `Firas Code project` / `Firas Brain search`;
completed → `<name> is ready` / `Tap to view the result.`; failed → `<name> could not finish` /
`Tap to view details or try again.`

---

## 7. Email deep links and the app

* Link host (`resetAppBase`, `2195-2206`): `APP_URL` env if set; else the request `Host` **only
  if** it matches `RESET_HOST_ALLOW` (`2185-2194`: localhost, 127.0.0.1, [::1], 192.168.x.x,
  `*.trycloudflare.com`, `*.netlify.app`, `*.fly.dev`, `*.onrender.com`); otherwise
  `http://localhost:<PORT>` with a warning. **`firasai.org` is not in the allow-list**, so
  production depends on `APP_URL=https://firasai.org` being set as a Fly secret (open question).
* `?verify=<token>` → the opener must call `POST /api/auth/verify-signup` (§4.2).
* `?reset=<token>&uid=<id>` → the opener must call `POST /api/auth/reset` (§4.14).
* Today both open in Safari on the phone (no universal links). That is fine for signup: the app's
  `verify-status` poll completes the sign-in on the phone (§4.3). For reset the user finishes in
  Safari and re-enters the password in the app.

---

## 8. Alignment notes for the existing native code (`ios/FirasAI`)

* `AuthModels.swift:32-40` `User { id, name, email, admin, sub, guest? }` and
  `Subscription { plan, expiresAt: Double?, daysLeft: Int?, limits, used, remaining }` match
  §3.2/3.3. `SubscriptionPlan` decodes unknown plans as `.free` — correct.
* `SignupResponse { ok, pending, email, pid }`, `VerificationStatusResponse { verified, gone?, expired?, user? }`,
  `VerifiedUserEnvelope { ok, user }`, `GuestSessionResponse { guest, user }`,
  `ChangeEmailResponse { ok, user }`, `UsageChargeResponse { ok, sub }` — all correct.
* `UserEnvelope { user }` is used for login / me / google-native — correct (no `ok` key there).
* `FirasAPI.me()` uses the default cache policy (`FirasAPI.swift:128`); switch to
  `.reloadIgnoringLocalCacheData` (§0.4).
* `APIClient.validate` (`APIClient.swift:168-175`) surfaces `error` strings; add status-based
  mapping for the Arabic account errors and the login-500 case (§0.5) rather than showing
  `internal error`.
* `APIClient` timeouts (45 s request / 180 s resource) are fine for everything here except
  `POST /api/memory/learn`, which can take longer — run it detached.
* Drop `exchangeGoogleAuthorizationCode` / `signInWithFirebaseIDToken` unless Firebase is kept.

---

## 9. Open questions (cannot be settled from the repo)

1. Is `TRUST_PROXY=1` set in the Fly secrets? If not, every per-IP limiter and the guest network
   bucket are site-wide (§0.6, §2). Check with `fly ssh console -C "printenv TRUST_PROXY"`.
2. Is `APP_URL=https://firasai.org` set? Without it verification/reset emails link to
   `http://localhost:8080` (§7).
3. Are `APNS_TEAM_ID` / `APNS_KEY_ID` / `APNS_BUNDLE_ID` / `APNS_PRIVATE_KEY` set, and what bundle
   id do they carry? The app's bundle id must equal `APNS_BUNDLE_ID` (§6.1).
4. Is `SESSION_SECRET` set (so sessions survive a DB reset) — `DEPLOY-ENV.md:27` says it must be.
5. Should the rewrite keep the Firebase path (`/api/auth/firebase`) at all, or use only
   `/api/auth/google-native`? Nothing on the server requires Firebase for the native app.
