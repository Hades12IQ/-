import Foundation

/// The launcher, the server-build lifecycle, the IDE chrome, the file rail, and the sentences the
/// store itself speaks (save caps, share, export, the AI thread's own turns).
///
/// The editor, preview, console, command-bar and diff-review copy lives in `Strings.CodeUI`, owned
/// by the engineer who owns those panes, so the two owners never edit one file.
///
/// Arabic is verbatim from the web `cwT` / `cwPlanT` / `cwFileOpsT` tables cited in
/// `web-code-ux.md §2, §3.3, §5.2, §6` and `server-code-brainask.md §2.5–§2.7`; strings marked
/// `[new]` exist only natively and follow `design-brief.md §7.9`.
extension Strings {
    enum Code {

        // MARK: - Launcher

        static let title = LText(ar: "Firas Code", en: "Firas Code")

        static let heroSubtitle = LText(
            ar: "اكتب ما تريد بناءه، ويبنيه فِراس لك — تطبيق كامل يعمل، أو ابدأ بمشروع فارغ",
            en: "Describe what to build and Firas builds it — a complete working app, or start blank"
        )

        static let namePlaceholder = LText(
            ar: "اسم المشروع (اختياري)",
            en: "Project name (optional)"
        )

        static let briefPlaceholder = LText(
            ar: "صف تطبيقك… مثال: لعبة ثعبان احترافية بلوحة نتائج، أو متجر ملابس بسلة تسوّق تعمل وتصميم أنيق داكن",
            en: "Describe your app… e.g. a polished Snake game with a scoreboard, or a clothing store with a working cart and elegant dark design"
        )

        /// [new] — the native launcher reads text and PDF attachments on device; a screenshot has
        /// no vision reader here yet, so the label promises only what it delivers.
        static let attachFile = LText(ar: "أرفق ملفًا", en: "Attach a file")
        static let attachHint = LText(ar: "نصوص، شيفرة، أو PDF", en: "Text, code, or PDF")
        static let attachUnsupported = LText(
            ar: "نوع ملف غير مدعوم هنا",
            en: "That file type is not supported here"
        )
        static let attachRemove = LText(ar: "أزل المرفق", en: "Remove attachment")
        static let attachmentsReading = LText(ar: "يقرأ المرفقات…", en: "Reading the attachments…")
        static let attachmentsOnly = LText(
            ar: "نفّذ ما تُظهره المرفقات على المشروع.",
            en: "Apply what the attachments show to this project."
        )
        /// `attIn` — the counted suffix a thread turn keeps.
        static let attachmentCount = LText(ar: "— مرفقات: %@", en: "— attachments: %@")

        static let blankProject = LText(ar: "مشروع فارغ", en: "Blank project")
        static let buildWithAI = LText(ar: "ابنِ بالذكاء ✨", en: "Build with AI ✨")
        static let buildingNow = LText(ar: "يبني مشروعك…", en: "Building…")

        static let yourProjects = LText(ar: "مشاريعك", en: "Your projects")
        static let projectFallbackName = LText(ar: "مشروع", en: "project")
        static let defaultProjectName = LText(ar: "مشروع جديد", en: "new-project")

        static let noProjects = LText(
            ar: "لا مشاريع بعد — أنشئ أول مشروع بالأعلى",
            en: "No projects yet — create your first above"
        )
        /// [new] — the "had some, now none" line after the last project is deleted.
        static let noProjectsLeft = LText(
            ar: "لم يبقَ أي مشروع — ابدأ واحدًا جديدًا من البطاقة بالأعلى",
            en: "No projects left — start a new one from the card above"
        )

        static let deleteProjectConfirm = LText(
            ar: "حذف هذا المشروع نهائيًا؟",
            en: "Delete this project permanently?"
        )
        static let projectDeleted = LText(ar: "حُذف المشروع", en: "Project deleted")

        /// [new] — guests keep their projects on the device only (web parity).
        static let guestLocalNotice = LText(
            ar: "مشاريعك محفوظة على هذا الجهاز فقط. أنشئ حسابًا لتجدها في كل مكان.",
            en: "Your projects live on this device only. Create an account to find them everywhere."
        )

        static let stillBuilding = LText(ar: "يُبنى الآن", en: "Building")

        // MARK: - Server build lifecycle

