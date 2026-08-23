/* ════════════════════════════════════════════════════════════════════════════════════════
   FIRAS IMAGES — BACKGROUND RUNNER

   WHY THIS FILE EXISTS
   The picture has to come from OpenAI, and OpenAI takes as long as it takes. An edge function
   cannot wait: it has a wall-clock budget it does not get to negotiate, and a render that
   outlives it does not fail politely — the platform kills the function, taking every fallback
   engine down with it. That is why a working key kept producing a Cloudflare picture with
   mangled Arabic in it, and why raising the timeout could never have fixed it.

   A Netlify BACKGROUND function is a Node runtime that keeps executing after the client is
   gone, with a 15-minute ceiling instead of seconds. So the edge stops waiting: it writes a
   job, fires this, and answers immediately. This calls OpenAI with all the time in the world,
   stores the finished picture, and marks the job done. The browser polls and shows it.

   The result is that quality is no longer a hostage to the clock. Medium — or high — renders
   for as long as it needs, and nothing falls through to another engine because of a stopwatch.

   Mirrors agent-background.mjs: same internal-secret guard, same RTDB helpers, same
   fire-and-forget contract.
   ════════════════════════════════════════════════════════════════════════════════════════ */

const FIREBASE_DB_URL = (process.env.FIREBASE_DB_URL || "").replace(/\/+$/, "");
const INTERNAL_SECRET = process.env.INTERNAL_JOB_SECRET || "";
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || "";

/* Generous on purpose — this is the whole point of the file. Still short of the 15-minute
   ceiling so a stuck render is recorded as failed rather than vanishing without a trace. */
const RENDER_TIMEOUT_MS = Number(process.env.OPENAI_IMAGE_JOB_TIMEOUT_MS) || 11 * 60 * 1000;

/* THE MONEY GUARD LIVES HERE NOW. The edge used to refuse a job outright when the OpenAI
   balance was low, which was wrong once Nano Banana became the first engine: a spent OpenAI
   balance was turning away jobs that were never going to cost anything. That refusal is gone,
   so the ceiling has to be enforced at the only place that actually spends — right before the
   gpt-image loop, after Gemini has had its turn and failed. Same ledger key as the edge
   (spend/openaiImageUsd) and the same default prices, so the two agree on what has been spent. */
const OPENAI_IMAGE_BUDGET_USD = Number(process.env.OPENAI_IMAGE_BUDGET_USD ?? 60);
const OPENAI_IMAGE_PRICES = (() => {
  const dflt = {
    low:    { "1024x1024": 0.006, "1024x1536": 0.005, "1536x1024": 0.005 },
    medium: { "1024x1024": 0.053, "1024x1536": 0.041, "1536x1024": 0.041 },
    high:   { "1024x1024": 0.211, "1024x1536": 0.165, "1536x1024": 0.165 },
  };
  try {
    const raw = process.env.OPENAI_IMAGE_PRICES;
    if (raw) { const o = JSON.parse(raw); if (o && typeof o === "object") return o; }
  } catch { /* keep the defaults */ }
  return dflt;
})();
/** An unrecognised size or quality must OVER-charge the guard, never under-charge it. */
function openaiImageCost(size, quality) {
  const row = OPENAI_IMAGE_PRICES[String(quality || "high").toLowerCase()];
  const cost = row && row[size];
  if (typeof cost === "number" && cost > 0) return cost;
  let worst = 0;
  for (const r of Object.values(OPENAI_IMAGE_PRICES)) {
    for (const v of Object.values(r || {})) if (typeof v === "number" && v > worst) worst = v;
  }
  return worst || 0.25;
}
async function openaiSpentUsd(token) {
  try { return Number(await dbGet("spend/openaiImageUsd", token)) || 0; } catch { return 0; }
}
async function openaiChargeUsd(token, cost) {
  try { await dbPut("spend/openaiImageUsd", (await openaiSpentUsd(token)) + cost, token); } catch { /* the render already happened */ }
}

