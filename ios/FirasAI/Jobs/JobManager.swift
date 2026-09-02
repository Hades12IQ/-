import Foundation
import Observation
import OSLog
import UIKit

/// How a feature store hears about a job it did not poll for.
///
/// The registry calls these on the main actor, and `didFinish` answers whether the result is
/// **safely in the store's model**. That boolean is the whole reason the pointer survives long
/// enough to be re-delivered: a job being finished and its output being written into the client are
/// two different moments, and forgetting the pointer at the first one throws finished work away.
protocol JobObserver: AnyObject {
    @MainActor func job(_ pointer: JobPointer, didProgress snapshot: JobSnapshot)
    @MainActor func job(_ pointer: JobPointer, didFinish terminal: JobTerminal) async -> Bool
}

/// The cloud-first spine. One registry, one on-disk pointer table, one watcher per pointer, one
/// driver per kind. **No feature store polls on its own.**
///
/// The contract every screen depends on: leaving the app does not cancel server work, coming back
/// reattaches to it, and a job that finishes while the app is closed announces itself. That is only
/// true if three things hold — the pointer reaches disk *before* the start call returns, the result
/// is landed by a store *before* the pointer is forgotten, and every terminal shape is enumerated
/// (including the ones nobody meets in development: `unknown`, a malformed record, a 403 from
/// another account's job on a shared device).
@MainActor
@Observable
final class JobManager: JobWatcherDelegate {

    private(set) var pointers: [JobPointer] = []

    /// Set by the call engine. A completion cue never fires over a live call.
    var callActive: Bool = false

    private let api: APIClient
    private let session: SessionStore
    private let prefs: PreferencesStore
    private let notifications: NotificationManager
    private let network: NetworkMonitor
    private let store: JobPointerStore

    @ObservationIgnored private var watchers: [String: JobWatcher] = [:]
    @ObservationIgnored private var observers: [JobKind: [ObserverBox]] = [:]
    @ObservationIgnored private var delivering: Set<String> = []
    @ObservationIgnored private var activeOwner: String?
    @ObservationIgnored private var isBackground = false
    @ObservationIgnored private var networkTask: Task<Void, Never>?

    init(
        api: APIClient,
        session: SessionStore,
        prefs: PreferencesStore,
        notifications: NotificationManager,
        network: NetworkMonitor
    ) {
        self.api = api
        self.session = session
        self.prefs = prefs
        self.notifications = notifications
        self.network = network
        self.store = JobPointerStore(disk: DiskStore.shared)
        session.onUnauthorized = { [weak self] in
            self?.suspendActiveOwnerSoon()
        }
        observeNetwork()
    }

    // MARK: - Reading the table

    func isLive(conversationID: String) -> Bool {
        pointer(forConversation: conversationID) != nil
    }

    func liveCount(product: ProductKind) -> Int {
        pointers.filter { $0.kind.product == product && belongsToActiveOwner($0) && Self.isLive($0.lastPhase) }.count
    }

    func pointer(id: String) -> JobPointer? {
        pointers.first { $0.id == id }
    }

    /// Under **either** name. A conversation is minted with a local id and gains a server id later;
    /// a pointer filed under one of them addresses nothing if only the other is looked up.
    func pointer(forConversation id: String) -> JobPointer? {
        guard !id.isEmpty else { return nil }
        return pointers.first { pointer in
            guard belongsToActiveOwner(pointer), Self.isLive(pointer.lastPhase) else { return false }
            return pointer.conversationID == id || pointer.serverChatID == id
        }
    }

    func register(_ observer: any JobObserver, for kind: JobKind) {
        var list = observers[kind] ?? []
        list.removeAll { $0.value == nil || $0.value === observer }
        list.append(ObserverBox(value: observer))
        observers[kind] = list
    }

    // MARK: - Starting

