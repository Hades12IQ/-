# Web client — Media creation UX (image / image-edit / video / music) and the gallery

Native spec for a **Media Studio** plus **in-chat creation**, derived from the deployed web client
(`app.js`) and the deployed server (`server.mjs`). Every field name, limit, status code, error code and
Arabic string below was read from the code; line numbers are `file:line` in the worktree at
`D:\Programming\Projects\FirasAI\.claude\worktrees\firasai-ios-app-development-64ca7e`.

Companion playbooks read for this slice: `.claude/skills/background-jobs-browser/SKILL.md`,
`.claude/skills/image-generation-prompting/SKILL.md`. Commit `4b0ed4a` ("An attached photo becomes the
first frame, and the message never carries it") is the source of the image-to-video design.
The server side of the same routes is documented independently in `ios/Docs/server-media.md`; this file was
re-verified line by line against `app.js` / `server.mjs` on 2026-09-02, and §5.3 (the video 413 is dead code) and
§6.6 (the music engine wait is 180 s) agree with that report. §14 maps everything here onto the Swift code that
already exists under `ios/FirasAI`.

---

## 0. One-page summary

| Kind | How the user asks (web) | Client entry | Server route | Result stored in the assistant message as | Card |
| --- | --- | --- | --- | --- | --- |
| Image | Natural language only (`turnKind === "image"`) | `streamAnswer` image branch `app.js:42170-42280` | `POST /api/image/job` → poll `GET /api/image/job?id=` → bytes at `GET /api/image?key=` | ```` ```firas-image {"prompt","key"} ``` ```` | `buildImageCard` `app.js:6192` |
| Image edit | Natural language with a picture "in play" (`turnKind === "edit-image"`) | edit branch `app.js:41716-41770` | `POST /api/image/job` (501 on server.mjs) → `POST /api/image/edit` | ```` ```firas-image {"prompt","key"} ``` ```` | same card |
| Video | Natural language (`turnKind === "video"`), optional attached photo = first frame | video branch `app.js:42033-42160` | `GET /api/video/quota`, `POST /api/video/job`, `GET /api/video/job?id=`, `GET /api/video/file?id=` | ```` ```firas-video {"prompt","seconds","seed","jobId"?,"key"?} ``` ```` | `buildVideoCard` `app.js:4715` |
| Song | Natural language (`turnKind === "song"`) | song branch `app.js:41846-42032` | `POST /api/music/job`, `GET /api/music/job?id=`, `GET /api/music/file?id=` | ```` ```firas-music {"prompt","lyrics","seconds":150,"title","key"?,"nonce"?} ``` ```` | `buildMusicCard` `app.js:4592` |
| Gallery | Topbar button `#galleryBtn` (hidden until the open chat has ≥1 image fence) | `openImageGallery` `app.js:5903` | none (reads message fences) | — | overlay grid |

Facts that shape the whole native design:

1. **There is no media UI in the composer.** The tools menu (`index.html:759-779`) has exactly three entries — web search (`بحث الويب`), thinking (`التفكير`), dictation language (`لغة الإملاء`). The slash menu (`app.js:1032-1046`) has summarise / translate / explain / review. No aspect-ratio picker, no style presets, no "how many" control, no explicit "make an image" tool. Everything is decided by a model classifier reading the message. The only hint copy is the landing text `app.js:744`: «جرّبها بكتابة «اصنع لي صورة…» داخل المحادثة».
2. **Guests cannot create any media.** Every branch returns an upsell answer + opens the sign-up card; the server independently returns `403 {error:"signin_required", feature:"image"|"video"|"music"}` to the guest cookie.
3. **A conversation never carries media bytes.** Each assistant turn stores a small JSON fence; the card re-derives the URL from it. Attached photos live only in memory (`msg.images`, raw base64) and are persisted as 256-px thumbnails (`msg.imageThumbs`).
4. **Every render is a server job that outlives the client.** The job id **is** the cache key; status is `running | done | fail`; a finished result is found by key even after a server restart. The client keeps one small pointer table per kind in localStorage and reattaches on return.
5. **Always exactly one output per request.** No batch/count option exists anywhere.

---

## 1. Turn routing — how a message becomes an image / edit / video / song

### 1.1 The one authority: `_classifyTurn` (`app.js:4130-4308`)

Runs once per user turn in `streamAnswer` (`app.js:41561-41573`) **before** any other router:

```js
const turnKind = await classifyTurnIntent(lastUserTurn.content, {
  hasAttachedImage: !!(lastUserTurn.images && lastUserTurn.images.length),
  hasPriorImage: !!lastGeneratedImageMeta(chat),
  product: state.product,
}, signal);
if (turnKind !== "unavailable") lastUserTurn.intent = turnKind;   // stored on the user message
```

- Returns one of `chat, image, edit-image, video, song, pdf, docx, pptx, xlsx, csv, code`, or
  `"unavailable"` when the model call failed. (`TURN_KINDS` at `app.js:4102` omits `song`, but the
  parser at `app.js:4239-4245` accepts it — treat `song` as a real kind.)
- Model tier: `"pro"` via `callAgentText(messages, "pro", signal)` (`app.js:4250`). Message text is
  sent sliced to 6000 chars; cache key = `(A?)(P?)(product)|text.slice(0,6000)` (`app.js:4155-4157`).
- Fast path (`app.js:4141-4152`): no attachment, no prior image, product ≠ code, `wantsGeneratedProblems(t)`
  and the text contains none of `pdf|docx|word|document|file|pptx|powerpoint|slides?|xlsx|spreadsheet|csv|video|image|picture|poster|logo|website|web app|application|program|script|ملف|بي دي اف|وورد|بوربوينت|عرض تقديمي|اكسل|فيديو|صورة|بوستر|شعار|موقع|تطبيق|برنامج` → `chat` without a call.
- Situation line prepended to the user content (`app.js:4160-4166`): `"The user HAS ATTACHED a picture to this message."` / `"The previous assistant turn produced a picture, which is on screen."` / `"There is no picture in play."` then `"The user is inside a CODE EDITOR that builds websites and web apps."` or `"The user is in an ordinary chat."`, then `"\nMESSAGE:\n" + text`.
- Reply is parsed from its own `KIND=` line; exact match first, then substring, longest-first order
  `edit-image, image, video, song, pptx, xlsx, docx, csv, pdf, code, chat` (`app.js:4239-4245`).
- **Downgrade:** `edit-image` with neither an attached nor a prior image becomes `image` (`app.js:4246`).
- The second line `REQUIREMENTS=` is stored as `lastUserTurn.requirements` (≤700 chars) — not used by media.

**The classifier system prompt, verbatim (decoded from the JS escapes; `app.js:4175-4266`):**

```
Read one message and answer TWO questions about it. Reply with exactly two lines and nothing else:
KIND=<one word>
REQUIREMENTS=<one line, or NONE>

QUESTION 1 - KIND. What should PRODUCE the answer? One word from this list:
chat, image, edit-image, video, song, pdf, docx, pptx, xlsx, csv, code

THE LANGUAGE IS IRRELEVANT TO THE ANSWER. The same request must get the same KIND whether it is written in Arabic, in Iraqi or Gulf dialect, in English, or in the mixture of Arabic and English people actually type. You are not judging how it is written. Never answer chat merely because a message is phrased casually or in dialect.

ANSWER KIND FIRST, before you think about REQUIREMENTS at all. A model that drafts a paragraph about requirements and then labels it has already talked itself into a category.

DECIDE FROM THE REQUEST, NOT FROM WORDS THAT APPEAR IN IT. A message can mention a picture, a file or a website while asking for something else entirely. If someone writes a long text and asks you to translate it, that is chat - even if the text they pasted is about photography, even if it contains the words image or صورة. Ask yourself only: when I finish, what does the user expect to be holding?

chat        an answer, an explanation, a translation, a rewrite, a summary, code shown inline to read, questions or problems answered in the conversation. This is the default and by far the most common. Choose it whenever nothing is being MANUFACTURED.
image       they want a picture generated: a logo, a poster, an illustration, artwork.
edit-image  a picture is in play and they want THAT picture changed. Recoloured; something added or removed; the background replaced; the text in it altered; and ALSO any change to its SHAPE OR FRAMING - made into a banner, made wide or tall or square, cropped, zoomed, resized, rotated, turned into a cover or a thumbnail. Changing the shape of the picture on screen is an EDIT, not a new picture: the subject must survive it.
            WHEN A PICTURE IS IN PLAY, THIS IS THE DEFAULT. Choose image over edit-image only when they are plainly asking for a DIFFERENT picture - a new subject, another one, something unrelated to what is on screen. If they say "make it...", "turn it into...", "سويها...", "خليها...", "غير..." - the word IT is the picture on screen, and that is an edit. Only ever valid when a picture is attached or on screen.
video       A VIDEO IS SOMETHING THEY WILL WATCH. They want a moving clip made: a short scene, an animation, a clip about a place or an idea, an advert, an explainer.
            THE BOUNDARY. It is video when what they end up with MOVES. It is chat when they are asking ABOUT a video — what one means, which is best, summarising or translating one. It is pptx when they want SLIDES, even if they call it a presentation or an عرض. It is code when they want a website or app that PLAYS videos. It is image when they want one still picture, however cinematic they make it sound.
            A picture in play does NOT make it edit-image: turning an attached photo into a moving clip is video, because the picture is the input and the clip is the deliverable.
song        A SONG IS AUDIO SOMEONE WILL PLAY. They want music with singing made: a song, a nasheed, an anthem, a rap, a lullaby, a jingle - any genre and any mood. All THREE of these are song: handing you finished lyrics and asking for them to be sung; giving you a line or a few words to build a song around; and describing a song for you to write from scratch.
            THE BOUNDARY, because this is where it goes wrong. It is a SONG when the thing they will end up with is something they can listen to. It is CHAT when the thing they will end up with is words on the screen: asking what a song means, who sang it, what its story is, to translate it, to explain it, to correct its grammar, or to write a POEM (a poem is read, a song is heard - unless they also ask for it to be sung or set to music). 'Write me lyrics' with no music asked for is chat; 'write me a song' is song.
            A request to sing about a PERSON, a team, a city, a brand or an event is a song like any other - the subject does not make it something else, and searching the web about that subject is not what they asked for.
pdf / docx / pptx / xlsx / csv  they want a FILE of that kind produced and handed over - a document to read, a report, a deck of slides, a spreadsheet. The giveaway is that the deliverable is a file they will download, not an answer they will read here. Pick the exact format they named; if they clearly want a document but name none, answer pdf.
code        they want software built or changed: a website, a web app, a page, a game, a component, a script. A website ABOUT documents is still code. A page that GENERATES pdfs is still code.

WORKED EXAMPLES. These are real messages this app got wrong. Study where the line falls:
  غنيلي اغنية حماسية عن هالة السلطان  -> song. It was answered as chat WITH A WEB SEARCH about the person. Singing about someone is a song; who they are is not the task.
  اريدها كأغنية  -> song. A short follow-up is still a request; it does not become chat for being brief or for lacking a verb.
  غنيلي شنو معناها  -> chat. Same opening word, and a question about meaning.
  make me 10 hard JEE integrals  -> chat. Problems answered in the conversation are chat, however hard or however many; nothing is being manufactured.
  اعمل لي موقع يعرض الاغاني  -> code. A website ABOUT songs is software.
  حط الكلمات هذي بلحن  -> song. He supplied the words; setting them to music is the task.
  اكتب لي قصيدة عن الوطن  -> chat. A poem is read. Only add music when they ask for it.
  سويلي فيديو قصير عن بغداد  -> video.
  شنو أفضل فيديو عن بغداد  -> chat. Same noun, and a question about videos rather than a request for one.
  حوّل هالصورة لفيديو  -> video, not edit-image. The picture is the input; the clip is what they are asking for.
  اعمل لي عرض عن الثورة الصناعية  -> pptx. عرض means slides here, not a moving picture.
  لخص لي هالفيديو  -> chat. The deliverable is words about a video, not a video.
  لخص لي هالملف بورد  -> docx. The deliverable is a file they download.

QUESTION 2 - REQUIREMENTS. List the conditions THE USER THEMSELVES set, as one short line of semicolon-separated items, in the language they wrote in. Include only things that are CHECKABLE against a finished result: an exact count ("exactly 20 problems"), a required title or heading, a required language, a required structure or sections, a difficulty or audience level, a required format, and anything they FORBADE ("no repetition", "do not use library X", "no introductions").

Copy their conditions; never invent, soften or add your own. A vague wish such as "make it nice" is not a requirement. If they set no checkable conditions, answer NONE.

Any language, any dialect, any length. Two lines only.
```

### 1.2 Branch order inside `streamAnswer` (the native router must keep this order)

1. Explicit page-count guard for pdf/docx (`app.js:41686-41697`) — not media.
2. **Edit image** (`app.js:41716-41770`): requires `(attached image || lastGeneratedImageMeta(chat)) && !fileFmt && !codeReq && (mode !== "plan" || planExecuting) && turnKind === "edit-image"`.
3. **Song** (`app.js:41846-42032`): `turnKind === "song" || (turnKind === "unavailable" && songAskedPlainly(text))`.
4. **Video** (`app.js:42033-42160`): `turnKind === "video" || (turnKind === "unavailable" && mediaIntent === "video")`.
5. **Image** (`app.js:42170-42280`): `turnKind === "image" || (turnKind === "unavailable" && detectImageRequest(text))`, and additionally `!imgHasAttachments && (mode !== "plan" || planExecuting) && !fileFmt && !codeReq`. **A message that carries an attached photo never generates a fresh image** (it is vision or edit).
6. Files, code, chat.

`kindBlocksCode` (`app.js:41603-41604`): a turn classified image / video / edit-image / document can never open the code window.

### 1.3 Fallback patterns — used **only** when `turnKind === "unavailable"`

- `classifyMediaIntent(text)` (`app.js:4327-4362`): returns `"video" | "image" | "none"`. Vetoes: product Agent → none; text > 600 chars → none; `MATH_FIGURE_RE` → none; `MEDIA_MAYBE` must match; then a `"mini"` model call with system prompt:
  ```
  Decide what the user wants CREATED. Answer with exactly one word: video, image, or none.
  video — they want a moving clip/animation generated (any phrasing: 'make a video', 'animate this', 'خلي الصورة تتحرك', 'أبي مشهد متحرك', 'حرّكلي المشهد', 'طلعلي ٦ ثواني').
  image — they want a still picture/logo/poster/illustration generated.
  none — anything else. In particular answer none when they ask ABOUT an existing video or image (explain it, summarise it, transcribe it), when they want a chart/graph/equation plot, when they want code or a document, or when they are just talking.
  Reply with the single word only.
  ```
- `MEDIA_MAYBE` (`app.js:4058-4066`), a deliberately wide gate:
  ```
  (اصنع|اعمل|سوّ?ي|ولّ?د|ولد|صم[مّ]|اعطني|اعطيني|عطني|ابي|أبي|اريد|أريد|بدي|عايز|عاوز|ودي|محتاج|جهّ?ز|طلّ?ع|هات|جيب|ارسم|حرّ?ك|خلي|خلّي|\b(?:make|create|generate|render|animate|produce|draw|design|give\s*me|i\s*want|can\s*you)\b)
  |(فيديو|فديو|مقطع|كليب|انيميشن|أنيميشن|رسوم|متحرك|صورة|صوره|مشهد|لقطة|\b(?:video|clip|animation|animate|movie|reel|footage|scene|shot|image|picture|photo)\b)     // flag i
  ```
- `MATH_FIGURE_RE` (`app.js:4070`) — a maths figure is **never** media (it is a native plot):
  ```
  /y\s*=|f\s*\(\s*x\s*\)|رسم\s*بياني|الكراف|الغراف|\bgraph\b|\bplot\b|دال[ةه]|منحن[يى]|\bfunction\b|معادلة|\b(?:sin|cos|tan|cot|sec|csc|exp|log|ln|lg|sqrt|cbrt|arctan|arcsin|arccos|sinh|cosh|tanh)\s*\(|مثلث|\bمربع\b|مستطيل|\bدائرة\b|قطع\s*مكافئ|\bparabola\b|متجه|\bvector\b|إحداثي|احداثي/i
  ```
- `detectImageRequest(text)` (`app.js:4960-4975`): false for Agent product; false if `MATH_FIGURE_RE`-equivalent matches; false if the text ends in `?`/`؟` and has none of `اصنع|ارسم|ولّد|ولد|generate|draw|create|make`; otherwise true when any of these match:
  ```
  ar     = /(اصنع|اعمل|سوّ?ي?(?:لي)?|ارسم|إرسم|ولّ?د|صم[مّ]|اعطني|اعطيني|عطني|اريد|بدي)\s*[^؟?]{0,24}?(صورة|صوره|رسمة|رسمه|لوحة|بوستر|تصميم|خلفية|لوغو|شعار|بورتريه)/i
  arDraw = /(^|\s)(ارسم|إرسم)(\s|$)/i
  en     = /\b(generate|create|make|draw|paint|design|render)\b[^.?!\n]{0,48}?\b(image|picture|photo|drawing|illustration|artwork|logo|logotype|poster|wallpaper|background|portrait|banner|icon|avatar|emblem|mockup|sticker|thumbnail)\b/i
  ```
- `songAskedPlainly(text)` (`app.js:41820-41830`): false when text > 1200 chars; true if `SING` matches; else `SONG_NOUN && MAKE`:
  ```
  SING      = /(غنّ?ي\s*لي|غنيلي|غنّ?ِ?ي\s|لحّ?ن|نشيد|أنشودة|انشودة|\bsing\b|\bnasheed\b)/i
  SONG_NOUN = /(أغنية|اغنية|أغاني|اغاني|\bsong\b|\bsongs\b)/i
  MAKE      = /(اعمل|أعمل|اصنع|أصنع|سوّ?ي|ألّ?ف|الف\s|اكتب\s*لي|اكتبلي|ولّ?د|عطني|أعطني|خلّ?ي|\bmake\b|\bwrite\b|\bcreate\b|\bgenerate\b|\bturn .* into\b)/i
  ```
- `detectImageEditRequest(text)` (`app.js:4825-4831`) — a *fast path* consulted by `classifyAttachedImageIntent` (`app.js:4850-4878`; `"edit" | "ask"`, mini tier). Note: in the current send path the **turn classifier** decides edit-image; these two are legacy helpers still present. Patterns:
  ```
  ar = /عدّل|عدل|غيّر|غير|بدّل|بدل|حوّل|حول|اجعل|خلّي|خلي|اضف|أضف|ضيف|احذف|امسح|شيل|أزل|ازل|لوّن|لون|اقصص|قصّ|كبّر|صغّر|دوّر|اقلب|نظّف|حسّن|طوّر|استبدل|ابدل|اضبط|صحّح|رتّب|زيّن|موّه|فتّح|غمّق/
  en = /\b(?:edit|change|modify|alter|make (?:it|the|this)|turn (?:it|the|this)|add|remove|delete|erase|replace|swap|recolou?r|colou?r|crop|rotate|flip|resize|upscale|enhance|retouch|fix|clean up|blur|brighten|darken|convert)\b/i
  ```
  (No `\b` around Arabic — JavaScript `\b` is ASCII-only; the comment at `app.js:4818-4824` explains the bug that caused.)

### 1.4 "A picture in play"

`lastGeneratedImageMeta(chat)` (`app.js:5122-5140`): walks back over at most **4 assistant turns** and returns the first ```` ```firas-image ```` meta found (video and music fences do not count). This is what makes «اجعل السماء بنفسجية» right after a generation an edit rather than a new picture.

For attachments: `refersToPriorImage(text)` (`app.js:35905-35909`) silently re-attaches the chat's last attached image (in-memory `lastImagesByChat`) to a follow-up that mentions
`الصور|صورة|الملف|المرفق|المرفقة|منها|فيها|الأسئلة|نفس(ها)?|بنفس|image|file|attachment|extract|estract|the questions|them|it` or passes `isImageTransformRequest`. So "edit it" two turns after attaching a photo still has the photo as source.

---

## 2. Auth model (both cookies) and guest gates

- Member session cookie `firas_session` (`server.mjs:1046`, `currentUser` `server.mjs:1098`). Guest cookie `firas_guest` (`server.mjs:1131`, `currentGuest` `server.mjs:1156`, id prefix `g_`).
- Every media **creation** route requires a member; a guest gets `403` JSON `{error:"signin_required", feature:"image"|"video"|"music"}`; no cookie at all gets `401` (body is the plain text `auth required` on most routes; `/api/image/quota` returns JSON `{ok:false,error:"auth required"}`).
- **Serving finished bytes:** `/api/video/file` and `/api/music/file` accept member **or** guest cookie (`server.mjs:4839-4842`, `4969-4972`); `/api/image?key=` requires a member (guest → 403 JSON) (`server.mjs:5210-5220`).
- Client-side guest gate (defence in depth). Each branch writes a markdown answer into the assistant turn and opens the sign-up card 250 ms later via `openSignUpPrompt("image")` (`app.js:47087`):

| Branch | Assistant text (ar) | (en) |
| --- | --- | --- |
| image (`app.js:42177-42185`), edit (`41737-41745`) | `**توليد الصور يحتاج حسابًا**\n\nأنشئ حسابًا مجانيًا خلال ثوانٍ لتوليد الصور، وحفظ محادثاتك، ورفع حدّك اليومي.` (`guestImageTitle`/`guestImageBody`, `app.js:695-696`) | `**Image generation needs an account**\n\nCreate a free account in seconds to generate images, save your chats, and raise your daily limit.` (`app.js:1792-1793`) |
| song (`app.js:41850-41856`) | `**الأناشيد للأعضاء**\n\nأنشئ حسابًا مجانيًا حتى تصنع نشيدًا.` | `**Songs are for members**\n\nCreate a free account to make one.` |
| video (`app.js:42035-42043`) | `**توليد الفيديو للأعضاء**\n\nأنشئ حسابًا مجانيًا لتوليد مقاطع فيديو.` | `**Video generation is for members**\n\nCreate a free account to generate video clips.` |

Sign-up card copy (`app.js:695-699, 715 / 1792-1796, 1808`): title `توليد الصور يحتاج حسابًا` (image) or `هذه الميزة تحتاج حسابًا` (other), body as above / `أنشئ حسابًا مجانيًا لتفعيلها — يستغرق أقل من دقيقة.`, CTA `إنشاء حساب مجاني` / `Create a free account`, dismiss `لاحقًا` / `Later`.

---

## 3. Image generation

### 3.1 Client flow (`app.js:42170-42280`)

1. Guest gate (§2).
2. **Pre-check** `fetchImageQuota()` (`app.js:6390-6410`): `POST /api/image/quota` with body `{}`.
   - 429 → `{ok:false, reason:"limit", limit, remaining:0, ...}`; 401 → `{ok:false, reason:"auth"}`; 403 with `error:"signin_required"` → `reason:"signup"`; any other non-2xx or network error → `null` (**fail open**).
   - If `quota.ok === false` the turn ends with `imageLimitText(lang, quota)` (§3.7) and nothing is rendered.
3. Loader: `setTurnLoader(md, buildImageLoadingHtml(lang))` — the dot-field plate (§3.5).
4. **Prompt rewrite** (`app.js:42200-42208`): `prompt = userText.slice(0,1000)`, then `callAgentText([...], "pro", signal)`; on success `prompt = enhanced.trim()` with leading/trailing quotes/backticks stripped, whitespace collapsed, `.slice(0,1000)`. The system prompt, verbatim:
   ```
   Turn the user's request into ONE rich, vivid ENGLISH image-generation prompt that yields a HIGH-QUALITY, professional result. Keep the user's subject and intent, then add concrete visual detail: composition, setting, lighting, mood, colors, and camera/style cues. If the user wants a realistic photo, add photoreal cues (e.g. "photorealistic, ultra-detailed, sharp focus, natural lighting, shot on 50mm, high resolution"); if they want art/illustration/3D/anime, add the matching style cues instead. Do NOT contradict the requested style. Output ONLY the final prompt text — no quotes, no explanation, no preamble.
   ```
   User message = the raw user text. If Stop is pressed during the rewrite the empty assistant turn is removed (`dropEmptyAiTurn`) and nothing is charged.
5. **Shape** `pickImageShape(rawUserText)` (`app.js:5100-5115`) — reads the **raw Arabic**, not the rewrite; square is tested first:
   ```
   square = /لوغو|لوقو|شعار|أيقونة|ايقونة|رمز|ستيكر|ملصق دائري|أفاتار|افاتار|بروفايل بيك|ختم|\b(?:logo|icon|avatar|emblem|badge|sticker|monogram|favicon|profile pic)\b/i  → {w:1024,h:1024}
   tall   = /بوستر|ملصق|ستوري|قصة|بورتريه|بروفايل|جوال|موبايل|كتاب|غلاف كتاب|\b(?:poster|story|portrait|vertical|phone|mobile|book cover|flyer|reel|tiktok)\b/i → {w:1024,h:1536}
   wide   = /لافتة|لافته|بانر|غلاف|كفر|خلفية|خلفيه|ويلبيبر|مشهد|منظر|بانوراما|شريط علوي|هيدر|واجهة|واجهه|\b(?:banner|cover|header|hero|wallpaper|background|landscape|panorama|scene|thumbnail|widescreen)\b/i → {w:1536,h:1024}
   default → {w:1024,h:1024}
   ```
   The `aspect` labels in that function (`"3:4"`, `"4:3"`) are mislabeled (1536/1024 = 3:2) and unused. The server clamps to 1280 and Replicate snaps to the nearest ratio, so a "wide" request becomes 1280×1024 → `5:4` (image-generation-prompting §4).
6. `aiMsg.cid = uid()` if absent, then `requestImageJob(prompt, w, h, signal, null, {chatId, sid: chat.serverId, cid})` (§3.2).
7. On `null` key: if `_lastImageJobError` ∈ {`daily_limit`, `rate_limited`, `signin_required`} the turn becomes a text answer (§3.7). **Any other failure or an unconfigured job route falls back to the synchronous URL**: the fence is written as `{prompt, w, h, seed, cid}` and the card loads `/api/image?prompt=…&w=…&h=…&seed=…&cid=…` (§3.3), which renders inline on the request (can take minutes).
8. Success: `aiMsg.content = "```firas-image\n" + JSON.stringify({prompt, key}) + "\n```"`, `finalizeAi`.
9. Remaining-count toast fires **only when the `<img>` actually loads** (`app.js:42269-42277`): `imageRemainingText` → `تم إنشاء الصورة • تبقّى لك ٤ من ٨ اليوم` / `Image created • 4 of 8 left today` (Arabic-Indic digits via `arDigits`; remaining = quota.remaining − 1).

### 3.2 `requestImageJob(prompt, w, h, signal, srcB64?, owner?)` (`app.js:5043-5098`)

- `POST /api/image/job`, JSON `{prompt: prompt.slice(0,1000), w, h}` (+ `image: srcB64` when editing), `credentials: same-origin`.
- Non-2xx → `_lastImageJobError = body.error || "http_<status>"`, `_lastImageJobLimit = body.limit` (number) or −1; returns `null`.
- Response `{ok:true, jobId, phase:"queued"|"done", key?}`. If `owner.chatId` is given, the pointer is written **before the first poll**: `imgJobRemember(chatId, jobId, cid, prompt, sid)` (§8).
- `phase:"done"` → return `key` immediately (cache hit).
- Poll `GET /api/image/job?id=<jobId>` starting at 1.5 s, ×1.25 backoff, ceiling 5 s, deadline 12 min. `phase:"done"` → return key and forget pointer; `phase:"fail"` → `_lastImageJobError = error || reason || "render_failed"`, forget pointer, return null. Network errors on a poll are ignored. Abort stops the poll and **leaves the pointer** so the reattach sweep collects the picture.

### 3.3 Server contract

**`POST /api/image/quota`** (`server.mjs:3237-3250`) — read-only pre-check, never charges.
- 401 `{ok:false,error:"auth required"}`; guest 403 `{ok:false,error:"signin_required",feature:"image"}`.
- 429 `{ok:false, limit, used, remaining:0}` when `IMAGE_DAILY_LIMIT >= 0 && used >= limit`.
- 200 `{ok:true, limit, used, remaining}` (`remaining:-1` when the limit is −1 = unmetered).
- `IMAGE_DAILY_LIMIT` env, **default 8** (`server.mjs:3187`; the comment above it still says 5, and the client's fallback strings say 5). The quota day is Baghdad's calendar day: `QUOTA_TZ_OFFSET_MINUTES` default 180 (`server.mjs:3196-3204`).

**`POST /api/image/job`** (`server.mjs:5138-5190`)
- Auth as above. Rate: 20 requests / 60 s per user → 429 `{error:"rate_limited"}`. Body limit 30 MB (`readJson(req, 30_000_000)`).
- Body: `prompt` (trimmed, ≤1000, required → else 400 `{error:"bad_request"}`), `w`, `h` (ints, clamped 256…1280, default 1024), `image` (if present → **501 `{error:"edit_job_unsupported"}`**; the client then uses `/api/image/edit`).
- `seed` is always `""` on this path. Job id = cache key = `sha1(engine + "|" + prompt + "|" + w + "x" + h + "|" + seed)` where engine = `REPLICATE_IMAGE_MODEL + ":" + REPLICATE_RESOLUTION + ":" + IMAGE_RECIPE` (`google/nano-banana-pro:2K:v2-nbpro-directed`) (`server.mjs:3268-3273`, `4167`). **Same prompt + same size = same bytes forever.**
- Cache hit → 200 `{ok:true, jobId:ckey, phase:"done", key:ckey}` (charges a slot if this user never had it).
- 429 `{error:"daily_limit", limit}` when a **new** slot would exceed `IMAGE_DAILY_LIMIT` (a repeat of a picture the user already made is free).
- Otherwise 200 `{ok:true, jobId:ckey, phase:"queued"}`; the render runs detached (`renderImageToCache`, `server.mjs:5029`): Replicate nano-banana-pro (with `directedPrompt`, ≤180 s) → Gemini → Cloudflare → OpenAI (budget-guarded, `OPENAI_IMAGE_DAILY` 8) → Puter → Hugging Face → pollinations. Non-Replicate rungs are passed through Picsart upscale (fails open). The slot is charged only on success.
- On terminal phase the server sends an APNs push (§10).

**`GET /api/image/job?id=<hex>`** (`server.mjs:5192-5205`) — member only (401). id is sanitised to `[a-f0-9]{≤64}`; empty → 400 `{error:"bad_request"}`. Responses, all 200: `{phase:"done", key}` (bytes exist on disk — wins even after a restart), `{phase:"fail", error}` (`error` is `"all_engines_failed"`, an exception message, or the fallback `"render_failed"` when the record carries no text), `{phase:"running"}` — **also for an id the server has never heard of**; there is no `unknown` phase, so the client's own 20-minute TTL is the only thing that ends a dead poll.

**`GET /api/image?key=<hex>`** (`server.mjs:5207-5232`) — member only (guest → 403 JSON `signin_required`); rate 240 / 60 s. 200 with the stored MIME (PNG on the Replicate rung) and `Cache-Control: public, max-age=86400`; 404 `not found` (text) when the key has no bytes.

**`GET /api/image?prompt=&w=&h=&seed=&cid=`** (`server.mjs:5233-5290`) — the legacy **synchronous** render used by the fallback fence. Same daily-cap logic keyed on the image; 429 plain text `daily limit reached`; 502 plain text `image generation failed`. Native should not depend on it.

### 3.4 The stored record (`firas-image` fence)

```
```firas-image
{"prompt":"<final English prompt>","key":"<sha1 hex>"}
```
```
Optional fields: `note` (reader caption ≤140 chars, §3.6), `w`,`h`,`seed`,`cid` (legacy sync-URL form, no `key`), `srUrl` (never persisted — on-device upscale blob). Parsed by `parseImageMeta` (`app.js:5022-5027`, regex ```` /```firas-image\s*([\s\S]*?)```/i ````; requires `prompt`). The message may carry prose around the fence; only the fence is replaced when the caption is written (`imgNoteWrite` `app.js:6150-6185`). `imageUrl(meta)` (`app.js:5170-5178`): `key` → `/api/image?key=…`; else `/api/image?prompt=…&w=…&h=…[&seed=…][&cid=…]`.

### 3.5 The image card (`buildImageCard` `app.js:6192-6385`, CSS `styles.css:4140-4370`)

- Layout: card max-inline-size 420 px (300 px square while loading; 340 px 4:3 when failed); the frame's aspect ratio is set from the decoded image's natural size (`--img-ar`) before the reveal; done state shows the image at its natural ratio, `cursor: zoom-in`.
- **Loader**: a calm dot field on a slow radial wave, accent-coloured, with a pulse and one rotating word. Words cycle every 2.6 s (`app.js:5200-5210`):
  - ar `["أقرأ طلبك", "أُركّب المشهد", "أضبط الضوء", "أصقل التفاصيل"]`, en `["Reading your prompt", "Composing the scene", "Setting the light", "Refining details"]`
  - sharpening phase: ar `["أرفع الدقّة", "أستعيد التفاصيل", "أشحذ الحوافّ", "أُنهي الصورة"]`, en `["Raising resolution", "Recovering detail", "Sharpening edges", "Finishing up"]`
  - Reveal on arrival: dots fade, one sheen sweeps, frame grows into the picture, total `IMG_REVEAL_MS = 1850`. Reduced motion freezes the wave but keeps the plate.
- **On-device upscale (opt-in, default OFF)**: `state.imgSr = localStorage["firas_ai_img_sr"] === "1"` (`app.js:3178`); Settings → «الصور» → toggle «شحذ الصور تلقائيًّا» hint «شبكة تعمل على جهازك — ثانية أو اثنتان، وبلا أي كلفة» (`app.js:45648-45649`). ESPCN ×3 ONNX on WebGPU/WASM, delivered at 2×, 30 s deadline, luma only. Saving always writes the **server's original** bytes, never the upscaled WebP. Native equivalent: optional Core ML / Metal sharpening is a bonus; not required for parity.
- **Actions when done**: tap/Enter/Space on the picture → full-screen viewer (§3.8); `تحميل` / `Download` → fetch full bytes and save as `resolveImageName(meta)` = prompt with `\/:*?"<>|` removed, whitespace collapsed, ≤50 chars, + `.png` (`app.js:5180-5183`); caption button (§3.6). The card never prints the prompt (deliberate — the rewritten English prompt is "machine text"); prompt is used only for `alt` (≤120 chars) and the filename.
- **Failure plate** (`imgFailShow` `app.js:5370-5415`): headline `imgFailed` (`تعذّر توليد الصورة` / `Image generation failed`), a reason line and one 44-px button. Reason: `imgWhyNet` when `navigator.onLine === false` (`تعذّر الوصول إلى الصورة — تحقّق من اتّصالك.`), else `imgWhyEngine` (`لم يُعدِ المحرّك صورة.`); after a paid retry also `imgWhyQuota` (`بلغت حدّك اليومي من الصور. الحدّ يتجدّد غدًا.`) or `imgWhySignin` (`انتهت جلستك. سجّل الدخول ثمّ أعد المحاولة.`). **Retry is cheap first**: press 1 = `إعادة المحاولة` / `Try again` reloads the same URL with `&_r=<ts>` (free — same cache slot); press 2 = `أعد التوليد` / `Regenerate` runs `requestImageJob(meta.prompt, meta.w||1024, meta.h||1024)` (paid; button shows `جارٍ…` / `Working…`; no owner pointer, so not reattachable) and on success rewrites the fence with the new key (`imgCardRetry` `app.js:5440-5488`).
- Save failure toast `imgSaveFailed`: `تعذّر حفظ الصورة.` / `The image could not be saved.`

### 3.6 Reader caption (`note`)

`IMG_NOTE_MAX = 140` (`app.js:6120`). Button `أضف تعليقًا` / `Add a caption` becomes `عدّل التعليق` / `Edit caption`; placeholder `اكتب تعليقًا قصيرًا على الصورة…` / `Write a short caption…`; toasts `حُفظ التعليق ✓` / `Caption saved ✓`, `أُزيل التعليق` / `Caption removed`. Backticks are stripped and whitespace collapsed before storage (the fence is one line of JSON). Read-only on the share page. Stored **inside the fence** as `note` so reloads, share links and exports carry it with no second store.

### 3.7 Quota / limit strings for images (verbatim)

`imageLimitText(lang, q)` (`app.js:6413-6430`):
- `reason:"signup"` → `**توليد الصور يحتاج حسابًا**\n\nأنشئ حسابًا مجانيًا خلال ثوانٍ لتوليد الصور، وحفظ محادثاتك، ورفع حدّك اليومي.` + sign-up card.
- `reason:"auth"` → `🔒 يجب تسجيل الدخول لإنشاء الصور.` / `🔒 Please sign in to generate images.`
- limit → `` `🌙 لقد وصلت إلى الحدّ اليومي لإنشاء الصور (${arDigits(limit)} صور في اليوم). يمكنك إنشاء المزيد غداً.` `` / `` `🌙 You've reached your daily image limit (${limit} images per day). You can create more tomorrow.` `` — `limit = q.limit || 5`. (Arabic plural: the string always says «صور» regardless of the number.)
- `rate_limited` (`app.js:42256-42258`) → `طلبات كثيرة في وقت قصير. انتظر دقيقة ثمّ أعد المحاولة.` / `Too many requests in a short time. Wait a minute and try again.`
- Landing feature copy (`app.js:742-744`): badge `تجريبي`, title `ميزة توليد الصور`, body `أُطلقت حديثًا وما زالت قيد التطوير، لذا قد تتحسّن النتائج تدريجيًا. الحدّ الحالي: ٥ صور في اليوم لكل مستخدم. جرّبها بكتابة «اصنع لي صورة…» داخل المحادثة.` (en `app.js:1831-1833`).

### 3.8 Full-screen viewer (`openImageViewer(url, meta)` `app.js:5758-5838`)

Overlay `role=dialog aria-modal`, sized in dvh/dvw, close button inset from the safe area (`aria-label` `إغلاق` / `Close`), the picture, the caption (read-only) and one bar with `حفظ الصورة` / `Save image` (downloads the **original** — `meta.directUrl` when the meta carries one, else `imageUrl(meta)` — never the upscaled blob; `app.js:5815-5822`). Backdrop tap closes; taps on the picture or the bar do not. Escape closes; Tab is trapped; focus returns to the picture that opened it. Opened from the card **and** from the gallery.

---

## 4. Image edit

### 4.1 Client flow (`app.js:41716-41770`)

- Trigger: §1.2 step 2. Source = `imgUser.images[0]` (raw base64, no prefix) when attached; otherwise `imageMetaToB64(priorImg)` (`app.js:5150-5165`) fetches `imageUrl(meta)` same-origin and base64-encodes it.
- Loader: the same image dot-plate.
- `editPrompt = rawUserText.slice(0,1000)` — **the edit instruction is not rewritten**.
- Source unreadable → `imageEditErrorText({error:"bad_image"})`. Stop during the read → the empty turn is removed.
- `requestImageEdit(editPrompt, srcB64, "", signal)` (`app.js:4880-4926`):
  1. `requestImageJob(prompt, 1024, 1024, signal, b64)` → on server.mjs always **501 `edit_job_unsupported`**.
  2. If `_lastImageJobError` is empty / `edit_job_unsupported` / `http_501` / `http_404` / `http_405`: `POST /api/image/edit` JSON `{prompt: prompt.slice(0,1000), image: b64, mime: "image/png"}`. `r.ok && key` → `{key}`; JSON `error` → `{error, limit}`; 429 without JSON → `{error:"daily_limit", limit:-1}`; 401/403 → `{error:"signin_required"}`.
  3. Otherwise `{error: _lastImageJobError}`; last resort probes `/api/image/quota` and returns `{error:"daily_limit", limit}` if `ok:false`, else `{error:"edit_failed"}`.
- Success: fence `{"prompt": editPrompt, "key"}` (so the stored prompt of an edited picture is the raw instruction, e.g. «اجعل السماء بنفسجية»). Failure: the assistant turn is the sentence from `imageEditErrorText` — **never a description of the picture**.

### 4.2 `imageEditErrorText(err, lang)` (`app.js:4928-4958`), verbatim

| `err.error` | ar | en |
| --- | --- | --- |
| `daily_limit` | `بلغت حدّك اليومي من تعديل الصور` + (limit ≥ 0 ? ` (N في اليوم)` : ``) + `. جرّب غدًا.` | `You have reached your daily image-editing limit` + ` (N/day)` + `. Try again tomorrow.` |
| `edit_unavailable` | `تعديل الصور غير متاح حاليًا — المحرّك الذي يقوم به نفد رصيده. توليد صور جديدة ما زال يعمل.` | `Image editing is unavailable right now — the engine that performs it is out of credit. Generating new images still works.` |
| `signin_required` | `سجّل الدخول لتعديل الصور.` | `Sign in to edit images.` |
| `bad_image` | `تعذّرت قراءة الصورة المرفقة.` | `That attached image could not be read.` |
| `background_unconfigured` | `تعديل الصور يحتاج إعداد المُشغّل الخلفي (INTERNAL_JOB_SECRET و FIREBASE_SERVICE_ACCOUNT في Netlify). أضِفهما ثم أعد المحاولة.` | `Image editing needs the background runner configured (INTERNAL_JOB_SECRET and FIREBASE_SERVICE_ACCOUNT in Netlify).` |
| `openai_unconfigured` | `مفتاح OpenAI غير مضبوط، وهو المحرّك الوحيد الذي يعدّل الصور.` | `The OpenAI key is not set, and it is the only engine that can edit a picture.` |
| `no_budget` | `نفد رصيد الصور المخصّص. ارفع السقف في الإعدادات لمواصلة التعديل.` | `The image budget is spent. Raise the ceiling to keep editing.` |
| default (`edit_failed`, `bad_request`, …) | `تعذّر تعديل الصورة. حاول مرة أخرى، أو صِف التعديل بتفصيل أوضح.` | `The image could not be edited. Try again, or describe the change more specifically.` |

### 4.3 Server `POST /api/image/edit` (`server.mjs:3922-4040`)

- Guest → 403 JSON `{error:"signin_required",feature:"image"}`; no cookie → 401 text. Rate 30 / 60 s → 429 text `rate limited`. Body ≤ 26 MB.
- Body: `prompt` (trim ≤1000), `image` (base64; a `data:…,` prefix is stripped), `mime` (default `image/png`; the server sniffs JPEG/PNG/WebP magic bytes and trusts those). Missing prompt/image → 400 `{error:"bad_request"}`; undecodable, empty or > 20 MB → 400 `{error:"bad_image"}`.
- **There is no mask, no region, no reference image and no size field** — the body is exactly `{prompt, image, mime}` (`server.mjs:3935-3937`); the whole picture is re-rendered from the instruction. `mime` is advisory: the server sniffs JPEG (`FF D8`), PNG (`89 50`) and WebP (`RIFF…WEBP`) magic bytes and prefers those (`server.mjs:3945-3949`).
- Cache key = `sha1("edit|" + engineTag + "|" + prompt + "|" + sha1(sourceBytes))` where `engineTag` = `"replicate|" + REPLICATE_IMAGE_MODEL + "|" + REPLICATE_RESOLUTION` (`replicate|google/nano-banana-pro|2K`) when a Replicate token exists, else `<openai model>|<OPENAI_IMAGE_QUALITY>` (`server.mjs:3960-3966`); hit → 200 `{ok:true, key, cached:true}` with no charge.
- Daily cap shared with generation (`imgCids`, `IMAGE_DAILY_LIMIT`): 429 `{error:"daily_limit", limit}`.
- Engine: Replicate nano-banana-pro `image_input:[dataUri]`, `aspect_ratio:"match_input_image"`, `directedPrompt(prompt,{edit:true})` (craft block only, no art direction); source > 8 MB skips Replicate. Fallback OpenAI edit: 503 `{error:"edit_unavailable"}` when no key/budget, 429 `{error:"daily_limit", limit: OPENAI_IMAGE_DAILY}` (8), 502 `{error:"edit_failed"}`.
- Success 200 `{ok:true, key}`; the bytes are then at `GET /api/image?key=`. **Synchronous** — the request stays open for the whole render (Replicate wait up to 180 s). There is no push for edits (they are not jobs).

---

## 5. Video

### 5.1 Client flow (`app.js:42033-42160`)

1. Guest gate (§2).
2. **Pre-check** `GET /api/video/quota` → `vq = {ok, limit, used, remaining, seconds}`. `vq.ok === false` → answer `بلغت حدّك اليومي من الفيديو (N يوميًا). الحدّ يتجدّد غدًا.` / `Daily video limit reached (N/day). It resets tomorrow.` and stop. Network failure → proceed.
3. Loader: file-style loader with `يجهّز الفيديو…` / `Preparing the video…`.
4. **Prompt rewrite** (`app.js:42063-42093`), `"pro"` tier, `vSecForPrompt = vq.seconds || 6`, `vHasImage` = the last user turn carries an attachment. System prompt verbatim (the two branches are the text-to-video and image-to-video variants):
   ```
   Turn the user's request into ONE vivid ENGLISH prompt for a {vSecForPrompt}-second video clip. Output ONLY the prompt text.
   ```
   then, **with a photo**:
   ```
   THE FIRST FRAME IS ALREADY GIVEN as a photograph the user attached, and the video animates forward from it. So do NOT describe the subject's appearance, the setting or the lighting — they are decided, and describing them again fights the photo and can replace the person in it with someone else. Describe ONLY WHAT CHANGES over the {vSecForPrompt} seconds: the motion, the transformation, how the light shifts as it happens, and ONE camera move.
   ```
   **without a photo**:
   ```
   Describe a SINGLE continuous shot: the subject, the setting, the lighting, and ONE simple camera or subject motion (a slow push in, a gentle pan, a rising object).
   ```
   then in both cases:
   ```
   ONE UNBROKEN SHOT: no scene cuts, no jumps in time or place, no dialogue, no on-screen text. A single continuous CHANGE is not a cut and is welcome — a person transforming, ice melting, a structure assembling — so keep any progression the user asked for and pace it across the full {vSecForPrompt} seconds, saying what has happened by the end.
   ```
   Result trimmed of quotes/backticks, whitespace collapsed, `.slice(0,1000)`; on failure the raw text (≤1000) is the prompt.
5. `vSeconds = vq.seconds || 6` (server returns `VIDEO_SECONDS` = 10), `vSeed = random int < 1e9` (only used by the legacy URL form).
6. **First frame** (`app.js:42102-42145`): if the last user turn has images, `vidDataUri(images[0])` (`app.js:3906-3917`) builds a data URI by sniffing the base64 head — `iVBOR`→png, `/9j/`→jpeg, `UklGR`→webp, `Qk`→bmp, else `""` (unknown types are dropped; a string already beginning `data:image/` passes through). The first-frame POST is sent **without** the turn's abort signal, so Stop cannot cancel it. The **turn** then `POST /api/video/job` `{prompt, seconds, image: dataUri}` and keeps only `jobId`. On a non-2xx the clip is still made from the text by the card, and a note is appended after the fence:
   - 429: `\n\n_تعذّر استخدام صورتك: بلغت حدّ الفيديو الآن._` / `\n\n_Could not use your photo: the video limit was reached._`
   - other status: `\n\n_تعذّر استخدام صورتك كإطار أول، فصُنع المقطع من الوصف وحده._` / `\n\n_Your photo could not be used as the first frame, so the clip was made from the description alone._`
   - exception: `\n\n_تعذّر إرسال صورتك، فصُنع المقطع من الوصف وحده._` / `\n\n_Your photo could not be sent, so the clip was made from the description alone._`
7. Fence: `{prompt, seconds, seed, jobId}` when a first-frame job was accepted, else `{prompt, seconds, seed}`; `finalizeAi`.
8. Toast (`app.js:42155-42158`): when `vq.remaining >= 0`: `بقي لك N فيديو اليوم` / `N video(s) left today` with `N = max(0, vq.remaining − 1)`.

### 5.2 The card (`buildVideoCard(meta, lang, msg)` `app.js:4715-4820`, CSS `styles.css:12382-12455`)

- 16:9 frame, max-inline-size 520 px, shimmer border while loading, spinner + text `يولّد الفيديو… قد يستغرق نحو نصف دقيقة` / `Generating video… this takes about half a minute` (stale — a Wan-3 clip takes 6–15 min). A `<video controls playsinline preload="metadata">` with `object-fit: contain` on black. Bar: prompt caption (≤80 chars, `dir=auto`) and a `تحميل` / `Download` button (hidden until done).
- **Three states:**
  1. `meta.key` → play `/api/video/file?id=<key>` immediately; download link = same URL, filename = sanitised prompt ≤50 + `.mp4`.
  2. `meta.jobId` (a first-frame job the turn started) → remember pointer (`videoJobRemember`), **poll** `videoJobPeek` every 2.5 s ×1.2 → 6 s until `VIDEO_JOB_MAX_MS` (20 min); never starts a second job.
  3. neither → `requestVideoJob(prompt, seconds||10, null, chatId)` (`app.js:3993-4030`): `POST /api/video/job` `{prompt: prompt.slice(0,2000), seconds}` (no image), remember pointer, poll as above.
- On key: `meta.key = key`, fence rewritten in place and `persistChat`; card flips to done.
- Failure text: `daily_limit` → `بلغت حدّك اليومي من الفيديو. جرّب بعدين.` / `Daily video limit reached.`; `signin_required` → `أنشئ حسابًا لتوليد الفيديو` / `Create an account to generate video`; `not_configured` → `محرّك الفيديو غير مهيّأ بعد` / `The video engine is not configured yet`; everything else (incl. `rate_window`, `site_media_ceiling`, `rate_limited`, `engine_failed`, `timeout`, `unreachable`) → `تعذّر توليد الفيديو` / `Video generation failed`. **There is no retry button on the video card.**
- `videoUrl(meta)` (`app.js:3919-3923`): key → `/api/video/file?id=`; no key → legacy `/api/video?prompt=…&seconds=…&seed=…` (HF Spaces path, pre-Replicate messages only).

### 5.3 Server contract

**`GET /api/video/quota`** (`server.mjs:5349-5359`) — member only (401). 200 `{ok, limit, used, remaining, seconds}`: `limit = VIDEO_DAILY_LIMIT` (default **2**), `used = user.vidCids.length`, `seconds = VIDEO_SECONDS` (default **10**, env-clamped 2…30). **Quirk:** `vidCids` is only ever charged by the legacy `/api/video` route; the job route logs to `vidLog`. So on the deployed server `used` is effectively always 0, `ok` is always true, and the web toast always says «بقي لك 1 فيديو اليوم». The real limiter is the rolling window below. Native should read `seconds` from here and ignore `remaining`.

**`POST /api/video/job`** (`server.mjs:4736-4823`)
- Guest 403 `{error:"signin_required",feature:"video"}`; 401 text; 503 `{error:"not_configured",feature:"video"}` when `REPLICATE_API_TOKEN` is unset; rate 10 / 60 s → 429 `{error:"rate_limited"}`. Body ≤ 12 MB.
- Body: `prompt` (trim ≤2000, required → 400 `{error:"bad_request"}`), `seconds` (int, clamp 2…30, default 10), `image` optional: must match `^data:image/(png|jpe?g|webp|bmp);base64,[A-Za-z0-9+/=]+$` or `^https://\S+$`, else 400 `{error:"bad_image"}`. The 413 `{error:"image_too_large", limit:10000000}` branch (string > `VID_IMAGE_MAX_BYTES × 1.4` = 14 M chars, `server.mjs:4764`) is **unreachable**: the body is read with `readJson(req, 12_000_000)` (`server.mjs:4747`), so a JSON body over 12 M characters is dropped, `b` becomes `null`, `prompt` is empty and the answer is **400 `{error:"bad_request"}`**. Practical ceiling for the data URI ≈ 11.9 M chars ≈ 8.9 MB of image bytes.
- Job id = cache key = `sha1("replicate:" + model + ":" + res + "|" + prompt + "|" + seconds + "|" + sha1(image or ""))` — the photo is part of the identity (`server.mjs:4640-4645`).
- Cache hit → 200 `{ok:true, jobId, phase:"done", key}`.
- Site ceiling (video + music, in-memory, 24 h rolling, `MEDIA_DAILY_MAX` default 120, owner **not** exempt) → 429 `{error:"site_media_ceiling", limit:120}`.
- Per-user rolling window `VIDEO_LIMIT` default **6 per 120 min** (`VIDEO_WINDOW_MIN`), owner exempt, repeats of an identical clip free → 429 `{error:"rate_window", limit:6, used, windowMin:120, freesInMin, hint?}`.
- 200 `{ok:true, jobId, phase:"queued"}`; render detached: Replicate `alibaba/wan-3`, `duration` 2…30, `resolution` `720p`, with image: `image`, `enable_prompt_expansion:false`, `negative_prompt:"different person, different face, changing facial features, replacing the subject, morphing into someone else, deformed face, extra people"`; wait up to `VIDEO_MAX_WAIT_MS` 20 min; clips over 200 MB are discarded (job fails). Terminal → APNs push (§10).

**`GET /api/video/job?id=`** (`server.mjs:4825-4837`) — member only. `{phase:"done", key}` | `{phase:"fail", error}` (`"engine_failed"` or an exception message ≤200) | `{phase:"running"}` (also for unknown ids).

**`GET /api/video/file?id=`** (`server.mjs:4839-4873`) — member **or guest**. 404 text; full 200 or HTTP Range 206 (`Accept-Ranges: bytes`, 416 on a bad range); `Content-Type: video/mp4`; `Cache-Control: private, max-age=31536000, immutable`. AVPlayer can stream it directly with the cookie attached.

**Legacy `GET /api/video?prompt=&seconds=&seed=`** (`server.mjs:5304-5347`) — synchronous HF Spaces path, `seconds` clamp 2…10, 429 `{error:"daily_limit", limit:2, used}`, 503 text when no HF accounts. Only reachable from pre-Replicate messages; do not implement.

### 5.4 Pointer table

`LS_VIDEO_JOBS = "firas_ai_video_jobs"` (`app.js:3921-3947`): `{ [chatId]: { jobId, sid, p: prompt≤400, ts } }`, capped at 8 (oldest `ts` evicted), TTL `VIDEO_JOB_MAX_MS` 20 min, `ts` never refreshed. `videoJobsReattach` (`app.js:3979-3991`) peeks each pointer **once** per return event: `done` → `videoLandKey` writes the key into the newest assistant turn carrying a `firas-video` fence without a key (matching the chat by `id`, `serverId` or `sid`), persists, re-renders if active, forgets; `fail` → forget; `running` → left for the next return (or the card's own poll when that chat is open).

---

## 6. Music (songs)

### 6.1 Client flow (`app.js:41846-42032`)

1. Guest gate (§2).
2. Loader: file-style loader `يكتب الكلمات…` / `Writing the lyrics…`.
3. `askedWith = lastUserTurn.content.slice(0,4000)`.
4. **Supplied lyrics** (`songIsWrittenOut` `app.js:41798-41805`): true if the text contains a `[verse|chorus|bridge|intro|outro|hook]` tag, or has ≥4 non-empty lines of which ≥ max(4, 80 %) are ≤60 chars. Then `lyrics = askedWith` untouched, prefixed with `[verse]\n` if no `[verse]`/`[chorus]` tag; `title = "نشيد"` / `"Song"`; **no model call**.
5. **Described song**: `callAgentText([...], "pro")` with the lyric-author system prompt below and user = `askedWith`. Facts material: the last 6 assistant turns (music fences stripped, ≤2000 each, ≤4000 total) is appended to the system prompt as `Take the facts from THIS material, which is already on the reader's screen, rather than from your own recall:\n<material>`. The reply's leading `STYLE:` line (tolerant regex `^[\s>#*_-]*\**\s*STYLE\s*\**\s*[:\-–]\s*(.+?)\s*$` on any line; surrounding code fence stripped; every remaining STYLE line dropped) becomes `musicStyleFromAuthor`; the rest is `lyrics`. Empty lyrics → answer `ما قدرت أكتب الكلمات. جرّب توصف النشيد بشكل أوضح.` / `I could not write the lyrics. Try describing the song more clearly.` `title = askedWith` whitespace-collapsed ≤60.
6. `style = musicStyleFromAuthor || musicStyleFor(lang, askedWith)` (§6.3).
7. Fence: `{"prompt": style, "lyrics", "seconds": 150, "title"}`; `finalizeAi` — **the turn does not start the job; the card does** (§6.4).

**Lyric-author system prompt, verbatim (decoded; `app.js:41891-41976`):**

```
You write song lyrics. WRITE THE SONG THEY ASKED FOR - their subject, their mood, their genre, their language. Anything: a love song, a sad one, an anthem, a rap, a pop song, a lullaby, a song about a person or a city or a team, a joke song, a classical qasida, a nasheed, or a Husseini latmiya. Do NOT default to a religious or educational register: unless they asked for one, write an ordinary song the way any songwriter would.
FIRST LINE OF YOUR REPLY: `STYLE: ` followed by English production tags describing how this song should SOUND - genre, tempo, instruments, voice. Then a blank line, then the lyrics. The style line is read by the music engine and is never sung, so write it for a producer, not for a listener. Always include `clear arabic vocals` when the lyrics are Arabic, or the engine may sing them in English.
  Some forms, so you name them rather than approximate them:
  - LATMIYA (لطمية حسينية): a mourning chant, not a sad song. A radoud leads and a majlis answers him; the metre is carried by chest percussion and frame drum with NO melodic instruments; grieving, dignified, building. Tags like: `husseini latmiya, radoud lead vocal with male group response, chest percussion, frame drum, no melodic instruments, mournful, dignified, building intensity`.
  - NASHEED: daf and ney, warm, a chorus built to be remembered.
  - IRAQI: maqam-coloured melody, joza, oud, iraqi percussion, choubi rhythm when it is a celebration.
  - And every ordinary genre: pop, rap, rock, ballad, lullaby, children's song.
Rules, in order of importance:
0. THE DIALECT IS THE WORDS THEMSELVES. If they asked for Iraqi, Khaleeji, Egyptian, Levantine or Maghrebi - or wrote to you in one - then WRITE IN THAT DIALECT: its own vocabulary and its own grammar, the way people actually speak it. Do not write Modern Standard Arabic and expect an accent to carry it; an accent over فصحى is still فصحى. Say so in the style line too (e.g. `iraqi arabic vocals`). Only write فصحى when they asked for it, or when the subject calls for it - a qasida, a nasheed, or a lesson to memorise.
1. ONLY IF THE SONG TEACHES SOMETHING, every fact in it must be correct - a wrong number or name in something a person memorises is worse than no song, so leave out anything you are not sure of. For every other kind of song this rule does not apply at all, and you should write freely and with feeling.
2. Write in the SAME LANGUAGE the user wrote in.
3. Short lines - six to nine words. A [chorus] that repeats and CARRIES THE THING TO BE REMEMBERED, so the chorus alone teaches it.
4. A steady metre. Keep syllable counts close between paired lines; rhyme is welcome but never at the cost of a fact or of the metre.
5. ARABIC: TASHKEEL, AND BE SPECIFIC ABOUT IT. The singer reads phonetically and guesses at anything unmarked, and a wrong guess is not an accent - it is a DIFFERENT WORD, sung confidently. Mark these, every time:
   a) THE LAST LETTER OF EVERY SUNG LINE. The ending is held in singing and is where the model guesses hardest. Put a sukun on a stopped ending.
   b) EVERY SHADDA. A doubled consonant is a different word, not an ornament: عَلَّمَ is not عَلِمَ.
   c) THE FIRST VOWEL OF EVERY VERB - it carries voice and tense. كَتَبَ, كُتِبَ and يَكْتُبُ are one written form and three meanings.
   d) ANY WORD CARRYING THE POINT - a name, a number, the fact itself.
   e) WRITE HAMZA PROPERLY: أ إ ؤ ئ ء, never a bare alif standing in for one. The singer reads what is written, and a missing hamza is a missing consonant.
   NEVER put tanwin on a stopped line ending: كِتَابٌ at the end of a sung line asks for "kitabun" where a singer stops on "kitab", and that one habit is what makes Arabic AI vocals sound like a textbook read aloud instead of a song.
   Do not vowel every letter of every word beyond the above: over-marking makes the line harder to segment, and the aim is removing ambiguity rather than decoration.
   IF THE LYRICS ARE IN A DIALECT, rule 5 changes: dialects have no إعراب, and marking case endings drags the singing back toward فصحى. Keep only the marks that are about SOUND - every shadda, correct hamza, and the vowel on any word that would otherwise be read as a different word. Never put tanwin or a case ending on dialect words at all.
5. Use [verse] and [chorus] tags. Two or three verses. Nothing else - no title, no commentary, no explanation. Output the lyrics and stop.

KEEP HIS WORDS. Read what he sent and decide which of these it is:
- He gave you WORDS HE WANTS IN THE SONG - a line, a phrase, a name, a refrain, something in quotes, something he says to mention or include. Those words appear in your lyrics EXACTLY as he wrote them, letter for letter. Build the song around them. Do not paraphrase them, do not translate them, do not improve them. You may add tashkeel to them and nothing else.
- He only DESCRIBED a song, and gave you no words of his own. Then every word is yours, taken from what he described.
When you cannot tell, treat the words as his and keep them. Handing someone back a paraphrase of their own line is worse than including a line you did not need to.
```
(followed, when material exists, by `\n\nTake the facts from THIS material, which is already on the reader's screen, rather than from your own recall:\n` + material).

### 6.2 Options the user can influence (no UI; all from the text)

- **Genre / dialect / mood** — read by the author model; fallback `musicStyleFor` (§6.3).
- **Own lyrics vs. described** — `songIsWrittenOut`.
- **Instrumental** — not offered; the server sends `lyrics` only when non-empty (ACE-Step's default is `[instrumental]`), but the client always sends lyrics.
- **Duration** — always `150` s in the fence (server clamps 10…600, default 150).

### 6.3 `musicStyleFor(lang, ask)` (`app.js:4402-4460`) — first regex match wins; tags are English on purpose

`arabicVoice = "clear arabic vocals, "` (ar) / `"clear vocals, "`; `eastern = "oud, darbuka, ney, middle eastern melody, "` (ar only); `mix = "professional studio mixing"`.

| Regex (flag i) | Style |
| --- | --- |
| `(حماسي\|حماسية\|قوي\|قوية\|طاقة\|رياضي\|نشيط\|energetic\|hype\|anthem\|epic\|powerful)` | `epic anthem, driving percussion, powerful ` + arabicVoice + `big chorus, cinematic, ` + eastern + mix |
| `(لطمية\|لطميات\|لطميه\|رادود\|رواديد\|مجلس\s*عزاء\|عاشوراء\|حسيني[ةه]?\|\b(?:latmiya\|latmiyat\|radoud\|husseini\|ashura)\b)` | `husseini latmiya, radoud lead male vocal with male group response, chest percussion, frame drum, daf, no melodic instruments, mournful, dignified, building intensity, clear arabic vocals, ` + mix |
| `(عراقي\|عراقية\|بغدادي\|جوبي\|چوبي\|مقام\s*عراقي\|\b(?:iraqi\|choubi\|maqam)\b)` | `iraqi arabic song, iraqi arabic vocals, maqam-coloured melody, joza, oud, iraqi percussion, choubi rhythm, ` + mix |
| `(خليجي\|خليجية\|سعودي\|كويتي\|إماراتي\|اماراتي\|\b(?:khaleeji\|gulf)\b)` | `khaleeji arabic song, gulf arabic vocals, oud, tabl, khaleeji rhythm, ` + mix |
| `(مصري\|مصرية\|شعبي\|مهرجان\|\b(?:egyptian\|masri\|shaabi\|mahraganat)\b)` | `egyptian arabic song, egyptian arabic vocals, shaabi rhythm, accordion, tabla, ` + mix |
| `(شامي\|شامية\|لبناني\|سوري\|دبكة\|\b(?:levantine\|shami\|lebanese\|syrian\|dabke)\b)` | `levantine arabic song, levantine arabic vocals, dabke rhythm, mijwiz, derbake, ` + mix |
| `(مغربي\|مغربية\|جزائري\|تونسي\|\bراي\b\|\b(?:maghrebi\|moroccan\|algerian\|rai)\b)` | `maghrebi arabic song, maghrebi arabic vocals, gnawa percussion, rai influence, ` + mix |
| `(حزين\|حزينة\|شجن\|فراق\|بكاء\|sad\|melancholy\|heartbreak\|emotional)` | `sad emotional ballad, slow tempo, expressive ` + arabicVoice + `strings, ` + eastern + mix |
| `(رومانسي\|رومانسية\|حب\|غرام\|عشق\|romantic\|love)` | `romantic ballad, warm ` + arabicVoice + `soft strings, intimate, ` + eastern + mix |
| `(راب\|هيب\s*هوب\|rap\|hip\s*hop\|trap)` | `hip hop, rap, hard drums, confident ` + arabicVoice + `bass heavy, ` + mix |
| `(روك\|rock\|metal\|guitar)` | `rock, electric guitars, live drums, strong ` + arabicVoice + mix |
| `(بوب\|pop\|dance\|رقص\|حفلة\|party)` | `modern pop, catchy hook, upbeat, ` + arabicVoice + eastern + mix |
| `(طرب\|كلاسيك\|فصحى\|قصيدة\|موشح\|tarab\|classical\|qasida)` | `tarab, classical arabic, oud, qanun, ney, warm dynamic arabic vocals, middle eastern melody, ` + mix |
| `(هادئ\|هادئة\|نوم\|تأمل\|calm\|lullaby\|sleep\|ambient)` | `calm lullaby, gentle, soft ` + arabicVoice + `sparse arrangement, ` + eastern + mix |
| `(أطفال\|اطفال\|طفل\|children\|kids\|nursery)` | `children's song, playful, simple memorable chorus, ` + arabicVoice + eastern + mix |
| `(نشيد\|أنشودة\|انشودة\|ديني\|إسلامي\|اسلامي\|nasheed\|anasheed)` | `arabic nasheed, clear arabic vocals, simple memorable chorus, daf, ney, middle eastern melody, warm, ` + mix |
| default (ar) | `modern arabic song, clear arabic vocals, catchy memorable chorus, oud, darbuka, middle eastern melody, warm, ` + mix |
| default (en) | `clear vocals, catchy memorable melody, warm, ` + mix |

### 6.4 The card (`buildMusicCard(meta, lang, msg)` `app.js:4592-4713`, player `musicPlayerEl` `app.js:4470-4590`, CSS `styles.css:22421-22500`)

- Header: `♪` + title (`meta.title || meta.prompt`, ≤90, `dir=auto`). Body states:
  - working: spinner + `يلحّن الأغنية… حوالي دقيقة` / `Composing… about a minute`
  - ready: custom player (44-px accent play/pause button `تشغيل`/`إيقاف مؤقّت` / `Play`/`Pause`, range seek `موضع التشغيل`/`Seek`, times `0:00` / `--:--` LTR), row with `تحميل` / `Download` (`<a download>` of `/api/music/file?id=`, filename = sanitised title or `firas-song` + `.mp3`) and `أعد التلحين` / `Regenerate`.
  - failed: sentence + Regenerate. Sentences: `not_configured` → `محرّك الموسيقى غير مهيّأ بعد` / `The music engine is not configured yet`; `rate_window` or `daily_limit` → `لقد وصلت إلى الحد — يرجى الانتظار ساعتين` / `You have reached the limit — please wait two hours`; `signin_required` → `سجّل دخولك حتى تصنع أغنية` / `Sign in to make a song`; anything else (`site_media_ceiling`, `rate_limited`, `engine_failed`, `timeout`, `unreachable`, `http_*`) → `ما ضبط التلحين` / `The song did not come out`.
- `meta.key` → ready immediately; else the **card** calls `requestMusicJob(prompt, lyrics, seconds||150, null, chatId)` and on success rewrites the fence with `key` and persists.
- **Regenerate**: copies meta, deletes `key`, sets `nonce = String(Date.now())` (a string; the nonce is *not* sent to the server; since ACE-Step is seeded randomly and the server cache key is `engine|prompt|lyrics|seconds`, a regenerate with identical inputs returns the **cached** recording — a real re-roll needs a changed prompt/lyrics).
- One song audible at a time (`_musicPlaying`); TTS read-aloud is stopped when a song plays; `preload="none"`; the element is released when the card leaves the DOM.

### 6.5 `requestMusicJob(prompt, lyrics, seconds, signal, chatId)` (`app.js:59147-59190`)

`POST /api/music/job` `{prompt: prompt.slice(0,2000), lyrics: lyrics.slice(0,6000), seconds}`; error → `_lastMusicError = body.error || "http_<status>"` / `"unreachable"` / `"no_job"`. Pointer `musicJobRemember(chatId, jobId, prompt, sid)` written before polling. Poll `GET /api/music/job?id=` from 2 s ×1.2 → 6 s until `MUSIC_JOB_MAX_MS` (10 min) → `"timeout"`.

### 6.6 Server contract

**`POST /api/music/job`** (`server.mjs:4875-4949`): guest 403 `{error:"signin_required",feature:"music"}`; 401 text; 503 `{error:"not_configured",feature:"music"}`; rate 10 / 60 s → 429 `{error:"rate_limited"}`; body ≤ 200 KB. Body: `prompt` (≤2000), `lyrics` (≤6000), both empty → 400 `{error:"bad_request"}`; `seconds` int clamp 10…600 default 150. Cache key `sha1("replicate:"+model+"|"+prompt+"|"+lyrics+"|"+seconds)` (or `musicapi:`+model). Cache hit → `{ok:true,jobId,phase:"done",key}`. 429 `{error:"site_media_ceiling", limit:120}`; 429 `{error:"rate_window", limit:10, used, windowMin:120, freesInMin}` (`MUSIC_LIMIT` 10 per 120 min rolling, owner exempt, identical song free). 200 `{ok:true, jobId, phase:"queued"}`; engine ACE-Step 1.5 (pinned) via Replicate with `tags = prompt`, `lyrics` (sent only when non-empty — absent means the model's own `[instrumental]` default), `duration`, `seed:-1`, `batch_size:1`, `audio_format:"mp3"` (`ACE_FORMAT`), plus the tuned `inference_steps` / `guidance_scale` / `shift` / `time_signature` / `thinking` (`musicInputFor` `server.mjs:4449-4473`); or MusicAPI (Suno) when `MUSIC_PROVIDER=musicapi`. **Engine wait is 180 s, not 7 min**: `renderMusicToCache` (`server.mjs:4578-4589`) calls `replicateRun` without a `waitMs`, so the default `REPLICATE_MAX_WAIT_MS = 180_000` (`server.mjs:4192`, applied at `4260`) governs — `MUSIC_MAX_WAIT_MS` (420 s, `server.mjs:4385`) is defined and never used. A `seconds` far above the 150 default can therefore end as `engine_failed`. Terminal → APNs push.

**`GET /api/music/job?id=`** (`server.mjs:4951-4967`) and **`GET /api/music/file?id=`** (`server.mjs:4969-4996`): identical shapes to video (§5.3), MIME `audio/mpeg`, Range supported, guest may fetch the file.

### 6.7 Pointer table

`LS_MUSIC_JOBS = "firas_ai_music_jobs"` (`app.js:59027-59063`): `{ [chatId]: { jobId, sid, p≤400, ts } }`, cap 8, TTL `MUSIC_JOB_MAX_MS` 10 min. `musicJobsReattach` (`app.js:59076-59108`) peeks once per return; `musicLandKey` (`app.js:59110-59145`) writes into the newest `firas-music` turn without a key whose `jobId` (if present) matches; forgets only when landed or failed.

---

## 7. The gallery (`#galleryBtn`, `openImageGallery` `app.js:5903-6100`, CSS `styles.css:4451-4575`)

- **What it lists:** every ```` firas-image ```` fence in the **open conversation's assistant turns**, in message order (`chatImageMetas(chat)` `app.js:5846-5862`). Images only — no videos, no songs, no attached user photos. There is **no gallery state, no localStorage, no server route**: the fences are the record. The topbar button (`index.html:685`, `title` «صور المحادثة», `aria-label` "Chat images") is `hidden` unless the active chat has ≥1 image (`syncGalleryBtn`, called on chat open/render `app.js:20146`, `22286`).
- Overlay `role=dialog`: header = title `صور هذه المحادثة` / `Images in this chat` + count (LTR digits), primary button `تحميل الكل (ZIP)` / `Download all (ZIP)`, close `إغلاق` / `Close`. Grid of square tiles (`minmax(168px,1fr)`, `object-fit: cover`, lazy), each numbered, with two actions (always visible on touch): `تحميل الصورة` / `Download image` (original bytes) and `اعرضها في المحادثة` / `Show it in the chat` (closes, then `jumpToTurn(index)` after 240 ms). Tapping a tile opens the viewer (§3.8). Escape closes one layer at a time (viewer first, then grid).
- **Download all**: sequential fetches (never parallel), label counts `k / total` in LTR, entries named `NN - <resolveImageName sans .png>.<ext by response MIME: jpg|webp|png>`, ZIP named `<chat title sanitised ≤48 || "firas-images"> (<n>).zip`, built client-side (`buildZip` `app.js:50825`). Toasts: `تم حفظ الصور ✅` / `Images saved ✅`; partial `تعذّر جلب {n} من الصور — والباقي محفوظ` / `{n} couldn't be fetched — the rest are saved`; failure `تعذّر تحميل الصور — حاول مرة أخرى` / `Couldn't download the images — try again`. One archive at a time (`_galZipping`).
- All strings: `app.js:1021-1030` (ar), `2091-2099` (en).

---

## 8. Background jobs and reattach (media)

Common shape (background-jobs-browser §3–§7): the server owns the work, localStorage owns a pointer, the view is disposable.

| Kind | Table key | Record | Cap | TTL (client) | Reattach behaviour |
| --- | --- | --- | --- | --- | --- |
| image | `firas_ai_img_jobs` (`app.js:59019`) | `{jobId, cid, sid, p≤600, ts}` | 8 | 20 min (`IMG_JOB_MAX_MS`) | `imgJobsReattach` → `imgWatchJob` **continuous poll** (2 s ×1.25 → 6 s), idempotent per chat (`_imgJobPolls`), 401/403 → forget, chat missing for >15 ticks after the list loaded → forget, `fail` → forget, `done` → `imgLandKey` then forget |
| music | `firas_ai_music_jobs` | `{jobId, sid, p≤400, ts}` | 8 | 10 min | single peek per return event |
| video | `firas_ai_video_jobs` | `{jobId, sid, p≤400, ts}` | 8 | 20 min | single peek per return event |

- The flat `firas_job_<chatId>` key (the rail "still working" badge) is **deliberately not written** for media (`app.js:59015-59018`), so a rendering picture does not light the sidebar row. `jobPtrSweep` (`app.js:59323`) ignores the three media tables.
- Return events (`app.js:50755-50778`): `visibilitychange` (visible), `online`, `focus`, `pageshow`; plus boot after `fetchChats()` (`app.js:47199-47207`). All three media reattachers run on each.
- `imgLandKey(chat, cid, prompt, key)` (`app.js:59240-59263`) targets the message with `msg.cid === cid` (else the last assistant turn); refuses if that turn already has a keyed fence or has non-fence content; writes `{prompt, key}`, clears `reasoning`, persists, re-renders if active, repaints the sidebar. `ts` is the job start and is never refreshed.
- Abort (Stop button / navigation) stops the **poll only**; there is no cancel endpoint for any media job — the render always completes and is charged.
- Pointer files under `chat.id` (local uid) **and** `sid` (`chat.serverId`); lookup `jobChatById` (`app.js:58566`) tries all four combinations because after a reload `state.chats` carries server ids only.

---

## 9. Persistence shapes the native client must read and write

- Assistant message content = the fence string exactly as shown in §3.4 / §5.1 / §6.1 (single-line JSON, ```` ``` ```` fences, kind name lowercase). Server-side `sanitizeMessages` passes `content` through untouched, so old chats pulled from `/api/chats` contain these fences; the native renderer must dispatch on them in this order (`app.js:23897-23917`): agent → deck → project → image → music → video → code → file → markdown. A message is one card; a video/music note (the `_…_` first-frame sentence) trails the fence as markdown and the web card path drops it (only the card is rendered when a fence is present).
- User message: `content`, `lang`, `tier`, `images` (array of raw base64, **in memory only**, ≤10, longest edge downscaled to 1568 px client-side `app.js:35897-35899`), `imageThumbs` (data-URL thumbs, 256 px, persisted), `files`, `cid`, `intent` (turnKind, in memory), `requirements`.
- The share page (`/?share=`) renders image cards read-only; `firas-video` / `firas-music` fences are **not** parsed there (they fall to markdown) (`app.js:79869-79877`).
- The T-shaped chat map / sidebar marks turns that contain `firas-image` (`app.js:21956`); pictures are the only media kind surfaced there.
- Regenerate on an image turn (`regenerate` `app.js:46324`): re-runs the prompting message; the result is a new turn appended below (cards never fold into versions); because the job cache key is the rewritten prompt, an identical rewrite returns the identical picture.

---

## 10. Push notifications for media jobs (server → native)

`notifyMediaJobTerminal` (`server.mjs:~4715`) → `notifyDurableJobTerminal` (`server.mjs:1627`) on every image/video/music job reaching `done` or `fail` (once per job, never for guests, only when APNs is configured and the user has registered devices). Payload (`apnsPayload`, just above `server.mjs:1627`):

```json
{
  "aps": {
    "alert": { "title": "صورتك جاهزة", "body": "اضغط لعرض الصورة وحفظها أو مشاركتها." },
    "sound": "FirasComplete.wav",
    "category": "FIRAS_JOB_COMPLETE",
    "thread-id": "firas-ai-<jobId>"
  },
  "firas": { "type": "job-terminal", "product": "ai", "jobId": "<cache key>", "phase": "completed" | "failed", "mediaKind": "image" | "video" | "music" }
}
```
`apns-collapse-id` = jobId. **No `chatId`** is carried for media jobs (the job record has none) — the native app must map `jobId` → conversation from its own pointer table. Copy per device language (`apnsLocalizedCopy`):

| kind | ar completed | ar failed | en completed | en failed |
| --- | --- | --- | --- | --- |
| image | `صورتك جاهزة` / `اضغط لعرض الصورة وحفظها أو مشاركتها.` | `تعذر إنشاء الصورة` / `اضغط لعرض التفاصيل أو المحاولة مجددا.` | `Your image is ready` / `Tap to view, save, or share it.` | `Your image could not be created` / `Tap to view details or try again.` |
| video | `فيديوك جاهز` / `اضغط لمشاهدة الفيديو وحفظه أو مشاركته.` | `تعذر إنشاء الفيديو` / same | `Your video is ready` / `Tap to watch, save, or share it.` | `Your video could not be created` / same |
| music | `أغنيتك جاهزة` / `اضغط للاستماع إلى الأغنية وحفظها أو مشاركتها.` | `تعذر إنشاء الأغنية` / same | `Your song is ready` / `Tap to listen, save, or share it.` | `Your song could not be created` / same |

---

## 11. Every media error code and the sentence the UI should show

| Route | HTTP | `error` | Web sentence (ar) | Native note |
| --- | --- | --- | --- | --- |
| all creation routes | 403 | `signin_required` (+`feature`) | image: `سجّل الدخول لتعديل الصور.` (edit) / `🔒 يجب تسجيل الدخول لإنشاء الصور.`; video card: `أنشئ حسابًا لتوليد الفيديو`; music card: `سجّل دخولك حتى تصنع أغنية` | guests should be gated before the call with the §2 upsell |
| all | 401 | (text) | image: `انتهت جلستك. سجّل الدخول ثمّ أعد المحاولة.` (`imgWhySignin`) | session expired → re-auth |
| image/job, image/edit | 429 | `daily_limit` (+`limit`) | `🌙 لقد وصلت إلى الحدّ اليومي لإنشاء الصور (N صور في اليوم). يمكنك إنشاء المزيد غداً.` / edit: `بلغت حدّك اليومي من تعديل الصور (N في اليوم). جرّب غدًا.` | resets at Baghdad midnight |
| image/job, video/job, music/job | 429 | `rate_limited` | image: `طلبات كثيرة في وقت قصير. انتظر دقيقة ثمّ أعد المحاولة.`; video/music: generic failure | 20 / 10 / 10 per minute |
| image/job | 501 | `edit_job_unsupported` | (internal → use `/api/image/edit`) | never shown |
| image/job GET | 200 | `phase:"fail"` `all_engines_failed` | `لم يُعدِ المحرّك صورة.` + retry | |
| image/edit | 400 | `bad_request`, `bad_image` | `تعذّرت قراءة الصورة المرفقة.` | |
| image/edit | 503 | `edit_unavailable` | `تعديل الصور غير متاح حاليًا — المحرّك الذي يقوم به نفد رصيده. توليد صور جديدة ما زال يعمل.` | |
| image/edit | 502 | `edit_failed` | `تعذّر تعديل الصورة. حاول مرة أخرى، أو صِف التعديل بتفصيل أوضح.` | |
| video/job, music/job | 503 | `not_configured` | `محرّك الفيديو غير مهيّأ بعد` / `محرّك الموسيقى غير مهيّأ بعد` | |
| video/job | 400 | `bad_image` (data URI of the wrong shape) / `bad_request` (JSON body over the 12 M-char cap — the photo *and* the prompt are dropped); the 413 `image_too_large` branch is unreachable (§5.3) | web appends `_تعذّر استخدام صورتك كإطار أول، فصُنع المقطع من الوصف وحده._` and makes a text-only clip | native: re-encode the photo to JPEG ≤ ~8 MB (data URI < 11.9 M chars) before sending |
| video/job, music/job | 429 | `rate_window` (`limit`, `used`, `windowMin`, `freesInMin`) | music: `لقد وصلت إلى الحد — يرجى الانتظار ساعتين`; video: generic `تعذّر توليد الفيديو` (gap) | native should say "N per 2 hours; frees in `freesInMin` minutes" |
| video/job, music/job | 429 | `site_media_ceiling` (+`limit`) | generic failure (gap) | native: "the site's daily media budget is used up; try later" |
| video/job, music/job GET | 200 | `phase:"fail"` `engine_failed` / message | `تعذّر توليد الفيديو` / `ما ضبط التلحين` | |
| client | — | `timeout` / `unreachable` / `no_job` | same generic sentences | image: 12 min in-turn, 20 min pointer TTL; video 20 min; music 10 min |

---

## 12. Native spec — Media Studio + in-chat creation

### 12.1 In-chat creation (parity with the web)

1. **Routing.** Reproduce §1 exactly: one `pro`-tier classification call per user turn with the verbatim prompt and situation lines; store `intent` on the message; apply the branch order of §1.2 and the guards (attachment ⇒ never fresh image; 4-turn lookback for "picture in play"; `edit-image` downgrade). Keep the regex fallbacks for the `unavailable` case only — never let a pattern overrule a verdict. Keep `MATH_FIGURE_RE` as a hard veto in the fallback path.
2. **Image turn.** Guest gate → `POST /api/image/quota` pre-check → placeholder card with the loader words → rewrite (`pro`) → `pickImageShape(rawText)` → `POST /api/image/job` → write the pointer → poll with the same backoff → persist `{prompt,key}` fence → toast the remaining count when the bytes decode. Treat `null` + unknown error as a failure plate with the free/paid retry pair; do **not** implement the synchronous `/api/image?prompt=` fallback unless parity with very old chats matters.
3. **Edit turn.** Source = attached UIImage bytes (JPEG/PNG, ≤20 MB decoded) or the prior key's bytes fetched from `/api/image?key=`; `POST /api/image/edit` directly (skip the 501 round trip); render the sentence table of §4.2 on failure; never fall back to describing the picture.
4. **Video turn.** Guest gate → `GET /api/video/quota` only to read `seconds` → placeholder → rewrite with the correct branch (photo vs. text) → if a photo is attached, POST the job **with the photo** from the turn (sniff the MIME; re-encode HEIC to JPEG; keep the whole JSON body under 12 M chars — §5.3) and store `jobId` in the fence; otherwise let the card start the text-only job. Show the first-frame refusal notes verbatim. Poll 2.5 s ×1.2 → 6 s, 20 min. Play with `AVPlayer` on `/api/video/file?id=` (Range-capable, cookie required) and offer Save to Photos / Share.
5. **Song turn.** Guest gate → "يكتب الكلمات…" placeholder → `songIsWrittenOut` → author call with the verbatim prompt (strip the STYLE line exactly as §6.1) or pass-through lyrics → fence `{prompt: style, lyrics, seconds:150, title}` → the card starts the job. Player: play/pause, scrubber, elapsed/total (LTR), download, regenerate; only one song audible at a time; pause TTS when a song starts. Use `AVAudioSession` playback category so a locked phone keeps playing.
6. **Cards.** Message-cell dispatch order of §9. Sizes: image ≤420 pt wide at natural ratio, video 16:9 ≤520 pt, song a full-width rounded card. Loader copy verbatim (§3.5, §5.2, §6.4). Reduced-motion honours the system setting.
7. **Failure plates.** Image: sentence + one 44-pt button, free reload first then paid regenerate. Video/music: sentence + (music) regenerate. Add the two web gaps (`rate_window`, `site_media_ceiling`) as proper sentences.
8. **Guest handling.** The four verbatim upsell answers + the sign-up sheet copy (§2).
9. **Background/return.** Keep three pointer tables with the same caps and TTLs (or one table with a `kind` field), reattach on `scenePhase == .active`, on network regain and on cold launch after the chat list loads; image reattach is a continuous poll, video/music at least a peek. Handle the `job-terminal` push: `mediaKind` + `jobId` → find the conversation via the pointer table → land the key into the newest fence without a key (the `imgLandKey` refusals apply: never overwrite a keyed fence, never write into a turn that has prose). Never present a "cancel" for media — the server has none.
10. **Attachments feeding media.** Keep `images` (raw base64, ≤10, longest edge 1568) in memory only and persist 256-px thumbs; re-attach the last photo on follow-ups that match `refersToPriorImage`.

### 12.2 Media Studio (a native surface the web does not have)

The web has no studio; everything is chat-first. A native studio should be a **front end onto the same fences and routes**, so a studio creation lands in a conversation exactly like a typed request would (that is what keeps the gallery, sharing, reattach and push working):

- **Library tab** = the gallery generalised: scan all conversations' assistant messages for `firas-image`, `firas-video`, `firas-music` fences (the web only indexes images and only for the open chat). Group by conversation, show kind chips, open the source turn, save/share, "download all" as a ZIP of originals with the same naming rules (§7).
- **Create tab**: a kind picker (image / edit / video / song) that writes a user message into a chosen or new conversation and runs the §12.1 branch with `intent` forced (skip the classifier). Expose the few controls the pipeline actually honours: for images an optional shape override (square 1024², tall 1024×1536, wide 1536×1024 — note the server clamp to 1280 and the Replicate snap); for video a photo picker (first frame) and a duration slider 2–30 s (server clamps; default `quota.seconds` = 10); for songs a "use my lyrics" toggle (bypasses the author) and a genre chip that pre-seeds the style tags from §6.3. Do **not** expose a count — every route returns one item and identical inputs return the cached item.
- **Quota panel**: images — `POST /api/image/quota` gives `used/limit/remaining` (limit 8 by default, Baghdad midnight reset). Video/music — there is **no read-only quota endpoint** for the rolling windows; show the window rule (6 clips / 10 songs per 2 h) and, after a 429 `rate_window`, the server's `freesInMin`.
- **Edit from the library**: any stored image key can be the source of an edit (fetch bytes from `/api/image?key=`, POST to `/api/image/edit`), producing a new turn in that image's conversation.

---

## 13. Risks and discrepancies to carry into the native port

1. **Video quota endpoint is stale.** `/api/video/quota` counts `vidCids` (legacy path) while the job route counts `vidLog`; `remaining` never drops and the web toast is always «بقي لك 1 فيديو اليوم». Read only `seconds` from it.
2. **Web video/music cards do not explain `rate_window` or `site_media_ceiling`** — both show a generic failure. Native should render them properly (the JSON carries `limit`, `used`, `windowMin`, `freesInMin`).
3. **`IMAGE_DAILY_LIMIT` is 8 in code, 5 in the comments and in the client's fallback copy** (`limit || 5`, landing text «٥ صور»). Always print the server's `limit`.
4. **Unknown job ids answer `running`, never `unknown`.** The client TTLs (image/video 20 min, music 10 min) are the only terminal condition after a server restart that forgot an in-flight job (rare — results are found by key).
5. **Identical inputs return identical bytes** (cache key = prompt + size, no seed on the job path; songs key on style+lyrics+seconds; clips on prompt+seconds+photo). "Regenerate" must change the prompt to get a different result; the music card's `nonce` is inert.
6. **Edits are synchronous** (`/api/image/edit` holds the request up to ~3 min on Replicate) and have no job id, no pointer, no push. A backgrounded iOS app will lose the response; the result is cached server-side under `sha1(edit|engine|prompt|sha1(src))`, so a retry with the same bytes+prompt is free and instant — native should retry on foreground rather than re-asking the user.
7. **No cancel** for any media job; Stop only stops watching. The server charges the slot when the render succeeds.
8. **Shape labels in `pickImageShape` are mislabeled** (`"3:4"`/`"4:3"` for 2:3/3:2) and the 1280 server clamp turns 1536×1024 into 1280×1024 → Replicate `5:4`. If the studio offers "wide", send 1280×1024 knowingly or accept the snap.
9. **First-frame photo limits:** data URI must be `png|jpe?g|webp|bmp`; HEIC from the camera roll must be re-encoded; the whole JSON body must stay under 12 M characters (the 14 M-char / 413 rule in the code is dead — over the cap the request degrades to 400 `bad_request` and the web silently makes a text-only clip), so keep the photo ≤ ~8 MB as JPEG; the server never logs it.
10. **`song` is missing from `TURN_KINDS`** but is parsed and routed — do not copy the constant literally.
11. **Guest cookie can fetch finished video/music files but not images** (`/api/image?key=` is member-only). A shared/read-only view for a guest can play a song but not load a picture.
12. **The web gallery is images-only and per-conversation, with no persisted state.** A cross-conversation library must be built by scanning message fences locally (all three kinds are `firas-*` fenced JSON, one per assistant turn).
13. **Web share page drops video/music cards** (renders raw fences as markdown). If native implements shared chats, render all three.
14. **The upscaler is opt-in and cosmetic**; saving always uses the server's PNG. Do not gate the reveal on any local enhancement.
15. **Push payloads carry no `chatId`** for media — keep `jobId → chatId` in the pointer table and do not evict it before the push can arrive (the TTLs above are the eviction rule).

---

## 14. Alignment with the existing Swift code (`ios/FirasAI`)

What the Codex-written app already has, and where it departs from the web behaviour above. Line numbers are in the
worktree's `ios/FirasAI/` tree.

**What exists**

- A standalone **Media Studio sheet**: `Features/Media/MediaStudioScreen.swift` (kind picker image / video / music, prompt field, lyrics field, aspect preset, duration picker), `Stores/MediaStudioStore.swift`, `Models/MediaStudioModels.swift`, strings in `Features/Media/Media.xcstrings` via `MediaStrings.swift` — title «إنشاء الوسائط», hero «حوّل الفكرة إلى مشهد», CTA «ابدأ الإنشاء», sign-in «سجّل الدخول للإنشاء», «حفظ في الصور», «مشاركة».
- Entry points: the chat "+" sheet lists three creation rows (`Features/Chat/AddContextSheet.swift:353-395`) → `ChatScreen.openMediaStudio(kind)` (`ChatScreen.swift:246-253`, sheet case `.media(kind, focusedJobID:)` `:6`); and a `job-terminal` push carrying `mediaKind` → `FirasAppShell.swift:228-237` → `MediaStudioStore.resumeNotificationJob(jobID:kind:)` (`MediaStudioStore.swift:58`) and the studio is presented focused on that job.
- Wire layer `Networking/FirasAPI.swift:381-475`: `startImageJob(prompt:preset:)` → `POST /api/image/job {prompt≤1000, w, h}`; `startVideoJob(prompt:seconds:)` → `{prompt≤2000, seconds 2…30}` (no `image`); `startMusicJob(prompt:lyrics:seconds:)` → `{prompt≤2000, lyrics≤6000, seconds 10…600}`; `mediaJobStatus(kind:id:)` → the three `GET …/job?id=`; `mediaAsset(kind:key:)` → `/api/image?key=`, `/api/video/file?id=`, `/api/music/file?id=`. Response structs `MediaJobStartResponse {ok?, jobId, phase?, key?}` and `MediaJobStatusResponse {phase, key?, error?, reason?}` match the wire (§3.3, §5.3, §6.6); `reason` is never sent by the server.
- Push handling: `NotificationCoordinator.swift:54-71` decodes `firas.mediaKind`; `:372-390` has per-kind local-fallback copy («صورة فِراس», «موسيقى فِراس», …); `MediaStudioStore.kind(forNotificationJobID:)` (`:47`) resolves `jobId → kind` from its own history.
- Save to Photos for image and video (`MediaStudioStore.saveToPhotos` `:184-206`; success «تم الحفظ في الصور.», permission refusal «اسمح لفِراس بإضافة الوسائط إلى الصور من إعدادات iPhone.»).

**Divergences this spec should drive out**

1. **Creations never become conversation turns.** They live in `UserDefaults` under `firas.ios.media-studio.history.v1`, per owner, capped at 24 (`MediaStudioStore.swift:21-22`), and no `firas-*` fence is ever written — so nothing reaches the gallery, sharing, the sidebar, other devices or the web. §12.2 asks for the opposite: a studio creation must land as a `firas-image` / `firas-video` / `firas-music` turn in a conversation.
2. **The iOS chat renders no media fence.** Only `firas-project` (`Models/CodeModels.swift:15`) and `firas-agent` (`Stores/AgentStore.swift:84`) are parsed; `firas-image` / `firas-video` / `firas-music` turns pulled from `/api/chats` show as raw fenced JSON. Implement §9's dispatch order and the three cards (§3.5, §5.2, §6.4).
3. **No in-chat routing.** Nothing classifies a typed «اصنع لي صورة…», so the iOS chat cannot create media at all; §1 (the `pro` classifier with the verbatim prompt, the branch order, the `unavailable` regex fallbacks) and §12.1 are unimplemented.
4. **No prompt pipeline.** The raw text goes straight to the server (`MediaStudioStore.swift:228`): no English rewrite (§3.1 step 4), no `pickImageShape`, no video rewrite with the photo / no-photo branches (§5.1 step 4), no lyric author and `STYLE:` parsing, no `musicStyleFor`. Worst case is music: the typed "prompt" is sent as ACE-Step **tags** (`FirasAPI.swift:416-436`), so an Arabic description typed there becomes a style field the engine cannot read — the web only ever puts English production tags in `prompt` and the words in `lyrics` (§6.1–6.3).
5. **Sizes and durations differ from the web.** `ImageAspectPreset` sends 1024², 1024×1280, 1280×720, 720×1280, 1280×640, 1280×853 (`MediaStudioModels.swift:35-66`); the web sends only 1024², 1024×1536, 1536×1024 (server clamp 1280, §3.1 step 5). Video picker `[5, 10, 15, 30]`, default 10 (`MediaStudioScreen.swift:19, 122`) — the web always sends `quota.seconds` (10). Music picker `[30, 60, 90, 180]`, default 90 (`:20, 208`; store fallback `?? 90` `:386`) — the web always sends 150, and anything long risks the 180 s engine wait (§6.6).
6. **Missing routes.** No `/api/image/edit` call (§4), no first-frame `image` on `MediaVideoJobRequest` (`MediaStudioModels.swift:76`, §5.1 step 6), no `POST /api/image/quota` pre-check (§3.1 step 2), no `GET /api/video/quota` read of `seconds` (§5.3).
7. **Polling has no deadline.** `MediaStudioStore.poll` (`:391-450`) backs off 1.5 → 2 → 3 → 4 → 6 s and deliberately never times out (`:403-404`). Because the server answers `running` for any id it has forgotten (§3.3, §13.4), a job lost to a restart polls for the life of the process. Adopt the web TTLs — image/video 20 min, music 10 min — as the terminal condition while keeping the pointer so a later status call can still find a cache hit.
8. **Failure copy is the store's own** (`localizedFailure` `:626-647`): `daily_limit` → «وصلت إلى حد إنشاء الصور اليومي.» for every kind, `rate_window` / `rate_limited` → «الإنشاء مزدحم الآن؛ حاول بعد قليل.» with no `freesInMin`, `site_media_ceiling` → «توقّف إنشاء الوسائط مؤقتاً لحماية الرصيد.». Replace with the web sentences in §3.7, §4.2, §5.2, §6.4 and §11, and add the `freesInMin` sentence the web itself lacks.
9. **Retry semantics.** `retry(_:)` (`:161`) re-creates with identical inputs, which is a server cache hit (identical bytes) once a render succeeded and a fresh render only after a `fail` (the job map replaces a failed record, `server.mjs:5167`, `4800`, `4924`). That matches the web's paid "Regenerate" for a *failed* card; the web's free first retry (reload the same URL, §3.5) has no equivalent and costs nothing to add.
10. **Songs cannot be saved**, only shared (`saveToPhotos` is image/video only); the web downloads all three kinds (§6.4 `تحميل`).
11. **Push → conversation.** The `jobId → kind` map exists; once creations live in conversations it must also yield the `chatId`, because the APNs payload carries none for media (§10).