        /// `srvKeep` — the only feedback a handed-off build gives.
        static let serverKeep = LText(
            ar: "يُبنى على الخادم — غادِر الصفحة إن شئت، ستجده جاهزًا حين تعود",
            en: "Building on the server — leave if you like, it will be here when you are back"
        )
        static let serverDone = LText(ar: "خلص بناء المشروع ✅", en: "Project build finished ✅")
        static let serverReady = LText(
            ar: "«%@» صار جاهزًا في فراس كود",
            en: "“%@” is ready in Firas Code"
        )
        static let serverOpen = LText(ar: "افتحه", en: "Open it")
        static let serverFailed = LText(
            ar: "تعثّر بناء «%@» على الخادم — افتحه وجرّب من جديد",
            en: "“%@” did not finish building on the server — open it and try again"
        )
        static let buildRefused = LText(
            ar: "لم يكتمل الإنشاء — أعد المحاولة، أو أضِف تفاصيل للوصف",
            en: "Build did not complete — retry, or add more detail to your description"
        )

        static let planningHeadline = LText(ar: "يخطّط للمعمارية…", en: "Planning architecture…")
        static let buildingHeadline = LText(ar: "يبني", en: "Building")

        // MARK: - Workspace chrome

        static let home = LText(ar: "الرئيسية", en: "Home")
        static let tabFiles = LText(ar: "الملفات", en: "Files")
        static let tabCode = LText(ar: "الكود", en: "Code")
        static let tabPreview = LText(ar: "المعاينة", en: "Preview")
        static let tabAssistant = LText(ar: "المساعد", en: "AI")
        static let paneConsole = LText(ar: "الطرفية", en: "Console")

        static let run = LText(ar: "تشغيل", en: "Run")
        static let newFile = LText(ar: "ملف جديد", en: "New file")
        static let share = LText(ar: "مشاركة", en: "Share")
        static let zip = LText(ar: "ZIP", en: "ZIP")
        /// `cwDockMore` — the overflow menu.
        static let moreTools = LText(ar: "أدوات أخرى", en: "More tools")
        static let collapseRail = LText(ar: "طيّ شريط الملفات", en: "Collapse the file rail")
        static let expandRail = LText(ar: "إظهار شريط الملفات", en: "Show the file rail")

        static let saved = LText(ar: "محفوظ", en: "Saved")
        static let editing = LText(ar: "يُحرَّر", en: "Editing")
        static let saving = LText(ar: "يحفظ…", en: "Saving…")

        static let workspaceLoading = LText(ar: "يفتح المشروع…", en: "Opening the project…")
        static let workspaceMissing = LText(
            ar: "لم نعثر على هذا المشروع",
            en: "We could not find this project"
        )
        static let workspaceMissingHint = LText(
            ar: "قد يكون حُذف من جهاز آخر. ارجع إلى الرئيسية واختر مشروعًا آخر.",
            en: "It may have been deleted from another device. Go home and pick another project."
        )
        /// The cached copy is on screen while the server is unreachable.
        static let offlineCopy = LText(
            ar: "هذه نسخة محفوظة على الجهاز — التعديلات ستُرفع حين يعود الاتصال.",
            en: "This is the copy stored on your device — edits upload when you are back online."
        )

        // MARK: - Files

        static let filesHeader = LText(ar: "الملفات", en: "Files")
        static let newFilePrompt = LText(
            ar: "اسم الملف (مثل js/tools.js)",
            en: "File name (e.g. js/tools.js)"
        )
        static let renameTitle = LText(ar: "المسار الجديد:", en: "New path:")
        static let deleteFileConfirm = LText(ar: "حذف الملف؟", en: "Delete this file?")
        static let pathTaken = LText(ar: "المسار مستخدم بالفعل", en: "That path is already taken")
        static let fileLimitReached = LText(ar: "بلغت الحد (30 ملفًا)", en: "File limit reached (30)")
        static let invalidName = LText(ar: "اسم غير صالح", en: "Invalid name")
        static let renamed = LText(ar: "أُعيدت التسمية ✓", en: "Renamed ✓")
        static let noFilesTitle = LText(ar: "لا ملفات في المشروع", en: "This project has no files")
        static let noFilesHint = LText(
            ar: "أضِف ملفًا للبدء، أو اطلب من فِراس أن يبني المشروع.",
            en: "Add a file to start, or ask Firas to build the project."
        )

