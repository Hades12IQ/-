import Foundation

/// Every user-visible string of the Firas Agent product.
///
/// Copy marked "verbatim" is pasted from the web client through `web-agent-ux.md` (`FC_COPY`
/// §8, the failure table §9, the credits dialog §14) and `server-agent.md §11.2`. The card's
/// refusal sentences already live in `Strings.Errors` (`agentBusy`, `agentCreditsSpent`,
/// `agentCreditsReserved`, `agentSignIn`, `agentFailed`) and are never duplicated here.
///
/// The chrome follows the **UI** language, not the mission's `lang`; only mission content is
/// direction-detected, through `bidiIsland`.
extension Strings {
    enum Agent {

        // MARK: - Product

        /// The panel identity line — a brand name, identical in both languages.
        static let name = LText(ar: "Firas Agent", en: "Firas Agent")

        /// `PRODUCTS.agent.tag` — verbatim (`app.js:59942`).
        static let tagline = LText(ar: "وكيل ينفّذ المهام الكبيرة", en: "Executes big tasks")

        /// Rail label — verbatim (`app.js:19526-19527`).
        static let railLabel = LText(ar: "الوكيل", en: "Agent")

        /// Composer placeholder — verbatim (`app.js:59961-59964`).
        static let composerPlaceholder = LText(ar: "كلّف فِراس بمهمة صعبة", en: "Give Firas a hard task")

        /// Composer accessibility label — verbatim.
        static let composerLabel = LText(ar: "مراسلة Firas Agent", en: "Message Firas Agent")

        /// `agentAttachHint` — verbatim (`app.js:197-198`).
        static let attachHint = LText(
            ar: "إرفاق ملفات وصور إلى المهمة",
            en: "Attach files and images to the mission"
        )

        // MARK: - Status pill (`FC_COPY`, verbatim)

        static let statusWorking = LText(ar: "قيد التنفيذ", en: "In progress")
        static let statusPlanning = LText(ar: "يُجهّز خطة العمل", en: "Preparing the plan")
        static let statusDone = LText(ar: "اكتملت المهمة", en: "Task completed")
        static let statusFailed = LText(ar: "تعذّر إكمال المهمة", en: "Task could not be completed")
        static let statusStopped = LText(ar: "توقفت المهمة", en: "Task stopped")
        static let stopMission = LText(ar: "إيقاف المهمة", en: "Stop the mission")
        static let stopping = LText(ar: "يتوقّف…", en: "Stopping…")
        static let statusBlocked = LText(ar: "مهمة أخرى قيد التنفيذ", en: "Another task is running")
        static let statusCredits = LText(ar: "استُهلك رصيد اليوم", en: "Daily credits used")
        static let statusReading = LText(ar: "يقرأ المرفقات…", en: "Reading attachments…")

        // MARK: - Groups (`FC_COPY`, verbatim)

        static let planGroup = LText(ar: "خطة التنفيذ", en: "Execution plan")
        static let sourcesGroup = LText(ar: "المصادر", en: "Sources")
        static let filesGroup = LText(ar: "الملفات والمخرجات", en: "Files and outputs")
        static let executionLog = LText(ar: "سجل التنفيذ", en: "Execution log")
        static let activityLog = LText(ar: "سجل النشاط", en: "Activity log")
        static let resultGroup = LText(ar: "النتيجة", en: "Result")

        // MARK: - Tool kinds (`FC_COPY`, verbatim)

        static let toolSearch = LText(ar: "البحث في الويب", en: "Searching the web")
        static let toolBrowser = LText(ar: "تصفّح صفحة", en: "Browsing a page")
        static let toolRead = LText(ar: "قراءة مصدر", en: "Reading a source")
        static let toolClick = LText(ar: "التفاعل مع الصفحة", en: "Interacting with the page")
        static let toolWrite = LText(ar: "كتابة المحتوى", en: "Writing content")
        static let toolGenerate = LText(ar: "إنشاء محتوى", en: "Creating content")
        static let toolFile = LText(ar: "إنشاء ملف", en: "Creating a file")
        static let toolGeneric = LText(ar: "تنفيذ إجراء", en: "Running an action")

