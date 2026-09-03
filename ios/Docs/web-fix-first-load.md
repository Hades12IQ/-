# First load — what actually happens, measured

Scope: the owner's complaints #7 ("خلي فتحه سريع وتحميله قوي"), #2 ("بطيء كلش و يعلك مرات") and
#9 ("متراجع هواي… استخدامه صاير مو سلس"), through the lens of a cold visit on a weak connection.

Branch inspected: `night/capabilities-and-code-ui`. Everything below is a file:line from that tree
or a number from a command whose output is pasted in. Where I estimated rather than measured, it
says so in the line.

---

## 0. The headline, in one paragraph

`app.js` is **1,913,204 bytes gzipped on the live site right now** — measured, not estimated. On the
link I measured from (≈0.5 Mbps, which is in the same range as a weak Iraqi mobile connection) it
took **35.2 seconds** to arrive. Nothing in `index.html` is visible before JavaScript runs except a
one-time consent screen that every returning student has already dismissed, so the page is **blank
for that entire time**. When `app.js` finally runs, `init()` shows a MentronX splash whose minimum
duration is hard-coded to **3150 ms** (`app.js:46917`) and holds the app behind an opaque full-screen
overlay even when everything else is ready. There is no brotli, no service worker, no code splitting,
and no static shell. Those four facts are the whole story.

---

## 1. What the browser is told to do, in order

`index.html` (56,247 bytes on disk, 16,837 gzipped on the wire — measured):

| Line | Resource | Blocking? | Wire size |
| --- | --- | --- | --- |
| `index.html:227` | inline theme bootstrap | parser | ~0.4 KB |
| `index.html:263` | Google Fonts `css2?family=Reem+Kufi…&display=swap` | **render-blocking**, cross-origin | ~3 KB + 14 font files |
| `index.html:271` | `<link rel="stylesheet" href="styles.css?v=v45" />` | **render-blocking** | **324,571 B gz** |
| `index.html:278` | `marked@12.0.2` from jsdelivr, `defer` | **blocks `DOMContentLoaded`** | ~13 KB gz |
| `index.html:279` | `dompurify@3.0.11` from jsdelivr, `defer` | **blocks `DOMContentLoaded`** | ~8 KB gz |
| `index.html:280` | inline lazy loader for KaTeX/hljs/motion | idle after `load` | — |
| `index.html:316` | `firebase-config.js`, `defer` | blocks DCL | 1.3 KB |
| `index.html:318` | `<script defer src="app.js?v=v57"></script>` | **blocks `DOMContentLoaded`** | **1,913,204 B gz** |

The lazy loader at `index.html:280` is genuinely good work — KaTeX, mhchem, auto-render, highlight.js,
framer-motion and auto-animate are all pushed behind `requestIdleCallback` after `load`, and the app
degrades and re-renders when they arrive. **That part is not the problem and should not be touched.**

### Live measurements (curl against https://firasai.org, this machine)

```
index.html               size=16,837     ttfb=0.63s   total=0.89s
styles.css?v=probe       size=324,571    ttfb=0.50s   total=3.96s   (82 KB/s)
app.js?v=probe2          size=1,913,204  ttfb=0.56s   total=35.24s  (54 KB/s)
```

**Honest caveat:** I checked whether the 54 KB/s was Fly's fault by pulling a 167 KB file from
cdn.jsdelivr.net (67 KB/s) and 2 MB from speed.cloudflare.com (also slow). It is **this machine's
link that measures ≈0.5 Mbps**, not the origin — TTFB from Fly is a healthy 0.5 s. So Fly is serving
fine; the link is slow. That is precisely why the measurement is useful: it is an accidental but
faithful stand-in for the Iraqi mobile connection the task asked about.

### Scaled to three link speeds (from the measured byte counts)

| Link | app.js today (gz 1.91 MB) | app.js with brotli (1.40 MB) | styles.css today (325 KB) | with brotli (241 KB) |
| --- | --- | --- | --- | --- |
| 0.5 Mbps (~64 KB/s) | **30 s** | 22 s | 5.1 s | 3.8 s |
| 1.5 Mbps (~190 KB/s) | **10.1 s** | 7.4 s | 1.7 s | 1.3 s |
| 5 Mbps (~640 KB/s) | 3.0 s | 2.2 s | 0.5 s | 0.4 s |

