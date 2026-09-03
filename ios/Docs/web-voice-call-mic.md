# Web client spec — Voice call, dictation (mic) and Listen (TTS)

Source of truth: `server.mjs` (routes at `server.mjs:13794-13796`) and `app.js`. Every line number below is
`file:line` in the worktree at the time of writing. All Arabic strings are copied verbatim from the `STR.ar`
table; English from `STR.en`. Skill rules folded in from `.claude/skills/realtime-voice-sessions/SKILL.md`
and `.claude/skills/speech-and-tts/SKILL.md`.

Three features, three separate speakers/listeners in the web client:

| Feature | Entry | Server routes | Owns which audio |
| --- | --- | --- | --- |
| Voice call | `#callBtn` in the composer → `callOpen()` `app.js:49971` | `POST /api/live/token`, then either OpenAI Realtime (WebRTC) / Gemini Live (WS) directly, or the three-hop fallback (`/api/transcribe` + chat + `/api/tts`) | `call.audioEl` (one `<audio>`), `call.speakToken` |
| Dictation | `#micBtn` → `micStart()` `app.js:47733` | `POST /api/transcribe` (or on-device SpeechRecognition fallback) | recorder only, no playback |
| Listen | per-answer action button `data-mact="listen"` `app.js:29040` → `readAloudStart()` `app.js:24357` | `POST /api/tts` (device speechSynthesis fallback) | `readAloud.audio` (one `<audio>`), `readAloud.token` |

Invariant (speech-and-tts skill §9, and `app.js:24359`): exactly one thing speaks at a time. Listen refuses
while a call is active (`listenBusy`), and a call going up ends any running read queue at its next tick
(`app.js:24777`).

---

## 1. Auth, identity and quotas shared by all three routes

- Identity comes from cookies: member session cookie `firas_session` (`server.mjs:1046`) or guest cookie
  `firas_guest` (`server.mjs:1131`). `callerOf(req)` (`server.mjs:1314`) returns `{user,id,isGuest:false}`,
  `{id,isGuest:true}` or `{}`. All three voice routes accept **either** a member or a guest cookie; a request
  with neither is refused.
- Voice quota is one product counter `voice` (`chargeVoice`, `server.mjs:5714`). One unit is charged per
  `/api/tts` request, per `/api/transcribe` request (non-probe), and per `/api/live/token` mint (except the
  grace-window fallback mint, §3.1).
  - Members: `PLAN_LIMITS.*.voice = -1` → never metered (`server.mjs:1353-1356`).
  - Guests: `GUEST_LIMITS.voice = 120` per day per cookie (`server.mjs:1152`, env `GUEST_DAILY_VOICE`), plus a
    network bucket of `120 × GUEST_IP_MULTIPLIER(4) = 480` per hashed IP per day (`server.mjs:1256-1278`).
  - Denial body (HTTP 429), guest cookie bucket: `{"error":"guest daily limit reached","guest":true,"quota":{"product":"voice","used":<n>,"limit":120,"plan":"guest"}}`; network bucket adds `"scope":"network"` and `limit:480` (`server.mjs:1271-1288`). Member (unreachable today): `{"error":"daily quota reached","quota":{"product":"voice","used":<n>,"limit":<n>,"plan":<plan>}}` (`server.mjs:5725`).
  - The client treats **any** 429 from `/api/tts` as "hand off to the device voice" — it does not read the body (`app.js:24187`).
- Per-minute rate limits (`rateLimited`, `server.mjs:1076`, sliding window, returns HTTP 429 `{"error":"rate limited"}`):

| Route | Guest | Member | Key |
| --- | --- | --- | --- |
| `POST /api/tts` | 25/min | 90/min | `tts:<id>` (`server.mjs:5735`) |
| `POST /api/transcribe` | 12/min (checked before probe) then 20/min | 20/min | `stt:<id>` (`server.mjs:6317`, `6324`) |
| `POST /api/live/token` | 3/min | 6/min | `live:<id>` (`server.mjs:6222`) |

- Guest sub-info (`/api/auth/me`-style meter) does **not** expose the `voice` counter (`server.mjs:1186-1192`); the native app cannot show "voice units left" — only react to the 429.

---

## 2. Voice call — overview and ladder

`VOICE_CALL_ENABLED = true` (`app.js:23`). `initCall()` (`app.js:50088`) hides the call button when
`!(callSRAvailable() || callMicAvailable())`; `callSupported()` (`app.js:48149`) additionally requires
`state.product === "ai"` (call exists only in Firas AI, not Code/Agent/Brain).

Three engines, strict ladder, decided in `callProceed()` (`app.js:50040`) → `liveTryStart()` (`app.js:49130`):

1. **OpenAI Realtime over WebRTC** (`liveStartRealtime`, `app.js:48973`) — when the mint returns `provider:"openai"`.
2. **Gemini Live over raw WebSocket** (rest of `liveTryStart`) — when the mint returns `provider:"gemini"`, or when OpenAI was minted but the WebRTC session would not come up (the client re-mints with `prefer:"gemini"`).
3. **Three-hop fallback** (`callProceed` tail → `callSpeak(callHello)` → `callListen()`) — for any failure above: record/SpeechRecognition → `/api/transcribe` → normal chat `sendMessage()` in `state.callMode` → `/api/tts` (device `speechSynthesis` behind it).

Whichever engine carried the call is recorded in `window.__firasLive` and logged; Gemini shows a toast to
signed-in users: `"Live: running on Gemini — set OPENAI_API_KEY to use OpenAI Realtime"` (English only,
`app.js:48391`). Every failed rung calls `liveFail(reason, detail)` (`app.js:48355`) which toasts
`"Live: " + reason [+ " — " + detail]` to signed-in users only (English only, diagnostic).

### 2.1 Call lifecycle (`callOpen` → `callProceed` → `callEnd`)

`callOpen()` (`app.js:49971`), all inside the tap gesture:

1. `if (call.active) return; if (state.product !== "ai") return; if (!callSupported()) { toast callUnsupported; return; }`
2. `callPrimeAudio()` (`app.js:48116`): creates one hidden `<audio playsinline preload=auto>` attached to the DOM, plays a 44-byte silent WAV `data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQAAAAA=` muted to unlock it, and speaks a zero-volume `SpeechSynthesisUtterance(" ")` to prime the device voice. Native equivalent: configure `AVAudioSession` (`.playAndRecord`, `.voiceChat`/`.videoChat` mode, `.defaultToSpeaker`) inside the tap.
3. Sets `call.active=true, muted=false, finalText=""`; saves and forces `state.mode="auto"` (no plan-mode clarifying turns), `state.think=false`, and caps `state.tier` to `"pro"` if it was `"ultra"` or `"max"` (never slows a `"mini"` user). Sets `state.callMode=true`. All restored in `callEnd` (`app.js:50073-50077`).
4. Flushes the composer draft, blanks the composer, resets mute button, sets `#callName` to `"Firas"`, clears caption, hides consent, shows `#callScreen` (class `is-open` next frame), adds `body.in-call`, starts the shader orb, starts the timer, `callSetPhase("connecting")`.
5. Mic consent gate: if `!callMicAvailable() || call.micGranted || await micAlreadyGranted()` → `callProceed()`. Otherwise show `#callConsent` with `callConsentText` and `callConsentBtn`, dim `.call__controls` to opacity 0.5, and put `callConsentText` in `#callStatus`.
   - `micAlreadyGranted()` (`app.js:48095`): Permissions API `microphone` → `"granted"` → remember (`localStorage firas_mic_ok = "1"`), `"denied"` → forget, else fall back to the remembered flag. Native: use `AVAudioApplication.shared.recordPermission` — the web's whole localStorage dance exists only because Safari lacks a persistent grant.
