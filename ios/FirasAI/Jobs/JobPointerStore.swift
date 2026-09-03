import Foundation
import OSLog

/// The on-disk pointer table: `Application Support/FirasAI/jobs.json`.
///
/// The server owns the work, this file owns a *pointer* to the work, and the UI is a disposable
/// viewer. Nothing here is ever a transcript — a pointer carries only what a poll cannot look up
/// (which job belongs to which conversation, under which identity, and when it started), because a
/// pointer table that starts accumulating content becomes a storage problem long before it becomes
/// useful. See `audit-ios-chat.md §Major M14`: the previous build persisted whole transcripts, with
/// base64 images, into `UserDefaults` on the main thread.
actor JobPointerStore {

    /// Relative to the `DiskStore` root.
    static let relativePath = "jobs.json"

    /// A pointer table, not a history. Oldest `startedAt` is evicted first.
    static let maxPointers = 40

    /// How long a pointer may outlive its own deadline before it is dropped unread. Matched to the
    /// server's `JOB_KEEP_MS`: past that the record is deleted and the id answers `unknown`, so a
    /// pointer that survives it can only ever light a row that will never go dark again.
    static let graceAfterDeadline: TimeInterval = 6 * 60 * 60

    /// Writes are coalesced: a growing answer bumps the pointer's phase and text count often, and a
    /// file write per tick would be pure waste.
    static let writeDebounce: TimeInterval = 0.2

    private let disk: DiskStore
    private var cache: [JobPointer] = []
    private var didLoad = false
    private var pendingWrite: Task<Void, Never>?

    init(disk: DiskStore) {
        self.disk = disk
    }

    /// Every pointer this device holds, for every identity. Reading is idempotent: the file is
    /// touched once per launch and the pruned result is kept in memory afterwards.
    func loadAll() async -> [JobPointer] {
        if didLoad { return cache }
        let stored = await disk.read([JobPointer].self, at: Self.relativePath) ?? []
        cache = Self.prune(stored, now: Date())
        didLoad = true
        if cache.count != stored.count {
            Log.jobs.info("job pointers pruned at load")
        }
        return cache
    }

    /// The pointers belonging to one identity. Other identities' rows stay on disk untouched: their
    /// jobs are still running server-side and must resume if that user signs back in.
    func load(owner: String) async -> [JobPointer] {
        let all = await loadAll()
        return all.filter { $0.ownerID == owner }
    }

    /// Replaces the table. `immediate` forces the write to complete before returning — used when a
    /// job has just been accepted by the server, because a pointer that is not on disk yet is a job
    /// that a crash makes unreachable.
    func save(_ pointers: [JobPointer], immediate: Bool) async {
        cache = Self.prune(pointers, now: Date())
        didLoad = true
        pendingWrite?.cancel()
        pendingWrite = nil
        if immediate {
            await writeNow()
            return
        }
        pendingWrite = Task { [weak self] in
            await JobClock.rest(Self.writeDebounce)
            guard !Task.isCancelled else { return }
            await self?.writeNow()
        }
    }

    /// Flushes any debounced write. Called when the app leaves the foreground.
    func flush() async {
        pendingWrite?.cancel()
        pendingWrite = nil
        await writeNow()
    }

    /// Drops every pointer, for every identity. Only used when the user erases local data.
    func removeAll() async {
        pendingWrite?.cancel()
        pendingWrite = nil
        cache = []
        didLoad = true
        await disk.delete(at: Self.relativePath)
    }

    private func writeNow() async {
        let snapshot = cache
        do {
            try await disk.write(snapshot, at: Self.relativePath)
        } catch {
            // A failed pointer write costs a reattach after a relaunch, never the job itself.
            Log.jobs.error("job pointer write failed")
        }
    }

    /// Drops dead rows and caps the table.
    ///
    /// Order matters: garbage (a row with no id) and rows past the server's retention go first, so
    /// the cap never evicts a live job in favour of a corpse.
    private static func prune(_ pointers: [JobPointer], now: Date) -> [JobPointer] {
        var kept = pointers.filter { pointer in
            guard !pointer.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard !pointer.ownerID.isEmpty else { return false }
            return now.timeIntervalSince(pointer.deadline) < graceAfterDeadline
        }
        // Duplicate ids can only come from a corrupted file; keep the newest of each.
        var seen: Set<String> = []
        kept = kept.sorted { $0.startedAt > $1.startedAt }.filter { seen.insert($0.id).inserted }
        if kept.count > maxPointers {
            kept.removeLast(kept.count - maxPointers)
        }
        return kept.sorted { $0.startedAt < $1.startedAt }
    }
}