---

## 2. What the user sees in the first second — and the next thirty

`index.html` body, element by element:

- `index.html:376` `<main id="seoIntro" class="fw">` — the consent/welcome screen. **Visible by
  default**, but the inline script at `index.html:426` removes it during HTML parsing for anyone who
  has already set `firas_welcome_v1`. That is every existing student.
- `index.html:477` `<div class="landing" id="landingScreen" hidden>`
- `index.html:504` `<div class="auth" id="authScreen" hidden>`
- `index.html:574` `<div class="app" id="appShell" hidden>`

So for a returning user the entire body is either removed or `hidden`. **After the browser finishes
`styles.css` it paints an empty page in `var(--color-bg)` and paints nothing else until `app.js` has
downloaded, parsed, evaluated, and `init()` has reached `bootApp` → `hideAuthScreen()`
(`app.js:46715`, `els.appShell.hidden = false`).**

Timeline on the measured 0.5 Mbps link, cold cache:

```
0.0 s   request
0.9 s   index.html done — nothing paints (styles.css is render-blocking)
~5 s    styles.css done — FIRST PAINT: a blank coloured rectangle
5–38 s  still blank. app.js is downloading at Low priority.
~38 s   app.js evaluates, DOMContentLoaded, init() runs
~38 s   mxIntroStart() paints the MentronX overlay (app.js:46920)
~39 s   /api/auth/me returns, bootApp() renders the shell BEHIND the overlay
41.5 s  intro.finish() releases: 3150 ms floor + 360 ms fade  →  usable
```

On a warm cache (the common case — `app.js?v=…` is `public, max-age=31536000, immutable`, confirmed
live) the same visit is roughly: 0.3 s index.html revalidation + ~0.3–0.6 s script evaluation on a
phone + 2 round trips of API + **3.51 s of splash**. The splash is then ~75 % of the wait.

---

## 3. What runs at boot, before anything is interactive

Top-level side effects in `app.js` are almost nil — I checked, and there are exactly two top-level
IIFEs (`app.js:28988` `barGatesWatch`, `app.js:80694` `initFirasNativeShell`) and two bare calls
(`app.js:80008` `installHeldImageLoader()`, `app.js:80680` `installBgJobReattach()`). The file is
almost entirely declarations. **That is the good news: the boot cost is transfer and parse, not
top-level execution.**

V8 compile cost, measured with `vm.Script` on this desktop:

```
app.js compile (lazy pre-parse, no eval): 51 ms   (5,652,847 bytes)
app.js compile with code cache:           14 ms
```

51 ms desktop → **estimated 250–400 ms on a mid-range Android**, plus top-level evaluation
(allocating the function objects and the very large string literals), which I could not measure
without a DOM. Call it **0.3–0.6 s on a phone**. Real, but an order of magnitude below the transfer.

`init()` (`app.js:79906`) then runs, in order: `dropSeoIntro`, `loadState` (≈20 `localStorage` reads,
one `try` — `app.js:3156`), `cacheEls` (60 `querySelector` calls — `app.js:50434`),
`startVersionWatch` (**fires a network request immediately** — `app.js:79920`), `setupAuthChannel`,
`setupCookieConsent`, `injectBrandMarks`, the eight `apply*` functions, three `build*` switches,
`applyShellLang` (three `querySelectorAll("[data-i18n*]")` passes over a 328-element document —
`app.js:13704`), `wireEvents` (~300 listeners — `app.js:50497`), `wireAuth`, `autoGrow`,
`updateSendState`. **All of that is single-digit milliseconds on a phone.** It is not where the time
goes, and I am not going to pretend otherwise.

Then the network chain, which *is* serial:

```
app.js:79962   const data = await apiJson("/api/auth/me");     ← RTT 1
app.js:79964   await bootApp(user)
app.js:47198     await fetchChats()
app.js:3372        const list = await apiJson("/api/chats");   ← RTT 2 (serial after RTT 1)
```