6. `callGrantMic()` (`app.js:50026`): re-primes audio, `getUserMedia({audio:{echoCancellation:true,noiseSuppression:true}})`, stops the tracks immediately, remembers the grant, hides consent, `callProceed()`. On denial: toast `micDenied` and set `#callStatus` to `micDenied`; call stays open on the consent screen.

`callProceed()` (`app.js:50040`):

1. `callSetPhase("connecting")`.
2. `call.live = await liveTryStart()`; if true, return — the live engine drives phases from its own events.
3. Probe server STT: `POST /api/transcribe {"probe":true}` → `call.serverStt = !!(d && d.ok)`.
4. `await callSpeak(t().callHello)` — greeting through `/api/tts`.
5. `callListen()`.

`callEnd()` (`app.js:50060`), also bound to `#callEnd`, `Escape` key (`app.js:50115`), and every mid-call failure:
`call.active=false; call.live=false; callTimerStop(); orbStop(); liveTeardown(); clearTimeout(call.silence); callStopSpeaking();` abort SpeechRecognition, stop recorder/stream/AudioContext, `state.callMode=false`, restore mode/tier/think, remove `body.in-call`, remove `is-open`, hide the screen after 260 ms, `callSetPhase("idle")`.

Teardown checklist the native app must replicate (`liveTeardown`, `app.js:48536`): set `ending=true` first (re-entrancy guard), clear idle+hard timers, flush playback, disconnect worklet/source nodes, **stop every mic track** (the only thing that turns the recording indicator off), close both AudioContexts, close data channel, close peer connection, pause and detach remote audio, close WS, null every handle, `open=false`.

### 2.2 Call state machine

`call.phase ∈ {"idle","connecting","listening","thinking","speaking"}` (`app.js:48050`), set only through
`callSetPhase(phase, captionKey)` (`app.js:49522`). `call.muted` is an orthogonal flag. "ended" and "failed"
are not phases — they are `callEnd()` plus a toast.

| Phase | `#callStatus` text (ar / en) | `#callOrb` class | Entered by |
| --- | --- | --- | --- |
| `idle` | `""` | none | `callEnd` |
| `connecting` | `جارٍ الاتصال…` / `Connecting…` | none | `callOpen`, `callProceed`; while consent is shown the status is overwritten with `callConsentText` |
| `listening` | `أستمع… تكلّم الآن` / `Listening… speak now`; **if muted**: `الميكروفون مكتوم` / `Microphone muted` | `is-listening` | OpenAI: session up, `input_audio_buffer.speech_started`, `response.done`; Gemini: `setupComplete`, `serverContent.interrupted`, drain timer after `turnComplete`; three-hop: `callListenSR/Record`, mute |
| `thinking` | `فِراس يفكّر…` / `Firas is thinking…` | `is-thinking` | OpenAI: `input_audio_buffer.speech_stopped`, `response.created`; three-hop: transcript received / recording finalised |
| `speaking` | `فِراس يتحدّث…` / `Firas is speaking…` | `is-speaking` | OpenAI: any `*audio.delta`; Gemini: `livePlayChunk`; three-hop: before `callSpeak(reply)` |

`#callCaption` (`.call__caption`) — `captionKey` argument: `""` clears, `undefined` leaves as is, a key shows `t()[key]`:
- `callTapInterrupt`: `اضغط الدائرة لمقاطعته` / `Tap the circle to interrupt` — three-hop while speaking.
- `callTapTalk`: `اضغط للتحدث` / `Tap to talk` — three-hop when no recorder is available (tap-to-talk).
- `callRecording`: `أستمع… اضغط عند الانتهاء` / `Listening… tap when done` — three-hop record mode.
- Three-hop also writes raw text into the caption: the interim/final transcript while listening, the heard text while thinking, and `callSpeakable(reply).slice(0, 240)` while speaking. **Live engines never show a caption** (transcription events are ignored on the OpenAI path; Gemini sends none).

Other call strings:
- `callLabel`: `مكالمة صوتية مع فِراس` / `Voice call with Firas` (button aria); index.html static: `#callBtn` aria-label `مكالمة صوتية`, title `مكالمة صوتية — تحدّث مع فِراس`; `#callMute` aria `كتم`; `#callEnd` aria `إنهاء المكالمة`; `#callName` `فِراس` (set to `"Firas"` at open, `app.js:49995`).
- `callHello`: `مرحبًا، معك فِراس. تفضّل، أنا أسمعك.` / `Hi, Firas here. Go ahead, I'm listening.` — spoken greeting, three-hop only.
- `callError`: `تعذّرت المكالمة — تأكد من إذن الميكروفون.` / `Call failed — check microphone permission.` — toast + `callEnd()` when SR reports `not-allowed`/`service-not-allowed` or `getUserMedia` fails in record mode.
- `callSorry`: `عذرًا، لم أستطع المتابعة. حاول مرة أخرى.` / `Sorry, I couldn't continue. Please try again.` — spoken (via TTS) when the chat reply is empty, then keep listening.
- `callUnsupported`: `المكالمة الصوتية غير مدعومة على هذا المتصفح.` / `Voice calls aren't supported in this browser.`
- `callConsentText`: `للتحدث في المكالمة، اسمح باستخدام الميكروفون` / `To talk on the call, allow microphone access`; `callConsentBtn`: `السماح بالميكروفون والبدء` / `Allow microphone & start`.
- `micDenied` (reused): `اسمح بالوصول إلى المايكروفون من إعدادات المتصفح ثم أعد المحاولة.` / `Allow microphone access in your browser settings, then try again.`
- Guest ceiling toast (`liveEndOnCap`, `app.js:49502`, spoken before the screen closes): `عذرًا، بدون حساب المكالمة محدودة بـ <secs> ثانية — سجّل لتكمل بلا حدود` / `Sorry — without an account a call is limited to <secs> seconds. Sign in to keep talking.` where `secs = round(tok.maxMs/1000)` (50).
- Sign-in wall toast (`app.js:49173`, when the mint returns `signin_required`): `المكالمة الصوتية الذكية تحتاج تسجيل دخول — بدونها تشتغل بالوضع البسيط` / `The AI voice call needs an account — without one it runs in basic mode`. Note: with the current server a guest **does** get a token, so this fires only with no cookie at all.
- Admin-only Gemini quota toast (`app.js:48284`): `انتهت حصة Gemini Live — فعّل الفوترة على مشروع المفتاح` / `Gemini Live quota exhausted — enable billing on the key's project`.
- Voice picker toast (`firasSetCallVoice`, `app.js:48311`): `صوت المكالمة: <name> — يُطبَّق على المكالمة القادمة` / `Call voice: <name> — applies to the next call`.

Timer (`callTimerStart`, `app.js:49953`): starts when the screen opens (not when connected), `MM:SS` zero-padded, `#callTimer dir="ltr"`, repainted every 1 s, cleared on end.

Mute (`callToggleMute`, `app.js:49923`): flips `call.muted`, toggles `.is-muted` on `#callMute`. OpenAI: `liveCall.micTrack.enabled = !call.muted`. Gemini: the capture callback drops frames while muted (`app.js:49330`). Live engines then `return` — mute never changes the phase on a live call. Three-hop: muting stops SR/recorder and sets `listening` (status shows `callMuted`); unmuting while `listening` restarts `callListen()`.

Orb tap (`callOrbTap`, `app.js:49901`): no-op on live engines. Three-hop: while `speaking` → stop speech and listen; while `listening` with SR → force-commit what was heard; with recorder → finish now; idle tap-to-talk → start listening.

Tab hidden (`app.js:50107-50112`): live engines ride it out; three-hop stops SR/recorder and speech, resumes `callListen()` when visible again if `listening && !muted`.

