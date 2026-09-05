import Foundation

/// One driver per job kind: the only place a job's wire shape is known.
///
/// Drivers are **values** — stateless `Sendable` structs — because a watcher rebuilt from
/// `jobs.json` after a relaunch has to be able to make one out of a `JobKind` and nothing else. A
/// driver never touches UI, never holds a conversation, and never remembers anything between reads;
/// everything it needs arrives in the pointer.
protocol JobKindDriver: Sendable {
    var kind: JobKind { get }
    var spec: JobKindSpec { get }

    /// One status read. Throws `APIError` so the watcher can apply the shared HTTP policy
    /// (401 suspend, 403 forget, transport backoff) in one place instead of nine.
    func read(_ pointer: JobPointer, api: APIClient) async throws -> DriverRead

    /// Asks the **server** to stop. `false` means it will not — either the route refuses (a queued
    /// chat job), or the kind has no real cancel at all (missions, builds, every media render).
    func cancel(_ pointer: JobPointer, api: APIClient) async throws -> Bool

    /// `nil` unless `spec.usesSSE`.
    func stream(_ pointer: JobPointer, api: APIClient) -> AsyncThrowingStream<DriverRead, Error>?
}

/// The per-kind polling contract, exactly as `ARCHITECTURE.md §2.4` tabulates it.
///
/// Every number here is either the server's own ceiling for that kind or the cadence the web client
/// already uses. Nothing else in the app is allowed to invent a poll interval or a deadline: a
/// pointer whose client TTL is longer than the server's retention is precisely what leaves a
/// conversation lit as "still working" forever, and a tighter poll only spends the user's request
/// budget asking "are we there yet".
enum JobKindSpecs {

    /// Server-side retention for a chat-queue record (`JOB_KEEP_MS`, 6 h). Past this the id answers
    /// `{"phase":"unknown"}` and nothing is ever coming again.
    static let chatQueueRetention: TimeInterval = 6 * 60 * 60

    static func spec(_ kind: JobKind) -> JobKindSpec {
        switch kind {
        case .chat:
            // Web cadence (`gap()`): immediate, 350 ms for the first 10 s, 700 ms to 40 s, then 1.2 s.
            return JobKindSpec(
                kind: .chat,
                cadence: [(after: 0, interval: 0.35), (after: 10, interval: 0.7), (after: 40, interval: 1.2)],
                backgroundInterval: 5,
                deadline: 30 * 60,
                cancelable: true,
                unknownReadsBeforeTerminal: 3,
                usesSSE: false
            )
        case .longdoc:
            // Same ladder as an ordinary turn; `LONGDOC_MAX_MS` is 6 h and matches `JOB_KEEP_MS`.
            return JobKindSpec(
                kind: .longdoc,
                cadence: [(after: 0, interval: 0.35), (after: 10, interval: 0.7), (after: 40, interval: 1.2)],
                backgroundInterval: 5,
                deadline: 6 * 60 * 60,
                cancelable: true,
                unknownReadsBeforeTerminal: 3,
                usesSSE: false
            )
        case .longfile:
            // A long file runs in 8-minute slices and re-queues itself between them, so brief
            // `queued` phases mid-run are normal and a 2 s poll is already generous.
            return JobKindSpec(
                kind: .longfile,
                cadence: [(after: 0, interval: 2)],
                backgroundInterval: 10,
                deadline: 6 * 60 * 60,
                cancelable: true,
                unknownReadsBeforeTerminal: 3,
                usesSSE: false
            )
        case .counteddoc:
            return JobKindSpec(kind: .counteddoc, cadence: [(after: 0, interval: 2)],
                backgroundInterval: 10, deadline: 7 * 24 * 60 * 60,
                cancelable: true, unknownReadsBeforeTerminal: 3, usesSSE: false)
        case .agentrun:
            // SSE first (`/api/agent/job-stream`); the poll below is only the fallback the web uses
            // at 700 ms while visible. `AG_JOB_MAX_MS` is 3 h. Two `{"job":null}` reads are terminal.
            return JobKindSpec(
                kind: .agentrun,
                cadence: [(after: 0, interval: 0.7)],
                backgroundInterval: 5,
                deadline: 3 * 60 * 60,
                cancelable: false,
                unknownReadsBeforeTerminal: 2,
                usesSSE: true
            )
        case .codebuild:
            // `CW_JOB_MAX_MS` = 2 h, poll every 4 s. `unknown` is terminal immediately: the build
            // record either exists or the six-hour retention already ate it.
            return JobKindSpec(
                kind: .codebuild,
                cadence: [(after: 0, interval: 4)],
                backgroundInterval: 10,
                deadline: 2 * 60 * 60,
                cancelable: false,
                unknownReadsBeforeTerminal: 1,
                usesSSE: false
            )
        case .brainask:
            // One model call; a few seconds to about a minute.
            return JobKindSpec(
                kind: .brainask,
                cadence: [(after: 0, interval: 3)],
                backgroundInterval: 10,
                deadline: 30 * 60,
                cancelable: false,
                unknownReadsBeforeTerminal: 1,
                usesSSE: false
            )
        case .image:
            // Media ids are cache keys: a forgotten id answers `running` forever, so the deadline
            // is the only exit. `IMG_JOB_MAX_MS` = 20 min.
            return JobKindSpec(
                kind: .image,
                cadence: [(after: 0, interval: 2), (after: 30, interval: 5)],
                backgroundInterval: 10,
                deadline: 20 * 60,
                cancelable: false,
                unknownReadsBeforeTerminal: 3,
                usesSSE: false
            )
        case .video:
            // `VIDEO_JOB_MAX_MS` = 20 min.
            return JobKindSpec(
                kind: .video,
                cadence: [(after: 0, interval: 2.5), (after: 30, interval: 6)],
                backgroundInterval: 15,
                deadline: 20 * 60,
                cancelable: false,
                unknownReadsBeforeTerminal: 3,
                usesSSE: false
            )
        case .music:
            // `MUSIC_JOB_MAX_MS` = 10 min.
            return JobKindSpec(
                kind: .music,
                cadence: [(after: 0, interval: 2), (after: 30, interval: 6)],
                backgroundInterval: 15,
                deadline: 10 * 60,
                cancelable: false,
                unknownReadsBeforeTerminal: 3,
                usesSSE: false
            )
        }
    }

