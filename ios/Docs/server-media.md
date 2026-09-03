# Server contract — Media (images, video, music)

Source of truth: `server.mjs` at the repo root (Node, zero deps). Every line reference below is
`server.mjs:<line>` unless it says `app.js:<line>`. `netlify/edge-functions/api.js` is a legacy
mirror and is NOT in parity on media (no Replicate rung, no `directedPrompt`) — ignore it.

This document is written so the Swift media layer can be implemented without opening the JS.
Arabic strings are copied verbatim from the web client so the native app says the same things.

---

## 0. Conventions that apply to every endpoint in this slice

### 0.1 Base URL, routing, methods

- Base: `https://firasai.org`. Routes are matched on the path only (`req.url.split("?")[0]`) and
  the exact method (`server.mjs:13725-13726`). A wrong method does not 405 — it falls through the
  whole route table: a wrong `GET`/`HEAD` reaches the static-file server (`server.mjs:13858`) and
  you get HTML or a static 404; any other wrong method (e.g. `POST /api/image`) gets a plain-text
  `404 not found` (`server.mjs:13860-13861`). Send exactly the method listed.
- `HEAD` is not routed for any `/api/...` path (it falls to `serveStatic`, `server.mjs:13858`).
  AVPlayer/AVURLAsset use `GET` + `Range`, so this is fine; do not issue `HEAD` yourself.
- Route table for this slice (`server.mjs:13745-13773`):

| Method | Path | Handler | Line |
|---|---|---|---|
| GET | `/api/images` | `handleImageSearch` | 6367 |
| GET | `/api/imgproxy` | `handleImgProxy` | 6478 |
| POST | `/api/image/quota` | `handleImageQuota` | 3237 |
| GET | `/api/image` | `handleImage` | 5207 |
| POST | `/api/image/job` | `handleImageJobStart` | 5138 |
| GET | `/api/image/job` | `handleImageJobStatus` | 5192 |
| POST | `/api/image/edit` | `handleImageEdit` | 3922 |
| POST | `/api/video/job` | `handleVideoJobStart` | 4736 |
| GET | `/api/video/job` | `handleVideoJobStatus` | 4825 |
| GET | `/api/video/file` | `handleVideoFile` | 4839 |
| GET | `/api/video/quota` | `handleVideoQuota` | 5349 |
| GET | `/api/video` (legacy sync, HF) | `handleVideo` | 5304 |
| POST | `/api/music/job` | `handleMusicJobStart` | 4875 |
| GET | `/api/music/job` | `handleMusicJobStatus` | 4951 |
| GET | `/api/music/file` | `handleMusicFile` | 4969 |

There is **no** `/api/music/quota` endpoint.

### 0.2 Authentication — two cookies

- Member session cookie: `firas_session` (`COOKIE_NAME`, `server.mjs:1046`). `HttpOnly;
  SameSite=Lax; Path=/; Max-Age=2592000` (30 days), `Secure` when behind HTTPS. Resolved by
  `currentUser(req)` (`server.mjs:1098`); a cookie whose session version is behind the account's
  (`sessVer`) resolves to nobody (logout-everywhere / password change revoke it).
- Guest cookie: `firas_guest` (`GUEST_COOKIE`, `server.mjs:1131`), 7 days, value is a signed
  `g_<hex>` id. Resolved by `currentGuest(req)` (`server.mjs:1156`).
- `callerOf(req)` (`server.mjs:1314`) = member if `firas_session` is valid, else guest, else `{}`.

Per-endpoint auth in this slice:

| Endpoint | Member cookie | Guest cookie only | No cookie |
|---|---|---|---|
| POST `/api/image/job`, GET `/api/image`, POST `/api/image/edit`, POST `/api/image/quota` | OK | **403** `{"error":"signin_required","feature":"image"}` | 401 |
| GET `/api/image/job` (status) | OK | 401 | 401 |
| POST `/api/video/job` | OK | **403** `{"error":"signin_required","feature":"video"}` | 401 |
| GET `/api/video/job`, GET `/api/video/quota` | OK | 401 | 401 |
| GET `/api/video/file` | OK | **OK** | 401 |
| POST `/api/music/job` | OK | **403** `{"error":"signin_required","feature":"music"}` | 401 |
| GET `/api/music/job` | OK | 401 | 401 |
| GET `/api/music/file` | OK | **OK** | 401 |
| GET `/api/images`, GET `/api/imgproxy` | OK | **OK** | 401 |

Important asymmetry: `/api/image?key=` (the image bytes) requires a **member** cookie — a guest
gets 403 — whereas `/api/video/file` and `/api/music/file` accept a guest cookie. Every media URL
you hand to `AsyncImage`, `URLSession`, or `AVPlayer` must carry `firas_session`.

### 0.3 Response body shapes — JSON vs plain text (this bites)

`sendJson` (`server.mjs:1691`) writes `Content-Type: application/json; charset=utf-8`. But many
refusals in this slice are written with bare `res.writeHead(status); res.end("text")` and have **no
content-type and a plain-text body**. Never assume a 4xx/5xx body parses as JSON. Concretely:

- Every `401` in this slice is the plain string `auth required` — except POST `/api/image/quota`
  (`{"ok":false,"error":"auth required"}`, line 3241), GET `/api/images` (`{"results":[],"error":"auth"}`,
  line 6371) and GET `/api/imgproxy` (`{"error":"auth"}`, line 6481).
- Every `403 signin_required` is JSON.
- `429` from the per-minute rate limiter is JSON `{"error":"rate_limited"}` on the three job
  starts, but plain text `rate limited` on GET `/api/image` (line 5219) and POST `/api/image/edit`
  (line 3931); JSON `{"results":[],"error":"rate"}` on GET `/api/images` (line 6372) and an
  **empty body** on GET `/api/imgproxy` (line 6482).
- GET `/api/image` errors are all plain text: `no prompt` (400), `not found` (404),
  `daily limit reached` (429), `image generation failed` (502).
- GET `/api/video/file` and `/api/music/file`: `not found` (404) plain text.

Rule for Swift: decode the body as JSON only when `Content-Type` starts with `application/json`;
otherwise treat the status code alone as the error.

### 0.4 Rate limiter

`rateLimited(key, max, windowMs)` (`server.mjs:1076`) is an in-memory sliding window per key,
reset on server restart. Every call counts (including the refused ones). Limits per user id:

| Bucket | Endpoint | Limit |
|---|---|---|
| `imgjob:<uid>` | POST `/api/image/job` | 20 / 60 s (line 5144) |
| `img:<uid>` | GET `/api/image` (both `?key=` and `?prompt=`) | 240 / 60 s (line 5219) |
| `imgedit:<uid>` | POST `/api/image/edit` | 30 / 60 s (line 3931) |
| `vidjob:<uid>` | POST `/api/video/job` | 10 / 60 s (line 4743) |
| `musicjob:<uid>` | POST `/api/music/job` | 10 / 60 s (line 4882) |
| `images:<id>` | GET `/api/images` | 40 / 60 s (line 6372) |
| `imgproxy:<id>` | GET `/api/imgproxy` | 80 / 60 s (line 6482) |

The status (GET `…/job?id=`) endpoints and the file endpoints have **no** rate limit.

### 0.5 The quota day

`serverDay()` (`server.mjs:3197`) shifts `Date.now()` by `QUOTA_TZ_OFFSET_MINUTES` (default 180 =
UTC+3, `server.mjs:3196`) and reads the UTC date, so daily counters reset at **00:00 Baghdad
time**. The Arabic copy on the web promises "الحدّ يتجدّد غدًا" — use the same.

### 0.6 Job ids ARE cache keys — the single most important fact

For all three media kinds, `jobId` returned by the POST **is** the SHA-1 hex cache key of the
result (40 lowercase hex chars). Consequences:

- The status endpoint answers `done` for any id whose bytes exist on disk, even after a server
  restart that forgot the in-memory job (`server.mjs:5201, 4832, 4958`).
