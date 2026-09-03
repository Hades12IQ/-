# The missing call button — what actually hides it, and the exact fix

Owner's complaint (#3): **«ميزة المكالمة ما موجود زرها يمهم»** — the call button is missing for
some people.

Scope: read-only analysis of `D:\Programming\Projects\FirasAI` on branch
`night/capabilities-and-code-ui` (the deployed tree). Every line number below was read out of that
working tree, not remembered. No file was modified.

Verdict up front: **there are four independent things that remove this button, and only one of them
is a browser problem.** The largest population is almost certainly not a capability failure at all —
it is the Agent product, where the button is hidden by CSS on purpose, on a preference that persists
across sessions. The genuine browser defect is real but narrower than it looks, and it is not the
browser everyone guesses (Firefox is fine).

---

## 0. The map — every gate between a user and `#callBtn`

The button is static markup, `index.html:791`:

```html
<button type="button" class="icon-btn composer__call" id="callBtn" aria-label="مكالمة صوتية" title="مكالمة صوتية — تحدّث مع فِراس">
```

It is cached at `app.js:50460` (`els.callBtn = $("#callBtn")`), and `initCall()` — `app.js:50095`,
called exactly once from `wireEvents()` at `app.js:50648` — decides its fate:

```js
function initCall() {
  if (!els.callBtn) return;
  if (!VOICE_CALL_ENABLED) { els.callBtn.style.display = "none"; els.callBtn.setAttribute("hidden", ""); return; }   // 50099
  if (!(callSRAvailable() || callMicAvailable())) { els.callBtn.style.display = "none"; return; }                    // 50100
  els.callBtn.addEventListener("click", callOpen);
```

`VOICE_CALL_ENABLED` is `true` (`app.js:23`), so line 50099 is dead code today. Line **50100** is
the live gate. The predicates, `app.js:48151-48158`:

```js
function callSRAvailable()   { return !!(window.SpeechRecognition || window.webkitSpeechRecognition); }
function callMicAvailable()  { return !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.MediaRecorder); }
function callSupported()     { return state.product === "ai" && (callSRAvailable() || callMicAvailable()); }
```

Then CSS can hide it a second time:

| file:line | rule | effect |
|---|---|---|
| `styles.css:7307-7308` | `body.product-agent .composer__call, body.product-code .composer__call { display: none; }` | **live** on Agent |
| `styles.css:8834` | `.product-brain .composer__call { display: none; }` | dead — `styles.css:8831` already `display:none`s `.composer-wrap` |
| `styles.css:5819` | `.product-code .chat-scroll,.product-code .composer-wrap{display:none}` | kills the whole composer in Code, so the 7308 half is dead too |
| `styles.css:13997-13999` | `:root[data-ui="2"] .composer__actions:has(.composer__send:not(:disabled)) .composer__call { display: none; }` | UI 2.0 only (opt-in, `app.js:3179`): the call button leaves the moment Send becomes enabled |

Nothing else in `styles.css` touches `#callBtn` or `.composer__call` with `display` (grep:
`composer__call` appears at 2454, 2456, 7307-7309, 8834, 13314, 13323, 13325, 13424, 13583, 13595,
13607, 13621, 13970-13998, 14153, 22006 — the rest are size/colour).

---

## 1. What the call engine ACTUALLY needs (the gate is measuring the wrong thing)

`callProceed()` (`app.js:50045`) gives the live engine first refusal, and only falls back to the old
three-hop path. The live path is `liveTryStart()` → `liveStartRealtime(tok)` at `app.js:48980`:

```js
async function liveStartRealtime(tok) {
  if (!window.RTCPeerConnection) return liveFail("this browser has no WebRTC");   // 48981
  ...
    liveCall.stream = await navigator.mediaDevices.getUserMedia({ ... });          // 48986
```

and the Gemini Live fallback at `app.js:49221` needs the same `getUserMedia` plus `WebSocket` +
`AudioContext`. **Neither live engine references `MediaRecorder`, and neither references
`SpeechRecognition`.** `MediaRecorder` appears on the call path in exactly one place — the *legacy*
three-hop recorder `callListenRecord()` at `app.js:49838-49839` — and `SpeechRecognition` in exactly
one — `callListenSR()`, reached from `app.js:49792`.

So the boot gate demands `MediaRecorder` for a call that does not use it, and accepts
`SpeechRecognition` for a call that does not use it either. Both directions are wrong, and both
produce a user-visible failure:

