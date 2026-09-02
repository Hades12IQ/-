# Firas AI — web chat UX inventory (for the native iOS/iPadOS port)

Source of truth for this document: `app.js`, `index.html`, `styles.css` at the repo root (worktree
`firasai-ios-app-development-64ca7e`), plus `server.mjs` only where a client string depends on a
server response shape. Every claim carries a `file:line` citation. Arabic strings are copied
verbatim (UTF-8). Where the web code is *absent* (no feature), the section says so explicitly so the
Swift engineers do not invent one.

Conventions used below:

- `t()` is `STR[state.lang]` (`app.js:2704`); `STR` is the i18n table at `app.js:141` (ar) and
  `app.js:1264` (en). The appendix at the end lists every key in this slice, ar + en.
- **The shell layout direction is fixed LTR.** `applyShellLang()` sets `html.dir = "ltr"` on every
  language switch (`app.js:13697-13703`) even though `index.html:2` ships `dir="rtl"`. Only the
  *text* and fonts change with language; each message bubble/body stamps its own `dir` from its
  content (`app.js:22962`, `app.js:23894`). The native port must mirror this: chrome does not
  mirror, content does.
- UI language is auto-detected from the user's latest message (`app.js:44542`,
  `syncShellLangFromChat` `app.js:13752`) unless the user explicitly picked a language in Settings
  (`LS_LANG_EXPLICIT`, `app.js:13731`). Default on first boot: `navigator.language` starting with
  `en` → `en`, else `ar` (`app.js:3197`).
- Device preferences are in `localStorage` under `firas_ai_*` keys (`app.js:2395-2412`). Chats are
  server-side for members and `localStorage` (`firas_guest_chats`) for guests (`app.js:46891-46892`).

---

## 1. Entry flows (consent gate → landing → auth / guest → app)

### 1.1 First-run consent screen (`#seoIntro`, index.html:376-455)

Shown once to everyone (crawlers read it as the page). Key `firas_welcome_v1 === "1"` in localStorage
means already agreed (`index.html:440`). The app boots *behind* it and `dropSeoIntro()` only removes it
once agreed (`app.js:15143-15155`). The checkbox is never pre-ticked and the button is disabled until
ticked (`index.html:445-448`). Verbatim copy (Arabic only; there is no English version of this screen):

- H1: `أهلًا بك في فِراس AI`
- Lede: `منصّة ذكاء اصطناعي عربية أولًا من شركة مِنترونكس العراقية — مبنية للطلبة في العراق والعالم العربي.`
- H2 `أربعة منتجات بحساب واحد` with four bullets:
  - `محادثة فِراس — تفهم الفصحى واللهجات، مع بحث في الويب، ومكالمة صوتية، وتوليد الصور والفيديو والأغاني.`
  - `فِراس ايجنت — ينفّذ المهام الطويلة خطوة بخطوة، ويكمل شغله على الخادم حتى لو أغلقت الموقع.`
  - `فِراس كود — بيئة برمجة كاملة في المتصفح: تكتب وتشغّل وتنشر بلا تنصيب.`
  - `فِراس برين — ترفع كتبك وتسأل عنها، فيجاوبك من محتواها مع رقم الصفحة، ويقرأ الكتب المصوّرة بالرؤية.`
- H2 `ليش فِراس مختلف`: `العربية ليست ترجمة — التشكيل واللهجات والإعراب والمناهج، من الأساس.` /
  `كل معلومة موثّقة — الجواب يذكر صفحته لتتحقّق بنفسك.` / `يشتغل على هاتف بسيط — مصمّم لاتصال ضعيف وأجهزة متوسطة.`
- H2 `أسئلة سريعة`: `هل هو مجاني؟ نعم، تقدر تجرّبه وتنشئ حسابًا مجانًا مع حصّة يومية لكل منتج.` /
  `هل يفهم اللهجة العراقية؟ نعم — والخليجية والمصرية والشامية والمغربية، ويجاوب بها.` /
  `هل يقرأ كتابًا مدرسيًا مصوّرًا؟ نعم، يقرأ صفحات PDF المصوّرة ويجاوب من محتواها.` /
  `منو طوّره؟ شركة مِنترونكس العراقية، ومؤسّسها فِراس.`
- Gate: checkbox label `أوافق على شروط الاستخدام وسياسة الخصوصية.` (links `/terms`, `/privacy`),
  button `متابعة`, note `قد يخطئ فِراس. تحقّق من المعلومات المهمة.`

### 1.2 Boot decision (`app.js:79931-79975`)

Order: `?verify=` link → `?reset=&uid=` link → Google redirect → `?share=<id>` public page → then
`GET /api/auth/me`. A user → `bootApp(user)`. 401 → `resumeGuestIfActive()` (`firas_guest_active === "1"`
→ `POST /api/guest`, `app.js:79979-79991`) else `showLanding()`. Other errors → landing + toast
(`authNetworkError` if no HTTP status, else the server message).

`LS_HAD_SESSION` (`firas_had_session`, `app.js:47323`) is a hint that a session probably exists; if
set, the **MentronX intro** overlay plays while `/api/auth/me` runs (`mxIntroStart`, `app.js:46913`).
The intro is a monochrome line-drawn "M X" mark + `BY MentronX`, minimum 3150 ms (`MX_MIN_MS`), 900 ms
under reduced motion (`app.js:46910-46911`). It plays on the two "doors" (Get Started, sign-in) and on
a returning visit, and is cancelled in 80 ms on failure (`app.js:46938-46953`).

### 1.3 Landing (logged-out hero, `#landingScreen`, index.html:477-501; copy `app.js:15122-15132`)

- Mark + wordmark `Firas AI`; about text `landingAbout`; primary CTA `landingStart`
  (`ابدأ الآن — بدون حساب` / `Get Started — no account`) → `startGuestSession()` (`app.js:46958`);
  secondary `landingSignIn` (`لديك حساب؟ تسجيل الدخول` / `Already have an account? Sign in`) → auth screen;
  hint `landingGuestHint`.
- A four-mark "scale" (`landingScale`, `app.js:721-726` / `1814-1819`): `AI — محادثة`, `Agent — مهام كبيرة`,
  `Code — برمجة`, `Brain — وثائقك` (en: Chat / Big tasks / Building / Your documents). No user counters —
  the fabricated ones were removed (`app.js:15059-15069`).
- Details section (`app.js:15093-15118`): title `landingFeaturesTitle`, sub `landingFeaturesSub`, seven
  feature cards (`landingFeatures`, `app.js:729-741` / `1822-1830`), then an image-generation note with
  badge `landingImageBadge` (`تجريبي` / `Beta`), title `landingImageTitle`, body `landingImageBody`
  (mentions a 5-images/day limit — copy only; the real image limit is server-side).

### 1.4 Guest trial

`startGuestSession()` (`app.js:46958-46984`): disables the CTA, starts the intro, `POST /api/guest` →
`{user:{guest:true,...}}`; stores `firas_guest_active = "1"`; `bootApp(user)`. On failure: cancel intro,
show auth screen, toast `authNetworkError` (no status) or the server message.

Guest facts the UI depends on:
- `isGuest()` = `state.user.guest` (`app.js:46894`). `<html>` gets class `is-guest` (`app.js:47064`).
- Guest chats live only in `localStorage` `firas_guest_chats` (`app.js:46987-47005`); `serverId` is always null.
- Sidebar guest slot above the account pill (`renderGuestUi`, `app.js:47062-47084`): note
  `guestLocalNote` + bilingual CTA pill (`guestCtaHtml`, `app.js:47045`): main `signUpNow`
  (`سجّل الآن`), alt `signUpNowEn` (`Sign up now`) — in the English UI the two swap (`app.js:1789-1790`).
- Upsell modal `openSignUpPrompt(feature)` (`app.js:47087-47120`): title/body are
  `guestImageTitle/Body` when `feature === "image"`, else `guestFeatureTitle/Body`; buttons
  `guestUpgradeCta` (`إنشاء حساب مجاني`) → `goSignUpFromGuest()` (auth screen in signup mode, guest
  chats kept for migration) and `guestLater` (`لاحقًا`). Escape / backdrop closes.
- Members-only gates that call it: image generation, share (`app.js:79687`, `79716`), KB manager,
  redeem/plans, Agent missions (`agentAccountRequiredPrompt`, `app.js:59392`; also when
  `POST /api/chat/job` answers `account_required` / `signin_required` or 401/403, `app.js:59416-59422`).
- After sign-up, `migrateGuestChats()` POSTs each local chat to `/api/chats` then `DELETE /api/guest`
  (`app.js:47132-47153`); toast `guestMigrated` (`تم نقل محادثاتك إلى حسابك ✓`).
- `exitGuest()` (`app.js:47156-47168`): `window.confirm(guestExitConfirm)` → `DELETE /api/guest`, clear
  local keys, back to landing.
- Server guest allowances (`server.mjs:1133-1153`, env-overridable): ai 180, code 60, agent 24,
  brain 120, internal 300, voice 120 per day; guest cookie `firas_guest`, 7 days (`server.mjs:1131-1132`).

### 1.5 Auth screen and cookie banner

Auth screen markup `index.html:504-571` (email/password, optional Google, 6-digit code field, forgot/
resend/back). The **cookie banner** (`#cookieBanner`) is shown **only on the auth screen** and only until
a choice is saved in `firas_cookie_consent` (`accepted` | `rejected`) (`app.js:46659-46695`). Copy is
localized at runtime (`renderCookieCopy`, `app.js:46664-46678`):
- ar: `نستخدم الكوكيز لإبقائك مسجّل الدخول ولتحسين تجربتك. هل توافق؟` — buttons `أوافق` / `رفض`
- en: `We use cookies to keep you signed in and to improve your experience. Do you want to enable cookies?` — `Accept` / `Reject`
The choice has no functional effect on the client beyond hiding the banner.

### 1.6 `bootApp(user)` (`app.js:47171-47215`)

Sets `firas_had_session = "1"`, identity → `applyUserIdentity()`, guest UI, hides landing/auth,
`renderWelcome()`, migrates guest chats (members only), `fetchChats()`, `renderAll()`, reattaches all
background job kinds, focuses the composer, and fires `fetchAnnouncements()` for the bell badge.

---

## 2. Shell inventory (index.html:574-836)

- **Sidebar** `#sidebar` (268 px, `--sidebar-w`, styles.css:185): logo lockup, product switcher
  `#productSwitch` (menu of `PRODUCTS`, `app.js:59940-59947`: `Firas AI — المحادثة الذكية / Smart chat`,
  `Firas Agent — وكيل ينفّذ المهام الكبيرة / Executes big tasks`, `Firas Code — بيئة تطوير بالمتصفح مع مساعد ذكي /
  In-browser IDE with an AI assistant`, `Firas Brain — اسأل ملفاتك — بإجابات موثّقة بالصفحة / Ask your files —
  answers cited by page`; a `locked` product would show `قريبًا` / `soon`, none is locked today), New chat
  button (`newChat`), search field (`searchPlaceholder`), two saved shelves (`محفوظاتي` = `shelfTitle`,
  `قصاصاتي` = `snipTitle`, counts hidden until non-zero), history list, usage row, account pill.
- **Topbar** (56 px, `--topbar-h`): drawer/sidebar toggles, wordmark, tier picker (`#tierSelect` on phones
  ≤640 px, `#tierSwitch` strip on desktop — CSS shows exactly one, index.html:667-673), `#topbarNewChat`
  (`newChatShort` = `جديد`), gallery button `#galleryBtn` (hidden unless the chat has generated images,
  `syncGalleryBtn` `app.js:5865-5869`; title `gallery`), share `#shareChatBtn` (title `مشاركة المحادثة`),
  bell `#notifyBtn` (title `تحديثات الموقع`) with `#notifyBadge` dot. The theme toggle was moved into
  Settings (index.html:699).
- **Chat scroll** `#chatScroll` holding `#chatThread` and `#welcome`; scroll-to-bottom pill
  `#scrollBottomBtn`; jump-to-question pill `#jumpBtn` revealed once a chat has ≥3 questions
  (index.html:715-720).
- **Composer** `#composer` (see §7).
- **Voice call overlay** `#callScreen` (index.html:839-870) — out of scope here (see voice slice), but note
  starting a call blanks `state.think`/`state.mode` to false/auto and restores them after
  (`app.js:49979-49987`, `50077-50079`).
- Live region `#liveRegion` (sr-only, `aria-live=polite`): receives `streaming` text
  (`يكتب فِراس...` / `Firas is typing…`) while streaming (`app.js:43958`, `43963`).

---

## 3. Tier picker (mini / pro / ultra / max)

### 3.1 The MODELS table (`app.js:27-135`) — user-facing fields

| key | label ar | label en | tagline ar | tagline en | short ar | short en | showThinking | max_tokens |
|---|---|---|---|---|---|---|---|---|
| mini | `فِراس ميني` | `Firas Mini` | `سريع للأسئلة اليومية` | `Fast for everyday questions` | `ميني` | `Mini` | false | 2048 |
| pro | `فِراس برو` | `Firas Pro` | `متوازن وذكي` | `Balanced & smart` | `برو` | `Pro` | true | 16384 |
| ultra | `فِراس أولترا` | `Firas Ultra` | `قويّ جدًا — الأفضل للأكواد` | `Very powerful — best for code` | `أولترا` | `Ultra` | true | 16384 |
| max | `فِراس ماكس` | `Firas Max` | `الأقوى — أعلى ذكاء وتفكير` | `Strongest — top intelligence` | `ماكس` | `Max` | true | 16384 |

`transport`, `persona`, `reasoning_effort`, `temperature` are internal and never rendered.
Default tier: `CONFIG.DEFAULT_TIER = "pro"` (`app.js:16`). Icons: `TIER_ICON = { mini: zap, pro: bolt,
ultra: star, max: crown }` (`app.js:2343`; SVG paths at `app.js:2318-2326`).

Dropdown-only badges `TIER_BADGE` (`app.js:15268`): max → `الأقوى` / `Strongest`; ultra → `للأكواد` /
`For code`.

### 3.2 Locks and caps

- **No tier is locked to a plan.** `PLAN_LIMITS` are all `-1` (unlimited) for free/gold/diamond/unlimited
  (`server.mjs:1347-1357`); the client comment says "Max is now FREE & UNLIMITED for everyone — no daily
  cap, no pre-check" (`app.js:42606`, `app.js:118`). The plan card in Settings reads
  `✦ مجاني بالكامل` / `Free — everything included` with body
  `كل مزايا فِراس متاحة للجميع مجانًا. يحصل كل حساب على ٥٠٠ كريديت في Firas Agent تتجدد يوميًا.` /
  `Every Firas feature is available free. Each account receives 500 Firas Agent credits refreshed daily.`
  (`app.js:45344-45351`). Plan colour tokens still exist: `--plan-gold #B8862A` (dark `#D8B45A`),
  `--plan-diamond #3E7CB1` (dark `#8FB4E0`) (styles.css:5415-5416).
- **Max daily cap UX (legacy, keep the strings):** `POST /api/max/quota` now returns
  `{ok:true, limit:0, used:0, remaining:-1}` (`server.mjs:3227-3231`), and the client no longer
  pre-checks. `maxLimitText(lang, q)` (`app.js:6454-6462`) is only rendered if a 429 on a Max turn carries
  `limit` or an error matching `/daily Max/i` (`app.js:42708-42713`):
  - auth: `🔒 يجب تسجيل الدخول لاستخدام فِراس ماكس.` / `🔒 Please sign in to use Firas Max.`
  - limit (default 10): `👑 لقد وصلت إلى حدّك اليومي من فِراس ماكس (١٠ رسائل في اليوم). استخدم أولترا أو برو الآن، وسيتجدّد ماكس غداً.` /
    `👑 You've reached your daily Firas Max limit (10 messages per day). Use Ultra or Pro for now — Max resets tomorrow.`
  - `maxRemainingText`: `فِراس ماكس • تبقّى لك {remaining} من {limit} اليوم` / `Firas Max • {remaining} of {limit} left today` (`app.js:6483-6488`, unused today).
- Firas Agent always runs on Max regardless of the picker (`app.js:44576`), so the pin control is hidden
  there (`app.js:15655-15660`).

### 3.3 Controls and persistence

