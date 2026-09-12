import Foundation

// The durable chat queue: start, poll, cancel, long-file artifact reads, and the pre-charge.
// Wire shapes: server-chat-jobs-chats.md §3, §4.4 and server-auth-session-account.md §5.2
// (verified against server.mjs 10491-10578, 12478-12711, 7654-7681).

// MARK: - Request bodies

private struct JobCancelBody: Encodable, Sendable {
    let id: String
}

private struct JobUsageChargeBody: Encodable, Sendable {
    let product: String
    let cid: String
}

// MARK: - Response envelopes

private struct JobCancelEnvelope: Decodable, Sendable {
    let ok: Bool?
    let stopped: Bool?
}

/// The server's `jobTail` offsets use JavaScript string lengths (UTF-16 code units), not Swift
/// Characters or UTF-8 bytes. Keep the envelope separate from the whole-snapshot wire model so
/// consumers never accidentally display a suffix as a complete answer.
struct ChatJobTailResponse: Decodable, Sendable {
    let status: ChatJobStatus
    let from: Int?
    let fromR: Int?
    let textLen: Int?
    let reasoningLen: Int?

    init(from decoder: Decoder) throws {
        status = try ChatJobStatus(from: decoder)
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        from = LenientJSON.int(container, "from")
        fromR = LenientJSON.int(container, "fromR")
        textLen = LenientJSON.int(container, "textLen")
        reasoningLen = LenientJSON.int(container, "reasoningLen")
    }

    /// Missing/zero offsets mean a whole snapshot: an older server, the first read, or a restarted
    /// worker. A mismatched echoed offset/length cannot be joined safely and asks for a full read.
    func reconstructed(text: String, reasoning: String) -> ChatJobStatus? {
        func joined(_ tail: String, previous: String, offset: Int?, length: Int?) -> String? {
            let offset = offset ?? 0
            guard offset >= 0 else { return nil }
            let result: String
            if offset > 0 {
                guard offset == previous.utf16.count else { return nil }
                result = previous + tail
            } else {
                result = tail
            }
            if let length, length != result.utf16.count { return nil }
            return result
        }
        guard let wholeText = joined(status.text, previous: text, offset: from, length: textLen),
              let wholeReasoning = joined(status.reasoning, previous: reasoning, offset: fromR, length: reasoningLen)
        else { return nil }
        var whole = status
        whole.text = wholeText
        whole.reasoning = wholeReasoning
        return whole
    }
}

private struct ChatJobReceipt: Decodable, Sendable {
    var response: ChatJobStartResponse
    let chatID: String?

    init(from decoder: Decoder) throws {
        response = try ChatJobStartResponse(from: decoder)
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        chatID = LenientJSON.string(container, "chatId")
    }
}

// MARK: - Endpoints

extension APIClient {

    /// `POST /api/chat/job` — starts (or replays) any chat-queue kind: `chat`, `longdoc`,
    /// `longfile`, `agentrun`, `codebuild`, `brainask`. A replay of a finished `cid` answers
    /// `completed` with the text inline; a failed one answers `retryRequiresNewCid`.
    /// The user turn is never saved by the job — persist it before calling this.
    func startChatJob(_ req: ChatJobRequest) async throws -> ChatJobStartResponse {
        try await json(
            .post,
            "/api/chat/job",
            body: req,
            budget: .interactive,
            as: ChatJobStartResponse.self
        )
    }

    /// `GET /api/chat/job?id=` — always 200 unless auth or ownership fails. `text` grows while the
    /// job runs; `{"phase":"unknown"}` means the record is gone (three consecutive reads before
    /// treating it as terminal, per the watcher rules).
    func chatJobStatus(
        id: String, previousText: String = "", previousReasoning: String = ""
    ) async throws -> ChatJobStatus {
        let response = try await json(
            .get,
            "/api/chat/job",
            query: ["id": id, "from": String(previousText.utf16.count),
                    "fromR": String(previousReasoning.utf16.count)],
            budget: .poll,
            as: ChatJobTailResponse.self
        )
        if let whole = response.reconstructed(text: previousText, reasoning: previousReasoning) {
            return whole
        }
        // A malformed tail must never duplicate or truncate content. One read without cursors
        // restores the authoritative snapshot; it cannot enqueue, replay or cancel server work.
        return try await json(.get, "/api/chat/job", query: ["id": id], budget: .poll,
                              as: ChatJobStatus.self)
    }

    /// The current website reconciles an uncertain POST through this read-only receipt route.
    /// A receipt carries identity/phase only. Always attach a watcher for the full terminal body;
    /// returning `completed` here would otherwise land an empty answer from a finished receipt.
    func chatJobReceipt(cid: String, chatID: String?) async throws -> ChatJobStartResponse? {
        var receipt = try await json(.get, "/api/chat/job", query: ["cid": cid], budget: .poll,
                                     as: ChatJobReceipt.self)
        guard let id = receipt.response.jobId, !id.isEmpty, id.utf8.count <= 100,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        if let actual = receipt.chatID, !actual.isEmpty, actual != (chatID ?? "") {
            throw APIError.decoding("job receipt conversation mismatch")
        }
        receipt.response.phase = "queued"
        return receipt.response
    }

    /// `POST /api/chat/cancel` → `true` when the server stopped the job. A queued plain chat job
    /// cannot be stopped before it starts and answers `409 job_not_running` — that is not an
    /// error, it means "stop locally", so it returns `false`.
    func cancelChatJob(id: String) async throws -> Bool {
        let body = JobCancelBody(id: id)
        do {
            let envelope = try await json(
                .post,
                "/api/chat/cancel",
                body: body,
                budget: .interactive,
                as: JobCancelEnvelope.self
            )
            return envelope.stopped ?? (envelope.ok ?? false)
        } catch let error as APIError {
            if error.status == 409 { return false }
            throw error
        }
    }

    /// `GET /api/chat/job/file?id=` — the long-file manifest. Works after the 6 h queue TTL because
    /// the artifact meta and parts are permanent.
    func longFileManifest(jobID: String) async throws -> LongFileManifest {
        try await json(
            .get,
            "/api/chat/job/file",
            query: ["id": jobID],
            budget: .poll,
            as: LongFileManifest.self
        )
    }

    /// `GET /api/chat/job/file?id=&part=N` — one 0-based part. `404 part_not_ready` while the
    /// index is beyond `partsDone`.
    func longFilePart(jobID: String, index: Int) async throws -> LongFilePart {
        try await json(
            .get,
            "/api/chat/job/file",
            query: ["id": jobID, "part": String(index)],
            budget: .poll,
            as: LongFilePart.self
        )
    }

    /// `POST /api/usage/charge` — the pre-charge for a Code build or an Agent mission, taken
    /// before the work starts. The server reads `product` and `cid` only (`cid` is the idempotency
    /// key, so pass the turn's cid); `units` has no wire field and is accepted for interface
    /// compatibility. A guest asking for `agent` gets `403 signin_required`; a network failure
    /// should fail open, exactly as the web does.
    func usageCharge(
        product: ProductKind,
        units: Int,
        cid: String = ""
    ) async throws -> UsageChargeResponse {
        let body = JobUsageChargeBody(product: product.wireValue, cid: cid)
        return try await json(
            .post,
            "/api/usage/charge",
            body: body,
            budget: .interactive,
            as: UsageChargeResponse.self
        )
    }
}
