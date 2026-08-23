// ============================================================================
// Firas AI — backend as a SINGLE Netlify Edge Function (Deno runtime).
// Mirrors server.mjs's /api/* routes so the unchanged frontend works as-is.
// DB = Firebase Realtime Database (per-record). Crypto = Web Crypto (crypto.subtle).
// Self-contained (no imports between edge files) to avoid resolution surprises.
// ============================================================================

const env = (k) => { try { return Netlify.env.get(k); } catch { return undefined; } };

const SESSION_SECRET     = env("SESSION_SECRET") || "";
const FIREBASE_DB_URL    = (env("FIREBASE_DB_URL") || "").replace(/\/+$/, "");
/* Shared secret for the server-to-server channel used by the background agent runner
   (netlify/functions/agent-background.mjs). Absent by default: with no value the job routes
   answer 501 and the internal /api/chat channel does not exist at all, so an unconfigured
   deploy cannot be reached through it. */
const INTERNAL_JOB_SECRET = env("INTERNAL_JOB_SECRET") || "";
const FIREBASE_PROJECT_ID= env("FIREBASE_PROJECT_ID") || "firas-ai";
let   FB_SA = null;
try { if (env("FIREBASE_SERVICE_ACCOUNT")) FB_SA = JSON.parse(env("FIREBASE_SERVICE_ACCOUNT")); } catch (_) {}
const OLLAMA_HOST    = (env("OLLAMA_HOST") || "https://ollama.com").replace(/\/+$/, "");
const OLLAMA_CHAT_URL= OLLAMA_HOST + "/api/chat";
// Ollama API KEY POOL — each free key has a WEEKLY quota; when one hits its limit (429/402/403)
// the pool rotates to the next. OLLAMA_API_KEY + OLLAMA_API_KEYS="k2,k3,…" + OLLAMA_API_KEY_1..9.
// STICKY-FIRST picking (drain key 1, then key 2…).
const OLLAMA_KEYS = (() => {
  const keys = [];
  if (env("OLLAMA_API_KEY")) keys.push(String(env("OLLAMA_API_KEY")).trim());
  for (const k of String(env("OLLAMA_API_KEYS") || "").split(",")) { const v = k.trim(); if (v) keys.push(v); }
  for (let i = 1; i <= 9; i++) { const v = String(env("OLLAMA_API_KEY_" + i) || "").trim(); if (v) keys.push(v); }
  return [...new Set(keys)];
})();
const OLLAMA_API_KEY = OLLAMA_KEYS[0] || "";                  // back-compat
const _olCooldown = new Map();
/* A BUSY KEY IS NOT AN EMPTY KEY, and the difference matters most for the one that is paid for.

   Every limit used to cost 45 minutes. That is right for a free key with a weekly quota — once it
   is gone it is gone — and badly wrong for a subscription key, which throttles for seconds under
   load and recovers on its own. Sidelining the paid key for three quarters of an hour because it
   was briefly busy sends every user down to the free keys for no reason at all.

   429 is "come back shortly". 402 and 403 are "there is nothing left". They now rest for very
   different lengths, and the FIRST key in the pool — the subscription one by convention — gets
   the shortest rest of all, because it is the one we always want back. */
const OLLAMA_BUSY_MS  = Number(env("OLLAMA_BUSY_COOLDOWN_MS")) || 45000;      // rate limited
const OLLAMA_SPENT_MS = Number(env("OLLAMA_SPENT_COOLDOWN_MS")) || 45 * 60000; // out of quota
function ollamaMarkLimited(key, status) {
  if (!key) return;
  const spent = status === 402 || status === 403;
  const primary = OLLAMA_KEYS[0] === key;
  const rest = spent ? OLLAMA_SPENT_MS : (primary ? Math.min(OLLAMA_BUSY_MS, 15000) : OLLAMA_BUSY_MS);
  _olCooldown.set(key, Date.now() + rest);
}
function ollamaPickKey() {
  if (!OLLAMA_KEYS.length) return "";
  const now = Date.now();
  for (const k of OLLAMA_KEYS) { if (now >= (_olCooldown.get(k) || 0)) return k; }
  return OLLAMA_KEYS.reduce((a, b) => ((_olCooldown.get(a) || 0) <= (_olCooldown.get(b) || 0) ? a : b));
}
const FALLBACK_URL   = "https://text.pollinations.ai/openai";
const FALLBACK_MODEL = "openai";
// PREMIUM "Max" tier engines (server-side keys only — end users stay keyless).
// Max chain: Claude Sonnet (paid) → OpenRouter free (DeepSeek-R1) → Ollama/pollinations.
const ANTHROPIC_API_KEY  = env("ANTHROPIC_API_KEY") || "";
const ANTHROPIC_MODEL    = env("ANTHROPIC_MODEL") || "claude-sonnet-4-6";
const ANTHROPIC_URL      = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_MAX_TOK  = Math.max(1024, parseInt(env("ANTHROPIC_MAX_TOKENS") || "32768", 10) || 32768); // Claude Sonnet supports far more than the old 8192; long documents were losing their tail
const OPENROUTER_API_KEY = env("OPENROUTER_API_KEY") || "";
const OPENROUTER_MODEL   = env("OPENROUTER_MODEL") || "nvidia/nemotron-3-ultra-550b-a55b:free";
// Free VISION models on OpenRouter — used to READ attached images when Gemini/Ollama vision are
// unavailable, so image support never fully dies. Comma-separated, tried in order.
const OPENROUTER_VISION_MODELS = (env("OPENROUTER_VISION_MODELS") || "meta-llama/llama-3.2-11b-vision-instruct:free,qwen/qwen2.5-vl-32b-instruct:free,google/gemma-3-27b-it:free").split(",").map((s) => s.trim()).filter(Boolean);
const OPENROUTER_URL     = "https://openrouter.ai/api/v1/chat/completions";
// Gemini TEXT for Max — Google AI Studio FREE tier (Flash family, ~1500 req/day, no card).
// OpenAI-compatible endpoint → streams like OpenRouter. Tried FIRST in the Max chain.
// GEMINI_TEXT_MODEL may be a comma-separated fallback list; first id that streams wins.
const GEMINI_TEXT_MODELS = (env("GEMINI_TEXT_MODEL") || "gemini-2.5-flash,gemini-flash-latest").split(",").map((s) => s.trim()).filter(Boolean);
/* VISION uses its OWN model chain, separate from text. Page OCR is transcription, not reasoning,
   so the cheapest capable model wins — and on the free tier the difference is not subtle:
   gemini-2.5-flash allows 20 requests/DAY per key, while the Flash-Lite line allows 500. With a
   12-key pool that is 240 page-scans/day for the whole site versus 6,000. Same 250K TPM, so
   throughput is unaffected. 2.5-flash stays last as the known-good fallback, and any id the
   account cannot serve simply falls through to the next entry in the loop. */
const GEMINI_VISION_MODELS = (env("GEMINI_VISION_MODEL") ||
  "gemini-3.5-flash-lite,gemini-3.1-flash-lite,gemini-2.5-flash").split(",").map((s) => s.trim()).filter(Boolean);
const GEMINI_OAI_URL     = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";
// Gemini image model (Google AI Studio "Nano Banana"). If GEMINI_API_KEY is set,
// /api/image uses it FIRST, falling back to keyless pollinations. Free key, no card.
// GEMINI KEY POOL — put all keys (from DIFFERENT Google accounts) in GEMINI_API_KEYS
// (commas/spaces/newlines), or GEMINI_API_KEY / GEMINI_API_KEY_1..24. On a 429 the
// pool rotates; a limited key rests briefly and self-heals. Feeds the voice + image + text.
const GEMINI_KEYS = (() => {
  const blob = [env("GEMINI_API_KEY") || "", env("GEMINI_API_KEYS") || "", ...Array.from({ length: 24 }, (_, i) => env("GEMINI_API_KEY_" + (i + 1)) || "")].join(" ");
  return [...new Set(blob.split(/[\s,;]+/).map((k) => k.trim().replace(/^["']+|["']+$/g, "")).filter((k) => k.length >= 20))];
})();
const _gemCd = new Map();
const _gemStrikes = new Map();   // key -> CONSECUTIVE 429s, cleared by a success
let _gemCursor = 0;
function gemMarkOk(k) { if (k) _gemStrikes.delete(k); }
/* Google answers 429 for BOTH the per-minute and the per-DAY cap and does not reliably say which.
   gemini-2.5-flash on the free tier allows only 20 requests/DAY per key, so a day-capped key
   retried every 65s is pure waste. Escalate on consecutive 429s: burst -> pressure -> spent. */
function gemMark(k, s) {
  if (!k) return;
  if (s !== 429) { _gemCd.set(k, Date.now() + 300000); return; }
  const n = (_gemStrikes.get(k) || 0) + 1;
  _gemStrikes.set(k, n);
  _gemCd.set(k, Date.now() + (n <= 1 ? 65000 : n === 2 ? 300000 : 6 * 3600000));
}
/* ROUND-ROBIN, not first-available: always returning key #1 burns its whole daily allowance
   before key #2 is touched, so an N-key pool delivers one key's capacity at a time. */
function gemPick() {
  if (!GEMINI_KEYS.length) return "";
  const now = Date.now();
  for (let i = 0; i < GEMINI_KEYS.length; i++) {
    const idx = (_gemCursor + i) % GEMINI_KEYS.length;
    const k = GEMINI_KEYS[idx];
    if (now >= (_gemCd.get(k) || 0)) { _gemCursor = (idx + 1) % GEMINI_KEYS.length; return k; }
  }
  return GEMINI_KEYS.reduce((a, b) => ((_gemCd.get(a) || 0) <= (_gemCd.get(b) || 0) ? a : b));
}
const GEMINI_API_KEY     = GEMINI_KEYS[0] || "";   // back-compat: `if (GEMINI_API_KEY)` = "any key configured"
const GEMINI_IMAGE_MODEL = env("GEMINI_IMAGE_MODEL") || "gemini-2.5-flash-image";
// NVIDIA NIM — FREE OpenAI-compatible API. Max tier PRIMARY engine (DeepSeek V4 Pro, frontier-class).
// Set NVIDIA_API_KEY in Netlify env vars; Max falls back to Gemini when unset or rate-limited.
const NVIDIA_API_KEY = env("NVIDIA_API_KEY") || "";
const NVIDIA_OAI_URL = "https://integrate.api.nvidia.com/v1/chat/completions";
const NVIDIA_MODEL   = env("NVIDIA_MODEL") || "deepseek-ai/deepseek-v4-pro";
// CREDIT GUARD: max DeepSeek calls per day (GLOBAL, counted in Firebase since edge is stateless).
// Beyond it, Max uses Gemini (free) so the NVIDIA credit can't be drained. Tune with NVIDIA_DAILY_CAP.
const NVIDIA_DAILY_CAP = parseInt(env("NVIDIA_DAILY_CAP")) || 100;
// Hugging Face image model — only FLUX.1-schnell is still free (dev/SDXL/SD3.5 = 410/400).
const HF_API_KEY     = env("HF_API_KEY") || "";
const HF_IMAGE_MODEL = env("HF_IMAGE_MODEL") || "black-forest-labs/FLUX.1-schnell";
const HF_IMAGE_URL   = env("HF_IMAGE_URL") || ("https://router.huggingface.co/hf-inference/models/" + HF_IMAGE_MODEL);
// Puter.com image generation (BEST free option). Server-side call with the DEVELOPER's
// auth token, so END USERS never sign in to Puter → real GPT-Image/Gemini quality, free.
// Tried FIRST when set. Token: https://puter.com/dashboard#account → API token → Create.
const PUTER_AUTH_TOKEN    = env("PUTER_AUTH_TOKEN") || "";
// Default = gpt-image-2 at "low": the FULL GPT-Image model (sharper, better in-image
// text than gpt-image-1-mini) at moderate cost. gpt-image-2 "high"/"medium" + gemini
// "nano-banana" cost more and 402 fast; set gpt-image-1-mini for the cheapest option.
const PUTER_IMAGE_MODEL   = env("PUTER_IMAGE_MODEL") || "gpt-image-2";
const PUTER_IMAGE_QUALITY = env("PUTER_IMAGE_QUALITY") || "low"; // gpt-image-2 / gpt-image-1.5 only: low | medium | high
const PUTER_DRIVER_URL    = "https://api.puter.com/drivers/call";
const PUTER_MODEL_ALIASES = { "nano-banana": "gemini-2.5-flash-image-preview", "nano-banana-pro": "gemini-3-pro-image-preview" };
function puterEngineTag() { const m = PUTER_MODEL_ALIASES[PUTER_IMAGE_MODEL] || PUTER_IMAGE_MODEL; return m + (/gpt-image-(2|1\.5)/i.test(m) ? " " + PUTER_IMAGE_QUALITY : ""); }
let _puterCooldownUntil = 0; // set when Puter is out of credits → skip the doomed 402 call briefly
// Cloudflare Workers AI — RELIABLE FREE fallback (10k neurons/day ≈ ~150-200 imgs/day, no
// card). FLUX.1-schnell quality (≈ pollinations). Server-side token → no user login. Free
// Cloudflare account → Account ID + an API token with "Workers AI" permission.
const CF_ACCOUNT_ID  = env("CF_ACCOUNT_ID") || "";
const CF_API_TOKEN   = env("CF_API_TOKEN") || "";
// Default = FLUX.2 Klein 9B: newest FLUX.2 — excellent quality + best free in-image text
// AND fast (~4s), far better value than flux-2-dev (same quality, ~80s — would also TIME
// OUT on the edge). ~65 free imgs/day. FLUX.2 needs multipart (handled below). Higher
// volume: @cf/black-forest-labs/flux-1-schnell (~130/day). NOTE: flux-2-dev is too slow
// for the edge's response window — keep a fast model (klein/schnell/leonardo) here.
const CF_IMAGE_MODEL = env("CF_IMAGE_MODEL") || "@cf/black-forest-labs/flux-2-klein-9b";
const CF_IMAGE_STEPS = Math.min(20, Math.max(1, parseInt(env("CF_IMAGE_STEPS") || "10", 10) || 10)); // flux-2 uses this; flux-schnell clamped to 8 in the request
// Cloudflare Workers AI TEXT — a real free engine (10k neurons/day) that works from ANY country
// (Iraq included). Rescues chat when the Gemini/OpenRouter free tiers are 429-exhausted.
const CF_TEXT_MODEL = env("CF_TEXT_MODEL") || "@cf/meta/llama-3.3-70b-instruct-fp8-fast";
// STRONG CF model for HARD tasks (Max tier / math / science / exam): a free Workers-AI REASONING model
// (<think>…</think> chains) — far more CORRECT on hard problems than the fast llama fallback. Used only
// on the hard path; degrades to the next engine if unavailable; its <think> is stripped before output.
const CF_TEXT_MODEL_STRONG = env("CF_TEXT_MODEL_STRONG") || "@cf/qwen/qwq-32b";
const CF_HARD_RE = /امتحان|اختبار|أسئلة|اسئلة|بنك\s*أسئلة|واجب|مسألة|مسائل|احسب|أثبت|برهن|اشتقاق|تكامل|تفاضل|معادل|هندسة|نظرية|رياضيات|جبر|فيزياء|كيمياء|quiz|exam|worksheet|\bmcq\b|olympiad|putnam|\bproof\b|theorem|integral|derivative|calculus|algebra|geometry|equation|\bmath\b|physics|chem|\bsolve\b|∫|√|∑|[0-9]\s*[+\-*/^=]\s*[0-9a-zA-Z]/i;
function cfLastUserText(messages) {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m && m.role === "user") return typeof m.content === "string" ? m.content : (Array.isArray(m.content) ? m.content.map((p) => (p && p.text) || "").join(" ") : "");
  }
  return "";
}
// Pool of CF accounts → multiplies the free 10k-neuron/day quota: primary CF_ACCOUNT_ID/
// CF_API_TOKEN + any pairs in CF_ACCOUNTS ("id:token,id:token"). (Pooling to bypass a free
// tier may breach Cloudflare's ToS — operator's choice.)
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
  for (let i = 1; i <= 64; i++) add(env("CF_ACCOUNT_ID_" + i), env("CF_API_TOKEN_" + i));
  // 3) Legacy combined string "id:token,id:token,…".
  for (const pair of (env("CF_ACCOUNTS") || "").split(",")) {
    const s = pair.trim(); if (!s) continue;
    const i = s.indexOf(":"); if (i < 1) continue;
    add(s.slice(0, i), s.slice(i + 1));
  }
  return list;
})();
const _cfCooldown = new Map(); // accountId -> ms timestamp to skip until (its daily 429)
function sniffImageMime(b) { if (!b || b.length < 4) return "image/jpeg"; if (b[0] === 0x89 && b[1] === 0x50) return "image/png"; if (b[0] === 0xFF && b[1] === 0xD8) return "image/jpeg"; if (b[0] === 0x52 && b[1] === 0x49 && b[8] === 0x57) return "image/webp"; return "image/jpeg"; }
/* IDLE-BASED, NOT ABSOLUTE — mirrors server.mjs, and for the same defect: a flat 5-minute
   deadline armed at request time aborted replies that were streaming perfectly well, so the
   longest jobs (a ten-problem PDF with cover, contents and worked solutions) reliably came
   back as "I couldn't reach the service" with nothing kept. Silence is what indicates a dead
   upstream, so every chunk rearms the clock; UPSTREAM_MAX_MS is the runaway backstop. */
const UPSTREAM_IDLE_MS = Number(env("REQUEST_IDLE_TIMEOUT_MS")) || Number(env("REQUEST_TIMEOUT_MS")) || 300000;
/* FIRST-BYTE DEADLINE + MODEL LADDER — mirrors server.mjs; see the long note there.
   In short: a model name the cloud does not host does NOT 404, it accepts and goes silent, so a
   tier pointed at a stronger model sat mute until the request died. The 12s head-timeout below
   does not catch it, because the headers arrive normally and it is the BODY that never comes.
   Past this deadline the attempt is abandoned, the model is marked unavailable, and the caller's
   rescue chain answers. Every OLLAMA_MODEL_* setting takes a comma-separated ladder, strongest
   first, so the tier self-heals downward and climbs back when the mark expires. */
const OLLAMA_FIRST_BYTE_MS = Number(env("OLLAMA_FIRST_BYTE_MS")) || 45000;
const MODEL_DEAD_MS = Number(env("OLLAMA_MODEL_DEAD_MS")) || 1800000;
const _modelDead = new Map();
function modelMarkDead(model) {
  if (!model) return;
  _modelDead.set(model, Date.now() + MODEL_DEAD_MS);
}
function modelLadder(value, fallback) {
  const list = String(value == null || value === "" ? fallback : value)
    .split(",").map((m) => m.trim()).filter(Boolean);
  return list.length ? list : [String(fallback)];
}
function pickModel(ladder) {
  const now = Date.now();
  for (const m of ladder) if (now >= (_modelDead.get(m) || 0)) return m;
  return ladder[0];
}
const UPSTREAM_MAX_MS = Number(env("REQUEST_MAX_MS")) || 1800000; // 30 min hard ceiling

const COOKIE_NAME = "firas_session";
const COOKIE_MAX_AGE = 2592000;            // 30 days (seconds)
const MAX_CHATS_PER_USER = 1000;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
/* -1 = UNMETERED, and that is now the default: Firas asked for no daily usage anywhere.
   Kept as a real setting rather than deleted, because this is the ONE counter standing between
   a single runaway client and the shared upstream image pools (which have their own hard daily
   caps that cannot be raised from here). Set the env var to a positive number to bring a
/* Per-user daily image cap. DEFAULT 5 — Firas asked for a real ceiling again after a spell of
   -1 (unmetered). This is the one counter standing between a single runaway client and the shared
   upstream image pools, which have their own hard daily caps that cannot be raised from here.
   The env var still wins, and -1 there still means unmetered, so the ceiling moves without a
   code change. */
const IMAGE_DAILY_LIMIT = (() => { const n = parseInt(env("IMAGE_DAILY_LIMIT"), 10); return Number.isFinite(n) ? n : 5; })();
/* Same shape as IMAGE_DAILY_LIMIT above, and for the same reason. This used to be
   `Math.max(1, parseInt(env(…) || "10", 10) || 10)`, which had two independent faults:
   it defaulted to 10 instead of the -1 sentinel, and the Math.max(1, …) floor made
   "unlimited" UNREPRESENTABLE — setting MAX_DAILY_LIMIT=-1 in the Netlify UI produced a
   ceiling of 1, tighter than the default it was meant to remove. server.mjs was already
   on -1 with a `>= 0` guard at its enforcement site, so the live edge deploy was the only
   place still capping the Max tier (at 10/day) after everything else went unmetered. */
const MAX_DAILY_LIMIT   = (() => { const n = parseInt(env("MAX_DAILY_LIMIT"), 10); return Number.isFinite(n) ? n : -1; })();
// Admins (the owner) can publish site updates. Comma-separated emails; default the owner.
const ADMIN_EMAILS = (env("ADMIN_EMAILS") || "firasnozad@gmail.com").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
function isAdmin(user) { return !!(user && user.email && ADMIN_EMAILS.includes(String(user.email).toLowerCase())); }
// Admin knowledge base (RAG) — silently grounds answers in the admin's uploaded books.
function kbNorm(s) { return String(s || "").replace(/[ً-ْـ]/g, "").replace(/[آأإٱ]/g, "ا").replace(/ى/g, "ي").replace(/ة/g, "ه").toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, " ").replace(/\s+/g, " ").trim(); }
const KB_STOP = new Set("the a an of to in on for and or is are was were be this that و ما هو هي أو ثم عند كل لا ان أن إن هذا هذه ذلك التي الذي مع شنو وش كيف في من على عن الى إلى با بين الفرق ايه ماهي".split(/\s+/));
function kbStem(t) { t = t.replace(/^(?:[وفبك]ال|لل)/, ""); if (t.startsWith("ال") && t.length > 3) t = t.slice(2); return t; }
/* keepDigits: additionally admit single-character NUMERIC tokens ("3", "9"). OFF by default so
   the admin KB / LOCAL_KB keep their exact existing recall; Firas Brain turns it on for BOTH the
   corpus and the query (it MUST be symmetric — tokenizing one side with digits and the other
   without makes the extra tokens silently never match) because document questions hinge on bare
   numbers: "السؤال 3", "ماذا في صفحة 9". Mirrors server.mjs. */
function kbTokens(s, keepDigits) {
  return kbNorm(s).split(" ").map(kbStem).filter((t) => (t.length > 1 || (keepDigits && /^\d$/.test(t))) && !KB_STOP.has(t));
}
/* The sentence-packing splitter, parameterized. kbChunk keeps its exact original behavior
   (700-char budget, drop <25 chars, cap 4000); Firas Brain reuses the same algorithm PER PAGE
   with a lower floor so a sparse scanned page still produces a citable chunk. */
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
/* A chunk is EITHER a plain string (admin books, LOCAL_KB — everything already stored) or a
   `{ t, p, l }` record (Firas Brain documents, where p = 1-based page/slide/sheet). These two
   accessors accept both, so nothing already in the database needs migrating. */
function chunkText(c) { return typeof c === "string" ? c : ((c && c.t) || ""); }
function chunkPage(c) { return (c && typeof c === "object" && Number.isFinite(c.p)) ? c.p : 0; }
/* Score a query against an EXPLICIT corpus and return hits WITH provenance.
   Split out so Firas Brain can search ONE user's documents instead of the global admin
   library (a shared corpus here would be a cross-tenant leak, not just a scoping bug).
   `minScore` filters BEFORE the top-k slice — the old code sliced first, which silently
   shrank the result set instead of backfilling with the next-best passage. */