### 2.3 Orb states and motion (`orbStart`, `app.js:48737`; `orbAudioLevel`, `app.js:48677`; `orbWatchLevel`, `app.js:48701`; `orbStop`, `app.js:48843`)

- WebGL shader with uniforms `iTime, iResolution, hue (ORB_HUE, localStorage firas_orb_hue, default 0), rot, hover, hoverIntensity`; the CSS fallback orb (`.call__ring ×3`, `.call__core .nib.is-aurora`) animates via the `is-listening/is-thinking/is-speaking` classes.
- Level source: on OpenAI, `pc.getStats()` polled every 50 ms, `inbound-rtp audio audioLevel` → `min(1, sqrt(level) × 1.9)`; trusted only after the first non-zero sample, otherwise while `phase === "speaking"` a synthetic envelope `0.42 + 0.30·sin(7.3t) + 0.16·sin(11.9t+1.7)` clamped to `[0.12, 0.85]`. Eased: rise factor 0.45, fall 0.10 per frame. Rotation speed `0.30 + level × 2.4` rad/s. `hover = min(level×2, 1)`, `hoverIntensity = min(level×0.8, 0.8)`. DPR capped at 2, host 176 px. Native: drive the same envelope from `AVAudioPlayerNode` metering / `RTCAudioTrack` stats.

---

## 3. `POST /api/live/token` (`handleLiveToken`, `server.mjs:6212`)

Request: JSON body ≤ 2000 bytes (`readJson(req, 2_000)`), optional:

```json
{ "voice": "cedar", "prefer": "gemini" }
```

- `voice`: string, honoured only if in `CALL_VOICE_ALLOW = ["cedar","ash","verse","echo","ballad"]` (`server.mjs:6146`); default `OPENAI_REALTIME_VOICE` = `"cedar"`.
- `prefer`: only `"gemini"` is recognised (asks to come *down* the ladder); `"openai"` or anything else is ignored.
- The web client always sends `{voice: callVoice()}` (`app.js:49155`), where `callVoice()` reads `localStorage firas_call_voice` filtered through `CALL_VOICES` (same list, `app.js:48302`), default `"cedar"`.

Responses:

| Status | Body | When |
| --- | --- | --- |
| 403 | `{"error":"signin_required","feature":"live"}` | no member and no guest cookie |
| 429 | `{"error":"rate limited"}` | 3/min guest, 6/min member |
| 503 | `{"error":"no_engine"}` | neither `OPENAI_API_KEY` nor `GEMINI_API_KEY` configured |
| 429 | voice-quota denial (§1) | `chargeVoice` refused (guests only in practice) |
| 200 | `{"provider":"openai","token":"ek_…","model":"gpt-realtime-2.1","voice":"cedar","maxMs":600000,"guest":false,"startWithinMs":60000}` | OpenAI key present and `prefer !== "gemini"` and mint succeeded |
| 200 | `{"provider":"gemini","token":"<auth_tokens name>","model":"gemini-3.1-flash-live-preview","maxMs":600000,"guest":false,"startWithinMs":60000}` | Gemini path (no `voice` field) |
| 502 | `{"error":"mint_failed"}` | OpenAI mint failed **and** no Gemini key; or Gemini `auth_tokens` non-OK / no name |
| 502 | `{"error":"unreachable"}` | Gemini `auth_tokens` fetch threw |

Field types/defaults: `maxMs` = `LIVE_SESSION_MAX_MS` (env, default 600000, capped 30 min) for members, `GUEST_LIVE_MAX_MS` (env, default 50000, capped 5 min) for guests (`server.mjs:6090-6104`); `startWithinMs` = 60000 always; `guest` boolean.

### 3.1 Charge-once grace

`LIVE_CHARGE_GRACE_MS = 90000` (`server.mjs:6125`). A mint with `prefer:"gemini"` within 90 s of the last charged mint for the same owner is **not** charged; every other mint charges one voice unit **before** trying any engine. Native ladder must therefore: mint once (no prefer) → if OpenAI session fails, mint again with `{prefer:"gemini"}` within 90 s → then fall to three-hop. Never mint "openai" twice.

### 3.2 What the OpenAI ephemeral secret already contains (`mintOpenAIRealtime`, `server.mjs:6166`)

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

`REALTIME_INSTRUCTIONS` (`server.mjs:6151`, joined with single spaces):

> You are Firas, on a live voice call. SPEAK, do not lecture: short conversational turns, the way a person actually talks on the phone. Never read markdown aloud, never say asterisk or hash, never spell out punctuation, never read numbered lists aloud unless you are asked to. Answer in the SAME language and the SAME dialect the caller uses - if they speak Iraqi Arabic, answer in Iraqi Arabic, not Modern Standard. Never switch to English because a technical term came up. If the caller interrupts you, stop immediately and listen. Keep answers to a couple of sentences unless the caller asks for detail. You cannot browse the web on this call: if you are asked for something you cannot know - today's news, a live price, a score - say so in one short sentence and offer to look it up in the chat after the call, rather than guessing.

`IDENTITY_BLOCK` (`server.mjs:12720`) is the shared identity text ("trained by Mentronx", «تم تدريبي بواسطة Mentronx بأحدث التقنيات», «مِنترونكس شركة عراقية تصنع الذكاء الاصطناعي وتدرّبه», never name a provider). The persona is **server-side**; the client never sends instructions. The secret can open exactly one session and dies after 600 s.

---

## 4. OpenAI Realtime session — what the web does over WebRTC, and the WebSocket equivalent

Web (`liveStartRealtime`, `app.js:48973`):

1. `getUserMedia({audio:{channelCount:1, echoCancellation:true, noiseSuppression:true, autoGainControl:true}})`; on failure `micForget()` and fall back.
2. `RTCPeerConnection`, remote track → the primed `call.audioEl` (`srcObject`, `autoplay`, `play()`), `addTrack(micTrack)`, `track.enabled = !call.muted`, data channel named `"oai-events"`.
3. `POST https://api.openai.com/v1/realtime/calls?model=<tok.model || "gpt-realtime-2.1-mini">` with `Authorization: Bearer <tok.token>`, `Content-Type: application/sdp`, body = offer SDP, 12 s abort. Answer must start with `v=0`.
4. Wait up to 12 s for `dc.onopen`; `connectionState` `failed/closed/disconnected` → fail. Only then `liveCall.open = true`, `liveEngine("openai")`, `callSetPhase("listening")`.
5. Greeting request sent on the data channel immediately (`app.js:49093`):

```json
{ "type": "response.create",
  "response": { "instructions": "Greet the caller warmly in ONE short sentence in Arabic, then stop and listen." } }
```
(`"Arabic"` when `state.lang === "ar"`, else `"English"`.)

6. Timers: hard cap `setTimeout(liveEndOnCap, max(60000, tok.maxMs || 600000) − 1500)`; idle hang-up when `Date.now() − lastVoiceAt > LIVE_IDLE_HANGUP_MS (45000)`, checked every 5 s. `lastVoiceAt` is bumped on `speech_started`, `speech_stopped`, `response.done`. Mid-call `connectionState` `failed/closed/disconnected` → `liveEnd()` (teardown + `callEnd`).

Events handled (`liveRealtimeEvent`, `app.js:48933`) — everything else, including all transcription events, is ignored:

| `type` | Action |
| --- | --- |
| `input_audio_buffer.speech_started` | `lastVoiceAt=now; interruptions++; phase=listening` |
| `input_audio_buffer.speech_stopped` | `lastVoiceAt=now; phase=thinking` |
| `response.created` | `phase=thinking; if (!LIVE_BARGE_IN) liveMicGate(false)` |
| any type containing `audio.delta` (`response.audio.delta` **or** `response.output_audio.delta`) | `phase=speaking; if (!LIVE_BARGE_IN) liveMicGate(false)` |
| `response.done` | `lastVoiceAt=now; phase=listening; if (!LIVE_BARGE_IN) liveMicReopenSoon()` |
| `error` | console only |

