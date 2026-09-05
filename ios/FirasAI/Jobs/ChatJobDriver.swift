import Foundation

/// The durable chat queue: `chat`, `longdoc`, `longfile`, `codebuild` and `brainask` all read the
/// same status route and differ only in cadence, deadline and how many `unknown` reads are terminal.
///
/// Wire contract: `server-chat-jobs-chats.md §3.2–§3.5`, `server-code-brainask.md §1.7`.
struct ChatJobDriver: JobKindDriver {

    let kind: JobKind

    init(kind: JobKind) {
        self.kind = kind
    }

    var spec: JobKindSpec { JobKindSpecs.spec(kind) }

    func read(_ pointer: JobPointer, api: APIClient) async throws -> DriverRead {
        let status = try await api.chatJobStatus(id: pointer.id)
        switch status.phase.lowercased() {
        case "unknown":
            // The record is gone: expired past the six-hour retention, or never existed. The caller
            // counts these — one blip must not throw an answer away.
            return .unknown
        case "completed", "done":
            return .terminal(.completed(Self.snapshot(pointer, status, phase: .completed)))
        case "failed", "fail":
            return .terminal(Self.terminal(for: status, pointer: pointer, kind: kind))
        case "queued":
            return .running(Self.snapshot(pointer, status, phase: .queued))
        default:
            // `processing`, and anything a future deploy invents. A job that is not terminal is
            // running; that is the only safe default.
            return .running(Self.snapshot(pointer, status, phase: .processing))
        }
    }

    func cancel(_ pointer: JobPointer, api: APIClient) async throws -> Bool {
        guard spec.cancelable else { return false }
        do {
            return try await api.cancelChatJob(id: pointer.id)
        } catch let error as APIError {
            // 409 `job_not_running` (a queued chat job cannot be stopped before it starts), 404
            // `unknown_job`, 403 `not_yours`: every one of them means "the server will not stop
            // this", and the caller stops locally instead. Only transport failures propagate.
            if error.status != nil { return false }
            throw error
        }
    }

    func stream(_ pointer: JobPointer, api: APIClient) -> AsyncThrowingStream<DriverRead, Error>? {
        nil
    }

    // MARK: - Mapping

    private static func snapshot(_ pointer: JobPointer, _ status: ChatJobStatus, phase: JobPhase) -> JobSnapshot {
        JobSnapshot(
            pointerID: pointer.id,
            phase: phase,
            text: status.text,
            reasoning: status.reasoning,
            progress: status.progress,
            surface: status.surface,
            agent: nil,
            mediaKey: nil
        )
    }

    /// The three shapes a `failed` phase can carry, in the order the contract distinguishes them.
    private static func terminal(for status: ChatJobStatus, pointer: JobPointer, kind: JobKind) -> JobTerminal {
        let raw = status.error.trimmingCharacters(in: .whitespacesAndNewlines)

        // An automatic generation error may leave a real, separately identified partial PDF.
        // Explicit Stop does not mint a partial deliverable or silently resume the work.
        if kind == .counteddoc, status.status != 499,
           !["cancelled", "canceled"].contains(raw.lowercased()),
           let meta = FileMeta.document(inContent: status.text), meta.partial == true,
           meta.hasVerifiedPDFReference {
            return .failed(code: "partial_document", partial: snapshot(pointer, status, phase: .failed))
        }

        // A refusal: quota, rate limit or auth captured inside the worker. `error` is the JSON body
        // the live route would have returned, and `status` is its HTTP status — so it takes the same
        // ErrorPresenter path as a live 429.
        if status.status >= 400, let server = ServerError.parse(jsonString: raw) {
            return .refused(status: status.status, error: server)
        }

        // The user pressed Stop on a long file: partial output was discarded and nothing is shown.
        if status.status == 499
            || raw.caseInsensitiveCompare("cancelled") == .orderedSame
            || raw.caseInsensitiveCompare("canceled") == .orderedSame {
            return .cancelled
        }

        return .failed(code: raw.isEmpty ? "no_answer" : raw, partial: partial(pointer, status, kind: kind))
    }

    /// The output node is written empty at enqueue and is never cleared between attempts, so a
    /// failed build can still be carrying a complete project fence published by an earlier attempt.
    /// The web saves any parseable fence it sees regardless of phase; so do we — throwing away a
    /// finished project because the last attempt threw would be the worst outcome available.
    private static func partial(_ pointer: JobPointer, _ status: ChatJobStatus, kind: JobKind) -> JobSnapshot? {
        guard kind == .codebuild else { return nil }
        guard status.text.contains("```firas-project") else { return nil }
        return snapshot(pointer, status, phase: .failed)
    }
}