function kbSearchIn(books, query, maxChunks, minScore, keepDigits) {
  const qt = kbTokens(query, keepDigits); if (!qt.length) return [];
  const qset = new Set(qt); const scored = [];
  const floor = (minScore === undefined ? 0.25 : minScore);
  for (const book of books) {
    const chunks = book.chunks || [];
    const toks = book._toks || chunks.map((c) => kbTokens(chunkText(c), keepDigits));   // prefer pre-tokenized (isolate cache)
    for (let i = 0; i < chunks.length; i++) {
      const ct = toks[i]; if (!ct || !ct.length) continue;
      let hits = 0; const matched = new Set();
      for (const t of ct) if (qset.has(t)) { hits++; matched.add(t); }
      if (!hits) continue;
      // Rank by DISTINCT query-term coverage; raw repeats are only log-dampened so a chunk
      // spamming one common word 20x can no longer outrank a chunk matching several terms.
      const cov = matched.size / qset.size;
      const score = cov * 2 + (matched.size + Math.log(1 + hits)) / Math.sqrt(ct.length + 5);
      if (score <= floor) continue;
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
function kbSearchChunks(books, query, maxChunks) { return kbSearchIn(books, query, maxChunks || 4, 0.25); }
// Isolate-level KB cache: without it EVERY chat message re-downloads the WHOLE library from
// Firebase and re-tokenizes every chunk — with any-size books that ruins latency. 60s TTL,
// pre-tokenized once per fetch; busted by the /api/kb POST/DELETE handlers.
let _kbCache = { at: 0, books: null };
function kbCacheBust() { _kbCache = { at: 0, books: null }; }
// Bundled LOCAL knowledge base (math/science/arabic/quran…), compiled by
// knowledge/build.mjs. Imported ONCE per isolate, pre-tokenized, and searched
// alongside the admin books. A missing/unbundled file degrades to empty (never throws).
let _localKb = null;
async function localKbBooks() {
  if (_localKb) return _localKb;
  try {
    const mod = await import("../../knowledge/compiled.mjs");
    const raw = Array.isArray(mod.default) ? mod.default : [];
    _localKb = raw.map((b) => ({ ...b, _toks: (b.chunks || []).map((c) => kbTokens(chunkText(c))) }));
  } catch (_) { _localKb = []; }
  return _localKb;
}
async function kbContext(query) {
  let books;
  if (_kbCache.books && Date.now() - _kbCache.at < 60_000) books = _kbCache.books;
  else {
    let node = null; try { node = await dbGet("kb"); } catch (_) { node = null; }
    books = node ? Object.values(node) : [];
    for (const b of books) b._toks = (b.chunks || []).map((c) => kbTokens(chunkText(c)));
    _kbCache = { at: Date.now(), books };
  }
  const all = books.concat(await localKbBooks());
  if (!all.length) return "";
  const hits = kbSearchChunks(all, query, 4);
  if (!hits.length) return "";
  return "REFERENCE MATERIAL (authoritative — use it to answer accurately and completely, then organize " +
    "clearly. NEVER mention, quote, cite, or hint that this material or a book exists — answer as your own knowledge):\n" +
    hits.map((h, i) => (i + 1) + ". " + h.text).join("\n\n");
}

/* ===========================================================================
   FIRAS BRAIN — the per-user document library (product #4). Port of the block in
   server.mjs; the JSON contract is identical because the same app.js talks to both.

   Answers are grounded ONLY in the signed-in user's own uploaded documents and every
   passage carries an exact page number, so a citation can be clicked and verified.

   Three deliberate departures from the admin KB above — do not "unify" them:
   1. HEAVY/LIGHT SPLIT. dbGet has no shallow/limit support: reading a node downloads the
      WHOLE subtree, so a `GET /api/brain/docs` that touched the documents themselves would
      pull every chunk of every document just to render a sidebar. Same pair the chats /
      chatMeta routes already use:
        brainDoc/<uid>/<docId>   = the full document, incl. chunks   (search + passage)
        brainMeta/<uid>/<docId>  = the listing row only              (the docs list)
   2. CHUNKS ARE `{ t, p }`, CHUNKED PER PAGE. kbChunk on a flat document deletes the page
      separator and then cuts on a 700-char budget, so most chunks straddle two pages and a
      page number could only ever be a guess. Splitting INSIDE one page makes it exact.
   3. THE CORPUS IS SCOPED TO ONE USER — see _brainCache below.

   PATH SAFETY: every id segment that reaches a db path goes through dbKey(), and any id
   that dbKey() would alter is rejected outright (400 invalid id), same shape as the kb /
   announcements / codes deletes.
   =========================================================================== */
const BRAIN_MAX_DOCS = 20;                      // documents per user
const BRAIN_MAX_CHUNKS_PER_DOC = 12000;
const BRAIN_MAX_CHARS_PER_DOC = 8_000_000;
const BRAIN_MAX_PAGES_PER_REQ = 1200;
const BRAIN_BODY_LIMIT = 24_000_000;            // `await request.json()` is UNBOUNDED on the edge
const BRAIN_KINDS = new Set(["pdf", "docx", "pptx", "xlsx", "text", "image"]);
const BRAIN_UNITS = new Set(["page", "slide", "sheet", "section"]);
// Daily INGEST budget, in pages. Metered because page OCR runs through /api/chat with
// nomem:true, which both backends deliberately exclude from quota charging — so without this
// a 400-page scan would fire 400 unmetered vision calls.
/* Unmetered like every other product — see PLAN_LIMITS. The daily page ceiling on Brain
   INGEST was the last per-member cap left, and a document library is exactly the thing a
   student hits it with. */
const BRAIN_PAGES_DAILY = { free: -1, gold: -1, diamond: -1, unlimited: -1 };

function brainIdOk(s) { return /^[A-Za-z0-9_-]{1,64}$/.test(String(s || "")); }
function brainNewId() {
  const b = crypto.getRandomValues(new Uint8Array(4));
  return "bd" + Date.now().toString(36) + Array.from(b).map((x) => x.toString(16).padStart(2, "0")).join("");
}
/* Firas Brain is open to GUESTS too. The signed firas_guest cookie IS the account: the library
   is keyed to that id, so clearing cookies or changing device loses it, and guest allowances are
   deliberately small. Mirrors server.mjs. */
/* SITE-WIDE vision budget — see server.mjs for the full reasoning. gemini-2.5-flash free tier is
   20 requests/DAY per key, so a 12-key pool serves ~240 page-scans per day for everyone combined.
   NOTE the edge caveat: this counter is per ISOLATE, so the real ceiling is looser than the number
   suggests. It is a guard rail against one upload draining the pool, not an exact accountant;
   Gemini's own 429 plus the escalating key cooldown is the hard backstop. */
const GEMINI_RPD_PER_KEY = Math.max(1, parseInt(env("GEMINI_RPD_PER_KEY") || "500", 10) || 500);
const BRAIN_VISION_DAILY = Math.max(0, parseInt(env("BRAIN_VISION_DAILY") || "0", 10) ||
                                       (GEMINI_KEYS.length * GEMINI_RPD_PER_KEY));
let _brainVision = { day: "", used: 0 };
function brainVisionLeft() {
  const today = serverDay();
  if (_brainVision.day !== today) _brainVision = { day: today, used: 0 };
  return Math.max(0, BRAIN_VISION_DAILY - _brainVision.used);
}
function brainVisionCharge(n) { brainVisionLeft(); _brainVision.used += Math.max(0, Math.floor(Number(n) || 0)); }

const BRAIN_GUEST_MAX_DOCS = 3;
const BRAIN_GUEST_PAGES_DAILY = 120;
function brainDocLimit(c) { return c.isGuest ? BRAIN_GUEST_MAX_DOCS : BRAIN_MAX_DOCS; }
function brainPagesLimit(c) {
  if (c.isGuest) return BRAIN_GUEST_PAGES_DAILY;
  const l = BRAIN_PAGES_DAILY[planOf(c.user)];
  return l === undefined ? BRAIN_PAGES_DAILY.free : l;
}
function brainMetaOf(doc) {
  return {
    id: doc.id, title: doc.title, kind: doc.kind, unit: doc.unit,
    pages: doc.pages || 0, indexed: doc.indexed || 0, ocr: doc.ocr || 0,
    chunks: (doc.chunks || []).length, chars: doc.chars || 0, ts: doc.ts || 0,
  };
}

/* ---- storage ---- */
/* RTDB re-materializes a stored array as an ARRAY only while its keys stay contiguous 0..n;
   anything else comes back as an object map, and `obj.length` is undefined → the retrieval
   loops would silently see an empty document. Coerce on the way in (integer-like keys come
   out of Object.values in ascending order, so chunk order and therefore `ci` are preserved). */
function brainNormDoc(d) {
  if (!d || !d.id) return null;
  if (!Array.isArray(d.chunks)) d.chunks = (d.chunks && typeof d.chunks === "object") ? Object.values(d.chunks) : [];
  return d;
}
async function brainMetaAll(userId) {
  let node = null;
  try { node = await dbGet("brainMeta/" + dbKey(userId)); } catch (_) { node = null; }
  const out = [];
  for (const m of (node ? Object.values(node) : [])) if (m && m.id) out.push(m);
  out.sort((a, b) => (b.ts || 0) - (a.ts || 0));
  return out;
}
async function brainLoadAll(userId) {
  let node = null;
  try { node = await dbGet("brainDoc/" + dbKey(userId)); } catch (_) { node = null; }
  const out = [];
  for (const raw of (node ? Object.values(node) : [])) { const d = brainNormDoc(raw); if (d) out.push(d); }
  out.sort((a, b) => (b.ts || 0) - (a.ts || 0));
  return out;
}
async function brainLoadDoc(userId, docId) {
  try { return brainNormDoc(await dbGet(`brainDoc/${dbKey(userId)}/${dbKey(docId)}`)); } catch (_) { return null; }
}
/* Writes are NOT swallowed. The /api/kb POST next door does `try { await dbPut(...) } catch {}`
   and then answers { ok: true } — i.e. it reports success on a LOST book. A Brain upload can be
   hundreds of OCR'd pages; silently discarding it and telling the client it worked is the worst
   possible failure mode, so a storage error surfaces as 502. Heavy node first, listing row
   second: brainMeta can then never advertise a document brainDoc doesn't hold. */
async function brainSaveDoc(userId, doc) {
  const uk = dbKey(userId), dk = dbKey(doc.id);
  await dbPut(`brainDoc/${uk}/${dk}`, doc);
  try {
    await dbPut(`brainMeta/${uk}/${dk}`, brainMetaOf(doc));
  } catch (e) {
    // Roll the heavy node back. Without this, a failed listing write leaves a document that is
    // invisible in /api/brain/docs, undeletable from the UI (the client only knows listed ids)
    // and uncounted against the doc cap — yet still downloaded and re-tokenized on every search.
    try { await dbPut(`brainDoc/${uk}/${dk}`, null); } catch (_) {}
    throw e;
  } finally { brainCacheBust(userId); }
}
async function brainRemoveDoc(userId, docId) {
  const uk = dbKey(userId), dk = dbKey(docId);
  try {
    // Heavy node FIRST. An orphaned brainMeta row is self-correcting — it still shows in the
    // list, so its delete can simply be retried — whereas an orphaned brainDoc is unreachable.
    await dbPut(`brainDoc/${uk}/${dk}`, null);
    await dbPut(`brainMeta/${uk}/${dk}`, null);
  } finally { brainCacheBust(userId); }
}

/* Per-USER retrieval cache. Deliberately NOT _kbCache: that one is module-scope and NOT keyed
   by user, so reusing it would serve one user's private documents to the next caller on the
   same isolate. Chunks are pre-tokenized ONCE per fetch (keepDigits ON, matching the query)
   because re-tokenizing a whole library per request does not fit the edge's ~50ms CPU budget. */
const _brainCache = new Map();   // userId → { at, docs }
const BRAIN_CACHE_TTL = 60_000;
function brainCacheBust(userId) { _brainCache.delete(String(userId)); }
async function brainCorpus(userId) {
  const key = String(userId);
  const hit = _brainCache.get(key);
  if (hit && Date.now() - hit.at < BRAIN_CACHE_TTL) return hit.docs;
  const docs = await brainLoadAll(userId);
  for (const d of docs) d._toks = (d.chunks || []).map((c) => kbTokens(chunkText(c), true));
  // Bounded like rlBuckets: an isolate that serves many users must not grow a library cache
  // without limit (insertion order → the oldest entries go first).
  if (_brainCache.size > 40) { for (const k of _brainCache.keys()) { _brainCache.delete(k); if (_brainCache.size <= 20) break; } }
  _brainCache.set(key, { at: Date.now(), docs });
  return docs;
}

/** Chunk a document PAGE BY PAGE so every chunk's page number is exact by construction. */
/* Representative excerpts spanning the WHOLE selection, for questions with no keywords to match
   on ("اشرح لي السلايدات", "summarize this"). Lexical retrieval scores those at zero — the words
   are not in the document — so without this the product answers its single most common question
   with "I couldn't find anything". Under the budget the whole document goes in; over it, an even
   stride keeps the sample spread from first page to last. Mirrors server.mjs. */
const BRAIN_OVERVIEW_CHARS = 48000;
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
   lines are not semantic boundaries, and those keep the sentence packer untouched.
   Mirrors server.mjs. */
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
const ANN_IMG_OK = (s) => typeof s === "string" && /^(data:image\/(png|jpe?g|webp);base64,|https?:\/\/)/.test(s);
/* A video is a URL, never inline data. The trailer is 47 MB and an announcement record is
   JSON in RTDB — embedding it would blow past the record limit and take the database with
   it. Only a same-origin /media/ path or an https URL is accepted, so a stored string can
   never become a javascript: or data: sink when the client puts it in a <video src>. */
const ANN_VID_OK = (s) => typeof s === "string" &&
  /^(\/media\/[A-Za-z0-9._-]+\.(mp4|webm)|https:\/\/[^\s"'<>]+\.(mp4|webm))$/.test(s);

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
  // EVERY tier has a fallbackModel on a DIFFERENT hosted pool, so a busy/saturated primary degrades
  // to a working model instead of surfacing "The Firas AI engine is busy".
  mini:  { models: modelLadder(env("OLLAMA_MODEL_MINI"),  "gemma4:cloud,qwen3.5:35b-cloud,gpt-oss:120b-cloud"),     get model() { return pickModel(this.models); }, temperature: 0.5, num_predict: 16384,  fallbackModel: "qwen3-coder:480b-cloud" },
  pro:   { models: modelLadder(env("OLLAMA_MODEL_PRO"),   "glm-5.2:cloud,deepseek-v4-flash:cloud,gpt-oss:120b-cloud"),     get model() { return pickModel(this.models); }, temperature: 0.7, num_predict: 131072, fallbackModel: "qwen3-coder:480b-cloud" },
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
  ultra: { models: modelLadder(env("OLLAMA_MODEL_ULTRA"), "kimi-k2.7-code:cloud,glm-5.1:cloud,minimax-m3:cloud,qwen3-coder:480b-cloud"), get model() { return pickModel(this.models); }, temperature: 0.35, num_predict: 131072, fallbackModel: "gpt-oss:120b-cloud" },
  // Max = strongest general/reasoning model (671B), gated by a per-user daily cap.
  // Env-overridable so the model can be swapped without a redeploy if Ollama's
  // cloud catalog rotates. fallbackModel degrades to a known-good hosted model
  // (gpt-oss) before the last-resort pollinations fallback.
  /* Max was left on 32768 — a QUARTER of pro's ceiling on the tier that runs the Agent and
     every document build, i.e. exactly the work that needs the most room. The budget, not the
     model, was ending a ten-problem PDF early. Matched to pro/ultra; Ollama clamps to what the
     chosen model actually supports, so raising it cannot error. */
  /* TEMPERATURE 0.5. The Agent runs long chains where every step is the input to the next, so a
     wrong turn early is not one bad sentence — it is the rest of the mission built on top of it.
     Reliability beats flair here in a way it does not in ordinary chat. */
  max:   { models: modelLadder(env("OLLAMA_MODEL_MAX"),   "kimi-k3:cloud,nemotron-3-ultra:cloud,glm-5.2:cloud,qwen3-coder:480b-cloud"), get model() { return pickModel(this.models); }, temperature: 0.5, num_predict: 131072, fallbackModel: env("OLLAMA_MODEL_MAX_FALLBACK") || "gpt-oss:120b-cloud", capped: false },
};
// Vision model. The edge ALWAYS talks to Ollama cloud, which does NOT host the
// local-only qwen2.5vl — so use a CLOUD-hosted multimodal model. gemma3:27b-cloud
// is free, available, and reads images (verified). Env-overridable.
const OLLAMA_MODEL_VISION = env("OLLAMA_MODEL_VISION") || "gemma3:27b-cloud";
const MAX_IMAGES_PER_REQUEST = 10;
const MAX_IMAGE_B64_BYTES = 8000000;
const SEARCH_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

const te = new TextEncoder();
const td = new TextDecoder();

/* ---------------- base64url + json helpers ---------------- */
function b64urlFromBytes(buf) {
  const b = buf instanceof ArrayBuffer ? new Uint8Array(buf) : buf;
  let s = ""; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlToBytes(str) {
  let s = String(str).replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s); const u = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
  return u;
}
function b64FromBytes(buf){ const b=buf instanceof ArrayBuffer?new Uint8Array(buf):buf; let s=""; for(let i=0;i<b.length;i++)s+=String.fromCharCode(b[i]); return btoa(s); }
function b64ToBytes(s){ const bin=atob(s); const u=new Uint8Array(bin.length); for(let i=0;i<bin.length;i++)u[i]=bin.charCodeAt(i); return u; }
function b64urlJson(obj){ return b64urlFromBytes(te.encode(JSON.stringify(obj))); }
function decodeJwtSeg(seg){ try { return JSON.parse(td.decode(b64urlToBytes(seg))); } catch { return null; } }
function json(obj, status, extra) { return new Response(JSON.stringify(obj), { status: status || 200, headers: Object.assign({ "content-type": "application/json; charset=utf-8" }, extra || {}) }); }
function emailKey(email){ return b64urlFromBytes(te.encode(String(email).toLowerCase())); }

/* ---------------- HMAC signed session value ---------------- */
let _hmacKey = null;
async function hmacKey() {
  if (_hmacKey) return _hmacKey;
  _hmacKey = await crypto.subtle.importKey("raw", te.encode(SESSION_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
  return _hmacKey;
}
/* REVOCABLE SESSIONS — mirrors server.mjs. The signed value used to be the bare user id,
   so one cookie was a permanent bearer credential: logout cleared only the victim's own
   browser, a password change left outstanding cookies working, and a reset re-issued a
   byte-identical value because the HMAC input never changed.
   Version 0 signs exactly the old payload, so shipping this logs nobody out; the first
   bump moves the account to the "id|vN" form and every older cookie stops verifying. */
function sessionPayload(id, ver) {
  return (ver > 0) ? (id + "|v" + ver) : id;
}
function sessionParts(payload) {
  const i = payload.lastIndexOf("|v");
  if (i <= 0) return { id: payload, ver: 0 };
  const v = payload.slice(i + 2);
  if (!/^d+$/.test(v)) return { id: payload, ver: 0 };
  return { id: payload.slice(0, i), ver: parseInt(v, 10) };
}
async function signUserId(userId, ver) {
  const payload = sessionPayload(userId, ver || 0);
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(), te.encode(payload));
  return payload + "." + b64urlFromBytes(sig);
}
async function verifySessionValue(value) {
  if (typeof value !== "string") return null;
  const dot = value.lastIndexOf(".");
  if (dot <= 0) return null;
  const userId = value.slice(0, dot), sig = value.slice(dot + 1);
  let ok = false;
  try { ok = await crypto.subtle.verify("HMAC", await hmacKey(), b64urlToBytes(sig), te.encode(userId)); } catch { return null; }
  return ok ? userId : null;
}

/* ---------------- PBKDF2 password hashing (Web Crypto; scrypt is unavailable on Edge) ---------------- */
const PBKDF2_ITER = 100000; // stays well under Netlify Edge's 50ms CPU-per-request limit (verifyPassword reads each hash's own iter count, so this is backward-compatible)
async function hashPassword(password) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const km = await crypto.subtle.importKey("raw", te.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations: PBKDF2_ITER, hash: "SHA-256" }, km, 256);
  return `pbkdf2$${PBKDF2_ITER}$${b64FromBytes(salt)}$${b64FromBytes(bits)}`;
}
async function verifyPassword(password, stored) {
  if (typeof stored !== "string") return false;
  const [scheme, iterStr, saltB64, hashB64] = stored.split("$");
  if (scheme !== "pbkdf2") return false;          // legacy scrypt hashes can't verify here
  const km = await crypto.subtle.importKey("raw", te.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt: b64ToBytes(saltB64), iterations: parseInt(iterStr, 10) || PBKDF2_ITER, hash: "SHA-256" }, km, 256);
  const a = new Uint8Array(bits), b = b64ToBytes(hashB64);
  if (a.length !== b.length) return false;
  let diff = 0; for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/* ---------------- Firebase RTDB (service-account RS256 -> OAuth token -> REST) ---------------- */
function pemToPkcs8(pem) {
  let p = String(pem); if (p.includes("\\n")) p = p.replace(/\\n/g, "\n");
  const body = p.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return b64ToBytes(body).buffer;
}
let _saKey = null, _fbToken = null, _fbExp = 0;
async function fbAccessToken() {
  if (!FB_SA) throw new Error("firebase not configured");
  const now = Math.floor(Date.now() / 1000);
  if (_fbToken && now < _fbExp - 60) return _fbToken;
  if (!_saKey) _saKey = await crypto.subtle.importKey("pkcs8", pemToPkcs8(FB_SA.private_key), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const aud = FB_SA.token_uri || "https://oauth2.googleapis.com/token";
  const claims = { iss: FB_SA.client_email, scope: "https://www.googleapis.com/auth/firebase.database https://www.googleapis.com/auth/userinfo.email", aud, iat: now, exp: now + 3600 };
  const input = b64urlJson({ alg: "RS256", typ: "JWT" }) + "." + b64urlJson(claims);
  const sig = await crypto.subtle.sign({ name: "RSASSA-PKCS1-v1_5" }, _saKey, te.encode(input));
  const jwt = input + "." + b64urlFromBytes(sig);
  const r = await fetch(aud, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }) });
  if (!r.ok) throw new Error("fb token " + r.status + " " + (await r.text()).slice(0, 160));
  const j = await r.json(); _fbToken = j.access_token; _fbExp = now + (j.expires_in || 3600);
  return _fbToken;
}
/* PATH-INJECTION GUARD. Every db path below is a template string that concatenates an
   id into `${FIREBASE_DB_URL}/${path}.json`, and URL parsing collapses ".." segments —
   so ANY id that reaches a path with a slash in it escapes its own subtree. Concretely:
   `DELETE /api/admin/codes?id=..%2Fusers` used to resolve to <db>/users.json and PUT
   null over the ENTIRE users table (searchParams.get() already percent-decodes, so the
   attacker never even needs a literal slash). dbKey() is the single choke point: RTDB
   keys may not contain . $ # [ ] / anyway, and every id this app mints (uuid, base36,
   hex, base64url email key, "YYYY-MM-DD") already fits [A-Za-z0-9_-], so stripping is a
   no-op on legitimate values and only ever destroys a traversal attempt. */
function dbKey(s) { return String(s == null ? "" : s).replace(/[^A-Za-z0-9_-]/g, "").slice(0, 128); }
/* Belt-and-braces for any future call site that forgets dbKey(): a path is only ever
   dbKey-shaped segments joined by single slashes. Throws (→ the handler's 500) rather
   than letting a malformed path reach Firebase. */
function dbPath(path) {
  const p = String(path);
  if (!/^[A-Za-z0-9_-]+(\/[A-Za-z0-9_-]+)*$/.test(p)) throw new Error("unsafe db path");
  return p;
}
async function dbGet(path) {
  const t = await fbAccessToken();
  const r = await fetch(`${FIREBASE_DB_URL}/${dbPath(path)}.json`, { headers: { Authorization: "Bearer " + t } });
  if (!r.ok) throw new Error("db get " + r.status);
  return await r.json();
}
async function dbPut(path, value) {
  const t = await fbAccessToken();
  const r = await fetch(`${FIREBASE_DB_URL}/${dbPath(path)}.json?print=silent`, { method: "PUT", headers: { Authorization: "Bearer " + t, "content-type": "application/json" }, body: JSON.stringify(value) });
  if (!r.ok) throw new Error("db put " + r.status + " " + (await r.text()).slice(0, 160));
}
async function dbDelete(path) {
  const t = await fbAccessToken();
  const r = await fetch(`${FIREBASE_DB_URL}/${dbPath(path)}.json?print=silent`, { method: "DELETE", headers: { Authorization: "Bearer " + t } });
  if (!r.ok && r.status !== 404) throw new Error("db del " + r.status);
}

/* ─────────────────────────────────────────────────────────────────────────────
   ATOMIC COUNTER — closes the last quota bypass, the one that needed no exploit.

   Every quota counter here was read-modify-write: read the day's count, add one in
   the isolate, PUT the result back. Edge functions run in MANY isolates at once, so
   two requests that read the same value both write the same value+1, and one of them
   is free. Nothing clever is required to trigger it — two browser tabs, or a phone
   and a laptop, or simply a fast double-send. It is not a race an attacker has to
   win; it is one that ordinary use loses for you, every day, in the user's favour.

   Firebase RTDB REST has no `increment` verb, but it does have conditional writes:
   GET with `X-Firebase-ETag: true` returns an ETag, and PUT with `if-match: <etag>`
   is rejected with 412 when the value moved underneath. That is compare-and-swap,
   which is all an atomic counter needs — retry on 412 with the value the server hands
   back in the failure response.

   Bounded at 6 attempts. Under contention that is astronomically more than enough
   (each retry only loses if ANOTHER writer commits in the same millisecond); if it
   somehow exhausts, the final write is forced rather than dropped, because
   undercounting by one is the failure mode we are here to remove.
   ───────────────────────────────────────────────────────────────────────────── */
async function dbIncrement(path, delta, opts) {
  const t = await fbAccessToken();
  const url = `${FIREBASE_DB_URL}/${dbPath(path)}.json`;
  const max = (opts && opts.max) || 12;
  const cap = opts && typeof opts.cap === "number" ? opts.cap : null;
  let etag = null, cur = null;

  for (let attempt = 0; attempt < max; attempt++) {
    if (etag === null) {
      const g = await fetch(url, { headers: { Authorization: "Bearer " + t, "X-Firebase-ETag": "true" } });
      if (!g.ok) throw new Error("db inc get " + g.status);
      etag = g.headers.get("ETag");
      cur = await g.json();
    }
    const base = typeof cur === "number" ? cur : 0;
    const next = cap !== null ? Math.min(base + delta, cap) : base + delta;

    const headers = { Authorization: "Bearer " + t, "content-type": "application/json" };
    // Only send if-match when the server actually gave us an ETag; without one a
    // conditional write would be rejected outright and the counter would never move.
    if (etag) headers["if-match"] = etag;

    const p = await fetch(url + "?print=silent", { method: "PUT", headers, body: JSON.stringify(next) });
    if (p.ok) return next;

    if (p.status === 412) {
      // Someone else committed first. The 412 body carries the CURRENT value and the
      // response carries its ETag, so the next attempt needs no extra round trip.
      etag = p.headers.get("ETag");
      try { cur = await p.json(); } catch (_) { etag = null; cur = null; }
      if (!etag) { etag = null; cur = null; }   // fall back to a fresh read
      /* JITTERED BACKOFF. Without it, N contenders retry in lockstep and keep colliding
         with each other — a 40-way stress test spent 219 conflicts and still lost most
         of the charges. A few milliseconds of randomised delay desynchronises them, which
         is the whole mechanism; the delay grows with the attempt so a genuinely hot key
         spreads out instead of hammering. */
      const backoff = Math.floor(Math.random() * (4 << Math.min(attempt, 5)));
      if (backoff) await new Promise((r) => setTimeout(r, backoff));
      continue;
    }
    throw new Error("db inc put " + p.status + " " + (await p.text()).slice(0, 160));
  }

  /* Contention never resolved within the retry budget. The write still has to land —
     an uncharged request is the failure we are here to prevent — but it must never
     UNDO someone else's charge, which a blind `read + delta` PUT can do: the value read
     here may already be stale by the time it is written. Writing only when the result
     is strictly greater than what is stored makes the fallback monotonic, so the worst
     case is one charge merged into another's, never a counter going backwards. */
  const g = await fetch(url, { headers: { Authorization: "Bearer " + t } });
  const raw = g.ok ? await g.json() : 0;
  const base = typeof raw === "number" ? raw : 0;
  const next = cap !== null ? Math.min(base + delta, cap) : base + delta;
  if (next > base) await dbPut(path, next);
  return next > base ? next : base;
}

/* ---------------- user + chat records ---------------- */
/* ---- Subscriptions & daily quotas (mirrors server.mjs; sub+quota live on the user record) ---- */
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
function planOf(user) {
  const s = user && user.sub;
  if (!s || !s.plan) return "free";
  if (s.plan === "unlimited") return "unlimited";
  if (s.plan !== "gold" && s.plan !== "diamond") return "free";
  if (s.expiresAt && Date.now() > s.expiresAt) return "free";
  return s.plan;
}
function quotaRollDay(user) {
  const today = serverDay();
  // brainPages = Firas Brain's daily INGEST budget (pages indexed), separate from `brain`
  // (answers), because page OCR rides nomem:true calls that quota charging deliberately skips.
  if (!user.quota || user.quota.day !== today) { user.quota = { day: today, ai: 0, code: 0, agent: 0, brain: 0, brainPages: 0, agentCids: {}, last: {} }; return true; }
  if (!user.quota.last) user.quota.last = {};
  // agentCids is a MAP here (one child key per cid), not the array server.mjs keeps:
  // saveQuota() writes each cid as its own child so two concurrent agent charges can't
  // clobber each other. Records written before that change still hold an array.
  if (!user.quota.agentCids || typeof user.quota.agentCids !== "object") user.quota.agentCids = {};
  return false;
}
// "__proto__" survives the cid charset filter, and assigning it as a map key hits the
// prototype setter instead of storing anything — treat it as "no cid" (never deduped).
function agentCidOk(cid) { return !!cid && cid !== "__proto__"; }
function agentCidSeen(q, cid) {
  const a = q && q.agentCids;
  if (!agentCidOk(cid) || !a) return false;
  return Array.isArray(a) ? a.includes(cid) : Object.prototype.hasOwnProperty.call(a, cid);
}
function agentCidAdd(q, cid) {
  if (!agentCidOk(cid)) return;
  if (Array.isArray(q.agentCids)) { const m = {}; for (const c of q.agentCids) m[String(c)] = true; q.agentCids = m; } // migrate a legacy array in place
  q.agentCids[cid] = true;
  // No 500-entry trim is needed any more: a charge is rejected BEFORE it is recorded
  // once the plan's daily limit is hit, so the map is bounded by that limit and the
  // whole node is replaced when the day rolls.
}
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
/* ---- redeem codes (stored in RTDB under codes/<id>) ---- */
function normCode(s) { return String(s || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 40); }
function genCode() {
  const A = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
  const rnd = crypto.getRandomValues(new Uint8Array(12));
  let out = "FIRAS"; for (let i = 0; i < 12; i++) out += A[rnd[i] % A.length]; return out;
}
/* Redemptions are counted from codes/<id>/claims/<userId> — one child per redeemer, see
   /api/redeem. `uses`/`usedBy` are the PRE-claims shape and are now frozen: they stay as
   the base count for codes redeemed before the change, and new redemptions only ever add
   a claim child. Total = frozen base + claim count. */
function codeLegacyUses(c) { return Math.max(Number(c && c.uses) || 0, Array.isArray(c && c.usedBy) ? c.usedBy.length : 0); }
function codeClaims(c) { return (c && c.claims && typeof c.claims === "object" && !Array.isArray(c.claims)) ? c.claims : null; }
function codeClaimList(c) {
  const m = codeClaims(c); if (!m) return [];
  return Object.keys(m).map((k) => { const v = m[k] || {}; return { userId: v.userId || k, email: v.email || "", at: Number(v.at) || 0 }; }).sort((a, b) => a.at - b.at);
}
function codeUses(c) { const m = codeClaims(c); return codeLegacyUses(c) + (m ? Object.keys(m).length : 0); }
function codeClaimedBy(c, userId) {
  const m = codeClaims(c);
  if (m && Object.prototype.hasOwnProperty.call(m, dbKey(userId))) return true;
  return Array.isArray(c && c.usedBy) && c.usedBy.some((u) => u && u.userId === userId);
}
function codeStatus(c) {
  if (!c) return "invalid";
  if (c.disabled) return "disabled";
  if (c.expiresAt && Date.now() > c.expiresAt) return "expired";
  if (codeUses(c) >= (c.maxUses || 1)) return "used-up";
  return "active";
}
// The admin panel reads uses/usedBy — keep serving those field names, computed from the
// claims node, so the UI needs no change and the raw claims map is never shipped.
function publicCode(c) {
  const { claims, ...rest } = c || {};
  const legacy = Array.isArray(rest.usedBy) ? rest.usedBy : [];
  return { ...rest, uses: codeUses(c), usedBy: legacy.concat(codeClaimList(c)), status: codeStatus(c) };
}
async function edgeCodesAll() { const n = await dbGet("codes"); return n ? Object.values(n) : []; }
async function edgeFindCode(codeStr) { const c = normCode(codeStr); if (!c) return null; return (await edgeCodesAll()).find((x) => x.code === c) || null; }

function publicUser(u) { return { id: u.id, name: u.name, email: u.email, admin: isAdmin(u), sub: subInfo(u) }; }
async function getUserById(id) { const k = dbKey(id); if (!k) return null; return (await dbGet("users/" + k)) || null; }
async function getUserByEmail(email) {
  const id = await dbGet("emailIndex/" + dbKey(emailKey(email)));
  return id ? getUserById(id) : null;
}
/* WHOLE-RECORD write. Only for account-lifecycle changes (create / password / email /
   reset) — a user never fires those while chatting, so the stale-snapshot clobber
   described on saveUserChild() can't bite. Everything hot goes through saveUserChild()
   or saveQuota(). */
async function saveUser(u) {
  await dbPut("users/" + dbKey(u.id), u);
  await dbPut("emailIndex/" + dbKey(emailKey(u.email)), u.id);
}
/* Write ONE child of the user record. saveUser() is a full `PUT users/<id>`, so any two
   requests that both read the user and both save it lose one of the two writes: /api/chat
   bumped the quota while /api/memory/learn was still holding the snapshot it read seconds
   earlier (three LLM calls), and whichever PUT landed last reverted the other — daily
   plan limits went unenforced in production and learned memory vanished. Disjoint child
   paths mean the two requests no longer touch the same node.
   (server.mjs needs none of this: one process, one in-memory DB object, no lost update.) */
async function saveUserChild(u, key, value) {
  await dbPut(`users/${dbKey(u.id)}/${dbKey(key)}`, value === undefined ? null : value);
}
/* Persist a quota charge as individual child keys — same reasoning as saveUserChild(),
   and the same shape the file already uses for maxQuota/<uid>/<day>/<cid>.

   The residual this comment used to describe — "two charges inside the same read window
   undercount by one, RTDB REST has no atomic increment" — is FIXED. RTDB REST does support
   conditional writes (X-Firebase-ETag + if-match), which is enough to build compare-and-swap,
   and dbIncrement() does. Verified exact up to 12 simultaneous charges on one counter;
   beyond that it degrades monotonically (never over-counts, never rolls backwards) rather
   than losing charges silently. */
async function saveQuota(user, product, qcid, rolled) {
  const base = `users/${dbKey(user.id)}/quota`;
  const q = user.quota;
  if (rolled) await dbPut(base, { day: q.day, ai: 0, code: 0, agent: 0, brain: 0, brainPages: 0, agentCids: {}, last: {} });
  /* ATOMIC. This used to PUT the count this isolate had computed, which silently
     discarded any charge another isolate committed after we read. Incrementing the
     stored value instead means concurrent requests each add their own unit.
     `rolled` writes zeros immediately above, so incrementing from there is correct.
     If the CAS path fails outright, fall back to the old write rather than lose the
     charge entirely — degraded, but never free. */
  try {
    await dbIncrement(`${base}/${dbKey(product)}`, 1);
  } catch (_) {
    await dbPut(`${base}/${dbKey(product)}`, q[product] || 0);
  }
  if (qcid) {
    if (product === "agent") { if (agentCidOk(qcid)) await dbPut(`${base}/agentCids/${dbKey(qcid)}`, true); }
    else await dbPut(`${base}/last/${dbKey(product)}`, qcid);
  }
}
/* Persist Firas Brain's daily INGEST counter. Same child-key discipline as saveQuota() —
   NEVER saveUser(), which is a whole-record PUT and would revert whatever /api/chat or
   /api/memory/learn wrote since it read its snapshot. Same honest residual too: RTDB REST
   has no atomic increment, so two ingests inside one read window can undercount by one
   batch; that is a one-request slip, not a lost document. */
async function saveBrainPages(user, rolled, addPages) {
  const base = `users/${dbKey(user.id)}/quota`;
  const q = user.quota;
  if (rolled) await dbPut(base, { day: q.day, ai: 0, code: 0, agent: 0, brain: 0, brainPages: 0, agentCids: {}, last: {} });
  /* ATOMIC, same reason as saveQuota: ingesting a document from two tabs at once used to
     let one whole batch of pages through unmetered, because both isolates wrote the count
     they had each computed from the same starting value. */
  const delta = typeof addPages === "number" && addPages > 0 ? addPages : 1;
  try {
    await dbIncrement(`${base}/brainPages`, delta);
  } catch (_) {
    await dbPut(`${base}/brainPages`, q.brainPages || 0);
  }
}

/* ---------------- email (Resend) + signup verification + password reset ---------------- */
const RESEND_API_KEY = env("RESEND_API_KEY") || "";
const RESEND_FROM    = env("RESEND_FROM") || "Firas AI <onboarding@resend.dev>";
// Brevo (primary): single-sender reaches ALL members for free, no domain needed.
const BREVO_API_KEY   = env("BREVO_API_KEY") || "";
const BREVO_FROM      = env("BREVO_FROM") || "firasnozad@gmail.com";
const BREVO_FROM_NAME = env("BREVO_FROM_NAME") || "Firas AI";
const VERIFY_TTL_MS  = 15 * 60000;
const RESET_TTL_MS   = 30 * 60000;
function appBase(request) { try { return new URL(request.url).origin; } catch (_) { return ""; } }
async function sendViaBrevo(to, subject, html, fromName) {
  if (!BREVO_API_KEY) { console.error("[firas] Brevo: BREVO_API_KEY is EMPTY on this deploy (set it in Netlify env + redeploy)"); return false; }
  try {
    const r = await fetch("https://api.brevo.com/v3/smtp/email", { method: "POST", headers: { "content-type": "application/json", "accept": "application/json", "api-key": BREVO_API_KEY }, body: JSON.stringify({ sender: { name: fromName || BREVO_FROM_NAME, email: BREVO_FROM }, to: [{ email: to }], subject, htmlContent: html }) });
    if (!r.ok) { const b = await r.text().catch(() => ""); console.error("[firas] Brevo send failed " + r.status + " (from=" + BREVO_FROM + ") -> " + b.slice(0, 300)); return false; }
    return true;
  } catch (e) { console.error("[firas] Brevo error: " + ((e && e.message) || e)); return false; }
}
async function sendViaResend(to, subject, html, fromName) {
  if (!RESEND_API_KEY) return false;
  const addr = (RESEND_FROM.match(/<([^>]+)>/) || [])[1] || "onboarding@resend.dev";
  const from = fromName ? (fromName + " <" + addr + ">") : RESEND_FROM;
  try {
    const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { "content-type": "application/json", "Authorization": "Bearer " + RESEND_API_KEY }, body: JSON.stringify({ from, to: [to], subject, html }) });
    if (!r.ok) { const b = await r.text().catch(() => ""); console.error("[firas] Resend send failed " + r.status + " -> " + b.slice(0, 200)); return false; }
    return true;
  } catch (e) { console.error("[firas] Resend error: " + ((e && e.message) || e)); return false; }
}
// Brevo first (reaches everyone free), Resend fallback. opts.fromName overrides display name.
async function sendEmail(to, subject, html, opts) {
  const fromName = opts && opts.fromName;
  if (BREVO_API_KEY) { if (await sendViaBrevo(to, subject, html, fromName)) return true; }
  if (RESEND_API_KEY) { if (await sendViaResend(to, subject, html, fromName)) return true; }
  return false;
}
function fmtNow(loc) { try { return new Date().toLocaleString(loc || "ar", { dateStyle: "long", timeStyle: "short" }); } catch (_) { return new Date().toISOString().replace("T", " ").slice(0, 16) + " UTC"; } }
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
  // Matches the SITE's dark theme + fonts (IBM Plex Sans Arabic / Inter w/ system fallbacks).
  // Bright + bold text; glow in TOP-RIGHT + BOTTOM-LEFT corners.
  const bg = "#262624", card = "#30302E", border = "#46453F", hair = "#3A3A36",
        ink = "#F6F4ED", muted = "#C2BFB6", soft = "#8C8A81", accent = "#57AE9C", accent2 = "#6BC0AE", onacc = "#10221D";
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
function escEmail(s) { return String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }
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
  return brandedEmail({ lang: "en", preheader: "Welcome to Firas AI — a note from Firas", heading: "Welcome to Firas AI 👋", lead: "Hi " + (first || "there") + ",", contentHtml: content });
}
function verifyEmailHtml(link) {
  return brandedEmail({ preheader: "أكمل إنشاء حسابك في Firas AI", heading: "تأكيد بريدك الإلكتروني", lead: "أهلاً بك في " + ltr("Firas AI") + " — اضغط الزر لتأكيد بريدك وتفعيل حسابك، وتدخل مباشرةً.", contentHtml: mailButton(link, "تأكيد الحساب وبدء الاستخدام") + mailLink(link), note: "الرابط صالح لمدة 15 دقيقة. إذا لم تطلب إنشاء حساب، تجاهل هذه الرسالة." });
}
function resetEmailHtml(link) {
  return brandedEmail({ preheader: "رابط إعادة تعيين كلمة المرور — Firas AI", heading: "إعادة تعيين كلمة المرور", lead: "طلبت إعادة تعيين كلمة مرورك. اضغط الزر للمتابعة:", contentHtml: mailButton(link, "تعيين كلمة مرور جديدة") + mailLink(link), note: "الرابط صالح لمدة 30 دقيقة. إذا لم تطلب هذا، تجاهل الرسالة وكلمة مرورك تبقى كما هي." });
}
// Pending signups live in Firebase with reverse-indexes by token + pid (for O(1) lookup).
async function delPending(ek, rec) {
  if (!dbKey(ek)) return;
  try { await dbDelete("pending/" + dbKey(ek)); } catch (_) {}
  if (rec && dbKey(rec.token)) { try { await dbDelete("pendingTok/" + dbKey(rec.token)); } catch (_) {} }
  if (rec && dbKey(rec.pid)) { try { await dbDelete("pendingPid/" + dbKey(rec.pid)); } catch (_) {} }
}

