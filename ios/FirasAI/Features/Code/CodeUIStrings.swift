import Foundation

/// Copy for the five Firas Code surfaces owned by the editor/preview/console/AI/diff engineer.
///
/// It is a separate namespace from `Strings.Code` (launcher, build lifecycle and IDE chrome, owned
/// by the workspace engineer) so the two owners never edit the same file. Arabic is verbatim from
/// `web-code-ux.md §5.3–§5.5, §6.1–§6.5` wherever the web has the sentence; the handful of native
/// additions are marked.
extension Strings {

    enum CodeUI {

        // MARK: - Editor (§5.3)

        static let editorEmptyTitle = LText(ar: "لا ملف مفتوح", en: "No file open")
        static let editorEmptyBody = LText(
            ar: "اختر ملفًا من قائمة الملفات ليظهر هنا، أو أنشئ ملفًا جديدًا.",
            en: "Pick a file from the file list to open it here, or create a new one."
        )
        static let editorMissing = LText(
            ar: "هذا الملف لم يعد موجودًا في المشروع.",
            en: "That file is no longer in this project."
        )
        static let editorLoading = LText(ar: "يفتح المشروع…", en: "Opening the project…")
        /// Accessibility label for the text view: `%@` is the file path.
        static let editorAccessibility = LText(ar: "محرّر الملف %@", en: "Editor for %@")

        static let saveStateSaved = LText(ar: "محفوظ", en: "Saved")
        static let saveStateEditing = LText(ar: "تعديل…", en: "Editing…")
        static let saveStateSaving = LText(ar: "حفظ…", en: "Saving…")

        static let lineLabel = LText(ar: "سطر", en: "Ln")
        static let columnLabel = LText(ar: "عمود", en: "Col")
        static let commentToggle = LText(ar: "تعليق أو إلغاء التعليق", en: "Toggle comment")

        // MARK: - Preview (§5.4)

        static let previewTab = LText(ar: "المعاينة", en: "Preview")
        static let previewEmptyTitle = LText(ar: "لا شيء لعرضه بعد", en: "Nothing to preview yet")
        static let previewEmptyBody = LText(
            ar: "المعاينة تحتاج صفحة HTML واحدة على الأقل. أنشئ index.html أو اطلب من فِراس أن يبنيها لك.",
            en: "A preview needs at least one HTML page. Create an index.html, or ask Firas to build it for you."
        )
        static let previewCreateIndex = LText(ar: "أنشئ index.html", en: "Create index.html")
        static let previewAskFiras = LText(ar: "اطلب من فِراس", en: "Ask Firas")
        static let previewBuilding = LText(ar: "يُبنى الآن", en: "Building")
        static let previewNoProject = LText(
            ar: "لا مشروع مفتوح — افتح مشروعًا لتظهر معاينته هنا.",
            en: "No project open — open one and its preview shows up here."
        )

        static let autoReload = LText(ar: "تحديث تلقائي", en: "Auto")
        static let autoReloadOn = LText(ar: "التحديث التلقائي مُفعّل", en: "Auto-reload on")
        static let autoReloadOff = LText(ar: "التحديث التلقائي مُعطّل", en: "Auto-reload off")
        static let reloadPreview = LText(ar: "إعادة تحميل المعاينة", en: "Reload preview")
        static let rotateToLandscape = LText(ar: "دوّر للوضع الأفقي", en: "Rotate to landscape")
        static let rotateToPortrait = LText(ar: "دوّر للوضع العمودي", en: "Rotate to portrait")
        static let deviceMobile = LText(ar: "جوال", en: "Mobile")
        static let deviceTablet = LText(ar: "لوحي", en: "Tablet")
        static let deviceDesktop = LText(ar: "سطح", en: "Desktop")

        static let runIdle = LText(ar: "لم يُشغّل بعد", en: "Not run yet")
        static let runRunning = LText(ar: "يشتغل…", en: "Running…")
        static let runOk = LText(ar: "يعمل", en: "Working")
        static let runWarn = LText(ar: "يعمل مع تحذيرات", en: "Works, with warnings")
        static let runFail = LText(ar: "فشل التشغيل", en: "Run failed")
        static let runErrors = LText(ar: "أخطاء", en: "errors")
        static let runWarnings = LText(ar: "تحذيرات", en: "warnings")
        static let runRerun = LText(ar: "أعد التشغيل", en: "Re-run")
        static let openConsole = LText(ar: "افتح الكونسول", en: "Open the console")

        // MARK: - Console (§5.5)

        static let consoleTab = LText(ar: "الطرفية", en: "Console")
        static let consoleAll = LText(ar: "الكل", en: "All")
        static let consoleErrors = LText(ar: "أخطاء", en: "Errors")
        static let consoleWarnings = LText(ar: "تحذيرات", en: "Warnings")
        static let consoleLogs = LText(ar: "سجل", en: "Logs")
        static let consoleFilter = LText(ar: "تصفية المخرجات…", en: "Filter output…")
        static let consoleClock = LText(ar: "إظهار وقت كل سطر", en: "Show a clock on every line")
        static let consoleClear = LText(ar: "أفرغ الكونسول", en: "Clear the console")
        static let consoleEmptyTitle = LText(ar: "الكونسول ساكن", en: "The console is quiet")
        static let consoleEmptyBody = LText(
            ar: "شغّل المشروع أو نفّذ ملف بايثون، وستنزل السطور هنا واحدًا تلو الآخر.",
            en: "Run the project or execute a Python file and the lines land here one after another."
        )
        static let consoleRunProject = LText(ar: "شغّل المشروع", en: "Run the project")
        static let consoleNoMatch = LText(ar: "لا يوجد سطر يطابق التصفية.", en: "No line matches the filter.")
        static let consoleFix = LText(ar: "أصلحه بالذكاء", en: "Fix it with AI")
        static let consoleFixAsk = LText(
            ar: "التطبيق قيد التشغيل يُسجّل هذه الأخطاء — جد السبب عبر الملفات وأصلحه:",
            en: "The running app logs these errors — find the cause across the files and fix it:"
        )

