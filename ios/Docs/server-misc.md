# server-misc — everything else the iOS app may call

Source of truth: `server.mjs` at the repo root (the deployed Fly server). Every line number below is
`server.mjs:<line>` unless another file is named. Read-only analysis; nothing here is guessed —
where the code and a comment disagree, the code wins and the disagreement is called out.

Scope of this slice: `GET /api/search`, `GET /api/images`, `GET /api/fetch`, `GET /api/imgproxy`,
`POST /api/translate`, `GET /api/kb`, `GET /api/version`, static serving (`serveStatic`, `/media`,
`/brand`), the announcements API + schema, the durable job *file* endpoints (auth summary only),
body-size limits, the rate-limit buckets a phone will hit, the server-side quota display tables
(plans, guest allowances, daily caps), every environment flag that can turn an endpoint into
`not_configured` / 503 so the app can hide the feature, the APNs push contract the app must
implement (§15), and a guest-vs-member capability matrix (§16).

---

## 0. Conventions that apply to every endpoint in this file

### 0.1 Router
* `server.mjs:13723-13868` — `http.createServer`. `route = req.url.split("?")[0]` (exact string
  match, no trailing-slash tolerance), `method = req.method`.
* Unknown route + `GET`/`HEAD` → `serveStatic` → **200 with `index.html`** (the SPA fallback,
  `13858`). A typo'd GET API path therefore returns HTML with status 200, never 404. Detect this by
  `Content-Type: text/html`.
* Unknown route + any other method → `404` plain text `not found` (`13860-13861`).
* Wrong method on a known route: `/api/chat` (`13740-13741`), `/api/chats` (`13845-13846`) and
  `/api/chats/<id>` (`13855-13856`) answer `405` plain text `method not allowed`; every other API
  route has no method guard and simply falls through (GET/HEAD → the SPA shell, else → 404).
* Any thrown error → `500 {"error":"internal error"}` if headers not yet sent (`13864`).
* **No CORS headers anywhere** (`grep Access-Control` → 0 hits). Irrelevant for URLSession; the app
  must call `https://firasai.org` directly, never through a WebView proxy.
* **`OPTIONS`**: only `/api/chat` answers it (`204`, header `Allow: POST, OPTIONS`, `13734-13738`);
  every other path → `404`. Do not send preflights.
* **Retired routes**: `POST /api/agent/start` and `GET /api/agent/poll` are short-circuited in the
  router to `410 {"error":"durable_agent_route_required"}` before any auth check (`13763-13765`).
  The handler bodies further down the file (`8878-8881`) are unreachable dead code. Agent
  missions go through `POST /api/chat/job` with `kind:"agentrun"` (agent slice).
* Router order matters: `/api/chat/job/file` (`13729`) is matched before `/api/chat/job`, and
  `/api/chats/<id>` is a regex (`13849`).

### 0.2 Identity (cookies)
| Cookie | Name | Max-Age | Flags | Set by |
| --- | --- | --- | --- | --- |
| Member session | `firas_session` (`1046`) | `2_592_000` s = 30 days (`1047`) | `HttpOnly; SameSite=Lax; Path=/` + `Secure` when `SECURE_COOKIES=1` or `x-forwarded-proto: https` (`1052-1054`). Fly sets `SECURE_COOKIES="1"` (`fly.toml:17`) | login / signup / google-native |
| Guest trial | `firas_guest` (`1131`) | `604_800` s = 7 days (`1132`) | same flags (`1162-1168`) | `POST /api/guest` |

* `currentUser(req)` (`1098-1117`) → member or `null`. The cookie also carries a session version;
  logout-everywhere / password change bumps it and every older cookie silently becomes `null`.
* `currentGuest(req)` (`1156-1161`) → `{ id: "g_<24 hex>", guest: true }` or `null`.
* `callerOf(req)` (`1314-1320`) → `{ user, id, isGuest:false }` | `{ id, isGuest:true }` | `{}`.
  A member cookie always wins over a guest cookie when both are present.
* URLSession's cookie jar must store both cookies and send them on every request (default
  `HTTPCookieStorage` does this). `HttpOnly` is irrelevant to a native client.
* `GET /api/auth/me` (`2009-2012`) knows nothing about guests: with only a guest cookie it answers
  `401 {"error":"not authenticated"}`. The guest identity and its meter are obtained from
  `POST /api/guest` (idempotent — a valid guest cookie is reused, `2017-2027`), never from
  `/api/auth/me`. A 401 from a members-only route while in guest mode is therefore normal and must
  not trigger a "session expired" screen (the web client guards this in `handleSessionExpired`,
  `app.js:3243`).

Three auth tiers used below:
* **member** — `currentUser` must resolve; guest gets `401`.
* **member-or-guest** — `callerOf` must have an id; otherwise `401`.
* **none** — public.

### 0.3 Response helpers
* `sendJson(res, status, obj)` (`1691-1695`) → `Content-Type: application/json; charset=utf-8`.
* Several handlers write JSON by hand with `Content-Type: application/json` (no charset) —
  `/api/search`, `/api/images`, `/api/fetch`, `/api/imgproxy`. Parse as UTF-8 regardless.
* A few 429/401/415/413/502 responses are **empty or plain text**, noted per endpoint. The Swift
  client must not assume every non-2xx body is JSON.

### 0.4 Body reading
* `readBody(req, limit = 2_000_000)` (`1646-1680`) — the limit is a **JS string length (UTF-16
  units), not bytes** (deliberate, see comment `1662-1665`). Exceeding it destroys the socket and
  rejects with `Error("body too large")`. Handlers that `try/catch` around it answer
  `400 {"error":"invalid JSON body"}` or `400 {"error":"invalid JSON"}`; handlers that do not
  (e.g. `handleTranslate`) fall through to the router's `500 {"error":"internal error"}`.
* `readJson(req, limit)` (`1682-1689`) → parsed object, `{}` for an empty body, `null` on a parse
  error. Most handlers then answer `400 {"error":"invalid JSON body"}` / `{"error":"invalid JSON"}`;
  `handleTranslate` never checks for `null` and answers `200 {"text":""}` instead (§5). When a
  handler calls `readJson(req)` with no limit the default `2_000_000` applies.
* Global constants: `CHAT_BODY_LIMIT = 25_000_000` (`442`), `JOB_PAYLOAD_MAX = 600_000` (`9330`),
  `MAX_IMAGES_PER_REQUEST = 10` (`440`), `MAX_IMAGE_B64_BYTES = 8_000_000` (`441`).

### 0.5 Rate limiter
`rateLimited(key, max, windowMs)` (`1076-1086`): in-memory sliding window per key; the call itself
pushes a timestamp, then returns `count > max`. So `max` is the number of **allowed** calls per
window; the (max+1)th is refused. Resets on process restart. Map is bounded to 5000 keys. The
window is always `60_000` ms in every call site. Keys are per user id / guest id / IP, never global.

---

## 1. `GET /api/search` — web search (`handleWebSearch`, `6035-6051`)

| | |
| --- | --- |
| Route | `route === "/api/search" && method === "GET"` (`13744`) |
| Auth | member-or-guest (`6039-6041`). Guest allowed. |
| Rate limit | `search:<id>` 30 / min (`6042`) |
| Query | `q` — trimmed, sliced to **300** chars (`6044`). The web client sends at most 280 (`app.js:41038`). |

Responses (all `Content-Type: application/json`):
| Status | Body | Meaning |
| --- | --- | --- |
| 401 | `{"results":[],"error":"auth"}` | no cookie |
| 429 | `{"results":[],"error":"rate"}` | >30/min |
| 400 | `{"results":[]}` | empty `q` |
| 200 | `{"q":"<string>","results":[{title,url,snippet}],"via":"serper"\|"brave"\|"tavily"\|"gemini"\|"ddg"\|"none"}` | |

* `results[]` rows are built by `searchRow` (`5859-5864`): `title` ≤ 300 chars (whitespace
  collapsed), `url` must start `http(s)://`, `snippet` ≤ 500 chars (may be `""`). At most **8** rows
  per provider (`.slice(0, 8)`), the web client uses the first 6 (`app.js:41043`).
* Provider chain `webSearchChain` (`6022-6033`): first provider that returns ≥1 row wins, in order
  `serper → brave → tavily → gemini(grounded) → ddg`. `via: "none"` with `results: []` means every
  provider came back empty or down — treat as "no results", not an error.
* Env gating: `SERPER_API_KEY` (`5854`), `BRAVE_API_KEY` or `BRAVE_SEARCH_KEY` (`5855`),
  `TAVILY_API_KEY` (`5856`), Gemini keys (`GEMINI_KEYS`, `217-229`). DuckDuckGo is keyless
  (`5993-6017`), so **this endpoint never returns `not_configured`**.
