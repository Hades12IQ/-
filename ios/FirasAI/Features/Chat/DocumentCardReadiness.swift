import Foundation

/// A terminal transport state is not evidence that a generated document is complete.
enum DocumentCardReadiness: Equatable {
    case preparing
    case ready
    case blocked(String)

    var canOpen: Bool { self == .ready }
    var errorText: String? {
        if case .blocked(let message) = self { return message }
        return nil
    }

    static func evaluate(message: ChatMessage, meta: FileMeta, request: String,
                         isStreaming: Bool, lang: AppLanguage) -> Self {
        if meta.serverPdf == true {
            guard !isStreaming, message.status.isTerminal else { return .preparing }
            // An error can leave a real, labelled partial PDF. It is still verified on download.
            if case .failed = message.status, meta.partial != true { return .blocked(failed(lang)) }
            return meta.hasVerifiedPDFReference ? .ready : .blocked(incomplete(lang))
        }
        if case .failed = message.status { return .blocked(failed(lang)) }
        let durable = !(meta.jobId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if durable { return .ready }
        guard !isStreaming, message.status.isTerminal else { return .preparing }
        let source = message.visibleContent
        if DocumentHTML.hasIncompleteAuthoredDocument(in: source) { return .blocked(incomplete(lang)) }
        var body = source
        if let fence = FirasFence.firstFence(in: source), fence.name == "firas-file" {
            body.removeSubrange(fence.range)
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .blocked(incomplete(lang))
        }
        if case .stopped = message.status, DocumentHTML.authored(in: source) == nil {
            return .blocked(incomplete(lang))
        }
        let completion = DocumentCompletionChecks.validate(markdown: source, request: request)
        guard completion.isComplete else {
            return .blocked(completion.message(lang: lang) ?? incomplete(lang))
        }
        return .ready
    }

    static func request(for messageID: String, in conversation: ChatConversation?) -> String {
        guard let messages = conversation?.messages,
              let index = messages.firstIndex(where: { $0.id == messageID && $0.role == .assistant }) else { return "" }
        return messages[..<index].last(where: { $0.role == .user })?.content ?? ""
    }

    static let failed = LText(ar: "تعذّر إكمال هذا الملف. أعد المحاولة من المحادثة لإنشائه كاملاً.",
                             en: "This file could not be completed. Retry the answer to create the full document.")
    static let incomplete = LText(ar: "إنشاء الملف غير مكتمل. أعد المحاولة من المحادثة قبل فتحه أو حفظه.",
                                 en: "This document is incomplete. Retry the answer before opening or saving it.")
}

/// Prevent a slow export of one answer version from opening over a different selected version.
struct DocumentCardSnapshot: Equatable {
    let ownerID: String?
    let messageID: String
    let source: String
    let version: Int?
    let status: DeliveryStatus

    init(message: ChatMessage, ownerID: String?) {
        self.ownerID = ownerID
        messageID = message.id
        source = message.visibleContent
        version = message.altAt
        status = message.status
    }

    func matches(_ message: ChatMessage?, ownerID: String?) -> Bool {
        guard self.ownerID == ownerID, let message, message.role == .assistant else { return false }
        return messageID == message.id && source == message.visibleContent
            && version == message.altAt && status == message.status
    }
}