Frankfurt (`fly.toml:6 primary_region = "fra"`) from Iraq is roughly 120–200 ms RTT, so that is
~0.3–0.5 s of avoidable serialisation. `/api/chats` returns metadata only (`messages: null`,
`app.js:3385`) — that part is already right.

---

## 4. Findings

### F1 — `app.js` is served gzip-only; brotli is a Node built-in and saves 508 KB `[critical]`

`server.mjs:13300` `const GZIP_TYPES = …` and `server.mjs:13482` compress text with
`gzipSync(raw, { level: 6 })` (`server.mjs:13305`) and set `Content-Encoding: gzip`. Confirmed live:
a request advertising `Accept-Encoding: gzip, deflate, br, zstd` comes back `content-encoding: gzip`.

Measured with `node:zlib` on the real files (no npm — `brotliCompressSync` ships with Node):

| File | gzip L6 (today) | brotli q9 | brotli q11 | saving at q11 |
| --- | --- | --- | --- | --- |
| `app.js` | 1,907,505 | 1,533,774 (359 ms) | **1,399,892** (7.9 s) | **−507,613 B (−27 %)** |
| `styles.css` | 324,571 | — | **240,629** (1.67 s) | **−83,942 B (−26 %)** |
| `index.html` | 16,687 | — | 13,795 | −2,892 B |

**Total −594,447 bytes off every cold visit and every post-deploy visit** — about **9 s at 0.5 Mbps**,
**3.1 s at 1.5 Mbps**.

One hazard to design around: `brotliCompressSync` at q11 blocks the event loop for **7.9 s** on this
desktop and would be far worse on the 512 MB `shared-cpu-1x` (`fly.toml:41`). The existing
`gzipSync` already blocks for 111 ms, which the first visitor after every deploy pays today.

**Patch shape.** In `server.mjs`, beside `gzipFor` (`server.mjs:13302`):

```js
const _brCache = new Map();          // key -> { mtime, buf }
const _brPending = new Set();
function brFor(key, raw, mtimeMs) {
  const hit = _brCache.get(key);
  if (hit && hit.mtime === mtimeMs) return hit.buf;
  if (!_brPending.has(key)) {        // warm asynchronously; never block the loop
    _brPending.add(key);
    brotliCompress(raw, { params: {
      [constants.BROTLI_PARAM_QUALITY]: 11,
      [constants.BROTLI_PARAM_SIZE_HINT]: raw.length,
    } }, (e, buf) => { _brPending.delete(key); if (!e) _brCache.set(key, { mtime: mtimeMs, buf }); });
  }
  return null;                       // not ready → caller falls back to gzip this once
}
```

Then replace the branch at `server.mjs:13482` (exact anchor, matches once):

```js
    if (GZIP_TYPES.has(ext) && String(req.headers["accept-encoding"] || "").includes("gzip")) {
```

with an accept-encoding test that prefers `br`, calls `brFor(...)`, and falls through to the
existing `gzipFor(...)` when it returns `null`. Change the import at `server.mjs:28`
(`import { gzipSync } from "node:zlib";`) to also pull `brotliCompress` and `constants`. Warm both
caches for `app.js`, `styles.css` and `index.html` once at server boot so the first real visitor
after a deploy never pays the compression.

`Vary: Accept-Encoding` is already set (`server.mjs:13528`) and the ETag is computed on the encoded
bytes (`server.mjs:13513`), so different encodings already get different tags. **No parity concern
with `netlify/edge-functions/api.js`** — Netlify compresses at its own edge.

### F2 — Every returning visit is deliberately held for 3.15 s by the MentronX splash `[critical]`

`app.js:46917`:

```js
const MX_MIN_MS = 3150;      // full performance: draw + cross + lockup, then a LONGER breath — Firas asked the lockup to sit a moment before the site opens
const MX_MIN_REDUCED = 900;  // reduced motion: the finished lockup, briefly, no theatre
```

`app.js:79960` starts it for anyone with `LS_HAD_SESSION` — i.e. every existing student —
and `app.js:79964` awaits it *after* the app is already rendered:

