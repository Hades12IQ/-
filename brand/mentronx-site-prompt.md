# MentronX.com — Complete Build Prompt

Build the official company website for **MentronX** as a complete, production-ready static site:
`index.html` + `styles.css` + `script.js`. No frameworks, no build step, no CDN dependencies
except Google Fonts. Every asset the site needs is inline in this brief — use it **verbatim**,
never redraw or approximate the logo.

---

## 1 · Brand facts (do not invent beyond these)

- **Company:** MentronX — domain `mentronx.com`
- **What it is:** an AI products company. Its flagship product is **Firas AI** (`firasai.org`) —
  an Arabic-first AI platform: chat, an autonomous agent, a browser IDE (Firas Code), and a
  document library that answers from your own files (Firas Brain).
- **Founder:** Firas. Based in Iraq.
- **Voice:** calm, confident, precise. The brand whispers; the work speaks.
- Do NOT invent statistics, team members, investors, offices, or clients. Where contact links
  are needed use the placeholders `[EMAIL]`, `[X_URL]`, `[GITHUB_URL]` and leave them visible.

## 2 · The logo (exact — paste as-is, never modify the paths)

One continuous line writes the M and rises into the X's first arm without lifting; a single
second stroke crosses it. **Silent monochrome:** the mark is never colored, never gradiented,
never glowed.

**Mark (use `currentColor` so it inherits theme ink; second stroke is the muted tone):**

```html
<svg class="mx-mark" viewBox="0 0 96 64" fill="none" aria-label="MentronX">
  <path class="mx-line"  d="M8 52 18 12 30 44 42 12 54 52 78 12"
        stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>
  <path class="mx-cross" d="M54 12 78 52"
        stroke-width="8" stroke-linecap="round"/>
</svg>
```

```css
.mx-line  { stroke: var(--ink); }
.mx-cross { stroke: var(--dim); }
```

**Rules:** minimum render width 28px · clear space around it = the height of one stroke width
· on light surfaces the line is `--ink`, on dark it is `--ivory` · the cross stroke is always
the muted tone · never place on a gradient, photo, or colored panel.

**Favicon:** the same mark, line `#1C1B18` on transparent (and a `#EDEAE0` variant for dark
mode via `prefers-color-scheme` media in the manifest/link tags).

## 3 · Color tokens (complete palette — nothing outside it)

```css
:root {                       /* light — the default */
  --paper:  #F2F0E9;          /* page ground — warm cream, never pure white */
  --card:   #FAF9F5;          /* raised surfaces */
  --ink:    #1C1B18;          /* primary text & the mark — never pure black */
  --dim:    #8A8677;          /* secondary text & the cross stroke */
  --hair:   #E3E0D6;          /* hairline borders */
}
[data-theme="dark"] {
  --paper:  #171613;          /* warm charcoal, never pure black */
  --card:   #201F1B;
  --ink:    #EDEAE0;          /* warm ivory, never pure white */
  --dim:    #8B8578;
  --hair:   #2C2A25;
}
```

There is **no accent color**. Links are `--ink` underlined; hover states darken/lighten within
the greys. This restraint is the identity — resist every urge to add a color.

## 4 · Typography

- **Latin/UI:** `Space Grotesk` (Google Fonts; weights 400/500/600/700).
- **Arabic:** `Noto Sans Arabic` (weights 400/500/600).
- Display sizes generous, tracking slightly tight (`-0.02em`) on Latin headlines only.
- Body 16–17px, line-height 1.65 (Arabic 1.9). Max prose measure 68ch.
- The wordmark in text is always `MentronX` — capital M, capital X, one word, weight 600.

## 5 · The signature animation (the site's one showpiece)

The hero performs the mark **writing itself**, exactly like this — these numbers are measured
path lengths, not guesses:

```css
.mx-line  { stroke-dasharray: 200; stroke-dashoffset: 200; }
.mx-cross { stroke-dasharray: 49;  stroke-dashoffset: 49; }
.is-writing .mx-line  { animation: mxWrite 1150ms cubic-bezier(.5,.05,.3,1) forwards; }
.is-writing .mx-cross { animation: mxWrite 420ms  cubic-bezier(.4,0,.3,1) 1120ms forwards; }
@keyframes mxWrite { to { stroke-dashoffset: 0; } }
```

Sequence on first load: page paints with hero mark empty → `.is-writing` added on the next
frame → the line writes (pen pace, 1.15s) → the cross closes it → the headline and CTA fade up
(400ms, 12px rise) **after** the cross lands (~1.6s). The animation runs once per visit
(sessionStorage guard), not on every internal navigation.

`prefers-reduced-motion: reduce` → mark renders complete instantly, headline appears with a
simple fade, no writing.

## 6 · Motion language (calm is a hard constraint)

- Durations 150–500ms only. Properties: `opacity` and `transform` only.
- Scroll reveals: IntersectionObserver, single 12px rise + fade, once, staggered ≤80ms apart.
- Link hover: underline draws from the reading direction (left in LTR, right in RTL), 200ms.
- Buttons: background deepens one step; no scale, no shadow-pop.
- **Banned outright:** parallax, gradients, glows, particles, tilt effects, marquees,
  auto-playing anything, scroll-jacking, confetti. If an effect calls attention to itself,
  it is wrong for this brand.

## 7 · Page structure (single page + anchor nav)

1. **Nav** (sticky, hairline bottom border, `--paper` at 92% + backdrop-blur): mark + word
   `MentronX` · links: Products, Principles, About, Contact · right cluster: language toggle
   `AR/EN`, theme toggle (sun/moon, persists in localStorage).
