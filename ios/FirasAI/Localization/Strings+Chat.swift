import Foundation

/// Every user-visible string of the chat surface: the screen chrome, the welcome, the tier and mode
/// pickers, the message rows, their actions, the plan cycle and the `firas-ask` panel, plus the
/// composer copy the composer owner needs (the composer has no `Strings` file of its own).
///
/// Arabic is verbatim from the web `STR` tables cited in `web-chat-ux.md` Appendix A and
/// `web-plan-mode.md §1.1`; strings marked `[new]` exist only natively and are named in
/// `design-brief.md §7`.
extension Strings {
    enum Chat {

        // MARK: - Screen chrome

        static let newChat = LText(ar: "محادثة جديدة", en: "New chat")
        static let newChatShort = LText(ar: "جديد", en: "New")
        static let openDrawer = LText(ar: "المحادثات", en: "Conversations")
        static let gallery = LText(ar: "صور المحادثة", en: "Chat images")
        static let galleryTitle = LText(ar: "صور هذه المحادثة", en: "Images in this chat")
        static let galleryEmpty = LText(
            ar: "لا توجد صور في هذه المحادثة بعد.",
            en: "No images in this conversation yet."
        )

        /// The line under the composer, on every chat product.
        static let disclaimer = LText(
            ar: "قد يخطئ فِراس. تحقّق من المعلومات المهمة.",
            en: "Firas can make mistakes. Check important info."
        )

        static let streaming = LText(ar: "يكتب فِراس...", en: "Firas is typing…")
        static let thinkingLive = LText(ar: "فِراس يفكّر…", en: "Firas is thinking…")
        static let searchingWeb = LText(ar: "يبحث في الإنترنت…", en: "Searching the web…")
        static let readingAttachments = LText(ar: "يقرأ المرفقات…", en: "Reading attachments…")
        static let busyWait = LText(
            ar: "انتظر حتى ينتهي الرد الحالي",
            en: "Wait for the current reply to finish"
        )

        // MARK: - Banners

        static let errorTitle = LText(ar: "تعذّر الاتصال.", en: "Couldn't connect.")
        static let chatsLoadError = LText(ar: "تعذّر تحميل المحادثات.", en: "Couldn't load conversations.")

        /// `[new]` — the offline strip above the transcript.
        static let offlineBanner = LText(
            ar: "لا يوجد اتصال — تقدر تقرأ محادثاتك المحفوظة فقط.",
            en: "You're offline — you can read your saved conversations only."
        )

        /// `[new]` — the history window note (`HistoryWindow` trimmed the turns that leave the device).
        static let historyTrimmed = LText(
            ar: "المحادثة طويلة — يُرسَل آخر جزء منها فقط إلى النموذج.",
            en: "This conversation is long — only its latest part is sent to the model."
        )

        static let sessionExpiredSignIn = LText(ar: "تسجيل الدخول", en: "Sign in")

        static let outboxHeld = LText(
            ar: "لم تُرسَل رسالتك — لا يوجد اتصال. سنرسلها فور عودته.",
            en: "Your message didn't go out — there's no connection. It will be sent the moment it's back."
        )
        static let outboxReady = LText(
            ar: "عاد الاتصال — رسالتك لم تُرسَل بعد.",
            en: "The connection is back — your message still hasn't been sent."
        )
        static let outboxSend = LText(ar: "أرسلها الآن", en: "Send it now")
        static let undoSend = LText(
            ar: "أُرسلت رسالتك — التراجع يعيدها ويوقف الردّ",
            en: "Message sent — undo puts it back and stops the reply"
        )

        static let scrollToBottom = LText(ar: "انتقل إلى آخر الرسائل", en: "Scroll to the latest")

        // MARK: - Welcome

        static let greetingMorning = LText(ar: "صباح الخير", en: "Good morning")
        static let greetingAfternoon = LText(ar: "مساء الخير", en: "Good afternoon")
        static let greetingEvening = LText(ar: "مساءً سعيدًا", en: "Good evening")
        /// `%@` = greeting base, `%@` = first name.
        static let greetingWithName = LText(ar: "%@ يا %@", en: "%@, %@")