```js
    if (user) { await bootApp(user); await intro.finish(); return; }
```

`finish()` (`app.js:46953`) sleeps `MX_MIN_MS - elapsed`, then `remove(false)` and another
`await new Promise(r => setTimeout(r, 360))`. The overlay is `position: fixed; inset: 0;
background: var(--color-bg); z-index: 4000` with pointer events live until `.is-out`
(`styles.css:5534`, `styles.css:5540`). **Floor: 3510 ms during which the app is finished, painted,
and unreachable.**

This is not a bug — the comment says the owner asked for the longer breath. But it is also, on a
warm cache, roughly three quarters of the total wait, and the same owner is now saying
"خلي فتحه سريع". Both facts are true and he should decide with the number in front of him.

**Patch shape.** Smallest version: `const MX_MIN_MS = 1200;` (anchor `const MX_MIN_MS = 3150;`,
matches once). Better version: keep the full performance for a genuinely first visit of the day and
use ~900 ms otherwise — gate on a `localStorage` date stamp read inside `mxIntroStart()`. Either
way, remove the trailing `await new Promise((r) => setTimeout(r, 360));` in `finish()` — the overlay
is already `pointer-events: none` at that point, so that 360 ms buys nothing but delay.

### F3 — The page is blank for the whole download; there is no static shell `[critical]`

There is no defect in a single line here — it is an absence. `#landingScreen`, `#authScreen` and
`#appShell` are all `hidden` in the markup (`index.html:477`, `:504`, `:574`), and `#seoIntro` is
removed by `index.html:426` for returning users. Nothing in the document is visible without JS.

That converts a slow load into an apparently **broken** one, which is exactly the shape of
"يعلك مرات" and "متراجع هواي": people do not report "slow", they report "it froze".

**Patch shape.** Two edits, no JS framework, no build step:

1. In `index.html`, immediately before `<link rel="stylesheet" href="styles.css?v=v45" />`
   (anchor matches once), add a small `<style>` with the splash rules *inline in `<head>`*, and add
   a `<div id="bootSplash">` as the first child of `<body>` — the brand mark plus a slow
   `@keyframes` pulse, using the same `var(--color-bg, #262624)` fallback the `.fw` block at
   `index.html:336` already uses so it works before `styles.css` lands.
2. In `app.js`, remove it at the three points where a real screen becomes visible — one line each,
   `try { const b = document.getElementById("bootSplash"); if (b) b.remove(); } catch (_) {}`:
   - `mxIntroStart()` right after `document.body.appendChild(ov);` (`app.js:46935` — **that
     exact line appears 31 times in `app.js`; anchor on the surrounding `ov.className =
     "mx-intro";` block, not on `appendChild(ov)` alone**)
   - `showLanding()` at `app.js:15157`
   - `hideAuthScreen()` at `app.js:46713` (this is the `els.appShell.hidden = false` path)
   - and `showAuthScreen()` at `app.js:46703`

   Do **not** put it at the top of `init()` — that reintroduces the blank frame.

Saves zero milliseconds. Changes what 35 seconds *feels* like, which is what the owner asked for.

### F4 — `marked` and `dompurify` come from jsdelivr and gate `DOMContentLoaded` `[major]`

`index.html:278` and `index.html:279` load two third-party scripts with `defer`. A `defer` script
delays `DOMContentLoaded` until it resolves — and `init()` is wired to exactly that
(`app.js:80682-80683`). If `cdn.jsdelivr.net` is slow or unreachable from an Iraqi carrier, **the
entire app boot waits on a foreign CDN's TCP timeout**, which can be 30 s or more. The failure looks
identical to a hang.

The renderer already degrades safely without them — `app.js:7051` reads `typeof window.marked` and
`typeof window.DOMPurify` and falls through to `basicFormat`, which escapes everything
(`app.js:7080`, `app.js:7092`). So the dependency is a boot-order accident, not a requirement.

