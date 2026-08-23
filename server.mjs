/* ============================================================================
   Firas AI — local server + AI proxy + accounts + database (Node 18+, ESM)
   ZERO npm dependencies. Pure node: http / crypto / fs / url / stream.

   What this server does:
     1. Serves the static site (index.html / styles.css / app.js / ...) with a
        Cache-Control: no-cache header so edits show up immediately.
     2. Exposes an authenticated AI stream at POST /api/chat, powered by Ollama
        (native /api/chat endpoint) with a free keyless pollinations fallback.
     3. Provides a real multi-user account system (signup / login / logout / me)
        backed by a serialized JSON-file database, with secure scrypt password
        hashing and signed HttpOnly session cookies.
     4. Stores per-user chat history (list / read / create / update / delete).

   Run:  node server.mjs      then open  http://localhost:3000
   ========================================================================== */
import http from "node:http";
import https from "node:https";
import crypto from "node:crypto";
import { readFile, mkdir, writeFile, readdir, rm, realpath } from "node:fs/promises";
import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Load a local .env (KEY=value lines) if present, so secrets like OPENROUTER_API_KEY
// can be dropped in a gitignored file instead of exported each run. Real env vars
// still win (loadEnvFile does not overwrite already-set process.env). Node 20.12+.
try { process.loadEnvFile(path.join(__dirname, ".env")); } catch (_) { /* no .env — fine */ }

const PORT = process.env.PORT || process.argv[2] || 3000;

/* ---------------------------------------------------------------------------
   AI ENGINE = OLLAMA (native endpoint). Free pollinations fallback.
   --------------------------------------------------------------------------- */
// When an API key is set we're meant to use Ollama's HOSTED cloud, so default
// the host to https://ollama.com (a deployed server has no local daemon). Only
// fall back to localhost when there's no key (local dev).
const OLLAMA_HOST = (process.env.OLLAMA_HOST || (process.env.OLLAMA_API_KEY ? "https://ollama.com" : "http://localhost:11434")).replace(/\/+$/, "");
const OLLAMA_CHAT_URL = OLLAMA_HOST + "/api/chat";
const FALLBACK_URL = "https://text.pollinations.ai/openai"; // keyless, server-side (no Origin)
const FALLBACK_MODEL = "openai";
/* THE STREAM DEADLINE IS IDLE-BASED, NOT ABSOLUTE.
   It used to be one flat `setTimeout(abort, 300_000)` armed when the request arrived, so a
   reply that was streaming perfectly well was killed the moment it crossed five minutes and
   the user got "I couldn't reach the service" with ZERO characters kept — reproducibly, on
   exactly the work that takes longest: a ten-problem PDF with a cover, contents and full
   worked solutions. A deadline that fires while tokens are still arriving is measuring the
   wrong thing. What actually indicates a dead upstream is SILENCE, so the clock is reset by
   every byte written (see sseWrite) and only unbroken silence aborts.
   UPSTREAM_MAX_MS is the runaway backstop and is deliberately far above any real answer. */
const UPSTREAM_IDLE_MS = Number(process.env.REQUEST_IDLE_TIMEOUT_MS) || Number(process.env.REQUEST_TIMEOUT_MS) || 300_000;
const UPSTREAM_MAX_MS = Number(process.env.REQUEST_MAX_MS) || 1_800_000; // 30 min hard ceiling
/* FIRST-BYTE DEADLINE — separate from the silence clock above, and the reason a stronger model
   is safe to point a tier at.

   UPSTREAM_IDLE_MS measures SILENCE and is five minutes, which is right for a model that IS
   generating: a long build pauses between tokens and must not be cut. It is badly wrong for a
   model that will never speak at all. A model name Ollama Cloud does not host does not answer
   404 — it accepts the request and holds the connection open. So the tier sat mute for five
   minutes and then the whole request died, rescue chain included, because every upstream shared
   one AbortController. That is what "Max hung" was when this tier was last pointed at a bigger
   model, and it is the only thing that made upgrading risky.

   A hosted model that is working emits its first token in seconds. Past this deadline the
   attempt is abandoned and the caller's rescue chain answers on a still-live signal. */
const OLLAMA_FIRST_BYTE_MS = Number(process.env.OLLAMA_FIRST_BYTE_MS) || 45_000;

/* MODEL LADDER — how a tier gets to run the STRONGEST model without betting the tier on it.

   Every OLLAMA_MODEL_* setting accepts a COMMA-SEPARATED list, strongest first:

     OLLAMA_MODEL_MAX="deepseek-v3.1:671b-cloud,qwen3-coder:480b-cloud,gpt-oss:120b-cloud"

   The first entry that is actually answering is used. A model that takes the first-byte deadline
   without speaking — which is what an un-hosted name does — is marked dead for MODEL_DEAD_MS and
   skipped, so exactly ONE request pays the timeout and every request after it goes straight to
   the next rung. The mark expires on its own, so the moment the cloud starts hosting that model
   the tier climbs back up with no redeploy and no code change.

   This is what makes "point it at the best model" a safe instruction instead of a gamble: a name
   that turns out not to exist costs one slow answer, not a broken tier. */
const MODEL_DEAD_MS = Number(process.env.OLLAMA_MODEL_DEAD_MS) || 1_800_000;   // 30 min
const _modelDead = new Map();                                 // model name -> ms timestamp it may be retried
function modelMarkDead(model) {
  if (!model) return;
  _modelDead.set(model, Date.now() + MODEL_DEAD_MS);
  console.warn("[firas] model " + model + " marked unavailable for " +
    Math.round(MODEL_DEAD_MS / 60000) + " min - the tier drops to its next rung");
}
/** Split a setting into a ladder. Empty entries are dropped so a trailing comma is harmless. */
function modelLadder(value, fallback) {
  const list = String(value == null || value === "" ? fallback : value)
    .split(",").map((m) => m.trim()).filter(Boolean);
  return list.length ? list : [String(fallback)];
}
/** The highest rung not currently marked dead; the top rung if every one of them is. */
function pickModel(ladder) {
  const now = Date.now();
  for (const m of ladder) if (now >= (_modelDead.get(m) || 0)) return m;
  return ladder[0];
}

// Ollama API KEY POOL. Set OLLAMA_API_KEY (+ OLLAMA_HOST=https://ollama.com) to use Ollama's
// HOSTED cloud API. Each free key has a WEEKLY quota — when one key hits its limit (429/402/403)
// the pool moves to the NEXT key automatically. Add extra keys via OLLAMA_API_KEYS="k2,k3,…"
// or numbered OLLAMA_API_KEY_1..OLLAMA_API_KEY_9. Picking is STICKY-FIRST (drain key 1, then
// key 2…) so quotas are consumed one at a time, not all at once.
const OLLAMA_KEYS = (() => {
  const keys = [];
  if (process.env.OLLAMA_API_KEY) keys.push(process.env.OLLAMA_API_KEY.trim());
  for (const k of (process.env.OLLAMA_API_KEYS || "").split(",")) { const v = k.trim(); if (v) keys.push(v); }
  for (let i = 1; i <= 9; i++) { const v = (process.env["OLLAMA_API_KEY_" + i] || "").trim(); if (v) keys.push(v); }
  return [...new Set(keys)];
})();
const OLLAMA_API_KEY = OLLAMA_KEYS[0] || "";                  // back-compat (startup logs / host default)
const _olCooldown = new Map();                                 // key → ms timestamp it may be retried
// A limited key rests 45 min (limits reset weekly, but a periodic re-probe self-heals sooner
// if the quota was actually a transient 429).
/* A BUSY KEY IS NOT AN EMPTY KEY, and the difference matters most for the one that is paid for.

   Every limit used to cost 45 minutes. That is right for a free key with a weekly quota — once it
   is gone it is gone — and badly wrong for a subscription key, which throttles for seconds under
   load and recovers on its own. Sidelining the paid key for three quarters of an hour because it
   was briefly busy sends every user down to the free keys for no reason at all.

   429 is "come back shortly". 402 and 403 are "there is nothing left". They now rest for very
   different lengths, and the FIRST key in the pool — the subscription one by convention — gets
   the shortest rest of all, because it is the one we always want back. */
const OLLAMA_BUSY_MS  = Number(process.env.OLLAMA_BUSY_COOLDOWN_MS) || 45000;      // rate limited
const OLLAMA_SPENT_MS = Number(process.env.OLLAMA_SPENT_COOLDOWN_MS) || 45 * 60000; // out of quota
function ollamaMarkLimited(key, status) {
  if (!key) return;
  const spent = status === 402 || status === 403;
  const primary = OLLAMA_KEYS[0] === key;
  const rest = spent ? OLLAMA_SPENT_MS : (primary ? Math.min(OLLAMA_BUSY_MS, 15000) : OLLAMA_BUSY_MS);
  _olCooldown.set(key, Date.now() + rest);
}
// First key not on cooldown; if ALL are cooling, the one that recovers soonest (never give up).
function ollamaPickKey() {
  if (!OLLAMA_KEYS.length) return "";
  const now = Date.now();
  for (const k of OLLAMA_KEYS) { if (now >= (_olCooldown.get(k) || 0)) return k; }
  return OLLAMA_KEYS.reduce((a, b) => ((_olCooldown.get(a) || 0) <= (_olCooldown.get(b) || 0) ? a : b));
}
function ollamaHeaders(key) {
  const h = { "Content-Type": "application/json" };
  const k = key !== undefined ? key : ollamaPickKey();
  if (k) h["Authorization"] = "Bearer " + k;
  return h;
}

// PREMIUM "Max" tier engines (server-side keys only — end users stay keyless).
// Max chain: Gemini Flash (free) → Claude Sonnet (paid) → OpenRouter free (Nemotron) → Ollama/pollinations.
const ANTHROPIC_API_KEY  = process.env.ANTHROPIC_API_KEY || "";
const ANTHROPIC_MODEL    = process.env.ANTHROPIC_MODEL || "claude-sonnet-4-6";
const ANTHROPIC_URL      = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_MAX_TOK  = Math.max(1024, parseInt(process.env.ANTHROPIC_MAX_TOKENS, 10) || 32768); // Claude Sonnet supports far more than the old 8192; long documents were losing their tail
const OPENROUTER_API_KEY = process.env.OPENROUTER_API_KEY || "";
const OPENROUTER_MODEL   = process.env.OPENROUTER_MODEL || "nvidia/nemotron-3-ultra-550b-a55b:free";
// NVIDIA NIM (build.nvidia.com) — FREE OpenAI-compatible API. Powers the Max tier's PRIMARY engine
// (DeepSeek V4 Pro, frontier-class reasoning+coding). Key from .env (NVIDIA_API_KEY); when it's
// unset or rate-limited (free tier ~40 req/min) Max falls back to Gemini automatically.
const NVIDIA_API_KEY = process.env.NVIDIA_API_KEY || "";
const NVIDIA_OAI_URL = "https://integrate.api.nvidia.com/v1/chat/completions";
const NVIDIA_MODEL   = process.env.NVIDIA_MODEL || "deepseek-ai/deepseek-v4-pro";
// CREDIT GUARD: cap DeepSeek (NVIDIA) calls per day so the free credit can't be drained — beyond the
// cap, Max uses Gemini (free). Tune with NVIDIA_DAILY_CAP. (server.mjs: in-memory per-process day count.)
const NVIDIA_DAILY_CAP = parseInt(process.env.NVIDIA_DAILY_CAP, 10) || 100;
let _nvDay = "", _nvCount = 0;
function nvidiaUnderCap() { const d = new Date().toISOString().slice(0, 10); if (d !== _nvDay) { _nvDay = d; _nvCount = 0; } return _nvCount < NVIDIA_DAILY_CAP; }
function nvidiaCharge() { _nvCount++; }
const OPENROUTER_URL     = "https://openrouter.ai/api/v1/chat/completions";
// Gemini TEXT for the Max tier — Google AI Studio FREE tier (Flash family is free,
// ~1500 req/day, no credit card; the stronger Pro tier is paid since Apr 2026). Uses
// Gemini's OpenAI-compatible endpoint so it streams exactly like OpenRouter. Tried FIRST
// in the Max chain. GEMINI_TEXT_MODEL may be a comma-separated fallback list of ids — the
// adapter uses the first that actually streams (resilient to Google's model-id churn).
const GEMINI_TEXT_MODELS = (process.env.GEMINI_TEXT_MODEL || "gemini-2.5-flash,gemini-flash-latest").split(",").map((s) => s.trim()).filter(Boolean);
/* VISION uses its OWN model chain, separate from text. Page OCR is transcription, not reasoning,
   so the cheapest capable model wins — and on the free tier the difference is not subtle:
   gemini-2.5-flash allows 20 requests/DAY per key, while the Flash-Lite line allows 500. With a
   12-key pool that is 240 page-scans/day for the whole site versus 6,000. Same 250K TPM, so
   throughput is unaffected. 2.5-flash stays last as the known-good fallback, and any id the
   account cannot serve simply falls through to the next entry in the loop. */
const GEMINI_VISION_MODELS = (process.env.GEMINI_VISION_MODEL ||
  "gemini-3.5-flash-lite,gemini-3.1-flash-lite,gemini-2.5-flash").split(",").map((s) => s.trim()).filter(Boolean);
const GEMINI_OAI_URL     = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";
// Gemini image model (Google AI Studio "Nano Banana") — actual Gemini-level quality.
// If GEMINI_API_KEY is set, /api/image uses it FIRST, falling back to keyless
// pollinations on error/quota. Free key, NO credit card (aistudio.google.com).
// GEMINI API KEY POOL — Gemini's free tier is quota-limited PER PROJECT (not per key),
// so add keys from DIFFERENT Google Cloud projects/accounts to multiply the daily voice
// quota. Put ALL your keys in ONE variable — GEMINI_API_KEYS — separated by commas,
// spaces or new lines (whatever); GEMINI_API_KEY and GEMINI_API_KEY_1..24 also still work.
// Everything is merged, quotes/whitespace stripped, and DUPLICATES removed, so it doesn't
// matter if the same key appears twice. When a key hits its limit (429) the pool rotates
// to the next; a limited key rests briefly (RPM resets each minute, daily ~midnight PT).
const GEMINI_KEYS = (() => {
  const blob = [
    process.env.GEMINI_API_KEY || "",
    process.env.GEMINI_API_KEYS || "",
    ...Array.from({ length: 24 }, (_, i) => process.env["GEMINI_API_KEY_" + (i + 1)] || ""),
  ].join(" ");
  const keys = blob
    .split(/[\s,;]+/)                         // comma / space / newline / semicolon — any separator
    .map((k) => k.trim().replace(/^["']+|["']+$/g, "")) // strip stray quotes/whitespace
    .filter((k) => k.length >= 20);           // real keys are long; drops empty/junk tokens
  return [...new Set(keys)];                  // de-dupe so a repeated key isn't counted twice
})();
const GEMINI_API_KEY     = GEMINI_KEYS[0] || "";   // back-compat: `if (GEMINI_API_KEY)` = "any key configured"
const _gemCooldown = new Map();                    // key → ms timestamp it may be retried
const _gemStrikes  = new Map();                    // key → CONSECUTIVE 429s, cleared by a success
let   _gemCursor   = 0;                            // round-robin position
/** A key answered successfully → it is healthy, so forget its strike history. */
function geminiMarkOk(key) { if (key) _gemStrikes.delete(key); }
function geminiMarkLimited(key, status) {
  if (!key) return;
  if (status !== 429) { _gemCooldown.set(key, Date.now() + 5 * 60_000); return; }
  // Google returns 429 for BOTH the per-minute cap and the per-DAY cap, and the body does not
  // reliably say which. A minute-capped key is healthy again in a minute; a DAY-capped one is
  // dead until Google's quota window resets, and retrying it every 65s all day is pure waste —
  // each retry is a round-trip that fails and, on some quotas, still counts. So escalate on
  // CONSECUTIVE 429s: one is a burst, two is pressure, three means the daily allowance is gone.
  const n = (_gemStrikes.get(key) || 0) + 1;
  _gemStrikes.set(key, n);
  _gemCooldown.set(key, Date.now() + (n <= 1 ? 65_000 : n === 2 ? 5 * 60_000 : 6 * 3_600_000));
}
/** Next healthy key, ROUND-ROBIN; if all are cooling, the one recovering soonest (never give up). */
function geminiPickKey() {
  if (!GEMINI_KEYS.length) return "";
  const now = Date.now();
  // Round-robin, NOT first-available. Always handing out key #1 while it is healthy burns its
  // entire daily allowance before key #2 is ever touched, so a 12-key pool delivers the daily
  // capacity of ONE key at a time instead of twelve. Spreading the load is what makes the pool
  // worth having — it matters most for Brain, which fires one request per scanned page.
  for (let i = 0; i < GEMINI_KEYS.length; i++) {
    const idx = (_gemCursor + i) % GEMINI_KEYS.length;
    const k = GEMINI_KEYS[idx];
    if (now >= (_gemCooldown.get(k) || 0)) { _gemCursor = (idx + 1) % GEMINI_KEYS.length; return k; }
  }
  return GEMINI_KEYS.reduce((a, b) => ((_gemCooldown.get(a) || 0) <= (_gemCooldown.get(b) || 0) ? a : b));
}
const GEMINI_IMAGE_MODEL = process.env.GEMINI_IMAGE_MODEL || "gemini-2.5-flash-image";
// Hugging Face image model. Only FLUX.1-schnell is still served FREE by hf-inference
// (FLUX.1-dev/SDXL/SD3.5 now 410/400 — need a paid provider). Lossless PNG, but not
// clearly better than keyless pollinations. If HF_API_KEY is set, /api/image tries it
// after Gemini, before keyless pollinations. HF_IMAGE_URL overrides the endpoint.
const HF_API_KEY     = process.env.HF_API_KEY || "";
const HF_IMAGE_MODEL = process.env.HF_IMAGE_MODEL || "black-forest-labs/FLUX.1-schnell";
const HF_IMAGE_URL   = process.env.HF_IMAGE_URL || ("https://router.huggingface.co/hf-inference/models/" + HF_IMAGE_MODEL);
// Puter.com image generation (the BEST free option). Calls Puter's driver API with
// the DEVELOPER's auth token server-side, so END USERS never sign in to Puter. Gives
// real GPT-Image / Gemini ("Nano Banana") quality for free. Tried FIRST when the token
// is set. Get a token at https://puter.com/dashboard#account → API token → Create.
const PUTER_AUTH_TOKEN    = process.env.PUTER_AUTH_TOKEN || "";
// Default = gpt-image-2 at "low": the FULL GPT-Image model (sharper, better in-image
// text than gpt-image-1-mini) at moderate cost. gpt-image-2 "high"/"medium" + gemini
// "nano-banana" cost more and 402 fast; set gpt-image-1-mini for the cheapest / most-
// images-per-credit option.
const PUTER_IMAGE_MODEL   = process.env.PUTER_IMAGE_MODEL || "gpt-image-2";
const PUTER_IMAGE_QUALITY = process.env.PUTER_IMAGE_QUALITY || "low"; // gpt-image-2 / gpt-image-1.5 only: low | medium | high
const PUTER_DRIVER_URL    = "https://api.puter.com/drivers/call";
// Friendly aliases (mirrors puter.js so PUTER_IMAGE_MODEL=nano-banana works server-side)
const PUTER_MODEL_ALIASES = { "nano-banana": "gemini-2.5-flash-image-preview", "nano-banana-pro": "gemini-3-pro-image-preview" };
// Cloudflare Workers AI image generation — RELIABLE FREE fallback (10,000 neurons/day
// free ≈ ~150-200 images/day, no card). FLUX.1-schnell quality (≈ pollinations, NOT
// gpt-image/Gemini). Server-side with the developer's token → no user login. Needs a
// free Cloudflare account: dash.cloudflare.com → Account ID + an API token with the
// "Workers AI" permission. Tried after the premium engines, before keyless pollinations.
const CF_ACCOUNT_ID  = process.env.CF_ACCOUNT_ID || "";
const CF_API_TOKEN   = process.env.CF_API_TOKEN || "";
// Default = FLUX.2 Klein 9B: newest FLUX.2 family — excellent quality + the BEST free
// in-image text (legible "Firas AI") AND fast (~4s at 6 steps), far better value than
// flux-2-dev (same quality, ~80s). ~65 free imgs/day. FLUX.2 needs a multipart request
// (handled in generateImageCloudflare). Higher volume: @cf/black-forest-labs/flux-1-schnell
// (~130/day, weak text). Premium-but-pricey: @cf/leonardo/lucid-origin (~4/day).
const CF_IMAGE_MODEL = process.env.CF_IMAGE_MODEL || "@cf/black-forest-labs/flux-2-klein-9b";
const CF_IMAGE_STEPS = Math.min(20, Math.max(1, parseInt(process.env.CF_IMAGE_STEPS || "10", 10) || 10)); // flux-2 (no per-step cost) uses this; flux-schnell clamped to 8 in the request
// Cloudflare Workers AI TEXT model — a REAL free engine (10k neurons/day) that works from any country
// (Iraq included), so it rescues chat when the Gemini/OpenRouter free tiers are 429-exhausted.
const CF_TEXT_MODEL = process.env.CF_TEXT_MODEL || "@cf/meta/llama-3.3-70b-instruct-fp8-fast";
// STRONG Cloudflare model for HARD tasks (Max tier / math / science / exam generation): a free
// Workers-AI REASONING model (emits <think>…</think> chains) — far more CORRECT on Olympiad/JEE-grade
// problems than the fast llama fallback. Used only on the hard path so normal chat stays fast; if it's
// unavailable the rescue chain simply degrades to the next engine. Its <think> is stripped before the
// answer is streamed (see streamCloudflareText). Override with CF_TEXT_MODEL_STRONG.
const CF_TEXT_MODEL_STRONG = process.env.CF_TEXT_MODEL_STRONG || "@cf/qwen/qwq-32b";
// Detect a genuinely hard prompt (math/science/exam) so it's routed to the reasoning model even on
// lower tiers. Keeps the fast model for everyday chat.
const CF_HARD_RE = /امتحان|اختبار|أسئلة|اسئلة|بنك\s*أسئلة|واجب|مسألة|مسائل|احسب|أثبت|برهن|اشتقاق|تكامل|تفاضل|معادل|هندسة|نظرية|رياضيات|جبر|فيزياء|كيمياء|quiz|exam|worksheet|\bmcq\b|olympiad|putnam|\bproof\b|theorem|integral|derivative|calculus|algebra|geometry|equation|\bmath\b|physics|chem|\bsolve\b|∫|√|∑|[0-9]\s*[+\-*/^=]\s*[0-9a-zA-Z]/i;
function cfLastUserText(messages) {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m && m.role === "user") return typeof m.content === "string" ? m.content : (Array.isArray(m.content) ? m.content.map((p) => (p && p.text) || "").join(" ") : "");
  }
  return "";
}

// Tier -> Ollama model + generation params (env-overridable).
// num_predict = MAX output tokens. Generous so long outputs (a full single-file
// website, big code, long derivations) are NOT truncated mid-answer. The model
// still stops early on short replies, so this only RAISES the ceiling.
// num_predict = MAX output tokens. The Ollama CLOUD models REJECT -1
// ("max_tokens must be positive"), so we use a very large finite cap instead —
// effectively unlimited (~65k tokens) so long code / full worksheets / multi-part
// science & math answers complete instead of cutting off. The model still stops
// early on short replies; the 5-min timeout is the backstop. Mini stays bounded
// so it remains the fast/short tier.
// num_predict = MAX output tokens. Generous so that "thinking" tokens (which
// share this budget on reasoning models) do NOT starve the actual answer/code.
// gpt-oss accepts up to 131072; qwen3-coder caps at its model max (65536, which
// still allows ~5000 lines and it does not spend tokens on thinking).
/* THE FOUR TIERS, ON THE SUBSCRIPTION CATALOGUE.

   Each is a LADDER, strongest first, ending on the model that is proven to answer today — so a
   name Ollama does not resolve costs one slow first request and is then skipped for half an hour,
   rather than hanging a tier the way qwen3.5:397b once did. The choices are not by reputation but
   by what each model says it is built for:

     mini  gemma4          frontier-level performance at small sizes; this tier exists to be fast
     pro   glm-5.2         flagship for long-horizon tasks, the everyday chat workhorse
     ultra kimi-k2.7-code  purpose-built for coding, ~30% fewer thinking tokens than k2.6 — this
                           is the Firas Code tier, where thinking tokens compete with the file
     max   kimi-k3         the most capable in the catalogue, backed by nemotron-3-ultra which is
                           explicitly built for LONG-RUNNING AGENT WORKFLOWS — the Agent tier

   Every one of them is overridable: OLLAMA_MODEL_MINI / _PRO / _ULTRA / _MAX take the same
   comma-separated form, so a better model can be tried without touching this file. */
const TIERS = {
  // EVERY tier has a fallbackModel on a DIFFERENT hosted pool, so a busy primary degrades to a
  // working model instead of surfacing "The Firas AI engine is busy".
  mini:  { models: modelLadder(process.env.OLLAMA_MODEL_MINI,  "gemma4:cloud,qwen3.5:35b-cloud,gpt-oss:120b-cloud"), get model() { return pickModel(this.models); }, temperature: 0.5, num_predict: 16384,  fallbackModel: "qwen3-coder:480b-cloud" },
  pro:   { models: modelLadder(process.env.OLLAMA_MODEL_PRO,   "glm-5.2:cloud,deepseek-v4-flash:cloud,gpt-oss:120b-cloud"), get model() { return pickModel(this.models); }, temperature: 0.7, num_predict: 131072, fallbackModel: "qwen3-coder:480b-cloud" },
  /* ultra is the CODE tier and had HALF the ceiling of the chat tier (65536 vs pro's
     131072), which is backwards: a chat answer stops when the point is made, but a
     single-file build has a hard floor — it is only useful if it reaches </html>. An
     ambitious brief (a Three.js globe with real geometry, shaders, country data and UI)
     runs to thousands of lines, and the budget was the binding constraint long before
     the model ran out of things to say. Raised to match pro. */
  /* TEMPERATURE 0.35, NOT 0.8. This is the code tier, and high temperature buys variety — which
     in prose is character and in code is invented APIs, inconsistent structure and a build that
     does not run. The model here is purpose-built for programming; 0.8 was spending its precision
     on randomness nobody asked for. Chat keeps its warmth on the pro tier where it belongs. */
  ultra: { models: modelLadder(process.env.OLLAMA_MODEL_ULTRA, "kimi-k2.7-code:cloud,glm-5.1:cloud,minimax-m3:cloud,qwen3-coder:480b-cloud"), get model() { return pickModel(this.models); }, temperature: 0.35, num_predict: 131072, fallbackModel: "gpt-oss:120b-cloud" },
  // Max = strongest general/reasoning model (671B), gated by a per-user daily cap.
  // Env-overridable so the model swaps without a redeploy if Ollama's cloud catalog
  // rotates. fallbackModel degrades to a known-good hosted model (gpt-oss) before the
  // last-resort pollinations fallback.
  /* Max was left on 32768 — a QUARTER of pro's ceiling on the tier that runs the Agent and
     every document build, which is precisely the work that needs the most room. A ten-problem
     PDF with a cover, a contents page and full worked solutions is tens of thousands of tokens
     before the model has said anything unusual, so the budget, not the model, was ending the
     document early and delivering two problems out of ten. Matched to pro/ultra; Ollama clamps
     to whatever the chosen model actually supports, so raising it cannot error. */
  /* TEMPERATURE 0.5. The Agent runs long chains where every step is the input to the next, so a
     wrong turn early is not one bad sentence — it is the rest of the mission built on top of it.
     Reliability beats flair here in a way it does not in ordinary chat. */
  max:   { models: modelLadder(process.env.OLLAMA_MODEL_MAX,   "kimi-k3:cloud,nemotron-3-ultra:cloud,glm-5.2:cloud,qwen3-coder:480b-cloud"), get model() { return pickModel(this.models); }, temperature: 0.5, num_predict: 131072, fallbackModel: process.env.OLLAMA_MODEL_MAX_FALLBACK || "gpt-oss:120b-cloud", capped: false },
};

// Vision/multimodal model — used automatically when a request carries images.
// qwen2.5vl:7b is verified installed locally. vl models do not emit useful
// "thinking", so vision requests always run with think OFF.
const OLLAMA_MODEL_VISION = process.env.OLLAMA_MODEL_VISION || "qwen2.5vl:7b";

// Image caps: at most 6 images per request; skip any single image whose raw
// base64 exceeds ~8MB. Larger JSON body cap (~25MB) applies to /api/chat only.
const MAX_IMAGES_PER_REQUEST = 10;
const MAX_IMAGE_B64_BYTES = 8_000_000;
const CHAT_BODY_LIMIT = 25_000_000;

// Strip an optional "data:image/...;base64," prefix and return RAW base64.
// Returns null for anything that isn't a usable, in-bounds base64 string.
function normalizeImage(img) {
  try {
    if (typeof img !== "string") return null;
    let s = img.trim();
    if (!s) return null;
    const comma = s.indexOf(",");
    if (s.startsWith("data:") && comma !== -1) s = s.slice(comma + 1);
    s = s.trim();
    if (!s) return null;
    if (s.length > MAX_IMAGE_B64_BYTES) return null; // too large -> skip
    return s;
  } catch {
    return null;
  }
}

// Vision is decided by the LATEST user message ONLY. So a text follow-up after
// an image routes back to the strong text model instead of staying stuck on the
// weaker vision model (the user's text is NOT treated as an image turn).
function hasImages(messages) {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m && m.role === "user") {
      return Array.isArray(m.images) && m.images.length > 0;
    }
  }
  return false;
}

// Drop image data from every message (used for the TEXT path so the text model
// never receives base64 images it cannot read).
function stripImages(messages) {
  return messages.map((m) => {
    if (m && Array.isArray(m.images)) {
      const { images, ...rest } = m;
      return rest;
    }
    return m;
  });
}

// Build an Ollama-native messages array, attaching cleaned RAW base64 images.
// Caps the total number of images across the whole request to MAX_IMAGES.
function buildVisionMessages(messages) {
  let budget = MAX_IMAGES_PER_REQUEST;
  return messages.map((m) => {
    const out = { role: m && typeof m.role === "string" ? m.role : "user", content: String((m && m.content) ?? "") };
    if (m && Array.isArray(m.images) && m.images.length && budget > 0) {
      const imgs = [];
      for (const raw of m.images) {
        if (budget <= 0) break;
        const norm = normalizeImage(raw);
        if (norm) { imgs.push(norm); budget--; }
      }
      if (imgs.length) out.images = imgs;
    }
    return out;
  });
}

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js":   "text/javascript; charset=utf-8",
  ".mjs":  "text/javascript; charset=utf-8",
  ".css":  "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg":  "image/svg+xml",
  ".png":  "image/png",
  ".jpg":  "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".ico":  "image/x-icon",
  ".woff2":"font/woff2",
  ".woff": "font/woff",
  ".map":  "application/json",
  ".txt":  "text/plain; charset=utf-8",
  ".mp4":  "video/mp4",
  ".webm": "video/webm",
};

/* ===========================================================================
   DATABASE — JSON file at data/db.json with serialized writes (mutex).
   shape: { users: [], chats: [], secret: "<hex>" }
   =========================================================================== */
// DATA_DIR is env-overridable so a deploy can point it at a persistent disk
// (the bundled ./data is ephemeral on most hosts).
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, "data");
const DB_PATH = path.join(DATA_DIR, "db.json");

let DB = { users: [], chats: [], secret: "" };

// Promise-chain mutex: every write awaits the previous one, so concurrent
// writes can never interleave and corrupt the file.
let writeChain = Promise.resolve();

/* ---------------------------------------------------------------------------
   OPTIONAL Firebase Realtime Database backend (free, no card, PERSISTENT).
   Enabled ONLY when FIREBASE_DB_URL + FIREBASE_SERVICE_ACCOUNT are set; otherwise
   the server uses the local JSON file exactly as before (no behavior change).
   Lets the app keep accounts + history on hosts with no persistent disk
   (Render free, etc.). Zero deps: signs a service-account JWT with node:crypto,
   stores the whole DB under one RTDB key. The service account has ADMIN access,
   so the database can stay in locked mode (no public access needed).
--------------------------------------------------------------------------- */
const FB_DB_URL = (process.env.FIREBASE_DB_URL || "").replace(/\/+$/, "");
let FB_SA = null;
try {
  if (process.env.FIREBASE_SERVICE_ACCOUNT) FB_SA = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
} catch (e) {
  console.error("[firas] FIREBASE_SERVICE_ACCOUNT is not valid JSON:", (e && e.message) || e);
}
function fbEnabled() { return !!(FB_DB_URL && FB_SA && FB_SA.client_email && FB_SA.private_key); }
const FB_KEY = "firasdb"; // single RTDB key holding the whole DB JSON

function b64url(buf) {
  return Buffer.from(buf).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
let fbToken = null, fbTokenExp = 0;
async function fbAccessToken() {
  const now = Math.floor(Date.now() / 1000);
  if (fbToken && now < fbTokenExp - 60) return fbToken;
  const aud = FB_SA.token_uri || "https://oauth2.googleapis.com/token";
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(JSON.stringify({
    iss: FB_SA.client_email,
    scope: "https://www.googleapis.com/auth/firebase.database https://www.googleapis.com/auth/userinfo.email",
    aud, iat: now, exp: now + 3600,
  }));
  const signer = crypto.createSign("RSA-SHA256");
  signer.update(header + "." + claims);
  const jwt = header + "." + claims + "." + b64url(signer.sign(FB_SA.private_key));
  const r = await fetch(aud, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=" + encodeURIComponent(jwt),
    signal: AbortSignal.timeout(15_000),
  });
  if (!r.ok) throw new Error("firebase token " + r.status + ": " + (await r.text()).slice(0, 160));
  const j = await r.json();
  fbToken = j.access_token;
  fbTokenExp = now + (j.expires_in || 3600);
  return fbToken;
}
async function fbLoad() {
  const token = await fbAccessToken();
  const r = await fetch(FB_DB_URL + "/" + FB_KEY + ".json", { headers: { Authorization: "Bearer " + token }, signal: AbortSignal.timeout(45_000) });
  if (!r.ok) throw new Error("firebase load " + r.status);
  return await r.json(); // null when the key doesn't exist yet (fresh DB)
}
async function fbSave(db) {
  const token = await fbAccessToken();
  // Bounded: persist() serializes every DB write behind writeChain — a single hung
  // PUT with no timeout would silently freeze ALL persistence (accounts, chats,
  // memory) until a restart. Timing out lets the next queued write proceed.
  const r = await fetch(FB_DB_URL + "/" + FB_KEY + ".json", {
    method: "PUT",
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: JSON.stringify(db),
    signal: AbortSignal.timeout(60_000),
  });
  if (!r.ok) throw new Error("firebase save " + r.status + ": " + (await r.text()).slice(0, 160));
}

// Normalize a loaded DB (RTDB may return empty arrays as null / arrays as objects).
function normalizeDb(parsed) {
  const arr = (x) => (Array.isArray(x) ? x : (x && typeof x === "object" ? Object.values(x) : []));
  return {
    users: arr(parsed && parsed.users),
    chats: arr(parsed && parsed.chats),
    // announcements MUST persist across restarts (admin posts them once for everyone);
    // pending signups are transient but harmless to carry over (a sweep drops expired ones).
    announcements: arr(parsed && parsed.announcements),
    // Admin knowledge base (reference books for RAG grounding) — MUST persist across restarts.
    kb: arr(parsed && parsed.kb),
    // Redeem/activation codes (Gold/Diamond/Unlimited) — admin-managed, MUST persist.
    codes: arr(parsed && parsed.codes),
    pending: (parsed && parsed.pending && typeof parsed.pending === "object" && !Array.isArray(parsed.pending)) ? parsed.pending : {},
    // Public share snapshots (read-only chat pages at /?share=<id>).
    shares: (parsed && parsed.shares && typeof parsed.shares === "object" && !Array.isArray(parsed.shares)) ? parsed.shares : {},
    secret: parsed && typeof parsed.secret === "string" ? parsed.secret : "",
    /* Running OpenAI image spend, in dollars. Whitelisted here on purpose: normalizeDb drops
       anything it does not name, so without this line the budget would reset to zero on every
       restart and the ceiling would never actually be reached. */
    openaiImageUsd: Number(parsed && parsed.openaiImageUsd) || 0,
  };
}

function loadDbFromFile() {
  try {
    if (existsSync(DB_PATH)) DB = normalizeDb(JSON.parse(readFileSync(DB_PATH, "utf8") || "{}"));
  } catch (e) {
    console.error("[firas] failed to load db, starting fresh:", (e && e.message) || e);
    DB = { users: [], chats: [], secret: "" };
  }
}

// Load the DB (Firebase if configured, else file), then ensure a secret exists.
async function initDb() {
  if (fbEnabled()) {
    try {
      DB = normalizeDb((await fbLoad()) || {});
      console.log("[firas] database: Firebase Realtime Database");
    } catch (e) {
      // NEVER silently fall back to the (empty) file DB here — a later persist()
      // would overwrite the real remote data. Crash so the operator fixes config.
      console.error("[firas] FATAL: Firebase is configured but unreachable at boot:", (e && e.message) || e);
      process.exit(1);
    }
  } else {
    loadDbFromFile();
    try { if (!existsSync(DATA_DIR)) await mkdir(DATA_DIR, { recursive: true }); }
    catch (e) { console.error("[firas] could not create data dir:", (e && e.message) || e); }
  }
  if (!DB.secret) DB.secret = crypto.randomBytes(32).toString("hex");
  await persist(); // persists the secret on first run
}

// Serialized write (mutex) → Firebase when configured, else the local file.
function persist() {
  writeChain = writeChain.then(async () => {
    try {
      if (fbEnabled()) { await fbSave(DB); return; }
      if (!existsSync(DATA_DIR)) await mkdir(DATA_DIR, { recursive: true });
      const tmp = DB_PATH + ".tmp";
      // Pretty-print only while the DB is small; a big reference library would double every
      // write (persist runs on each chat save) for no benefit.
      const compact = JSON.stringify(DB);
      const payload = compact.length > 2_000_000 ? compact : JSON.stringify(DB, null, 2);
      await writeFile(tmp, payload, "utf8");
      try {
        const { rename } = await import("node:fs/promises");
        await rename(tmp, DB_PATH);
      } catch {
        await writeFile(DB_PATH, payload, "utf8");
      }
    } catch (e) {
      console.error("[firas] db write failed:", (e && e.message) || e);
    }
  });
  return writeChain;
}

/* ===========================================================================
   AUTH — scrypt password hashing + signed HttpOnly session cookies.
   =========================================================================== */
function sessionSecret() {
  return process.env.SESSION_SECRET || DB.secret;
}

// ASYNC scrypt — never blocks the event loop (a synchronous hash on every
// login/signup would let a few requests stall the whole server = DoS).
function hashPassword(password) {
  return new Promise((resolve, reject) => {
    const salt = crypto.randomBytes(16).toString("hex");
    crypto.scrypt(password, salt, 64, (err, dk) => {
      if (err) return reject(err);
      resolve({ salt, passHash: dk.toString("hex") });
    });
  });
}

function verifyPassword(password, salt, passHash) {
  return new Promise((resolve) => {
    crypto.scrypt(password, salt, 64, (err, dk) => {
      if (err) return resolve(false);
      try {
        const stored = Buffer.from(passHash, "hex");
        if (dk.length !== stored.length) return resolve(false);
        resolve(crypto.timingSafeEqual(dk, stored));
      } catch {
        resolve(false);
      }
    });
  });
}

/* ── REVOCABLE SESSIONS ────────────────────────────────────────────────────────────────
   The signed value used to be the bare user id, so one cookie string was a PERMANENT
   bearer credential for that account — valid until SESSION_SECRET itself changed. Every
   remedy a victim has was a no-op by construction: logout only clears the victim's own
   browser, changing the password rewrote passHash but left outstanding cookies working,
   and password RESET re-issued a byte-identical cookie because the HMAC input (the user id)
   had not changed. There was no "sign out everywhere" that could work.

   The payload now carries a per-user session VERSION. Bumping it invalidates every cookie
   issued before the bump, which is what makes reset/change-password/sign-out-everywhere
   mean something.

   BACKWARD COMPATIBLE ON PURPOSE: version 0 signs exactly the old payload, byte for byte,
   so no existing session is dropped when this ships. The first bump moves a user to the
   `id|vN` form and every cookie predating it stops verifying — revocation starts working
   the moment it is first needed, at the cost of logging nobody out today. */
function sessionPayload(id, ver) {
  return (ver > 0) ? (id + "|v" + ver) : id;
}
/** Split a verified payload back into its parts. */
function sessionParts(payload) {
  const i = payload.lastIndexOf("|v");
  if (i <= 0) return { id: payload, ver: 0 };
  const v = payload.slice(i + 2);
  if (!/^\d+$/.test(v)) return { id: payload, ver: 0 };
  return { id: payload.slice(0, i), ver: parseInt(v, 10) };
}
function signUserId(userId, ver) {
  const payload = sessionPayload(userId, ver || 0);
  const mac = crypto.createHmac("sha256", sessionSecret()).update(payload).digest("hex");
  return payload + "." + mac;
}

// Returns the userId if the cookie value is a valid, untampered signature.
function verifySessionValue(value) {
  if (typeof value !== "string") return null;
  const dot = value.lastIndexOf(".");
  if (dot <= 0) return null;
  const userId = value.slice(0, dot);
  const mac = value.slice(dot + 1);
  const expected = crypto.createHmac("sha256", sessionSecret()).update(userId).digest("hex");
  try {
    const a = Buffer.from(mac, "hex");
    const b = Buffer.from(expected, "hex");
    if (a.length !== b.length) return null;
    if (!crypto.timingSafeEqual(a, b)) return null;
  } catch {
    return null;
  }
  return userId;
}

function parseCookies(req) {
  const header = req.headers.cookie || "";
  const out = {};
  for (const part of header.split(";")) {
    const idx = part.indexOf("=");
    if (idx === -1) continue;
    const k = part.slice(0, idx).trim();
    const v = part.slice(idx + 1).trim();
    if (k) out[k] = decodeURIComponent(v);
  }
  return out;
}

const COOKIE_NAME = "firas_session";
const COOKIE_MAX_AGE = 2_592_000; // 30 days

// Send the cookie with Secure when we're actually on HTTPS (or told to via
// SECURE_COOKIES=1). Adding Secure unconditionally would break plain-HTTP
// localhost (the browser silently drops Secure cookies over http).
function isSecureReq(req) {
  return process.env.SECURE_COOKIES === "1" || (req && req.headers["x-forwarded-proto"] === "https");
}

function setSessionCookie(res, userId, req) {
  // Sign with the account's CURRENT session version, so a cookie minted right after a
  // revocation is valid while every cookie minted before it is not.
  const u = DB.users.find((x) => x.id === userId);
  const value = signUserId(userId, u ? (u.sessVer || 0) : 0);
  const secure = isSecureReq(req) ? "; Secure" : "";
  res.setHeader(
    "Set-Cookie",
    `${COOKIE_NAME}=${encodeURIComponent(value)}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${COOKIE_MAX_AGE}${secure}`
  );
}

function clearSessionCookie(res, req) {
  const secure = isSecureReq(req) ? "; Secure" : "";
  res.setHeader("Set-Cookie", `${COOKIE_NAME}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0${secure}`);
}

/* Simple in-memory rate limiter (per key, sliding window) — slows brute-force
   on auth endpoints. Good enough for a single-node deploy; resets on restart. */
const rlBuckets = new Map();
function rateLimited(key, max, windowMs) {
  const now = Date.now();
  const arr = (rlBuckets.get(key) || []).filter((t) => now - t < windowMs);
  arr.push(now);
  rlBuckets.set(key, arr);
  if (rlBuckets.size > 5000) {
    // bound memory: drop the oldest-ish entries
    for (const k of rlBuckets.keys()) { rlBuckets.delete(k); if (rlBuckets.size <= 2500) break; }
  }
  return arr.length > max;
}
function clientIp(req) {
  // Only trust X-Forwarded-For when explicitly behind a known proxy — otherwise
  // a client could spoof it to dodge the per-IP rate limiter.
  if (process.env.TRUST_PROXY === "1") {
    const xff = String(req.headers["x-forwarded-for"] || "").split(",")[0].trim();
    if (xff) return xff;
  }
  return (req.socket && req.socket.remoteAddress) || "unknown";
}

// Resolve the logged-in user (or null) from the request's session cookie.
function currentUser(req) {
  const cookies = parseCookies(req);
  const raw = cookies[COOKIE_NAME];
  if (!raw) return null;
  const payload = verifySessionValue(raw);
  if (!payload) return null;
  const { id, ver } = sessionParts(payload);
  const user = DB.users.find((u) => u.id === id) || null;
  if (!user) return null;
  /* The MAC only proves the cookie was issued by us, never that it is still current.
     A cookie whose version is behind the account's was issued before a logout-everywhere,
     a password change, or a reset — the three moments at which outstanding sessions must
     stop working. Without this check those actions could not revoke anything. */
  if ((user.sessVer || 0) !== ver) return null;
  return user;
}

/** Invalidate every session issued so far for this user. Callers persist. */
function bumpSessionVersion(user) {
  if (!user) return 0;
  user.sessVer = (user.sessVer || 0) + 1;
  return user.sessVer;
}

/* ===========================================================================
   GUEST SESSIONS — "try it without signing up".
   A guest gets its OWN signed cookie (firas_guest) carrying a random id
   prefixed "g_". It reuses the same HMAC as the real session, so a guest value
   pasted into firas_session still resolves to nothing (no DB user has a "g_"
   id) — the two identities can never be confused.
   A guest may CHAT (small daily quota, server-authoritative) but may NOT
   generate images, persist chats server-side, use memory, share, or subscribe.
   =========================================================================== */
const GUEST_COOKIE = "firas_guest";
const GUEST_COOKIE_MAX_AGE = 604_800; // 7 days — long enough to keep a trial going
const GUEST_LIMITS = {
  /* Guests are raised for real trial use but stay FAR below members, and that gap is
     deliberate. A guest identity costs nothing to mint — clear the cookie and you have a new
     one — so this is the allowance an abuser actually farms, and the network-scoped bucket
     (guestChargeIp) multiplies it by 4 per address, not per cookie. Members are the ones the
     site is free for; guests get enough to decide whether to sign up. */
  /* Tripled 2026-08-06 at Firas's request, now that members are fully unmetered: the gap
     between "trying it" and "signed up" was wider than it needed to be. Keep server.mjs and
     the edge function on the SAME numbers — a guest who hits a wall locally that the live
     site doesn't have (or worse, the reverse) is a bug that only shows up in production. */
  ai:    Math.max(0, parseInt(process.env.GUEST_DAILY_AI, 10)    || 180),
  code:  Math.max(0, parseInt(process.env.GUEST_DAILY_CODE, 10)  || 60),
  agent: Math.max(0, parseInt(process.env.GUEST_DAILY_AGENT, 10) || 24),
  brain: Math.max(0, parseInt(process.env.GUEST_DAILY_BRAIN, 10) || 120),
  /* Budget for nomem=true helper calls. Without an entry here `guestCharge` returns early
     (`!(limit >= 0)`) and the guest internal channel would stay unlimited — which is the
     exact hole being closed on the member side. Sized ~8x the guest chat allowance so a
     normal Code build never trips it. */
  internal: Math.max(0, parseInt(process.env.GUEST_DAILY_INTERNAL, 10) || 300),
  voice: Math.max(0, parseInt(process.env.GUEST_DAILY_VOICE, 10) || 120),
};
function newGuestId() { return "g_" + crypto.randomBytes(12).toString("hex"); }
/** The guest identity carried by this request, or null. */
function currentGuest(req) {
  const raw = parseCookies(req)[GUEST_COOKIE];
  if (!raw) return null;
  const id = verifySessionValue(raw);
  return id && id.startsWith("g_") ? { id, guest: true } : null;
}
function setGuestCookie(res, id, req) {
  const secure = isSecureReq(req) ? "; Secure" : "";
  const value = signUserId(id);
  res.setHeader(
    "Set-Cookie",
    `${GUEST_COOKIE}=${encodeURIComponent(value)}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${GUEST_COOKIE_MAX_AGE}${secure}`
  );
}
/** Per-guest daily counters, kept in DB.guests. Stale days are pruned so the
    store can never grow without bound (guest records are ephemeral by design). */
function guestRecord(id) {
  if (!DB.guests || typeof DB.guests !== "object") DB.guests = {};
  const today = serverDay();
  let g = DB.guests[id];
  if (!g || g.day !== today) { g = { day: today, ai: 0, code: 0, agent: 0, brain: 0, brainPages: 0, agentCids: [], last: {} }; DB.guests[id] = g; }
  if (!g.last) g.last = {};
  if (!Array.isArray(g.agentCids)) g.agentCids = [];
  const keys = Object.keys(DB.guests);
  if (keys.length > 5000) for (const k of keys) { if (DB.guests[k] && DB.guests[k].day !== today) delete DB.guests[k]; }
  return g;
}
/** Entitlement view for a guest — same shape as subInfo() so the client can
    render one meter component for both guests and members. */
function guestSubInfo(id) {
  const g = guestRecord(id);
  const remain = (p) => Math.max(0, GUEST_LIMITS[p] - (g[p] || 0));
  return {
    plan: "guest", expiresAt: null, daysLeft: null,
    limits: { ai: GUEST_LIMITS.ai, code: GUEST_LIMITS.code, agent: GUEST_LIMITS.agent, brain: GUEST_LIMITS.brain },
    used: { ai: g.ai || 0, code: g.code || 0, agent: g.agent || 0, brain: g.brain || 0 },
    remaining: { ai: remain("ai"), code: remain("code"), agent: remain("agent"), brain: remain("brain") },
  };
}
/** Charge one guest unit. Returns null when allowed, or a 429 body when the
    daily guest limit is spent. Idempotent on a repeated cid (same as members). */
/* IDEMPOTENCY THAT CANNOT BE FARMED.
   The retry check used to be `bucket.last[product] === cid` — a bare client string with no
   expiry and no tie to the request. So one charged turn bought the rest of the day: send
   {"cid":"X"} once, then reuse cid "X" with completely different messages forever. Every
   later call matched, skipped BOTH the limit test and the increment, and still streamed.

   A retry is now only a retry if it is the SAME REQUEST, sent AGAIN, SOON:
     · same cid, AND
     · same last user message (hashed), AND
     · within RETRY_WINDOW_MS.
   A genuine network retry satisfies all three. Farming satisfies none — a new question
   changes the hash, and waiting changes the clock.

   `agent` keeps its longer life on purpose: one mission legitimately spans many calls over
   several minutes and must count once. It is bounded by MISSION_WINDOW_MS rather than
   running until midnight. */
const RETRY_WINDOW_MS = 120_000;      // a real retry happens within seconds
const MISSION_WINDOW_MS = 45 * 60_000; // one agent mission
function reqHash(cid, messages) {
  let lastUser = "";
  if (Array.isArray(messages)) {
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i] && messages[i].role === "user") { lastUser = String(messages[i].content || ""); break; }
    }
  }
  return crypto.createHash("sha256").update(cid + "\u0000" + lastUser).digest("hex").slice(0, 32);
}
/** True when this is a genuine retry of an already-charged request. Prunes as it goes. */
function isRepeatCharge(bucket, product, cid, messages) {
  if (!cid) return false;
  const now = Date.now();
  const win = product === "agent" ? MISSION_WINDOW_MS : RETRY_WINDOW_MS;
  if (!Array.isArray(bucket.seen)) bucket.seen = [];
  bucket.seen = bucket.seen.filter((e) => e && now - e.t < MISSION_WINDOW_MS);
  const h = reqHash(cid, messages);
  // For agent the mission id alone identifies it; for everything else the body must match too.
  const hit = bucket.seen.find((e) =>
    e.p === product && e.c === cid && (product === "agent" || e.h === h) && now - e.t < win);
  if (hit) return true;
  bucket.seen.push({ p: product, c: cid, h, t: now });
  if (bucket.seen.length > 400) bucket.seen.shift();
  return false;
}

/* ── FREE GUEST RESETS, CLOSED ─────────────────────────────────────────────────────────
   The guest meter was keyed solely on the cookie id, and a fresh id is one request away:
   DELETE /api/guest clears the cookie, POST /api/guest mints a new one with a FULL
   allowance. The only brake was a 20/min per-IP limiter, which still permits ~28,800
   identities a day from one address — every one of them a fresh trial spending the owner's
   weekly-capped model pools.

   The fix is to meter the NETWORK identity as well: the cookie bucket stays (so people
   behind one household NAT are not charged for each other's usage at the individual level),
   and a second bucket keyed on a HASH of the IP is charged in parallel. Minting a new
   cookie no longer resets anything, because the IP bucket does not move.

   The IP allowance is deliberately a multiple of the per-cookie one — several genuine
   people do share an address (a household, a school, a café) and must not lock each other
   out. It only has to be small enough that farming thousands of identities is pointless. */
const GUEST_IP_MULTIPLIER = 4;
function guestIpKey(req) {
  const ip = clientIp(req);
  if (!ip) return null;
  // Hashed with the session secret so raw addresses are never written to db.json.
  return "ip_" + crypto.createHmac("sha256", sessionSecret()).update(String(ip)).digest("hex").slice(0, 24);
}
/** Charge the IP-wide bucket alongside the cookie one. Returns a denial or null. */
function guestChargeIp(req, product) {
  const key = guestIpKey(req);
  if (!key) return null;                       // no address to meter → cookie bucket only
  const limit = GUEST_LIMITS[product];
  if (!(limit >= 0)) return null;
  const cap = limit * GUEST_IP_MULTIPLIER;
  const g = guestRecord(key);
  if ((g[product] || 0) >= cap) {
    return { error: "guest daily limit reached", guest: true,
             quota: { product, used: g[product] || 0, limit: cap, plan: "guest", scope: "network" } };
  }
  g[product] = (g[product] || 0) + 1;
  return null;
}

function guestCharge(id, product, cidRaw, messages) {
  const g = guestRecord(id);
  const limit = GUEST_LIMITS[product];
  if (!(limit >= 0)) return null;
  const cid = String(cidRaw || "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64);
  const already = isRepeatCharge(g, product, cid, messages);
  if (!already && (g[product] || 0) >= limit) {
    return { error: "guest daily limit reached", guest: true, quota: { product, used: g[product] || 0, limit, plan: "guest" } };
  }
  if (!already) {
    /* Charge the network bucket FIRST: if it is spent, this identity must not consume one
       of its own units either, or a farmer would still drain the cookie allowances. */
    if (guestCharge._req) {
      const denied = guestChargeIp(guestCharge._req, product);
      if (denied) { persist(); return denied; }
    }
    g[product] = (g[product] || 0) + 1;
    if (product === "agent") { if (cid) { g.agentCids.push(cid); if (g.agentCids.length > 200) g.agentCids.shift(); } }
    else if (cid) g.last[product] = cid;
    persist();
  }
  return null;
}
/* The request is threaded to guestCharge() through a per-call slot rather than a new
   parameter on all five call sites — the alternative is five signatures that must stay in
   sync, and a missed one silently reopens the hole. Set immediately before each charge and
   cleared after, so it can never leak between requests (Node handles one at a time here). */
function guestChargeWithReq(req, id, product, cidRaw, messages) {
  guestCharge._req = req;
  try { return guestCharge(id, product, cidRaw, messages); }
  finally { guestCharge._req = null; }
}
/** Resolve "who is calling" for endpoints a guest is allowed to reach.
    Returns { user, id, isGuest:false } for a member, { id, isGuest:true } for a
    guest, or {} when neither identity is present. */
function callerOf(req) {
  const user = currentUser(req);
  if (user) return { user, id: user.id, isGuest: false };
  const g = currentGuest(req);
  if (g) return { id: g.id, isGuest: true };
  return {};
}

/* ===========================================================================
   SUBSCRIPTIONS & DAILY QUOTAS
   Plans: free (default) · gold · diamond · unlimited. Diamond & unlimited are
   uncapped; the difference is that unlimited never expires. All limits are
   per-calendar-day and reset at local midnight (serverDay). Server is the ONLY
   authority — the client can never set its own plan or bypass a limit.
   =========================================================================== */
/* `internal` is the budget for nomem=true helper calls — auto-title, the Code build
   pipeline, agent sub-steps, OCR. These are sub-steps of an action the user already paid
   for, so they are NOT charged against the product meters; but they are no longer free
   either, because `nomem` is a client-supplied boolean and an unbounded free channel is an
   unbounded free channel. The ceilings are ~8x the product limits: a heavy Code session
   fires roughly a dozen per build, so real use never approaches them. */
/* THE SITE IS FREE. Every plan now carries the same generous allowance — the paid tiers
   remain only so existing records that already hold one keep resolving.

   These are NOT sales limits, they are an ABUSE CEILING, and that is why they are numbers
   rather than -1. The model pools are shared: one Ollama weekly quota and real Anthropic
   credit on the Max tier serve every user at once. Uncapped, a single scripted loop drains
   both and takes the site down for everyone — the cost of "free" would land on the other
   users, not on the person abusing it.

   The numbers are set where no human reaches them: 2000 chat messages a day is roughly one
   every 40 seconds for 24 hours without pause. A real user simply never sees a limit.
   Raise them with env overrides if that ever proves wrong. */
const PLAN_LIMITS = {
  /* NO DAILY LIMIT. Firas asked for the site to be 100% free with no daily usage at all, so
     every plan is unmetered and the per-product counters below exist only as statistics.
     -1 is the existing "unlimited" sentinel every call site already understands, so nothing
     downstream needed to change: quotaRollDay still rolls the day, the counters still count,
     and limitsFor() simply never returns a ceiling to compare against. */
  free:      { ai: -1,   code: -1,  agent: -1,  brain: -1,  internal: -1,   voice: -1 },
  gold:      { ai: -1,   code: -1,  agent: -1,  brain: -1,  internal: -1,   voice: -1 },
  diamond:   { ai: -1,   code: -1,  agent: -1,  brain: -1,  internal: -1,   voice: -1 },
  unlimited: { ai: -1,   code: -1,  agent: -1,  brain: -1,  internal: -1,   voice: -1 },
};
function limitsFor(plan) { return PLAN_LIMITS[plan] || PLAN_LIMITS.free; }
// Effective plan RIGHT NOW — expired timed plans silently fall back to free
// (data/chats are untouched, so downgrade is lossless).
function planOf(user) {
  const s = user && user.sub;
  if (!s || !s.plan) return "free";
  if (s.plan === "unlimited") return "unlimited";
  if (s.plan !== "gold" && s.plan !== "diamond") return "free";
  if (s.expiresAt && Date.now() > s.expiresAt) return "free";
  return s.plan;
}
/* Ensure today's usage counters exist (resets on a new local day). Mutates user.quota.
   PARITY NOTE: the edge backend persists these counters as individual child keys under
   users/<id>/quota (and keeps agentCids as a MAP, not this array) because two Netlify
   isolates each doing read-modify-write on the whole user record lose one of the two
   writes. Here there is exactly one process mutating one shared in-memory DB object and
   persist() serializes it, so an array and a whole-record write are correct and cheap —
   this divergence is deliberate, don't "restore parity" by copying the edge shape. */
function quotaRollDay(user) {
  const today = serverDay();
  // brainPages = Firas Brain's daily INGEST budget (pages indexed), separate from `brain`
  // (answers), because page OCR rides nomem:true calls that quota charging deliberately skips.
  if (!user.quota || user.quota.day !== today) { user.quota = { day: today, ai: 0, code: 0, agent: 0, brain: 0, brainPages: 0, agentCids: [], last: {} }; return true; }
  if (!user.quota.last) user.quota.last = {};
  if (!Array.isArray(user.quota.agentCids)) user.quota.agentCids = [];
  return false;
}
// Read-only entitlement view for the client (no mutation).
function subInfo(user) {
  const plan = planOf(user);
  const s = (user && user.sub) || {};
  const lim = limitsFor(plan);
  const today = serverDay();
  const q = (user && user.quota && user.quota.day === today) ? user.quota : { ai: 0, code: 0, agent: 0, brain: 0 };
  const expiresAt = plan === "unlimited" ? null : (s.expiresAt || null);
  const daysLeft = expiresAt ? Math.max(0, Math.ceil((expiresAt - Date.now()) / 86400000)) : null;
  const remain = (p) => (lim[p] < 0 ? -1 : Math.max(0, lim[p] - (q[p] || 0)));
  return {
    plan, expiresAt, daysLeft,
    limits: { ai: lim.ai, code: lim.code, agent: lim.agent, brain: lim.brain },
    used: { ai: q.ai || 0, code: q.code || 0, agent: q.agent || 0, brain: q.brain || 0 },
    remaining: { ai: remain("ai"), code: remain("code"), agent: remain("agent"), brain: remain("brain") },
  };
}
// ---- redeem code helpers ----
function codesList() { if (!Array.isArray(DB.codes)) DB.codes = []; return DB.codes; }
function normCode(s) { return String(s || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 40); }
function genCode() {
  const A = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"; // no ambiguous 0/O/1/I/L
  const rnd = crypto.randomBytes(12);
  let out = "FIRAS";
  for (let i = 0; i < 12; i++) out += A[rnd[i] % A.length];
  return out; // FIRAS + 12 chars
}
function findCode(codeStr) { const c = normCode(codeStr); return c ? (codesList().find((x) => x.code === c) || null) : null; }
function codeStatus(c) {
  if (!c) return "invalid";
  if (c.disabled) return "disabled";
  if (c.expiresAt && Date.now() > c.expiresAt) return "expired";
  if ((c.uses || 0) >= (c.maxUses || 1)) return "used-up";
  return "active";
}
function publicCode(c) { return { ...c, status: codeStatus(c) }; }

// Strip secrets — NEVER return passHash / salt to the client. Includes the live
// subscription/quota view and the admin flag so the UI can gate features.
function publicUser(u) {
  return { id: u.id, name: u.name, email: u.email, admin: isAdmin(u), sub: subInfo(u) };
}

/* ===========================================================================
   Request helpers
   =========================================================================== */
function readBody(req, limit = 2_000_000) {
  return new Promise((resolve, reject) => {
    let data = "";
    let aborted = false;
    req.on("data", (c) => {
      data += c;
      if (data.length > limit) {
        aborted = true;
        req.destroy();
      }
    });
    req.on("end", () => (aborted ? reject(new Error("body too large")) : resolve(data)));
    req.on("error", reject);
  });
}

async function readJson(req, limit) {
  const raw = await readBody(req, limit);
  try {
    return JSON.parse(raw || "{}");
  } catch {
    return null;
  }
}

function sendJson(res, status, obj) {
  if (res.writableEnded) return;
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(obj));
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/* ===========================================================================
   FIREBASE / GOOGLE SIGN-IN — ID-token verification with ZERO npm deps.
   We verify the RS256 JWT ourselves using node:crypto + global fetch:
     1. split header.payload.signature, base64url-decode header+payload JSON
     2. fetch Google's x509 certs (kid -> PEM), cached per Cache-Control max-age
     3. pick the cert by header.kid, verify RS256 over `${header}.${payload}`
     4. validate alg/aud/iss/exp/iat/auth_time/sub/email claims
   On success we link-or-create a passwordless { provider:"google" } user and
   issue the SAME signed session cookie as email/password login.
   =========================================================================== */
// projectId is public (it ships in firebase-config.js); default to it so Google
// login works locally and on deploy without an extra env var. Override via env.
const FIREBASE_PROJECT_ID = process.env.FIREBASE_PROJECT_ID || "firas-ai";
// Google's public signing certs for Firebase Auth ID tokens.
const GOOGLE_CERTS_URL =
  "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com";

// In-memory cert cache: { keys: { kid: pem, ... }, expiresAt: epochMs }.
let googleCertCache = { keys: null, expiresAt: 0 };
let googleCertInflight = null; // de-dupe concurrent refreshes

// base64url -> Buffer (tolerant of missing padding).
function b64urlToBuffer(str) {
  if (typeof str !== "string") return null;
  let s = str.replace(/-/g, "+").replace(/_/g, "/");
  const pad = s.length % 4;
  if (pad === 2) s += "==";
  else if (pad === 3) s += "=";
  else if (pad === 1) return null; // invalid base64url length
  try {
    return Buffer.from(s, "base64");
  } catch {
    return null;
  }
}

// base64url JSON segment -> parsed object (or null).
function decodeJwtSegment(seg) {
  const buf = b64urlToBuffer(seg);
  if (!buf) return null;
  try {
    return JSON.parse(buf.toString("utf8"));
  } catch {
    return null;
  }
}

// Fetch Google's x509 certs, caching them in memory until Cache-Control max-age
// expires. Returns the kid->PEM map, or null if it can't be (re)fetched and no
// cached copy is usable. Never throws.
async function getGoogleCerts() {
  const now = Date.now();
  if (googleCertCache.keys && now < googleCertCache.expiresAt) {
    return googleCertCache.keys;
  }
  if (googleCertInflight) return googleCertInflight; // coalesce parallel refreshes

  googleCertInflight = (async () => {
    try {
      const ac = new AbortController();
      const to = setTimeout(() => ac.abort(), 10_000);
      let resp;
      try {
        resp = await fetch(GOOGLE_CERTS_URL, { signal: ac.signal });
      } finally {
        clearTimeout(to);
      }
      if (!resp || !resp.ok) {
        // Serve a stale-but-present cache rather than failing outright.
        return googleCertCache.keys || null;
      }
      const keys = await resp.json();
      if (!keys || typeof keys !== "object") return googleCertCache.keys || null;

      // Honor Cache-Control max-age; default to 1h if absent/unparseable.
      let maxAge = 3600;
      const cc = resp.headers.get("cache-control") || "";
      const m = cc.match(/max-age\s*=\s*(\d+)/i);
      if (m) maxAge = parseInt(m[1], 10) || 3600;

      googleCertCache = { keys, expiresAt: Date.now() + maxAge * 1000 };
      return keys;
    } catch {
      return googleCertCache.keys || null; // network error -> stale cache if any
    } finally {
      googleCertInflight = null;
    }
  })();
  return googleCertInflight;
}

// Verify a Firebase/Google ID token. Returns the validated payload on success,
// or null on ANY failure (generic — callers must not leak the reason). Never
// throws and never hangs (cert fetch is bounded).
async function verifyFirebaseIdToken(idToken) {
  if (typeof idToken !== "string" || idToken.length < 20 || idToken.length > 8192) return null;
  const parts = idToken.split(".");
  if (parts.length !== 3) return null;
  const [headerB64, payloadB64, signatureB64] = parts;

  const header = decodeJwtSegment(headerB64);
  const payload = decodeJwtSegment(payloadB64);
  if (!header || !payload) return null;

  // alg MUST be RS256 (never accept "none" or HS* — algorithm-confusion guard).
  if (header.alg !== "RS256" || header.typ && header.typ !== "JWT") return null;
  if (typeof header.kid !== "string" || !header.kid) return null;

  const certs = await getGoogleCerts();
  if (!certs) return null;
  const pem = certs[header.kid];
  if (typeof pem !== "string" || !pem) return null; // unknown / rotated kid

  const signature = b64urlToBuffer(signatureB64);
  if (!signature || !signature.length) return null;

  // Verify the RS256 signature over the EXACT signing input bytes.
  const signingInput = `${headerB64}.${payloadB64}`;
  let sigOk = false;
  try {
    sigOk = crypto
      .createVerify("RSA-SHA256")
      .update(signingInput)
      .verify(pem, signature);
  } catch {
    return null;
  }
  if (!sigOk) return null;

  // ---- Claim validation (all required) ----
  const now = Math.floor(Date.now() / 1000);
  const skew = 300; // tolerate 5 min of clock skew

  // aud must equal our Firebase project; iss must be the matching issuer.
  if (payload.aud !== FIREBASE_PROJECT_ID) return null;
  if (payload.iss !== `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`) return null;

  // exp in the future; iat/auth_time not absurdly in the future.
  if (typeof payload.exp !== "number" || payload.exp <= now - skew) return null;
  if (typeof payload.iat !== "number" || payload.iat > now + skew) return null;
  if (payload.auth_time != null) {
    if (typeof payload.auth_time !== "number" || payload.auth_time > now + skew) return null;
  }

  // sub = the Firebase user id; must be a non-empty string.
  if (typeof payload.sub !== "string" || !payload.sub) return null;

  // A usable, valid email is required to link/create an account.
  const email = String(payload.email || "").trim().toLowerCase();
  if (!email || !EMAIL_RE.test(email) || email.length > 200) return null;
  // NOTE: email_verified is false for fresh Firebase email/password sign-ups, so
  // we do NOT reject on it (otherwise password sign-in would never work). For a
  // PUBLIC deployment, enable email verification in Firebase to harden this.

  return payload;
}

/* ===========================================================================
   AUTH ENDPOINTS
   =========================================================================== */
async function handleSignup(req, res) {
  if (rateLimited("auth:" + clientIp(req), 12, 60_000)) {
    return sendJson(res, 429, { error: "too many attempts, please wait a minute" });
  }
  const body = await readJson(req, 100_000);
  if (!body) return sendJson(res, 400, { error: "invalid JSON body" });

  const name = String(body.name ?? "").trim().slice(0, 80);
  const email = String(body.email ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");

  if (!name) return sendJson(res, 400, { error: "name is required" });
  if (!EMAIL_RE.test(email) || email.length > 200) return sendJson(res, 400, { error: "a valid email is required" });
  if (password.length < 8) return sendJson(res, 400, { error: "password must be at least 8 characters" });
  if (password.length > 200) return sendJson(res, 400, { error: "password is too long" });
  if (DB.users.some((u) => u.email === email)) return sendJson(res, 409, { error: "email already registered" });

  // Do NOT create the account yet — stash a PENDING signup and email a verification LINK
  // (a button). The real account is created when the link is opened (handleVerifySignup).
  // A poll-id (pid) lets the ORIGINAL device finish the moment the link is opened on ANY
  // device (open the email on your phone → your computer logs in too).
  const { salt, passHash } = await hashPassword(password);
  const token = crypto.randomBytes(24).toString("hex");
  const pid = crypto.randomBytes(16).toString("hex");
  if (!DB.pending) DB.pending = {};
  DB.pending[email] = { name, email, passHash, salt, token, pid, exp: Date.now() + VERIFY_TTL_MS, verified: false, userId: null };
  await persist();
  const link = resetAppBase(req) + "/?verify=" + token;
  const sent = await sendEmail(email, "تأكيد حسابك — Firas AI", verifyEmailHtml(link));
  if (!sent) console.log("[firas] signup verify link for " + email + " -> " + link + " (not delivered — dev fallback)");
  return sendJson(res, 200, { ok: true, pending: true, email, pid });
}

// Open the emailed LINK → create the real account (idempotent) + sign in THIS device.
async function handleVerifySignup(req, res) {
  if (rateLimited("verify:" + clientIp(req), 30, 60_000)) return sendJson(res, 429, { error: "too many attempts, please wait a minute" });
  const body = await readJson(req, 100_000);
  const token = String((body && body.token) || "").trim();
  if (!token) return sendJson(res, 400, { error: "رابط غير صالح" });
  const email = Object.keys(DB.pending || {}).find((k) => DB.pending[k].token === token);
  const p = email && DB.pending[email];
  if (!p || Date.now() > p.exp) { if (p) { delete DB.pending[email]; await persist(); } return sendJson(res, 400, { error: "الرابط غير صالح أو منتهي — أعد التسجيل" }); }
  let user;
  if (p.verified && p.userId) {
    user = DB.users.find((u) => u.id === p.userId); // idempotent re-open
  } else {
    if (DB.users.some((u) => u.email === email)) { delete DB.pending[email]; await persist(); return sendJson(res, 409, { error: "email already registered" }); }
    user = { id: crypto.randomUUID(), name: p.name, email: p.email, passHash: p.passHash, salt: p.salt, emailVerified: true, createdAt: new Date().toISOString() };
    DB.users.push(user);
    p.verified = true; p.userId = user.id; p.verifiedAt = Date.now();
    await persist();
    // personal welcome from Firas (fire-and-forget — never block sign-in on email)
    sendEmail(user.email, "Welcome to Firas AI 🎉", welcomeEmailHtml(user.name, resetAppBase(req) + "/"), { fromName: "Firas" }).catch(() => {});
  }
  if (!user) return sendJson(res, 400, { error: "تعذّر التأكيد — أعد التسجيل" });
  setSessionCookie(res, user.id, req);
  return sendJson(res, 200, { ok: true, user: publicUser(user) });
}

// The original device polls this with its pid; once the link is opened ANYWHERE it returns
// verified and signs THIS device in too (cross-device completion), then cleans up.
async function handleVerifyStatus(req, res) {
  if (rateLimited("vstatus:" + clientIp(req), 60, 60_000)) return sendJson(res, 429, { error: "too many requests" });
  const body = await readJson(req, 100_000);
  const pid = String((body && body.pid) || "").trim();
  if (!pid) return sendJson(res, 400, { error: "missing pid" });
  const email = Object.keys(DB.pending || {}).find((k) => DB.pending[k].pid === pid);
  const p = email && DB.pending[email];
  if (!p) return sendJson(res, 200, { verified: false, gone: true });
  if (Date.now() > p.exp) { delete DB.pending[email]; await persist(); return sendJson(res, 200, { verified: false, expired: true }); }
  if (p.verified && p.userId) {
    const user = DB.users.find((u) => u.id === p.userId);
    if (user) {
      setSessionCookie(res, user.id, req);
      delete DB.pending[email]; await persist();   // both devices handled → done
      return sendJson(res, 200, { verified: true, user: publicUser(user) });
    }
  }
  return sendJson(res, 200, { verified: false });
}

// Re-send a fresh verification LINK for a pending email.
async function handleResendCode(req, res) {
  if (rateLimited("resend:" + clientIp(req), 4, 60_000)) return sendJson(res, 429, { error: "too many requests, wait a minute" });
  const body = await readJson(req, 100_000);
  const email = String((body && body.email) || "").trim().toLowerCase();
  /* PROTOTYPE POLLUTION: DB.pending is a plain object keyed by the CALLER's string, and
     this was the one lookup that never validated it. `{"email":"__proto__"}` resolved to
     Object.prototype — truthy, .verified undefined — so the branch below assigned .token
     and .exp ONTO Object.prototype, and from then on EVERY object in the process
     inherited an `exp` timestamp and a `token`. (The signup path is safe because
     EMAIL_RE rejects "__proto__" before the write.) The edge backend can't hit this at
     all: it keys pending signups by emailKey(), a base64url hash, under a db path.
     Require a real address AND an own property. */
  if (!EMAIL_RE.test(email) || email.length > 200) return sendJson(res, 200, { ok: true }); // same reply either way (anti-enumeration)
  const p = (DB.pending && Object.prototype.hasOwnProperty.call(DB.pending, email)) ? DB.pending[email] : null;
  if (p && !p.verified) {
    p.token = crypto.randomBytes(24).toString("hex"); p.exp = Date.now() + VERIFY_TTL_MS;
    await persist();
    const link = resetAppBase(req) + "/?verify=" + p.token;
    const sent = await sendEmail(email, "تأكيد حسابك — Firas AI", verifyEmailHtml(link));
    if (!sent) console.log("[firas] (resend) signup verify link for " + email + " -> " + link + " (not delivered — dev fallback)");
  }
  return sendJson(res, 200, { ok: true });
}

// Periodically drop expired pending signups so DB.pending can't grow unbounded when the verify
// link is opened on the SAME device (no cross-device poll ever cleans it). They're useless past
// exp anyway. unref() so this timer never keeps the process alive on shutdown.
const _pendingSweep = setInterval(async () => {
  if (!DB.pending) return;
  const now = Date.now(); let changed = false;
  for (const k of Object.keys(DB.pending)) {
    if (now > (DB.pending[k].exp || 0) + 60_000) { delete DB.pending[k]; changed = true; }
  }
  if (changed) { try { await persist(); } catch (_) {} }
}, 5 * 60_000);
if (_pendingSweep && typeof _pendingSweep.unref === "function") _pendingSweep.unref();

async function handleLogin(req, res) {
  const ip = clientIp(req);
  if (rateLimited("auth:" + ip, 12, 60_000)) {
    return sendJson(res, 429, { error: "too many attempts, please wait a minute" });
  }
  const body = await readJson(req, 100_000);
  if (!body) return sendJson(res, 400, { error: "invalid JSON body" });

  const email = String(body.email ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");

  // Extra per-account throttle to slow targeted brute-force.
  if (rateLimited("login:" + email, 6, 60_000)) {
    return sendJson(res, 429, { error: "too many attempts, please wait a minute" });
  }

  const user = DB.users.find((u) => u.email === email);
  // Generic error — never reveal which field was wrong.
  if (!user || !(await verifyPassword(password, user.salt, user.passHash))) {
    return sendJson(res, 401, { error: "invalid email or password" });
  }

  setSessionCookie(res, user.id, req);
  return sendJson(res, 200, { user: publicUser(user) });
}

function handleLogout(req, res) {
  clearSessionCookie(res, req);
  return sendJson(res, 200, { ok: true });
}

function handleMe(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "not authenticated" });
  return sendJson(res, 200, { user: publicUser(user) });
}

/* ---- Guest session: start (or resume) a no-signup trial. Idempotent — an
   existing valid guest cookie is reused so a reload keeps the same quota. ---- */
function handleGuestStart(req, res) {
  // Already signed in? Don't hand out a guest identity — return the real user so
  // a stray call from a logged-in tab is harmless.
  const user = currentUser(req);
  if (user) return sendJson(res, 200, { guest: false, user: publicUser(user) });
  if (rateLimited("guest:" + clientIp(req), 20, 60_000)) return sendJson(res, 429, { error: "too many requests" });
  let g = currentGuest(req);
  if (!g) { g = { id: newGuestId(), guest: true }; setGuestCookie(res, g.id, req); }
  return sendJson(res, 200, { guest: true, user: { id: g.id, name: "", email: "", guest: true, admin: false, sub: guestSubInfo(g.id) } });
}

/* ---- Guest session: end the trial (clears the cookie). ---- */
function handleGuestEnd(req, res) {
  const secure = isSecureReq(req) ? "; Secure" : "";
  res.setHeader("Set-Cookie", `${GUEST_COOKIE}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0${secure}`);
  return sendJson(res, 200, { ok: true });
}

/* ---- Password reset: email a time-limited link via Resend (zero-dep HTTP API).
   Without RESEND_API_KEY the link is logged to the server console (dev). ---- */
const RESEND_API_KEY = process.env.RESEND_API_KEY || "";
const RESEND_FROM    = process.env.RESEND_FROM || "Firas AI <onboarding@resend.dev>";
// Brevo (primary): single-sender verification reaches ALL members for free, no domain needed.
const BREVO_API_KEY   = process.env.BREVO_API_KEY || "";
const BREVO_FROM      = process.env.BREVO_FROM || "firasnozad@gmail.com"; // your VERIFIED single sender
const BREVO_FROM_NAME = process.env.BREVO_FROM_NAME || "Firas AI";
const RESET_APP_URL  = (process.env.APP_URL || "").replace(/\/+$/, "");
const RESET_TTL_MS   = 30 * 60_000;
const VERIFY_TTL_MS  = 15 * 60_000; // signup email-verification code lifetime
function fmtNow(loc) {
  try { return new Date().toLocaleString(loc || "ar", { dateStyle: "long", timeStyle: "short" }); }
  catch (_) { return new Date().toISOString().replace("T", " ").slice(0, 16) + " UTC"; }
}
// DARK, bold, professional, email-client-safe template (table layout + inline styles + RTL).
// Logo is rendered in-email (CSS) so it shows in ALL clients incl. Gmail — external image
// files are blocked by most clients until the site is on a real domain.
// Isolate a Latin/brand run inside RTL Arabic so the sentence doesn't scramble.
function ltr(s) { return '<span dir="ltr" style="unicode-bidi:isolate;">' + s + '</span>'; }
function bidiAuto(s) { return '<span dir="auto" style="unicode-bidi:isolate;">' + s + '</span>'; }
const EMAIL_FONT = "'IBM Plex Sans Arabic','Inter','Segoe UI',Tahoma,Arial,sans-serif";
function mailButton(link, label) {
  return '<table role="presentation" cellpadding="0" cellspacing="0" align="center" style="margin:16px auto 2px;"><tr>' +
    '<td style="border-radius:12px;background:#57AE9C;box-shadow:0 10px 26px rgba(87,174,156,0.34);" bgcolor="#57AE9C"><a href="' + link + '" style="display:inline-block;padding:15px 42px;font-family:' + EMAIL_FONT + ';font-size:16px;font-weight:700;color:#10221D;text-decoration:none;border-radius:12px;letter-spacing:.2px;">' + label + '</a></td>' +
    '</tr></table>';
}
function mailLink(link) {
  return '<p style="margin:20px 0 0;font-size:12.5px;color:#9C9A91;" dir="rtl">أو افتح هذا الرابط:<br><span dir="ltr" style="unicode-bidi:isolate;word-break:break-all;"><a href="' + link + '" style="color:#6BC0AE;">' + link + '</a></span></p>';
}
function brandedEmail(o) {
  // Matches the SITE's dark theme + the SITE's fonts (IBM Plex Sans Arabic / Inter, with system
  // fallbacks for clients that block web fonts). Text is bright + bold for clarity. Glow sits in
  // the TOP-RIGHT and BOTTOM-LEFT corners (page radial gradients + diagonal card box-shadows).
  const bg = "#262624", card = "#30302E", border = "#46453F", hair = "#3A3A36",
        ink = "#F6F4ED", body = "#DBD8CF", muted = "#C2BFB6", soft = "#8C8A81", accent = "#57AE9C", accent2 = "#6BC0AE", onacc = "#10221D";
  const font = EMAIL_FONT;
  const isEn = o.lang === "en";
  const cdir = isEn ? "ltr" : "rtl", calign = isEn ? "left" : "right";
  const time = o.time || fmtNow(isEn ? "en" : "ar");
  const sentLabel = isEn ? "Sent: " : "أُرسلت في: ";
  const tagline = isEn ? "Your intelligent assistant · Automated message, no need to reply." : "مساعدك الذكي · رسالة آلية، لا داعي للرد عليها.";
  const pageBg = "background:radial-gradient(60% 50% at 100% 0%,rgba(87,174,156,0.22),transparent 70%),radial-gradient(60% 50% at 0% 100%,rgba(87,174,156,0.17),transparent 70%)," + bg + ";";
  const cardGlow = "box-shadow:0 0 0 1px rgba(87,174,156,0.12),28px -28px 100px -16px rgba(87,174,156,0.24),-28px 28px 100px -16px rgba(87,174,156,0.20),0 28px 64px rgba(0,0,0,0.55);";
  return '<!doctype html><html dir="' + cdir + '" lang="' + (isEn ? "en" : "ar") + '"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<meta name="color-scheme" content="dark"><meta name="supported-color-schemes" content="dark">' +
    '<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>' +
    '<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Arabic:wght@400;500;600;700&family=Inter:wght@400;600;700;800&display=swap" rel="stylesheet">' +
    '<style>body,table,td,h1,p,a,span{font-family:' + font + ' !important;}</style></head>' +
    '<body bgcolor="' + bg + '" style="margin:0;padding:0;background:' + bg + ';' + pageBg + 'font-family:' + font + ';">' +
    '<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:' + bg + ';">' + (o.preheader || "") + '</div>' +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="' + bg + '" style="' + pageBg + 'padding:42px 14px;"><tr><td align="center">' +
    '<table role="presentation" width="600" cellpadding="0" cellspacing="0" bgcolor="' + card + '" style="max-width:600px;width:100%;background:' + card + ';border:1px solid ' + border + ';border-radius:18px;overflow:hidden;' + cardGlow + '">' +
    '<tr><td style="height:3px;background:linear-gradient(90deg,' + accent + ',' + accent2 + ');font-size:0;line-height:0;" bgcolor="' + accent + '">&nbsp;</td></tr>' +
    '<tr><td style="padding:30px 34px 10px;"><table role="presentation" cellpadding="0" cellspacing="0" dir="ltr"><tr>' +
      '<td style="width:48px;height:48px;border-radius:14px;background:' + accent + ';text-align:center;font-family:' + font + ';font-size:25px;font-weight:800;line-height:48px;color:' + onacc + ';" bgcolor="' + accent + '">F</td>' +
      '<td style="padding-left:13px;font-family:' + font + ';font-size:21px;font-weight:700;line-height:1;letter-spacing:.3px;color:' + ink + ';" dir="ltr">Firas<span style="color:' + accent + ';"> AI</span></td>' +
    '</tr></table></td></tr>' +
    '<tr><td dir="' + cdir + '" style="padding:18px 34px 6px;font-family:' + font + ';color:' + ink + ';text-align:' + calign + ';">' +
      '<h1 style="margin:0 0 10px;font-size:23px;font-weight:700;color:' + ink + ';line-height:1.5;">' + o.heading + '</h1>' +
      '<div style="width:40px;height:3px;border-radius:3px;background:' + accent + ';margin:0 0 18px;"></div>' +
      '<p style="margin:0 0 18px;font-size:15.5px;line-height:1.95;color:' + muted + ';">' + o.lead + '</p>' +
      o.contentHtml +
      (o.note ? '<p style="margin:24px 0 0;font-size:13px;line-height:1.8;color:' + soft + ';">' + o.note + '</p>' : '') +
    '</td></tr>' +
    '<tr><td dir="' + cdir + '" style="padding:18px 34px 2px;font-family:' + font + ';font-size:12px;color:' + soft + ';text-align:' + calign + ';">' + sentLabel + time + '</td></tr>' +
    '<tr><td style="padding:18px 34px 0;"><div style="border-top:1px solid ' + hair + ';"></div></td></tr>' +
    '<tr><td style="padding:18px 34px 30px;font-family:' + font + ';text-align:center;">' +
      '<p style="margin:0 0 5px;font-family:' + font + ';font-size:13px;font-weight:700;letter-spacing:2px;color:' + accent + ';" dir="ltr">FIRAS AI</p>' +
      '<p style="margin:0;font-size:12px;color:' + soft + ';" dir="' + cdir + '">' + tagline + '</p>' +
    '</td></tr></table>' +
    '<p style="margin:18px 0 0;font-family:' + font + ';font-size:11px;color:#6b695f;" dir="ltr">© Firas AI</p>' +
    '</td></tr></table></body></html>';
}
function verifyEmailHtml(link) {
  return brandedEmail({
    preheader: "أكمل إنشاء حسابك في Firas AI",
    heading: "تأكيد بريدك الإلكتروني",
    lead: "أهلاً بك في " + ltr("Firas AI") + " — اضغط الزر لتأكيد بريدك وتفعيل حسابك، وتدخل مباشرةً.",
    contentHtml: mailButton(link, "تأكيد الحساب وبدء الاستخدام") + mailLink(link),
    note: "الرابط صالح لمدة 15 دقيقة. إذا لم تطلب إنشاء حساب، تجاهل هذه الرسالة.",
  });
}
function sha256hex(s) { return crypto.createHash("sha256").update(String(s)).digest("hex"); }
function escEmail(s) { return String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }
// Personal welcome from the developer (Firas), sent once the account is verified & created.
function welcomeEmailHtml(name, link) {
  const safe = escEmail(String(name || "").trim());
  const first = safe ? safe.split(/\s+/)[0] : "";
  const p = (t) => '<p style="margin:0 0 15px;font-size:15.5px;line-height:2;color:#DBD8CF;">' + t + '</p>';
  const brand = '<b style="color:#6BC0AE;font-weight:700;">Firas AI</b>';
  const content =
    p("I'm Firas, founder and developer of " + brand + ". I wanted to personally reach out and thank you for signing up and joining our community. We're truly delighted to have you on board!") +
    p("We built " + brand + " with the goal of providing the best possible experience — to help you achieve your tasks intelligently and efficiently, and explore the world of AI.") +
    p("As a new member, you can immediately start exploring the features we've developed specifically for you. We are constantly working to improve and develop the platform.") +
    p("Once again, thank you for your trust in us. We hope you have a fantastic and productive experience!") +
    mailButton(link, "Start exploring Firas AI") +
    '<p style="margin:28px 0 0;font-size:14.5px;line-height:1.85;color:#C2BFB6;">Best regards,<br><b style="color:#F6F4ED;font-weight:700;">Firas</b><br>Founder &amp; Developer, Firas AI</p>';
  return brandedEmail({
    lang: "en",
    preheader: "Welcome to Firas AI — a note from Firas",
    heading: "Welcome to Firas AI 👋",
    lead: "Hi " + (first || "there") + ",",
    contentHtml: content,
  });
}
async function sendViaBrevo(to, subject, html, fromName) {
  try {
    const r = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Accept": "application/json", "api-key": BREVO_API_KEY },
      body: JSON.stringify({ sender: { name: fromName || BREVO_FROM_NAME, email: BREVO_FROM }, to: [{ email: to }], subject, htmlContent: html }),
    });
    if (!r.ok) { const e = await r.text().catch(() => ""); console.error("[firas] Brevo send failed " + r.status + " -> " + e.slice(0, 200)); return false; }
    return true;
  } catch (e) { console.error("[firas] Brevo send error: " + ((e && e.message) || e)); return false; }
}
async function sendViaResend(to, subject, html, fromName) {
  if (!RESEND_API_KEY) return false;
  const addr = (RESEND_FROM.match(/<([^>]+)>/) || [])[1] || "onboarding@resend.dev";
  const from = fromName ? (fromName + " <" + addr + ">") : RESEND_FROM;
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": "Bearer " + RESEND_API_KEY },
      body: JSON.stringify({ from, to: [to], subject, html }),
    });
    if (!r.ok) { const e = await r.text().catch(() => ""); console.error("[firas] Resend send failed " + r.status + " -> " + e.slice(0, 200)); return false; }
    return true;
  } catch (e) { console.error("[firas] Resend send error: " + ((e && e.message) || e)); return false; }
}
// Brevo first (free, reaches everyone via single-sender), then Resend as fallback.
// opts.fromName overrides the sender display name (e.g. "Firas" for the welcome email).
async function sendEmail(to, subject, html, opts) {
  const fromName = opts && opts.fromName;
  if (BREVO_API_KEY) { if (await sendViaBrevo(to, subject, html, fromName)) return true; }
  if (RESEND_API_KEY) { if (await sendViaResend(to, subject, html, fromName)) return true; }
  return false;
}
/* ACCOUNT-TAKEOVER FIX — never build an outbound link from a request header.
   This used to return `req.headers.origin` whenever APP_URL was unset, and APP_URL is set
   nowhere in this project. An attacker POSTs a password-reset for the victim's address with
   `Origin: https://attacker.example`; the server mails the VICTIM a genuine reset link whose
   host is the attacker's. The victim clicks a legitimate-looking email from the real service
   and hands over a valid reset token. Same path for email-verification links.

   Now: an explicit APP_URL wins; otherwise `Host` is accepted ONLY if it matches a known
   deployment hostname or is plainly local. `Origin` is ignored entirely — it is chosen by
   whoever sends the request and can never be evidence of where the app lives. */
const RESET_HOST_ALLOW = [
  /^localhost(:\d+)?$/i,
  /^127\.0\.0\.1(:\d+)?$/,
  /^\[::1\](:\d+)?$/,
  /^192\.168\.\d{1,3}\.\d{1,3}(:\d+)?$/,       // the owner's LAN, used for phone testing
  /^[a-z0-9-]+\.trycloudflare\.com$/i,
  /^[a-z0-9-]+\.netlify\.app$/i,
  /^[a-z0-9-]+\.fly\.dev$/i,
  /^[a-z0-9-]+\.onrender\.com$/i,
];
function resetAppBase(req) {
  if (RESET_APP_URL) return RESET_APP_URL;                 // explicit config always wins
  const host = String(req.headers.host || "");
  if (host && RESET_HOST_ALLOW.some((re) => re.test(host))) {
    const proto = /^(localhost|127\.|\[::1\]|192\.168\.)/.test(host) ? "http" : "https";
    return proto + "://" + host;
  }
  // Unrecognized host → refuse to guess. Set APP_URL for a new deployment domain.
  console.warn("[auth] refusing to build a reset link for an unknown Host:", host, "— set APP_URL");
  return "http://localhost:" + PORT;
}
function resetEmailHtml(link) {
  return brandedEmail({
    preheader: "رابط إعادة تعيين كلمة المرور — Firas AI",
    heading: "إعادة تعيين كلمة المرور",
    lead: "طلبت إعادة تعيين كلمة مرورك. اضغط الزر للمتابعة:",
    contentHtml: mailButton(link, "تعيين كلمة مرور جديدة") + mailLink(link),
    note: "الرابط صالح لمدة 30 دقيقة. إذا لم تطلب هذا، تجاهل الرسالة وكلمة مرورك تبقى كما هي.",
  });
}
async function handleForgot(req, res) {
  if (rateLimited("forgot:" + (clientIp(req) || "?"), 6, 60_000)) return sendJson(res, 429, { error: "too many requests" });
  const body = await readJson(req, 100_000);
  const email = String((body && body.email) || "").trim().toLowerCase();
  if (EMAIL_RE.test(email)) {
    const user = DB.users.find((u) => u.email === email && u.passHash); // password accounts only
    if (user) {
      const token = crypto.randomBytes(32).toString("hex");
      user.reset = { hash: sha256hex(token), exp: Date.now() + RESET_TTL_MS };
      await persist();
      const link = resetAppBase(req) + "/?reset=" + token + "&uid=" + encodeURIComponent(user.id);
      const sent = await sendEmail(user.email, "إعادة تعيين كلمة المرور — Firas AI", resetEmailHtml(link));
      if (!sent) console.log("[firas] password-reset (not delivered — dev fallback) for " + user.email + " -> " + link);
    }
  }
  return sendJson(res, 200, { ok: true }); // anti-enumeration: ALWAYS ok
}
async function handleReset(req, res) {
  if (rateLimited("reset:" + (clientIp(req) || "?"), 10, 60_000)) return sendJson(res, 429, { error: "too many requests" });
  const body = await readJson(req, 100_000);
  const uid = String((body && body.uid) || "");
  const token = String((body && body.token) || "");
  const password = String((body && body.password) || "");
  if (password.length < 8) return sendJson(res, 400, { error: "password must be at least 8 characters" });
  if (password.length > 200) return sendJson(res, 400, { error: "password is too long" });
  const user = DB.users.find((u) => u.id === uid);
  if (!user || !user.reset || !user.reset.hash || Date.now() > user.reset.exp || sha256hex(token) !== user.reset.hash) {
    return sendJson(res, 400, { error: "invalid or expired link" });
  }
  const { salt, passHash } = await hashPassword(password);
  user.salt = salt; user.passHash = passHash;
  delete user.reset;
  /* A reset exists to lock out whoever had access. Re-issuing the same cookie value made
     it decorative: the attacker's stolen copy kept working. Bump first, THEN set the
     cookie below, so this browser gets the new version and every other copy dies. */
  bumpSessionVersion(user);
  await persist();
  setSessionCookie(res, user.id, req); // sign them in after a successful reset
  return sendJson(res, 200, { ok: true, user: publicUser(user) });
}

/* ---- Account management (require an authenticated session) ---- */
async function handleChangePassword(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "not authenticated" });
  if (rateLimited("acct:" + user.id, 10, 60_000)) return sendJson(res, 429, { error: "too many requests" });
  const body = await readJson(req, 100_000);
  const current = String((body && body.current) || "");
  const next = String((body && body.password) || "");
  if (!user.passHash) return sendJson(res, 400, { error: "هذا الحساب يسجّل عبر Google ولا يملك كلمة مرور" });
  if (next.length < 8) return sendJson(res, 400, { error: "كلمة المرور يجب أن تكون 8 أحرف على الأقل" });
  if (next.length > 200) return sendJson(res, 400, { error: "كلمة المرور طويلة جداً" });
  if (!(await verifyPassword(current, user.salt, user.passHash))) return sendJson(res, 403, { error: "كلمة المرور الحالية غير صحيحة" });
  const { salt, passHash } = await hashPassword(next);
  user.salt = salt; user.passHash = passHash;
  // Same reasoning as the reset path: a password change that leaves old sessions alive
  // does not actually revoke anything.
  bumpSessionVersion(user);
  await persist();
  setSessionCookie(res, user.id, req);   // keep THIS browser signed in
  return sendJson(res, 200, { ok: true });
}
async function handleChangeEmail(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "not authenticated" });
  if (rateLimited("acct:" + user.id, 10, 60_000)) return sendJson(res, 429, { error: "too many requests" });
  const body = await readJson(req, 100_000);
  const current = String((body && body.current) || "");
  const email = String((body && body.email) || "").trim().toLowerCase();
  if (!user.passHash) return sendJson(res, 400, { error: "هذا الحساب يسجّل عبر Google" });
  if (!EMAIL_RE.test(email) || email.length > 200) return sendJson(res, 400, { error: "أدخل بريداً صالحاً" });
  if (!(await verifyPassword(current, user.salt, user.passHash))) return sendJson(res, 403, { error: "كلمة المرور غير صحيحة" });
  if (email === user.email) return sendJson(res, 400, { error: "هذا هو بريدك الحالي" });
  if (DB.users.some((u) => u.email === email)) return sendJson(res, 409, { error: "هذا البريد مستخدم بالفعل" });
  user.email = email;
  /* ── ACCOUNT-TAKEOVER FIX ────────────────────────────────────────────────────────────
     This endpoint proves the CALLER's password and that the address is unused. It does not
     — and cannot — prove the caller owns the new address. handleFirebaseAuth then links a
     Google sign-in into whatever account already holds that email, on the stated assumption
     that "an email present in the DB is owned by that person". This endpoint is exactly what
     breaks that assumption, and the chain is short:

       1. attacker signs up as attacker@x.com and verifies it
       2. attacker POSTs {current:"<own password>", email:"victim@gmail.com"}
       3. victim later taps "Continue with Google"
       4. the lookup finds the ATTACKER's record, the token is verified, a session is issued
          — the victim is now inside an account whose password the attacker knows, and every
          chat, Brain document and memory they create is readable by simply logging in.

     `emailUnverified` marks an address this server has never seen proven. handleFirebaseAuth
     refuses to auto-link into such an account, which severs step 4. The flag is absent on
     every existing record, so nothing about current sign-ins changes.

     NOT reusing `emailVerified` for this: it is set only by the signup-verification path,
     so Google-created accounts do not carry it, and gating on it would lock those users out. */
  user.emailUnverified = true;
  delete user.emailVerified;
  await persist();
  return sendJson(res, 200, { ok: true, user: publicUser(user) });
}
async function handleDeleteAccount(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "not authenticated" });
  if (rateLimited("acct:" + user.id, 10, 60_000)) return sendJson(res, 429, { error: "too many requests" });
  const body = await readJson(req, 100_000);
  const current = String((body && body.current) || "");
  if (user.passHash && !(await verifyPassword(current, user.salt, user.passHash))) {
    return sendJson(res, 403, { error: "كلمة المرور غير صحيحة" });
  }
  DB.chats = (DB.chats || []).filter((c) => c.userId !== user.id);
  DB.users = DB.users.filter((u) => u.id !== user.id);
  await brainRemoveUser(user.id);   // documents live outside DB, so persist() cannot clear them
  await persist();
  clearSessionCookie(res, req);
  return sendJson(res, 200, { ok: true });
}

// POST /api/auth/firebase — verify a Google/Firebase ID token and log in,
// issuing the SAME signed session cookie as email/password login.
async function handleFirebaseAuth(req, res) {
  // Same per-IP throttle as the other auth endpoints.
  if (rateLimited("auth:" + clientIp(req), 12, 60_000)) {
    return sendJson(res, 429, { error: "too many attempts, please wait a minute" });
  }
  // Social sign-in must be explicitly configured.
  if (!FIREBASE_PROJECT_ID) {
    return sendJson(res, 501, { error: "social sign-in not configured" });
  }

  const body = await readJson(req, 100_000);
  if (!body) return sendJson(res, 400, { error: "invalid JSON body" });

  const idToken = typeof body.idToken === "string" ? body.idToken : "";
  // Verify never throws/hangs; any failure -> generic 401.
  let payload = null;
  try {
    payload = await verifyFirebaseIdToken(idToken);
  } catch {
    payload = null;
  }
  if (!payload) return sendJson(res, 401, { error: "invalid token" });

  const email = String(payload.email).trim().toLowerCase();
  const name =
    (typeof payload.name === "string" && payload.name.trim() && payload.name.trim().slice(0, 80)) ||
    (typeof body.name === "string" && body.name.trim() && body.name.trim().slice(0, 80)) ||
    email.split("@")[0];

  // Link to an existing account by email, or create a Firebase-backed one.
  const verified = payload.email_verified === true;
  let user = DB.users.find((u) => u.email === email);
  if (user) {
    // ACCOUNT-TAKEOVER GUARD: Firebase email/password tokens carry
    // email_verified=false, so anyone could mint a token for a victim's email
    // (including the admin's) using the PUBLIC web apiKey. Only a VERIFIED token
    // (e.g. Google sign-in) may auto-link into an EXISTING account — this now
    // protects BOTH local password accounts AND existing social/admin accounts.
    if (!verified) {
      return sendJson(res, 409, {
        error: "An account with this email already exists. Please sign in with your password, or verify your email first.",
      });
    }
    /* …and a VERIFIED token is still not enough on its own. The guard above assumes the
       account holding this email legitimately owns it — /api/auth/change-email lets any
       user claim any unused address without proving anything, so that assumption fails for
       exactly those records. Refusing to auto-link into an unproven address is what stops a
       squatted email from handing the real owner's session to the squatter.
       Absent on every existing record, so ordinary Google sign-in is unaffected. */
    if (user.emailUnverified) {
      return sendJson(res, 409, {
        error: "An account with this email already exists but the address was never confirmed. Please sign in with your password.",
      });
    }
  } else {
    // Never let an UNVERIFIED token CREATE an admin-privileged account.
    if (!verified && isAdmin({ email })) {
      return sendJson(res, 403, { error: "email verification required for this account" });
    }
    user = {
      id: crypto.randomUUID(),
      name,
      email,
      provider: "firebase", // social/Firebase account; NO passHash / salt fields
      createdAt: new Date().toISOString(),
    };
    DB.users.push(user);
    await persist();
  }

  setSessionCookie(res, user.id, req);
  return sendJson(res, 200, { user: publicUser(user) });
}

/* ===========================================================================
   CHAT HISTORY ENDPOINTS (per user)
   =========================================================================== */
function userChats(userId) {
  return DB.chats.filter((c) => c.userId === userId);
}

// Validate/cap messages stored in the DB so a client can't bloat db.json or
// inject odd shapes. Keeps only known fields, bounds counts and lengths.
const MAX_MESSAGES = 2000;     // match the edge cap (a heavy Agent chat can exceed 1000 messages)
const MAX_CONTENT = 200_000;   // match the edge cap so Agent projects/runs aren't truncated on the local server
const MAX_CHATS_PER_USER = 1000;
function sanitizeMessages(arr) {
  if (!Array.isArray(arr)) return [];
  return arr.slice(0, MAX_MESSAGES).map((m) => {
    const o = {
      role: m && typeof m.role === "string" ? m.role.slice(0, 20) : "user",
      content: m && typeof m.content === "string" ? m.content.slice(0, MAX_CONTENT) : "",
    };
    if (m && typeof m.tier === "string") o.tier = m.tier.slice(0, 20);
    if (m && typeof m.lang === "string") o.lang = m.lang.slice(0, 5);
    if (m && typeof m.mode === "string") o.mode = m.mode.slice(0, 20);   // plan-mode UI depends on it after reload (edge keeps it too)
    if (m && typeof m.reasoning === "string") o.reasoning = m.reasoning.slice(0, MAX_CONTENT);
    // Keep small image thumbnails so attached images still show after reload
    // (bounded: up to 6 thumbs, each capped — full images are never persisted).
    if (m && Array.isArray(m.imageThumbs) && m.imageThumbs.length) {
      o.imageThumbs = m.imageThumbs
        .slice(0, 6)
        .filter((t) => typeof t === "string" && t.length <= 300_000);
    }
    return o;
  });
}

async function handleListChats(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "not authenticated" });
  const list = userChats(user.id)
    .slice()
    .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)))
    .map((c) => ({ id: c.id, title: c.title, updatedAt: c.updatedAt, pinned: !!c.pinned, agent: !!c.agent, codeProj: !!c.codeProj, brainNb: !!c.brainNb }));
  return sendJson(res, 200, list);
}

async function handleGetChat(req, res, id) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "not authenticated" });
  const chat = DB.chats.find((c) => c.id === id && c.userId === user.id);
  if (!chat) return sendJson(res, 404, { error: "not found" });
  return sendJson(res, 200, { id: chat.id, title: chat.title, messages: chat.messages || [] });
}

async function handleCreateChat(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "not authenticated" });
  const body = await readJson(req, 2_000_000);
  if (!body) return sendJson(res, 400, { error: "invalid JSON body" });

  if (userChats(user.id).length >= MAX_CHATS_PER_USER) {
    return sendJson(res, 409, { error: "chat limit reached; delete some conversations" });
  }

  const now = new Date().toISOString();
  const chat = {
    id: crypto.randomUUID(),
    userId: user.id,
    title: String(body.title ?? "New chat").slice(0, 200) || "New chat",
    messages: sanitizeMessages(body.messages),
    pinned: !!body.pinned,
    agent: !!body.agent,       // Firas Agent chats live in their OWN sidebar list
    codeProj: !!body.codeProj, // Firas Code workspace projects — their own list too
    brainNb: !!body.brainNb,   // Firas Brain notebooks — likewise. Set ONLY here: handleUpdateChat
                               // never writes product flags, so a chat POSTed without its flag can
                               // never acquire one later and would leak into the Firas AI list.
    createdAt: now,
    updatedAt: now,
  };
  DB.chats.push(chat);
  await persist();
  return sendJson(res, 201, {
    id: chat.id,
    title: chat.title,
    createdAt: chat.createdAt,
    updatedAt: chat.updatedAt,
  });
}

async function handleUpdateChat(req, res, id) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "not authenticated" });
  const body = await readJson(req, 2_000_000);
  if (!body) return sendJson(res, 400, { error: "invalid JSON body" });

  const chat = DB.chats.find((c) => c.id === id && c.userId === user.id);
  if (!chat) return sendJson(res, 404, { error: "not found" });

  let touched = false;
  if (typeof body.title === "string") { chat.title = body.title.slice(0, 200); touched = true; }
  if (Array.isArray(body.messages)) { chat.messages = sanitizeMessages(body.messages); touched = true; }
  if (typeof body.pinned === "boolean") chat.pinned = body.pinned; // pin toggle alone must NOT bump updatedAt (would reorder)
  if (touched) chat.updatedAt = new Date().toISOString();
  await persist();
  return sendJson(res, 200, { ok: true });
}

async function handleDeleteChat(req, res, id) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "not authenticated" });
  const idx = DB.chats.findIndex((c) => c.id === id && c.userId === user.id);
  if (idx === -1) return sendJson(res, 404, { error: "not found" });
  DB.chats.splice(idx, 1);
  await persist();
  return sendJson(res, 200, { ok: true });
}

/* ===========================================================================
   AI STREAM — POST /api/chat (auth required)
   Ollama native NDJSON -> frontend SSE transform, with pollinations fallback.
   =========================================================================== */
function sseInit(res) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });
}

// ---- BACKTRACK SCRUBBER — SHARED w/ netlify/edge-functions/api.js & app.js — keep BYTE-IDENTICAL ----
// Removes visible self-correction ('wait, that's wrong, let me redo…', Arabic 'مهلا/دعني أعيد…') from
// streamed CONTENT so science answers read clean-from-the-first-line. Anchored + correction-gated so
// legit prose ('average wait times', 'correction:', 'Step 1:', '3:30', 'اللحظة') is never touched, and
// byte-identical on any text with no cue. Only runs on the plain-chat product (gated by res._scrubBt);
// never on code/agent streams (nomem) or reasoning. Verified: 37/37 fixtures incl. random chunkings.
const _BT_EN = "(?:no,?\\s*)?wait,\\s+(?:that'?s|this is|it'?s|i|no|the)\\b|that'?s (?:wrong|not right|incorrect)|let me (?:redo|re-?do|reconsider|recompute|recalculate|start over|try again|fix that)|i made (?:an?|a) (?:error|mistake)|scratch that|on second thought|my mistake|ignore (?:that|the above)|hold on,\\s+(?:that|this|no|i)\\b|actually,?\\s+(?:that'?s|this is|no)\\b|oops|whoops";
const _BT_AR = "(?:انتظر|مهلا|مهلًا|لحظة|عذرا|عذرًا|عفوا|عفوًا)s*[،,]|هناك خطأ|هذا خطأ|هذا غير صحيح|في الواقع هذا خطأ|دعني (?:أعيد|اعيد|أصحح|اصحح|أعدّل)|أعيد الحساب|اعيد الحساب|خطأ مني";
const BACKTRACK_RE = new RegExp("(?:(?:^|[\\s.!?…])(?:" + _BT_EN + "))|(?:(?:^|[\\s.!?…،؛])(?:" + _BT_AR + ")(?=$|[\\s.!?…،؛]))", "i");
/* How many characters of the NEXT sentence must arrive before the PREVIOUS one is released.
   The longest cue in either language is well under 40 characters ("no, wait, that's wrong",
   "هناك خطأ في الحساب"), so 56 leaves generous headroom while capping how far behind the
   reader can ever be. Raising it makes streaming laggier; lowering it below the longest cue
   would let a real self-correction slip through. */
const BT_WINDOW = 56;
function makeBacktrackScrubber() {
  let pending = "", cur = "", cleared = false;
  const isEnd = (c) => c === "." || c === "!" || c === "?" || c === "؟" || c === "\n";
  const isWs = (c) => c === undefined || c === " " || c === "\t" || c === "\n" || c === "\r";
  function recover(s) {
    const m = BACKTRACK_RE.exec(s);
    if (!m) return "";
    let tail = s.slice(m.index + m[0].length);
    const cm = /[,،]\s*/.exec(tail);
    if (!cm) return "";
    tail = tail.slice(cm.index + cm[0].length).trim();
    return (tail && !BACKTRACK_RE.test(tail)) ? tail : "";
  }
  return {
    push(tok) {
      if (!tok) return "";
      let out = "";
      for (let i = 0; i < tok.length; i++) {
        const ch = tok[i]; cur += ch;
        /* EARLY RELEASE — this is what makes streaming feel like typing.

           A backtrack cue only ever appears at the START of a sentence, and what it retracts
           is the sentence BEFORE it. The sentence currently being written is never itself
           retracted. So once enough of it has arrived to rule out a cue in its opening, two
           things become safe at once: the held previous sentence can go out, and every
           further character of this sentence can go out the moment it arrives.

           Without this the buffer held the entire current sentence no matter how long it ran —
           measured at 213 characters of a 214-character sentence, i.e. the reader saw nothing
           until the full stop. That is exactly the "arrives in one jump" the owner described.

           `cleared` is per-sentence and resets at each boundary, so every new sentence is
           re-checked from scratch. */
        if (!cleared && cur.length >= BT_WINDOW && !BACKTRACK_RE.test(cur)) {
          cleared = true;
          out += pending; pending = "";   // nothing can retract it now
          out += cur; cur = "";           // and this sentence can stream from here on
          continue;
        }
        if (cleared) { out += ch; cur = ""; if (isEnd(ch) && isWs(tok[i + 1])) cleared = false; continue; }
        if (isEnd(ch) && isWs(tok[i + 1])) {
          const s = cur; cur = "";
          /* DATA LOSS FIX. This used to be `else { pending = ""; }` — when a cue matched but
             recover() could not confidently extract the corrected text, it DELETED the
             previous sentence and kept nothing in its place.

             That fires on ordinary prose. `لحظة` ("moment") is in the Arabic cue list, so a
             sentence like "لحظة الغليان مهمة هنا." matched, recover() found no comma to split
             on, returned "", and the sentence BEFORE it vanished from the answer. Measured:
             a clean 78-character Arabic paragraph came out at 37 characters. A chained
             correction ("مهلًا، هذا خطأ، …") recursed into itself and returned the empty
             string, deleting the whole answer.

             Now an unrecoverable match is treated as ordinary text. The worst case becomes a
             visible "wait, that's wrong" that should have been trimmed — mildly untidy.
             The old worst case was silently deleting a correct sentence from a student's
             answer, which is not a trade this product can make. */
          if (BACKTRACK_RE.test(s)) {
            const rec = recover(s);
            if (rec) { out += pending; pending = rec; }
            else { out += pending; pending = s; }   // not confident → keep it, never drop it
            continue;
          }
          out += pending; pending = s;
        }
      }
      return out;
    },
    /* Same correction as push(): an unrecoverable match must NOT return "". flush() emits the
       LAST thing the reader ever sees, so `rec || ""` silently truncated the end of an answer
       whenever the closing sentence happened to contain a cue word like "لحظة". Falling back
       to `rest` keeps the text; the worst case is an untrimmed self-correction, never a
       missing conclusion. */
    flush() { let rest = pending + cur; pending = ""; cur = ""; if (BACKTRACK_RE.test(rest)) { const rec = recover(rest); return rec || rest; } return rest; },
    reset() { pending = ""; cur = ""; cleared = false; },
  };
}

function sseWrite(res, content, reasoning) {
  if (res.writableEnded) return;
  // Scrub only plain-chat content (never reasoning, never code/agent streams — gated by res._scrubBt).
  if (content && res._scrubBt) { if (!res._bt) res._bt = makeBacktrackScrubber(); content = res._bt.push(content); }
  const delta = {};
  if (content) delta.content = content;
  if (reasoning) delta.reasoning = reasoning;
  if (!("content" in delta) && !("reasoning" in delta)) return;
  res.write(`data: ${JSON.stringify({ choices: [{ delta }] })}\n\n`);
  // Progress is the proof the upstream is alive — push the idle deadline out (see UPSTREAM_IDLE_MS).
  if (res._keepAlive) res._keepAlive();
}

function sseDone(res) {
  if (res.writableEnded) return;
  if (res._bt) { const tail = res._bt.flush(); if (tail) res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: tail } }] })}\n\n`); }
  res.write("data: [DONE]\n\n");
  res.end();
}

// Call Ollama native /api/chat, transform NDJSON -> SSE. `think` toggles
// reasoning; when false we additionally DROP any thinking tokens so the toggle
// reliably hides thinking even for models that always reason.
// Returns true on success, false if Ollama was unreachable (-> caller falls back).
/* Models that answered 400 to a thinking request. Learned at runtime, so the cost of finding out
   is paid once per model per process rather than on every turn Thinking is switched on. */
const _noThink = new Set();

async function streamOllama(res, messages, tier, think, signal, modelOverride) {
  const t = TIERS[tier];
  const model = modelOverride || t.model;
  // Stronger thinking: gpt-oss accepts a reasoning LEVEL — use "high" when the
  // user has thinking on. Other models just take a boolean.
  /* THINKING IS A PER-MODEL CAPABILITY, AND ASKING A MODEL THAT LACKS IT COSTS THE WHOLE CALL.
     Ollama answers 400 for `think` on a model that does not support it. 400 is not one of the
     quota codes handled below, so every attempt resent the identical rejected body, all of them
     failed, and the tier fell through to the rescue chain. The visible symptom was the reported
     one — the Thinking panel never appears — but the real cost was worse: switching Thinking ON
     silently DEMOTED the answer to a weaker engine. A rejection now drops thinking and retries
     the same model at once, and the model is remembered so the next turn does not re-buy it. */
  let wantThink = think && !_noThink.has(model);
  const buildBody = () => JSON.stringify({
    model,
    messages,
    stream: true,
    // gpt-oss accepts a reasoning LEVEL rather than a boolean; others just take true.
    think: wantThink ? (/gpt-oss/i.test(model) ? "high" : true) : false,
    options: { temperature: t.temperature, num_predict: t.num_predict },
  });
  let body = buildBody();

  // Retry transient failures with REAL backoff before any bytes are streamed — a brief
  // 429/503 on the hosted pool clears within a second or two. A QUOTA hit (429/402/403 on a
  // hosted key) marks that key limited and jumps IMMEDIATELY to the next key in the pool.
  /* A controller OF OUR OWN, chained to the caller's. The caller's signal covers the whole
     request and is what the rescue chain runs on, so this attempt must never abort it — it
     aborts only itself, and returns false so the chain takes over with a live signal. */
  const ac = new AbortController();
  if (signal) {
    if (signal.aborted) return true;                       // client already gone
    signal.addEventListener("abort", () => { try { ac.abort("caller"); } catch (_) {} }, { once: true });
  }
  let firstByte = false, starved = false;
  let fbTimer = setTimeout(() => {
    if (firstByte) return;
    starved = true;
    modelMarkDead(model);
    console.warn("[firas] ollama model " + model + " sent nothing in " +
      Math.round(OLLAMA_FIRST_BYTE_MS / 1000) + "s - abandoning it for the rescue chain");
    try { ac.abort("first-byte"); } catch (_) {}
  }, OLLAMA_FIRST_BYTE_MS);
  const settle = () => { clearTimeout(fbTimer); };

  let upstream = null;
  let lastErr = null;
  let was429 = false;
  const OLLAMA_BACKOFF = [400, 900];
  const OLLAMA_BACKOFF_429 = [1200, 2500];   // FAST-FAIL: abandon a saturated pool in ~2.5s so a fast provider answers
  const attemptsMax = Math.max(2, OLLAMA_KEYS.length + 1);
  for (let attempt = 0; attempt < attemptsMax; attempt++) {
    const olKey = ollamaPickKey();
    try {
      upstream = await fetch(OLLAMA_CHAT_URL, {
        method: "POST",
        headers: ollamaHeaders(olKey),
        body,
        signal: ac.signal,
      });
      if (upstream.ok && upstream.body) break;
      const st = upstream.status;
      was429 = (st === 429);   // reset each attempt so a 429→503 sequence doesn't over-wait
      lastErr = new Error("ollama " + st);
      upstream = null;
      if (wantThink && (st === 400 || st === 422)) {
        /* Not a quota problem and not a dead model — this model simply cannot think out loud.
           Retry it immediately, unthinking, rather than losing the tier to a fallback engine. */
        _noThink.add(model);
        wantThink = false;
        body = buildBody();
        attempt--;
        continue;
      }
      if (olKey && (st === 429 || st === 402 || st === 403)) {
        ollamaMarkLimited(olKey, st);
        // a FRESH key is available → rotate to it immediately, no backoff wasted
        if (OLLAMA_KEYS.some((k) => k !== olKey && Date.now() >= (_olCooldown.get(k) || 0))) continue;
        // NO healthy key left → bail out NOW (no pointless backoff+retry on dead keys) so the
        // caller's rescue chain (Gemini → Cloudflare → OpenRouter → pollinations) answers fast.
        break;
      }
      // a non-OK HTTP status from Ollama itself is not a "connect" failure;
      // retry then give up — the caller decides the fallback.
    } catch (e) {
      // Starved on the first byte -> NOT handled: return false so the rescue chain answers.
      if (starved) { settle(); return false; }
      if (signal && signal.aborted) { settle(); return true; }   // client gone; nothing to do
      lastErr = e;
      upstream = null;
    }
    if (attempt < attemptsMax - 1) await new Promise((r) => setTimeout(r, (was429 ? OLLAMA_BACKOFF_429 : OLLAMA_BACKOFF)[Math.min(attempt, 1)]));
  }

  if (!upstream) {
    // Could not reach Ollama at all -> let caller fall back.
    settle();
    console.error("[firas] ollama unreachable:", (lastErr && lastErr.message) || lastErr);
    return false;
  }

  // Transform NDJSON stream line-by-line (buffer across chunks).
  const decoder = new TextDecoder();
  let buffer = "";
  try {
    for await (const chunk of upstream.body) {
      if (res.writableEnded) break;
      buffer += decoder.decode(chunk, { stream: true });
      let nl;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line) continue;
        let obj;
        try {
          obj = JSON.parse(line);
        } catch {
          continue;
        }
        const msg = obj.message || {};
        const content = msg.content || "";
        // Drop thinking entirely when think is off.
        const reasoning = think ? msg.thinking || "" : "";
        if (content || reasoning) {
          if (!firstByte) { firstByte = true; clearTimeout(fbTimer); }   // it spoke: the generous silence clock takes over
          sseWrite(res, content, reasoning);
        }
        if (obj.done) {
          settle();
          sseDone(res);
          return true;
        }
      }
    }
    // flush any trailing buffered line
    const tail = buffer.trim();
    if (tail) {
      try {
        const obj = JSON.parse(tail);
        const msg = obj.message || {};
        const reasoning = think ? msg.thinking || "" : "";
        if (msg.content || reasoning) sseWrite(res, msg.content || "", reasoning);
      } catch { /* ignore */ }
    }
    settle();
    sseDone(res);
    return true;
  } catch (e) {
    settle();
    // Nothing was ever written, so falling back is still clean.
    if (starved || (!firstByte && !(signal && signal.aborted))) return false;
    if (signal && signal.aborted) return true;
    // Stream broke mid-flight — we've already sent headers, so we can't cleanly
    // fall back; close out gracefully.
    console.error("[firas] ollama stream error:", (e && e.message) || e);
    sseDone(res);
    return true;
  }
}

// Fallback: free keyless pollinations (OpenAI-style SSE we can re-emit).
// The free fallback engine appends an ad / reveals its own brand. Strip it so
// the underlying engine is NEVER exposed to the user (only "Firas AI" shows).
function stripEngineAd(text) {
  if (!text) return text;
  let t = text;
  const cut = t.search(/\n*\s*(?:[-—*_]{2,}\s*)?\**\s*(?:support\s+|powered\s+by\s+)*pollinations|support our mission|🌸|free text api/i);
  if (cut !== -1) t = t.slice(0, cut);
  t = t.replace(/^.*pollinations.*$/gim, "");          // drop any stray brand line
  t = t.replace(/^\s*\**\s*ad\s*\**\s*$/gim, "");       // drop a lone "Ad" marker line
  return t.replace(/\s+$/, "");
}

// One-shot, non-streaming translation (keyless pollinations OpenAI-compat). Used for the
// AR/EN toggle on announcements. Falls back to the original text on any failure.
const TRANSLATE_TIMEOUT_MS = 22_000;
// Gemini first (reliable + fast), then keyless pollinations. Each call has a hard timeout so the
// UI never hangs on a stalled engine. Returns "" on total failure (caller falls back to original).
async function translateFetch(messages) {
  const tryOne = async (url, body, headers) => {
    const ac = new AbortController();
    const to = setTimeout(() => ac.abort(), TRANSLATE_TIMEOUT_MS);
    try {
      const r = await fetch(url, { method: "POST", headers, body: JSON.stringify(body), signal: ac.signal });
      if (!r.ok) return "";
      const j = await r.json();
      return stripEngineAd(String((j && j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content) || ""));
    } catch (_) { return ""; } finally { clearTimeout(to); }
  };
  if (GEMINI_API_KEY) {
    const g = await tryOne(GEMINI_OAI_URL, { model: GEMINI_TEXT_MODELS[0] || "gemini-2.5-flash", messages, temperature: 0.2 },
      { "Content-Type": "application/json", "Authorization": "Bearer " + (geminiPickKey() || GEMINI_API_KEY) });
    if (g) return g;
  }
  return await tryOne(FALLBACK_URL, { model: "openai-fast", messages, stream: false, temperature: 0.2 }, { "Content-Type": "application/json" });
}
async function translateText(text, toLangName) {
  const sys = "You are a professional translator. Translate the user's text into " + toLangName +
    ". Output ONLY the translation — preserve line breaks, formatting and emoji, keep brand/product names as-is. No notes, no quotes.";
  return (await translateFetch([{ role: "system", content: sys }, { role: "user", content: text }])).trim();
}
// Translate a title + body together in ONE upstream call (avoids concurrent-call failures and
// is faster), parsing them back out via sentinel markers.
async function translatePair(title, bodyText, toLangName) {
  const sys = "You are a professional translator. Translate the update below into " + toLangName +
    ". Keep brand/product names as-is, preserve line breaks and emoji. Respond in EXACTLY this format and nothing else:\n<<<TITLE>>>\n{translated title}\n<<<BODY>>>\n{translated body}";
  const usr = "<<<TITLE>>>\n" + (title || "") + "\n<<<BODY>>>\n" + (bodyText || "");
  const out = await translateFetch([{ role: "system", content: sys }, { role: "user", content: usr }]);
  const tm = out.indexOf("<<<TITLE>>>"), bm = out.indexOf("<<<BODY>>>");
  if (tm !== -1 && bm !== -1 && bm > tm) return { title: out.slice(tm + 11, bm).trim(), body: out.slice(bm + 10).trim() };
  return { title, body: out.trim() || bodyText };
}
async function handleTranslate(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "not authenticated" });
  if (rateLimited("translate:" + user.id, 40, 60_000)) return sendJson(res, 429, { error: "too many requests" });
  const body = await readJson(req, 200_000);
  const to = String((body && body.to) || "").toLowerCase() === "en" ? "English" : "Arabic";
  if (body && (typeof body.title === "string" || typeof body.body === "string")) {
    const title = String(body.title || "").slice(0, 400);
    const btext = String(body.body || "").slice(0, 8000);
    if (!title.trim() && !btext.trim()) return sendJson(res, 200, { title: "", body: "" });
    try { return sendJson(res, 200, await translatePair(title, btext, to)); }
    catch (_) { return sendJson(res, 200, { title, body: btext }); }
  }
  const text = String((body && body.text) || "").slice(0, 8000);
  if (!text.trim()) return sendJson(res, 200, { text: "" });
  try { const out = await translateText(text, to); return sendJson(res, 200, { text: out || text }); }
  catch (_) { return sendJson(res, 200, { text }); }
}

/* ---------------------------------------------------------------------------
   Web search — keyless, server-side DuckDuckGo proxy. Returns up to 6 results
   as { title, url, snippet }. Done server-side to dodge browser CORS/Turnstile.
--------------------------------------------------------------------------- */
const SEARCH_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
function decodeEntities(s) {
  return String(s).replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#x27;|&#39;/g, "'")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&nbsp;/g, " ");
}
function stripTags(s) { return decodeEntities(String(s).replace(/<[^>]+>/g, "")).replace(/\s+/g, " ").trim(); }
function decodeDdgUrl(href) {
  try {
    const m = href.match(/[?&]uddg=([^&]+)/);
    if (m) return decodeURIComponent(m[1]);
    return href.startsWith("//") ? "https:" + href : href;
  } catch { return href; }
}
function parseDuckDuckGo(html) {
  const out = [];
  // Parse each result CONTAINER as a unit and pull its title/url + snippet from
  // WITHIN that block, so a missing/extra snippet can never shift snippets onto
  // the wrong title (the old parallel-index zip had that bug).
  const titleRe = /<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = titleRe.exec(html)) && out.length < 8) {
    const url = decodeDdgUrl(m[1]);
    const title = stripTags(m[2]);
    if (!title || !/^https?:\/\//i.test(url)) continue;
    // Look for a snippet in the slice that follows this title, but stop before
    // the next result's title so we never borrow a later block's snippet.
    const after = html.slice(titleRe.lastIndex, titleRe.lastIndex + 1500);
    const nextTitle = after.search(/<a[^>]+class="[^"]*result__a/i);
    const window = nextTitle >= 0 ? after.slice(0, nextTitle) : after;
    const sm = window.match(/<a[^>]+class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)<\/a>/i);
    out.push({ title, url, snippet: sm ? stripTags(sm[1]) : "" });
  }
  return out;
}
/* Image generation — keyless, server-side pollinations proxy (avoids browser
   CORS/Turnstile). Returns the generated image bytes. */
// Per-user daily image-creation cap. Configurable via env; defaults to 5/day.
/* -1 = UNMETERED, and that is now the default: Firas asked for no daily usage anywhere.
   Kept as a real setting rather than deleted, because this is the ONE counter standing between
   a single runaway client and the shared upstream image pools (which have their own hard daily
   caps that cannot be raised from here). Set the env var to a positive number to bring a
/* Per-user daily image cap. DEFAULT 5 — Firas asked for a real ceiling again after a spell of
   -1 (unmetered). This is the one counter standing between a single runaway client and the shared
   upstream image pools, which have their own hard daily caps that cannot be raised from here.
   The env var still wins, and -1 there still means unmetered, so the ceiling moves without a
   code change. */
const IMAGE_DAILY_LIMIT = (() => { const n = parseInt(process.env.IMAGE_DAILY_LIMIT, 10); return Number.isFinite(n) ? n : 5; })();

/* The quota day is the USERS' calendar day, not the host's. This used the machine's
   local time while the edge used UTC, so the same build reset counters at a different
   wall-clock instant depending on where it ran — in production (UTC) that was 03:00 in
   Baghdad, three hours after the app's own 429 notice promises "يتجدّد تلقائيًا بعد
   منتصف الليل". Both backends now shift the instant by QUOTA_TZ_OFFSET_MINUTES
   (default 180 = UTC+3, the Arabic user base) and read UTC fields off the shifted value.
   Must stay byte-for-byte equivalent to serverDay() in netlify/edge-functions/api.js. */
const QUOTA_TZ_OFFSET_MINUTES = (() => { const n = parseInt(process.env.QUOTA_TZ_OFFSET_MINUTES, 10); return Number.isFinite(n) ? n : 180; })();
function serverDay(d) {
  const ms = (d instanceof Date ? d.getTime() : (typeof d === "number" ? d : Date.now())) + QUOTA_TZ_OFFSET_MINUTES * 60000;
  const x = new Date(ms);
  const y = x.getUTCFullYear();
  const m = String(x.getUTCMonth() + 1).padStart(2, "0");
  const day = String(x.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

// Reset the per-day creation set when the local day rolls over.
function imgRollDay(user) {
  const today = serverDay();
  if (user.imgDay !== today) { user.imgDay = today; user.imgCids = []; return true; }
  if (!Array.isArray(user.imgCids)) { user.imgCids = []; return true; }
  return false;
}

// Per-user daily cap for the Max tier (strongest model). Configurable via env.
/* -1 = UNMETERED, now the default. Same reasoning as IMAGE_DAILY_LIMIT: Max is the largest
   model in the chain, so this is the one guard against one client draining it for everyone —
   set the env var to a positive number to restore a ceiling. */
const MAX_DAILY_LIMIT = (() => { const n = parseInt(process.env.MAX_DAILY_LIMIT, 10); return Number.isFinite(n) ? n : -1; })();
// Reset the per-day Max-request set when the local day rolls over.
function maxRollDay(user) {
  const today = serverDay();
  if (user.maxDay !== today) { user.maxDay = today; user.maxCids = []; return true; }
  if (!Array.isArray(user.maxCids)) { user.maxCids = []; return true; }
  return false;
}
/* Max is FREE & UNLIMITED for everyone now — always report capacity available. */
async function handleMaxQuota(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { ok: false, error: "auth required" });
  return sendJson(res, 200, { ok: true, limit: 0, used: 0, remaining: -1 });
}

/* PRE-CHECK only (read-only): tells the client whether the user can still create
   an image today. The slot is NOT charged here — it's charged in handleImage
   only when real bytes come back (so failed generations never cost a credit, and
   reloads of an existing image never re-count). */
async function handleImageQuota(req, res) {
  const user = currentUser(req);
  if (!user) {
    if (currentGuest(req)) return sendJson(res, 403, { ok: false, error: "signin_required", feature: "image" });
    return sendJson(res, 401, { ok: false, error: "auth required" });
  }
  if (imgRollDay(user)) await persist();
  const used = user.imgCids.length;
  if (IMAGE_DAILY_LIMIT >= 0 && used >= IMAGE_DAILY_LIMIT) {
    return sendJson(res, 429, { ok: false, limit: IMAGE_DAILY_LIMIT, used, remaining: 0 });
  }
  return sendJson(res, 200, { ok: true, limit: IMAGE_DAILY_LIMIT, used, remaining: IMAGE_DAILY_LIMIT < 0 ? -1 : IMAGE_DAILY_LIMIT - used });
}

// Generate an image with Gemini (Google AI Studio). Returns {buf, mime} or null to
// fall back to pollinations. Free key, ~500 images/day, no card.
// --- Generated-image disk cache (DATA_DIR/imgcache) -------------------------
// Reloads of a saved image (same prompt+size+seed+engine) are served from disk so
// they're instant, don't re-spend Puter credits, and never silently change the
// picture. Keyed by the ENGINE config too, so switching models yields fresh images.
const IMG_CACHE_DIR = path.join(DATA_DIR, "imgcache");
function imgEngineTag() {
  if (!PUTER_AUTH_TOKEN) return "pollinations";
  const m = PUTER_MODEL_ALIASES[PUTER_IMAGE_MODEL] || PUTER_IMAGE_MODEL;
  return m + (/gpt-image-(2|1\.5)/i.test(m) ? ":" + PUTER_IMAGE_QUALITY : "");
}
function imgCacheKey(prompt, w, h, seed) {
  return crypto.createHash("sha1").update(imgEngineTag() + "|" + prompt + "|" + w + "x" + h + "|" + (seed || "")).digest("hex");
}
function imgCacheGet(key) {
  try {
    const f = path.join(IMG_CACHE_DIR, key), m = path.join(IMG_CACHE_DIR, key + ".t");
    if (existsSync(f) && existsSync(m)) {
      const buf = readFileSync(f);
      if (buf && buf.length) return { buf, mime: (readFileSync(m, "utf8").trim() || "image/png") };
    }
  } catch (_) {}
  return null;
}
async function imgCacheSet(key, buf, mime) {
  try {
    if (!buf || !buf.length || buf.length > 6_000_000) return; // skip empty/oversized
    if (!existsSync(IMG_CACHE_DIR)) await mkdir(IMG_CACHE_DIR, { recursive: true });
    await writeFile(path.join(IMG_CACHE_DIR, key), buf);
    await writeFile(path.join(IMG_CACHE_DIR, key + ".t"), mime || "image/png");
  } catch (_) {}
}

// Generate an image via Puter's driver API using the DEVELOPER's auth token (server-
// side → end users never sign in to Puter). Real GPT-Image / Gemini quality, free.
// Returns {buf, mime} or null on any failure (so the chain degrades to the next engine).
let _puterCooldownUntil = 0; // set when Puter is out of credits → skip it briefly so
                             // every image isn't slowed by a doomed 402 round-trip.
async function generateImagePuter(prompt) {
  if (!PUTER_AUTH_TOKEN) return null;
  if (Date.now() < _puterCooldownUntil) return null;
  const model = PUTER_MODEL_ALIASES[PUTER_IMAGE_MODEL] || PUTER_IMAGE_MODEL;
  const args = { prompt: String(prompt || "").slice(0, 4000), model };
  if (/gpt-image-(2|1\.5)/i.test(model) && PUTER_IMAGE_QUALITY) args.quality = PUTER_IMAGE_QUALITY;
  const ac = new AbortController();
  const to = setTimeout(() => ac.abort(), 120_000); // gpt-image at "high" can be slow
  try {
    const r = await fetch(PUTER_DRIVER_URL, {
      method: "POST",
      headers: { "Authorization": "Bearer " + PUTER_AUTH_TOKEN, "Content-Type": "application/json" },
      body: JSON.stringify({ interface: "puter-image-generation", driver: "ai-image", method: "generate", args }),
      signal: ac.signal,
    });
    if (!r.ok) {
      const body = await r.text().catch(() => "");
      if (r.status === 402 || /insufficient/i.test(body)) { _puterCooldownUntil = Date.now() + 10 * 60_000; } // out of credits → back off 10 min
      console.error("[firas] Puter image HTTP " + r.status + ": " + body.slice(0, 200));
      return null;
    }
    const ct = (r.headers.get("content-type") || "").toLowerCase();
    if (ct.startsWith("image/")) {
      const buf = Buffer.from(await r.arrayBuffer());
      return buf.length ? { buf, mime: ct } : null;
    }
    // Otherwise a JSON envelope or a bare string (data-URL / http URL / base64).
    const txt = await r.text();
    let j = null; try { j = JSON.parse(txt); } catch (_) {}
    if (j && j.success === false) { console.error("[firas] Puter image error: " + txt.slice(0, 200)); return null; }
    const pick = (v) => {
      if (!v) return null;
      if (typeof v === "string") return v;
      if (typeof v === "object") return v.url || v.image_url || v.image || v.data || v.b64_json || v.base64 || pick(v.result) || null;
      return null;
    };
    let s = j ? (pick(j.result) || pick(j)) : txt;
    if (typeof s !== "string" || !s) return null;
    s = s.trim();
    if (s.startsWith("data:")) {
      const comma = s.indexOf(","), semi = s.indexOf(";");
      const mime = semi > 5 ? s.slice(5, semi) : "image/png";
      const buf = Buffer.from(s.slice(comma + 1), "base64");
      return buf.length ? { buf, mime } : null;
    }
    if (/^https?:\/\//i.test(s)) {
      const ir = await fetch(s, { signal: ac.signal });
      if (!ir.ok) return null;
      const buf = Buffer.from(await ir.arrayBuffer());
      return buf.length ? { buf, mime: ir.headers.get("content-type") || "image/png" } : null;
    }
    if (/^[A-Za-z0-9+/=\s]+$/.test(s) && s.replace(/\s+/g, "").length > 200) {
      try { const buf = Buffer.from(s.replace(/\s+/g, ""), "base64"); if (buf.length > 100) return { buf, mime: "image/png" }; } catch (_) {}
    }
    return null;
  } catch (e) { console.error("[firas] Puter image exception: " + (e && e.message || e)); return null; }
  finally { clearTimeout(to); }
}

// Detect image type from magic bytes (Cloudflare models return PNG or JPEG base64).
function sniffImageMime(buf) {
  if (!buf || buf.length < 4) return "image/jpeg";
  if (buf[0] === 0x89 && buf[1] === 0x50) return "image/png";
  if (buf[0] === 0xFF && buf[1] === 0xD8) return "image/jpeg";
  if (buf[0] === 0x52 && buf[1] === 0x49 && buf[8] === 0x57) return "image/webp";
  return "image/jpeg";
}

// Generate an image via Cloudflare Workers AI (free daily quota, reliable). FLUX.2 models
// require multipart/form-data; flux-1/Leonardo take simple JSON. Response is base64 in
// {result:{image}} (or raw image bytes for some). Returns {buf,mime} or null.
// Pool of Cloudflare accounts → multiplies the free 10k-neuron/day quota. The primary
// CF_ACCOUNT_ID/CF_API_TOKEN plus any pairs in CF_ACCOUNTS ("id:token,id:token,..."). Each
// request tries them in order, skipping any in a 429 cooldown. NOTE: pooling many accounts
// to bypass a free tier may breach Cloudflare's ToS — the operator's choice.
const CF_ACCOUNTS = (() => {
  const list = [], seen = new Set();
  const add = (id, token) => {
    id = String(id || "").trim(); token = String(token || "").trim();
    if (id && token && !seen.has(id)) { seen.add(id); list.push({ id, token }); }
  };
  // 1) Primary (unnumbered) pair.
  add(CF_ACCOUNT_ID, CF_API_TOKEN);
  // 2) NUMBERED pairs: CF_ACCOUNT_ID_1 + CF_API_TOKEN_1, _2, _3 … add as many as you want;
  //    only the pairs actually set are used, and the engine rotates/falls over between them.
  for (let i = 1; i <= 64; i++) add(process.env["CF_ACCOUNT_ID_" + i], process.env["CF_API_TOKEN_" + i]);
  // 3) Legacy combined string "id:token,id:token,…".
  for (const pair of (process.env.CF_ACCOUNTS || "").split(",")) {
    const s = pair.trim(); if (!s) continue;
    const i = s.indexOf(":"); if (i < 1) continue;
    add(s.slice(0, i), s.slice(i + 1));
  }
  return list;
})();
const _cfCooldown = new Map(); // accountId -> ms timestamp to skip until (its daily 429)

// One generation attempt against a SINGLE account. Returns {buf,mime}, the string "429"
// (quota exhausted → caller cools it down and tries the next), or null on other failure.
async function cfTryAccount(acct, prompt, w, h) {
  const ac = new AbortController();
  const to = setTimeout(() => ac.abort(), 90_000); // flux-2-klein ~4s; flux-2-dev ~80s
  try {
    const url = "https://api.cloudflare.com/client/v4/accounts/" + acct.id + "/ai/run/" + CF_IMAGE_MODEL;
    const text = String(prompt || "").slice(0, 2000);
    let r;
    if (/flux-2/i.test(CF_IMAGE_MODEL)) {
      // FLUX.2 needs multipart/form-data — don't set Content-Type (fetch adds the boundary).
      const fd = new FormData();
      fd.append("prompt", text); fd.append("steps", String(CF_IMAGE_STEPS));
      fd.append("width", String(w || 1024)); fd.append("height", String(h || 1024));
      r = await fetch(url, { method: "POST", headers: { "Authorization": "Bearer " + acct.token }, body: fd, signal: ac.signal });
    } else {
      const body = { prompt: text };
      if (/flux-1|schnell/i.test(CF_IMAGE_MODEL)) body.steps = Math.min(8, CF_IMAGE_STEPS); // flux-schnell max 8
      r = await fetch(url, { method: "POST", headers: { "Authorization": "Bearer " + acct.token, "Content-Type": "application/json" }, body: JSON.stringify(body), signal: ac.signal });
    }
    if (!r.ok) {
      const errBody = await r.text().catch(() => "");
      if (r.status === 429 || /allocation|neurons/i.test(errBody)) return "429";
      console.error("[firas] Cloudflare image HTTP " + r.status + ": " + errBody.slice(0, 160));
      return null;
    }
    const ct = (r.headers.get("content-type") || "").toLowerCase();
    if (ct.startsWith("image/")) { const buf = Buffer.from(await r.arrayBuffer()); return buf.length ? { buf, mime: ct } : null; }
    const j = await r.json().catch(() => null);
    const b64 = j && ((j.result && (j.result.image || (Array.isArray(j.result.images) && j.result.images[0]))) || j.image);
    if (typeof b64 === "string" && b64.length > 100) {
      const clean = b64.startsWith("data:") ? b64.slice(b64.indexOf(",") + 1) : b64;
      const buf = Buffer.from(clean, "base64");
      return buf.length ? { buf, mime: sniffImageMime(buf) } : null;
    }
    if (j && j.success === false) console.error("[firas] Cloudflare image error: " + JSON.stringify(j.errors || j).slice(0, 160));
    return null;
  } catch (e) { console.error("[firas] Cloudflare image exception: " + (e && e.message || e)); return null; }
  finally { clearTimeout(to); }
}

// Try each pooled account in turn; skip those in 429 cooldown. Returns {buf,mime} or null.
let _cfNext = 0; // round-robin cursor → spreads load across accounts (not always account #1)
/* ── OPENAI IMAGES — the sharpest engine, on a budget that cannot overrun ──────────────────
   Firas bought credit on OpenAI directly and wants it used for pictures. Two things make that
   safe to wire in as the FIRST engine rather than a nice-to-have:

   1. A HARD SPEND CEILING, tracked in the DB so it survives restarts. Money is finite here in a
      way none of the other engines are — Cloudflare, Gemini, Hugging Face and pollinations all
      fail free, this one fails expensive. The estimate is a guard, not the truth: the truth is
      OpenAI's own billing error, and the moment it says the account is out, the engine is
      switched off for the life of the process and every request falls to Cloudflare.
   2. A PER-USER DAILY ALLOWANCE of two. One person cannot spend everyone else's credit, and the
      existing five-a-day image cap still applies on top — so images three, four and five of the
      day come from the free chain exactly as they do today.

   Nothing here degrades if the key is absent: no key means the function returns null on its
   first line and the chain is what it was before.
   ──────────────────────────────────────────────────────────────────────────────────────────── */
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || "";
/* The newest model first, with a fallback behind it. A name OpenAI does not serve comes back as
   a clean 400 in under a second — nothing like the silent hang an unhosted Ollama model causes —
   so the cost of guessing wrong here is one fast failure, and it is remembered so only the first
   request pays it. Comma-separated, strongest first. */
const OPENAI_IMAGE_MODELS = String(process.env.OPENAI_IMAGE_MODEL || "gpt-image-2")
  .split(",").map((m) => m.trim()).filter(Boolean);
const _oaiModelDead = new Set();
function openaiPickImageModel() {
  return OPENAI_IMAGE_MODELS.find((m) => !_oaiModelDead.has(m)) || OPENAI_IMAGE_MODELS[0];
}
// medium: Firas's choice. low is ~4x cheaper and visibly softer; high is ~4x dearer and would
// empty the account in a few hundred pictures.
const OPENAI_IMAGE_QUALITY = process.env.OPENAI_IMAGE_QUALITY || "high";
/* FIVE A DAY, AND THE ENGINE IS NOT THE USER'S PROBLEM. The allowance is five pictures per
   person per day, full stop. Nano Banana draws all five; if the subscription behind it will not
   answer, gpt-image draws the rest of that same five. Those are not two budgets stacked on top of
   each other — the user asked for five and gets five, and which engine served them is an internal
   detail they never see. This number therefore matches IMAGE_DAILY_LIMIT rather than sitting
   under it, so the premium counter can never bind tighter than the allowance itself. */
const OPENAI_IMAGE_DAILY = Number(process.env.OPENAI_IMAGE_DAILY ?? 5);
const OPENAI_IMAGE_BUDGET_USD = Number(process.env.OPENAI_IMAGE_BUDGET_USD ?? 60);
/* WHAT ONE PICTURE ACTUALLY COSTS — OpenAI's published per-image prices, not an estimate.

   The first version of this guard used one flat figure for every picture. That is wrong in both
   directions at once, because price moves with quality AND shape, and not in the direction you
   would guess: a square medium image costs $0.053 while the taller and wider ones cost $0.041,
   so a flat $0.05 over-charged every portrait and under-charged every square. Under-charging is
   the one that matters — it lets real spend run past a ceiling that thinks it still has room.

   Prices are per image, US dollars, GPT Image 2. Override the whole table with
   OPENAI_IMAGE_PRICES as JSON if OpenAI changes them; the shape is {quality:{size:usd}}. */
const OPENAI_IMAGE_PRICES = (() => {
  const dflt = {
    low:    { "1024x1024": 0.006, "1024x1536": 0.005, "1536x1024": 0.005 },
    medium: { "1024x1024": 0.053, "1024x1536": 0.041, "1536x1024": 0.041 },
    high:   { "1024x1024": 0.211, "1024x1536": 0.165, "1536x1024": 0.165 },
  };
  try {
    const raw = process.env.OPENAI_IMAGE_PRICES;
    if (raw) { const o = JSON.parse(raw); if (o && typeof o === "object") return o; }
  } catch (_) {}
  return dflt;
})();

/** Cost of one picture at the quality and size it will actually be made at. Falls back to the
    dearest price in the table when something is unrecognised — an unknown case must over-charge
    the guard, never under-charge it. */
function openaiImageCost(size, quality) {
  const q = String(quality || OPENAI_IMAGE_QUALITY).toLowerCase();
  const row = OPENAI_IMAGE_PRICES[q];
  const cost = row && row[size];
  if (typeof cost === "number" && cost > 0) return cost;
  let worst = 0;
  for (const r of Object.values(OPENAI_IMAGE_PRICES)) {
    for (const v of Object.values(r || {})) if (typeof v === "number" && v > worst) worst = v;
  }
  return worst || 0.25;
}
/** The dearest picture this configuration can produce — what "is there room for one more?"
    has to be measured against, since the size is not known until the request is shaped. */
function openaiImageMaxCost() {
  const row = OPENAI_IMAGE_PRICES[String(OPENAI_IMAGE_QUALITY).toLowerCase()] || {};
  let worst = 0;
  for (const v of Object.values(row)) if (typeof v === "number" && v > worst) worst = v;
  return worst || openaiImageCost("1024x1024", OPENAI_IMAGE_QUALITY);
}
let _openaiImagesOff = false;   // flipped by OpenAI itself saying the credit is gone

function openaiImageSpent() { return Number(DB.openaiImageUsd) || 0; }
function openaiImageBudgetLeft() {
  if (_openaiImagesOff || !OPENAI_API_KEY) return 0;
  return Math.max(0, OPENAI_IMAGE_BUDGET_USD - openaiImageSpent());
}
function openaiImageCharge(cost) {
  DB.openaiImageUsd = openaiImageSpent() + cost;
  persist();
  if (DB.openaiImageUsd >= OPENAI_IMAGE_BUDGET_USD) {
    console.warn("[firas] OpenAI image budget of $" + OPENAI_IMAGE_BUDGET_USD +
      " reached - images now come from Cloudflare");
  }
}
/** Called when OPENAI says the money is gone. Permanent for this process: retrying a dead
    account on every image would add a slow, certain failure in front of every picture. */
function openaiImagesExhausted(reason) {
  if (_openaiImagesOff) return;
  _openaiImagesOff = true;
  console.warn("[firas] OpenAI images disabled (" + reason + ") - falling back to Cloudflare");
}

/** gpt-image only accepts a fixed set of sizes; pick the one matching the requested shape. */
function openaiImageSize(w, h) {
  const ratio = (Number(w) || 1024) / (Number(h) || 1024);
  if (ratio > 1.2) return "1536x1024";
  if (ratio < 0.84) return "1024x1536";
  return "1024x1024";
}

/** Reset the per-day OpenAI allowance. Deliberately a SEPARATE counter from imgCids: the
    five-a-day total and the two-a-day premium allowance are different budgets. */
function oaiImgRollDay(user) {
  const today = serverDay();
  if (user.oaiImgDay !== today) { user.oaiImgDay = today; user.oaiImgCids = []; return; }
  if (!Array.isArray(user.oaiImgCids)) user.oaiImgCids = [];
}
/** May this user still spend a premium image today, and is there money for it? */
function openaiImageAllowed(user, slot) {
  if (openaiImageBudgetLeft() < openaiImageMaxCost()) return false;
  oaiImgRollDay(user);
  if (user.oaiImgCids.includes(slot)) return true;               // same picture again — no new spend
  return OPENAI_IMAGE_DAILY < 0 || user.oaiImgCids.length < OPENAI_IMAGE_DAILY;
}

/* WHICH RUNG FAILED, AND WHY. Returns the picture, or a REASON so the caller knows whether to
   try the next model or give up: "model" means this name is not one this account can use and the
   next rung is worth a try; anything else means trying another name will not help. */
async function openaiImageResult(r, what, model) {
  if (!r.ok) {
    const txt = (await r.text().catch(() => "")).slice(0, 400);
    // A name this account cannot use is a CONFIGURATION fault, not a money fault.
    if ((r.status === 400 || r.status === 404) && /model/i.test(txt)) {
      console.warn("[firas] OpenAI image model " + model + " rejected: " + txt);
      return { reason: "model" };
    }
    if (r.status === 401) { openaiImagesExhausted("HTTP 401 - the API key is not valid"); return { reason: "auth" }; }
    if (r.status === 402) { openaiImagesExhausted("HTTP 402"); return { reason: "money" }; }
    if (r.status === 429 && /insufficient_quota|billing|exceeded your current quota/i.test(txt)) {
      openaiImagesExhausted("HTTP 429 insufficient_quota");
      return { reason: "money" };
    }
    // A plain 429 is rate limiting, not bankruptcy — leave the engine on.
    console.error("[firas] OpenAI " + what + " (" + model + ") HTTP " + r.status + ": " + txt);
    return { reason: "http" };
  }
  const j = await r.json().catch(() => null);
  const d = (j && j.data && j.data[0]) || null;
  // Edits ask for JPEG (see editImageOpenAI); generations keep the default PNG.
  const mime = what === "edit" ? "image/jpeg" : "image/png";
  if (d && d.b64_json) return { buf: Buffer.from(d.b64_json, "base64"), mime };
  /* SOME MODELS ANSWER WITH A LINK, not the bytes. Reading only b64_json turned a perfectly
     good 200 into "no image" — a working key that still failed all the way down the chain. */
  if (d && d.url) {
    try {
      const img = await fetch(d.url);
      if (img.ok) {
        const buf = Buffer.from(await img.arrayBuffer());
        if (buf.length) return { buf, mime: img.headers.get("content-type") || mime };
      }
      console.error("[firas] OpenAI " + what + " (" + model + ") image link returned HTTP " + img.status);
    } catch (e) { console.error("[firas] OpenAI " + what + " (" + model + ") image link failed: " + ((e && e.message) || e)); }
    return { reason: "link" };
  }
  console.error("[firas] OpenAI " + what + " (" + model + ") returned no image; payload keys: " +
    (d ? Object.keys(d).join(",") : "no data[]"));
  return { reason: "empty" };
}

/* EVERY RUNG IS TRIED IN THIS REQUEST, not one rung per request.

   The first version remembered a rejected model in a module-level set and let the NEXT request
   start lower. That is fine on a long-lived server and useless on the edge, where an isolate is
   born and discarded around a single request: the memory dies with it, so a wrong first name is
   retried forever and the working one below it is never reached. Looping here costs one extra
   fast call the first time and always lands on a model that works.

   Only a "model" verdict continues to the next rung. A billing or auth failure means no other
   name will help either, so it stops immediately rather than burning the whole ladder. */
async function generateImageOpenAI(prompt, w, h) {
  if (openaiImageBudgetLeft() < openaiImageMaxCost()) return null;
  for (const model of OPENAI_IMAGE_MODELS) {
    const ac = new AbortController();
    const to = setTimeout(() => ac.abort(), 120_000);   // gpt-image at medium is not fast
    let out = null;
    try {
      const r = await fetch("https://api.openai.com/v1/images/generations", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: "Bearer " + OPENAI_API_KEY },
        body: JSON.stringify({
          model,
          prompt: String(prompt || "").slice(0, 4000),
          size: openaiImageSize(w, h),
          quality: OPENAI_IMAGE_QUALITY,
          n: 1,
        }),
        signal: ac.signal,
      });
      out = await openaiImageResult(r, "image", model);
    } catch (e) { out = { reason: "network" }; }
    finally { clearTimeout(to); }
    if (out && out.buf) { _oaiModelDead.delete(model); return out; }
    if (!out || out.reason !== "model") return null;      // another name will not help
    _oaiModelDead.add(model);                             // remembered for this process too
  }
  console.error("[firas] no OpenAI image model in the ladder was accepted: " + OPENAI_IMAGE_MODELS.join(", "));
  return null;
}

/** EDIT an existing picture from an instruction — "make the sky purple", "remove the car".
    This is the one thing no other engine in the chain can do: they all generate from text alone,
    so an edit request could only ever be answered with a description of the picture. Walks the
    same ladder as generation, for the same reason. */
async function editImageOpenAI(prompt, imageBuf, mime) {
  if (openaiImageBudgetLeft() < openaiImageMaxCost()) return null;
  if (!imageBuf || !imageBuf.length) return null;
  for (const model of OPENAI_IMAGE_MODELS) {
    const ac = new AbortController();
    const to = setTimeout(() => ac.abort(), 180_000);   // edits are slower than generations
    let out = null;
    try {
      const fd = new FormData();
      fd.append("model", model);
      fd.append("prompt", String(prompt || "").slice(0, 4000));
      fd.append("quality", OPENAI_IMAGE_QUALITY);
      fd.append("n", "1");
      /* JPEG, not PNG. An edited 1024px PNG is ~1.5 MB; the same picture at quality 85 is nearer
         200 KB, which is what lets the edge keep it in the database and serve it back by key. */
      fd.append("output_format", "jpeg");
      fd.append("output_compression", "85");
      /* The API infers the type from the filename as well as the blob, and a mismatch there is
         rejected as a bare "invalid image" with nothing to debug. */
      const type = /jpe?g/i.test(mime || "") ? "image/jpeg" : /webp/i.test(mime || "") ? "image/webp" : "image/png";
      const ext = type === "image/jpeg" ? "jpg" : type === "image/webp" ? "webp" : "png";
      fd.append("image", new Blob([imageBuf], { type }), "source." + ext);
      const r = await fetch("https://api.openai.com/v1/images/edits", {
        method: "POST",
        headers: { Authorization: "Bearer " + OPENAI_API_KEY },   // FormData sets its own boundary
        body: fd,
        signal: ac.signal,
      });
      out = await openaiImageResult(r, "edit", model);
    } catch (e) { out = { reason: "network" }; }
    finally { clearTimeout(to); }
    if (out && out.buf) { _oaiModelDead.delete(model); return out; }
    if (!out || out.reason !== "model") return null;
    _oaiModelDead.add(model);
  }
  return null;
}

async function generateImageCloudflare(prompt, w, h) {
  const n = CF_ACCOUNTS.length;
  if (!n) return null;
  for (let k = 0; k < n; k++) {
    const acct = CF_ACCOUNTS[(_cfNext + k) % n];
    if (Date.now() < (_cfCooldown.get(acct.id) || 0)) continue; // in 429 cooldown → skip
    const out = await cfTryAccount(acct, prompt, w, h);
    if (out === "429") { _cfCooldown.set(acct.id, Date.now() + 30 * 60_000); continue; } // exhausted → next account
    if (out && out.buf && out.buf.length) { _cfNext = (_cfNext + k + 1) % n; return out; } // advance cursor for next call
    // other failure → try the next account
  }
  return null;
}

async function generateImageGemini(prompt) {
  if (!GEMINI_API_KEY) return null;
  const ac = new AbortController();
  const to = setTimeout(() => ac.abort(), 45_000);
  try {
    const r = await fetch("https://generativelanguage.googleapis.com/v1beta/models/" + GEMINI_IMAGE_MODEL + ":generateContent", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": (geminiPickKey() || GEMINI_API_KEY) },
      body: JSON.stringify({ contents: [{ parts: [{ text: String(prompt || "").slice(0, 4000) }] }] }),
      signal: ac.signal,
    });
    if (!r.ok) { console.error("[firas] Gemini image HTTP " + r.status + ": " + (await r.text().catch(() => "")).slice(0, 160)); return null; }
    const j = await r.json();
    const parts = j && j.candidates && j.candidates[0] && j.candidates[0].content && j.candidates[0].content.parts;
    if (Array.isArray(parts)) {
      for (const p of parts) {
        const inl = p.inlineData || p.inline_data;
        if (inl && inl.data) return { buf: Buffer.from(inl.data, "base64"), mime: inl.mimeType || inl.mime_type || "image/png" };
      }
    }
    return null;
  } catch (_) { return null; }
  finally { clearTimeout(to); }
}

// Generate an image with Hugging Face (FLUX.1-schnell). Returns {buf, mime} or null.
async function generateImageHF(prompt) {
  if (!HF_API_KEY) return null;
  const ac = new AbortController();
  const to = setTimeout(() => ac.abort(), 60_000);
  try {
    const r = await fetch(HF_IMAGE_URL, {
      method: "POST",
      headers: { "Authorization": "Bearer " + HF_API_KEY, "Content-Type": "application/json", "Accept": "image/png" },
      body: JSON.stringify({ inputs: String(prompt || "").slice(0, 2000) }),
      signal: ac.signal,
    });
    if (!r.ok) { console.error("[firas] HF image HTTP " + r.status + ": " + (await r.text().catch(() => "")).slice(0, 160)); return null; }
    const ct = r.headers.get("content-type") || "";
    if (!ct.startsWith("image/")) { console.error("[firas] HF non-image response (" + ct + ")"); return null; }
    const buf = Buffer.from(await r.arrayBuffer());
    return buf.length ? { buf, mime: ct } : null;
  } catch (_) { return null; }
  finally { clearTimeout(to); }
}

/* ══ VIDEO GENERATION — HuggingFace ZeroGPU Spaces ══════════════════════════════════════════
   The only path we could verify that is free, RESETS DAILY, and is callable from a server.
   Measured live before building: 16.2-21.6 s for a 5.90 s H.264 clip at 704x512, 30 fps —
   generated from PLAIN NODE over Gradio's REST protocol, with no Python and no gradio_client:

       POST {space}/gradio_api/call/{api}   {data:[…]}  -> { event_id }
       GET  {space}/gradio_api/call/{api}/{event_id}    -> SSE, "complete" carries the result

   WHY A POOL. ZeroGPU quota is per ACCOUNT ("GPU usage is subject to daily quotas, per account
   tier": free 5 min/day, PRO 40 min/day, "resets exactly 24 hours after your first GPU usage"),
   NOT per IP — so N tokens multiply the daily allowance the same way CF_ACCOUNTS already
   multiplies Cloudflare's. 18 free accounts ≈ 90 GPU-minutes/day ≈ 280 clips ≈ 140 users at two
   clips each. Tokens are tried in rotation and a token that reports its quota exhausted is
   parked for the rest of the day rather than retried on every request.

   WHY A SPACE LIST. These are community Spaces, not a product API: of the video Spaces live when
   this was written, 36 were RUNNING and 36 were in RUNTIME_ERROR. One name is a single point of
   failure, so the list is walked in order exactly like the image chain. */
const HF_VIDEO_SPACES = (process.env.HF_VIDEO_SPACES ||
  "Lightricks/ltx-video-distilled")
  .split(",").map((s) => s.trim()).filter(Boolean);
const HF_VIDEO_API = process.env.HF_VIDEO_API || "/text_to_video";
/* Seconds per clip. 6 is the tested sweet spot: the model returns 5.90 s and the whole call
   lands ~19 s, comfortably inside a 60 s @spaces.GPU slot. Longer clips are not merely slower —
   they raise the odds of exceeding the Space's own duration cap and failing outright. */
const VIDEO_SECONDS = Math.min(10, Math.max(2, parseInt(process.env.VIDEO_SECONDS, 10) || 6));
const VIDEO_W = Math.min(1280, Math.max(256, parseInt(process.env.VIDEO_W, 10) || 704));
const VIDEO_H = Math.min(1280, Math.max(256, parseInt(process.env.VIDEO_H, 10) || 512));
/* Per-user DAILY cap. 2 by default — the owner's number. -1 disables the cap. */
const VIDEO_DAILY_LIMIT = (() => { const n = parseInt(process.env.VIDEO_DAILY_LIMIT, 10); return Number.isFinite(n) ? n : 2; })();

/* Up to 18 tokens: HF_ACCOUNTS="hf_a,hf_b,…" plus the single HF_API_KEY, de-duplicated. */
const HF_ACCOUNTS = (() => {
  const out = [];
  const add = (t) => { const v = String(t || "").trim(); if (v && !out.includes(v)) out.push(v); };
  for (const t of (process.env.HF_ACCOUNTS || "").split(",")) add(t);
  for (let i = 1; i <= 18; i++) add(process.env["HF_API_KEY_" + i]);
  add(process.env.HF_API_KEY);
  return out.slice(0, 18);
})();
let _hfNext = 0;                       // rotation cursor, so load spreads across accounts
const _hfCooldown = new Map();         // token -> ms timestamp to skip until (its daily quota)

/** Slugify "Owner/Space" into its *.hf.space origin. */
function hfSpaceOrigin(id) {
  return "https://" + String(id).replace("/", "-").toLowerCase().replace(/[^a-z0-9-]/g, "-") + ".hf.space";
}
/** Does this error text mean "this account is out of daily GPU", as opposed to a transient fault? */
function hfQuotaExhausted(txt) {
  return /quota|exceeded|exhaust|limit reached|gpu.*(quota|limit)|too many requests/i.test(String(txt || ""));
}

/** One attempt against one Space with one token. Returns { bytes, mime } or null. */
async function hfVideoAttempt(space, token, prompt, seconds, seed, signal) {
  const origin = hfSpaceOrigin(space);
  const auth = token ? { Authorization: "Bearer " + token } : {};
  // Parameter ORDER is the endpoint signature — see /text_to_video on the Space's API page.
  const data = [
    String(prompt || "").slice(0, 1200),
    "worst quality, blurry, jittery, distorted, watermark, text, subtitles",
    null, null,                                  // input image / input video (text-to-video)
    VIDEO_H, VIDEO_W,
    "text-to-video",
    seconds,
    9,                                           // frames to use (image/video modes only)
    Number(seed) || 0,
    !seed,                                       // randomize when no seed was pinned
    1,                                           // guidance
    false,                                       // improve_texture (slower; off for the free tier)
  ];
  const post = await fetch(origin + "/gradio_api/call" + HF_VIDEO_API, {
    method: "POST",
    headers: Object.assign({ "Content-Type": "application/json" }, auth),
    body: JSON.stringify({ data }),
    signal,
  });
  const posted = await post.text();
  if (!post.ok) { if (hfQuotaExhausted(posted)) throw new Error("QUOTA"); return null; }
  let eventId = "";
  try { eventId = JSON.parse(posted).event_id || ""; } catch (_) { return null; }
  if (!eventId) return null;

  const ev = await fetch(origin + "/gradio_api/call" + HF_VIDEO_API + "/" + eventId, { headers: auth, signal });
  if (!ev.ok || !ev.body) return null;
  const reader = ev.body.getReader();
  const dec = new TextDecoder();
  let buf = "", lastEvent = "", result = null;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    const lines = buf.split("\n");
    buf = lines.pop();
    for (const ln of lines) {
      if (ln.startsWith("event:")) { lastEvent = ln.slice(6).trim(); continue; }
      if (!ln.startsWith("data:")) continue;
      const raw = ln.slice(5).trim();
      if (lastEvent === "complete") { try { result = JSON.parse(raw); } catch (_) {} }
      else if (lastEvent === "error") {
        if (hfQuotaExhausted(raw)) throw new Error("QUOTA");
        return null;
      }
    }
    if (result) break;
  }
  const first = result && result[0];
  const vid = first && (first.video || first);
  const href = vid && (vid.url || vid.path);
  if (!href) return null;
  const fileUrl = /^https?:/i.test(href) ? href : origin + "/gradio_api/file=" + href;
  const f = await fetch(fileUrl, { headers: auth, signal });
  if (!f.ok) return null;
  const bytes = new Uint8Array(await f.arrayBuffer());
  // A "success" that returns a few bytes is a failure wearing a 200.
  if (bytes.length < 20000) return null;
  return { bytes, mime: f.headers.get("content-type") || "video/mp4" };
}

/** Walk the Space list and the token pool until something produces a real clip. */
async function generateVideoHF(prompt, seconds, seed, signal) {
  if (!HF_ACCOUNTS.length) return null;
  const secs = Math.min(10, Math.max(2, Number(seconds) || VIDEO_SECONDS));
  const now = Date.now();
  for (const space of HF_VIDEO_SPACES) {
    for (let k = 0; k < HF_ACCOUNTS.length; k++) {
      const idx = (_hfNext + k) % HF_ACCOUNTS.length;
      const token = HF_ACCOUNTS[idx];
      if ((_hfCooldown.get(token) || 0) > now) continue;   // this account is out for today
      try {
        const out = await hfVideoAttempt(space, token, prompt, secs, seed, signal);
        if (out) { _hfNext = (idx + 1) % HF_ACCOUNTS.length; return out; }
      } catch (e) {
        if (String(e && e.message) === "QUOTA") {
          // Park the account until tomorrow — ZeroGPU resets 24h after first use.
          _hfCooldown.set(token, now + 6 * 3600_000);
          continue;
        }
        if (signal && signal.aborted) throw e;
      }
    }
  }
  return null;
}

/* EDIT AN EXISTING PICTURE.

   Every other engine in the chain generates from text alone, so until now "make the sky purple"
   on an attached photo could only be answered by describing the photo or by inventing a new one
   that ignored it. gpt-image's edit endpoint is the only thing here that can actually take the
   picture in and give the picture back changed.

   The result is stored in the same disk cache the generator uses and handed back as a KEY, so the
   chat card is an ordinary /api/image URL: it survives a reload, costs nothing to re-open, and
   needs no new rendering path. It spends from the same two-a-day allowance and the same dollar
   ceiling as a generated image — an edit is not cheaper than a generation. */
async function handleImageEdit(req, res) {
  const user = currentUser(req);
  if (!user) {
    if (currentGuest(req)) {
      res.writeHead(403, { "Content-Type": "application/json" });
      return res.end(JSON.stringify({ error: "signin_required", feature: "image" }));
    }
    res.writeHead(401); return res.end("auth required");
  }
  if (rateLimited("imgedit:" + user.id, 30, 60_000)) { res.writeHead(429); return res.end("rate limited"); }

  let body;
  try { body = await readJson(req, 26_000_000); } catch (_) { body = null; }
  const prompt = String((body && body.prompt) || "").trim().slice(0, 1000);
  const b64 = String((body && body.image) || "").replace(/^data:[^,]*,/, "");
  const mime = String((body && body.mime) || "image/png");
  if (!prompt || !b64) { res.writeHead(400, { "Content-Type": "application/json" }); return res.end(JSON.stringify({ error: "bad_request" })); }

  let src;
  try { src = Buffer.from(b64, "base64"); } catch (_) { src = null; }
  /* Trust the BYTES, not the label. The client sends raw base64 with no mime attached, and a
     JPEG announced as png comes back from the API as a bare "invalid image" with nothing to
     debug. The three magic numbers below cover everything the attachment tray can produce. */
  const sniffed = src && src.length > 12
    ? (src[0] === 0xFF && src[1] === 0xD8 ? "image/jpeg"
      : (src[0] === 0x89 && src[1] === 0x50 ? "image/png"
        : (src.slice(0, 4).toString("ascii") === "RIFF" && src.slice(8, 12).toString("ascii") === "WEBP" ? "image/webp" : "")))
    : "";
  if (!src || !src.length || src.length > 20_000_000) {
    res.writeHead(400, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ error: "bad_image" }));
  }

  /* Keyed on the SOURCE BYTES plus the instruction, so asking for the same edit on the same
     picture twice is free and returns the identical result rather than paying again. */
  const key = crypto.createHash("sha1")
    .update("edit|" + openaiPickImageModel() + "|" + OPENAI_IMAGE_QUALITY + "|" + prompt + "|" +
            crypto.createHash("sha1").update(src).digest("hex"))
    .digest("hex");

  const already = imgCacheGet(key);
  if (already) {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ ok: true, key, cached: true }));
  }

  // Editing exists ONLY on OpenAI. Say so plainly rather than silently returning a picture that
  // ignored the instruction — that is the failure this feature was added to remove.
  if (!OPENAI_API_KEY || openaiImageBudgetLeft() < openaiImageMaxCost()) {
    res.writeHead(503, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ error: "edit_unavailable" }));
  }
  if (!openaiImageAllowed(user, key)) {
    res.writeHead(429, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ error: "daily_limit", limit: OPENAI_IMAGE_DAILY }));
  }
  imgRollDay(user);
  if (IMAGE_DAILY_LIMIT >= 0 && !user.imgCids.includes(key) && user.imgCids.length >= IMAGE_DAILY_LIMIT) {
    res.writeHead(429, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ error: "daily_limit", limit: IMAGE_DAILY_LIMIT }));
  }

  const out = await editImageOpenAI(prompt, src, sniffed || mime);
  if (!out || !out.buf || !out.buf.length) {
    res.writeHead(502, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ error: "edit_failed" }));
  }

  /* An edit is priced at the DEAREST size for this quality: the API decides the output shape
     from the source picture, so the exact one is not known here and the guard must never
     under-count. */
  const editCost = openaiImageMaxCost();
  console.log("[firas] image EDITED by OpenAI (" + openaiPickImageModel() + "/" + OPENAI_IMAGE_QUALITY +
    ", $" + editCost.toFixed(3) + "; $" + openaiImageSpent().toFixed(2) + " of $" + OPENAI_IMAGE_BUDGET_USD + " used)");
  openaiImageCharge(editCost);
  await imgCacheSet(key, out.buf, out.mime);
  if (!user.oaiImgCids.includes(key)) user.oaiImgCids.push(key);
  if (!user.imgCids.includes(key)) user.imgCids.push(key);
  persist();

  res.writeHead(200, { "Content-Type": "application/json" });
  return res.end(JSON.stringify({ ok: true, key }));
}

async function handleImage(req, res) {
  // Require a session so the proxy can't be used as an anonymous, unmetered relay
  // to pollinations. Authed reloads of saved images still carry the cookie, so
  // they keep working. A generous per-user rate cap bounds abuse loops without
  // tripping history reloads (image-heavy chats re-request every saved image).
  const user = currentUser(req);
  if (!user) {
    // A GUEST reaching image generation is not an error — it's the upsell moment.
    // Answer with a machine-readable 403 so the client can show "sign up to create
    // images" instead of a generic auth failure.
    if (currentGuest(req)) {
      res.writeHead(403, { "Content-Type": "application/json" });
      return res.end(JSON.stringify({ error: "signin_required", feature: "image" }));
    }
    res.writeHead(401); return res.end("auth required");
  }
  if (rateLimited("img:" + user.id, 240, 60_000)) { res.writeHead(429); return res.end("rate limited"); }
  const u = new URL(req.url, "http://localhost");
  const prompt = (u.searchParams.get("prompt") || "").trim().slice(0, 1000);
  if (!prompt) { res.writeHead(400); return res.end("no prompt"); }
  // Daily cap keyed by creation id: a NEW image (unseen cid) counts ONCE and only
  // on success; reloads (same cid) are free; failures never charge. A MISSING cid must still
  // be charged (an omitted cid was a full quota bypass) → synthesize one from prompt+seed so a
  // retry of the same prompt doesn't double-count. (Matches the edge backend.)
  let cid = (u.searchParams.get("cid") || "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64);
  const _seedParam = (u.searchParams.get("seed") || "").replace(/[^0-9]/g, "").slice(0, 12);
  if (!cid) {
    let hsh = 0; const pk = prompt + "|" + _seedParam;
    for (let i = 0; i < pk.length; i++) hsh = ((hsh << 5) - hsh + pk.charCodeAt(i)) | 0;
    cid = "auto" + (hsh >>> 0).toString(36);
  }
  /* A finished EDIT is served by key. The picture already exists on disk and was charged when
     it was made, so this is a pure read — that is what lets an edited image sit in the chat as an
     ordinary <img src> and survive a reload with no re-spend. */
  const editKey = (u.searchParams.get("key") || "").replace(/[^a-f0-9]/g, "").slice(0, 64);
  if (editKey) {
    const hit = imgCacheGet(editKey);
    if (hit) {
      res.writeHead(200, { "Content-Type": hit.mime, "Cache-Control": "public, max-age=86400" });
      return res.end(hit.buf);
    }
    res.writeHead(404); return res.end("not found");
  }
  imgRollDay(user);
  const w = Math.min(1280, Math.max(256, parseInt(u.searchParams.get("w"), 10) || 1024));
  const h = Math.min(1280, Math.max(256, parseInt(u.searchParams.get("h"), 10) || 1024));
  const seed = (u.searchParams.get("seed") || "").replace(/[^0-9]/g, "").slice(0, 12);
  /* The daily cap keyed on `cid` ALONE, and only checked when the cid was new. So
     ?cid=X&prompt=<anything> charged one of the five slots, and every later request reusing
     cid X with a DIFFERENT prompt skipped the 429 branch entirely and generated a brand-new
     image — real spend on Puter / Cloudflare / Gemini, with a nominal limit of five a day.
     The disk cache did not save it either: that is keyed on the prompt, so a fresh prompt
     always missed.

     The slot is now the IMAGE, not the client's string: same prompt+size+seed is genuinely
     the same picture and stays free, anything else costs a slot. The check moved below the
     parameter parsing because it now needs them. */
  const slot = imgCacheKey(prompt, w, h, seed);
  const isNew = !user.imgCids.includes(slot);
  if (IMAGE_DAILY_LIMIT >= 0 && isNew && user.imgCids.length >= IMAGE_DAILY_LIMIT) { res.writeHead(429); return res.end("daily limit reached"); }
  // Serve a previously-generated identical image straight from disk: instant, stable
  // (the saved picture never changes), and zero extra Puter/engine spend on reloads.
  const ckey = imgCacheKey(prompt, w, h, seed);
  const cached = imgCacheGet(ckey);
  if (cached) {
    if (isNew) { user.imgCids.push(slot); persist(); }   // record the IMAGE, not the client string
    res.writeHead(200, { "Content-Type": cached.mime, "Cache-Control": "public, max-age=86400" });
    return res.end(cached.buf);
  }
  /* -1) OpenAI gpt-image FIRST — the sharpest engine, and the one Firas is paying for.
     Three gates stand in front of it and ALL of them must pass, otherwise this is skipped
     silently and the chain below runs exactly as it did before:
       · a key is configured,
       · the account still has budget (a running total kept in the DB, plus OpenAI's own
         billing error, which switches the engine off permanently),
       · and this user has one of their two premium images left today.
     A failure here is never an error to the client: it returns null and Cloudflare answers. */
  if (OPENAI_API_KEY && openaiImageAllowed(user, slot)) {
    try {
      const oai = await generateImageOpenAI(prompt, w, h);
      if (oai && oai.buf && oai.buf.length) {
        // Priced at the size actually requested — square and portrait do not cost the same.
        const genCost = openaiImageCost(openaiImageSize(w, h), OPENAI_IMAGE_QUALITY);
        console.log("[firas] image served by OpenAI (" + openaiPickImageModel() + "/" + OPENAI_IMAGE_QUALITY +
          " " + openaiImageSize(w, h) + ", $" + genCost.toFixed(3) +
          "; $" + openaiImageSpent().toFixed(2) + " of $" + OPENAI_IMAGE_BUDGET_USD + " used)");
        openaiImageCharge(genCost);
        if (!user.oaiImgCids.includes(slot)) { user.oaiImgCids.push(slot); }
        await imgCacheSet(ckey, oai.buf, oai.mime);
        if (isNew) { user.imgCids.push(slot); }
        persist();
        res.writeHead(200, { "Content-Type": oai.mime, "Cache-Control": "public, max-age=86400" });
        return res.end(oai.buf);
      }
    } catch (_) { /* fall through to Cloudflare */ }
  }
  // 0) Cloudflare Workers AI (FREE FLUX.2, ~65/day) → PRIMARY: great quality + in-image
  // text at NO per-image cost and no user login. Falls through to Puter when its daily
  // quota is exhausted, so paid credits are only spent once the free pool is gone.
  try {
    const cf = await generateImageCloudflare(prompt, w, h);
    if (cf && cf.buf && cf.buf.length) {
      console.log("[firas] image served by Cloudflare (" + CF_IMAGE_MODEL + ")");
      await imgCacheSet(ckey, cf.buf, cf.mime);
      if (isNew) { user.imgCids.push(slot); persist(); }   // record the IMAGE, not the client string
      res.writeHead(200, { "Content-Type": cf.mime, "Cache-Control": "public, max-age=86400" });
      return res.end(cf.buf);
    }
  } catch (_) { /* fall through to Puter */ }
  // 1) Puter gpt-image-2 (paid credits) → premium fallback: the sharpest in-image text.
  try {
    const put = await generateImagePuter(prompt);
    if (put && put.buf && put.buf.length) {
      console.log("[firas] image served by Puter (" + imgEngineTag() + ")");
      await imgCacheSet(ckey, put.buf, put.mime);
      if (isNew) { user.imgCids.push(slot); persist(); }   // record the IMAGE, not the client string
      res.writeHead(200, { "Content-Type": put.mime, "Cache-Control": "public, max-age=86400" });
      return res.end(put.buf);
    }
    if (PUTER_AUTH_TOKEN) console.error("[firas] Puter returned no image → next engine");
  } catch (_) { if (PUTER_AUTH_TOKEN) console.error("[firas] Puter error → next engine"); }
  // 2) Gemini (free key) → actual Gemini-image quality. Falls back to pollinations.
  try {
    const gem = await generateImageGemini(prompt);
    if (gem && gem.buf && gem.buf.length) {
      console.log("[firas] image served by Gemini (" + GEMINI_IMAGE_MODEL + ")");
      await imgCacheSet(ckey, gem.buf, gem.mime);
      if (isNew) { user.imgCids.push(slot); persist(); }   // record the IMAGE, not the client string
      res.writeHead(200, { "Content-Type": gem.mime, "Cache-Control": "public, max-age=86400" });
      return res.end(gem.buf);
    }
    if (GEMINI_API_KEY) console.error("[firas] Gemini returned no image → next engine");
  } catch (_) { if (GEMINI_API_KEY) console.error("[firas] Gemini error → next engine"); }
  // 1b) Hugging Face FLUX.1-schnell (free token) → lossless PNG; ~on par with keyless.
  try {
    const hf = await generateImageHF(prompt);
    if (hf && hf.buf && hf.buf.length) {
      console.log("[firas] image served by Hugging Face (" + HF_IMAGE_MODEL + ")");
      await imgCacheSet(ckey, hf.buf, hf.mime);
      if (isNew) { user.imgCids.push(slot); persist(); }   // record the IMAGE, not the client string
      res.writeHead(200, { "Content-Type": hf.mime, "Cache-Control": "public, max-age=86400" });
      return res.end(hf.buf);
    }
  } catch (_) { /* fall through to pollinations */ }
  // 2) Keyless pollinations (flux) with LLM prompt-enhance + private/no-feed for the
  // best free quality (enhance≈doubles detail; private+nofeed keep it off the feed).
  const src = "https://image.pollinations.ai/prompt/" + encodeURIComponent(prompt) +
    "?width=" + w + "&height=" + h + "&nologo=true&enhance=true&private=true&nofeed=true&model=flux" + (seed ? "&seed=" + seed : "");
  try {
    const r = await fetch(src, { headers: { "User-Agent": SEARCH_UA, "Accept": "image/*" } });
    if (!r.ok) { res.writeHead(502); return res.end("image generation failed"); }
    const buf = Buffer.from(await r.arrayBuffer());
    const pmime = r.headers.get("content-type") || "image/jpeg";
    await imgCacheSet(ckey, buf, pmime);
    if (isNew) { user.imgCids.push(slot); persist(); }   // record the IMAGE, not the client string // charge only now (real bytes)
    res.writeHead(200, { "Content-Type": pmime, "Cache-Control": "public, max-age=86400" });
    res.end(buf);
  } catch (_) {
    res.writeHead(502);
    res.end("image generation error");
  }
}


// Reset the per-day video set when the local day rolls over. Mirrors imgRollDay.
function vidRollDay(user) {
  const today = serverDay();
  if (user.vidDay !== today) { user.vidDay = today; user.vidCids = []; return true; }
  if (!Array.isArray(user.vidCids)) { user.vidCids = []; return true; }
  return false;
}
/* The daily slot is derived from the VIDEO (prompt + seconds + seed), never from a
   client-supplied id — the same bypass that once made IMAGE_DAILY_LIMIT unbounded would
   otherwise apply here, on a path that spends a far scarcer resource. */
function vidSlotKey(prompt, seconds, seed) {
  return crypto.createHash("sha1").update("v1|" + prompt + "|" + seconds + "|" + (seed || "")).digest("hex");
}

async function handleVideo(req, res) {
  const user = currentUser(req);
  if (!user) {
    // A guest hitting video generation is the upsell moment, not an error — same shape as images.
    if (currentGuest(req)) {
      res.writeHead(403, { "Content-Type": "application/json" });
      return res.end(JSON.stringify({ error: "signin_required", feature: "video" }));
    }
    res.writeHead(401); return res.end("auth required");
  }
  if (rateLimited("vid:" + user.id, 12, 60_000)) { res.writeHead(429); return res.end("rate limited"); }
  const u = new URL(req.url, "http://localhost");
  const prompt = (u.searchParams.get("prompt") || "").trim().slice(0, 1000);
  if (!prompt) { res.writeHead(400); return res.end("no prompt"); }
  const seconds = Math.min(10, Math.max(2, parseInt(u.searchParams.get("seconds"), 10) || VIDEO_SECONDS));
  const seed = (u.searchParams.get("seed") || "").replace(/[^0-9]/g, "").slice(0, 12);

  vidRollDay(user);
  const slot = vidSlotKey(prompt, seconds, seed);
  const isNew = !user.vidCids.includes(slot);
  if (VIDEO_DAILY_LIMIT >= 0 && isNew && user.vidCids.length >= VIDEO_DAILY_LIMIT) {
    res.writeHead(429, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ error: "daily_limit", limit: VIDEO_DAILY_LIMIT, used: user.vidCids.length }));
  }
  if (!HF_ACCOUNTS.length) { res.writeHead(503); return res.end("video engine not configured"); }

  /* No absolute deadline on a live generation — the same lesson as the chat stream. A clip is
     ~20s when the queue is empty and minutes when it is not, and killing a healthy job to obey
     a stopwatch is how a working feature becomes "it does nothing". The client aborts if the
     user navigates away; this only bounds a truly dead call. */
  const ac = new AbortController();
  const to = setTimeout(() => { try { ac.abort(); } catch (_) {} }, 300_000);
  res.on("close", () => { try { ac.abort(); } catch (_) {} });
  try {
    const out = await generateVideoHF(prompt, seconds, seed, ac.signal);
    if (!out || !out.bytes || !out.bytes.length) { res.writeHead(502); return res.end("video generation failed"); }
    if (isNew) { user.vidCids.push(slot); persist(); }   // charge once, only on success
    res.writeHead(200, { "Content-Type": out.mime || "video/mp4", "Cache-Control": "public, max-age=86400" });
    res.end(Buffer.from(out.bytes));
  } catch (_) {
    if (!res.writableEnded) { res.writeHead(502); res.end("video generation error"); }
  } finally { clearTimeout(to); }
}

/** Remaining video allowance for today — lets the UI say "1 of 2 left" before spending 20s. */
async function handleVideoQuota(req, res) {
  const user = currentUser(req);
  if (!user) { res.writeHead(401); return res.end("auth required"); }
  vidRollDay(user);
  const used = user.vidCids.length;
  return sendJson(res, 200, {
    ok: VIDEO_DAILY_LIMIT < 0 || used < VIDEO_DAILY_LIMIT,
    limit: VIDEO_DAILY_LIMIT, used,
    remaining: VIDEO_DAILY_LIMIT < 0 ? -1 : Math.max(0, VIDEO_DAILY_LIMIT - used),
    seconds: VIDEO_SECONDS,
  });
}

// Lite-mirror parser (lite.duckduckgo.com) — same {title,url,snippet} shape as parseDuckDuckGo.
// The html endpoint intermittently blocks datacenter IPs (403 / anomaly page); the lite mirror
// usually still answers, so search keeps feeding live facts into answers.
function parseDdgLite(html) {
  const out = [];
  const linkRe = /<a[^>]*class=['"]result-link['"][^>]*href=['"]([^'"]+)['"][^>]*>([\s\S]*?)<\/a>|<a[^>]*href=['"]([^'"]+)['"][^>]*class=['"]result-link['"][^>]*>([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = linkRe.exec(html)) && out.length < 8) {
    const url = decodeDdgUrl(m[1] || m[3] || "");
    const title = stripTags(m[2] || m[4] || "");
    if (!title || !/^https?:\/\//i.test(url)) continue;
    // Snippet lives in the following <td class="result-snippet"> — bounded slice like the html parser.
    const after = html.slice(linkRe.lastIndex, linkRe.lastIndex + 1200);
    const sm = after.match(/<td[^>]*class=['"]result-snippet['"][^>]*>([\s\S]*?)<\/td>/i);
    out.push({ title, url, snippet: sm ? stripTags(sm[1]) : "" });
  }
  return out;
}
/* ===========================================================================
   VOICE OUTPUT — POST /api/tts (auth required)
   A CONSISTENT, natural, keyless voice that sounds the SAME on every browser
   (unlike the device speechSynthesis, whose Arabic voice is often robotic or
   missing). We proxy Google Translate TTS (free, no key), chunk the text to its
   ~200-char limit, and concatenate the MP3 segments into one audio stream the
   browser plays with <audio>. The client falls back to speechSynthesis if this
   fails (offline / blocked).
   =========================================================================== */
/* ---------------------------------------------------------------------------
   Microsoft Edge "Read Aloud" NEURAL TTS — free, keyless, professional-grade
   voices for many languages. We speak the protocol directly over a raw TLS
   WebSocket (RFC-6455) so we can set the Origin header Microsoft requires — no
   npm deps. Falls back to Google Translate TTS (below) if Edge is unavailable.
   --------------------------------------------------------------------------- */
const EDGE_TRUSTED = "6A5AA1D4EAFF4E9FB37E23D68491D6F4";
const EDGE_SEC_VER = "1-143.0.3650.75";
const EDGE_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0";
// Speaking rate for the Edge voice — a touch brisk feels more natural in a call.
// English is dialed back slightly (+7%): its neural voices already talk fast, so
// +12% sounded rushed; Arabic and the rest keep the brisker default.
const EDGE_RATE = process.env.EDGE_TTS_RATE || "+12%";
const EDGE_RATE_EN = process.env.EDGE_TTS_RATE_EN || "+7%";
// A natural neural voice per language (male, warm — fits the "معك فِراس" persona).
const EDGE_VOICES = {
  ar: "ar-SA-HamedNeural", "ar-sa": "ar-SA-HamedNeural", "ar-eg": "ar-EG-ShakirNeural",
  "ar-iq": "ar-IQ-BasselNeural", "ar-jo": "ar-JO-TaimNeural", "ar-ma": "ar-MA-JamalNeural",
  en: "en-US-AndrewMultilingualNeural", "en-us": "en-US-AndrewMultilingualNeural",
  fr: "fr-FR-HenriNeural", tr: "tr-TR-AhmetNeural", de: "de-DE-ConradNeural",
  es: "es-ES-AlvaroNeural", ur: "ur-PK-AsadNeural", fa: "fa-IR-FaridNeural",
  ru: "ru-RU-DmitryNeural", it: "it-IT-DiegoNeural", pt: "pt-BR-AntonioNeural",
  hi: "hi-IN-MadhurNeural", id: "id-ID-ArdiNeural", ja: "ja-JP-KeitaNeural",
  zh: "zh-CN-YunxiNeural", ko: "ko-KR-InJoonNeural",
};
let edgeSkew = 0;         // clock-skew correction (seconds), learned on a 403
let edgeDisabledUntil = 0; // circuit-breaker: skip Edge for a while after repeated failures
function edgeVoiceFor(lang) {
  const l = String(lang || "").toLowerCase();
  return EDGE_VOICES[l] || EDGE_VOICES[l.slice(0, 2)] || EDGE_VOICES.en;
}
function edgeGec(skew) {
  let ticks = Date.now() / 1000 + (skew || 0) + 11644473600;
  ticks -= ticks % 300;
  ticks *= 1e7;
  return crypto.createHash("sha256").update(Math.floor(ticks) + EDGE_TRUSTED, "ascii").digest("hex").toUpperCase();
}
function edgeDateStr() {
  const d = new Date();
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const mons = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const p = (n) => String(n).padStart(2, "0");
  return days[d.getUTCDay()] + " " + mons[d.getUTCMonth()] + " " + p(d.getUTCDate()) + " " +
    d.getUTCFullYear() + " " + p(d.getUTCHours()) + ":" + p(d.getUTCMinutes()) + ":" + p(d.getUTCSeconds()) +
    " GMT+0000 (Coordinated Universal Time)";
}
function edgeXmlEscape(s) {
  // strip control chars the service rejects (U+0000-08, 0B-0C, 0E-1F), then XML-escape
  let out = "";
  for (const ch of String(s)) {
    const c = ch.codePointAt(0);
    if (c <= 8 || c === 11 || c === 12 || (c >= 14 && c <= 31)) continue;
    out += ch === "&" ? "&amp;" : ch === "<" ? "&lt;" : ch === ">" ? "&gt;" : ch;
  }
  return out;
}
/** Synthesize ONE text chunk to an MP3 Buffer via Edge neural TTS. */
function edgeSynthOne(text, voice, skew, rate) {
  return new Promise((resolve, reject) => {
    const path = "/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=" + EDGE_TRUSTED +
      "&Sec-MS-GEC=" + edgeGec(skew) + "&Sec-MS-GEC-Version=" + EDGE_SEC_VER +
      "&ConnectionId=" + crypto.randomUUID().replace(/-/g, "");
    const key = crypto.randomBytes(16).toString("base64");
    let settled = false;
    const done = (err, buf) => { if (settled) return; settled = true; clearTimeout(to); try { req.destroy(); } catch (_) {} err ? reject(err) : resolve(buf); };
    const req = https.request({
      host: "speech.platform.bing.com", path, method: "GET",
      headers: {
        "Connection": "Upgrade", "Upgrade": "websocket", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": key,
        "Origin": "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", "User-Agent": EDGE_UA,
        "Pragma": "no-cache", "Cache-Control": "no-cache", "Accept-Language": "en-US,en;q=0.9",
      },
    });
    const to = setTimeout(() => done(new Error("edge timeout")), 12000);
    req.on("upgrade", (res, socket) => {
      const mask = (payload, opcode) => {
        const len = payload.length, m = crypto.randomBytes(4); let hdr;
        if (len < 126) hdr = Buffer.from([0x80 | opcode, 0x80 | len]);
        else if (len < 65536) hdr = Buffer.from([0x80 | opcode, 0x80 | 126, (len >> 8) & 255, len & 255]);
        else { hdr = Buffer.alloc(10); hdr[0] = 0x80 | opcode; hdr[1] = 0x80 | 127; hdr.writeUInt32BE(0, 2); hdr.writeUInt32BE(len, 6); }
        const out = Buffer.alloc(len); for (let i = 0; i < len; i++) out[i] = payload[i] ^ m[i % 4];
        return Buffer.concat([hdr, m, out]);
      };
      const sendText = (s) => socket.write(mask(Buffer.from(s, "utf8"), 0x1));
      sendText("X-Timestamp:" + edgeDateStr() + "\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n" +
        '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}');
      const ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='" +
        voice + "'><prosody pitch='+0Hz' rate='" + (rate || EDGE_RATE) + "' volume='+0%'>" + edgeXmlEscape(text) + "</prosody></voice></speak>";
      sendText("X-RequestId:" + crypto.randomUUID().replace(/-/g, "") + "\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:" + edgeDateStr() + "Z\r\nPath:ssml\r\n\r\n" + ssml);
      let buf = Buffer.alloc(0); const parts = [];
      socket.on("data", (d) => {
        buf = Buffer.concat([buf, d]);
        while (buf.length >= 2) {
          const op = buf[0] & 0x0f; let len = buf[1] & 0x7f, off = 2;
          if (len === 126) { if (buf.length < 4) break; len = buf.readUInt16BE(2); off = 4; }
          else if (len === 127) { if (buf.length < 10) break; len = Number(buf.readBigUInt64BE(2)); off = 10; }
          if (buf.length < off + len) break;
          const payload = buf.slice(off, off + len); buf = buf.slice(off + len);
          if (op === 0x1) { if (payload.toString("utf8").includes("Path:turn.end")) { done(null, Buffer.concat(parts)); return; } }
          else if (op === 0x2) { const hlen = payload.readUInt16BE(0); parts.push(payload.slice(2 + hlen)); }
          else if (op === 0x8) { done(null, Buffer.concat(parts)); return; }
        }
      });
      socket.on("close", () => done(parts.length ? null : new Error("edge closed early"), Buffer.concat(parts)));
      socket.on("error", (e) => done(e));
    });
    req.on("response", (res) => {
      // Non-101 (usually 403). Learn clock skew from the server Date header so a retry works.
      if (res.statusCode === 403 && res.headers.date) { const sv = Date.parse(res.headers.date); if (sv) edgeSkew = (sv - Date.now()) / 1000; }
      done(new Error("edge http " + res.statusCode));
    });
    req.on("error", (e) => done(e));
    req.end();
  });
}
/** Synthesize `text` (chunked) to one MP3 Buffer via Edge; retries once on 403 with learned skew. */
async function edgeSynthesize(text, lang) {
  if (Date.now() < edgeDisabledUntil) throw new Error("edge circuit-open");
  const voice = edgeVoiceFor(lang);
  const rate = String(lang || "").toLowerCase().startsWith("en") ? EDGE_RATE_EN : EDGE_RATE;
  const chunks = ttsChunks(text, 1600);
  const bufs = [];
  for (const c of chunks) {
    let out;
    try { out = await edgeSynthOne(c, voice, edgeSkew, rate); }
    catch (e1) {
      // one retry with the (possibly just-learned) skew
      try { out = await edgeSynthOne(c, voice, edgeSkew, rate); }
      catch (e2) { edgeDisabledUntil = Date.now() + 60_000; throw e2; }
    }
    if (out && out.length) bufs.push(out);
  }
  const all = Buffer.concat(bufs);
  if (!all.length) throw new Error("edge empty");
  return all;
}

/* ---------------------------------------------------------------------------
   Gemini EXPRESSIVE TTS — the emotional, ChatGPT-grade voice. Unlike classic
   TTS (which reads), this is a generative audio model we DIRECT with a style
   instruction ("speak warmly, like a close friend"), so it performs the line
   with real intonation and feeling, in any language/dialect. Uses the same
   free GEMINI_API_KEY as chat/vision. Returns WAV (PCM wrapped). Falls back
   to Edge neural / Google TTS when the key is missing or the quota is hit.
   --------------------------------------------------------------------------- */
const GEMINI_TTS_MODEL = process.env.GEMINI_TTS_MODEL || "gemini-2.5-flash-preview-tts";
const GEMINI_TTS_VOICE = process.env.GEMINI_TTS_VOICE || "Sadaltager"; // warm, confident male — the owner's pick
let geminiTtsDisabledUntil = 0; // circuit-breaker after quota/errors
// Small in-memory cache (greeting + repeated lines) so the call's fixed phrases
// never re-spend quota. ~40 clips × ~250 KB ≈ 10 MB tops.
const ttsCache = new Map();
function ttsCachePut(key, buf) {
  ttsCache.set(key, buf);
  if (ttsCache.size > 40) ttsCache.delete(ttsCache.keys().next().value);
}
/** Wrap raw little-endian 16-bit mono PCM in a WAV header so <audio> plays it. */
function pcmToWav(pcm, rate) {
  const hdr = Buffer.alloc(44);
  hdr.write("RIFF", 0); hdr.writeUInt32LE(36 + pcm.length, 4); hdr.write("WAVE", 8);
  hdr.write("fmt ", 12); hdr.writeUInt32LE(16, 16); hdr.writeUInt16LE(1, 20); hdr.writeUInt16LE(1, 22);
  hdr.writeUInt32LE(rate, 24); hdr.writeUInt32LE(rate * 2, 28); hdr.writeUInt16LE(2, 32); hdr.writeUInt16LE(16, 34);
  hdr.write("data", 36); hdr.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([hdr, pcm]);
}
/** The acting direction that gives the voice its feeling, per language. */
function geminiTtsStyle(lang) {
  return String(lang || "").startsWith("ar")
    ? "أنت فِراس، شابٌّ عربيّ ودود ومرِح تتحدث مع صديقك على الهاتف. انطق النص التالي بعربيةٍ فصيحة سليمة النطق — مخارج حروف واضحة، وتشكيل صحيح للكلمات كما ينطقها متحدثٌ فصيح متمكّن، من غير لكنة أعجمية — لكن بروحٍ عفوية دافئة جدًّا وحميمة: نبرة إنسانية حيّة تتموّج مع المعنى (تعلو قليلاً عند السؤال أو الحماس وتلين عند اللطف)، ابتسامة تُسمع في الصوت، وقفات قصيرة طبيعية بين الجُمل، وإيقاع سريع قليلاً وحيوي. تكلّم كإنسان حقيقي مقرّب، لا كقارئ نشرة أخبار — لا جمود ولا رسمية ولا رتابة إطلاقًا. النص: "
    : "You are Firas, a friendly, upbeat young man talking to a friend on the phone. Say the following with a very warm, human, spontaneous delivery — a lively voice that rises a touch on questions and excitement and softens on kindness, a smile you can hear, short natural pauses, and a slightly brisk, energetic rhythm. Speak like a real close friend, never like a news reader — no stiffness, no formality, no monotone at all. Text: ";
}
async function geminiSynthesize(text, lang) {
  if (!GEMINI_KEYS.length) throw new Error("no gemini key");
  if (Date.now() < geminiTtsDisabledUntil) throw new Error("gemini tts circuit-open");
  const cacheKey = crypto.createHash("sha1").update(GEMINI_TTS_VOICE + "|" + lang + "|" + text).digest("hex");
  const hit = ttsCache.get(cacheKey);
  if (hit) return hit;
  const body = JSON.stringify({
    contents: [{ parts: [{ text: geminiTtsStyle(lang) + text }] }],
    generationConfig: {
      responseModalities: ["AUDIO"],
      speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: GEMINI_TTS_VOICE } } },
    },
  });
  // Try up to N keys from the pool — a 429 on one key rotates to the next, so the
  // expressive voice keeps working across keys until ALL are quota-limited.
  const tries = Math.min(GEMINI_KEYS.length, 6);
  let lastStatus = 0;
  for (let i = 0; i < tries; i++) {
    const key = geminiPickKey();
    if (!key) break;
    let r;
    try {
      r = await fetch("https://generativelanguage.googleapis.com/v1beta/models/" + GEMINI_TTS_MODEL + ":generateContent", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-goog-api-key": key },
        body,
        signal: AbortSignal.timeout(40_000),
      });
    } catch (e) { geminiMarkLimited(key, 0); lastStatus = 0; continue; } // network/timeout → cool this key, try next
    if (!r.ok) { lastStatus = r.status; geminiMarkLimited(key, r.status); continue; }
    const j = await r.json().catch(() => null);
    const parts = j && j.candidates && j.candidates[0] && j.candidates[0].content && j.candidates[0].content.parts;
    const inl = Array.isArray(parts) ? parts.find((p) => p.inlineData && p.inlineData.data) : null;
    if (!inl) { lastStatus = 200; continue; }
    const rate = (() => { const m = /rate=(\d+)/.exec(inl.inlineData.mimeType || ""); return m ? +m[1] : 24000; })();
    const wav = pcmToWav(Buffer.from(inl.inlineData.data, "base64"), rate);
    ttsCachePut(cacheKey, wav);
    return wav;
  }
  // Every tried key failed → rest the whole engine briefly so calls fall to Edge fast.
  geminiTtsDisabledUntil = Date.now() + (lastStatus === 429 ? 120_000 : 45_000);
  throw new Error("gemini tts exhausted (" + lastStatus + ")");
}

function ttsChunks(text, max) {
  // Split on sentence enders first, then pack words up to `max` chars per piece.
  const sentences = String(text).split(/(?<=[.!?؟،؛\n])\s+/);
  const out = [];
  let cur = "";
  for (let s of sentences) {
    s = s.trim();
    if (!s) continue;
    while (s.length > max) {                 // a single very long run → hard-split at a space
      let cut = s.lastIndexOf(" ", max);
      if (cut < max * 0.5) cut = max;        // no good space → cut hard
      out.push(s.slice(0, cut).trim());
      s = s.slice(cut).trim();
    }
    if ((cur + " " + s).trim().length > max) { if (cur) out.push(cur.trim()); cur = s; }
    else cur = cur ? cur + " " + s : s;
  }
  if (cur.trim()) out.push(cur.trim());
  return out.filter(Boolean).slice(0, 14);   // hard cap so one call can't fan out unbounded
}
/* VOICE HAD NO DAILY METER AT ALL — only a per-minute rateLimited() bucket, which on the
   edge is an in-isolate Map and therefore not a per-user cap in the first place. Both
   endpoints spend the shared GEMINI_KEYS pool, the scarcest resource the app has, so an
   unmetered caller could exhaust speech for all 55 real users. This charges a real daily
   unit against the same counters every other product uses. */
function chargeVoice(caller) {
  if (caller.isGuest) {
    const denied = guestChargeWithReq(req, caller.id, "voice", null, null);
    return denied || null;
  }
  const u = caller.user;
  if (!u) return null;
  const limit = limitsFor(planOf(u)).voice;
  if (!(limit >= 0)) return null;
  quotaRollDay(u);
  if ((u.quota.voice || 0) >= limit) {
    return { error: "daily quota reached", quota: { product: "voice", used: u.quota.voice || 0, limit, plan: planOf(u) } };
  }
  u.quota.voice = (u.quota.voice || 0) + 1;
  return null;
}

async function handleTts(req, res) {
  const caller = callerOf(req);
  const user = caller.user || (caller.id ? { id: caller.id } : null);
  if (!user) return sendJson(res, 401, { error: "authentication required" });
  if (rateLimited("tts:" + user.id, caller.isGuest ? 25 : 90, 60_000)) return sendJson(res, 429, { error: "rate limited" });
  { const denied = chargeVoice(caller); if (denied) return sendJson(res, 429, denied); }
  const body = await readJson(req, 200_000);
  if (!body) return sendJson(res, 400, { error: "invalid JSON body" });
  const text = String(body.text || "").replace(/\s+/g, " ").trim().slice(0, 1400);
  if (!text) { res.writeHead(400); return res.end(); }
  const raw = String(body.lang || "").toLowerCase();
  const lang = raw.startsWith("ar") ? "ar" : (/^[a-z]{2}(-[a-z]{2})?$/.test(raw) ? raw.slice(0, 2) : "en");
  // 1) PRIMARY (ARABIC ONLY): Gemini EXPRESSIVE TTS — the generative, emotional
  //    voice. We reserve it for ARABIC — that's where the expressive delivery
  //    matters most and it keeps the limited Gemini quota for Arabic. Every OTHER
  //    language skips straight to Edge neural, whose native accents are excellent.
  if (lang === "ar") {
    try {
      const gem = await geminiSynthesize(text, raw || lang);
      if (gem && gem.length) {
        res.writeHead(200, { "Content-Type": "audio/wav", "Cache-Control": "no-store", "Content-Length": gem.length, "X-TTS-Engine": "gemini" });
        return res.end(gem);
      }
    } catch (_) { /* no key / quota / error → Edge neural below */ }
  }
  // 2) Microsoft Edge NEURAL voices (professional quality, keyless).
  //    Pass the raw lang/dialect so Arabic gets the right regional neural voice.
  try {
    const edge = await edgeSynthesize(text, raw || lang);
    if (edge && edge.length) {
      res.writeHead(200, { "Content-Type": "audio/mpeg", "Cache-Control": "no-store", "Content-Length": edge.length, "X-TTS-Engine": "edge" });
      return res.end(edge);
    }
  } catch (_) { /* Edge blocked/unavailable → Google Translate TTS below */ }
  // 3) FALLBACK: Google Translate TTS (robust, keyless, lower quality).
  const slow = body.slow ? "&ttsspeed=0.5" : "";
  const chunks = ttsChunks(text, 190);
  const bufs = [];
  try {
    for (const c of chunks) {
      const url = "https://translate.google.com/translate_tts?ie=UTF-8&client=tw-ob" + slow +
        "&tl=" + encodeURIComponent(lang) + "&q=" + encodeURIComponent(c);
      const r = await fetch(url, {
        headers: { "User-Agent": SEARCH_UA, "Referer": "https://translate.google.com/", "Accept": "audio/mpeg,*/*" },
        signal: AbortSignal.timeout(10000),
      });
      if (!r.ok) throw new Error("tts http " + r.status);
      bufs.push(Buffer.from(await r.arrayBuffer()));
    }
  } catch (_) {
    return sendJson(res, 502, { error: "tts unavailable" });
  }
  const out = Buffer.concat(bufs);
  if (!out.length) return sendJson(res, 502, { error: "tts empty" });
  res.writeHead(200, { "Content-Type": "audio/mpeg", "Cache-Control": "no-store", "Content-Length": out.length });
  res.end(out);
}

async function handleWebSearch(req, res) {
  res.setHeader("Content-Type", "application/json");
  // Auth + rate limit so the DuckDuckGo proxy isn't an open anonymous scraper.
  // Guests may search (it's part of answer quality) under a tighter cap.
  const caller = callerOf(req);
  const user = caller.user || (caller.id ? { id: caller.id } : null);
  if (!user) { res.writeHead(401); return res.end(JSON.stringify({ results: [], error: "auth" })); }
  if (rateLimited("search:" + user.id, 30, 60_000)) { res.writeHead(429); return res.end(JSON.stringify({ results: [], error: "rate" })); }
  const u = new URL(req.url, "http://localhost");
  const q = (u.searchParams.get("q") || "").trim().slice(0, 300);
  if (!q) { res.writeHead(400); return res.end(JSON.stringify({ results: [] })); }
  let results = [];
  try {
    // Bounded: a hung DDG socket must degrade to "answer without search" fast,
    // never stall the whole chat turn (this call sits inline before the reply).
    const ac = new AbortController();
    const to = setTimeout(() => ac.abort(), 8_000);
    try {
      const r = await fetch("https://html.duckduckgo.com/html/?q=" + encodeURIComponent(q), {
        headers: { "User-Agent": SEARCH_UA, "Accept-Language": "ar,en-US;q=0.8,en;q=0.6", "Accept": "text/html" },
        signal: ac.signal,
      });
      if (r.ok) results = parseDuckDuckGo(await r.text()).slice(0, 6);
    } finally { clearTimeout(to); }
  } catch (_) { /* fall through to the lite mirror below */ }
  if (!results.length) {
    // Primary endpoint blocked or empty → retry on the lite mirror so answers still get live facts.
    try {
      const r2 = await fetch("https://lite.duckduckgo.com/lite/?q=" + encodeURIComponent(q), {
        headers: { "User-Agent": SEARCH_UA, "Accept-Language": "ar,en-US;q=0.8,en;q=0.6", "Accept": "text/html" },
        signal: AbortSignal.timeout(8000),
      });
      if (r2.ok) results = parseDdgLite(await r2.text()).slice(0, 6);
    } catch (_) { /* return empty on failure — the AI answers without search */ }
  }
  res.writeHead(200);
  res.end(JSON.stringify({ q, results }));
}

/* ===========================================================================
   VOICE DICTATION — POST /api/transcribe (auth required)
   The browser records the mic (MediaRecorder), converts it to 16-kHz mono WAV
   and sends base64. Engine: Gemini Flash (free key, hears audio natively) —
   Whisper-grade verbatim transcription with automatic language detection plus
   an optional dialect hint from the in-app picker. When no engine is
   configured the endpoint answers 503 and the frontend falls back to the
   browser's live SpeechRecognition dictation, so the mic works either way.
   {probe:true} lets the client discover server-STT availability at boot.
   =========================================================================== */
const STT_HINTS = {
  auto: "",
  msa: " The speech is Arabic (العربية الفصحى).",
  iraqi: " The speech is Iraqi Arabic dialect (اللهجة العراقية). Write it in Arabic script exactly as spoken.",
  gulf: " The speech is Gulf Arabic dialect (اللهجة الخليجية). Write it in Arabic script exactly as spoken.",
  egyptian: " The speech is Egyptian Arabic dialect (اللهجة المصرية). Write it in Arabic script exactly as spoken.",
  levant: " The speech is Levantine Arabic dialect (اللهجة الشامية). Write it in Arabic script exactly as spoken.",
  maghrebi: " The speech is Maghrebi Arabic dialect (اللهجة المغاربية). Write it in Arabic script exactly as spoken.",
  en: " The speech is English.",
  fr: " The speech is French.",
  tr: " The speech is Turkish.",
  de: " The speech is German.",
  es: " The speech is Spanish.",
  ur: " The speech is Urdu.",
  fa: " The speech is Persian (Farsi).",
};
const STT_INSTRUCTION =
  "You are a professional speech-to-text engine. Output ONLY the verbatim transcription of the audio — " +
  "no commentary, no quotation marks, no labels, no translation. Keep the speaker's language and dialect " +
  "exactly as spoken (Arabic dialects stay in Arabic script as pronounced; mixed Arabic/English stays mixed). " +
  "Add natural punctuation. If there is no intelligible speech, output an empty string.";
/* ══ LIVE VOICE TOKEN — parity with netlify/edge-functions/api.js ═══════════════════════════
   The browser holds the WebSocket to Google itself; this only mints the short-lived token that
   lets it, so the API key never reaches the page. The session ceiling is expireTime, enforced by
   Google — a browser cannot talk for longer than the token allows, whatever it does. */
const GEMINI_LIVE_MODEL = String(process.env.GEMINI_LIVE_MODEL || "gemini-3.1-flash-live-preview");
const LIVE_SESSION_MAX_MS = (() => {
  const v = parseInt(process.env.LIVE_SESSION_MAX_MS, 10);
  return Number.isFinite(v) && v > 0 ? Math.min(v, 30 * 60_000) : 10 * 60_000;
})();
const LIVE_START_WINDOW_MS = 60_000;

async function handleLiveToken(req, res) {
  const caller = callerOf(req);
  const user = caller.user || null;
  /* Members only: a live minute costs on the order of a hundred dictations, and a guest is an
     unauthenticated cookie — the cheapest identity there is to mint again. */
  if (!user) return sendJson(res, 403, { error: "signin_required", feature: "live" });
  if (rateLimited("live:" + user.id, 6, 60_000)) return sendJson(res, 429, { error: "rate limited" });
  if (!GEMINI_API_KEY) return sendJson(res, 503, { error: "no_engine" });
  { const denied = chargeVoice(caller); if (denied) return sendJson(res, 429, denied); }
  const now = Date.now();
  let r;
  try {
    r = await fetch("https://generativelanguage.googleapis.com/v1beta/auth_tokens", {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_API_KEY },
      body: JSON.stringify({
        uses: 1,
        expireTime: new Date(now + LIVE_SESSION_MAX_MS).toISOString(),
        newSessionExpireTime: new Date(now + LIVE_START_WINDOW_MS).toISOString(),
        /* bidiGenerateContentSetup, not liveConnectConstraints: the latter is the SDK name and
           the REST resource has no such field, which 400s every mint. */
        bidiGenerateContentSetup: {
          model: "models/" + GEMINI_LIVE_MODEL,
          generationConfig: { responseModalities: ["AUDIO"] },
        },
        fieldMask: "model,generationConfig.responseModalities",
      }),
    });
  } catch (_) { return sendJson(res, 502, { error: "unreachable" }); }
  /* The upstream body can carry the project id and the refused key — never relay it. */
  if (!r.ok) return sendJson(res, 502, { error: "mint_failed" });
  let j = null; try { j = await r.json(); } catch (_) {}
  const name = j && (j.name || j.token || (j.tokenInfo && j.tokenInfo.name));
  if (!name) return sendJson(res, 502, { error: "mint_failed" });
  return sendJson(res, 200, {
    token: String(name),
    model: GEMINI_LIVE_MODEL,
    maxMs: LIVE_SESSION_MAX_MS,
    startWithinMs: LIVE_START_WINDOW_MS,
  });
}

async function handleTranscribe(req, res) {
  const caller = callerOf(req);
  const user = caller.user || (caller.id ? { id: caller.id } : null);
  if (!user) return sendJson(res, 401, { error: "authentication required" });
  // Guests may dictate, but under a tight cap (server STT burns Gemini quota).
  if (caller.isGuest && rateLimited("stt:" + caller.id, 12, 60_000)) return sendJson(res, 429, { error: "rate limited" });
  const body = await readJson(req, CHAT_BODY_LIMIT);
  if (!body) return sendJson(res, 400, { error: "invalid JSON body" });
  // Capability probe — lets the frontend pick server STT vs live browser dictation.
  if (body.probe) return sendJson(res, 200, { ok: !!GEMINI_API_KEY });
  if (!GEMINI_API_KEY) return sendJson(res, 503, { error: "no stt engine" });
  if (rateLimited("stt:" + user.id, 20, 60_000)) return sendJson(res, 429, { error: "rate limited" });
  { const denied = chargeVoice(caller); if (denied) return sendJson(res, 429, denied); }
  const mime = body.format === "mp3" ? "audio/mp3" : "audio/wav";
  const audio = String(body.audio || "").replace(/^data:audio\/[a-z0-9.+-]+;base64,/i, "");
  if (!audio || audio.length < 4_000) return sendJson(res, 400, { error: "no audio" });
  if (audio.length > 20_000_000 || !/^[A-Za-z0-9+/=]+$/.test(audio)) return sendJson(res, 400, { error: "bad audio" });
  const hint = STT_HINTS[String(body.lang || "auto")] || "";
  const payload = {
    contents: [{
      role: "user",
      parts: [
        { text: STT_INSTRUCTION + " Transcribe this audio verbatim." + hint },
        { inline_data: { mime_type: mime, data: audio } },
      ],
    }],
    generationConfig: { temperature: 0 },
  };
  // Try each configured Gemini model (same list the chat engines use).
  for (const model of GEMINI_TEXT_MODELS) {
    try {
      const r = await fetch("https://generativelanguage.googleapis.com/v1beta/models/" + model + ":generateContent", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-goog-api-key": (geminiPickKey() || GEMINI_API_KEY) },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(60_000),
      });
      if (!r.ok) {
        console.error("[firas] STT " + model + " HTTP " + r.status);
        continue;
      }
      const j = await r.json().catch(() => null);
      const parts = j && j.candidates && j.candidates[0] && j.candidates[0].content && j.candidates[0].content.parts;
      let text = Array.isArray(parts) ? parts.map((p) => p.text || "").join("") : "";
      text = String(text || "").trim();
      // The engine occasionally wraps a short answer in quotes — unwrap once.
      if ((/^".*"$/s.test(text) && text.length > 2) || (/^«.*»$/s.test(text) && text.length > 2)) text = text.slice(1, -1).trim();
      return sendJson(res, 200, { text });
    } catch (e) { /* timeout / network → next model */ }
  }
  return sendJson(res, 502, { error: "stt engine unavailable" });
}

/** Keyless REAL image search (Openverse — CC-licensed photos, no API key). Returns reliable
    Openverse-hosted thumbnail URLs so generated sites get real, relevant photos. */
async function handleImageSearch(req, res) {
  res.setHeader("Content-Type", "application/json");
  const caller = callerOf(req);
  const user = caller.user || (caller.id ? { id: caller.id } : null);
  if (!user) { res.writeHead(401); return res.end(JSON.stringify({ results: [], error: "auth" })); }
  if (rateLimited("images:" + user.id, 40, 60_000)) { res.writeHead(429); return res.end(JSON.stringify({ results: [], error: "rate" })); }
  const u = new URL(req.url, "http://localhost");
  const q = (u.searchParams.get("q") || "").trim().slice(0, 120);
  if (!q) { res.writeHead(400); return res.end(JSON.stringify({ results: [] })); }
  let results = [];
  try {
    const r = await fetch("https://api.openverse.org/v1/images/?format=json&mature=false&page_size=10&q=" + encodeURIComponent(q), {
      headers: { "User-Agent": SEARCH_UA, "Accept": "application/json" },
    });
    if (r.ok) {
      const d = await r.json();
      results = (Array.isArray(d.results) ? d.results : [])
        .map((x) => ({ url: x.thumbnail || x.url, title: String(x.title || "").slice(0, 100) }))
        .filter((x) => x.url && /^https:\/\//.test(x.url)).slice(0, 8);
    }
  } catch (_) { /* return empty — build falls back to gradients/picsum */ }
  res.writeHead(200);
  res.end(JSON.stringify({ q, results }));
}

/* SSRF guard shared by the proxies: hostname must not be private/loopback/link-local. */
/** True when an IP literal falls in a range that must never be reachable from the proxy. */
function privateIp(ip) {
  const s = String(ip || "");
  if (/^(::1|::ffff:127\.|fe80:|fc|fd)/i.test(s)) return true;          // v6 loopback/link-local/ULA
  const m = /^(?:::ffff:)?(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
  if (!m) return false;
  const [a, b] = [ +m[1], +m[2] ];
  return a === 0 || a === 127 || a === 10                                // this-host, loopback, private
    || (a === 169 && b === 254)                                          // link-local + cloud metadata
    || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && b === 168)
    || (a === 100 && b >= 64 && b <= 127)                                // CGNAT
    || a >= 224;                                                         // multicast / reserved
}

/* SSRF FIX — check the ADDRESS, not the name.
   The guard below is a hostname string test, so it only ever blocked hosts that LOOK
   internal. An attacker registers a public name whose A record is 127.0.0.1 (or
   169.254.169.254, the cloud metadata address) and it passes every pattern here, because
   "evil.example.com" contains nothing suspicious. The redirect re-validation had the same
   blind spot: it re-checked each hop's hostname, never where that hostname pointed.

   proxyHostAllowed() below now resolves the name and rejects it if ANY returned address is
   private. The string test is kept as a cheap first pass. */
function proxyHostBlocked(host) {
  const bare = String(host || "").replace(/^\[|\]$/g, "");
  return /^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|0\.|::1|\[)/.test(host)
    || /\.local$/.test(host)
    || host === "metadata.google.internal"
    || privateIp(bare);
}

/** Resolve `host` and reject it when any address it maps to is private. */
async function proxyHostAllowed(host) {
  if (proxyHostBlocked(host)) return false;
  try {
    const { lookup } = await import("node:dns/promises");
    const addrs = await lookup(String(host).replace(/^\[|\]$/g, ""), { all: true });
    if (!addrs || !addrs.length) return false;
    // EVERY address must be public — one private answer is enough to be a rebinding attempt.
    return !addrs.some((a) => privateIp(a.address));
  } catch {
    return false;   // cannot resolve → cannot vouch for it
  }
}
/* Fetch with MANUAL redirect handling: every hop's hostname is re-validated, so a public host
   can't 302 the proxy into localhost / the cloud metadata service (classic SSRF bypass). */
async function safeProxyFetch(target, headers, maxHops) {
  let cur = target;
  for (let hop = 0; hop <= (maxHops || 3); hop++) {
    const host = new URL(cur).hostname.toLowerCase();
    // Resolve EVERY hop, not just the first: a public host can 302 into a name that
    // resolves to loopback or the metadata address, and a name-only check never sees it.
    if (!(await proxyHostAllowed(host))) throw new Error("blocked host");
    const r = await fetch(cur, { headers, redirect: "manual" });
    if (r.status >= 300 && r.status < 400) {
      const loc = r.headers.get("location");
      if (!loc) return r;
      cur = new URL(loc, cur).href;
      if (!/^https?:\/\//i.test(cur)) throw new Error("bad redirect");
      continue;
    }
    return r;
  }
  throw new Error("too many redirects");
}

/** Stream an external image through OUR origin so documents can draw it onto the PDF canvas
    without CORS taint. SSRF-guarded, images only, 4MB cap, cached. */
async function handleImgProxy(req, res) {
  const caller = callerOf(req);
  const user = caller.user || (caller.id ? { id: caller.id } : null);
  if (!user) { res.writeHead(401, { "Content-Type": "application/json" }); return res.end(JSON.stringify({ error: "auth" })); }
  if (rateLimited("imgproxy:" + user.id, 80, 60_000)) { res.writeHead(429); return res.end(); }
  const u = new URL(req.url, "http://localhost");
  const target = (u.searchParams.get("u") || "").trim();
  let host = "";
  try { host = new URL(target).hostname.toLowerCase(); } catch { res.writeHead(400); return res.end(); }
  if (!/^https:\/\//i.test(target) || /^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|0\.|::1|\[)/.test(host) || /\.local$/.test(host)) { res.writeHead(400); return res.end(); }
  try {
    const r = await safeProxyFetch(target, { "User-Agent": SEARCH_UA, "Accept": "image/*" }, 3);
    const ct = r.headers.get("content-type") || "";
    if (!r.ok || !/^image\//i.test(ct)) { res.writeHead(415); return res.end(); }
    const buf = Buffer.from(await r.arrayBuffer());
    if (buf.length > 4_000_000) { res.writeHead(413); return res.end(); }
    res.writeHead(200, { "Content-Type": ct, "Cache-Control": "public, max-age=86400", "Content-Length": buf.length });
    return res.end(buf);
  } catch (_) { res.writeHead(502); return res.end(); }
}

/** Read a URL the user pasted → return its readable text (HTML stripped). SSRF-guarded (no
    localhost/private hosts), auth + rate limited. Lets the agent work FROM a link. */
async function handleUrlFetch(req, res) {
  res.setHeader("Content-Type", "application/json");
  const caller = callerOf(req);
  const user = caller.user || (caller.id ? { id: caller.id } : null);
  if (!user) { res.writeHead(401); return res.end(JSON.stringify({ text: "", error: "auth" })); }
  if (rateLimited("fetch:" + user.id, 20, 60_000)) { res.writeHead(429); return res.end(JSON.stringify({ text: "", error: "rate" })); }
  const u = new URL(req.url, "http://localhost");
  let target = (u.searchParams.get("url") || "").trim();
  if (!/^https?:\/\//i.test(target)) target = "https://" + target;
  let host = "";
  try { host = new URL(target).hostname.toLowerCase(); } catch { res.writeHead(400); return res.end(JSON.stringify({ text: "", error: "bad url" })); }
  if (/^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|0\.|::1|\[)/.test(host) || /\.local$/.test(host) || host === "metadata.google.internal") {
    res.writeHead(400); return res.end(JSON.stringify({ text: "", error: "blocked" }));
  }
  let text = "", title = "";
  try {
    const r = await safeProxyFetch(target, { "User-Agent": SEARCH_UA, "Accept": "text/html,application/xhtml+xml,text/plain" }, 3);
    if (r.ok) {
      const ct = r.headers.get("content-type") || "";
      const raw = (await r.text()).slice(0, 800000);
      if (/html/i.test(ct)) {
        const tm = raw.match(/<title[^>]*>([\s\S]*?)<\/title>/i); title = tm ? tm[1].replace(/\s+/g, " ").trim().slice(0, 200) : "";
        text = raw.replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<style[\s\S]*?<\/style>/gi, " ").replace(/<!--[\s\S]*?-->/g, " ").replace(/<[^>]+>/g, " ").replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&").replace(/&lt;/gi, "<").replace(/&gt;/gi, ">").replace(/&quot;/gi, '"').replace(/&#39;/g, "'").replace(/\s+/g, " ").trim().slice(0, 40000);
      } else if (/text|json|xml|markdown/i.test(ct)) { text = raw.slice(0, 40000); }
    }
  } catch (_) { /* empty on failure */ }
  res.writeHead(200);
  res.end(JSON.stringify({ url: target, title, text }));
}

/** Build version = newest mtime of the core static files. An open tab polls this
    and reloads itself when it changes, so stale SPA sessions can't linger. */
function handleVersion(req, res) {
  res.setHeader("Content-Type", "application/json");
  let v = 0;
  for (const f of ["app.js", "index.html", "styles.css"]) {
    try { v = Math.max(v, statSync(path.join(__dirname, f)).mtimeMs); } catch (_) {}
  }
  res.writeHead(200);
  res.end(JSON.stringify({ version: Math.floor(v) }));
}

// ── Max engine: Claude (Anthropic Messages API → our SSE) ───────────────────
// ── Max engine: Gemini (OpenAI-compatible, FREE Flash tier) ──────────────────
// Sniff an image mime from the base64 signature (for the data-URL Gemini expects).
function b64Mime(b64) {
  const s = String(b64 || "");
  if (s.startsWith("/9j/")) return "image/jpeg";
  if (s.startsWith("iVBOR")) return "image/png";
  if (s.startsWith("R0lGOD")) return "image/gif";
  if (s.startsWith("UklGR")) return "image/webp";
  return "image/jpeg";
}
// Stream a prebuilt OpenAI-format messages array through the Gemini OpenAI-compat endpoint,
// trying each candidate model id. Returns true if any bytes streamed. Shared by text + vision.
async function _geminiStream(res, msgs, signal, label, models, think) {
  for (const model of (models && models.length ? models : GEMINI_TEXT_MODELS)) {
    if (res.writableEnded) return true;
    /* THINKING. Gemini is reached through its OpenAI-COMPAT endpoint, so the switch is
       OpenAI-shaped (reasoning_effort) and the thoughts come back on delta.reasoning_content,
       NOT through the native thinkingConfig/parts[].thought shape. Gated on `think`: with the
       toggle off the body stays byte-identical to what shipped before, so the default path
       cannot regress. "low" is deliberate — it is enough for a readable summary, and
       gemini-2.5-flash's free tier is ~20 requests/day, so a bigger budget buys length nobody
       asked for. Vision never reaches here with think set (it passes 5 args). */
    let askThink = !!think;
    let upstream = null;
    for (;;) {
      const body = JSON.stringify(askThink
        /* THOUGHTS ARE OPT-IN, AND ASKING TO THINK IS NOT THE SAME AS ASKING TO SEE IT. Google's
           OpenAI-compatible layer will reason internally on reasoning_effort alone but returns NO
           thought text unless include_thoughts is set — which is why the panel stayed empty even
           on turns that really did reason. The effort also rises from "low": the user pressed a
           button to watch the model think, so a token budget tuned for invisible background
           reasoning is the wrong one. If either field is rejected the 400 branch below drops
           askThink and retries, so the answer itself is never at risk. */
        ? { model, messages: msgs, stream: true, reasoning_effort: "medium",
            extra_body: { google: { thinking_config: { include_thoughts: true } } } }
        : { model, messages: msgs, stream: true });
      try {
        upstream = await fetch(GEMINI_OAI_URL, {
          method: "POST",
          headers: { "Content-Type": "application/json", "Authorization": "Bearer " + (geminiPickKey() || GEMINI_API_KEY) },
          body, signal,
        });
      } catch (e) { if (signal.aborted) return true; upstream = null; break; }
      /* A rejected reasoning_effort must NOT cost us the engine. Gemini is rescue slot #1 and
         holds the only text key that is reliably present, so a 400 here would silently drop
         every tier to the next engine and turn "show me the thinking" into "the site got
         worse". Retry the same model once without the field, then continue as before. */
      if (upstream.status === 400 && askThink) {
        try { upstream.body && upstream.body.cancel(); } catch (_) {}
        console.error("[firas] " + (label || "Gemini") + " (" + model + ") rejected reasoning_effort — retrying without thinking");
        askThink = false;
        continue;
      }
      break;
    }
    if (!upstream) continue;
    if (!upstream.ok || !upstream.body) {
      console.error("[firas] " + (label || "Gemini") + " (" + model + ") HTTP " + (upstream && upstream.status) + " — trying next");
      try { upstream && upstream.body && upstream.body.cancel(); } catch (_) {}
      continue;
    }
    const decoder = new TextDecoder();
    let buffer = "", any = false;
    try {
      for await (const chunk of upstream.body) {
        if (res.writableEnded) break;
        buffer += decoder.decode(chunk, { stream: true });
        let nl;
        while ((nl = buffer.indexOf("\n")) !== -1) {
          let line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1);
          if (line.endsWith("\r")) line = line.slice(0, -1);
          if (!line.startsWith("data:")) continue;
          const payload = line.slice(5).trim();
          if (!payload || payload === "[DONE]") continue;
          let evt; try { evt = JSON.parse(payload); } catch { continue; }
          const delta = evt.choices && evt.choices[0] && evt.choices[0].delta;
          if (delta) {
            /* Thoughts stream LIVE so the panel fills as the model reasons — but they must
               NEVER set `any`. A thought-only stream that reported itself as served would
               cancel the rest of the rescue chain and leave the user a thinking panel above
               an empty answer. Only real content means "this engine served the turn". */
            const rz = delta.reasoning_content || delta.reasoning;
            if (rz) sseWrite(res, "", rz);
            if (delta.content) { sseWrite(res, delta.content); any = true; }
          }
        }
      }
      if (any) { console.log("[firas] served by " + (label || "Gemini") + " (" + model + ")"); return true; }
    } catch (e) { return signal.aborted ? true : any; }
  }
  return false;
}
// Text: Max-tier first engine. Returns true if it streamed any bytes.
async function streamGemini(res, messages, signal, think) {
  if (!GEMINI_API_KEY) return false;
  const msgs = messages
    .filter((m) => m.role === "system" || m.role === "user" || m.role === "assistant")
    .map((m) => ({ role: m.role, content: String(m.content || "") }));
  if (!msgs.length) return false;
  return _geminiStream(res, msgs, signal, "Max→Gemini", null, think);
}
// Max-tier PRIMARY engine: DeepSeek V4 Pro via NVIDIA NIM (free, OpenAI-compatible) — frontier-class
// reasoning + coding, so Max is genuinely the strongest tier. Returns true if it streamed any bytes;
// false (no key / 401 / 402 / 429 rate-limit / error BEFORE any byte) so the caller falls back to Gemini.
async function streamDeepSeek(res, messages, signal) {
  if (!NVIDIA_API_KEY) return false;
  const msgs = messages
    .filter((m) => m.role === "system" || m.role === "user" || m.role === "assistant")
    .map((m) => ({ role: m.role, content: String(m.content || "") }));
  if (!msgs.length) return false;
  // Local abort linked to the caller's signal + a 15s "first response" timeout, so if NVIDIA is slow
  // or unreachable Max bails to Gemini within 15s instead of hanging. (A user Stop still aborts.)
  const ac = new AbortController();
  const fwd = () => { try { ac.abort(); } catch (_) {} };
  if (signal.aborted) ac.abort(); else signal.addEventListener("abort", fwd, { once: true });
  const cleanup = () => { try { signal.removeEventListener("abort", fwd); } catch (_) {} };
  const headTimer = setTimeout(() => { try { ac.abort(); } catch (_) {} }, 15000);
  let upstream;
  try {
    upstream = await fetch(NVIDIA_OAI_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": "Bearer " + NVIDIA_API_KEY },
      body: JSON.stringify({
        model: NVIDIA_MODEL, messages: msgs,
        temperature: 0.6, top_p: 0.95, max_tokens: 16384,
        chat_template_kwargs: { thinking: false },
        stream: true,
      }),
      signal: ac.signal,
    });
  } catch (e) { clearTimeout(headTimer); cleanup(); return signal.aborted ? true : false; }
  clearTimeout(headTimer);
  if (!upstream.ok || !upstream.body) {
    console.error("[firas] Max→DeepSeek HTTP " + (upstream && upstream.status) + " — falling back to Gemini");
    try { upstream && upstream.body && upstream.body.cancel(); } catch (_) {}
    cleanup();
    return false;
  }
  const decoder = new TextDecoder();
  let buffer = "", any = false;
  try {
    for await (const chunk of upstream.body) {
      if (res.writableEnded) break;
      buffer += decoder.decode(chunk, { stream: true });
      let nl;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        let line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1);
        if (line.endsWith("\r")) line = line.slice(0, -1);
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (!payload || payload === "[DONE]") continue;
        let evt; try { evt = JSON.parse(payload); } catch { continue; }
        const delta = evt.choices && evt.choices[0] && evt.choices[0].delta;
        if (delta && delta.content) { sseWrite(res, delta.content); any = true; }   // skip reasoning_content
      }
    }
    if (any) { console.log("[firas] served by Max→DeepSeek (" + NVIDIA_MODEL + ")"); cleanup(); return true; }
  } catch (e) { cleanup(); return signal.aborted ? true : any; }
  cleanup();
  return false;
}
// VISION: a strong, cloud, multimodal model (works on the deployed site, no local GPU). Sends
// the attached image(s) as data-URL image_url parts. Tried BEFORE the local Ollama vision model.
async function streamGeminiVision(res, messages, signal) {
  if (!GEMINI_API_KEY) return false;
  let budget = MAX_IMAGES_PER_REQUEST;
  const msgs = messages
    .filter((m) => m.role === "system" || m.role === "user" || m.role === "assistant")
    .map((m) => {
      const text = String((m && m.content) || "");
      if (m && m.role === "user" && Array.isArray(m.images) && m.images.length && budget > 0) {
        const parts = text ? [{ type: "text", text }] : [];
        for (const raw of m.images) {
          if (budget <= 0) break;
          const norm = normalizeImage(raw);
          if (norm) { parts.push({ type: "image_url", image_url: { url: "data:" + b64Mime(norm) + ";base64," + norm } }); budget--; }
        }
        if (parts.length) return { role: m.role, content: parts };
      }
      return { role: m.role, content: text };
    });
  if (!msgs.length) return false;
  return _geminiStream(res, msgs, signal, "Vision→Gemini", GEMINI_VISION_MODELS);
}

// Returns true if it streamed any answer, false if it failed BEFORE any bytes
// (no key / 402 no-credit / error) so the caller can fall back. Does NOT send the
// terminal [DONE] — handleChat's finally does that.
async function streamAnthropic(res, messages, signal) {
  if (!ANTHROPIC_API_KEY) return false;
  // Anthropic takes system text as a top-level field; messages must be user/assistant.
  const system = messages.filter((m) => m.role === "system").map((m) => String(m.content || "")).join("\n\n");
  const conv = messages
    .filter((m) => m.role === "user" || m.role === "assistant")
    .map((m) => ({ role: m.role, content: String(m.content || "") }));
  while (conv.length && conv[0].role !== "user") conv.shift(); // Anthropic must start with user
  if (!conv.length) return false;
  const body = JSON.stringify({ model: ANTHROPIC_MODEL, max_tokens: ANTHROPIC_MAX_TOK, stream: true, ...(system ? { system } : {}), messages: conv });
  let upstream;
  try {
    upstream = await fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01" },
      body, signal,
    });
  } catch (e) { return signal.aborted ? true : false; }
  if (!upstream.ok || !upstream.body) { console.error("[firas] Max→Claude HTTP " + (upstream && upstream.status) + " — falling back"); try { upstream && upstream.body && upstream.body.cancel(); } catch (_) {} return false; }
  const decoder = new TextDecoder();
  let buffer = "", any = false;
  try {
    for await (const chunk of upstream.body) {
      if (res.writableEnded) break;
      buffer += decoder.decode(chunk, { stream: true });
      let nl;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        let line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1);
        if (line.endsWith("\r")) line = line.slice(0, -1);
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (!payload || payload === "[DONE]") continue;
        let evt; try { evt = JSON.parse(payload); } catch { continue; }
        if (evt.type === "content_block_delta" && evt.delta) {
          if (evt.delta.type === "text_delta" && evt.delta.text) { sseWrite(res, evt.delta.text); any = true; }
          else if (evt.delta.type === "thinking_delta" && evt.delta.thinking) { sseWrite(res, "", evt.delta.thinking); }
        } else if (evt.type === "error" && !any) {
          return false; // upstream error before any content → fall back
        }
      }
    }
    if (any) console.log("[firas] Max served by Claude (" + ANTHROPIC_MODEL + ")");
    return any; // true = served; false = nothing came → caller falls back
  } catch (e) { return signal.aborted ? true : any; }
}

// ── Max engine: OpenRouter (OpenAI-compatible, free DeepSeek-R1) ─────────────
async function streamOpenRouter(res, messages, signal) {
  if (!OPENROUTER_API_KEY) return false;
  const msgs = messages
    .filter((m) => m.role === "system" || m.role === "user" || m.role === "assistant")
    .map((m) => ({ role: m.role, content: String(m.content || "") }));
  if (!msgs.length) return false;
  const body = JSON.stringify({ model: OPENROUTER_MODEL, messages: msgs, stream: true });
  let upstream;
  try {
    upstream = await fetch(OPENROUTER_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": "Bearer " + OPENROUTER_API_KEY, "HTTP-Referer": "https://firasai.netlify.app", "X-Title": "Firas AI" },
      body, signal,
    });
  } catch (e) { return signal.aborted ? true : false; }
  if (!upstream.ok || !upstream.body) { console.error("[firas] Max→OpenRouter HTTP " + (upstream && upstream.status) + " — falling back"); try { upstream && upstream.body && upstream.body.cancel(); } catch (_) {} return false; }
  const decoder = new TextDecoder();
  let buffer = "", any = false;
  try {
    for await (const chunk of upstream.body) {
      if (res.writableEnded) break;
      buffer += decoder.decode(chunk, { stream: true });
      let nl;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        let line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1);
        if (line.endsWith("\r")) line = line.slice(0, -1);
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (!payload || payload === "[DONE]") continue;
        let evt; try { evt = JSON.parse(payload); } catch { continue; }
        const delta = evt.choices && evt.choices[0] && evt.choices[0].delta;
        if (delta) {
          if (delta.reasoning) sseWrite(res, "", delta.reasoning);   // R1 thinking
          if (delta.content) { sseWrite(res, delta.content); any = true; }
        }
      }
    }
    if (any) console.log("[firas] Max served by OpenRouter (" + OPENROUTER_MODEL + ")");
    return any;
  } catch (e) { return signal.aborted ? true : any; }
}

/* Cloudflare Workers AI TEXT — free (10k neurons/day), works from any country. Rotates through the
   same CF accounts used for images (429 cooldown aware). Returns true if it streamed any bytes. */
// A streaming <think>…</think> stripper for reasoning models (qwq / deepseek-r1): they emit their
// chain-of-thought in the SAME response field as the answer. Suppress everything up to and including
// </think>, then forward only the real answer. Safe on non-reasoning output too (auto-flushes if no
// <think> opens). Returns the visible text to forward for a given token (or "").
function makeThinkStripper() {
  let done = false, inside = false, buf = "", seen = 0;
  return {
    push(tok) {
      if (done) return tok;
      buf += tok; seen += tok.length;
      if (!inside && buf.indexOf("<think>") !== -1) inside = true;
      const close = buf.indexOf("</think>");
      if (close !== -1) { done = true; const after = buf.slice(close + 8); buf = ""; return after; }
      if (inside) { if (buf.length > 24) buf = buf.slice(-24); return ""; }   // discard think body, keep tail for a split tag
      if (seen > 240) { done = true; const out = buf; buf = ""; return out; }  // no <think> appeared → not a reasoning stream
      return "";                                                               // still buffering the opening chars
    },
    // Stream ended: flush any buffered NON-think content (a short answer under 240 chars with no tag).
    // If we were still inside an unclosed <think> (truncated reasoning), discard it → caller falls through.
    flush() { if (done || inside) { done = true; return ""; } const out = buf; buf = ""; done = true; return out; },
  };
}
async function streamCloudflareText(res, messages, signal, model, maxTokens) {
  if (!CF_ACCOUNTS.length) return false;
  const useModel = model || CF_TEXT_MODEL;
  const strip = useModel !== CF_TEXT_MODEL;                 // strong/reasoning path → strip <think>
  /* The rescue engines were capped low enough to truncate the very documents they were
     rescuing: a long worksheet that fell through to Cloudflare stopped at 4096 tokens and the
     user got half a file with no indication why. Raised, and still env-overridable so a model
     that rejects the larger ask can be dialled back without a redeploy. */
  const cap = maxTokens || Number(process.env.CF_MAX_TOKENS) || (strip ? 16384 : 8192);   // reasoning needs room for think AND answer
  const msgs = messages.filter((m) => m.role === "system" || m.role === "user" || m.role === "assistant")
    .map((m) => ({ role: m.role, content: String(m.content || "") }));
  if (!msgs.length) return false;
  for (let k = 0; k < CF_ACCOUNTS.length; k++) {
    if (res.writableEnded) return true;
    const acct = CF_ACCOUNTS[(_cfNext + k) % CF_ACCOUNTS.length];
    if (Date.now() < (_cfCooldown.get("txt:" + acct.id) || 0)) continue;   // separate cooldown for text
    let upstream;
    try {
      upstream = await fetch("https://api.cloudflare.com/client/v4/accounts/" + acct.id + "/ai/run/" + useModel, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Authorization": "Bearer " + acct.token },
        body: JSON.stringify({ messages: msgs, stream: true, max_tokens: cap }),
        signal,
      });
    } catch (e) { if (signal.aborted) return true; continue; }
    if (!upstream.ok || !upstream.body) {
      if (upstream && upstream.status === 429) _cfCooldown.set("txt:" + acct.id, Date.now() + 20 * 60_000);
      console.error("[firas] CF text (" + acct.id.slice(0, 6) + ") HTTP " + (upstream && upstream.status) + " — next");
      try { upstream && upstream.body && upstream.body.cancel(); } catch (_) {}
      continue;
    }
    const decoder = new TextDecoder();
    let buffer = "", any = false;
    const strip_ = strip ? makeThinkStripper() : null;
    try {
      for await (const chunk of upstream.body) {
        if (res.writableEnded) break;
        buffer += decoder.decode(chunk, { stream: true });
        let nl;
        while ((nl = buffer.indexOf("\n")) !== -1) {
          let line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1);
          if (line.endsWith("\r")) line = line.slice(0, -1);
          if (!line.startsWith("data:")) continue;
          const payload = line.slice(5).trim();
          if (!payload || payload === "[DONE]") continue;
          let evt; try { evt = JSON.parse(payload); } catch { continue; }   // CF: {"response":"token"}
          if (evt && typeof evt.response === "string" && evt.response) {
            const out = strip_ ? strip_.push(evt.response) : evt.response;
            if (out) { sseWrite(res, out); any = true; }
          }
        }
      }
      if (strip_) { const tail = strip_.flush(); if (tail) { sseWrite(res, tail); any = true; } }
      if (any) { _cfNext = (_cfNext + k + 1) % CF_ACCOUNTS.length; return true; }
    } catch (e) { if (signal.aborted) return true; }
  }
  return false;
}

async function streamFallback(res, messages, tier, think, signal) {
  const body = JSON.stringify({ model: FALLBACK_MODEL, messages, stream: true });
  let upstream;
  try {
    upstream = await fetch(FALLBACK_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" }, // no Origin server-side
      body,
      signal,
    });
  } catch (e) {
    if (signal.aborted) return;
    sseWrite(res, "تعذّر الوصول إلى محرك Firas AI حالياً — يرجى المحاولة مرة أخرى بعد لحظات.\n\nThe Firas AI engine is unavailable right now. Please try again.");
    sseDone(res);
    return;
  }

  if (!upstream.ok || !upstream.body) {
    sseWrite(res, "محرك Firas AI مشغول حالياً — يرجى المحاولة مرة أخرى بعد لحظات.\n\nThe Firas AI engine is busy right now. Please try again.");
    sseDone(res);
    return;
  }

  // Buffer the whole fallback answer, then strip the engine ad/brand before
  // sending (the ad arrives as a trailing block, so it can't be cleaned per-token).
  const decoder = new TextDecoder();
  let buffer = "";
  let answer = "";
  let reasoningAcc = "";
  try {
    for await (const chunk of upstream.body) {
      if (res.writableEnded) break;
      buffer += decoder.decode(chunk, { stream: true });
      let nl;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        let line = buffer.slice(0, nl);
        buffer = buffer.slice(nl + 1);
        if (line.endsWith("\r")) line = line.slice(0, -1);
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (!payload) continue;
        if (payload === "[DONE]") { buffer = ""; break; }
        let evt;
        try {
          evt = JSON.parse(payload);
        } catch {
          continue;
        }
        const delta = (evt.choices && evt.choices[0] && evt.choices[0].delta) || {};
        if (delta.content) answer += delta.content;
        if (think && (delta.reasoning || delta.reasoning_content)) {
          reasoningAcc += delta.reasoning || delta.reasoning_content;
        }
      }
    }
    const cleaned = stripEngineAd(answer);
    if (reasoningAcc) sseWrite(res, "", reasoningAcc);
    if (cleaned) sseWrite(res, cleaned, "");
    else if (!reasoningAcc) sseWrite(res, "The Firas AI engine is busy right now. Please try again.");
    sseDone(res);
  } catch (e) {
    if (signal.aborted) return;
    console.error("[firas] fallback stream error:", (e && e.message) || e);
    sseDone(res);
  }
}

/* ===========================================================================
   PERSISTENT USER MEMORY — the assistant learns durable facts about each user
   from their conversations and recalls them in future chats (private, per-user,
   server-side). Extraction runs via the keyless pollinations engine.
   =========================================================================== */
const MEMORY_MAX = 60;
function userMemory(user) { if (!Array.isArray(user.memory)) user.memory = []; return user.memory; }
function memoryBlock(user) {
  const m = userMemory(user);
  if (!m.length) return "";
  return "PERSISTENT MEMORY — VERIFIED facts about the user you are talking to RIGHT NOW (saved from past chats). Treat them as TRUE:\n" +
    m.map((f) => "- " + f).join("\n") +
    "\nUse them to personalize naturally. When the user ASKS what you know/remember about them, answer using EXACTLY these facts and nothing invented — keep their exact name, country, city, age and numbers as written here; never substitute a different place or guess a value. If the user now says something that contradicts a fact, trust their newest statement.";
}
// Non-streaming completion for memory extraction. Prefers the STRONG Ollama model
// (accurate, deterministic at temperature 0 — no hallucination) and falls back to the
// keyless pollinations engine. Returns text or "".
async function llmComplete(messages, opts) {
  opts = opts || {};
  const tok = opts.maxTokens || 1500; // room for a reasoning model to think AND answer
  const temp = opts.temperature != null ? opts.temperature : 0;
  // 1) Ollama (strong, accurate) — gpt-oss reasoning model. num_predict must be large
  // enough that thinking + the JSON answer both fit, or .content comes back empty.
  // Rotates to the next pool key when one is quota-limited (429/402/403).
  for (let a = 0; a < Math.max(1, Math.min(3, OLLAMA_KEYS.length || 1)); a++) {
    const olKey = ollamaPickKey();
    try {
      const r = await fetch(OLLAMA_CHAT_URL, {
        method: "POST",
        headers: ollamaHeaders(olKey),
        body: JSON.stringify({ model: (TIERS.pro && TIERS.pro.model) || "gpt-oss:120b-cloud", messages, stream: false, options: { temperature: temp, num_predict: tok } }),
        signal: opts.signal,
      });
      if (r.ok) {
        const j = await r.json().catch(() => null);
        const c = j && j.message && j.message.content;
        if (typeof c === "string" && c.trim()) return c;
        break;                                              // OK but empty → don't burn more keys
      }
      if (olKey && (r.status === 429 || r.status === 402 || r.status === 403)) { ollamaMarkLimited(olKey, r.status); continue; }
      break;                                                // non-quota error → fall through to pollinations
    } catch (_) { break; }
  }
  // 2) Keyless pollinations fallback.
  try {
    const r = await fetch(FALLBACK_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: FALLBACK_MODEL, messages, stream: false, temperature: temp, max_tokens: tok }),
      signal: opts.signal,
    });
    if (!r.ok) return "";
    const j = await r.json().catch(() => null);
    const c = j && j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content;
    return typeof c === "string" ? c : "";
  } catch (_) { return ""; }
}
// Pull durable USER facts from one exchange and merge into the user's memory.
async function handleMemoryLearn(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "authentication required" });
  if (rateLimited("mem:" + user.id, 60, 60_000)) return sendJson(res, 429, { error: "rate limited" });
  let payload; try { payload = JSON.parse((await readBody(req, 200_000)) || "{}"); } catch { return sendJson(res, 400, { error: "invalid JSON" }); }
  const userText = String(payload.user || "").slice(0, 4000).trim();
  const aiText = String(payload.assistant || "").slice(0, 2000).trim();
  if (!userText) return sendJson(res, 200, { ok: true, added: 0 });
  const existing = userMemory(user);
  const sys =
    "You extract durable facts about a USER. Preserve name, age, country, city EXACTLY as stated " +
    "(from Iraq -> 'From Iraq'; age 16 -> 'Age: 16'; never change or guess). " +
    "Capture name, age, country, job, language, likes, projects, goals, interests, and any personal detail. " +
    "Return ONLY a JSON array of short strings. If nothing, []." +
    (existing.length ? " Skip facts already in: " + JSON.stringify(existing.slice(-50)) : "");
  const u = 'The USER said: "' + userText + '". Return JSON array of facts:';
  const msgs = [{ role: "system", content: sys }, { role: "user", content: u }];
  // The cloud model is non-deterministic and often returns PARTIAL facts on any single
  // call; run a few passes and UNION the results so we capture the full set.
  const collected = new Map();
  const temps = [0, 0.5, 0.8]; // varied temps so passes differ → fuller union; run in PARALLEL for speed
  const outs = await Promise.all(temps.map((t) => llmComplete(msgs, { maxTokens: 1500, temperature: t })));
  for (const out of outs) {
    let arr = []; try { const m = out.match(/\[[\s\S]*\]/); if (m) arr = JSON.parse(m[0]); } catch (_) {}
    if (Array.isArray(arr)) for (const f of arr) { const s = String(f || "").trim(); if (s && s.length <= 140) { const k = s.toLowerCase(); if (!collected.has(k)) collected.set(k, s); } }
  }
  let facts = [...collected.values()];
  if (!Array.isArray(facts)) facts = [];
  let added = 0;
  const seen = new Set(existing.map((f) => String(f).toLowerCase().trim()));
  const labelOf = (s) => { const i = String(s).indexOf(":"); return i > 0 ? String(s).slice(0, i).trim().toLowerCase() : ""; };
  for (let f of facts) {
    f = String(f || "").trim();
    if (!f || f.length > 140) continue;
    const key = f.toLowerCase();
    if (seen.has(key)) continue;
    // Correction-via-conversation: a new "Label: value" REPLACES any older fact with the
    // same label (so a fresh "City: Baghdad" removes a stale "City: Aleppo") — the user
    // can fix what Firas knows just by telling it, no manual editor needed.
    const lab = labelOf(f);
    if (lab) {
      for (let i = existing.length - 1; i >= 0; i--) {
        if (labelOf(existing[i]) === lab) { seen.delete(String(existing[i]).toLowerCase().trim()); existing.splice(i, 1); }
      }
    }
    seen.add(key); existing.push(f); added++;
  }
  if (added) { while (existing.length > MEMORY_MAX) existing.shift(); persist(); }
  return sendJson(res, 200, { ok: true, added, total: existing.length });
}
function handleMemoryGet(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "authentication required" });
  return sendJson(res, 200, { memory: userMemory(user) });
}
async function handleMemoryClear(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "authentication required" });
  // DELETE /api/memory clears all; DELETE /api/memory?i=N removes one by index.
  const u = new URL(req.url, "http://localhost");
  const idx = u.searchParams.get("i");
  const mem = userMemory(user);
  if (idx != null && idx !== "") { const n = parseInt(idx, 10); if (n >= 0 && n < mem.length) mem.splice(n, 1); }
  else user.memory = [];
  persist();
  return sendJson(res, 200, { ok: true, memory: userMemory(user) });
}

/* ============================================================================
   SITE UPDATES / ANNOUNCEMENTS — the owner (admin) publishes updates (text +
   image); every user sees them on every device. Stored in DB (file / Firebase).
   ========================================================================== */
const ADMIN_EMAILS = (process.env.ADMIN_EMAILS || "firasnozad@gmail.com").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
function isAdmin(user) { return !!(user && user.email && ADMIN_EMAILS.includes(String(user.email).toLowerCase())); }

/* ===========================================================================
   REDEEM CODES — user activation + admin management. All validation is
   server-side; the client can never grant itself a plan.
   =========================================================================== */
// USER: activate a code → apply the subscription. Brute-force-guarded.
async function handleRedeem(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "authentication required" });
  if (rateLimited("redeem:" + user.id, 8, 60_000) || rateLimited("redeemip:" + (clientIp(req) || "?"), 20, 60_000))
    return sendJson(res, 429, { error: "too many attempts, please wait a minute" });
  const body = await readJson(req, 4_000);
  const codeStr = normCode(body && body.code);
  if (!codeStr || codeStr.length < 5) return sendJson(res, 400, { error: "invalid code" });
  const c = findCode(codeStr);
  if (!c) return sendJson(res, 404, { error: "code not found" });
  const st = codeStatus(c);
  if (st === "disabled") return sendJson(res, 403, { error: "code disabled" });
  if (st === "expired") return sendJson(res, 410, { error: "code expired" });
  if (st === "used-up") return sendJson(res, 409, { error: "code fully used" });
  if (c.boundUserId && c.boundUserId !== user.id) return sendJson(res, 403, { error: "code not for this account" });
  if (Array.isArray(c.usedBy) && c.usedBy.some((u) => u.userId === user.id)) return sendJson(res, 409, { error: "you already redeemed this code" });

  const now = Date.now();
  const type = c.type;
  let expiresAt = null;
  if (type === "gold" || type === "diamond") {
    const days = Number(c.durationDays) > 0 ? Number(c.durationDays) : 30;
    // Extend from the current expiry if the SAME plan is still active (stacking).
    const cur = user.sub;
    const base = (cur && cur.plan === type && cur.expiresAt && cur.expiresAt > now) ? cur.expiresAt : now;
    expiresAt = base + days * 86400000;
  }
  user.sub = { plan: type, expiresAt, since: now, code: c.code };
  /* PARITY NOTE: the edge reserves codes/<id>/claims/<userId> and re-counts, because two
     concurrent isolates could both read uses:0 on a maxUses:1 code and both write uses:1.
     Node is single-threaded and nothing above this line awaits, so this check-then-
     increment cannot be interleaved — the plain counter stays correct here. Codes written
     by the edge carry a `claims` map; this backend never reads or writes one. */
  c.uses = (c.uses || 0) + 1;
  c.usedBy = Array.isArray(c.usedBy) ? c.usedBy : [];
  c.usedBy.push({ userId: user.id, email: user.email, at: now });
  await persist();
  return sendJson(res, 200, { ok: true, sub: subInfo(user) });
}
// ADMIN: list all codes (+ optional search).
async function handleAdminCodesList(req, res, url) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "authentication required" });
  if (!isAdmin(user)) return sendJson(res, 403, { error: "admins only" });
  const qraw = ((url && url.searchParams.get("q")) || "").toString().trim().toLowerCase();
  let list = codesList().slice().sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
  if (qraw) list = list.filter((c) => (c.code || "").toLowerCase().includes(qraw) || (c.note || "").toLowerCase().includes(qraw) || (c.type || "").includes(qraw));
  return sendJson(res, 200, { codes: list.map(publicCode), plans: PLAN_LIMITS });
}
// ADMIN: create one custom code OR a batch of random codes.
async function handleAdminCodesCreate(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "authentication required" });
  if (!isAdmin(user)) return sendJson(res, 403, { error: "admins only" });
  const body = await readJson(req, 20_000) || {};
  const type = ["gold", "diamond", "unlimited"].includes(body.type) ? body.type : "gold";
  const durationDays = type === "unlimited" ? null : (Number(body.durationDays) > 0 ? Math.min(3650, Math.floor(Number(body.durationDays))) : 30);
  const maxUses = Math.min(1_000_000, Math.max(1, parseInt(body.maxUses, 10) || 1));
  const note = String(body.note || "").slice(0, 200);
  const expiresAt = Number(body.expiresAt) > 0 ? Number(body.expiresAt) : null;
  let boundUserId = null;
  if (body.boundUserEmail) { const bu = DB.users.find((u) => u.email === String(body.boundUserEmail).toLowerCase().trim()); if (!bu) return sendJson(res, 404, { error: "bound user not found" }); boundUserId = bu.id; }
  const custom = normCode(body.customCode);
  const count = custom ? 1 : Math.min(500, Math.max(1, parseInt(body.count, 10) || 1));
  const created = [];
  for (let i = 0; i < count; i++) {
    let code = custom || genCode();
    if (findCode(code) || created.some((x) => x.code === code)) {
      if (custom) return sendJson(res, 409, { error: "code already exists" });
      do { code = genCode(); } while (findCode(code) || created.some((x) => x.code === code));
    }
    created.push({
      id: "cd" + Date.now().toString(36) + crypto.randomBytes(4).toString("hex") + i,
      code, type, durationDays, maxUses, uses: 0, usedBy: [],
      expiresAt, note, disabled: false, boundUserId, createdAt: Date.now(), createdBy: user.email,
    });
  }
  for (const c of created) codesList().push(c);
  await persist();
  return sendJson(res, 200, { ok: true, created: created.map(publicCode) });
}
// ADMIN: edit / disable / re-enable a code.
async function handleAdminCodesPatch(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "authentication required" });
  if (!isAdmin(user)) return sendJson(res, 403, { error: "admins only" });
  const body = await readJson(req, 8_000) || {};
  const c = codesList().find((x) => x.id === body.id);
  if (!c) return sendJson(res, 404, { error: "code not found" });
  if (typeof body.disabled === "boolean") c.disabled = body.disabled;
  if (typeof body.note === "string") c.note = body.note.slice(0, 200);
  if (body.type && ["gold", "diamond", "unlimited"].includes(body.type)) { c.type = body.type; if (c.type === "unlimited") c.durationDays = null; }
  if (body.durationDays != null && c.type !== "unlimited") c.durationDays = Math.max(1, Math.floor(Number(body.durationDays)) || 30);
  if (body.maxUses != null) c.maxUses = Math.min(1_000_000, Math.max(1, parseInt(body.maxUses, 10) || 1));
  if (body.expiresAt !== undefined) c.expiresAt = Number(body.expiresAt) > 0 ? Number(body.expiresAt) : null;
  await persist();
  return sendJson(res, 200, { ok: true, code: publicCode(c) });
}
// ADMIN: delete a code (?id=).
async function handleAdminCodesDelete(req, res, url) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "authentication required" });
  if (!isAdmin(user)) return sendJson(res, 403, { error: "admins only" });
  const id = (url && url.searchParams.get("id")) || "";
  if (!id) return sendJson(res, 400, { error: "id required" });
  const before = codesList().length;
  DB.codes = codesList().filter((c) => c.id !== id);
  if (DB.codes.length !== before) await persist();
  return sendJson(res, 200, { ok: true });
}
// Charge ONE unit of the Code (per build) or Agent (per mission) daily quota.
// Server-authoritative; the client calls this at a build/mission's entry point.
async function handleUsageCharge(req, res) {
  const caller = callerOf(req);
  const user = caller.user || null;
  if (!user && !caller.isGuest) return sendJson(res, 401, { error: "authentication required" });
  const body = await readJson(req, 2_000) || {};
  const product = (body.product === "code" || body.product === "agent") ? body.product : null;
  if (!product) return sendJson(res, 400, { error: "invalid product" });
  // GUEST: charge the trial allowance so Code builds / Agent missions are gated
  // for guests too (otherwise the client's gate is the only one, i.e. none).
  if (caller.isGuest) {
    const denied = guestChargeWithReq(req, caller.id, product, body.cid);
    if (denied) return sendJson(res, 429, denied);
    return sendJson(res, 200, { ok: true, sub: guestSubInfo(caller.id) });
  }
  const limit = limitsFor(planOf(user))[product];
  if (limit < 0) return sendJson(res, 200, { ok: true, sub: subInfo(user) }); // unlimited plan
  quotaRollDay(user);
  const q = user.quota;
  const cid = String(body.cid || "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64);
  const already = product === "agent" ? (cid && q.agentCids.includes(cid)) : (cid && q.last[product] === cid);
  if (!already && (q[product] || 0) >= limit) return sendJson(res, 429, { error: "daily quota reached", quota: { product, used: q[product] || 0, limit, plan: planOf(user) } });
  if (!already) { q[product] = (q[product] || 0) + 1; if (product === "agent") { if (cid) { q.agentCids.push(cid); if (q.agentCids.length > 500) q.agentCids.shift(); } } else if (cid) q.last[product] = cid; await persist(); }
  return sendJson(res, 200, { ok: true, sub: subInfo(user) });
}

function announcementsList() { if (!Array.isArray(DB.announcements)) DB.announcements = []; return DB.announcements; }
const ANN_IMG_OK = (s) => typeof s === "string" && /^(data:image\/(png|jpe?g|webp);base64,|https?:\/\/)/.test(s);
/* Mirrors the edge. A video is a URL, never inline data: the trailer is 47 MB and an
   announcement record is JSON. Only a same-origin /media/ path or an https URL passes, so a
   stored string can never become a javascript: or data: sink in the client's <video src>. */
const ANN_VID_OK = (s) => typeof s === "string" &&
  /^(\/media\/[A-Za-z0-9._-]+\.(mp4|webm)|https:\/\/[^\s"'<>]+\.(mp4|webm))$/.test(s);
function handleAnnouncementsGet(req, res) {
  // Guests see site updates too (read-only); only a real admin gets the admin flag.
  const caller = callerOf(req);
  if (!caller.user && !caller.isGuest) return sendJson(res, 401, { error: "authentication required" });
  // Pinned first, then newest — a pinned item must not scroll away as others are posted.
  const list = announcementsList().slice()
    .sort((a, b) => (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0) || (b.ts || 0) - (a.ts || 0)).slice(0, 50);
  return sendJson(res, 200, { announcements: list, admin: isAdmin(caller.user) });
}
async function handleAnnouncementsPost(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "authentication required" });
  if (!isAdmin(user)) return sendJson(res, 403, { error: "admins only" });
  let p; try { p = JSON.parse((await readBody(req, CHAT_BODY_LIMIT)) || "{}"); } catch { return sendJson(res, 400, { error: "invalid JSON" }); }
  const title = String(p.title || "").slice(0, 200).trim();
  const body = String(p.body || "").slice(0, 4000).trim();
  // Bilingual by STORAGE, not machine translation — both texts are authored and kept.
  const titleEn = String(p.titleEn || "").slice(0, 200).trim();
  const bodyEn = String(p.bodyEn || "").slice(0, 4000).trim();
  let image = String(p.image || "").trim();
  if (image && !ANN_IMG_OK(image)) image = "";
  if (image.length > 600000) return sendJson(res, 413, { error: "image too large" });
  let video = String(p.video || "").trim();
  if (video && !ANN_VID_OK(video)) video = "";
  const pinned = !!p.pinned;
  if (!title && !body && !image && !video) return sendJson(res, 400, { error: "empty announcement" });
  const item = { id: "a" + Date.now().toString(36) + Math.random().toString(36).slice(2, 7), title, body, titleEn, bodyEn, image, video, pinned, ts: Date.now(), by: user.name || "Firas" };
  const list = announcementsList();
  list.unshift(item);
  while (list.length > 100) list.pop();
  await persist();
  return sendJson(res, 200, { ok: true, announcement: item });
}
async function handleAnnouncementsDelete(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "authentication required" });
  if (!isAdmin(user)) return sendJson(res, 403, { error: "admins only" });
  const q = new URL(req.url, "http://localhost").searchParams;
  /* CLEAR ALL — ?all=1. Splices by the ids actually present rather than reassigning
     DB.announcements, so nothing outside this array can be caught by it. This database
     has no backup, which is exactly why the blast radius is written down here. */
  if (q.get("all") === "1") {
    const l = announcementsList();
    const ids = l.map((a) => a && a.id).filter(Boolean);
    l.length = 0;
    await persist();
    return sendJson(res, 200, { ok: true, removed: ids.length, ids });
  }
  const id = q.get("id");
  const list = announcementsList();
  const i = list.findIndex((a) => a.id === id);
  if (i >= 0) { list.splice(i, 1); await persist(); }
  return sendJson(res, 200, { ok: true });
}
async function handleAnnouncementsPatch(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "authentication required" });
  if (!isAdmin(user)) return sendJson(res, 403, { error: "admins only" });
  let p; try { p = JSON.parse((await readBody(req, CHAT_BODY_LIMIT)) || "{}"); } catch { return sendJson(res, 400, { error: "invalid JSON" }); }
  const item = announcementsList().find((a) => a.id === String(p.id || ""));
  if (!item) return sendJson(res, 404, { error: "not found" });
  if (typeof p.title === "string") item.title = p.title.slice(0, 200).trim();
  if (typeof p.body === "string") item.body = p.body.slice(0, 4000).trim();
  if (typeof p.image === "string") {
    let image = p.image.trim();
    if (image && !ANN_IMG_OK(image)) image = "";
    if (image.length > 600000) return sendJson(res, 413, { error: "image too large" });
    item.image = image; // "" removes the image
  }
  item.editedTs = Date.now();
  await persist();
  return sendJson(res, 200, { ok: true, announcement: item });
}

/* ============================================================================
   ADMIN KNOWLEDGE BASE (RAG) — the admin uploads reference books/material; on any
   user question we silently retrieve the most relevant passages (topic/keyword
   match) and feed them to the model as HIDDEN reference, so answers are grounded
   in the books WITHOUT citing them. Strengthens science, grammar, etc.
   ========================================================================== */
// Bundled LOCAL knowledge base (math/science/arabic/quran…), compiled by
// knowledge/build.mjs into an importable ES module. Loaded ONCE at boot and
// searched alongside the admin KB. Missing/broken file → empty (never crashes).
let LOCAL_KB = [];
try {
  const mod = await import("./knowledge/compiled.mjs");
  if (Array.isArray(mod.default)) LOCAL_KB = mod.default;
  console.log("[firas] local knowledge base: " + LOCAL_KB.length + " topics, " +
    LOCAL_KB.reduce((n, b) => n + (b.chunks ? b.chunks.length : 0), 0) + " entries");
} catch (e) { console.warn("[firas] local KB not loaded:", (e && e.message) || e); }

function kbList() { if (!Array.isArray(DB.kb)) DB.kb = []; return DB.kb; }
// Normalize Arabic (+ generic) for robust topic matching: strip harakat/tatweel,
// unify alef/ya/ta-marbuta, lowercase, keep letters/numbers.
function kbNorm(s) {
  return String(s || "")
    .replace(/[ً-ْـ]/g, "")
    .replace(/[آأإٱ]/g, "ا")
    .replace(/ى/g, "ي")
    .replace(/ة/g, "ه")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .replace(/\s+/g, " ").trim();
}
const KB_STOP = new Set("the a an of to in on for and or is are was were be this that با في من على عن الى إلى ما هو هي و أو ثم عند كل لا ان أن إن هذا هذه ذلك التي الذي مع شنو وش كيف بين الفرق ايه ماهي".split(/\s+/));
// Light Arabic stemming: strip the definite article ال (incl. after و/ف/ب/ك/لـ) so
// "الاحتمال"≈"احتمال" and "بالدستور"≈"دستور". Applied to query AND stored tokens
// symmetrically, so it only improves recall; never strips a bare consonant off a root.
function kbStem(t) {
  t = t.replace(/^(?:[وفبك]ال|لل)/, "");
  if (t.startsWith("ال") && t.length > 3) t = t.slice(2);
  return t;
}
/* keepDigits: admit single-character NUMERIC tokens ("3", "9"). Off by default so the admin
   KB / LOCAL_KB keep their exact existing recall; Firas Brain turns it on for both the corpus
   and the query (symmetric, so it can only add recall) because document questions hinge on
   bare numbers — "السؤال 3", "ماذا في صفحة 9" — which would otherwise be dropped entirely. */
function kbTokens(s, keepDigits) {
  return kbNorm(s).split(" ").map(kbStem).filter((t) => (t.length > 1 || (keepDigits && /^\d$/.test(t))) && !KB_STOP.has(t));
}
/* The sentence-packing splitter, parameterized. kbChunk keeps its exact original behavior
   (700-char budget, drop <25 chars, cap 4000); Firas Brain reuses the same algorithm per
   PAGE with a lower floor so a sparse scanned page still produces a citable chunk. */
function kbSplitText(text, maxLen, minLen) {
  const clean = String(text || "").replace(/\r/g, "").replace(/\n{2,}/g, "\n").trim();
  const parts = clean.split(/(?<=[.!?؟\n])\s+/);
  const chunks = []; let buf = "";
  for (const p of parts) {
    if ((buf + " " + p).length > maxLen && buf) { chunks.push(buf.trim()); buf = p; }
    else buf = (buf + " " + p).trim();
  }
  if (buf.trim()) chunks.push(buf.trim());
  return chunks.filter((c) => c.length > minLen);
}
function kbChunk(text) { return kbSplitText(text, 700, 25).slice(0, 4000); }
// Per-book token cache — kbTokens over every chunk of every book on EVERY chat request is
// O(total library chars) of regex work; with any-size books that blocks the event loop for
// hundreds of ms. Chunks are immutable after creation, so a WeakMap keyed by the book object
// needs no invalidation (deleted books get GC'd out).
const KB_TOK_CACHE = new WeakMap();
const KB_TOK_CACHE_D = new WeakMap();   // the keepDigits variant — MUST NOT share a cache with the
                                        // default one, or a book tokenized in one mode gets scored
                                        // against a query tokenized in the other, and the extra
                                        // tokens silently never match (caught by the unit check).
function kbBookTokens(book, keepDigits) {
  const cache = keepDigits ? KB_TOK_CACHE_D : KB_TOK_CACHE;
  let toks = cache.get(book);
  if (!toks) { toks = (book.chunks || []).map((ch) => kbTokens(chunkText(ch), keepDigits)); cache.set(book, toks); }
  return toks;
}
/* Score a query against an EXPLICIT corpus and return hits WITH provenance.
   Split out of kbSearch so Firas Brain can search one user's documents instead of the
   global admin library (kbSearch hardcoded `kbList().concat(LOCAL_KB)`, which for a
   per-user library would be a cross-tenant leak, not just a scoping bug).
   Chunks may be plain strings (admin books, LOCAL_KB) or `{ t, p, l }` records (Brain
   documents, where p = 1-based page/slide/sheet). chunkText() accepts both, so nothing
   already stored needs migrating.
   `minScore` filters BEFORE the top-k slice — the original sliced first, which silently
   shrank the result set instead of backfilling with the next-best passage. */
function chunkText(c) { return typeof c === "string" ? c : ((c && c.t) || ""); }
function chunkPage(c) { return (c && typeof c === "object" && Number.isFinite(c.p)) ? c.p : 0; }
function kbSearchIn(books, query, maxChunks, minScore, keepDigits) {
  const qt = kbTokens(query, keepDigits);
  if (!qt.length) return [];
  const qset = new Set(qt);
  const scored = [];
  for (const book of books) {
    const chunks = book.chunks || [];
    const toks = book._toks || kbBookTokens(book, keepDigits);
    for (let i = 0; i < chunks.length; i++) {
      const ct = toks[i];
      if (!ct || !ct.length) continue;
      let hits = 0; const matched = new Set();
      for (const t of ct) if (qset.has(t)) { hits++; matched.add(t); }
      if (!hits) continue;
      // Rank by DISTINCT query-term coverage; raw repeats are only log-dampened so a chunk
      // spamming one common word 20x can no longer outrank a chunk matching several terms.
      const cov = matched.size / qset.size;
      const score = cov * 2 + (matched.size + Math.log(1 + hits)) / Math.sqrt(ct.length + 5);
      if (score <= (minScore === undefined ? 0.25 : minScore)) continue;
      scored.push({
        score, text: chunkText(chunks[i]),
        docId: book.id || "", title: book.title || "", kind: book.kind || "", unit: book.unit || "page",
        page: chunkPage(chunks[i]), label: (chunks[i] && chunks[i].l) || "", ci: i,
      });
    }
  }
  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, maxChunks || 4);
}
function kbSearch(query, maxChunks) {
  // Search the admin's uploaded books AND the bundled local knowledge base.
  const books = LOCAL_KB.length ? kbList().concat(LOCAL_KB) : kbList();
  return kbSearchIn(books, query, maxChunks || 4, 0.25);
}
function kbContext(query) {
  const hits = kbSearch(query, 4);
  if (!hits.length) return "";
  return "REFERENCE MATERIAL (authoritative — use it to answer accurately and completely, then organize " +
    "the answer clearly. NEVER mention, quote, cite, or hint that this material or a book exists — just give " +
    "the polished answer as your own knowledge):\n" + hits.map((h, i) => (i + 1) + ". " + h.text).join("\n\n");
}
async function handleKbList(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "auth required" });
  if (!isAdmin(user)) return sendJson(res, 403, { error: "admins only" });
  return sendJson(res, 200, { books: kbList().map((b) => ({ id: b.id, title: b.title, chunks: (b.chunks || []).length, ts: b.ts })) });
}
async function handleKbAdd(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "auth required" });
  if (!isAdmin(user)) return sendJson(res, 403, { error: "admins only" });
  let p; try { p = JSON.parse((await readBody(req, 24_000_000)) || "{}"); } catch { return sendJson(res, 400, { error: "invalid JSON" }); }
  const title = String(p.title || "").slice(0, 200).trim() || "Untitled";
  const text = String(p.text || "");
  if (text.trim().length < 20) return sendJson(res, 400, { error: "text too short" });
  const chunks = kbChunk(text);
  if (!chunks.length) return sendJson(res, 400, { error: "no usable text" });
  const book = { id: "kb" + Date.now().toString(36) + Math.random().toString(36).slice(2, 6), title, chunks, ts: Date.now() };
  kbList().unshift(book);
  await persist();
  return sendJson(res, 200, { ok: true, id: book.id, title, chunks: chunks.length });
}
async function handleKbDelete(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "auth required" });
  if (!isAdmin(user)) return sendJson(res, 403, { error: "admins only" });
  const id = new URL(req.url, "http://localhost").searchParams.get("id");
  const list = kbList();
  const i = list.findIndex((b) => b.id === id);
  if (i >= 0) { list.splice(i, 1); await persist(); }
  return sendJson(res, 200, { ok: true });
}

/* ===========================================================================
   FIRAS BRAIN — the per-user document library (product #4).

   Answers are grounded ONLY in the signed-in user's own uploaded documents and every
   passage carries an exact page number, so a citation can be clicked and verified.
   Three deliberate departures from the admin KB above — do not "unify" them:

   1. STORAGE LIVES OUTSIDE `DB`. persist() re-serializes and rewrites the ENTIRE
      database on every chat message; data/db.json is already ~5MB, and a few 400-page
      libraries push it past 50MB → ~170ms of blocked event loop per message for every
      user (and a 50MB PUT per message in Firebase mode). One file/node per document
      keeps a write O(document) and leaves persist() completely untouched. This is also
      why nothing here needs registering in normalizeDb.
   2. CHUNKS ARE `{ t, p }`, CHUNKED PER PAGE. kbChunk on a flat document deletes the
      \n\n page separator on its first line and then cuts on a 700-char budget, so most
      chunks straddle two pages and a page number can only ever be a guess. Splitting
      inside one page makes the number exact by construction.
   3. THE CORPUS IS SCOPED TO ONE USER. kbSearch hardcodes the global library; reusing
      it here would make every user's documents readable by every other user.
   =========================================================================== */
const BRAIN_DIR = path.join(DATA_DIR, "brain");
const BRAIN_FB_ROOT = FB_KEY + "_brain";        // sibling of the monolithic DB key, never inside it
const BRAIN_MAX_DOCS = 20;                      // documents per user
const BRAIN_MAX_CHUNKS_PER_DOC = 12000;
const BRAIN_MAX_CHARS_PER_DOC = 8_000_000;
const BRAIN_MAX_PAGES_PER_REQ = 1200;
const BRAIN_BODY_LIMIT = 24_000_000;            // same ceiling handleKbAdd uses
const BRAIN_KINDS = new Set(["pdf", "docx", "pptx", "xlsx", "text", "image"]);
const BRAIN_UNITS = new Set(["page", "slide", "sheet", "section"]);
// Daily INGEST budget, in pages. Metered here because page OCR runs through /api/chat with
// nomem:true, which both backends deliberately exclude from quota charging — so without this
// a 400-page scan would fire 400 unmetered vision calls.
/* Unmetered like every other product — see PLAN_LIMITS. The daily page ceiling on Brain
   INGEST was the last per-member cap left, and a document library is exactly the thing a
   student hits it with. */
const BRAIN_PAGES_DAILY = { free: -1, gold: -1, diamond: -1, unlimited: -1 };

/* SITE-WIDE vision budget. The per-user budgets above meter fairness between users; this meters
   the resource they all draw from, which is a far smaller number than it looks.

   Page OCR goes to Gemini, and gemini-2.5-flash on the free tier allows 20 requests per DAY per
   key. With a 12-key pool that is 240 page-scans for the entire site per day — one 87-page book
   is 36% of it. Without this guard a single "free" user's 400-page allowance would be 167% of
   everything the site can serve, and once Gemini 429s the vision chain silently falls back to
   Ollama, quietly spending the weekly allowance there instead. Better to stop and say so.

   Deliberately in memory, not in DB: it is one small counter, and adding a top-level DB key means
   registering it in normalizeDb() or watching it vanish on restart. A restart re-grants the day's
   budget, which only ever over-grants — and Gemini's own 429 plus the escalating key cooldown is
   the real backstop underneath. */
const GEMINI_RPD_PER_KEY = Math.max(1, parseInt(process.env.GEMINI_RPD_PER_KEY, 10) || 500);
const BRAIN_VISION_DAILY = Math.max(0, parseInt(process.env.BRAIN_VISION_DAILY, 10) ||
                                       (GEMINI_KEYS.length * GEMINI_RPD_PER_KEY));
let _brainVision = { day: "", used: 0 };
function brainVisionLeft() {
  const today = serverDay();
  if (_brainVision.day !== today) _brainVision = { day: today, used: 0 };
  return Math.max(0, BRAIN_VISION_DAILY - _brainVision.used);
}
function brainVisionCharge(n) {
  brainVisionLeft();                       // rolls the day
  _brainVision.used += Math.max(0, Math.floor(Number(n) || 0));
}

function brainIdOk(s) { return /^[A-Za-z0-9_-]{1,64}$/.test(String(s || "")); }
function brainNewId() { return "bd" + Date.now().toString(36) + crypto.randomBytes(4).toString("hex"); }
/* Directory/node name for a user. Hashed rather than used raw so a user id can never
   escape BRAIN_DIR via path separators or dots, whatever shape ids take later. */
function brainUserKey(userId) { return crypto.createHash("sha1").update(String(userId)).digest("hex"); }

/* ---- storage: one document per file (disk) or per node (Firebase) ---- */
async function fbNodeGet(node) {
  const token = await fbAccessToken();
  const r = await fetch(FB_DB_URL + "/" + node + ".json", { headers: { Authorization: "Bearer " + token }, signal: AbortSignal.timeout(20_000) });
  if (!r.ok) throw new Error("firebase get " + r.status);
  return await r.json();
}
async function fbNodePut(node, value) {
  const token = await fbAccessToken();
  const r = await fetch(FB_DB_URL + "/" + node + ".json?print=silent", {
    method: "PUT",
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: JSON.stringify(value),
    signal: AbortSignal.timeout(40_000),
  });
  if (!r.ok) throw new Error("firebase put " + r.status + ": " + (await r.text()).slice(0, 160));
}

function brainMetaOf(doc) {
  return {
    id: doc.id, title: doc.title, kind: doc.kind, unit: doc.unit,
    pages: doc.pages || 0, indexed: doc.indexed || 0, ocr: doc.ocr || 0,
    chunks: (doc.chunks || []).length, chars: doc.chars || 0, ts: doc.ts || 0,
  };
}

async function brainLoadAll(userId) {
  const uk = brainUserKey(userId);
  const out = [];
  if (fbEnabled()) {
    let node = null;
    try { node = await fbNodeGet(BRAIN_FB_ROOT + "/" + uk); } catch (_) { node = null; }
    for (const d of (node ? Object.values(node) : [])) if (d && d.id) out.push(d);
  } else {
    const dir = path.join(BRAIN_DIR, uk);
    let names = [];
    try { names = await readdir(dir); } catch (_) { names = []; }
    for (const n of names) {
      if (!n.endsWith(".json")) continue;
      try {
        const d = JSON.parse(await readFile(path.join(dir, n), "utf8") || "null");
        if (d && d.id) out.push(d);
      } catch (_) {}
    }
  }
  out.sort((a, b) => (b.ts || 0) - (a.ts || 0));
  return out;
}

async function brainSaveDoc(userId, doc) {
  const uk = brainUserKey(userId);
  if (fbEnabled()) {
    await fbNodePut(BRAIN_FB_ROOT + "/" + uk + "/" + doc.id, doc);
  } else {
    const dir = path.join(BRAIN_DIR, uk);
    if (!existsSync(dir)) await mkdir(dir, { recursive: true });
    await writeFile(path.join(dir, doc.id + ".json"), JSON.stringify(doc));
  }
  brainCacheBust(userId);
}

/* Throws on a storage failure rather than swallowing it: a delete that silently didn't happen
   is reported to the user as done, and the document reappears on the next load. The edge twin
   behaves identically (502), so the shared client sees one contract. */
async function brainRemoveDoc(userId, docId) {
  const uk = brainUserKey(userId);
  try {
    if (fbEnabled()) await fbNodePut(BRAIN_FB_ROOT + "/" + uk + "/" + docId, null);
    else await rm(path.join(BRAIN_DIR, uk, docId + ".json"), { force: true });
  } finally { brainCacheBust(userId); }
}

/** Drop a whole user's library (account deletion). */
async function brainRemoveUser(userId) {
  const uk = brainUserKey(userId);
  if (fbEnabled()) {
    try { await fbNodePut(BRAIN_FB_ROOT + "/" + uk, null); } catch (_) {}
  } else {
    try { await rm(path.join(BRAIN_DIR, uk), { recursive: true, force: true }); } catch (_) {}
  }
  brainCacheBust(userId);
}

/* Per-USER retrieval cache. Deliberately NOT the shared KB cache: that one is module-scope
   and unkeyed, so reusing it would serve one user's documents to the next caller. Chunks are
   pre-tokenized once per load, since tokenizing a whole library per query is the expensive part. */
const _brainCache = new Map();   // userId → { at, docs }
const BRAIN_CACHE_TTL = 60_000;
function brainCacheBust(userId) { _brainCache.delete(String(userId)); }
async function brainCorpus(userId) {
  const key = String(userId);
  const hit = _brainCache.get(key);
  if (hit && Date.now() - hit.at < BRAIN_CACHE_TTL) return hit.docs;
  const docs = await brainLoadAll(userId);
  for (const d of docs) d._toks = (d.chunks || []).map((c) => kbTokens(chunkText(c), true));
  if (_brainCache.size > 40) { for (const k of _brainCache.keys()) { _brainCache.delete(k); if (_brainCache.size <= 20) break; } }
  _brainCache.set(key, { at: Date.now(), docs });
  return docs;
}

/* Representative excerpts spanning the WHOLE selection, for questions that have no keywords to
   match on ("اشرح لي السلايدات", "summarize this", "وش موضوع الملف"). Lexical retrieval scores
   these at zero — the words simply are not in the document — so without this the product answers
   its single most common question with "I couldn't find anything", which reads as "it never read
   my file". Under the budget the whole document goes in; over it, an even stride keeps the sample
   spread from first page to last instead of front-loading the opening pages. */
const BRAIN_OVERVIEW_CHARS = 48_000;
function brainOverviewHits(docs, budget) {
  const flat = [];
  for (const d of docs) {
    const chunks = d.chunks || [];
    for (let i = 0; i < chunks.length; i++) {
      flat.push({
        score: 0, text: chunkText(chunks[i]),
        docId: d.id || "", title: d.title || "", kind: d.kind || "", unit: d.unit || "page",
        page: chunkPage(chunks[i]), label: (chunks[i] && chunks[i].l) || "", ci: i,
      });
    }
  }
  const total = flat.reduce((n, h) => n + h.text.length, 0);
  const cap = budget || BRAIN_OVERVIEW_CHARS;
  if (total <= cap) return flat;
  // Stride picks the spacing; the running total is what actually enforces the cap. Deriving the
  // count from the stride alone overshoots by a few chunks on uneven documents, and this budget
  // is a context-window guard, so it has to be hard rather than approximate.
  const stride = Math.ceil(total / cap);
  const out = [];
  let used = 0;
  for (let i = 0; i < flat.length; i += stride) {
    const len = flat[i].text.length;
    if (used + len > cap) break;
    out.push(flat[i]); used += len;
  }
  return out.length ? out : [flat[0]];
}

/* Pull in each hit's NEIGHBOURING chunks as hits in their own right.

   Textbooks put the question on one page and its answer on the next: "التمرين الثاني" sits on
   p.78 while the الجواب table is on p.79, and p.79 contains none of the question's words. Pure
   chunk-level lexical scoring can therefore never reach the answer — measured on the real
   document, a query for "حل التمرين الثاني من موضوع التوكيد" scored p.73/50/45 and missed p.79
   entirely. The same applies to any table split across a page break, or a definition followed by
   its example.

   Neighbours are returned as SEPARATE hits carrying their OWN page and ci, not merged into the
   matched chunk's text — otherwise the answer would be cited to the page the question was on. */
function brainExpandNeighbours(hits, docs, radius, cap) {
  if (!hits.length) return hits;
  const byId = new Map(docs.map((d) => [d.id, d]));
  const seen = new Set(hits.map((h) => h.docId + "#" + h.ci));
  const out = hits.slice();
  const limit = cap || 24;
  // Offsets are applied in PASSES across all hits, nearest first and forward before backward:
  // +1, -1, +2, -2. Walking each hit's full radius before moving to the next would let the first
  // hit's distant neighbours consume the cap and starve the later hits entirely. Forward reaches
  // further than backward because a heading is followed by its answer, not preceded by it —
  // measured on the real textbook, the "التمرين الثاني" match is on p.78 and the الجواب table is
  // TWO chunks later, so a symmetric radius of 1 lands one chunk short of it.
  // ALL forward offsets before any backward one: an answer follows its question, so +2 is worth
  // more than -1. Interleaving them let the backward pass exhaust the cap before +2 ever ran,
  // which left the retrieval one chunk short of the الجواب table on the real textbook.
  const r = Math.max(1, radius || 2);
  const passes = [];
  for (let d = 1; d <= r; d++) passes.push(d);
  for (let d = 1; d <= r; d++) passes.push(-d);
  for (const d of passes) {
    for (const h of hits) {
      const doc = byId.get(h.docId);
      if (!doc) continue;
      const chunks = doc.chunks || [];
      const i = h.ci + d;
      if (i < 0 || i >= chunks.length) continue;
      const key = h.docId + "#" + i;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({
        // Strictly below every genuine match, and decaying with distance.
        score: h.score * (d > 0 ? 0.30 : 0.22) / Math.abs(d),
        text: chunkText(chunks[i]),
        docId: doc.id, title: doc.title || "", kind: doc.kind || "", unit: doc.unit || "page",
        page: chunkPage(chunks[i]), label: (chunks[i] && chunks[i].l) || "", ci: i, near: true,
      });
      if (out.length >= limit) return out;
    }
  }
  return out;
}

/* Pack a page into ~700-char chunks on LINE boundaries. kbSplitText's `(?<=[.!?؟\n])\s+` only
   fires when a newline is FOLLOWED by more whitespace, so a bare "\n" between a slide title and
   its bullets is not a boundary at all: measured, a 13-bullet slide lands as ONE 1115-char chunk,
   59% over the budget the rest of the pipeline is built around. Slide text is lines, not
   sentences, so pack lines, and fall back to the sentence splitter for any single line longer
   than the budget on its own. Used for .pptx ONLY — a PDF or .docx page is prose whose wrapped
   lines are not semantic boundaries, and those keep the sentence packer untouched. */
function brainSplitLines(text) {
  const lines = String(text || "").split("\n").map((s) => s.trim()).filter(Boolean);
  const out = [];
  let buf = "";
  for (const line of lines) {
    for (const piece of (line.length > 700 ? kbSplitText(line, 700, 12) : [line])) {
      if (buf && (buf.length + 1 + piece.length) > 700) { out.push(buf); buf = piece; }
      else buf = buf ? (buf + "\n" + piece) : piece;
    }
  }
  if (buf) out.push(buf);
  return out.filter((c) => c.length > 12);
}
/** Chunk a document PAGE BY PAGE so every chunk's page number is exact by construction. */
function brainChunkPages(pages, byLine) {
  const out = [];
  for (const pg of pages) {
    const p = Math.max(1, Math.floor(Number(pg && pg.p) || 0));
    const label = String((pg && pg.l) || "").slice(0, 80);
    // minLen 12, not kbChunk's 25: a sparse or freshly-OCR'd page can legitimately hold one
    // short line, and dropping it would punch a hole in the citable page range.
    const parts = byLine ? brainSplitLines(pg && pg.text) : kbSplitText(pg && pg.text, 700, 12);
    /* A page whose ENTIRE text is under that floor produced nothing at all, so the page was
       absent from the index: not searchable, not citable, and invisible to "extract every
       definition". A slide titled only "Ribosome", a section divider, a figure page with a
       three-word caption — all silently gone. Whatever the floor is for, it must not be able
       to delete a page that genuinely has text on it. */
    const text = String((pg && pg.text) || "").trim();
    if (!parts.length && text) parts.push(text);
    for (const t of parts) {
      const c = { t, p };
      if (label) c.l = label;
      out.push(c);
    }
  }
  return out;
}

/* ---- request plumbing ---- */
/* Firas Brain is open to GUESTS as well as members. A guest is identified by the same signed
   firas_guest cookie the rest of the trial uses, and their library is stored server-side under
   that id exactly like a member's — brainUserKey() hashes whatever id it is given, so the two
   namespaces cannot collide and a guest id can never escape BRAIN_DIR.
   Two honest consequences, both bounded below rather than hidden:
     - the cookie IS the account. Clearing cookies, or switching browser/device, loses the
       library. There is no way to recover it, because there is nothing else to key it to.
     - guest libraries are pruned after BRAIN_GUEST_TTL_DAYS of inactivity, otherwise abandoned
       trials would accumulate documents on disk forever. */
const BRAIN_GUEST_TTL_DAYS = 14;          // > the 7-day guest cookie, so an active trial is never cut short
const BRAIN_GUEST_MAX_DOCS = 3;
const BRAIN_GUEST_PAGES_DAILY = 120;
function brainCaller(req, res) {
  const c = callerOf(req);
  if (!c.id) { sendJson(res, 403, { error: "signin_required", feature: "brain" }); return null; }
  return c;                                // { user, id, isGuest }
}
function brainDocLimit(c) { return c.isGuest ? BRAIN_GUEST_MAX_DOCS : BRAIN_MAX_DOCS; }
function brainPagesLimit(c) {
  if (c.isGuest) return BRAIN_GUEST_PAGES_DAILY;
  const l = BRAIN_PAGES_DAILY[planOf(c.user)];
  return l === undefined ? BRAIN_PAGES_DAILY.free : l;
}
/* Daily counters for a guest live on the same DB.guests record the other trial products use, so
   they roll over and get pruned by the existing machinery instead of a parallel one. */
function brainChargePages(c, n) {
  const limit = brainPagesLimit(c);
  if (limit < 0) return null;
  if (c.isGuest) {
    const g = guestRecord(c.id);
    if ((g.brainPages || 0) + n > limit) return { used: g.brainPages || 0, max: limit };
    g.brainPages = (g.brainPages || 0) + n;
    return null;
  }
  quotaRollDay(c.user);
  const used = c.user.quota.brainPages || 0;
  if (used + n > limit) return { used, max: limit };
  c.user.quota.brainPages = used + n;
  return null;
}
/** Drop guest libraries that have gone quiet, so abandoned trials cannot pile up on disk. */
async function brainSweepGuests() {
  if (fbEnabled()) return;                 // RTDB listing is a whole-subtree read; not worth it here
  const cutoff = Date.now() - BRAIN_GUEST_TTL_DAYS * 86400000;
  let dirs = [];
  try { dirs = await readdir(BRAIN_DIR); } catch (_) { return; }
  for (const dir of dirs) {
    try {
      const full = path.join(BRAIN_DIR, dir);
      const names = await readdir(full);
      let newest = 0, guest = false;
      for (const n of names) {
        if (!n.endsWith(".json")) continue;
        const doc = JSON.parse(await readFile(path.join(full, n), "utf8") || "null");
        if (!doc) continue;
        if (doc.guest) guest = true;
        newest = Math.max(newest, doc.ts || 0);
      }
      if (guest && newest && newest < cutoff) await rm(full, { recursive: true, force: true });
    } catch (_) {}
  }
}

async function handleBrainDocs(req, res) {
  const c = brainCaller(req, res); if (!c) return;
  const docs = await brainLoadAll(c.id);
  const today = serverDay();
  const pagesToday = c.isGuest
    ? (guestRecord(c.id).brainPages || 0)
    : (c.user.quota && c.user.quota.day === today ? (c.user.quota.brainPages || 0) : 0);
  return sendJson(res, 200, {
    docs: docs.map(brainMetaOf),
    guest: !!c.isGuest,
    limits: { docs: brainDocLimit(c), pagesPerDay: brainPagesLimit(c), visionLeft: brainVisionLeft() },
    used: { docs: docs.length, pagesToday },
  });
}

async function handleBrainDocAdd(req, res) {
  const c = brainCaller(req, res); if (!c) return;
  if (rateLimited("brain:add:" + c.id, 60, 60_000)) return sendJson(res, 429, { error: "too many requests" });
  let p;
  try { p = JSON.parse((await readBody(req, BRAIN_BODY_LIMIT)) || "{}"); }
  catch { return sendJson(res, 413, { error: "too_large" }); }   // readBody destroys the request past the cap

  const title = String(p.title || "").slice(0, 200).trim() || "Untitled";
  const kind = BRAIN_KINDS.has(p.kind) ? p.kind : "text";
  const unit = BRAIN_UNITS.has(p.unit) ? p.unit : "page";
  const pages = Array.isArray(p.pages) ? p.pages : [];
  if (!pages.length) return sendJson(res, 400, { error: "no pages" });
  if (pages.length > BRAIN_MAX_PAGES_PER_REQ) return sendJson(res, 413, { error: "too_large" });

  const existing = await brainLoadAll(c.id);
  // A continuation part carries the docId minted by part 1; a fresh upload does not.
  let doc = null;
  if (p.docId) {
    if (!brainIdOk(p.docId)) return sendJson(res, 400, { error: "invalid id" });
    doc = existing.find((d) => d.id === p.docId) || null;
    if (!doc) return sendJson(res, 404, { error: "not found" });
  } else if (existing.length >= brainDocLimit(c)) {
    return sendJson(res, 429, { error: "limit", limit: "docs", max: brainDocLimit(c) });
  }

  /* Meter the INGEST by DISTINCT PAGE, per day — for guests as well as members.

     This used to charge `pages.length`, the number of RECORDS in the POST. That was the same
     number for every producer until the spreadsheet reader began emitting one record per row
     group instead of one per sheet: a 5,000-row sheet went from 1 record to 556, which a guest
     (120/day) and a free user (400/day) would hit as a hard 429 on a file that used to upload
     fine. The citable unit is the page/slide/sheet, and that is what is charged.

     For every other producer — PDF, .docx, .pptx, images, text — there is exactly one record
     per page, so seen.size === pages.length and the charge is unchanged to the unit.
     BRAIN_MAX_PAGES_PER_REQ above still bounds `pages.length`: that one IS a record ceiling,
     protecting the request body rather than the quota. */
  const seen = new Set(pages.map((pg) => Math.max(1, Math.floor(Number(pg && pg.p) || 0))));
  const denied = brainChargePages(c, seen.size);
  if (denied) return sendJson(res, 429, { error: "limit", limit: "pages", used: denied.used, max: denied.max, guest: !!c.isGuest });
  await persist();

  const added = brainChunkPages(pages, kind === "pptx");
  const addedChars = added.reduce((n, c) => n + c.t.length, 0);
  const indexedNow = new Set(added.map((c) => c.p)).size;

  if (!doc) {
    doc = { id: brainNewId(), title, kind, unit, pages: 0, indexed: 0, ocr: 0, chars: 0, ts: Date.now(), chunks: [] };
    if (c.isGuest) doc.guest = true;   // lets brainSweepGuests() reclaim abandoned trials
  }
  if ((doc.chunks.length + added.length) > BRAIN_MAX_CHUNKS_PER_DOC) return sendJson(res, 413, { error: "too_large", limit: "chunks" });
  if ((doc.chars || 0) + addedChars > BRAIN_MAX_CHARS_PER_DOC) return sendJson(res, 413, { error: "too_large", limit: "chars" });

  doc.chunks = doc.chunks.concat(added);
  doc.pages = (doc.pages || 0) + seen.size;
  doc.indexed = (doc.indexed || 0) + indexedNow;
  doc.chars = (doc.chars || 0) + addedChars;
  const ocrAdded = Math.max(0, Math.floor(Number(p.ocr) || 0));
  doc.ocr = (doc.ocr || 0) + ocrAdded;
  if (ocrAdded) brainVisionCharge(ocrAdded);   // site-wide Gemini budget, not just this user's
  doc.ts = Date.now();
  await brainSaveDoc(c.id, doc);

  return sendJson(res, 200, { ok: true, id: doc.id, title: doc.title, chunks: added.length, total: doc.chunks.length, doc: brainMetaOf(doc) });
}

async function handleBrainDocDelete(req, res) {
  const c = brainCaller(req, res); if (!c) return;
  const id = new URL(req.url, "http://localhost").searchParams.get("id") || "";
  if (!brainIdOk(id)) return sendJson(res, 400, { error: "invalid id" });
  try { await brainRemoveDoc(c.id, id); } catch (_) { return sendJson(res, 502, { error: "storage failed" }); }
  return sendJson(res, 200, { ok: true });
}

async function handleBrainSearch(req, res) {
  const c = brainCaller(req, res); if (!c) return;
  if (rateLimited("brain:q:" + c.id, 120, 60_000)) return sendJson(res, 429, { error: "too many requests" });
  // readBody REJECTS past the cap and readJson does not catch it, so without this an oversize
  // body would surface as a generic 500 here while the edge answers 413.
  let p;
  try { p = (await readJson(req, 200_000)) || {}; } catch (_) { return sendJson(res, 413, { error: "too_large" }); }
  const q = String(p.q || "").slice(0, 4000);
  const k = Math.min(Math.max(parseInt(p.k, 10) || 8, 1), 12);
  const want = Array.isArray(p.docIds) ? p.docIds.filter(brainIdOk) : [];

  // THE per-answer charge for Firas Brain. It has to happen here, not on /api/chat: the answer
  // itself streams through callAgentText/streamAgentText with nomem:true, which both backends
  // deliberately exclude from quota charging. Exactly one search precedes each answer, and the
  // cid makes a retry of the same turn idempotent (same rule as the other products).
  const cid = String(p.cid || "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64);
  if (c.isGuest) {
    // guestCharge already owns the roll-over, idempotency and 429 shape for trial products.
    const denied = guestChargeWithReq(req, c.id, "brain", cid);
    if (denied) return sendJson(res, 429, denied);
  } else {
    const blimit = limitsFor(planOf(c.user)).brain;
    if (blimit >= 0) {
      quotaRollDay(c.user);
      const bq = c.user.quota;
      const already = cid && bq.last.brain === cid;
      if (!already && (bq.brain || 0) >= blimit) {
        return sendJson(res, 429, { error: "daily quota reached", quota: { product: "brain", used: bq.brain || 0, limit: blimit, plan: planOf(c.user) } });
      }
      if (!already) { bq.brain = (bq.brain || 0) + 1; if (cid) bq.last.brain = cid; await persist(); }
    }
  }
  let docs = await brainCorpus(c.id);
  if (want.length) { const s = new Set(want); docs = docs.filter((d) => s.has(d.id)); }
  if (!docs.length) return sendJson(res, 200, { hits: [], docs: 0, mode: "none" });
  if (p.mode === "all") {
    // HARVEST: hand back the corpus in document order, paged. "Extract every definition"
    // cannot be served by top-k retrieval — the answer is not "the 8 best matches", it is
    // every occurrence in the book — so the client sweeps the whole thing in batches instead.
    const off = Math.max(0, parseInt(p.offset, 10) || 0);
    const lim = Math.min(Math.max(parseInt(p.limit, 10) || 400, 1), 1500);
    const flat = [];
    for (const d of docs) {
      const ch = d.chunks || [];
      for (let i = 0; i < ch.length; i++) {
        flat.push({
          score: 0, text: chunkText(ch[i]),
          docId: d.id || "", title: d.title || "", kind: d.kind || "", unit: d.unit || "page",
          page: chunkPage(ch[i]), label: (ch[i] && ch[i].l) || "", ci: i,
        });
      }
    }
    return sendJson(res, 200, { hits: flat.slice(off, off + lim), total: flat.length, offset: off, mode: "all" });
  }
  if (p.mode === "overview") {
    return sendJson(res, 200, { hits: brainOverviewHits(docs), docs: docs.length, mode: "overview" });
  }
  // A lower floor than the admin KB's 0.25: this corpus is the user's OWN documents, where a
  // single strong term match is a legitimate lead rather than noise from an unrelated book.
  const hits = brainExpandNeighbours(kbSearchIn(docs, q, k, 0.18, true), docs, 2, k + 20);
  return sendJson(res, 200, { hits, docs: docs.length, mode: "search" });
}

async function handleBrainPassage(req, res) {
  const c = brainCaller(req, res); if (!c) return;
  const url = new URL(req.url, "http://localhost");
  const docId = url.searchParams.get("doc") || "";
  const ci = parseInt(url.searchParams.get("i"), 10);
  const w = Math.min(Math.max(parseInt(url.searchParams.get("w"), 10) || 2, 0), 5);
  if (!brainIdOk(docId) || !Number.isFinite(ci) || ci < 0) return sendJson(res, 400, { error: "invalid id" });
  const docs = await brainCorpus(c.id);
  const doc = docs.find((d) => d.id === docId);
  if (!doc) return sendJson(res, 404, { error: "not found" });
  const chunks = doc.chunks || [];
  const hit = chunks[ci];
  if (!hit) return sendJson(res, 404, { error: "not found" });
  const page = chunkPage(hit);
  // Neighbours are restricted to the SAME page — the point of the reader is to show the cited
  // passage in its page context, not to bleed into a page the citation never claimed.
  const near = (from, to, step) => {
    const out = [];
    for (let i = from; i !== to && out.length < w; i += step) {
      if (!chunks[i] || chunkPage(chunks[i]) !== page) break;
      out.push({ ci: i, t: chunkText(chunks[i]) });
    }
    return step < 0 ? out.reverse() : out;
  };
  return sendJson(res, 200, {
    docId: doc.id, title: doc.title, kind: doc.kind, unit: doc.unit,
    page, label: (hit && hit.l) || "", ci, text: chunkText(hit),
    before: near(ci - 1, -1, -1), after: near(ci + 1, chunks.length, 1),
  });
}

/* ── Public share links: snapshot a chat → read-only page at /?share=<id> ── */
function sharesMap() { if (!DB.shares || typeof DB.shares !== "object") DB.shares = {}; return DB.shares; }
/* Shares live in the monolithic db.json, and every write re-serialises the WHOLE database.
   A snapshot can be 400 messages x 200,000 chars plus 10 thumbnails at 200,000 each, this
   endpoint had no rate limit and no per-user cap, and nothing ever pruned DB.shares. So a
   logged-in user could build one large chat and loop POST /api/share: each call appended
   megabytes AND triggered a full re-serialise, until every ordinary chat message stalled
   the event loop for seconds and the volume filled. persist() swallows its write error, so
   the app would keep reporting success while no longer saving anything — and db.json has
   no backup. Three bounds, cheapest first. */
const SHARES_PER_USER_MAX = 20;
async function handleShareCreate(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "auth required" });
  if (rateLimited("share:" + user.id, 5, 60_000)) return sendJson(res, 429, { error: "too many requests" });
  let p; try { p = JSON.parse((await readBody(req)) || "{}"); } catch { return sendJson(res, 400, { error: "invalid JSON" }); }
  const chat = DB.chats.find((c) => c.id === String(p.chatId || "") && c.userId === user.id);
  if (!chat) return sendJson(res, 404, { error: "not found" });
  /* Re-share of the SAME chat reuses its snapshot instead of minting a new one. This is
     also the common real case — pressing Share twice — so it removes most of the growth
     before the cap is ever consulted. */
  const shares = sharesMap();
  const existing = Object.values(shares).find((s) => s && s.owner === user.id && s.chatId === chat.id);
  if (existing) {
    existing.ts = Date.now();
    await persist();
    return sendJson(res, 200, { ok: true, id: existing.id });
  }
  const mine = Object.values(shares).filter((s) => s && s.owner === user.id);
  if (mine.length >= SHARES_PER_USER_MAX) {
    return sendJson(res, 409, { error: "لقد وصلت إلى الحد الأقصى للمشاركات (" + SHARES_PER_USER_MAX + "). احذف مشاركة قديمة أولاً." });
  }
  const id = "s" + Date.now().toString(36) + crypto.randomBytes(5).toString("hex");
  const msgs = (chat.messages || []).slice(0, 400).map((m) => {
    const o = { role: m.role === "assistant" ? "assistant" : "user", content: String(m.content || "").slice(0, 200000) };
    if (m.lang) o.lang = String(m.lang).slice(0, 8);
    if (m.tier) o.tier = String(m.tier).slice(0, 16);
    if (Array.isArray(m.imageThumbs) && m.imageThumbs.length) o.imageThumbs = m.imageThumbs.slice(0, 10).map((s) => String(s).slice(0, 200000));
    return o;
  });
  // chatId is recorded so a repeat share of the same chat reuses this snapshot (above)
  // rather than minting another multi-megabyte copy.
  shares[id] = { id, chatId: chat.id, title: String(chat.title || "").slice(0, 200), messages: msgs, ts: Date.now(), owner: user.id };
  await persist();
  return sendJson(res, 200, { ok: true, id });
}
function handleShareGet(req, res) {   // PUBLIC — no auth by design
  const id = String(new URL(req.url, "http://localhost").searchParams.get("id") || "").replace(/[^a-zA-Z0-9]/g, "");
  const snap = id ? sharesMap()[id] : null;
  if (!snap) return sendJson(res, 404, { error: "not found" });
  return sendJson(res, 200, { id: snap.id, title: snap.title || "", messages: snap.messages || [], ts: snap.ts || 0 });
}
async function handleShareDelete(req, res) {
  const user = currentUser(req);
  if (!user) return sendJson(res, 401, { error: "auth required" });
  const id = String(new URL(req.url, "http://localhost").searchParams.get("id") || "").replace(/[^a-zA-Z0-9]/g, "");
  const snap = id ? sharesMap()[id] : null;
  if (snap && snap.owner !== user.id && !isAdmin(user)) return sendJson(res, 403, { error: "not yours" });
  if (snap) { delete sharesMap()[id]; await persist(); }
  return sendJson(res, 200, { ok: true });
}

async function handleChat(req, res) {
  // AUTH REQUIRED — or a valid GUEST trial cookie (smaller daily quota, no memory).
  const caller = callerOf(req);
  const user = caller.user || null;
  const guestId = caller.isGuest ? caller.id : "";
  if (!user && !guestId) {
    return sendJson(res, 401, { error: "authentication required" });
  }

  // Per-caller rate limit: the AI stream is by far the most expensive endpoint (it
  // burns upstream Ollama/Gemini/Claude credits on every call). Auth alone is not
  // enough — one logged-in account could hammer it and drain quota/bills. The cap
  // is generous so the Firas Agent multi-step pipeline still flows normally;
  // guests get a much tighter cap since the identity is free to mint.
  if (rateLimited("chat:" + caller.id, guestId ? 30 : 120, 60_000)) {
    return sendJson(res, 429, { error: "too many requests, please slow down" });
  }

  let payload;
  try {
    // Raise the body limit for /api/chat ONLY so image payloads fit.
    payload = JSON.parse((await readBody(req, CHAT_BODY_LIMIT)) || "{}");
  } catch {
    return sendJson(res, 400, { error: "invalid JSON body" });
  }

  const messages = Array.isArray(payload.messages) ? payload.messages : [];
  const tier = TIERS[payload.tier] ? payload.tier : "pro";

  if (!messages.length) {
    return sendJson(res, 400, { error: 'body must include a non-empty "messages" array' });
  }

  // KNOWLEDGE BASE: silently ground the answer in the bundled local corpus AND the admin's
  // uploaded books. Find the last user TEXT question, retrieve relevant passages, inject as hidden context.
  // SKIPPED for (a) internal helper calls — nomem:true, e.g. auto-title, the file pipeline and Brain's
  // page OCR: injecting unrelated reference passages there poisons a verbatim transcription and burns
  // tokens on every page (the edge already guards on nomem; this restores parity), and (b) Firas Brain
  // turns, whose whole contract is "answer from THESE sources and cite them" — kbContext's preamble says
  // the exact opposite ("NEVER mention, quote, cite, or hint that this material exists") and would both
  // contradict the citation instruction and smuggle in passages the user never uploaded.
  /* ── KB INJECTION DISABLED FOR PLAIN CHAT ────────────────────────────────────────────
     This spliced the bundled knowledge base in as a system message headed "REFERENCE
     MATERIAL (authoritative — use it to answer accurately and completely)". Retrieval
     returns whatever four chunks best match the wording, and "authoritative" then made the
     model treat those four chunks as the BOUNDARY of what it knows.

     Observed: "اعطني 10 تكاملات صعبة" retrieved a few basic-integral entries from the
     bundled math corpus and the reply was "المادة المرجعية المتوفرة لدي تحتوي على تكاملات
     أساسية فقط… لا تشتمل على أمثلة لتكاملات صعبة" — the model refusing to use its own
     knowledge because a snippet told it what its knowledge was. A retrieval corpus is a
     floor for facts it happens to contain; framed this way it became a ceiling on
     everything else, and on a general assistant that trade is plainly bad.

     KB_IN_CHAT re-enables it if that judgement ever needs revisiting. The admin library and
     its routes are untouched, and Firas Brain — whose entire contract IS "answer from these
     sources and cite them" — was already excluded here and still is. */
  const KB_IN_CHAT = process.env.KB_IN_CHAT === "1";
  if (KB_IN_CHAT && !payload.nomem && payload.product !== "brain" && (kbList().length || LOCAL_KB.length)) {
    try {
      let li = -1;
      for (let i = messages.length - 1; i >= 0; i--) if (messages[i] && messages[i].role === "user") { li = i; break; }
      if (li >= 0 && typeof messages[li].content === "string") {
        const ctx = kbContext(messages[li].content);
        if (ctx) messages.splice(li, 0, { role: "system", content: ctx });   // right before the question
      }
    } catch (_) {}
  }

  // Capped tier (Max): enforce the per-user daily limit and charge one slot per
  // distinct request id (idempotent on retry of the same cid).
  if (user && TIERS[tier] && TIERS[tier].capped) {
    maxRollDay(user);
    let cid = String(payload.cid || "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64);
    const isNew = !cid || !user.maxCids.includes(cid);
    if (MAX_DAILY_LIMIT >= 0 && isNew && user.maxCids.length >= MAX_DAILY_LIMIT) {
      return sendJson(res, 429, { error: "daily Max limit reached", limit: MAX_DAILY_LIMIT, used: user.maxCids.length, remaining: 0 });
    }
    if (isNew) { user.maxCids.push(cid || ("r" + Date.now())); persist(); }
  }

  // PER-PRODUCT DAILY QUOTA (Firas AI / Code / Agent) by subscription plan.
  // ai/code count per message; agent counts per MISSION (a stable cid spans the
  // mission's internal calls). diamond/unlimited (-1) skip the cap entirely.
  // nomem=true marks INTERNAL helper calls (auto-title, file pipeline, agent steps,
  // prompt-enhance) — those are never charged; only real user turns count.
  /* INTERNAL CALLS ARE STILL CALLS.
     `nomem` is a plain JSON boolean the browser sends, and it used to skip BOTH charging
     branches outright. So `{"messages":[…],"tier":"max","nomem":true}` from devtools bought
     unlimited completions on any plan: the free tier's 100/day, the guest's allowance, and
     every entitlement sold through /api/redeem all evaporated, while the model still streamed
     a full answer. The only remaining brake was a 120/min rate limit.

     It cannot simply be charged as a normal turn — these really are sub-steps of one user
     action (auto-title, the Code build pipeline, agent steps, OCR), and a single build fires
     a dozen of them. Charging each would break legitimate use.

     So they now draw on their OWN generous-but-bounded budget. Real usage sits far under it;
     abuse hits a ceiling instead of running forever. The proper long-term fix is a
     server-signed internal token minted by the endpoint that already charged — recorded in
     SUGGESTIONS.md — but this closes the unlimited hole without touching any working flow. */
  if (payload.nomem && user) {
    quotaRollDay(user);
    const q = user.quota;
    const cap = limitsFor(planOf(user)).internal;
    if (cap >= 0) {
      if ((q.internal || 0) >= cap) {
        return sendJson(res, 429, { error: "daily quota reached", quota: { product: "internal", used: q.internal || 0, limit: cap, plan: planOf(user) } });
      }
      q.internal = (q.internal || 0) + 1;
      persist();
    }
  }
  if (payload.nomem && guestId) {
    const denied = guestChargeWithReq(req, guestId, "internal", payload.cid);
    if (denied) return sendJson(res, 429, denied);
  }
  if (!payload.nomem && guestId) {
    // GUEST trial quota — same idempotency rules, much smaller allowance.
    const product = (payload.product === "code" || payload.product === "agent") ? payload.product : "ai";
    const denied = guestChargeWithReq(req, guestId, product, payload.cid, payload.messages);
    if (denied) return sendJson(res, 429, denied);
  }
  if (!payload.nomem && user) {
    // "brain" is member-only, so it is NOT added to the guest coercion above — a guest sending
    // product:"brain" correctly falls through to the "ai" bucket.
    const product = (payload.product === "code" || payload.product === "agent" || payload.product === "brain") ? payload.product : "ai";
    const qlimit = limitsFor(planOf(user))[product];
    if (qlimit >= 0) {
      quotaRollDay(user);
      const q = user.quota;
      const qcid = String(payload.cid || "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64);
      const already = isRepeatCharge(q, product, qcid, payload.messages);
      if (!already && (q[product] || 0) >= qlimit) {
        return sendJson(res, 429, { error: "daily quota reached", quota: { product, used: q[product] || 0, limit: qlimit, plan: planOf(user) } });
      }
      if (!already) {
        q[product] = (q[product] || 0) + 1;
        if (product === "agent") { if (qcid) { q.agentCids.push(qcid); if (q.agentCids.length > 500) q.agentCids.shift(); } }
        else if (qcid) { q.last[product] = qcid; }
        persist();
      }
    }
  }

  // PERSISTENT MEMORY: inject what we know about this user as a system message
  // (right after the first system message) so every reply is personalized.
  // nomem=true on internal agent calls (file/PDF generation, prompt-enhance, batches)
  // so personal facts NEVER leak into generated documents — memory is for CHAT only.
  // Guests have no stored memory (nothing is kept for them) → never inject.
  const memBlk = (payload.nomem || !user) ? "" : memoryBlock(user);
  if (memBlk) {
    // Merge memory INTO the first system message (not a separate one) — some models
    // (e.g. the coder model on Ultra) ignore a second system message.
    const sysIdx = messages.findIndex((m) => m && m.role === "system");
    if (sysIdx >= 0) messages[sysIdx] = { role: "system", content: String(messages[sysIdx].content || "") + "\n\n" + memBlk };
    else messages.unshift({ role: "system", content: memBlk });
  }

  // VISION DETECTION: any message carrying a non-empty images array routes to
  // the vision model with think forced OFF and RAW base64 images attached.
  const vision = hasImages(messages);
  const think = vision ? false : !!payload.think;
  const ollamaMessages = vision ? buildVisionMessages(messages) : stripImages(messages);
  const modelOverride = vision ? OLLAMA_MODEL_VISION : undefined;

  /* Never hang, but never cut a live answer either: the clock measures SILENCE, and every
     chunk sseWrite emits rearms it. A runaway is still bounded by UPSTREAM_MAX_MS. */
  const ac = new AbortController();
  const startedAt = Date.now();
  let idleTimer = setTimeout(() => ac.abort("idle"), UPSTREAM_IDLE_MS);
  const hardTimer = setTimeout(() => ac.abort("max"), UPSTREAM_MAX_MS);
  res._keepAlive = () => {
    if (res.writableEnded) return;
    clearTimeout(idleTimer);
    if (Date.now() - startedAt >= UPSTREAM_MAX_MS) return;
    idleTimer = setTimeout(() => ac.abort("idle"), UPSTREAM_IDLE_MS);
  };
  const clearDeadlines = () => { clearTimeout(idleTimer); clearTimeout(hardTimer); };
  res.on("close", () => { clearDeadlines(); ac.abort(); });
  res.on("error", () => {});

  sseInit(res);
  // Backtrack scrubbing runs ONLY on the plain Firas-AI chat product — never on Firas Code / Firas
  // Agent internal calls (they set nomem:true) so code and agent output is never mutated.
  res._scrubBt = !payload.nomem && !payload.agent;

  try {
    let served = false;
    // VISION → a strong CLOUD multimodal model FIRST (Gemini Flash): much better than the local
    // qwen2.5vl, and it works on the deployed site with NO local GPU. Falls back to local Ollama
    // vision only if Gemini isn't configured or fails before any bytes.
    if (vision && GEMINI_API_KEY) {
      served = await streamGeminiVision(res, messages, ac.signal);
    }
    // Max tier → premium external engines FIRST: Gemini Flash (free) → Claude Sonnet
    // (paid) → OpenRouter free (Nemotron). Each returns false if it failed before any
    // bytes, so the chain degrades cleanly to the next engine.
    if (tier === "max" && !vision && !served) {
      // Max = Qwen3.5 397B (free Ollama) FIRST — strongest tier, zero credit. External engines fall back.
      served = await streamOllama(res, ollamaMessages, tier, think, ac.signal);   // Qwen3.5 397B
      // DeepSeek V4 Pro via NVIDIA NIM (free, credit-guarded per day) — frontier-class
      // reasoning+coding rescue so Max stays genuinely the strongest tier.
      if (!served && !res.writableEnded && NVIDIA_API_KEY && nvidiaUnderCap()) {
        served = await streamDeepSeek(res, messages, ac.signal);
        if (served) nvidiaCharge();
      }
      if (!served && !res.writableEnded) served = await streamGemini(res, messages, ac.signal, think);
      if (!served && !res.writableEnded) served = await streamAnthropic(res, messages, ac.signal);
      if (!served && !res.writableEnded) served = await streamOpenRouter(res, messages, ac.signal);
    }
    // Max (non-vision) already exhausted its Ollama attempt in the premium chain above —
    // don't burn seconds retrying the same dead pool before the rescue chain answers.
    let ok = served ? true : ((tier === "max" && !vision) ? false : await streamOllama(res, ollamaMessages, tier, think, ac.signal, modelOverride));
    if (!ok && vision && !res.writableEnded) {
      // The vision model can fail on a COLD START (it has to load into VRAM first) — the
      // first request times out/errors, the model loads, and a retry then succeeds. streamOllama
      // returns false only when it failed BEFORE writing any bytes, so a retry is safe.
      await new Promise((r) => setTimeout(r, 1200));
      ok = await streamOllama(res, ollamaMessages, tier, think, ac.signal, modelOverride);
    }
    if (!ok && !res.writableEnded) {
      if (vision) {
        // LAST-RESORT VISION: the keyless fallback engine accepts OpenAI-style image_url
        // parts, so instead of a dead-end apology we convert the attached images to data
        // URLs and let it actually answer. streamFallback shows its own message if even
        // this fails — the user always gets a reply, never a hang.
        let vBudget = 3; // keep the JSON body small enough for the free engine
        const oaiVision = messages
          .filter((m) => m && (m.role === "system" || m.role === "user" || m.role === "assistant"))
          .map((m) => {
            const text = String((m && m.content) || "");
            if (m.role === "user" && Array.isArray(m.images) && m.images.length && vBudget > 0) {
              const parts = text ? [{ type: "text", text }] : [];
              for (const raw of m.images) {
                if (vBudget <= 0) break;
                const norm = normalizeImage(raw);
                if (norm) { parts.push({ type: "image_url", image_url: { url: "data:" + b64Mime(norm) + ";base64," + norm } }); vBudget--; }
              }
              if (parts.length) return { role: m.role, content: parts };
            }
            return { role: m.role, content: text };
          });
        await streamFallback(res, oaiVision, tier, think, ac.signal);
      } else {
        // RESCUE CHAIN for EVERY tier — never surface "busy" while any engine can answer:
        // 1) the tier's Ollama fallback model (different hosted pool), 2) Gemini Flash (free),
        // 3) OpenRouter free, 4) last-resort pollinations text fallback.
        // FAST rescue: Gemini (fast, good) → Cloudflare (fast ~0.5s, free, ANY country, real capacity)
        // → OpenRouter → the slow Ollama fallback pool → keyless pollinations. CF is high so a
        // 429-storm on the other free tiers doesn't crawl through slow pools before answering.
        const fb = TIERS[tier] && TIERS[tier].fallbackModel;
        // HARD tasks (Max tier / math / science / exam) → Cloudflare REASONING model for correctness;
        // everyday chat stays on the fast model. (Agent always runs tier "max" → always the strong model.)
        const cfHard = tier === "max" || CF_HARD_RE.test(cfLastUserText(messages));
        const cfModel = cfHard ? CF_TEXT_MODEL_STRONG : CF_TEXT_MODEL;
        let recovered = await streamGemini(res, messages, ac.signal, think);
        if (!recovered && !res.writableEnded) recovered = await streamCloudflareText(res, messages, ac.signal, cfModel);
        // If the strong reasoning model produced nothing (e.g. truncated mid-think / unavailable), retry
        // the fast model so we still answer rather than falling straight through.
        if (!recovered && !res.writableEnded && cfModel !== CF_TEXT_MODEL) recovered = await streamCloudflareText(res, messages, ac.signal, CF_TEXT_MODEL);
        if (!recovered && !res.writableEnded) recovered = await streamOpenRouter(res, messages, ac.signal);
        if (!recovered && !res.writableEnded && fb) recovered = await streamOllama(res, ollamaMessages, tier, think, ac.signal, fb);
        if (!recovered && !res.writableEnded) {
          await streamFallback(res, messages, tier, think, ac.signal);   // last-resort keyless pollinations
        }
      }
    }
  } catch (e) {
    console.error("[firas] chat handler error:", (e && e.message) || e);
    if (!res.writableEnded) {
      sseWrite(res, "Something went wrong with the Firas AI engine. Please try again.");
      sseDone(res);
    }
  } finally {
    clearDeadlines();
    if (!res.writableEnded) sseDone(res);
  }
}

/* ===========================================================================
   Static file serving (path-traversal guard + index fallback + no-cache)
   =========================================================================== */
/* ALLOWLIST — the only files this server will ever hand out.
   ===========================================================================
   This replaces a denylist that lost twice, both verified by exploit:

     GET /DATA/db.json   →  the whole 5.6 MB database. The guard was
                            `filePath.startsWith(DATA_DIR + path.sep)`, a CASE-SENSITIVE
                            compare against a lowercase literal — while NTFS and APFS are
                            case-INSENSITIVE. `/DATA/`, `/Data/`, `/x/../DATA/` and the
                            percent-encoded form all walked straight past it. The dump
                            contains `secret`, the session-signing HMAC key, so an attacker
                            could then forge a cookie for ANY user id including the admin.

     GET /ENV~1          →  .env with every live API key. The guard tested
                            `segment.startsWith(".")`, but Windows keeps a second DOT-FREE
                            8.3 short name for every such file and NTFS resolves it to the
                            same bytes. /GIT~1/config exposed the repository the same way.

   A denylist has to anticipate every alias the filesystem accepts — case folding, 8.3 names,
   trailing dots and spaces, alternate data streams, unicode normalization. It will keep
   losing. An allowlist inverts the default: anything not named here is simply not a file
   this server knows how to serve, whatever the URL spells.

   Note this also closes an exposure nobody had filed: server.mjs, package.json, Dockerfile,
   local-server.log and cloudflared.exe were all being served on request. */
const STATIC_ALLOW = new Set([
  "index.html",
  "app.js",
  "styles.css",
  "firebase-config.js",     // optional, git-ignored; absent on most deploys
  "logo-preview.html",      // temporary design-review page; safe to delete with this entry
  "favicon.ico",
  "robots.txt",
  "manifest.webmanifest",
  "sw.js",
]);
/* Prefixes that may serve their whole subtree.
   `media/` holds site assets that are too large to live in the database — the trailer is
   47 MB, and an announcement record is JSON in RTDB. It is a read-only directory of files
   the owner puts there deliberately; the containment check below still resolves the real
   path, so a "../" cannot climb out of it. */
const STATIC_ALLOW_PREFIX = [".well-known/", "media/"];

async function serveStatic(req, res) {
  let urlPath;
  try { urlPath = decodeURIComponent(req.url.split("?")[0]); }
  catch { urlPath = req.url.split("?")[0]; }          // malformed %-escape → treat as literal
  if (urlPath === "/" || urlPath === "") urlPath = "/index.html";

  // Normalize to a forward-slash relative key, then decide from the ALLOWLIST alone.
  const rel = path.normalize(urlPath).replace(/^([/\\]|\.\.[/\\])+/, "").replace(/\\/g, "/");
  const allowed =
    STATIC_ALLOW.has(rel) ||
    STATIC_ALLOW_PREFIX.some((p) => rel.startsWith(p) && !rel.includes(".."));

  /* Anything else falls through to index.html — the SPA behaviour this app already had for
     unknown routes. Serving the shell rather than 403/404 also means the response is
     identical for "a route that doesn't exist" and "a file you may not have", so probing
     cannot distinguish them. */
  let filePath = allowed ? path.join(__dirname, rel) : path.join(__dirname, "index.html");

  // Belt and braces: even an allowlisted name must resolve inside the project and outside
  // the data directory. realpath defeats symlinks and 8.3/case aliases by resolving to the
  // canonical path before comparison.
  try {
    const real = await realpath(filePath).catch(() => filePath);
    const root = await realpath(__dirname).catch(() => __dirname);
    const dataRoot = await realpath(DATA_DIR).catch(() => DATA_DIR);
    const fold = (p) => (process.platform === "win32" || process.platform === "darwin" ? p.toLowerCase() : p);
    const inside = (child, parent) => fold(child) === fold(parent) || fold(child).startsWith(fold(parent) + path.sep);
    if (!inside(real, root) || inside(real, dataRoot)) {
      res.writeHead(404, { "Content-Type": "text/plain" });
      return res.end("404 Not Found");
    }
    filePath = real;
  } catch { /* resolution failed → fall through to the read, which will 404 */ }

  if (!existsSync(filePath)) filePath = path.join(__dirname, "index.html");

  /* ── RANGE REQUESTS ──────────────────────────────────────────────────────────────────
     Every response below is a whole-file read. For text that is fine; for the 47 MB trailer
     it is not. A <video> element asks for byte ranges: without a 206 it must download the
     entire file before the first frame, the progress bar cannot be dragged at all, and
     Safari refuses to start playback on a 200 that has no Accept-Ranges.
     Handled only for media, so nothing about how the app's own files are served changes. */
  {
    const ext0 = path.extname(filePath).toLowerCase();
    if (ext0 === ".mp4" || ext0 === ".webm") {
      const { statSync, createReadStream } = await import("node:fs");
      const size = statSync(filePath).size;
      const range = req.headers.range;
      const base = {
        "Content-Type": MIME[ext0] || "application/octet-stream",
        "Accept-Ranges": "bytes",
        "Cache-Control": "public, max-age=86400",
        "X-Content-Type-Options": "nosniff",
      };
      if (range) {
        const m = /bytes=(\d*)-(\d*)/.exec(range);
        let start = m && m[1] ? parseInt(m[1], 10) : 0;
        let end = m && m[2] ? parseInt(m[2], 10) : size - 1;
        // A malformed or out-of-bounds range must answer 416, never a truncated 206.
        if (!isFinite(start) || !isFinite(end) || start > end || start >= size) {
          res.writeHead(416, { "Content-Range": `bytes */${size}` });
          return res.end();
        }
        if (end >= size) end = size - 1;
        res.writeHead(206, Object.assign({}, base, {
          "Content-Range": `bytes ${start}-${end}/${size}`,
          "Content-Length": end - start + 1,
        }));
        return createReadStream(filePath, { start, end }).pipe(res);
      }
      res.writeHead(200, Object.assign({}, base, { "Content-Length": size }));
      return createReadStream(filePath).pipe(res);
    }
  }

  try {
    const data = await readFile(filePath);
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, {
      "Content-Type": MIME[ext] || "application/octet-stream",
      "Cache-Control": "no-cache", // always revalidate so edits show up immediately
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "strict-origin-when-cross-origin",
      "X-Frame-Options": "SAMEORIGIN", // clickjacking protection for the login UI
      /* CSP, deliberately narrow. `script-src`/`img-src`/`connect-src` are NOT set here and
         that is a decision, not an omission: Firas Code renders every user project inside a
         srcdoc iframe, and a srcdoc INHERITS the parent's CSP. Any subresource directive
         would therefore break real user projects — blob: ES-module imports, CDN scripts,
         inline handlers, images from anywhere. The zero-click image-exfiltration vector this
         was meant to cover is closed precisely, at the sanitizer (installPurifyHooks).
         Framing is already handled by X-Frame-Options above — and deliberately NOT by
         `frame-ancestors`, whose enforcement on inherited-CSP srcdoc documents differs
         between browsers and could blank a preview. What is left are the two directives no
         user project can legitimately need: */
      "Content-Security-Policy": "base-uri 'self'; object-src 'none'",
    });
    res.end(data);
  } catch {
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("404 Not Found");
  }
}

/* ===========================================================================
   Router
   =========================================================================== */
// POST /api/oauth/google/exchange — OPTIONAL server-side PKCE code exchange for
// the native (iOS) system-browser sign-in. The iOS OAuth client has NO client
// secret; the PKCE code_verifier authenticates the public client. We forward
// code+verifier to Google and return { id_token }. Google's token endpoint is
// CORS-open so the app CAN fetch it directly; this handler is a durable
// alternative that keeps the flow off undocumented CORS behavior. Nothing secret
// lives here — there is no iOS client secret to protect.
const GOOGLE_IOS_CLIENT_ID = "237562309958-p0njbmb5imqcfd6fk728ccr6lhesq03e.apps.googleusercontent.com";
const GOOGLE_IOS_REDIRECT  = "com.googleusercontent.apps.237562309958-p0njbmb5imqcfd6fk728ccr6lhesq03e:/oauth2redirect";
async function handleGoogleOAuthExchange(req, res) {
  if (rateLimited("auth:" + clientIp(req), 12, 60_000)) {
    return sendJson(res, 429, { error: "too many attempts, please wait a minute" });
  }
  const body = await readJson(req, 20_000);
  if (!body) return sendJson(res, 400, { error: "invalid JSON body" });
  const code = typeof body.code === "string" ? body.code : "";
  const verifier = typeof body.code_verifier === "string" ? body.code_verifier : "";
  if (!code || !verifier) return sendJson(res, 400, { error: "missing code or code_verifier" });

  let data = null;
  try {
    const r = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: GOOGLE_IOS_CLIENT_ID,
        code,
        code_verifier: verifier,
        redirect_uri: GOOGLE_IOS_REDIRECT,   // must exactly match the authorize request
        grant_type: "authorization_code",
        // NO client_secret — not applicable to iOS OAuth clients.
      }),
    });
    data = await r.json().catch(() => ({}));
    if (!r.ok || !data.id_token) {
      return sendJson(res, 401, { error: data.error_description || data.error || "exchange failed" });
    }
  } catch {
    return sendJson(res, 502, { error: "token endpoint unreachable" });
  }
  return sendJson(res, 200, { id_token: data.id_token });
}

const server = http.createServer(async (req, res) => {
  try {
    const route = req.url.split("?")[0];
    const method = req.method;

    // ---- AI stream ----
    if (route === "/api/chat") {
      if (method === "POST") return await handleChat(req, res);
      if (method === "OPTIONS") {
        // Same-origin app: do not advertise a wildcard cross-origin policy.
        res.writeHead(204, { Allow: "POST, OPTIONS" });
        return res.end();
      }
      res.writeHead(405);
      return res.end("method not allowed");
    }

    // ---- Web search (keyless, server-proxied DuckDuckGo) ----
    if (route === "/api/search" && method === "GET") return await handleWebSearch(req, res);
    if (route === "/api/images" && method === "GET") return await handleImageSearch(req, res);
    if (route === "/api/fetch" && method === "GET") return await handleUrlFetch(req, res);
    if (route === "/api/imgproxy" && method === "GET") return await handleImgProxy(req, res);

    // ---- Image generation (keyless, server-proxied pollinations) ----
    if (route === "/api/image/quota" && method === "POST") return await handleImageQuota(req, res);
    if (route === "/api/image" && method === "GET") return await handleImage(req, res);
    if (route === "/api/image/edit" && method === "POST") return await handleImageEdit(req, res);
    if (route === "/api/video/quota" && method === "GET") return await handleVideoQuota(req, res);
    if (route === "/api/video" && method === "GET") return await handleVideo(req, res);

    // ---- Max tier daily quota (read-only pre-check) ----
    if (route === "/api/max/quota" && method === "POST") return await handleMaxQuota(req, res);

    // ---- Subscriptions / redeem codes ----
    if (route === "/api/redeem" && method === "POST") return await handleRedeem(req, res);
    if (route === "/api/admin/codes" && method === "GET") return await handleAdminCodesList(req, res, new URL(req.url, "http://localhost"));
    if (route === "/api/admin/codes" && method === "POST") return await handleAdminCodesCreate(req, res);
    if (route === "/api/admin/codes" && method === "PATCH") return await handleAdminCodesPatch(req, res);
    if (route === "/api/admin/codes" && method === "DELETE") return await handleAdminCodesDelete(req, res, new URL(req.url, "http://localhost"));
    if (route === "/api/usage/charge" && method === "POST") return await handleUsageCharge(req, res);

    if (route === "/api/memory" && method === "GET") return handleMemoryGet(req, res);
    if (route === "/api/memory" && method === "DELETE") return await handleMemoryClear(req, res);
    if (route === "/api/memory/learn" && method === "POST") return await handleMemoryLearn(req, res);
    if (route === "/api/announcements" && method === "GET") return handleAnnouncementsGet(req, res);
    if (route === "/api/announcements" && method === "POST") return await handleAnnouncementsPost(req, res);
    if (route === "/api/announcements" && method === "PATCH") return await handleAnnouncementsPatch(req, res);
    if (route === "/api/announcements" && method === "DELETE") return await handleAnnouncementsDelete(req, res);
    if (route === "/api/translate" && method === "POST") return await handleTranslate(req, res);
    if (route === "/api/live/token" && method === "POST") return await handleLiveToken(req, res);
    if (route === "/api/transcribe" && method === "POST") return await handleTranscribe(req, res);
    if (route === "/api/tts" && method === "POST") return await handleTts(req, res);

    // ---- Admin knowledge base (RAG reference books) ----
    if (route === "/api/kb" && method === "GET") return await handleKbList(req, res);
    if (route === "/api/kb" && method === "POST") return await handleKbAdd(req, res);
    if (route === "/api/kb" && method === "DELETE") return await handleKbDelete(req, res);

    // ---- Firas Brain: the signed-in user's OWN document library (page-cited RAG) ----
    if (route === "/api/brain/docs" && method === "GET") return await handleBrainDocs(req, res);
    if (route === "/api/brain/doc" && method === "POST") return await handleBrainDocAdd(req, res);
    if (route === "/api/brain/doc" && method === "DELETE") return await handleBrainDocDelete(req, res);
    if (route === "/api/brain/search" && method === "POST") return await handleBrainSearch(req, res);
    if (route === "/api/brain/passage" && method === "GET") return await handleBrainPassage(req, res);

    // ---- Public share links ----
    if (route === "/api/share" && method === "POST") return await handleShareCreate(req, res);
    if (route === "/api/share" && method === "GET") return handleShareGet(req, res);
    if (route === "/api/share" && method === "DELETE") return await handleShareDelete(req, res);

    // ---- Build version (lets an open tab auto-reload when code changes) ----
    if (route === "/api/version" && method === "GET") return handleVersion(req, res);

    // ---- Auth ----
    if (route === "/api/auth/signup" && method === "POST") return await handleSignup(req, res);
    if (route === "/api/auth/verify-signup" && method === "POST") return await handleVerifySignup(req, res);
    if (route === "/api/auth/verify-status" && method === "POST") return await handleVerifyStatus(req, res);
    if (route === "/api/auth/resend-code" && method === "POST") return await handleResendCode(req, res);
    if (route === "/api/auth/login" && method === "POST") return await handleLogin(req, res);
    if (route === "/api/auth/firebase" && method === "POST") return await handleFirebaseAuth(req, res);
    if (route === "/api/oauth/google/exchange" && method === "POST") return await handleGoogleOAuthExchange(req, res);
    if (route === "/api/auth/forgot" && method === "POST") return await handleForgot(req, res);
    if (route === "/api/auth/reset" && method === "POST") return await handleReset(req, res);
    if (route === "/api/auth/change-password" && method === "POST") return await handleChangePassword(req, res);
    if (route === "/api/auth/change-email" && method === "POST") return await handleChangeEmail(req, res);
    if (route === "/api/auth/delete-account" && method === "POST") return await handleDeleteAccount(req, res);
    if (route === "/api/auth/logout" && method === "POST") return handleLogout(req, res);
    if (route === "/api/auth/me" && method === "GET") return handleMe(req, res);
    // ---- Guest trial (no signup) ----
    if (route === "/api/guest" && method === "POST") return handleGuestStart(req, res);
    if (route === "/api/guest" && method === "DELETE") return handleGuestEnd(req, res);

    // ---- Chats ----
    if (route === "/api/chats") {
      if (method === "GET") return await handleListChats(req, res);
      if (method === "POST") return await handleCreateChat(req, res);
      res.writeHead(405);
      return res.end("method not allowed");
    }
    const chatMatch = route.match(/^\/api\/chats\/([^/]+)$/);
    if (chatMatch) {
      const id = decodeURIComponent(chatMatch[1]);
      if (method === "GET") return await handleGetChat(req, res, id);
      if (method === "PUT") return await handleUpdateChat(req, res, id);
      if (method === "DELETE") return await handleDeleteChat(req, res, id);
      res.writeHead(405);
      return res.end("method not allowed");
    }

    // ---- Static ----
    if (method === "GET" || method === "HEAD") return await serveStatic(req, res);

    res.writeHead(404);
    res.end("not found");
  } catch (e) {
    console.error("[firas] request handler error:", (e && e.message) || e);
    if (!res.headersSent) sendJson(res, 500, { error: "internal error" });
    else if (!res.writableEnded) {
      try { res.end(); } catch (_) {}
    }
  }
});

// A single dropped connection or stream hiccup must never take the server down.
process.on("uncaughtException", (e) => console.error("[firas] uncaught:", (e && e.message) || e));
process.on("unhandledRejection", (e) => console.error("[firas] rejection:", (e && e.message) || e));

// Boot: ensure DB exists, then listen.
initDb()
  .then(() => {
    // Reclaim abandoned GUEST document libraries. Once at boot (so a long-dead process's
    // leftovers go on the next restart) and daily after that. unref() so it never holds the
    // process open, and every failure is swallowed — a sweep must not be able to break boot.
    setTimeout(() => { brainSweepGuests().catch(() => {}); }, 30_000).unref();
    setInterval(() => { brainSweepGuests().catch(() => {}); }, 86_400_000).unref();
    server.listen(PORT, "0.0.0.0", () => { // bind all interfaces (required by Fly.io/containers)
      console.log(`\n  ✦ Firas AI  →  http://localhost:${PORT}`);
      console.log(`  engine: Ollama (${OLLAMA_HOST})  fallback: keyless pollinations`);
      console.log(`  voice: ${GEMINI_KEYS.length ? "Gemini expressive (" + GEMINI_KEYS.length + " key" + (GEMINI_KEYS.length > 1 ? "s" : "") + ") → Edge neural → Google" : "Edge neural → Google (set GEMINI_API_KEY for the expressive voice)"}`);
      console.log(`  db: ${fbEnabled() ? "Firebase RTDB (" + FB_DB_URL + ")" : DB_PATH}  (users: ${DB.users.length}, chats: ${DB.chats.length})`);
      // Production-readiness guardrails (warn loudly, don't crash).
      const prod = process.env.NODE_ENV === "production";
      if (!process.env.SESSION_SECRET) {
        console.warn("  ⚠ SESSION_SECRET is not set — sessions are signed with a DB-stored secret that is regenerated if the DB is wiped. Set SESSION_SECRET for production.");
      }
      if (OLLAMA_HOST.includes("localhost") && (OLLAMA_API_KEY || prod)) {
        console.warn("  ⚠ OLLAMA_HOST points at localhost but this looks like a deploy — the engine will be unreachable and chat will degrade to the keyless fallback. Set OLLAMA_HOST=https://ollama.com (+ OLLAMA_API_KEY).");
      }
      if (prod && !fbEnabled() && !process.env.DATA_DIR) {
        console.warn("  ⚠ No persistent storage — data/db.json is ephemeral on most hosts (accounts/chats reset). Set FIREBASE_DB_URL + FIREBASE_SERVICE_ACCOUNT (recommended), or point DATA_DIR at a persistent disk.");
      }
      console.log("");
    });
  })
  .catch((e) => {
    console.error("[firas] failed to start:", (e && e.message) || e);
    process.exit(1);
  });