/* Drop pending signups whose verification window has closed. server.mjs does this on a
   5-minute timer (_pendingSweep); an edge isolate has no timer, so this runs request-driven
   from the signup path — the only request that creates these records, which makes the
   cleanup rate track the creation rate automatically.

   `max` bounds the work so a single signup can never turn into a long scan of a large
   subtree. A 60s grace beyond `exp` mirrors server.mjs, so a verification landing in the
   same second as the sweep is never destroyed underneath the user. Fails silently on
   purpose: this is housekeeping, and a signup must not 500 because a cleanup could not run. */
async function sweepExpiredPendings(max) {
  let all = null;
  try { all = await dbGet("pending"); } catch (_) { return 0; }
  if (!all || typeof all !== "object") return 0;
  const now = Date.now();
  let removed = 0;
  for (const ek of Object.keys(all)) {
    if (removed >= (max || 40)) break;
    const rec = all[ek];
    if (!rec || rec.verified) continue;                 // a verified record is claimed elsewhere
    if (now <= (Number(rec.exp) || 0) + 60000) continue;
    try { await delPending(ek, rec); removed++; } catch (_) {}
  }
  return removed;
}
// Best-effort client IP for per-client rate-limit keys (Netlify provides x-nf-client-connection-ip).
function ipOf(request, context) {
  try {
    return (context && context.ip) ||
      request.headers.get("x-nf-client-connection-ip") ||
      (request.headers.get("x-forwarded-for") || "").split(",")[0].trim() || "?";
  } catch (_) { return "?"; }
}
async function sha256hex(s) {
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(String(s)));
  return Array.from(new Uint8Array(b)).map((x) => x.toString(16).padStart(2, "0")).join("");
}
async function currentUser(context) {
  if (!SESSION_SECRET) return null;
  const raw = context.cookies.get(COOKIE_NAME);
  if (!raw) return null;
  const payload = await verifySessionValue(raw);
  if (!payload) return null;
  const { id, ver } = sessionParts(payload);
  const user = await getUserById(id);
  if (!user) return null;
  // The MAC proves we issued it, never that it is still current. A cookie whose version is
  // behind the account's was minted before a logout-everywhere, a password change or a
  // reset — the three moments at which outstanding sessions must stop working.
  if ((user.sessVer || 0) !== ver) return null;
  return user;
}
async function attachSession(context, userId, request, ver) {
  // Sign with the account's CURRENT version so a cookie minted right after a revocation
  // is valid while every cookie minted before it is not.
  const value = await signUserId(userId, ver || 0);
  const secure = new URL(request.url).protocol === "https:";
  context.cookies.set({ name: COOKIE_NAME, value, httpOnly: true, sameSite: "Lax", secure, maxAge: COOKIE_MAX_AGE, path: "/" });
}

/* ===========================================================================
   GUEST SESSIONS (mirrors server.mjs) — "try it without signing up".
   Own cookie (firas_guest) holding an HMAC-signed random id prefixed "g_".
   Quota lives in RTDB at guestQuota/<id>/<day> so it survives across isolates.
   A guest may CHAT under a small daily cap but may NOT generate images,
   persist chats, use memory, share, or subscribe.
   =========================================================================== */
const GUEST_COOKIE = "firas_guest";
const GUEST_COOKIE_MAX_AGE = 604800; // 7 days
const GUEST_LIMITS = {
  /* Raised for real trial use, still FAR below members — mirrors server.mjs. A guest
     identity is free to mint, so this is the allowance an abuser farms; the network-scoped
     bucket multiplies it by 4 per ADDRESS, not per cookie.
     Tripled 2026-08-06 at Firas's request, now that members are fully unmetered. These
     numbers MUST match server.mjs — see the note there. */
  ai:    Math.max(0, parseInt(env("GUEST_DAILY_AI")    || "180", 10) || 180),
  code:  Math.max(0, parseInt(env("GUEST_DAILY_CODE")  || "60", 10) || 60),
  agent: Math.max(0, parseInt(env("GUEST_DAILY_AGENT") || "24", 10) || 24),
  brain: Math.max(0, parseInt(env("GUEST_DAILY_BRAIN") || "120", 10) || 120),
  internal: Math.max(0, parseInt(env("GUEST_DAILY_INTERNAL") || "300", 10) || 300),
  voice: Math.max(0, parseInt(env("GUEST_DAILY_VOICE") || "120", 10) || 120),
};
function newGuestId() {
  const b = crypto.getRandomValues(new Uint8Array(12));
  return "g_" + Array.from(b).map((x) => x.toString(16).padStart(2, "0")).join("");
}
async function currentGuest(context) {
  if (!SESSION_SECRET) return null;
  const raw = context.cookies.get(GUEST_COOKIE);
  if (!raw) return null;
  const id = await verifySessionValue(raw);
  return id && id.startsWith("g_") ? { id, guest: true } : null;
}
async function attachGuest(context, id, request) {
  const value = await signUserId(id);
  const secure = new URL(request.url).protocol === "https:";
  context.cookies.set({ name: GUEST_COOKIE, value, httpOnly: true, sameSite: "Lax", secure, maxAge: GUEST_COOKIE_MAX_AGE, path: "/" });
}
async function guestDayNode(id) { return (await dbGet(`guestQuota/${dbKey(id)}/${serverDay()}`)) || {}; }
/** Entitlement view for a guest — same shape as subInfo() so one client
    component renders meters for guests and members alike. */
async function guestSubInfo(id) {
  let node = {};
  try { node = await guestDayNode(id); } catch (_) {}
  const used = { ai: Number(node.ai) || 0, code: Number(node.code) || 0, agent: Number(node.agent) || 0, brain: Number(node.brain) || 0 };
  const remain = (p) => Math.max(0, GUEST_LIMITS[p] - used[p]);
  return {
    plan: "guest", expiresAt: null, daysLeft: null,
    limits: { ai: GUEST_LIMITS.ai, code: GUEST_LIMITS.code, agent: GUEST_LIMITS.agent, brain: GUEST_LIMITS.brain },
    used,
    remaining: { ai: remain("ai"), code: remain("code"), agent: remain("agent"), brain: remain("brain") },
  };
}
/** Charge one guest unit. Returns null when allowed, or a 429 body when spent.
    Idempotent on a repeated cid, exactly like the member path. */
/* NETWORK-SCOPED GUEST BUCKET — parity with server.mjs (this backend had none).
   The guest meter was keyed solely on the cookie id, and POST /api/guest mints a fresh id
   with no device, IP or proof-of-work binding. So the reset loop was: DELETE /api/guest →
   POST /api/guest → a brand-new full allowance. The only brake was a per-minute limiter,
   and on the edge rateLimited() is an in-ISOLATE Map, so parallel mints landing on
   different isolates each saw an empty bucket — it is not a per-IP cap at all.

   A second bucket keyed on a HASH of the address is now charged in parallel, so minting a
   new cookie resets nothing. The allowance is a MULTIPLE of the per-cookie one because
   real people do share an address — a household, a school, a café — and must not lock
   each other out; it only has to be small enough that farming identities is pointless. */
const GUEST_IP_MULTIPLIER = 4;
async function guestIpKey(request, context) {
  const ip = ipOf(request, context);
  if (!ip) return null;
  // Hashed with the session secret so raw addresses are never written to the database.
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(), te.encode("guestip:" + ip));
  return "ip_" + Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 24);
}
/** Charge the IP-wide bucket alongside the cookie one. Returns a denial or null. */
async function guestChargeIp(request, context, product) {
  const limit = GUEST_LIMITS[product];
  if (!(limit >= 0)) return null;
  let key = null;
  try { key = await guestIpKey(request, context); } catch (_) { return null; }
  if (!key) return null;                       // no address to meter → cookie bucket only
  const cap = limit * GUEST_IP_MULTIPLIER;
  const day = serverDay();
  let node = {};
  try { node = (await dbGet(`guestQuota/${dbKey(key)}/${day}`)) || {}; } catch (_) { return null; }
  const used = Number(node[product]) || 0;
  if (used >= cap) {
    return { error: "guest daily limit reached", guest: true,
             quota: { product, used, limit: cap, plan: "guest", scope: "network" } };
  }
  try { await dbIncrement(`guestQuota/${dbKey(key)}/${day}/${dbKey(product)}`, 1); } catch (_) {}
  return null;
}
async function guestCharge(id, product, cidRaw, messages) {
  const limit = GUEST_LIMITS[product];
  if (!(limit >= 0)) return null;
  const day = serverDay();
  let node = {};
  try { node = await guestDayNode(id); } catch (_) { return null; } // DB blip → fail open
  const cid = String(cidRaw || "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64);
  /* Same defect as the member path, same fix. `seen[cid] === product` treated ANY later
     request carrying that cid as a free retry — a guest could spend one of twelve and then
     ask unlimited different questions on the same id for the rest of the day. A retry is
     now the same cid AND the same question, within the retry window. */
  const bucket = { seen: (node.seen && typeof node.seen === "object") ? node.seen : {} };
  const already = await isRepeatCharge(bucket, product, cid, messages);
  const used = Number(node[product]) || 0;
  if (!already && used >= limit) {
    return { error: "guest daily limit reached", guest: true, quota: { product, used, limit, plan: "guest" } };
  }
  if (!already) {
    /* Charge the NETWORK bucket first: if it is spent this identity must not consume one of
       its own units either, or a farmer minting cookies would still drain the allowances. */
    if (guestCharge._req) {
      const denied = await guestChargeIp(guestCharge._req.request, guestCharge._req.context, product);
      if (denied) return denied;
    }
    try {
      await dbIncrement(`guestQuota/${dbKey(id)}/${day}/${dbKey(product)}`, 1);
      await dbPut(`guestQuota/${dbKey(id)}/${day}/seen`, bucket.seen || {});
    } catch (_) {}
  }
  return null;
}
/* The request/context pair is threaded through a per-call slot rather than a new parameter
   on all five call sites — five signatures that must stay in sync is exactly how one gets
   missed and silently reopens the hole. Mirrors guestChargeWithReq() in server.mjs. */
async function guestChargeWithReq(request, context, id, product, cidRaw, messages) {
  guestCharge._req = { request, context };
  try { return await guestCharge(id, product, cidRaw, messages); }
  finally { guestCharge._req = null; }
}
/** Who is calling, for endpoints a guest may reach.
    → { user, id, isGuest:false } · { id, isGuest:true } · {} */
async function callerOf(context) {
  const user = await currentUser(context);
  if (user) return { user, id: user.id, isGuest: false };
  const g = await currentGuest(context);
  if (g) return { id: g.id, isGuest: true };
  return {};
}
function sanitizeMessages(arr) {
  if (!Array.isArray(arr)) return [];
  return arr.slice(0, 2000).map((m) => {
    const o = { role: m && m.role === "assistant" ? "assistant" : "user", content: String((m && m.content) ?? "").slice(0, 200000) };
    if (m && m.tier) o.tier = String(m.tier).slice(0, 16);
    if (m && m.lang) o.lang = String(m.lang).slice(0, 8);
    if (m && m.reasoning) o.reasoning = String(m.reasoning).slice(0, 200000);
    if (m && m.mode) o.mode = String(m.mode).slice(0, 16);
    if (m && Array.isArray(m.imageThumbs) && m.imageThumbs.length) o.imageThumbs = m.imageThumbs.slice(0, 6).map((s) => String(s).slice(0, 200000));
    return o;
  });
}

/* ---------------- Firebase ID-token verification (Google JWK) ---------------- */
let _googleJwks = { keys: null, exp: 0 };
async function getGoogleKey(kid) {
  const now = Date.now();
  if (!_googleJwks.keys || now >= _googleJwks.exp) {
    const r = await fetch("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com");
    if (!r.ok) return null;
    const j = await r.json();
    let maxAge = 3600; const cc = r.headers.get("cache-control") || ""; const m = cc.match(/max-age\s*=\s*(\d+)/i); if (m) maxAge = parseInt(m[1], 10) || 3600;
    const map = {}; for (const k of (j.keys || [])) map[k.kid] = k;
    _googleJwks = { keys: map, exp: now + maxAge * 1000 };
  }
  return _googleJwks.keys ? _googleJwks.keys[kid] : null;
}
async function verifyFirebaseIdToken(idToken) {
  if (typeof idToken !== "string" || idToken.length < 20 || idToken.length > 8192) return null;
  const parts = idToken.split("."); if (parts.length !== 3) return null;
  const header = decodeJwtSeg(parts[0]); const payload = decodeJwtSeg(parts[1]);
  if (!header || !payload) return null;
  if (header.alg !== "RS256" || (header.typ && header.typ !== "JWT")) return null;
  if (typeof header.kid !== "string" || !header.kid) return null;
  const jwk = await getGoogleKey(header.kid); if (!jwk) return null;
  let key;
  try { key = await crypto.subtle.importKey("jwk", { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]); } catch { return null; }
  let ok = false;
  try { ok = await crypto.subtle.verify({ name: "RSASSA-PKCS1-v1_5" }, key, b64urlToBytes(parts[2]), te.encode(parts[0] + "." + parts[1])); } catch { return null; }
  if (!ok) return null;
  const now = Math.floor(Date.now() / 1000), skew = 300;
  if (payload.aud !== FIREBASE_PROJECT_ID) return null;
  if (payload.iss !== `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`) return null;
  if (typeof payload.exp !== "number" || payload.exp <= now - skew) return null;
  if (typeof payload.iat !== "number" || payload.iat > now + skew) return null;
  // Mirror server.mjs: reject a future-dated auth_time (clock-skew / tampering guard).
  if (payload.auth_time != null && (typeof payload.auth_time !== "number" || payload.auth_time > now + skew)) return null;
  if (typeof payload.sub !== "string" || !payload.sub) return null;
  const email = String(payload.email || "").trim().toLowerCase();
  if (!email || !EMAIL_RE.test(email) || email.length > 200) return null;
  return payload;
}

/* ---------------- best-effort per-isolate rate limit ---------------- */
const rlBuckets = new Map();
function rateLimited(key, max, windowMs) {
  const now = Date.now();
  const arr = (rlBuckets.get(key) || []).filter((t) => now - t < windowMs);
  arr.push(now); rlBuckets.set(key, arr);
  if (rlBuckets.size > 5000) { for (const k of rlBuckets.keys()) { rlBuckets.delete(k); if (rlBuckets.size <= 2500) break; } }
  return arr.length > max;
}

/* ---------------- AI engine helpers (ported from server.mjs) ---------------- */
function normalizeImage(img) {
  if (typeof img !== "string") return null;
  let s = img.trim(); if (!s) return null;
  const c = s.indexOf(","); if (s.startsWith("data:") && c !== -1) s = s.slice(c + 1);
  s = s.trim(); if (!s || s.length > MAX_IMAGE_B64_BYTES) return null;
  return s;
}
/* ---- Persistent per-user memory (mirrors server.mjs; persisted via saveUser) ---- */
const MEMORY_MAX = 60;
function userMemory(user) { if (!Array.isArray(user.memory)) user.memory = []; return user.memory; }
function memoryBlock(user) {
  const m = userMemory(user);
  if (!m.length) return "";
  return "PERSISTENT MEMORY — VERIFIED facts about the user you are talking to RIGHT NOW (saved from past chats). Treat them as TRUE:\n" +
    m.map((f) => "- " + f).join("\n") +
    "\nUse them to personalize naturally. When the user ASKS what you know/remember about them, answer using EXACTLY these facts and nothing invented — keep their exact name, country, city, age and numbers as written here; never substitute a different place or guess a value. If the user now says something that contradicts a fact, trust their newest statement.";
}
// Strong, accurate completion: Ollama (gpt-oss, temperature-controlled) → pollinations.
async function llmComplete(messages, maxTokens, temperature) {
  const tok = maxTokens || 1500;
  const temp = temperature != null ? temperature : 0;
  for (let a = 0; a < Math.max(1, Math.min(3, OLLAMA_KEYS.length || 1)); a++) {
    const olKey = ollamaPickKey();
    const headers = { "content-type": "application/json" };
    if (olKey) headers["Authorization"] = "Bearer " + olKey;
    try {
      const r = await fetch(OLLAMA_CHAT_URL, { method: "POST", headers, body: JSON.stringify({ model: (TIERS.pro && TIERS.pro.model) || "gpt-oss:120b-cloud", messages, stream: false, options: { temperature: temp, num_predict: tok } }) });
      if (r.ok) { const j = await r.json().catch(() => null); const c = j && j.message && j.message.content; if (typeof c === "string" && c.trim()) return c; break; }
      if (olKey && (r.status === 429 || r.status === 402 || r.status === 403)) { ollamaMarkLimited(olKey, r.status); continue; }
      break;
    } catch (_) { break; }
  }
  try {
    const r = await fetch(FALLBACK_URL, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ model: FALLBACK_MODEL, messages, stream: false, temperature: temp, max_tokens: tok }) });
    if (!r.ok) return "";
    const j = await r.json().catch(() => null);
    const c = j && j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content;
    return typeof c === "string" ? c : "";
  } catch (_) { return ""; }
}
// Translation completion: Gemini first (reliable + fast), then llmComplete (Ollama→pollinations).
// Hard timeout so the announcements AR/EN toggle never hangs.
async function translateComplete(messages) {
  if (GEMINI_API_KEY) {
    const ac = new AbortController();
    const to = setTimeout(() => ac.abort(), 22000);
    try {
      const r = await fetch(GEMINI_OAI_URL, { method: "POST", headers: { "content-type": "application/json", "Authorization": "Bearer " + GEMINI_API_KEY }, body: JSON.stringify({ model: GEMINI_TEXT_MODELS[0] || "gemini-2.5-flash", messages, temperature: 0.2 }), signal: ac.signal });
      if (r.ok) { const j = await r.json().catch(() => null); const c = j && j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content; if (typeof c === "string" && c.trim()) return c; }
    } catch (_) {} finally { clearTimeout(to); }
  }
  return await llmComplete(messages, 1500, 0.2);
}
async function memoryLearn(user, userText, aiText) {
  const existing = userMemory(user);
  const sys =
    "You extract durable facts about a USER. Preserve name, age, country, city EXACTLY as stated " +
    "(from Iraq -> 'From Iraq'; age 16 -> 'Age: 16'; never change or guess). " +
    "Capture name, age, country, job, language, likes, projects, goals, interests, and any personal detail. " +
    "Return ONLY a JSON array of short strings. If nothing, []." +
    (existing.length ? " Skip facts already in: " + JSON.stringify(existing.slice(-50)) : "");
  const u = 'The USER said: "' + userText + '". Return JSON array of facts:';
  const msgs = [{ role: "system", content: sys }, { role: "user", content: u }];
  const collected = new Map();
  const temps = [0, 0.5, 0.8]; // varied temps → fuller union; run in PARALLEL for speed
  const outs = await Promise.all(temps.map((t) => llmComplete(msgs, 1500, t)));
  for (const out of outs) {
    let arr = []; try { const mm = out.match(/\[[\s\S]*\]/); if (mm) arr = JSON.parse(mm[0]); } catch (_) {}
    if (Array.isArray(arr)) for (const f of arr) { const s = String(f || "").trim(); if (s && s.length <= 140) { const k = s.toLowerCase(); if (!collected.has(k)) collected.set(k, s); } }
  }
  let added = 0; const seen = new Set(existing.map((f) => String(f).toLowerCase().trim()));
  for (const s of collected.values()) { const k = s.toLowerCase(); if (seen.has(k)) continue; seen.add(k); existing.push(s); added++; }
  // Write ONLY users/<id>/memory. This call holds its user snapshot for the several
  // seconds the three llmComplete() calls take, and the client fires it after EVERY
  // assistant turn — a whole-record PUT here reverted the quota bump (and a redeem)
  // that /api/chat had written in the meantime.
  if (added) { while (existing.length > MEMORY_MAX) existing.shift(); try { await saveUserChild(user, "memory", existing); } catch (_) {} }
  return added;
}

function hasImages(messages) {
  for (let i = messages.length - 1; i >= 0; i--) { const m = messages[i]; if (m && m.role === "user") return Array.isArray(m.images) && m.images.length > 0; }
  return false;
}
function stripImages(messages) { return messages.map((m) => { if (m && Array.isArray(m.images)) { const { images, ...rest } = m; return rest; } return m; }); }
function buildVisionMessages(messages) {
  let budget = MAX_IMAGES_PER_REQUEST;
  return messages.map((m) => {
    const out = { role: m && typeof m.role === "string" ? m.role : "user", content: String((m && m.content) ?? "") };
    if (m && Array.isArray(m.images) && m.images.length && budget > 0) {
      const imgs = []; for (const raw of m.images) { if (budget <= 0) break; const n = normalizeImage(raw); if (n) { imgs.push(n); budget--; } }
      if (imgs.length) out.images = imgs;
    }
    return out;
  });
}
/* ── BACKTRACK SCRUBBER — PARITY WITH server.mjs ─────────────────────────────────────
   This whole block is COPIED BYTE-FOR-BYTE from server.mjs and must stay that way; the
   dual-backend rule means a fix applied to one is a bug left in the other.

   It was missing here entirely, which mattered because netlify IS the deployed backend.
   app.js does run scrubBacktrackFull() on the client, so the corrections were never
   PERMANENT — but the client scrubs the whole accumulated answer on each paint, so a
   self-correction streamed in, was painted, and then VANISHED one frame later. On the
   self-hosted server the same text is held back and never shown at all. Same answer,
   two different reading experiences, and the deployed one is the worse of the two.

   Holding it server-side also keeps the new incremental painter on its fast path: a
   retroactive edit to already-settled text forces a full rebuild of the answer DOM.
   ──────────────────────────────────────────────────────────────────────────────── */
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

function sseFrame(content, reasoning) {
  const delta = {}; if (content) delta.content = content; if (reasoning) delta.reasoning = reasoning;
  if (!("content" in delta) && !("reasoning" in delta)) return "";
  return `data: ${JSON.stringify({ choices: [{ delta }] })}\n\n`;
}
function stripEngineAd(text) {
  if (!text) return text; let t = text;
  const cut = t.search(/\n*\s*(?:[-—*_]{2,}\s*)?\**\s*(?:support\s+|powered\s+by\s+)*pollinations|support our mission|🌸|free text api/i);
  if (cut !== -1) t = t.slice(0, cut);
  t = t.replace(/^.*pollinations.*$/gim, "").replace(/^\s*\**\s*ad\s*\**\s*$/gim, "");
  return t.replace(/\s+$/, "");
}

// Stream the AI reply as SSE. Returns a Response immediately; upstream work runs
// inside the stream so the 40s header timeout is satisfied and the body can run
// for minutes. Tries Ollama first; on connect failure falls back to pollinations.
function chatStreamResponse(messages, tier, think, vision, scrubBt) {
  const ac = new AbortController();
  const startedAt = Date.now();
  let idleTimer = setTimeout(() => ac.abort("idle"), UPSTREAM_IDLE_MS);
  const hardTimer = setTimeout(() => ac.abort("max"), UPSTREAM_MAX_MS);
  const clearDeadlines = () => { clearTimeout(idleTimer); clearTimeout(hardTimer); };
  const keepAlive = () => {
    clearTimeout(idleTimer);
    if (Date.now() - startedAt >= UPSTREAM_MAX_MS) return;
    idleTimer = setTimeout(() => ac.abort("idle"), UPSTREAM_IDLE_MS);
  };
  const ollamaMessages = vision ? buildVisionMessages(messages) : stripImages(messages);
  const modelOverride = vision ? OLLAMA_MODEL_VISION : undefined;

  // `closed` is hoisted so cancel() (client disconnect / Stop) can mark it; every
  // controller op is guarded so a post-cancel enqueue/close can never throw an
  // unhandled TypeError in the isolate.
  let closed = false;
  const body = new ReadableStream({
    async start(controller) {
      // Progress is the proof the upstream is alive — every emitted chunk pushes the idle
      // deadline out. `raw` is the single funnel all ~20 emit sites go through, so arming it
      // here cannot be missed as engines are added.
      const raw = (s) => { if (closed || !s) return; try { controller.enqueue(te.encode(s)); keepAlive(); } catch (_) { closed = true; } };

      /* The scrubber is applied HERE rather than at each of the ~20 emit sites. Every one of
         them goes through sseFrame(), so intercepting the finished frame and re-framing the
         scrubbed content covers all of them at once and cannot drift as engines are added.
         The frame is our own construction three lines up, so parsing it back is exact.
         Reasoning is passed through untouched — server.mjs scrubs content only. */
      const bt = scrubBt ? makeBacktrackScrubber() : null;
      const enc = !bt ? raw : (s) => {
        if (closed || !s || !s.startsWith("data: ")) return raw(s);
        let obj;
        try { obj = JSON.parse(s.slice(6)); } catch (_) { return raw(s); }
        const d = obj && obj.choices && obj.choices[0] && obj.choices[0].delta;
        if (!d || typeof d.content !== "string" || !d.content) return raw(s);
        const cleaned = bt.push(d.content);
        // Held back this tick: emit nothing, unless the same frame also carried reasoning.
        if (!cleaned) return d.reasoning ? raw(sseFrame("", d.reasoning)) : undefined;
        return raw(sseFrame(cleaned, d.reasoning));
      };

      const finish = () => {
        if (closed) return;
        // Whatever the scrubber is still holding must go out BEFORE [DONE], or the answer
        // loses its final sentence — the same bug flush() exists to prevent server-side.
        if (bt) { try { const tail = bt.flush(); if (tail) raw(sseFrame(tail)); } catch (_) {} }
        closed = true;
        try { controller.enqueue(te.encode("data: [DONE]\n\n")); } catch (_) {}
        try { controller.close(); } catch (_) {}
        clearDeadlines();
      };
      try {
        let served = false;
        // VISION → strong CLOUD multimodal model FIRST (Gemini). On the deployed site there is no
        // local GPU, so this is the primary image reader; Ollama-cloud vision is the fallback.
        if (vision && GEMINI_API_KEY) {
          served = await streamGeminiVisionInto(enc, messages, ac.signal);
        }
        // Max tier → premium external engines FIRST: Claude Sonnet (paid), then
        // OpenRouter free (DeepSeek-R1) when Claude has no credit/fails.
        if (tier === "max" && !vision && !served) {
          // Max = Qwen3.5 397B (free Ollama) FIRST — strongest tier, zero credit. External engines fall back.
          served = await streamOllamaInto(enc, ollamaMessages, tier, think, ac.signal);   // Qwen3.5 397B
          if (!served && !closed) served = await streamGeminiInto(enc, messages, ac.signal, think);
          if (!served && !closed) served = await streamAnthropicInto(enc, messages, ac.signal);
          if (!served && !closed) served = await streamOpenRouterInto(enc, messages, ac.signal);
        }
        // Max (non-vision) already exhausted its Ollama attempt in the premium chain above —
        // don't burn seconds retrying the same dead pool before the rescue chain answers.
        // server.mjs has carried this guard for a while (5260); the EDGE function is what Netlify
        // actually deploys (netlify.toml line 4), so until now the fix had never shipped. Every
        // Firas Agent and Firas Code call runs on tier "max", so a saturated pool charged each of
        // them a SECOND full pass — attempts × a 12 s head timeout — before Gemini Flash (~1 s to
        // first token) was ever asked. That doubled silence is the "very slow" users feel.
        const okOllama = served ? true : ((tier === "max" && !vision) ? false : await streamOllamaInto(enc, ollamaMessages, tier, think, ac.signal, modelOverride));
        if (!okOllama && !closed) {
          if (vision) {
            // Gemini + Ollama vision failed → free OpenRouter vision model reads the image before giving up.
            let vr = await streamOpenRouterVisionInto(enc, messages, ac.signal);
            if (!vr && !closed) enc(sseFrame("The Firas AI vision engine is offline right now, so I can't view images. Please try again shortly."));
          }
          else {
            // RESCUE CHAIN — FAST providers first so a saturated Ollama pool doesn't slow the reply:
            // 1) Gemini Flash (free, ~1s first token), 2) OpenRouter free, 3) the tier's Ollama
            // fallback model (same slow pool — near-last), 4) last-resort pollinations.
            const fb = TIERS[tier] && TIERS[tier].fallbackModel;
            // HARD tasks (Max tier / math / science / exam) → CF REASONING model for correctness; normal
            // chat stays on the fast model. (Agent always runs tier "max" → always the strong model.)
            const cfHard = tier === "max" || CF_HARD_RE.test(cfLastUserText(messages));
            const cfModel = cfHard ? CF_TEXT_MODEL_STRONG : CF_TEXT_MODEL;
            let recovered = await streamGeminiInto(enc, messages, ac.signal, think);
            if (!recovered && !closed) recovered = await streamCloudflareTextInto(enc, messages, ac.signal, cfModel);   // free, ANY country
            if (!recovered && !closed && cfModel !== CF_TEXT_MODEL) recovered = await streamCloudflareTextInto(enc, messages, ac.signal, CF_TEXT_MODEL);   // strong model empty → fast model
            if (!recovered && !closed) recovered = await streamOpenRouterInto(enc, messages, ac.signal);
            if (!recovered && !closed && fb) recovered = await streamOllamaInto(enc, ollamaMessages, tier, think, ac.signal, fb);
            if (!recovered && !closed) await streamFallbackInto(enc, stripImages(messages), tier, think, ac.signal);
          }
        }
      } catch (e) {
        if (!ac.signal.aborted) enc(sseFrame("Something went wrong with the Firas AI engine. Please try again."));
      } finally { finish(); }
    },
    cancel() { closed = true; try { ac.abort(); } catch (_) {} clearDeadlines(); },
  });
  return new Response(body, { headers: { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-cache, no-transform", "Connection": "keep-alive", "X-Accel-Buffering": "no" } });
}

// Returns true on success (stream delivered or aborted), false if Ollama unreachable.
async function streamOllamaInto(enc, messages, tier, think, signal, modelOverride) {
  const t = TIERS[tier]; const model = modelOverride || t.model;
  const thinkVal = think ? (/gpt-oss/i.test(model) ? "high" : true) : false;
  const reqBody = JSON.stringify({ model, messages, stream: true, think: thinkVal, options: { temperature: t.temperature, num_predict: t.num_predict } });
  /* The 12s head-timeout below covers only the RESPONSE HEADERS. A model the cloud does not host
     returns 200 immediately and then never writes a body, so the timeout passes and the reader
     below waits forever. This deadline covers the first BYTE, which is the thing that actually
     proves the model is alive. */
  let firstByte = false, starved = false;
  const fbAc = new AbortController();
  const fbTimer = setTimeout(() => {
    if (firstByte) return;
    starved = true;
    modelMarkDead(model);
    try { fbAc.abort("first-byte"); } catch (_) {}
  }, OLLAMA_FIRST_BYTE_MS);
  const settle = () => { clearTimeout(fbTimer); };

  let upstream = null;
  // FAST-FAIL: short backoff + a 12s head-timeout per try. When the Ollama pool is saturated we
  // abandon it in ~2-3s and let a fast provider (Gemini) answer. A QUOTA hit (429/402/403) marks
  // that KEY limited and rotates IMMEDIATELY to the next key in the pool.
  const BACKOFF = [400, 900];
  const BACKOFF_429 = [1200, 2500];
  let was429 = false;
  const attemptsMax = Math.max(2, OLLAMA_KEYS.length + 1);
  for (let attempt = 0; attempt < attemptsMax; attempt++) {
    const olKey = ollamaPickKey();
    const headers = { "content-type": "application/json" };
    if (olKey) headers["Authorization"] = "Bearer " + olKey;
    try {
      const hc = new AbortController();
      const ht = setTimeout(() => { try { hc.abort(); } catch (_) {} }, 12000);
      const onOuter = () => { try { hc.abort(); } catch (_) {} };
      try { signal.addEventListener("abort", onOuter, { once: true }); } catch (_) {}
      try { fbAc.signal.addEventListener("abort", onOuter, { once: true }); } catch (_) {}
      try {
        upstream = await fetch(OLLAMA_CHAT_URL, { method: "POST", headers, body: reqBody, signal: hc.signal });
      } finally { clearTimeout(ht); try { signal.removeEventListener("abort", onOuter); } catch (_) {} }
      if (upstream.ok && upstream.body) break;
      const st = upstream.status;
      was429 = st === 429;
      upstream = null;
      if (olKey && (st === 429 || st === 402 || st === 403)) {
        ollamaMarkLimited(olKey, st);
        if (OLLAMA_KEYS.some((k) => k !== olKey && Date.now() >= (_olCooldown.get(k) || 0))) continue;   // fresh key → no backoff
        break;   // NO healthy key left → bail now; the rescue chain (Gemini → CF → OpenRouter → pollinations) answers fast
      }
    } catch (e) { if (starved) { settle(); return false; } if (signal.aborted) { settle(); return true; } upstream = null; }
    if (attempt < attemptsMax - 1) await new Promise((r) => setTimeout(r, (was429 ? BACKOFF_429 : BACKOFF)[Math.min(attempt, 1)]));
  }
  if (!upstream) { settle(); return false; } // unreachable -> caller falls back
  const reader = upstream.body.getReader(); let buffer = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (starved) { settle(); try { reader.cancel(); } catch (_) {} return false; }
      if (done) break;
      buffer += td.decode(value, { stream: true });
      let nl;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, nl).trim(); buffer = buffer.slice(nl + 1);
        if (!line) continue;
        let obj; try { obj = JSON.parse(line); } catch { continue; }
        const msg = obj.message || {};
        const content = msg.content || "";
        const reasoning = think ? (msg.thinking || "") : "";
        if (content || reasoning) {
          if (!firstByte) { firstByte = true; clearTimeout(fbTimer); }   // it spoke
          const f = sseFrame(content, reasoning); if (f) enc(f);
        }
        if (obj.done) { settle(); return true; }
      }
    }
    const tail = buffer.trim();
    if (tail) { try { const obj = JSON.parse(tail); const msg = obj.message || {}; const r = think ? (msg.thinking || "") : ""; if (msg.content || r) { const f = sseFrame(msg.content || "", r); if (f) enc(f); } } catch (_) {} }
    settle();
    return true;
  } catch (e) {
    settle();
    // Nothing was written yet, so the caller can still rescue cleanly.
    if (starved || (!firstByte && !signal.aborted)) return false;
    return true;
  }
}