        static let agentWelcomeTitle = LText(ar: "Firas Agent", en: "Firas Agent")
        static let agentWelcomeSubtitle = LText(
            ar: "وكيل ذكي للمهام الكبيرة: يخطّط، ينفّذ خطوة بخطوة، يراجع عمله بنفسه، ثم يسلّمك ملفات ومشاريع جاهزة.",
            en: "An autonomous agent for big tasks: it plans, executes step by step, reviews its own work, then delivers ready files and projects."
        )
        static let brainWelcomeTitle = LText(ar: "Firas Brain", en: "Firas Brain")
        static let brainWelcomeSubtitle = LText(
            ar: "اسأل ملفاتك — بإجابات موثّقة بالصفحة.",
            en: "Ask your files — every answer cites its page."
        )

        // MARK: - Tier picker

        /// `[new]` — the web sheet has no title.
        static let modelSheetTitle = LText(ar: "النموذج", en: "Model")
        static let modelPickerHint = LText(ar: "اختر نموذج فِراس", en: "Choose a Firas model")
        static let responseStyle = LText(ar: "أسلوب الردّ", en: "Response style")

        static let thinkLabel = LText(ar: "التفكير", en: "Thinking")
        static let thinkOn = LText(ar: "التفكير مُفعّل — دقة أعلى", en: "Thinking on — higher accuracy")
        static let thinkOff = LText(ar: "التفكير مُعطّل — استجابة أسرع", en: "Thinking off — faster replies")

        static let webSearch = LText(ar: "بحث الويب", en: "Web search")
        static let searchOn = LText(
            ar: "بحث الويب مُفعّل — يبحث في كل رسالة",
            en: "Web search on — searches every message"
        )
        static let searchOff = LText(
            ar: "بحث الويب تلقائي — يبحث عند الحاجة",
            en: "Web search auto — searches when needed"
        )

        // MARK: - Mode (Auto / Plan)

        static let modeLabel = LText(ar: "النمط", en: "Mode")
        static let modeAuto = LText(ar: "تلقائي", en: "Auto")
        static let modeAutoHint = LText(ar: "ذكي ومباشر — يجيب فورًا.", en: "Smart & direct — answers right away.")
        static let modePlan = LText(ar: "تخطيط", en: "Plan")
        static let modePlanHint = LText(
            ar: "يسأل ويضع خطة، ثم ينفّذ بعد موافقتك.",
            en: "Asks & plans first, then executes once you approve."
        )
        /// `[new]` — shown once when the mode changes in the middle of a live plan cycle.
        static let modeSwitchedMidCycle = LText(
            ar: "النمط الجديد يبدأ من رسالتك القادمة — الخطة الحالية تكمل كما هي.",
            en: "The new mode starts with your next message — the current plan finishes as it is."
        )

        static let planStart = LText(ar: "ابدأ التنفيذ", en: "Start")
        static let planStartHint = LText(
            ar: "موافقة على الخطة وبدء التنفيذ",
            en: "Approve the plan and start executing"
        )
        static let planApproval = LText(ar: "ابدأ التنفيذ ونفّذ الخطة.", en: "Go ahead and execute the plan.")

        // MARK: - firas-ask panel

        static let askRecommended = LText(ar: "موصى به", en: "Recommended")
        static let askContinue = LText(ar: "متابعة", en: "Continue")
        static let askBack = LText(ar: "السابق", en: "Back")
        static let askSubmit = LText(ar: "تأكيد الاختيارات", en: "Confirm")
        /// `%@` = step number, `%@` = total (Arabic-Indic digits in Arabic).
        static let askStep = LText(ar: "سؤال %@ / %@", en: "Question %@ / %@")
        static let askExtraPlaceholder = LText(ar: "أو أضف تفصيلاً…", en: "Or add a detail…")
        static let askAnswered = LText(ar: "تم الإرسال", en: "Sent")
        static let askMyChoices = LText(ar: "اختياراتي", en: "My choices")
        static let askPreparing = LText(ar: "جاري تحضير الأسئلة…", en: "Preparing questions…")