async function fbToken() {
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT || "";
  if (!raw) return null;
  let sa; try { sa = JSON.parse(raw); } catch { return null; }
  const now = Math.floor(Date.now() / 1000);
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const unsigned = b64({ alg: "RS256", typ: "JWT" }) + "." + b64({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.database https://www.googleapis.com/auth/userinfo.email",
    aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600,
  });
  const { createSign } = await import("node:crypto");
  const sign = createSign("RSA-SHA256"); sign.update(unsigned); sign.end();
  const jwt = unsigned + "." + sign.sign(sa.private_key).toString("base64url");
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }),
  });
  if (!r.ok) return null;
  return (await r.json()).access_token || null;
}
async function dbGet(path, token) {
  const r = await fetch(`${FIREBASE_DB_URL}/${path}.json`, { headers: { Authorization: "Bearer " + token } });
  if (!r.ok) throw new Error("db get " + r.status);
  return await r.json();
}
async function dbPut(path, value, token) {
  const r = await fetch(`${FIREBASE_DB_URL}/${path}.json?print=silent`, {
    method: "PUT", headers: { Authorization: "Bearer " + token, "content-type": "application/json" },
    body: JSON.stringify(value),
  });
  if (!r.ok) throw new Error("db put " + r.status + " " + (await r.text()).slice(0, 200));
}

/** Read one OpenAI image reply. Returns { b64, mime } or { reason, detail } — never throws. */
async function parseImageReply(r, model) {
  const text = await r.text();
  if (!r.ok) {
    let msg = text.slice(0, 300);
    try { msg = (JSON.parse(text).error || {}).message || msg; } catch { /* keep the raw text */ }
    const modelFault = (r.status === 400 || r.status === 404) && /model/i.test(msg);
    return { reason: modelFault ? "model" : "http", status: r.status, detail: model + ": " + msg };
  }
  let j = null; try { j = JSON.parse(text); } catch { /* handled below */ }
  const d = (j && j.data && j.data[0]) || null;
  if (d && d.b64_json) return { b64: d.b64_json, mime: "image/png" };
  /* Some models answer with a link rather than the bytes. */
  if (d && d.url) {
    const img = await fetch(d.url);
    if (img.ok) {
      const buf = Buffer.from(await img.arrayBuffer());
      if (buf.length) return { b64: buf.toString("base64"), mime: img.headers.get("content-type") || "image/png" };
    }
    return { reason: "link", detail: "image link returned HTTP " + img.status };
  }
  return { reason: "empty", detail: "payload keys: " + (d ? Object.keys(d).join(",") : "no data[]") };
}

/** Trust the BYTES, not the label: a JPEG announced as png comes back as a bare "invalid image". */
function sniffImageType(buf) {
  if (buf.length > 12) {
    if (buf[0] === 0xFF && buf[1] === 0xD8) return "image/jpeg";
    if (buf[0] === 0x89 && buf[1] === 0x50) return "image/png";
    if (buf.slice(0, 4).toString("ascii") === "RIFF" && buf.slice(8, 12).toString("ascii") === "WEBP") return "image/webp";
  }
  return "image/png";
}

/** Make a new picture from a description. */
async function render(model, prompt, size, quality) {
  const ac = new AbortController();
  const to = setTimeout(() => { try { ac.abort(); } catch { /* already gone */ } }, RENDER_TIMEOUT_MS);
  try {
    const r = await fetch("https://api.openai.com/v1/images/generations", {
      method: "POST",
      headers: { "content-type": "application/json", Authorization: "Bearer " + OPENAI_API_KEY },
      body: JSON.stringify({ model, prompt: String(prompt || "").slice(0, 4000), size, quality, n: 1 }),
      signal: ac.signal,
    });
    return await parseImageReply(r, model);
  } catch (e) {
    return { reason: ac.signal.aborted ? "timeout" : "network", detail: String((e && e.message) || e) };
  } finally { clearTimeout(to); }
}