* Per-provider timeout `SEARCH_TIMEOUT_MS` default `8000` (`5853`); gemini uses
  `max(SEARCH_TIMEOUT_MS, 15000)` plus a 1800 ms redirect-resolve pass (`5924-5947`). Worst case
  wall time for a fully-failing chain is roughly 8+8+8+15+8+8 s — the app should use its own
  timeout (the web client's silent-search path passes a tight AbortController budget,
  `app.js:41031-41037`).
* Gemini-grounded rows may have `title` = bare hostname (`5945`), and `url` may still be a
  `vertexaisearch.cloud.google.com/grounding-api-redirect/...` link when the redirect did not
  resolve in 1.8 s (`resolveGroundingLinks`, `5928-5949`) — open it anyway; it redirects.
  DuckDuckGo fallback: `searchDdg` (`6002-6020`).

## 2. `GET /api/images` — keyless photo search (`handleImageSearch`, `6367-6390`)

| | |
| --- | --- |
| Route | `13745` |
| Auth | member-or-guest (`6371`) |
| Rate limit | `images:<id>` 40 / min (`6372`) |
| Query | `q` — trimmed, sliced to **120** chars (`6374`) |
| Upstream | Openverse `api.openverse.org/v1/images/?format=json&mature=false&page_size=10&q=` (`6378`) |

| Status | Body |
| --- | --- |
| 401 | `{"results":[],"error":"auth"}` |
| 429 | `{"results":[],"error":"rate"}` |
| 400 | `{"results":[]}` (empty q) |
| 200 | `{"q":"…","results":[{"url":"https://…","title":"≤100 chars"}]}` — max **8** rows; `url` is the Openverse thumbnail (falls back to full url), https only. Upstream failure → `results: []` with 200. |

No env dependency. Used by the web client only inside the Agent/Code pipeline to decorate generated
sites (`app.js:55835-55841`).

## 3. `GET /api/fetch` — read a pasted URL as text (`handleUrlFetch`, `6506-6536`)

| | |
| --- | --- |
| Route | `13746` |
| Auth | member-or-guest (`6510`) |
| Rate limit | `fetch:<id>` 20 / min (`6511`) |
| Query | `url` — trimmed; if it does not start with `http(s)://`, `https://` is prepended (`6513-6514`). Web client slices to 500 chars before sending (`app.js:55937`). |

| Status | Body |
| --- | --- |
| 401 | `{"text":"","error":"auth"}` |
| 429 | `{"text":"","error":"rate"}` |
| 400 | `{"text":"","error":"bad url"}` — unparsable URL |
| 400 | `{"text":"","error":"blocked"}` — host is localhost / private / link-local / `.local` / `metadata.google.internal` (`6516-6518`) |
| 200 | `{"url":"<final target as requested, not post-redirect>","title":"≤200","text":"≤40000"}` — **any fetch failure, non-2xx, blocked redirect hop, or non-text content type yields 200 with `text:""`** (`6531-6533`). Treat empty `text` as "could not read". |

* Fetch goes through `safeProxyFetch` (`6456-6474`): manual redirects, max 3 hops, every hop's
  hostname DNS-resolved and rejected if any A/AAAA is private (`proxyHostAllowed`, `6426-6438`).
* HTML: `<title>` extracted, scripts/styles/comments/tags stripped, entities decoded, whitespace
  collapsed, first 800 000 raw chars considered, output capped at 40 000 chars (`6526-6529`).
  `text/*`, `json`, `xml`, `markdown` content types are returned raw (40 000 cap). Anything else
  (PDF, images) → `text:""`.
* Headers sent upstream: desktop Chrome UA (`SEARCH_UA`, `3140`), `Accept: text/html,…`.

## 4. `GET /api/imgproxy` — same-origin image relay (`handleImgProxy`, `6478-6504`)

| | |
| --- | --- |
| Route | `13747` |
| Auth | member-or-guest (`6481`) → `401 {"error":"auth"}` |
| Rate limit | `imgproxy:<id>` 80 / min → **429 with empty body** (`6482`) |
| Query | `u` — must start `https://` (http is refused), host must not be private/`.local` (`6486-6488`) → **400 empty body** |

| Status | Body / headers |
| --- | --- |
| 200 | raw image bytes. `Content-Type` = upstream type (allowlist below), `Cache-Control: public, max-age=86400`, `Content-Length`, `X-Content-Type-Options: nosniff`, `Content-Security-Policy: sandbox; default-src 'none'` (`6499`) |
| 415 | empty — upstream not 2xx or type not in `["image/png","image/jpeg","image/jpg","image/gif","image/webp","image/avif","image/bmp","image/tiff","image/x-icon","image/vnd.microsoft.icon"]` (`6495-6496`). **SVG is deliberately refused.** |
| 413 | empty — body > **4_000_000 bytes** (`6498`) |
| 502 | empty — network error / blocked redirect hop |

A native app rarely needs this (it can load remote images directly); it exists for the web
client's PDF canvas taint problem (`app.js:34634`, `40552`). Use it only when reproducing a
document export that embeds a remote image.

## 5. `POST /api/translate` — one-shot translation (`handleTranslate`, `3118-3135`)

| | |
| --- | --- |
| Route | `13793` |
| Auth | **member only** (`currentUser`, `3119-3120`). A guest gets `401 {"error":"not authenticated"}` — by design; the web client hides its translate button for guests (`app.js:79114-79116`). |
| Rate limit | `translate:<userId>` 40 / min → `429 {"error":"too many requests"}` (`3121`) |
| Body limit | `readJson(req, 200_000)` (`3122`) — no try/catch, so an oversize body is a `500 {"error":"internal error"}`. A **malformed** JSON body is not a 400: `readJson` yields `null`, both branches see no text, and the reply is `200 {"text":""}` |

Request body (JSON), two shapes:
1. Pair mode (announcements): `{ "title": string, "body": string, "to": "en"|"ar" }` — engaged when
   `title` **or** `body` is a string (`3124`). `title` sliced to 400, `body` to 8000. Both blank →
   `200 {"title":"","body":""}`. Response `200 {"title":"…","body":"…"}`; on engine failure the
   **original** title/body come back unchanged with 200 (`3129`).
2. Text mode (chat-translation view): `{ "text": string, "to": "en"|"ar" }`. `text` sliced to
   **8000** chars; blank → `200 {"text":""}`; success `200 {"text":"<translation>"}`; engine
   failure → `200 {"text":"<original>"}` (`3131-3134`).

* `to`: anything other than the case-insensitive string `"en"` means Arabic (`3123`).
* Engine: `translateFetch` (`3084-3097`) — Gemini OpenAI-compat endpoint if any Gemini key,
  then keyless pollinations `https://text.pollinations.ai/openai` (`FALLBACK_URL`, `47`). Each
  call has a 22 s hard timeout (`TRANSLATE_TIMEOUT_MS`, `3081`). **Never returns `not_configured`**;
  "failed" is indistinguishable from "translation equals source" except by comparing strings.
* The web client chunks long chat text at 5200 chars and caps itself at 26 requests per
  translation pass to stay under the 40/min bucket (`app.js:79121-79126`). Mirror that.

## 6. `GET /api/kb` — admin knowledge-base list (`handleKbList`, `7941-7946`)

| | |
| --- | --- |
| Route | `13799` (also `POST` `13800` = add, `DELETE ?id=` `13801` = remove) |
| Auth | member **and** `isAdmin(user)` (`7535`): email in `ADMIN_EMAILS` env (default `firasnozad@gmail.com`, `7534`). Non-admin → `403 {"error":"admins only"}`; no cookie → `401 {"error":"auth required"}`. |
| 200 | `{"books":[{"id":"kb<base36>","title":"≤200","chunks":<int>,"ts":<ms>}]}` |

Admin-only; the app can gate on `user.admin` from `/api/auth/me` (`publicUser`, `1424-1426`) and
hide it otherwise. `POST /api/kb` (`7947-7961`): body limit `24_000_000` chars (`7951`), fields
`{title ≤200 (default "Untitled"), text}`; errors `400 {"error":"invalid JSON"}`,
`400 {"error":"text too short"}` (trimmed `text` shorter than 20 chars), `400 {"error":"no usable
text"}`; success `200 {"ok":true,"id":"kb…","title":"…","chunks":<int>}`. `DELETE /api/kb?id=`
always answers `{"ok":true}` (`7962-7970`).

## 7. `GET /api/version` (`handleVersion`, `6538-6546`)

* Route `13816`. **Auth: none.** No rate limit.
* `200 {"version": <integer>}` — the newest `mtimeMs` (floored) of `app.js`, `index.html`,
  `styles.css` on the server. `0` if none can be stat'd.
