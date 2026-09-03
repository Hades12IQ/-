import Foundation

/// Folding attachments and prior context into the mission task (`web-agent-ux.md §11, §2.2.3`).
///
/// Nothing binary ever reaches the job: the server passes `task` straight to Manus, so images and
/// documents are read into **text** on the way in. The section headers below are the web's,
/// character for character — the mission prompt is a contract with the upstream agent, not UI copy.
extension AgentStore {

    // MARK: - Bounds (the web's)

    private static let taskLimit = 120_000
    private static let briefLimit = 3_500
    private static let visualLimit = 12_000
    private static let imageLimit = 30_000
    private static let fileLimit = 60_000
    private static let historyLimit = 3_000
    private static let previousFinalLimit = 12_000
    private static let briefThreshold = 4_000

    // MARK: - Section headers (verbatim)

    private static let fileBriefHeader =
        "\n\n=== خلاصة الملف المرفق (كل المتطلبات والأرقام — اعمل بها) / ATTACHED FILE BRIEF (every requirement and figure — work from it) ===\n"
    private static let visualReferenceHeader =
        "\n\n=== مرجع بصري مرفق — المستخدم أرفق تصميمًا/لقطة شاشة؛ أعِد بناءه في كود حقيقي بأقصى تطابق (نفس التخطيط والألوان والمكوّنات والنصوص) / ATTACHED VISUAL REFERENCE — REBUILD it in real code as closely as possible (same layout, colors, components, copy): ===\n"
    private static let imageContentHeader =
        "\n\n=== محتوى الصورة/الصور المرفقة (مصدر) / ATTACHED IMAGE CONTENT (source) ===\n"
    private static let fileContentHeader =
        "\n\n=== محتوى ملف مرفق (مصدر — ابنِ المطلوب منه) / ATTACHED FILE CONTENT (source — build from it) ===\n"
    private static let priorContextHeader =
        "\n\n=== سياق المحادثة السابقة / PRIOR CONVERSATION CONTEXT ===\n"
    private static let lastResultHeader =
        "\n\n=== آخر نتيجة سُلّمت / LAST DELIVERED RESULT ===\n"

    // MARK: - Entry point

    func foldedTask(
        base: String,
        attachments: [PreparedAttachment],
        history: [ChatMessage],
        previousFinal: String,
        lang: AppLanguage
    ) async -> String {
        var task = base

        let documentText = Self.documentText(from: attachments)
        let images = Array(attachments.compactMap { $0.imageBase64 }.prefix(10))

        if documentText.count >= Self.briefThreshold {
            let brief = await readFileBrief(task: base, documents: documentText, lang: lang)
            if !brief.isEmpty {
                task += Self.fileBriefHeader + String(brief.prefix(Self.briefLimit))
            }
        }

        if !images.isEmpty {
            let read = await readImages(task: base, images: images, lang: lang)
            if !read.isEmpty {
                if Self.wantsBuild(base) {
                    task += Self.visualReferenceHeader + String(read.prefix(Self.visualLimit))
                } else {
                    task += Self.imageContentHeader + String(read.prefix(Self.imageLimit))
                }
            }
        }

        if !documentText.isEmpty {
            task += Self.fileContentHeader + String(documentText.prefix(Self.fileLimit))
        }

        let prior = Self.priorContext(from: history)
        if !prior.isEmpty {
            task += Self.priorContextHeader + String(prior.prefix(Self.historyLimit))
        }
        let previous = previousFinal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !previous.isEmpty {
            task += Self.lastResultHeader + String(previous.prefix(Self.previousFinalLimit))
        }

        return String(task.prefix(Self.taskLimit))
    }

    // MARK: - Model reads

    /// A dense brief of the attached documents, produced by the ordinary chat engine at tier
    /// `pro` with memory off. An empty stream or an engine-busy notice is skipped silently.
    private func readFileBrief(task: String, documents: String, lang: AppLanguage) async -> String {
        let userText: String
        switch lang {
        case .arabic:
            userText = "المهمة التي سينفّذها الوكيل: " + String(task.prefix(400))
                + "\n\nالملف/الملفات المرفقة:\n" + String(documents.prefix(60_000))
        case .english:
            userText = "The task the agent will carry out: " + String(task.prefix(400))
                + "\n\nThe attached file(s):\n" + String(documents.prefix(60_000))
        }
        let request = Self.readerRequest(userText: userText, images: nil, lang: lang)
        return await Self.collectAnswer(api: api, request: request, seconds: 60)
    }