- `setTier(key)` (`app.js:15337-15364`): validates against `MODELS`, writes `firas_ai_tier`, rebuilds the
  phone dropdown, toggles `.is-active`/`aria-selected` on strip buttons, re-adds the `just-activated` class for
  700 ms (`app.js:15355`) which plays the 0.42 s CSS `tierPop` animation (styles.css:835; Max also `maxGlow`), then `applyThinkAvailability()` (hide the
  Think toggle when `!showThinking`, i.e. on Mini — `app.js:15368-15372`), `applyThink()`, and re-syncs
  the composer length meter.
- Strip button: icon + `short[lang]`, `title = tagline[lang]`, `role=tab` (`app.js:15248-15263`).
- Phone dropdown (`buildTierSelect`, `app.js:15271-15306`): trigger shows icon + short name + chevron;
  listbox rows show icon, `label[lang]`, optional badge, and `tagline[lang]` as hint. Escape closes and
  refocuses the trigger; outside click closes.
- Strip colours (styles.css:754-851): container `--color-bg-subtle` with hairline border, 32 px tall,
  radius `--radius-sm` (3 px); active = `--color-surface` + `--shadow-xs`; **Ultra** active =
  `--color-accent-soft` bg, `--color-accent` text, 6 px accent dot before the name; **Max** dot `#8b5cf6`,
  hover/active text `#7c3aed`, active bg `rgba(139,92,246,0.13)`, dot pulses (`maxDotPulse`); an optional
  `.tier-beta` badge style exists (`#a78bfa` on `rgba(139,92,246,.16)`) but nothing renders it today.
- Settings → Chat tab → "Default model" (`modelH`: `النموذج الافتراضي` · `للمحادثات الجديدة`) is the same
  `setTier` with toast `modelSet` (`تم تعيين النموذج الافتراضي ✓`) (`app.js:45724-45727`, `46063-46065`).

### 3.4 Per-conversation model pin ("tpin", `app.js:15374-15741`)

Desktop-only (≤640 px phones, UI 2.0 and the share page get nothing, `app.js:15641-15652`). A chip after
the strip (`#tierPin`, hairline while unpinned, accent when pinned) opens a listbox of the four tiers
(label + tagline + a per-tier count of answers in this chat, `tpinLedger`) plus `tpinNone`/`tpinNoneHint`.
Stored in `firas_ai_chat_tier` as `{ [serverId]: {tier, ts} }`, LRU 60 (`CHAT_TIER_MAX`), keyed by server
id (re-keyed from the local uid once, `tpinKey`). Applying a pin moves the strip **without** changing the
device default (`tpinApply` restores `firas_ai_tier`, including its absence, `app.js:15472-15482`).
Picking a tier from the strip while a chat is pinned retargets the pin (`app.js:15724-15741`). Toasts:
`tpinSet` (`هذه المحادثة تبقى على {name}`), `tpinCleared`. Only chats with ≥1 message, not Agent/Code/Brain.

---

## 4. Think toggle (`#thinkToggle`)

- Lives in the composer's "+" tools menu (`#toolsMenu`, index.html:759-780) together with Web search and
  the dictation-language row; the "+" trigger gets `has-active` when either toggle is on
  (`app.js:15216-15218`). Also mirrored in Settings → Chat → "Reply behaviour" (`thinkLbl`
  `التفكير العميق` · `أبطأ وأدقّ في المسائل الصعبة`, `app.js:45642`, `45835`).
- State `state.think`, default **false**, persisted as `firas_ai_think` = `"true"|"false"`
  (`app.js:2502`, `3188-3189`, `15196-15201`). A device that never touched it reads off.
- Visual: `role=switch`, `aria-checked`, class `is-on`; `title` = `thinkOn` (`التفكير مُفعّل — دقة أعلى`) or
  `thinkOff` (`التفكير مُعطّل — استجابة أسرع`) (`app.js:15181-15195`). Hidden entirely on Mini
  (`applyThinkAvailability`). Max **does** think now; `thinkMaxBlocked` is a dead string
  (`app.js:15183-15188`).
- **Effect on the request:** the chat job body carries
  `think: aiMsg.think && rtModel.showThinking` (`app.js:42624`), where `aiMsg.think = state.think`
  (`app.js:41551-41553`). Server-side this raises reasoning effort (comment `app.js:2499`). Internal helper
  calls always send `think:false, nomem:true` (`app.js:38818`).
- **Reasoning panel:** an assistant turn shows the collapsible `thinking` disclosure only when
  `tier.showThinking && msg.think !== false && msg.reasoning.trim()` (`app.js:23886-23889`).
  `thinkingEl` (`app.js:23964-23986`): a button head with the word `thinking` (`التفكير` / `Thinking`) and a
  chevron that rotates 90° when open; body is plain text (`textContent`), max-height 600 px when open
  (styles.css:1576-1602). Closed by default. `msg.reasoning` and `msg.think` are persisted per message
  (`app.js:3519`, `3572`).

---

## 5. Web search toggle (`#searchToggle`)

- Same tools menu; `role=switch`; `state.webSearch` default false, persisted `firas_ai_websearch`
  (`app.js:2503`, `3190`, `15202-15214`). Title: `searchOn` (`بحث الويب مُفعّل — يبحث في كل رسالة`) /
  `searchOff` (`بحث الويب تلقائي — يبحث عند الحاجة`). Label `webSearch` (`بحث الويب`). Settings mirror:
  `webLbl` `البحث في الويب` · `يبحث قبل كلّ ردّ`.
