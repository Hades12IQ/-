# Firas AI — Voice slice: server contract and native-client rules

Source of truth: `server.mjs` at the repo root (Node, zero deps). Every `file:line` below is a
citation into that file unless prefixed `app.js:` (the web client, read only to learn what the
server expects and how the shipped client behaves) or `SKILL:` (the repo playbooks
`.claude/skills/realtime-voice-sessions/SKILL.md` and `.claude/skills/speech-and-tts/SKILL.md`).
`netlify/edge-functions/api.js` is a legacy mirror and is deliberately not described here.

Three routes make up the slice (server.mjs:13794–13796):

| Route | Method | Handler | Purpose |
| --- | --- | --- | --- |
| `/api/live/token` | POST | `handleLiveToken` (6212) | Mint a one-session credential for a live two-way voice call (OpenAI Realtime first, Gemini Live second) |
| `/api/transcribe` | POST | `handleTranscribe` (6312) | Dictation: base64 WAV/MP3 in, `{text}` out (Gemini) |
| `/api/tts` | POST | `handleTts` (5731) | Text in, one audio file out (Gemini TTS → OpenAI TTS → Edge neural → 503) |

Every marker in §8 is tagged **VERIFIED-FROM-CODE** (read in this repo) or **FROM-KNOWLEDGE**
(OpenAI Realtime GA protocol as I know it; confirm against a live `session.created` event before
shipping).

---

## 1. Identity and auth (applies to all three routes)

All three routes call `callerOf(req)` (1314–1320), which returns:

- `{ user, id: user.id, isGuest: false }` when the **member cookie** resolves;
- `{ id: "g_…", isGuest: true }` when the **guest cookie** resolves;
- `{}` when neither does.

There is **no bearer-token or header auth anywhere** (grep for `headers.authorization` and
`headers["authorization"]` in server.mjs finds no reader — re-verified 2026-09-02). A native client must carry the server's cookies:

| Cookie | Name | Set by | Lifetime | Flags | Resolves via |
| --- | --- | --- | --- | --- | --- |
| Member | `firas_session` (1046) | login / register / Google sign-in | 30 days (`COOKIE_MAX_AGE` 1047) | `HttpOnly; SameSite=Lax; Path=/` + `Secure` when `x-forwarded-proto: https` or `SECURE_COOKIES=1` (1052–1054) | `currentUser` (1098–1114): HMAC-verified value `"<id>.<ver>.<mac>"`, and the embedded session version must equal `user.sessVer` — a password change / logout-everywhere invalidates every older cookie |
| Guest | `firas_guest` (1131) | `POST /api/guest` (2017–2026, route 13837) | 7 days (`GUEST_COOKIE_MAX_AGE` 1132) | same flags | `currentGuest` (1156–1160): HMAC-verified id starting with `g_` |

Guest bootstrap: `POST /api/guest` with no body → `200 { guest: true, user: { id, name: "", email: "", guest: true, admin: false, sub } }` and a `Set-Cookie: firas_guest=…`. If a member cookie is already present it answers `200 { guest: false, user }` and sets nothing. Rate limit `guest:<ip>` 20/min → `429 { error: "too many requests" }`. `DELETE /api/guest` clears the cookie (2029–2033). Use `HTTPCookieStorage` with `httpShouldSetCookies = true` (the existing Swift `LiveVoiceTokenClient` already does this).

Per-route identity requirement:

| Route | Member | Guest | Nobody |
| --- | --- | --- | --- |
| `/api/live/token` | allowed, 10-min ceiling | allowed, 50-s ceiling | `403 { error: "signin_required", feature: "live" }` (6219) |
| `/api/transcribe` | allowed | allowed (tighter rate limit) | `401 { error: "authentication required" }` (6315) |
| `/api/tts` | allowed | allowed (tighter rate limit) | `401 { error: "authentication required" }` (5734) |

Note the asymmetry: the live route answers **403 signin_required** to an anonymous caller, the other two answer **401**. The web client treats any 403 with `error === "signin_required"` as "open the sign-up prompt for `feature`" (app.js:3223–3226), and a 401 as "session expired" only for members (app.js:3221, 3239–3242).

---

## 2. Shared mechanics you must model

### 2.1 `rateLimited(key, max, windowMs)` (1076–1086)

In-memory sliding window per process. It **pushes the current timestamp first and then tests `count > max`**, so `max` requests per window succeed and the `(max+1)`th is refused. Every refusal is `429 { error: "rate limited" }`. Buckets are per server process (one Fly machine) and reset on restart.

| Key | Limit | Where |
| --- | --- | --- |
| `live:<ownerId>` | guest 3/min, member 6/min | 6222 |
| `stt:<id>` | guest pre-check 12/min (6317, before the body is read) **and** everyone 20/min (6323, after the probe) — **the same key**, so a guest's non-probe request is counted twice: a guest effectively gets 6 transcriptions per minute (the 7th trips the 12 cap). A probe counts once for guests. | 6317, 6323 |
| `tts:<id>` | guest 25/min, member 90/min | 5735 |
| `guest:<ip>` | 20/min | 2022 |

### 2.2 Body reading (`readJson` 1682–1689, `readBody` 1646–1680)

`limit` is a **JavaScript string length** (UTF-16 code units after UTF-8 decode), not bytes. Exceeding it destroys the socket and rejects with `Error("body too large")`. Unless the handler wraps the call in `try/catch`, that rejection reaches the router's catch (13862–13868) and becomes `500 { error: "internal error" }` with the connection possibly reset. Unparseable JSON → `readJson` returns `null` → handler answers `400 { error: "invalid JSON body" }`. An empty body parses as `{}`.

| Route | Limit | Over-limit outcome |
| --- | --- | --- |
| `/api/live/token` | 2 000 chars (6240), inside try/catch | the rejection is swallowed, but `readBody` has already called `req.destroy()` (1670–1671) before rejecting, so whatever the handler answers afterwards never reaches the client — expect a connection reset, not a token. The real body is ~40 bytes; never pad it. |
| `/api/transcribe` | `CHAT_BODY_LIMIT` = 25 000 000 chars (442, 6318) | 500 internal error / socket reset |
| `/api/tts` | 200 000 chars (5736) | 500 internal error / socket reset |

`sendJson` (1691–1695) always sets `Content-Type: application/json; charset=utf-8`.

### 2.3 Voice quota: `chargeVoice(req, caller)` (5714–5728)

Called by all three handlers. Returns `null` (allowed) or a **429 body**.

- **Members**: `PLAN_LIMITS.<plan>.voice` is `-1` on every plan (1347–1357) → `chargeVoice` returns `null` before touching the counter (5721). **Members are unmetered; `user.quota.voice` is never even incremented.** The `429 { error: "daily quota reached", quota: { product: "voice", used, limit, plan } }` branch (5725) is dead unless `PLAN_LIMITS` changes — model it anyway.
- **Guests**: `guestChargeWithReq(req, id, "voice", null, null)` (5716) → `guestCharge` (1279–1304): two daily buckets — per-cookie `GUEST_LIMITS.voice` = 120 (env `GUEST_DAILY_VOICE`, 1152) and per-network (an HMAC of the client IP, `guestIpKey` 1257–1262) `120 × GUEST_IP_MULTIPLIER(4)` = 480 (`guestChargeIp` 1264–1277). Order inside one charge: (a) cookie count ≥ 120 → cookie denial; (b) network count ≥ 480 → network denial and the cookie is **not** incremented; (c) otherwise both are incremented. The `cid` is `null` on every voice route, so `isRepeatCharge` (1225–1240) returns `false` every time — a retried voice request is a fresh charge; there is no retry idempotency on voice. Denials, both status **429**:
  - cookie bucket: `{ error: "guest daily limit reached", guest: true, quota: { product: "voice", used, limit: 120, plan: "guest" } }`
  - network bucket: `{ error: "guest daily limit reached", guest: true, quota: { product: "voice", used, limit: 480, plan: "guest", scope: "network" } }`
- The "day" rolls at **Baghdad midnight**, not the device's: `serverDay` (3197–3203) shifts the clock by `QUOTA_TZ_OFFSET_MINUTES` (env, default **180** = UTC+3, 3196) and reads UTC date fields off the shifted value. The next reset instant is `Date.UTC(y, m, d + 1)` of the shifted date minus 180 min — `manusResetAt` (8614–8620) is that exact formula. A "resets at" label must use this clock.
- `guestSubInfo` (1185–1194) does **not** expose the `voice` product, so a client cannot pre-read remaining voice units; the only signal is the 429 body.
- Each charge persists `db.json` (`persist()` in guestCharge), so guest charges are durable across restarts; member counters are irrelevant (unmetered).

Because members are unmetered, the only real 429s a signed-in user sees on voice routes are **per-minute rate limits**. Distinguish the two by body: `error === "rate limited"` vs `quota` present (SKILL speech-and-tts §11).

---

## 3. `POST /api/live/token` — `handleLiveToken` (6212–6310)

### 3.1 Request

Optional JSON body (≤ 2 000 chars, else ignored):

```json
{ "prefer": "gemini", "voice": "cedar" }
```

- `prefer` — the **only** accepted value is `"gemini"` (6241). It means "I already hold an OpenAI token for this call and could not bring the session up; give me the Gemini token for the same call". Any other value (including `"openai"`) is ignored. The client can only walk **down** the ladder, never skip a fallback.
- `voice` — must be one of `CALL_VOICE_ALLOW = ["cedar", "ash", "verse", "echo", "ballad"]` (6146); anything else is ignored and the default `OPENAI_REALTIME_VOICE` (`"cedar"`, env override, 6142) is used. Applies to the **OpenAI** session only; the Gemini voice is chosen client-side at setup (§7.9).