        // MARK: - AI bar and thread (§6.1)

        static let assistantTab = LText(ar: "المساعد", en: "Assistant")
        static let aiPlaceholder = LText(ar: "اطلب تعديلًا على المشروع…", en: "Ask for a project change…")
        static let aiRun = LText(ar: "نفّذ", en: "Run")
        static let aiWorking = LText(ar: "يفكر ويعدّل…", en: "Thinking & editing…")
        /// `%@` is an already-formatted count (Arabic-Indic in Arabic).
        static let aiWorkingFor = LText(ar: "منذ %@ث", en: "%@s so far")
        static let threadEmpty = LText(
            ar: "ابدأ محادثة مع فراس — اطلب تعديلًا أو ميزة وسيظهر الحوار هنا.",
            en: "Start a conversation with Firas — ask for a change or a feature and the dialogue shows up here."
        )
        static let threadExplain = LText(ar: "اشرح لي هذا المشروع", en: "Explain this project")
        static let youLabel = LText(ar: "أنت", en: "You")
        static let firasLabel = LText(ar: "فراس", en: "Firas")
        static let noChanges = LText(ar: "لا تغييرات مقترحة", en: "No changes proposed")
        static let editFailed = LText(ar: "تعذّر التعديل — جرّب ثانية", en: "Couldn't edit — try again")
        /// `%@` is an already-formatted count.
        static let attachmentsLine = LText(ar: "— مرفقات: %@", en: "— attachments: %@")
        static let noFileMatches = LText(ar: "لا ملف يطابق", en: "no file matches")
        static let mentionFiles = LText(ar: "ملفات المشروع", en: "Project files")
        static let removeAttachment = LText(ar: "أزل المرفق", en: "Remove attachment")
        static let needProject = LText(
            ar: "افتح مشروعًا أولًا ليعمل المساعد على ملفاته.",
            en: "Open a project first so the assistant has files to work on."
        )

        // MARK: - Diff review (§6.5)

        static let diffTitle = LText(ar: "مراجعة التعديلات", en: "Review changes")
        static let diffApply = LText(ar: "تطبيق المحدد", en: "Apply selected")
        static let diffNew = LText(ar: "جديد", en: "new")
        static let diffEdit = LText(ar: "تعديل", en: "edit")
        static let diffDelete = LText(ar: "حذف", en: "delete")
        static let diffRename = LText(ar: "إعادة تسمية", en: "rename")
        static let diffReplaceAll = LText(ar: "استبدال كامل للملف", en: "Full file replacement")
        static let diffApplied = LText(ar: "طُبّقت التعديلات ✓", en: "Changes applied ✓")
        static let diffUndone = LText(ar: "تراجَعت عن التعديل ✓", en: "Edit undone ✓")
        static let diffUndo = LText(ar: "↺ تراجع", en: "↺ Undo")
        static let diffEmpty = LText(
            ar: "لا ملف اختلف — لا شيء لمراجعته.",
            en: "No file differs — nothing to review."
        )
        /// `+%@ −%@`, both already formatted.
        static let diffCounts = LText(ar: "+%@ −%@", en: "+%@ −%@")

        // MARK: - Counted nouns

        /// `n ملف` with the six Arabic forms (`web-code-ux.md §3.7`).
        static func fileCount(_ n: Int, _ lang: AppLanguage) -> String {
            ArabicPlurals.count(
                n, lang,
                zero: LText(ar: "لا ملفات", en: "no files"),
                one: LText(ar: "ملف واحد", en: "1 file"),
                two: LText(ar: "ملفان", en: "2 files"),
                few: LText(ar: "%ld ملفات", en: "%ld files"),
                many: LText(ar: "%ld ملفًا", en: "%ld files"),
                other: LText(ar: "%ld ملف", en: "%ld files")
            )
        }

        /// `n خطأ` with the six Arabic forms (`web-code-ux.md §5.5`).
        static func errorCount(_ n: Int, _ lang: AppLanguage) -> String {
            ArabicPlurals.count(
                n, lang,
                zero: LText(ar: "لا أخطاء", en: "no errors"),
                one: LText(ar: "خطأ واحد", en: "1 error"),
                two: LText(ar: "خطآن", en: "2 errors"),
                few: LText(ar: "%ld أخطاء", en: "%ld errors"),
                many: LText(ar: "%ld خطأً", en: "%ld errors"),
                other: LText(ar: "%ld خطأ", en: "%ld errors")
            )
        }

        /// `n تحذير` with the six Arabic forms (`web-code-ux.md §5.5`).
        static func warningCount(_ n: Int, _ lang: AppLanguage) -> String {
            ArabicPlurals.count(
                n, lang,
                zero: LText(ar: "لا تحذيرات", en: "no warnings"),
                one: LText(ar: "تحذير واحد", en: "1 warning"),
                two: LText(ar: "تحذيران", en: "2 warnings"),
                few: LText(ar: "%ld تحذيرات", en: "%ld warnings"),
                many: LText(ar: "%ld تحذيرًا", en: "%ld warnings"),
                other: LText(ar: "%ld تحذير", en: "%ld warnings")
            )
        }
    }
}
