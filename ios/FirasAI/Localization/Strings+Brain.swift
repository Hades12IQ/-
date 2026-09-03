import Foundation

/// Firas Brain copy — the web's `brainT()` table, verbatim
/// (`web-brain-ux.md §5.1, §7.9, §10, §11`, `server-brain.md §15`).
///
/// Arabic first, English second. Anything the web builds by string concatenation is an `LText`
/// with `%@` placeholders here, so Arabic agreement and Arabic-Indic digits stay under our control
/// (`ARCHITECTURE.md §2.9`): the caller renders the number with `ArabicText.count` and passes it in.
extension Strings {

    enum Brain {

        // MARK: - Hero and library chrome

        static let heroTitle = LText(ar: "اسأل ملفاتك", en: "Ask your files")

        static let heroBody = LText(
            ar: "ارفع ملفاتك واسأل عنها — كل معلومة في الجواب موثّقة بالصفحة اللي جات منها.",
            en: "Upload your documents and ask — every claim in the answer is cited to the page it came from."
        )

        static let sources = LText(ar: "المصادر", en: "Sources")
        static let sourcesHead = LText(ar: "مصادرك", en: "Your sources")
        static let add = LText(ar: "إضافة ملفات", en: "Add files")

        static let addHint = LText(
            ar: "PDF، Word، PowerPoint، Excel، نصوص، وصور",
            en: "PDF, Word, PowerPoint, Excel, text and images"
        )

        static let noSources = LText(ar: "ما في مصادر بعد", en: "No sources yet")
        static let noSourcesHint = LText(ar: "ارفع أول ملف لتبدأ", en: "Upload your first file to begin")

        static let askPlaceholder = LText(ar: "اسأل عن ملفاتك…", en: "Ask about your files…")
        static let askNoSources = LText(ar: "ارفع ملفًا أولًا", en: "Upload a file first")

        // MARK: - Units (the citation noun; the web's own `p.` abbreviation in English)

        static let unitPage = LText(ar: "صفحة", en: "p.")
        static let unitSlide = LText(ar: "شريحة", en: "slide")
        static let unitSheet = LText(ar: "ورقة", en: "sheet")
        static let unitSection = LText(ar: "قسم", en: "section")

        static func unit(_ unit: BrainDocumentUnit) -> LText {
            switch unit {
            case .page: return unitPage
            case .slide: return unitSlide
            case .sheet: return unitSheet
            case .section: return unitSection
            }
        }

        /// `"صفحة ٤٢"` / `"p. 42"` — the label under a source row and inside a citation tooltip.
        static func unitAndNumber(_ unit: BrainDocumentUnit, _ number: Int, _ lang: AppLanguage) -> String {
            Self.unit(unit)(lang) + " " + ArabicText.count(number, lang)
        }

        /// `"١٢ صفحة"` / `"12 p."` — the page count in a library row.
        static func pagesCount(_ number: Int, _ unit: BrainDocumentUnit, _ lang: AppLanguage) -> String {
            ArabicText.count(number, lang) + " " + Self.unit(unit)(lang)
        }

        // MARK: - Import phases

        static let indexing = LText(ar: "يفهرس", en: "Indexing")
        static let reading = LText(ar: "يقرأ", en: "Reading")
        static let readingScanned = LText(ar: "يقرأ الصفحات المصوّرة", en: "Reading scanned pages")
        static let uploading = LText(ar: "يرفع", en: "Uploading")
        static let indexed = LText(ar: "تمّت الفهرسة", en: "Indexed")

        static let ocrToggle = LText(
            ar: "اقرأ بالرؤية (أدق للملفات العربية والمصوّرة — أبطأ)",
            en: "Read with vision (better for Arabic & scanned files — slower)"
        )

        static let dropHere = LText(ar: "أفلت الملفات هنا", en: "Drop files here")

        // MARK: - Import errors

        static let unsupported = LText(ar: "نوع ملف غير مدعوم", en: "Unsupported file type")
        static let readFail = LText(ar: "تعذّرت قراءة الملف", en: "Couldn't read the file")
        static let noText = LText(ar: "ما لقيت نص في هذا الملف", en: "No readable text in this file")
        static let limitDocs = LText(ar: "وصلت الحد الأقصى للمستندات", en: "Document limit reached")
        static let limitPages = LText(ar: "وصلت حدّ الصفحات اليومي", en: "Daily page limit reached")
        static let tooLarge = LText(ar: "الملف كبير جدًا", en: "File too large")

