//
//  RequestClassifier.swift
//  FirasAI
//
//  The deterministic turn router. The web asks a "pro" model what a message is (`_classifyTurn`,
//  app.js:4130-4308) and only falls back to these regexes when that call fails; the native client
//  runs the regexes FIRST so a turn is routed before any network round-trip, and a store may still
//  refine the verdict with the model classifier afterwards (`ChatMessage.intent`).
//
//  Branch order is the plan's, not the web's: image-edit → image → video → music → longfile →
//  longdoc → file → code → i'rab → chat.
//
//  Pure functions, Foundation only. Nothing here touches a store, the network or the UI.
//

import Foundation

/// What the user expects to be holding when the turn finishes.
enum RequestKind: Sendable, Equatable {
    case chat
    case code
    /// A downloadable document. `format` is one of `pdf|docx|pptx|xlsx|csv`.
    case file(format: String, explicitPages: Int?)
    case image
    case imageEdit
    case video
    case music
    /// A book-length answer written chapter by chapter by the `longdoc` job.
    case longdoc(sections: Int)
    /// An exact-page pdf/docx written as durable parts by the `longfile` job.
    case longfile(format: String, pages: Int)
    case irab
}

enum RequestClassifier {

    // MARK: - Entry point

    /// Classify the last user message. `hasImages` is true when this very turn carries a photo
    /// (attached now, or silently re-attached by `refersToPreviousImage`).
    static func classify(_ text: String, hasImages: Bool, lang: AppLanguage) -> RequestKind {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .chat }

        let format = detectFileRequest(raw, hasAttachment: hasImages)

        /* A NAMED FORMAT OUTRANKS THE MEDIA VOCABULARY. The web never reaches these fallbacks for a
           document turn — a "pro" model reads the whole sentence first and `turnIntentIsDocument`
           then blocks every other route. Here the patterns run alone, and they overlap badly:
           «اعمل لي بوربوينت عن الأغاني العراقية» carries a song noun AND a make-verb, so the music
           gate claimed it and the deck was never written; «سوّي لي pdf فيه صورة القمر» carried
           «صورة» within the image gate's 24-character window. A prompt that names pptx/xlsx/docx/
           pdf/csv/txt outright is asking for that file, and nothing else. */
        let namesDocument = format != nil && (namesDocumentExplicitly(raw)
            || hasGenericDocumentDestination(raw) || isDocumentRevisionRequest(raw))
        let mediaIntent = MediaRequestIntent.resolve(raw, hasImages: hasImages)

        if !namesDocument, mediaIntent != .nonMedia, !detectCodeRequest(raw) {
            if case .media(let kind) = mediaIntent,
               kind != .image || !matches(mathFigurePattern, raw) { return kind }
            // A photo can be the source of a clip, rather than the image to edit.
            if hasImages, matches(imageToClipPattern, raw) || matches(videoMotionPattern, raw) { return .video }
            if hasImages, isImageEditRequest(raw) { return .imageEdit }
            // 2. Image generation. A turn that carries a photo is vision or an edit, never generation.
            if !hasImages, detectImageRequest(raw) { return .image }
            // 3. Video, 4. music.
            if detectVideoRequest(raw) { return .video }
            if songAskedPlainly(raw) { return .music }
        }

        let pages = parseExplicitPageCount(raw)