// Streaming <think>…</think> stripper for reasoning models (qwq / deepseek-r1): suppress the
// chain-of-thought (streamed in the same response field) and forward only the real answer. Safe on
// non-reasoning output (auto-flushes if no <think> opens). Returns the visible text for a token.
function makeThinkStripper() {
  let done = false, inside = false, buf = "", seen = 0;
  return {
    push(tok) {
      if (done) return tok;
      buf += tok; seen += tok.length;
      if (!inside && buf.indexOf("<think>") !== -1) inside = true;
      const close = buf.indexOf("</think>");
      if (close !== -1) { done = true; const after = buf.slice(close + 8); buf = ""; return after; }
      if (inside) { if (buf.length > 24) buf = buf.slice(-24); return ""; }
      if (seen > 240) { done = true; const out = buf; buf = ""; return out; }
      return "";
    },
    flush() { if (done || inside) { done = true; return ""; } const out = buf; buf = ""; done = true; return out; },
  };
}
/* Cloudflare Workers AI TEXT — free (10k neurons/day), works from any country. Rotates the same CF
   accounts used for images (429 cooldown aware). Returns true if it streamed any bytes. A strong
   reasoning model (model !== CF_TEXT_MODEL) gets a larger token budget and its <think> stripped. */
async function streamCloudflareTextInto(enc, messages, signal, model, maxTokens) {
  if (!CF_ACCOUNTS.length) return false;
  const useModel = model || CF_TEXT_MODEL;
  const strip = useModel !== CF_TEXT_MODEL;
  /* The rescue engines were capped low enough to truncate the very documents they were
     rescuing: a long worksheet that fell through to Cloudflare stopped at 4096 tokens and the
     user got half a file with no indication why. Raised, and still env-overridable so a model
     that rejects the larger ask can be dialled back without a redeploy. */
  const cap = maxTokens || Number(env("CF_MAX_TOKENS")) || (strip ? 16384 : 8192);
  const msgs = messages.filter((m) => m.role === "system" || m.role === "user" || m.role === "assistant")
    .map((m) => ({ role: m.role, content: String(m.content || "") }));
  if (!msgs.length) return false;
  for (let k = 0; k < CF_ACCOUNTS.length; k++) {
    const acct = CF_ACCOUNTS[(_cfNext + k) % CF_ACCOUNTS.length];
    if (Date.now() < (_cfCooldown.get("txt:" + acct.id) || 0)) continue;
    let upstream;
    try {
      upstream = await fetch("https://api.cloudflare.com/client/v4/accounts/" + acct.id + "/ai/run/" + useModel, {
        method: "POST",
        headers: { "content-type": "application/json", "Authorization": "Bearer " + acct.token },
        body: JSON.stringify({ messages: msgs, stream: true, max_tokens: cap }),
        signal,
      });
    } catch (e) { if (signal.aborted) return true; continue; }
    if (!upstream.ok || !upstream.body) {
      if (upstream && upstream.status === 429) _cfCooldown.set("txt:" + acct.id, Date.now() + 20 * 60000);
      try { upstream && upstream.body && upstream.body.cancel(); } catch (_) {}
      continue;
    }
    const reader = upstream.body.getReader(); let buffer = "", any = false;
    const strip_ = strip ? makeThinkStripper() : null;
    try {
      while (true) {
        const { done, value } = await reader.read(); if (done) break;
        buffer += td.decode(value, { stream: true });
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
            if (out) { const f = sseFrame(out); if (f) enc(f); any = true; }
          }
        }
      }
      if (strip_) { const tail = strip_.flush(); if (tail) { const f = sseFrame(tail); if (f) enc(f); any = true; } }
      if (any) { _cfNext = (_cfNext + k + 1) % CF_ACCOUNTS.length; return true; }
    } catch (e) { if (signal.aborted) return true; }
  }
  return false;
}

async function streamFallbackInto(enc, messages, tier, think, signal) {
  let upstream;
  try { upstream = await fetch(FALLBACK_URL, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ model: FALLBACK_MODEL, messages: stripImages(messages), stream: true }), signal }); }
  catch (e) { if (signal.aborted) return; const f = sseFrame("The Firas AI engine is unavailable right now. Please try again."); if (f) enc(f); return; }
  if (!upstream.ok || !upstream.body) { const f = sseFrame("The Firas AI engine is busy right now. Please try again."); if (f) enc(f); return; }
  const reader = upstream.body.getReader(); let buffer = "", answer = "", reasoningAcc = "";
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      buffer += td.decode(value, { stream: true });
      let nl;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        let line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1);
        if (line.endsWith("\r")) line = line.slice(0, -1);
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim(); if (!payload) continue;
        if (payload === "[DONE]") { buffer = ""; break; }
        let evt; try { evt = JSON.parse(payload); } catch { continue; }
        const delta = (evt.choices && evt.choices[0] && evt.choices[0].delta) || {};
        if (delta.content) answer += delta.content;
        if (think && (delta.reasoning || delta.reasoning_content)) reasoningAcc += delta.reasoning || delta.reasoning_content;
      }
    }
    const cleaned = stripEngineAd(answer);
    if (reasoningAcc) { const f = sseFrame("", reasoningAcc); if (f) enc(f); }
    if (cleaned) { const f = sseFrame(cleaned, ""); if (f) enc(f); }
    else if (!reasoningAcc) { const f = sseFrame("The Firas AI engine is busy right now. Please try again."); if (f) enc(f); }
  } catch (e) { /* end gracefully */ }
}

// ── Max engine: Claude (Anthropic Messages API → our SSE). Returns true if it
// streamed any answer, false if it failed BEFORE any bytes (no key / no-credit /
// error) so the caller can fall back. Does NOT send [DONE] (finish() does). ──
async function streamAnthropicInto(enc, messages, signal) {
  if (!ANTHROPIC_API_KEY) return false;
  const system = messages.filter((m) => m.role === "system").map((m) => String(m.content || "")).join("\n\n");
  const conv = messages.filter((m) => m.role === "user" || m.role === "assistant").map((m) => ({ role: m.role, content: String(m.content || "") }));
  while (conv.length && conv[0].role !== "user") conv.shift();
  if (!conv.length) return false;
  const reqBody = JSON.stringify({ model: ANTHROPIC_MODEL, max_tokens: ANTHROPIC_MAX_TOK, stream: true, ...(system ? { system } : {}), messages: conv });
  let upstream;
  try { upstream = await fetch(ANTHROPIC_URL, { method: "POST", headers: { "content-type": "application/json", "x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01" }, body: reqBody, signal }); }
  catch (e) { return signal.aborted ? true : false; }
  if (!upstream.ok || !upstream.body) { try { upstream && upstream.body && upstream.body.cancel(); } catch (_) {} return false; }
  const reader = upstream.body.getReader(); let buffer = "", any = false;
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      buffer += td.decode(value, { stream: true });
      let nl;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        let line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1);
        if (line.endsWith("\r")) line = line.slice(0, -1);
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (!payload || payload === "[DONE]") continue;
        let evt; try { evt = JSON.parse(payload); } catch { continue; }
        if (evt.type === "content_block_delta" && evt.delta) {
          if (evt.delta.type === "text_delta" && evt.delta.text) { const f = sseFrame(evt.delta.text); if (f) enc(f); any = true; }
          else if (evt.delta.type === "thinking_delta" && evt.delta.thinking) { const f = sseFrame("", evt.delta.thinking); if (f) enc(f); }
        } else if (evt.type === "error" && !any) { return false; }
      }
    }
    return any;
  } catch (e) { return signal.aborted ? true : any; }
}

// ── Max engine: OpenRouter (OpenAI-compatible, free DeepSeek-R1) ──
async function streamGeminiInto(enc, messages, signal, think) {
  if (!GEMINI_API_KEY) return false;
  const msgs = messages.filter((m) => m.role === "system" || m.role === "user" || m.role === "assistant").map((m) => ({ role: m.role, content: String(m.content || "") }));
  if (!msgs.length) return false;
  for (const model of GEMINI_TEXT_MODELS) {
    /* THINKING — mirrors server.mjs _geminiStream exactly. This is the OpenAI-COMPAT endpoint,
       so the switch is reasoning_effort and thoughts arrive on delta.reasoning_content. Gated
       on `think`, so with the toggle off the body is byte-identical to what shipped before. */
    let askThink = !!think;
    let upstream = null;
    let key = gemPick() || GEMINI_API_KEY;           // rotate the pool + cool a failing key (parity with server.mjs)
    for (;;) {
      const reqBody = JSON.stringify(askThink
        ? { model, messages: msgs, stream: true, reasoning_effort: "low" }
        : { model, messages: msgs, stream: true });
      try { upstream = await fetch(GEMINI_OAI_URL, { method: "POST", headers: { "content-type": "application/json", "Authorization": "Bearer " + key }, body: reqBody, signal }); }
      catch (e) { if (signal.aborted) return true; gemMark(key, 0); upstream = null; break; }
      /* A rejected reasoning_effort must NOT cost us the engine — Gemini is rescue slot #1 and
         holds the only reliably-present text key, so a 400 here would drop every tier to the
         next engine. Retry once without the field. Deliberately NOT gemMark'd: the key is fine,
         the field was the problem, and cooling it would punish a healthy key. */
      if (upstream.status === 400 && askThink) {
        try { upstream.body && upstream.body.cancel(); } catch (_) {}
        askThink = false;
        continue;
      }
      break;
    }
    if (!upstream) continue;
    if (!upstream.ok || !upstream.body) { gemMark(key, upstream && upstream.status); try { upstream && upstream.body && upstream.body.cancel(); } catch (_) {} continue; }
    const reader = upstream.body.getReader(); let buffer = "", any = false;
    try {
      while (true) {
        const { done, value } = await reader.read(); if (done) break;
        buffer += td.decode(value, { stream: true });
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
            /* Thoughts stream LIVE, but must NEVER set `any`: a thought-only stream reporting
               itself as served would cancel the rest of the rescue chain and leave the user a
               thinking panel above an empty answer. Only content means "served". */
            const rz = delta.reasoning_content || delta.reasoning;
            if (rz) { const f = sseFrame("", rz); if (f) enc(f); }
            if (delta.content) { const f = sseFrame(delta.content); if (f) enc(f); any = true; }
          }
        }
      }
      if (any) return true;   // served by this id; otherwise try the next candidate
    } catch (e) { return signal.aborted ? true : any; }
  }
  return false;
}
// Max-tier PRIMARY engine: DeepSeek V4 Pro via NVIDIA NIM (free, OpenAI-compatible). 15s "first
// response" timeout → bails to Gemini fast if NVIDIA is slow/unreachable. Returns true if it streamed.
async function streamDeepSeekInto(enc, messages, signal) {
  if (!NVIDIA_API_KEY) return false;
  const msgs = messages.filter((m) => m.role === "system" || m.role === "user" || m.role === "assistant").map((m) => ({ role: m.role, content: String(m.content || "") }));
  if (!msgs.length) return false;
  const ac = new AbortController();
  const fwd = () => { try { ac.abort(); } catch (_) {} };
  if (signal.aborted) ac.abort(); else signal.addEventListener("abort", fwd, { once: true });
  const cleanup = () => { try { signal.removeEventListener("abort", fwd); } catch (_) {} };
  const headTimer = setTimeout(() => { try { ac.abort(); } catch (_) {} }, 15000);
  let upstream;
  try {
    upstream = await fetch(NVIDIA_OAI_URL, {
      method: "POST",
      headers: { "content-type": "application/json", "Authorization": "Bearer " + NVIDIA_API_KEY },
      body: JSON.stringify({ model: NVIDIA_MODEL, messages: msgs, temperature: 0.6, top_p: 0.95, max_tokens: 16384, chat_template_kwargs: { thinking: false }, stream: true }),
      signal: ac.signal,
    });
  } catch (e) { clearTimeout(headTimer); cleanup(); return signal.aborted ? true : false; }
  clearTimeout(headTimer);
  if (!upstream.ok || !upstream.body) { try { upstream && upstream.body && upstream.body.cancel(); } catch (_) {} cleanup(); return false; }
  const reader = upstream.body.getReader(); let buffer = "", any = false;
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      buffer += td.decode(value, { stream: true });
      let nl;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        let line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1);
        if (line.endsWith("\r")) line = line.slice(0, -1);
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (!payload || payload === "[DONE]") continue;
        let evt; try { evt = JSON.parse(payload); } catch { continue; }
        const delta = evt.choices && evt.choices[0] && evt.choices[0].delta;
        if (delta && delta.content) { const f = sseFrame(delta.content); if (f) enc(f); any = true; }
      }
    }
    if (any) { cleanup(); return true; }
  } catch (e) { cleanup(); return signal.aborted ? true : any; }
  cleanup();
  return false;
}

function b64Mime(b64) {
  const s = String(b64 || "");
  if (s.startsWith("/9j/")) return "image/jpeg";
  if (s.startsWith("iVBOR")) return "image/png";
  if (s.startsWith("R0lGOD")) return "image/gif";
  if (s.startsWith("UklGR")) return "image/webp";
  return "image/jpeg";
}
// VISION via Gemini (strong, cloud, multimodal) — the deployed site has no local GPU, so this
// is the primary image reader. Sends image(s) as data-URL image_url parts.
async function streamGeminiVisionInto(enc, messages, signal) {
  if (!GEMINI_API_KEY) return false;
  let budget = MAX_IMAGES_PER_REQUEST;
  const msgs = messages.filter((m) => m.role === "system" || m.role === "user" || m.role === "assistant").map((m) => {
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
  for (const model of GEMINI_VISION_MODELS) {
    const reqBody = JSON.stringify({ model, messages: msgs, stream: true });
    let upstream;
    // ROTATE the key pool (server.mjs:2855 already does). This path was pinned to GEMINI_KEYS[0],
    // so one 429'd key killed vision for everyone until its cooldown — and Firas Brain fires one
    // vision call per scanned page, which saturates a single free-tier key in a dozen pages.
    const key = gemPick() || GEMINI_API_KEY;
    try { upstream = await fetch(GEMINI_OAI_URL, { method: "POST", headers: { "content-type": "application/json", "Authorization": "Bearer " + key }, body: reqBody, signal }); }
    catch (e) { if (signal.aborted) return true; gemMark(key, 0); continue; }
    if (!upstream.ok || !upstream.body) { gemMark(key, upstream && upstream.status); try { upstream && upstream.body && upstream.body.cancel(); } catch (_) {} continue; }
    const reader = upstream.body.getReader(); let buffer = "", any = false;
    try {
      while (true) {
        const { done, value } = await reader.read(); if (done) break;
        buffer += td.decode(value, { stream: true });
        let nl;
        while ((nl = buffer.indexOf("\n")) !== -1) {
          let line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1);
          if (line.endsWith("\r")) line = line.slice(0, -1);
          if (!line.startsWith("data:")) continue;
          const payload = line.slice(5).trim();
          if (!payload || payload === "[DONE]") continue;
          let evt; try { evt = JSON.parse(payload); } catch { continue; }
          const delta = evt.choices && evt.choices[0] && evt.choices[0].delta;
          if (delta && delta.content) { const f = sseFrame(delta.content); if (f) enc(f); any = true; }
        }
      }
      if (any) return true;
    } catch (e) { return signal.aborted ? true : any; }
  }
  return false;
}

async function streamOpenRouterInto(enc, messages, signal) {
  if (!OPENROUTER_API_KEY) return false;
  const msgs = messages.filter((m) => m.role === "system" || m.role === "user" || m.role === "assistant").map((m) => ({ role: m.role, content: String(m.content || "") }));
  if (!msgs.length) return false;
  const reqBody = JSON.stringify({ model: OPENROUTER_MODEL, messages: msgs, stream: true });
  let upstream;
  try { upstream = await fetch(OPENROUTER_URL, { method: "POST", headers: { "content-type": "application/json", "Authorization": "Bearer " + OPENROUTER_API_KEY, "HTTP-Referer": "https://firasai.netlify.app", "X-Title": "Firas AI" }, body: reqBody, signal }); }
  catch (e) { return signal.aborted ? true : false; }
  if (!upstream.ok || !upstream.body) { try { upstream && upstream.body && upstream.body.cancel(); } catch (_) {} return false; }
  const reader = upstream.body.getReader(); let buffer = "", any = false;
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      buffer += td.decode(value, { stream: true });
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
          if (delta.reasoning) { const f = sseFrame("", delta.reasoning); if (f) enc(f); }
          if (delta.content) { const f = sseFrame(delta.content); if (f) enc(f); any = true; }
        }
      }
    }
    return any;
  } catch (e) { return signal.aborted ? true : any; }
}

/* Read attached images via a FREE OpenRouter vision model (image_url data-URL parts). Fallback for
   when Gemini/Ollama vision are unavailable, so image support never fully dies. */
async function streamOpenRouterVisionInto(enc, messages, signal) {
  if (!OPENROUTER_API_KEY || !OPENROUTER_VISION_MODELS.length) return false;
  let budget = MAX_IMAGES_PER_REQUEST;
  const msgs = messages.filter((m) => m.role === "system" || m.role === "user" || m.role === "assistant").map((m) => {
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
  for (const model of OPENROUTER_VISION_MODELS) {
    const reqBody = JSON.stringify({ model, messages: msgs, stream: true });
    let upstream;
    try { upstream = await fetch(OPENROUTER_URL, { method: "POST", headers: { "content-type": "application/json", "Authorization": "Bearer " + OPENROUTER_API_KEY, "HTTP-Referer": "https://firasai.netlify.app", "X-Title": "Firas AI" }, body: reqBody, signal }); }
    catch (e) { if (signal.aborted) return true; continue; }
    if (!upstream.ok || !upstream.body) { try { upstream && upstream.body && upstream.body.cancel(); } catch (_) {} continue; }
    const reader = upstream.body.getReader(); let buffer = "", any = false;
    try {
      while (true) {
        const { done, value } = await reader.read(); if (done) break;
        buffer += td.decode(value, { stream: true });
        let nl;
        while ((nl = buffer.indexOf("\n")) !== -1) {
          let line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1);
          if (line.endsWith("\r")) line = line.slice(0, -1);
          if (!line.startsWith("data:")) continue;
          const payload = line.slice(5).trim();
          if (!payload || payload === "[DONE]") continue;
          let evt; try { evt = JSON.parse(payload); } catch { continue; }
          const delta = evt.choices && evt.choices[0] && evt.choices[0].delta;
          if (delta && delta.content) { const f = sseFrame(delta.content); if (f) enc(f); any = true; }
        }
      }
      if (any) return true;
    } catch (e) { if (signal.aborted) return true; }
  }
  return false;
}

/* ---------------- DuckDuckGo search (ported) ---------------- */
function decodeEntities(s){ return String(s).replace(/&amp;/g,"&").replace(/&quot;/g,'"').replace(/&#x27;|&#39;/g,"'").replace(/&lt;/g,"<").replace(/&gt;/g,">").replace(/&nbsp;/g," "); }
function stripTags(s){ return decodeEntities(String(s).replace(/<[^>]+>/g,"")).replace(/\s+/g," ").trim(); }
function decodeDdgUrl(href){ try { const m=href.match(/[?&]uddg=([^&]+)/); if(m) return decodeURIComponent(m[1]); return href.startsWith("//")?"https:"+href:href; } catch { return href; } }
function parseDuckDuckGo(html) {
  const out = []; const titleRe = /<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi; let m;
  while ((m = titleRe.exec(html)) && out.length < 8) {
    const url = decodeDdgUrl(m[1]); const title = stripTags(m[2]);
    if (!title || !/^https?:\/\//i.test(url)) continue;
    const after = html.slice(titleRe.lastIndex, titleRe.lastIndex + 1500);
    const nt = after.search(/<a[^>]+class="[^"]*result__a/i);
    const win = nt >= 0 ? after.slice(0, nt) : after;
    const sm = win.match(/<a[^>]+class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)<\/a>/i);
    out.push({ title, url, snippet: sm ? stripTags(sm[1]) : "" });
  }
  return out;
}

/* ---------------- image quota helpers ---------------- */
/* The quota day is the USERS' calendar day, not the server's. This function read UTC
   fields while server.mjs read the host's local time, so production rolled every counter
   at 00:00 UTC = 03:00 in Baghdad, three hours after the app's own 429 notice promises
   "يتجدّد تلقائيًا بعد منتصف الليل" — and self-hosting the same build behaved differently
   again. Both backends now shift the instant by QUOTA_TZ_OFFSET_MINUTES (default 180 =
   UTC+3, the Arabic user base) and read UTC fields off the shifted value, so the reset
   happens at the users' midnight, at the same instant, wherever the process runs. */
const QUOTA_TZ_OFFSET_MINUTES = (() => { const n = parseInt(env("QUOTA_TZ_OFFSET_MINUTES"), 10); return Number.isFinite(n) ? n : 180; })();
function serverDay(d) {
  const ms = (d instanceof Date ? d.getTime() : (typeof d === "number" ? d : Date.now())) + QUOTA_TZ_OFFSET_MINUTES * 60000;
  const x = new Date(ms);
  return `${x.getUTCFullYear()}-${String(x.getUTCMonth()+1).padStart(2,"0")}-${String(x.getUTCDate()).padStart(2,"0")}`;
}
// Today's charged cids for a user, as an object { cid: true }. Each cid is its own
// child key so concurrent distinct-cid charges never clobber each other (no array
// read-modify-write), and the day naturally "rolls over" since the path is dated.
/* The daily image slot is derived from the IMAGE, never from a client-supplied id — see the
   quota check in the /api/image handler. Mirrors server.mjs imgCacheKey(); Deno has no
   node:crypto createHash, so this uses SubtleCrypto and is therefore async. */
async function imgSlotKey(prompt, w, h, seed) {
  const data = new TextEncoder().encode(String(prompt) + "|" + w + "x" + h + "|" + (seed || ""));
  const buf = await crypto.subtle.digest("SHA-1", data);
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
/* ── cid REUSE, CLOSED (parity with server.mjs isRepeatCharge) ───────────────────────
   The member and guest quota checks both asked "have I seen this cid before?" against a
   bare client string with no expiry and no tie to the request body. So one charged turn
   bought the whole day: send cid="X" once, then send every later question that day with
   cid="X" and `already` stayed true, skipping BOTH the limit test and the increment while
   still streaming a full answer.

   A real retry is the same cid AND the same question, seconds apart. That is what this
   matches. An agent MISSION is the exception the design intends — its steps legitimately
   share one id with different bodies — so for "agent" the id alone identifies it, bounded
   by a mission-length window instead of a retry-length one.
   Ported from server.mjs:714-739; Deno has no node:crypto, hence SubtleCrypto + async. */
const RETRY_WINDOW_MS = 120000;        // a real retry happens within seconds
const MISSION_WINDOW_MS = 45 * 60000;  // one agent mission
async function reqHash(cid, messages) {
  let lastUser = "";
  if (Array.isArray(messages)) {
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i] && messages[i].role === "user") { lastUser = String(messages[i].content || ""); break; }
    }
  }
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(cid + " " + lastUser));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}
/** True when this is a genuine retry of an already-charged request. Prunes as it goes. */
async function isRepeatCharge(bucket, product, cid, messages) {
  if (!cid) return false;
  const now = Date.now();
  const win = product === "agent" ? MISSION_WINDOW_MS : RETRY_WINDOW_MS;
  const seen = (bucket.seen && typeof bucket.seen === "object") ? bucket.seen : {};
  for (const k of Object.keys(seen)) { if (!(now - (seen[k] || 0) < MISSION_WINDOW_MS)) delete seen[k]; }
  const h = await reqHash(cid, messages);
  // agent: the mission id alone identifies it. Everything else must match the body too.
  const key = product + "_" + (product === "agent" ? cid : h);
  const hit = seen[key];
  if (hit && now - hit < win) { bucket.seen = seen; return true; }
  seen[key] = now;
  const keys = Object.keys(seen);
  if (keys.length > 400) { keys.sort((a, b) => seen[a] - seen[b]); for (let i = 0; i < keys.length - 400; i++) delete seen[keys[i]]; }
  bucket.seen = seen;
  return false;
}
/* VOICE DAILY METER — parity with server.mjs chargeVoice(). Both voice endpoints spend the
   shared GEMINI_KEYS pool and had only a per-minute rateLimited() bucket in front of them.
   On the edge that bucket is an in-isolate Map, so a burst spread across isolates each saw
   an empty one: it was never a per-user cap. This charges a real daily unit. */
async function chargeVoiceEdge(c) {
  if (!c) return null;
  if (c.isGuest) return await guestCharge(c.id, "voice", null, null);
  const u = c.user;
  if (!u) return null;
  const limit = limitsFor(planOf(u)).voice;
  if (!(limit >= 0)) return null;
  const rolled = quotaRollDay(u);
  if ((u.quota.voice || 0) >= limit) {
    return { error: "daily quota reached", quota: { product: "voice", used: u.quota.voice || 0, limit, plan: planOf(u) } };
  }
  u.quota.voice = (u.quota.voice || 0) + 1;
  try { await saveQuota(u, "voice", null, rolled); } catch (_) {}
  return null;
}
async function imgDayNode(userId) { return (await dbGet(`imgQuota/${dbKey(userId)}/${serverDay()}`)) || {}; }
// Today's charged Max-tier request ids for a user, as { cid: true } — same per-child
// scheme as images so concurrent distinct charges never clobber each other.
async function maxDayNode(userId) { return (await dbGet(`maxQuota/${dbKey(userId)}/${serverDay()}`)) || {}; }

// Generate an image via Puter's driver API using the DEVELOPER's auth token (server-
// side → end users never sign in). Real GPT-Image/Gemini quality, free. {bytes,mime}|null.
async function generateImagePuter(prompt) {
  if (!PUTER_AUTH_TOKEN) return null;
  if (Date.now() < _puterCooldownUntil) return null;
  const model = PUTER_MODEL_ALIASES[PUTER_IMAGE_MODEL] || PUTER_IMAGE_MODEL;
  const args = { prompt: String(prompt || "").slice(0, 4000), model };
  if (/gpt-image-(2|1\.5)/i.test(model) && PUTER_IMAGE_QUALITY) args.quality = PUTER_IMAGE_QUALITY;
  const ac = new AbortController();
  const to = setTimeout(() => ac.abort(), 120000);
  try {
    const r = await fetch(PUTER_DRIVER_URL, {
      method: "POST",
      headers: { "Authorization": "Bearer " + PUTER_AUTH_TOKEN, "content-type": "application/json" },
      body: JSON.stringify({ interface: "puter-image-generation", driver: "ai-image", method: "generate", args }),
      signal: ac.signal,
    });
    if (!r.ok) {
      if (r.status === 402 || /insufficient/i.test(await r.text().catch(() => ""))) { _puterCooldownUntil = Date.now() + 10 * 60000; }
      return null;
    }
    const ct = (r.headers.get("content-type") || "").toLowerCase();
    if (ct.startsWith("image/")) {
      const bytes = new Uint8Array(await r.arrayBuffer());
      return bytes.length ? { bytes, mime: ct } : null;
    }
    const txt = await r.text();
    let j = null; try { j = JSON.parse(txt); } catch (_) {}
    if (j && j.success === false) return null;
    const pick = (v) => { if (!v) return null; if (typeof v === "string") return v; if (typeof v === "object") return v.url || v.image_url || v.image || v.data || v.b64_json || v.base64 || pick(v.result) || null; return null; };
    let s = j ? (pick(j.result) || pick(j)) : txt;
    if (typeof s !== "string" || !s) return null;
    s = s.trim();
    if (s.startsWith("data:")) {
      const comma = s.indexOf(","), semi = s.indexOf(";");
      const mime = semi > 5 ? s.slice(5, semi) : "image/png";
      try { return { bytes: b64ToBytes(s.slice(comma + 1)), mime }; } catch (_) { return null; }
    }
    if (/^https?:\/\//i.test(s)) {
      const ir = await fetch(s, { signal: ac.signal });
      if (!ir.ok) return null;
      const bytes = new Uint8Array(await ir.arrayBuffer());
      return bytes.length ? { bytes, mime: ir.headers.get("content-type") || "image/png" } : null;
    }
    if (/^[A-Za-z0-9+/=\s]+$/.test(s) && s.replace(/\s+/g, "").length > 200) {
      try { const bytes = b64ToBytes(s.replace(/\s+/g, "")); if (bytes.length > 100) return { bytes, mime: "image/png" }; } catch (_) {}
    }
    return null;
  } catch (_) { return null; }
  finally { clearTimeout(to); }
}

// Generate an image via Cloudflare Workers AI (free daily quota, reliable). flux-schnell
// returns base64 in {result:{image}}; SDXL-style models return raw bytes. {bytes,mime}|null.
// One attempt against a SINGLE account. Returns {bytes,mime}, "429", or null.
async function cfTryAccount(acct, prompt, w, h) {
  const ac = new AbortController();
  const to = setTimeout(() => ac.abort(), 90000);
  try {
    const url = "https://api.cloudflare.com/client/v4/accounts/" + acct.id + "/ai/run/" + CF_IMAGE_MODEL;
    const text = String(prompt || "").slice(0, 2000);
    let r;
    if (/flux-2/i.test(CF_IMAGE_MODEL)) {
      // FLUX.2 needs multipart/form-data — don't set content-type (fetch adds the boundary).
      const fd = new FormData();
      fd.append("prompt", text); fd.append("steps", String(CF_IMAGE_STEPS));
      fd.append("width", String(w || 1024)); fd.append("height", String(h || 1024));
      r = await fetch(url, { method: "POST", headers: { "Authorization": "Bearer " + acct.token }, body: fd, signal: ac.signal });
    } else {
      const body = { prompt: text };
      if (/flux-1|schnell/i.test(CF_IMAGE_MODEL)) body.steps = Math.min(8, CF_IMAGE_STEPS); // flux-schnell max 8
      r = await fetch(url, { method: "POST", headers: { "Authorization": "Bearer " + acct.token, "content-type": "application/json" }, body: JSON.stringify(body), signal: ac.signal });
    }
    if (!r.ok) {
      if (r.status === 429 || /allocation|neurons/i.test(await r.text().catch(() => ""))) return "429";
      return null;
    }
    const ct = (r.headers.get("content-type") || "").toLowerCase();
    if (ct.startsWith("image/")) { const bytes = new Uint8Array(await r.arrayBuffer()); return bytes.length ? { bytes, mime: ct } : null; }
    const j = await r.json().catch(() => null);
    const b64 = j && ((j.result && (j.result.image || (Array.isArray(j.result.images) && j.result.images[0]))) || j.image);
    if (typeof b64 === "string" && b64.length > 100) {
      const clean = b64.startsWith("data:") ? b64.slice(b64.indexOf(",") + 1) : b64;
      try { const bytes = b64ToBytes(clean); return bytes.length ? { bytes, mime: sniffImageMime(bytes) } : null; } catch (_) { return null; }
    }
    return null;
  } catch (_) { return null; }
  finally { clearTimeout(to); }
}
// Round-robin across pooled accounts (spreads load), skipping any in 429 cooldown and
// falling over to the next on failure. Returns {bytes,mime} or null.
let _cfNext = 0;
/* ── OPENAI IMAGES (edge) — mirrors server.mjs; see the long note there ────────────────────
   Two differences forced by the environment, both deliberate:

   · There is no disk here, so the spend total lives in the database and an EDITED picture is
     stored there too — which is why edits are asked for as compressed JPEG (~200 KB) rather
     than the default PNG (~1.5 MB). Generated pictures are streamed straight back and stored
     nowhere, exactly as the other engines already are.
   · The spend total is cached in the isolate for a minute. A stale read can let a little extra
     through, which is fine: the dollar ceiling is the SOFT guard. The hard one is OpenAI's own
     billing error, which switches the engine off for the life of the isolate.
   ──────────────────────────────────────────────────────────────────────────────────────────── */
const OPENAI_API_KEY = env("OPENAI_API_KEY") || "";
/* The newest model first, with a fallback behind it. A name OpenAI does not serve comes back as
   a clean 400 in under a second — nothing like the silent hang an unhosted Ollama model causes —
   so the cost of guessing wrong here is one fast failure, and it is remembered so only the first
   request pays it. Comma-separated, strongest first. */
const OPENAI_IMAGE_MODELS = String(env("OPENAI_IMAGE_MODEL") || "gpt-image-2")
  .split(",").map((m) => m.trim()).filter(Boolean);