    /// The foreground interval for a job that started `elapsed` seconds ago. The ladder is read
    /// left to right; the last rung whose `after` has been reached wins.
    static func foregroundInterval(_ spec: JobKindSpec, elapsed: TimeInterval) -> TimeInterval {
        var chosen = spec.cadence.first?.interval ?? 2
        for rung in spec.cadence where elapsed >= rung.after {
            chosen = rung.interval
        }
        return Swift.max(0.2, chosen)
    }

    /// While the app is in the background a live watcher holds a `BackgroundHold` and slows down:
    /// never faster than the kind's background interval, and never faster than twice its current
    /// foreground cadence.
    static func backgroundInterval(_ spec: JobKindSpec, elapsed: TimeInterval) -> TimeInterval {
        Swift.max(spec.backgroundInterval, foregroundInterval(spec, elapsed: elapsed) * 2)
    }
}

/// A cancellation-aware delay that never blocks a thread and never spins.
///
/// Deliberately built on a `DispatchWorkItem` rather than the obvious sleep primitive: this target
/// forbids the whole family of blocking waits, and a timer that resolves a continuation is both
/// cheaper and easier to cancel from a task-cancellation handler.
enum JobClock {

    /// Waits `seconds`, throwing `CancellationError` if the surrounding task is cancelled first.
    static func wait(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        guard seconds > 0 else { return }
        let handle = JobDelayHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                handle.begin(after: seconds, continuation: continuation)
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Waits `seconds` and returns early and quietly on cancellation. Used by loops that check
    /// their own stop flags on the next turn.
    static func rest(_ seconds: TimeInterval) async {
        do {
            try await wait(seconds)
        } catch {
            // Cancellation is the only error this can throw, and the caller's loop condition
            // already knows what to do about it.
        }
    }
}

/// One-shot timer whose state is guarded by a lock so the timer callback and the cancellation
/// handler can race safely.
private final class JobDelayHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var item: DispatchWorkItem?

    func begin(after seconds: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if isFinished {
            // Cancelled before the continuation was even installed.
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let work = DispatchWorkItem { [weak self] in
            self?.settle(with: nil)
        }
        item = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func cancel() {
        settle(with: CancellationError())
    }

    private func settle(with error: Error?) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        let waiting = continuation
        continuation = nil
        let work = item
        item = nil
        lock.unlock()

        if let error {
            work?.cancel()
            waiting?.resume(throwing: error)
        } else {
            waiting?.resume()
        }
    }
}
