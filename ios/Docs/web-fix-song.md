# Why "اصنعلي اغنية" answers with lyrics instead of a song

Scope: the whole client path from the typed message to the audio card, plus the three server
routes behind it. Read-only pass. Line numbers are against
`D:\Programming\Projects\FirasAI\app.js` (5,796,169 bytes, mtime 2026-09-02 15:06) and
`D:\Programming\Projects\FirasAI\server.mjs` (807,839 bytes) — the tree that is deployed.

Two of the five findings below were **confirmed by running the real code**, not by reading it: the
detectors were sliced out of `app.js` verbatim with Python and driven with real Arabic input
(rung 2 of `.claude/skills/defect-triage-honesty`). The reproduction is at the end.

---

## 1. The path, as it actually runs

```
sendMessage                  app.js:~44540
  runAssistant               app.js:44581      → if (chat.agent) runAgentAssistant  ← song never handled there
    streamAnswer             app.js:41528
      classifyTurnIntent     app.js:41569      → _classifyTurn  app.js:4132
        ├─ FAST PATH         app.js:4142       obviousProblemChat → returns {kind:"chat"} with NO model call
        └─ model call        app.js:4172       callAgentText(…, "pro") → KIND=<one of 11 words>
                                               throws → verdict "unavailable"  (app.js:4297)
      wantsSong              app.js:41853      turnKind==="song"  ||  (turnKind==="unavailable" && songAskedPlainly)
        ├─ isGuest()         app.js:41856      → "**الأناشيد للأعضاء**"
        ├─ songIsWrittenOut  app.js:41813      supplied lyrics → pass through untouched
        ├─ else              app.js:41898      lyric author call ("pro"), STYLE: line stripped
        └─ aiMsg.content =   app.js:42033      ```firas-music {prompt,lyrics,seconds,title}```
finalizeAi                   app.js:43160      parseMusicMeta → buildMusicCard  app.js:4592
  start()                    app.js:4693       requestMusicJob  app.js:59154
    POST /api/music/job      server.mjs:4875   handleMusicJobStart
    GET  /api/music/job      server.mjs:4951   handleMusicJobStatus   (poll, 2s→6s, 10 min cap)
    GET  /api/music/file     server.mjs:4969   handleMusicFile        (Range-aware, from our cache)
  musicJobRemember           app.js:59050      localStorage pointer, collected by
  musicJobsReattach          app.js:59083      at boot (app.js:47213) and on return (app.js:50770)
```

The plumbing below `wantsSong` is sound. Everything that goes wrong goes wrong **above** it —
the turn never becomes a song turn — or **after** a `not_configured` refusal, where the words
that were just written are thrown on the floor.

Nothing steals the turn the way the brief suspected:
`isFileStreamReply` (app.js:3120) refuses any content starting `` ```firas- `` at line 3127, so
the document masker cannot eat a music fence; `codeReq` (app.js:41613) is computed but the song
branch at 41853 returns before any code rendering; `detectFileRequest`/`detectImageRequest` are
only consulted on `unavailable`. The guest gate and the quota gate both answer in Arabic and are
not silent.

---

## 2. Finding S1 — the "problems" fast path answers `chat` for song requests, with no model call

`_classifyTurn` app.js:4142:

```js
const obviousProblemChat = !ctx.hasAttachedImage && !ctx.hasPriorImage && ctx.product !== "code" &&
  wantsGeneratedProblems(t) &&
  !/(?:\b(?:pdf|docx|word|document|file|pptx|…|video|image|picture|poster|logo|website|…)\b|ملف|…|فيديو|صورة|بوستر|شعار|موقع|تطبيق|برنامج)/i.test(t);