        // 5. An exact page count on a pdf/docx is the durable long-file pipeline.
        if let fmt = format, fmt == "pdf" || fmt == "docx", let p = pages, p > 0 {
            return .longfile(format: fmt, pages: p)
        }
        // 6. Encyclopedia-scale prose.
        if matches(longDocPattern, raw) { return .longdoc(sections: longDocSections(raw)) }
        // 7. An ordinary document.
        if let fmt = format {
            let explicit = (pages ?? 0) > 0 ? pages : nil
            return .file(format: fmt, explicitPages: explicit)
        }
        // 8. Software, 9. i'rab, 10. ordinary chat.
        if detectCodeRequest(raw) { return .code }
        if matches(irabPattern, raw) { return .irab }
        return .chat
    }

    // MARK: - Frozen helpers

    /// `detectCodeRequest` (app.js:2800-2837), evaluated in the web's exact order.
    static func detectCodeRequest(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if matches(codeDocOverridePattern, text) { return false }
        let spec = matches(codeSpecPattern, text)
        if matches(codeDrawRequestPattern, text), !matches(codeDrawAsAppPattern, text), !spec { return false }
        if spec { return true }
        if matches(codeAsksToLearnPattern, text) { return false }
        if !matches(codeBuildVerbsPattern, text) { return false }
        if matches(codeDocNounPattern, text) {
            let escapes = matches(codeGenericPattern, text)
                || matches(codeSoftPattern, text)
                || matches(codeDocEscapePattern, text)
            if !escapes { return false }
        }
        return matches(codeHardPattern, text) || matches(codeSoftPattern, text) || matches(codeGenericPattern, text)
    }

    /// `parseExplicitPageCount` (app.js:30219). `nil` when the user named no page count;
    /// `-1` when the count is syntactically explicit but above the 10 000-page ceiling, so the
    /// caller can refuse visibly instead of silently writing a short file.
    static func parseExplicitPageCount(_ text: String) -> Int? {
        let src = latinDigits(text)
        guard !src.isEmpty else { return nil }
        let ns = src as NSString
        let number = pageNumberGroup
        let unit = pageUnitGroup
        var found: [Int] = []

        for m in allMatches("(?:between|بين)\\s*" + number + "\\s*(?:" + unit + "\\s*)?(?:and|و)\\s*" + number + "\\s*" + unit, src) {
            let a = pageValue(group(m, 1, ns)), b = pageValue(group(m, 2, ns))
            if a > 0 && b > 0 { found.append(max(a, b)) }
        }
        for m in allMatches(number + "\\s*(?:" + unit + "\\s*)?(?:-|–|—|to|إلى|الى|حتى|تا)\\s*" + number + "\\s*" + unit, src) {
            let a = pageValue(group(m, 1, ns)), b = pageValue(group(m, 2, ns))
            if a > 0 && b > 0 { found.append(max(a, b)) }
        }
        let singlePattern = number + "\\s*(?:\\+\\s*)?(?:[-–—]\\s*)?" + unit + "(?=$|[^A-Za-z0-9\u{0600}-\u{06FF}])"
        for m in allMatches(singlePattern, src) {
            let location = m.range.location
            if location > 0 {
                let before = ns.substring(with: NSRange(location: location - 1, length: 1))
                // A digit or letter immediately before means this is the tail of another token.
                if matches("[A-Za-z0-9\u{0600}-\u{06FF}.\u{066B}]", before) { continue }
            }
            let start = max(0, location - 24)
            let prefix = ns.substring(with: NSRange(location: start, length: location - start))
            // "100 x 200 page size" is a dimension, not a requested document length.
            if matches("[0-9]\\s*[x\u{00D7}]\\s*$", prefix) { continue }
            let n = pageValue(group(m, 1, ns))
            if n > 0 { found.append(n) }
        }

        guard let requested = found.max() else { return nil }
        return requested > pageCountMax ? -1 : requested
    }

    /// `refersToPriorImage` (app.js:35913) — a follow-up that should silently reuse the chat's
    /// last attached or generated picture.
    static func refersToPreviousImage(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if MediaRequestIntent.refersToPreviousImage(text) { return true }
        if matches(imageTransformArabicPattern, text) { return true }
        if matches(imageTransformEnglishPattern, text) { return true }
        return matches(priorImagePattern, text)
    }

    // MARK: - Media predicates

    /// `detectImageRequest` (app.js:4960-4975).
    static func detectImageRequest(_ text: String) -> Bool {
        if matches(mathFigurePattern, text) { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, last == "?" || last == "؟" {
            // A message that OPENS with an interrogative is a question whatever else it holds:
            // «شنو أفضل صورة للقمر؟». «ممكن تصنع لي صورة؟» opens with politeness, not with «شنو».
            if matches(fileQuestionArabicLeadPattern, trimmed) { return false }
            if !matches(imageQuestionEscapePattern, text) { return false }
        }
        return matches(imageArabicPattern, text)
            || matches(imageArabicDrawPattern, text)
            || matches(imageEnglishPattern, text)
    }

    /// `detectImageEditRequest` (app.js:4825-4831). Only meaningful when a picture is in play.
    static func isImageEditRequest(_ text: String) -> Bool {
        return matches(imageEditArabicPattern, text) || matches(imageEditEnglishPattern, text)
    }

    /// The web decides video with a model call; this is the deterministic gate built from its
    /// fallback vocabulary (`MEDIA_MAYBE` + `MATH_FIGURE_RE`, app.js:4058-4070).
    static func detectVideoRequest(_ text: String) -> Bool {
        if text.count > 600 { return false }
        if matches(mathFigurePattern, text) { return false }
        // "شنو أفضل فيديو عن بغداد؟" — a question ABOUT clips is chat, not a request for one.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, last == "?" || last == "؟", matches(mediaAboutPattern, text) { return false }
        // A phrase that carries its own verb and object — "animate this", «خلي الصورة تتحرك» —
        // names no clip and is still unmistakably a request for one. Not, however, when the thing
        // being animated is a page: «خلي النص يتحرك بالموقع» and "make it move with CSS" are the
        // code path's, and the motion phrases alone cannot tell that apart.
        if matches(videoMotionPattern, text),
           !matches(codeSoftPattern, text), !matches(codeHardPattern, text) {
            return true
        }
        guard matches(videoNounPattern, text) else { return false }
        return matches(mediaMakeVerbPattern, text)
    }

    /// `songAskedPlainly` (app.js:41820-41830), widened on the ask side and fenced on the other.
    ///
    /// The web reaches this only when its model classifier failed, so it can afford to fire rarely.
    /// Here it is the only reader the sentence gets, and a miss is not a degraded answer — it is
    /// the app quietly writing lyrics at someone who asked for a song. So the vocabulary is wide,
    /// and everything narrowness used to buy is bought back by the five vetoes below, each one a
    /// line the classifier prompt draws in so many words.
    static func songAskedPlainly(_ text: String) -> Bool {
        /* The web's cap is 1200, and it is wrong for the commonest way a person asks for a song:
           they paste the words they want sung. Lyrics run past 1200 characters easily, and the
           whole request then fell through to an ordinary chat turn — which answered by writing
           more lyrics, so the reader got a poem where they asked for music. The cap exists to stop
           a long essay that merely mentions singing from being read as a request; 4000 still does
           that while leaving room for the words themselves. */
        if text.count > 4000 { return false }

        // 1. A question about music. «شنو افضل اغنية عراقية؟» — but «ممكن تصنع لي أغنية؟» is a
        //    request wearing Iraqi politeness, and the question mark must not cost it the feature.
        //    An interrogative in front settles it either way and is asked first.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, last == "?" || last == "؟" {
            if matches(fileQuestionArabicLeadPattern, trimmed) { return false }
            if !matches(songQuestionEscapePattern, text) { return false }
        }
        // 2. Words on the screen about a song that already exists.
        if asksAboutMusic(text) { return false }
        // 3. The lyrics alone, with no music asked for.
        if asksForLyricsOnly(text) { return false }
        // 4. A written deliverable that merely has music as its topic.
        if matches(songProsePattern, text) { return false }
        // 5. Software whose subject is music.
        if matches(songAsSoftwarePattern, text) { return false }

        if matches(songSingPattern, text) { return true }
        return matches(songMakeNounPattern, text) || matches(songNounMakePattern, text)
    }

    /// "It is CHAT when the thing they will end up with is words on the screen: asking what a song
    /// means, who sang it, what its story is, to translate it, to explain it" — the classifier
    /// prompt, verbatim. The first test is `detectFileRequest`'s own "reading, not producing" rule:
    /// a comprehension verb pointed at something that already exists.
    static func asksAboutMusic(_ text: String) -> Bool {
        if matches(comprehendVerbPattern, text), matches(refersExistingPattern, text) { return true }
        // The same boundary from the other side: a want pointed at KNOWING about music rather than
        // at holding a song. `comprehendVerbPattern` cannot see it — «اعرف» is not a comprehension
        // verb aimed at something already in the chat, it is the whole question.
        if matches(songKnowledgeAskPattern, text) { return true }
        return matches(songAboutPattern, text)
    }

    /// "'Write me lyrics' with no music asked for is chat." A sing verb, or a verb that says what
    /// to DO with the words, takes the turn back.
    static func asksForLyricsOnly(_ text: String) -> Bool {
        guard matches(songLyricsOnlyPattern, text) else { return false }
        if matches(songSingPattern, text) { return false }
        return !matches(songLyricsEscapePattern, text)
    }

    // MARK: - Documents

    /// `detectFileRequest(text, {hasAttachment})` (app.js:2923-3030). Returns the format the user
    /// wants handed over, or `nil` when nothing is being manufactured.
    static func detectFileRequest(_ text: String, hasAttachment: Bool) -> String? {
        guard !text.isEmpty else { return nil }
        let s = text.lowercased()

        // The user said NOT to make a file. Honour it.
        if matches(fileNegationEnglishPattern, s) { return nil }
        if matches(fileNegationArabicPattern, s) { return nil }
        if matches(fileNegationArabicVerbPattern, s) { return nil }

        let hasVerb = matches(fileRequestVerbsPattern, s)
        let isQuestion = matches(fileQuestionMarkPattern, s)
            || matches(fileQuestionArabicLeadPattern, s)
            || matches(fileQuestionArabicWordPattern, s)
            || matches(fileQuestionEnglishPattern, s)

        // A named DESTINATION decides the format first, so "حوّل هذا البي دي اف كملف وورد" is docx.
        if let target = outputFormatTarget(s) { return target }
        if isDocumentRevisionRequest(s) {
            // Honour a named Word/Excel/etc. target below; a generic existing document defaults
            // to the PDF path, where the conversation supplies the source being revised.
            if !namesDocumentExplicitly(s) { return "pdf" }
        }

        // Reading, not producing: a comprehension verb pointed at something that already exists.
        let points = matches(refersExistingPattern, s) || hasAttachment
        if matches(comprehendVerbPattern, s) && points { return nil }

        // An explicit pdf output request wins over an incidental sheet/slide mention.
        if (hasVerb || !isQuestion) && matches(filePdfDestinationPattern, s) { return "pdf" }

        let strong: [(format: String, pattern: String)] = [
            ("pptx", fileStrongPPTX), ("csv", fileStrongCSV), ("xlsx", fileStrongXLSX),
            ("docx", fileStrongDOCX), ("pdf", fileStrongPDF), ("txt", fileStrongTXT),
        ]
        for entry in strong where matches(entry.pattern, s) && (hasVerb || !isQuestion) {
            return entry.format
        }
        if isDesignedDocumentRequest(s) { return "pdf" }

        // Source code is not a document; the code path owns it.
        if detectCodeRequest(text) { return nil }

        let generic = matches(fileGenericPattern, s)
        let sWeak = replacingMatches(fileWeakStripPattern, in: s, with: " ")
        let weak: [(format: String, pattern: String)] = [
            ("pptx", fileWeakPPTX), ("xlsx", fileWeakXLSX), ("docx", fileWeakDOCX),
        ]
        for entry in weak where matches(entry.pattern, sWeak) && (hasVerb || generic) {
            return entry.format
        }

        // A request verb plus a generic "file/document" word defaults to PDF.
        if hasVerb && generic { return "pdf" }
        return nil
    }

    /// Did the prompt NAME a document format, rather than merely imply one? A generic
    /// «سويلي ملف» has not; «سويلي بوربوينت» has. Only a named format is allowed to outrank the
    /// image/video/music gates in `classify`.
    static func namesDocumentExplicitly(_ text: String) -> Bool {
        let s = text.lowercased()
        if outputFormatTarget(s) != nil { return true }
        if matches(filePdfDestinationPattern, s) { return true }
        let strong = [
            fileStrongPPTX, fileStrongCSV, fileStrongXLSX,
            fileStrongDOCX, fileStrongPDF, fileStrongTXT,
        ]
        for pattern in strong where matches(pattern, s) { return true }
        /* «اعمل لي عرض عن الأغاني العراقية» names a deck as plainly as «بوربوينت» does, and until
           the weak list learned «عرض عن» it was the music gate that answered it. Tested on the
           STRIPPED string for the same reason `detectFileRequest` does: "cheat sheet" and "sheet
           music" are neither a workbook nor a document. */
        let sWeak = replacingMatches(fileWeakStripPattern, in: s, with: " ")
        return matches(fileWeakPPTX, sWeak)
    }

    // MARK: - Which document THIS answer is

    /// `resolvedFileFormat` (app.js:3075): the classifier's stored verdict when the message carries
    /// one, the pattern otherwise. `nil` when the turn asked for no document at all.
    ///
    /// A stored `intent` of `"file"` is not a verdict — it is the app's own coarse label for the
    /// whole document family — so it falls through to the patterns, which name the format.
    static func documentFormat(for message: ChatMessage) -> String? {
        if let stored = message.intent?.trimmingCharacters(in: .whitespaces).lowercased(),
           documentFormats.contains(stored) {
            return stored
        }
        let hasAttachment = !(message.images?.isEmpty ?? true)
            || !(message.files?.isEmpty ?? true)
            || !((message.fileText ?? "").isEmpty)
        return detectFileRequest(message.content, hasAttachment: hasAttachment)
    }

    /// `requestedFormatForAssistant` (app.js:3092) — the format the user asked for in the turn this
    /// assistant row is answering. The `firas-file` fence the model writes for an ordinary file
    /// carries `filename`/`title`/`theme` and **no** `format` (`web-prompt-builder.md §A.6`), so
    /// this is the only place the card can learn whether it is holding a PDF or a workbook.
    static func documentFormat(forAssistantAt index: Int, in messages: [ChatMessage]) -> String? {
        guard index > 0, index <= messages.count else { return nil }
        var cursor = index - 1
        while cursor >= 0 {
            if messages[cursor].role == .user {
                let history = Array(messages[..<cursor])
                let request = messages[cursor].content
                let previous = DocumentRevisionContext.latestMessage(in: history, request: request)
                if let revision = DocumentRevisionContext.format(for: request, candidate: previous, history: history) {
                    return revision
                }
                return documentFormat(for: messages[cursor])
            }
            cursor -= 1
        }
        return nil
    }

    /// `outputFormatTarget` (app.js:2894) — the format named as a DESTINATION.
    static func outputFormatTarget(_ s: String) -> String? {
        for entry in fileFormatWords {
            let pattern = fileLeadBoundary + "(?:" + fileLeadPattern + ")(?:" + entry.pattern + ")"
            if matches(pattern, s) { return entry.format }
        }
        return nil
    }

    /// `longDocSections` (app.js:41519): roughly four printed pages per chapter, 6…240.
    static func longDocSections(_ text: String) -> Int {
        if let raw = firstCapture(longDocPagesPattern, latinDigits(text)), let pages = Int(raw), pages > 0 {
            let chapters = Int((Double(pages) / 4.0).rounded())
            return max(6, min(240, chapters))
        }
        return 40
    }

    // MARK: - Small regex utilities used above

    static func allMatches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard !text.isEmpty else { return [] }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return re.matches(in: text, options: [], range: range)
    }

    static func replacingMatches(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private static func group(_ m: NSTextCheckingResult, _ index: Int, _ ns: NSString) -> String {
        guard m.numberOfRanges > index else { return "" }
        let r = m.range(at: index)
        guard r.location != NSNotFound, r.length >= 0, r.location + r.length <= ns.length else { return "" }
        return ns.substring(with: r)
    }

    /// The web's `valueOf`: digit-group separators are dropped, anything else is not a count, and
    /// an unrepresentable number is an overflow rather than "no count".
    private static func pageValue(_ raw: String) -> Int {
        guard !raw.isEmpty else { return 0 }
        var digits = ""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "0"..."9":
                digits.unicodeScalars.append(scalar)
            case ",", "\u{066C}", "\u{060C}", "_", " ", "\u{00A0}", "\u{202F}":
                continue
            default:
                return 0
            }
        }
        guard !digits.isEmpty else { return 0 }
        guard let n = Int(digits) else { return pageCountMax + 1 }
        return n
    }
}
