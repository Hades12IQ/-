import Foundation
import OSLog

/// What a watcher tells the registry. Deliberately not `JobObserver`: a watcher never talks to a
/// feature store, and the terminal callback is synchronous so that landing the result can outlive
/// the watcher's own task.
protocol JobWatcherDelegate: AnyObject {
    @MainActor func watcher(_ watcher: JobWatcher, didProgress snapshot: JobSnapshot, pointer: JobPointer)
    @MainActor func watcher(_ watcher: JobWatcher, didFinish terminal: JobTerminal, pointer: JobPointer)
    @MainActor func watcherNeedsReauthentication(_ watcher: JobWatcher, pointer: JobPointer)
}

/// One loop per pointer, implementing rules (1)–(9) of `ARCHITECTURE.md §2.4`.
///
/// The watcher is given **ids and values only** — a pointer, a driver, the client. It never holds a
/// conversation, a message or a caller's closure, because the whole point of this machinery is that
/// a watcher rebuilt from `jobs.json` after a relaunch behaves identically to the one that started
/// the job. Every path the started-it case takes, the reattached case takes too.
@MainActor
final class JobWatcher {

    /// `singleRead` is the "one later check" a media pointer gets after its deadline: the server
    /// answers `running` forever for an id it has forgotten, but the bytes may have landed in the
    /// cache in the meantime, so one authoritative read is worth a great deal and a second poll
    /// loop is worth nothing.
    enum Mode: Equatable {
        case continuous
        case singleRead
    }

    let pointerID: String
    private(set) var pointer: JobPointer

    private let driver: any JobKindDriver
    private let api: APIClient
    private let network: NetworkMonitor
    private let mode: Mode
    private weak var delegate: (any JobWatcherDelegate)?

    private var loop: Task<Void, Never>?
    private var isStopped = false
    private var isFinished = false
    private var isBackground = false
    private var wakeRequested = false
    private var hold: BackgroundHold?

    private var transportFailures = 0
    private var unknownReads = 0
    private var lastPublished: JobSnapshot?
    private var lastPublishAt = Date.distantPast
    private var pollBackoff = Backoff(initial: 1.2, max: 30)
    private var streamBackoff = Backoff(initial: 1, max: 15, factor: 2)

    init(
        pointer: JobPointer,
        driver: any JobKindDriver,
        api: APIClient,
        network: NetworkMonitor,
        mode: Mode,
        delegate: any JobWatcherDelegate
    ) {
        self.pointerID = pointer.id
        self.pointer = pointer
        self.driver = driver
        self.api = api
        self.network = network
        self.mode = mode
        self.delegate = delegate
    }

    // MARK: - Lifecycle

    func start() {
        guard loop == nil, !isStopped, !isFinished else { return }
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    /// Stops **watching**. The pointer and the server-side job are untouched — this is what leaving
    /// a screen, changing identity or tearing the app down means. Cancelling the *job* is a
    /// separate, explicit action that goes through `JobManager.cancel(jobID:)`.
    func stop() {
        isStopped = true
        loop?.cancel()
        loop = nil
        hold?.end()
        hold = nil
    }

    /// "We're back." Idempotent by design: foreground, connectivity and an explicit refresh may all
    /// call this as often as they like; the loop takes at most one extra read from it.
    func poke() {
        guard !isStopped, !isFinished else { return }
        wakeRequested = true
        if loop == nil { start() }
    }

    func setBackground(_ background: Bool) {
        guard isBackground != background else { return }
        isBackground = background
        if background {
            if hold == nil, !isStopped, !isFinished {
                hold = BackgroundExecutor.hold(name: "firas.job." + pointerID)
            }
        } else {
            hold?.end()
            hold = nil
            wakeRequested = true
        }
    }

    // MARK: - The loop

    /// How long a `.singleRead` watcher waits for connectivity before giving its one look up. It
    /// cannot use the deadline — that is already in the past — and a device that never comes back
    /// online must not leave a loop turning for the life of the process.
    private static let singleReadGrace: TimeInterval = 60

    private func run() async {
        let spec = driver.spec
        // A `.singleRead` watcher exists *because* the deadline has already passed; measuring it
        // against that deadline again would expire it before it ever took the one authoritative
        // read that is its entire purpose (`ARCHITECTURE.md §2.4` rule 4).
        let giveUpAt = mode == .continuous
            ? pointer.deadline
            : Date().addingTimeInterval(Self.singleReadGrace)
        while !isStopped, !isFinished, !Task.isCancelled {
            if Date() >= giveUpAt {
                await finish(.expired)
                return
            }
            // (1) Pause while offline. A stalled request is not evidence of anything; the monitor is.
            guard network.isOnline else {
                await idle(2)
                continue
            }
            if mode == .continuous, spec.usesSSE, let stream = driver.stream(pointer, api: api) {
                let outcome = await consume(stream)
                if isFinished || isStopped || Task.isCancelled { return }
                if outcome == .terminal { return }
                // The stream ended or dropped: take one authoritative read before trusting anything,
                // then rebuild the stream with a doubling delay (1 s → 15 s).
                await pollOnce()
                if isFinished || isStopped || Task.isCancelled { return }
                await idle(streamBackoff.next())
                continue
            }
            await pollOnce()
            if isFinished || isStopped || Task.isCancelled { return }
            if mode == .singleRead {
                await finish(.expired)
                return
            }
            await idle(interval(for: spec))
        }
    }

    private enum StreamOutcome: Equatable {
        case terminal
        case ended
        case failed
    }

    private func consume(_ stream: AsyncThrowingStream<DriverRead, Error>) async -> StreamOutcome {
        do {
            for try await read in stream {
                if isStopped || Task.isCancelled { return .ended }
                switch read {
                case .running(let snapshot):
                    transportFailures = 0
                    unknownReads = 0
                    pollBackoff.reset()
                    streamBackoff.reset()
                    publish(snapshot)
                case .unknown:
                    continue
                case .terminal(let terminal):
                    await finish(terminal)
                    return .terminal
                }
            }
            return .ended
        } catch {
            let ended = await handle(error)
            return ended ? .terminal : .failed
        }
    }

    private func pollOnce() async {
        do {
            let read = try await driver.read(pointer, api: api)
            transportFailures = 0
            pollBackoff.reset()
            switch read {
            case .running(let snapshot):
                unknownReads = 0
                publish(snapshot)
            case .unknown:
                // A record the server has no memory of. Chat jobs need three of these in a row
                // (the web's rule), the agent needs two `{"job":null}` reads, a build needs one.
                unknownReads += 1
                if unknownReads >= Swift.max(1, driver.spec.unknownReadsBeforeTerminal) {
                    await finish(.expired)
                }
            case .terminal(let terminal):
                await finish(terminal)
            }
        } catch {
            _ = await handle(error)
        }
    }

    /// Applies rules (2) and (3). Returns `true` when the watcher has ended and the loop must stop.
    private func handle(_ error: Error) async -> Bool {
        if error is CancellationError { return true }
        if let apiError = error as? APIError {
            switch apiError {
            case .cancelled:
                return true
            case .http(let status, let server, let raw):
                if status == 401 {
                    // The pointer is kept: the job is still the server's, and it resumes when this
                    // identity signs back in.
                    delegate?.watcherNeedsReauthentication(self, pointer: pointer)
                    stop()
                    return true
                }
                if status == 403 {
                    // Someone else's job on a shared device. Forget it, say nothing.
                    await finish(.forbidden)
                    return true
                }
                if status == 404, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await finish(.failed(code: server.code ?? "unknown_job", partial: nil))
                    return true
                }
                if status == 400 {
                    await finish(.failed(code: server.code ?? "bad_request", partial: nil))
                    return true
                }
                // 408 / 409 / 429 / every 5xx is transient. `storage_unavailable` in particular is
                // the server telling us to come back, not that the job died.
            default:
                break
            }
        }
        // (2) A miss is not a death. Wi-Fi blips; a stale claim is re-queued after two silent
        // minutes and resumes. Count misses, back off, and never spin.
        transportFailures += 1
        if transportFailures >= 20 {
            markReconnecting()
            await idle(30)
        } else {
            await idle(pollBackoff.next())
        }
        return false
    }

