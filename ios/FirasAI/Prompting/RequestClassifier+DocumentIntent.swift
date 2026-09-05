import Foundation

extension RequestClassifier {
    /// The destination can be a generic document even when its sources are photographs.
    static func hasGenericDocumentDestination(_ text: String) -> Bool {
        matches(#"(?:إلى|الى|بصيغة|على\s*شكل|كـ?|\b(?:as|into|to)\s+(?:an?\s+)?)(?:\s*)(?:ملف|مستند|وثيقة|file\b|document\b)"#, text)
    }

    /// A concrete existing document is being revised, while an attached screenshot is evidence.
    /// Merely reviewing/explaining a file, or editing an image file, does not satisfy this gate.
    static func isDocumentRevisionRequest(_ text: String) -> Bool {
        let edit = #"(?:^|\s)(?:عدّل|عدل|حدّث|حدث|حرّر|حرر|غيّر|غير|revise|edit|update|modify)(?:\s|$)"#
        let existing = #"(?:نفس\s+(?:ال)?|هذا\s+(?:ال)?|هال|ال)(?:ملف|مستند|وثيقة)|\b(?:this|the|same|existing)\s+(?:file|document|pdf)\b"#
        return matches(edit, text) && matches(existing, text)
    }

    /// A terse edit continues the most recent authored document. Callers supply whether a real
    /// source exists; this function never treats an arbitrary prior answer as a document.
    static func documentRevisionFormat(_ text: String, hasPreviousDocument: Bool) -> String? {
        guard hasPreviousDocument else { return nil }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !detectCodeRequest(text) else { return nil }
        if matches(fileNegationEnglishPattern, text) || matches(fileNegationArabicPattern, text)
            || matches(fileNegationArabicVerbPattern, text) { return nil }
        // Reading quoted instructions must not apply them to the previous file.
        if matches(#"^(?:please\s+)?(?:translate|explain|summari[sz]e|review|how|what|why|which)\b|^(?:ترجم|اشرح|وضح|لخص|شنو|شلون|كيف|ليش|لماذا|هل)(?:\s|$)"#, text) { return nil }
        if matches(#"^(?:please\s+)?(?:don['’]?t|do\s+not|never)\s+(?:edit|change|remove|delete|replace|add|fix|revise)\b|^لا\s+(?:تعدل|تعدّل|تغير|تغيّر|تكبر|تصغر|تحذف|تبدل|تضيف)"#, text) { return nil }
        let revision = #"(?:^|\s)(?:عدّل|عدل|حدّث|حدث|حرّر|حرر|غيّر|غير|احذف|إحذف|شيل|امسح|استبدل|بدّل|بدل|ضيف|اضف|أضف|صحح|صحّح|رتب|رتّب|لون|لوّن|كبّر|كبر|صغر|صغّر|revise|edit|update|modify|remove|delete|replace|change|add|fix|recolou?r|reformat|resize)(?:\s|$)"#
        let explicitDocument = hasExplicitDocumentRevisionReference(text)
        let attachedPronounEdit = #"(?:^|\s)(?:عدله|عدّله|غيره|غيّره|رتبه|رتّبه|كبره|كبّره|صغره|صغّره)(?:\s|$|[،,؛;.!؟?])"#
        guard matches(revision, text) || matches(attachedPronounEdit, text)
            || hasActionableDocumentFeedback(text, explicitDocument: explicitDocument) else { return nil }
        // A separate creation remains media even when a document happens to precede it.
        if !explicitDocument, case .media(let kind) = MediaRequestIntent.resolve(text, hasImages: false),
           kind == .image || kind == .video || kind == .music { return nil }
        if !explicitDocument,
           matches(#"(?:عدّل|عدل|حرر|حرّر|حسن|حسّن)\s+(?:هذه\s+|هاي\s+|هال)?(?:الصورة|الصوره|صورة|صوره)|\b(?:edit|retouch|crop|upscale)\s+(?:this\s+|the\s+)?(?:image|photo|picture)\b"#, text) {
            return nil
        }
        // Keep an explicitly requested output extension; screenshot presence is only evidence.
        return outputFormatTarget(text.lowercased()) ?? detectFileRequest(text, hasAttachment: false) ?? "pdf"
    }

    /// Explicit references may reach an earlier document across a later image or song. Implicit
    /// edits are resolved only against the newest artifact by DocumentRevisionContext.
    static func hasExplicitDocumentRevisionReference(_ text: String) -> Bool {
        isDocumentRevisionRequest(text)
            || matches(#"(?:الملف|المستند|الوثيقة)|\b(?:pdf|document|booklet|brochure)\b"#, text)
    }

    /// Concrete feedback about the existing file's layout is an edit brief even without an
    /// imperative. A generic complaint or a question does not create a new version by itself.
    private static func hasActionableDocumentFeedback(_ text: String, explicitDocument: Bool) -> Bool {
        guard !text.contains("؟"), !text.contains("?") else { return false }
        let screenshotReference = matches(#"(?:بالصورة|بالصوره|الصورة\s+المرفقة|المحدد\s+بالصورة)|\b(?:attached\s+)?screenshot\b"#, text)
        // A concrete new specification after a real document is a revision even without “file”.
        let dissatisfied = matches(#"\b(?:i\s+(?:do(?:n['’]t|\s+not)\s+like|dislike)|not\s+what\s+i\s+want)\b|(?:ما\s*عجبني|مو\s*عاجبني|ما\s*اريده\s*هيج)"#, text)
        let replacement = matches(#"\b(?:i\s+want|make|very\s+hard|harder|new\s+ideas|pro(?:fessional)?\s+design|better\s+design)\b|(?:اريد|أريد|خليه|خليها|اصعب|أصعب|تصميم\s+احترافي)"#, text)
        if dissatisfied && replacement { return true }
        guard explicitDocument || screenshotReference else { return false }
        let aspect = #"(?:الخط|حجم\s+الخط|الكتابة|النص|اللون|الألوان|الالوان|التنسيق|المسافات|الهوامش|\b(?:font|text|colou?r|spacing|margins?|layout)\b)"#
        let problem = #"(?:صغير|كبير|مقطوع|متداخل|ملتصق|مو\s*واضح|غير\s*واضح|ما\s*ينقري|ما\s*عجبني|مو\s*حلو|سي[ءئ]|\b(?:too\s+small|too\s+large|tiny|unreadable|clipped|overlapping|cramped)\b)"#
        if matches(aspect + #"[^.!؟?\n]{0,70}"# + problem, text)
            || matches(problem + #"[^.!؟?\n]{0,40}"# + aspect, text) { return true }
        return explicitDocument && matches(#"(?:شكله|تصميمه|تنسيقه)\s*(?:حيل\s*)?(?:سي[ءئ]|مو\s*حلو|مو\s*مرتب)|(?:شكل|تصميم|تنسيق)\s+الملف\s*(?:حيل\s*)?(?:سي[ءئ]|مو\s*حلو|مو\s*مرتب)"#, text)
    }

    /// A booklet/brochure is a designed deliverable; a report becomes one when the request also
    /// asks for its visual layout. A plain question or prose request retains the normal chat path.
    static func isDesignedDocumentRequest(_ text: String) -> Bool {
        guard matches(fileRequestVerbsPattern, text) else { return false }
        if matches(#"\b(?:booklet|brochure|workbook)\b|كتيّ?ب|كرا[سّ]ة|مطوية|ملزمة"#, text) { return true }
        let report = #"\b(?:report|guide)\b|تقرير|دليل"#
        let layout = #"\b(?:professional|professionally|designed|illustrated|layout|photos|images|beautifully)\b|احترافي|احترافية|مصمّم|مصمم|منسّق|منسق|صور|رسوم|تصميم"#
        return matches(report, text) && matches(layout, text)
    }
}
