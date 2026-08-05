# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Arabic speakers — primarily in Iraq and the wider Arab world — who want an AI assistant that
handles Arabic as a first-class language rather than as a translation target. Students are a
confirmed core audience: the codebase carries dedicated handling for pasted exams, worksheet
and definition extraction, and converting study material to PDF.

Two access levels exist in code: signed-in members and guests. Guests are a deliberate,
supported audience — a signed `firas_guest` cookie grants real quota without an account, and
guest chats stay local to the device.

*Inferred from the codebase and the owner's prior instructions, not from a user interview.*

## Product Purpose

Firas AI is a single web app containing four distinct products, switched from one sidebar
control:

- **Firas AI** — general chat. Streaming answers, images in and out, web search, a thinking
  toggle, voice dictation, and a real-time voice call mode.
- **Firas Agent** — long multi-step tasks. Plans, executes step by step, reviews its own work,
  and returns finished files.
- **Firas Code** — an in-browser development environment. Multi-file projects, live preview,
  and generation from a plain-language description.
- **Firas Brain** — cited question-answering over the user's own documents. Files are chunked
  per page, so every answer cites filename and exact page, and the citation opens the stored
  passage.

Success is a user getting a correct, verifiable answer in Arabic without switching to an
English-first tool and losing quality.

## Positioning

Arabic-first, not Arabic-translated. Two mechanisms a neighbouring product could not truthfully
copy:

1. **Page-exact citation.** Firas Brain chunks documents *within* each page, so a citation
   names a real page number and resolves to the stored passage. Scanned and image-only files
   are read through the site's own vision chain, so a photographed textbook is answerable.
2. **Four products, one account, one quota system.** Chat, agent, IDE and document Q&A share
   an account, a plan, and a model chain — not four separate subscriptions.

## Operating Context

- Runs in the browser with **zero build step** — no bundler, no framework, no npm dependencies
  at runtime. `index.html`, `styles.css`, `app.js` are served directly.
- **Two backends that must stay in parity**: `server.mjs` (self-hosted Node) and
  `netlify/edge-functions/api.js` (Netlify Edge, Deno). Any backend change lands in both.
- Storage is either a JSON file (`data/db.json`) or Firebase, chosen at boot.
- Heavy libraries (KaTeX, highlight.js, motion) load lazily after first paint and the app
  renders correctly without them.
- Real users are on the live database now. There is no second copy of `data/db.json`.

## Capabilities and Constraints

**Model chain.** Four user-facing tiers — `mini`, `pro`, `ultra`, `max` — backed by hosted
Ollama models (`gpt-oss:120b`, `qwen3-coder:480b`), each with a cross-pool fallback so a busy
primary degrades instead of failing. Gemini serves vision and transcription through a rotating
key pool. A last-resort public fallback exists.

**Plans and quota.** `free` / `gold` / `diamond` / `unlimited`, enforced per calendar day and
per product — free is 100 chat, 60 code, 30 agent, 60 brain. The server is the only authority;
the client cannot set its own plan. Expired paid plans fall back to free without data loss.

**Languages.** Arabic and English throughout, including mixed-script content in a single
answer. Right-to-left is the primary reading direction.

**Voice.** Dictation with a dialect picker, and a full voice call mode.

**Accessibility of content.** Answers must render Arabic, English, LaTeX and code together
without corruption — this has been an explicit, repeated product requirement.

## Brand Commitments

Confirmed with the owner on 2026-08-03, before a full redesign. Exactly two things are binding:

1. **The product stays dark.** Designed dark-first; dark remains the default a visitor sees.
   The existing light theme is a shipped feature and stays available — it is not the identity.
2. **The names stay.** "Firas AI", and the four products *Firas AI / Firas Agent / Firas Code /
   Firas Brain*. Real users know these names; renaming was offered and declined.

Everything else was explicitly released: logo, colour beyond the dark foundation, typography,
composition, iconography, and motion are all open for replacement.

The rest of the incumbent identity — a teal-gradient rounded-square mark bearing an "F", and
Inter with IBM Plex Sans Arabic — is therefore **evidence and anti-reference**, not authority.

**Copy is in scope.** The owner explicitly authorised rewriting UI copy — button labels, error
messages, product descriptions, and landing text — to match the new identity. Invented claims
remain forbidden: no prices, statistics, testimonials, or capabilities the product lacks.

## Evidence on Hand

- A live user base with real accounts, chats and projects in `data/db.json`.
- Real generated content: user documents in Firas Brain, user projects in Firas Code.
- Working voice, image generation, and document OCR.
- **No** testimonials, press, customer logos, benchmarks, or usage statistics exist. Future
  work must not fabricate them. The landing page's current "100% free" claim is being removed
  because paid tiers exist.

## Product Principles

1. **Arabic is the first-class case, not the edge case.** Any layout, font, or component that
   works in English but degrades in Arabic is broken.
2. **Verifiability over fluency.** Firas Brain's value is the citation, not the prose. Never
   trade a checkable answer for a smoother one.
3. **Degrade, never fail.** Every model tier has a fallback; every lazy library has a
   render path without it; every expired plan keeps its data.
4. **Two backends move together.** A feature that exists in only one of `server.mjs` and the
   edge function is not shipped.
5. **The user's data is irreplaceable.** No broad deletions, no pattern-matched removal, and a
   verified backup before structural change.

## Accessibility & Inclusion

Right-to-left and mixed-script rendering are functional requirements, not enhancements.
Beyond that, no formal standard has been set by the owner; the working target is WCAG AA.