The web client always sends `{ voice: callVoice() }` and adds `prefer` only for the fallback leg (app.js:49152–49158). `callVoice()` is the persisted pick from `localStorage["firas_call_voice"]`, default `"cedar"` (app.js:48302–48306).

### 3.2 Decision order and status codes

| Step | Condition | Response |
| --- | --- | --- |
| 1 | no member and no guest | `403 { "error": "signin_required", "feature": "live" }` (6219) |
| 2 | `rateLimited("live:"+ownerId, guest?3:6, 60s)` | `429 { "error": "rate limited" }` (6222) |
| 3 | neither `OPENAI_API_KEY` nor any Gemini key configured | `503 { "error": "no_engine" }` (6223) |
| 4 | parse body (2 KB, errors swallowed) | — |
| 5 | **charge once per call** (see 3.5); denied | `429` guest quota body (§2.3) (6250–6251) |
| 6 | `OPENAI_API_KEY` set and `prefer !== "gemini"` → `mintOpenAIRealtime(callVoice)` succeeded | `200` OpenAI token (3.3) |
| 6b | mint failed (any reason; logged, never relayed) | fall through to 7 |
| 7 | no Gemini key | `502 { "error": "mint_failed" }` (6274) |
| 8 | `fetch` to `generativelanguage.googleapis.com/v1beta/auth_tokens` threw | `502 { "error": "unreachable" }` (6293) |
| 9 | non-2xx from Google, or no `name` in the reply | `502 { "error": "mint_failed" }` (6295, 6298) |
| 10 | success | `200` Gemini token (3.4) |

The charge (step 5) happens **before** the mint, so a 502 still consumed a guest unit; the 90-s grace (3.5) makes the immediate `prefer:"gemini"` retry free.

### 3.3 Success response — OpenAI (6261–6269)

```json
{
  "provider": "openai",
  "token": "ek_…",
  "model": "gpt-realtime-2.1",
  "voice": "cedar",
  "maxMs": 600000,
  "guest": false,
  "startWithinMs": 60000
}
```

- `token` is the ephemeral client secret (`j.value` or `j.client_secret.value`, 6208) — valid **600 s from creation** (`expires_after: { anchor: "created_at", seconds: 600 }`, 6175), one session.
- `model` = `OPENAI_REALTIME_MODEL` default `"gpt-realtime-2.1"` (env override; the comment at 6132–6137 says `gpt-realtime-2.1-mini` is the cheaper revert with "noticeably weaker" Arabic).
- `voice` = the voice actually configured on the session (validated value or default).
- `maxMs` = `LIVE_SESSION_MAX_MS` (default 10 min, env-capped at 30 min, 6090–6093) for members; `GUEST_LIVE_MAX_MS` (default 50 000 ms, env-capped at 5 min, 6101–6104) for guests. **Nothing on the OpenAI side enforces `maxMs`** — the secret expiry bounds the *start*, not the *call*. The client's hard timer is the only ceiling on this engine (§7.3).
- `guest` = `true` when minted for a guest cookie. Drive the "why did it stop" toast from it (§7.3).
- `startWithinMs` = `LIVE_START_WINDOW_MS` = 60 000 (6094). Open the session within 60 s.

### 3.4 Success response — Gemini (6302–6309)

```json
{
  "provider": "gemini",
  "token": "auth_tokens/…",
  "model": "gemini-3.1-flash-live-preview",
  "maxMs": 600000,
  "guest": false,
  "startWithinMs": 60000
}
```

- No `voice` field.
- `token` is the `auth_tokens` resource **name** (`j.name || j.token || j.tokenInfo.name`, 6297), passed verbatim as `?access_token=` on the WebSocket URL (§7.9).
- `model` = `GEMINI_LIVE_MODEL` default `"gemini-3.1-flash-live-preview"` (6089).
- The Gemini token **is** enforced upstream: minted with `uses: 1`, `expireTime = now + maxMs` (the call ceiling), `newSessionExpireTime = now + 60 000` (the dial window) (6281–6283). A token that has opened one socket is spent even if the setup was then refused — every reconnect needs a fresh mint (app.js:49142–49146).
- The mint body pins only model and audio modality via `fieldMask: "model,generationConfig.responseModalities"` with `bidiGenerateContentSetup: { model: "models/<GEMINI_LIVE_MODEL>", generationConfig: { responseModalities: ["AUDIO"] } }` (6286–6290). Voice, VAD tuning, tools and system instruction are therefore **client-supplied at setup** (§7.9). The field is `bidiGenerateContentSetup`, not the SDK's `liveConnectConstraints` (6284–6285).

### 3.5 Charge-once-per-call grace (6113–6130, 6246–6253)

```js
const LIVE_CHARGE_GRACE_MS = 90_000;
const liveCharged = new Map();   // ownerId -> ts of last charged mint
const already = liveCharged.get(liveOwnerId) || 0;
if (!(prefer === "gemini" && Date.now() - already < LIVE_CHARGE_GRACE_MS)) {
  const denied = chargeVoice(req, caller); if (denied) return sendJson(res, 429, denied);
  liveCharged.set(liveOwnerId, Date.now());
}
```