if (obviousProblemChat) { … return Promise.resolve({ kind: "chat", requirements }); }
```

The exclusion list names **every manufactured deliverable except a song**. There is no
`song|music|أغنية|اغنية|نشيد|أنشودة|لحن|أغاني` in it. And `wantsGeneratedProblems` (app.js:2988-ish,
found by `grep -an "function wantsGeneratedProblems"`) fires on a very wide net that includes
`امتحان`, `اختبار`, `سؤال`, `معادل`, and — in its `HARDER` branch — the bare word **`زدني`**.

Measured (verbatim source, real input):

| message | fast path fires? | result |
|---|---|---|
| `اصنعلي اغنية عن العراق` | no | reaches the model |
| `زدني اغنية ثانية` | **yes** | `kind:"chat"`, **no model call at all** |
| `اصنعلي اغنية عن امتحان البكالوريا` | **yes** | `kind:"chat"`, **no model call at all** |

Both of those are ordinary Iraqi phrasing for the second most common song request there is
("give me another one") and for a student-app song ("a song about the exam"). They are
**deterministic**: the same words produce lyrics-as-text every single time, and no amount of
classifier quality can save them because the classifier is never asked.

`turnKind` then equals `"chat"`, not `"unavailable"`, so the `songAskedPlainly` net at 41854 is
never consulted either. The chat model receives the request, writes lyrics, and the reader sees
exactly what the owner described.

**Fix.** Add song/music to the exclusion alternation in the same line, so a message that mentions
a song can never take the no-model shortcut. Anchor (unique, one occurrence — verified with
`grep -c`):

```
|ملف|بي\s*دي\s*اف|وورد|بوربوينت|عرض\s*تقديمي|اكسل|فيديو|صورة|بوستر|شعار|موقع|تطبيق|برنامج)/i.test(t);
```

Replace with the same string with `song|songs|music|lyrics|nasheed|anthem|jingle` added to the
`\b(?: … )\b` Latin group and `|أغنية|اغنية|أغاني|اغاني|نشيد|أنشودة|انشودة|لحن|تلحين|غنيلي|غني لي`
appended to the Arabic group. This only ever *removes* fast-path hits, so it cannot break a
problem-list turn; the worst case is one extra classifier call on a message that mentions a song.

---

## 3. Finding S2 — the classifier-failed net drops the supplied-lyrics case, which is the case it exists for

`songAskedPlainly` app.js:41833-41841, first executable line:

```js
if (v.length > 1200) return false;                       // a brief that long is a document
```

This net is the **only** thing that routes a song when the classifier's own model call fails —
and `callAgentText` (app.js:38820) throws on an empty stream *and* on the backend's
"all engines busy" notice (`isEngineBusyText`, app.js:38855), so under exactly the load the owner
is complaining about, `_classifyTurn` returns `"unavailable"` for every turn (app.js:4297) and
this net is load-bearing.

Meanwhile the branch below it — `songIsWrittenOut` (app.js:41813) — exists specifically to
recognise **supplied lyrics**, which are long by construction: it wants four or more short lines.
A pasted verse plus "اصنعلي اغنية" is 1,000–3,000 characters as a matter of course.

Measured: `اصنعلي اغنية` + 45 lines of verse = 1,408 characters → `songAskedPlainly` returns
**false**. The one shape the feature advertises most loudly ("handing you finished lyrics and
asking for them to be sung", classifier prompt app.js:4218) is the one shape the fallback refuses.

**Fix.** The length guard is trying to say "a long *prose brief* is a document", which is a
statement about shape, not size. Replace

```js
      if (v.length > 1200) return false;                       // a brief that long is a document
```

with a shape test that lets a lyric sheet through:

```js
      /* LENGTH IS NOT THE QUESTION — SHAPE IS. Supplied lyrics are long by construction (four
         short lines minimum, usually thirty), and they are the single case this net exists for.
         The ask itself always sits in the opening lines, so read those; a genuinely long PROSE
         brief still fails the SING/SONG_NOUN tests below and falls through as before. */
      const head = v.slice(0, 600);
      if (v.length > 1200 && !songIsWrittenOut(v)) return head.length ? (void 0, false) : false;
```

Simpler and safer to patch (one statement, no new control flow, and `songIsWrittenOut` is
declared just above at 41813 as a `const` arrow in the same scope, so it is already in scope):

```js
      if (v.length > 1200 && !songIsWrittenOut(v)) return false;
```

and then run `SING`/`SONG_NOUN`/`MAKE` against `v.slice(0, 600)` instead of `v` so a thirty-line
lyric sheet is judged by its request line, not by a stray word in verse 3.

---

## 4. Finding S3 — a `not_configured` server throws away the lyrics it just paid to write

Order of operations in the song branch:

1. app.js:41870 — loader: "يكتب الكلمات…"
2. app.js:41898 — a full **`"pro"` tier** completion writes the lyrics (tens of seconds).
3. app.js:42033 — the lyrics go into a `` ```firas-music `` fence as the **entire** message body.
4. app.js:4709 → 4693 → 59154 — `requestMusicJob` POSTs `/api/music/job`.
5. server.mjs:4882 — `engineReady` is false → **HTTP 503 `{error:"not_configured"}`**.
6. app.js:4696 — `showFailed("not_configured")` → app.js:4638 → `L.notCfg`.