- The in-memory job maps (`imageJobs` 5129, `videoJobs` 4730, `musicJobs` 4869) forget finished
  jobs one hour after they end (sweep every 10 min). An **unknown** id (forgotten, or lost in a
  restart while still running) answers `{"phase":"running"}` forever (`server.mjs:5203, 4834,
  4960`). The client must therefore own a hard polling deadline; the server will never say `fail`
  for a lost job.
- Same inputs → same key → the server returns the cached result **without rendering** and without
  charging a slot. To get a genuinely new picture/clip/song you must change an input that is part
  of the key (see each section). There is no `seed`/`nonce` on any job path.
- The status endpoints do **not** check that the caller owns the job. Any member can poll any id.
- Ids are sanitised with `.replace(/[^a-f0-9]/g, "").slice(0, 64)` on every GET — uppercase or
  non-hex characters are silently stripped, so always pass the id exactly as received.

### 0.7 Site-wide spend ceiling (video + music only)

`MEDIA_DAILY_MAX` (default **120**, `server.mjs:4355`) caps the number of **paid** video + music
renders started site-wide in any rolling 24 h window (`mediaCeilingHit`, 4358). In memory, resets
on restart, applies to the owner too. Refusal: `429 {"error":"site_media_ceiling","limit":120}`.
Images are not counted.

### 0.8 Push notifications for media jobs

When a job reaches `done`/`fail`, `notifyMediaJobTerminal` (`server.mjs:4720`) sends one APNs alert
per registered device (`notifyDurableJobTerminal`, 1627; payload built by `apnsPayload`, 1562):

```json
{
  "aps": {
    "alert": { "title": "صورتك جاهزة", "body": "اضغط لعرض الصورة وحفظها أو مشاركتها." },
    "sound": "FirasComplete.wav",
    "category": "FIRAS_JOB_COMPLETE",
    "thread-id": "firas-ai-<jobId>"
  },
  "firas": { "type": "job-terminal", "product": "ai", "jobId": "<40-hex>", "phase": "completed", "mediaKind": "image" }
}
```

- `product` is always `"ai"` for media (`durableNotificationProduct`, 1515).
- `phase` is `"completed"` or `"failed"` (note: the HTTP status endpoint says `done`/`fail`; the
  push says `completed`/`failed`).
- `mediaKind` ∈ `image | video | music`. No `chatId` for media jobs.
- `apns-collapse-id` = the jobId, so a duplicate send collapses.
- Alert copy, verbatim (`apnsLocalizedCopy`, `server.mjs:1521-1547`), chosen by the device's
  registered language:

| kind | outcome | ar title | ar body |
|---|---|---|---|
| image | completed | صورتك جاهزة | اضغط لعرض الصورة وحفظها أو مشاركتها. |
| image | failed | تعذر إنشاء الصورة | اضغط لعرض التفاصيل أو المحاولة مجددا. |
| video | completed | فيديوك جاهز | اضغط لمشاهدة الفيديو وحفظه أو مشاركته. |
| video | failed | تعذر إنشاء الفيديو | اضغط لعرض التفاصيل أو المحاولة مجددا. |
| music | completed | أغنيتك جاهزة | اضغط للاستماع إلى الأغنية وحفظها أو مشاركتها. |
| music | failed | تعذر إنشاء الأغنية | اضغط لعرض التفاصيل أو المحاولة مجددا. |

English: "Your image is ready" / "Tap to view, save, or share it."; "Your image could not be
created" / "Tap to view details or try again."; video: "Your video is ready" / "Tap to watch, save,
or share it."; music: "Your song is ready" / "Tap to listen, save, or share it."

A push is **not** sent when the POST returned `phase:"done"` immediately (cache hit) — no job was
created.

---

## 1. Images

### 1.1 POST `/api/image/job` — start a background render (`server.mjs:5138-5190`)

Auth: member cookie. Guest → `403 {"error":"signin_required","feature":"image"}`. None → `401`
plain `auth required`.

Request: `Content-Type: application/json`, body read limit 30,000,000 chars (`readJson(req,
30_000_000)`, line 5145; over the limit → body treated as `null` → `400 bad_request`).

| Field | Type | Rules |
|---|---|---|
| `prompt` | string | required; trimmed; **hard-cut to 1000 chars** (line 5146). Empty → `400 {"error":"bad_request"}`. |
| `w` | int | `parseInt`, default 1024, clamped **256…1280** (line 5150). |
| `h` | int | same as `w` (line 5151). |
| `image` | any truthy | **Do not send.** Any truthy value → `501 {"error":"edit_job_unsupported"}` (line 5149). Edits go to `/api/image/edit`. |

No `seed`, `style`, `n`, `model`, `engine`, `aspect` fields exist. Anything else in the body is
ignored. The seed on the job path is always `""` (line 5152).

Processing order (matters for which error you get first): auth → rate limit (20/min →
`429 {"error":"rate_limited"}`) → body/prompt → `image` check → clamp w/h → `imgRollDay` →
`ckey = imgCacheKey(prompt, w, h, "")` → **cache hit short-circuit** → daily limit → create job.

Cache key (`imgCacheKey`, `server.mjs:3268`):
`sha1("<engine>|<prompt>|<w>x<h>|<seed>")` where `<engine>` =
`REPLICATE_IMAGE_MODEL:REPLICATE_RESOLUTION:IMAGE_RECIPE` = `google/nano-banana-pro:2K:v2-nbpro-directed`
when Replicate is configured (lines 4182, 4188, 4167). Identical prompt + w + h ⇒ identical picture,
forever, no re-render. To re-roll, the prompt text must differ.

Responses:

| Status | Body | Meaning |
|---|---|---|
| 200 | `{"ok":true,"jobId":"<hex>","phase":"done","key":"<hex>"}` | Already on disk. Load `/api/image?key=<key>` now. A slot is charged only if this key was not already in today's list (line 5159). |
| 200 | `{"ok":true,"jobId":"<hex>","phase":"queued"}` | Render started in the background. Poll. |
| 400 | `{"error":"bad_request"}` | empty prompt / unparsable body |
| 401 | `auth required` (text) | no valid cookie |
| 403 | `{"error":"signin_required","feature":"image"}` | guest |
| 429 | `{"error":"rate_limited"}` | >20 starts/min |
| 429 | `{"error":"daily_limit","limit":8}` | `IMAGE_DAILY_LIMIT` reached (line 5163) |
| 501 | `{"error":"edit_job_unsupported"}` | body carried `image` |

Daily limit: `IMAGE_DAILY_LIMIT` default **8** per member per quota-day (`server.mjs:3187`; `-1`
via env = unmetered, then `limit` is -1 in the quota response). The counter is `user.imgCids`
(array of cache keys). A slot is charged **on success only** (`renderImageToCache` pushes the slot
after the bytes are cached, e.g. line 5038) — a failed render costs nothing; a repeat of an
existing key costs nothing. Edits share the same 8 (§1.4).

Job record: `{ id, uid, product:"ai", mediaKind:"image", phase:"running"|"done"|"fail", key, error, ts }`
(line 5169). A failed job for the same key can be restarted by POSTing again (line 5168 —
`!job || job.phase === "fail"`); a `running` one is reused (you get `queued` again with the same id).

Server render budget: Replicate rung waits up to `REPLICATE_MAX_WAIT_MS` = 180 s (line 4192) per
attempt, then falls down the ladder (§1.6); a full ladder walk can take several minutes.

### 1.2 GET `/api/image/job?id=<jobId>` — status (`server.mjs:5192-5205`)

Auth: member cookie (guest → `401` plain text). No rate limit.

| Status | Body |
|---|---|
| 400 | `{"error":"bad_request"}` — id empty after sanitising |
| 200 | `{"phase":"done","key":"<hex>"}` — bytes exist (checked first, line 5201) or job finished |
| 200 | `{"phase":"fail","error":"<code>"}` — see codes below |
| 200 | `{"phase":"running"}` — running **or unknown id** (line 5203) |

