import Foundation

/// Firas Agent missions. The only kind with a push channel: `GET /api/agent/job-stream` delivers a
/// full snapshot whenever the mission moves, and the poll below exists purely as the fallback.
///
/// Wire contract: `server-agent.md §7, §8, §9, §12.2, §14`.
struct AgentJobDriver: JobKindDriver {

    let kind: JobKind = .agentrun

    init() {}

    var spec: JobKindSpec { JobKindSpecs.spec(.agentrun) }

    func read(_ pointer: JobPointer, api: APIClient) async throws -> DriverRead {
        // `{"job":null}` after the six-hour retention, or for an id that never existed. Two of these
        // in a row are terminal (`spec.unknownReadsBeforeTerminal`); one is not, because a 503 on
        // the storage layer can look the same from a distance.
        guard let job = try await api.agentJob(id: pointer.id) else { return .unknown }
        return Self.read(from: job, pointer: pointer)
    }

    /// Cancel is cosmetic for a mission: the Manus loop never reads the flag, the task runs to
    /// completion and its answer is still filed. The UI must never offer "Stop" for one, so this
    /// always answers "no, it was not stopped".
    func cancel(_ pointer: JobPointer, api: APIClient) async throws -> Bool {
        false
    }

    func stream(_ pointer: JobPointer, api: APIClient) -> AsyncThrowingStream<DriverRead, Error>? {
        let jobID = pointer.id
        let target = pointer
        return AsyncThrowingStream<DriverRead, Error> { continuation in
            let task = Task {
                do {
                    let frames = await api.agentJobStream(id: jobID)
                    for try await frame in frames {
                        if Task.isCancelled { break }
                        switch frame.event ?? "" {
                        case "snapshot":
                            guard let job = Self.decodeJob(frame.data) else { continue }
                            if case .running(let snapshot) = Self.read(from: job, pointer: target) {
                                continuation.yield(.running(snapshot))
                            } else {
                                // A terminal snapshot is always followed by a `terminal` frame, but
                                // the authoritative read belongs to the watcher either way.
                                continuation.finish()
                                return
                            }
                        case "terminal":
                            // The server closes the socket right after this. One final read settles
                            // the result: the snapshot we hold may predate the saved answer.
                            continuation.finish()
                            return
                        case "agent-error":
                            let failure = Self.decodeStreamError(frame.data)
                            if failure.retryable == true {
                                // Transient: fall back to the poll and rebuild the stream.
                                continuation.finish()
                            } else {
                                let code = (failure.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                continuation.yield(.terminal(.failed(code: code.isEmpty ? "task_failed" : code, partial: nil)))
                                continuation.finish()
                            }
                            return
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Mapping

    static func read(from job: AgentJob, pointer: JobPointer) -> DriverRead {
        let snapshot = Self.snapshot(from: job, pointer: pointer)
        switch job.phase {
        case .done:
            return .terminal(.completed(snapshot))
        case .fail:
            // On a failed snapshot `error` is a bare code (`agent_busy`, `credits_exhausted`,
            // `task_failed`), not a JSON body. The snapshot rides along as the partial so the card
            // can keep the checklist it already drew.
            let code = job.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return .terminal(.failed(code: code.isEmpty ? "task_failed" : code, partial: snapshot))
        default:
            // `queued` and `run`. A mission that outlives its 30-minute upstream deadline flips
            // between the two every minute or so while it reconciles; neither is a failure.
            return .running(snapshot)
        }
    }

    private static func snapshot(from job: AgentJob, pointer: JobPointer) -> JobSnapshot {
        let phase: JobPhase
        switch job.phase {
        case .done: phase = .completed
        case .fail: phase = .failed
        case .queued: phase = .queued
        default: phase = .processing
        }
        return JobSnapshot(
            pointerID: pointer.id,
            phase: phase,
            text: job.final,
            reasoning: "",
            progress: nil,
            surface: nil,
            agent: job,
            mediaKey: nil
        )
    }

    /// `data` is `{"job": <AgentJobView>}`; a bare view is accepted too, because the web client
    /// tolerates both and a frame we cannot read must be skipped, never fatal.
    private static func decodeJob(_ data: String) -> AgentJob? {
        let bytes = Data(data.utf8)
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(AgentJobEnvelope.self, from: bytes), let job = envelope.job {
            return job
        }
        return try? decoder.decode(AgentJob.self, from: bytes)
    }

    private struct AgentStreamError: Decodable, Sendable {
        var error: String?
        var retryable: Bool?
    }

    private static func decodeStreamError(_ data: String) -> AgentStreamError {
        (try? JSONDecoder().decode(AgentStreamError.self, from: Data(data.utf8)))
            ?? AgentStreamError(error: nil, retryable: true)
    }
}