Echo guard (`liveMicGate`, `app.js:48907`; `LIVE_BARGE_IN` default **false**, `localStorage firas_barge_in`): while Firas speaks the mic track is disabled at the source (`track.enabled = open && !call.muted`), reopened 280 ms after `response.done` (`liveMicReopenSoon`), with a 20 s safety timer that re-enables the track if `response.done` never arrives. Idempotent while closed. Consequence: voice barge-in is **off** by default on the OpenAI path; the caller must wait for the reply to end. Native should replicate: mute `RTCAudioTrack`/input node during `speaking`, reopen +280 ms, 20 s safety.

### 4.1 Native WebSocket reproduction

Connect `wss://api.openai.com/v1/realtime?model=<tok.model>` with header `Authorization: Bearer <tok.token>` (the `ek_…` client secret; do not send `OpenAI-Beta` unless required by the SDK version in use). Audio must then be carried by the app itself as PCM16 24 kHz mono base64 (`input_audio_buffer.append`) and played from `response.output_audio.delta` — or use the WebRTC transport via the iOS WebRTC framework, which is what the web does and what gives AEC, jitter buffering and server VAD for free (realtime-voice-sessions skill §4 recommends WebRTC; prefer it on iOS). If using WebSocket, the session the `ek_…` secret opens **already carries** everything in §3.2 (instructions + identity, `gpt-4o-mini-transcribe` transcription, `near_field` noise reduction, `semantic_vad` with `create_response`/`interrupt_response`, the voice, speed 1.0). The web client never sends a `session.update` at all — WebRTC negotiates the audio format and the data channel only ever carries the greeting `response.create`. The one thing a WebSocket client must add is the audio format, which the mint does not pin. Send this after `session.created` and nothing more:

```json
{
  "type": "session.update",
  "session": {
    "type": "realtime",
    "audio": {
      "input":  { "format": { "type": "audio/pcm", "rate": 24000 } },
      "output": { "format": { "type": "audio/pcm", "rate": 24000 } }
    }
  }
}
```

Do **not** resend `instructions`, `audio.output.voice`, or `audio.input.turn_detection`: they are server-authoritative (the persona lives in `server.mjs`, the voice is validated against `CALL_VOICE_ALLOW` at mint), re-asserting them buys nothing, and a voice update after the first audio is refused upstream. For reference only, the full effective session — what you would see echoed back in `session.created` — is:

```json
{
  "type": "realtime",
  "model": "gpt-realtime-2.1",
  "instructions": "<REALTIME_INSTRUCTIONS>\n\n<IDENTITY_BLOCK>",
  "audio": {
    "input": {
      "format": { "type": "audio/pcm", "rate": 24000 },
      "transcription": { "model": "gpt-4o-mini-transcribe" },
      "noise_reduction": { "type": "near_field" },
      "turn_detection": { "type": "semantic_vad", "create_response": true, "interrupt_response": true }
    },
    "output": { "format": { "type": "audio/pcm", "rate": 24000 }, "voice": "<tok.voice>", "speed": 1.0 }
  }
}
```

Then the greeting `response.create` from §4 step 5. Audio up: `{"type":"input_audio_buffer.append","audio":"<base64 PCM16 LE mono 24 kHz>"}` continuously (server VAD commits turns; never send `input_audio_buffer.commit` yourself while `semantic_vad` is on). Audio down: `response.output_audio.delta` (`delta` = base64 PCM16 24 kHz) — match on the substring `audio.delta` as the web does. Interruption: with `interrupt_response: true` the server cancels its own response on `speech_started`; the client must then stop local playback immediately (WebRTC did that implicitly) — the web's phase table (§4) needs no extra events. `ios/Docs/server-voice.md` §8 carries the fuller GA event cheat-sheet; this file is authoritative for the phases and strings.

**Transcript into the chat:** on the OpenAI and Gemini live paths the web client writes **nothing** into the conversation — no user turn, no assistant turn, no caption. Only the three-hop path (§6) posts through `sendMessage()`. A native app that wants the call saved should consume `conversation.item.input_audio_transcription.completed` and `response.output_audio_transcript.done`, which the web requests (transcription model is on) but ignores.

---

## 5. Gemini Live path (WebSocket, raw PCM) — `liveTryStart` tail (`app.js:49206-49500`)

Skip entirely if `liveQuotaBlocked()` (10-minute in-memory cooldown after a 1008/1011 close, `LIVE_QUOTA_COOLDOWN_MS`, `app.js:48246`).

- Capture: `getUserMedia` (same constraints as §4), `AudioWorklet` 128-sample blocks, batched into `LIVE_FRAME_MS = 100` ms frames, linear-interpolation resample to `LIVE_IN_RATE = 16000`, Int16 LE (`liveTo16k`, `app.js:48414`). Playback: `LIVE_OUT_RATE = 24000`, scheduled on a forward-only cursor with `LIVE_JITTER_LEAD = 0.2` s (`livePlayChunk`, `app.js:48442`).
- Socket: `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained?access_token=<tok.token>` (`LIVE_WS_BASE`, `app.js:48180`), `binaryType="arraybuffer"`, 10 s open timeout ("no setupComplete within 10s").
- Setup message sent on open (`app.js:49256`; fields marked ⁽ʳ⁾ are dropped on the "reduced" retry; the `tools` block is dropped when `firas_live_no_search` localStorage list contains the model):