        // MARK: - Message rows

        static let assistantName = LText(ar: "FIRAS", en: "FIRAS")
        static let assistantNameAgent = LText(ar: "Firas Agent", en: "Firas Agent")
        static let showMore = LText(ar: "عرض المزيد", en: "Show more")
        static let showLess = LText(ar: "عرض أقل", en: "Show less")
        static let fileViewContent = LText(ar: "عرض المحتوى", en: "View content")
        static let fileHideContent = LText(ar: "إخفاء المحتوى", en: "Hide content")
        static let attachedImage = LText(ar: "صورة مرفقة", en: "Attached image")
        static let attachedFile = LText(ar: "ملف مرفق", en: "Attached file")
        static let messageFailed = LText(ar: "تعذّر إرسال هذه الرسالة.", en: "This message wasn't sent.")
        static let messageStopped = LText(ar: "أوقفت الردّ.", en: "You stopped the reply.")

        static let retryWasRetried = LText(
            ar: "أُعيد هذا الجواب بنموذج أقوى",
            en: "This answer was retried on a stronger model"
        )
        static let retryStronger = LText(ar: "أُعيد بنموذج أقوى", en: "Retried on a stronger model")

        static let qreplyAria = LText(ar: "أسئلة متابعة مقترحة", en: "Suggested follow-ups")
        /// `%@` = the topic lifted from the answer.
        /* WHAT FIRAS IS DOING, while the card that will say it is still being written.
           The owner asked for these three by name. */
        static let writingSong = LText(
            ar: "فِراس يكتب الأغنية…",
            en: "Firas is writing the song…"
        )
        static let planningImage = LText(
            ar: "فِراس يخطّط للصورة…",
            en: "Firas is planning the picture…"
        )
        static let planningVideo = LText(
            ar: "فِراس يخطّط للفيديو…",
            en: "Firas is planning the clip…"
        )
        static let preparingCard = LText(
            ar: "فِراس يُجهّز…",
            en: "Firas is preparing it…"
        )
        static let qreplyAsk = LText(ar: "اشرح لي «%@» بتفصيل أكثر", en: "Explain “%@” in more detail")

        // MARK: - Versions

        static let verLabel = LText(ar: "نسخة", en: "Version")
        static let verPrev = LText(ar: "النسخة السابقة", en: "Previous version")
        static let verNext = LText(ar: "النسخة التالية", en: "Next version")
        static let verHint = LText(
            ar: "أكثر من إجابة لنفس السؤال — قلّب بينهن وخلّي اللي تعجبك",
            en: "More than one answer to the same question — flip between them and keep the one you prefer"
        )
        /// `%@` = current index, `%@` = total.
        static let verCounter = LText(ar: "%@ / %@", en: "%@ / %@")

        // MARK: - Actions

        static let regenerate = LText(ar: "إعادة التوليد", en: "Regenerate")
        static let regenSame = LText(ar: "بالنموذج نفسه", en: "Same model")
        static let regenMax = LText(ar: "أعد بـ فِراس ماكس", en: "Retry with Firas Max")
        static let listen = LText(ar: "اسمع", en: "Listen")
        static let listenStop = LText(ar: "إيقاف", en: "Stop")
        static let more = LText(ar: "المزيد", en: "More")
        static let download = LText(ar: "تصدير", en: "Download")
        static let downloadMarkdown = LText(ar: "ملف Markdown", en: "Markdown file")
        static let downloadText = LText(ar: "نص عادي (TXT)", en: "Plain text (TXT)")
        static let exportEmpty = LText(ar: "لا يوجد محتوى للتصدير.", en: "Nothing to export.")
        static let continueAnswer = LText(ar: "أكمل", en: "Continue")
        static let continueHint = LText(
            ar: "يبدو أن الجواب توقّف قبل أن يكتمل — اضغط لإكماله",
            en: "This answer looks cut off — continue it"
        )
        static let shareOne = LText(ar: "شارك هذه الإجابة", en: "Share this answer")
        static let shareOneHint = LText(
            ar: "رابط لهذه الإجابة وحدها — بقيّة المحادثة تبقى عندك",
            en: "A link to this answer alone — the rest of the chat stays with you"
        )