* The web client polls it every **15 s** and reloads when the number changes while idle
  (`app.js:50797-50815`). For a native app this number only tells you the *web bundle* changed;
  it is not an API version. Useful at most as a "server reachable" ping (no auth, tiny body).

---

## 8. Static serving — `serveStatic` (`13357-13548`)

Only reached for `GET`/`HEAD` on a route no API handler claimed (`13851`).

### 8.1 What is served at all
* Allowlist `STATIC_ALLOW` (`13139-13163`): `index.html`, `app.js`, `styles.css`, `robots.txt`,
  `sitemap.xml`, `llms.txt`, `terms.html`, `privacy.html`, `firebase-config.js`,
  `logo-preview.html`, `favicon.ico`, `manifest.webmanifest`, `sw.js`.
* Prefixes `STATIC_ALLOW_PREFIX = [".well-known/", "media/", "models/"]` (`13171`).
* Anything else (including **`/brand/*.svg`**) falls back to `index.html` with **200 text/html**
  (`13387`). **The `brand/` directory is NOT served** — bundle the SVGs in the app
  (`brand/firas-mark.svg`, `firas-mark-dark.svg`, `firas-mark-light.svg`, `firas-icon-*.svg`,
  `firas-lockup-*.svg`, `mentronx*.svg`). Do not fetch them from the site.
* `.well-known/` is allowlisted but **the directory does not exist in the repo** (`ls` confirms).
  An `apple-app-site-association` for universal links would have to be added to the deploy; today
  `/.well-known/apple-app-site-association` returns the SPA shell as text/html.
* `/terms` and `/privacy` (with or without trailing slash) rewrite to the two HTML files
  (`13373-13374`) — open these in `SFSafariViewController`; they are plain HTML pages.
* `/__/auth/*` is proxied to Firebase's own auth handler (`13330-13355`); not for native use.
* Path containment: realpath must be inside the project and outside `DATA_DIR`, else 404
  (`13389-13404`).

### 8.2 Media inventory (`media/`, served under `/media/<name>`)
| File | Size | Notes |
| --- | --- | --- |
| `firas-trailer.mp4` | 52 551 377 B | launch trailer, 1920×1080, 83.6 s (referenced by the built-in announcement as `/media/firas-trailer.mp4`) |
| `icon.svg` | 259 B | app glyph (svg is served here because `media/` is a prefix) |
| `logo-48.png`, `logo-180.png`, `logo-192.png`, `logo-512.png` | 768 / 1550 / 1650 / 4293 B | PWA/touch icons |
| `og-agent.jpg`, `og-brain.jpg`, `og-chat.jpg`, `og-code.jpg`, `og-image.jpg` | ~51-58 KB each | Open Graph cards, one per product route (`SEO_ROUTES`, `13185-13206`) |
| `models/espcn-x3.onnx` | 240 078 B | super-resolution weights, served under `/models/`, MIME `application/octet-stream` (`524`) |

### 8.3 Headers and caching
* MIME table `506-528` (`.svg` → `image/svg+xml`, `.webmanifest` →
  `application/manifest+json`, `.mp4`/`.webm` video types, unknown → `application/octet-stream`).
* **Video (`.mp4`/`.webm`) path** (`13415-13448`): honours `Range: bytes=a-b` → `206` with
  `Content-Range`, `Accept-Ranges: bytes`, `Cache-Control: public, max-age=86400`,
  `X-Content-Type-Options: nosniff`; malformed/out-of-range → `416`. No gzip, no ETag.
  AVPlayer works directly against `/media/firas-trailer.mp4`.
* **Everything else**:
  * `Cache-Control: public, max-age=31536000, immutable` **only when the request URL carries
    `?v=` / `&v=`** (`13502-13503`); otherwise `no-cache` + weak `ETag` (`W/"<len hex>-<sha1[0:16]>"`,
    computed over the bytes actually sent, `13511-13516`) with `304` on a matching
    `If-None-Match` (`13518-13522`). `index.html` is always `no-cache`+ETag.
  * gzip when `Accept-Encoding` includes `gzip` and ext ∈ `.html .js .mjs .css .json .svg .txt .xml`
    (`GZIP_TYPES`, `13300`; `13482-13488`); `Vary: Accept-Encoding` always set.
  * Security headers on every static response (`13526-13546`): `X-Content-Type-Options: nosniff`,
    `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: SAMEORIGIN` (`13534`),
    `Content-Security-Policy: base-uri 'self'; object-src 'none'`.
  * HTML responses get `app.js?v=…`/`styles.css?v=…` stamped from file mtimes (`13465-13480`) and,
    for `/agent`, `/code`, `/brain`, `/chat`, per-route `<title>`/meta rewrites (`seoRewrite`,
    `13245-13292`). Irrelevant to the native app except that these four paths are valid deep-link
    targets on the web.
* Missing file after allowlist → `index.html`; read failure → `404 text/plain "404 Not Found"`.

---

## 9. Announcements (`/api/announcements`)

Routes `13789-13792`. Storage: `DB.announcements` array, persisted (`625-627`). Max **100** records
kept (`7719`), GET returns at most **50** (`7696`).

### 9.1 `GET /api/announcements` (`handleAnnouncementsGet`, `7690-7698`)
* Auth: **member-or-guest** (`7693`) → `401 {"error":"authentication required"}` without a cookie.
* `200 {"announcements":[Announcement…],"admin":<bool>}` — sorted pinned-first, then `ts` desc.
  `admin` is true only for an `ADMIN_EMAILS` member; guests always get `false`.

### 9.2 Announcement record schema (as stored and returned; `7716`)
| Field | Type | Limit / rule | Source |
| --- | --- | --- | --- |
| `id` | string | `"a" + base36(ts) + 5 random base36` | server |
| `title` | string | ≤ 200, trimmed, Arabic original | POST `title` |
| `body` | string | ≤ 4000, trimmed, Arabic original, `\n` paragraphs | POST `body` |
| `titleEn` | string | ≤ 200 — **bilingual by storage**, may be `""` | POST `titleEn` |
| `bodyEn` | string | ≤ 4000, may be `""` | POST `bodyEn` |
| `image` | string | `""` or `data:image/(png|jpeg|jpg|webp);base64,…` or `http(s)://…` (`ANN_IMG_OK`, `7684`); total length ≤ 600 000 else `413 {"error":"image too large"}` | POST/PATCH `image` |
| `video` | string | `""` or `/media/<[A-Za-z0-9._-]>.(mp4|webm)` or `https://…mp4|webm` (`ANN_VID_OK`, `7688-7689`); invalid → silently `""` | POST `video` (not PATCHable) |
| `pinned` | bool | | POST `pinned` |
| `ts` | number | `Date.now()` ms at creation | server |
| `by` | string | `user.name \|\| "Firas"` | server |
| `editedTs` | number | present only after a PATCH (`7759`) | server |

**There is no `audience`, `expiry`/`expiresAt`, `lang`, `locale`, `platform` or `minVersion`
field.** Every record is for everyone, forever, until deleted. Language is handled by the client:
show `titleEn`/`bodyEn` when the UI is English and they are non-empty, else the Arabic
`title`/`body`; the web client falls back to `POST /api/translate` (pair mode) for records that
have no English copy (`app.js:45191`) — a guest cannot do that (translate is member-only), so a
guest in English simply sees the Arabic text.

### 9.3 The built-in launch post (client-side, not on the server)
`app.js:44692-44724` ships `BUILTIN_ANNOUNCEMENTS` — one record with `id: "builtin_launch"`,
`pinned: true`, `builtin: true`, `by: "Firas"`, `ts: Date.UTC(2026, 7, 5)` (= 2026-08-05T00:00Z),
`video: "/media/firas-trailer.mp4"`, and the Arabic/English title+body copied verbatim in
`brand/announcement-launch.json` ("payload" key). The web client merges it into the server list
unless a server record with the same id exists (`annMerge`, `44733-44740`), and hides edit/delete
for ids starting with `builtin_` (`44728-44731`). The iOS app must ship the same record locally
(`brand/announcement-launch.json` is the reference copy) — **do not POST it**; the server already
warns that doing so creates a duplicate.

Unread badge: web stores the newest seen `ts` in localStorage and shows a dot when any
`announcement.ts > seen` (`app.js:44755-44761`).

### 9.4 Admin writes (only when `admin === true`)
* `POST /api/announcements` (`7699-7722`): member + admin, body limit `CHAT_BODY_LIMIT`
  (parse error → `400 {"error":"invalid JSON"}`). All of `title`, `body`, `image`, `video` empty →
  `400 {"error":"empty announcement"}`. `200 {"ok":true,"announcement":<record>}`.