        static let ocrAllEmpty = LText(
            ar: "تعذّرت قراءة هذا الملف الآن — محرّك القراءة مشغول. جرّب رفعه مجددًا بعد دقائق.",
            en: "Could not read this file right now — the reading engine is busy. Try uploading again in a few minutes."
        )

        static let visionOut = LText(
            ar: "حصة القراءة بالرؤية انتهت اليوم — الملف انفهرس بنصّه المستخرج فقط",
            en: "Today's vision budget is spent — the file was indexed from its extracted text only"
        )

        /// `ocrCap(n,total)` — `%1$@` pages read, `%2$@` total candidates.
        static let ocrCap = LText(
            ar: "قرأت %1$@ صفحة مصوّرة من %2$@ — الباقي بقي بنصّه المستخرج",
            en: "Read %1$@ of %2$@ scanned pages — the rest kept their extracted text"
        )

        /// `ocrPartial(n,total)`.
        static let ocrPartial = LText(
            ar: "توقّفت الرؤية عند %1$@/%2$@ — حُفِظ ما قُرئ والباقي بنصّه المستخرج",
            en: "Vision stopped at %1$@/%2$@ — kept what it read; the rest use their extracted text"
        )

        // MARK: - Usage line

        static let usageDocs = LText(ar: "المستندات", en: "Documents")
        static let usagePages = LText(ar: "صفحات اليوم", en: "Pages today")

        static let usageFull = LText(
            ar: "امتلأت المكتبة — احذف مستندًا لإضافة غيره",
            en: "Library is full — delete a document to add another"
        )

        static let excludedHint = LText(ar: "مستبعد من البحث", en: "excluded from search")

        // MARK: - Pins

        static let pinLabel = LText(ar: "مثبّت", en: "Pinned")
        static let pinAdd = LText(ar: "ثبّت هذا المستند", en: "Pin this document")
        static let pinDrop = LText(ar: "إزالة التثبيت", en: "Unpin")
        static let pinClear = LText(ar: "إزالة التثبيت عن الكل", en: "Clear all pins")

        static let pinWhy = LText(
            ar: "المستند المثبّت يبقى داخل البحث في كل محادثة، والملفات الجديدة تبقى خارجه حتى تضمّها بنفسك.",
            en: "A pinned source stays in the search in every chat; files added later stay out of it until you add them yourself."
        )

        // MARK: - Summarize

        static let summarize = LText(ar: "لخّص المستند", en: "Summarize")

        static let summarizeTip = LText(
            ar: "خريطة للمستند: أقسامه بترتيبها وأهم ما في كل قسم، وكل نقطة موثّقة بصفحتها",
            en: "A map of the document: its sections in order and what each one says, every point cited to its page"
        )

        static let summarizeAskOne = LText(ar: "لخّص لي هذا المستند", en: "Summarize this document")
        static let summarizeAskMany = LText(ar: "لخّص لي هذي المستندات", en: "Summarize these documents")

        static func summarizeAsk(_ count: Int, _ lang: AppLanguage) -> String {
            count > 1 ? summarizeAskMany(lang) : summarizeAskOne(lang)
        }

        // MARK: - Page range chip

        static let scope = LText(ar: "الصفحات", en: "Pages")
        static let scopePages = LText(ar: "صفحة", en: "pp.")
        static let scopeHint = LText(ar: "حصر البحث في صفحات معيّنة", en: "Limit the search to a page range")
        static let scopeRemove = LText(ar: "إزالة النطاق", en: "Remove range")
        static let scopeFrom = LText(ar: "من", en: "from")
        static let scopeTo = LText(ar: "إلى", en: "to")
        static let scopeApply = LText(ar: "تطبيق", en: "Apply")

        // MARK: - Compare chip

        static let compare = LText(ar: "قارن مستندين", en: "Compare two")

        static let compareTip = LText(
            ar: "اسأل سؤالًا واحدًا وشوف جواب كل مستند لحاله بمصادره",
            en: "Ask one question and see each document answer it on its own, with its own citations"
        )