`error` values: `"all_engines_failed"` (every rung returned nothing, line 5178);
`"render_failed"` (job stored an empty error, line 5204); otherwise an arbitrary exception
message string (line 5184). Treat anything not `all_engines_failed` as a generic failure.

Web polling cadence (for parity): first wait 1.5 s, ×1.25 each poll, capped at 5 s, in-turn
deadline 12 min (`requestImageJob`, `app.js:5043`, loop at `5077-5096`); the reattach poller uses
2 s → ×1.25 → cap 6 s, 20 min (`IMG_JOB_MAX_MS`, `app.js:59196`, loop at `59273-59275`). After 20 min give up and show
`imgWhyEngine`. Suggested native: 2 s → cap 5 s, 20 min hard deadline.

### 1.3 GET `/api/image?key=<hex>` — the image bytes (`server.mjs:5207-5236`)

Auth: **member cookie required** (guest → `403 signin_required` JSON, none → 401 text).
Rate: 240/min per user, plain-text `429 rate limited` — an image-heavy history that reloads many
thumbnails at once can hit this; cache the bytes locally after the first fetch.

- `key` is sanitised to `[a-f0-9]{0,64}`; when present the prompt path is skipped (line 5228).
- 200: raw bytes, `Content-Type` = whatever the cache recorded (`image/png` from Replicate with
  `REPLICATE_OUTPUT_FORMAT=png`, line 4191; other rungs may yield `image/jpeg`/`image/webp`),
  `Cache-Control: public, max-age=86400`. No `Content-Length`, no `ETag`, no Range support.
- 404 plain `not found` when the key is unknown. Loading by key never renders and never charges.

Legacy synchronous form `GET /api/image?prompt=…&w=&h=&seed=&cid=` (lines 5238-5289) still
exists: it renders inline (can take minutes), charges a slot on success, returns bytes or
`502 image generation failed` / `429 daily limit reached` (text). **Do not use it from native**;
use the job path. Documented only so you recognise legacy `firas-image` fences that carry
`prompt/w/h/seed/cid` instead of `key` (§1.7): to display those, POST `/api/image/job` with the
same `prompt/w/h` and use the returned key (it will usually be a cache hit).

### 1.4 POST `/api/image/edit` — edit an existing picture (`server.mjs:3922-4033`)

Auth: member cookie (guest → `403 {"error":"signin_required","feature":"image"}`; none → 401
text). Rate: 30/min → plain text `429 rate limited`. Synchronous — the response arrives when the
edit is finished (Replicate waits up to 180 s). Use a long `URLSession` timeout (≥ 200 s).

Request: JSON, body limit 26,000,000 chars (line 3934).

| Field | Type | Rules |
|---|---|---|
| `prompt` | string | required, trimmed, cut to 1000 (line 3935) |
| `image` | string | required. Base64 of the source picture. A `data:…;base64,` prefix is stripped if present (line 3936). Decoded bytes must be 1…20,000,000 bytes (line 3950). |
| `mime` | string | optional, default `"image/png"`; **ignored when the bytes are recognisable** — the server sniffs JPEG/PNG/WebP magic numbers (lines 3945-3949) and uses the sniffed type. |

Behaviour:
- Key = `sha1("edit|<engineTag>|<prompt>|<sha1(sourceBytes)>")` (line 3963). Same source bytes +
  same instruction → cached, free, identical.
- Order: cache check (returns `{"ok":true,"key":"…","cached":true}`) **before** the daily-limit
  check, so re-requesting an old edit never fails on quota.
- Daily limit: shares `IMAGE_DAILY_LIMIT` (8) with generation; the edit key is pushed into
  `imgCids` on success (line 4029).
- Engine: Replicate `google/nano-banana-pro` with `image_input:[dataUri]`,
  `aspect_ratio:"match_input_image"` (`editImageReplicate`, 5012) — only when the source is
  ≤ 8,000,000 bytes (line 5016); larger sources skip straight to OpenAI. If Replicate produces
  nothing → OpenAI `gpt-image-2` edit (needs `OPENAI_API_KEY`, budget and a separate
  `OPENAI_IMAGE_DAILY`=8 counter, lines 3486, 3572).
- No mask parameter exists. No aspect/size parameters exist. Output shape follows the input.

Responses:

| Status | Body |
|---|---|
| 200 | `{"ok":true,"key":"<hex>"}` or `{"ok":true,"key":"<hex>","cached":true}` → display `/api/image?key=` |
| 400 | `{"error":"bad_request"}` — missing prompt or image |
| 400 | `{"error":"bad_image"}` — base64 undecodable, empty, or > 20 MB |
| 429 | `rate limited` (plain text) |
| 429 | `{"error":"daily_limit","limit":8}` |
| 502 | `{"error":"edit_failed"}` — OpenAI produced nothing |
| 503 | `{"error":"edit_unavailable"}` — Replicate failed and OpenAI is unconfigured / out of budget |

The web client sends raw base64 with no prefix and `mime` as a hint (`app.js:4901-4906`), and for
prompts it sends the user's instruction untranslated (`editPrompt = imgUser.content`, `app.js:41748`).

### 1.5 POST `/api/image/quota` — read-only pre-check (`server.mjs:3237-3249`)

Method is POST; the body is ignored (web sends `{}`). Auth: member.

| Status | Body |
|---|---|
| 200 | `{"ok":true,"limit":8,"used":<n>,"remaining":<8-n>}` — `remaining` is `-1` when `limit` is `-1` (unmetered) |
| 429 | `{"ok":false,"limit":8,"used":8,"remaining":0}` |
| 403 | `{"ok":false,"error":"signin_required","feature":"image"}` (guest) |
| 401 | `{"ok":false,"error":"auth required"}` |

`used` counts generated + edited pictures today (both push into `imgCids`). Nothing is charged
by this call.

### 1.6 What the server does with your prompt (so you know what to send)

Engine ladder in `renderImageToCache` (`server.mjs:5029-5117`), first success wins:
1. Replicate `google/nano-banana-pro`, resolution `2K`, `png`, `allow_fallback_model:true`
   (`generateImageReplicate`, 4998). This rung receives `directedPrompt(prompt)` (4152) =
   `prompt + "\n\n" + IMAGE_CRAFT [+ "\n\n" + IMAGE_DIRECTION]`. `IMAGE_DIRECTION` (cinematic art
   direction, 4128) is withheld when the prompt already names a restrained style — any of
   `flat|minimal|minimalist|line art|lineart|outline|wireframe|blueprint|schematic|diagram|icon|logo|logotype|emblem|monogram|sticker|pictogram|infographic|chart|cartoon|comic|anime|manga|pixel art|8-bit|low.?poly|vector|clipart|sketch|doodle|watercolou?r|pencil|charcoal|silhouette|isometric|technical drawing`
   (word-bounded) or the Arabic `مسطح|بسيط|بسيطة|مبسط|مبسطة|رسم خطي|مخطط|مخططات|رسم تخطيطي|أيقونة|ايقونة|شعار|لوغو|كرتون|كرتوني|أنمي|انمي|كوميك|ملصق بسيط|رسمة بسيطة|اسكتش|تخطيطي|فيكتور` (4141-4150).
   Native tip: for a logo/icon preset put the word `logo`/`icon`/`flat vector` in the prompt.
   Never write negated style words ("not a cartoon") — they claim the style and drop direction.
2. Gemini `gemini-2.5-flash-image` (`GEMINI_IMAGE_MODEL`, line 262; raw prompt, ≤4000 chars,
   line 3727) — then Picsart upscale if configured.
3. Cloudflare Workers AI `@cf/black-forest-labs/flux-2-klein-9b` (line 296; raw, ≤2000, line 3414).
4. OpenAI `gpt-image-2` (raw, ≤4000, line 3645; own `OPENAI_IMAGE_DAILY`=8 counter and USD budget).
5. Puter (raw, ≤4000, line 3315). 6. Hugging Face `black-forest-labs/FLUX.1-schnell` (line 268;
   raw, ≤2000, line 3753). 7. pollinations.ai (raw, `flux`, line 5104).
