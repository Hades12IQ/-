# Netlify environment variables — Firas AI

Every value below was read out of `netlify/edge-functions/api.js` (the live backend), not from
memory. Anything marked **default** already works without you setting it.

**Where:** Netlify → *Site configuration* → *Environment variables* → *Add a variable*.
Scope must include **Functions** and **Edge functions**.

**Never** put a secret in `netlify.toml` — that file is committed to git, so the secret becomes
public the moment you push.

To generate any secret asked for below:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

---

## 1. Required — the site returns HTTP 500 without these

The backend refuses every request except `/api/version` and replies
`server not configured — missing/invalid env: …` naming exactly what is missing.

| Variable | What to put | Where it comes from |
|---|---|---|
| `SESSION_SECRET` | a long random hex string | you generate it (command above) |
| `FIREBASE_DB_URL` | `https://<project>-default-rtdb.firebaseio.com` | Firebase Console → Build → Realtime Database → the URL at the top |
| `FIREBASE_SERVICE_ACCOUNT` | the **whole** downloaded JSON, on one line | Firebase Console → ⚙ Project settings → Service accounts → *Generate new private key* |

`FIREBASE_SERVICE_ACCOUNT` must stay valid JSON. Paste it exactly as downloaded — do not
"tidy" the `\n` inside `private_key`, they are part of the key.

---

## 2. The engine — without at least one of these, nothing can answer

The chain is tried in order and falls through on failure or rate-limit.

| Variable | What to put | Where |
|---|---|---|
| `OLLAMA_API_KEY` | your Ollama Cloud key | ollama.com → Settings → Keys |
| `OLLAMA_API_KEYS` | several keys, comma separated — drained one at a time | same |
| `OLLAMA_API_KEY_1` … `_9` | same thing, one per variable | same |
| `GEMINI_API_KEY` | a Google AI Studio key | aistudio.google.com → Get API key |
| `GEMINI_API_KEYS` | several, comma separated | same |
| `GEMINI_API_KEY_1` … `_24` | same, one per variable | same |
| `ANTHROPIC_API_KEY` | `sk-ant-…` | console.anthropic.com → API keys |
| `OPENROUTER_API_KEY` | `sk-or-…` | openrouter.ai → Keys |
| `NVIDIA_API_KEY` | `nvapi-…` | build.nvidia.com |
| `CF_ACCOUNT_ID` + `CF_API_TOKEN` | Cloudflare account id and a Workers AI token | dash.cloudflare.com → Workers AI |
| `CF_ACCOUNT_ID_1`…`_64` + `CF_API_TOKEN_1`…`_64` | more Cloudflare accounts, paired by number | same |
| `CF_ACCOUNTS` | legacy single string: `id:token,id:token` | same |
| `HF_API_KEY` | `hf_…` — images only | huggingface.co → Settings → Access tokens |
| `PUTER_AUTH_TOKEN` | Puter token — images only | puter.com |

> **Rotate `PUTER_AUTH_TOKEN` before launch.** Part of it was printed into an agent transcript
> during development. Rotate `SESSION_SECRET` at the same time.

---

## 3. Background missions — the tab can be closed

| Variable | What to put | Where |
|---|---|---|
| `INTERNAL_JOB_SECRET` | a long random hex string | you generate it |

An edge function cannot run for 15 minutes, so `POST /api/agent/job` writes the job to the
database and kicks a Netlify **background** function that runs detached and writes its progress
back. Closing the tab stops nothing — the tab was only ever polling the job record.

That kick is a plain HTTP request to a **public** URL
(`/.netlify/functions/agent-background`), so without a shared secret anyone could call it and
spend your model quota. Both sides compare this value in the `x-firas-internal` header.

**Unset = the feature is simply off:** `/api/agent/job` answers
`501 {"error":"background jobs not configured"}` and missions run in the tab as before.
Requires section 1, because the job state has to outlive the request that started it.

---

## 4. Email — verification and password reset

Without one of these, signup links are never delivered.

| Variable | What to put | Default |
|---|---|---|
| `RESEND_API_KEY` | `re_…` from resend.com | — |
| `RESEND_FROM` | `Firas AI <you@yourdomain>` | `Firas AI <onboarding@resend.dev>` |
| `BREVO_API_KEY` | `xkeysib-…` from brevo.com | — |
| `BREVO_FROM` | the verified sender address | `firasnozad@gmail.com` |
| `BREVO_FROM_NAME` | sender display name | `Firas AI` |
| `DEV_LOG_LINKS` | `1` to print the link to the log instead of sending — **development only** | off |