* `PATCH /api/announcements` (`7744-7762`): body `{id, title?, body?, image?}` — only these three
  are editable; `image: ""` removes the image; unknown id → `404 {"error":"not found"}`.
  `200 {"ok":true,"announcement":<record>}`.
* `DELETE /api/announcements?id=<id>` → `200 {"ok":true}` even when the id is unknown;
  `DELETE /api/announcements?all=1` → `200 {"ok":true,"removed":<n>,"ids":[…]}` (`7723-7743`).
* Non-admin member → `403 {"error":"admins only"}`; no cookie → `401`.

---

## 10. Durable job / file endpoints — auth summary

Detailed contracts belong to the chat/agent/media slices; this table only answers "which cookie".
`ownerId` = member id or guest id; a job is readable only by its owner (`403 {"error":"forbidden"}`).

| Endpoint | Method | Auth | Notes / distinctive errors |
| --- | --- | --- | --- |
| `/api/chat/job` | POST | member-or-guest (`12538`) | rate `chatjob:` 60/min member, **30/min guest** (`12540`); body ≤ `CHAT_BODY_LIMIT` but `413 {"error":"payload_too_large"}` above `JOB_PAYLOAD_MAX = 600_000` chars (`12560`) — image turns must use the live stream; guest + `kind:"agentrun"`/`product:"agent"` → `403 {"ok":false,"error":"account_required","feature":"agent"}` (`12554-12556`); `503 {"error":"storage_unavailable"}` when the job store is unreachable |
| `/api/chat/job?id=` | GET | member-or-guest (`12658-12661`) | `phase` ∈ `processing`/`completed`/`failed`…; `503 storage_unavailable` |
| `/api/chat/job/file?id=&part=` | GET | member-or-guest (`10491-10494`) | long-file artifacts only: `404 unknown_artifact`, `403 forbidden`, `400 not_a_longfile`, `409 {"error":"artifact_not_ready","phase":…}`, `400 bad_part` (`part` must be 1-6 digits); without `part` → `{ok, phase, artifact:{artifactId, artifactVersion:1, format, pageCount, coverPages, bodyPages, partsDone, partsTotal, completedPages, complete, questionBank, meta}, partsUrl:"/api/chat/job/file?id=…&part={part}"}` |
| `/api/chat/cancel` | POST | (chat slice) | |
| `/api/agent/job?id=` | GET | member-or-guest (`12100-12103`) | `{job: null}` when unknown; `503 storage_unavailable` |
| `/api/agent/job-stream?id=` | GET (SSE) | member-or-guest | rate `agent-job-stream:<owner>:<ip>` 90/min (`12189`) |
| `/api/agent/artifact?id=&index=&download=1` | GET | member-or-guest (`12419-12422`) | **only** query keys `id`,`index`,`download` allowed else `400 bad_request`; `id` `/^[A-Za-z0-9_-]{1,96}$/`, `index` 1-3 digits; rate `agent-artifact:` 30/min; `404 artifact_not_found`, `502 artifact_unavailable`; response is the file bytes with `Content-Disposition` inline/attachment, `Cache-Control: private, no-store` |
| `/api/agent/start`, `/api/agent/poll` | POST / GET | **retired** — the router answers `410 {"error":"durable_agent_route_required"}` before any auth check (`13763-13765`) | never call; the member-only / `503 not_configured` bodies at `8878-8881` are dead code |
| `/api/agent/credits` | GET | member-or-guest (`8960-8972`) | guest gets `{remaining:0, allowance, used:0, held:0, resetAt, period:"daily", configured:<bool>, guest:true, locked:true}`; member gets `manusCreditView` (`8621+`). `configured` reflects `MANUS_API_KEY`. |
| `/api/image/job` | POST | **member only**; guest → `403 signin_required feature:image` (`5137-5141`) | rate `imgjob:` 20/min; body ≤ 30 000 000 chars |
| `/api/image/job?id=` | GET | member only (`5193-5194`, plain-text `401 auth required`) | `{phase:"running"\|"done"\|"fail", key?, error?}` |
| `/api/image?key=` (and generation params) | GET | member only; guest → `403 {"error":"signin_required","feature":"image"}` (`5217-5220`); no cookie → plain-text `401 auth required` | rate `img:` 240/min; keyed reads served with `Cache-Control: public, max-age=86400` |
| `/api/image/quota` | **POST** | member only; guest → `403 {"ok":false,"error":"signin_required","feature":"image"}` (`3240`) | `200 {ok:true, limit, used, remaining}` / `429 {ok:false, limit, used, remaining:0}` |
| `/api/image/edit` | POST | member only (guest `403 signin_required image`, `3927`) | rate `imgedit:` 30/min (plain-text 429); `503 {"error":"edit_unavailable"}` when no Replicate and no OpenAI budget (`3997-3998`) |
| `/api/video/job` | POST | member only; guest `403 signin_required video` (`4739`) | `503 not_configured feature:video` without `REPLICATE_API_TOKEN` (`4742`); rate `vidjob:` 10/min; `429 {"error":"site_media_ceiling","limit":120}` when the site-wide 24 h media counter is full (`4784-4785`) |
| `/api/video/job?id=` | GET | member only (`4826-4827`) | |
| `/api/video/file?id=` | GET | **member-or-guest** (`4840-4841`) | Range supported (206/416), `Cache-Control: private, max-age=31536000, immutable` |
| `/api/video/quota` | GET | member only (`5350-5351`) | `{ok, limit, used, remaining, seconds}` |
| `/api/video` (legacy live) | GET | member only; guest `403 signin_required video` (`5310`) | `503` plain text `video engine not configured` when `HF_ACCOUNTS` is empty (`5328`) |
| `/api/music/job` | POST | member only; guest `403 signin_required music` (`4879`) | `503 not_configured feature:music` (`4883`) when `MUSIC_PROVIDER==="musicapi"` and no `MUSICAPI_KEY`, or otherwise no `REPLICATE_API_TOKEN` (`4882`); rate `musicjob:` 10/min; same `site_media_ceiling` 429 (`4910-4911`) |
| `/api/music/job?id=` | GET | member only (`4952-4953`) | |
| `/api/music/file?id=` | GET | **member-or-guest** (`4970-4971`) | Range supported |
| `/api/brain/*` | — | brain slice; guest without any cookie → `403 signin_required feature:brain` (`8345`) | `/api/brain/whole` also `503 not_configured feature:brain_whole` without `MINIMAX_API_KEY` (`8978`) and guest → `403 signin_required brain_whole` (`8977`) |
| `/api/share?id=` | GET | **none — public by design** (`9296`) | `200 {id, title, messages, ts, one}` / `404 {"error":"not found"}` |
| `/api/share` | POST / DELETE | member only; rate `share:` 5/min | |
| `/api/live/token` | POST | member-or-guest; no identity → `403 {"error":"signin_required","feature":"live"}` (`6219`) | `503 {"error":"no_engine"}` without `OPENAI_API_KEY` and Gemini (`6223`); rate `live:` 6/min member, **3/min guest** (`6222`); optional body `{prefer:"gemini", voice}` read with limit 2 000 (`6240`) |
| `/api/transcribe` | POST | member-or-guest (`6314`) | `{probe:true}` → `{ok:<bool GEMINI configured>}` (`6321`); `503 {"error":"no stt engine"}` (`6322`); body ≤ `CHAT_BODY_LIMIT`, `{audio:<base64 4 000–20 000 000 chars>, format:"mp3"\|"wav", lang}`; a guest passes **two** `rateLimited` calls on the same key `stt:<id>` (12-cap at `6317`, 20-cap at `6323`), so a guest is effectively capped at **6 requests/min**; the daily `voice` unit is charged by `chargeVoice` (`5716-5727`) after validation |
| `/api/tts` | POST | member-or-guest | rate `tts:` 90/min member, **25/min guest** (`5735`); `503 {"error":"tts unavailable","reason":"no male voice engine available"}` when no OpenAI/Gemini voice and `TTS_ALLOW_FEMALE_FALLBACK` unset (`5825`) |
| `/api/push/register`, `/api/push/unregister` | POST | member only (`1457-1458`, `1480-1481`) | rate `push:` 30/min; **accepts registrations even when `APNS_*` env is missing** — `apnsConfiguration()` (`1491-1498`) returns `null` and sends are silently skipped; there is no `not_configured` signal for push. Full contract and notification payload in §15 |
| `/api/usage/charge` | POST | member-or-guest (`7655-7657`) | body ≤ 2000 chars `{product:"code"\|"agent", cid?}`; guest + `agent` → `403 {"ok":false,"error":"signin_required","feature":"agent"}` (`7665`); `200 {"ok":true,"sub":<subInfo\|guestSubInfo>}` |
| `/api/max/quota` | POST | member only | always `200 {ok:true, limit:0, used:0, remaining:-1}` (`3227-3231`) |
| `/api/guest` | POST / DELETE | none | POST: signed-in member → `{guest:false, user:<publicUser>}`; otherwise mints/reuses cookie → `{guest:true, user:{id:"g_…", name:"", email:"", guest:true, admin:false, sub:<guestSubInfo>}}` (`2017-2027`); rate `guest:<ip>` 20/min → `429 {"error":"too many requests"}`. DELETE clears the cookie (`Max-Age=0`) → `{ok:true}` (`2030-2034`). |
| `/api/auth/me` | GET | member only (`2009-2012`) | `200 {"user":<publicUser>}`; guest cookie or none → `401 {"error":"not authenticated"}` |
| `/api/chats`, `/api/chats/<id>` | GET/POST · GET/PUT/DELETE | member only (`2539-2541`): `401 {"error":"not authenticated"}` | guests keep history on-device only (chat slice) |
| `/api/memory` | GET | member only (`7512-7515`): `401 {"error":"authentication required"}` | `200 {"memory":[<string>…]}` |
| `/api/memory` | DELETE (`?i=N` removes index N; no `i` clears all) | member only (`7517-7529`) | `200 {"ok":true,"memory":[…]}` |
| `/api/memory/learn` | POST | member only (`7462-7464`) | rate `mem:` 60/min → `429 {"error":"rate limited"}`; body ≤ 200 000 `{user ≤4000, assistant ≤2000}` (`400 invalid JSON`); empty `user` → `200 {"ok":true,"added":0}` |
| `/api/share` | POST | member only (`9217-9218`): `401 {"error":"auth required"}` | rate `share:` 5/min; body `{chatId, msg?, cid?}` (default `readBody` limit 2 000 000, `400 invalid JSON`); `404 {"error":"not found"}` when the chat is not the caller's; at most `SHARES_PER_USER_MAX = 20` snapshots per user (`9216`) |
| `/api/share` | DELETE `?id=` | member only (`9303-9310`) | `403 {"error":"not yours"}` unless owner or admin; unknown id still `{ok:true}` |
| `/api/redeem` | POST | member only (`7542-7544`): `401 {"error":"authentication required"}` | body ≤ 4 000 `{code}` — normalised to `[A-Z0-9]`, ≤ 40 chars, fewer than 5 → `400 {"error":"invalid code"}`; then `404 {"error":"code not found"}`, `403 {"error":"code disabled"}`, `410 {"error":"code expired"}`, `409 {"error":"code fully used"}`, `403 {"error":"code not for this account"}`, `409 {"error":"you already redeemed this code"}`; success `200 {"ok":true,"sub":<subInfo>}` (`7548-7589`). Rate `redeem:<uid>` 8/min or `redeemip:<ip>` 20/min → `429 {"error":"too many attempts, please wait a minute"}` |