        /// `[new]` — the native translate action (members only).
        static let translateAction = LText(ar: "ترجم هذه الإجابة", en: "Translate this answer")
        static let translateWorking = LText(ar: "يُترجم…", en: "Translating…")
        static let translateTitle = LText(ar: "الترجمة", en: "Translation")
        static let translateHide = LText(ar: "أخفِ الترجمة", en: "Hide translation")
        static let translateFailed = LText(ar: "تعذّرت الترجمة — حاول مرة أخرى", en: "Couldn't translate — try again")

        // MARK: - Composer (owned by the composer file, worded here)

        static let composerPlaceholder = LText(ar: "اسأل فِراس...", en: "Ask Firas…")
        static let composerPlaceholderAgent = LText(ar: "كلّف فِراس بمهمة صعبة", en: "Give Firas a hard task")
        static let composerPlaceholderBrain = LText(ar: "اسأل عن ملفاتك…", en: "Ask about your files…")
        static let composerPlaceholderBrainEmpty = LText(ar: "ارفع ملفًا أولًا", en: "Upload a file first")
        static let attachHint = LText(ar: "إرفاق ملف", en: "Attach a file")
        static let agentAttachHint = LText(
            ar: "إرفاق ملفات وصور إلى المهمة",
            en: "Attach files and images to the mission"
        )
        static let dropToAttach = LText(ar: "أفلت الملفات هنا للإرفاق", en: "Drop files here to attach")
        static let micLabel = LText(ar: "إدخال صوتي", en: "Voice input")
        static let micHint = LText(
            ar: "إدخال صوتي — اضغط مطوّلًا لاختيار اللهجة",
            en: "Voice input — long-press to pick a dialect"
        )
        static let micLangTitle = LText(ar: "لغة الإملاء", en: "Dictation language")
        static let callLabel = LText(ar: "مكالمة صوتية", en: "Voice call")
        static let agentCannotStop = LText(
            ar: "المهمة تكمل على الخادم — ما تقدر توقفها",
            en: "The mission keeps running on the server — it can't be stopped"
        )

        /// `%@` = character count (Arabic-Indic digits in Arabic).
        static let lenmChars = LText(ar: "الأحرف %@", en: "%@ chars")
        /// `%@` = token estimate.
        static let lenmTokens = LText(ar: "الرموز ≈%@", en: "≈%@ tokens")
        /// `%@` = the model's short name.
        static let lenmNear = LText(ar: "اقترب من حدّ %@", en: "near the %@ limit")
        /// `%@` = the model's short name.
        static let lenmOver = LText(ar: "تجاوز حدّ %@", en: "over the %@ limit")
        /// `%@` = the hard character cut.
        static let lenmTip = LText(
            ar: "تقدير تقريبي. ما يتجاوز %@ حرف قد يُقصّ عند حفظ الرسالة — قسّمها أو أرفق النصّ كملف.",
            en: "A rough estimate. Past %@ characters a saved message may be cut — split it, or attach the text as a file."
        )