The reader is left with a card that says **"محرّك الموسيقى غير مهيّأ بعد"** and *nothing else*.
The lyrics are sitting in `meta.lyrics` inside the fence, invisible, because `buildMusicCard` never
renders them and `renderThread` (app.js:23902) hands the whole message to the card. So the honest
description of this state is: the app spent a premium model call writing a song, then showed a
one-line refusal and deleted the work in front of the user.

It also offers **"أعد التلحين"** (app.js:4640, `body.appendChild(againBtn())` is unconditional) —
a button that will fail identically for ever, because the engine is a deployment fact, not a
transient one.

**Fix, three small edits inside `buildMusicCard` (app.js:4592-4711):**

(a) Add two strings to `L` (app.js:4596-4603):

```js
    notCfgBody: ar ? "ما أكدر أغنّيها الآن — محرّك الموسيقى مو مهيّأ على الخادم. هذي كلمات الأغنية:"
                   : "I can't sing it right now — the music engine is not set up on the server. Here are the lyrics:",
```

(b) In `showFailed` (app.js:4629-4641), when `why === "not_configured"` (or `"signin_required"`),
append the lyrics as readable text and **do not** append `againBtn()`:

anchor (unique):
```js
    body.appendChild(p);
    body.appendChild(againBtn());
  };
```
replacement idea:
```js
    body.appendChild(p);
    /* NEVER LOSE THE WORDS. A song that cannot be sung is still a lyric sheet, and it cost a
       premium completion to write. Showing the refusal alone is what made this read as "it
       wrote me lyrics instead of a song" with no lyrics anywhere on screen. */
    if (why === "not_configured" || why === "signin_required") {
      const lead = document.createElement("p");
      lead.className = "music-card__msg";
      lead.textContent = L.notCfgBody;
      const pre = document.createElement("pre");
      pre.className = "music-card__lyrics";
      pre.setAttribute("dir", "auto");
      pre.textContent = String(meta.lyrics || "");
      if (pre.textContent.trim()) { body.appendChild(lead); body.appendChild(pre); }
    }
    /* A refusal that is a DEPLOYMENT FACT does not get a retry button: pressing it fails the
       same way for ever, which teaches the reader the app is broken rather than unconfigured. */
    if (why !== "not_configured" && why !== "signin_required") body.appendChild(againBtn());
  };
```

(c) `styles.css` needs one rule for `.music-card__lyrics` (`white-space: pre-wrap; …`) — a
separate, trivial patch.

---

## 5. Finding S4 — production has no music engine configured, and the config that would arm one is not in the deploy manifest

Server gate, server.mjs:4882:

```js
const engineReady = MUSIC_PROVIDER === "musicapi" ? !!MUSICAPI_KEY : !!REPLICATE_API_TOKEN;
if (!engineReady) return sendJson(res, 503, { error: "not_configured", feature: "music" });
```

`MUSIC_PROVIDER` defaults to `"replicate"` (server.mjs:4487), so the env var that must be set is:

- **`REPLICATE_API_TOKEN`** — under the default provider; or
- **`MUSICAPI_KEY`** *together with* **`MUSIC_PROVIDER=musicapi`** — for the Suno/MusicAPI engine.

(Values are secrets and are not reproduced here.)

What the repo shows, and this is checkable in one command each:

- `fly.toml` `[env]` lists `NODE_ENV, PORT, DATA_DIR, SECURE_COOKIES, OLLAMA_HOST, DURABLE_CHAT`.
  **`MUSIC_PROVIDER` is not there.** It is a non-secret config value, so it belongs in `[env]`,
  and its absence means the deployed process reads the default `"replicate"`.
- `.env.prod` (the production manifest, 24 names) contains
  `BREVO_*, CF_*, FIREBASE_*, GEMINI_*, NVIDIA_API_KEY, OLLAMA_*, OPENAI_API_KEY,
  OPENROUTER_API_KEY, PUTER_AUTH_TOKEN, SESSION_SECRET` and **no `MUSICAPI_KEY`, no
  `REPLICATE_API_TOKEN`, no `MUSIC_PROVIDER`**.
- `DEPLOY-ENV.md` mentions neither "music" nor "replicate" (`grep -i` → 0 hits).
- `.env.example` documents neither `MUSIC_PROVIDER` nor `MUSICAPI_KEY` (`grep` → 0 hits), so
  nobody setting this deployment up from the repo would ever know to set them.
- The local `.env` **does** have all three (provider = `musicapi`), which is why the feature works
  on the developer's machine and can be dead in production without anyone noticing.