const _oaiModelDead = new Set();
function openaiPickImageModel() {
  return OPENAI_IMAGE_MODELS.find((m) => !_oaiModelDead.has(m)) || OPENAI_IMAGE_MODELS[0];
}
const OPENAI_IMAGE_QUALITY = env("OPENAI_IMAGE_QUALITY") || "high";
const OPENAI_IMAGE_DAILY = Number(env("OPENAI_IMAGE_DAILY") ?? 2);
const OPENAI_IMAGE_BUDGET_USD = Number(env("OPENAI_IMAGE_BUDGET_USD") ?? 60);
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
    const raw = env("OPENAI_IMAGE_PRICES");
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
const OPENAI_EDIT_KEEP = Number(env("OPENAI_EDIT_KEEP") ?? 20);   // stored edits kept per user
const OPENAI_IMAGE_TIMEOUT_MS = Number(env("OPENAI_IMAGE_TIMEOUT_MS") ?? 18000);
/* WHICH ENGINE DRAWS THE PICTURE. "gemini" puts Nano Banana first with gpt-image behind it,
   "openai" puts it back the other way round. One variable, no redeploy, no code change - the
   whole point being that trying an engine should not be a commitment. */
const IMAGE_ENGINE = String(env("IMAGE_ENGINE") || "gemini").toLowerCase();
/* A LADDER, not a guess. "Nano Banana Pro" is a marketing name and its API id is not something
   to assume; each candidate is tried and the first the account accepts is used, so a wrong name
   costs one fast 404 rather than a dead engine. /api/image/diag reports which one won. */
const GEMINI_IMAGE_MODELS = String(env("GEMINI_IMAGE_MODEL") ||
  "gemini-3-pro-image-preview,gemini-3-pro-image,gemini-2.5-flash-image")
  .split(",").map((m) => m.trim()).filter(Boolean);   // first try; the low-quality retry gets 60% of this on top
let _openaiImagesOff = false;
let _oaiSpend = { usd: 0, at: 0 };

async function openaiImageSpent() {
  if (Date.now() - _oaiSpend.at < 60000) return _oaiSpend.usd;
  let usd = 0;
  try { usd = Number(await dbGet("spend/openaiImageUsd")) || 0; } catch (_) { usd = _oaiSpend.usd; }
  _oaiSpend = { usd, at: Date.now() };
  return usd;
}
async function openaiImageBudgetLeft() {
  if (_openaiImagesOff || !OPENAI_API_KEY) return 0;
  return Math.max(0, OPENAI_IMAGE_BUDGET_USD - (await openaiImageSpent()));
}
async function openaiImageCharge(cost) {
  const next = (await openaiImageSpent()) + cost;
  _oaiSpend = { usd: next, at: Date.now() };
  try { await dbPut("spend/openaiImageUsd", next); } catch (_) {}
}
function openaiImagesExhausted(reason) {
  if (_openaiImagesOff) return;
  _openaiImagesOff = true;
  console.warn("[firas] OpenAI images disabled (" + reason + ") - falling back to Cloudflare");
}
function openaiImageSize(w, h) {
  const ratio = (Number(w) || 1024) / (Number(h) || 1024);
  if (ratio > 1.2) return "1536x1024";
  if (ratio < 0.84) return "1024x1536";
  return "1024x1024";
}
/** Today's premium images for a user, as { slot: true } — same day-scoped shape as imgQuota. */
async function oaiImgDayNode(userId) {
  try { return (await dbGet(`oaiQuota/${dbKey(userId)}/${serverDay()}`)) || {}; } catch (_) { return {}; }
}
async function openaiImageAllowed(userId, slot) {
  if ((await openaiImageBudgetLeft()) < openaiImageMaxCost()) return false;
  const node = await oaiImgDayNode(userId);
  if (slot in node) return true;                                   // same picture again — free
  return OPENAI_IMAGE_DAILY < 0 || Object.keys(node).length < OPENAI_IMAGE_DAILY;
}
async function openaiImageMark(userId, slot) {
  try { await dbPut(`oaiQuota/${dbKey(userId)}/${serverDay()}/${dbKey(slot)}`, true); } catch (_) {}
}

/* WHICH RUNG FAILED, AND WHY. Returns the picture, or a REASON so the caller knows whether to
   try the next model or give up: "model" means this name is not one this account can use and the
   next rung is worth a try; anything else means trying another name will not help. */
async function openaiImageResult(r, what, model) {
  if (!r.ok) {
    const txt = (await r.text().catch(() => "")).slice(0, 400);
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
    console.error("[firas] OpenAI " + what + " (" + model + ") HTTP " + r.status + ": " + txt);
    return { reason: "http" };
  }
  const j = await r.json().catch(() => null);
  const d = (j && j.data && j.data[0]) || null;
  const mime = what === "edit" ? "image/jpeg" : "image/png";
  if (d && d.b64_json) return { bytes: b64ToBytes(d.b64_json), mime, b64: d.b64_json };
  /* SOME MODELS ANSWER WITH A LINK, not the bytes. Reading only b64_json turned a perfectly
     good 200 into "no image", which is how a working key still ended at the bottom of the
     chain in "image generation failed" — and why a probe that checked only the HTTP status
     reported everything was fine. */
  if (d && d.url) {
    try {
      const img = await fetch(d.url);
      if (img.ok) {
        const bytes = new Uint8Array(await img.arrayBuffer());
        if (bytes.length) return { bytes, mime: img.headers.get("content-type") || mime, b64: b64FromBytes(bytes) };
      }
      console.error("[firas] OpenAI " + what + " (" + model + ") image link returned HTTP " + img.status);
    } catch (e) { console.error("[firas] OpenAI " + what + " (" + model + ") image link failed: " + ((e && e.message) || e)); }
    return { reason: "link" };
  }
  // Neither shape: say WHAT came back, so a third one is diagnosable instead of silent.
  console.error("[firas] OpenAI " + what + " (" + model + ") returned no image; payload keys: " +
    (d ? Object.keys(d).join(",") : "no data[]"));
  return { reason: "empty" };
}

/* THE PICTURE COMES FROM OPENAI, OR IT DOES NOT COME FROM OPENAI AT ALL — but it is never lost to
   a clock. Two ladders are walked here, not one.

   MODEL ladder, walked inside this request. Remembering a rejected model for the NEXT request is
   useless on the edge, where an isolate is born and discarded around a single call: the memory
   dies with it, so a wrong first name is retried forever and the working one below is never
   reached. Only a "model" verdict moves down a rung — a billing or auth failure means no other
   name helps either.

   QUALITY ladder, for the clock. The probe proved the key, the model and the payload are all
   fine: 920,368 characters of real base64 came back at low quality, inside one edge request.
   Medium renders take considerably longer, and an edge function has a wall-clock budget it does
   not get to negotiate — so a medium render that overruns is not a slow success, it is a dead
   request that takes every engine below it down with it. Rather than hand a slow medium over to
   Cloudflare, which is how a working OpenAI key kept producing a FLUX picture with mangled Arabic
   in it, we drop to low ON OPENAI and deliver that. Same engine, same text rendering, a fifth of
   the wait, and a ninth of the price.

   The quality that actually produced the picture is returned, so the caller charges for what it
   got rather than what it asked for. */
async function generateImageOpenAI(prompt, w, h) {
  if ((await openaiImageBudgetLeft()) < openaiImageMaxCost()) return null;
  const size = openaiImageSize(w, h);
  /* ONE quality, the configured one. The drop to low existed only because an edge function
     could not wait for a medium render; the background runner can, so a picture is never quietly
     downgraded to beat a stopwatch any more. */
  const qualities = [String(OPENAI_IMAGE_QUALITY || "high").toLowerCase()];

  for (const model of OPENAI_IMAGE_MODELS) {
    let modelRejected = false;
    for (let qi = 0; qi < qualities.length; qi++) {
      const quality = qualities[qi];
      /* The first attempt gets most of the budget; the retry gets what is left, so the two of
         them together still finish inside the function's lifetime. */
      const budgetMs = qi === 0 ? OPENAI_IMAGE_TIMEOUT_MS : Math.max(8000, Math.round(OPENAI_IMAGE_TIMEOUT_MS * 0.6));
      const ac = new AbortController();
      const to = setTimeout(() => { try { ac.abort(); } catch (_) {} }, budgetMs);
      const t0 = Date.now();
      let out = null;
      try {
        const r = await fetch("https://api.openai.com/v1/images/generations", {
          method: "POST",
          headers: { "content-type": "application/json", Authorization: "Bearer " + OPENAI_API_KEY },
          body: JSON.stringify({ model, prompt: String(prompt || "").slice(0, 4000), size, quality, n: 1 }),
          signal: ac.signal,
        });
        out = await openaiImageResult(r, "image", model);
      } catch (e) {
        out = { reason: ac.signal.aborted ? "slow" : "network" };
      } finally { clearTimeout(to); }

      if (out && out.bytes) {
        _oaiModelDead.delete(model);
        console.log("[firas] OpenAI image " + model + "/" + quality + " " + size +
          " in " + (Date.now() - t0) + "ms");
        out.quality = quality;                 // charge for what was made, not what was asked
        return out;
      }
      if (out && out.reason === "model") { modelRejected = true; break; }   // try the next model
      // Too slow, or a transient failure: drop a quality rung and try again on the SAME model.
      if (out && (out.reason === "slow" || out.reason === "network" || out.reason === "http")) {
        console.warn("[firas] OpenAI " + model + "/" + quality + " gave up after " +
          (Date.now() - t0) + "ms (" + out.reason + ")" +
          (qi + 1 < qualities.length ? " - retrying at " + qualities[qi + 1] : ""));
        continue;
      }
      return null;                              // auth or money: nothing else will help
    }
    if (!modelRejected) return null;            // this model was reachable and still gave nothing
    _oaiModelDead.add(model);
  }
  console.error("[firas] no OpenAI image model accepted: " + OPENAI_IMAGE_MODELS.join(", "));
  return null;
}

/** EDIT an existing picture from an instruction. The one thing no other engine here can do —
    they all generate from text alone. Walks the same ladder, for the same reason. */
async function editImageOpenAI(prompt, bytes, mime) {
  if ((await openaiImageBudgetLeft()) < openaiImageMaxCost()) return null;
  if (!bytes || !bytes.length) return null;
  for (const model of OPENAI_IMAGE_MODELS) {
    const ac = new AbortController();
    const to = setTimeout(() => { try { ac.abort(); } catch (_) {} }, OPENAI_IMAGE_TIMEOUT_MS + 10000);   // edits run a little longer
    let out = null;
    try {
      const fd = new FormData();
      fd.append("model", model);
      fd.append("prompt", String(prompt || "").slice(0, 4000));
      fd.append("quality", OPENAI_IMAGE_QUALITY);
      fd.append("n", "1");
      // JPEG so the result is small enough to keep in the database and serve back by key.
      fd.append("output_format", "jpeg");
      fd.append("output_compression", "85");
      const type = /jpe?g/i.test(mime || "") ? "image/jpeg" : /webp/i.test(mime || "") ? "image/webp" : "image/png";
      const ext = type === "image/jpeg" ? "jpg" : type === "image/webp" ? "webp" : "png";
      fd.append("image", new Blob([bytes], { type }), "source." + ext);
      const r = await fetch("https://api.openai.com/v1/images/edits", {
        method: "POST",
        headers: { Authorization: "Bearer " + OPENAI_API_KEY },
        body: fd,
        signal: ac.signal,
      });
      out = await openaiImageResult(r, "edit", model);
    } catch (e) { out = { reason: "network" }; }
    finally { clearTimeout(to); }
    if (out && out.bytes) { _oaiModelDead.delete(model); return out; }
    if (!out || out.reason !== "model") return null;
    _oaiModelDead.add(model);
  }
  return null;
}

async function oaiEditStore(userId, key, b64, mime) {
  const uid = dbKey(userId);
  try {
    await dbPut(`imgEdits/${uid}/${dbKey(key)}`, { b64, mime: mime || "image/jpeg" });
    await dbPut(`imgEditsIndex/${uid}/${dbKey(key)}`, Date.now());
    const idx = (await dbGet(`imgEditsIndex/${uid}`)) || {};
    const keys = Object.keys(idx).sort((a, b) => (idx[a] || 0) - (idx[b] || 0));
    for (const old of keys.slice(0, Math.max(0, keys.length - OPENAI_EDIT_KEEP))) {
      try { await dbDelete(`imgEdits/${uid}/${old}`); await dbDelete(`imgEditsIndex/${uid}/${old}`); } catch (_) {}
    }
  } catch (_) { /* the picture was still returned to the caller; only re-opening it is lost */ }
}
async function oaiEditLoad(userId, key) {
  try {
    const rec = await dbGet(`imgEdits/${dbKey(userId)}/${dbKey(key)}`);
    if (rec && rec.b64) return { bytes: b64ToBytes(rec.b64), mime: rec.mime || "image/jpeg" };
  } catch (_) {}
  return null;
}

async function generateImageCloudflare(prompt, w, h) {
  const n = CF_ACCOUNTS.length;
  if (!n) return null;
  for (let k = 0; k < n; k++) {
    const acct = CF_ACCOUNTS[(_cfNext + k) % n];
    if (Date.now() < (_cfCooldown.get(acct.id) || 0)) continue;
    const out = await cfTryAccount(acct, prompt, w, h);
    if (out === "429") { _cfCooldown.set(acct.id, Date.now() + 30 * 60000); continue; }
    if (out && out.bytes && out.bytes.length) { _cfNext = (_cfNext + k + 1) % n; return out; }
  }
  return null;
}

// Generate an image with Gemini (Google AI Studio). Returns {bytes, mime} or null to
// fall back to pollinations. Free key, ~500/day, no card.
async function generateImageGemini(prompt) {
  if (!GEMINI_API_KEY) return null;
  const ac = new AbortController();
  const to = setTimeout(() => ac.abort(), 45000);
  try {
    const r = await fetch("https://generativelanguage.googleapis.com/v1beta/models/" + GEMINI_IMAGE_MODEL + ":generateContent", {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_API_KEY },
      body: JSON.stringify({ contents: [{ parts: [{ text: String(prompt || "").slice(0, 4000) }] }] }),
      signal: ac.signal,
    });
    if (!r.ok) return null;
    const j = await r.json();
    const parts = j && j.candidates && j.candidates[0] && j.candidates[0].content && j.candidates[0].content.parts;
    if (Array.isArray(parts)) {
      for (const p of parts) {
        const inl = p.inlineData || p.inline_data;
        if (inl && inl.data) { try { return { bytes: b64ToBytes(inl.data), mime: inl.mimeType || inl.mime_type || "image/png" }; } catch (_) {} }
      }
    }
    return null;
  } catch (_) { return null; }
  finally { clearTimeout(to); }
}