- **wrong-negative** — a browser with `getUserMedia` + WebRTC but no `MediaRecorder` and no
  `SpeechRecognition` gets no button, while the Realtime call would have worked perfectly.
- **wrong-positive** — a browser with `webkitSpeechRecognition` defined but `navigator.mediaDevices`
  undefined (any insecure origin in Chrome) passes the gate, shows the button, and then:
  `callOpen` → `callSupported()` true → `!callMicAvailable()` at `app.js:50022` is true so the
  consent screen is **skipped** → `callProceed` → `liveStartRealtime` throws on `getUserMedia` →
  Gemini throws on `getUserMedia` → `callListen` (`app.js:49791-49792`) → `callListenSR` → the
  SpeechRecognition call is itself blocked on an insecure origin. The user gets an orb, a running
  timer, and a call that never hears them. That is a worse outcome than no button.

---

## 2. Who really loses the button — enumerated honestly

The gate is false only when **both** predicates are false. Working through it:

| situation | `SpeechRecognition` | `mediaDevices.getUserMedia` | `MediaRecorder` | button? | could it have called? |
|---|---|---|---|---|---|
| Firefox desktop/Android, https | ✗ | ✓ | ✓ | **shown** | yes |
| Chrome/Edge desktop, https | ✓ | ✓ | ✓ | shown | yes |
| iOS Safari 14.5+ | ✓ | ✓ | ✓ | shown | yes |
| **iOS Safari 14.0–14.2** | ✗ (landed 14.5) | ✓ | ✗ (landed 14.3) | **HIDDEN** | **yes — WebRTC works on iOS 11+** |
| **iOS in-app webview (Instagram / Facebook / TikTok), iOS < 14.3** | ✗ (WKWebView never had it) | ✗ | ✗ | **HIDDEN** | no |
| iOS in-app webview, iOS 14.3+ | ✗ | ✓ | ✓ | shown | usually yes |
| Android WebView / Telegram in-app, https | ✗ (WebView has no Web Speech API) | ✓ | ✓ | shown | yes |
| **Android WebView on Android 5.x (pre-Chrome-47)** | ✗ | ✓ | ✗ | **HIDDEN** | yes (WebRTC present) |
| **Firefox over `http://<lan-ip>:1988`** | ✗ | ✗ (not a secure context) | ✓ but useless | **HIDDEN** | no |
| Chrome over `http://<lan-ip>:1988` | ✓ (constructor still defined) | ✗ | — | shown, **call is dead** | no |

**Confidence.** Rows that are pure code-reading of this repo — the `MediaRecorder`-not-needed logic
gap, and the insecure-origin wrong-positive — are CONFIRMED by reading. The specific browser-version
boundaries (iOS 14.3 / 14.5, Chrome 47, WKWebView) are my knowledge of the platforms, not something
I ran; treat them as PLAUSIBLE. The one-line probe that settles it on a real handset, pasted into any
remote-debug console on `https://firasai.org`:

```js
JSON.stringify({
  sr: !!(window.SpeechRecognition||window.webkitSpeechRecognition),
  md: !!(navigator.mediaDevices&&navigator.mediaDevices.getUserMedia),
  mr: !!window.MediaRecorder, rtc: !!window.RTCPeerConnection,
  sec: window.isSecureContext, prod: document.body.className,
  btn: getComputedStyle(document.getElementById('callBtn')).display, ua: navigator.userAgent })
```

`btn: "none"` with `md:true, rtc:true` proves finding **B**. `prod` containing `product-agent`
proves finding **A**. That is the whole diagnosis in one paste.

---

## 3. The finding I believe explains most of the reports

**The button is hidden on Firas Agent, on a preference that survives every reload.**

`styles.css:7307-7308` hides it under `body.product-agent`, with the comment "The call button is a
Firas-AI-only feature — hide it on Agent/Code." `state.product` is restored from `localStorage` at
`app.js:3194`:

```js
state.product = (savedProduct === "agent" || savedProduct === "code" || savedProduct === "brain") ? savedProduct : "ai";
```

So a student who tried Firas Agent once, and never explicitly switched back, opens the app on Agent
for the rest of time — with a composer that has a mic and a send button and **no call button, and
nothing anywhere that says the call lives in Firas AI**. There is no toast, no disabled state, no
tooltip. From the outside this is indistinguishable from "the feature was removed", which is exactly
the shape of the owner's complaint and exactly the shape of complaint #9 («متراجع هواي») — nothing
regressed, the user is standing in a different room.