Only a mint that **explicitly sends `prefer: "gemini"` within 90 s of the last charged mint** skips the charge. A retry without `prefer` (the web's `retry()` after a refused Gemini setup, app.js:49443–49449) pays again — harmless for members (unmetered), one guest unit for guests. The map is swept every 60 s.

### 3.6 Constants (server.mjs)

| Name | Default | Env | Line |
| --- | --- | --- | --- |
| `OPENAI_REALTIME_MODEL` | `"gpt-realtime-2.1"` | `OPENAI_REALTIME_MODEL` | 6138 |
| `OPENAI_REALTIME_VOICE` | `"cedar"` | `OPENAI_REALTIME_VOICE` | 6142 |
| `CALL_VOICE_ALLOW` | `["cedar","ash","verse","echo","ballad"]` | — | 6146 |
| `GEMINI_LIVE_MODEL` | `"gemini-3.1-flash-live-preview"` | `GEMINI_LIVE_MODEL` | 6089 |
| `LIVE_SESSION_MAX_MS` | 600 000 (10 min), max 1 800 000 | `LIVE_SESSION_MAX_MS` | 6090–6093 |
| `GUEST_LIVE_MAX_MS` | 50 000, max 300 000 | `GUEST_LIVE_MAX_MS` | 6101–6104 |
| `LIVE_START_WINDOW_MS` | 60 000 | — | 6094 |
| `LIVE_CHARGE_GRACE_MS` | 90 000 (map swept every 60 s, `unref`'d) | — | 6125–6130 |
| `QUOTA_TZ_OFFSET_MINUTES` | 180 (UTC+3, guest day boundary) | `QUOTA_TZ_OFFSET_MINUTES` | 3196 |
| OpenAI secret TTL | 600 s | — | 6175 |
| `OPENAI_API_KEY` | `""` | `OPENAI_API_KEY` | 3466 |
| Gemini key pool | `GEMINI_API_KEY`, `GEMINI_API_KEYS`, `GEMINI_API_KEY_1…24` | — | 217–229 |

### 3.7 The exact OpenAI session minted — `mintOpenAIRealtime(voice)` (6166–6210)

`POST https://api.openai.com/v1/realtime/client_secrets` with `Authorization: Bearer <OPENAI_API_KEY>`:

```json
{
  "expires_after": { "anchor": "created_at", "seconds": 600 },
  "session": {
    "type": "realtime",
    "model": "gpt-realtime-2.1",
    "instructions": "<REALTIME_INSTRUCTIONS>\n\n<IDENTITY_BLOCK>",
    "audio": {
      "input": {
        "transcription": { "model": "gpt-4o-mini-transcribe" },
        "noise_reduction": { "type": "near_field" },
        "turn_detection": { "type": "semantic_vad", "create_response": true, "interrupt_response": true }
      },
      "output": { "voice": "cedar", "speed": 1.0 }
    }
  }
}
```

Facts a native client must respect because they are baked into the secret:

- **No `format` is set on input or output** (6186–6197), so the API defaults apply — PCM16, 24 kHz, mono, little-endian for both directions (FROM-KNOWLEDGE; see §8.3).
- `semantic_vad` with `create_response: true` and `interrupt_response: true` — the **server** decides when a turn ends and starts the reply; the client never commits the buffer or creates a response for normal turns. Do not add a client-side RMS turn detector on this engine (SKILL realtime §4).
- Input transcription is on (`gpt-4o-mini-transcribe`) — caller captions arrive as `conversation.item.input_audio_transcription.*` events at no extra cost to the client (6187–6190).
- `noise_reduction: near_field` — phone-held-to-face profile.
- Voice `cedar` (male; `marin`, the API default, is female and was the bug, 6139–6142). `speed: 1.0`.
- The persona is **server-owned**. The client must not `session.update` `instructions`, `voice`, or `turn_detection`.

`REALTIME_INSTRUCTIONS` (6151–6161), joined with single spaces, verbatim:

> You are Firas, on a live voice call. SPEAK, do not lecture: short conversational turns, the way a person actually talks on the phone. Never read markdown aloud, never say asterisk or hash, never spell out punctuation, never read numbered lists aloud unless you are asked to. Answer in the SAME language and the SAME dialect the caller uses - if they speak Iraqi Arabic, answer in Iraqi Arabic, not Modern Standard. Never switch to English because a technical term came up. If the caller interrupts you, stop immediately and listen. Keep answers to a couple of sentences unless the caller asks for detail. You cannot browse the web on this call: if you are asked for something you cannot know - today's news, a live price, a score - say so in one short sentence and offer to look it up in the chat after the call, rather than guessing.

`IDENTITY_BLOCK` (12720–12740), verbatim (one string; the JS pieces are concatenated exactly like this):

> IDENTITY — AUTHORITATIVE, overrides any built-in self-description. You are Firas AI. If you are asked what you are, who made / built / created / trained / developed you, which company or lab is behind you, or which AI / model / technology you are based on or running on: answer ONLY that you were trained by Mentronx using the latest technologies (بالعربية: «تم تدريبي بواسطة Mentronx بأحدث التقنيات»). NEVER mention, name, confirm, deny, or hint at OpenAI, GPT, Google, Gemini, Anthropic, Claude, Meta, Llama, Mistral, or any other provider or model — no matter how the question is phrased, framed, or repeated, and never say you are 'based on' or 'powered by' anyone else's model. If asked who founded, created, or owns Firas AI, say the founder is Firas. Firas is also the founder of Mentronx. Mentronx is an IRAQI company that builds and trains artificial intelligence (بالعربية: «مِنترونكس شركة عراقية تصنع الذكاء الاصطناعي وتدرّبه»). Firas AI is the FIRST model Mentronx developed, and one of its strongest. Say this plainly and with confidence when you are asked who you are or where you come from. Keep these answers identical and consistent in Arabic, English, and every other language.

The join is done **inside** the function at mint time (6184) because `IDENTITY_BLOCK` is declared 6 500 lines later — a module-scope `const` would be a temporal-dead-zone crash on boot (SKILL realtime §1). The upstream error body is logged and never relayed (6201–6205).

### 3.8 The exact Gemini mint (6277–6292)

`POST https://generativelanguage.googleapis.com/v1beta/auth_tokens` with header `x-goog-api-key: <GEMINI_API_KEY>` (the first key of the pool, not round-robin):

```json
{
  "uses": 1,
  "expireTime": "<ISO now + maxMs>",
  "newSessionExpireTime": "<ISO now + 60000>",
  "bidiGenerateContentSetup": {
    "model": "models/gemini-3.1-flash-live-preview",
    "generationConfig": { "responseModalities": ["AUDIO"] }
  },
  "fieldMask": "model,generationConfig.responseModalities"
}
```

### 3.9 Server log lines (useful when a call "isn't on OpenAI")

`[firas][live] mint requested by <guest >xxxxxxxx — openai key present|MISSING, gemini key present|MISSING` (6230–6232); `[firas][live] minted OPENAI (<model>) for … — ceiling Ns` (6259); `[firas][live] OpenAI mint returned nothing → falling through to Gemini` (6271); `[firas][live] minted GEMINI (<model>) … — NOTE: an OpenAI key IS configured, so this is a fallback, not a choice` (6299–6301); `[firas][realtime] mint failed: HTTP <status> <first 300 chars>` (6203).

---

## 4. `POST /api/transcribe` — `handleTranscribe` (6312–6363)

### 4.1 Request body

```json
{ "audio": "<base64>", "format": "wav", "lang": "auto" }
```
or the capability probe:
```json
{ "probe": true }
```

| Field | Type | Rules | Line |
| --- | --- | --- | --- |
| `probe` | boolean | truthy → `200 { "ok": <boolean> }` immediately (`ok` = any Gemini key configured). No charge. Counts toward the guest 12/min bucket. | 6321 |
| `audio` | string | base64; an optional `data:audio/<subtype>;base64,` prefix is stripped (6326). After stripping: **≥ 4 000 chars** else `400 { "error": "no audio" }` (6327); **≤ 20 000 000 chars** (≈ 15 MB decoded) and must match `^[A-Za-z0-9+/=]+$` (standard alphabet, **no line breaks, no URL-safe `-`/`_`**) else `400 { "error": "bad audio" }` (6328). | 6326–6328 |
| `format` | string | `"mp3"` → the bytes are sent to Gemini as `audio/mp3`; **anything else or absent → `audio/wav`** (6325). There is no `m4a`/`webm`/`caf` branch — sending AAC or Opus labelled `audio/wav` is unsupported (Gemini may or may not decode it; do not rely on it). Send **WAV** (RIFF, 16 kHz, mono, PCM16 LE — exactly what the web encodes in `micWavBase64`, app.js:47947–47978) or MP3. | 6325 |
| `lang` | string | key of `STT_HINTS`; unknown/absent → `"auto"` (no hint). | 6329 |

`STT_HINTS` (6064–6079), verbatim — the value is appended to the transcription instruction:

| key | hint |
| --- | --- |
| `auto` | *(none)* |
| `msa` | ` The speech is Arabic (العربية الفصحى).` |
| `iraqi` | ` The speech is Iraqi Arabic dialect (اللهجة العراقية). Write it in Arabic script exactly as spoken.` |
| `gulf` | ` The speech is Gulf Arabic dialect (اللهجة الخليجية). Write it in Arabic script exactly as spoken.` |
| `egyptian` | ` The speech is Egyptian Arabic dialect (اللهجة المصرية). Write it in Arabic script exactly as spoken.` |
| `levant` | ` The speech is Levantine Arabic dialect (اللهجة الشامية). Write it in Arabic script exactly as spoken.` |
| `maghrebi` | ` The speech is Maghrebi Arabic dialect (اللهجة المغاربية). Write it in Arabic script exactly as spoken.` |
| `en` | ` The speech is English.` |
| `fr` | ` The speech is French.` |
| `tr` | ` The speech is Turkish.` |
| `de` | ` The speech is German.` |
| `es` | ` The speech is Spanish.` |
| `ur` | ` The speech is Urdu.` |
| `fa` | ` The speech is Persian (Farsi).` |

These keys are the same ones the web's dialect picker stores in `localStorage["firas_mic_lang"]` (`mic.lang`, app.js:47614) and maps to BCP-47 for on-device recognition via `MIC_BCP` (app.js:47600–47604): `auto:""`, `msa:"ar-SA"`, `iraqi:"ar-IQ"`, `gulf:"ar-SA"`, `egyptian:"ar-EG"`, `levant:"ar-JO"`, `maghrebi:"ar-MA"`, `en:"en-US"`, `fr:"fr-FR"`, `tr:"tr-TR"`, `de:"de-DE"`, `es:"es-ES"`, `ur:"ur-PK"`, `fa:"fa-IR"`. `auto` on a device recogniser must resolve to `ar-SA` (Arabic-first product; SKILL speech-and-tts §13, app.js:48152).

### 4.2 Decision order and status codes

| Step | Condition | Response |
| --- | --- | --- |
| 1 | no identity | `401 { "error": "authentication required" }` (6315) |
| 2 | guest and `rateLimited("stt:"+id, 12, 60s)` | `429 { "error": "rate limited" }` (6317) |
| 3 | body unparseable | `400 { "error": "invalid JSON body" }` (6319) |
| 4 | `probe` | `200 { "ok": true|false }` (6321) |
| 5 | no Gemini key | `503 { "error": "no stt engine" }` (6322) |
| 6 | `rateLimited("stt:"+id, 20, 60s)` (everyone) | `429 { "error": "rate limited" }` (6323) |
| 7 | `chargeVoice` denied (guests only in practice) | `429` quota body (§2.3) (6324) |
| 8 | audio too short / missing | `400 { "error": "no audio" }` (6327) |
| 9 | audio too long / bad alphabet | `400 { "error": "bad audio" }` (6328) |
| 10 | every model in `GEMINI_TEXT_MODELS` failed (non-2xx, network, or 60-s timeout) | `502 { "error": "stt engine unavailable" }` (6362) |
| 11 | success | `200 { "text": "…" }` (6359) — `text` may be `""` (no intelligible speech) |
| — | body > 25 000 000 chars | `500 { "error": "internal error" }` / connection reset |

### 4.3 Engine (6330–6361)

Gemini `generateContent` on each model of `GEMINI_TEXT_MODELS` (default `"gemini-2.5-flash,gemini-flash-latest"`, 197) in order, key from `geminiPickKey()` (round-robin pool), `temperature: 0`, `AbortSignal.timeout(60_000)` per attempt. Prompt = `STT_INSTRUCTION + " Transcribe this audio verbatim." + hint` with the audio as `inline_data`. `STT_INSTRUCTION` (6080–6084): *"You are a professional speech-to-text engine. Output ONLY the verbatim transcription of the audio — no commentary, no quotation marks, no labels, no translation. Keep the speaker's language and dialect exactly as spoken (Arabic dialects stay in Arabic script as pronounced; mixed Arabic/English stays mixed). Add natural punctuation. If there is no intelligible speech, output an empty string."* A reply wrapped once in `"…"` or `«…»` is unwrapped (6357). Expect 2–10 s latency for a 10-s clip; budget a 60-s client timeout.

### 4.4 Client-side rules the web enforces (copy them)

- Hard recording cap `MIC_MAX_SECONDS = 300` (app.js:47598) — 5 min of 16-kHz WAV base64 is ≈ 12.8 MB, under the 20 M-char limit.
- Locally reject a take shorter than 700 ms or a blob under 1 500 bytes with `micTooShort` (app.js:47905, 47911) instead of hitting the server's 4 000-char floor.
- Show `micTranscribing` while waiting; empty `text` → `micEmpty`; network/5xx → `micFail`; **503** → remember "no server STT" and switch to on-device recognition (app.js:47937: `if (e.status === 503 && micLiveSupported()) { mic.serverStt = false; micStartLive(); }`). On iOS the equivalent is `SFSpeechRecognizer` with the `MIC_BCP` locale.
- Probe once at boot with `{ probe: true }` to decide server STT vs device dictation (app.js:47738, 50054).
- Append the transcript to the composer with a single space separator (app.js:47926).

---

## 5. `POST /api/tts` — `handleTts` (5731–5848)

### 5.1 Request body

```json
{ "text": "…", "lang": "ar", "gender": "male", "voice": "ar-IQ-BasselNeural", "slow": false }
```

| Field | Type | Rules | Line |
| --- | --- | --- | --- |
| `text` | string, required | whitespace collapsed to single spaces, trimmed, **sliced to 1 400 chars** (silently). Empty after that → **`400` with an empty body (not JSON)** (`res.writeHead(400); res.end()`). | 5738–5739 |
| `lang` | string | lowercased; starts with `ar` → `"ar"`; else matches `^[a-z]{2}(-[a-z]{2})?$` → first two letters; else `"en"`. The **raw** lowercased value (e.g. `ar-iq`) is what reaches the engines, so a regional tag selects the Edge dialect voice. | 5740–5741 |
| `gender` | string, optional | if present and not `"male"`/`"m"` (case-insensitive) → `400 { "error": "only a male voice is available" }`. The web always sends `"male"`. | 5757–5760 |
| `voice` | string, optional | must be one of the `EDGE_VOICES` values (5405–5414); otherwise silently ignored. Only affects the Edge hop. | 5761 |
| `slow` | boolean, optional | only used by the disabled Google Translate hop (`&ttsspeed=0.5`). | 5827 |

`EDGE_VOICES` (all male): `ar:"ar-SA-HamedNeural"`, `ar-sa:"ar-SA-HamedNeural"`, `ar-eg:"ar-EG-ShakirNeural"`, `ar-iq:"ar-IQ-BasselNeural"`, `ar-jo:"ar-JO-TaimNeural"`, `ar-ma:"ar-MA-JamalNeural"`, `en:"en-US-AndrewMultilingualNeural"`, `en-us:"en-US-AndrewMultilingualNeural"`, `fr:"fr-FR-HenriNeural"`, `tr:"tr-TR-AhmetNeural"`, `de:"de-DE-ConradNeural"`, `es:"es-ES-AlvaroNeural"`, `ur:"ur-PK-AsadNeural"`, `fa:"fa-IR-FaridNeural"`, `ru:"ru-RU-DmitryNeural"`, `it:"it-IT-DiegoNeural"`, `pt:"pt-BR-AntonioNeural"`, `hi:"hi-IN-MadhurNeural"`, `id:"id-ID-ArdiNeural"`, `ja:"ja-JP-KeitaNeural"`, `zh:"zh-CN-YunxiNeural"`, `ko:"ko-KR-InJoonNeural"`.

### 5.2 Decision order and status codes

| Step | Condition | Response |
| --- | --- | --- |
| 1 | no identity | `401 { "error": "authentication required" }` (5734) |
| 2 | `rateLimited("tts:"+id, guest?25:90, 60s)` | `429 { "error": "rate limited" }` (5735) |
| 3 | body unparseable | `400 { "error": "invalid JSON body" }` (5737) |
| 4 | text empty | `400`, empty body (5739) |
| 5 | `chargeVoice` denied (guests only in practice) | `429` quota body (§2.3) (5749) |
| 6 | `gender` present and not male | `400 { "error": "only a male voice is available" }` (5759) |
| 7 | engine ladder (5.3) produced bytes | `200` audio |
| 8 | every male engine failed and `TTS_ALLOW_FEMALE_FALLBACK` unset (default) | `503 { "error": "tts unavailable", "reason": "no male voice engine available" }` (5825) |
| 8b | `TTS_ALLOW_FEMALE_FALLBACK=1` and Google Translate TTS failed | `502 { "error": "tts unavailable" }` (5842) / `502 { "error": "tts empty" }` (5845) |
| — | body > 200 000 chars | `500 { "error": "internal error" }` |

Quota is charged **after** validation of JSON/text but **before** the gender check and engines (5742–5749), so a refused gender hint or an engine failure still consumed a guest unit.

### 5.3 Engine ladder and response headers

The response is **one complete file, not streamed**: `Content-Length` is set and the whole buffer is written (`res.end(buf)`). `Cache-Control: no-store` on every success. Custom headers name the engine so a client can log which voice answered.

| Order | Condition | Engine | `Content-Type` | `X-TTS-Engine` | `X-TTS-Voice` | `X-TTS-Gender` | Line |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `lang === "ar"` and `TTS_PRIMARY !== "openai"` (default `"gemini"`, 5432) | Gemini expressive TTS `GEMINI_TTS_MODEL` (default `gemini-2.5-flash-preview-tts`, 5599), voice `GEMINI_TTS_VOICE` (default `Sadaltager`; a female name in env is refused, 5606–5616), acting direction `geminiTtsStyle(lang)` (5633), 40-s timeout, up to 6 pool keys, **40-entry in-memory cache** keyed `sha1(voice|lang|text)` (5618–5622) | `audio/wav` (PCM16 mono wrapped by `pcmToWav`, rate from the reply's `rate=` mime param, default 24 000) | `gemini` | `Sadaltager` | `male` | 5766–5773 |
| 2 | always | OpenAI `OPENAI_TTS_MODEL` (default `gpt-4o-mini-tts`, 5433) voice `OPENAI_TTS_VOICE` (default `onyx`, 5434), `response_format: "mp3"`, an Arabic/English `instructions` string, input sliced to 4 000 (already ≤ 1 400) | `audio/mpeg` | `openai` | `onyx` | `male` | 5776–5783 |
| 3 | always | Microsoft Edge neural (`edgeSynthesize`, 5567): keyless raw WebSocket to `speech.platform.bing.com`, `audio-24khz-48kbitrate-mono-mp3`, text split into ≤ 1 600-char sentence chunks, **max 14 chunks** (`ttsChunks`, 5682–5701), rate `+12%` (`+7%` for English), circuit-breaker 60 s after two failures | `audio/mpeg` | `edge` | the Edge voice name | `male` | 5787–5793 |
| 2b | `lang !== "ar"` (Arabic already tried Gemini at 1) | Gemini expressive TTS again | `audio/wav` | `gemini` | `Sadaltager` | `male` | 5799–5806 |
| 4 | `TTS_ALLOW_FEMALE_FALLBACK` truthy only | Google Translate TTS, 190-char chunks concatenated | `audio/mpeg` | `google` | *(absent)* | `female` | 5827–5847 |

Engine circuit breakers (why the same text can come back as WAV one minute and MP3 the next): Gemini TTS rests the whole engine for **120 s** when the last failing key answered 429, else **45 s** (5678); a network error or 40-s timeout marks that key limited and moves to the next (5666); Edge is skipped for **60 s** after one chunk fails twice in a row (5582). None of this is visible to the client except through `X-TTS-Engine` and the content type.

So a native client must be ready to decode **both WAV and MP3** from the same endpoint (`AVAudioPlayer` handles both — hand it the bytes, or sniff `RIFF` vs an MP3 sync/`ID3` header if you route by type; never assume the type from the previous request), and must treat `503` as "no server voice right now → device voice".

### 5.4 Client-side rules the web enforces (copy them)

- Chunk long answers **client-side at ≤ 1 300 chars, never mid-sentence**, splitting on `.!?` **and** `؟ ، ؛` and newlines (`readAloudChunks`, SKILL speech-and-tts §8) — the server would silently truncate at 1 400 and the 1 300 headroom covers its whitespace collapsing. A single over-long sentence is cut on whitespace locally.
- One request per chunk; cache blobs by `lang + "\0" + text` so re-listening is free (app.js:24164–24167).
- Retry policy (`readAloudFetch`, app.js:24166–24200): network failure or 5xx → wait 500 ms, retry once; **429 → hand the *rest* of the chunks to the device voice from the failed index** (toast `listenLocal`), never restart from chunk 0; any other 4xx → give up on the server voice for this reading (no retry).
- Reject a "success" whose body is ≤ 64 bytes or whose content type is JSON/text (app.js:24183).
- The call screen sends `{ text, lang, gender: "male" }` with `lang` from `detectLang(text)` (`"ar"` or `"en"`), and falls back to the device voice when the fetch fails or playback is refused (app.js:49688–49740).

---

## 6. Error code → what the UI says

All strings verbatim from `STR.ar` / `STR.en` in app.js (line numbers given). The shell language decides which table; the rule that the toast names the actor and the fix stays (SKILL speech-and-tts §10).

| Situation | Arabic | English | app.js |
| --- | --- | --- | --- |
| `/api/live/token` → 403 `signin_required` | المكالمة الصوتية الذكية تحتاج تسجيل دخول — بدونها تشتغل بالوضع البسيط | The AI voice call needs an account — without one it runs in basic mode | 49179–49183 (inline, not in STR) |
| Guest hard cap fired (`tok.guest`), `secs = round(maxMs/1000)` | عذرًا، بدون حساب المكالمة محدودة بـ {secs} ثانية — سجّل لتكمل بلا حدود | Sorry — without an account a call is limited to {secs} seconds. Sign in to keep talking. | 49505–49509 |
| Any live failure (signed-in users only; guests see nothing beyond the sign-in line) | *(English console-style toast)* `Live: <reason> — <detail>` | same | 48355–48369 |
| Landed on Gemini while an OpenAI key exists | — | Live: running on Gemini — set OPENAI_API_KEY to use OpenAI Realtime | 48380–48393 |
| Call voice changed | صوت المكالمة: {name} — يُطبَّق على المكالمة القادمة | Call voice: {name} — applies to the next call | 48310 |
| Call phases | callConnecting: جارٍ الاتصال… · callListening: أستمع… تكلّم الآن · callThinking: فِراس يفكّر… · callSpeaking: فِراس يتحدّث… · callMuted: الميكروفون مكتوم · callHello: مرحبًا، معك فِراس. تفضّل، أنا أسمعك. | Connecting… · Listening… speak now · Firas is thinking… · Firas is speaking… · Microphone muted · Hi, Firas here. Go ahead, I'm listening. | 243–251 / 1365–1373 |
| Mic consent / errors | callConsentText: للتحدث في المكالمة، اسمح باستخدام الميكروفون · callConsentBtn: السماح بالميكروفون والبدء · callError: تعذّرت المكالمة — تأكد من إذن الميكروفون. · callSorry: عذرًا، لم أستطع المتابعة. حاول مرة أخرى. · callUnsupported: المكالمة الصوتية غير مدعومة على هذا المتصفح. | To talk on the call, allow microphone access · Allow microphone & start · Call failed — check microphone permission. · Sorry, I couldn't continue. Please try again. · Voice calls aren't supported in this browser. | 252–256 / 1374–1378 |
| Dictation states | micListening: جارٍ الاستماع… تكلّم الآن · micTranscribing: جارٍ تحويل كلامك… | Listening… speak now · Transcribing your speech… | 229–230 / 1351–1352 |
| Mic permission denied | micDenied: اسمح بالوصول إلى المايكروفون من إعدادات المتصفح ثم أعد المحاولة. | Allow microphone access in your browser settings, then try again. | 231 / 1353 |
| Recording unsupported | micUnsupported: التسجيل الصوتي غير مدعوم على هذا المتصفح. | Voice recording is not supported in this browser. | 232 / 1354 |
| Take < 700 ms or < 1 500 bytes | micTooShort: التسجيل قصير جدًا — تكلّم ثم اضغط ✓. | Recording too short — speak, then press ✓. | 233 / 1355 |
| `/api/transcribe` network / 4xx / 5xx (other than 503) | micFail: تعذّر تحويل الصوت — حاول مرة أخرى. | Couldn't transcribe the audio — please try again. | 234 / 1356 |
| `/api/transcribe` 200 with empty `text` | micEmpty: لم أسمع كلامًا واضحًا — حاول مجددًا. | I didn't catch any clear speech — try again. | 235 / 1357 |
| `/api/tts` 429 (rate or quota) mid-reading | listenLocal: انتهت حصة الصوت — يكمّل بصوت الجهاز | Voice quota spent — finishing on your device | 617 / 1718 |
| Device has no TTS voice at all | listenNoVoice: جهازك ما عنده صوت للقراءة — ثبّت صوتًا من إعدادات النظام | This device has no speech voice installed — add one in your system settings | 625 / 1726 |
| Device has no Arabic TTS voice | listenNoVoiceAr: جهازك ما عنده صوت عربي — ثبّته من إعدادات اللغة بالنظام، وبعدها يشتغل | This device has no Arabic voice — add one in your system language settings and it will work | 626 / 1727 |
| Listen pressed during a call | listenBusy: أنهِ المكالمة أول | End the call first | SKILL speech-and-tts §10 |

Server error strings that have **no dedicated UI copy** and should map to the generic lines above: `no_engine`, `mint_failed`, `unreachable` (live → treat as "the server would not mint a token", run the fallback ladder), `no stt engine` (503 → device dictation), `stt engine unavailable` (502 → `micFail`), `tts unavailable` (503/502 → device voice), `bad audio`/`no audio` (client bug → `micFail`), `only a male voice is available` (client bug — never send a non-male `gender`), `internal error` (500 → generic).

Note the existing Swift `LiveVoiceTokenClient.safeError` maps an error code `"quota"` that the server never sends; the real quota strings are `"daily quota reached"` and `"guest daily limit reached"` (with a `quota` object) — match on the presence of `quota` in the body.

---

## 7. Rules a native client must keep (from the two skills + the shipped client)

### 7.1 The ladder, and the rule against silent downgrades (SKILL realtime §0–§1)

Three engines, strictly ordered: **OpenAI Realtime → Gemini Live → "three-hop"** (record → `/api/transcribe` → `/api/chat` → `/api/tts`/device voice). Every rung is reachable in production. Landing on rung 3 must be *announced* (toast) — a silent downgrade is the bug. The credential (`OPENAI_API_KEY`, Gemini keys) never leaves the server; the client only ever holds an `ek_…` secret or an `auth_tokens/…` name.

Dispatch on `tok.provider === "openai"`; a **missing** `provider` means "not that engine" (never crash on absence). After a failed OpenAI attempt, mint again with `prefer: "gemini"` (free inside 90 s) and continue down the ladder (app.js:49193–49204). Every exit names its reason (`liveFail`) and the winning engine names itself (`liveEngine`) — keep a `__firasLive`-style diagnostic record `{ engine, reason, detail, model, at }`.

### 7.2 Charge once per call (SKILL realtime §2) — see §3.5. Never mint twice for one call without `prefer: "gemini"` on the second leg.

### 7.3 Two clocks, both real (SKILL realtime §7; app.js:49102–49109, 49483–49490)

- **Hard cap**: `maxMs = max(60000, tok.maxMs || 600000)`; fire at `maxMs − 1500` so the client hangs up *before* the upstream does and can explain. For a **guest** (`tok.guest`), show the cap toast (§6) **before** closing the screen (`liveEndOnCap`, app.js:49502–49512). On OpenAI this timer is the *only* ceiling.
- **Idle hang-up**: `LIVE_IDLE_HANGUP_MS = 45000` (app.js:48184), checked every 5 s against `lastVoiceAt`, which is bumped only by session events (`speech_started`, `speech_stopped`, `response.done` on OpenAI; `setupComplete`, and any mic frame with RMS > 0.02 on Gemini). A caller who is genuinely talking is never cut off.
- **Start window**: open the session within `startWithinMs` (60 s). Gemini enforces it; OpenAI's secret lasts 600 s but treat 60 s as the contract.
- Upstream quota refusal on Gemini (close **1011** "You exceeded your current quota" or **1008** "denied access") → remember in memory for `LIVE_QUOTA_COOLDOWN_MS = 10 min` (app.js:48246–48248) and skip the Gemini rung (not the OpenAI rung — the check sits *below* the OpenAI dispatch, app.js:49206–49209). Exception: if the setup carried `tools:[{googleSearch:{}}]`, the same 1011 means "no search entitlement on this model" → persist the model name in a per-model list (`firas_live_no_search`, keep last 10) and reconnect **without** the tool (app.js:49424–49431, 49449–49452).

### 7.4 Echo and barge-in are different problems on the two engines (SKILL realtime §4–§5)

**OpenAI (server VAD)**: do not resample, do not queue by hand, do not run an RMS detector. Two shipped modes, chosen by `LIVE_BARGE_IN` (default **false**, `localStorage["firas_barge_in"]`, app.js:48895–48905):

- *Guard on, barge-in off (default)*: while Firas speaks, the microphone is switched off at the source — `micTrack.enabled = false` on `response.created` and on every audio delta (`liveMicGate(false)`, idempotent while closed), reopened **280 ms** after `response.done` (`liveMicReopenSoon`, app.js:48926–48929), with a **20-s safety timer** that reopens it even if `response.done` never arrives (app.js:48907–48923). Mute always wins: every write is `enabled = open && !muted`. A call you cannot interrupt is preferable to one that answers its own voice.
- *Barge-in on*: rely on AEC (`voiceChat` session mode on iOS) and `interrupt_response: true`; verify AEC was actually granted and log it.

**Gemini (raw PCM WebSocket)**: everything is yours — resample 48 kHz → 16 kHz with **linear interpolation** (`liveTo16k`, app.js:48412–48424; never nearest-sample), batch **100 ms** frames (`LIVE_FRAME_MS`), and run the echo guard `liveBargeDecision(rms, armed, echoFloor, loudRun)` (app.js:48479–48503) with `LIVE_BARGE_RMS = 0.055`, `LIVE_BARGE_FRAMES = 3`, `LIVE_BARGE_OVER_ECHO = 3.0`, `LIVE_ECHO_HANGOVER_MS = 350`:

```
if !armed            → send; loudRun=0; echoFloor=0
if echoFloor <= 0    → do NOT send; echoFloor = max(rms, 1e-4)        // seed from the leak
threshold = max(0.055, echoFloor * 3.0); loud = rms >= threshold
run = loud ? loudRun+1 : 0
send = run >= 3; echoFloor = loud ? echoFloor : echoFloor*0.7 + rms*0.3   // frozen while a candidate runs
```
`armed` = playback scheduled **or** turn open (`liveIsSpeaking() || turnOpen`), extended 350 ms past the last audio. A frame that is not sent is replaced by **silence of the same length, not dropped** (the far-side detector needs a continuous stream, app.js:49374–49377). On `serverContent.interrupted` flush playback **and** zero `echoFloor`/`speakingUntil`, or the caller's first words are swallowed (`liveFlushPlayback`, app.js:48526–48534). Playback is scheduled against a **forward-only cursor 0.2 s ahead** (`LIVE_JITTER_LEAD`, `livePlayChunk`, app.js:48442–48470) — on iOS `AVAudioPlayerNode.scheduleBuffer` queuing gives the same property; never start a separate player per packet. "Listening" is announced only when the turn is closed **and** the schedule has drained, after a 160-ms debounce (`liveMaybeListening`, app.js:48515–48524).

### 7.5 Teardown checklist (SKILL realtime §6; `liveTeardown` app.js:48536–48556)

Run it first in `callEnd`, make it re-entrant, wrap each step in its own catch, null every handle afterwards, set `ending = true` first so `onclose`/state-change handlers do not re-enter:

1. `ending = true`; cancel idle + hard timers.
2. Flush playback (stop every scheduled source, reset cursor, zero echo state).
3. Disconnect capture nodes; **stop every microphone track/tap** (the only thing that turns off the recording indicator — closing the peer/socket does not).
4. Close capture and playback audio contexts / stop `AVAudioEngine`; deactivate the `AVAudioSession` with `.notifyOthersOnDeactivation`.
5. Close the data channel, the peer connection, the WebSocket; detach the remote audio.
6. Null all handles; `open = false`; clear the playback queue.
7. A **failed attempt must tear down before falling back**, or the next rung opens a second microphone while the first is still held.
8. Wait for the channel, not for the fetch: a session is "up" only when audio can flow both ways (data channel open / `setupComplete` received), with a 12-s (OpenAI) / 10-s (Gemini) timeout and a settle latch so timeout and state-change cannot both resolve.
9. Mid-call drop (connection state `failed|closed|disconnected`, socket close) → end the call and the UI together.

### 7.6 Two engines must never answer one question (SKILL realtime §11)

While a live session owns the call (`call.live`), mute, app-background/foreground, orb tap and the three-hop's own `callProceed` must all early-return before starting any recorder/recogniser/TTS. Muting on OpenAI must disable the mic track itself; on Gemini the capture loop reads the flag every frame. Muting must not rewrite the phase.

### 7.7 iOS audio (SKILL realtime §8, speech-and-tts §6; app.js:48116–48143)

The web unlocks *one* audio element inside the call tap (44-byte silent WAV, attached to the DOM so AEC sees it) and reuses it for every engine. The native equivalents: configure `AVAudioSession` (`.playAndRecord`, mode `.voiceChat` for AEC, `.defaultToSpeaker`, `.allowBluetoothHFP`) and start the engine **inside the user's tap**, before any `await` on the network; request mic permission in its own gesture (`AVAudioApplication.requestRecordPermission`), and forget a remembered grant when capture later fails so the consent screen comes back. Never put a second consumer on the remote track; drive the orb from a level you already have (RTP stats on WebRTC; the PCM you are scheduling on WebSocket, 20 Hz is enough, `sqrt` before display).

### 7.8 One voice at a time, chunking, and the 429 hand-off (SKILL speech-and-tts §8–§9)

A monotonic `token` claimed synchronously before the first `await`, re-checked after every await; a stale continuation is a silent no-op. Reading aloud is refused while a call is active (`listenBusy`). Chunk at ≤ 1 300 chars on `.!?؟،؛\n`; on 429 continue on the device voice **from the failed chunk**; pick the device voice **before** building the utterance and refuse with `listenNoVoiceAr`/`listenNoVoice` when the language has none (strict for reading, lenient for a call).

### 7.9 The Gemini Live WebSocket protocol as shipped (VERIFIED-FROM-CODE, app.js:49239–49441; mirrored by `ios/FirasAI/Features/Chat/LiveVoiceController.swift`)

- URL: `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained?access_token=<tok.token>` (app.js:48180–48181, 49243). No headers.
- First frame, text JSON (app.js:49258–49305):

```json
{ "setup": {
    "model": "models/<tok.model>",
    "generationConfig": {
      "responseModalities": ["AUDIO"],
      "speechConfig": { "voiceConfig": { "prebuiltVoiceConfig": { "voiceName": "Charon" } } }
    },
    "tools": [ { "googleSearch": {} } ],
    "realtimeInputConfig": { "automaticActivityDetection": {
      "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
      "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
      "prefixPaddingMs": 300, "silenceDurationMs": 800 } },
    "systemInstruction": { "parts": [ { "text": "<see below>" } ] }
} }
```
  `tools` is omitted when the model is in the no-search list; on a "reduced" retry (setup refused, close within 8 s, code not 1000/1008) `speechConfig`, `tools` and `realtimeInputConfig` are all dropped (app.js:49266–49287, 49456–49463). Voice default `"Charon"`; allowed male list `LIVE_VOICES` (app.js:48222–48226): Charon, Sadaltager, Achird, Umbriel, Algieba, Iapetus, Schedar, Puck, Orus, Enceladus, Fenrir, Alnilam, Rasalgethi, Algenib, Zubenelgenubi, Sadachbia.
- The Gemini system instruction is **client-supplied** and does **not** include `IDENTITY_BLOCK` (only the OpenAI mint carries it). Verbatim (app.js:49288–49305), where `<LANG>` is `Arabic` when the UI is Arabic, else `the user language`:

> You are Firas, on a live voice call. SPEAK, do not lecture: short conversational turns, the way a person actually talks on the phone. Never read markdown, never say asterisk or hash, never spell out punctuation, never list numbered points aloud unless asked. Answer in the SAME language and the SAME dialect the caller uses — if they speak Iraqi Arabic, answer in Iraqi Arabic, not Modern Standard. The interface language is <LANG>, but the CALLER decides. If you are interrupted, stop immediately and listen. YOU CAN SEARCH THE WEB. When a question needs current information — news, prices, scores, what happened today, anything you are unsure of — first say WHAT you are about to look up, in one short sentence, in the caller's own language and dialect. NAME THE SUBJECT; do not just promise to check. In Iraqi Arabic something like لحظة، أدوّرلك على سعر الدولار اليوم, in English something like "one second, let me look up today's dollar rate". THE ANNOUNCEMENT AND THE ANSWER ARE ONE SINGLE TURN — never two. Do NOT stop speaking the moment you have announced it, and do NOT hand the turn back to the caller to wait: search, then keep going in the SAME turn and tell them what you found. The caller must NEVER have to prompt you, ask what you found, or say anything at all between your announcement and your answer. If you are about to end a turn having promised to look something up but not yet said what you found, do not end it — give the answer now. Never go silent while searching — a silent line sounds like a dropped call. Say the answer, not the URLs.

- Wait for `{ "setupComplete": {} }` (10-s timeout) **before** sending audio; audio sent earlier is discarded.
- Audio up, every 100 ms: `{ "realtimeInput": { "audio": { "mimeType": "audio/pcm;rate=16000", "data": "<base64 PCM16 LE mono>" } } }` (app.js:49379–49384). Send silence frames rather than nothing when the guard suppresses a frame.
- Audio down: `{ "serverContent": { "modelTurn": { "parts": [ { "inlineData": { "mimeType": "audio/pcm;rate=24000", "data": "<base64>" } } ] } } }` — `LIVE_OUT_RATE = 24000` (app.js:48183). `{ "serverContent": { "interrupted": true } }` = barge-in: flush now. `turnComplete` / `generationComplete` = model stopped generating (audio may still be queued). `{ "goAway": … }` = server is about to close → end the call.
- Close codes: 1011/1008 as in §7.3; the close **reason** is the only place Google explains a refused setup — log it.

---

## 8. OpenAI Realtime GA — WebSocket cheat-sheet for a native client holding `tok.token` (`ek_…`)

The shipped web client uses **WebRTC** (`POST https://api.openai.com/v1/realtime/calls?model=<tok.model>` with `Authorization: Bearer <ek>` and `Content-Type: application/sdp`, body = SDP offer, answer = SDP text starting `v=0`, events on a data channel named `oai-events` — VERIFIED-FROM-CODE app.js:49035–49058). A native client without a WebRTC dependency uses the WebSocket transport with the **same secret and the same session** (the mint's `session` config is attached to the secret). Items below are tagged individually.

### 8.1 Connect

- **FROM-KNOWLEDGE** URL: `wss://api.openai.com/v1/realtime?model=<tok.model>` (the `model` query is optional when the secret already carries a session; if present it must match `tok.model`).
- **FROM-KNOWLEDGE** Headers: `Authorization: Bearer <tok.token>` only. **Do not send `OpenAI-Beta: realtime=v1`**: on the GA endpoint that header selects the *beta* interface (`response.audio.delta`, flat `session.modalities` / `input_audio_format`), which is precisely the event-name drift the web client papers over by substring-matching (VERIFIED app.js:48950–48953). Without it you get the GA vocabulary in §8.3. Browser-style subprotocols (`realtime`, `openai-insecure-api-key.*`, `openai-beta.realtime-v1`) exist only because a browser cannot set headers; `URLSessionWebSocketTask` can, so skip them.
- **FROM-KNOWLEDGE** First server event is `session.created` carrying the resolved session (`session.model`, `session.instructions`, `session.audio.output.voice`, `session.audio.input.turn_detection`). **Verify here** that the server-side persona and `semantic_vad` came through; if `instructions` is empty the secret was minted without a session and the client must not proceed (the persona is server-owned).
- **VERIFIED-FROM-CODE** Secret TTL 600 s from creation; one session.
- **VERIFIED-FROM-CODE** The mint reply is read as `j.value` or `j.client_secret.value` (6208). FROM-KNOWLEDGE: the GA shape is `{ "value": "ek_…", "expires_at": <unix seconds>, "session": { …the resolved session… } }` — the server forwards only `value`, so the client never sees `expires_at`; treat `startWithinMs` (60 s) as the dial window.
- **FROM-KNOWLEDGE** A Realtime session has an upstream maximum duration of about **60 minutes**; the client's 10-min hard cap (§7.3) is well inside it, so the cap timer — not the upstream — is what ends a member call.
- **FROM-KNOWLEDGE** Keep-alive: while the mic gate is closed (§8.4 item 3) nothing flows upstream for up to 20 s. Either keep appending silence frames or call `URLSessionWebSocketTask.sendPing` every ~20 s; a NAT that drops the idle flow shows up as a close with no `error` event.

### 8.2 Client → server events (JSON text frames)

| Event | Shape | Tag / note |
| --- | --- | --- |
| `session.update` | `{ "type": "session.update", "session": { "type": "realtime", … } }` | FROM-KNOWLEDGE. GA requires `session.type: "realtime"`. **Do not** send `instructions`, `audio.output.voice`, or `audio.input.turn_detection` — they are minted server-side (VERIFIED §3.7). Optional: pin formats explicitly, `"audio": { "input": { "format": { "type": "audio/pcm", "rate": 24000 } }, "output": { "format": { "type": "audio/pcm", "rate": 24000 } } }`. |
| `input_audio_buffer.append` | `{ "type": "input_audio_buffer.append", "audio": "<base64>" }` | FROM-KNOWLEDGE. Base64 of **PCM16 little-endian mono at 24 000 Hz** (the API default when no `format` is set — the mint sets none, VERIFIED). Send ~50–100 ms per frame; max ~15 MB per event. |
| `input_audio_buffer.commit` | `{ "type": "input_audio_buffer.commit" }` | FROM-KNOWLEDGE. **Not needed** with server VAD (`semantic_vad` commits and creates the response itself, VERIFIED `create_response: true`). |
| `input_audio_buffer.clear` | `{ "type": "input_audio_buffer.clear" }` | FROM-KNOWLEDGE. Drops un-committed audio (e.g. after a long mute). |
| `response.create` | `{ "type": "response.create", "response": { "instructions": "Greet the caller warmly in ONE short sentence in Arabic, then stop and listen." } }` | VERIFIED-FROM-CODE (app.js:49089–49096): sent once the channel is open so Firas speaks first; `Arabic`/`English` by UI language. |
| `response.cancel` | `{ "type": "response.cancel" }` (optionally `"response_id"`) | FROM-KNOWLEDGE. Manual interrupt (orb tap). With `interrupt_response: true` the server cancels by itself on detected speech, so this is only for explicit taps. |
| `conversation.item.truncate` | `{ "type": "conversation.item.truncate", "item_id": "<assistant item>", "content_index": 0, "audio_end_ms": <ms actually played> }` | FROM-KNOWLEDGE. After a barge-in, tells the model how much of its reply the caller heard, so the transcript does not contain unheard text. WebRTC does this implicitly; WebSocket clients must do it themselves. |
| `output_audio_buffer.clear` | — | FROM-KNOWLEDGE. **WebRTC only**; on WebSocket you flush your own playback queue. |

### 8.3 Server → client events

| Event | Payload of interest | Tag / what to do |
| --- | --- | --- |
| `session.created`, `session.updated` | `session` | FROM-KNOWLEDGE. Verify config (8.1). |
| `input_audio_buffer.speech_started` | `audio_start_ms`, `item_id` | VERIFIED-FROM-CODE handled (app.js:48938–48943): bump `lastVoiceAt`, count an interruption, phase → listening. **Barge-in on WebSocket**: stop and flush local playback *immediately* on this event (FROM-KNOWLEDGE: the server cancels the in-flight response on its own when `interrupt_response` is true; already-delivered audio is your problem). |
| `input_audio_buffer.speech_stopped` | `audio_end_ms`, `item_id` | VERIFIED handled (app.js:48944–48948): `lastVoiceAt`, phase → thinking. |
| `input_audio_buffer.committed` | `item_id`, `previous_item_id` | FROM-KNOWLEDGE. Informational. |
| `input_audio_buffer.cleared` | — | FROM-KNOWLEDGE. Ack of `input_audio_buffer.clear`. |
| `input_audio_buffer.timeout_triggered` | `audio_start_ms`, `audio_end_ms`, `item_id` | FROM-KNOWLEDGE. Only with `server_vad` + `idle_timeout_ms`; **never** on this session (`semantic_vad`, VERIFIED 6195). Ignore if seen. |
| `conversation.item.input_audio_transcription.delta` / `.completed` / `.failed` | `item_id`, `transcript` (completed), `delta` | FROM-KNOWLEDGE. Caller caption (`gpt-4o-mini-transcribe` was requested at mint, VERIFIED 6190). Optional to display. |
| `conversation.item.created` / `conversation.item.added` / `conversation.item.done` | `item` | FROM-KNOWLEDGE. GA emits `added`/`done`; beta emitted `created`. Use `item.id` of the assistant item for `truncate`. |
| `conversation.item.retrieved` / `.truncated` / `.deleted` | `item` / `item_id`, `content_index`, `audio_end_ms` | FROM-KNOWLEDGE. Acks of `retrieve` / `truncate` / `delete`. |
| `response.created` | `response.id` | VERIFIED handled (app.js:48949): phase → thinking; close the mic gate when barge-in is off. |
| `response.output_item.added`, `response.content_part.added` | ids | FROM-KNOWLEDGE. Informational. |
| **`response.output_audio.delta`** (GA) / `response.audio.delta` (beta) | `delta` = base64 PCM16 24 kHz mono, plus `response_id`, `item_id`, `output_index`, `content_index` | VERIFIED-FROM-CODE that both names exist and the client matches the substring `"audio.delta"` (app.js:48950–48957). Decode, append to the forward-only playback queue, phase → speaking, keep the mic gate closed. |
| `response.output_audio.done` / `response.audio.done` | — | FROM-KNOWLEDGE. Audio for this item finished generating (queue may still be playing). |
| `response.output_audio_transcript.delta` / `.done` (GA) / `response.audio_transcript.*` (beta) | `delta` / `transcript` | FROM-KNOWLEDGE. Firas's own words as text. |
| `response.output_text.delta` / `.done` | `delta` / `text` | FROM-KNOWLEDGE. Not expected — the mint sets no `output_modalities`, so the session defaults to audio (VERIFIED nothing is set, 6176–6198) — but log it if it appears. |
| `response.function_call_arguments.*`, `response.mcp_call*` | — | FROM-KNOWLEDGE. Never: the session has no `tools` (VERIFIED §3.7). |
| `output_audio_buffer.started` / `.stopped` / `.cleared` | `response_id` | FROM-KNOWLEDGE. **WebRTC only** — a WebSocket client never sees them; their job (knowing when playback actually ended) is done by your own `AVAudioPlayerNode` completion handlers. |
| `response.done` | `response.status` (`completed` / `cancelled` / `failed` / `incomplete`), `response.usage` | VERIFIED handled (app.js:48958–48963): `lastVoiceAt`, phase → listening, reopen the mic gate after 280 ms. `status: "cancelled"` is what a server-side barge-in looks like. |
| `rate_limits.updated` | `rate_limits[]` | FROM-KNOWLEDGE. Informational. |
| `error` | `error: { type, code, message, param, event_id }` | VERIFIED handled (app.js:48965–48967): log `error` (first 300 chars). FROM-KNOWLEDGE: a fatal error is usually followed by a socket close. |

### 8.4 Session semantics the native client must reproduce (mapping the shipped WebRTC behaviour onto WebSocket)

1. **Audio in**: capture at the hardware rate, resample to 24 kHz PCM16 mono with linear interpolation, base64, `input_audio_buffer.append` every ~100 ms (FROM-KNOWLEDGE format; VERIFIED batching cadence on the Gemini path). Do not commit; do not create responses except the greeting.
2. **Audio out**: `response.output_audio.delta` → 24 kHz PCM16 mono → append to `AVAudioPlayerNode` (queue, never "play on arrival"). Playback queue is the equivalent of the WebRTC jitter buffer the web relies on.
3. **Mic gate (default)**: from `response.created` until 280 ms after `response.done`, do not append caller audio (append silence frames, or nothing — FROM-KNOWLEDGE: the server VAD tolerates gaps; sending silence keeps timing simplest). Re-open on a 20-s safety timer regardless. Mute overrides everything.
4. **Barge-in (if enabled)**: on `input_audio_buffer.speech_started` while audio is queued → stop the player, drop the queue, send `conversation.item.truncate` with the ms actually played; optionally `response.cancel`. Then re-arm.
5. **Two clocks**: hard `maxMs − 1500` (client is the only ceiling on OpenAI — VERIFIED §3.3) and idle 45 s from `lastVoiceAt`.
6. **Teardown**: §7.5, including `socket.cancel(with: .normalClosure)` and stopping the input tap.
7. **Diagnostics**: log every `type` you see on the first call (SKILL realtime §14 — the vocabulary has been renamed once already), and record `{ engine: "openai", model: tok.model }`.
8. **Transport alternative**: if a WebRTC library is acceptable, the exact shipped flow is: `pc.addTrack(mic)`, `createDataChannel("oai-events")`, `createOffer`, POST the SDP to `/v1/realtime/calls?model=…` with the `ek_` bearer, `setRemoteDescription(answer)`, wait for the data channel to open (12 s), then everything above except the audio plumbing (VERIFIED-FROM-CODE app.js:49035–49077).

### 8.5 Literal frames and the minimal loop (FROM-KNOWLEDGE unless a line is tagged VERIFIED)

Connect → the first frame from the server:

```json
{ "type": "session.created", "event_id": "event_…",
  "session": { "object": "realtime.session", "type": "realtime", "id": "sess_…",
    "model": "gpt-realtime-2.1",
    "instructions": "You are Firas, on a live voice call. SPEAK, do not lecture: …",
    "output_modalities": ["audio"],
    "audio": {
      "input": { "format": { "type": "audio/pcm", "rate": 24000 },
                 "transcription": { "model": "gpt-4o-mini-transcribe" },
                 "noise_reduction": { "type": "near_field" },
                 "turn_detection": { "type": "semantic_vad", "eagerness": "auto", "create_response": true, "interrupt_response": true } },
      "output": { "format": { "type": "audio/pcm", "rate": 24000 }, "voice": "cedar", "speed": 1.0 } },
    "expires_at": 1756800000 } }
```

Assert on it: `session.instructions` begins with `You are Firas` and `audio.input.turn_detection.type == "semantic_vad"` (the values the mint sets, VERIFIED §3.7). If either is missing the secret did not carry the session — tear down and fall back; never `session.update` the persona in from the device.

Greeting, sent once the socket is up (VERIFIED-FROM-CODE app.js:49089–49096; `Arabic` ↔ `English` by UI language):

```json
{ "type": "response.create", "response": { "instructions": "Greet the caller warmly in ONE short sentence in Arabic, then stop and listen." } }
```

Caller audio, every ~100 ms (2 400 Int16LE samples = 4 800 bytes before base64):

```json
{ "type": "input_audio_buffer.append", "audio": "<base64>" }
```

A turn, as the server sees it:

```json
{ "type": "input_audio_buffer.speech_started", "event_id": "event_…", "audio_start_ms": 1230, "item_id": "item_…" }
{ "type": "input_audio_buffer.speech_stopped", "event_id": "event_…", "audio_end_ms": 3410, "item_id": "item_…" }
{ "type": "input_audio_buffer.committed", "event_id": "event_…", "previous_item_id": "item_…", "item_id": "item_…" }
{ "type": "conversation.item.input_audio_transcription.completed", "event_id": "event_…", "item_id": "item_…", "content_index": 0, "transcript": "شلونك فراس، شنو سعر الدولار اليوم؟", "usage": { "type": "tokens", "total_tokens": 31 } }
```

The reply:

```json
{ "type": "response.created", "event_id": "event_…", "response": { "object": "realtime.response", "id": "resp_…", "status": "in_progress", "output": [] } }
{ "type": "response.output_item.added", "event_id": "event_…", "response_id": "resp_…", "output_index": 0, "item": { "id": "item_…", "object": "realtime.item", "type": "message", "role": "assistant", "status": "in_progress", "content": [] } }
{ "type": "response.output_audio.delta", "event_id": "event_…", "response_id": "resp_…", "item_id": "item_…", "output_index": 0, "content_index": 0, "delta": "<base64 PCM16 24 kHz mono>" }
{ "type": "response.output_audio_transcript.delta", "event_id": "event_…", "response_id": "resp_…", "item_id": "item_…", "output_index": 0, "content_index": 0, "delta": "هلا، " }
{ "type": "response.output_audio.done", "event_id": "event_…", "response_id": "resp_…", "item_id": "item_…", "output_index": 0, "content_index": 0 }
{ "type": "response.output_audio_transcript.done", "event_id": "event_…", "response_id": "resp_…", "item_id": "item_…", "output_index": 0, "content_index": 0, "transcript": "هلا، …" }
{ "type": "response.done", "event_id": "event_…", "response": { "object": "realtime.response", "id": "resp_…", "status": "completed", "output": [ { "id": "item_…", "type": "message", "role": "assistant", "content": [ { "type": "output_audio", "transcript": "هلا، …" } ] } ], "usage": { "total_tokens": 812, "input_tokens": 600, "output_tokens": 212 } } }
```

`response.done.response.status` is `"cancelled"` after a server-side barge-in and `"failed"` (with `status_details.error`) when the model refused. Treat every status the same for the mic gate — reopen 280 ms later (VERIFIED app.js:48958–48962 keys on the event, not the status). The gate must never depend on the status, or a refused response leaves the microphone shut until the 20-s safety timer.

Barge-in on WebSocket (only when the barge-in setting is on; the default gate makes it unreachable):

```text
←  { "type": "input_audio_buffer.speech_started", "audio_start_ms": 9800, "item_id": "item_…" }
   stop the AVAudioPlayerNode, drop the queue, playedMs = samplesActuallyRendered / 24
→  { "type": "conversation.item.truncate", "item_id": "<assistant item_id from output_item.added>", "content_index": 0, "audio_end_ms": <playedMs> }
←  { "type": "conversation.item.truncated", "item_id": "…", "content_index": 0, "audio_end_ms": <playedMs> }
←  { "type": "response.done", "response": { "status": "cancelled", … } }
```

`response.cancel` is unnecessary in that sequence — `interrupt_response: true` already cancelled it (VERIFIED the flag is set, 6195). Send `{ "type": "response.cancel" }` only for an explicit orb tap while nothing was detected.

An error:

```json
{ "type": "error", "event_id": "event_…", "error": { "type": "invalid_request_error", "code": "invalid_value", "message": "…", "param": "session.audio.output.voice", "event_id": "<the client event_id that caused it>" } }
```

Log `error.code` + `error.message` (first 300 chars, VERIFIED app.js:48965–48967). Do not tear down on `error` alone — a session-level fault is followed by a socket close; run the teardown checklist (§7.5) from the close handler, with `ending` checked first.

Minimal loop, in order: open the socket → wait for `session.created` with a 12-s timeout and a settle latch (the WebSocket equivalent of "wait for the data channel", SKILL realtime §6) → `liveEngine("openai")`, arm both clocks (§7.3) → send the greeting `response.create` → start the input tap → for every event bump `lastVoiceAt` on the four voice events (`speech_started`, `speech_stopped`, `response.done`, and — reasonable on WebSocket — every `output_audio.delta`) and run the phase machine of §8.3 → on hard cap / idle / socket close → teardown §7.5 and, if this was the dial attempt, mint again with `prefer: "gemini"` (§3.5).

---

## 9. The existing Swift `LiveVoiceController.swift` versus this contract

`ios/FirasAI/Features/Chat/LiveVoiceController.swift` (601 lines, Codex-written) is a Gemini-only implementation. Gaps a rewrite must close:

- It always sends `{ "prefer": "gemini", "voice": … }` (line 62) and **rejects any non-Gemini token** (line 77). It therefore never uses the primary engine, and every first mint is `prefer:"gemini"` — which the server honours (no OpenAI attempt) and charges normally (no earlier mint inside the grace window). A native client must mint **without** `prefer` first and dispatch on `provider`.
- `safeError` maps a `"quota"` code that does not exist (line 93); match on `body.quota` instead (§2.3), and handle the 400/500/502 strings in §6.
- Its setup omits `tools:[{googleSearch:{}}]` and the reduced-setup retry rung, and uses a shortened system instruction (line 178–183) instead of the verbatim one in §7.9 — the shipped call persona and the Iraqi search announcement rule are lost.
- No idle hang-up (45 s), no charge-once fallback leg, no quota cooldown on 1011/1008, no per-model no-search memory, no echo-guard/silence substitution (it relies on `.voiceChat` AEC + `interrupted`), no `goAway`-before-cap toast for guests (`tok.guest` is decoded but unused).
- Hard cap is `max(10_000, maxMs − 1500)` (line 140), matching the web's `− 1500` but with a lower floor than the web's `max(60000, …)`.
- `VoiceCallView.swift` only instantiates `LiveVoiceController` (line 27) and renders `LiveVoiceConnectionState` (204); it makes no API calls of its own, so the contract above lives entirely in the controller.
- Positive: cookie session handling, `.playAndRecord`/`.voiceChat`/`.defaultToSpeaker`/`.allowBluetoothHFP`, linear-interpolation resampling to 16 kHz, 24 kHz Int16 `AVAudioPlayerNode` queue, and a re-entrant `finish()` are all in the right shape.

---

## 10. Open questions (could not be settled from the code)

1. Whether OpenAI applies the minted `session` config on the **WebSocket** transport exactly as on WebRTC (the repo only ever exercised WebRTC). Confirm from the first `session.created` event.
2. The exact GA WebSocket URL for an `ek_` secret (is `?model=` optional when the secret already carries a session?) — §8.1 is FROM-KNOWLEDGE, as is the rule to omit the beta header. Settle both by logging the first `session.created` of one real call.
3. Whether `/api/transcribe` accepts AAC/M4A bytes labelled `audio/wav` (Gemini sniffs containers in practice but the server never promises it). Plan on encoding WAV or MP3 natively.
4. ~~`QUOTA_TZ_OFFSET_MINUTES` value~~ — **settled**: default 180 (UTC+3), env-overridable, server.mjs:3196; the reset formula is in §2.3.
5. Whether the owner wants the Gemini path to also carry `IDENTITY_BLOCK` (today only the OpenAI session gets it — a caller on the fallback engine can be told the upstream vendor's name).