/** Change an existing picture from an instruction. Same 11-minute budget as a fresh render —
    an edit is a full re-render internally and is no faster, which is exactly why it belongs
    here rather than inside an edge function's stopwatch. */
async function renderEdit(model, prompt, srcB64, quality) {
  const ac = new AbortController();
  const to = setTimeout(() => { try { ac.abort(); } catch { /* already gone */ } }, RENDER_TIMEOUT_MS);
  try {
    const buf = Buffer.from(String(srcB64 || ""), "base64");
    if (!buf.length) return { reason: "empty", detail: "the source picture was unreadable" };
    const type = sniffImageType(buf);
    const ext = type === "image/jpeg" ? "jpg" : type === "image/webp" ? "webp" : "png";
    const fd = new FormData();
    fd.append("model", model);
    fd.append("prompt", String(prompt || "").slice(0, 4000));
    fd.append("quality", quality);
    fd.append("n", "1");
    // JPEG so the result is small enough to keep in the database and serve back by key.
    fd.append("output_format", "jpeg");
    fd.append("output_compression", "85");
    fd.append("image", new Blob([buf], { type }), "source." + ext);
    const r = await fetch("https://api.openai.com/v1/images/edits", {
      method: "POST",
      headers: { Authorization: "Bearer " + OPENAI_API_KEY },   // FormData sets its own boundary
      body: fd,
      signal: ac.signal,
    });
    const out = await parseImageReply(r, model);
    if (out.b64) out.mime = "image/jpeg";
    return out;
  } catch (e) {
    return { reason: ac.signal.aborted ? "timeout" : "network", detail: String((e && e.message) || e) };
  } finally { clearTimeout(to); }
}


/* NANO BANANA (Gemini image) — the primary engine, with gpt-image behind it.

   Firas's Google AI Pro subscription opens Nano Banana Pro through AI Studio, and its selling
   point is the exact thing that has been wrong in every Arabic logo so far: text rendered inside
   the picture, in non-Latin scripts. So it goes first and gpt-image becomes the fallback. If it
   disappoints, IMAGE_ENGINE=openai puts things back the way they were — one variable, no redeploy.

   The model id is a LADDER rather than a guess. Google's marketing name is "Nano Banana Pro" and
   the API id is not something to assume; the ladder tries each candidate and uses the first the
   account actually accepts, so a wrong name costs one fast 404 instead of a broken engine. */
const GEMINI_API_KEY = process.env.GEMINI_API_KEY || "";
const GEMINI_IMAGE_MODELS = String(process.env.GEMINI_IMAGE_MODEL ||
  "gemini-3-pro-image-preview,gemini-3-pro-image,gemini-2.5-flash-image")
  .split(",").map((m) => m.trim()).filter(Boolean);

