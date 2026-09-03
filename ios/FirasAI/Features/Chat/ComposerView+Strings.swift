import Foundation

/// Every user-visible string the composer stack shows.
///
/// The chat *screen* owns `Strings.Chat`; the composer keeps its own namespace so the two files can
/// land in the same batch without colliding. Arabic is verbatim from the web STR tables cited in
/// `web-chat-ux.md §7 / Appendix A` and `design-brief.md §7.3, §7.14`; the handful of strings the web
/// has no equivalent for are marked `[new]`.
extension Strings {
    enum Composer {

        // MARK: - The composer itself

        static let disclaimer = LText(
            ar: "قد يخطئ فِراس. تحقّق من المعلومات المهمة.",
            en: "Firas can make mistakes. Check important info."
        )
        static let attachHint = LText(ar: "إرفاق ملف", en: "Attach a file")
        static let agentAttachHint = LText(
            ar: "إرفاق ملفات وصور إلى المهمة",
            en: "Attach files and images to the mission"
        )
        /// [new] — the web has no empty-composer feedback because its button is simply disabled.
        static let nothingToSend = LText(
            ar: "اكتب رسالة أو أرفق ملفًا أولًا.",
            en: "Write a message or attach a file first."
        )
        /// [new]
        static let stillReading = LText(
            ar: "لحظة — ما زال فِراس يقرأ المرفقات.",
            en: "One moment — the attachments are still being read."
        )
        static let agentBusy = LText(
            ar: "المهمة الحالية قيد التنفيذ هنا. بقي النص الجديد محفوظًا.",
            en: "Your current task is already running here. Your new draft stays saved."
        )
        /// [new] — the call button is hidden outside Firas AI; this is the toast if it is ever reached.
        static let callLabel = LText(ar: "مكالمة صوتية", en: "Voice call")

        // MARK: - Tools

        static let thinking = LText(ar: "التفكير", en: "Thinking")
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
        // MARK: - Length meter

        static let lengthChars = LText(ar: "الأحرف %@", en: "%@ chars")
        static let lengthTokens = LText(ar: "الرموز ≈%@", en: "≈%@ tokens")
        static let lengthNear = LText(ar: "اقترب من حدّ %@", en: "near the %@ limit")
        static let lengthOver = LText(ar: "تجاوز حدّ %@", en: "over the %@ limit")
        static let lengthTip = LText(
            ar: "تقدير تقريبي. ما يتجاوز %@ حرف قد يُقصّ عند حفظ الرسالة — قسّمها أو أرفق النصّ كملف.",
            en: "A rough estimate. Past %@ characters a saved message may be cut — split it, or attach the text as a file."
        )

        // MARK: - Slash menu

        static let slashTitle = LText(ar: "أوامر سريعة", en: "Quick commands")
        static let slashSummarizeLabel = LText(ar: "تلخيص", en: "Summarize")
        static let slashSummarizeHint = LText(
            ar: "اختصر نصًا طويلًا إلى نقاط",
            en: "Boil a long text down to points"
        )
        static let slashSummarizeBody = LText(
            ar: "لخّص لي النص التالي في نقاط مركّزة، مع الإبقاء على كل فكرة أساسية وحذف الحشو:\n\n",
            en: "Summarize the text below into tight points — keep every key idea, cut the filler:\n\n"
        )
        static let slashTranslateLabel = LText(ar: "ترجمة", en: "Translate")
        static let slashTranslateHint = LText(
            ar: "ترجمة طبيعية بين العربية والإنجليزية",
            en: "Natural Arabic ↔ English translation"
        )
        static let slashTranslateBody = LText(
            ar: "ترجم النص التالي ترجمة طبيعية لا حرفية، مع الحفاظ على المعنى والنبرة. وإن لم أذكر اللغة فترجم من العربية إلى الإنجليزية أو العكس:\n\n",
            en: "Translate the text below naturally, not literally, keeping the meaning and the tone. If I don't name a language, translate between Arabic and English:\n\n"
        )
        static let slashExplainLabel = LText(ar: "شرح", en: "Explain")
        static let slashExplainHint = LText(
            ar: "شرح مبسّط خطوة بخطوة",
            en: "Plain, step-by-step explanation"
        )
        static let slashExplainBody = LText(
            ar: "اشرح لي التالي شرحًا واضحًا ومبسّطًا، خطوة بخطوة، مع مثال عملي واحد على الأقل:\n\n",
            en: "Explain the following clearly and simply, step by step, with at least one concrete example:\n\n"
        )
        static let slashReviewLabel = LText(ar: "مراجعة", en: "Review")
        static let slashReviewHint = LText(
            ar: "تدقيق مع اقتراح تحسين لكل ملاحظة",
            en: "Critique, with a fix for every note"
        )
        static let slashReviewBody = LText(
            ar: "راجع التالي مراجعة دقيقة: اذكر الأخطاء والثغرات ونقاط الضعف، ثم اقترح تحسينًا محدّدًا لكل ملاحظة:\n\n",
            en: "Review the following carefully: list the errors, gaps and weak points, then suggest one specific improvement for each note:\n\n"
        )