```json
{ "setup": {
    "model": "models/gemini-3.1-flash-live-preview",
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
⁽ʳ⁾ = `speechConfig`, `tools`, `realtimeInputConfig`. Voice: `liveVoice()` = `localStorage firas_live_voice` if in `LIVE_VOICES` (`app.js:48229`: Charon, Sadaltager, Achird, Umbriel, Algieba, Iapetus, Schedar, Puck, Orus, Enceladus, Fenrir, Alnilam, Rasalgethi, Algenib, Zubenelgenubi, Sadachbia), default `"Charon"`. The settings UI no longer exposes this list (console `firasSetVoice()` only).

  System instruction text (`app.js:49287-49312`, `lang` = `"Arabic"` when UI is Arabic else `"the user language"`):

  > You are Firas, on a live voice call. SPEAK, do not lecture: short conversational turns, the way a person actually talks on the phone. Never read markdown, never say asterisk or hash, never spell out punctuation, never list numbered points aloud unless asked. Answer in the SAME language and the SAME dialect the caller uses — if they speak Iraqi Arabic, answer in Iraqi Arabic, not Modern Standard. The interface language is `<lang>`, but the CALLER decides. If you are interrupted, stop immediately and listen. YOU CAN SEARCH THE WEB. When a question needs current information — news, prices, scores, what happened today, anything you are unsure of — first say WHAT you are about to look up, in one short sentence, in the caller's own language and dialect. NAME THE SUBJECT; do not just promise to check. In Iraqi Arabic something like لحظة، أدوّرلك على سعر الدولار اليوم, in English something like "one second, let me look up today's dollar rate". THE ANNOUNCEMENT AND THE ANSWER ARE ONE SINGLE TURN — never two. Do NOT stop speaking the moment you have announced it, and do NOT hand the turn back to the caller to wait: search, then keep going in the SAME turn and tell them what you found. The caller must NEVER have to prompt you, ask what you found, or say anything at all between your announcement and your answer. If you are about to end a turn having promised to look something up but not yet said what you found, do not end it — give the answer now. Never go silent while searching — a silent line sounds like a dropped call. Say the answer, not the URLs.

- Audio up, one message per 100 ms frame, continuous (silence frames are sent, never gaps):
  `{"realtimeInput":{"audio":{"mimeType":"audio/pcm;rate=16000","data":"<base64 Int16 LE>"}}}`.
- Audio down: `serverContent.modelTurn.parts[].inlineData{mimeType:/audio/, data}` → play. `serverContent.interrupted` → flush playback, `turnOpen=false`, phase listening. `serverContent.turnComplete || generationComplete` → `turnOpen=false`, `liveMaybeListening()` (160 ms drain timer; listening only when nothing is scheduled). `goAway` → `liveEnd()`.
- Echo/barge guard (`liveBargeDecision`, pure, `app.js:48479`): armed while `liveIsSpeaking() || turnOpen`, held for `LIVE_ECHO_HANGOVER_MS = 350` after; first armed frame seeds `echoFloor = max(rms, 1e-4)` and is sent as silence; threshold `max(LIVE_BARGE_RMS 0.055, echoFloor × LIVE_BARGE_OVER_ECHO 3.0)`; a frame is forwarded only after `LIVE_BARGE_FRAMES = 3` consecutive loud frames; floor decays `0.7·floor + 0.3·rms` on quiet frames and freezes on loud ones. Frames that fail are replaced with zero PCM of the same length. `rms > 0.02` bumps `lastVoiceAt`.
- Close codes: `1008` or `1011` → if the setup carried the search tool, remember "no search entitlement" for this model in `localStorage firas_live_no_search` (last 10 models) and retry once without it; otherwise 10-minute quota cooldown. A close within 8 s of setup (other than 1000/1008) → one retry with the reduced setup. Every retry mints a **new** token (`uses:1`). Mid-call close → `liveEnd()`.
- Timers identical to §4 step 6.

Skill guidance for the native port: keep this rung only if the server can still mint Gemini; the WebRTC rung is the one that ships first, and the three-hop is the mandatory floor.

---

## 6. Three-hop fallback (record → `/api/transcribe` → chat → `/api/tts`)

Entered from `callProceed()` after `liveTryStart()` returned false. Greeting: `callSpeak(callHello)` then `callListen()` (`app.js:49776`).

Listening mode selection:
- `mic.lang === "auto" && call.serverStt && callMicAvailable()` → **record mode** (`callListenRecord`) — the server truly auto-detects language.
- else if SpeechRecognition exists → **SR mode** (`callListenSR`) with `rec.lang = callBcp()` = `MIC_BCP[mic.lang] || "ar-SA"` (auto biases to Arabic, never the UI language).
- else record mode. Native: there is no SpeechRecognition; use record mode, or `SFSpeechRecognizer` with the same BCP-47 mapping.

Record mode (`callListenRecord`, `app.js:49831`): status `callRecording` caption; `getUserMedia({audio:{echoCancellation:true,noiseSuppression:true}})` (failure → toast `callError`, `callEnd()`); `MediaRecorder` timeslice 200 ms; VAD on `AnalyserNode` fftSize 512 byte-time-domain RMS: `rms > 6` (0–128 scale ≈ 0.047 full-scale) marks speech; stop when `hadSpeech && quiet > 1050 ms` or `elapsed > 15000 ms`; blob `< 1500` bytes or no speech → keep listening; else phase `thinking`, encode WAV (§7.3), `POST /api/transcribe {audio, format:"wav", lang: mic.lang}`, then `callHandleTranscript(text)`. Any error → keep listening.

SR mode (`callListenSR`, `app.js:49788`): `continuous=true, interimResults=true, maxAlternatives=1`; the caption shows `finalText + interim`; commit after **850 ms** of no new results once something was heard (`app.js:49811`; the comment says 1.2 s, the code says 850); `no-speech` → restart; `not-allowed`/`service-not-allowed` → toast `callError`, `callEnd()`; `onend` without commit → restart while `listening && !muted`.

Turn (`callHandleTranscript`, `app.js:49760`): empty → `callListen()`; else phase `thinking`, caption = heard text, `reply = await callSend(text)`; empty reply → speak `callSorry`, listen; else phase `speaking` with caption `callTapInterrupt`, caption text = `callSpeakable(reply).slice(0,240)`, `await callSpeak(reply)`, then `callListen()`.

`callSend` (`app.js:49750`): puts the transcript in the composer, `clearPendingImages()`, `await sendMessage()` (the normal streaming chat pipeline — the user turn and the assistant reply are **saved to the active chat** like any typed message), returns the last assistant message's content.

Call-mode system prompt (`app.js:38113-38124`, used by `sendMessage` when `state.callMode`; `system = callSys + identityRule + langRule + NO_NEEDLESS_REFUSAL`, no math/file/code rules). `callSys` by `replyLang`:

Arabic:

> أنت فِراس AI، مساعد صوتي ذكيّ ودافئ طوّره المطوّر فِراس. أنت الآن في مكالمة صوتية مباشرة: المستخدم يتحدّث إليك ويسمع ردّك مقروءًا بصوتٍ مسموع. تحدّث بعربيةٍ فصيحة رشيقة وبليغة بأسلوب محادثة هاتفية حيّة — عربية متحدثٍ مثقفٍ فصيح: اختيار كلماتٍ دقيق وأنيق، تراكيب سليمة متقنة النحو، وروابط محكية طبيعية تلين الكلام («طيّب»، «بصراحة»، «الحقيقة»، «يعني»، «خلّني أوضّح لك») — من غير تقعّرٍ ولا جفافٍ كتابيّ ولا ركاكة. جُملٌ قصيرة متنوّعة الإيقاع، وردٌّ موجز (جملة إلى ثلاث جُمل غالبًا) إلا إذا طلب المستخدم تفصيلًا فتُوسّع باعتدال وبنَفَسٍ منطوق. قاعدة صارمة: لا تكتب أبدًا رموزًا رياضية أو صيغ LaTeX أو علامات $ أو markdown أو عناوين أو نجوم أو قوائم أو جداول أو كتل برمجية أو روابط أو رموزًا تعبيرية. انطق كل رقم ورمز ومعادلة بالكلمات كما تُلفظ صوتيًا — مثال: بدل «١+١=٢» قل «واحد زائد واحد يساوي اثنين»، وبدل «x²» قل «إكس تربيع». اكتب كأنك تُملي كلامًا يُسمع، لا نصًّا يُقرأ. كن دقيقًا: تحقّق من الحساب في نفسك قبل أن تقوله، ولا تختلق معلومة؛ إن لم تكن متأكدًا فقل ذلك بوضوح. لا تُنشئ ملفات ولا أكوادًا أثناء المكالمة. كن ودودًا دافئًا متفاعلًا مع كلام المستخدم — تُحسّ باهتمامه وتجاريه — كأنك صديق فصيح يتحدّث وجهًا لوجه.

English:

> You are Firas AI, a warm, smart voice assistant developed by the developer Firas. You are on a LIVE VOICE CALL: the user talks to you and hears your reply read aloud. Speak POLISHED, natural conversational English — the fluent, articulate English of a well-spoken native speaker: idiomatic phrasing, impeccable grammar, precise word choice, smooth connectors (well, actually, that said, here's the thing), light contractions (I'm, you'll, that's), and a varied, easy sentence rhythm. Keep replies brief (usually one to three sentences) unless the user asks for detail, then expand moderately while still sounding spoken, never essay-like. STRICT RULE: never write math symbols, LaTeX, dollar signs, markdown, headings, asterisks, lists, tables, code blocks, links or emoji. Say every number, symbol and equation in spoken words — e.g. instead of "1+1=2" say "one plus one equals two", instead of "x^2" say "x squared". Write as if dictating speech to be heard, not text to be read. Stay accurate: check any calculation privately before you say it, and never fabricate — if unsure, say so plainly. Do not create files or code during the call. Be friendly, natural and engaging, like a sharp, well-spoken friend talking face to face.

`identityRule`/`langRule` are the ordinary chat rules at `app.js:37839-37857` (chat slice owns them). Also in call mode: no problem-set generation (`app.js:37241`, `37812`), no file-format detection (`app.js:38192`).

Speaking (`callSpeak`, `app.js:49688`): `clean = callSpeakable(text)`; `lang = detectLang(clean)` (`app.js:2707`: any char in U+0600–U+06FF → `"ar"`, else `"en"`); `POST /api/tts {text: clean, lang, gender:"male"}`; play the blob on `call.audioEl`; token-guarded (`call.speakToken`). If the server fails or `play()` is refused → device `speechSynthesis` chunked on `[.!?؟،؛\n]`, voice from `callPickVoice(lang, false)` (lenient: any voice beats silence), `rate=pitch=volume=1`. `callStopSpeaking()` (`app.js:49743`) bumps the token, pauses+detaches the element, cancels synthesis.

`callSpeakable` (`app.js:49536`) — strip for speech, apply before any TTS request: drop fenced/inline code; `$$…$$`/`$…$` → inner text; `\boxed{x}`→x, `\text{x}`→x, `\frac{a}{b}`→`a over b`, `\sqrt{x}`→`root x`, `\times`→`x`, `\cdot`→`.`, `\pi`→`pi`, other `\cmd` removed, braces removed; `^2`→` squared`, `^3`→` cubed`, other `^`→` to the power `; images dropped, links → label; headings/markdown marks `*_~>#|` removed; URLs removed; emoji ranges removed; whitespace collapsed, blank lines → `". "`.