**Patch shape (preferred, lowest risk).** Vendor both files into the repo (`vendor/marked.min.js`,
`vendor/purify.min.js` — ~62 KB total, no npm involved, they are single files), point the two
`<script defer src=…>` tags at them, add the two paths to `STATIC_ALLOW` (`server.mjs:13139`, anchor
`const STATIC_ALLOW = new Set([`), and drop the two `cdn.jsdelivr.net` preconnects at
`index.html:251-252` **only if** nothing else uses that origin — the lazy loader at `index.html:280`
still does, so keep them. Same-origin means one already-open connection, immutable caching, and no
Iraqi-carrier reachability risk.

**Alternative (do not do this without the second half):** switch both to `async`. That removes them
from `DOMContentLoaded`, but breaks today's guarantee that they exist when `app.js` runs, so it
*must* be paired with an `onload` handler that calls `invalidateTurnCache()` (exists,
`app.js:20267`) and re-renders. The vendoring option avoids the whole question.

### F5 — `startVersionWatch()` fires a request at boot and reloads every tab on every deploy `[major]`

`app.js:79920` calls `startVersionWatch()` as the fourth statement of `init()`. Its body
(`app.js:50804`) calls `check()` synchronously, which does
`fetch("/api/version", { cache: "no-store" })` — an extra request competing with `/api/auth/me` at
the exact moment the app is trying to become interactive — and then `setInterval(check, 15000)`
forever, including in a hidden background tab.

Worse, when the version moves it does:

```js
        setTimeout(() => location.reload(), 700);
```

with no jitter and no visibility check. On every `fly deploy` **every open tab in Iraq reloads within
the same 15-second window**, and each one pulls 1.91 MB from a single 512 MB `shared-cpu-1x` machine
with `min_machines_running = 1` (`fly.toml:41`, `fly.toml:33`). That is a self-inflicted thundering
herd, and it is a strong candidate for both "يعلك مرات" and the sense that the app **regressed** —
the owner deploys often, so users meet the full cold download repeatedly.

**Patch shape.** In `startVersionWatch` (`app.js:50804`):
- replace the bare `check();` with `setTimeout(check, 8000);` so boot is not competing with itself;
- add `if (document.hidden) return;` at the top of `check`, and re-arm on `visibilitychange`;
- replace the fixed 700 ms with `700 + Math.random() * 20000` so the herd spreads over 20 s;
- raise the interval from `15000` to `60000` — four times fewer requests per user per minute against
  the single instance.

### F6 — 225 KB of Firas Code game-genre recipes ship to every chat user `[major]`

`app.js:61933` `const CW_GENRE_RECIPES = [` … `];` ends at `app.js:61966`. Measured:
**224,947 bytes raw, 88,140 bytes gzipped, 32 entries.** It has exactly **one** consumer —
`cwGameGenreRecipe` at `app.js:61967`, whose only call site is inside `cwBrain` at `app.js:61827`,
which only runs when someone builds a project in Firas Code.

**Honest correction to an assumption I started with:** I expected the 32 giant `new RegExp(...)`
constructions to be a boot CPU cost. They are not — V8 defers regex compilation until first use.
Measured in Node: constructing all 32 takes **0.32 ms**; the first `.test()` across all 32 costs
5.37 ms, and that only happens when a game is actually requested. **The cost of this block is
bandwidth only, and it is 88 KB gzipped — 4.6 % of `app.js` on the wire.**

**Patch shape.** Move lines `61933`–`61966` verbatim into a new file `code-recipes.js` at repo root,
changing only the first line to `window.CW_GENRE_RECIPES = [`. Then:

- Rewrite `cwGameGenreRecipe` (`app.js:61967`). Current body, anchor matches once:

  ```js
    for (const g of CW_GENRE_RECIPES) { try { if (g.re.test(s)) return g.recipe; } catch (_) {} }
  ```

  becomes a read of `window.CW_GENRE_RECIPES`, returning `""` when it is not loaded yet.
- Add `function cwEnsureRecipes()` that injects `<script src="code-recipes.js?v=…">` once, and call
  it from wherever the Code product is entered — `setProduct` (grep `setProduct` before writing;
  do not assume the name of the branch inside it).