---

## 11. Body-size limits per endpoint (JS string length, see §0.4)

| Endpoint | Limit | On overflow |
| --- | --- | --- |
| `POST /api/chat`, `/api/chat/job` | `CHAT_BODY_LIMIT` 25 000 000 (`12761`, `12541`) | `400 invalid JSON body` |
| `POST /api/chat/job` | additionally `413 payload_too_large` above 600 000 (`12560`) | use live stream |
| `POST /api/transcribe` | 25 000 000 (`6318`); audio base64 must be 4 000–20 000 000 chars, `[A-Za-z0-9+/=]` only (`6329-6330`) | `400 no audio` / `400 bad audio` |
| `POST /api/translate` | 200 000 (`3122`) | 500 internal error |
| `POST /api/tts` | 200 000; `text` sliced to 1400 (`5736-5738`) | `400` |
| `POST /api/live/token` | 2 000 (`6240`) | ignored (no body is normal) |
| `POST /api/usage/charge` | 2 000 (`7658`) | 500 |
| `POST /api/redeem` | 4 000 (`7547`) | 500 |
| `POST /api/announcements`, PATCH | 25 000 000; `image` ≤ 600 000 | `400 invalid JSON` / `413 image too large` |
| `POST /api/kb` | 24 000 000 (`7951`) | `400 invalid JSON` |
| `POST /api/image/job` | 30 000 000 (`5145`) | body ignored → prompt empty → 400 |
| `POST /api/music/job`, `/api/agent/start` | 200 000 (`4886`, `8883`) | |
| `POST /api/auth/google-native` | 20 000 (`13678`) | |
| `POST /api/push/register` | default 2 000 000 | |
| Brain uploads | `BRAIN_BODY_LIMIT` 24 000 000 (`7999`) | |

---

## 12. Rate-limit buckets a phone will actually hit (all windows = 60 s)

| Bucket key | Max/min | Endpoint | 429 body |
| --- | --- | --- | --- |
| `chat:<id>` | 120 member / **30 guest** | `POST /api/chat` (`12754`) | `{"error":"too many requests, please slow down"}` |
| `chatjob:<id>` | 60 / **30 guest** | `POST /api/chat/job` (`12540`) | `{"error":"too many requests"}` |
| `search:<id>` | 30 | `/api/search` | `{"results":[],"error":"rate"}` |
| `images:<id>` | 40 | `/api/images` | `{"results":[],"error":"rate"}` |
| `fetch:<id>` | 20 | `/api/fetch` | `{"text":"","error":"rate"}` |
| `imgproxy:<id>` | 80 | `/api/imgproxy` | empty body |
| `translate:<uid>` | 40 | `/api/translate` | `{"error":"too many requests"}` |
| `tts:<id>` | 90 / **25 guest** | `/api/tts` | `{"error":"rate limited"}` |
| `stt:<id>` | 20 member / **6 guest effective** — the guest pre-check (`6317`, cap 12) and the main check (`6323`, cap 20) push onto the same key, so each guest request counts twice | `/api/transcribe` | `{"error":"rate limited"}` |
| `live:<id>` | 6 / **3 guest** | `/api/live/token` | `{"error":"rate limited"}` |
| `img:<uid>` | 240 | `GET /api/image` | plain text `rate limited` |
| `imgjob:<uid>` | 20 | `POST /api/image/job` | `{"error":"rate_limited"}` |
| `imgedit:<uid>` | 30 | `/api/image/edit` | plain text `rate limited` |
| `vidjob:` / `musicjob:` | 10 | video/music job start | `{"error":"rate_limited"}` |
| `vid:<uid>` | 12 | legacy `GET /api/video` | plain text |
| `agent-artifact:<id>` | 30 | `/api/agent/artifact` | `{"error":"rate_limited"}` |
| `agent-job-stream:<id>:<ip>` | 90 | `/api/agent/job-stream` | |
| `brain:add:` / `brain:q:` / `brainwhole:` | 60 / 120 / 6 | brain | `too many requests` / `rate_limited` |
| `mem:<uid>` | 60 | `/api/memory/learn` (`7465`) | `{"error":"rate limited"}` |
| `share:<uid>` | 5 | `POST /api/share` (`9220`) | `{"error":"too many requests"}` |
| `push:<uid>` | 30 | push register/unregister | `{"error":"too many requests"}` |
| `redeem:<uid>` 8 + `redeemip:<ip>` 20 | | `/api/redeem` (`7545`) | `{"error":"too many attempts, please wait a minute"}` |
| `guest:<ip>` | 20 | `POST /api/guest` (`2022`) | `{"error":"too many requests"}` |
| `auth:<ip>` 12, `login:<email>` 6, `verify:` 30, `vstatus:` 60, `resend:` 4, `forgot:` 6, `reset:` 10, `acct:<uid>` 10, `auth:google:<ip>` 12 | | auth slice (`1860-2336`, `13675`, `13707`) | |

A per-minute bucket is **not** a quota: a 429 from these means "slow down and retry after ≤60 s",
whereas a 429 carrying a `quota` object (§13.4) means "done for today".

---

## 13. Quota display — the server-side tables

### 13.1 The day
`serverDay()` (`3197-3204`): UTC shifted by `QUOTA_TZ_OFFSET_MINUTES` (env, default **180** =
UTC+3 Baghdad, `3196`), formatted `YYYY-MM-DD`. Every daily counter resets at Baghdad midnight.
The client message promises "يتجدّد تلقائيًا بعد منتصف الليل". `manusResetAt()` (`8614-8620`)
computes the next such midnight as an epoch ms for the credits `resetAt`.