    private func finish(_ terminal: JobTerminal) async {
        guard !isFinished else { return }
        isFinished = true
        isStopped = true
        hold?.end()
        hold = nil
        let ended = pointer
        // Deliberately not `stop()`: cancelling our own task here would cut the delivery short.
        delegate?.watcher(self, didFinish: terminal, pointer: ended)
    }

    // MARK: - Publishing

    /// (9) Growing text is published at no more than 10 Hz, and only when something actually moved.
    private func publish(_ snapshot: JobSnapshot) {
        // Never let a poll shorten what the user already watched arrive.
        if snapshot.phase == pointer.lastPhase, snapshot.text.count < pointer.lastTextCount { return }
        if let last = lastPublished, last == snapshot { return }
        let phaseChanged = snapshot.phase != pointer.lastPhase
        if !phaseChanged, Date().timeIntervalSince(lastPublishAt) < 0.1 { return }

        lastPublished = snapshot
        lastPublishAt = Date()
        pointer.lastPhase = snapshot.phase
        pointer.lastTextCount = snapshot.text.count
        delegate?.watcher(self, didProgress: snapshot, pointer: pointer)
    }

    /// Twenty consecutive transport errors is no longer a blip. Say so honestly instead of leaving
    /// a spinner that means nothing, keep the pointer, and retry every 30 s until the deadline.
    private func markReconnecting() {
        guard pointer.lastPhase != .reconnecting else { return }
        Log.jobs.info("job watcher reconnecting")
        let carried = lastPublished
        publish(
            JobSnapshot(
                pointerID: pointerID,
                phase: .reconnecting,
                text: carried?.text ?? "",
                reasoning: carried?.reasoning ?? "",
                progress: carried?.progress,
                surface: carried?.surface,
                agent: carried?.agent,
                mediaKey: carried?.mediaKey
            )
        )
    }

    // MARK: - Timing

    private func interval(for spec: JobKindSpec) -> TimeInterval {
        let elapsed = Date().timeIntervalSince(pointer.startedAt)
        return isBackground
            ? JobKindSpecs.backgroundInterval(spec, elapsed: elapsed)
            : JobKindSpecs.foregroundInterval(spec, elapsed: elapsed)
    }

    /// A poke-interruptible wait. The step is small enough that returning to the app feels
    /// immediate and large enough that a dozen watchers cost nothing.
    private func idle(_ seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while !isStopped, !isFinished, !Task.isCancelled {
            if wakeRequested {
                wakeRequested = false
                return
            }
            let remaining = end.timeIntervalSinceNow
            if remaining <= 0 { return }
            await JobClock.rest(Swift.min(0.25, remaining))
        }
    }
}