2. **Hero:** the writing mark (~200px wide) above one headline and one line of support text,
   one primary CTA → `https://firasai.org` ("Try Firas AI") + one quiet text link ("What we
   build ↓"). Nothing else. Whitespace is the design.
3. **Products:** one large card — Firas AI — with the four capabilities as a compact 2×2 grid
   (Chat · Agent · Code · Brain), one sentence each, one CTA to firasai.org. Leave room for
   future product cards (grid supports 2).
4. **Principles:** three short columns, no icons needed (or 16px inline strokes max):
   Arabic-first · Calm technology · Ship real things.
5. **About:** 3–4 sentences, the honest story (see copy).
6. **Contact:** email + X + GitHub as plain links (placeholders).
7. **Footer:** small mark, `© 2026 MentronX`, `BY MentronX` treatment: the word BY in `--dim`
   13px letter-spaced small caps **optically raised 3px** beside `MentronX` in `--ink` 600.

## 8 · Copy (verbatim — EN default, AR via toggle)

**EN**
- Hero H1: `Software that stays out of your way.`
- Hero sub: `MentronX builds AI products with a calm hand — starting with Firas AI, the
  Arabic-first AI platform.`
- CTA: `Try Firas AI` · secondary: `What we build`
- Products H2: `What we build` · Card title: `Firas AI` · Card sub: `One account, four tools.`
  - `Chat — answers that think in your language.`
  - `Agent — long tasks, done step by step.`
  - `Code — a full dev environment in the browser.`
  - `Brain — answers from your own documents, with the page number.`
- Principles H2: `How we work`
  - `Arabic-first · Our products think in Arabic from the first line of code — not as a translation.`
  - `Calm technology · No noise, no dark patterns, no theatrics. Software should lower the pulse.`
  - `Ship real things · Working products over promises. If it is on the site, it runs today.`
- About H2: `About MentronX` — `MentronX is an independent software company from Iraq. We build
  AI products we want to use ourselves: fast, honest, and fluent in Arabic. Our first product,
  Firas AI, is live today.`
- Contact H2: `Contact` — `For anything: [EMAIL]`
- Footer line: `Quietly building. Baghdad → the world.`

**AR** (dir="rtl", Noto Sans Arabic)
- H1: `برمجيات لا تقف في طريقك.`
- Sub: `MentronX تصنع منتجات ذكاء اصطناعي بيدٍ هادئة — بدءًا من فِراس AI، منصّة الذكاء الاصطناعي التي تفكّر بالعربية أولًا.`
- CTA: `جرّب فِراس AI` · secondary: `ماذا نصنع`
- Products: `ماذا نصنع` / `فِراس AI` / `حساب واحد، أربع أدوات.`
  - `محادثة — إجابات تفكّر بلغتك.`
  - `وكيل — مهامّ طويلة تُنجَز خطوة خطوة.`
  - `برمجة — بيئة تطوير كاملة في المتصفّح.`
  - `مكتبة — إجابات من ملفّاتك أنت، مع رقم الصفحة.`
- Principles: `كيف نعمل`
  - `العربية أولًا · منتجاتنا تفكّر بالعربية من أوّل سطر كود — لا كترجمة.`
  - `تقنية هادئة · لا ضجيج ولا حِيَل ولا استعراض. البرمجيات يجب أن تُهدّئ النبض.`
  - `نشحن أشياء حقيقية · منتجات تعمل، لا وعود. ما تراه على الموقع يعمل اليوم.`
- About: `عن MentronX` — `MentronX شركة برمجيات مستقلّة من العراق. نصنع منتجات الذكاء الاصطناعي
  التي نريد أن نستخدمها بأنفسنا: سريعة، صادقة، وتُتقن العربية. منتجنا الأوّل، فِراس AI، يعمل اليوم.`
- Contact: `تواصل` — `لأيّ شيء: [EMAIL]`
- Footer: `نبني بهدوء. بغداد ← العالم.`

## 9 · Bilingual + RTL (hard requirements)

- Full i18n dictionary EN/AR in `script.js`; toggle swaps every string, sets
  `<html lang dir>`, persists in localStorage.
- In RTL: layout mirrors via CSS logical properties (`margin-inline-start`, `inset-inline-end`,
  `text-align: start`) — **no** `left/right` physical properties anywhere except the signature
  animation itself, which stays physically identical in both directions.
- Arabic gets `Noto Sans Arabic` and line-height 1.9 automatically via `[dir="rtl"]` rules.

## 10 · Responsive + accessibility (acceptance criteria)

- Flawless at 360, 390, 768, 1024, 1440, 1920 wide. Use `dvh` not `vh` for full-height hero;
  respect `env(safe-area-inset-*)`.
- Mobile nav: links collapse into a slide-down panel; tap targets ≥ 44px.
- All text pairs meet WCAG AA on both themes (the token palette above already does — verify
  `--dim` on `--paper` in both).
- Visible `:focus-visible` rings (2px `--ink` offset 2). Semantic landmarks
  (`header/main/section/footer`), one `h1`, skip-link.
- Full `prefers-reduced-motion` handling as specified.
- SEO: title `MentronX — AI products, built calmly`, meta description, OG tags with the mark,
  `theme-color` per theme.
- Lighthouse targets: Performance ≥ 95, A11y ≥ 95, no layout shift after the hero writes
  (reserve the mark's box).

## 11 · Final checklist (verify before declaring done)

- [ ] Logo paths byte-identical to §2 — never redrawn
- [ ] Signature writes once, pen-paced, then headline rises; reduced-motion path works
- [ ] Zero colors outside §3 tokens; zero gradients/glows anywhere
- [ ] AR toggle: every string flips, layout mirrors, animation still physically identical
- [ ] Both themes, both languages, six viewport widths — screenshot-clean
- [ ] `BY MentronX` footer with the 3px-raised BY
- [ ] Placeholders `[EMAIL] [X_URL] [GITHUB_URL]` present and visible