        // MARK: - Action titles (`FC_COPY`, verbatim)

        static let actionSearch = LText(ar: "يبحث", en: "Searching")
        static let actionAcademicSearch = LText(
            ar: "يبحث في المصادر الأكاديمية",
            en: "Searching scholarly literature"
        )
        static let actionBrowse = LText(ar: "يتصفّح", en: "Browsing")
        static let actionOpen = LText(ar: "يفتح المصدر", en: "Opening the source")
        static let actionRead = LText(ar: "يقرأ المصدر", en: "Reading the source")
        static let actionFile = LText(ar: "ينشئ الملف", en: "Creating a file")
        static let actionWrite = LText(ar: "يكتب", en: "Writing")
        static let actionFallback = LText(ar: "ينفّذ الإجراء", en: "Running an action")

        // MARK: - Row words (`FC_COPY`, verbatim)

        static let running = LText(ar: "جارٍ الآن", en: "In progress")
        static let waiting = LText(ar: "لاحقًا", en: "Up next")
        static let completed = LText(ar: "تم", en: "Done")
        static let failedShort = LText(ar: "تعذّر", en: "Failed")
        /// The event-count word; `%@` carries the number.
        static let eventsCount = LText(ar: "%@ أحداث", en: "%@ events")
        static let openSource = LText(ar: "فتح المصدر", en: "Open source")
        static let noDetail = LText(
            ar: "اكتمل هذا الإجراء ضمن تنفيذ المهمة.",
            en: "This action was completed as part of the task."
        )
        static let stepNow = LText(
            ar: "يعمل Firas Agent على هذه الخطوة الآن…",
            en: "Firas Agent is working on this step now…"
        )
        static let stepLater = LText(
            ar: "ستظهر تفاصيل هذه الخطوة عند بدء تنفيذها.",
            en: "Details will appear when this step starts."
        )
        static let stepOutput = LText(ar: "الناتج", en: "Output")

        // MARK: - Files and images (`FC_COPY`, verbatim)

        static let imageCreating = LText(
            ar: "يتم صنع الصور بواسطة Firas AI",
            en: "Images are being created by Firas AI"
        )
        static let imageCreated = LText(
            ar: "صُنعت الصور بواسطة Firas AI",
            en: "Images were created by Firas AI"
        )
        static let imageAttribution = LText(
            ar: "صُنعت هذه الصورة بواسطة Firas AI",
            en: "This image was created by Firas AI"
        )
        /// `%@` is the file name.
        static let openFileNamed = LText(ar: "فتح الملف: %@", en: "Open file: %@")
        static let openFile = LText(ar: "فتح الملف", en: "Open file")
        static let downloadFile = LText(ar: "تنزيل الملف", en: "Download file")
        static let viewerLoading = LText(ar: "جارٍ فتح الملف…", en: "Opening the file…")
        static let viewerFailed = LText(
            ar: "تعذّر فتح هذا الملف داخل Firas Agent.",
            en: "This file could not be opened inside Firas Agent."
        )
        static let viewerTooLarge = LText(
            ar: "حجم الملف كبير للمعاينة؛ يمكنك تنزيله.",
            en: "This file is too large to preview; you can download it."
        )
        static let viewerUnsupported = LText(
            ar: "هذا النوع متاح للتنزيل.",
            en: "This file type is available to download."
        )

        // MARK: - Footer actions (`web-agent-ux.md §7`, verbatim)