---

## 7. Dictation (`#micBtn`)

### 7.1 UI and gestures (`initMic`, `app.js:47980`)

- Button hidden when neither recorder nor SpeechRecognition exists **and** the context is secure; on an insecure origin it stays, marked `is-unavailable`, and tapping toasts: `الإملاء الصوتي يحتاج اتصالًا آمنًا (HTTPS). افتح الموقع عبر https أو من localhost.` / `Voice input needs a secure connection (HTTPS). Open the site over https or from localhost.` (irrelevant natively).
- Labels: `micLabel` `إدخال صوتي` / `Voice input`; `micHint` (title) `إدخال صوتي — اضغط مطوّلًا لاختيار اللهجة` / `Voice input — long-press to pick a dialect`.
- Tap: start recording, or finish if recording; tap while the dialect menu is open closes it. Long-press 450 ms, right-click, or the tools-menu row `#micLangItem` (`micLangTitle`: `لغة الإملاء` / `Dictation language`) opens the dialect picker `#micMenu`. The recording bar's chip `#micLangChip` (🌐 + short label) toggles it too.
- Recording bar `#micRec` (overlays the composer): cancel `#micCancel` (aria `إلغاء التسجيل`), red dot, waveform canvas (32 bars from analyser time-domain, accent colour), status `#micStatus`, timer `#micTime` `m:ss` (Arabic-Indic digits when UI is Arabic), dialect chip, done `#micDone` (aria `إيقاف وتحويل`). Composer gets class `is-recording`, mic button `is-on`.
- The recorder can be retargeted to another textarea (`micUse(tgt)`, `app.js:47668`) — Firas Brain's ask box uses the same recorder; the bar and menu are physically moved to the target's host.
- Tab hidden while recording → `micFinish()` (auto-submit, privacy) `app.js:48039`.
- Escape closes the picker (`app.js:87417`).

### 7.2 Dialect list (`MIC_LANGS`, `app.js:47582`; persisted in `localStorage firas_ai_mic_lang`, default `"auto"`)