Rungs 2-7 all receive the **undirected** prompt; only rung 1 gets `IMAGE_CRAFT`/`IMAGE_DIRECTION`.

Aspect ratio: pixels are clamped to 256…1280 **before** anything else, then the Replicate rung snaps
`w/h` to the nearest of `1:1, 4:3, 3:4, 16:9, 9:16, 3:2, 2:3, 5:4, 4:5, 21:9` in log space
(`replicateAspect`, 4200). OpenAI has only `1024x1024 | 1536x1024 | 1024x1536`
(`openaiImageSize`, 3557: ratio > 1.2 → wide, < 0.84 → tall). So the delivered shape depends on
which rung answered. Recommended native presets that survive the clamp and snap cleanly:

| Preset | send `w`×`h` | Replicate snaps to |
|---|---|---|
| square | 1024×1024 | 1:1 |
| landscape 4:3 | 1280×960 | 4:3 |
| portrait 3:4 | 960×1280 | 3:4 |
| wide 16:9 | 1280×720 | 16:9 |
| story 9:16 | 720×1280 | 9:16 |
| banner 21:9 | 1280×549 | 21:9 |

(The current Swift `ImageAspectPreset` (`ios/FirasAI/Models/MediaStudioModels.swift:35-66`)
sends: `square` 1024×1024 → 1:1; `portrait` 1024×1280 (0.80) → **4:5**, not 3:4; `landscape`
1280×720 → 16:9; `story` 720×1280 → 9:16; `banner` 1280×640 (2.00) → **16:9**, not 21:9 —
|ln(2.00/1.778)| = 0.118 beats |ln(2.333/2.00)| = 0.154; `cover` 1280×853 (1.50) → 3:2. Use 1280×549
if a true 21:9 banner is wanted.) The web client's `pickImageShape` (`app.js:5108-5119`) sends
1024×1024 (logo/icon/avatar words, tested first), 1024×1536 (poster/story/portrait words) or
1536×1024 (banner/cover/wallpaper words); the clamp turns the last two into 1024×1280 /
1280×1024 → 4:5 / 5:4 on Replicate (and 1024x1536 / 1536x1024 on the OpenAI rung).

Prompt language: the web rewrites the user's Arabic into one English prompt (≤1000 chars) with a
model call before POSTing, keeping any text meant to appear *inside* the picture as a quoted
literal in Arabic (see `.claude/skills/image-generation-prompting/SKILL.md` §3). If the native app
skips the rewrite it may send the raw Arabic — the server does not translate; nano-banana-pro
handles Arabic prompts but the direction paragraph is English either way.

Picture size on disk: 2K PNG is typically 3–5 MB (comment at 4184-4187); the cache refuses files
over `IMG_CACHE_MAX_BYTES` = 25 MB (3290). Expect multi-megabyte downloads; do not hold many
full-size images in memory.

### 1.7 Chat message format — the `firas-image` fence

Assistant messages that carry a picture contain **only** a fenced block (`app.js:42262`):

```
```firas-image
{"prompt":"<english prompt>","key":"<40-hex>"}
```
```

Fields (`parseImageMeta`, `app.js:5020`; requires `prompt` to be present):
- `prompt` (string, required) — shown as the caption.
- `key` (string) — present for job-rendered and edited pictures → `GET /api/image?key=`.
- Legacy (no `key`): `w`, `h`, `seed`, `cid` → web builds `/api/image?prompt=…&w=&h=&seed=&cid=`
  (`imageUrl`, `app.js:5170`). Native: re-POST `/api/image/job` with `prompt/w/h` to obtain a key.
- `note` (string, optional) — the user's caption comment (`imgNoteWrite`, `app.js:6150-6152`).
- `srUrl` is a transient `blob:` URL and is never persisted; ignore if seen.

An edit result is stored identically with the edit instruction as `prompt` (`app.js:41765`).

### 1.8 Web UI copy for image outcomes (verbatim)

| Situation | Arabic | English |
|---|---|---|
| Guest asked for an image (`STR.ar`, `app.js:695-696`; `STR.en`, `1792-1793`) | **توليد الصور يحتاج حسابًا** / أنشئ حسابًا مجانيًا خلال ثوانٍ لتوليد الصور، وحفظ محادثاتك، ورفع حدّك اليومي. | **Image generation needs an account** / Create a free account in seconds to generate images, save your chats, and raise your daily limit. |
| Not signed in (`imageLimitText`, `app.js:6423`) | 🔒 يجب تسجيل الدخول لإنشاء الصور. | 🔒 Please sign in to generate images. |
| `daily_limit` on start (`app.js:6428`, `{limit}` rendered with Arabic-Indic digits) | 🌙 لقد وصلت إلى الحدّ اليومي لإنشاء الصور (٨ صور في اليوم). يمكنك إنشاء المزيد غداً. | 🌙 You've reached your daily image limit (8 images per day). You can create more tomorrow. |
| `rate_limited` on start (`app.js:42253`) | طلبات كثيرة في وقت قصير. انتظر دقيقة ثمّ أعد المحاولة. | Too many requests in a short time. Wait a minute and try again. |
| After success, remaining (`app.js:6434`) | تم إنشاء الصورة • تبقّى لك ٧ من ٨ اليوم | Image created • 7 of 8 left today |
| Card failure title (`app.js:790`) | تعذّر توليد الصورة | Image generation failed |
| Card retry / regenerate / busy (`app.js:791-793`) | إعادة المحاولة / أعد التوليد / جارٍ… | Retry / Regenerate / Working… |
| Engine failure (`imgWhyEngine`) | لم يُعدِ المحرّك صورة. | The engine returned no picture. |
| Offline (`imgWhyNet`) | تعذّر الوصول إلى الصورة — تحقّق من اتّصالك. | The picture could not be fetched — check your connection. |
| `daily_limit` on card (`imgWhyQuota`) | بلغت حدّك اليومي من الصور. الحدّ يتجدّد غدًا. | You have reached today's image limit. It resets tomorrow. |
| `signin_required` on card (`imgWhySignin`) | انتهت جلستك. سجّل الدخول ثمّ أعد المحاولة. | Your session ended. Sign in and try again. |
| Save failed (`imgSaveFailed`) | تعذّر حفظ الصورة. | — |

Edit outcomes (`imageEditErrorText`, `app.js:4928-4959`):

| code | Arabic | English |
|---|---|---|
| `daily_limit` | بلغت حدّك اليومي من تعديل الصور (8 في اليوم). جرّب غدًا. | You have reached your daily image-editing limit (8/day). Try again tomorrow. |
| `edit_unavailable` | تعديل الصور غير متاح حاليًا — المحرّك الذي يقوم به نفد رصيده. توليد صور جديدة ما زال يعمل. | Image editing is unavailable right now — the engine that performs it is out of credit. Generating new images still works. |
| `signin_required` | سجّل الدخول لتعديل الصور. | Sign in to edit images. |
| `bad_image` | تعذّرت قراءة الصورة المرفقة. | That attached image could not be read. |
| anything else (`edit_failed`, 502, network) | تعذّر تعديل الصورة. حاول مرة أخرى، أو صِف التعديل بتفصيل أوضح. | The image could not be edited. Try again, or describe the change more specifically. |

---

## 2. Video

### 2.1 POST `/api/video/job` — start a clip (`server.mjs:4736-4823`)

Auth: member (guest → `403 {"error":"signin_required","feature":"video"}`; none → 401 text).
Pre-checks in order: auth → `503 {"error":"not_configured","feature":"video"}` when
`REPLICATE_API_TOKEN` is unset (4742) → rate limit 10/min `429 {"error":"rate_limited"}` → body.

Request: JSON, **body read limit 12,000,000 chars** (4747). A body over that is rejected by
`readJson` and becomes `b = null` → `400 {"error":"bad_request"}` (not 413 — see quirk below).