This costs zero browser work to confirm: ask one complaining user to open the product rail and pick
**فِراس AI**. If the button reappears, this is the whole bug for them.

Whether Agent *should* hide the call is a product decision, not a defect — but hiding it **silently**
is. See fix F4.

---

## 4. The structural defect behind all of it: the gate runs once and writes an inline style

`app.js:50100` writes `els.callBtn.style.display = "none"`. An inline declaration outranks every
selector in `styles.css` that lacks `!important`, and **nothing in the codebase ever clears it** —
`callBtn` appears in `app.js` at only five places (50096, 50099, 50100, 50101, 50460) and none of
them removes the property. So:

- the decision is permanent for the session, and
- it is *stronger* than the product CSS, meaning any future JS that writes `display` on the success
  branch would silently defeat `styles.css:7307`.

This matters because the two things the answer depends on **do** change during a session:
`state.product` (`setProduct`, `app.js:59996`) and the microphone permission — which the file already
watches. `app.js:48112-48121` holds a live `PermissionStatus.onchange` subscription:

```js
    st.onchange = () => { if (st.state === "granted") micRemember(); else if (st.state === "denied") micForget(); };
```

That is the exact hook a re-evaluation belongs on, and it is already wired. Raw capability
(`mediaDevices`, `RTCPeerConnection`) genuinely cannot change mid-session — I am not claiming it can —
but *permission* and *product* can, and the button's explanation must track them.

---

## 5. The precedent this file already set — and half-finished

`initMic()` at `app.js:47986-48009` solved this exact problem for the microphone and wrote the
reasoning down:

> Silently deleting the button made that look like a missing feature. It now STAYS, and says what
> is wrong when tapped — an unavailable control that explains itself beats a control that vanishes.

`initCall()` never got the same treatment. It should — with one correction: **`initMic`'s
`is-unavailable` class is not styled anywhere.** `grep -ain "unavailable" styles.css` returns exactly
one hit, a prose comment at line 13339. So `app.js:48001`'s
`els.micBtn.classList.add("is-unavailable")` currently changes nothing visually, and the only signal
is a `title` tooltip — which does not exist on a touch device, i.e. on precisely the phones the
comment was written about. Any fix that reuses the pattern must ship the CSS with it.

---

## 6. The fixes

### F1 — Replace the capability predicates with ones that describe the real engines
**File:** `app.js` · **Anchor (unique, verified):**
```js
function callMicAvailable() { return !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.MediaRecorder); }
```
(line 48153; `callMicAvailable` is also read at 49791, 50022 and 50100 — keep the name and its
meaning, it correctly means "the legacy recorder path can run".) **Insert after it:**

```js
/* WHAT THE CALL ACTUALLY NEEDS, split by engine — because the two answers are different and the
   boot gate used to ask only the second one. liveStartRealtime (app.js:48980) needs a microphone
   and WebRTC; the Gemini Live fallback (app.js:49221) needs a microphone, a WebSocket and an
   AudioContext. NEITHER touches MediaRecorder, and neither touches SpeechRecognition. Demanding
   MediaRecorder here refused the button to browsers that could have taken a Realtime call. */
function callLiveCapable() {
  const AC = window.AudioContext || window.webkitAudioContext;
  return !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia &&
    (window.RTCPeerConnection || (window.WebSocket && AC)));
}
/* The three-hop fallback: browser transcription, or a recorder posting to /api/transcribe. */
function callLegacyCapable() { return !!(callSRAvailable() || callMicAvailable()); }
function callAnyCapable() { return callLiveCapable() || callLegacyCapable(); }
```

**Anchor 2 (unique):**
```js
function callSupported() {
  return state.product === "ai" && (callSRAvailable() || callMicAvailable());
}
```
**Replace with:**
```js
function callSupported() {
  return state.product === "ai" && callAnyCapable();
}
```

### F2 — Make the gate a re-runnable function, and never write an inline `display` on success
**File:** `app.js` · **Anchor (unique, line 50100):**
```js
  if (!(callSRAvailable() || callMicAvailable())) { els.callBtn.style.display = "none"; return; }
```
**Replace with:** `callSyncBtn();` and add the function immediately above `function initCall() {`:

```js
/** Decide the call button's appearance from CURRENT state, every time it is asked — never once at
    boot, and NEVER by writing an inline `display`. An inline declaration outranks
    `body.product-agent .composer__call{display:none}` (styles.css:7307), so the success branch has
    to hand the property back to the stylesheet rather than set a value of its own. */
function callSyncBtn() {
  if (!els.callBtn) return;
  const b = els.callBtn;
  if (!VOICE_CALL_ENABLED) { b.style.display = "none"; b.setAttribute("hidden", ""); return; }
  b.style.removeProperty("display");
  b.removeAttribute("hidden");
  const why = callWhyUnavailable();
  if (!why) {
    b.classList.remove("is-unavailable");
    b.removeAttribute("aria-disabled");
    b.title = t().callLabel;
    b.setAttribute("aria-label", t().callLabel);
    return;
  }
  /* IT STAYS AND EXPLAINS ITSELF — the same decision initMic() already made (app.js:47988).
     A control that vanishes reads as a feature that was removed; the report this fixes was
     literally "ميزة المكالمة ما موجود زرها". */
  b.classList.add("is-unavailable");
  b.setAttribute("aria-disabled", "true");
  b.title = why;
  b.setAttribute("aria-label", why);
}
/** "" when the call can run; otherwise the sentence to show, in the shell language. */
function callWhyUnavailable() {
  const L = t();
  if (state.product !== "ai") return L.callOnlyInAi || L.callUnsupported;
  if (!window.isSecureContext) return L.callNeedsHttps || L.callUnsupported;
  if (!callAnyCapable()) return L.callUnsupported;
  return "";
}
```

`callWhyUnavailable` must be defined before `callSyncBtn` runs, but both are hoisted function
declarations, so file order does not matter.

### F3 — Re-evaluate at the three moments the answer can change
1. **Boot** — already covered: `initCall()` calls `callSyncBtn()` (F2).
2. **Product change.** `app.js` · anchor (unique, inside `updateProductUi`, line ~59961):
   ```js
     document.body.classList.toggle("product-brain", brain);
   ```
   append on the next line: `try { callSyncBtn(); } catch (_) {}`
   This is what makes the Agent case explain itself instead of vanishing, and it also refreshes the
   Arabic/English label when `applyShellLang` re-runs through this path.
3. **Microphone permission change.** `app.js` · anchor (unique, line 48120):
   ```js
       st.onchange = () => { if (st.state === "granted") micRemember(); else if (st.state === "denied") micForget(); };
   ```
   replace with:
   ```js
       st.onchange = () => {
         if (st.state === "granted") micRemember(); else if (st.state === "denied") micForget();
         try { callSyncBtn(); } catch (_) {}
       };
   ```
   Guarded because this IIFE resolves asynchronously and may land before `cacheEls()` has run;
   `callSyncBtn` already returns early on a missing `els.callBtn`, and the `try` covers the rest.

### F4 — Stop the Agent from hiding the button silently
Two options; **pick one and say which in the commit.**

- **F4a (smaller, recommended first):** keep `styles.css:7307-7308` as-is and let F3.2 give the
  button an explanation — but the CSS `display:none` wins, so the tooltip never shows. To make F4a
  actually work, narrow the rule to Code only and let the JS do Agent:
  **anchor (unique):**
  ```css
  body.product-agent .composer__call,
  body.product-code .composer__call { display: none; }
  ```
  **replace with:**
  ```css
  /* Code has no composer at all (see .product-code .composer-wrap, styles.css:5819), so this
     rule only ever governed Agent. Agent now keeps the button and disables it with a reason —
     callSyncBtn() in app.js — because a control that disappears reads as a feature that was
     removed, which is exactly how «ميزة المكالمة ما موجود زرها» was reported. */
  body.product-agent .composer__call.is-unavailable { opacity: .45; cursor: not-allowed; }
  ```
- **F4b:** leave Agent hiding the button, and instead make the **product rail** say where the call
  lives. More work, no CSS risk. Do not do both.

Also delete the two dead rules while you are in there — `styles.css:8834`
(`.product-brain .composer__call`) and the `body.product-code` half above — each is fully shadowed
by a `.composer-wrap { display: none }` on the same product (`styles.css:8831`, `styles.css:5819`).
Cosmetic, but they are what made this look like four gates instead of one.