        /// `n ملف` with full Arabic agreement (`web-code-ux.md §3.7`).
        static let filesZero = LText(ar: "لا ملفات", en: "no files")
        static let filesOne = LText(ar: "ملف واحد", en: "%ld file")
        static let filesTwo = LText(ar: "ملفان", en: "%ld files")
        static let filesFew = LText(ar: "%ld ملفات", en: "%ld files")
        static let filesMany = LText(ar: "%ld ملفًا", en: "%ld files")
        static let filesOther = LText(ar: "%ld ملف", en: "%ld files")

        static func fileCount(_ n: Int, _ lang: AppLanguage) -> String {
            ArabicPlurals.count(
                n,
                lang,
                zero: filesZero,
                one: filesOne,
                two: filesTwo,
                few: filesFew,
                many: filesMany,
                other: filesOther
            )
        }

        // MARK: - Save caps

        /// Verbatim (`server-code-brainask.md §2.5`).
        static let projectTooLarge = LText(
            ar: "المشروع أكبر من حدّ الحفظ — لم يُحفظ. احذف أو صغّر أكبر ملف.",
            en: "Project exceeds the save limit — not saved. Remove or shrink the largest file."
        )
        static let fileTooLarge = LText(
            ar: "«%@» أكبر من ٦٠٬٠٠٠ حرف — لم يُحفظ. صغّره أولًا.",
            en: "“%@” is over 60,000 characters — not saved. Shrink it first."
        )
        static let pathTooLong = LText(
            ar: "المسار أطول من ١٢٠ حرفًا — اختر مسارًا أقصر.",
            en: "That path is longer than 120 characters — pick a shorter one."
        )
        static let saveFailed = LText(
            ar: "تعذّر حفظ المشروع على الخادم — سنعيد المحاولة مع أول تعديل قادم.",
            en: "Could not save the project to the server — we will retry on your next edit."
        )

        // MARK: - Preview

        static let openInSafari = LText(ar: "فتح في Safari", en: "Open in Safari")
        static let openInSafariFailed = LText(
            ar: "تعذّر فتح المعاينة خارج التطبيق",
            en: "Could not open the preview outside the app"
        )
        static let addIndexFirst = LText(ar: "أضف ملف index.html أولًا", en: "Add an index.html first")

        // MARK: - Console

        /// `cwDeckFixAsk` — the instruction prefilled into the AI bar.
        static let fixWithAIPrompt = LText(
            ar: "التطبيق قيد التشغيل يُسجّل هذه الأخطاء — جد السبب عبر الملفات وأصلحه:",
            en: "The running app logs these errors — find the cause across the files and fix it:"
        )

        // MARK: - AI command bar

        static let noChanges = LText(ar: "لا تغييرات مقترحة", en: "No changes proposed")
        static let askFailed = LText(ar: "تعذّر التعديل — جرّب ثانية", en: "Could not edit — try again")

        /// The daily Code ceiling a guest can hit (`web-code-ux.md §4`).
        static let dailyLimit = LText(
            ar: "بلغت حدّك اليومي من فِراس Code (%@ يوميًا). فعّل اشتراكًا للمزيد.",
            en: "Daily Firas Code limit reached (%@/day). Activate a subscription for more."
        )

        // MARK: - Diff review

        static let diffTitle = LText(ar: "مراجعة التعديلات", en: "Review changes")
        static let diffApplied = LText(ar: "طُبّقت التعديلات ✓", en: "Changes applied ✓")
        static let diffUndone = LText(ar: "تراجَعت عن التعديل ✓", en: "Edit undone ✓")

        // MARK: - Share and export

        static let shareCreating = LText(ar: "ينشئ رابط المشاركة…", en: "Creating share link…")
        static let shareCopied = LText(ar: "تم نسخ رابط المشاركة ✓", en: "Share link copied ✓")
        static let shareFailed = LText(
            ar: "تعذّر إنشاء الرابط — تأكد من تسجيل الدخول واتصالك ثم أعد المحاولة",
            en: "Could not create the link — check you are signed in and online, then retry"
        )
        static let shareLimit = LText(
            ar: "وصلت إلى الحد الأقصى لروابط المشاركة في حسابك",
            en: "You have reached the share-link limit on your account"
        )
        static let shareBusy = LText(
            ar: "طلبات كثيرة بسرعة — انتظر دقيقة ثم أعد المحاولة",
            en: "Too many requests — wait a minute, then try again"
        )
        static let exportFailed = LText(
            ar: "تعذّر تجهيز ملف ZIP — أعد المحاولة",
            en: "Could not prepare the ZIP — try again"
        )
        static let exporting = LText(ar: "يجهّز الملف…", en: "Preparing the file…")
    }
}