| key | flag | ar label (menu) | en label | short ar | short en | SR BCP-47 (`MIC_BCP`) |
| --- | --- | --- | --- | --- | --- | --- |
| auto | 🌐 | تلقائي — يتعرّف على لغتك من كلامك | Auto — detects your language | تلقائي | Auto | `""` → `ar-SA` for SR |
| msa | 📖 | العربية الفصحى | Arabic (Fus'ha) | فصحى | MSA | ar-SA |
| iraqi | 🇮🇶 | عراقية | Iraqi Arabic | عراقية | Iraqi | ar-IQ |
| gulf | 🇸🇦 | خليجية | Gulf Arabic | خليجية | Gulf | ar-SA |
| egyptian | 🇪🇬 | مصرية | Egyptian Arabic | مصرية | Egyptian | ar-EG |
| levant | 🇸🇾 | شامية | Levantine Arabic | شامية | Levantine | ar-JO |
| maghrebi | 🇲🇦 | مغاربية | Maghrebi Arabic | مغاربية | Maghrebi | ar-MA |
| en | 🇺🇸 | الإنجليزية | English | English | English | en-US |
| fr | 🇫🇷 | الفرنسية | French | Français | French | fr-FR |
| tr | 🇹🇷 | التركية | Turkish | Türkçe | Turkish | tr-TR |
| de | 🇩🇪 | الألمانية | German | Deutsch | German | de-DE |
| es | 🇪🇸 | الإسبانية | Spanish | Español | Spanish | es-ES |
| ur | 🇵🇰 | الأردية | Urdu | اردو | Urdu | ur-PK |
| fa | 🇮🇷 | الفارسية | Persian | فارسی | Persian | fa-IR |

No Kurdish. The same list backs the Settings → Voice tab select (`dictH` `لهجة الإملاء` / `Dictation dialect`, `dictSub` `حين تُملي كلامك نصّاً` / `when you speak instead of type`, `app.js:45753`, `46095`). Changing the dialect mid live-dictation restarts SR with the new language.

### 7.3 Recording flow (`micStart` `app.js:47733` → `micFinish` `app.js:47901`)

1. Lazy probe once per session (`mic.serverStt === null`): `POST /api/transcribe {"probe":true}` → `mic.serverStt = !!d.ok`; a thrown error leaves it `null` (still tries record mode). If `serverStt === false` (or no recorder) and SpeechRecognition exists → live dictation mode (§7.5).
2. `getUserMedia({audio:{echoCancellation:true,noiseSuppression:true}})`; denial → toast `micDenied`.
3. `MediaRecorder` mime: first supported of `audio/webm;codecs=opus`, `audio/webm`, `audio/mp4`, `audio/ogg;codecs=opus` (`micPickMime`, `app.js:47728`); timeslice 250 ms. Native: record straight to 16 kHz mono PCM with `AVAudioEngine`; the web's mime choice only exists because it must decode later.
4. Timer ticks every 500 ms; at `MIC_MAX_SECONDS = 300` (`app.js:47598`) recording auto-finishes.
5. Cancel (`micCancel`): stop tracks, drop chunks, hide bar — nothing inserted.
6. Done (`micFinish`): `tooShort = elapsed < 700 ms`; blob `< 1500` bytes or too short → toast `micTooShort` (`التسجيل قصير جدًا — تكلّم ثم اضغط ✓.` / `Recording too short — speak, then press ✓.`). Status → `micTranscribing` (`جارٍ تحويل كلامك…` / `Transcribing your speech…`), timer hidden.
7. Encode: decode the blob, render offline to **16 000 Hz mono**, 16-bit PCM LE WAV with a standard 44-byte RIFF header (`micWavBase64`, `app.js:47942`; ≈32 KB/s, 5 min ≈ 12 MB of base64), base64-encode.
8. `POST /api/transcribe` body `{"audio":"<base64 wav>","format":"wav","lang":"<MIC_LANGS key>"}` via `apiJson` (same-origin cookies).
9. Result: `text = out.text.trim()`; empty → toast `micEmpty` (`لم أسمع كلامًا واضحًا — حاول مجددًا.` / `I didn't catch any clear speech — try again.`). Otherwise **append** to the target textarea: `box.value = cur ? cur.replace(/\s*$/, " ") + text : text` — never replaces, never auto-sends; caret moved to the end, composer resynced (autoGrow, direction, send-state, draft save).
10. Errors: HTTP 503 with SpeechRecognition available → `mic.serverStt = false` and immediately reopen in live mode; anything else → toast `micFail` (`تعذّر تحويل الصوت — حاول مرة أخرى.` / `Couldn't transcribe the audio — please try again.`). 401 triggers the global session-expired handler; 403 `signin_required` opens the sign-up prompt (`apiJson`, `app.js:3216`).

Other strings: `micListening` `جارٍ الاستماع… تكلّم الآن` / `Listening… speak now` (live mode status); `micUnsupported` `التسجيل الصوتي غير مدعوم على هذا المتصفح.` / `Voice recording is not supported in this browser.`

### 7.4 `POST /api/transcribe` (`handleTranscribe`, `server.mjs:6312`)

Body (JSON, limit `CHAT_BODY_LIMIT` = 25 000 000 bytes):

| Field | Type | Rules |
| --- | --- | --- |
| `probe` | bool | if truthy → `200 {"ok": <GEMINI_API_KEY present>}`, nothing charged, no auth beyond identity |
| `audio` | string | base64; optional `data:audio/<x>;base64,` prefix stripped; `< 4000` chars → `400 {"error":"no audio"}`; `> 20 000 000` chars or non-`[A-Za-z0-9+/=]` → `400 {"error":"bad audio"}` |
| `format` | string | `"mp3"` → `audio/mp3`, anything else → `audio/wav` |
| `lang` | string | `STT_HINTS` key (`auto,msa,iraqi,gulf,egyptian,levant,maghrebi,en,fr,tr,de,es,ur,fa`); unknown/missing → no hint |

Order of checks: 401 `{"error":"authentication required"}` (no cookie) → guest 12/min 429 → 400 `{"error":"invalid JSON body"}` → probe → 503 `{"error":"no stt engine"}` → 20/min 429 → voice charge 429 → audio validation 400s → Gemini `generateContent` on each of `GEMINI_TEXT_MODELS` (default `gemini-2.5-flash,gemini-flash-latest`), `temperature:0`, 60 s timeout, prompt `STT_INSTRUCTION + " Transcribe this audio verbatim." + hint` (`server.mjs:6064-6084`; e.g. iraqi hint: ` The speech is Iraqi Arabic dialect (اللهجة العراقية). Write it in Arabic script exactly as spoken.`). Surrounding `"…"` or `«…»` is unwrapped once. Success `200 {"text":"…"}` (may be `""`); all models failed → `502 {"error":"stt engine unavailable"}`.

### 7.5 Live browser dictation fallback (`micStartLive`, `app.js:47840`)

Used only when the server has no STT. `SpeechRecognition` with `lang = MIC_BCP[mic.lang] || "ar-SA"`, `continuous`, `interimResults`; the box shows `base + final + interim` live (base = the text already in the box, joined with one space); cancel restores `base`; done keeps the final text; errors `not-allowed`/`service-not-allowed` → `micDenied`, `no-speech` → `micEmpty`, other (if nothing was heard) → `micFail`. Bar shows `micListening` instead of the waveform (class `is-live`). Native analogue: `SFSpeechRecognizer` on-device, same append semantics.

---

## 8. Listen (read one answer aloud)

### 8.1 Button and behaviour (`app.js:29040-29046`, `readAloudStart` `app.js:24357`)

- Action-row button on every assistant message (second after Copy), label `listen`: `اسمع` / `Listen`; while playing the label becomes `listenStop`: `إيقاف` / `Stop` and the button gets `is-on`; pressing it again stops. Pressing Listen on another message stops the first (single `readAloud.token`).
- Refused while a call is active: toast `listenBusy` `أنهِ المكالمة أول` / `End the call first`.
- Text = `callSpeakable(msg.content)` (§6); empty → nothing. `lang = detectLang(clean)` → `"ar"` or `"en"` only.
- Chunking (`readAloudChunks`, `app.js:24271`): split on `[.!?؟،؛\n]`, pack to ≤ 1300 chars, never mid-sentence; a single sentence > 1300 is cut on whitespace. (Server truncates at 1400 and collapses whitespace first.)
- Fetch (`readAloudFetch`, `app.js:24162`): `POST /api/tts {"text":<chunk>,"lang":"ar"|"en","gender":"male"}`, `credentials: same-origin`. One-chunk lookahead (chunk i+1 is requested once chunk i is known good). Retry once after 500 ms on 5xx/network; 4xx (except 429) → give up to device; a 200 whose body is ≤ 64 bytes or `json`/`text/*` typed is treated as failure. **Cache**: `Map` keyed `lang + "\0" + text`, `READ_CACHE_MAX = 16` entries, in memory for the page life — re-reading the same answer spends no quota.
- 429 (rate limit **or** quota — indistinguishable to the client) → toast `listenLocal` `انتهت حصة الصوت — يكمّل بصوت الجهاز` / `Voice quota spent — finishing on your device` and the **rest** of the chunks continue on device speech from the failed index (no restart, no stop).
- Playback (`readAloudPlay`, `app.js:24204`): one hidden `<audio>` created inside the press (`readAloudPrime`, `app.js:24029`, same silent-WAV unlock), else Web Audio decode+play; `NotAllowedError` marks the element blocked for the rest of the reading. Native: `AVAudioPlayer`/`AVPlayer` per chunk, sequential, preloading the next.
- Device fallback (`readAloudDevice`, `app.js:24295`): strict pick `callPickVoice(lang, true)`; if none for the language, lenient pick with the utterance's `lang` forced to `ar-SA`/`en-US` and a toast `listenNoVoiceAr` `جهازك ما عنده صوت عربي — ثبّته من إعدادات اللغة بالنظام، وبعدها يشتغل` / `This device has no Arabic voice — add one in your system language settings and it will work` (or `listenNoVoice` `جهازك ما عنده صوت للقراءة — ثبّت صوتًا من إعدادات النظام` / `This device has no speech voice installed — add one in your system settings` for English / no voices). The mismatched case toasts **up front** and still speaks (`app.js:24308`). When a language-matched voice was used, two evidence checks toast the same string afterwards: a reading of ≥ 60 chars whose utterances all "finish" in < 600 ms (`app.js:24324`), or one that never fires `onstart` within 4 s while `speechSynthesis.speaking || pending` is false (`app.js:24347`); both then `readAloudStop()`. Voice ranking (`voiceScore`, `app.js:49644`; `callPickVoice` `app.js:49671`): known-male names first, unknown second, known-female last; quality regex `/google|natural|premium|enhanced|neural/` and `default` only break ties. Native: `AVSpeechSynthesizer` with `AVSpeechSynthesisVoice(language: "ar-SA")`, preferring a male voice by name (e.g. Maged/Tarik), same refusal strings.
- Stop (`readAloudStop`, `app.js:24250`): bump token, pause, `removeAttribute("src")` + `load()` (never `src=""`), cancel synthesis, reset the button label to `listen`.

### 8.2 "Listen on" read queue (`readQueueStart`, `app.js:24790`) — desktop only

Offered on a message only when a later readable message exists, and **never** on `max-width: 640px`, UI 2.0, the share page, Code or Brain (`rqOffScreen`, `app.js:24470`) — so iPhone parity does not require it; iPad may. Strings: `rqStart` `اسمع من هنا` / `Listen on`; `rqHint` `يقرأ المحادثة بصوتٍ عالٍ من هذه الرسالة إلى آخرها، ويتخطّى الشيفرة` / `Reads the thread aloud from this turn to the end, skipping code`; `rqPrev` `السابق` / `Previous`; `rqNext` `التالي` / `Next`; `rqPause` `إيقاف مؤقّت` / `Pause`; `rqResume` `متابعة` / `Resume`; `rqClose` `إنهاء القراءة` / `End reading`; `rqDone` `انتهت المحادثة` / `End of the conversation`; `rqEmpty` `لا يوجد نصّ يُقرأ هنا` / `Nothing here to read aloud`. Items: user+assistant messages whose speakable text is ≥ `RQ_MIN_SPEAK = 12` chars and that are not ```` ```firas-* ```` cards; bar shows `msgHitYou`/`msgHitAi` and `n / total`; 400 ms tick; pause/resume must remember which transport was paused (`rqHush`/`rqUnhush`, `app.js:24678-24710`).

### 8.3 `POST /api/tts` (`handleTts`, `server.mjs:5731`)

Body (JSON ≤ 200 000 bytes):

| Field | Type | Rules |
| --- | --- | --- |
| `text` | string | whitespace collapsed to single spaces, trimmed, sliced to **1400** chars; empty → `400` with empty body |
| `lang` | string | lowercased; starts with `ar` → `"ar"`; matches `/^[a-z]{2}(-[a-z]{2})?$/` → first two letters; else `"en"`. The raw value (e.g. `ar-iq`) is what picks the Edge dialect voice |
| `gender` | string | optional; anything other than `"male"`/`"m"` → `400 {"error":"only a male voice is available"}` |
| `voice` | string | optional Edge voice name, honoured only if in `EDGE_VOICE_ALLOW` (values of `EDGE_VOICES`, `server.mjs:5405`, e.g. `ar-IQ-BasselNeural`, `ar-SA-HamedNeural`, `en-US-AndrewMultilingualNeural`) |
| `slow` | bool | only affects the disabled Google fallback |

Order: 401 `{"error":"authentication required"}` → 429 `{"error":"rate limited"}` (25/90 per min) → 400 `{"error":"invalid JSON body"}` → 400 empty text → **voice charge** (429 denial) → gender 400 → engine ladder:

1. `lang === "ar"` and `TTS_PRIMARY !== "openai"`: Gemini TTS `gemini-2.5-flash-preview-tts`, voice `Sadaltager` (female names refused), acting-direction prompt `geminiTtsStyle` (`server.mjs:5633`), server-side cache of 40 clips → `200 audio/wav`, headers `X-TTS-Engine: gemini`, `X-TTS-Voice: Sadaltager`, `X-TTS-Gender: male`.
2. OpenAI `gpt-4o-mini-tts` voice `onyx`, input sliced 4000 → `200 audio/mpeg`, `X-TTS-Engine: openai`.
3. Microsoft Edge neural (male map per language) → `200 audio/mpeg`, `X-TTS-Engine: edge`, `X-TTS-Voice: <name>`.
4. Non-Arabic only: Gemini second try → `audio/wav`.
5. `503 {"error":"tts unavailable","reason":"no male voice engine available"}` unless env `TTS_ALLOW_FEMALE_FALLBACK` enables Google Translate TTS (`audio/mpeg`, `X-TTS-Gender: female`, 190-char chunks ≤ 14, `502 {"error":"tts unavailable"}` / `{"error":"tts empty"}` on failure).

Every success sets `Cache-Control: no-store` and `Content-Length`. The client never reads `X-TTS-*`. The native client should decode by `Content-Type` (`audio/wav` vs `audio/mpeg`), never by assumption.

---

## 9. Settings → Voice tab (`tabVoice` `الصوت` / `Voice`, `app.js:45634-45635`, `45750`, `45858`, `46090`)

- `voiceH` `صوت المكالمة` / `Call voice`; `voiceSub` `يُطبَّق على مكالمتك القادمة` / `applies to your next call`; `voiceNote` `أصوات المكالمة المباشرة. جرّب حتى تجد الأقرب إلى أذنك.` / `Live-call voices. Try a few until one sounds right.` — a `<select dir="ltr">` over `CALL_VOICES` (`cedar, ash, verse, echo, ballad`, shown as raw names), saved via `firasSetCallVoice` → `localStorage firas_call_voice`, sent as `voice` on the next mint. Applies only to the OpenAI engine.
- Dictation dialect select (§7.2).

---

## 10. Native implementation notes (from the two skills, condensed)

1. Ladder and naming: mint → OpenAI (WebRTC preferred on iOS too) → re-mint `prefer:"gemini"` within 90 s → three-hop. Every exit must record a reason; a silent downgrade is the bug.
2. Two clocks on every live engine: hard cap `maxMs − 1500 ms` (explain the guest cap **before** closing) and 45 s idle hang-up fed by session events.
3. Mute always wins over the echo gate; the gate needs its 20 s safety reopen; reopen +280 ms after `response.done`.
4. Teardown stops every input track, closes every context/connection, nulls handles, and runs first in `callEnd`.
5. One speaker at a time: a monotonically increasing token checked after every await; Listen refuses during a call; a call kills the read queue.
6. Device TTS: pick the voice before speaking; no voice for the language → say so with `listenNoVoiceAr`/`listenNoVoice` and reset the button; lenient in a call, strict for Listen.
7. Sentence splitting must include `؟ ، ؛`; keep chunks ≤ 1300 and finish the paragraph on the device after a 429 — never restart from chunk 0.
8. Never send `lang` alone with a mismatched voice; `u.lang` comes from the chosen voice.
9. Dictation appends with one space, never replaces or auto-sends; auto-finish at 300 s; auto-finish when backgrounded; too-short/empty/failed each have their own string.
10. Realtime event names drift (`response.audio.delta` vs `response.output_audio.delta`); match on substring.

---

## 11. Existing iOS code to reconcile (`ios/FirasAI/Features/Chat/LiveVoiceController.swift`, 601 lines)

The Codex-written controller already implements **only the Gemini rung**: it mints with
`LiveVoiceTokenRequest(prefer: "gemini", voice: voice)` (`LiveVoiceController.swift:62`), opens
`LIVE_WS_BASE` (`:122`), sends the setup (`sendSetup`, `:175`, with `realtimeInputConfig` `:195`), streams
`realtimeInput.audio` PCM16 (`sendPCM16`, `:155`), schedules playback (`schedulePlayback`, `:439`) and models
`LiveVoiceConnectionState { idle, requestingPermission, connecting, connected, ended, failed(String) }` (`:6-13`).
Three consequences for the rewrite:

- Sending `prefer: "gemini"` on the **first** mint skips the OpenAI rung entirely (server §3: `prefer === "gemini"` bypasses
  `mintOpenAIRealtime`) and is still charged (the grace only waives a `prefer:"gemini"` mint that follows a charged one within
  90 s). The ladder in §2 requires the first mint to carry **no** `prefer`, and `prefer:"gemini"` only on the fallback leg.
- Its `LiveVoiceToken` decoder (`:20-27`) has no optional `voice` field; the OpenAI response (§3) includes `voice`, so decoding
  must tolerate it (and `provider:"openai"` must dispatch to a Realtime transport that does not exist yet).
- Its connection states do not distinguish `listening / thinking / speaking / muted`; the UI strings in §2.2 need the web's
  five phases plus the orthogonal `muted` flag, driven from the session events listed in §4 (OpenAI) and §5 (Gemini).

There is no native dictation, `/api/transcribe`, `/api/tts`, or three-hop code in `ios/` today (a case-insensitive grep for
`transcribe` and `api/tts` across `ios/**/*.swift` returns nothing); §6–§8 must be built from scratch.