/** One Gemini image attempt. Returns { b64, mime } or { reason, detail }. */
async function renderGemini(model, prompt, srcB64, aspect, withConfig) {
  const ac = new AbortController();
  const to = setTimeout(() => { try { ac.abort(); } catch { /* already gone */ } }, RENDER_TIMEOUT_MS);
  try {
    /* An attached picture rides in the SAME parts array as the instruction — that is how Gemini
       edits: it is given the picture and told what to change, rather than a separate endpoint. */
    const shapeWord = aspect === "4:3" ? " Compose it as a WIDE landscape image."
      : aspect === "3:4" ? " Compose it as a TALL portrait image."
      : aspect === "1:1" ? " Compose it as a SQUARE image." : "";
    const parts = [{ text: String(prompt || "").slice(0, 4000) + shapeWord }];
    if (srcB64) {
      const buf = Buffer.from(String(srcB64), "base64");
      if (buf.length) parts.unshift({ inlineData: { mimeType: sniffImageType(buf), data: String(srcB64) } });
    }
    /* The aspect ratio is asked for TWICE, in two different registers: once as a structured
       field, and once in plain words inside the prompt. The field is the one that actually binds,
       but its exact name is not something to bet the engine on - so `withConfig` false retries
       without it, and the words in the prompt still carry the intent. */
    const body = { contents: [{ parts }] };
    if (withConfig && aspect) body.generationConfig = { imageConfig: { aspectRatio: aspect } };
    const r = await fetch(
      "https://generativelanguage.googleapis.com/v1beta/models/" + model + ":generateContent",
      {
        method: "POST",
        headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_API_KEY },
        body: JSON.stringify(body),
        signal: ac.signal,
      });
    const text = await r.text();
    if (!r.ok) {
      let msg = text.slice(0, 300);
      try { msg = (JSON.parse(text).error || {}).message || msg; } catch { /* keep the raw text */ }
      /* An unknown field comes back as a 400 naming it. That is a REQUEST fault, not a model
         fault, and the caller retries once without the config rather than skipping the rung. */
      if (r.status === 400 && withConfig && /aspect|imageConfig|generationConfig|unknown name|invalid json/i.test(msg)) {
        return { reason: "config", detail: model + ": " + msg };
      }
      const nameFault = (r.status === 404 || r.status === 400) && /model|not found|not supported/i.test(msg);
      return { reason: nameFault ? "model" : "http", status: r.status, detail: model + ": " + msg };
    }
    let j = null; try { j = JSON.parse(text); } catch { /* handled below */ }
    const cands = (j && j.candidates) || [];
    for (const c of cands) {
      const ps = (c && c.content && c.content.parts) || [];
      for (const p of ps) {
        const inl = p.inlineData || p.inline_data;
        if (inl && inl.data) return { b64: inl.data, mime: inl.mimeType || inl.mime_type || "image/png" };
      }
    }
    /* A refusal comes back as 200 with prose instead of pixels — worth naming, because it is not
       the same thing as an engine being broken. */
    const said = cands[0] && cands[0].content && cands[0].content.parts &&
      cands[0].content.parts.map((p) => p.text).filter(Boolean).join(" ").slice(0, 200);
    return { reason: "empty", detail: said ? "answered with text: " + said : "no image in the reply" };
  } catch (e) {
    return { reason: ac.signal.aborted ? "timeout" : "network", detail: String((e && e.message) || e) };
  } finally { clearTimeout(to); }
}