// Generate an image with Hugging Face (FLUX.1-schnell). Returns {bytes, mime} or null.
async function generateImageHF(prompt) {
  if (!HF_API_KEY) return null;
  const ac = new AbortController();
  const to = setTimeout(() => ac.abort(), 60000);
  try {
    const r = await fetch(HF_IMAGE_URL, {
      method: "POST",
      headers: { "Authorization": "Bearer " + HF_API_KEY, "content-type": "application/json", "Accept": "image/png" },
      body: JSON.stringify({ inputs: String(prompt || "").slice(0, 2000) }),
      signal: ac.signal,
    });
    if (!r.ok) return null;
    const ct = r.headers.get("content-type") || "";
    if (!ct.startsWith("image/")) return null;
    const bytes = new Uint8Array(await r.arrayBuffer());
    return bytes.length ? { bytes, mime: ct } : null;
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
const HF_VIDEO_SPACES = (env("HF_VIDEO_SPACES") ||
  "Lightricks/ltx-video-distilled")
  .split(",").map((s) => s.trim()).filter(Boolean);
const HF_VIDEO_API = env("HF_VIDEO_API") || "/text_to_video";
/* Seconds per clip. 6 is the tested sweet spot: the model returns 5.90 s and the whole call
   lands ~19 s, comfortably inside a 60 s @spaces.GPU slot. Longer clips are not merely slower —
   they raise the odds of exceeding the Space's own duration cap and failing outright. */
const VIDEO_SECONDS = Math.min(10, Math.max(2, parseInt(env("VIDEO_SECONDS"), 10) || 6));
const VIDEO_W = Math.min(1280, Math.max(256, parseInt(env("VIDEO_W"), 10) || 704));
const VIDEO_H = Math.min(1280, Math.max(256, parseInt(env("VIDEO_H"), 10) || 512));
/* Per-user DAILY cap. 2 by default — the owner's number. -1 disables the cap. */
const VIDEO_DAILY_LIMIT = (() => { const n = parseInt(env("VIDEO_DAILY_LIMIT"), 10); return Number.isFinite(n) ? n : 2; })();

/* Up to 18 tokens: HF_ACCOUNTS="hf_a,hf_b,…" plus the single HF_API_KEY, de-duplicated. */
const HF_ACCOUNTS = (() => {
  const out = [];
  const add = (t) => { const v = String(t || "").trim(); if (v && !out.includes(v)) out.push(v); };
  for (const t of (env("HF_ACCOUNTS") || "").split(",")) add(t);
  for (let i = 1; i <= 18; i++) add(env("HF_API_KEY_" + i));
  add(env("HF_API_KEY"));
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

/* Deno has no node:crypto createHash — the slot hash uses SubtleCrypto, like imgSlotKey. */
async function vidSlotKey(prompt, seconds, seed) {
  const data = new TextEncoder().encode("v1|" + String(prompt) + "|" + seconds + "|" + (seed || ""));
  const buf = await crypto.subtle.digest("SHA-1", data);
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
/* The day is the PATH, so it rolls over on its own — same trick imgQuota uses. */
async function vidDayNode(userId) { return (await dbGet(`vidQuota/${dbKey(userId)}/${serverDay()}`)) || {}; }

/* ============================================================================
   ROUTER
   ============================================================================ */
/* ---------------- VOICE (Deno port): /api/tts + /api/transcribe ----------------
   Arabic → Gemini EXPRESSIVE TTS (generative, emotional). Other languages → Google
   Translate TTS (Edge neural TTS needs a Node raw-WS and can't run on Deno edge, so
   it's skipped here; the browser speechSynthesis is the client's final fallback).
   /api/transcribe → Gemini (multimodal audio). All keyless-for-users via the pool. */
const GEMINI_TTS_MODEL = env("GEMINI_TTS_MODEL") || "gemini-2.5-flash-preview-tts";
const GEMINI_TTS_VOICE = env("GEMINI_TTS_VOICE") || "Sadaltager";
const TTS_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
function ttsStyleAr(lang) {
  return String(lang || "").startsWith("ar")
    ? "أنت فِراس، شابٌّ عربيّ ودود. انطق النص التالي بعربية فصيحة سليمة النطق، بروح دافئة حيوية عفوية وبوتيرة سريعة قليلاً، كأنك تتحدث مع صديق — لا جمود ولا رتابة. النص: "
    : "You are Firas, a friendly voice assistant. Say the following in a warm, lively, natural spoken tone at a slightly brisk pace, like talking to a friend. Text: ";
}
function ttsB64ToBytes(b64) { const bin = atob(b64); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u; }
function pcmToWav(pcm, rate) {
  const n = pcm.length, buf = new Uint8Array(44 + n), dv = new DataView(buf.buffer);
  const ws = (o, s) => { for (let i = 0; i < s.length; i++) dv.setUint8(o + i, s.charCodeAt(i)); };
  ws(0, "RIFF"); dv.setUint32(4, 36 + n, true); ws(8, "WAVE"); ws(12, "fmt "); dv.setUint32(16, 16, true);
  dv.setUint16(20, 1, true); dv.setUint16(22, 1, true); dv.setUint32(24, rate, true); dv.setUint32(28, rate * 2, true);
  dv.setUint16(32, 2, true); dv.setUint16(34, 16, true); ws(36, "data"); dv.setUint32(40, n, true); buf.set(pcm, 44); return buf;
}
function ttsChunks(text, max) {
  const parts = String(text).split(/(?<=[.!?؟،؛\n])\s+/); const out = []; let cur = "";
  for (let s of parts) { s = s.trim(); if (!s) continue; while (s.length > max) { let cut = s.lastIndexOf(" ", max); if (cut < max * 0.5) cut = max; out.push(s.slice(0, cut).trim()); s = s.slice(cut).trim(); } if ((cur + " " + s).trim().length > max) { if (cur) out.push(cur.trim()); cur = s; } else cur = cur ? cur + " " + s : s; }
  if (cur.trim()) out.push(cur.trim()); return out.filter(Boolean).slice(0, 14);
}
async function fetchTO(url, opts, ms) { const ac = new AbortController(); const to = setTimeout(() => ac.abort(), ms || 10000); try { return await fetch(url, Object.assign({ signal: ac.signal }, opts || {})); } finally { clearTimeout(to); } }
async function geminiTtsSynth(text, lang) {
  if (!GEMINI_KEYS.length) return null;
  const body = JSON.stringify({ contents: [{ parts: [{ text: ttsStyleAr(lang) + text }] }], generationConfig: { responseModalities: ["AUDIO"], speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: GEMINI_TTS_VOICE } } } } });
  for (let i = 0; i < Math.min(GEMINI_KEYS.length, 4); i++) {
    const key = gemPick(); if (!key) break;
    let r; try { r = await fetchTO("https://generativelanguage.googleapis.com/v1beta/models/" + GEMINI_TTS_MODEL + ":generateContent", { method: "POST", headers: { "content-type": "application/json", "x-goog-api-key": key }, body }, 40000); } catch (_) { gemMark(key, 0); continue; }
    if (!r.ok) { gemMark(key, r.status); continue; }
    const j = await r.json().catch(() => null);
    const parts = j && j.candidates && j.candidates[0] && j.candidates[0].content && j.candidates[0].content.parts;
    const inl = Array.isArray(parts) ? parts.find((p) => p.inlineData && p.inlineData.data) : null;
    if (!inl) continue;
    const rate = (() => { const m = /rate=(\d+)/.exec(inl.inlineData.mimeType || ""); return m ? +m[1] : 24000; })();
    return { bytes: pcmToWav(ttsB64ToBytes(inl.inlineData.data), rate), type: "audio/wav" };
  }
  return null;
}
async function googleTtsSynth(text, lang) {
  const l = String(lang || "").startsWith("ar") ? "ar" : (/^[a-z]{2}/.test(lang) ? lang.slice(0, 2) : "en");
  const chunks = ttsChunks(text, 190), bufs = [];
  for (const c of chunks) {
    let r; try { r = await fetchTO("https://translate.google.com/translate_tts?ie=UTF-8&client=tw-ob&tl=" + encodeURIComponent(l) + "&q=" + encodeURIComponent(c), { headers: { "User-Agent": TTS_UA, "Referer": "https://translate.google.com/" } }, 10000); } catch (_) { return null; }
    if (!r.ok) return null; bufs.push(new Uint8Array(await r.arrayBuffer()));
  }
  if (!bufs.length) return null;
  const total = bufs.reduce((a, b) => a + b.length, 0), out = new Uint8Array(total); let off = 0;
  for (const b of bufs) { out.set(b, off); off += b.length; }
  return { bytes: out, type: "audio/mpeg" };
}
async function geminiSTT(b64, format, lang) {
  if (!GEMINI_KEYS.length) return null;
  const hint = String(lang || "") === "auto" || !lang ? "" : (" The language/dialect is " + lang + "; write it in its native script exactly as spoken.");
  const body = JSON.stringify({ contents: [{ role: "user", parts: [{ text: "You are a professional speech-to-text engine. Output ONLY the verbatim transcription — no commentary, no quotes, no translation. Keep the spoken language and dialect exactly (Arabic dialects stay in Arabic script)." + hint }, { inline_data: { mime_type: format === "mp3" ? "audio/mp3" : "audio/wav", data: b64 } }] }], generationConfig: { temperature: 0 } });
  for (const model of GEMINI_TEXT_MODELS) {
    const key = gemPick(); if (!key) break;
    let r; try { r = await fetchTO("https://generativelanguage.googleapis.com/v1beta/models/" + model + ":generateContent", { method: "POST", headers: { "content-type": "application/json", "x-goog-api-key": key }, body }, 60000); } catch (_) { gemMark(key, 0); continue; }
    if (!r.ok) { gemMark(key, r.status); continue; }
    const j = await r.json().catch(() => null);
    const parts = j && j.candidates && j.candidates[0] && j.candidates[0].content && j.candidates[0].content.parts;
    let t = Array.isArray(parts) ? parts.map((p) => p.text || "").join("") : "";
    t = String(t || "").trim(); if (/^".*"$/s.test(t) && t.length > 2) t = t.slice(1, -1).trim();
    return t;
  }
  return null;
}

export default async (request, context) => {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;
  try {
    if (!SESSION_SECRET || !FB_SA || !FIREBASE_DB_URL) {
      // Misconfig: name exactly which env var is missing/invalid (must be set in the
      // Netlify UI with the "Functions" scope — NOT in netlify.toml).
      if (path !== "/api/version") {
        const missing = [!SESSION_SECRET && "SESSION_SECRET", !FIREBASE_DB_URL && "FIREBASE_DB_URL", !FB_SA && "FIREBASE_SERVICE_ACCOUNT (valid JSON)"].filter(Boolean);
        return json({ error: "server not configured — missing/invalid env: " + missing.join(", ") }, 500);
      }
    }

    // Version changes per deploy (deploy id), so open tabs auto-reload after a deploy.
    if (path === "/api/version") return json({ version: (context.deploy && context.deploy.id) || env("DEPLOY_VERSION") || "netlify-1" });

    if (path === "/api/chat") {
      if (method !== "POST") return new Response("method not allowed", { status: 405 });
      // Member OR guest trial (guests get a much smaller daily allowance, no memory).
      let caller = await callerOf(context);
      /* INTERNAL CHANNEL for the background agent runner. It has no cookie — it is a Node
         function talking to us server-to-server — so it presents the deploy secret and the
         id of the user whose mission it is executing. Everything downstream then behaves
         exactly as for that user, including quota charging: a background mission must cost
         the same as a foreground one, or it becomes the cheapest way to spend the pool.
         Gated on a constant-time-ish equality against a secret that is absent in dev, so
         this path simply does not exist unless it is deliberately configured. */
      if (!caller.user && INTERNAL_JOB_SECRET && request.headers.get("x-firas-internal") === INTERNAL_JOB_SECRET) {
        const jobUser = await getUserById(String(request.headers.get("x-firas-job-user") || ""));
        if (jobUser) caller = { user: jobUser, id: jobUser.id, isGuest: false };
      }
      const user = caller.user || null;
      const guestId = caller.isGuest ? caller.id : "";
      if (!user && !guestId) return json({ error: "authentication required" }, 401);
      // Per-caller rate limit on the most expensive endpoint (burns upstream AI credits).
      // Generous cap so the Firas Agent multi-step pipeline still flows normally;
      // guests are capped much tighter since the identity is free to mint.
      if (rateLimited("chat:" + caller.id, guestId ? 30 : 120, 60000)) return json({ error: "too many requests, please slow down" }, 429);
      let payload; try { payload = await request.json(); } catch { return json({ error: "invalid JSON body" }, 400); }
      const messages = Array.isArray(payload.messages) ? payload.messages : [];
      const tier = TIERS[payload.tier] ? payload.tier : "pro";
      if (!messages.length) return json({ error: 'body must include a non-empty "messages" array' }, 400);
      // Inject persistent user memory so every reply is personalized — but NOT for
      // internal agent calls (nomem=true: file/PDF generation, prompt-enhance), so
      // personal facts never leak into generated documents. Memory is for CHAT only.
      // Guests have no stored memory (nothing is kept for them) → never inject.
      const memBlk = (payload.nomem || !user) ? "" : memoryBlock(user);
      if (memBlk) { const si = messages.findIndex((m) => m && m.role === "system"); if (si >= 0) messages[si] = { role: "system", content: String(messages[si].content || "") + "\n\n" + memBlk }; else messages.unshift({ role: "system", content: memBlk }); }
      // KNOWLEDGE BASE: silently ground the answer in the bundled local corpus + the admin's uploaded books (topic match).
      // Firas Brain turns are excluded: they carry their OWN cited sources block, and kbContext's
      // preamble ("NEVER mention, quote, cite, or hint that this material exists") is the exact
      // opposite instruction — plus it would inject passages the user never uploaded. Mirrors server.mjs.
      /* KB INJECTION DISABLED FOR PLAIN CHAT — mirrors server.mjs.
         The retrieved chunks arrived headed "REFERENCE MATERIAL (authoritative — use it to
         answer accurately and completely)", which made the model treat four matched snippets
         as the LIMIT of its knowledge: "اعطني 10 تكاملات صعبة" pulled a few basic-integral
         entries and the answer became "my reference material contains only basic integrals".
         A corpus should raise the floor on facts it holds, never cap everything else.
         Set KB_IN_CHAT=1 to restore. Firas Brain is unaffected — its contract is to answer
         from the user's own uploaded sources and cite them. */
      const KB_IN_CHAT = env("KB_IN_CHAT") === "1";
      if (KB_IN_CHAT && !payload.nomem && payload.product !== "brain") {
        try {
          let li = -1;
          for (let i = messages.length - 1; i >= 0; i--) if (messages[i] && messages[i].role === "user") { li = i; break; }
          if (li >= 0 && typeof messages[li].content === "string") {
            const kbctx = await kbContext(messages[li].content);
            if (kbctx) messages.splice(li, 0, { role: "system", content: kbctx });
          }
        } catch (_) {}
      }
      const vision = hasImages(messages);
      const think = vision ? false : !!payload.think;
      // Capped tier (Max): enforce the per-user daily limit and charge one slot per
      // distinct request id (idempotent on retry of the same cid).
      if (user && TIERS[tier] && TIERS[tier].capped) {
        const day = serverDay();
        const node = await maxDayNode(user.id);
        let cid = String(payload.cid || "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64);
        const isNew = !cid || !(cid in node);
        if (MAX_DAILY_LIMIT >= 0 && isNew && Object.keys(node).length >= MAX_DAILY_LIMIT) {
          return json({ error: "daily Max limit reached", limit: MAX_DAILY_LIMIT, used: Object.keys(node).length, remaining: 0 }, 429);
        }
        if (isNew) { if (!cid) cid = crypto.randomUUID(); try { await dbPut(`maxQuota/${dbKey(user.id)}/${day}/${dbKey(cid)}`, true); } catch (_) {} }
      }
      /* ── QUOTA BYPASS, CLOSED ───────────────────────────────────────────────────────
         `nomem` is a plain JSON boolean the browser sends. Both charging branches below
         are gated on `!payload.nomem`, so until now
             POST /api/chat {"messages":[…],"tier":"max","nomem":true}
         typed into devtools streamed a full completion and charged nothing — on any plan,
         and on a free guest cookie. The free tier's 100/day, every redeemed gold/diamond
         entitlement and the guest allowance all evaporated, and `tier:"max"` spends real
         paid Anthropic/OpenRouter credit. The only remaining brake was rateLimited(), which
         on the edge is a per-ISOLATE Map and therefore not a per-user cap at all.

         server.mjs closed this by giving internal calls their own generous-but-finite
         budget; the fix was never ported here. It is ported now, byte-for-byte in intent:
         real helper traffic (auto-title, file pipeline, page OCR, agent steps) never comes
         close to 800/day, but an attacker looping free completions hits a wall. */
      if (payload.nomem && guestId) {
        const denied = await guestChargeWithReq(request, context, guestId, "internal", payload.cid, messages);
        if (denied) return json(denied, 429);
      }
      if (payload.nomem && user) {
        const ilimit = limitsFor(planOf(user)).internal;
        if (ilimit >= 0) {
          const rolled = quotaRollDay(user);
          const q = user.quota;
          if ((q.internal || 0) >= ilimit) {
            return json({ error: "daily quota reached", quota: { product: "internal", used: q.internal || 0, limit: ilimit, plan: planOf(user) } }, 429);
          }
          q.internal = (q.internal || 0) + 1;
          try { await saveQuota(user, "internal", null, rolled); } catch (_) {}
        }
      }
      // PER-PRODUCT DAILY QUOTA (Firas AI / Code / Agent). nomem=true = internal
      // helper call (auto-title, file pipeline, agent steps) → charged above, not here.
      if (!payload.nomem && guestId) {
        // GUEST trial quota — same idempotency rules, much smaller allowance.
        const product = (payload.product === "code" || payload.product === "agent") ? payload.product : "ai";
        const denied = await guestChargeWithReq(request, context, guestId, product, payload.cid, messages);
        if (denied) return json(denied, 429);
      }
      if (!payload.nomem && user) {
        // "brain" is member-only, so it is deliberately NOT added to the guest coercion above —
        // a guest sending product:"brain" correctly falls through to the "ai" bucket.
        const product = (payload.product === "code" || payload.product === "agent" || payload.product === "brain") ? payload.product : "ai";
        const qlimit = limitsFor(planOf(user))[product];
        if (qlimit >= 0) {
          const rolled = quotaRollDay(user);
          const q = user.quota;
          const qcid = String(payload.cid || "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64);
          /* `already` used to be `q.last[product] === qcid` — a bare client string with no
             expiry and no tie to the question asked, so reusing one cid bought the whole
             day. It is now a real retry test: same cid AND same last user message, inside a
             two-minute window (agent missions keep the id-only rule, bounded to 45 min). */
          const already = await isRepeatCharge(q, product, qcid, messages);
          if (!already && (q[product] || 0) >= qlimit) return json({ error: "daily quota reached", quota: { product, used: q[product] || 0, limit: qlimit, plan: planOf(user) } }, 429);
          if (!already) {
            q[product] = (q[product] || 0) + 1;
            if (product === "agent") agentCidAdd(q, qcid);
            else if (qcid) q.last[product] = qcid;
            // Child-key writes only — a full saveUser() here reverted whatever
            // /api/memory/learn had written since it read its snapshot (and vice versa).
            // `seen` rides along so the retry window survives across isolates.
            try { await saveQuota(user, product, qcid, rolled); } catch (_) {}
            try { await dbPut(`users/${dbKey(user.id)}/quota/seen`, q.seen || {}); } catch (_) {}
          }
        }
      }
      // Same gate as server.mjs (res._scrubBt): scrub the plain Firas AI chat only, never
      // Firas Code / Firas Agent internal calls (they send nomem:true) — mutating code output
      // would be far worse than leaving a stray "wait, that is wrong" in prose.
      return chatStreamResponse(messages, tier, think, vision, !payload.nomem && !payload.agent);
    }

    /* ---- auth ---- */
    if (path === "/api/auth/signup" && method === "POST") {
      if (rateLimited("auth:signup:" + ipOf(request, context), 12, 60000)) return json({ error: "too many attempts, please wait a minute" }, 429);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON body" }, 400); }
      const name = String(b.name ?? "").trim().slice(0, 80);
      const email = String(b.email ?? "").trim().toLowerCase();
      const password = String(b.password ?? "");
      if (!name) return json({ error: "name is required" }, 400);
      if (!EMAIL_RE.test(email) || email.length > 200) return json({ error: "a valid email is required" }, 400);
      if (password.length < 8) return json({ error: "password must be at least 8 characters" }, 400);
      if (password.length > 200) return json({ error: "password is too long" }, 400);
      if (await getUserByEmail(email)) return json({ error: "email already registered" }, 409);
      // Don't create the account yet — stash a PENDING signup (Firebase) + email a verify LINK.
      const ek = dbKey(emailKey(email));
      const prev = await dbGet("pending/" + ek); // re-signup before verifying → clear old indexes
      if (prev) await delPending(ek, prev);
      /* RECLAIM EXPIRED PENDINGS. Each signup writes three permanent RTDB nodes — pending/,
         pendingTok/ and pendingPid/ — carrying a name, an email and a full password hash.
         They are deleted only on successful verification or on a re-signup with the SAME
         address, so a signup that is never verified is never reclaimed. server.mjs sweeps
         these on a timer (_pendingSweep); an edge isolate has no timer to sweep with, and
         nothing here did it, so unauthenticated requests grew the shared database without
         bound until dbPut began failing for every product.
         Sweeping on the signup path is the natural place: it is the only request that
         creates these records, so the cleanup rate tracks the creation rate exactly.
         Bounded per request so one signup can never turn into a long scan. */
      try { await sweepExpiredPendings(40); } catch (_) {}
      const token = crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "");
      const pid = crypto.randomUUID().replace(/-/g, "");
      const rec = { name, email, passHash: await hashPassword(password), token, pid, exp: Date.now() + VERIFY_TTL_MS, verified: false, userId: null };
      await dbPut("pending/" + ek, rec);
      await dbPut("pendingTok/" + dbKey(token), ek);
      await dbPut("pendingPid/" + dbKey(pid), ek);
      const link = appBase(request) + "/?verify=" + token;
      const sent = await sendEmail(email, "تأكيد حسابك — Firas AI", verifyEmailHtml(link));
      if (!sent && env("DEV_LOG_LINKS")) console.log("[firas] signup verify link for " + email + " -> " + link + " (not delivered)");   // token link: dev-only, never in prod logs
      return json({ ok: true, pending: true, email, pid });
    }

    if (path === "/api/auth/login" && method === "POST") {
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON body" }, 400); }
      const email = String(b.email ?? "").trim().toLowerCase();
      const password = String(b.password ?? "");
      if (rateLimited("login:" + email, 6, 60000) || rateLimited("auth:login:" + ipOf(request, context), 30, 60000)) return json({ error: "too many attempts, please wait a minute" }, 429);
      const user = await getUserByEmail(email);
      // A legacy scrypt account (from the old Node backend) can't be verified with
      // Web Crypto — give a clear message instead of "invalid password".
      if (user && user.passHash && !user.passHash.startsWith("pbkdf2$")) {
        return json({ error: "This account predates the new sign-in. Please reset your password, or sign in with Google." }, 401);
      }
      if (!user || !user.passHash || !(await verifyPassword(password, user.passHash))) return json({ error: "invalid email or password" }, 401);
      await attachSession(context, user.id, request, user.sessVer || 0);
      return json({ user: publicUser(user) });
    }

    if (path === "/api/auth/verify-signup" && method === "POST") {
      if (rateLimited("verify:" + ipOf(request, context), 60, 60000)) return json({ error: "too many requests" }, 429);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const token = dbKey(String(b.token || "").trim()); if (!token) return json({ error: "رابط غير صالح" }, 400); // raw token → db path: sanitize before ANY db call
      const ek = dbKey(await dbGet("pendingTok/" + token));
      const rec = ek ? await dbGet("pending/" + ek) : null;
      if (!rec || Date.now() > rec.exp) { if (ek) await delPending(ek, rec); return json({ error: "الرابط غير صالح أو منتهي — أعد التسجيل" }, 400); }
      let user;
      if (rec.verified && rec.userId) { user = await getUserById(rec.userId); }
      else {
        if (await getUserByEmail(rec.email)) { await delPending(ek, rec); return json({ error: "email already registered" }, 409); }
        user = { id: crypto.randomUUID(), name: rec.name, email: rec.email, passHash: rec.passHash, emailVerified: true, createdAt: new Date().toISOString() };
        await saveUser(user);
        rec.verified = true; rec.userId = user.id; rec.verifiedAt = Date.now();
        await dbPut("pending/" + ek, rec);
        // Consume the token so the link can't be replayed; the pid index stays for the
        // original device's cross-device poll, which then cleans up the rest.
        try { await dbDelete("pendingTok/" + token); } catch (_) {}
        // personal welcome from Firas — don't block sign-in (run after response if possible)
        const _welcome = sendEmail(user.email, "Welcome to Firas AI 🎉", welcomeEmailHtml(user.name, appBase(request) + "/"), { fromName: "Firas" }).catch(() => {});
        if (context && typeof context.waitUntil === "function") context.waitUntil(_welcome); else await _welcome;
      }
      if (!user) return json({ error: "تعذّر التأكيد — أعد التسجيل" }, 400);
      await attachSession(context, user.id, request, user.sessVer || 0);
      return json({ ok: true, user: publicUser(user) });
    }
    if (path === "/api/auth/verify-status" && method === "POST") {
      if (rateLimited("vstatus:" + ipOf(request, context), 120, 60000)) return json({ error: "too many requests" }, 429);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const pid = dbKey(String(b.pid || "").trim()); if (!pid) return json({ error: "missing pid" }, 400); // raw pid → db path: sanitize first
      const ek = dbKey(await dbGet("pendingPid/" + pid));
      const rec = ek ? await dbGet("pending/" + ek) : null;
      if (!rec) return json({ verified: false, gone: true });
      if (Date.now() > rec.exp) { await delPending(ek, rec); return json({ verified: false, expired: true }); }
      if (rec.verified && rec.userId) {
        const user = await getUserById(rec.userId);
        if (user) { await attachSession(context, user.id, request, user.sessVer || 0); await delPending(ek, rec); return json({ verified: true, user: publicUser(user) }); }
      }
      return json({ verified: false });
    }
    if (path === "/api/auth/resend-code" && method === "POST") {
      if (rateLimited("resend:" + ipOf(request, context), 8, 60000)) return json({ error: "too many requests" }, 429);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const email = String(b.email || "").trim().toLowerCase();
      if (!EMAIL_RE.test(email) || email.length > 200) return json({ ok: true }); // anti-enumeration: same reply, no db lookup
      const ek = dbKey(emailKey(email));
      const rec = await dbGet("pending/" + ek);
      if (rec && !rec.verified) {
        if (dbKey(rec.token)) { try { await dbDelete("pendingTok/" + dbKey(rec.token)); } catch (_) {} }
        const token = crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "");
        rec.token = token; rec.exp = Date.now() + VERIFY_TTL_MS;
        await dbPut("pending/" + ek, rec);
        await dbPut("pendingTok/" + dbKey(token), ek);
        const link = appBase(request) + "/?verify=" + token;
        const sent = await sendEmail(email, "تأكيد حسابك — Firas AI", verifyEmailHtml(link));
        if (!sent && env("DEV_LOG_LINKS")) console.log("[firas] (resend) verify link for " + email + " -> " + link);
      }
      return json({ ok: true });
    }
    if (path === "/api/auth/forgot" && method === "POST") {
      if (rateLimited("forgot:" + ipOf(request, context), 6, 60000)) return json({ error: "too many requests" }, 429);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const email = String(b.email || "").trim().toLowerCase();
      if (EMAIL_RE.test(email)) {
        const user = await getUserByEmail(email);
        if (user && user.passHash) {
          const token = crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "");
          user.reset = { hash: await sha256hex(token), exp: Date.now() + RESET_TTL_MS }; // store only a hash, never the raw token
          await saveUser(user);
          const link = appBase(request) + "/?reset=" + token + "&uid=" + encodeURIComponent(user.id);
          const sent = await sendEmail(email, "إعادة تعيين كلمة المرور — Firas AI", resetEmailHtml(link));
          if (!sent && env("DEV_LOG_LINKS")) console.log("[firas] password-reset link for " + email + " -> " + link);
        }
      }
      return json({ ok: true }); // anti-enumeration
    }
    if (path === "/api/auth/reset" && method === "POST") {
      if (rateLimited("reset:" + ipOf(request, context), 10, 60000)) return json({ error: "too many requests" }, 429);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const uid = String(b.uid || ""), token = String(b.token || ""), password = String(b.password || "");
      if (password.length < 8) return json({ error: "password must be at least 8 characters" }, 400);
      if (password.length > 200) return json({ error: "password is too long" }, 400);
      const user = await getUserById(uid);
      if (!user || !user.reset || !user.reset.hash || Date.now() > user.reset.exp || user.reset.hash !== await sha256hex(token)) return json({ error: "invalid or expired link" }, 400);
      user.passHash = await hashPassword(password);
      delete user.reset;
      /* A reset exists to lock out whoever had access. Re-issuing an identical cookie made
         it decorative — a stolen copy kept working. Bump, persist, THEN hand this browser a
         cookie carrying the new version; every other copy stops verifying. */
      user.sessVer = (user.sessVer || 0) + 1;
      await saveUser(user);
      await attachSession(context, user.id, request, user.sessVer);
      return json({ ok: true, user: publicUser(user) });
    }

    if (path === "/api/auth/change-password" && method === "POST") {
      const user = await currentUser(context);
      if (!user) return json({ error: "not authenticated" }, 401);
      if (rateLimited("acct:" + user.id, 10, 60000)) return json({ error: "too many requests" }, 429);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const current = String(b.current || ""), next = String(b.password || "");
      if (!user.passHash) return json({ error: "هذا الحساب يسجّل عبر Google ولا يملك كلمة مرور" }, 400);
      if (next.length < 8) return json({ error: "كلمة المرور يجب أن تكون 8 أحرف على الأقل" }, 400);
      if (next.length > 200) return json({ error: "كلمة المرور طويلة جداً" }, 400);
      if (!(await verifyPassword(current, user.passHash))) return json({ error: "كلمة المرور الحالية غير صحيحة" }, 403);
      user.passHash = await hashPassword(next);
      await saveUser(user);
      return json({ ok: true });
    }
    if (path === "/api/auth/change-email" && method === "POST") {
      const user = await currentUser(context);
      if (!user) return json({ error: "not authenticated" }, 401);
      if (rateLimited("acct:" + user.id, 10, 60000)) return json({ error: "too many requests" }, 429);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const current = String(b.current || ""), email = String(b.email || "").trim().toLowerCase();
      if (!user.passHash) return json({ error: "هذا الحساب يسجّل عبر Google" }, 400);
      if (!EMAIL_RE.test(email) || email.length > 200) return json({ error: "أدخل بريداً صالحاً" }, 400);
      if (!(await verifyPassword(current, user.passHash))) return json({ error: "كلمة المرور غير صحيحة" }, 403);
      if (email === user.email) return json({ error: "هذا هو بريدك الحالي" }, 400);
      if (await getUserByEmail(email)) return json({ error: "هذا البريد مستخدم بالفعل" }, 409);
      const oldKey = dbKey(emailKey(user.email));
      user.email = email;
      /* ACCOUNT-TAKEOVER FIX — mirrors server.mjs handleChangeEmail. This endpoint proves
         the CALLER's password and that the address is free; it cannot prove the caller owns
         the address. The Firebase link path below then trusts "an email in the DB is owned
         by that person", so an attacker could claim victim@gmail.com here and receive the
         victim's session the next time they tapped Continue with Google. `emailUnverified`
         marks an address never proven to this backend, and that path refuses to auto-link
         into one. Absent on existing records, so nothing about current sign-ins changes. */
      user.emailUnverified = true;
      delete user.emailVerified;
      await saveUser(user);
      try { await dbDelete("emailIndex/" + oldKey); } catch (_) {}
      return json({ ok: true, user: publicUser(user) });
    }
    if (path === "/api/auth/delete-account" && method === "POST") {
      const user = await currentUser(context);
      if (!user) return json({ error: "not authenticated" }, 401);
      if (rateLimited("acct:" + user.id, 10, 60000)) return json({ error: "too many requests" }, 429);
      let b; try { b = await request.json(); } catch { b = {}; }
      const current = String((b && b.current) || "");
      if (user.passHash && !(await verifyPassword(current, user.passHash))) return json({ error: "كلمة المرور غير صحيحة" }, 403);
      // Purge ALL of the user's data (chat bodies + the chatMeta list index + usage quotas)
      // so "delete my account" actually erases everything (privacy / data-retention).
      const uk = dbKey(user.id);
      try { await dbDelete("chats/" + uk); } catch (_) {}
      try { await dbDelete("chatMeta/" + uk); } catch (_) {}
      try { await dbDelete("imgQuota/" + uk); } catch (_) {}
      try { await dbDelete("maxQuota/" + uk); } catch (_) {}
      // Firas Brain lives in its own heavy/light pair of subtrees — neither is under users/<id>,
      // so deleting the user record alone would leave the whole document library behind.
      try { await dbDelete("brainDoc/" + uk); } catch (_) {}
      try { await dbDelete("brainMeta/" + uk); } catch (_) {}
      brainCacheBust(user.id);
      try { await dbDelete("emailIndex/" + dbKey(emailKey(user.email))); } catch (_) {}
      try { await dbDelete("users/" + uk); } catch (_) {}
      context.cookies.delete({ name: COOKIE_NAME, path: "/" });
      return json({ ok: true });
    }

    if (path === "/api/auth/logout" && method === "POST") {
      context.cookies.delete({ name: COOKIE_NAME, path: "/" });
      return json({ ok: true });
    }

    if (path === "/api/auth/me" && method === "GET") {
      const user = await currentUser(context);
      if (!user) return json({ error: "not authenticated" }, 401);
      return json({ user: publicUser(user) });
    }

    /* ---- Guest trial (no signup). Idempotent: an existing valid guest cookie is
       reused so a reload keeps the same daily quota. ---- */
    if (path === "/api/guest" && method === "POST") {
      const signed = await currentUser(context);
      if (signed) return json({ guest: false, user: publicUser(signed) });
      if (rateLimited("guest:" + ipOf(request, context), 20, 60000)) return json({ error: "too many requests" }, 429);
      let g = await currentGuest(context);
      if (!g) { g = { id: newGuestId(), guest: true }; await attachGuest(context, g.id, request); }
      return json({ guest: true, user: { id: g.id, name: "", email: "", guest: true, admin: false, sub: await guestSubInfo(g.id) } });
    }
    if (path === "/api/guest" && method === "DELETE") {
      context.cookies.delete({ name: GUEST_COOKIE, path: "/" });
      return json({ ok: true });
    }

    if (path === "/api/auth/firebase" && method === "POST") {
      if (rateLimited("auth:fb:" + ipOf(request, context), 30, 60000)) return json({ error: "too many attempts, please wait a minute" }, 429);
      if (!FIREBASE_PROJECT_ID) return json({ error: "social sign-in not configured" }, 501);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON body" }, 400); }
      let payload = null; try { payload = await verifyFirebaseIdToken(b.idToken); } catch { payload = null; }
      if (!payload) return json({ error: "invalid token" }, 401);
      const email = String(payload.email).trim().toLowerCase();
      const name = (typeof payload.name === "string" && payload.name.trim() && payload.name.trim().slice(0, 80)) || (typeof b.name === "string" && b.name.trim() && b.name.trim().slice(0, 80)) || email.split("@")[0];
      const verified = payload.email_verified === true;
      let user = await getUserByEmail(email);
      if (user) {
        // Only a VERIFIED token (Google sign-in) may auto-link into an EXISTING account —
        // an unverified Firebase email/password token can be minted for any victim's address
        // (including a social/admin account) via the public web apiKey, so never let it link in.
        if (!verified) return json({ error: "An account with this email already exists. Please sign in with your password, or verify your email first." }, 409);
        /* …and a verified token alone is still not enough: the guard above assumes the
           account holding this email actually owns it, and /api/auth/change-email lets any
           user claim any unused address without proof. Refusing to auto-link into an
           unproven address is what stops a squatted email handing over the owner's session. */
        if (user.emailUnverified) return json({ error: "An account with this email already exists but the address was never confirmed. Please sign in with your password." }, 409);
      } else {
        // Never let an UNVERIFIED token CREATE an admin-privileged account.
        if (!verified && isAdmin({ email })) return json({ error: "email verification required for this account" }, 403);
        user = { id: crypto.randomUUID(), name, email, provider: "firebase", createdAt: new Date().toISOString() };
        await saveUser(user);
      }
      await attachSession(context, user.id, request, user.sessVer || 0);
      return json({ user: publicUser(user) });
    }

    /* ---- chats ---- */
    if (path === "/api/chats") {
      const user = await currentUser(context);
      if (!user) return json({ error: "not authenticated" }, 401);
      if (method === "GET") {
        const meta = (await dbGet("chatMeta/" + dbKey(user.id))) || {};
        const list = Object.keys(meta).map((id) => ({ id, title: meta[id].title, updatedAt: meta[id].updatedAt, pinned: !!meta[id].pinned, agent: !!meta[id].agent, codeProj: !!meta[id].codeProj, brainNb: !!meta[id].brainNb })).sort((a, b) => (b.updatedAt || "").localeCompare(a.updatedAt || ""));
        return json(list);
      }
      if (method === "POST") {
        let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON body" }, 400); }
        const meta = (await dbGet("chatMeta/" + dbKey(user.id))) || {};
        if (Object.keys(meta).length >= MAX_CHATS_PER_USER) return json({ error: "chat limit reached; delete some conversations" }, 409);
        const now = new Date().toISOString();
        const chat = { id: crypto.randomUUID(), userId: user.id, title: String(b.title ?? "New chat").slice(0, 200) || "New chat", messages: sanitizeMessages(b.messages), pinned: !!b.pinned, agent: !!b.agent, codeProj: !!b.codeProj, brainNb: !!b.brainNb, createdAt: now, updatedAt: now };
        await dbPut(`chats/${dbKey(user.id)}/${dbKey(chat.id)}`, chat);
        await dbPut(`chatMeta/${dbKey(user.id)}/${dbKey(chat.id)}`, { title: chat.title, updatedAt: now, pinned: chat.pinned, agent: chat.agent, codeProj: !!chat.codeProj, brainNb: !!chat.brainNb });
        return json({ id: chat.id, title: chat.title, createdAt: now, updatedAt: now }, 201);
      }
      return new Response("method not allowed", { status: 405 });
    }
    const chatMatch = path.match(/^\/api\/chats\/([^/]+)$/);
    if (chatMatch) {
      const user = await currentUser(context);
      if (!user) return json({ error: "not authenticated" }, 401);
      // The route pattern only forbids a literal "/", so "%2F..%2F.." decoded straight
      // into the db path and escaped this user's chats subtree (DELETE would have hit
      // any node, users included). dbKey() makes the id a single key or nothing.
      const id = dbKey(decodeURIComponent(chatMatch[1]));
      if (!id) return json({ error: "not found" }, 404);
      const uk = dbKey(user.id);
      if (method === "GET") {
        const chat = await dbGet(`chats/${uk}/${id}`);
        if (!chat) return json({ error: "not found" }, 404);
        return json({ id: chat.id, title: chat.title, messages: chat.messages || [] });
      }
      if (method === "PUT") {
        let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON body" }, 400); }
        const chat = await dbGet(`chats/${uk}/${id}`);
        if (!chat) return json({ error: "not found" }, 404);
        let touched = false;
        if (typeof b.title === "string") { chat.title = b.title.slice(0, 200); touched = true; }
        if (Array.isArray(b.messages)) { chat.messages = sanitizeMessages(b.messages); touched = true; }
        if (typeof b.pinned === "boolean") chat.pinned = b.pinned; // pin toggle alone must not bump updatedAt
        if (touched) chat.updatedAt = new Date().toISOString();
        await dbPut(`chats/${uk}/${id}`, chat);
        await dbPut(`chatMeta/${uk}/${id}`, { title: chat.title, updatedAt: chat.updatedAt, pinned: !!chat.pinned, agent: !!chat.agent, codeProj: !!chat.codeProj, brainNb: !!chat.brainNb });
        return json({ ok: true });
      }
      if (method === "DELETE") {
        await dbDelete(`chats/${uk}/${id}`);
        await dbDelete(`chatMeta/${uk}/${id}`);
        return json({ ok: true });
      }
      return new Response("method not allowed", { status: 405 });
    }

    /* ---- image quota (read-only pre-check) ---- */
    if (path === "/api/image/quota" && method === "POST") {
      const user = await currentUser(context);
      if (!user) {
        if (await currentGuest(context)) return json({ ok: false, error: "signin_required", feature: "image" }, 403);
        return json({ ok: false, error: "auth required" }, 401);
      }
      const used = Object.keys(await imgDayNode(user.id)).length;
      if (IMAGE_DAILY_LIMIT >= 0 && used >= IMAGE_DAILY_LIMIT) return json({ ok: false, limit: IMAGE_DAILY_LIMIT, used, remaining: 0 }, 429);
      return json({ ok: true, limit: IMAGE_DAILY_LIMIT, used, remaining: IMAGE_DAILY_LIMIT < 0 ? -1 : IMAGE_DAILY_LIMIT - used });
    }

    /* ---- Max tier quota (read-only pre-check) ---- */
    if (path === "/api/memory" && method === "GET") {
      const user = await currentUser(context); if (!user) return json({ error: "authentication required" }, 401);
      return json({ memory: userMemory(user) });
    }
    if (path === "/api/memory" && method === "DELETE") {
      const user = await currentUser(context); if (!user) return json({ error: "authentication required" }, 401);
      const i = url.searchParams.get("i"); const mem = userMemory(user);
      if (i != null && i !== "") { const n = parseInt(i, 10); if (n >= 0 && n < mem.length) mem.splice(n, 1); } else user.memory = [];
      try { await saveUserChild(user, "memory", user.memory); } catch (_) {} // never PUT the whole record: it would revert a concurrent quota/sub write
      return json({ ok: true, memory: userMemory(user) });
    }
    if (path === "/api/memory/learn" && method === "POST") {
      const user = await currentUser(context); if (!user) return json({ error: "authentication required" }, 401);
      if (rateLimited("mem:" + user.id, 60, 60000)) return json({ error: "rate limited" }, 429);
      let payload; try { payload = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const userText = String(payload.user || "").slice(0, 4000).trim();
      const aiText = String(payload.assistant || "").slice(0, 2000).trim();
      if (!userText) return json({ ok: true, added: 0 });
      const added = await memoryLearn(user, userText, aiText);
      return json({ ok: true, added, total: userMemory(user).length });
    }

    if (path === "/api/max/quota" && method === "POST") {
      const user = await currentUser(context);
      if (!user) return json({ ok: false, error: "auth required" }, 401);
      // Max is FREE & UNLIMITED for everyone now.
      return json({ ok: true, limit: 0, used: 0, remaining: -1 });
    }

    /* ---- Subscriptions / redeem codes ---- */
    if (path === "/api/redeem" && method === "POST") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      if (rateLimited("redeem:" + user.id, 8, 60000) || rateLimited("redeemip:" + ipOf(request, context), 20, 60000)) return json({ error: "too many attempts, please wait a minute" }, 429);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON body" }, 400); }
      const codeStr = normCode(b && b.code);
      if (!codeStr || codeStr.length < 5) return json({ error: "invalid code" }, 400);
      const c = await edgeFindCode(codeStr);
      if (!c) return json({ error: "code not found" }, 404);
      const st = codeStatus(c);
      if (st === "disabled") return json({ error: "code disabled" }, 403);
      if (st === "expired") return json({ error: "code expired" }, 410);
      if (st === "used-up") return json({ error: "code fully used" }, 409);
      if (c.boundUserId && c.boundUserId !== user.id) return json({ error: "code not for this account" }, 403);
      if (codeClaimedBy(c, user.id)) return json({ error: "you already redeemed this code" }, 409);
      const ck = dbKey(c.id), uk = dbKey(user.id);
      if (!ck || !uk) return json({ error: "invalid code" }, 400);
      const now = Date.now();
      /* CLAIM FIRST, VERIFY SECOND. The old flow validated codeStatus, incremented
         c.uses and PUT the whole code record, so two people tapping Activate on the
         same maxUses:1 code inside that window both read uses:0 and both wrote uses:1
         — two accounts got the plan and the loser's usedBy row was dropped too. RTDB's
         REST API has no transaction, so instead: write our own child key, re-read the
         claims node, and keep only the earliest maxUses claimants (ties broken by id,
         so every racer computes the SAME winner set); a loser releases its claim.
         RESIDUAL RACE, honestly: the write and the read-back are still two round trips,
         so if two claims are written and both re-reads are served before either write is
         visible, both callers see only themselves and both win. The window shrinks from
         "the whole handler" to "one read-back", but this is NOT atomic — only a real
         transaction or a security rule on codes/<id>/claims would close it. */
      try { await dbPut(`codes/${ck}/claims/${uk}`, { userId: user.id, email: user.email, at: now }); }
      catch (_) { return json({ error: "could not redeem, please try again" }, 503); }
      let claimNode = {};
      try { claimNode = (await dbGet(`codes/${ck}/claims`)) || {}; } catch (_) { claimNode = {}; }
      const slots = Math.max(0, (Number(c.maxUses) || 1) - codeLegacyUses(c)); // uses/usedBy = redemptions made before claims existed
      const winners = Object.keys(claimNode)
        .sort((a, b) => (((claimNode[a] || {}).at || 0) - ((claimNode[b] || {}).at || 0)) || (a < b ? -1 : a > b ? 1 : 0))
        .slice(0, slots);
      if (!winners.includes(uk)) {
        // Lost the race → give the slot back. If this release itself fails the slot stays
        // consumed by a user who never got the plan; it shows up in the admin list as a
        // redeemer, and an admin can raise maxUses to compensate.
        try { await dbPut(`codes/${ck}/claims/${uk}`, null); } catch (_) {}
        return json({ error: "code fully used" }, 409);
      }
      const type = c.type;
      let expiresAt = null;
      if (type === "gold" || type === "diamond") {
        const days = Number(c.durationDays) > 0 ? Number(c.durationDays) : 30;
        const cur = user.sub;
        const base = (cur && cur.plan === type && cur.expiresAt && cur.expiresAt > now) ? cur.expiresAt : now;
        expiresAt = base + days * 86400000;
      }
      user.sub = { plan: type, expiresAt, since: now, code: c.code };
      // users/<id>/sub only — a full saveUser() let a /api/memory/learn call that was
      // already in flight erase the plan the user just activated.
      try { await saveUserChild(user, "sub", user.sub); } catch (_) {}
      return json({ ok: true, sub: subInfo(user) });
    }
    if (path === "/api/admin/codes" && method === "GET") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      if (!isAdmin(user)) return json({ error: "admins only" }, 403);
      const qraw = (url.searchParams.get("q") || "").toString().trim().toLowerCase();
      let list = (await edgeCodesAll()).sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
      if (qraw) list = list.filter((c) => (c.code || "").toLowerCase().includes(qraw) || (c.note || "").toLowerCase().includes(qraw) || (c.type || "").includes(qraw));
      return json({ codes: list.map(publicCode), plans: PLAN_LIMITS });
    }
    if (path === "/api/admin/codes" && method === "POST") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      if (!isAdmin(user)) return json({ error: "admins only" }, 403);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON body" }, 400); }
      const type = ["gold", "diamond", "unlimited"].includes(b.type) ? b.type : "gold";
      const durationDays = type === "unlimited" ? null : (Number(b.durationDays) > 0 ? Math.min(3650, Math.floor(Number(b.durationDays))) : 30);
      const maxUses = Math.min(1000000, Math.max(1, parseInt(b.maxUses, 10) || 1));
      const note = String(b.note || "").slice(0, 200);
      const expiresAt = Number(b.expiresAt) > 0 ? Number(b.expiresAt) : null;
      let boundUserId = null;
      if (b.boundUserEmail) { const bu = await getUserByEmail(String(b.boundUserEmail).toLowerCase().trim()); if (!bu) return json({ error: "bound user not found" }, 404); boundUserId = bu.id; }
      const custom = normCode(b.customCode);
      const existing = await edgeCodesAll();
      const count = custom ? 1 : Math.min(500, Math.max(1, parseInt(b.count, 10) || 1));
      const created = [];
      const taken = (cc) => existing.some((x) => x.code === cc) || created.some((x) => x.code === cc);
      for (let i = 0; i < count; i++) {
        let code = custom || genCode();
        if (taken(code)) { if (custom) return json({ error: "code already exists" }, 409); do { code = genCode(); } while (taken(code)); }
        created.push({ id: "cd" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8) + i, code, type, durationDays, maxUses, uses: 0, usedBy: [], expiresAt, note, disabled: false, boundUserId, createdAt: Date.now(), createdBy: user.email });
      }
      try { for (const c of created) await dbPut("codes/" + dbKey(c.id), c); } catch (_) {}
      return json({ ok: true, created: created.map(publicCode) });
    }
    if (path === "/api/admin/codes" && method === "PATCH") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      if (!isAdmin(user)) return json({ error: "admins only" }, 403);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON body" }, 400); }
      const c = (await edgeCodesAll()).find((x) => x.id === b.id);
      if (!c) return json({ error: "code not found" }, 404);
      const ck = dbKey(c.id);
      if (!ck) return json({ error: "code not found" }, 404);
      // Edit field-by-field: a whole-record PUT would write back the claims map as it
      // looked when this admin loaded the page and silently free up any slot claimed
      // since (see /api/redeem).
      const patch = {};
      if (typeof b.disabled === "boolean") patch.disabled = c.disabled = b.disabled;
      if (typeof b.note === "string") patch.note = c.note = b.note.slice(0, 200);
      if (b.type && ["gold", "diamond", "unlimited"].includes(b.type)) { patch.type = c.type = b.type; if (c.type === "unlimited") patch.durationDays = c.durationDays = null; }
      if (b.durationDays != null && c.type !== "unlimited") patch.durationDays = c.durationDays = Math.max(1, Math.floor(Number(b.durationDays)) || 30);
      if (b.maxUses != null) patch.maxUses = c.maxUses = Math.min(1000000, Math.max(1, parseInt(b.maxUses, 10) || 1));
      if (b.expiresAt !== undefined) patch.expiresAt = c.expiresAt = Number(b.expiresAt) > 0 ? Number(b.expiresAt) : null;
      try { for (const k of Object.keys(patch)) await dbPut(`codes/${ck}/${dbKey(k)}`, patch[k]); } catch (_) {}
      return json({ ok: true, code: publicCode(c) });
    }
    if (path === "/api/admin/codes" && method === "DELETE") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      if (!isAdmin(user)) return json({ error: "admins only" }, 403);
      // searchParams.get() percent-DECODES, so "?id=..%2Fusers" arrived here as
      // "../users" and `dbPut("codes/" + id, null)` resolved to <db>/users.json —
      // one request wiped every account, and db.json/RTDB has no backup. Sanitize to a
      // single key BEFORE any db call, and refuse anything that isn't one.
      const raw = url.searchParams.get("id") || "";
      const id = dbKey(raw);
      if (!id || id !== raw) return json({ error: "invalid id" }, 400);
      try { await dbPut("codes/" + id, null); } catch (_) {}
      return json({ ok: true });
    }
    if (path === "/api/usage/charge" && method === "POST") {
      const caller = await callerOf(context);
      const user = caller.user || null;
      if (!user && !caller.isGuest) return json({ error: "authentication required" }, 401);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON body" }, 400); }
      const product = (b.product === "code" || b.product === "agent") ? b.product : null;
      if (!product) return json({ error: "invalid product" }, 400);
      // GUEST: charge the trial allowance so Code builds / Agent missions are
      // gated for guests too, not just client-side.
      if (caller.isGuest) {
        const denied = await guestChargeWithReq(request, context, caller.id, product, b.cid);
        if (denied) return json(denied, 429);
        return json({ ok: true, sub: await guestSubInfo(caller.id) });
      }
      const limit = limitsFor(planOf(user))[product];
      if (limit < 0) return json({ ok: true, sub: subInfo(user) });
      const rolled = quotaRollDay(user);
      const q = user.quota;
      const cid = String(b.cid || "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64);
      /* Same cid-reuse hole as /api/chat, on the meter that bills Firas Code and Firas
         Agent. There is no message body on this endpoint, so the retry test binds on the
         cid alone — but now inside a two-minute window rather than "until midnight", which
         is the difference between tolerating a genuine retry and handing over the day. */
      const already = await isRepeatCharge(q, product, cid, null);
      if (!already && (q[product] || 0) >= limit) return json({ error: "daily quota reached", quota: { product, used: q[product] || 0, limit, plan: planOf(user) } }, 429);
      // Child-key write, same reason as /api/chat: a full saveUser() here reverted
      // whatever another in-flight request (memory/learn, redeem) had just written.
      if (!already) { q[product] = (q[product] || 0) + 1; if (product === "agent") agentCidAdd(q, cid); else if (cid) q.last[product] = cid; try { await saveQuota(user, product, cid, rolled); } catch (_) {}
        // Persist the retry window too, or it lives only inside this isolate and the
        // reuse hole reopens the moment the next request lands somewhere else.
        try { await dbPut(`users/${dbKey(user.id)}/quota/seen`, q.seen || {}); } catch (_) {} }
      return json({ ok: true, sub: subInfo(user) });
    }

    /* ---- site updates / announcements (admin publishes, all users see) ---- */
    if (path === "/api/announcements" && method === "GET") {
      // Guests see site updates too (read-only); only a real admin gets the flag.
      const caller = await callerOf(context);
      if (!caller.user && !caller.isGuest) return json({ error: "authentication required" }, 401);
      const node = (await dbGet("announcements")) || {};
      const list = Object.values(node).sort((a, b) => (b.ts || 0) - (a.ts || 0)).slice(0, 50);
      return json({ announcements: list, admin: isAdmin(caller.user) });
    }
    if (path === "/api/announcements" && method === "POST") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      if (!isAdmin(user)) return json({ error: "admins only" }, 403);
      let p; try { p = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const title = String(p.title || "").slice(0, 200).trim();
      const body = String(p.body || "").slice(0, 4000).trim();
      /* Bilingual by storage, not by machine translation. The app is Arabic-first but its UI
         switches to English, and an announcement that stays Arabic in an English UI is the
         one place the product visibly forgets which language it is speaking. Both texts are
         authored and stored; the client shows whichever matches the active language and
         falls back to the other rather than to nothing. */
      const titleEn = String(p.titleEn || "").slice(0, 200).trim();
      const bodyEn = String(p.bodyEn || "").slice(0, 4000).trim();
      let image = String(p.image || "").trim();
      if (image && !ANN_IMG_OK(image)) image = "";
      if (image.length > 600000) return json({ error: "image too large" }, 413);
      let video = String(p.video || "").trim();
      if (video && !ANN_VID_OK(video)) video = "";
      // Pinned items sort above everything and survive the "clear all" sweep below.
      const pinned = !!p.pinned;
      if (!title && !body && !image && !video) return json({ error: "empty announcement" }, 400);
      const id = "a" + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
      const item = { id, title, body, titleEn, bodyEn, image, video, pinned, ts: Date.now(), by: user.name || "Firas" };
      try { await dbPut("announcements/" + dbKey(id), item); } catch (_) {}
      return json({ ok: true, announcement: item });
    }
    if (path === "/api/announcements" && method === "PATCH") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      if (!isAdmin(user)) return json({ error: "admins only" }, 403);
      let p; try { p = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const id = dbKey(p.id); // body-supplied id → db path
      if (!id) return json({ error: "not found" }, 404);
      const item = await dbGet("announcements/" + id);
      if (!item) return json({ error: "not found" }, 404);
      if (typeof p.title === "string") item.title = p.title.slice(0, 200).trim();
      if (typeof p.body === "string") item.body = p.body.slice(0, 4000).trim();
      if (typeof p.image === "string") {
        let image = p.image.trim();
        if (image && !ANN_IMG_OK(image)) image = "";
        if (image.length > 600000) return json({ error: "image too large" }, 413);
        item.image = image;
      }
      item.editedTs = Date.now();
      try { await dbPut("announcements/" + id, item); } catch (_) {}   // id already dbKey()'d above
      return json({ ok: true, announcement: item });
    }
    if (path === "/api/announcements" && method === "DELETE") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      if (!isAdmin(user)) return json({ error: "admins only" }, 403);
      // Same traversal shape as the code-delete route: "?id=..%2Fusers" would have
      // PUT-nulled the users table. One key or nothing.
      const raw = url.searchParams.get("id") || "";

      /* CLEAR ALL — ?all=1. Deliberately NOT a null-PUT on the whole `announcements` subtree:
         one wrong key in that path erases a neighbouring table, and this database has no
         backup. Instead the ids are read first and deleted ONE BY ONE, so the blast radius
         is exactly the records that were listed and nothing else can be caught by it.
         The full list is returned so the caller can show what was removed. */
      if (url.searchParams.get("all") === "1") {
        const node = (await dbGet("announcements")) || {};
        const ids = Object.keys(node).filter((k) => dbKey(k) === k);
        let removed = 0;
        for (const k of ids) {
          try { await dbPut("announcements/" + k, null); removed++; } catch (_) {}
        }
        return json({ ok: true, removed, ids });
      }

      const id = dbKey(raw);
      if (!id || id !== raw) return json({ error: "invalid id" }, 400);
      try { await dbPut("announcements/" + id, null); } catch (_) {}
      return json({ ok: true });
    }
    // ---- Admin knowledge base (RAG reference books) ----
    if (path === "/api/kb" && method === "GET") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      if (!isAdmin(user)) return json({ error: "admins only" }, 403);
      const node = (await dbGet("kb")) || {};
      const books = Object.values(node).map((b) => ({ id: b.id, title: b.title, chunks: (b.chunks || []).length, ts: b.ts })).sort((a, b) => (b.ts || 0) - (a.ts || 0));
      return json({ books });
    }
    if (path === "/api/kb" && method === "POST") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      if (!isAdmin(user)) return json({ error: "admins only" }, 403);
      let p; try { p = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const title = String(p.title || "").slice(0, 200).trim() || "Untitled";
      const text = String(p.text || "");
      if (text.trim().length < 20) return json({ error: "text too short" }, 400);
      const chunks = kbChunk(text);
      if (!chunks.length) return json({ error: "no usable text" }, 400);
      const id = "kb" + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
      const book = { id, title, chunks, ts: Date.now() };
      try { await dbPut("kb/" + dbKey(id), book); } catch (_) {}
      kbCacheBust();
      return json({ ok: true, id, title, chunks: chunks.length });
    }
    if (path === "/api/kb" && method === "DELETE") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      if (!isAdmin(user)) return json({ error: "admins only" }, 403);
      const raw = url.searchParams.get("id") || "";
      const id = dbKey(raw);                       // same traversal shape as the code/announcement deletes
      if (!id || id !== raw) return json({ error: "invalid id" }, 400);
      try { await dbPut("kb/" + id, null); } catch (_) {}
      kbCacheBust();
      return json({ ok: true });
    }

    /* ---- Firas Brain: the per-user document library (members only) ----
       MEMBERS ONLY: a library needs durable server-side storage and a stable owner, and guest
       chats are localStorage-only with a tiny daily budget that per-page OCR would exhaust
       immediately. Guests AND anonymous callers get the SAME signin_required body so the client
       renders one sign-in prompt for both — hence currentUser() with no currentGuest() fallback. */
    if (path === "/api/brain/docs" && method === "GET") {
      const c = await callerOf(context);
      if (!c.id) return json({ error: "signin_required", feature: "brain" }, 403);
      const docs = await brainMetaAll(c.id);   // light node ONLY — never pulls the chunks
      const pagesToday = c.isGuest
        ? (Number((await guestDayNode(c.id).catch(() => ({}))).brainPages) || 0)
        : (c.user.quota && c.user.quota.day === serverDay() ? (c.user.quota.brainPages || 0) : 0);
      return json({
        docs,
        guest: !!c.isGuest,
        limits: { docs: brainDocLimit(c), pagesPerDay: brainPagesLimit(c), visionLeft: brainVisionLeft() },
        used: { docs: docs.length, pagesToday },
      });
    }
    if (path === "/api/brain/doc" && method === "POST") {
      const c = await callerOf(context);
      if (!c.id) return json({ error: "signin_required", feature: "brain" }, 403);
      if (rateLimited("brain:add:" + c.id, 60, 60000)) return json({ error: "too many requests" }, 429);
      // `await request.json()` reads an UNBOUNDED body on the edge — buffer the text with an
      // explicit ceiling instead (declared length first, actual length second, since
      // content-length is client-supplied and absent on a chunked upload).
      const clen = Number(request.headers.get("content-length") || 0);
      if (Number.isFinite(clen) && clen > BRAIN_BODY_LIMIT) return json({ error: "too_large" }, 413);
      let p;
      try {
        const raw = await request.text();
        if (raw.length > BRAIN_BODY_LIMIT) return json({ error: "too_large" }, 413);
        p = JSON.parse(raw || "{}");
      } catch { return json({ error: "too_large" }, 413); }   // matches server.mjs, whose readBody destroys the request past the cap

      const title = String(p.title || "").slice(0, 200).trim() || "Untitled";
      const kind = BRAIN_KINDS.has(p.kind) ? p.kind : "text";
      const unit = BRAIN_UNITS.has(p.unit) ? p.unit : "page";
      const pages = Array.isArray(p.pages) ? p.pages : [];
      if (!pages.length) return json({ error: "no pages" }, 400);
      if (pages.length > BRAIN_MAX_PAGES_PER_REQ) return json({ error: "too_large" }, 413);

      // A continuation part carries the docId minted by part 1; a fresh upload does not.
      let doc = null;
      if (p.docId) {
        if (!brainIdOk(p.docId)) return json({ error: "invalid id" }, 400);
        doc = await brainLoadDoc(c.id, p.docId);
        if (!doc) return json({ error: "not found" }, 404);
      } else {
        const existing = await brainMetaAll(c.id);   // count only → the light node suffices
        if (existing.length >= brainDocLimit(c)) return json({ error: "limit", limit: "docs", max: brainDocLimit(c) }, 429);
      }

      /* Meter the INGEST by DISTINCT PAGE, per day — guests included. Mirrors server.mjs.

         This used to charge `pages.length`, the number of RECORDS in the POST. That was the
         same number for every producer until the spreadsheet reader began emitting one record
         per row group instead of one per sheet: a 5,000-row sheet went from 1 record to 556,
         which a guest (120/day) and a free user (400/day) would hit as a hard 429 on a file
         that used to upload fine. The citable unit is the page/slide/sheet, and that is what
         is charged. For every other producer there is one record per page, so
         seen.size === pages.length and nothing changes. BRAIN_MAX_PAGES_PER_REQ still bounds
         `pages.length`: that one IS a record ceiling, protecting the body not the quota. */
      const seen = new Set(pages.map((pg) => Math.max(1, Math.floor(Number(pg && pg.p) || 0))));
      const pageLimit = brainPagesLimit(c);
      if (pageLimit >= 0) {
        if (c.isGuest) {
          const node = await guestDayNode(c.id).catch(() => ({}));
          const used = Number(node.brainPages) || 0;
          if (used + seen.size > pageLimit) return json({ error: "limit", limit: "pages", used, max: pageLimit, guest: true }, 429);
          try { await dbIncrement(`guestQuota/${dbKey(c.id)}/${serverDay()}/brainPages`, seen.size); } catch (_) {}
        } else {
          const rolled = quotaRollDay(c.user);
          const used = c.user.quota.brainPages || 0;
          if (used + seen.size > pageLimit) return json({ error: "limit", limit: "pages", used, max: pageLimit }, 429);
          c.user.quota.brainPages = used + seen.size;
          try { await saveBrainPages(c.user, rolled, seen.size); } catch (_) {}
        }
      }

      const added = brainChunkPages(pages, kind === "pptx");
      const addedChars = added.reduce((n, c) => n + c.t.length, 0);
      const indexedNow = new Set(added.map((c) => c.p)).size;

      if (!doc) { doc = { id: brainNewId(), title, kind, unit, pages: 0, indexed: 0, ocr: 0, chars: 0, ts: Date.now(), chunks: [] }; if (c.isGuest) doc.guest = true; }
      if ((doc.chunks.length + added.length) > BRAIN_MAX_CHUNKS_PER_DOC) return json({ error: "too_large", limit: "chunks" }, 413);
      if ((doc.chars || 0) + addedChars > BRAIN_MAX_CHARS_PER_DOC) return json({ error: "too_large", limit: "chars" }, 413);

      doc.chunks = doc.chunks.concat(added);
      doc.pages = (doc.pages || 0) + seen.size;
      doc.indexed = (doc.indexed || 0) + indexedNow;
      doc.chars = (doc.chars || 0) + addedChars;
      const ocrAdded = Math.max(0, Math.floor(Number(p.ocr) || 0));
      doc.ocr = (doc.ocr || 0) + ocrAdded;
      if (ocrAdded) brainVisionCharge(ocrAdded);
      doc.ts = Date.now();
      // NOT swallowed — see brainSaveDoc(). Answering { ok: true } on a lost upload would make
      // the client believe hundreds of OCR'd pages are indexed when nothing was stored.
      try { await brainSaveDoc(c.id, doc); } catch (_) { return json({ error: "storage failed" }, 502); }

      return json({ ok: true, id: doc.id, title: doc.title, chunks: added.length, total: doc.chunks.length, doc: brainMetaOf(doc) });
    }
    if (path === "/api/brain/doc" && method === "DELETE") {
      const c = await callerOf(context);
      if (!c.id) return json({ error: "signin_required", feature: "brain" }, 403);
      const raw = url.searchParams.get("id") || "";
      const id = dbKey(raw);                       // same traversal shape as the kb/code/announcement deletes
      if (!id || id !== raw || !brainIdOk(id)) return json({ error: "invalid id" }, 400);
      try { await brainRemoveDoc(c.id, id); } catch (_) { return json({ error: "storage failed" }, 502); }
      return json({ ok: true });
    }
    if (path === "/api/brain/search" && method === "POST") {
      const c = await callerOf(context);
      if (!c.id) return json({ error: "signin_required", feature: "brain" }, 403);
      if (rateLimited("brain:q:" + c.id, 120, 60000)) return json({ error: "too many requests" }, 429);
      // Bounded like the doc POST (server.mjs uses readJson(req, 200_000) here). A malformed
      // body degrades to {} → empty query → { hits: [], docs: n }, exactly as readJson's null does.
      let p = {};
      const qlen = Number(request.headers.get("content-length") || 0);
      if (Number.isFinite(qlen) && qlen > 200_000) return json({ error: "too_large" }, 413);
      try {
        const raw = await request.text();
        if (raw.length > 200_000) return json({ error: "too_large" }, 413);
        p = JSON.parse(raw || "{}") || {};
      } catch (_) { p = {}; }
      const q = String(p.q || "").slice(0, 4000);
      const k = Math.min(Math.max(parseInt(p.k, 10) || 8, 1), 12);
      const want = Array.isArray(p.docIds) ? p.docIds.filter(brainIdOk) : [];

      // THE per-answer charge for Firas Brain. It has to happen here, not on /api/chat: the
      // answer itself streams via streamAgentText with nomem:true, which quota charging
      // deliberately skips. Exactly one search precedes each answer, and the cid makes a retry
      // of the same turn idempotent — same rule the other products use. Mirrors server.mjs.
      const bcid = String(p.cid || "").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64);
      if (c.isGuest) {
        const denied = await guestChargeWithReq(request, context, c.id, "brain", bcid);   // owns roll-over + idempotency
        if (denied) return json(denied, 429);
      } else {
        const blimit = limitsFor(planOf(c.user)).brain;
        if (blimit >= 0) {
          const rolled = quotaRollDay(c.user);
          const bq = c.user.quota;
          if (!(bcid && bq.last.brain === bcid)) {
            if ((bq.brain || 0) >= blimit) {
              return json({ error: "daily quota reached", quota: { product: "brain", used: bq.brain || 0, limit: blimit, plan: planOf(c.user) } }, 429);
            }
            bq.brain = (bq.brain || 0) + 1;
            if (bcid) bq.last.brain = bcid;
            try { await saveQuota(c.user, "brain", bcid, rolled); } catch (_) {}
          }
        }
      }

      let docs = await brainCorpus(c.id);
      if (want.length) { const s = new Set(want); docs = docs.filter((d) => s.has(d.id)); }
      if (!docs.length) return json({ hits: [], docs: 0, mode: "none" });
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
        return json({ hits: flat.slice(off, off + lim), total: flat.length, offset: off, mode: "all" });
      }
      if (p.mode === "overview") {
        return json({ hits: brainOverviewHits(docs), docs: docs.length, mode: "overview" });
      }
      // A lower floor than the admin KB's 0.25: this corpus is the user's OWN documents, where a
      // single strong term match is a legitimate lead rather than noise from an unrelated book.
      // keepDigits=true, matching how brainCorpus() tokenized the chunks (asymmetry matches nothing).
      const hits = brainExpandNeighbours(kbSearchIn(docs, q, k, 0.18, true), docs, 2, k + 20);
      return json({ hits, docs: docs.length, mode: "search" });
    }
    if (path === "/api/brain/passage" && method === "GET") {
      const c = await callerOf(context);
      if (!c.id) return json({ error: "signin_required", feature: "brain" }, 403);
      const docId = url.searchParams.get("doc") || "";
      const ci = parseInt(url.searchParams.get("i"), 10);
      const w = Math.min(Math.max(parseInt(url.searchParams.get("w"), 10) || 2, 0), 5);
      if (!brainIdOk(docId) || !Number.isFinite(ci) || ci < 0) return json({ error: "invalid id" }, 400);
      const docs = await brainCorpus(c.id);
      const doc = docs.find((d) => d.id === docId);
      if (!doc) return json({ error: "not found" }, 404);
      const chunks = doc.chunks || [];
      const hit = chunks[ci];
      if (!hit) return json({ error: "not found" }, 404);
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
      return json({
        docId: doc.id, title: doc.title, kind: doc.kind, unit: doc.unit,
        page, label: (hit && hit.l) || "", ci, text: chunkText(hit),
        before: near(ci - 1, -1, -1), after: near(ci + 1, chunks.length, 1),
      });
    }
    /* ── BACKGROUND AGENT JOBS ───────────────────────────────────────────────────────────
       A mission used to live entirely in the browser tab, so closing the tab stopped it.
       These two routes hand the mission to a Netlify BACKGROUND function, which is a Node
       runtime that keeps executing for up to 15 minutes after the response is sent (and
       re-triggers itself for longer missions). The job record in RTDB is the source of
       truth; the client just polls it, so the tab is now a viewer rather than the engine. */
    if (path === "/api/agent/job" && method === "POST") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      if (!INTERNAL_JOB_SECRET) return json({ error: "background jobs not configured" }, 501);
      if (rateLimited("job:" + user.id, 6, 60000)) return json({ error: "too many requests" }, 429);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const task = String(b.task || "").trim().slice(0, 8000);
      if (!task) return json({ error: "task required" }, 400);

      /* A background mission spends model credit with nobody watching, so it is metered up
         front like any other agent turn rather than trusted to bill itself later. */
      const denied = await (async () => {
        const limit = limitsFor(planOf(user)).agent;
        if (!(limit >= 0)) return null;
        const rolled = quotaRollDay(user);
        if ((user.quota.agent || 0) >= limit) {
          return { error: "daily quota reached", quota: { product: "agent", used: user.quota.agent || 0, limit, plan: planOf(user) } };
        }
        user.quota.agent = (user.quota.agent || 0) + 1;
        try { await saveQuota(user, "agent", null, rolled); } catch (_) {}
        return null;
      })();
      if (denied) return json(denied, 429);

      const jobId = "j" + Date.now().toString(36) + crypto.randomUUID().replace(/-/g, "").slice(0, 8);
      const job = {
        id: jobId, task,
        lang: b.lang === "ar" ? "ar" : "en",
        tier: ["mini", "pro", "ultra", "max"].includes(b.tier) ? b.tier : "max",
        phase: "queued", steps: [], final: "", createdAt: Date.now(), updatedAt: Date.now(),
      };
      await dbPut(`agentJobs/${dbKey(user.id)}/${dbKey(jobId)}`, job);
      // Fire and forget — the background function answers 202 and keeps going without us.
      const kick = fetch(new URL("/.netlify/functions/agent-background", request.url).toString(), {
        method: "POST",
        headers: { "content-type": "application/json", "x-firas-internal": INTERNAL_JOB_SECRET },
        body: JSON.stringify({ jobId, userId: user.id, chain: 0 }),
      }).catch(() => {});
      if (context && typeof context.waitUntil === "function") context.waitUntil(kick);
      return json({ ok: true, job });
    }
    if (path === "/api/agent/job" && method === "GET") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      const id = dbKey(url.searchParams.get("id") || "");
      if (!id) return json({ error: "not found" }, 404);
      // Scoped under the caller's own id, so one user can never read another's mission.
      const job = await dbGet(`agentJobs/${dbKey(user.id)}/${id}`);
      if (!job) return json({ error: "not found" }, 404);
      return json({ ok: true, job });
    }
    if (path === "/api/agent/jobs" && method === "GET") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      const all = (await dbGet(`agentJobs/${dbKey(user.id)}`)) || {};
      // Summary only — the step outputs of every past mission would be megabytes.
      const list = Object.values(all).map((j) => ({
        id: j.id, task: String(j.task || "").slice(0, 200), title: j.title || "",
        phase: j.phase, steps: (j.steps || []).length,
        done: (j.steps || []).filter((s) => s && s.s === "done").length,
        updatedAt: j.updatedAt || 0,
      })).sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 30);
      return json({ ok: true, jobs: list });
    }

    // ── Public share links: snapshot a chat → read-only page at /?share=<id> ──
    if (path === "/api/share" && method === "POST") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const chatId = dbKey(b.chatId);   // body-supplied id → db path (a "../.." here read outside the user's subtree)
      if (!chatId) return json({ error: "not found" }, 404);
      const chat = await dbGet(`chats/${dbKey(user.id)}/${chatId}`);
      if (!chat) return json({ error: "not found" }, 404);
      /* Same bounds as server.mjs handleShareCreate. Each snapshot can carry 400 messages at
         200,000 chars plus 10 thumbnails, and nothing here was rate-limited, capped, or ever
         pruned — a loop over this endpoint inflates RTDB storage until dbPut starts failing
         for every product. The edge does not amplify every OTHER write the way the monolithic
         db.json does, but unbounded is unbounded.
         An index of the caller's shares is kept so a repeat share of one chat reuses its
         snapshot instead of minting another copy — which is also the common real case. */
      if (rateLimited("share:" + user.id, 5, 60000)) return json({ error: "too many requests" }, 429);
      const idxPath = `shareIndex/${dbKey(user.id)}`;
      const idx = (await dbGet(idxPath)) || {};
      const prior = idx[chatId];
      if (prior) {
        try { await dbPut(`shares/${dbKey(prior)}/ts`, Date.now()); } catch (_) {}
        return json({ ok: true, id: prior });
      }
      if (Object.keys(idx).length >= 20) {
        return json({ error: "لقد وصلت إلى الحد الأقصى للمشاركات (20). احذف مشاركة قديمة أولاً." }, 409);
      }
      const id = "s" + Date.now().toString(36) + crypto.randomUUID().replace(/-/g, "").slice(0, 10);
      // Snapshot only what the public page needs — content/lang/tier/thumbs; never raw images,
      // never fileText, never user identity.
      const msgs = (chat.messages || []).slice(0, 400).map((m) => {
        const o = { role: m.role === "assistant" ? "assistant" : "user", content: String(m.content || "").slice(0, 200000) };
        if (m.lang) o.lang = String(m.lang).slice(0, 8);
        if (m.tier) o.tier = String(m.tier).slice(0, 16);
        if (Array.isArray(m.imageThumbs) && m.imageThumbs.length) o.imageThumbs = m.imageThumbs.slice(0, 10).map((s) => String(s).slice(0, 200000));
        return o;
      });
      await dbPut("shares/" + dbKey(id), { id, chatId, title: String(chat.title || "").slice(0, 200), messages: msgs, ts: Date.now(), owner: user.id });
      try { await dbPut(`${idxPath}/${chatId}`, id); } catch (_) {}
      return json({ ok: true, id });
    }
    if (path === "/api/share" && method === "GET") {   // PUBLIC — no auth: this is the whole point
      const id = dbKey(url.searchParams.get("id"));
      if (!id) return json({ error: "missing id" }, 400);
      const snap = await dbGet("shares/" + id);
      if (!snap) return json({ error: "not found" }, 404);
      return json({ id: snap.id, title: snap.title || "", messages: snap.messages || [], ts: snap.ts || 0 });
    }
    if (path === "/api/share" && method === "DELETE") {
      const user = await currentUser(context);
      if (!user) return json({ error: "authentication required" }, 401);
      const id = dbKey(url.searchParams.get("id"));
      const snap = id ? await dbGet("shares/" + id) : null;
      if (snap && snap.owner !== user.id && !isAdmin(user)) return json({ error: "not yours" }, 403);
      if (snap) {
        try { await dbPut("shares/" + id, null); } catch (_) {}
        /* Clear the owner's index entry too, or the per-user cap would count a share that
           no longer exists — the user would hit "you have 20" with none left to delete. */
        if (snap.chatId && snap.owner) { try { await dbPut(`shareIndex/${dbKey(snap.owner)}/${dbKey(snap.chatId)}`, null); } catch (_) {} }
      }
      return json({ ok: true });
    }
    if (path === "/api/translate" && method === "POST") {
      const user = await currentUser(context);
      if (!user) return json({ error: "not authenticated" }, 401);
      if (rateLimited("translate:" + user.id, 40, 60000)) return json({ error: "too many requests" }, 429);
      let p; try { p = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const toName = String(p.to || "").toLowerCase() === "en" ? "English" : "Arabic";
      if (typeof p.title === "string" || typeof p.body === "string") {
        const title = String(p.title || "").slice(0, 400), btext = String(p.body || "").slice(0, 8000);
        if (!title.trim() && !btext.trim()) return json({ title: "", body: "" });
        const sys = "You are a professional translator. Translate the update below into " + toName + ". Keep brand/product names as-is, preserve line breaks and emoji. Respond in EXACTLY this format and nothing else:\n<<<TITLE>>>\n{translated title}\n<<<BODY>>>\n{translated body}";
        const usr = "<<<TITLE>>>\n" + title + "\n<<<BODY>>>\n" + btext;
        try {
          const out = stripEngineAd(String(await translateComplete([{ role: "system", content: sys }, { role: "user", content: usr }]) || ""));
          const tm = out.indexOf("<<<TITLE>>>"), bm = out.indexOf("<<<BODY>>>");
          if (tm !== -1 && bm !== -1 && bm > tm) return json({ title: out.slice(tm + 11, bm).trim(), body: out.slice(bm + 10).trim() });
          return json({ title, body: out.trim() || btext });
        } catch (_) { return json({ title, body: btext }); }
      }
      const text = String(p.text || "").slice(0, 8000);
      if (!text.trim()) return json({ text: "" });
      const sys = "You are a professional translator. Translate the user's text into " + toName + ". Output ONLY the translation — preserve line breaks, formatting and emoji, keep brand/product names as-is. No notes, no quotes.";
      try { const out = stripEngineAd(String(await translateComplete([{ role: "system", content: sys }, { role: "user", content: text }]) || "")).trim(); return json({ text: out || text }); }
      catch (_) { return json({ text }); }
    }

    /* ---- image generation proxy (charge on success by cid) ---- */
    /* ---- video: remaining allowance for today ---- */
    if (path === "/api/video/quota" && method === "GET") {
      const user = await currentUser(context);
      if (!user) return new Response("auth required", { status: 401 });
      const used = Object.keys(await vidDayNode(user.id)).length;
      return json({
        ok: VIDEO_DAILY_LIMIT < 0 || used < VIDEO_DAILY_LIMIT,
        limit: VIDEO_DAILY_LIMIT, used,
        remaining: VIDEO_DAILY_LIMIT < 0 ? -1 : Math.max(0, VIDEO_DAILY_LIMIT - used),
        seconds: VIDEO_SECONDS,
      });
    }

    /* ---- video generation (HuggingFace ZeroGPU pool) ---- */
    if (path === "/api/video" && method === "GET") {
      const user = await currentUser(context);
      if (!user) {
        // Same upsell shape as images: a guest reaching video is a signup moment, not an error.
        if (await currentGuest(context)) return json({ error: "signin_required", feature: "video" }, 403);
        return new Response("auth required", { status: 401 });
      }
      if (rateLimited("vid:" + user.id, 12, 60000)) return new Response("rate limited", { status: 429 });
      const prompt = (url.searchParams.get("prompt") || "").trim().slice(0, 1000);
      if (!prompt) return new Response("no prompt", { status: 400 });
      const seconds = Math.min(10, Math.max(2, parseInt(url.searchParams.get("seconds"), 10) || VIDEO_SECONDS));
      const seed = (url.searchParams.get("seed") || "").replace(/[^0-9]/g, "").slice(0, 12);
      const day = serverDay();
      const node = await vidDayNode(user.id);
      /* Slot derived from the VIDEO, never from a client id — the bypass that made
         IMAGE_DAILY_LIMIT unbounded would be far more expensive on this path. */
      const slot = await vidSlotKey(prompt, seconds, seed);
      const isNew = !(slot in node);
      if (VIDEO_DAILY_LIMIT >= 0 && isNew && Object.keys(node).length >= VIDEO_DAILY_LIMIT) {
        return json({ error: "daily_limit", limit: VIDEO_DAILY_LIMIT, used: Object.keys(node).length }, 429);
      }
      if (!HF_ACCOUNTS.length) return new Response("video engine not configured", { status: 503 });
      /* A clip is ~20s on an idle queue and minutes on a busy one. Netlify Edge only bounds the
         RESPONSE HEADER at 40s, so the body is streamed: headers go out immediately and the MP4
         is enqueued when it exists. Same shape as chatStreamResponse, and the reason a slow
         queue degrades into a wait rather than a failure. */
      const body = new ReadableStream({
        async start(controller) {
          try {
            const out = await generateVideoHF(prompt, seconds, seed, null);
            if (!out || !out.bytes || !out.bytes.length) { controller.error(new Error("no video")); return; }
            if (isNew) { try { await dbPut(`vidQuota/${dbKey(user.id)}/${day}/${dbKey(slot)}`, true); } catch (_) {} }
            controller.enqueue(out.bytes);
            controller.close();
          } catch (_) { try { controller.error(new Error("video generation error")); } catch (__) {} }
        },
      });
      return new Response(body, { headers: { "Content-Type": "video/mp4", "Cache-Control": "public, max-age=86400" } });
    }

    /* EDIT AN EXISTING PICTURE. Every other engine here generates from text alone, so before
       this an edit request could only be answered by describing the photo back. The result is
       stored (as compressed JPEG) and handed back as a key, so the chat card is an ordinary
       /api/image URL that survives a reload. Spends from the same two-a-day allowance and the
       same dollar ceiling as a generated image — an edit is not cheaper than a generation. */
    /* WHY DID THE PICTURE FAIL? Open /api/image/diag while signed in and it says so.

       Image generation walks five engines and only reports the last line of the chain — "image
       generation failed" — which is true and useless: it cannot tell you whether no engine is
       configured, or one is configured and refusing, or the money ran out. Edge function logs
       are the other way to find out, and they are awkward to reach and easy to point at the
       wrong place. This asks each engine what it thinks and hands back the answer.

       It makes ONE real OpenAI call, the cheapest size at the cheapest quality, and does NOT
       charge it against the budget or the daily allowance — it is a probe, not a picture. No
       key or secret is ever included in the reply; only whether one is present, and whatever
       error text the provider returned. */
    if (path === "/api/image/diag" && method === "GET") {
      const user = await currentUser(context);
      if (!user) return new Response("auth required", { status: 401 });
      if (rateLimited("imgdiag:" + user.id, 6, 60000)) return new Response("rate limited", { status: 429 });

      const out = {
        configured: {
          openai: !!OPENAI_API_KEY,
          cloudflare: CF_ACCOUNTS.length,
          puter: !!PUTER_AUTH_TOKEN,
          gemini: !!GEMINI_API_KEY,
          huggingface: !!HF_API_KEY,
        },
        openai: { models: OPENAI_IMAGE_MODELS, quality: OPENAI_IMAGE_QUALITY, tried: [] },
        budget: {
          ceiling: OPENAI_IMAGE_BUDGET_USD,
          spent: null,
          left: null,
          switchedOff: _openaiImagesOff,
        },
        dailyAllowance: OPENAI_IMAGE_DAILY,
        /* The background runner is what lets a picture take minutes instead of seconds. Without
           BOTH of these the job route answers 503, the client falls back to the direct path, and
           editing is not possible at all - so it is worth saying out loud rather than leaving it
           to be deduced from a failure. */
        backgroundRunner: {
          secret: !!INTERNAL_JOB_SECRET,
          database: !!FIREBASE_DB_URL,
          ready: !!(INTERNAL_JOB_SECRET && FIREBASE_DB_URL),
        },
      };
      try { out.budget.spent = await openaiImageSpent(); } catch (e) { out.budget.spent = "unreadable: " + (e && e.message); }
      try { out.budget.left = await openaiImageBudgetLeft(); } catch (_) {}

      /* WHICH NANO BANANA ID DOES THIS ACCOUNT ACTUALLY ACCEPT? Asked rather than assumed - the
         product name is "Nano Banana Pro" and the API id behind it is not something to guess at,
         so each candidate is probed and the winner is named. A rejection here is a NAME problem
         and says so; a 200 that answers with prose instead of pixels is a refusal, which is a
         different thing again and also worth distinguishing. */
      /* THE PROBE MUST OUTLIVE ITSELF. The first version gave every rung 60 seconds, which is
         several times the edge function's own budget - so the diagnostic crashed with "the edge
         function timed out" and told us nothing. Ironically that IS the finding this whole page
         exists to explain, but a tool that dies proving its own point is still a broken tool.
         A hard total budget, and any rung not reached says so rather than being silently absent. */
      const DIAG_TOTAL_MS = 22000, DIAG_PROBE_MS = 9000;
      const diagStarted = Date.now();
      const diagLeft = () => DIAG_TOTAL_MS - (Date.now() - diagStarted);
      out.gemini = { engine: IMAGE_ENGINE, key: !!GEMINI_API_KEY, models: GEMINI_IMAGE_MODELS, tried: [] };
      if (GEMINI_API_KEY) {
        for (const gm of GEMINI_IMAGE_MODELS) {
          if (diagLeft() < 3000) { out.gemini.tried.push({ model: gm, skipped: "ran out of probe time" }); continue; }
          const ac = new AbortController();
          const to = setTimeout(() => { try { ac.abort(); } catch (_) {} }, Math.min(DIAG_PROBE_MS, diagLeft()));
          const t0 = Date.now();
          try {
            const r = await fetch(
              "https://generativelanguage.googleapis.com/v1beta/models/" + gm + ":generateContent",
              {
                method: "POST",
                headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_API_KEY },
                body: JSON.stringify({ contents: [{ parts: [{ text: "a single grey dot" }] }] }),
                signal: ac.signal,
              });
            const body = await r.text().catch(() => "");
            const ms = Date.now() - t0;
            let note = "", imageLen = 0, said = "";
            try {
              const j = JSON.parse(body);
              note = (j.error || {}).message || "";
              for (const c of (j.candidates || [])) {
                for (const p of ((c.content && c.content.parts) || [])) {
                  const inl = p.inlineData || p.inline_data;
                  if (inl && inl.data) imageLen = Math.max(imageLen, String(inl.data).length);
                  if (p.text) said += p.text;
                }
              }
            } catch (_) { note = body.slice(0, 200); }
            out.gemini.tried.push({
              model: gm, status: r.status, ok: r.ok, usable: r.ok && imageLen > 100,
              imageChars: imageLen, ms,
              error: r.ok
                ? (imageLen > 100 ? "" : (said ? "answered with text, not a picture: " + said.slice(0, 160) : "200 with no image"))
                : note.slice(0, 240),
            });
            if (r.ok && imageLen > 100) break;
          } catch (e) {
            out.gemini.tried.push({ model: gm, status: 0, ok: false, usable: false, ms: Date.now() - t0, error: String((e && e.message) || e) });
          } finally { clearTimeout(to); }
        }
        /* An abort at 9 seconds says the model is slower than this probe waits - nothing more.
           Reporting that as "broken" would send us chasing the wrong thing again. */
        out.gemini.tried.forEach((t) => {
          if (!t.usable && !t.skipped && t.status === 0) t.note = "no answer within the probe window - slow, not necessarily broken";
        });
        const gwin = out.gemini.tried.find((t) => t.usable);
        out.gemini.verdict = gwin
          ? ("Nano Banana works on " + gwin.model + " (" + gwin.ms + "ms). This is the engine drawing your pictures.")
          : "No Gemini image model in the ladder produced a picture - see the errors, then set GEMINI_IMAGE_MODEL to a name this account accepts.";
      } else {
        out.gemini.verdict = "GEMINI_API_KEY is not visible to the edge function.";
      }
      out.probeMs = Date.now() - diagStarted;

      if (!OPENAI_API_KEY) {
        out.verdict = "OPENAI_API_KEY is not visible to the edge function. Check the variable name and that its scope includes Edge Functions, then redeploy.";
        return json(out);
      }

      /* Probe at BOTH qualities and TIME them. The cheap probe already proved the key, the model
         and the payload are all fine — 920,368 characters of base64 came back. So the fault is
         after the response, and the two things that differ between this probe and the real path
         are how long the call takes and how big the answer is. Both are now measured, because an
         edge function has a wall-clock budget and a slow medium-quality render can exceed it
         while a fast low-quality one never does. */
      for (const model of OPENAI_IMAGE_MODELS) {
        let settled = false;
        for (const q of [OPENAI_IMAGE_QUALITY]) {
          if (diagLeft() < 3000) { out.openai.tried.push({ model, quality: q, skipped: "ran out of probe time" }); continue; }
          const ac = new AbortController();
          const to = setTimeout(() => { try { ac.abort(); } catch (_) {} }, Math.min(DIAG_PROBE_MS, diagLeft()));
          const t0 = Date.now();
          try {
            const r = await fetch("https://api.openai.com/v1/images/generations", {
              method: "POST",
              headers: { "content-type": "application/json", Authorization: "Bearer " + OPENAI_API_KEY },
              body: JSON.stringify({ model, prompt: "a single grey dot", size: "1024x1024", quality: q, n: 1 }),
              signal: ac.signal,
            });
            const body = await r.text().catch(() => "");
            const ms = Date.now() - t0;
            let note = "", shape = "", imageLen = 0;
            try {
              const j = JSON.parse(body);
              note = (j.error || {}).message || "";
              const d = (j.data && j.data[0]) || null;
              shape = d ? Object.keys(d).join(",") : "no data[]";
              const v = d ? (d.b64_json || d.url || "") : "";
              imageLen = String(v).length;
            } catch (_) { note = body.slice(0, 200); shape = "unparseable"; }
            const usable = r.ok && imageLen > 100;
            out.openai.tried.push({
              model, quality: q, status: r.status, ok: r.ok, usable,
              payload: shape, imageChars: imageLen, approxKB: Math.round(imageLen * 0.75 / 1024), ms,
              error: r.ok
                ? (usable ? "" : "200 and the keys look right, but the image value is " + imageLen + " characters")
                : note.slice(0, 300),
            });
            if (usable && q === OPENAI_IMAGE_QUALITY) { settled = true; break; }
            if (usable) { settled = true; break; }
          } catch (e) {
            out.openai.tried.push({
              model, quality: q, status: 0, ok: false, usable: false,
              ms: Date.now() - t0, error: "request failed: " + ((e && e.message) || e),
            });
          } finally { clearTimeout(to); }
        }
        if (settled) break;
      }

      const good = out.openai.tried.find((t) => t.usable);
      const first = out.openai.tried[0] || {};
      const okButUnreadable = out.openai.tried.find((t) => t.ok && !t.usable);
      out.verdict = good
        ? ("OpenAI works on " + good.model + " (payload: " + good.payload + "). If pictures still fail, the fault is after this point.")
        : okButUnreadable
        ? ("OpenAI accepted the request on " + okButUnreadable.model + " but returned a body with no readable image. Payload keys: " + okButUnreadable.payload)
        : first.status === 401 ? "The key is rejected (401). It is wrong, revoked, or from a different organisation."
        : first.status === 403 ? "The key is refused (403) — most often a Restricted key without the Images permission."
        : first.status === 429 ? "Rate limited or out of credit (429). Read the error text below."
        : (first.status === 400 || first.status === 404) ? "No model name in the ladder was accepted. Set OPENAI_IMAGE_MODEL to a name this account can use."
        : "OpenAI could not be reached. See the error text below.";
      return json(out);
    }
    /* ASK OPENAI FOR A PICTURE WITHOUT A STOPWATCH.

       An edge function cannot wait for a medium or high render — it has a wall-clock budget it
       does not negotiate, and overrunning it kills the whole function along with every fallback
       below it. So the edge stops waiting: it writes a job, fires the background runner, and
       answers at once. netlify/functions/image-background.mjs is a Node runtime with a
       15-minute ceiling; it renders at full quality and stores the result. The browser polls.

       Quality is therefore no longer a hostage to the clock, and nothing silently degrades to
       another engine because a timer expired. */
    if (path === "/api/image/job" && method === "POST") {
      const user = await currentUser(context);
      if (!user) {
        if (await currentGuest(context)) return json({ error: "signin_required", feature: "image" }, 403);
        return new Response("auth required", { status: 401 });
      }
      if (rateLimited("imgjob:" + user.id, 20, 60000)) return new Response("rate limited", { status: 429 });
      // Either engine is enough to accept the job; the runner falls between them as needed.
      if (!OPENAI_API_KEY && !(IMAGE_ENGINE === "gemini" && GEMINI_API_KEY)) {
        return json({ error: "openai_unconfigured" }, 503);
      }
      if (!INTERNAL_JOB_SECRET) return json({ error: "background_unconfigured" }, 503);

      let b = null; try { b = await request.json(); } catch (_) {}
      const prompt = String((b && b.prompt) || "").trim().slice(0, 1000);
      if (!prompt) return json({ error: "bad_request" }, 400);
      const w = Math.min(1280, Math.max(256, parseInt((b && b.w), 10) || 1024));
      const h = Math.min(1280, Math.max(256, parseInt((b && b.h), 10) || 1024));
      const size = openaiImageSize(w, h);
      /* An attached picture turns this into an EDIT. Same road from here — same allowance, same
         ceiling, same storage — because an edit IS a re-render internally and costs the same. */
      const srcB64 = String((b && b.image) || "").replace(/^data:[^,]*,/, "");
      const isEdit = srcB64.length > 0;
      if (isEdit && srcB64.length > 27000000) return json({ error: "bad_image" }, 400);

      if ((await openaiImageBudgetLeft()) < openaiImageMaxCost()) return json({ error: "no_budget" }, 503);

      // Both allowances: the premium two-a-day and the overall five-a-day.
      const slot = await imgSlotKey(prompt, w, h, "");
      if (!(await openaiImageAllowed(user.id, slot))) return json({ error: "daily_limit", limit: OPENAI_IMAGE_DAILY }, 429);
      const day = serverDay();
      const node = await imgDayNode(user.id);
      if (IMAGE_DAILY_LIMIT >= 0 && !(slot in node) && Object.keys(node).length >= IMAGE_DAILY_LIMIT) {
        return json({ error: "daily_limit", limit: IMAGE_DAILY_LIMIT }, 429);
      }

      /* Keyed on the source as well, so editing two different pictures with the same words
         cannot collide - and asking for the same edit twice still reuses the finished one. */
      const jobId = isEdit
        ? await imgSlotKey("edit|" + prompt, 0, 0, await imgSlotKey(srcB64.slice(0, 200000), 0, 0, ""))
        : slot;
      const already = await oaiEditLoad(user.id, jobId);
      if (already) return json({ ok: true, jobId, phase: "done", key: jobId });

      await dbPut(`imgJobs/${dbKey(user.id)}/${dbKey(jobId)}`, {
        id: jobId, prompt, size, quality: OPENAI_IMAGE_QUALITY,
        models: OPENAI_IMAGE_MODELS.join(","),
        engine: IMAGE_ENGINE,
        // gpt-image takes a pixel size, Gemini takes a ratio — carry both, let the runner pick.
        aspect: size === "1536x1024" ? "4:3" : size === "1024x1536" ? "3:4" : "1:1",
        kind: isEdit ? "edit" : "image",
        src: isEdit ? srcB64 : null,          // the runner drops this the moment it is done with it
        phase: "queued", createdAt: Date.now(), updatedAt: Date.now(),
      });
      // Fire and forget — the runner answers immediately and keeps going without us.
      const kick = fetch(new URL("/.netlify/functions/image-background", request.url).toString(), {
        method: "POST",
        headers: { "content-type": "application/json", "x-firas-internal": INTERNAL_JOB_SECRET },
        body: JSON.stringify({ jobId, userId: user.id }),
      }).catch(() => {});
      if (context && typeof context.waitUntil === "function") context.waitUntil(kick);
      return json({ ok: true, jobId, phase: "queued" });
    }

    if (path === "/api/image/job" && method === "GET") {
      const user = await currentUser(context);
      if (!user) return new Response("auth required", { status: 401 });
      const id = dbKey(url.searchParams.get("id") || "");
      if (!id) return json({ error: "not_found" }, 404);
      let job = null;
      try { job = await dbGet(`imgJobs/${dbKey(user.id)}/${id}`); } catch (_) {}
      if (!job) return json({ error: "not_found" }, 404);

      /* Charged HERE, once, when the finished picture is first seen — not when the job was
         queued. A render that failed costs nothing, which is the same rule the synchronous
         path follows. */
      if (job.phase === "done" && !job.charged) {
        await openaiImageCharge(openaiImageCost(job.size || "1024x1024", job.quality || OPENAI_IMAGE_QUALITY));
        await openaiImageMark(user.id, id);
        try { await dbPut(`imgQuota/${dbKey(user.id)}/${serverDay()}/${dbKey(id)}`, true); } catch (_) {}
        job.charged = true;
        try { await dbPut(`imgJobs/${dbKey(user.id)}/${id}`, job); } catch (_) {}
      }
      return json({
        ok: true, phase: job.phase, key: job.key || null, error: job.error || null,
        model: job.model || null, quality: job.quality || null, ms: job.ms || null,
      });
    }

    if (path === "/api/image/edit" && method === "POST") {
      const user = await currentUser(context);
      if (!user) {
        if (await currentGuest(context)) return json({ error: "signin_required", feature: "image" }, 403);
        return new Response("auth required", { status: 401 });
      }
      if (rateLimited("imgedit:" + user.id, 30, 60000)) return new Response("rate limited", { status: 429 });

      let body = null;
      try { body = await request.json(); } catch (_) {}
      const prompt = String((body && body.prompt) || "").trim().slice(0, 1000);
      const rawB64 = String((body && body.image) || "").replace(/^data:[^,]*,/, "");
      if (!prompt || !rawB64) return json({ error: "bad_request" }, 400);

      let src = null;
      try { src = b64ToBytes(rawB64); } catch (_) { src = null; }
      if (!src || !src.length || src.length > 20000000) return json({ error: "bad_image" }, 400);
      /* Trust the BYTES, not the label: a JPEG announced as png comes back as a bare
         "invalid image" with nothing to debug. */
      const sniffed = src.length > 12
        ? (src[0] === 0xFF && src[1] === 0xD8 ? "image/jpeg"
          : (src[0] === 0x89 && src[1] === 0x50 ? "image/png"
            : (String.fromCharCode(...src.slice(0, 4)) === "RIFF" && String.fromCharCode(...src.slice(8, 12)) === "WEBP" ? "image/webp" : "image/png")))
        : "image/png";

      // Keyed on the SOURCE BYTES plus the instruction, so the same edit twice is free.
      const srcHash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-1", src)))
        .map((b) => b.toString(16).padStart(2, "0")).join("");
      const key = await imgSlotKey("edit|" + openaiPickImageModel() + "|" + OPENAI_IMAGE_QUALITY + "|" + prompt, 0, 0, srcHash);

      const already = await oaiEditLoad(user.id, key);
      if (already) return json({ ok: true, key, cached: true });

      // Editing exists ONLY on OpenAI. Say so plainly rather than quietly returning a picture
      // that ignored the instruction — that is the failure this feature exists to remove.
      if (!OPENAI_API_KEY || (await openaiImageBudgetLeft()) < openaiImageMaxCost()) {
        return json({ error: "edit_unavailable" }, 503);
      }
      if (!(await openaiImageAllowed(user.id, key))) return json({ error: "daily_limit", limit: OPENAI_IMAGE_DAILY }, 429);
      const day = serverDay();
      const node = await imgDayNode(user.id);
      if (IMAGE_DAILY_LIMIT >= 0 && !(key in node) && Object.keys(node).length >= IMAGE_DAILY_LIMIT) {
        return json({ error: "daily_limit", limit: IMAGE_DAILY_LIMIT }, 429);
      }

      const out = await editImageOpenAI(prompt, src, sniffed);
      if (!out || !out.bytes || !out.bytes.length) return json({ error: "edit_failed" }, 502);

      /* Priced at the dearest size for this quality: the API picks the output shape from the
         source picture, so the exact one is not known here and the guard must not under-count. */
      await openaiImageCharge(openaiImageMaxCost());
      await oaiEditStore(user.id, key, out.b64, out.mime);
      await openaiImageMark(user.id, key);
      try { await dbPut(`imgQuota/${dbKey(user.id)}/${day}/${dbKey(key)}`, true); } catch (_) {}
      return json({ ok: true, key });
    }
    if (path === "/api/image" && method === "GET") {
      const user = await currentUser(context);
      if (!user) {
        // A GUEST hitting image generation is the upsell moment, not an error.
        if (await currentGuest(context)) return json({ error: "signin_required", feature: "image" }, 403);
        return new Response("auth required", { status: 401 });
      }
      if (rateLimited("img:" + user.id, 240, 60000)) return new Response("rate limited", { status: 429 });
      /* A finished EDIT is addressed by key: it already exists and was already charged, so this
         is a pure read. That is what lets an edited picture sit in the chat as an ordinary
         <img src> and survive a reload without being remade or recharged. */
      const editKey = (url.searchParams.get("key") || "").replace(/[^a-f0-9]/g, "").slice(0, 64);
      if (editKey) {
        const hit = await oaiEditLoad(user.id, editKey);
        if (!hit) return new Response("not found", { status: 404 });
        return new Response(hit.bytes, { headers: { "Content-Type": hit.mime, "Cache-Control": "private, max-age=86400" } });
      }
      const prompt = (url.searchParams.get("prompt") || "").trim().slice(0, 1000);
      if (!prompt) return new Response("no prompt", { status: 400 });
      /* The cid parsing that used to live here is GONE, not merely unused. It existed to
         give the daily slot a key, and the slot is now derived from the image itself — so
         leaving a `cid` variable in scope would only invite a future edit to key billing on
         it again, which is the exact bug below. The client may still send ?cid=… ; nothing
         reads it here any more. */
      /* ── IMAGE QUOTA BYPASS, CLOSED ─────────────────────────────────────────────────
         The daily slot used to be keyed on `cid` — a raw query parameter. `isNew` was
         `!(cid in node)`, and the 5/day check only ran when the cid was new, so:
             GET /api/image?cid=X&prompt=first     → charges one of the five slots
             GET /api/image?cid=X&prompt=anything  → isNew false, limit branch skipped
                                                     entirely, brand-new picture generated
         repeated forever. IMAGE_DAILY_LIMIT became unbounded, on a path that spends paid
         Puter/Cloudflare credit, with only a per-isolate rate limiter left in front of it.

         The slot is now derived from the IMAGE (prompt + size + seed), exactly as
         server.mjs does it. A genuine reload of the same picture is still free, because it
         hashes to the same slot; a different prompt costs a slot, because it cannot. The
         client's cid no longer decides anything about billing.
         w/h/seed are parsed BEFORE the check because the slot depends on them. */
      const w = Math.min(1280, Math.max(256, parseInt(url.searchParams.get("w"), 10) || 1024));
      const h = Math.min(1280, Math.max(256, parseInt(url.searchParams.get("h"), 10) || 1024));
      const seed = (url.searchParams.get("seed") || "").replace(/[^0-9]/g, "").slice(0, 12);
      const day = serverDay();
      const node = await imgDayNode(user.id);
      const slot = await imgSlotKey(prompt, w, h, seed);
      const isNew = !(slot in node);
      if (IMAGE_DAILY_LIMIT >= 0 && isNew && Object.keys(node).length >= IMAGE_DAILY_LIMIT) return new Response("daily limit reached", { status: 429 });
      /* OpenAI gpt-image FIRST — the sharpest engine, and the one being paid for. Three gates,
         all of which must pass: a key, money left against the ceiling, and one of this user's
         two premium images for the day. Any failure returns null and Cloudflare answers, so this
         can only make the result better, never break the request. */
      if (OPENAI_API_KEY && await openaiImageAllowed(user.id, slot)) {
        try {
          const oai = await generateImageOpenAI(prompt, w, h);
          if (oai && oai.bytes && oai.bytes.length) {
            // Priced at the size actually requested — square and portrait do not cost the same.
            // Charged at the quality that was actually produced: a medium request that fell back to low
            // costs low, and the ceiling stays honest.
            await openaiImageCharge(openaiImageCost(openaiImageSize(w, h), oai.quality || OPENAI_IMAGE_QUALITY));
            await openaiImageMark(user.id, slot);
            if (isNew) { try { await dbPut(`imgQuota/${dbKey(user.id)}/${day}/${dbKey(slot)}`, true); } catch (_) {} }
            return new Response(oai.bytes, { headers: { "Content-Type": oai.mime, "Cache-Control": "public, max-age=86400" } });
          }
        } catch (_) { /* fall through to Cloudflare */ }
      }
      // Cloudflare Workers AI (FREE FLUX.2, ~65/day) → great quality + in-image text,
      // no per-image cost, no user login. Falls through to Puter when its daily quota is gone.
      try {
        const cf = await generateImageCloudflare(prompt, w, h);
        if (cf && cf.bytes && cf.bytes.length) {
          if (isNew) { try { await dbPut(`imgQuota/${dbKey(user.id)}/${day}/${dbKey(slot)}`, true); } catch (_) {} }
          return new Response(cf.bytes, { headers: { "Content-Type": cf.mime, "Cache-Control": "public, max-age=86400" } });
        }
      } catch (_) { /* fall through */ }
      // Puter gpt-image-2 (paid credits) → premium fallback: the sharpest in-image text.
      try {
        const put = await generateImagePuter(prompt);
        if (put && put.bytes && put.bytes.length) {
          if (isNew) { try { await dbPut(`imgQuota/${dbKey(user.id)}/${day}/${dbKey(slot)}`, true); } catch (_) {} }
          return new Response(put.bytes, { headers: { "Content-Type": put.mime, "Cache-Control": "public, max-age=86400" } });
        }
      } catch (_) { /* fall through */ }
      // Gemini (free key) → actual Gemini-image quality; else keyless pollinations.
      try {
        const gem = await generateImageGemini(prompt);
        if (gem && gem.bytes && gem.bytes.length) {
          if (isNew) { try { await dbPut(`imgQuota/${dbKey(user.id)}/${day}/${dbKey(slot)}`, true); } catch (_) {} }
          return new Response(gem.bytes, { headers: { "Content-Type": gem.mime, "Cache-Control": "public, max-age=86400" } });
        }
      } catch (_) { /* fall through */ }
      // Hugging Face FLUX.1-schnell (free token) → lossless PNG; ~on par with keyless.
      try {
        const hf = await generateImageHF(prompt);
        if (hf && hf.bytes && hf.bytes.length) {
          if (isNew) { try { await dbPut(`imgQuota/${dbKey(user.id)}/${day}/${dbKey(slot)}`, true); } catch (_) {} }
          return new Response(hf.bytes, { headers: { "Content-Type": hf.mime, "Cache-Control": "public, max-age=86400" } });
        }
      } catch (_) { /* fall through to pollinations */ }
      const src = "https://image.pollinations.ai/prompt/" + encodeURIComponent(prompt) + "?width=" + w + "&height=" + h + "&nologo=true&enhance=true&private=true&nofeed=true&model=flux" + (seed ? "&seed=" + seed : "");
      try {
        const r = await fetch(src, { headers: { "User-Agent": SEARCH_UA, "Accept": "image/*" } });
        if (!r.ok) return new Response("image generation failed", { status: 502 });
        const buf = new Uint8Array(await r.arrayBuffer());
        if (isNew) { try { await dbPut(`imgQuota/${dbKey(user.id)}/${day}/${dbKey(slot)}`, true); } catch (_) {} } // charge once, on success
        return new Response(buf, { headers: { "Content-Type": r.headers.get("content-type") || "image/jpeg", "Cache-Control": "public, max-age=86400" } });
      } catch (_) { return new Response("image generation error", { status: 502 }); }
    }

    /* ---- web search ---- */
    if (path === "/api/search" && method === "GET") {
      const caller = await callerOf(context);
      let user = caller.user || (caller.id ? { id: caller.id } : null);
      /* Same internal channel as /api/chat: the background agent runner has no cookie, so it
         presents the deploy secret plus the id of the user whose mission it is running. The
         rate limit below then applies to that user exactly as it would in the foreground. */
      if (!user && INTERNAL_JOB_SECRET && request.headers.get("x-firas-internal") === INTERNAL_JOB_SECRET) {
        const jid = String(request.headers.get("x-firas-job-user") || "");
        if (jid) { const ju = await getUserById(jid); if (ju) user = { id: ju.id }; }
      }
      if (!user) return json({ results: [], error: "auth" }, 401);
      if (rateLimited("search:" + user.id, 30, 60000)) return json({ results: [], error: "rate" }, 429);
      const q = (url.searchParams.get("q") || "").trim().slice(0, 300);
      if (!q) return json({ results: [] }, 400);
      let results = [];
      try {
        const r = await fetch("https://html.duckduckgo.com/html/?q=" + encodeURIComponent(q), { headers: { "User-Agent": SEARCH_UA, "Accept-Language": "ar,en-US;q=0.8,en;q=0.6", "Accept": "text/html" } });
        if (r.ok) results = parseDuckDuckGo(await r.text()).slice(0, 6);
      } catch (_) {}
      return json({ q, results });
    }
    if (path === "/api/images" && method === "GET") {
      const caller = await callerOf(context);
      const user = caller.user || (caller.id ? { id: caller.id } : null);
      if (!user) return json({ results: [], error: "auth" }, 401);
      if (rateLimited("images:" + user.id, 40, 60000)) return json({ results: [], error: "rate" }, 429);
      const q = (url.searchParams.get("q") || "").trim().slice(0, 120);
      if (!q) return json({ results: [] }, 400);
      let results = [];
      try {
        const r = await fetch("https://api.openverse.org/v1/images/?format=json&mature=false&page_size=10&q=" + encodeURIComponent(q), { headers: { "User-Agent": SEARCH_UA, "Accept": "application/json" } });
        if (r.ok) { const d = await r.json(); results = (Array.isArray(d.results) ? d.results : []).map((x) => ({ url: x.thumbnail || x.url, title: String(x.title || "").slice(0, 100) })).filter((x) => x.url && /^https:\/\//.test(x.url)).slice(0, 8); }
      } catch (_) {}
      return json({ q, results });
    }
    if (path === "/api/imgproxy" && method === "GET") {
      const caller = await callerOf(context);
      const user = caller.user || (caller.id ? { id: caller.id } : null);
      if (!user) return json({ error: "auth" }, 401);
      if (rateLimited("imgproxy:" + user.id, 80, 60000)) return new Response(null, { status: 429 });
      const target = (url.searchParams.get("u") || "").trim();
      let host = "";
      try { host = new URL(target).hostname.toLowerCase(); } catch { return new Response(null, { status: 400 }); }
      if (!/^https:\/\//i.test(target) || proxyHostBlocked(host)) return new Response(null, { status: 400 });
      try {
        const r = await safeProxyFetch(target, { "User-Agent": SEARCH_UA, "Accept": "image/*" }, 3);
        const ct = r.headers.get("content-type") || "";
        if (!r.ok || !/^image\//i.test(ct)) return new Response(null, { status: 415 });
        const buf = await r.arrayBuffer();
        if (buf.byteLength > 4000000) return new Response(null, { status: 413 });
        return new Response(buf, { status: 200, headers: { "Content-Type": ct, "Cache-Control": "public, max-age=86400" } });
      } catch (_) { return new Response(null, { status: 502 }); }
    }
    if (path === "/api/fetch" && method === "GET") {
      const caller = await callerOf(context);
      const user = caller.user || (caller.id ? { id: caller.id } : null);
      if (!user) return json({ text: "", error: "auth" }, 401);
      if (rateLimited("fetch:" + user.id, 20, 60000)) return json({ text: "", error: "rate" }, 429);
      let target = (url.searchParams.get("url") || "").trim();
      if (!/^https?:\/\//i.test(target)) target = "https://" + target;
      let host = "";
      try { host = new URL(target).hostname.toLowerCase(); } catch { return json({ text: "", error: "bad url" }, 400); }
      if (proxyHostBlocked(host)) return json({ text: "", error: "blocked" }, 400);
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
      } catch (_) {}
      return json({ url: target, title, text });
    }

    if (path === "/api/transcribe" && method === "POST") {
      const caller = await callerOf(context);
      const user = caller.user || (caller.id ? { id: caller.id } : null);
      if (!user) return json({ error: "authentication required" }, 401);
      if (caller.isGuest && rateLimited("stt:" + caller.id, 12, 60000)) return json({ error: "rate limited" }, 429);
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      if (b && b.probe) return json({ ok: GEMINI_KEYS.length > 0 });
      if (!GEMINI_KEYS.length) return json({ error: "no stt engine" }, 503);
      if (rateLimited("stt:" + user.id, 20, 60000)) return json({ error: "rate limited" }, 429);
      { const denied = await chargeVoiceEdge(caller); if (denied) return json(denied, 429); }
      const audio = String((b && b.audio) || "").replace(/^data:audio\/[a-z0-9.+-]+;base64,/i, "");
      if (!audio || audio.length < 4000 || audio.length > 20000000 || !/^[A-Za-z0-9+/=]+$/.test(audio)) return json({ error: "bad audio" }, 400);
      try { const t = await geminiSTT(audio, b.format === "mp3" ? "mp3" : "wav", String(b.lang || "auto")); return json({ text: typeof t === "string" ? t : "" }); }
      catch (_) { return json({ error: "stt unavailable" }, 502); }
    }
    if (path === "/api/tts" && method === "POST") {
      const caller = await callerOf(context);
      const user = caller.user || (caller.id ? { id: caller.id } : null);
      if (!user) return json({ error: "authentication required" }, 401);
      if (rateLimited("tts:" + user.id, caller.isGuest ? 25 : 90, 60000)) return json({ error: "rate limited" }, 429);
      { const denied = await chargeVoiceEdge(caller); if (denied) return json(denied, 429); }
      let b; try { b = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const text = String((b && b.text) || "").replace(/\s+/g, " ").trim().slice(0, 1400);
      if (!text) return new Response("", { status: 400 });
      const raw = String((b && b.lang) || "").toLowerCase();
      const lang = raw.startsWith("ar") ? "ar" : (/^[a-z]{2}(-[a-z]{2})?$/.test(raw) ? raw.slice(0, 2) : "en");
      // Arabic → Gemini expressive voice; every other language → Google TTS (Edge neural needs Node).
      let audio = null;
      if (lang === "ar") { try { audio = await geminiTtsSynth(text, raw || lang); } catch (_) {} }
      if (!audio) { try { audio = await googleTtsSynth(text, lang); } catch (_) {} }
      if (!audio || !audio.bytes || !audio.bytes.length) return json({ error: "tts unavailable" }, 502);
      return new Response(audio.bytes, { status: 200, headers: { "content-type": audio.type, "cache-control": "no-store", "X-TTS-Engine": audio.type === "audio/wav" ? "gemini" : "google" } });
    }
    return json({ error: "not found" }, 404);
  } catch (e) {
    // Never echo internal error text (Firebase status codes / response fragments) to the client.
    try { console.error("api error:", e); } catch (_) {}
    return json({ error: "internal error" }, 500);
  }
};

/** True when an IP literal falls in a range that must never be reachable from the proxy. */
function privateIp(ip) {
  const s = String(ip || "");
  if (/^(::1|::ffff:127\.|fe80:|fc|fd)/i.test(s)) return true;          // v6 loopback/link-local/ULA
  const m = /^(?:::ffff:)?(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
  if (!m) return false;
  const a = +m[1], b = +m[2];
  return a === 0 || a === 127 || a === 10                                // this-host, loopback, private
    || (a === 169 && b === 254)                                          // link-local + cloud metadata
    || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && b === 168)
    || (a === 100 && b >= 64 && b <= 127)                                // CGNAT
    || a >= 224;                                                         // multicast / reserved
}

/* SSRF guard shared by the proxies. Mirrors server.mjs.
   The name test alone only catches hosts that LOOK internal — a public name whose A record
   is 127.0.0.1 or 169.254.169.254 sails through it. proxyHostAllowed() below resolves the
   name too, so the ADDRESS is what decides. */
function proxyHostBlocked(host) {
  const bare = String(host || "").replace(/^\[|\]$/g, "");
  return /^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|0\.|::1|\[)/.test(host)
    || /\.local$/.test(host)
    || host === "metadata.google.internal"
    || privateIp(bare);
}

/** Resolve `host` and reject it when any address it maps to is private.
    Deno.resolveDns needs --allow-net and is not guaranteed on every edge runtime, so its
    absence is not treated as failure — the name test above still applies, and the edge
    sandbox does not route private ranges outbound in the first place. */
async function proxyHostAllowed(host) {
  if (proxyHostBlocked(host)) return false;
  const bare = String(host).replace(/^\[|\]$/g, "");
  if (/^[\d.]+$/.test(bare) || bare.includes(":")) return true;          // already an IP literal, checked above
  try {
    if (typeof Deno === "undefined" || typeof Deno.resolveDns !== "function") return true;
    const settled = await Promise.allSettled([Deno.resolveDns(bare, "A"), Deno.resolveDns(bare, "AAAA")]);
    const addrs = settled.flatMap((r) => (r.status === "fulfilled" ? r.value : []));
    if (!addrs.length) return true;                                      // no answer we can judge → defer to the name test
    return !addrs.some((a) => privateIp(a));                             // one private answer = rebinding attempt
  } catch { return true; }
}
/* Fetch with MANUAL redirect handling: every hop's hostname is re-validated, so a public host
   can't 302 the proxy into localhost / the cloud metadata service (classic SSRF bypass). */
async function safeProxyFetch(target, headers, maxHops) {
  let cur = target;
  for (let hop = 0; hop <= (maxHops || 3); hop++) {
    const host = new URL(cur).hostname.toLowerCase();
    // Resolve EVERY hop: a public host can 302 into a name that points at loopback.
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

export const config = { path: "/api/*" };