There is also a **silent mismatch trap**: if `MUSICAPI_KEY` were set with `fly secrets set` but
`MUSIC_PROVIDER` were not, `engineReady` would test `REPLICATE_API_TOKEN`, find nothing, and refuse
every song — with a perfectly good MusicAPI key sitting one variable away. That is the single most
likely production state given what is in the repo.

And nothing announces it. There is no boot line for music: `grep -a 'console.log("\[firas\]' server.mjs`
shows banners for the database, images, video, search and live voice, but the only music log
(server.mjs:4572) fires *after a successful render*.

**Fix, two parts:**

1. **Diagnosability, server.mjs.** Add a boot line next to the other banners so the deployed state
   is readable from `fly logs`. Anchor after the `MUSIC_LIMIT` declaration (server.mjs:4339) or
   alongside the other startup logs:
   ```js
   console.log("[firas] music: " + (MUSIC_PROVIDER === "musicapi"
     ? ("MusicAPI/" + MUSICAPI_MODEL + (MUSICAPI_KEY ? " armed" : " NO KEY — songs will refuse"))
     : ("Replicate/" + REPLICATE_MUSIC_MODEL.split(":")[0] +
        (REPLICATE_API_TOKEN ? " armed" : " NO TOKEN — songs will refuse"))));
   ```
   Never print the key — presence only.
2. **Config, `fly.toml`.** Put `MUSIC_PROVIDER = "musicapi"` in `[env]` (it is not a secret) and
   set `MUSICAPI_KEY` with `fly secrets set`. Document both in `.env.example` and `DEPLOY-ENV.md`.

Until (2) lands, S3 is what the user experiences, so **S3 should ship first**: a server that
cannot sing must say so in Arabic *and still hand over the words*.

---

## 6. Finding S5 — the card restarts the job on every re-render, and the poll it abandons keeps running

`buildMusicCard` ends (app.js:4709-4710):

```js
  if (meta.key) showReady(meta.key);
  else start(meta, true);
```

`start()` (app.js:4693) calls `requestMusicJob(m.prompt, m.lyrics, m.seconds || 150, null, chatId)`
— note the **`null` signal**: there is no `AbortController`, so the loop at app.js:59186-59199
(2s → 6s backoff, `MUSIC_JOB_MAX_MS` = 10 minutes) runs to completion whether or not its card is
still in the document.

`buildMusicCard` is called from `renderThread` (app.js:23915) and from `finalizeAi` (app.js:43173).
`renderThread` runs on a chat switch, on a reload, and from `musicLandKey` itself (app.js:59139).
Each of those, while the key is still missing, builds a *new* card, fires a *new*
`POST /api/music/job`, and starts a *new* 10-minute poll — and the old one is neither cancelled nor
reachable.

The server dedupes by cache key (`musicJobs.get(ckey)` at server.mjs:4930), so this does not
double-spend. What it does cost:

- **~120 `GET /api/music/job` requests per song per poll loop**, multiplied by however many times
  the thread was re-rendered, against a single 512 MB Fly instance. This is a direct contributor to
  complaint 2 ("بطيء كلش و يعلك مرات").
- The visible spinner **restarts from zero** every time the reader comes back to the chat, so a
  song that is 80 seconds in looks like it just started. That reads as a hang.

Contrast `buildImageCard` (app.js:6192), which points an `<img>` at a URL and never re-runs a job.

**Fix.** Give the card a module-level in-flight registry keyed by the message, the way the durable
job pointers already are, and reuse the running loop instead of starting a second one:

```js
/* ONE LOOP PER SONG. A card is rebuilt by every renderThread, and each rebuild used to start a
   fresh POST plus a fresh ten-minute poll that nothing could cancel — a hundred requests per
   re-render against one 512 MB machine, and a spinner that restarted from zero every time the
   reader came back. */
const _musicInFlight = new Map();   // ckeyish id -> Promise<string|null>
```
keyed on `(chatId + "|" + (msg && msg.cid || "") + "|" + (m.lyrics || m.prompt || "").slice(0, 200))`,
with `start()` awaiting an existing entry when one is present and deleting it in a `finally`.
`msg.cid` is a real field (it is what `retryOf.cid` reads at app.js:44590) — grep it before relying
on it in the patch, because not every assistant message carries one; fall back to
`chat.messages.indexOf(msg)`.

Also worth the same patch: `L.working` says **"يلحّن الأغنية… حوالي دقيقة"** (app.js:4596) while the
request asks for `seconds: 150` (app.js:42034) and the MusicAPI poller waits up to
`MUSICAPI_MAX_WAIT_MS` = 420,000 ms (server.mjs:4491) at 15-second intervals. "About a minute" for
something that routinely takes three to seven is how a working feature gets reported as frozen.
Say **"يلحّن الأغنية… قد يستغرق بضع دقائق"**.