### 13.2 Member plans — `PLAN_LIMITS` / `limitsFor` / `planOf` / `subInfo`
```js
// server.mjs:1347-1357
const PLAN_LIMITS = {
  free:      { ai: -1, code: -1, agent: -1, brain: -1, internal: -1, voice: -1 },
  gold:      { ai: -1, code: -1, agent: -1, brain: -1, internal: -1, voice: -1 },
  diamond:   { ai: -1, code: -1, agent: -1, brain: -1, internal: -1, voice: -1 },
  unlimited: { ai: -1, code: -1, agent: -1, brain: -1, internal: -1, voice: -1 },
};
function limitsFor(plan) { return PLAN_LIMITS[plan] || PLAN_LIMITS.free; }   // 1358
```
* **Every member product is unmetered (`-1`)**. The long comment above it (`1319-1346`) describes
  numeric abuse ceilings (2000/day etc.) — that comment is stale; the code is all `-1`.
  `limitsFor` never returns a ceiling, so the member branch in `/api/chat` (`12892-12898`) and
  `/api/usage/charge` (`7671-7672`) never 429s on quota.
* Plan names: `free` (default), `gold`, `diamond` (timed, `expiresAt` ms), `unlimited` (never
  expires). `planOf(user)` (`1361-1369`): expired gold/diamond → `free`; unknown → `free`.
  Plans are granted only by redeem codes (`POST /api/redeem`, `7542-7590`).
* **Arabic plan labels live in the web client only** (`app.js:45282-45286`), copy verbatim:

  | plan | icon | ar | en |
  | --- | --- | --- | --- |
  | `free` | ✦ | `المجانية` | `Free` |
  | `gold` | 👑 | `Gold` | `Gold` |
  | `diamond` | 💎 | `Diamond` | `Diamond` |
  | `unlimited` | ♾️ | `غير محدودة` | `Unlimited` |

  `unlimited` expiry text: `دائم — لا ينتهي` / `Permanent — never expires` (`app.js:45322`).
  The server itself has no Arabic plan strings (`grep` → none).
* **Do not copy `PLAN_FEATURES` (`app.js:45290-45308`)** — its bullets ("١٠٠ رسالة فِراس AI يوميًا",
  "1000 Firas AI messages / day", …) predate the all-`-1` table and no longer describe the server.
  The live meter (`subMetersHtml`, `app.js:45310-45320`) renders `∞` whenever `limits[k] < 0` —
  today every member row — and `used / limit` in Arabic-Indic digits (`arDigits`) otherwise; the
  row labels are `فِراس AI` / `فِراس Code` / `فِراس Agent` / `فِراس Brain` (same in English with
  `Firas`).
* Guest-mode badge: `STR.ar.guestBadge` = `وضع الضيف` / `STR.en.guestBadge` = `Guest mode`
  (`app.js:691`, `1788`).
* `subInfo(user)` (`1386-1401`) — the object returned as `user.sub` by `/api/auth/me`,
  `/api/auth/login`, `/api/redeem`, `/api/usage/charge`:
  ```json
  { "plan": "free", "expiresAt": null, "daysLeft": null,
    "limits":    { "ai": -1, "code": -1, "agent": -1, "brain": -1 },
    "used":      { "ai": 0,  "code": 0,  "agent": 0,  "brain": 0 },
    "remaining": { "ai": -1, "code": -1, "agent": -1, "brain": -1 } }
  ```
  `expiresAt` (ms) and `daysLeft` (ceil) are non-null only for active gold/diamond. `remaining` is
  `-1` whenever the limit is `-1`. `used` counters still increment (statistics only).
* `publicUser(u)` (`1424-1426`) = `{ id, name, email, admin:<bool>, sub:<subInfo> }`.

### 13.3 Guests — `GUEST_LIMITS` / `guestSubInfo`
```js
// server.mjs:1133-1152 (env override, clamped ≥ 0; 0 = feature closed to guests)
ai:       GUEST_DAILY_AI       || 180
code:     GUEST_DAILY_CODE     || 60
agent:    GUEST_DAILY_AGENT    || 24     // but agent is refused to guests before charging (§10)
brain:    GUEST_DAILY_BRAIN    || 120
internal: GUEST_DAILY_INTERNAL || 300    // nomem:true helper calls
voice:    GUEST_DAILY_VOICE    || 120    // tts + transcribe + live, one bucket
```
* Per **cookie** per day. A second, invisible **network** bucket keyed on an HMAC of the client IP
  is charged first with cap `limit × GUEST_IP_MULTIPLIER` (= **4**, `1256`; `guestChargeIp`,
  `1264-1276`). Minting a new guest cookie does not reset it.
* `guestSubInfo(id)` (`1185-1193`) — same shape as `subInfo` so one meter view serves both:
  ```json
  { "plan": "guest", "expiresAt": null, "daysLeft": null,
    "limits":    { "ai": 180, "code": 60, "agent": 24, "brain": 120 },
    "used":      { "ai": 0,   "code": 0,  "agent": 0,  "brain": 0 },
    "remaining": { "ai": 180, "code": 60, "agent": 24, "brain": 120 } }
  ```
  Only the cookie bucket is reported; the network bucket is deliberately never exposed.
* Idempotent retries: a charge is skipped when the same `cid` **and** the same last user message
  are re-sent within `RETRY_WINDOW_MS = 120_000` (`1213`); `agent` matches on `cid` alone within
  `MISSION_WINDOW_MS = 45 min` (`1214`, `isRepeatCharge` `1225-1239`). `cid` is sanitised to
  `[A-Za-z0-9_-]{0,64}` (`guestCharge`, `1279-1300`; request-threaded via `guestChargeWithReq`,
  `1306-1310`). Send a fresh cid per turn; reuse it only on a genuine retry.
* Guest product coercion in `/api/chat` (`12882`): anything other than `"code"`/`"agent"` is
  charged as `ai`. The `brain` bucket is charged by the Brain endpoints themselves, which do accept
  a guest cookie (`brainCaller`, `8343-8347`; guest ceilings `BRAIN_GUEST_MAX_DOCS = 3`,
  `BRAIN_GUEST_PAGES_DAILY = 120`, `8341-8342`) — see the brain slice.

### 13.4 Quota-denial bodies (all `429`)
| Source | Body |
| --- | --- |
| guest cookie bucket (`1284-1286`) | `{"error":"guest daily limit reached","guest":true,"quota":{"product":"ai","used":180,"limit":180,"plan":"guest"}}` |
| guest network bucket (`1271-1273`) | same but `"limit": 720` and `"scope":"network"` |
| member product (`12897`, `7678`, `9008`, `9130`, `12866`) | `{"error":"daily quota reached","quota":{"product":"ai"\|"code"\|"agent"\|"brain"\|"internal"\|"voice","used":n,"limit":n,"plan":"free"}}` — unreachable today (limits are −1) but keep the parser |
| Max tier (`12834-12835`) | `{"error":"daily Max limit reached","limit":n,"used":n,"remaining":0}` — unreachable: `MAX_DAILY_LIMIT` default **−1** (`3218`) and no tier has `capped:true` (`grep` → none; `max` is `capped:false`, `435`) |
| image (`3979-3981`, `5163-5164`) | `{"error":"daily_limit","limit":8}` |
| video (`5324-5326`) | `{"error":"daily_limit","limit":2,"used":n}` |
| OpenAI image edit (`4001-4002`) | `{"error":"daily_limit","limit":8}` |
| site-wide media (`4785`, `4911`) | `{"error":"site_media_ceiling","limit":120}` |

What the web client shows (`quotaLimitText`, `app.js:6464-6481`), verbatim:
* guest (`q.plan === "guest"` or the app is in guest mode) → opens the sign-up prompt and shows
  `STR.ar.guestLimitReached` = `انتهت رسائلك المجانية لهذا اليوم كضيف. أنشئ حسابًا مجانيًا للحصول على حدّ أعلى بكثير.`
  / en `You have used today's free guest messages. Create a free account for a much higher limit.`
  (`app.js:716`, `1809`). The client does **not** yet distinguish `scope:"network"`; the guest
  skill recommends a separate "your connection has reached today's shared trial limit" string if
  you surface it.
* member → product name map ar `{ ai: "رسائل فِراس AI", code: "طلبات فِراس Code", agent: "مهام فِراس Agent", brain: "أسئلة فِراس Brain" }`, fallback `الرسائل`; en `{ ai: "Firas AI messages", code: "Firas Code requests", agent: "Firas Agent tasks", brain: "Firas Brain questions" }`, fallback `messages`; then
  ar: `🚦 بلغت الحدّ اليومي من ${name} (${lim}/يوم). يتجدّد تلقائيًا بعد منتصف الليل.\n\nفِراس مجاني بالكامل — هذا السقف موجود ليبقى المحرّك متاحًا للجميع، وهو مرتفع لدرجة أن الاستخدام الطبيعي لا يبلغه.`
  en: `🚦 You've reached today's limit of ${name} (${lim}/day). It resets automatically after midnight.\n\nFiras is completely free — this ceiling only keeps the engine available for everyone, and it is set high enough that ordinary use never reaches it.`
  (`lim` rendered with Arabic-Indic digits in ar).