        static let resume = LText(ar: "▶ استئناف المهمة", en: "▶ Resume task")
        static let openRunning = LText(ar: "فتح المهمة الجارية ←", en: "Open running task →")
        static let exportMarkdown = LText(ar: "⬇ تصدير Markdown", en: "⬇ Export Markdown")
        static let exportMarkdownHint = LText(
            ar: "احفظ المهمة كاملة — الخطة وكل خطوة مع مخرجاتها والمصادر — بملف Markdown واحد",
            en: "Save the whole task — the plan, every step with its output, and the sources — as one Markdown file"
        )
        static let exportDone = LText(ar: "تم تنزيل ملف المهمة ✓", en: "Task file downloaded ✓")
        static let refreshListToFind = LText(
            ar: "حدّث قائمة المحادثات حتى تظهر المهمة.",
            en: "Refresh the conversation list to find the task."
        )

        // MARK: - One live mission at a time (`web-agent-ux.md §2.1.2`, verbatim)

        static let busySameChat = LText(
            ar: "المهمة الحالية قيد التنفيذ هنا. بقي النص الجديد محفوظًا.",
            en: "Your current task is already running here. Your new draft stays saved."
        )
        static let busyOtherChat = LText(
            ar: "توجد مهمة قيد التنفيذ؛ فُتحت لمتابعتها. بقي النص الجديد محفوظًا هنا.",
            en: "You already have a task running; opening it now. Your new draft stays saved here."
        )
        static let busyUnknownChat = LText(
            ar: "توجد مهمة قيد التنفيذ. حدّث قائمة المحادثات لعرضها؛ بقي النص الجديد محفوظًا.",
            en: "You have a task running. Refresh the conversation list to find it; your new draft stays saved."
        )
        /// The 409 toasts (`server-agent.md §11.2`, verbatim).
        static let openedRunning = LText(ar: "فُتحت المهمة الجارية.", en: "Opening your running task.")
        static let anotherRunning = LText(
            ar: "توجد مهمة قيد التنفيذ. حدّث قائمة المحادثات لعرضها.",
            en: "Another task is running. Refresh the conversation list to find it."
        )

        // MARK: - Enqueue refused for any other reason (`web-agent-ux.md §9.7`, verbatim)

        static let startFailedStep = LText(ar: "تعذّر بدء المهمة", en: "Task could not be started")
        static let unavailableFinal = LText(
            ar: "الخدمة غير متاحة مؤقتًا. لم تُحوَّل المهمة إلى أداة أخرى؛ أعد المحاولة.",
            en: "Firas Agent is temporarily unavailable. Nothing was handed to another tool; please retry."
        )

        // MARK: - Guest gate (`web-agent-ux.md §1`, verbatim)

        static let guestTitle = LText(ar: "هذه الميزة تحتاج حسابًا", en: "This feature needs an account")
        static let guestBody = LText(
            ar: "أنشئ حسابًا مجانيًا لتفعيلها — يستغرق أقل من دقيقة.",
            en: "Create a free account to unlock it — it takes less than a minute."
        )
        static let guestCta = LText(ar: "إنشاء حساب مجاني", en: "Create a free account")

        // MARK: - Welcome and templates (native copy, same voice)

        static let welcomeTitle = LText(ar: "كلّفني بمهمة كاملة", en: "Give me a whole mission")
        static let welcomeBody = LText(
            ar: "يبحث فِراس، ينفّذ، ويسلّم الملفات. المهمة تعمل على الخادم — يمكنك إغلاق التطبيق، وسنُشعرك عند انتهائها.",
            en: "Firas researches, executes and delivers the files. The mission runs on the server — close the app if you like; we will let you know when it is done."
        )
        static let templatesTitle = LText(ar: "ابدأ من هنا", en: "Start from here")