- Add `"code-recipes.js"` to `STATIC_ALLOW` (`server.mjs:13139`).
- Extend the cache-busting rewrite at `server.mjs:13473` — the regex is
  `/(src|href)="(app\.js|styles\.css)\?v=[^"]*"/g` — so it also stamps `code-recipes.js`, *or*
  build the URL client-side from the version already on the `app.js` script tag. Do **not**
  hardcode a `?v=`; `AGENTS.md` is explicit about that.

Risk to be honest about: a Code build that starts before the file lands loses genre guidance
silently. Preloading on product entry (not on Build click) makes that window effectively zero, but
it is a real trade and worth saying out loud.

### F7 — `/api/auth/me` and `/api/chats` are serial when they could be parallel `[minor]`

`app.js:79962` awaits `/api/auth/me`; `bootApp` then awaits `fetchChats()` which awaits
`/api/chats` (`app.js:3372`). Two full round trips to Frankfurt, back to back: ~0.3–0.5 s from Iraq.

**Patch shape.** Before `const hadSession = …` (`app.js:79959`), fire a speculative
`fetch("/api/chats", { credentials: "same-origin" })` into a module-level `let _chatsPrefetch`, and
have `fetchChats` consume it when present (falling back to a fresh call on any failure, and clearing
it after one use so a refresh re-fetches).

**Critical detail for whoever writes this:** the prefetch must use bare `fetch`, **not** `apiJson`.
`apiJson` calls `handleSessionExpired()` on a 401 (`app.js:3221`, inside `apiJson` at `app.js:3216`) — I verified live that
`/api/chats` returns 401 without a cookie — so a speculative `apiJson` on a logged-out visitor would
fire the session-expiry path on the landing page.

### F8 — 1.4 MB of render-blocking CSS, and 14 font files `[minor, measure before acting]`

`styles.css` is 1,373,662 bytes / 26,148 lines / ~7,885 rules / 350 `@media` blocks / 107
`@keyframes`, and it blocks first paint. Brotli (F1) takes it from 325 KB to 241 KB, which is the
cheap 80 % of the win. A real critical-CSS split of 26k lines is a much larger surgery and I would
not recommend it before F1–F5 have landed and been re-measured.

The Google Fonts link (`index.html:263`) requests **4 families across 14 faces**
(Reem Kufi 400/500/600/700, Noto Sans Arabic 400/500/600/700, Archivo 400/500/600/700,
JetBrains Mono 400/500). `styles.css` actually uses weights 400 (×2), 500 (×9), 600 (×39), 650 (×4),
700 (×32), 800 (×4) — so the requested set is broadly justified and I will not claim a saving I
have not measured. The font *stylesheet* is render-blocking, but it is not on the critical path
today because `styles.css` takes far longer; it becomes worth fixing (`media="print"
onload="this.media='all'"`) only after F1.

**I did not measure the font file bytes** — that needs a browser trace with the real User-Agent,
because Google serves different subsets per client. Recipe: open DevTools → Network → filter
`fonts.gstatic.com`, hard reload, read the transferred column.

### F9 — No service worker, on a product for phones on flaky networks `[minor]`

`sw.js` is allowlisted at `server.mjs:13160` but **does not exist**, and nothing calls
`navigator.serviceWorker.register` (grep returns nothing in `app.js`). Immutable caching already
covers the ordinary repeat visit, so this is not urgent — but a mobile HTTP cache is small and
evicted aggressively, and there is currently no story at all for "the network died mid-load".
`.claude/skills/pwa-without-a-framework/SKILL.md` documents this same gap and owns the design; read
it before writing any of it.

---

## 5. Recommended order