### 13.5 The other daily numbers (env-overridable; `-1` = unmetered)
| Constant | Default | Line | Applies to |
| --- | --- | --- | --- |
| `IMAGE_DAILY_LIMIT` | **8** (code; the comment above it says 5 — the code wins) | `3187` | image generation per member per day (`/api/image`, `/api/image/job`, `/api/image/quota`) |
| `OPENAI_IMAGE_DAILY` | 8 | `3486` | OpenAI-engine images/edits |
| `VIDEO_DAILY_LIMIT` | 2 | `3796` | video per member/day (`/api/video/quota` also returns `seconds` = `VIDEO_SECONDS`, default 10, clamped 2-30, `3792`) |
| `MUSIC_LIMIT` | 10 | `4339` | songs per `MUSIC_WINDOW_MIN` (default 120 min, `4363`) |
| `VIDEO_LIMIT` | 6 | `4623` | videos per `VIDEO_WINDOW_MIN` |
| `MEDIA_DAILY_MAX` | 120 | `4355` | **site-wide** paid renders per rolling 24 h, in-memory |
| `MAX_DAILY_LIMIT` | −1 | `3218` | Max tier — inert |
| `MANUS_USER_CREDITS` | **500** per member per day (`8509`; the memory note saying 100 is out of date) | | `/api/agent/credits` → `{remaining, allowance:500, used, held, resetAt:<ISO>, period:"daily", configured:<bool>}`; `MANUS_MAX_TASK` 600 per task (`8512`) |
| `BRAIN_PAGES_DAILY` | all −1 | `8008` | Brain ingest pages |
| guest live-call ceiling `GUEST_LIVE_MAX_MS` | 50 000 ms (max 5 min via env) | `6101-6104` | vs member `LIVE_SESSION_MAX_MS` 10 min (max 30) `6090-6093` |

---

## 14. Environment-dependent feature flags → what the app must hide

The server never exposes a capabilities endpoint; the only probes are `POST /api/transcribe
{probe:true}` and the `configured` field of `GET /api/agent/credits`. Everything else is discovered
by the first real call. Cache the answer per launch and hide the feature.

| Feature | Env that enables it | Endpoint & exact refusal when missing |
| --- | --- | --- |
| Video generation | `REPLICATE_API_TOKEN` (`4181`) | `POST /api/video/job` → `503 {"error":"not_configured","feature":"video"}` (`4742`). Legacy `GET /api/video` needs `HF_ACCOUNTS`/`HF_API_KEY[_n]` (`3799-3807`) → `503` text `video engine not configured` (`5328`) |
| Music generation | `MUSIC_PROVIDER` (default `replicate`, `4487`): `musicapi` → `MUSICAPI_KEY`; else `REPLICATE_API_TOKEN` | `POST /api/music/job` → `503 {"error":"not_configured","feature":"music"}` (`4882-4883`) |
| Firas Agent (Manus) | `MANUS_API_KEY` (`8501`) | The only up-front probe is `GET /api/agent/credits` → `.configured === false` (`8628`; guests `8967`). `POST /api/agent/start` is retired (`410`, §0.1), so **no endpoint returns `not_configured` for agent before a mission starts**; a durable agent job whose Manus create call fails with code `not_configured` is treated as a definite refusal (`10908`), recorded as `agentState:"create_refused", createError:"not_configured"` (`10927-10930`), and the job then fails with `error:"agent_unavailable"` / HTTP 503 in its status (`10932`, `11105-11110`). Hide the Agent entry point whenever `configured` is false. |
| Brain "whole document" | `MINIMAX_API_KEY` (`6891`) | `POST /api/brain/whole` → `503 {"error":"not_configured","feature":"brain_whole"}` (`8978`) |
| Live voice call | `OPENAI_API_KEY` (`3466`) or any Gemini key | `POST /api/live/token` → `503 {"error":"no_engine"}` (`6223`); `502 {"error":"mint_failed"}` / `{"error":"unreachable"}` are transient |
| Server dictation (STT) | any Gemini key (`GEMINI_KEYS`, `217-229`) | `POST /api/transcribe` → `503 {"error":"no stt engine"}` (`6322`); probe with `{"probe":true}` → `{"ok":false}` → use on-device `SFSpeechRecognizer` |
| Server TTS male voice | `OPENAI_API_KEY` or Gemini; female Google fallback only if `TTS_ALLOW_FEMALE_FALLBACK` truthy (`5481`) | `POST /api/tts` → `503 {"error":"tts unavailable","reason":"no male voice engine available"}` (`5825`) → use `AVSpeechSynthesizer` |
| Image editing | `REPLICATE_API_TOKEN`, else `OPENAI_API_KEY` + budget (`OPENAI_IMAGE_BUDGET_USD`) | `POST /api/image/edit` → `503 {"error":"edit_unavailable"}` (`3997-3998`) |
| Image generation | never `not_configured` — keyless pollinations is the last rung | quality varies with `PUTER_AUTH_TOKEN`, `REPLICATE_API_TOKEN`, `CF_API_TOKEN`, `HF_*`, Gemini |
| Web search | never `not_configured` (DDG keyless) | empty `results` + `via:"none"` = nothing found |
| Translate | never `not_configured` (pollinations keyless) | failure = source text echoed with 200 |
| Push notifications | `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY` (`1491-1498`) | registration always succeeds; sends silently no-op — no signal to the app |
| Durable jobs store | Firebase (`FIREBASE_DB_URL` + `FIREBASE_SERVICE_ACCOUNT`, `fbEnabled` `567`) or the local `DATA_DIR` file | `503 {"error":"storage_unavailable"}` on `/api/chat/job*`, `/api/agent/job`, `/api/agent/artifact` (`12122-12134`, `12445`, `12570`, `12605`, `12650`) — transient, retry with backoff |
| Durable *live* chat streaming | `DURABLE_CHAT=1` (`2751`) — **Fly sets `"0"`** (`fly.toml:23`) | only affects whether an interrupted `/api/chat` stream keeps generating server-side (`12981`); the job queue (`/api/chat/job`) works regardless |
| Email verification / reset mail | `BREVO_API_KEY` (primary) / `RESEND_API_KEY` (`2037-2042`) | auth slice; without keys the link is logged server-side only |
| Admin surfaces (`/api/kb`, announcements writes, codes) | `ADMIN_EMAILS` (`7534`) | `403 {"error":"admins only"}`; gate UI on `user.admin` |
| Secure cookies | `SECURE_COOKIES=1` on Fly (`fly.toml:17`); `force_https = true` | cookies carry `Secure`; the app must use `https://` |
| Network guest bucket correctness | `TRUST_PROXY=1` (`1078-1084`) | not set in `fly.toml` `[env]` (only commented in `.env.example:193`); if unset behind Fly's proxy every guest shares one hashed "network" bucket (`remoteAddress` is the proxy) — expect `scope:"network"` denials to be possible at 4× a single guest allowance site-wide. Deployment fact to verify with `fly ssh console -C "printenv TRUST_PROXY"` before blaming the app. |

`signin_required` (`403`) `feature` values the app must map to an upsell sheet: `image`, `video`,
`music`, `live`, `agent`, `brain`, `brain_whole`; plus `account_required` with `feature:"agent"`
from `/api/chat/job` (`12555`). The web client centralises this in `apiJson`
(`app.js:3216-3232`): any `403` whose `data.error === "signin_required"` opens
`openSignUpPrompt(data.feature)`, and any `401` for a *member* session (not a guest) tears down to
the auth screen with `انتهت جلستك. الرجاء تسجيل الدخول من جديد.` / `Your session expired. Please sign in again.` (`3243`).

---

## 15. Push notifications (APNs) — the contract the iOS app implements

### 15.1 `POST /api/push/register` (`handlePushRegister`, `1455-1478`)
* Auth: **member only** → `401 {"error":"authentication required"}`. Guests cannot register, and a
  guest-owned job never notifies (`notifyDurableJobTerminal` returns on `rec.isGuest`, `1628`).
* Rate: `push:<uid>` 30/min → `429 {"error":"too many requests"}`.
* Body (`readJson(req, 4_000)`; malformed → `400 {"error":"invalid JSON"}`):

  | Field | Rule | Error |
  | --- | --- | --- |
  | `token` | hex string (`apnsTokenValue`, `1435-1439`): lower-cased server-side, length 32–512 **and even**, `/^[a-f0-9]+$/` — i.e. `deviceToken.map { String(format: "%02x", $0) }.joined()` | `400 {"error":"invalid device token"}` |
  | `environment` | exactly `"sandbox"` or `"production"` (Xcode/debug builds → sandbox; TestFlight and App Store → production) | `400 {"error":"invalid APNs environment"}` |
  | `language` | `"ar"` → Arabic alert copy; any other value is stored as `"en"` | never rejected |