    /// Hands a turn to the durable chat queue. Throws `APIError` for every refusal the caller must
    /// present itself (409 `agent_busy`, 429 quota, 403 `account_required`, 413 payload) and for the
    /// 404/501 that mean "this backend has no queue", which is the caller's cue to fall back to the
    /// live stream rather than lose the turn.
    func startChatQueueJob(_ request: ChatJobRequest, pointer draft: JobPointer) async throws -> JobPointer {
        let response = try await api.startChatJob(request)
        let jobID = (response.jobId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jobID.isEmpty else { throw APIError.decoding("chat job start returned no id") }

        var pointer = Self.rekey(draft, id: jobID)
        let phase = Self.phase(fromRaw: response.phase ?? "queued")
        pointer.lastPhase = phase
        upsert(pointer)
        // Before returning, not after: a job whose pointer never reached disk is a job a crash makes
        // unreachable — still billed, never shown, never cleaned up.
        await store.save(pointers, immediate: true)
        prepareCompletionChannels()

        // The queue is idempotent per owner+cid, so a replayed start can answer with the finished
        // answer. Land it directly; there is nothing left to watch.
        if phase == .completed {
            deliverSoon(
                pointer,
                .completed(
                    JobSnapshot(
                        pointerID: jobID,
                        phase: .completed,
                        text: response.text ?? "",
                        reasoning: response.reasoning ?? "",
                        progress: response.progress,
                        surface: response.surface,
                        agent: nil,
                        mediaKey: nil
                    )
                )
            )
            return pointer
        }
        if phase == .failed {
            // `retryRequiresNewCid`: this cid is spent, and a retry must mint a fresh one — which is
            // the user's decision, not ours.
            let raw = (response.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            deliverSoon(pointer, .failed(code: raw.isEmpty ? "previous_attempt_failed" : raw, partial: nil))
            return pointer
        }

        attachWatcher(for: pointer, mode: .continuous)
        return pointer
    }

    func startMediaJob(kind: MediaKind, request: any Encodable & Sendable, pointer draft: JobPointer) async throws -> JobPointer {
        let response: MediaJobStartResponse
        switch kind {
        case .image:
            guard let body = request as? ImageJobRequest else { throw APIError.decoding("image job request") }
            response = try await api.startImageJob(body)
        case .video:
            guard let body = request as? VideoJobRequest else { throw APIError.decoding("video job request") }
            response = try await api.startVideoJob(body)
        case .music:
            guard let body = request as? MusicJobRequest else { throw APIError.decoding("music job request") }
            response = try await api.startMusicJob(body)
        }

        let jobID = response.jobId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jobID.isEmpty else { throw APIError.decoding("media job start returned no id") }
        var pointer = Self.rekey(draft, id: jobID)
        pointer.lastPhase = Self.phase(fromRaw: response.phase ?? "queued")
        upsert(pointer)
        await store.save(pointers, immediate: true)
        prepareCompletionChannels()

        // Same inputs mean the same cache key, and a cache hit is answered without rendering.
        if pointer.lastPhase == .completed {
            let key = (response.key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            deliverSoon(
                pointer,
                .completed(
                    JobSnapshot(
                        pointerID: jobID,
                        phase: .completed,
                        text: "",
                        reasoning: "",
                        progress: nil,
                        surface: nil,
                        agent: nil,
                        mediaKey: key.isEmpty ? jobID : key
                    )
                )
            )
            return pointer
        }
        attachWatcher(for: pointer, mode: .continuous)
        return pointer
    }

    /// Adopts a pointer minted elsewhere (a restore, or a store that already knows the job id).
    func attach(_ pointer: JobPointer) {
        var normalized = pointer
        // The ceiling measures the age of the JOB, so it is always recomputed from `startedAt` and
        // never extended by the fact that we just looked at it.
        normalized.deadline = pointer.startedAt.addingTimeInterval(JobKindSpecs.spec(pointer.kind).deadline)
        upsert(normalized)
        persistSoon()
        attachWatcher(for: normalized, mode: normalized.lastPhase == .expired ? .singleRead : .continuous)
    }

    // MARK: - Stopping

    /// Two verbs live here and only one of them is this method. `cancel` asks the **server** to
    /// stop; it answers `false` for every kind that cannot be stopped and for a queued chat job the
    /// server refuses to touch. Either way the conversation settles locally, because from the user's
    /// side pressing Stop must end the wait.
    func cancel(jobID: String) async -> Bool {
        guard var target = pointer(id: jobID) else { return false }
        target.cancelRequested = true
        upsert(target)
        persistSoon()

        let driver = Self.driver(for: target.kind)
        var stopped = false
        do {
            stopped = try await driver.cancel(target, api: api)
        } catch {
            stopped = false
        }
        if driver.spec.cancelable {
            await deliver(target, .cancelled)
        }
        return stopped
    }

    /// Forgets a pointer. Only ever called once the result has landed, or once the job is provably
    /// unreachable — the irreversible half of the pair.
    func forget(jobID: String) {
        remove(jobID: jobID, clearingNotification: true)
    }

    /// `clearingNotification` is false on exactly one path: the terminal delivery that has just
    /// posted the "it's ready" notification. Clearing there would pull the notification out from
    /// under the user in the same breath as posting it.
    private func remove(jobID: String, clearingNotification: Bool) {
        watchers[jobID]?.stop()
        watchers[jobID] = nil
        pointers.removeAll { $0.id == jobID }
        if clearingNotification { notifications.clearDelivered(jobID: jobID) }
        persistSoon()
    }

    /// Stops watching every job of one identity without touching the pointers: the work is still the
    /// server's, and it resumes when that identity comes back.
    func suspend(owner: String) {
        for (id, watcher) in watchers {
            guard let target = pointer(id: id), target.ownerID == owner else { continue }
            watcher.stop()
            watchers[id] = nil
        }
    }

    // MARK: - Resuming

    /// Boot, foreground and identity change all land here. Idempotent: `attachWatcher` makes every
    /// call after the first one free.
    func resumeAll(owner: String) async {
        let identity = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty else { return }
        if activeOwner != identity {
            // Other identities' rows stay on disk and simply stop being watched.
            for (id, watcher) in watchers {
                watcher.stop()
                watchers[id] = nil
            }
            pointers = await store.loadAll()
            activeOwner = identity
        }

        let now = Date()
        for target in pointers where target.ownerID == identity {
            let expired = target.lastPhase == .expired || now >= target.deadline
            // Durable first: even a pointer past its deadline earns one authoritative read, because
            // the server may have finished it — or, for media, the bytes may now be in the cache.
            attachWatcher(for: target, mode: expired ? .singleRead : .continuous)
        }
        for (id, watcher) in watchers where pointer(id: id) == nil {
            watcher.stop()
            watchers[id] = nil
        }
    }

    /// The background-task entry point: one read per pointer inside a hard budget, a notification
    /// for anything terminal, and an answer saying whether another slot is worth asking for.
    func refreshOnce(budgetSeconds: Double) async -> Bool {
        let snapshot = pointers.filter { belongsToActiveOwner($0) }
        guard !snapshot.isEmpty else { return false }

        let client = api
        let budget = Swift.max(1, budgetSeconds)
        let results: [JobReadResult] = await withTaskGroup(of: JobReadResult.self) { group in
            for target in snapshot {
                let driver = Self.driver(for: target.kind)
                group.addTask {
                    let read = try? await driver.read(target, api: client)
                    return JobReadResult(pointerID: target.id, read: read)
                }
            }
            // The budget is a member of the group so that overrunning children are cancelled rather
            // than left to finish after the system has taken the process back.
            group.addTask {
                await JobClock.rest(budget)
                return JobReadResult(pointerID: "", read: nil)
            }
            var collected: [JobReadResult] = []
            for await item in group {
                if item.pointerID.isEmpty {
                    group.cancelAll()
                    break
                }
                collected.append(item)
                if collected.count >= snapshot.count {
                    group.cancelAll()
                    break
                }
            }
            return collected
        }

        for result in results {
            guard let target = pointer(id: result.pointerID), let read = result.read else { continue }
            switch read {
            case .running(let snap):
                var updated = target
                updated.lastPhase = snap.phase
                updated.lastTextCount = snap.text.count
                upsert(updated)
            case .unknown:
                break
            case .terminal(let terminal):
                await deliver(target, terminal)
            }
        }
        await store.save(pointers, immediate: true)
        return pointers.contains { belongsToActiveOwner($0) && Self.isLive($0.lastPhase) }
    }

    /// A `@Sendable` adapter for `BackgroundRefresh.register(handler:)`.
    nonisolated func backgroundRefreshHandler(budgetSeconds: Double = 20) -> @Sendable () async -> Bool {
        { [weak self] in
            guard let self else { return false }
            return await self.refreshOnce(budgetSeconds: budgetSeconds)
        }
    }

    // MARK: - App lifecycle

    func applicationDidBecomeActive() {
        isBackground = false
        for watcher in watchers.values {
            watcher.setBackground(false)
            watcher.poke()
        }
    }

    func applicationDidEnterBackground() {
        isBackground = true
        for watcher in watchers.values {
            watcher.setBackground(true)
        }
        if !pointers.isEmpty {
            BackgroundRefresh.schedule(after: 60)
        }
        let store = self.store
        let snapshot = pointers
        Task {
            await store.save(snapshot, immediate: true)
        }
    }

    // MARK: - JobWatcherDelegate

    func watcher(_ watcher: JobWatcher, didProgress snapshot: JobSnapshot, pointer: JobPointer) {
        let phaseChanged = self.pointer(id: pointer.id)?.lastPhase != pointer.lastPhase
        upsert(pointer)
        // Text growth is memory-only; a phase change is worth a (debounced) write.
        if phaseChanged { persistSoon() }
        for box in observers[pointer.kind] ?? [] {
            box.value?.job(pointer, didProgress: snapshot)
        }
    }

    func watcher(_ watcher: JobWatcher, didFinish terminal: JobTerminal, pointer: JobPointer) {
        deliverSoon(pointer, terminal)
    }

    func watcherNeedsReauthentication(_ watcher: JobWatcher, pointer: JobPointer) {
        suspend(owner: pointer.ownerID)
        Task { @MainActor [weak self] in
            await self?.session.handleUnauthorized()
        }
    }

    // MARK: - Terminal delivery

    private func deliverSoon(_ pointer: JobPointer, _ terminal: JobTerminal) {
        Task { @MainActor [weak self] in
            await self?.deliver(pointer, terminal)
        }
    }

    /// Order is the whole point: **land before forget.** The store gets the result first and says
    /// whether it took it; only then does the app celebrate, and only then is the pointer dropped.
    /// The server keeps the output fetchable for six hours, so waiting costs nothing — dropping the
    /// pointer is irreversible.
    private func deliver(_ pointer: JobPointer, _ terminal: JobTerminal) async {
        guard !delivering.contains(pointer.id) else { return }
        delivering.insert(pointer.id)
        watchers[pointer.id]?.stop()
        watchers[pointer.id] = nil

        let stored = self.pointer(id: pointer.id)
        let alreadyExpiredOnce = stored?.lastPhase == .expired
        var current = stored ?? pointer

        if case .unauthorized = terminal {
            delivering.remove(pointer.id)
            return                                  // pointer kept; it resumes after re-auth
        }
        if case .forbidden = terminal {
            // Another account's job on a shared device. Nothing to say to anyone.
            delivering.remove(pointer.id)
            forget(jobID: pointer.id)
            return
        }

        current.lastPhase = Self.phase(for: terminal)
        upsert(current)

        var landed = await notifyObservers(current, terminal)
        if !landed, current.kind == .codebuild {
            // A finished build whose files have not been written into the project yet is the one
            // case worth waiting on: 15 × 4 s, then give up rather than hold the pointer forever.
            for _ in 0..<15 {
                await JobClock.rest(4)
                landed = await notifyObservers(current, terminal)
                if landed { break }
            }
            if !landed { Log.jobs.error("code build result was never landed") }
        }

        // Media only: a deadline is not proof of failure, because the server answers `running`
        // forever for an id it has forgotten while the bytes may still arrive in the cache. Keep the
        // pointer for exactly one later check and say nothing yet.
        let keepForLaterCheck = current.kind.mediaKind != nil
            && terminal == .expired
            && !alreadyExpiredOnce

        var didNotify = false
        if !keepForLaterCheck {
            if UIApplication.shared.applicationState == .active {
                await CompletionCue.fire(
                    key: current.id,
                    success: terminal.isSuccess,
                    prefs: prefs,
                    callActive: callActive
                )
            } else if !current.notified {
                current.notified = true
                upsert(current)
                didNotify = true
                await notifications.postJobTerminal(current, terminal: terminal, lang: prefs.lang)
            }
        }

        delivering.remove(pointer.id)
        if keepForLaterCheck {
            current.lastPhase = .expired
            upsert(current)
            await store.save(pointers, immediate: true)
        } else {
            remove(jobID: current.id, clearingNotification: !didNotify)
        }
    }

    private func notifyObservers(_ pointer: JobPointer, _ terminal: JobTerminal) async -> Bool {
        var landed = false
        for box in observers[pointer.kind] ?? [] {
            guard let observer = box.value else { continue }
            let ok = await observer.job(pointer, didFinish: terminal)
            landed = landed || ok
        }
        return landed
    }

    // MARK: - Plumbing

    private func attachWatcher(for pointer: JobPointer, mode: JobWatcher.Mode) {
        if let existing = watchers[pointer.id] {
            existing.poke()
            return
        }
        guard !delivering.contains(pointer.id) else { return }
        let watcher = JobWatcher(
            pointer: pointer,
            driver: Self.driver(for: pointer.kind),
            api: api,
            network: network,
            mode: mode,
            delegate: self
        )
        watchers[pointer.id] = watcher
        watcher.setBackground(isBackground)
        watcher.start()
    }

    private func upsert(_ pointer: JobPointer) {
        if let index = pointers.firstIndex(where: { $0.id == pointer.id }) {
            pointers[index] = pointer
        } else {
            pointers.append(pointer)
        }
    }

    /// Run once per accepted job, before the first read comes back.
    ///
    /// `NotificationManager.requestIfNeeded` is the only place the system prompt is ever asked for,
    /// and it stays silent until the explainer sheet has set `prefs.notificationsExplained` —
    /// without this call nothing in the app ever asks, so a job that finishes in the background
    /// would never be announced. `CompletionCue.prepare` warms the Taptic engine so the two-pulse
    /// cue lands without the cold-start delay; there is nothing to warm while the app is away.
    private func prepareCompletionChannels() {
        if !isBackground { CompletionCue.prepare() }
        Task { [weak self] in
            guard let self else { return }
            await self.notifications.requestIfNeeded()
        }
    }

    private func persistSoon() {
        let store = self.store
        let snapshot = pointers
        Task {
            await store.save(snapshot, immediate: false)
        }
    }

    private func belongsToActiveOwner(_ pointer: JobPointer) -> Bool {
        guard let owner = activeOwner else { return true }
        return pointer.ownerID == owner
    }

    private func observeNetwork() {
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            guard let updates = self?.network.updates else { return }
            for await online in updates {
                guard let self else { return }
                guard online else { continue }
                // (1) Back online: every paused watcher takes one immediate read.
                for watcher in self.watchers.values { watcher.poke() }
            }
        }
    }

    nonisolated private func suspendActiveOwnerSoon() {
        Task { @MainActor [weak self] in
            guard let self, let owner = self.activeOwner else { return }
            self.suspend(owner: owner)
        }
    }

    nonisolated static func driver(for kind: JobKind) -> any JobKindDriver {
        switch kind {
        case .chat, .longdoc, .longfile, .codebuild, .brainask:
            return ChatJobDriver(kind: kind)
        case .agentrun:
            return AgentJobDriver()
        case .image, .video, .music:
            return MediaJobDriver(kind: kind)
        }
    }

    private static func isLive(_ phase: JobPhase) -> Bool {
        switch phase {
        case .queued, .processing, .reconnecting: return true
        default: return false
        }
    }

    private static func phase(for terminal: JobTerminal) -> JobPhase {
        switch terminal {
        case .completed: return .completed
        case .expired: return .expired
        default: return .failed
        }
    }

    private static func phase(fromRaw raw: String) -> JobPhase {
        switch raw.lowercased() {
        case "completed", "done": return .completed
        case "failed", "fail": return .failed
        case "queued": return .queued
        case "unknown": return .unknown
        default: return .processing
        }
    }

    /// Rebuilds a pointer under the id the server just gave it and pins the deadline to the kind's
    /// ceiling measured from the job's **start** — never refreshed, or the ceiling is unreachable
    /// and the row stays lit forever.
    private static func rekey(_ draft: JobPointer, id: String) -> JobPointer {
        JobPointer(
            id: id,
            kind: draft.kind,
            ownerID: draft.ownerID,
            cid: draft.cid,
            conversationID: draft.conversationID,
            serverChatID: draft.serverChatID,
            assistantMessageID: draft.assistantMessageID,
            projectID: draft.projectID,
            creationID: draft.creationID,
            title: draft.title,
            lang: draft.lang,
            startedAt: draft.startedAt,
            deadline: draft.startedAt.addingTimeInterval(JobKindSpecs.spec(draft.kind).deadline),
            lastPhase: draft.lastPhase,
            cancelRequested: draft.cancelRequested,
            notified: draft.notified,
            lastTextCount: draft.lastTextCount
        )
    }

}

/// Weak so a torn-down store never keeps the registry alive, and so a stale registration is simply
/// skipped instead of resurrecting a screen the user has left.
private struct ObserverBox {
    weak var value: (any JobObserver)?
}

/// Declared at file scope on purpose: it is produced inside a task group, off the main actor.
private struct JobReadResult: Sendable {
    let pointerID: String
    let read: DriverRead?
}