- **It is not a request field.** The client itself decides per turn (`app.js:42440-42499`, skipped in
  plan mode and on image turns):
  - `explicitSearch = state.webSearch || needsWebSearch(text)`; `silentSearch` when a factual question
    benefits from it; i'rab (`إعراب`) requests always search.
  - It calls `GET /api/search?q=<first 280 chars>` (`fetchWebSearch`, `app.js:41031`) with an 8000 ms budget
    for explicit searches and 1500 ms for silent ones (`app.js:42471`).
  - The indicator `يبحث في الإنترنت…` / `Searching the web…` (rendered via `buildFileLoadingHtml`, three
    dots + label) follows `showIndicator = (isIrab || silentSearch) ? (!silentSearch && !!state.webSearch) : true`
    (`app.js:42460-42464`): an explicit search always shows it; an i'rab lookup shows it only while the
    toggle is on; a silent search never shows it.
  - Results are injected as a **user-role** message right after the system prompt (`app.js:42480`). On an
    explicit (non-silent, non-i'rab) search **every tier except Max is switched to Pro for that turn**
    (`if (!isIrab && !silentSearch && requestTier !== "max") requestTier = "pro"`, `app.js:42489`) — Mini
    and Ultra alike; Max stays Max; silent searches never change the tier. If the toggle is on, it is not
    an i'rab turn, and nothing came back, a **system-role** note is inserted instead
    (`app.js:42490-42497`): ar `تنبيه: لم تُرجع نتائج بحث ويب لهذا السؤال؛ أجب من معرفتك العامة وأخبر المستخدم أنه لم تتوفر نتائج ويب حيّة.` /
    en `Note: no live web results were found for this query; answer from general knowledge and tell the user that no live web results were available.`

---

## 6. Mode switch (Auto / Plan, `#modeSwitch`)

- `MODES` (`app.js:2364-2367`): `auto` (icon lightning, `modeAuto` `تلقائي` / `Auto`, hint `modeAutoHint`
  `ذكي ومباشر — يجيب فورًا.` / `Smart & direct — answers right away.`) and `plan` (clipboard icon,
  `modePlan` `تخطيط` / `Plan`, hint `modePlanHint` `يسأل ويضع خطة، ثم ينفّذ بعد موافقتك.` /
  `Asks & plans first, then executes once you approve.`).
- State `state.mode`, default `auto`, persisted `firas_ai_mode` (`app.js:2492`, `3165-3166`, `15854-15860`).
- UI: compact trigger (icon + label + caret, `title` = hint) in the composer bar; a `role=menu` of
  `menuitemradio` rows (icon, label, hint, check) with Arrow/Enter/Escape/Tab handling
  (`app.js:15752-15853`). Menu aria-label `modeLabel` (`النمط` / `Mode`).
- Effect: every new assistant message is stamped `mode: state.mode` (`app.js:44577`). In plan mode the
  client adds a plan system prompt and disables file/code/image routers until approval
  (`app.js:38149`, `41596-41606`). A finished plan-mode reply shows the **Start pill**
  (`planStartEl`, `app.js:29268-29285`): `planStart` (`ابدأ التنفيذ` / `Start`), title `planStartHint`;
  clicking puts `planApproval` (`ابدأ التنفيذ ونفّذ الخطة.` / `Go ahead and execute the plan.`) in the
  composer and sends it (`approvePlan`, `app.js:29597-29602`). The Start pill is suppressed on a
  `firas-ask` turn and on the delivery turn that follows approval (`shouldShowPlanStart`,
  `app.js:29640-29651`; `precededByApproval` also accepts hand-typed `ابدأ|نفّذ|نفذ|go ahead|execute|start|proceed`).
- Clarifying questions arrive as a ```` ```firas-ask ```` JSON block (≤4 questions, 2–5 options each,
  optional `multi`, `recommended`) rendered as a card of radios/checkboxes with `askRecommended`,
  `askContinue`, `askBack`, `askSubmit`, `askStep`, `askExtraPlaceholder`, `askAnswered`, `askMyChoices`,
  `askPreparing` (`normalizeAskSpec`/`parseFirasAsk`, `app.js:29298-29343`; strings `app.js:649-657`).

---

## 7. Composer

### 7.1 Layout and text entry (index.html:721-835)

Row 1: `<textarea id="input" rows=1>` placeholder `composerPlaceholder` (`اسأل فِراس...` / `Ask Firas…`);
in Agent product the placeholder becomes `كلّف فِراس بمهمة صعبة` / `Give Firas a hard task`
(`app.js:59959-59968`). Row 2 leading: attach, tools "+", mode dropdown; trailing: mic, call, send/stop.
Below: hint line `disclaimer` (`قد يخطئ فِراس. تحقّق من المعلومات المهمة.`). Drop veil `#composerDrop` with
`dropToAttach` (`أفلت الملفات هنا للإرفاق`; Agent: `agentDropToAttach`). Card: `--color-surface`, hairline
border, radius `--radius-xl` 9 px, `--shadow-composer`; focused adds `--shadow-focus` ring (styles.css:6579-6597).

- `autoGrow()` caps the textarea at **152 px** (`app.js:36387-36390`).
- Direction: empty box follows UI language; with content, `detectLang(value)` decides; `text-align:start`
  (`syncComposerDir`, `app.js:36399-36411`).
- **Enter behaviour** (`app.js:50616-50630`): default Enter = newline. `state.enterSend` (Settings →
  Chat → `enterLbl` `الإرسال بمفتاح Enter` · `و Shift+Enter لسطر جديد`, persisted `firas_ai_enter_send`
  `"1"/"0"`, default off, `app.js:3180-3183`, `14126-14132`) makes Enter send and Shift+Enter newline.
  Ctrl/Cmd+Enter always sends. `e.isComposing` (IME) never sends. Form submit while streaming = Stop.
- `updateSendState()` (`app.js:36417-36424`): Send enabled when text or a ready image/file exists and no
  attachment is still being read (`readingImages > 0` disables). While streaming the button becomes Stop
  (`is-stop`, aria-label `stop`) or disabled if the stream is visual-only (`app.js:43954-43969`).
- Send animation: `send-pulse` class for 440 ms (`app.js:44537-44538`).
- **Length meter** (`app.js:36426-36475`): silent under 400 chars (`LENM_SHOW_AT`); shows `lenmChars`,
  `lenmTokens`; `over = tok > cap`, `near = !over && tok >= round(cap * LENM_NEAR)` with `LENM_NEAR = 0.8`
  and `cap = LENM_TIER_TOKENS[state.tier] || 16000`, `LENM_TIER_TOKENS = { mini: 4000, pro: 16000,
  ultra: 16000, max: 24000 }` (`app.js:36456-36460`, `36502-36505`; labels `lenmNear`/`lenmOver` with
  `{m}` = the tier short name); the tooltip `lenmTip` names the hard cut `LENM_HARD_CHARS = 200000`.
- **Slash commands** (`initSlashMenu`, `app.js:50365-50422`; strings `app.js:1034-1046`): typing `/`
  opens `slashTitle` (`أوامر سريعة`) with four rows — Summarize (`slashSumL/H/P`), Translate
  (`slashTrL/H/P`), Explain (`slashExpL/H/P`), Review (`slashRevL/H/P`); the `P` string replaces the token.
  Arrow keys move, Enter/Tab accept, Escape closes; modified keys are passed through.
- **Quote pills / select-to-ask** (`selAskChip`, `quotePillHint`, `quoteLeadN`, …): a highlighted passage
  of an earlier answer can be attached to the next question; the fenced passage is prepended at send
  (`quotePrefix`, `app.js:44419-44421`) and cleared once committed (`app.js:44462`).
- **Difficulty ladder** (`app.js:36874-36967`): 7 rungs, default 5, per-chat (`firas_ai_difficulty`):
  1 `تأسيس`/Foundation, 2 `تمرين`/Drill, 3 `منهجي`/Standard, 4 `تحليلي`/Analytical, 5 `متقدّم`/Advanced,
  6 `تنافسي`/Competition, 7 `أولمبي`/Olympiad (hints in `arHint/enHint`). The composer pill was removed
  (`dfxMount` now only removes it, `app.js:37279-37282`); what remains is (a) the chooser card
  `dfxAskGate` shown before sending a problem-set request (`dfxAskTitle`, `dfxAskNote`, `dfxAskSkip`;
  gate at `app.js:44459`) and (b) "harder/easier" phrases in a message moving the level with a toast
  (`dfxUp`/`dfxDown`/`dfxTop`/`dfxBot` + `dfxUndo`, `app.js:44514-44517`).

### 7.2 Drafts (`app.js:12961-13039`)

One localStorage key `firas_ai_drafts` = `{ [chatId | "new:<product>"]: {text, ts} }`, LRU 30
(`DRAFT_MAX`), text capped at 20 000 chars. Saved 400 ms after input (`saveDraftSoon`), and immediately
on chat switch, `pagehide`, and `visibilitychange:hidden`. `restoreDraft()` runs on chat open before the
streaming-UI sync. An emptied box deletes the draft. Never written for a temporary (ephemeral) chat.
`clearDraft()` on send also drops the `new:<product>` sentinel.

### 7.3 Attach tray (`app.js:35893-36234`, index.html:727-730)

- Single hidden `<input type=file multiple>` with
  `accept="image/*,application/pdf,.pdf,.docx,.pptx,.xlsx,.xlsm,.txt,.md,.markdown,.csv,.tsv,.json,.jsonl,.xml,.yml,.yaml,.html,.htm,.css,.scss,.js,.jsx,.mjs,.cjs,.ts,.tsx,.py,.java,.c,.h,.cpp,.cc,.hpp,.cs,.go,.rs,.rb,.php,.swift,.kt,.sql,.sh,.bash,.ini,.toml,.env,.log,.tex,.srt,.vtt,text/*"`.
  **There is no dedicated camera or gallery button and no `capture` attribute** — the OS picker decides.
  The attach button title is `attachHint` (`إرفاق ملف`), or `agentAttachHint` in Agent (`app.js:59980-59984`).
- Also accepted via **paste** of any file item (`app.js:50661-50666`) and **drag-drop** onto the chat
  scroll / composer (`app.js:50668+`).
- Dispatch `handleFiles` (`app.js:36077-36085`): `image/*` → image path; PDF (`application/pdf` or
  `.pdf`), Office (`.docx .pptx .xlsx .xlsm` by extension only), text/code (`text/*`, json/xml/js/ts/csv/
  yaml/sh/python MIME, or `CODE_EXT` list `app.js:35917`) → document path; anything else → toast
  `نوع ملف غير مدعوم` / `Unsupported file type`.
- **Images** (`handleImageFiles`, `app.js:36139-36169`): `MAX_IMAGES = 10` (toast `الحد الأقصى ١٠ صور` /
  `Max 10 images` — note the code interpolates `10` as a Latin digit: ``الحد الأقصى ${MAX_IMAGES} صور``);
  decoded via `<img>`, downscaled so the longest edge ≤ **1568 px** (`MAX_EDGE`) and re-encoded
  **JPEG q=0.85** (`downscale`, `app.js:36057-36068`); thumbnail longest edge 256 px JPEG q=0.7. Sent as
  raw base64 with `mime: "image/jpeg"` (`item.full`); thumbs persisted on the user message as
  `imageThumbs` (`app.js:44483-44484`). Decode failure → `تعذّر قراءة الصورة` / `Couldn't read image`.
  A follow-up that "refers to the prior image" (`refersToPriorImage`, `app.js:35906-35910`) silently
  re-attaches the last images of that chat (in-memory only).
- **Documents** (`handleDocFiles`, `app.js:36088-36132`): `MAX_FILES = 5` (`الحد الأقصى ٥ ملفات` /
  `Max 5 files`, again Latin digit interpolated), `MAX_FILE_CHARS = 120000` per file,
  `MAX_TOTAL_FILE_CHARS = 300000` total (`حجم الملفات كبير جداً` / `Files too large`). PDF text via lazy
  pdf.js 3.11.174, first **60 pages** max (`app.js:35993`). Office files are extracted client-side into
  `[Section n]` / `[Slide n]` / `[Sheet n]` marked blocks (`OFFICE_UNIT`, `app.js:35941`). Empty text →
  `ما كدرت أقرأ نص من الملف` / `No readable text in file`; read failure → `تعذّر قراءة الملف` /
  `Couldn't read file`. If truncated, the chip gets `is-cut` and a tooltip/toast
  `الملف كبير — أُرسل نحو {pct}٪ من محتواه فقط. للمستند الكامل استخدم فِراس Brain.` /
  `File is large — only about {pct}% of it was sent. Use Firas Brain for the whole document.`
  Filenames are clipped to 80 chars. On send, text goes as `userMsg.fileText` with a
  `===== FILE: name =====` framing and marker explanation (`app.js:44492-44507`); persisted chips are
  `files: [{name, kind}]` where kind ∈ `pdf | docx | pptx | xlsx | code`.
- Tray rendering (`renderAttachTray`, `app.js:36183-36234`): image cells (`attach-thumb`, `is-loading`
  skeleton, × remove button labelled `delete`), file chips (`attach-file` with a kind tag from
  `brainKindTag`: `PDF`, `DOC`, `PPT`, `XLS`, `IMG`, `TXT` — `app.js:81209-81212`, and the name, or `...قراءة` /
  `reading…` while loading).
- Sending with attachments but no text titles the chat `صورة` / `Image` or the first file name
  (`app.js:44465-44467`).

### 7.4 Send, undo-send, outbox

- `sendMessage()` (`app.js:44417-44570`): refuses while the active chat streams or attachments are
  reading; guest in Agent → sign-up prompt; one live Agent mission at a time (toasts at
  `app.js:44441-44449`); aborts streams of *other* chats; pushes `{role:"user", content, lang, tier}` (+
  images/files); first user message sets a provisional title (`titleFrom`: first 42 chars + `…`,
  `app.js:13327-13330`) and fires `autoTitleChat`; clears composer/tray/draft; shell language follows the
  message unless explicit; renders immediately; creates the server chat (`POST /api/chats`) on the first
  message; arms undo; `runAssistant`.
- **Undo send** (`app.js:44036-44158`): only on desktop (>640 px), not UI 2.0, not on a chat's first
  turn, text-only sends, and only while the reply is still streaming; toast `undoSend`
  (`أُرسلت رسالتك — التراجع يعيدها ويوقف الردّ`) with button `undo` for 6 s (`SEND_UNDO_MS`). Taking it
  stops the stream, removes the message (+ its placeholder answer), restores the text.
- **Outbox** (`app.js:44160-44260`): when a send fails offline with zero streamed tokens and no server
  job pointer, the chat is marked in `firas_outbox` and a strip appears where the answer would be:
  `outboxHeld` (`لم تُرسَل رسالتك — لا يوجد اتصال. سنرسلها فور عودته.`) → on reconnect `outboxReady`
  (`عاد الاتصال — رسالتك لم تُرسَل بعد.`) with button `outboxSend` (`أرسلها الآن`).
- **Stop** (`stopStreaming`, `app.js:43998-44034`): aborts the fetch and, if a job id is stored under
  `firas_job_<chatId>`, POSTs `/api/chat/cancel {id}` with `keepalive`. Closing the app must *not* cancel.
- Chat request body (job path, `app.js:42624-42636`): `{ messages, tier, think, cid, product:"ai",
  chatId, nokb }` plus `kind:"longdoc", sections, lang, task` when `LONGDOC_RE` matches
  (`app.js:41507`). Members without `serverId` and temporary chats use plain streaming; guests always use
  the job path (`app.js:42646`). 429 handling: `j.quota` → `quotaLimitText`; Max cap → `maxLimitText`;
  else `طلبات كثيرة بسرعة — انتظر لحظة ثم حاول مجددًا.` / `Too many requests too fast — wait a moment and try again.`
  (`app.js:42701-42720`).
- 15-minute client timeout per turn (`app.js:41536`). Interrupted turns auto-resume when the app is
  foreground + online (`resumeQueue`, `app.js:2522-2529`) and finished server answers are adopted if
  "better" than the local copy (`refreshChatFromServer`, `app.js:2537-2558`).

---

## 8. Message rendering

### 8.1 User turn (`userTurnEl`, `app.js:22956-23037`)

`.msg-user__bubble`: max 80 % / 544 px wide, fill `--user-fill` (accent-deep mixed 90 % with surface;
94 % on dark), white ink `--user-ink #FFFFFF`, edge `--user-edge` (accent at 40 %), radius
`--soft-radius 20px`, top sheen (styles.css:6443-6478, 6510-6515). Contents in order: image thumbnails
grid (click → lightbox with full-res if still in memory, title `اضغط للتكبير` / `Click to enlarge`), file
chips (`msg-file-chip` = kind tag + name; tapping arms "ask about this file" → `askFileChip`), then the
text (`white-space: pre-wrap`, collapsed after **12 lines** with `showMore`/`showLess` via `tclamp`,
`app.js:23026-23031`), and KaTeX typesetting of the user's own `$…$` (`app.js:23032`). Text selection is
disabled; **long-press / right-click opens a Copy menu** (`attachCopyMenu`, `app.js:23035`). There is
**no edit-and-resend and no reactions** on user turns (nothing in the codebase); the closest features
are "Ask again" (§9) and Undo send (§7.4).

### 8.2 Assistant turn (`aiTurnEl`, `app.js:23834-23962`)

Order inside `.turn.msg-ai`:
1. Version pager `.ans-vers` if the turn has ≥2 versions (§10).
2. Head: avatar (Firas mark, 24 px rounded square on accent gradient, styles.css:985-996), name `Firas`
   (or `Firas Agent` in agent chats, no badge), and the **tier badge** `msg-ai__badge` = `short[lang]`
   uppercased with `data-tier`. Styles: muted text by default; Ultra = accent pill with 6 px dot; Max =
   purple pill `#7c3aed` (dark `#a78bfa`) with dot (styles.css:1003-1040).
3. Retry-pair strip when the answer was escalated (`retryPairStripEl`; strings `retryStronger`,
   `retryWasRetried`, `retryCompare`, `retryGoOld`, `retryGoNew`, `retryGone`).
4. Thinking disclosure (§4).
5. Body `.msg-ai__body[dir]` → `.md`. Card dispatch by fenced meta blocks, first match wins
   (`app.js:23897-23930`): `firas-agent` → agent card; `firas-deck` → slide deck card; `firas-project` →
   multi-file project card; `firas-image` → image card; `firas-music`; `firas-video`; `firas-code` →
   code deliverable card (+ intro/outro prose); a file-request reply → collapsed `file-disclosure`
   (`fileViewContent` `عرض المحتوى` summary) with the markdown inside; otherwise
   `renderMarkdown` → `decorateMarkdown` → `decorateFirasAsk` → checklist ticks (`tdoDecorate`) →
   arithmetic check (`mckDecorate`) → `typesetMath`.
   Optional chapter bar above `.md` for long answers (`chpBar`, `chpPrev`, `chpNext`).
6. File card (§8.5) for file-request replies.
7. Plan Start pill (§6).
8. Quick-reply chips (`qreplyEl`, `app.js:26479-26530`): topics lifted from the answer's headings/bullets;
   each chip inserts `qreplyAsk` (`اشرح لي «{q}» بتفصيل أكثر`) into the composer. Hidden on card turns,
   truncated answers and plan turns.
9. Action row (§9).

Prose typography: `--font-serif` (Archivo/Reem Kufi) 17/29 for LTR; Arabic bodies use `--font-arabic`
(Noto Sans Arabic) with line-height 1.9 (styles.css:1043-1050). Reading measure 704 px (`--reading-w`),
920 px when Settings → "Reading width" = wide (styles.css:6445, 6487). Reading size setting scales
`--read-scale` 0.92 / 1 / 1.14 (styles.css:3512-3514).

### 8.3 Markdown pipeline

- `marked@12.0.2` + `DOMPurify@3.0.11` loaded eagerly; KaTeX 0.16.11 (+ mhchem + auto-render) and
  highlight.js 11.9.0 (github theme) load lazily after first paint and re-render when they arrive
  (index.html:273-310). Math is scanned by the single authority `scanMathSpans` (see
  `.claude/skills/math-rendering`); failed KaTeX parses fall back to Unicode text marked `.katex.math-fallback`
  (`app.js:7819-7838`). External links open in a new tab with `noopener` (`app.js:7660-7662`). TikZ figures
  render via `scheduleTikz` (`app.js:7663`). Tables, blockquotes, lists are standard markdown.
- **Code blocks** (`app.js:7574-7657`): `.code-block` with a head showing the language tag
  (`language-xxx` class, or `code`), then buttons: **Preview** (`preview` `معاينة`) only when
  `canPreviewCode(lang, code)` (HTML/Markdown/SVG/JSON/CSS/JS render, Python runs — `app.js:6839-6841`),
  **Copy** (`copyCode` `نسخ` → `copied` `تم النسخ` for 1400 ms; failure toast `copyFailed`), and **Save**
  to the code shelf (`snipSave` `احفظ` → `snipSaved`; toasts `snipSavedToast`, `snipDupe`, `snipFull`,
  `snipFail`; not on the share page). There is **no "Run" button** in chat code blocks — Preview is the
  run surface (`openCodePreview`, a full-screen panel).
- Structured Agent step fences (`firas-sources`, `firas-pair`, `firas-review`, `firas-decision`,
  `firas-proof`, `firas-dataset`, `firas-critique`, `firas-schedule`, timeline, checklist, cards, quiz,
  map, …) are drawn as cards instead of JSON (`app.js:7565-7572`) — documented in the agent slice.

### 8.4 Streaming indicators

- The live turn gets `.is-generating` (mark arms animate, styles.css:11462-11464; quick replies hidden,
  styles.css:1833) and its `.md` gets `.stream-caret` (2 px accent bar pulsing 1 s, styles.css:1052-1060;
  `app.js:22256`). Under `data-motion="off"` all of these animations are disabled (styles.css:3754-3772).
- Before the first token, stage loaders replace the body: `buildFileLoadingHtml(label)` = three glowing
  dots + label (`firas-ask-loading`, `app.js:3823-3832`). Labels: `fileCreating`
  (`جاري إنشاء الملف…` / `Creating your file…`) and per-stage `fileStageText` (`app.js:38799-38807`):
  extract `يقرأ الصورة ويستخرج كل المحتوى…`, plan `يخطّط لهيكل الملف…`, content `يكتب المحتوى…`, validate
  `يراجع الدقة والبنية والمعادلات…`, assemble `يجمّع ويُخرج باحتراف…`; search `يبحث في الإنترنت…`;
  attachments `يقرأ المرفقات…` / `Reading attachments…` (`app.js:51688`); code card `يكتب الكود…` /
  `Writing code…` (`app.js:6760`).
- Thread-level loader `.thread-loading` (three 8 px dots, `thread-glow`, styles.css:3412-3430) while a
  chat's messages load; sidebar uses shimmer skeleton rows (`showHistorySkeleton`, `app.js:15880-15889`).
- Paint loop: settled-prefix + live-tail incremental render at ~55 ms cadence (`app.js:43382-43400`).
- **No completion sound and no completion haptic exist.** The only `navigator.vibrate` call is a 10 ms
  buzz on long-press of a Firas Code file row (`app.js:75183`); `AudioContext`/`new Audio` are used only
  by TTS and the voice call. `document.title` is changed only during file export (`app.js:31907`). No
  Notification API usage.

### 8.5 File cards (`fileCardEl`, `app.js:29664-29703`; meta `fileFormatMeta`, `app.js:3015-3024`)

Shown under a reply that answered a document request (`isFileStreamReply`, `app.js:3120`). Card =
format icon (`data-fmt`), AI-chosen filename (fallback `fileNamePdf` `firas-document.pdf`, `fileNameDocx`,
`fileNameXlsx` `firas-data.xlsx`, `fileNamePptx` `firas-presentation.pptx`, `fileNameCsv`), label
(`fileLabelPdf` `مستند PDF`, `fileLabelDocx` `مستند Word`, `fileLabelXlsx` `جدول Excel`, `fileLabelPptx`
`عرض PowerPoint`, `fileLabelCsv` `ملف CSV`), a **Download** button (`fileDownload` `تنزيل`) and, for pptx,
a **Present** button (`اعرض` / `Present`). The whole card is clickable/keyboard-activatable. Download
runs the matching *client-side* exporter over the rendered markdown (`exportPdf` / `exportWord` /
`exportExcel` / `exportPpt` / `exportCsv`) — the server does not serve these files; libraries lazy-load
and on failure a toast appears (`app.js:29705-29711`). Mobile/in-app browsers get a "Save" button because
`<a download>` is unreliable there (`FIRAS_DL_MOBILE`, `app.js:29718-29747`). Aria: `fileReady` — name.

### 8.6 Code deliverable card (`buildCodeCard`, `app.js:6732-6769`; actions `app.js:6787-6894`)

`.code-card` (always LTR): head with three dots, filename, language label, line count, and actions:
**Wrap/No wrap** (`لفّ الأسطر` / `لا تلفّ`, remembered in `firas_code_wrap`, default wrapped when any
line > 140 chars), **Preview** (`معاينة`, only when previewable; a *freshly finished* complete HTML page
auto-opens its preview), **Copy** (`نسخ` → toast `تم نسخ الكود` / `Code copied`), **Download**
(`تحميل`), **Continue** (`كمّل` / `Continue`). Footer bar: `الكود غير مكتمل؟` / `Code cut off?` +
`كمّل الكود` / `Continue code`. While streaming: `يكتب الكود…`.

### 8.7 Agent card and Brain citations (brief; see their slices)

- Agent runs render `buildAgentCard` (`app.js:53322`) = `fcPanelEnsure/fcPanelPatch` live panel with
  plan checklist, tool rows, files, elapsed clock, plus `agent-card__report` (`تقرير المهمة` /
  `Task report`), `agent-card__final` (`النتيجة` / `Result`), Resume/Export buttons, and a steer input
  (`agentSteerPh`, `agentSteerSend`).
- Brain answers turn `[S1]` markers into `.fb-cite` chips (number; title = `<doc> — <unit> <page>`) that
  open the stored passage (`brainDecorateCitations`, `app.js:87993-88023`).

---

## 9. Message actions row (`aiActionsEl`, `app.js:29012-29263`)

Buttons are `.msg-action` (icon + label span; label `dir=auto`). Order and gating:

| # | Button | Label key | Gating / behaviour |
|---|---|---|---|
| 1 | Copy | `copy` → `copied` for 1400 ms | always; failure toast `copyFailed` |
| 2 | Save to shelf (`محفوظاتي`) | `shelfSave` → `shelfSaved` | prose turns only; saves the highlighted selection or the whole answer; toasts `shelfSavedSel`/`shelfSavedToast`/`shelfDupe`/`shelfFull`/`shelfFail` |
| 3 | Listen (TTS) | `listen` ↔ `listenStop` | only if speakable text (`barListenSpeakable`); refuses during a call (`listenBusy`); chunks ≤1300 chars → `POST /api/tts`; on 429 continues with device `speechSynthesis` (toast `listenLocal`); no voice → `listenNoVoice`/`listenNoVoiceAr` (`app.js:24357-24403`) |
| 4 | Listen on (read the rest of the thread) | `rqStart`, bar: `rqPrev/rqNext/rqPause/rqResume/rqClose/rqDone/rqEmpty` | only if a readable turn follows |
| 5 | Say it simpler | `simplify` → sheet `simplifyTitle/Pick/Child/Beginner/Exam` (+ `…D` hints), `simplifyHint`, toasts `simplifyWorking/Done/Empty/Failed` | prose of re-sayable length |
| 6 | Regenerate | `regenerate` | always; see §10 |
| 7 | Ask again (one word changed) | `askAgainBtn`, sheet `askAgainTitle/Aria/Hint` | when swappable words exist |
| 8 | Ask elsewhere | `askXBtn`, sheet `askXTitle/Aria/Hint`, options `askXBrainD`/`askXAgentD`, `askXNoDocs` | sends the same question to Brain/Agent |
| 9 | Continue | `continueAnswer` (`أكمل`), title `continueHint`; toasts `continueWorking/Done/Empty/Repeat/Failed/Busy` | only when `answerLooksTruncated` and not a card |
| 10 | Escalate to Max | `regenMax` (`أعد بـ فِراس ماكس` / `Retry with Firas Max`) | when `msg.tier !== "max"`; keeps both answers and links them (`escalateAnswer`, `app.js:27134-27154`); busy toast `continueBusy` |
| 11 | Share this answer | `shareOne`, title `shareOneHint`; toasts `shareOneWait/Copied/Fail/Busy(429)/Cap(409)` | members only, not offline/`firas-ask` turns; `POST /api/share {chatId, msg:i, cid}` → link `/?share=<id>` (`app.js:79715-79759`) |
| 12 | Export menu | trigger `download` (`تصدير` / `Download`) | prose turns; items in order: `PDF — بالهوية المحفوظة` / `PDF — saved identity`, `PDF — اختيار الهوية…` / `PDF — choose identity…`, `downloadPdf`, `downloadImage`, `downloadPrint`, `downloadWord`, `downloadExcel`, `downloadPpt`, `downloadHtml`, `downloadMarkdown`, `downloadText` (`app.js:35295-35318`); failure toast `formatUnavailable` |
| 13 | Compare | `cmpTwo`, sheet `cmpSub/cmpPick/cmpAnswerN/cmpChange/cmpAskBoth/cmpBothAttached` | when another answer exists |
| 14 | Focus reading | `focusRead`, title `focusReadHint`, exit `focusExit` | long answers only |
| 15 | Bigger | `bigText`, title `bigTextHint`, exit `bigTextExit` | `BIGTEXT_MIN_CHARS` threshold |
| 16 | Pace (sentence by sentence) | `paceRead`, `paceSlower/Faster/Speed/Done/Empty` | sentence-count threshold |

Appended afterwards by other modules into the same row: **Pin message** (`pinBtnEl`, `pinMsg`/`unpinMsg`,
max 12 per chat `pinFull`, strip `pinBar`; `app.js:20541-20600`) and **Private note** (`noteBtnEl`,
`noteAdd`/`noteHas`/`noteHead`/`notePh`/`noteDel`/`noteGone`, max 40 `noteFull`; `app.js:21270-21309`).
Both are device-local (`firas_msg_pins`, `firas_msg_notes`).

Also per turn: the `firas-ask` choice card, the `agentExportMd` button on missions, and the image card's
own `imgRetry/imgRegen/imgNoteAdd…` controls (strings `app.js:778-800`).

---

## 10. Regenerate, versions, escalate (`app.js:23039-23120`, `46324-46379`)

- `regenerate(index, tier)` re-answers the prompting user message without showing the old answer to the
  model, then **folds** the new answer into the same turn as a version (`msg.alts`, max
  `ANS_VERS_MAX = 5`, oldest evicted; `msg.altAt` selects; `msg.content` is always a copy of the shown
  version). Folding is refused for card turns, agent chats, stopped-before-token runs, or a mode change.
  Toast `verNew`.
- Pager (`ansVersionsEl`, `app.js:23738-23810`): label `verLabel` (`نسخة`), `‹ ›` nav with `verPrev`/
  `verNext`, counter `n / total` (LTR), `verKeep` (`خلّي هذي`, title `verKeepHint`, toast `verKept`), and
  a word-level diff toggle `verDiff`/`verDiffHide` (`verDiffTitle/First/Head/Add/Del/Gap/None/Long`).
- Escalate keeps two separate turns linked by `cid` and offers a side-by-side sheet
  (`retryCompareTitle`, `retryCompareSub`, `retryClose`).

---

## 11. Chat list / sidebar (`renderHistory`, `app.js:19014-19161`; rows `chatItemEl`, `app.js:19184-19286`)

- **Product filter**: `productChats()` (`app.js:15926-15937`) — Brain notebooks (`brainNb`), Code
  projects (`codeProj`), Agent missions (`agent`), else Firas AI; temporary chats excluded.
- Order of sections: colour-tag filter bar (`tagBar`, `tagAll`, empty `tagEmpty`), bulk-select bar,
  load-error state (`chatsLoadError` + retry `إعادة المحاولة` / `Try again`), empty state (icon + one of
  `noResults` / `tagEmpty` / `emptyHistory` / `emptyHistoryAgent` / `emptyHistoryCode` /
  `emptyHistoryBrain`), **resume strip** (`resumeHead` `أكمل من حيث توقّفت`; needs ≥2 picks and
  ≥`RSM_MAX + 1` = 4 chats, at most `RSM_MAX = 3` rows, never in UI 2.0 or on the share page; each row:
  title + who spoke last `msgHitYou`/`msgHitAi`; `app.js:18842-18930`), **folders**,
  **pinned** group (label `pinned` with pin icon, or a sticky pinned strip), then date groups `today`,
  `yesterday`, `previous7`, `previous30`, `older` (`groupKey`, `app.js:15865-15875`), then message hits.
- **Row**: title (dir by content), optional UI 2.0 time stamp, actions on hover: colour tag (`ctgBtn`),
  pin (`pin`/`unpin`), rename (`rename`, inline input; Enter commits, Escape cancels, blur commits;
  `PUT /api/chats/:id {title[, messages]}`), duplicate (`dup`, `dupWait/Done/Open/Fail`), delete
  (`delete`). Rows are HTML5 drag sources into folders. Click opens; in selection mode click toggles.
- **Delete with undo** (`deleteChat`, `app.js:13456-13556`): no confirm; row removed instantly; server
  `DELETE /api/chats/:id` scheduled after `UNDO_MS = 7000`; toast `chatDeleted` (or `chatDeletedStream`
  if a reply was streaming — the abort is not undoable) with `undo`. Pending deletes are flushed with
  `keepalive` on `pagehide`/hidden.
- **Pin**: `togglePin` → `PUT /api/chats/:id {pinned}` (`app.js:19289-19311`). Guest chats persist locally.
- **Folders** (`app.js:17750-18000`): device-local `firas_ai_folders` = `{ f:[folders], m:{chatKey:folderId} }`,
  max `CF_MAX = 20` (`folderMax`); "New folder" row (`newFolder`) is the only entry point; per folder:
  rename (`folderRename`), delete (`folderDelete`, toast `folderGone`; undoable), add conversations
  panel (`folderAdd`, `folderPick`, `folderFilter`, `folderDone`, `folderNone`), drop hint
  (`folderDrop`), move toast `folderMoved` (`انتقلت إلى «{name}»`).
- **Colour tags** (`app.js:80044-80063`): six hues fixed across themes — `r #C0503F` `tagRed`,
  `a #B0842C` `tagAmber`, `g #4E8A46` `tagGreen`, `t #2E8A82` `tagTeal`, `b #4A72B8` `tagBlue`,
  `v #8A5FB0` `tagPurple`; stored `firas_ai_chat_tags`; picker `tagPick`, clear `tagClear`; the row shows
  a colour stripe.
- **Bulk selection** (`bsSelect`, `bsSelected`, `bsAll`, `bsNone`, `bsDone`, `bsPin`, `bsUnpin`, `bsTag`,
  `bsFold`, `bsUnfile`, `bsExport`, `bsDelete`, `bsEmpty`, `bsMax`, `bsNoFolders`; result toasts
  `bsPinned/Unpinned/Tagged/Uncoloured/Unfiled/Exporting/Exported/Deleted/DeletedStream`) and **merge two**
  (`mgMerge`, `mgNeedTwo`, `mgBusy`, `mgWait`, `mgEmpty`, `mgTooLong`, `mgFail`, `mgDone`, `mgFrom`).
- **Search** (`app.js:15891-15937`, `19023-19040`): title filter on every keystroke; ≥3 characters also
  scans *loaded* message text (group `msgHits`, scope line `msgHitsScope` / `msgHitsScopeAll`, none
  `msgHitsNone` / `msgHitsNoneAll`, hit rows prefixed `msgHitYou`/`msgHitAi`, max 40 hits / 3 per chat,
  30 chars of context each side) and offers `searchAll` (`ابحث في كل المحادثات`) which loads the rest in
  batches (`searchAllN`, `searchAllRun`, `searchAllCancel`, `searchAllDone`, `searchAllFail`). In-chat
  search bar: `findHere`, `findHerePh`, `findHereNext/Prev/Close/None`.
- **Live dot** (`paintLiveRows`, `app.js:19599-19619`): a chat whose id is in `liveChatIds()` — any
  `firas_job_<id>` pointer, agent/long-file job pointers, or an in-flight stream (`app.js:19553-19573`) —
  gets class `is-working` and a leading `.chat-item__live` dot titled `ما زالت تشتغل` / `still working`.
  The (UI 2.0) product rail shows a busy dot or count per product (`railActivity`).
- Sidebar rows animate in once (`mStagger`); a first-load skeleton precedes data.
- **Usage row** above the account pill (`usageTitle` `استخدامك`, `usageWeek`, `usageTotal`, `usageNote`;
  `app.js:15939-16160`): counts conversations per product for 7 days, computed locally.
- Saved shelves: `محفوظاتي` (passages, `firas_shelf_v1`) and `قصاصاتي` (code, `firas_snips_v1`) with
  their own dialogs (`shelfSub`, `shelfSearch`, `shelfEmpty`, `shelfNoHits`, `shelfFrom`, `shelfCopy`,
  `shelfOpen`, `shelfDel`, `shelfDelAsk`, `shelfDelYes`, `shelfCancel`; `snipSub`, `snipSearch`,
  `snipEmpty`, `snipNoHits`, `snipCopy`, `snipDelAsk`, `snipCut`).

### 11.1 Auto-title (`autoTitleChat`, `app.js:13411-13445`; first-title logic `app.js:44518-44528`)

Provisional title = `titleFrom(text)`: whitespace-collapsed first 42 chars + `…` (or `newChat`). Then,
unless it is a temporary chat: Agent chats → `agentTitleFrom` (deterministic); file requests →
`fileChatTitleFrom` (deterministic, never the model); otherwise one Pro-tier model call with the system
prompt *"Generate a SHORT, specific title (2–5 words, ≤40 chars) … SAME language … Return ONLY the
title"* on the first 500 chars; the result is stripped of quotes/`Title:` prefixes, clipped to 60 chars,
validated by `validAutoChatTitle` (no newlines/braces/code-like tokens, must contain a letter), and
applied only if the user has not renamed meanwhile; then `PUT /api/chats/:id`.

---

## 12. Welcome screen (`renderWelcome`, `app.js:20189-20246`)

Shown when the active chat is empty. Firas AI: halo + mark + a single greeting line — no chips, no tips.
`greetingText()` (`app.js:20181-20187`): hour <12 `greetingMorning` (`صباح الخير`), <18
`greetingAfternoon` (`مساء الخير`), else `greetingEvening` (`مساءً سعيدًا`); with the first name:
ar `${base} يا ${first}`, en `${base}, ${first}`. Container `dir` follows the greeting's language.
Firas Agent: title `Firas Agent` + sub `وكيل ذكي للمهام الكبيرة: يخطّط، ينفّذ خطوة بخطوة، يراجع عمله بنفسه، ثم يسلّمك ملفات ومشاريع جاهزة.` /
`An autonomous agent for big tasks: it plans, executes step by step, reviews its own work, then delivers ready files and projects.`
plus a saved-templates strip (`atplHead` etc.). Entrance animation `animateWelcome` (halo bloom, mark
settle, word-by-word title).

---

## 13. Notifications / announcements (`app.js:44668-45030`)

- Bell `#notifyBtn` (title `تحديثات الموقع`, aria `Updates`); badge `#notifyBadge` is a **9 px accent dot**
  (no count; styles.css:5196) shown when any announcement `ts` > `firas_ann_seen` (`updateNotifyBadge`,
  `app.js:44756-44762`). Opening the panel stores the newest `ts` and clears the dot (`app.js:44925-44928`).
- Data: `GET /api/announcements` → `{announcements:[{id,title,body,titleEn,bodyEn,image,video,pinned,ts,by}], admin}`
  merged with the **built-in launch post** (`BUILTIN_ANNOUNCEMENTS`, `app.js:44692-44723`: id
  `builtin_launch`, pinned, `ts = 2026-08-05 UTC`, video `/media/firas-trailer.mp4`, title
  `فِراس AI — منصة عربية واحدة، أربعة منتجات` / `Firas AI — one Arabic-first platform, four products`, body
  verbatim in the source). Sort: pinned first, then newest.
- Panel (`openAnnouncementsPanel`, `app.js:44906-45030`): opens immediately with a spinner, then fills.
  Title `تحديثات Firas AI` / `Firas AI updates`, sub `آخر أخبار وتحديثات المنصّة.` / `Latest platform news &
  updates.`; rows = optional thumbnail, badges `مثبّت`/`Pinned` and `فيديو`/`Video`, title, body,
  date+time (`annDateTime`), chevron; empty `لا توجد تحديثات بعد.` / `No updates yet.`; row → reader
  overlay. Admin-only compose form and "Reference library" button are not for the consumer app.
- Settings → Data → About has `updatesLink` (`عرض آخر التحديثات` / `See what's new`) opening the same panel.

---

## 14. Account pill and settings

- Pill (`index.html:629-638`, `applyUserIdentity` `app.js:46795-46807`): avatar = first letter uppercased
  (`F` fallback), name = user name / email local-part / `Firas`; guest shows `guestName` (`ضيف` / `Guest`).
  Buttons: settings (`settings` `الإعدادات`) and logout (`logout` `تسجيل الخروج`). **No plan or quota is
  displayed in the pill** — plan/quota UI lives only in Settings (§3.2) and the usage row (§11).
- Settings panel (`openSettingsPanel`, `app.js:45603-46125`): tabs `tabAccount` `الحساب`, `tabLook`
  `المظهر`, `tabChat` `المحادثة`, `tabVoice` `الصوت`, `tabData` `البيانات` (+ `kmTab` keyboard on desktop).
  - Account: identity hero; members get the plan card, change email/password forms, danger zone
    (`dangerH`, `delBtn`, `delConfirmP`, `delFinal`); guests get one card `guestH`
    (`أنت تتصفّح كضيف`), `guestP`, CTA `guestCta` (`أنشئ حسابًا مجانيًا`).
  - Appearance: UI 2.0 switch (`ui2Lbl` `واجهة 2.0`, hint `ui2Hint`), **theme grid** (`themeH` `الثيم` ·
    `themeSub` `ستة أمزجة` / `six moods`; six tiles painted from `THEMES[].sw` = ground / surface / accent,
    named `th.ar`/`th.en`), text size (`readingH` `حجم النص`: `fsSmall/Medium/Large`), reading width
    (`widthH`: `widthNormal`/`widthWide`), motion (`motionH` `الحركة`: `motionFull`/`motionReduce` →
    `data-motion="off"`), interface language (`langH` `لغة الواجهة`: `العربية` / `English`, toast
    `تم تغيير لغة الواجهة ✓` / `Interface language changed ✓`).
  - Chat: default model, reply behaviour switches (think / web / enter), image sharpening
    (`srLbl` `شحذ الصور تلقائيًّا`, off by default, `firas_ai_img_sr`).
  - Voice: call voice select (`CALL_VOICES = ["cedar","ash","verse","echo","ballad"]`, `app.js:48302`),
    dictation dialect select (`MIC_LANGS`, `app.js:47582-47597`: auto, msa, iraqi, gulf, egyptian, levant,
    maghrebi, en, fr, tr, de, es, ur, fa).
  - Data: export/import backup JSON (`exportBtn`, `importBtn`, `importConfirm`…), clear device prefs
    (`clearBtn`, `clearConfirm`; guests see `guestStorageSub`), About (version + updates link).

---

## 15. Quotas and limit dialogs — every string

Server 429 bodies the client reads (`server.mjs:1286`, `7678`, `12897`, `9008`):
`{ error: "daily quota reached" | "guest daily limit reached", quota: { product: "ai"|"code"|"agent"|"brain"|"internal"|"voice", used, limit, plan: "free"|"gold"|"diamond"|"unlimited"|"guest"[, scope:"network"] } }`.
Members are unmetered today (`PLAN_LIMITS` all `-1`), so in practice only guests hit `quota`.

`quotaLimitText(lang, q)` (`app.js:6464-6482`) — rendered **as the assistant message content**:
- Guest (`q.plan === "guest"` or `isGuest()`): returns `guestLimitReached` and opens the sign-up prompt
  after 200 ms:
  - ar `انتهت رسائلك المجانية لهذا اليوم كضيف. أنشئ حسابًا مجانيًا للحصول على حدّ أعلى بكثير.`
  - en `You have used today's free guest messages. Create a free account for a much higher limit.`
- Member: name by product — ar `رسائل فِراس AI` / `طلبات فِراس Code` / `مهام فِراس Agent` / `أسئلة فِراس Brain`
  (fallback `الرسائل`); en `Firas AI messages` / `Firas Code requests` / `Firas Agent tasks` /
  `Firas Brain questions` (fallback `messages`); limit in Arabic-Indic digits for ar:
  - ar `🚦 بلغت الحدّ اليومي من {name} ({lim}/يوم). يتجدّد تلقائيًا بعد منتصف الليل.\n\nفِراس مجاني بالكامل — هذا السقف موجود ليبقى المحرّك متاحًا للجميع، وهو مرتفع لدرجة أن الاستخدام الطبيعي لا يبلغه.`
  - en `🚦 You've reached today's limit of {name} ({lim}/day). It resets automatically after midnight.\n\nFiras is completely free — this ceiling only keeps the engine available for everyone, and it is set high enough that ordinary use never reaches it.`
Other limit strings: `maxLimitText` (§3.2); generic 429 `طلبات كثيرة بسرعة — انتظر لحظة ثم حاول مجددًا.` /
`Too many requests too fast — wait a moment and try again.`; image quota `imgWhyQuota`
(`بلغت حدّك اليومي من الصور. الحدّ يتجدّد غدًا.`); TTS quota `listenLocal`; share `shareOneBusy` (429),
`shareOneCap` (409); session expiry (`handleSessionExpired`, `app.js:3239-3251`, members only):
`انتهت جلستك. الرجاء تسجيل الدخول من جديد.` / `Your session expired. Please sign in again.`; agent busy toasts
(`app.js:44441-44449`); connection `errorTitle` (`تعذّر الاتصال.`) with `retry`. Toasts last 3200 ms
(`app.js:3285`); undo toasts carry one button.

---

## 16. The six themes (`THEMES`, `app.js:2464-2483`; tokens styles.css:11-391)

Default **dark**; `firas_ai_theme` whitelisted against `THEME_IDS`, else `dark` (`app.js:3170-3171`,
`14063-14080`). `applyTheme` sets `data-theme` and the `theme-color` meta. The inline bootstrap only
knows light vs dark (`index.html:227-233`). All non-light themes are "dark family" (`previewTheme`).

| id | ar | en | meta/theme-color | swatch ground / surface / accent |
|---|---|---|---|---|
| light | `نهاري` | Light | `#FAF9F5` | `#FAF9F5` / `#FFFFFF` / `#237A68` |
| dark | `ليلي` | Dark | `#262624` | `#262624` / `#30302E` / `#57AE9C` |
| black | `أسود` | Black | `#000000` | `#000000` / `#161616` / `#5FBBA7` |
| midnight | `نيلي` | Midnight | `#0F1522` | `#0F1522` / `#182133` / `#5AA9E6` |
| graphite | `كربوني` | Graphite | `#171719` | `#171719` / `#202023` / `#57AE9C` |
| amber | `عنبري` | Amber | `#1B1713` | `#1B1713` / `#241F19` / `#D9A05B` |

Full token values (styles.css line ranges: light 11-188, dark 196-235, black 248-283, midnight 286-319,
graphite 322-355, amber 358-391):

| token | light | dark | black | midnight | graphite | amber |
|---|---|---|---|---|---|---|
| --color-bg | #FAF9F5 | #262624 | #000000 | #0F1522 | #171719 | #1B1713 |
| --color-bg-subtle | #F0EEE6 | #1F1E1D | #0A0A0A | #0A0E19 | #101012 | #141110 |
| --color-surface | #FFFFFF | #30302E | #161616 | #182133 | #202023 | #241F19 |
| --color-surface-sunken | #F0EEE6 | #1F1E1D | #0A0A0A | #0A0E19 | #101012 | #141110 |
| --color-sidebar-bg | #F5F4EE | #1F1E1D | #000000 | #0A0E19 | #101012 | #141110 |
| --color-text-primary | #1A1A18 | #ECEAE3 | #F2F2F0 | #E6ECF5 | #ECECEE | #F0E7D8 |
| --color-text-secondary | #6B6A63 | #A6A39A | #ABABA6 | #9FACC2 | #A5A5AA | #B3A793 |
| --color-text-muted | #6E6C64 | #9A978E | #8C8C87 | #8695AE | #8B8B90 | #9C907C |
| --color-border-hairline | #E6E4DA | #3A3A36 | #232323 | #232E44 | #2A2A2E | #332C23 |
| --color-border-strong | #D8D6CB | #46453F | #343432 | #33405A | #3A3A3F | #453C30 |
| --color-accent | #237A68 | #57AE9C | #5FBBA7 | #5AA9E6 | #57AE9C | #D9A05B |
| --color-accent-hover | #1A6253 | #6BC0AE | #74CFBB | #7CBEF0 | #6BC0AE | #E8B475 |
| --color-accent-soft | rgba(44,138,120,.08) | rgba(87,174,156,.14) | rgba(95,187,167,.15) | rgba(90,169,230,.15) | rgba(87,174,156,.14) | rgba(217,160,91,.15) |
| --color-accent-ring | rgba(44,138,120,.40) | rgba(87,174,156,.45) | rgba(95,187,167,.45) | rgba(90,169,230,.45) | rgba(87,174,156,.45) | rgba(217,160,91,.45) |
| --color-on-accent | #FFFFFF | #1F1E1D | #000000 | #0A0E19 | #101012 | #1B1713 |
| --color-accent-deep | #14544A | #2F6F62 | #2F6F62 | #2C6394 | #2F6F62 | #8A6234 |
| --color-success | #2E7D5B | #4BA784 | #4BA784 | #4BA784 | #4BA784 | #8FBF6F |
| --color-error | #B3261E | #E06A60 | #E06A60 | #E06A60 | #E06A60 | #E06A60 |
| --grain-opacity | .030 | .042 | 0 | .035 | .03 | .05 |

`--color-border` aliases `--color-border-hairline`; `--color-line` = accent, `--color-line-bright` =
accent-hover. Preview-iframe palette per theme (`THEMES[].pv`: bg/surface/text/muted/accent/hair/bad/ok)
is at `app.js:2467-2482` (e.g. dark bad `#E5877A`, ok `#8FBF6F`).

Shared design tokens (styles.css:68-188): spacing 4-px scale (`--space-1` 4 … `--space-16` 64); radii
xs 2 / sm 3 / md 5 / lg 7 / xl 9 / pill 999 (+ `--soft-radius` 20 px for the user bubble and image frames);
borders 1 / 1.5 px; shadows very soft (dark variants heavier); type: display `Archivo` + `Reem Kufi`
(Arabic display `--font-arabic-display`), body sans `Archivo` / `Noto Sans Arabic`, mono `JetBrains Mono`;
scale xs 12/16, sm 13/20, base 15/24, md 16/26, lg 17/29, xl 21/30, 2xl 26/34, 3xl 32/40; weights 400/500/
600/700; motion `--dur-fast 120ms`, `--dur-base 160ms`, `--dur-slow 220ms`, `--ease-out
cubic-bezier(.22,1,.36,1)`, `--spring cubic-bezier(.16,1,.30,1)` (no overshoot), keyboard curve
`--ease-ios cubic-bezier(.32,.72,0,1)` 0.30 s; layout sidebar 268, topbar 56, column 744, reading 704/920.

Component colours the port must reproduce: Max purple `#8b5cf6` dot / `#7c3aed` text / dark badge
`#a78bfa`; tag colours (§11); plan gold/diamond (§3.2); notify dot = accent with a 2 px surface ring
(styles.css:5196); streaming caret = accent; thread-loading dots muted→accent.

---

## Appendix A — STR entries used by this slice (key · ar · en)

Line numbers: ar block `app.js:141-1263`, en block `app.js:1264-2303`. `{n}`, `{name}`, `{q}`, `{m}`,
`{lvl}`, `{subj}`, `{d}` are placeholders substituted by code.

### Shell, navigation, welcome
| key | ar | en |
|---|---|---|
| newChat | محادثة جديدة | New chat |
| newChatShort | جديد | New |
| searchPlaceholder | ابحث في المحادثات | Search conversations |
| composerPlaceholder | اسأل فِراس... | Ask Firas… |
| settings | الإعدادات | Settings |
| logout | تسجيل الخروج | Log out |
| greetingMorning | صباح الخير | Good morning |
| greetingAfternoon | مساء الخير | Good afternoon |
| greetingEvening | مساءً سعيدًا | Good evening |
| today | اليوم | Today |
| yesterday | أمس | Yesterday |
| previous7 | آخر ٧ أيام | Previous 7 days |
| previous30 | آخر ٣٠ يومًا | Previous 30 days |
| older | أقدم | Older |
| emptyHistory | لا توجد محادثات بعد — اضغط «محادثة جديدة» للبدء. | No conversations yet — press “New chat” to begin. |
| emptyHistoryAgent | لا توجد مهام بعد — اضغط «محادثة جديدة» وصِف مهمتك. | No missions yet — press “New chat” and describe your task. |
| emptyHistoryCode | لا توجد مشاريع بعد — اضغط «محادثة جديدة» لبناء مشروعك الأول. | No projects yet — press “New chat” to build your first one. |
| emptyHistoryBrain | لا توجد محادثات بعد — ارفع ملفاتك واسأل عنها، والإجابة تجيك موثّقة بالصفحة. | No conversations yet — upload your files and ask; every answer cites its page. |
| noResults | لا توجد نتائج. | No results. |
| disclaimer | قد يخطئ فِراس. تحقّق من المعلومات المهمة. | Firas can make mistakes. Check important info. |
| streaming | يكتب فِراس... | Firas is typing… |
| badge | بواسطة | by |
| stop | إيقاف | Stop |
| send | إرسال | Send |
| retry | إعادة المحاولة | Retry |
| errorTitle | تعذّر الاتصال. | Couldn't connect. |
| chatsSaveError | تعذّر حفظ المحادثة. ستُعاد المحاولة. | Couldn't save the chat. Retrying. |
| chatsLoadError | تعذّر تحميل المحادثات. | Couldn't load conversations. |
| gallery | صور المحادثة | Chat images |
| galleryTitle | صور هذه المحادثة | Images in this chat |
| galleryClose | إغلاق | Close |
| galleryAll | تحميل الكل (ZIP) | Download all (ZIP) |
| galleryOne | تحميل الصورة | Download image |
| galleryGo | اعرضها في المحادثة | Show it in the chat |
| galleryDone | تم حفظ الصور ✅ | Images saved ✅ |
| galleryPartial | تعذّر جلب {n} من الصور — والباقي محفوظ | {n} couldn't be fetched — the rest are saved |
| galleryFail | تعذّر تحميل الصور — حاول مرة أخرى | Couldn't download the images — try again |
| ephTitle | محادثة مؤقتة | Temporary chat |
| ephStart | ابدأ محادثة مؤقتة | Start a temporary chat |
| ephEnd | أنهِ المحادثة المؤقتة | End the temporary chat |
| ephNote | محادثة مؤقتة — ما تنحفظ ولا تبيّن بسجلّك | Temporary chat — not saved, not in your history |
| ephBegan | بدأت محادثة مؤقتة — ما ينحفظ منها شي | Temporary chat started — nothing here is kept |
| ephAsk | إنهاء المحادثة المؤقتة يمسح كل اللي فيها، وما في تراجع. متابعة؟ | Ending this temporary chat erases everything in it, and there is no undo. Continue? |
| ephGone | انتهت المحادثة المؤقتة | Temporary chat ended |
| resumeHead | أكمل من حيث توقّفت | Pick up where you left off |
| usageTitle | استخدامك | Your usage |
| usageAria | تفاصيل استخدامك | Your usage in detail |
| usageWeek | هذا الأسبوع | This week |
| usageTotal | كل المحادثات | All conversations |
| usageNote | هذه الأرقام تُحسب على جهازك، ولا تُرسل إلى أي مكان. | These numbers are worked out on your device. They are not sent anywhere. |

### Composer, attachments, tools
| key | ar | en |
|---|---|---|
| attachHint | إرفاق ملف | Attach a file |
| agentAttachHint | إرفاق ملفات وصور إلى المهمة | Attach files and images to the mission |
| dropToAttach | أفلت الملفات هنا للإرفاق | Drop files here to attach |
| agentDropToAttach | أفلت الملفات هنا — يقرأها فِراس ضمن المهمة | Drop files here — Firas reads them into the mission |
| askFileChip | اسأل عن هذا الملف | Ask about this file |
| askFileLead | عن الملف | About the file |
| micLabel | إدخال صوتي | Voice input |
| micHint | إدخال صوتي — اضغط مطوّلًا لاختيار اللهجة | Voice input — long-press to pick a dialect |
| micLangTitle | لغة الإملاء | Dictation language |
| thinking | التفكير | Thinking |
| thinkOn | التفكير مُفعّل — دقة أعلى | Thinking on — higher accuracy |
| thinkOff | التفكير مُعطّل — استجابة أسرع | Thinking off — faster replies |
| thinkMaxBlocked (unused) | عذراً، لا يمكنك استخدام ميزة التفكير في فِراس ماكس — قد يؤدي إلى كسر القيود. | Sorry, Thinking can't be used in Firas Max — it may break the safety limits. |
| webSearch | بحث الويب | Web search |
| searchOn | بحث الويب مُفعّل — يبحث في كل رسالة | Web search on — searches every message |
| searchOff | بحث الويب تلقائي — يبحث عند الحاجة | Web search auto — searches when needed |
| modeLabel | النمط | Mode |
| modeAuto | تلقائي | Auto |
| modeAutoHint | ذكي ومباشر — يجيب فورًا. | Smart & direct — answers right away. |
| modePlan | تخطيط | Plan |
| modePlanHint | يسأل ويضع خطة، ثم ينفّذ بعد موافقتك. | Asks & plans first, then executes once you approve. |
| planStart | ابدأ التنفيذ | Start |
| planStartHint | موافقة على الخطة وبدء التنفيذ | Approve the plan and start executing |
| planApproval | ابدأ التنفيذ ونفّذ الخطة. | Go ahead and execute the plan. |
| askRecommended | موصى به | Recommended |
| askContinue | متابعة | Continue |
| askBack | السابق | Back |
| askSubmit | تأكيد الاختيارات | Confirm |
| askStep | سؤال | Question |
| askExtraPlaceholder | أو أضف تفصيلاً… | Or add a detail… |
| askAnswered | تم الإرسال | Sent |
| askMyChoices | اختياراتي | My choices |
| askPreparing | جاري تحضير الأسئلة… | Preparing questions… |
| lenmChars | الأحرف {n} | {n} chars |
| lenmTokens | الرموز ≈{n} | ≈{n} tokens |
| lenmNear | اقترب من حدّ {m} | near the {m} limit |
| lenmOver | تجاوز حدّ {m} | over the {m} limit |
| lenmTip | تقدير تقريبي. ما يتجاوز {n} حرف قد يُقصّ عند حفظ الرسالة — قسّمها أو أرفق النصّ كملف. | A rough estimate. Past {n} characters a saved message may be cut — split it, or attach the text as a file. |
| slashTitle | أوامر سريعة | Quick commands |
| slashSumL / slashSumH | تلخيص / اختصر نصًا طويلًا إلى نقاط | Summarize / Boil a long text down to points |
| slashTrL / slashTrH | ترجمة / ترجمة طبيعية بين العربية والإنجليزية | Translate / Natural Arabic ↔ English translation |
| slashExpL / slashExpH | شرح / شرح مبسّط خطوة بخطوة | Explain / Plain, step-by-step explanation |
| slashRevL / slashRevH | مراجعة / تدقيق مع اقتراح تحسين لكل ملاحظة | Review / Critique, with a fix for every note |
| selAskChip | اسأل عن هذا | Ask about this |
| selAskLead | بخصوص هذا المقطع من ردّك السابق: | About this passage from your earlier reply: |
| selAskTail | اشرح لي هذا الجزء تحديدًا. | Explain this specific part. |
| quotePillHint | مقطع مرفق من ردّ سابق — اكتب سؤالك عنه | A passage from an earlier reply — write your question about it |
| quotePillDrop | إزالة المقطع | Remove the passage |
| quoteLeadN | بخصوص هذه المقاطع من ردودك السابقة، بالترتيب: | About these passages from your earlier replies, in order: |
| quoteStackAria | المقاطع المرفقة | Attached passages |
| quoteAddMore | أضِفه إلى السؤال | Add to the question |
| quoteClearAll | أزل الكل | Remove all |
| quoteDupe | هذا المقطع مرفق من قبل | That passage is already attached |
| quoteFull | لا يتّسع السؤال لمقاطع أكثر — أزل واحدًا لتضيف غيره | One question can’t carry more passages — remove one to add another |
| undoSend | أُرسلت رسالتك — التراجع يعيدها ويوقف الردّ | Message sent — undo puts it back and stops the reply |
| undo | تراجع | Undo |
| outboxHeld | لم تُرسَل رسالتك — لا يوجد اتصال. سنرسلها فور عودته. | Your message didn’t go out — there’s no connection. It will be sent the moment it’s back. |
| outboxReady | عاد الاتصال — رسالتك لم تُرسَل بعد. | The connection is back — your message still hasn’t been sent. |
| outboxSend | أرسلها الآن | Send it now |
| dfxLabel | الصعوبة | Difficulty |
| dfxTitle | مستوى صعوبة ما يولّده فِراس في هذه المحادثة — يُحفظ معها | How hard Firas makes what it generates in this chat — kept with the conversation |
| dfxMenuTitle | سُلّم الصعوبة | Difficulty ladder |
| dfxUp / dfxDown | رُفعت الصعوبة إلى {lvl} / خُفّضت الصعوبة إلى {lvl} | Difficulty raised to {lvl} / Difficulty lowered to {lvl} |
| dfxTop | أنت على أعلى درجة في السلّم: {lvl}. لا مستوى فوقها. | You are on the top rung already: {lvl}. There is nothing above it. |
| dfxBot | أنت على أدنى درجة في السلّم: {lvl}. لا مستوى تحتها. | You are on the lowest rung already: {lvl}. There is nothing below it. |
| dfxSetTo / dfxUndo | الصعوبة: {lvl} / تراجع | Difficulty: {lvl} / Undo |
| dfxAskAria | اختيار مستوى الصعوبة لهذه المحادثة | Choose a difficulty level for this chat |
| dfxAskTitle | أسئلة {subj} — اختر مستوى الصعوبة | {subj} questions — choose a difficulty level |
| dfxAskNote | يُحفظ الاختيار مع هذه المحادثة، ويمكن تغييره لاحقًا من زرّ الصعوبة. | Kept with this conversation; change it later from the difficulty button. |
| dfxAskSkip | تابع بمستوى {lvl} | Continue at {lvl} |

### Slash-command prompt bodies (`slash*P`, inserted into the composer in place of the typed `/…` token; `app.js:1037-1046` / `2105-2114`)
| key | ar | en |
|---|---|---|
| slashSumP | لخّص لي النص التالي في نقاط مركّزة، مع الإبقاء على كل فكرة أساسية وحذف الحشو:

 | Summarize the text below into tight points — keep every key idea, cut the filler:

 |
| slashTrP | ترجم النص التالي ترجمة طبيعية لا حرفية، مع الحفاظ على المعنى والنبرة. وإن لم أذكر اللغة فترجم من العربية إلى الإنجليزية أو العكس:

 | Translate the text below naturally, not literally, keeping the meaning and the tone. If I don't name a language, translate between Arabic and English:

 |
| slashExpP | اشرح لي التالي شرحًا واضحًا ومبسّطًا، خطوة بخطوة، مع مثال عملي واحد على الأقل:

 | Explain the following clearly and simply, step by step, with at least one concrete example:

 |
| slashRevP | راجع التالي مراجعة دقيقة: اذكر الأخطاء والثغرات ونقاط الضعف، ثم اقترح تحسينًا محدّدًا لكل ملاحظة:

 | Review the following carefully: list the errors, gaps and weak points, then suggest one specific improvement for each note:

 |

(`

` is a literal two-newline suffix so the user's text starts on its own paragraph.)

### Dictation dialect labels (`MIC_LANGS`, `app.js:47582-47597`; shown in the tools-menu row `#micLangItem` and Settings → Voice)
Fields: `key`, `flag` (emoji), `ar`/`en` (full label), `sa`/`se` (short label used in the tools-menu value). Hard cap `MIC_MAX_SECONDS = 300` (`app.js:47598`).

| key | flag | ar | en | short ar | short en |
|---|---|---|---|---|---|
| auto | 🌐 | تلقائي — يتعرّف على لغتك من كلامك | Auto — detects your language | تلقائي | Auto |
| msa | 📖 | العربية الفصحى | Arabic (Fus'ha) | فصحى | MSA |
| iraqi | 🇮🇶 | عراقية | Iraqi Arabic | عراقية | Iraqi |
| gulf | 🇸🇦 | خليجية | Gulf Arabic | خليجية | Gulf |
| egyptian | 🇪🇬 | مصرية | Egyptian Arabic | مصرية | Egyptian |
| levant | 🇸🇾 | شامية | Levantine Arabic | شامية | Levantine |
| maghrebi | 🇲🇦 | مغاربية | Maghrebi Arabic | مغاربية | Maghrebi |
| en | 🇺🇸 | الإنجليزية | English | English | English |
| fr | 🇫🇷 | الفرنسية | French | Français | French |
| tr | 🇹🇷 | التركية | Turkish | Türkçe | Turkish |
| de | 🇩🇪 | الألمانية | German | Deutsch | German |
| es | 🇪🇸 | الإسبانية | Spanish | Español | Spanish |
| ur | 🇵🇰 | الأردية | Urdu | اردو | Urdu |
| fa | 🇮🇷 | الفارسية | Persian | فارسی | Persian |

### Tier pin
| key | ar | en |
|---|---|---|
| tpinTitle | النموذج في هذه المحادثة | Model in this chat |
| tpinBtn | ثبّت نموذجًا على هذه المحادثة | Pin a model to this chat |
| tpinBtnOn | هذه المحادثة مثبّتة على {name} | This chat is pinned to {name} |
| tpinNone | بدون تثبيت | No pin |
| tpinNoneHint | تتبع اختيار النموذج في التطبيق | Follows the app's model choice |
| tpinSet | هذه المحادثة تبقى على {name} | This chat stays on {name} |
| tpinCleared | أُلغي التثبيت — عادت المحادثة إلى نموذج التطبيق | Pin removed — back to the app's model |
| tpinReplies | ردود هذا النموذج هنا: {n} | Replies from this model here: {n} |

### Message actions, versions, sharing, export
| key | ar | en |
|---|---|---|
| copy / copied | نسخ / تم النسخ | Copy / Copied |
| copyFailed | تعذّر النسخ — جرّب مرة أخرى | Copy failed — try again |
| copyCode | نسخ | Copy |
| regenerate | إعادة التوليد | Regenerate |
| regenUltra | أعد بـ فِراس أولترا | Regenerate with Firas Ultra |
| regenMax | أعد بـ فِراس ماكس | Retry with Firas Max |
| listen / listenStop | اسمع / إيقاف | Listen / Stop |
| listenBusy | أنهِ المكالمة أول | End the call first |
| listenLocal | انتهت حصة الصوت — يكمّل بصوت الجهاز | Voice quota spent — finishing on your device |
| listenNoVoice | جهازك ما عنده صوت للقراءة — ثبّت صوتًا من إعدادات النظام | This device has no speech voice installed — add one in your system settings |
| listenNoVoiceAr | جهازك ما عنده صوت عربي — ثبّته من إعدادات اللغة بالنظام، وبعدها يشتغل | This device has no Arabic voice — add one in your system language settings and it will work |
| rqStart | اسمع من هنا | Listen on |
| rqHint | يقرأ المحادثة بصوتٍ عالٍ من هذه الرسالة إلى آخرها، ويتخطّى الشيفرة | Reads the thread aloud from this turn to the end, skipping code |
| rqPrev / rqNext | السابق / التالي | Previous / Next |
| rqPause / rqResume | إيقاف مؤقّت / متابعة | Pause / Resume |
| rqClose | إنهاء القراءة | End reading |
| rqDone | انتهت المحادثة | End of the conversation |
| rqEmpty | لا يوجد نصّ يُقرأ هنا | Nothing here to read aloud |
| simplify | قُلها أبسط | Say it simpler |
| simplifyTitle | أعد صياغة هذا الرد بمستوى أوضح | Re-say this answer at a clearer level |
| simplifyPick | لمن نشرحها؟ | Who are we explaining it to? |
| simplifyChild / simplifyChildD | لطفل / جمل قصيرة وكلمات يومية ومثال ملموس | For a child / Short sentences, everyday words, one concrete example |
| simplifyBeginner / simplifyBeginnerD | لمبتدئ / نفس البناء، مع تعريف كل مصطلح عند أول ذكر | For a beginner / The same shape, with every term defined the first time |
| simplifyExam / simplifyExamD | للامتحان / التعريفات والخطوات ونقاط الدرجات، مختصرة | For an exam / The definitions, the steps and the marks, tightened |
| simplifyHint | الأصل يبقى نسخة — ترجع إليه بالسهم فوق الإجابة | The original stays as a version — flip back with the arrow above the answer |
| simplifyWorking | أُبسِّط… | Simplifying… |
| simplifyDone | صارت أبسط — والأصل محفوظ كنسخة فوقها | Simpler now — the original is kept as a version above it |
| simplifyEmpty | ما رجع تبسيط صالح — الإجابة كما هي | No usable rewrite came back — the answer is unchanged |
| simplifyFailed | تعذّر التبسيط — جرّب مرة أخرى | Couldn’t simplify — try again |
| askAgainBtn | أعِد السؤال | Ask again |
| askAgainTitle | السؤال نفسه، بكلمة واحدة مختلفة | The same question, one word different |
| askAgainAria | الكلمات التي يمكن تبديلها | Words you can swap |
| askAgainHint | اختر كلمة، فينزل السؤال في مربع الكتابة وهي محدَّدة — اكتب بديلها وأرسل. | Pick a word: the question lands in the composer with it selected — type the new one and send. |
| askXBtn | اسأل منتجًا آخر | Ask elsewhere |
| askXTitle | السؤال نفسه، عند منتج آخر | The same question, in another product |
| askXAria | إلى أين يُرسَل السؤال | Where to send the question |
| askXHint | يُرسَل السؤال كما هو — بلا إعادة كتابة، وهذه المحادثة تبقى مكانها. | The question is sent exactly as it is — nothing is retyped, and this conversation stays where it is. |
| askXBrainD | يجيب من ملفاتك المختارة، بإجابة موثّقة بالصفحة | Answers from your selected files, and names the page |
| askXAgentD | ينفّذه كمهمّة، خطوة بخطوة | Works through it as a mission, step by step |
| askXNoDocs | لا ملف مختار في فِراس Brain — افتحه واختر ملفًا أولًا | No file is selected in Firas Brain — open it and pick one first |
| continueAnswer | أكمل | Continue |
| continueHint | يبدو أن الجواب توقّف قبل أن يكتمل — اضغط لإكماله | This answer looks cut off — continue it |
| continueWorking | يُكمل… | Continuing… |
| continueDone | أُكمل الجواب ✅ | Answer continued ✅ |
| continueEmpty | لم تصل أي إضافة — الجواب كما هو | Nothing came back — the answer is unchanged |
| continueRepeat | التكملة أعادت ما هو مكتوب — الجواب كما هو | The continuation repeated what was already there — the answer is unchanged |
| continueFailed | تعذّر الإكمال — حاول مرة أخرى | Couldn't continue — try again |
| continueBusy | انتظر حتى ينتهي الرد الحالي | Wait for the current reply to finish |
| verLabel | نسخة | Version |
| verPrev / verNext | النسخة السابقة / النسخة التالية | Previous version / Next version |
| verHint | أكثر من إجابة لنفس السؤال — قلّب بينهن وخلّي اللي تعجبك | More than one answer to the same question — flip between them and keep the one you prefer |
| verKeep / verKeepHint | خلّي هذي / احذف باقي النسخ وخلّي هذي بس | Keep this one / Drop the other versions and keep this one |
| verKept | خلّيت هذي النسخة بس | Kept this version |
| verNew | وصلت نسخة جديدة — قلّب بينهن وخلّي اللي تعجبك | New version — flip between them and keep the one you prefer |
| verDiff / verDiffHide | وش تغيّر / أخفِ الفروق | What changed / Hide changes |
| verDiffTitle | قارن هذي النسخة باللي قبلها كلمة كلمة | Compare this version with the one before it, word by word |
| verDiffFirst | هذي أول نسخة — ما قبلها شيء تُقارَن به | This is the first version — there is nothing before it to compare with |
| verDiffHead | الفرق عن النسخة السابقة | Changes from the previous version |
| verDiffAdd / verDiffDel | مضاف / محذوف | Added / Removed |
| verDiffGap | مقطع ما تغيّر | unchanged passage |
| verDiffNone | النسختان متطابقتان — ولا كلمة تغيّرت | The two versions are identical — not one word differs |
| verDiffLong | الجوابان أطول من أن يُقارَنا كلمة كلمة | These two answers are too long to compare word by word |
| retryStronger | أُعيد بنموذج أقوى | Retried on a stronger model |
| retryWasRetried | أُعيد هذا الجواب بنموذج أقوى | This answer was retried on a stronger model |
| retryCompare | قارن الجوابين | Compare both |
| retryGoOld / retryGoNew | الجواب الأول / الجواب الثاني | First answer / Second answer |
| retryGone | الجواب الآخر لم يعد موجودًا في هذه المحادثة | The other answer is no longer in this conversation |
| retryCompareTitle | الجوابان جنبًا إلى جنب | Both answers, side by side |
| retryCompareSub | نفس السؤال بنموذجين — اقرأ الاثنين واختر. | Same question, two models — read both and pick. |
| retryClose | إغلاق | Close |
| cmpTwo | قارِن | Compare |
| cmpTwoHint | ضع هذا الجواب بجانب أيّ جواب آخر في المحادثة | Put this answer beside any other answer in the conversation |
| cmpSub | جوابان من هذه المحادثة — كلّ واحد في عموده، بلغته واتجاهه. | Two answers from this conversation — each in its own column, in its own language. |
| cmpPick / cmpAnswerN / cmpChange | اختر جوابًا / الجواب {n} / غيّر | Choose an answer / Answer {n} / Change |
| cmpChangeHint | اختر جوابًا آخر لهذا العمود | Pick a different answer for this column |
| cmpAskBoth / cmpAskBothHint | اسأل عن الاثنين / يُرفَق الجوابان بسؤالك القادم، ويبقى السؤال لك تكتبه. | Ask about both / Both answers ride on your next question — the question stays yours to write. |
| cmpBothAttached | أُرفِق الجوابان — اكتب سؤالك | Both answers attached — write your question |
| focusRead / focusReadHint / focusExit | قراءة مركّزة / اقرأ هذه الإجابة وحدها بلا شريط جانبي ولا أزرار — اضغط Esc للعودة / إنهاء القراءة | Focus / Read this answer on its own — no sidebar, no buttons. Esc brings it all back / Exit reading |
| bigText / bigTextHint / bigTextExit / bigTextAria | تكبير / اقرأ هذه الإجابة وحدها بحجم مريح — اضغط Esc للعودة / إغلاق / الإجابة بحجم أكبر | Bigger / Read this answer on its own, at a size that does not fight you — Esc brings you back / Close / This answer, enlarged |
| paceRead / paceReadAria | جملة جملة / الإجابة جملةً جملة | Pace / This answer, one sentence at a time |
| paceReadHint | يكشف هذه الإجابة جملةً جملة بالسرعة التي تختارها — المسافة توقِف، والسهمان يتقدّمان ويرجعان، وEsc يعيدك | Reveals this answer one sentence at a time at a speed you pick — Space pauses, the arrows step, Esc brings you back |
| paceSlower / paceFaster / paceSpeed | أبطأ / أسرع / سرعة الكشف — كلمة في الدقيقة | Slower / Faster / Reveal speed — words per minute |
| paceDone / paceEmpty | هذه آخر جملة / لا يوجد هنا ما يُقرأ جملةً جملة | That was the last sentence / Nothing here to step through |
| shareOne | شارك هذه الإجابة | Share this answer |
| shareOneHint | رابط لهذه الإجابة وحدها — بقيّة المحادثة تبقى عندك | A link to this answer alone — the rest of the chat stays with you |
| shareOneWait | ينشئ رابط الإجابة… | Creating the answer link… |
| shareOneCopied | تم نسخ رابط الإجابة ✓ | Answer link copied ✓ |
| shareOneFail | تعذّر إنشاء الرابط — تأكد من تسجيل الدخول واتصالك ثم أعد المحاولة | Couldn't create the link — check you're signed in and online, then retry |
| shareOneBusy | طلبات كثيرة بسرعة — انتظر دقيقة ثم أعد المحاولة | Too many requests — wait a minute, then try again |
| shareOneCap | وصلت إلى الحد الأقصى لروابط المشاركة في حسابك | You've reached the share-link limit on your account |
| shareOneNote | من يفتح الرابط يقرأ هذه الإجابة وحدها، ولا يرى بقيّة المحادثة. | Whoever opens the link reads this answer only — the rest of the conversation isn't there. |
| shareOneEyebrow | إجابة واحدة من محادثة | One answer from a conversation |
| download | تصدير | Download |
| downloadPdf / downloadWord / downloadExcel / downloadPpt | ملف PDF / مستند Word / جدول Excel / عرض PowerPoint | PDF document / Word document / Excel spreadsheet / PowerPoint slides |
| downloadHtml / downloadMarkdown / downloadText / downloadImage | صفحة HTML / ملف Markdown / نص عادي (TXT) / صورة | HTML page / Markdown file / Plain text (TXT) / Image |
| downloadPrint | طباعة / حفظ بصيغة PDF… | Print / Save as PDF… |
| printPreparing | يُحضّر نسخة الطباعة… | Preparing the print copy… |
| printUnavailable | الطباعة غير متاحة في هذا المتصفح — سيُنزَّل ملف PDF بدلًا منها. | Printing isn't available in this browser — downloading a PDF instead. |
| preparing | جارٍ التحضير… | Preparing… |
| formatUnavailable | هذا التنسيق غير متاح حاليًا. | That format is unavailable right now. |
| exportEmpty | لا يوجد محتوى للتصدير. | Nothing to export. |
| chatMd | احفظ المحادثة كاملة — أسئلتك وأجوبة فِراس — بملف Markdown واحد | Save the whole conversation — your questions and Firas's answers — as one Markdown file |
| chatMdDone | تم تنزيل ملف المحادثة ✓ | Conversation file downloaded ✓ |
| chatPrint | اطبع المحادثة كاملة — أسئلتك وأجوبة فِراس — على ورق أو بصيغة PDF | Print the whole conversation — your questions and Firas's answers — on paper or as a PDF |
| chatPrintFail | تعذّر فتح نافذة الطباعة في هذا المتصفّح. | This browser wouldn't open the print dialog. |
| fileReady / fileDownload | الملف جاهز / تنزيل | File ready / Download |
| fileNamePdf … fileNameCsv | firas-document.pdf / firas-document.docx / firas-data.xlsx / firas-presentation.pptx / firas-data.csv | (same) |
| fileLabelPdf / Docx / Xlsx / Pptx / Csv | مستند PDF / مستند Word / جدول Excel / عرض PowerPoint / ملف CSV | PDF document / Word document / Excel spreadsheet / PowerPoint slides / CSV file |
| fileCreating | جاري إنشاء الملف… | Creating your file… |
| fileViewContent / fileHideContent | عرض المحتوى / إخفاء المحتوى | View content / Hide content |
| showMore / showLess | عرض المزيد / عرض أقل | Show more / Show less |
| preview / previewTitle / previewRefresh / previewOpen / previewDownload / previewClose | معاينة / معاينة HTML / تحديث / فتح في تبويب جديد / تنزيل HTML / إغلاق | Preview / HTML preview / Refresh / Open in new tab / Download HTML / Close |
| qreplyAria | أسئلة متابعة مقترحة | Suggested follow-ups |
| qreplyAsk | اشرح لي «{q}» بتفصيل أكثر | Explain “{q}” in more detail |
| pinMsg / unpinMsg / pinBar | تثبيت الرسالة / إلغاء التثبيت / الرسائل المثبّتة | Pin message / Unpin / Pinned messages |
| pinFull | ما تقدر تثبّت أكثر من ١٢ رسالة بالمحادثة الوحدة | You can pin 12 messages in one chat |
| noteAdd / noteHas / noteHead | أضف ملاحظة / ملاحظتك / ملاحظة خاصة — لا يراها غيرك | Add a note / Your note / Private note — only you can see it |
| notePh / noteDel / noteGone | اكتب ملاحظتك على هذا الجواب… / احذف الملاحظة / حُذفت الملاحظة | Write your note on this answer… / Delete note / Note deleted |
| noteFull | ما تقدر تضيف أكثر من ٤٠ ملاحظة بالمحادثة الوحدة | You can keep 40 notes in one chat |
| chpBar / chpPrev / chpNext | فصول هذه الإجابة / الفصل السابق / الفصل التالي | Chapters in this answer / Previous chapter / Next chapter |
| shelfTitle / shelfSub | محفوظاتي / مقاطع احتفظت بها من الأجوبة — تبقى على هذا الجهاز وحده | My saves / Passages you kept from answers — they stay on this device only |
| shelfSave / shelfSaved | احفظ / محفوظ | Save / Saved |
| shelfSavedToast / shelfSavedSel | تم حفظ الجواب في محفوظاتي / تم حفظ المقطع المحدد | Answer saved to My saves / Selection saved |
| shelfDupe / shelfFull / shelfFail | هذا المقطع محفوظ من قبل / امتلأت المحفوظات — أُزيل الأقدم / تعذر الحفظ — مساحة الجهاز ممتلئة | That passage is already saved / The shelf is full — the oldest save was dropped / Couldn’t save — this device is out of storage |
| shelfSearch / shelfEmpty | ابحث في محفوظاتك / ما عندك شيء محفوظ بعد — ظلّل مقطعاً من أي جواب واضغط «احفظ»، أو احفظ الجواب كله | Search your saves / Nothing saved yet — highlight part of any answer and press “Save”, or save the whole answer |
| shelfNoHits / shelfFrom / shelfCopy / shelfOpen | ما في نتيجة تطابق بحثك / من / نسخ المقطع / افتح المحادثة | Nothing matches that search / From / Copy passage / Open the conversation |
| shelfDel / shelfDelAsk / shelfDelYes / shelfCancel | حذف / أحذف هذا المقطع؟ / احذف / إلغاء | Delete / Delete this passage? / Delete / Cancel |
| snipTitle / snipSub | قصاصاتي / مقاطع كود احتفظت بها من الأجوبة — تبقى على هذا الجهاز وحده | My snippets / Code you kept from answers — it stays on this device only |
| snipSave / snipSaved / snipSavedToast | احفظ / محفوظ / تم حفظ المقطع في قصاصاتي | Save / Saved / Snippet saved to My snippets |
| snipDupe / snipFull / snipFail | هذا المقطع محفوظ من قبل / امتلأت القصاصات — أُزيل الأقدم / تعذر الحفظ — مساحة الجهاز ممتلئة | That snippet is already saved / The snippet list is full — the oldest save was dropped / Couldn’t save — this device is out of storage |
| snipSearch / snipEmpty / snipNoHits / snipCopy / snipDelAsk / snipCut | ابحث في قصاصاتك / ما عندك قصاصة بعد — اضغط «احفظ» في رأس أي مقطع كود / ما في نتيجة تطابق بحثك / نسخ الكود / أحذف هذه القصاصة؟ / مقطوع — محفوظ جزء منه | Search your snippets / Nothing saved yet — press “Save” in the head of any code block / Nothing matches that search / Copy code / Delete this snippet? / Truncated — saved in part |

### Sidebar management
| key | ar | en |
|---|---|---|
| rename | إعادة تسمية | Rename |
| pin / unpin | تثبيت / إلغاء التثبيت | Pin / Unpin |
| pinned | المثبّتة | Pinned |
| pinnedStrip / pinnedTop | المحادثات المثبّتة / تبقى في أعلى القائمة | Pinned conversations / Kept at the top of the list |
| delete | حذف | Delete |
| deleteConfirm | حذف هذه المحادثة؟ | Delete this conversation? |
| chatDeleted | حُذفت المحادثة | Conversation deleted |
| chatDeletedStream | حُذفت المحادثة، وأُوقف الردّ الجاري | Conversation deleted; the reply in progress was stopped |
| dup / dupSuffix | تكرار المحادثة / نسخة | Duplicate conversation / copy |
| dupWait / dupDone / dupOpen / dupFail | جارٍ تحضير النسخة… / تم تكرار المحادثة / افتح النسخة / تعذّر تكرار المحادثة — حاول مرة أخرى | Preparing the copy… / Conversation duplicated / Open the copy / Couldn’t duplicate — try again |
| folders / newFolder | المجلّدات / مجلّد جديد | Folders / New folder |
| folderAdd / folderRename / folderDelete | إضافة محادثات / إعادة تسمية المجلّد / حذف المجلّد | Add conversations / Rename folder / Delete folder |
| folderDrop / folderPick / folderFilter / folderDone / folderNone | اسحب أي محادثة إلى هنا / اختر محادثات لهذا المجلّد / ابحث عن محادثة / تم / ما في محادثات هنا | Drag any conversation here / Pick conversations for this folder / Find a conversation / Done / No conversations here |
| folderMoved | انتقلت إلى «{name}» | Moved to “{name}” |
| folderGone | حُذف المجلّد — المحادثات باقية مكانها | Folder deleted — the conversations stayed |
| folderMax | بلغت أقصى عدد من المجلّدات | You have reached the folder limit |
| tagLabel / tagPick / tagClear / tagBar / tagAll / tagEmpty | لون المحادثة / اختر لونًا لهذه المحادثة / بلا لون / تصفية بالألوان / الكل / لا محادثة بهذا اللون | Conversation colour / Pick a colour for this conversation / No colour / Filter by colour / All / No conversation carries that colour |
| tagRed / tagAmber / tagGreen / tagTeal / tagBlue / tagPurple | أحمر / كهرماني / أخضر / فيروزي / أزرق / بنفسجي | Red / Amber / Green / Teal / Blue / Purple |
| bsSelect / bsSelected / bsAll / bsNone / bsDone | تحديد عدّة محادثات / محدّدة / تحديد الكل / إلغاء التحديد / تمّ | Select several / selected / Select all / Clear / Done |
| bsPin / bsUnpin / bsTag / bsFold / bsExport / bsDelete | تثبيت المحدّد / إلغاء تثبيت المحدّد / لون المحدّد / نقل المحدّد إلى مجلّد / تصدير المحدّد / حذف المحدّد | Pin selected / Unpin selected / Colour selected / Move selected to a folder / Export selected / Delete selected |
| bsEmpty / bsMax / bsUnfile / bsNoFolders | لم تُحدّد أي محادثة / بلغت أقصى عدد للتحديد / إخراج من المجلّدات / لا مجلّدات بعد | Nothing is selected / That is as many as you can select at once / Take out of folders / No folders yet |
| bsPinned / bsUnpinned / bsTagged / bsUncoloured / bsUnfiled | ثُبّتت المحادثات / أُلغي تثبيت المحادثات / تلوّنت المحادثات / أُزيل اللون / أُخرجت من المجلّدات | Conversations pinned / Conversations unpinned / Conversations coloured / Colour removed / Taken out of their folders |
| bsExporting / bsExported / bsDeleted / bsDeletedStream | جارٍ التصدير… / نُزّل ملفّ المحادثات / حُذفت المحادثات / حُذفت المحادثات، وأُوقفت الردود الجارية | Exporting… / Conversations file downloaded / Conversations deleted / Conversations deleted; the replies in progress were stopped |
| mgMerge / mgNeedTwo / mgBusy / mgWait | دمج محادثتين / اختر محادثتين بالضبط / لا يمكن الدمج أثناء كتابة ردّ / جارٍ إحضار المحادثتين… | Merge two conversations / Pick exactly two conversations / Can’t merge while a reply is being written / Fetching both conversations… |
| mgEmpty / mgTooLong / mgFail / mgDone / mgFrom | إحدى المحادثتين فارغة / المحادثتان معًا أطول ممّا تتّسع له محادثة واحدة / تعذّر الدمج / دُمجت المحادثتان — والأحدث بقيت كما هي / تكملة من: {name} | One of them has nothing in it / Together they are longer than one conversation can hold / Couldn’t merge / Merged — the newer one was kept / Continued from {name} |
| msgHits / msgHitsScope / msgHitsScopeAll | داخل الرسائل / من المحادثات المفتوحة فقط / من كل المحادثات هنا | In messages / opened conversations only / all conversations here |
| msgHitsNone / msgHitsNoneAll | ما في شيء داخل الرسائل المفتوحة. / ما في شيء داخل أي محادثة هنا. | Nothing in the opened conversations. / Nothing in any conversation here. |
| msgHitYou / msgHitAi | أنت / فِراس | You / Firas |
| searchAll / searchAllN / searchAllRun / searchAllCancel / searchAllDone / searchAllFail | ابحث في كل المحادثات / بقيت {n} غير محمّلة / جارٍ التحميل / إلغاء / تم البحث في كل المحادثات. / تعذّر تحميل {n} منها. | Search every conversation / {n} not loaded / Loading / Cancel / Every conversation searched. / Couldn't load {n} of them. |
| findHere / findHerePh / findHereNext / findHerePrev / findHereClose / findHereNone | ابحث في هذه المحادثة / ابحث في المحادثة… / النتيجة التالية / النتيجة السابقة / إغلاق البحث / لا نتائج في هذه المحادثة | Search this conversation / Find in this conversation… / Next match / Previous match / Close search / No matches in this conversation |
| relatedHead / relatedShared | محادثات قريبة من هذه / كلمات مشتركة | Related conversations / shared words |
| relatedTip | أقرب ثلاث محادثات إلى هذه، محسوبة على جهازك من الكلمات المشتركة وحدها — دون أي طلب. | The three closest to this one, worked out on your device from the words they share — nothing is sent. |
| tocLabel / tocTick / msgIndexTip | فهرس أسئلتك في هذه المحادثة / سؤال {n} / رقم الرسالة | Index of your questions in this chat / Question {n} / Message number |

### Guest, landing, session
| key | ar | en |
|---|---|---|
| landingAbout | أربعة منتجات بحساب واحد: محادثة، ووكيل ينفّذ المهام الطويلة خطوة بخطوة، وبيئة برمجة كاملة داخل المتصفح، ومكتبة تقرأ ملفاتك وتجيب منها — مع رقم الصفحة، حتى تتحقّق بنفسك. | Four products, one account: chat, an agent that works through long tasks step by step, a full development environment in the browser, and a library that reads your own files and answers from them — with the page number, so you can check it yourself. |
| landingStart | ابدأ الآن — بدون حساب | Get Started — no account |
| landingSignIn | لديك حساب؟ تسجيل الدخول | Already have an account? Sign in |
| landingGuestHint | ادخل فورًا وجرّب فِراس. سجّل لاحقًا لحفظ محادثاتك. | Jump straight in and try Firas. Sign up later to save your chats. |
| landingFeaturesTitle | لماذا فِراس AI؟ | Why Firas AI? |
| landingFeaturesSub | منصّة ذكاء اصطناعي متكاملة، تتحدّث العربية والإنجليزية بطلاقة — كل ما تحتاجه في مكان واحد. | A complete AI platform — fluent in Arabic and English, with everything you need in one place. |
| landingFeatures[0] spark | أربعة نماذج ذكية — «ميني» للسرعة، و«برو» للمهام اليومية، و«أولترا» للأسئلة الصعبة والبرمجة، و«ماكس» الأقوى للأسئلة الصعبة والتحليل العميق في كل المجالات. | Four smart models — “Mini” for speed, “Pro” for everyday tasks, “Ultra” for hard questions & coding, and “Max” — the strongest for hard questions & deep analysis across every field. |
| landingFeatures[1] code | فِراس Code — برمجة كاملة بالمتصفح — بيئة تطوير حقيقية داخل التطبيق: مشاريع متعددة الملفات، ومعاينة حيّة — صِف فكرتك ويبنيها فِراس. | Firas Code — a full in-browser IDE — A real dev environment inside the app: multi-file projects and live preview — describe your idea and Firas builds it. |
| landingFeatures[2] devices | فِراس Agent — وكيل المهام الكبيرة — يخطّط وينفّذ خطوة بخطوة ويراجع عمله بنفسه، ثم يسلّمك ملفات ومشاريع كاملة جاهزة للتسليم. | Firas Agent — for big tasks — Plans, executes step by step, reviews its own work, then hands you complete, ready-to-submit files and projects. |
| landingFeatures[3] brain | فِراس Brain — يجيب من ملفاتك أنت — ارفع كتبك ومحاضراتك وامتحاناتك — بصيغها المختلفة، حتى المصوّرة — واسأل. الجواب يأتي من داخل ملفك مع اسم الملف ورقم الصفحة، تضغط عليه فيفتح لك النص نفسه. | Firas Brain — answers from your own files — Upload your books, lectures and past papers — any format, including scans — and ask. The answer comes from inside your file, with the filename and page number; click it and the passage itself opens. |
| landingFeatures[4] file | ملفات وامتحانات جاهزة — يولّد PDF وWord وExcel وPowerPoint بخطوط عربية أنيقة — وأسئلة مع حلولها بتنسيق ورقة امتحان حقيقية. | Ready files & exam papers — Generates PDF, Word, Excel and PowerPoint with elegant Arabic fonts — plus questions with solutions in a real exam-paper layout. |
| landingFeatures[5] search | بحث الويب المباشر — يجلب معلومات حديثة من الإنترنت ويجيبك مع ذكر المصادر القابلة للنقر. | Live web search — Pulls fresh information from the internet and answers with clickable sources. |
| landingFeatures[6] bulb | وضع التفكير — تحليل أعمق ودقّة أعلى عند تفعيله — مثالي للأسئلة المعقّدة والمسائل المنطقية. | Thinking mode — Deeper analysis and higher accuracy when enabled — ideal for complex, logical problems. |
| landingImageBadge / landingImageTitle | تجريبي / ميزة توليد الصور | Beta / Image generation |
| landingImageBody | أُطلقت حديثًا وما زالت قيد التطوير، لذا قد تتحسّن النتائج تدريجيًا. الحدّ الحالي: ٥ صور في اليوم لكل مستخدم. جرّبها بكتابة «اصنع لي صورة…» داخل المحادثة. | Recently launched and still under active development, so results will keep improving. Current limit: 5 images per day per user. Try it by typing “create an image of…” in the chat. |
| guestName / guestBadge | ضيف / وضع الضيف | Guest / Guest mode |
| signUpNow / signUpNowEn | سجّل الآن / Sign up now | Sign up now / سجّل الآن |
| guestLocalNote | محادثاتك كضيف محفوظة على هذا الجهاز فقط. | Guest chats are stored on this device only. |
| guestImageTitle / guestImageBody | توليد الصور يحتاج حسابًا / أنشئ حسابًا مجانيًا خلال ثوانٍ لتوليد الصور، وحفظ محادثاتك، ورفع حدّك اليومي. | Image generation needs an account / Create a free account in seconds to generate images, save your chats, and raise your daily limit. |
| guestFeatureTitle / guestFeatureBody | هذه الميزة تحتاج حسابًا / أنشئ حسابًا مجانيًا لتفعيلها — يستغرق أقل من دقيقة. | This feature needs an account / Create a free account to unlock it — it takes less than a minute. |
| guestUpgradeCta / guestLater | إنشاء حساب مجاني / لاحقًا | Create a free account / Later |
| guestLimitReached | انتهت رسائلك المجانية لهذا اليوم كضيف. أنشئ حسابًا مجانيًا للحصول على حدّ أعلى بكثير. | You have used today's free guest messages. Create a free account for a much higher limit. |
| guestExit / guestExitConfirm | الخروج من وضع الضيف / سيتم مسح محادثات الضيف من هذا الجهاز. متابعة؟ | Exit guest mode / Guest chats on this device will be cleared. Continue? |
| guestMigrated | تم نقل محادثاتك إلى حسابك ✓ | Your chats were moved to your account ✓ |
| authNetworkError | تعذّر الاتصال بالخادم. تحقّق من اتصالك. | Couldn't reach the server. Check your connection. |
| authGenericError | تعذّر إتمام العملية. حاول مرة أخرى. | Something went wrong. Please try again. |

### Image card (answer-language strings, `app.js:778-800`)
| key | ar | en |
|---|---|---|
| imgCardQ / imgCardWorking / imgCardDone | السؤال / يُحضّر الصورة… / تم تنزيل الصورة ✓ | Question / Preparing the image… / Image downloaded ✓ |
| imgNoteAdd / imgNoteEdit / imgNotePh / imgNoteSaved / imgNoteCleared / imgNoteLabel | أضف تعليقًا / عدّل التعليق / اكتب تعليقًا قصيرًا على الصورة… / حُفظ التعليق ✓ / أُزيل التعليق / تعليق | Add a caption / Edit caption / Write a short caption… / Caption saved ✓ / Caption removed / Caption |
| imgFailed / imgRetry / imgRegen / imgRetrying | تعذّر توليد الصورة / إعادة المحاولة / أعد التوليد / جارٍ… | Image generation failed / Try again / Regenerate / Working… |
| imgWhyEngine / imgWhyNet / imgWhyQuota / imgWhySignin / imgSaveFailed | لم يُعدِ المحرّك صورة. / تعذّر الوصول إلى الصورة — تحقّق من اتّصالك. / بلغت حدّك اليومي من الصور. الحدّ يتجدّد غدًا. / انتهت جلستك. سجّل الدخول ثمّ أعد المحاولة. / تعذّر حفظ الصورة. | The engine returned no picture. / The picture could not be fetched — check your connection. / You have reached today's image limit. It resets tomorrow. / Your session ended. Sign in and try again. / The image could not be saved. |
| imgCardTrimmed | عنصر واحد أطول من الصورة فظهر مقصوصًا — نزّل الإجابة بصيغة PDF لقراءته كاملًا. | One block is taller than the image and is clipped here — export the PDF to read it in full. |

### Settings panel copy (inline `tx`, `app.js:45615-45685`) — subset relevant here
| key | ar | en |
|---|---|---|
| title / sub | الإعدادات / إدارة حسابك وأمانه | Settings / Manage your account & security |
| tabAccount / tabLook / tabChat / tabVoice / tabData | الحساب / المظهر / المحادثة / الصوت / البيانات | Account / Appearance / Chat / Voice / Data |
| themeH / themeSub | الثيم / ستة أمزجة | Theme / six moods |
| themeLight / themeDark | نهاري / ليلي | Light / Dark |
| readingH / fsSmall / fsMedium / fsLarge | حجم النص / صغير / متوسط / كبير | Text size / Small / Medium / Large |
| widthH / widthNormal / widthWide | عرض القراءة / عادي / واسع | Reading width / Normal / Wide |
| motionH / motionFull / motionReduce | الحركة / كاملة / مخفّفة | Motion / Full / Reduced |
| langH / langAr / langEn | لغة الواجهة / العربية / English | Interface language / العربية / English |
| modelH / modelSub / modelSet | النموذج الافتراضي / للمحادثات الجديدة / تم تعيين النموذج الافتراضي ✓ | Default model / for new conversations / Default model set ✓ |
| behaveH | سلوك الردّ | Reply behaviour |
| thinkLbl / thinkHint | التفكير العميق / أبطأ وأدقّ في المسائل الصعبة | Deep thinking / slower, more careful on hard questions |
| webLbl / webHint | البحث في الويب / يبحث قبل كلّ ردّ | Web search / searches before every reply |
| enterLbl / enterHint | الإرسال بمفتاح Enter / و Shift+Enter لسطر جديد | Send with Enter / Shift+Enter for a new line |
| ui2H / ui2Lbl | المظهر الجديد / واجهة 2.0 | New look / UI 2.0 |
| ui2Hint | شريط دائم للمنتجات الأربعة، ولوحة جانبية تعرض خطوات الوكيل ومصادر البرين مع أرقام صفحاتها — نفس كل الميزات بالضبط | a permanent rail for all four products, plus a pinned panel showing Agent steps and Brain sources with their page numbers — every feature unchanged |
| imgH / srLbl / srHint | الصور / شحذ الصور تلقائيًّا / شبكة تعمل على جهازك — ثانية أو اثنتان، وبلا أي كلفة | Images / Sharpen pictures automatically / a network on your own device — a second or two, and free |
| voiceH / voiceSub / voiceNote | صوت المكالمة / يُطبَّق على مكالمتك القادمة / أصوات المكالمة المباشرة. جرّب حتى تجد الأقرب إلى أذنك. | Call voice / applies to your next call / Live-call voices. Try a few until one sounds right. |
| dictH / dictSub | لهجة الإملاء / حين تُملي كلامك نصّاً | Dictation dialect / when you speak instead of type |
| convH / convSub / exportBtn / importBtn | المحادثات / احفظ محادثاتك في ملف احتياطي، أو استعدها لاحقاً. / تصدير نسخة / استيراد من ملف | Conversations / Save your chats to a backup file, or restore them later. / Export backup / Import file |
| storageH / storageSub / clearBtn / clearConfirm | التخزين / يمسح تفضيلات هذا الجهاز فقط — محادثاتك محفوظة في حسابك. / مسح بيانات الجهاز / مسح تفضيلات هذا الجهاز وإعادة التحميل؟ محادثاتك لن تُحذف. | Storage / Clears this device's preferences only — your chats live safely in your account. / Clear device data / Clear this device's preferences and reload? Your chats won't be deleted. |
| guestH / guestCta | أنت تتصفّح كضيف / أنشئ حسابًا مجانيًا | You’re browsing as a guest / Create a free account |
| guestP | محادثاتك محفوظة على هذا الجهاز وحده، ولا يوجد حساب بعد — فلا بريد ولا كلمة مرور ولا حذف حساب هنا. أنشئ حسابًا مجانيًا وتنتقل محادثاتك إليه كما هي. | Your conversations are saved on this device only, and there is no account yet — so there is no email, no password and no account to delete here. Create a free account and these chats move into it exactly as they are. |
| guestStorageSub | يمسح تفضيلات هذا الجهاز فقط — محادثاتك كضيف محفوظة على هذا الجهاز ولن تُمسح. | Clears this device’s preferences only — your guest chats live on this device and are kept. |
| aboutH / versionLbl / updatesLink | عن التطبيق / الإصدار / عرض آخر التحديثات | About / Version / See what's new |
| dangerH / delBtn / delFinal / cancel | منطقة الخطر / حذف حسابي / حذف نهائي / إلغاء | Danger zone / Delete my account / Delete permanently / Cancel |

### Inline (non-STR) strings referenced above
| where | ar | en |
|---|---|---|
| Unsupported attachment (`app.js:36082`) | نوع ملف غير مدعوم | Unsupported file type |
| Files too large (`app.js:36095`) | حجم الملفات كبير جداً | Files too large |
| No text in file (`app.js:36116`) | ما كدرت أقرأ نص من الملف | No readable text in file |
| Read file failed (`app.js:36129`) | تعذّر قراءة الملف | Couldn't read file |
| Read image failed (`app.js:36162`) | تعذّر قراءة الصورة | Couldn't read image |
| Chip reading (`app.js:36223`) | ...قراءة | reading… |
| Enlarge (`app.js:22977`) | اضغط للتكبير | Click to enlarge |
| Searching (`app.js:42463`) | يبحث في الإنترنت… | Searching the web… |
| Generic 429 (`app.js:42715`) | طلبات كثيرة بسرعة — انتظر لحظة ثم حاول مجددًا. | Too many requests too fast — wait a moment and try again. |
| Session expired (`app.js:3249`) | انتهت جلستك. الرجاء تسجيل الدخول من جديد. | Your session expired. Please sign in again. |
| Sidebar retry (`app.js:19064-19067`) | إعادة المحاولة / جارٍ المحاولة… | Try again / Retrying… |
| Live row (`app.js:19612`) | ما زالت تشتغل | still working |
| Share chat (`app.js:79690-79711`) | افتح محادثة فيها رسائل أولًا / ينشئ رابط المشاركة… / تم نسخ رابط المشاركة ✓ / تعذّر إنشاء الرابط — تأكد من تسجيل الدخول واتصالك ثم أعد المحاولة | Open a chat with messages first / Creating share link… / Share link copied ✓ / Couldn't create the link — check you're signed in and online, then retry |
| Code card (`app.js:6820-6889`) | لفّ الأسطر / لا تلفّ / معاينة / نسخ / تم نسخ الكود / تعذّر النسخ / تحميل / كمّل / الكود غير مكتمل؟ / كمّل الكود / يكتب الكود… | Wrap / No wrap / Preview / Copy / Code copied / Copy failed / Download / Continue / Code cut off? / Continue code / Writing code… |
| Present (`app.js:29684`) | اعرض | Present |
| Announcements panel (`app.js:44978-45004`) | تحديثات Firas AI / آخر أخبار وتحديثات المنصّة. / لا توجد تحديثات بعد. / مثبّت / فيديو / تحديث | Firas AI updates / Latest platform news & updates. / No updates yet. / Pinned / Video / Update |
| Plan card (`app.js:45345-45349`) | الاشتراك / ✦ مجاني بالكامل / كل مزايا فِراس متاحة للجميع مجانًا. يحصل كل حساب على ٥٠٠ كريديت في Firas Agent تتجدد يوميًا. | Plan / Free — everything included / Every Firas feature is available free. Each account receives 500 Firas Agent credits refreshed daily. |
| Agent busy (`app.js:44441-44449`) | المهمة الحالية قيد التنفيذ هنا. بقي النص الجديد محفوظًا. / توجد مهمة قيد التنفيذ؛ فُتحت لمتابعتها. بقي النص الجديد محفوظًا هنا. / توجد مهمة قيد التنفيذ. حدّث قائمة المحادثات لعرضها؛ بقي النص الجديد محفوظًا. | Your current task is already running here. Your new draft stays saved. / You already have a task running; opening it now. Your new draft stays saved here. / You have a task running. Refresh the conversation list to find it; your new draft stays saved. |
| Agent welcome sub (`app.js:20204-20206`) | وكيل ذكي للمهام الكبيرة: يخطّط، ينفّذ خطوة بخطوة، يراجع عمله بنفسه، ثم يسلّمك ملفات ومشاريع جاهزة. | An autonomous agent for big tasks: it plans, executes step by step, reviews its own work, then delivers ready files and projects. |
| Agent placeholder (`app.js:59961-59963`) | كلّف فِراس بمهمة صعبة | Give Firas a hard task |
| Stage labels (`app.js:38801-38805`) | يقرأ الصورة ويستخرج كل المحتوى… / يخطّط لهيكل الملف… / يكتب المحتوى… / يراجع الدقة والبنية والمعادلات… / يجمّع ويُخرج باحتراف… | Reading the image & extracting everything… / Planning the file… / Writing the content… / Checking accuracy, structure & equations… / Assembling & polishing… |
| Interface language toast (`app.js:46036`) | تم تغيير لغة الواجهة ✓ | Interface language changed ✓ |