        static let slashTitle = LText(ar: "أوامر سريعة", en: "Quick commands")
        static let slashSummarize = LText(ar: "تلخيص", en: "Summarize")
        static let slashSummarizeHint = LText(ar: "اختصر نصًا طويلًا إلى نقاط", en: "Boil a long text down to points")
        static let slashSummarizeBody = LText(
            ar: "لخّص لي النص التالي في نقاط مركّزة، مع الإبقاء على كل فكرة أساسية وحذف الحشو:\n\n",
            en: "Summarize the text below into tight points — keep every key idea, cut the filler:\n\n"
        )
        static let slashTranslate = LText(ar: "ترجمة", en: "Translate")
        static let slashTranslateHint = LText(
            ar: "ترجمة طبيعية بين العربية والإنجليزية",
            en: "Natural Arabic ↔ English translation"
        )
        static let slashTranslateBody = LText(
            ar: "ترجم النص التالي ترجمة طبيعية لا حرفية، مع الحفاظ على المعنى والنبرة. وإن لم أذكر اللغة فترجم من العربية إلى الإنجليزية أو العكس:\n\n",
            en: "Translate the text below naturally, not literally, keeping the meaning and the tone. If I don't name a language, translate between Arabic and English:\n\n"
        )
        static let slashExplain = LText(ar: "شرح", en: "Explain")
        static let slashExplainHint = LText(ar: "شرح مبسّط خطوة بخطوة", en: "Plain, step-by-step explanation")
        static let slashExplainBody = LText(
            ar: "اشرح لي التالي شرحًا واضحًا ومبسّطًا، خطوة بخطوة، مع مثال عملي واحد على الأقل:\n\n",
            en: "Explain the following clearly and simply, step by step, with at least one concrete example:\n\n"
        )
        static let slashReview = LText(ar: "مراجعة", en: "Review")
        static let slashReviewHint = LText(
            ar: "تدقيق مع اقتراح تحسين لكل ملاحظة",
            en: "Critique, with a fix for every note"
        )
        static let slashReviewBody = LText(
            ar: "راجع التالي مراجعة دقيقة: اذكر الأخطاء والثغرات ونقاط الضعف، ثم اقترح تحسينًا محدّدًا لكل ملاحظة:\n\n",
            en: "Review the following carefully: list the errors, gaps and weak points, then suggest one specific improvement for each note:\n\n"
        )

        // MARK: - Empty and loading

        static let emptyConversation = LText(
            ar: "لا توجد رسائل في هذه المحادثة بعد.",
            en: "No messages in this conversation yet."
        )
        static let loadingConversation = LText(ar: "يفتح المحادثة…", en: "Opening the conversation…")

        // MARK: - The temporary (incognito) conversation
        //
        // Verbatim from the web's `ephTitle` / `ephStart` / `ephEnd` / `ephNote` / `ephBegan` /
        // `ephAsk` / `ephGone` (`app.js`, the `eph*` block).

        static let temporaryTitle = LText(ar: "محادثة مؤقتة", en: "Temporary chat")
        static let temporaryStart = LText(ar: "ابدأ محادثة مؤقتة", en: "Start a temporary chat")
        static let temporaryEnd = LText(ar: "أنهِ المحادثة المؤقتة", en: "End the temporary chat")

        /// The strip above the transcript, for as long as the temporary conversation is open.
        static let temporaryNote = LText(
            ar: "محادثة مؤقتة — ما تنحفظ ولا تبيّن بسجلّك",
            en: "Temporary chat — not saved, not in your history"
        )
        static let temporaryStarted = LText(
            ar: "بدأت محادثة مؤقتة — ما ينحفظ منها شي",
            en: "Temporary chat started — nothing here is kept"
        )
        /// Asked once, and only when there is something in the chat or in the composer to lose:
        /// ending is irreversible by construction, so the question is the entire safety net.
        static let temporaryAsk = LText(
            ar: "إنهاء المحادثة المؤقتة يمسح كل اللي فيها، وما في تراجع. متابعة؟",
            en: "Ending this temporary chat erases everything in it, and there is no undo. Continue?"
        )
        static let temporaryEnded = LText(
            ar: "انتهت المحادثة المؤقتة",
            en: "Temporary chat ended"
        )

        // MARK: - The conversation menu (top bar)

        /// `[new]` — the label of the «…» control beside New chat.
        static let conversationActions = LText(ar: "خيارات المحادثة", en: "Conversation options")
        /// `[new]` — the submenu that holds the nine export formats.
        static let exportAs = LText(ar: "تصدير كـ…", en: "Export as…")
        static let exportWorking = LText(ar: "يُصدّر…", en: "Exporting…")
    }
}
