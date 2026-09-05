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
            let items = changed ?? DocumentItemRequest(count: expected, requiresSolutions: meta.requiresSolutions == true,
                solutionsAtEnd: meta.solutionsAtEnd == true)
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