| Field | Type | Rules |
|---|---|---|
| `prompt` | string | required, trimmed, cut to 2000 (4748). Empty → 400 `bad_request`. |
| `seconds` | int | `parseInt`, default `VIDEO_SECONDS`=10 (3792), clamped **2…30** (4750). |
| `image` | string | optional first frame. Must match `^data:image/(png|jpe?g|webp|bmp);base64,[A-Za-z0-9+/=]+$` **or** `^https://\S+$` (4761). Anything else (e.g. raw base64 without the prefix, `http://`) → `400 {"error":"bad_image"}`. Length > `VID_IMAGE_MAX_BYTES × 1.4` = 14,000,000 chars → `413 {"error":"image_too_large","limit":10000000}` (4763-4765) — but this is unreachable because the 12 M body limit trips first. **Practical rule: keep the data URI under ~11.5 M chars, i.e. the JPEG/PNG under ~8.5 MB; re-encode photos as JPEG ≤ 2048 px before sending.** |

No `aspect`, `resolution`, `engine`, `seed` or `fps` fields exist. Resolution is fixed server-side at
`720p` (`VID_RES`, 4606); model `alibaba/wan-3` (4596). The web sends `{prompt, seconds}` or
`{prompt, seconds, image}` (`app.js:3998-3999`, `42116-42119`); its prompt is always ≤1000 chars
(`app.js:42061`, `42093`) even though the server accepts 2000.

Cache key (`vidCacheKey`, 4641): `sha1("replicate:alibaba/wan-3:720p|<prompt>|<seconds>|<sha1(image) or "">")`.
Same prompt + seconds + same first-frame bytes ⇒ same clip, returned as `phase:"done"` at once.

Processing after body parsing:
1. Cache hit → `200 {"ok":true,"jobId":"<hex>","phase":"done","key":"<hex>"}` (4771). No charge.
2. `isNew` = this key is not already in the user's rolling log.
3. If `isNew` and the **site ceiling** is hit → `429 {"error":"site_media_ceiling","limit":120}` (4785).
4. If `isNew` and the user is not the owner/admin and their rolling window is full →
   `429 {"error":"rate_window","limit":6,"used":6,"windowMin":120,"freesInMin":<n≥1>}`
   (4791-4796). `hint` (`"set OWNER_EMAIL to exempt the owner account"`) is present only when
   `OWNER_EMAIL` is unset — ignore it. **Per-user video allowance = 6 clips per rolling 120 min**
   (`VIDEO_LIMIT` 4623, `VIDEO_WINDOW_MS` 4624), not per day. `freesInMin` is the minutes until the
   oldest entry leaves the window — show it.
5. Create/refresh the job (a `fail`ed job for the same key restarts; a `running` one is reused),
   charge the window slot immediately if `isNew` (4808 — video charges **at start**, unlike images),
   fire the render → `200 {"ok":true,"jobId":"<hex>","phase":"queued"}`.

Render: `renderVideoToCache` (4680) sends `{prompt (≤2000), duration 2…30, resolution:"720p"}` and,
with a first frame, `image`, `enable_prompt_expansion:false`, a fixed identity-preserving
`negative_prompt`. Wait ceiling `VIDEO_MAX_WAIT_MS` = **20 min** (4611); a real clip took ~15 min
(comment at 4610). Output over `VID_CACHE_MAX_BYTES` = 200 MB is discarded and the job fails (4664).

### 2.2 GET `/api/video/job?id=` — status (`server.mjs:4825-4837`)

Auth: member (guest → 401 text). Same shape as images:
`{"phase":"done","key"}` | `{"phase":"fail","error"}` | `{"phase":"running"}` (also for unknown ids).
`error`: `"engine_failed"` (4813, and the default at 4835) or an exception message cut to 200 chars.

Web cadence: first wait 2.5 s, ×1.2, cap 6 s, deadline **20 min** (`VIDEO_JOB_MAX_MS`,
`app.js:3922`, poll at `app.js:4015-4027`). On deadline the web sets `_lastVideoError = "timeout"`.

### 2.3 GET `/api/video/file?id=<key>` — the MP4 (`server.mjs:4839-4866`)

Auth: **member or guest cookie** (401 text otherwise). No rate limit. 404 plain `not found` if the
key is unknown. The whole file is read from disk into memory per request.

Headers on 200: `content-type` (from the cache `.t` file; `video/mp4` unless Replicate said
otherwise), `content-length`, `accept-ranges: bytes`, `cache-control: private, max-age=31536000, immutable`.

**HTTP Range is honoured** — single range only:
- Parses `Range: bytes=<start>-<end>` with `^bytes=(\d*)-(\d*)$` (4846). `bytes=0-1`, `bytes=1000-`
  and `bytes=0-` all work → `206` with `content-range: bytes s-e/total`, `content-length`,
  `accept-ranges`, same `cache-control`, body = `buf.subarray(start, end+1)`.
- `end ≥ total` is clamped to `total-1`; `start > end` → `416` with `content-range: bytes */total`.
- **Suffix ranges are wrong**: `bytes=-500` is parsed as start=0, end=500 (first 501 bytes), not the
  last 500 bytes. AVPlayer does not normally send suffix ranges; do not rely on them.
- Multi-range (`bytes=0-1,5-9`) does not match the regex → full-file `200`.
- No `ETag`/`Last-Modified`; no `If-Range` handling (any `Range` is served against the current bytes,
  which are immutable per key, so this is safe).

AVPlayer: build the `AVURLAsset` with the session cookie —
`AVURLAsset(url:, options: [AVURLAssetHTTPCookiesKey: HTTPCookieStorage.shared.cookies(for: url) ?? []])`
or `"AVURLAssetHTTPHeaderFieldsKey": ["Cookie": "firas_session=…"]`. If the app keeps cookies in a
non-shared store, copy `firas_session` into the asset options explicitly. For save/share, download
with `URLSession` (same cookie) to a temp `.mp4` — the web names it `<prompt sanitised, ≤50>.mp4`
(`app.js:4753`).

### 2.4 GET `/api/video/quota` (`server.mjs:5349-5358`)

Auth: member (401 text). Response
`{"ok":true|false,"limit":2,"used":<n>,"remaining":<n>,"seconds":10}`.

**Caveat:** this reads `user.vidCids` / `VIDEO_DAILY_LIMIT`=2 (3796), which are only written by the
legacy synchronous `GET /api/video` path (5324-5335). The job path uses a **different** counter
(`vidLog`, 6 per 120 min). So `used`/`remaining` here do not reflect job-path usage and `ok` is
practically always `true`. The only useful field is `seconds` (= `VIDEO_SECONDS`, default 10,
`server.mjs:3792`) — the web reads it as the default clip length and falls back to **6** when the
quota call failed (`const vSeconds = (vq && vq.seconds) || 6`, `app.js:42098`; the rewriter uses
the same number at `42071`). Do not display `limit`/`remaining` from this endpoint as the user's
video allowance; derive it from `rate_window` refusals instead.

### 2.5 Legacy `GET /api/video?prompt=&seconds=&seed=` (`server.mjs:5304-5347`)

Synchronous Hugging-Face-Spaces path; rate bucket `vid:<uid>` 12/min (plain `429 rate limited`,
line 5314); returns MP4 bytes or `503 video engine not configured` (text) when no HF accounts are
configured, `429 {"error":"daily_limit","limit":2,"used":n}` on the old daily cap, `502` text on
failure. `seconds` clamped 2…10. **Do not use.** Exists only for `firas-video` fences written
before keys existed.

### 2.6 Chat message format — the `firas-video` fence (`app.js:42146-42149`)

```
```firas-video
{"prompt":"<english prompt>","seconds":10,"seed":123456789,"jobId":"<hex>"}
```
```