        static let templateResearchLabel = LText(ar: "تقرير بحثي", en: "Research report")
        static let templateResearchTask = LText(
            ar: "ابحث في هذا الموضوع من مصادر حديثة وموثوقة، ثم اكتب تقريرًا منظمًا بالعربية مع المصادر: ",
            en: "Research this topic from recent, reliable sources and write an organised report with citations: "
        )
        static let templateDeckLabel = LText(ar: "عرض تقديمي", en: "Slide deck")
        static let templateDeckTask = LText(
            ar: "جهّز عرضًا تقديميًا كاملًا بصيغة PowerPoint عن: ",
            en: "Build a complete PowerPoint deck about: "
        )
        static let templateAnalysisLabel = LText(ar: "تحليل ملف", en: "Analyse a file")
        static let templateAnalysisTask = LText(
            ar: "حلّل الملف المرفق واستخرج النتائج في جدول واضح مع خلاصة قصيرة. ما يهمني تحديدًا: ",
            en: "Analyse the attached file, put the findings in a clear table and add a short summary. What matters to me: "
        )
        static let templateCompareLabel = LText(ar: "مقارنة وقرار", en: "Compare and decide")
        static let templateCompareTask = LText(
            ar: "قارن بين هذه الخيارات بمعايير واضحة، ثم أوصِ بواحد وبرّر الاختيار: ",
            en: "Compare these options against clear criteria, then recommend one and justify it: "
        )

        // MARK: - States

        static let loadingMission = LText(ar: "جارٍ تحميل المهمة…", en: "Loading the mission…")
        static let emptyTitle = LText(ar: "لا توجد مهام بعد", en: "No missions yet")
        static let emptyBody = LText(
            ar: "اكتب مهمتك في الأسفل وسيبدأ فِراس فورًا.",
            en: "Write your mission below and Firas will start right away."
        )
        static let missionStarting = LText(ar: "جارٍ تسليم المهمة للخادم…", en: "Handing the mission to the server…")
        static let noFiles = LText(ar: "لم تُنتج هذه المهمة ملفات.", en: "This mission produced no files.")
        static let noActivity = LText(
            ar: "لم يصل أي نشاط بعد — ستظهر الخطوات هنا فور بدئها.",
            en: "No activity yet — steps appear here as soon as they start."
        )
        static let cannotStop = LText(
            ar: "المهمة تعمل على الخادم ولا يمكن إيقافها — ستصلك النتيجة عند اكتمالها.",
            en: "The mission runs on the server and cannot be stopped — the result arrives when it finishes."
        )
        static let openMenu = LText(ar: "القائمة", en: "Menu")
        static let sendMission = LText(ar: "أرسل المهمة", en: "Send the mission")
        static let stillReading = LText(
            ar: "ما زالت المرفقات تُقرأ…",
            en: "Attachments are still being read…"
        )
        /// `maxImages` — verbatim (`web-agent-ux.md §11`, `app.js:35897`).
        static let maxImages = LText(ar: "الحد الأقصى ١٠ صور", en: "Max 10 images")
        static let maxFiles = LText(ar: "الحد الأقصى ٥ ملفات", en: "Max 5 files")

        static let missionSteps = LText(ar: "خطوات المهمة", en: "Mission steps")
        static let elapsedLabel = LText(ar: "الزمن المنقضي", en: "Elapsed")

        // MARK: - Credits chip and dialog (`web-agent-ux.md §14`, verbatim)

        static let creditsChip = LText(ar: "كريديت", en: "credits")
        static let creditsHeldChip = LText(ar: "متاح · مهمة قيد التنفيذ", en: "available · task running")
        static let creditsLockedChip = LText(ar: "بعد التسجيل", en: "after sign-in")
        static let creditsUpdating = LText(ar: "جارٍ تحديث الرصيد", en: "Updating credits")
        static let creditsChipTitle = LText(ar: "عرض تفاصيل الرصيد اليومي", en: "View daily credit details")
        /// `%@` left, `%@` all, `%@` held.
        static let creditsChipAria = LText(
            ar: "رصيد Firas Agent: %@ من %@، %@ محجوز لمهمة جارية، اضغط للتفاصيل",
            en: "Firas Agent credits: %@ of %@, %@ reserved for active work, open details"
        )
        /// `%@` is the allowance.
        static let creditsChipAriaLocked = LText(
            ar: "%@ كريديت يوميًا بعد تسجيل الدخول، اضغط للتفاصيل",
            en: "%@ daily credits after sign-in, open details"
        )

