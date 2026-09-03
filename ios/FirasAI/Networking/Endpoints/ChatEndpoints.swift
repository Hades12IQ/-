import Foundation

// Chat storage, the live SSE stream, web search, URL reading, translation and public shares.
// Wire shapes: server-chat-jobs-chats.md §1, §5.3, §6 and server-misc.md §1, §3, §5
// (verified against server.mjs 2411-2641, 3118-3135, 6035-6051, 6506-6536, 9207-9312, 12740).

// MARK: - Request bodies

private struct ChatTranslateBody: Encodable, Sendable {
    let text: String
    let to: String
}

// MARK: - Response envelopes

private struct ChatSearchEnvelope: Decodable, Sendable {
    let results: [WebSearchResult]?
    let via: String?
    let error: String?
}

private struct ChatFetchEnvelope: Decodable, Sendable {
    let text: String?
    let title: String?
    let error: String?
}

private struct ChatTranslateEnvelope: Decodable, Sendable {
    let text: String?
}

// MARK: - Endpoints

extension APIClient {

    /// `GET /api/chats` → summaries only (no messages), newest `updatedAt` first.
    func listChats() async throws -> [ChatSummary] {
        try await json(
            .get,
            "/api/chats",
            budget: .interactive,
            as: [ChatSummary].self
        )
    }

    /// `GET /api/chats/:id` → `{ id, title, messages }`. 404 also covers another user's chat.
    func getChat(id: String) async throws -> ChatConversation {
        try await json(
            .get,
            "/api/chats/\(id)",
            budget: .interactive,
            as: ChatConversation.self
        )
    }

    /// `POST /api/chats` → 201 `{ id, title, createdAt, updatedAt }`. Re-posting the same
    /// `clientId` returns the existing record, so a retry is safe.
    func createChat(_ req: CreateChatRequest) async throws -> ChatConversation {
        try await json(
            .post,
            "/api/chats",
            body: req,
            budget: .upload,
            as: ChatConversation.self
        )
    }

    /// `PUT /api/chats/:id` — merges top-level keys but **replaces** `messages` wholesale, so the
    /// caller must always send its complete local copy. Omitting `messages` leaves them untouched.
    func updateChat(id: String, _ req: UpdateChatRequest) async throws {
        _ = try await raw(
            .put,
            "/api/chats/\(id)",
            body: req,
            budget: .upload
        )
    }

    /// `DELETE /api/chats/:id` — immediate and permanent.
    func deleteChat(id: String) async throws {
        _ = try await raw(
            .delete,
            "/api/chats/\(id)",
            budget: .interactive
        )
    }

    /// `POST /api/chat` — the live SSE stream. Frames are
    /// `data: {"choices":[{"delta":{"content":…,"reasoning":…}}]}` and a final `data: [DONE]`.
    /// Cancelling the consuming task closes the socket, which is the server's stop for a live turn.
    func chatStream(_ req: ChatStreamRequest) -> AsyncThrowingStream<SSEFrame, Error> {
        stream(.post, "/api/chat", body: req)
    }

    /// `GET /api/search?q=` — the server reads `q` only (sliced to 300 chars) and returns at most
    /// 8 rows; `count` trims them client-side the way the web keeps its first 6.
    /// An empty list with `via:"none"` means "no results", not an error.
    func webSearch(query: String, count: Int) async throws -> [WebSearchResult] {
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        let envelope = try await json(
            .get,
            "/api/search",
            query: ["q": trimmed],
            budget: .interactive,
            as: ChatSearchEnvelope.self
        )
        let results = envelope.results ?? []
        guard count > 0 else { return results }
        return Array(results.prefix(count))
    }

    /// `GET /api/fetch?url=` — reads a pasted link as text. Any failure, non-2xx upstream, blocked
    /// host or non-text body still answers 200 with an empty `text`; treat empty as "could not read".
    func fetchURL(_ url: String) async throws -> String {
        let trimmed = String(url.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let envelope = try await json(
            .get,
            "/api/fetch",
            query: ["url": trimmed],
            budget: .interactive,
            as: ChatFetchEnvelope.self
        )
        return envelope.text ?? ""
    }

    /// `POST /api/translate` (member only) — text mode. The server slices `text` to 8 000 chars and
    /// answers 200 with the **original** text when the engine fails, so an unchanged string is not
    /// an error. Each upstream call has a 22 s ceiling, hence the poll budget.
    func translate(text: String, to lang: String) async throws -> String {
        let body = ChatTranslateBody(text: text, to: lang)
        let envelope = try await json(
            .post,
            "/api/translate",
            body: body,
            budget: .poll,
            as: ChatTranslateEnvelope.self
        )
        return envelope.text ?? ""
    }

    /// `POST /api/share` (member only) → `{ ok, id }`. Re-sharing the same chat or the same single
    /// answer returns the existing id.
    func createShare(_ req: ShareCreateRequest) async throws -> ShareInfo {
        try await json(
            .post,
            "/api/share",
            body: req,
            budget: .interactive,
            as: ShareInfo.self
        )
    }

    /// `GET /api/share?id=` — public, no auth.
    func getShare(id: String) async throws -> SharedChat {
        try await json(
            .get,
            "/api/share",
            query: ["id": id],
            budget: .interactive,
            as: SharedChat.self
        )
    }

    /// `DELETE /api/share?id=` — owner or admin; 200 even when the id is already gone.
    func deleteShare(id: String) async throws {
        _ = try await raw(
            .delete,
            "/api/share",
            query: ["id": id],
            budget: .interactive
        )
    }
}