- `prompt` (required for `parseVideoMeta`, `app.js:3884`), `seconds`, `seed` (client-only, inert —
  never sent to the job path), `jobId` (present when the turn already started the job, e.g. with a
  first frame), `key` (written back once the clip exists → `/api/video/file?id=<key>`).
- Three states the card must handle (`app.js:4762-4778`): `key` → play; `jobId` without `key` →
  **poll** that job (never start a new one — a second start would pay twice); neither → POST a new
  job with `{prompt, seconds}` and write `key` back into the message.
- A note may follow the fence, e.g. `\n\n_تعذّر استخدام صورتك كإطار أول، فصُنع المقطع من الوصف وحده._`
  (`app.js:42133`) or `\n\n_تعذّر استخدام صورتك: بلغت حدّ الفيديو الآن._` (429 on the first-frame
  attempt, `app.js:42132`); `\n\n_تعذّر إرسال صورتك، فصُنع المقطع من الوصف وحده._` (network,
  `app.js:42143`). English: "_Your photo could not be used as the first frame, so the clip was made
  from the description alone._" / "_Could not use your photo: the video limit was reached._" /
  "_Your photo could not be sent, so the clip was made from the description alone._"

The web's prompt pipeline: the user's request is rewritten by a model into one English prompt
describing a single continuous shot for `<seconds>` seconds (`app.js:42061-42093`; with a first
frame the rewriter is told to describe only what changes, not the subject). The raw request (≤1000
chars) is the fallback prompt. `seed` is `Math.floor(Math.random() * 1e9)` (`app.js:42099`) and is
never sent to the server.

### 2.7 Web UI copy for video (verbatim)

| Situation | Arabic | English |
|---|---|---|
| Guest (`app.js:42039`) | **توليد الفيديو للأعضاء** / أنشئ حسابًا مجانيًا لتوليد مقاطع فيديو. | **Video generation is for members** / Create a free account to generate video clips. |
| Quota pre-check `ok:false` (`app.js:42053`) | بلغت حدّك اليومي من الفيديو (2 يوميًا). الحدّ يتجدّد غدًا. | Daily video limit reached (2/day). It resets tomorrow. |
| Loader (`app.js:42060`) | يجهّز الفيديو… | Preparing the video… |
| Toast after start (`app.js:42154`) | بقي لك N فيديو اليوم | N video(s) left today |
| Card generic failure (`app.js:4784`) | تعذّر توليد الفيديو | Video generation failed |
| `daily_limit` / (web also maps nothing else here) (`app.js:4785`) | بلغت حدّك اليومي من الفيديو. جرّب بعدين. | Daily video limit reached. |
| `signin_required` (`app.js:4786`) | أنشئ حسابًا لتوليد الفيديو | Create an account to generate video |
| `not_configured` (`app.js:4787`) | محرّك الفيديو غير مهيّأ بعد | The video engine is not configured yet |

The web has **no dedicated copy** for `rate_window`, `site_media_ceiling`, `image_too_large`,
`bad_image` or `timeout` on video (they fall to the generic "تعذّر توليد الفيديو"). Recommended
native copy, modelled on the music card's window string: `rate_window` →
"لقد وصلت إلى الحد — يرجى الانتظار {freesInMin} دقيقة" / "You have reached the limit — please wait
{freesInMin} minutes"; `site_media_ceiling` → same wording without minutes; `image_too_large`/
`bad_image` → reuse "تعذّرت قراءة الصورة المرفقة." and fall back to a text-only clip.

---

## 3. Music

### 3.1 POST `/api/music/job` — start a song (`server.mjs:4875-4949`)

Auth: member (guest → `403 {"error":"signin_required","feature":"music"}`; none → 401 text).
Pre-checks: `503 {"error":"not_configured","feature":"music"}` when the configured provider has
no key (`MUSIC_PROVIDER` default `replicate` needs `REPLICATE_API_TOKEN`; `musicapi` needs
`MUSICAPI_KEY`, 4880-4881) → rate limit 10/min `429 {"error":"rate_limited"}` → body.

Request: JSON, **body limit 200,000 chars** (4885).

| Field | Type | Rules |
|---|---|---|
| `prompt` | string | the **style/arrangement tags** (genre, tempo, instruments, voice), not a description of the song. Trimmed, cut to 2000 (4886). |
| `lyrics` | string | the words to sing, trimmed, cut to 6000 (4887). Use `[verse]` / `[chorus]` tags. **Omit or send empty for an instrumental** — the server then sends no `lyrics` field and ACE-Step defaults to instrumental (4464-4467). |
| `seconds` | int | `parseInt`, default `round(ACE_DURATION)` = **150**, clamped **10…600** (4889). |

At least one of `prompt`/`lyrics` must be non-empty, else `400 {"error":"bad_request"}`. There is
no `title`, `instrumental`, `genre`, `voice` or `seed` field (the web keeps `title` in the fence only).
Unknown fields are ignored.

Cache key (`musicCacheKey`, 4403): `sha1("replicate:fishaudio/ace-step-1.5:<hash>|<prompt>|<lyrics>|<seconds>")`.
Identical style + lyrics + seconds ⇒ identical recording, returned as `done` immediately, no charge.
**"Regenerate" must change one of the three** (the web's "أعد التلحين" adds a `nonce` to the fence
but does not send it, so on this server it returns the same song — do not copy that; e.g. bump
`seconds` by 1).

Flow after parsing: cache hit → `200 {"ok":true,"jobId","phase":"done","key"}` (4899) → site
ceiling `429 {"error":"site_media_ceiling","limit":120}` (4911) → per-user rolling window
`429 {"error":"rate_window","limit":10,"used":10,"windowMin":120,"freesInMin":<n≥1>}` (4916-4920;
**10 songs per rolling 120 min**, `MUSIC_LIMIT` 4339, `MUSIC_WINDOW_MS` 4365; owner/admin exempt)
→ create job, charge the window slot **at start** if new (4930) → `200 {"ok":true,"jobId","phase":"queued"}`.

Render (`renderMusicToCache`, 4578): ACE-Step input = `{tags: prompt, duration, inference_steps:50,
guidance_scale:8.39, shift:1.52, time_signature:"auto", seed:-1, thinking:true, batch_size:1,
audio_format:"mp3", lyrics?}` (4449-4474). **Server wait ceiling is 180 s**, not the 420 s
`MUSIC_MAX_WAIT_MS` — `replicateRun` is called without `waitMs` (4584) so it uses
`REPLICATE_MAX_WAIT_MS`. A slow render past 3 min yields `fail`/`engine_failed`. A file over
`MUSIC_CACHE_MAX_BYTES` = 30 MB is discarded (4424) and the job… still reports `done` with no bytes
on disk — the status endpoint then answers `done` only via the in-memory job, and the file endpoint
404s. Treat a 404 on `/api/music/file` after `done` as a failure.

### 3.2 GET `/api/music/job?id=` — status (`server.mjs:4951-4963`)

Auth: member (guest → 401 text). `{"phase":"done","key"}` | `{"phase":"fail","error"}` |
`{"phase":"running"}` (also unknown ids). `error`: `"engine_failed"` or an exception message ≤200
chars.

Web cadence: 2 s, ×1.2, cap 6 s, deadline **10 min** (`MUSIC_JOB_MAX_MS`, `app.js:59028`; loop at
`app.js:59179-59193`). Card text while working: "يلحّن الأغنية… حوالي دقيقة" / "Composing… about a minute".

### 3.3 GET `/api/music/file?id=<key>` — the MP3 (`server.mjs:4969-4995`)

Identical to the video file endpoint: member **or guest** cookie; 404 text; `content-type`
`audio/mpeg` (ACE `audio_format` mp3; MusicAPI provider may return another audio type);
`content-length`, `accept-ranges: bytes`, `cache-control: private, max-age=31536000, immutable`;
single-range `206`/`416` exactly as §2.3 (same suffix-range bug). AVPlayer with the cookie works
and can seek. Web download name: `<title or "firas-song">.mp3` (`app.js:4668`).

