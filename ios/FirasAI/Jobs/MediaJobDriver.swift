import Foundation

/// Image, video and music renders.
///
/// The one fact that shapes this whole file (`server-media.md §0.6`): **a media job id is the SHA-1
/// cache key of the result.** The status route answers `done` for any id whose bytes exist on disk,
/// even after a restart that forgot the job — and it answers `running` **forever** for an id it has
/// lost. The server will never say `fail` for a forgotten job, so the client's deadline is the only
/// exit, and the pointer is worth one more look on a later launch because the cache may have filled
/// in the meantime.
struct MediaJobDriver: JobKindDriver {

    let kind: JobKind

    init(kind: JobKind) {
        self.kind = kind
    }

    var spec: JobKindSpec { JobKindSpecs.spec(kind) }

    func read(_ pointer: JobPointer, api: APIClient) async throws -> DriverRead {
        let media = kind.mediaKind ?? .image
        let status = try await api.mediaJobStatus(kind: media, id: pointer.id)
        switch status.phase.lowercased() {
        case "done", "completed":
            // `key` is normally the id itself; falling back to the id keeps a terse response usable.
            let key = (status.key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .terminal(.completed(Self.snapshot(pointer, phase: .completed, mediaKey: key.isEmpty ? pointer.id : key)))
        case "fail", "failed", "error":
            // Keep the reason. "It did not work" reads identically whether the renderer is
            // unconfigured, the allowance is spent, or every engine rung came back empty.
            let reported = (status.error ?? status.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .terminal(.failed(code: reported.isEmpty ? "engine_failed" : reported, partial: nil))
        default:
            // `running`, `queued`, and an unknown id — indistinguishable by design.
            return .running(Self.snapshot(pointer, phase: .processing, mediaKey: nil))
        }
    }

    /// There is no cancel endpoint for any media job: the render always completes and is always
    /// charged. Stopping means stopping the *viewer*.
    func cancel(_ pointer: JobPointer, api: APIClient) async throws -> Bool {
        false
    }

    func stream(_ pointer: JobPointer, api: APIClient) -> AsyncThrowingStream<DriverRead, Error>? {
        nil
    }

    private static func snapshot(_ pointer: JobPointer, phase: JobPhase, mediaKey: String?) -> JobSnapshot {
        JobSnapshot(
            pointerID: pointer.id,
            phase: phase,
            text: "",
            reasoning: "",
            progress: nil,
            surface: nil,
            agent: nil,
            mediaKey: mediaKey
        )
    }
}