---

## 5. Limits — set these only to change the numbers

| Variable | Meaning | Default |
|---|---|---|
| `IMAGE_DAILY_LIMIT` | images per user per day | `5` |
| `MAX_DAILY_LIMIT` | Max-tier messages per user per day | `10` |
| `GUEST_DAILY_AI` | guest chat messages per day | `60` |
| `GUEST_DAILY_CODE` | guest Code builds | `20` |
| `GUEST_DAILY_AGENT` | guest Agent missions | `8` |
| `GUEST_DAILY_BRAIN` | guest Brain answers | `40` |
| `GUEST_DAILY_VOICE` | guest voice turns | `40` |
| `GUEST_DAILY_INTERNAL` | guest internal calls | `100` |
| `BRAIN_VISION_DAILY` | shared OCR budget for scanned pages | derived from your Gemini keys |
| `GEMINI_RPD_PER_KEY` | requests per Gemini key per day | `500` |
| `NVIDIA_DAILY_CAP` | NVIDIA calls per day | `100` |
| `QUOTA_TZ_OFFSET_MINUTES` | when "a day" rolls over — `180` is Baghdad | `180` |
| `REQUEST_TIMEOUT_MS` | upstream timeout | `300000` |

---

## 5b. Images — OpenAI first, on a budget that cannot overrun