### 3.4 How the web composes `prompt`/`lyrics` (so native can match)

Turn flow (`app.js:41840-42027`):
- Guest → refuse before any call.
- If the user's message **is** a lyric sheet (`songIsWrittenOut`, `app.js:41806`: contains
  `[verse]/[chorus]/[bridge]/[intro]/[outro]/[hook]`, or ≥4 lines with ≥80% of them ≤60 chars),
  `lyrics` = the message verbatim (prefixed with `[verse]\n` if it has no tags), `title` = "نشيد"/"Song",
  and `prompt` = `musicStyleFor(lang, text)` (`app.js:4402`) — a keyword→tags table, first match
  wins ("husseini
  latmiya, …", "iraqi arabic song, …", "epic anthem, …", …) always ending in
  `professional studio mixing` and, for Arabic, including `clear arabic vocals`.
- Otherwise a model writes the lyrics (system prompt at `app.js:41890-41975`): first line
  `STYLE: <english production tags>`, then `[verse]/[chorus]` lyrics with tashkeel rules for
  Arabic; the client strips the STYLE line into `prompt` and sends the rest as `lyrics`,
  `seconds: 150`, `title` = the request (≤60 chars, fence only).
- The style line **must say the language** ("clear arabic vocals"), or the engine may sing Arabic
  lyrics in English.

### 3.5 Chat message format — the `firas-music` fence (`app.js:42026-42027`)

```
```firas-music
{"prompt":"<style tags>","lyrics":"[verse]\n…","seconds":150,"title":"…","key":"<hex>"}
```
```

`parseMusicMeta` (`app.js:3868`) requires `prompt` or `lyrics`. `key` is written back after the
job finishes; `jobId` may also be present (`musicLandKey` checks it, `app.js:59125`); `nonce` is
client-only. Card with `key` → play `/api/music/file?id=`; without → POST `/api/music/job`.

### 3.6 Web UI copy for music (verbatim, `app.js:4596-4603`)

| Key | Arabic | English |
|---|---|---|
| working | يلحّن الأغنية… حوالي دقيقة | Composing… about a minute |
| ready | جاهز | Ready |
| download | تحميل | Download |
| regenerate | أعد التلحين | Regenerate |
| generic failure (`engine_failed`, `timeout`, `unreachable`, …) | ما ضبط التلحين | The song did not come out |
| `not_configured` | محرّك الموسيقى غير مهيّأ بعد | The music engine is not configured yet |
| `rate_window` / `daily_limit` | لقد وصلت إلى الحد — يرجى الانتظار ساعتين | You have reached the limit — please wait two hours |
| `signin_required` | سجّل دخولك حتى تصنع أغنية | Sign in to make a song |
| guest turn (`app.js:41853`) | **الأناشيد للأعضاء** / أنشئ حسابًا مجانيًا حتى تصنع نشيدًا. | **Songs are for members** / Create a free account to make one. |
| lyric author failed (`app.js:42007`) | ما قدرت أكتب الكلمات. جرّب توصف النشيد بشكل أوضح. | I could not write the lyrics. Try describing the song more clearly. |
| loader (`app.js:41861`) | يكتب الكلمات… | Writing the lyrics… |

The web has no copy for `site_media_ceiling` (falls to "ما ضبط التلحين"); prefer the
`rate_window` wording with `freesInMin` substituted for "ساعتين".

---

## 4. Image search and proxy (Agent/Code builds use these; not generation)

### 4.1 GET `/api/images?q=<text>` (`server.mjs:6367-6391`)

Auth: member **or guest** cookie. Rate 40/min. `q` trimmed, cut to 120 chars. Always
`Content-Type: application/json`.

| Status | Body |
|---|---|
| 200 | `{"q":"<q>","results":[{"url":"https://…","title":"<≤100>"}, …]}` — ≤8 Openverse (CC-licensed) thumbnails; `results` may be empty on upstream failure |
| 400 | `{"results":[]}` — empty `q` |
| 401 | `{"results":[],"error":"auth"}` |
| 429 | `{"results":[],"error":"rate"}` |

Web usage: `agentImageSearch` maps to `results[].url` (`app.js:55837-55841`). URLs are public
`https://` and can be loaded directly on native (no cookie).

### 4.2 GET `/api/imgproxy?u=<https url>` (`server.mjs:6478-6502`)

Member or guest; 80/min; only `https://` public hosts (SSRF-guarded); returns raster bytes with the
upstream `Content-Type` (allow-list png/jpeg/gif/webp/avif/bmp/tiff/ico), ≤ 4,000,000 bytes,
`Cache-Control: public, max-age=86400`, `Content-Length`, `X-Content-Type-Options: nosniff`,
`Content-Security-Policy: sandbox; default-src 'none'` (line 6498). Errors are empty-body `400`
(bad/blocked URL), `415` (not a raster image), `413` (> 4 MB), `502`, `429`; only the `401` has a
JSON body. Native does not need it — load the remote image directly.

---

## 5. Consolidated error-code → UI table

| HTTP | `error` | Endpoints | What the UI should say (ar / en) |
|---|---|---|---|
| 401 | (text `auth required`) | all | Session ended → sign in: "انتهت جلستك. سجّل الدخول ثمّ أعد المحاولة." / "Your session ended. Sign in and try again." |
| 403 | `signin_required` (+`feature`) | job starts, image GET/edit/quota | Guest upsell per feature (§1.8 / §2.7 / §3.6) and open sign-up. |
| 400 | `bad_request` | job starts, edit, status | Programming error (empty prompt/lyrics, bad id, oversized body). Video: also the practical "first frame too big" case → retry without the image and append the "تعذّر استخدام صورتك…" note. |
| 400 | `bad_image` | edit, video start | "تعذّرت قراءة الصورة المرفقة." / "That attached image could not be read." |
| 413 | `image_too_large` (`limit`) | video start (theoretical) | same as `bad_image`; retry text-only. |
| 429 | `rate_limited` | job starts | "طلبات كثيرة في وقت قصير. انتظر دقيقة ثمّ أعد المحاولة." / "Too many requests in a short time. Wait a minute and try again." (`app.js:42253`) |
| 429 | (text `rate limited`) | image GET, edit | same as above |
| 429 | `daily_limit` (`limit`) | image start, edit | §1.8 strings with `limit` (8). |
| 429 | `rate_window` (`limit`,`used`,`windowMin`,`freesInMin`) | video, music start | "لقد وصلت إلى الحد — يرجى الانتظار {freesInMin} دقيقة" (web says "ساعتين"). |
| 429 | `site_media_ceiling` (`limit`) | video, music start | Site-wide; same wording without a time, or "الخدمة مشغولة اليوم، جرّب لاحقًا". |
| 501 | `edit_job_unsupported` | image start with `image` | Never send `image` here; route to `/api/image/edit`. |
| 502 | `edit_failed` | edit | generic edit failure string |
| 503 | `edit_unavailable` | edit | §1.8 `edit_unavailable` string |
| 503 | `not_configured` (+`feature`) | video, music start | "محرّك الفيديو غير مهيّأ بعد" / "محرّك الموسيقى غير مهيّأ بعد" |
| 200 | phase `fail`, `all_engines_failed` / `render_failed` / `engine_failed` / other | status | image: "لم يُعدِ المحرّك صورة."; video: "تعذّر توليد الفيديو"; music: "ما ضبط التلحين". Offer retry (re-POST restarts a failed key). |
| — | client `timeout` (deadline) | polling | same generic failure; keep the job id — a later status call may still return `done`. |

---

## 6. Quirks the native port must handle

1. **Plain-text error bodies** (§0.3). A JSON decoder on every non-2xx will throw.
2. **`running` forever for unknown ids** (§0.6). Own the deadline: image 20 min, video 20 min,
   music 10 min (web values). Keep the id; retry status on app return; the cache may have the
   bytes. (The current `MediaStudioStore.poll` has **no** deadline — see §7.)
3. **No ownership check on status/file ids**; ids are guessable only as SHA-1s. Fine, but do not
   rely on the server to reject another user's id.
4. **Charging differs by kind**: images charge on success (and never for a cache hit); video and
   music charge their rolling window at job start, even if the render later fails. A failed video
   still consumed 1 of 6 for two hours.
5. **`/api/video/quota` is not the job-path allowance** (§2.4). Only `seconds` is meaningful.
6. **The 413 on video is dead code**; oversized first frames arrive as `400 bad_request`. Downscale
   the photo client-side (JPEG, ≤ 2048 px, ≤ 8 MB) and always send a proper `data:image/jpeg;base64,`
   URI — a raw base64 string is `bad_image`.
7. **Music server wait is 180 s** (§3.1), so a `seconds` of 600 may time out at the engine.
   Web default 150 s works.
8. **Cache = identity**: identical inputs never re-render. Regenerate = change the prompt (image),
   the prompt/seconds/first frame (video), or prompt/lyrics/seconds (music).
9. **Aspect clamp/snap** (§1.6): send ratios from the preset table; the delivered ratio can still
   differ by rung. Read the actual pixel size from the bytes; do not assume `w×h`.
10. **Image bytes need the member cookie**; video/music bytes accept guest. `AsyncImage` with a
    default `URLSession.shared` will only work if the cookie lives in `HTTPCookieStorage.shared`.
    Prefer downloading through the app's own session and caching to disk keyed by `key`.
11. **Range**: single `bytes=a-b` / `bytes=a-` only; suffix ranges return the wrong bytes;
    multi-range returns the whole file. No `If-Range`, no `ETag`. Files are immutable per key, so
    aggressive local caching is safe.
12. **Restart amnesia**: rate-limit buckets, job maps and the site ceiling are in memory; after a
    deploy a `queued` job that had not finished is gone (status says `running` forever). Cache
    hits survive because they are on disk (`DATA_DIR/imgcache|vidcache|musiccache`).
13. **Prompt truncation is a hard `slice`**: image 1000, video 2000, music prompt 2000 / lyrics
    6000. Put in-frame Arabic text early in an image prompt.
14. `handleImageJobStart` accepts up to 30 MB bodies but only reads `prompt/w/h/image`; do not send
    attachments there.

---

## 7. Alignment notes for the existing Swift code (`ios/FirasAI`)

Verified against `ios/FirasAI/Models/MediaStudioModels.swift`, `ios/FirasAI/Networking/FirasAPI.swift`,
`ios/FirasAI/Networking/APIClient.swift` and `ios/FirasAI/Stores/MediaStudioStore.swift`.

- **Wire shapes match.** `MediaJobStartResponse { ok: Bool?, jobId: String, phase: String?, key: String? }`
  (`MediaStudioModels.swift:87`) and `MediaJobStatusResponse { phase: String, key?, error?, reason? }`
  (`:94`) decode every 200 body in this document. The server never sends `reason`; keep it optional.
  `MediaStudioStore.poll` (`MediaStudioStore.swift:391-447`) already accepts both `done`/`completed`
  and `fail`/`failed` (`:413`, `:420`), so the HTTP `done`/`fail` and the APNs `completed`/`failed`
  are both handled.
- **Request bodies match.** `startImageJob` sends `{prompt (≤1000), w, h}`; `startVideoJob` sends
  `{prompt (≤2000), seconds clamped 2…30}`; `startMusicJob` sends `{prompt (≤2000), lyrics (≤6000),
  seconds clamped 10…600}` (`FirasAPI.swift:381-437`). `MediaVideoJobRequest` (`MediaStudioModels.swift:76`)
  has no `image` field — add an optional `image: String?` carrying a `data:image/jpeg;base64,…` URI
  (§2.1) to support first-frame video. Music defaults to `seconds ?? 90` (`MediaStudioStore.swift:386`);
  the web sends 150 (§3.4) — pick one deliberately; the cache key includes it.
- **No polling deadline.** `poll` loops until the task is cancelled ("a client-side clock must never
  turn a still-rendering cloud job into a permanent failure", `:403-405`). Combined with §0.6 (an
  unknown id answers `running` forever after a restart or after the one-hour sweep of a job that
  failed), a lost job spins indefinitely. Add a hard deadline per kind (image 20 min, video 20 min,
  music 10 min — the web's values) that marks the creation `failed` with code `timeout`
  (`localizedFailure` already has a `timeout` string, `:634`/`:642`) while keeping `jobID` so a later
  `resumeIfNeeded` can still find the bytes.
- **Error codes are recognised, numbers are dropped.** `APIClient.validate` decodes only
  `ServerErrorEnvelope { error: String? }` (`APIClient.swift:43-45`, `:168-172`), so `limit`, `used`,
  `windowMin` and `freesInMin` from `daily_limit` / `rate_window` never reach the store, and
  `localizedFailure` (`MediaStudioStore.swift:626-645`) cannot say "wait N minutes" or "8 per day".
  Extend the envelope with `limit: Int?`, `used: Int?`, `windowMin: Int?`, `freesInMin: Int?`,
  `feature: String?` and thread them into the message. Codes it already maps: `signin_required`/`auth`,
  `daily_limit`, `rate_window`/`rate_limited`, `site_media_ceiling`, `not_configured`, `timeout`,
  else generic. The `daily_limit` string is image-specific ("وصلت إلى حد إنشاء الصور اليومي.") but on
  this server only images use `daily_limit`, so that is correct. Missing codes: `bad_image`,
  `image_too_large` (video), `edit_failed`, `edit_unavailable`, `bad_request`, `all_engines_failed`,
  `engine_failed`, `render_failed` (the last three fall to the generic string, which is fine).
- **Plain-text bodies** (§0.3): a `401 auth required` has no JSON, so `validate` falls back to
  `HTTPURLResponse.localizedString(forStatusCode:)` ("unauthorized"), which `localizedFailure`
  matches through `key.contains("auth")` — by accident, but correctly. Do not rely on the text.
- **Request timeout too short for edits.** `APIClient` sets `timeoutIntervalForRequest = 45`
  (`APIClient.swift:62`). Fine for job starts, status and file downloads, but `POST /api/image/edit`
  is synchronous and can legitimately take up to ~180 s (§1.4); give that call its own session or a
  per-request timeout ≥ 200 s.
- **Cookies.** `APIClient` uses `HTTPCookieStorage.shared` with `httpShouldSetCookies = true`
  (`APIClient.swift:58-60`), so `firas_session` is in the shared jar and `AsyncImage`, `URLSession.shared`
  and `AVURLAsset` will send it by default. Still pass `AVURLAssetHTTPCookiesKey:
  HTTPCookieStorage.shared.cookies(for: url) ?? []` when building the asset — AVFoundation's media
  loader is a separate process and the explicit option is the documented contract.
- `FirasAPI.mediaAsset` downloads `/api/image?key=`, `/api/video/file?id=`, `/api/music/file?id=`
  (`FirasAPI.swift:451-473`) — parameter names are correct. For playback prefer streaming via
  `AVURLAsset` (Range works, §2.3/§3.3); for share/save the download is right.
- `requireIdentifier` allows `[A-Za-z0-9_-]`, ≤160 chars (`FirasAPI.swift:483`); server ids are 40
  lowercase hex. Fine.
- `ImageAspectPreset` pixel pairs (`MediaStudioModels.swift:35-66`) and what Replicate actually
  renders: `square` 1:1, `portrait` **4:5**, `landscape` 16:9, `story` 9:16, `banner` **16:9**
  (not 21:9 — 1280×640 is nearer 16:9 in log space), `cover` 3:2. If `portrait` should be 3:4 send
  960×1280; if `banner` should be 21:9 send 1280×549 (§1.6 table).
- Missing today: `POST /api/image/edit` (no Swift call), `POST /api/image/quota` pre-check, and the
  `firas-image` / `firas-video` / `firas-music` fence parsing for chat history (§1.7, §2.6, §3.5).
