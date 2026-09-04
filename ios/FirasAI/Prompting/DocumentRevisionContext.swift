import Foundation

/// A revision uses the entire latest authored document, independently of the chat history window.
/// The prior assistant message remains untouched until and after the new version is delivered.
struct DocumentRevisionContext: Sendable {
    let messageID: String
    let source: String
    var isHTML: Bool = true

    // Keep a full source within the inference and durable-job budgets. Refusing oversize input
    // is preferable to silently cutting the end of a document the user expects us to preserve.
    static let maximumSourceBytes = 300_000

    static func latestMessage(in history: [ChatMessage], request: String = "") -> ChatMessage? {
        let explicit = RequestClassifier.hasExplicitDocumentRevisionReference(request)
        var document: ChatMessage?
        var nearestArtifactIsDocument = false
        var questionRequestsDocument = false
        for message in history {
            if message.role == .user {
                let canRefer = document != nil && (nearestArtifactIsDocument
                    || RequestClassifier.hasExplicitDocumentRevisionReference(message.content))
                questionRequestsDocument = RequestClassifier.documentFormat(for: message) != nil
                    || RequestClassifier.documentRevisionFormat(message.content, hasPreviousDocument: canRefer) != nil
                continue
            }
            guard message.role == .assistant else { continue }
            let fence = FirasFence.firstFence(in: message.content)
            if fence?.name == "firas-file" {
                document = message
                nearestArtifactIsDocument = true
                continue
            }
            if DocumentHTML.authored(in: message.content) != nil
                || DocumentHTML.hasIncompleteAuthoredDocument(in: message.content) {
                // Carry document provenance through consecutive terse revisions, even after
                // client-only intent was removed during persistence. Website HTML stays code.
                if questionRequestsDocument { document = message }
                nearestArtifactIsDocument = questionRequestsDocument
                continue
            }
            if let name = fence?.name,
               ["firas-image", "firas-video", "firas-music", "firas-code", "firas-project"].contains(name) {
                nearestArtifactIsDocument = false
            }
        }
        return nearestArtifactIsDocument || explicit ? document : nil
    }

    static func completeSource(from message: ChatMessage?) -> DocumentRevisionContext? {
        guard let message else { return nil }
        if let source = DocumentHTML.authored(in: message.content) {
            guard source.utf8.count <= maximumSourceBytes else { return nil }
            return DocumentRevisionContext(messageID: message.id, source: source)
        }
        guard !DocumentHTML.hasIncompleteAuthoredDocument(in: message.content),
              message.content.utf8.count <= maximumSourceBytes,
              let fence = FirasFence.firstFence(in: message.content), fence.name == "firas-file",
              case .file(let meta)? = FirasFence.parse(name: fence.name, body: fence.body),
              (meta.artifactId ?? "").isEmpty, (meta.artifactEndpoint ?? "").isEmpty, meta.artifactParts == nil else { return nil }
        let body = (String(message.content[..<fence.range.lowerBound]) + String(message.content[fence.range.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        // Ordinary Office/text files are authored as markdown after their metadata fence.
        // Keep both, including every table row, instead of reconstructing from a preview.
        return DocumentRevisionContext(messageID: message.id, source: message.content, isHTML: false)
    }

    static func format(for request: String, candidate: ChatMessage?, history: [ChatMessage]) -> String? {
        guard let detected = RequestClassifier.documentRevisionFormat(request, hasPreviousDocument: candidate != nil) else { return nil }
        if RequestClassifier.namesDocumentExplicitly(request) { return detected }
        var current = candidate
        var visited: Set<String> = []
        while let candidate = current, visited.insert(candidate.id).inserted {
            if let fence = FirasFence.firstFence(in: candidate.content),
               case .file(let meta)? = FirasFence.parse(name: fence.name, body: fence.body) {
                if !meta.format.isEmpty { return meta.format }
                let extensionName = (meta.name ?? "").split(separator: ".").last.map(String.init)?.lowercased() ?? ""
                if ["pdf", "docx", "xlsx", "pptx", "csv", "txt"].contains(extensionName) { return extensionName }
            }
            guard let index = history.firstIndex(where: { $0.id == candidate.id }),
                  let questionIndex = history[..<index].lastIndex(where: { $0.role == .user }) else { break }
            let question = history[questionIndex]
            let before = Array(history[..<questionIndex])
            let previous = latestMessage(in: before, request: question.content)
            if !RequestClassifier.namesDocumentExplicitly(question.content),
               RequestClassifier.documentRevisionFormat(question.content, hasPreviousDocument: previous != nil) != nil {
                current = previous
                continue
            }
            return RequestClassifier.documentFormat(for: question) ?? detected
        }
        return detected
    }

    static let unavailable = LText(
        ar: "أحتاج مصدر الملف الكامل حتى أعدّل نفس التصميم بدون فقدان محتواه. الملف السابق باقٍ كما هو؛ أعد إرفاق مصدره، أو أكمل إنشاءه إذا كان متوقفاً.",
        en: "I need the complete document source to revise this design without losing its contents. The previous file is unchanged. Reattach its source, or finish its generation if it was interrupted."
    )

    static let tooLarge = LText(
        ar: "مصدر هذا الملف أكبر من سعة التعديل الحالية. أبقيت الملف كاملاً؛ حدّد جزءاً منفصلاً لتعديله بدلاً من قطع محتواه.",
        en: "This complete document exceeds the current revision capacity. The original file is intact. Supply a separate section to revise instead of truncating its contents."
    )
}