Set `OPENAI_API_KEY` and gpt-image becomes the FIRST image engine, ahead of Cloudflare. It is
also the only engine that can **edit** a picture you attach ("اجعل السماء بنفسجية", "remove the
car") — every other engine generates from text alone.

Three independent guards stand in front of the money, and all three must pass:

| Variable | Default | What it does |
|---|---|---|
| `IMAGE_ENGINE` | `gemini` | `gemini` draws with Nano Banana and keeps gpt-image behind it; `openai` swaps them |
| `GEMINI_IMAGE_MODEL` | a ladder | comma-separated Nano Banana candidates, first accepted wins — `/api/image/diag` names it |
| `OPENAI_API_KEY` | *(none)* | absent → the whole path is skipped and nothing changes |
| `OPENAI_IMAGE_DAILY` | `2` | premium images **per user per day**; images 3-5 come from the free chain |
| `OPENAI_IMAGE_BUDGET_USD` | `60` | hard ceiling on total spend; past it, everything falls to Cloudflare |
| `OPENAI_IMAGE_PRICES` | *(built-in table)* | JSON `{quality:{size:usd}}` — only needed if OpenAI changes its prices |
| `OPENAI_IMAGE_QUALITY` | `high` | see the table below |
| `OPENAI_IMAGE_MODEL` | `gpt-image-2,gpt-image-1` | comma-separated, newest first; an unavailable one retires itself |
| `OPENAI_EDIT_KEEP` | `20` | edited pictures kept per user (edge only — they live in the DB there) |

Spend is counted at OpenAI's **published per-image prices**, not an average — price moves with
quality *and* shape, and not in the direction you would guess:

| Quality | 1024×1024 | 1024×1536 | 1536×1024 | what $60 buys |
|---|---|---|---|---|
| low | $0.006 | $0.005 | $0.005 | ~10,000-12,000 |
| medium | $0.053 | $0.041 | $0.041 | ~1,132-1,463 |
| **high** | **$0.211** | **$0.165** | **$0.165** | **~284-363** |

At the default two-a-day, high quality gives one user roughly **142-181 days**. Dropping to medium roughly quadruples that, and low multiplies it by about thirty-five. Anything the
table does not recognise is charged at the dearest price in it — an unknown case must over-charge
the guard, never under-charge it.

The ceiling is the SOFT guard; the hard one is OpenAI's own billing error. A `402`, a `401`, or a
`429 insufficient_quota` switches the engine off immediately and permanently, and every image
after that comes from Cloudflare — no redeploy, no intervention, no failed requests.

Spend is recorded at `openaiImageUsd` (file DB) / `spend/openaiImageUsd` (Firebase), so restarting
does not reset it. To give the account more money, raise `OPENAI_IMAGE_BUDGET_USD`; to start the
count again, set that field back to 0.

---

## 6. Model choice — a LADDER, safe to aim at the strongest model

Every `OLLAMA_MODEL_*` value accepts a **comma-separated list, strongest first**. The first rung
that is actually answering is the one used:

```
OLLAMA_MODEL_MAX="deepseek-v3.1:671b-cloud,qwen3-coder:480b-cloud,gpt-oss:120b-cloud"
```

A model name the cloud does not host does **not** return 404 — it accepts the request and goes
silent. That used to hang the tier for five minutes and take the rescue chain down with it, which
is why this section used to say "leave alone unless you know the model exists". It no longer
applies: a rung that sends nothing within `OLLAMA_FIRST_BYTE_MS` is abandoned, marked unavailable
for `OLLAMA_MODEL_DEAD_MS`, and skipped — so exactly ONE request pays the timeout and everything
after it goes straight to the next rung. The mark expires on its own, so the tier climbs back the
moment the cloud starts hosting that model. No redeploy, no code change.

**So: put the best model you have access to at the front of the list, and leave a known-good one
at the back.** A wrong guess costs one slow answer, not a broken tier.

| Variable | Default |
|---|---|
| `OLLAMA_MODEL_MINI` | `gpt-oss:120b-cloud` |
| `OLLAMA_MODEL_PRO` | `gpt-oss:120b-cloud` |
| `OLLAMA_MODEL_ULTRA` | `qwen3-coder:480b-cloud` |
| `OLLAMA_MODEL_MAX` | `qwen3-coder:480b-cloud` |
| `OLLAMA_MODEL_MAX_FALLBACK` | `gpt-oss:120b-cloud` |
| `OLLAMA_FIRST_BYTE_MS` | `45000` — how long a rung may stay silent before it is dropped |
| `OLLAMA_MODEL_DEAD_MS` | `1800000` — how long a silent model stays skipped (30 min) |
| `OLLAMA_MODEL_VISION` | `gemma3:27b-cloud` |
| `OLLAMA_HOST` | `https://ollama.com` |
| `GEMINI_TEXT_MODEL` | `gemini-2.5-flash,gemini-flash-latest` |
| `GEMINI_VISION_MODEL` | a built-in list |
| `GEMINI_IMAGE_MODEL` | `gemini-2.5-flash-image` |
| `GEMINI_TTS_MODEL` | `gemini-2.5-flash-preview-tts` |
| `GEMINI_TTS_VOICE` | `Sadaltager` |
| `ANTHROPIC_MODEL` | `claude-sonnet-4-6` |
| `ANTHROPIC_MAX_TOKENS` | `8192` |
| `OPENROUTER_MODEL` | `nvidia/nemotron-3-ultra-550b-a55b:free` |
| `OPENROUTER_VISION_MODELS` | a built-in free list |
| `NVIDIA_MODEL` | `deepseek-ai/deepseek-v4-pro` |
| `CF_TEXT_MODEL` | `@cf/meta/llama-3.3-70b-instruct-fp8-fast` |
| `CF_TEXT_MODEL_STRONG` | `@cf/qwen/qwq-32b` |
| `CF_IMAGE_MODEL` | `@cf/black-forest-labs/flux-2-klein-9b` |
| `CF_IMAGE_STEPS` | `10` (clamped 1–20) |
| `HF_IMAGE_MODEL` | `black-forest-labs/FLUX.1-schnell` |
| `HF_IMAGE_URL` | derived from `HF_IMAGE_MODEL` |
| `PUTER_IMAGE_MODEL` | `gpt-image-2` |
| `PUTER_IMAGE_QUALITY` | `low` — `low` \| `medium` \| `high` |

---

## 7. Rarely touched

| Variable | Meaning | Default |
|---|---|---|
| `ADMIN_EMAILS` | who gets the admin panel, comma separated | `firasnozad@gmail.com` |
| `FIREBASE_PROJECT_ID` | only for Google sign-in token checks | `firas-ai` |
| `KB_IN_CHAT` | `1` injects the admin reference library into normal chat | off |
| `DEPLOY_VERSION` | forces open tabs to reload | the Netlify deploy id |

---

## The shortest path to a working deploy

Six variables:

```
SESSION_SECRET             = <generated>
FIREBASE_DB_URL            = https://<project>-default-rtdb.firebaseio.com
FIREBASE_SERVICE_ACCOUNT   = {"type":"service_account", … }
OLLAMA_API_KEY             = <your key>
GEMINI_API_KEY             = <your key>          # needed for voice, OCR and images
INTERNAL_JOB_SECRET        = <generated>         # background missions
```

Then add `RESEND_API_KEY` (or Brevo) so signup emails actually arrive.

**Check it worked:** open `/api/version`. It answers even when misconfigured. Then load the
site — if a variable is missing you get a 500 that names it.