    private func readImages(task: String, images: [String], lang: AppLanguage) async -> String {
        let userText: String
        switch lang {
        case .arabic:
            userText = "اقرأ الصورة/الصور المرفقة (هذه مرجع لطلب المستخدم: " + String(task.prefix(300)) + ")."
        case .english:
            userText = "Read the attached image(s) (reference for the user's request: "
                + String(task.prefix(300)) + ")."
        }
        let request = Self.readerRequest(userText: userText, images: images, lang: lang)
        return await Self.collectAnswer(api: api, request: request, seconds: 75)
    }

    nonisolated private static func readerRequest(
        userText: String,
        images: [String]?,
        lang: AppLanguage
    ) -> ChatStreamRequest {
        let system = PromptCatalog.systemPrompt(
            tier: "pro",
            product: ProductKind.ai.wireValue,
            mode: ResponseMode.auto.rawValue,
            lang: lang.rawValue,
            think: false,
            requestKind: "chat"
        )
        return ChatStreamRequest(
            messages: [
                OutgoingMessage(role: "system", content: system),
                OutgoingMessage(role: "user", content: userText, images: images)
            ],
            tier: "pro",
            think: false,
            cid: IDs.cid(),
            chatId: nil,
            product: ProductKind.ai.wireValue,
            nomem: true
        )
    }

    /// Drains one `/api/chat` SSE stream into a string. Any failure answers `""` — the mission
    /// still starts, it simply carries no brief.
    nonisolated private static func collectAnswer(
        api: APIClient,
        request: ChatStreamRequest,
        seconds: Double
    ) async -> String {
        let collected: String
        do {
            collected = try await withDeadline(seconds: seconds) { () async throws -> String in
                var text = ""
                let frames = await api.chatStream(request)
                for try await frame in frames {
                    let payload = frame.data.trimmingCharacters(in: .whitespacesAndNewlines)
                    if payload.isEmpty || payload == "[DONE]" { continue }
                    guard let data = payload.data(using: .utf8) else { continue }
                    guard let chunk = try? JSONDecoder().decode(AgentReaderChunk.self, from: data) else { continue }
                    for choice in chunk.choices ?? [] {
                        if let piece = choice.delta?.content { text += piece }
                    }
                }
                return text
            }
        } catch {
            return ""
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || EngineFailureDetector.isFailure(trimmed) { return "" }
        return trimmed
    }

    // MARK: - Local text assembly

    nonisolated private static func documentText(from attachments: [PreparedAttachment]) -> String {
        var parts: [String] = []
        for attachment in attachments {
            guard let text = attachment.text, !text.isEmpty else { continue }
            let name = attachment.name.isEmpty ? "file" : attachment.name
            parts.append("--- " + name + " ---\n" + text)
        }
        return parts.joined(separator: "\n\n")
    }

    /// The prior user turns of this conversation, newest last, without the turn that started this
    /// mission (it is already the task).
    nonisolated private static func priorContext(from history: [ChatMessage]) -> String {
        var userTurns = history.filter { $0.role == .user }
        if !userTurns.isEmpty { userTurns.removeLast() }
        guard !userTurns.isEmpty else { return "" }
        var lines: [String] = []
        var budget = 2_500
        for turn in userTurns.suffix(8) {
            let text = turn.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let clipped = String(text.prefix(budget))
            lines.append(clipped)
            budget -= clipped.count
            if budget <= 0 { break }
        }
        return lines.joined(separator: "\n")
    }

    /// The web's `wantsBuild` test — a screenshot attached to a build request becomes a visual
    /// reference instead of plain image content.
    nonisolated private static func wantsBuild(_ text: String) -> Bool {
        let needles = [
            "موقع", "صفحة", "واجهة", "تطبيق", "مثل هذا", "نفس التصميم", "أعد بناء", "أعِد بناء",
            "clone", "rebuild", "website", "landing", "page", "app", "ui", "design", "screenshot"
        ]
        let haystack = ArabicText.normalize(text)
        for needle in needles where haystack.contains(ArabicText.normalize(needle)) {
            return true
        }
        return false
    }
}

/// One OpenAI-style SSE chunk from `/api/chat`.
private struct AgentReaderChunk: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Delta: Decodable, Sendable {
            var content: String?
        }
        var delta: Delta?
    }
    var choices: [Choice]?
}