### F5 — Ship the `.is-unavailable` style that `initMic` has been missing
**File:** `styles.css` · this class is currently referenced from `app.js:48001` and defined nowhere.
**Anchor (unique, line 7309):**
```css
.composer__call svg { width: 20px; height: 20px; }
```
**Insert after:**
```css
/* An unavailable composer control STAYS and says why (app.js:47988, app.js:callSyncBtn). Until
   now `is-unavailable` was added by initMic and styled by nothing, so the only signal was a
   `title` — which does not exist on a touch device, i.e. on exactly the phones that hit it. */
.composer__mic.is-unavailable,
.composer__call.is-unavailable {
  opacity: .45;
  cursor: not-allowed;
}
.composer__mic.is-unavailable:hover,
.composer__call.is-unavailable:hover { background: transparent; border-color: transparent; }
```

### F6 — Two new i18n keys, both tables
**File:** `app.js` · Arabic anchor (unique, line 256):
```js
    callUnsupported: "المكالمة الصوتية غير مدعومة على هذا المتصفح.",
```
**Replace with:**
```js
    callUnsupported: "المكالمة الصوتية غير مدعومة على هذا المتصفح.",
    callNeedsHttps: "المكالمة الصوتية تحتاج اتصالًا آمنًا (HTTPS). افتح الموقع عبر https.",
    callOnlyInAi: "المكالمة الصوتية متاحة في فِراس AI — بدّل المنتج من الشريط الجانبي.",
```
English anchor (unique, line 1378):
```js
    callUnsupported: "Voice calls aren't supported in this browser.",
```
**Replace with:**
```js
    callUnsupported: "Voice calls aren't supported in this browser.",
    callNeedsHttps: "Voice calls need a secure connection (HTTPS). Open the site over https.",
    callOnlyInAi: "Voice calls live in Firas AI — switch product from the rail.",
```
Both anchors are unique in the file (`grep -ac 'callUnsupported' app.js` → 3 hits total: 256, 1378,
49981; the two string-table lines differ by their value, so each replacement string is unique).
Per AGENTS.md the tier ladders and i18n tables have near-identical copies — these two do not, but
assert `count == 1` in the patch script anyway.

### F7 — Close the wrong-positive: never open a call screen that cannot hear
**File:** `app.js` · anchor (unique, line 50022):
```js
  if (!callMicAvailable() || call.micGranted || await micAlreadyGranted()) { callProceed(); return; }
```
The `!callMicAvailable()` clause means "there is no microphone to ask for, go straight to
SpeechRecognition". That is right for the legacy path and wrong now: it also fires when
`navigator.mediaDevices` is undefined on an insecure origin, and takes the caller into a call screen
whose every engine will fail. **Replace with:**
```js
  /* Skip our consent gate only when there is genuinely no microphone to ask about AND the legacy
     SpeechRecognition path can still carry the call. On an insecure origin mediaDevices is
     undefined while webkitSpeechRecognition is still DEFINED, so the old test sent the caller into
     a call screen that no engine could answer — an orb, a running timer, and silence. */
  if (!navigator.mediaDevices && !callSRAvailable()) { showToast(t().callNeedsHttps); callEnd(); return; }
  if (!callMicAvailable() || call.micGranted || await micAlreadyGranted()) { callProceed(); return; }
```
(`callEnd` is `app.js:50070`, `showToast` is used throughout — both verified present.)

---

## 7. What I am NOT claiming

- **Firefox is not the bug.** It has no `SpeechRecognition`, but it has `getUserMedia` and
  `MediaRecorder`, so `callMicAvailable()` is true and the button shows. Reporting Firefox here
  would have been a false positive.
- **Capability does not change mid-session.** `navigator.mediaDevices` and `RTCPeerConnection`
  either exist at boot or never do. F3 is about *product* and *permission* changing, and about the
  inline style outranking the product CSS — not about a capability appearing late.
- **The UI 2.0 `:has()` rule is intended,** and UI 2.0 is opt-in and off by default
  (`app.js:3179`, `localStorage.getItem(LS_UI2) === "1"`). Its one rough edge: `updateSendState()`
  (`app.js:36424-36431`) enables Send when a *file or image* is ready even with an empty text box, so
  attaching a photo makes the call button vanish. Minor, UI-2-only, listed for completeness.
- **Nothing here was run in a browser.** All of it is reading. The probe in §2 is the one command
  that converts §2's table from PLAUSIBLE to CONFIRMED, and it should be run on one real Iraqi
  handset — ideally one opened from an Instagram link — before F1 ships.
