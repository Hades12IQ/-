import Foundation

enum PromptEngineering {
    static func range(in text: String) -> Range<String.Index>? {
        text.range(of: #"(?i)(?<!\S)/prompteng(?=\s|$)"#, options: .regularExpression)
    }
    static func request(in text: String) -> String? {
        guard let range = range(in: text) else { return nil }
        var value = text; value.removeSubrange(range)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func stream(request: String, language: AppLanguage, api: APIClient) async -> AsyncThrowingStream<SSEFrame, Error> {
        var body = ChatStreamRequest(messages: [
            OutgoingMessage(role: "system", content: language == .arabic ? GenerationPrompts.promptAR : GenerationPrompts.promptEN),
            OutgoingMessage(role: "user", content: request)
        ], tier: ModelTier.mini.rawValue, think: false, cid: IDs.cid(), product: "ai", nomem: true, nokb: true)
        body.promptEng = true
        return await api.chatStream(body)
    }
}
