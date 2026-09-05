import Foundation

/// Item quantities and server revision/resume references never become a physical page count.
struct CountedDocumentPlan: Sendable, Equatable {
    let items: DocumentItemRequest
    let task: String
    var resumeFrom: String? = nil
    var revisionOf: String? = nil

    static func resolve(request: String, kind: RequestKind, history: [ChatMessage],
                        previous: ChatMessage?, isRevision: Bool) -> Self? {
        if let previous, let meta = FileMeta.document(in: previous),
           meta.hasVerifiedPDFReference, meta.partial == true,
           let original = meta.resumeJobId, FileMeta.validArtifactID(original),
           history.last(where: { $0.role == .assistant && !$0.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.id == previous.id,
           isContinue(request), let count = meta.expectedItems {
            return Self(items: DocumentItemRequest(count: count, requiresSolutions: meta.requiresSolutions == true,
                solutionsAtEnd: meta.solutionsAtEnd == true), task: request, resumeFrom: original)
        }
        let format: String
        switch kind {
        case .file(let value, _), .longfile(let value, _): format = value
        default: return nil
        }
        guard format == "pdf" else { return nil }
        if isRevision {
            // Legacy HTML retains its full source through the ordinary revision pipeline.
            guard let meta = FileMeta.document(in: previous), meta.counteddoc == true,
                  meta.hasVerifiedPDFReference, let id = meta.artifactId,
                  let expected = meta.expectedItems, expected > 0 else { return nil }
            let changed = DocumentItemRequest.parse(request)
            let settings = solutionSettings(request, previous: meta)
            let items = DocumentItemRequest(count: changed?.count ?? expected,
                requiresSolutions: settings.required, solutionsAtEnd: settings.atEnd)
            return Self(items: items, task: request, revisionOf: id)
        }
        guard let items = DocumentItemRequest.parse(request) else { return nil }
        return Self(items: items, task: request)
    }

    static func isContinue(_ request: String) -> Bool {
        request.trimmingCharacters(in: .whitespacesAndNewlines).range(of:
            #"^(?:(?:yes|ok|okay|please)[,،! .]*)?(?:continue|complete(?:\s+it)?|finish(?:\s+it)?|resume)(?:\s+(?:please|the\s+(?:file|document)|it|remaining\s+items))?[.! ]*$|^(?:(?:اي|إي|نعم|تمام|اوكي|أوكي)[،,!.\s]*)?(?:كمل|كمّل|اكمل|أكمل|كمله|كمّله|واصل)(?:\s+(?:الملف|الباقي|الباقي\s+كله))?[.!\s]*$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func solutionSettings(_ request: String, previous: FileMeta) -> (required: Bool, atEnd: Bool) {
        func matches(_ pattern: String) -> Bool {
            request.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let excluded = matches(#"\b(?:without|no|omit|exclude|remove|delete)\s+(?:(?:the|any|all|worked|full)\s+)*(?:solutions?|answers?)\b|(?:بدون|دون|بلا|احذف|شيل)\s*(?:ال)?(?:حلول|حل|اجوب[ةه]|أجوب[ةه])"#)
        if excluded { return (false, false) }
        var required = previous.requiresSolutions == true
        var atEnd = previous.solutionsAtEnd == true
        let requested = matches(#"\b(?:with|and|add|include|provide|put|place|move|arrange)\s+(?:(?:the|all|worked|full|matching)\s+)*(?:solutions?|answers?)\b|(?:مع|ضيف|أضف|اضف|اريد|أريد|خلي|رتب)\s*(?:ال)?(?:حلول|حل|اجوب[ةه]|أجوب[ةه])"#)
        if requested { required = true }
        if required {
            if matches(#"\bat\s+(?:the\s+)?(?:end|back)\b|بالنهاي[ةه]|في\s+النهاي[ةه]|بال[اأ]خير"#) { atEnd = true }
            if matches(#"\b(?:after|below|beside)\s+(?:each|every)\s+(?:problem|item|integral|question)\b|بعد\s*كل\s*(?:تكامل|سؤال|مسأل[ةه])"#) { atEnd = false }
        }
        return (required, required && atEnd)
    }

    /// Walk the actual document lineage, retaining quantity/layout instructions through terse edits.
    static func originalRequirements(previous: ChatMessage?, history: [ChatMessage]) -> String {
        var current = previous
        var seen: Set<String> = []
        var requests: [String] = []
        while let candidate = current, seen.insert(candidate.id).inserted, requests.count < 12,
              let index = history.firstIndex(where: { $0.id == candidate.id }),
              let userIndex = history[..<index].lastIndex(where: { $0.role == .user }) {
            let request = history[userIndex].visibleContent
            requests.append(request)
            let before = Array(history[..<userIndex])
            let prior = DocumentRevisionContext.latestMessage(in: before, request: request)
            guard DocumentRevisionContext.format(for: request, candidate: prior, history: before) != nil else { break }
            current = prior
        }
        return requests.reversed().joined(separator: "\n\n")
    }

    static let queueRequired = LText(
        ar: "إنشاء هذا الملف يحتاج مهمة محفوظة على الخادم حتى تكتمل كل العناصر. استخدم محادثة عادية، وتحقق من الاتصال وحجم المرفقات ثم أعد المحاولة.",
        en: "This document needs a durable server job to complete every item. Use a regular conversation, check the connection and attachment sizes, then retry.")
}