        static let creditsTitle = LText(ar: "رصيدك اليومي", en: "Your daily credits")
        static let creditsTitleLocked = LText(ar: "رصيدك بعد تسجيل الدخول", en: "Credits after sign-in")
        static let creditsRemaining = LText(ar: "المتبقّي", en: "Remaining")
        static let creditsRemainingLocked = LText(ar: "يُفعّل للحساب", en: "Activated for your account")
        /// `%@` is the allowance.
        static let creditsOfAllowance = LText(ar: "من %@", en: "of %@")
        static let creditsDaily = LText(ar: "يوميًا", en: "daily")
        static let creditsBarLabel = LText(ar: "الرصيد اليومي المتبقي", en: "Remaining daily credits")
        static let creditsUsedToday = LText(ar: "المستخدم اليوم", en: "Used today")
        static let creditsReservedLabel = LText(ar: "محجوز لمهمة جارية", en: "Reserved for active work")
        static let creditsNextRefresh = LText(ar: "موعد التجديد", en: "Next refresh")
        /// `%@` hours, `%@` minutes.
        static let creditsRefreshesIn = LText(ar: "يتجدد بعد %@ س %@ د", en: "Refreshes in %@h %@m")
        static let creditsRefreshesDaily = LText(ar: "يتجدد يوميًا", en: "Refreshes daily")
        static let creditsAdd = LText(ar: "إضافة رصيد", en: "Add credits")
        static let creditsAddSoon = LText(
            ar: "هذه الميزة تحت التطوير حاليًا.",
            en: "This feature is currently under development."
        )
        static let creditsNote = LText(
            ar: "يتجدد الرصيد تلقائيًا كل يوم، وما يحتاج منك أي إجراء.",
            en: "Credits refresh automatically every day; no action is needed."
        )
        static let creditsNoteLocked = LText(
            ar: "سجّل الدخول حتى يتفعّل رصيدك اليومي وتحفظ مهامك بين أجهزتك.",
            en: "Sign in to activate your daily credits and keep tasks across devices."
        )
        static let creditsUnavailable = LText(
            ar: "تعذّر تحميل الرصيد الآن.",
            en: "Credits could not be loaded right now."
        )

        // MARK: - Markdown export (`AGENT_MD_L`, verbatim where the web has it)

        static let mdUntitled = LText(ar: "مهمة فِراس Agent", en: "Firas Agent task")
        static let mdExportedFrom = LText(ar: "صُدِّر من فِراس Agent", en: "Exported from Firas Agent")
        static let mdStepsLabel = LText(ar: "الخطوات", en: "Steps")
        static let mdTaskHeading = LText(ar: "المهمة", en: "Task")
        static let mdPlanHeading = LText(ar: "الخطة", en: "Plan")
        static let mdStepsHeading = LText(ar: "الخطوات", en: "Steps")
        /// `%@` is the step number.
        static let mdStepHeading = LText(ar: "الخطوة %@", en: "Step %@")
        static let mdResultHeading = LText(ar: "النتيجة", en: "Result")
        static let mdSourcesHeading = LText(ar: "المصادر", en: "Sources")
        static let mdFilesHeading = LText(ar: "الملفات", en: "Files")
        static let mdEmptyStep = LText(
            ar: "لا مخرجات لهذه الخطوة.",
            en: "This step produced no output."
        )
        static let mdNotRun = LText(ar: "لم تُنفَّذ", en: "Not run")
        static let mdStepFailed = LText(ar: "تعثّرت", en: "Failed")

        // MARK: - Phase labels used by the export line (`AGENT_PHASE_LABEL`, verbatim)

        static let phaseRun = LText(ar: "ينفّذ…", en: "Executing…")
        static let phasePlan = LText(ar: "يخطّط…", en: "Planning…")
        static let phaseDone = LText(ar: "اكتملت المهمة", en: "Task complete")
        static let phaseStopped = LText(ar: "أُوقفت", en: "Stopped")
        static let phaseFail = LText(ar: "تعثّرت", en: "Failed")
    }
}