export default async (req) => {
  if (!INTERNAL_SECRET || req.headers.get("x-firas-internal") !== INTERNAL_SECRET) {
    return new Response("forbidden", { status: 403 });
  }
  let body = {}; try { body = await req.json(); } catch { /* keep {} */ }
  const { jobId, userId } = body;
  if (!jobId || !userId) return new Response("bad request", { status: 400 });
  /* EITHER engine is enough to run a job. This used to demand an OpenAI key before doing
     anything, which meant an unfunded or missing OpenAI account killed jobs that were never
     going to touch OpenAI — Nano Banana is the FIRST engine below and costs nothing. */
  if (!OPENAI_API_KEY && !GEMINI_API_KEY) return new Response("no key", { status: 500 });

  const token = await fbToken();
  if (!token) return new Response("no db", { status: 500 });
  const path = `imgJobs/${userId}/${jobId}`;

  let job;
  try { job = await dbGet(path, token); } catch { return new Response("gone", { status: 404 }); }
  if (!job || job.phase === "done" || job.phase === "fail") return new Response("ok");

  const save = async (patch) => {
    job = Object.assign(job, patch, { updatedAt: Date.now() });
    try { await dbPut(path, job, token); } catch { /* the next write will carry it */ }
  };
  await save({ phase: "running" });

  const models = String(job.models || "gpt-image-2").split(",").map((m) => m.trim()).filter(Boolean);
  const started = Date.now();
  let last = null;

  /* An EDIT and a fresh render take the same road from here: same models, same budget, same
     storage, same charge. Internally an edit IS a re-render, so it is no faster and belongs on
     this side of the clock rather than inside an edge function's stopwatch. */
  const isEdit = job.kind === "edit";

  /* NANO BANANA FIRST when it is the chosen engine, gpt-image behind it. Whichever runs, the
     result is stored and charged identically, so switching engines is a one-variable decision
     and not a code change. */
  if ((job.engine || "gemini") === "gemini" && GEMINI_API_KEY) {
    for (const gm of GEMINI_IMAGE_MODELS) {
      let out = await renderGemini(gm, job.prompt, isEdit ? job.src : null, job.aspect, true);
      // The structured aspect field was refused — same model, same rung, just without it.
      if (out.reason === "config") out = await renderGemini(gm, job.prompt, isEdit ? job.src : null, job.aspect, false);
      if (out.b64) {
        try { await dbPut(`imgEdits/${userId}/${jobId}`, { b64: out.b64, mime: out.mime }, token); }
        catch (e) { await save({ phase: "fail", error: "could not store the picture: " + ((e && e.message) || e) }); return new Response("ok"); }
        if (isEdit) job.src = null;
        await save({
          phase: "done", key: jobId, engine: "gemini", model: gm, quality: "n/a",
          kind: job.kind || "image", ms: Date.now() - started,
          bytes: Math.round(out.b64.length * 0.75),
        });
        return new Response("ok");
      }
      last = out;
      if (out.reason !== "model") break;   // only a bad NAME is worth the next rung
    }
    // Gemini could not do it — fall through to gpt-image rather than failing the job.
  }

  /* Past this line the pictures cost real money, so the ceiling is checked HERE — the only
     point at which anything is actually about to be spent. */
  const jobCost = openaiImageCost(job.size || "1024x1024", job.quality || "high");
  if (!OPENAI_API_KEY || (await openaiSpentUsd(token)) + jobCost > OPENAI_IMAGE_BUDGET_USD) {
    await save({
      phase: "fail",
      error: (last && last.error) || "the image engine could not produce this picture",
    });
    return new Response("ok");
  }

  for (const model of models) {
    const out = isEdit
      ? await renderEdit(model, job.prompt, job.src, job.quality || "high")
      : await render(model, job.prompt, job.size || "1024x1024", job.quality || "high");
    if (out.b64) {
      /* The picture is stored where the edge already serves finished images from, so the browser
         asks for it with the same /api/image?key= it uses for an edit. */
      try { await dbPut(`imgEdits/${userId}/${jobId}`, { b64: out.b64, mime: out.mime }, token); }
      catch (e) { await save({ phase: "fail", error: "could not store the picture: " + ((e && e.message) || e) }); return new Response("ok"); }
      /* The source picture has done its work and is megabytes wide — drop it rather than
         leaving a copy of every edited photo sitting in the job record forever. */
      if (isEdit) job.src = null;
      /* CHARGE THE LEDGER. Nothing on this path did, which meant every picture the background
         runner made on gpt-image was free as far as spend/openaiImageUsd was concerned — the
         balance could drain to nothing while the guard above still read zero spent and happily
         approved the next one. Charged after the picture is safely stored, so a storage failure
         is never billed to a user who did not get a picture. */
      await openaiChargeUsd(token, jobCost);
      await save({
        phase: "done", key: jobId, engine: "openai", model, quality: job.quality || "high",
        kind: job.kind || "image", usd: jobCost,
        ms: Date.now() - started, bytes: Math.round(out.b64.length * 0.75),
      });
      return new Response("ok");
    }
    last = out;
    // Only an unusable model name is worth trying the next rung for.
    if (out.reason !== "model") break;
  }

  if (isEdit) job.src = null;
  await save({
    phase: "fail",
    error: (last && (last.detail || last.reason)) || "no image",
    reason: (last && last.reason) || "unknown",
    ms: Date.now() - started,
  });
  return new Response("ok");
};