* `200 {"ok":true}`. Re-registering an existing token replaces its record (dedupe by token,
  `1470-1474`). At most **8** devices per user (`APNS_DEVICE_LIMIT`, `1431`), newest first; a
  token not refreshed for **180 days** (`APNS_DEVICE_MAX_AGE_MS`, `1432`) is dropped at the next
  register/unregister. Re-register on every launch, on every new device token, and after the user
  changes the app language (the copy language is stored per token, not per user).

### 15.2 `POST /api/push/unregister` (`handlePushUnregister`, `1479-1489`)
Same auth / rate / body rules; only `token` is required. `200 {"ok":true}` even for an unknown
token. Call it on sign-out — the server has no other way to learn a device left the account.

### 15.3 When a push is sent (`notifyDurableJobTerminal`, `1627-1641`)
Only for **member-owned** jobs reaching a terminal phase, and only when all four of
`APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY` are set (`1491-1498`):
* durable chat jobs (`POST /api/chat/job`): `completed` (`11903`, skipped when cancelled) or
  `failed` (`11792`, `11918`, `11935`). `product` derives from the job record
  (`durableNotificationProduct`, `1515-1520`): `kind:"agentrun"` / `product:"agent"` → `agent`,
  `codebuild` / `code` → `code`, `brainask` / `brain` → `brain`, anything else → `ai`.
* media jobs (`/api/image/job`, `/api/video/job`, `/api/music/job`): once per job when its phase
  becomes `done` / `fail` (`notifyMediaJobTerminal`, `4720-4728`); `product` is always `"ai"` and
  `mediaKind` ∈ `image` | `video` | `music` (`5169`, `4802`, `4926`).
* Delivered to every registered device of the owner in parallel over HTTP/2 with
  `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration: 0` (Apple does not hold it for
  an offline device) and `apns-collapse-id` = the job id (`1580-1615`, `1635`). There are no
  silent/background pushes and no badge counts.

### 15.4 Payload (`apnsPayload`, `1562-1579`) — literal shape
```json
{
  "aps": {
    "alert": { "title": "صورتك جاهزة", "body": "اضغط لعرض الصورة وحفظها أو مشاركتها." },
    "sound": "FirasComplete.wav",
    "category": "FIRAS_JOB_COMPLETE",
    "thread-id": "firas-ai-<chatId or jobId>"
  },
  "firas": {
    "type": "job-terminal",
    "product": "ai",
    "jobId": "<job id>",
    "phase": "completed",
    "chatId": "<only when the job carries one>",
    "mediaKind": "image"
  }
}
```
* `firas.type` is always `"job-terminal"`; `firas.phase` ∈ `completed` | `failed`;
  `firas.product` ∈ `ai` | `agent` | `code` | `brain`; `firas.chatId` and `firas.mediaKind` are
  present only when applicable. `thread-id` = `"firas-" + product + "-" + (chatId || jobId)`
  truncated to 64 chars. The bundle must ship a sound named **`FirasComplete.wav`** (else the system
  default plays) and register the **`FIRAS_JOB_COMPLETE`** notification category.
* On tap: route by `firas.product` + `firas.chatId` / `firas.jobId` / `firas.mediaKind`, then load
  the result with the member cookie (`GET /api/chat/job?id=`, or the media `*/job?id=` +
  `*/file?id=`) — the push carries no content.
* Alert copy (`apnsLocalizedCopy`, `1521-1561`), verbatim, selected by the token's stored `language`:

  | product / mediaKind | outcome | ar title | ar body | en title | en body |
  | --- | --- | --- | --- | --- | --- |
  | `image` | completed | `صورتك جاهزة` | `اضغط لعرض الصورة وحفظها أو مشاركتها.` | `Your image is ready` | `Tap to view, save, or share it.` |
  | `image` | failed | `تعذر إنشاء الصورة` | `اضغط لعرض التفاصيل أو المحاولة مجددا.` | `Your image could not be created` | `Tap to view details or try again.` |
  | `video` | completed | `فيديوك جاهز` | `اضغط لمشاهدة الفيديو وحفظه أو مشاركته.` | `Your video is ready` | `Tap to watch, save, or share it.` |
  | `video` | failed | `تعذر إنشاء الفيديو` | `اضغط لعرض التفاصيل أو المحاولة مجددا.` | `Your video could not be created` | `Tap to view details or try again.` |
  | `music` | completed | `أغنيتك جاهزة` | `اضغط للاستماع إلى الأغنية وحفظها أو مشاركتها.` | `Your song is ready` | `Tap to listen, save, or share it.` |
  | `music` | failed | `تعذر إنشاء الأغنية` | `اضغط لعرض التفاصيل أو المحاولة مجددا.` | `Your song could not be created` | `Tap to view details or try again.` |
  | `ai` | completed | `إجابة فِراس اكتملت` | `اضغط لعرض النتيجة.` | `Firas answer is ready` | `Tap to view the result.` |
  | `ai` | failed | `إجابة فِراس لم تكتمل` | `اضغط لعرض التفاصيل أو المحاولة مجدداً.` | `Firas answer could not finish` | `Tap to view details or try again.` |
  | `agent` | completed / failed | `مهمة وكيل فِراس اكتملت` / `مهمة وكيل فِراس لم تكتمل` | as `ai` | `Firas Agent mission is ready` / `Firas Agent mission could not finish` | as `ai` |
  | `code` | completed / failed | `مشروع فِراس كود اكتملت` / `مشروع فِراس كود لم تكتمل` | as `ai` | `Firas Code project is ready` / `Firas Code project could not finish` | as `ai` |
  | `brain` | completed / failed | `بحث فِراس برين اكتملت` / `بحث فِراس برين لم تكتمل` | as `ai` | `Firas Brain search is ready` / `Firas Brain search could not finish` | as `ai` |

  The generic Arabic titles are string-joined as `names[product] + " اكتملت"` / `" لم تكتمل"`
  (`1557-1559`) with no gender agreement per noun; the media `failed` bodies end in `مجددا.` while
  the generic one ends in `مجدداً.` — both copied exactly as the server sends them.

---

## 16. Guest-vs-member capability matrix (what the app may show a guest)

| Capability | Guest cookie | Member cookie | Refusal the app must map |
| --- | --- | --- | --- |
| Chat (`/api/chat`, `/api/chat/job`), `/api/search`, `/api/fetch`, `/api/images`, `/api/imgproxy` | yes — daily `ai` 180 / `code` 60 (`/api/usage/charge`), per-minute 30 | yes, unmetered | `429` with `quota.plan:"guest"` → §13.4 upsell text |
| Agent missions | **no** — `403 {"ok":false,"error":"signin_required","feature":"agent"}` at `/api/usage/charge` (`7665`); `403 {"ok":false,"error":"account_required","feature":"agent"}` at `/api/chat/job` (`12555`) | yes — Manus credits 500/day (`/api/agent/credits`) | sign-up sheet, feature `agent` |
| Image / video / music generation, image edit | **no** — `403 signin_required` with `feature` `image` / `video` / `music` | yes — image 8/day, video 2/day, songs 10 per 120 min | sign-up sheet |
| Playing a finished video / song by id | yes (`/api/video/file`, `/api/music/file` accept a guest cookie, `4840`, `4970`) | yes | `401` text `auth required` with no cookie |
| Live voice call (`/api/live/token`) | yes — 50 s per call, 3 mints/min, `voice` 120/day | 10 min, 6 mints/min, unmetered | `403 signin_required live` only with **no** cookie at all; `503 no_engine` → hide |
| Dictation `/api/transcribe`, `/api/tts` | yes — `voice` 120/day shared with live; guest STT effectively 6/min, TTS 25/min | yes — STT 20/min, TTS 90/min | `503` → on-device STT / `AVSpeechSynthesizer` |
| Brain (own documents) | yes — 3 docs, 120 pages/day | yes | `403 signin_required brain` with no cookie; `/api/brain/whole` member-only (`brain_whole`) |
| Announcements (read) | yes (`admin:false`) | yes (`admin` true only for `ADMIN_EMAILS`) | `401` with no cookie |
| `/api/version`, `/api/share?id=` GET, static media | yes (no auth) | yes | — |
| Translate, memory, share create/delete, server chat history, push, redeem, KB, `/api/auth/me` | **no** — plain `401` | yes | show the sign-up prompt, not "session expired" |
