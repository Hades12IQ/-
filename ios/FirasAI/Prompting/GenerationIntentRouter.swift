import Foundation

enum GenerationIntentRouter {
    static func isFinishedImagePrompt(_ text: String) -> Bool {
        guard text.utf16.count >= 220,
              String(text.prefix(200)).range(of: #"\?|\bwhat do you think\b|\bdescribe\b|\bexplain\b|\bis (this|it)\b|شنو رأيك|صف لي|اشرح|هل هذي|وش رأيك"#, options: [.regularExpression, .caseInsensitive]) == nil else { return false }
        let markers = [
            #"\b(photo-?realistic|hyper-?realistic|photoreal)\b"#,
            #"\bcinematic\b|\bسينمائ"#,
            #"\b(bokeh|depth of field|shallow depth|rim ?light|catchlight|golden hour|softbox|rembrandt)\b"#,
            #"\b\d{2,3} ?mm\b|\bf/\d"#,
            #"\b(midjourney|dall-?e|stable diffusion|flux|sora|imagen)\b"#,
            #"\b(--ar|aspect ratio|4k|8k|ultra[- ]detailed|octane|unreal engine|render)\b"#,
            #"\b(close-?up|wide shot|portrait|composition|framing)\b|\bلقطة\b|\bتكوين\b"#,
            #"\b(lighting|backlit|rim lighting)\b|\bإضاءة\b"#
        ]
        return markers.filter { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }.count >= 3
    }
    struct Decision: Decodable, Sendable {
        let kind: String
        let requirements: String
        let codeTarget: String
        let codeLanguage: String

        func requestKind(fallback: RequestKind, text: String, hasImages: Bool) -> RequestKind {
            switch kind {
            case "image": return .image
            case "edit-image": return hasImages ? .imageEdit : fallback
            case "video": return .video
            case "song": return .music
            case "code": return .code
            case "pdf", "docx", "pptx", "xlsx", "csv":
                func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
                if matches(#"\blatex\b|\btex\b|\\documentclass|\\begin\s*\{\s*document\s*\}|لاتيك|لات[يى]خ"#)
                    || (matches(#"\bsource\s*code\b|الكود\s*المصدر[يى]|كود\s*(?:المصدر|مصدر[يى])|شفرة\s*المصدر"#)
                        && !matches(#"(?:about|on|regarding|concerning|عن|حول|بخصوص)\s+(?:the\s+|its\s+|a\s+)?(?:source\s*code|الكود\s*المصدر[يى]|كود\s*(?:المصدر|مصدر[يى])|شفرة\s*المصدر)"#)) { return .chat }
                let pages = RequestClassifier.parseExplicitPageCount(text)
                if (kind == "pdf" || kind == "docx"), let pages, pages > 0 { return .longfile(format: kind, pages: pages) }
                return .file(format: kind, explicitPages: pages)
            case "chat":
                switch fallback {
                case .irab, .longdoc: return fallback
                default: return .chat
                }
            default: return fallback
            }
        }
    }
    /// Only a complete semantic verdict may opt Omnix into the conversational fast path.
    /// A timeout or malformed answer leaves the existing durable workshop route untouched.
    static func classify(_ text: String, history: [ChatMessage], api: APIClient, hasImages: Bool = false) async -> Decision? {
        guard !text.isEmpty, text.utf16.count <= 60_000 else { return nil }
        if !hasImages, isFinishedImagePrompt(text) { return Decision(kind: "image", requirements: "", codeTarget: "unknown", codeLanguage: "unknown") }
        struct Context: Encodable {
            let product = "chat"
            let attached_image: Bool
            let prior_image = false
            let recent_messages: [OutgoingMessage]
            let project_files: [String] = []
        }
        struct Input: Encodable { let request: String; let context: Context }
        let recent = history.filter { ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty }
            .suffix(6).map { OutgoingMessage(role: $0.role.rawValue, content: String($0.content.prefix(4000))) }
        guard let data = try? JSONEncoder().encode(Input(request: text, context: Context(attached_image: hasImages, recent_messages: recent))),
              let input = String(data: data, encoding: .utf8) else { return nil }
        return await withTaskGroup(of: Decision?.self) { group in
            group.addTask {
                var request = ChatStreamRequest(messages: [OutgoingMessage(role: "system", content: GenerationRouterPrompt.system),
                    OutgoingMessage(role: "user", content: input)], tier: ModelTier.mini.rawValue, think: false,
                    cid: IDs.cid(), product: "ai", nomem: true, nokb: true)
                request.router = true
                var output = ""
                do {
                    let frames = await api.chatStream(request)
                    for try await frame in frames {
                        try Task.checkCancellation()
                        if frame.isDone { break }
                        if let delta = StreamBuffer.delta(fromData: frame.data) { output += delta.content }
                        guard output.utf16.count <= 8000 else { return nil }
                    }
                    guard let bytes = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                          let result = try? JSONDecoder().decode(Decision.self, from: bytes),
                          ["chat", "image", "edit-image", "video", "song", "pdf", "docx", "pptx", "xlsx", "csv", "code"].contains(result.kind) else { return nil }
                    return result
                } catch { return nil }
            }
            group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