        // MARK: - Add sheet

        static let addTitle = LText(ar: "إضافة", en: "Add")
        static let attachSection = LText(ar: "إرفاق", en: "Attach")
        static let toolsSection = LText(ar: "الأدوات", en: "Tools")
        static let camera = LText(ar: "الكاميرا", en: "Camera")
        static let photos = LText(ar: "الصور", en: "Photos")
        static let files = LText(ar: "الملفات", en: "Files")
        static let cameraUnavailable = LText(
            ar: "لا توجد كاميرا متاحة على هذا الجهاز.",
            en: "No camera is available on this device."
        )
        static let dictationLanguage = LText(ar: "لغة الإملاء", en: "Dictation language")
        static let brainVision = LText(
            ar: "اقرأ بالرؤية (أدق للملفات العربية والمصوّرة — أبطأ)",
            en: "Read with vision (better for Arabic and scanned files — slower)"
        )

        // MARK: - Attachments

        static let chipReading = LText(ar: "...قراءة", en: "reading…")
        static let removeAttachment = LText(ar: "إزالة المرفق", en: "Remove attachment")
        static let maxImages = LText(ar: "الحد الأقصى ١٠ صور", en: "Max 10 images")
        static let maxFiles = LText(ar: "الحد الأقصى ٥ ملفات", en: "Max 5 files")
        static let filesTooLarge = LText(ar: "حجم الملفات كبير جداً", en: "Files too large")
        static let unsupportedFile = LText(ar: "نوع ملف غير مدعوم", en: "Unsupported file type")
        static let unreadableFile = LText(ar: "تعذّر قراءة الملف", en: "Couldn't read file")
        static let emptyFile = LText(ar: "ما كدرت أقرأ نص من الملف", en: "No readable text in file")
        static let unreadableImage = LText(ar: "تعذّر قراءة الصورة", en: "Couldn't read image")
        static let truncatedFile = LText(
            ar: "الملف كبير — أُرسل نحو %@٪ من محتواه فقط. للمستند الكامل استخدم فِراس Brain.",
            en: "File is large — only about %@%% of it was sent. Use Firas Brain for the whole document."
        )

        // MARK: - Quote pill

        static let quoteHint = LText(
            ar: "مقطع مرفق من ردّ سابق — اكتب سؤالك عنه",
            en: "A passage from an earlier reply — write your question about it"
        )
        static let quoteDrop = LText(ar: "إزالة المقطع", en: "Remove the passage")

        // MARK: - Dictation

        static let micLabel = LText(ar: "إدخال صوتي", en: "Voice input")
        static let micHint = LText(
            ar: "إدخال صوتي — اضغط مطوّلًا لاختيار اللهجة",
            en: "Voice input — long-press to pick a dialect"
        )
        static let micCancel = LText(ar: "إلغاء التسجيل", en: "Cancel recording")
        static let micDone = LText(ar: "إيقاف وتحويل", en: "Stop and transcribe")
        static let micListening = LText(ar: "جارٍ الاستماع… تكلّم الآن", en: "Listening… speak now")
        static let micTranscribing = LText(ar: "جارٍ تحويل كلامك…", en: "Transcribing your speech…")
    }
}