| # | Change | Files | Saving | Risk |
| --- | --- | --- | --- | --- |
| 1 | Brotli in `serveStatic`, async-warmed at boot (F1) | `server.mjs` | **−594 KB per cold visit; ≈9 s @0.5 Mbps, 3.1 s @1.5 Mbps** | very low — Node built-in, no client change |
| 2 | Cut `MX_MIN_MS` and drop the trailing 360 ms (F2) | `app.js` | **−2.3 to −2.6 s on every visit, warm or cold** | none technical; it is a product call for the owner |
| 3 | Static `#bootSplash` in `index.html` (F3) | `index.html`, `app.js` ×4 lines | 0 ms; turns a blank page into a loading page | low |
| 4 | Vendor `marked` + `dompurify` same-origin (F4) | `index.html`, `server.mjs` | removes a foreign-CDN hang from the boot path | low |
| 5 | `startVersionWatch`: delay, visibility-gate, jitter, 60 s (F5) | `app.js` | −1 boot request; kills the post-deploy herd | low |
| 6 | Parallel `/api/chats` prefetch (F7) | `app.js` | −1 RTT (~0.3–0.5 s from Iraq) | low, **must not use `apiJson`** |
| 7 | Lazy `code-recipes.js` (F6) | `app.js`, new file, `server.mjs` | −88 KB gz (−4.6 % of `app.js`) | medium |
| 8 | Non-blocking Google Fonts stylesheet (F8) | `index.html` | ~1 RTT off first paint, **after** #1 | low |
| 9 | Service worker precache (F9) | new `sw.js`, `app.js` | repeat visits survive cache eviction | medium |

Items 1–3 alone take the measured 0.5 Mbps cold load from ~41.5 s to ~30 s **and** the warm load from
~4.2 s to ~1.5 s, while making the wait legible instead of looking like a crash.

### The larger split, if the owner wants it later

Six self-contained feature islands, measured by gzipping each range in isolation:

| Island | Lines | raw | gzip |
| --- | --- | --- | --- |
| Firas Code (`cw*`) | 60273–62600 | 437,571 | 162,584 |
| Agent | 51694–56200 | 331,671 | 108,664 |
| Diagram/chart/card renderers | 8317–13000 | 264,896 | 74,999 |
| OOXML writers (docx/pptx/xlsx/csv) | 32327–35368 | 182,905 | 60,840 |
| Image gen + upscaler + viewer | 3857–6490 | 151,345 | 53,342 |
| PDF/Brain ingest | 30010–32327 | 140,177 | 48,687 |

**Total ≈509 KB gzipped — 27 % of `app.js` on the wire.** With brotli that would put the first-screen
bundle near 1.0 MB instead of 1.91 MB.

Splitting classic scripts is legal here — top-level `const`/`let` in a classic script go into the
shared global lexical environment, so a later script sees an earlier script's bindings. The hazard
is the reverse direction: `app.js` calling into a not-yet-loaded island throws `ReferenceError`.
Every island therefore needs an `ensure<X>()` gate at its product entry point, exactly as sketched
for F6. That is a week of careful work on a live product, not a patch — do items 1–6 first, measure
again, and only then decide whether it is still needed.

---

## 6. How to verify, in the browser, before and after

Per `.claude/skills/perf-budget-frontend/SKILL.md` §1, Recipe C. Run on a hard reload with an empty
cache, on the phone if possible:

```js
const nav = performance.getEntriesByType("navigation")[0];
console.table({
  ttfb: Math.round(nav.responseStart - nav.requestStart),
  htmlDone: Math.round(nav.responseEnd - nav.startTime),
  domInteractive: Math.round(nav.domInteractive),
  domContentLoaded: Math.round(nav.domContentLoadedEventEnd),
  loadEvent: Math.round(nav.loadEventEnd),
});
performance.getEntriesByType("resource")
  .filter(r => /app\.js|styles\.css|fonts\.|jsdelivr/.test(r.name))
  .forEach(r => console.log(r.name.split("/").pop(),
    Math.round(r.duration) + "ms", Math.round(r.encodedBodySize / 1024) + "KB",
    r.encodedBodySize ? "" : "(cached)"));
console.log("FCP", performance.getEntriesByName("first-contentful-paint")[0]?.startTime);
```

Server side, one line, and the one that proves F1 landed:

```bash
curl -s -o /dev/null -D - -H "Accept-Encoding: gzip, br" "https://firasai.org/app.js?v=x" | grep -i content-encoding
# today:  content-encoding: gzip
# after:  content-encoding: br
```