---

## 7. Two smaller things, named for completeness

- **`TURN_KINDS` (app.js:4102) does not contain `"song"`.** It is a *dead constant* — `grep -an
  "TURN_KINDS"` returns exactly four lines: the declaration and three doc comments that claim the
  classifier "returns one of TURN_KINDS". So this is documentation drift, not a live bug today; but
  the next person who validates a verdict against that array will delete song generation without
  noticing. One-word fix: add `"song"` after `"video"`.
- **A server restart strands a running song.** `musicJobs` is a plain `Map` (server.mjs:4869) with
  no persistence, and `handleMusicJobStatus` answers an unknown id with `{phase:"running"}`
  (server.mjs:4960). After a `fly deploy` mid-render, the client polls a job that no longer exists
  for the full ten minutes and then shows "ما ضبط التلحين". The cache-first check on the line above
  saves only the case where the audio finished before the restart. Cheapest correct fix: have the
  status route answer `{phase:"unknown"}` for an id that is neither cached nor in the map, and have
  `requestMusicJob` re-POST once on `unknown` — the POST is idempotent because `ckey` is derived
  from the words (server.mjs:4402).
- `netlify/edge-functions/api.js` has **zero** `/api/music` routes (`grep -c` → 0). That is fine
  while the site runs on Fly, but the mirror would 404 the feature entirely if it were ever used.

---

## 8. How the two confirmed findings were reproduced

Both detectors were sliced out of `app.js` verbatim (no retyping — the regexes carry Arabic and
retyping them is exactly how this repo loses characters) and driven with real input:

```bash
cd /d/Programming/Projects/FirasAI
python - "$SCRATCH/song_unit3.mjs" <<'PY'
import io,sys,json
L=io.open('app.js',encoding='utf-8').read().split('\n')
song='\n'.join(L[41832:41841])                                    # const songAskedPlainly = …
i=next(n for n,l in enumerate(L) if l.startswith('function wantsGeneratedProblems'))
wgp='\n'.join(L[i:i+7])
j=next(n for n,l in enumerate(L) if 'const obviousProblemChat' in l)
raw=L[j+2].strip(); rx=raw[1:raw.rindex('.test(t)')]              # the exclusion regex, verbatim
… writes song + wgp + 'const EXCL = '+rx+';' + a table-printing harness …
PY
node "$SCRATCH/song_unit3.mjs"
```

Output:

```
short ask                len=22     songAskedPlainly=true   obviousProblemChatFastPath=false
ask + pasted lyrics      len=1408   songAskedPlainly=false  obviousProblemChatFastPath=false
one more song            len=16     songAskedPlainly=false  obviousProblemChatFastPath=true
song about the exam      len=33     songAskedPlainly=true   obviousProblemChatFastPath=true
sing these words         len=14     songAskedPlainly=true   obviousProblemChatFastPath=false
```

- row 2 is finding **S2** (`اصنعلي اغنية` + 45 lines of verse);
- rows 3 and 4 are finding **S1** (`زدني اغنية ثانية`, `اصنعلي اغنية عن امتحان البكالوريا`).

What is **not** confirmed: whether the live classifier answers `chat` for a plain short song ask
(row 1 reaches the model, and I cannot run the model from here), and whether the deployed Fly
process actually has a music key — `fly secrets` cannot be read. S4 rests on the repo's own
production manifest and deploy docs, which is strong circumstantial evidence and not proof. The
right first command after this handoff is:

```bash
fly logs -a firasai-web --no-tail | findstr /C:"[firas] music:"
```

which will print nothing until the boot banner from §5 is added — which is the point of adding it.

---

## 9. Recommended order

1. **S3** (client tells the truth and keeps the lyrics) — smallest patch, removes the worst
   symptom immediately, and is correct whether or not the engine ever gets configured.
2. **S1** (song words in the fast-path exclusion list) — one regex, deterministic bug, deterministic fix.
3. **S4** (`MUSIC_PROVIDER` into `fly.toml [env]`, key into `fly secrets`, boot banner) — turns the
   feature on.
4. **S2** (length guard → shape guard) — matters most while the engines are saturated.
5. **S5** (one loop per song, honest duration copy) — spills into the general slowness complaints.

Every one of these is a separate patch script. They touch four different regions of `app.js`
(4142, 4596-4641, 41835, 4709) plus `server.mjs` and `fly.toml`, so they do not drift each other's
anchors — but apply them one at a time through the harness anyway, per `AGENTS.md`.