        static let compareNeedsTwo = LText(
            ar: "اختر مستندين بالضبط من القائمة، ثم اسأل سؤالك",
            en: "Select exactly two documents in the list, then ask your question"
        )

        static let compareOn = LText(
            ar: "المقارنة مفعّلة — سؤالك الجاي يروح للمستندين",
            en: "Compare is on — your next question goes to both documents"
        )

        // MARK: - Thread notices

        static let thinking = LText(ar: "يبحث في مصادرك…", en: "Searching your sources…")
        static let wholeReading = LText(ar: "يقرأ المستند كاملًا…", en: "Reading the whole document…")
        static let searching = LText(ar: "يوسّع البحث بلغتين…", en: "Widening the search across languages…")

        /// `cmpWorking(d,t)` — `%1$@` of `%2$@`.
        static let compareWorking = LText(
            ar: "يقرأ المستند… %1$@/%2$@",
            en: "Reading document… %1$@/%2$@"
        )

        static let queued = LText(
            ar: "السؤال في الطابور — الجواب يكمل حتى لو خرجت من التطبيق.",
            en: "Queued — the answer keeps going even if you leave the app."
        )

        // MARK: - Thread outcomes

        static let noHits = LText(
            ar: "ما لقيت في مصادرك شيئًا يجاوب على هذا السؤال.",
            en: "I couldn't find anything in your sources that answers this."
        )

        /// `rangeEmpty(r)` — `%@` is the rendered range, e.g. `٤٠–٧٠`.
        static let rangeEmpty = LText(
            ar: "لا يوجد شيء في هذا النطاق (الصفحات %@). وسّع النطاق أو أزله لتشمل بقية المستند.",
            en: "There is nothing in that range (pages %@). Widen it or remove it to search the rest of the document."
        )

        static let gone = LText(
            ar: "المقطع لم يعد متاحًا (حُذف المصدر).",
            en: "This passage is no longer available (the source was deleted)."
        )

        static let matchHint = LText(ar: "أقرب سطر لسؤالك", en: "Closest to your question")

        static let showMore = LText(ar: "عرض المزيد", en: "Show more")
        static let showLess = LText(ar: "عرض أقل", en: "Show less")

        /// The shared dictation button, from the main `STR` table (`web-brain-ux.md §5.2`).
        static let micLabel = LText(ar: "إدخال صوتي", en: "Voice input")

        static let engineFail = LText(
            ar: "تعذّر الوصول للمحرّك. حاول مرة أخرى.",
            en: "Couldn't reach the engine. Please try again."
        )

        /// Appended to a partial answer when the reader pressed Stop. The web writes it as an
        /// italic line of its own, so the leading blank line is part of the string.
        static let stopped = LText(ar: "\n\n_(أُوقف الشرح)_", en: "\n\n_(stopped)_")

        // MARK: - Copy bar

        static let copyAll = LText(ar: "نسخ الكل", en: "Copy all")
        static let copyWithPages = LText(ar: "نسخ مع الصفحات", en: "Copy with pages")
        static let copySourcesHeading = LText(ar: "المصادر:", en: "Sources:")

        // MARK: - Passage reader

        static let openSource = LText(ar: "فتح المصدر", en: "Open the source")
        static let passageTitle = LText(ar: "المقطع", en: "Passage")

        // MARK: - Empty / error states

        static let libraryLoadFailed = LText(
            ar: "تعذّر تحميل مصادرك.",
            en: "Couldn't load your sources."
        )

        static let emptyHistory = LText(
            ar: "لا توجد محادثات بعد — ارفع ملفاتك واسأل عنها، والإجابة تجيك موثّقة بالصفحة.",
            en: "No conversations yet — upload your files and ask; every answer cites its page."
        )

        static let deleteConfirm = LText(
            ar: "حذف هذا المستند من مكتبتك؟",
            en: "Delete this document from your library?"
        )

        // MARK: - Kind tags (never translated, `brainKindTag`)

        static func kindTag(_ kind: BrainDocumentKind) -> String {
            switch kind {
            case .pdf: return "PDF"
            case .docx: return "DOC"
            case .pptx: return "PPT"
            case .xlsx: return "XLS"
            case .image: return "IMG"
            case .text: return "TXT"
            }
        }
    }
}
