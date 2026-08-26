# Firas AI

A premium, bilingual (العربية / English) AI chat platform — streaming answers, a mature Claude-style interface, and a **free, keyless** engine by default. Works on every device.

منصّة دردشة ذكاء اصطناعي احترافية ثنائية اللغة، بواجهة أنيقة هادئة على طراز Claude، وردود تُبثّ مباشرةً — **مجانية وبدون مفتاح** افتراضياً، ومصمّمة لكل الأجهزة.

---

## ✨ Features / المزايا

- **Three Firas models / ثلاثة نماذج:** `Firas Mini` (fast / سريع), `Firas Pro` (balanced / متوازن — default), `Firas Ultra` (deep reasoning / الأقوى — تفكير عميق).
- **Auto language detection / كشف تلقائي للّغة:** type in Arabic → it answers in Arabic with full RTL; type in English → LTR. No language switch button.
- **Never freezes / لا يتجمّد:** token streaming, a Stop button, timeouts, automatic retries, and an offline fallback.
- **Streaming + Thinking panel, Markdown & code blocks, conversation history, light/dark themes.**
- **Pure static frontend + a tiny zero-dependency server.** No build step.

---

## 🚀 Run locally / التشغيل محلياً

> The free engine must be reached through the included proxy server (the provider now blocks direct browser calls), so run it with **Node**, not a plain static server.
>
> المحرك المجاني يجب أن يُستدعى عبر الخادم الوسيط المرفق (المزوّد صار يحجب الاستدعاء المباشر من المتصفح)، لذلك شغّله بـ **Node** وليس بخادم ثابت عادي.

```bash
node server.mjs
# → open  http://localhost:3000
```

That's it — free, no API key, no signup. / هذا كل شيء — مجاني، بلا مفتاح، بلا تسجيل.

Change the port with `node server.mjs 8080` or `PORT=8080 node server.mjs`.

---

## ⚡ Optional upgrade — faster & smarter / ترقية اختيارية — أسرع وأذكى

The free keyless engine works but is a **smaller model and noticeably slower** (~15–25s/answer). For ChatGPT/Claude-level speed and quality, set **one** environment variable before starting — the UI doesn't change, and the underlying model is never shown to users:

المحرك المجاني يعمل لكنه **نموذج أصغر وأبطأ ملحوظاً**. لسرعة وجودة بمستوى ChatGPT/Claude، اضبط **متغيّر بيئة واحداً** قبل التشغيل:

| Provider | Env var | Notes |
|---|---|---|
| **Groq** (recommended) | `GROQ_API_KEY` | **Free** signup, *very* fast (Llama 3.3 70B). أفضل خيار مجاني سريع. |
| OpenAI | `OPENAI_API_KEY` | GPT-4o / 4o-mini |
| Anthropic (Claude) | `ANTHROPIC_API_KEY` | Claude — via the Vercel deploy (`api/chat.js`) |

```bash
# Windows PowerShell
$env:GROQ_API_KEY="gsk_..."; node server.mjs

# macOS / Linux
GROQ_API_KEY=gsk_... node server.mjs
```

Get a free Groq key at <https://console.groq.com>. The server prints which engine is active on startup.

---

## ☁️ Deploy online / النشر أونلاين

The full app (accounts, chat history, image generation, web search) is a **single
long-running Node service** (`server.mjs`). It must be deployed on a host that
runs a persistent process — **Render, Railway, Fly.io, a VPS, etc.** Start command:
`node server.mjs` (it listens on `$PORT`).

> ⚠️ **Vercel/Netlify serverless does NOT run the full app.** `api/chat.js` only
> serves anonymous `/api/chat`; on those hosts login, history, `/api/image`, and
> `/api/search` all 404, and the JSON DB can't persist. Use a long-running host
> for the complete product.

### Required environment variables for production

| Var | Why | Example |
|-----|-----|---------|
| `SESSION_SECRET` | Sign session cookies. **Without it, every restart logs everyone out** (the fallback secret lives in the ephemeral DB). | a long random string |
| `OLLAMA_HOST` | The engine. A deployed box has no local Ollama → point at the cloud. | `https://ollama.com` |
| `OLLAMA_API_KEY` | Auth for Ollama Cloud. (Setting the key now also auto-defaults the host to `https://ollama.com`.) | `sk-...` |
| `DATA_DIR` | Put `db.json` on a **persistent disk** — the default `./data` is wiped on redeploy. | `/data` (mounted volume) |
| `SECURE_COOKIES` | Set to `1` behind HTTPS so cookies get the `Secure` flag. | `1` |
| `NODE_ENV` | `production` enables the startup readiness warnings. | `production` |

The JSON-file DB is **single-instance only** — run exactly **one** instance
(no horizontal autoscaling) until you migrate to a real database, or concurrent
writers will clobber each other.

### Firebase (Google / email sign-in)
Add your production domain under **Firebase Console → Authentication → Settings →
Authorized domains**, or Google sign-in fails with `auth/unauthorized-domain`.
Keep `FIREBASE_PROJECT_ID` in sync with `firebase-config.js` `projectId`.

**Static-only hosts (GitHub Pages):** serve the UI but **no engine/auth/features** —
not supported for the real app.

---

## 🗂️ Project structure / البنية

```
FirasAI/
├── index.html       # markup
├── styles.css       # the full Claude-style design system (light default + dark)
├── app.js           # chat logic: streaming, 3 tiers, auto language detect, history
├── server.mjs       # local server + free-engine proxy (zero dependencies)
├── api/chat.js      # Vercel serverless proxy (Groq / OpenAI / Anthropic / free)
├── vercel.json      # static + /api routing
├── .env.example     # documents the optional keys
└── package.json
```

The underlying free model is an internal detail and is **never** shown in the UI — users only ever see the three **Firas** tiers.

---
