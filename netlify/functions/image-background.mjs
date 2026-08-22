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

/** One OpenAI attempt, with the long budget. Returns { b64, mime } or { reason, detail }. */
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
    const text = await r.text();
    if (!r.ok) {
      let msg = text.slice(0, 300);
      try { msg = (JSON.parse(text).error || {}).message || msg; } catch { /* keep the raw text */ }
      const modelFault = (r.status === 400 || r.status === 404) && /model/i.test(msg);
      return { reason: modelFault ? "model" : "http", status: r.status, detail: msg };
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
  if (!OPENAI_API_KEY) return new Response("no key", { status: 500 });

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

  const models = String(job.models || "gpt-image-2,gpt-image-1").split(",").map((m) => m.trim()).filter(Boolean);
  const started = Date.now();
  let last = null;

  for (const model of models) {
    const out = await render(model, job.prompt, job.size || "1024x1024", job.quality || "medium");
    if (out.b64) {
      /* The picture is stored where the edge already serves finished images from, so the browser
         asks for it with the same /api/image?key= it uses for an edit. */
      try { await dbPut(`imgEdits/${userId}/${jobId}`, { b64: out.b64, mime: out.mime }, token); }
      catch (e) { await save({ phase: "fail", error: "could not store the picture: " + ((e && e.message) || e) }); return new Response("ok"); }
      await save({
        phase: "done", key: jobId, model, quality: job.quality || "medium",
        ms: Date.now() - started, bytes: Math.round(out.b64.length * 0.75),
      });
      return new Response("ok");
    }
    last = out;
    // Only an unusable model name is worth trying the next rung for.
    if (out.reason !== "model") break;
  }

  await save({
    phase: "fail",
    error: (last && (last.detail || last.reason)) || "no image",
    reason: (last && last.reason) || "unknown",
    ms: Date.now() - started,
  });
  return new Response("ok");
};
