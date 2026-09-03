import Foundation
import Observation

/// One unsent message per conversation, kept across screens and across launches.
///
/// The web keeps `firas_ai_drafts` (`web-chat-ux.md §7.2`): a map keyed by conversation id or by
/// the sentinel `new:<product>` for a conversation that does not exist yet, at most 30 entries,
/// 20 000 characters each, written 400 ms after typing stops. This is the same table, on disk
/// instead of in `localStorage`, and written off the main actor.
///
/// The debounce is the point: a draft is saved on a timer, on `flush()` (chat switch, background),
/// and never on every keystroke — a multi-kilobyte write per character is exactly the hitch
/// `audit-ios-chat.md §Major M14` measured.
@MainActor
@Observable
final class DraftStore {

    private static let path = "drafts.json"
    private static let maximumEntries = 30
    private static let maximumCharacters = 20_000
    private static let debounce: TimeInterval = 0.4

    private var entries: [String: DraftEntry] = [:]

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var didRestore = false

    init() {
        Task { [weak self] in
            await self?.restore()
        }
    }

    // MARK: - Keys

    /// The key for a conversation that exists.
    static func key(conversationID: String) -> String { conversationID }

    /// The key for the composer of a conversation that has not been created yet.
    static func key(newIn product: ProductKind) -> String { "new:" + product.rawValue }

    // MARK: - Reading and writing

    func draft(for key: String) -> String {
        entries[key]?.text ?? ""
    }

    func set(_ text: String, for key: String) {
        guard !key.isEmpty else { return }
        let trimmed = String(text.prefix(Self.maximumCharacters))
        if trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard entries[key] != nil else { return }
            entries.removeValue(forKey: key)
        } else {
            entries[key] = DraftEntry(text: trimmed, at: Date().timeIntervalSince1970)
            trimToCapacity()
        }
        scheduleSave()
    }

    func clear(_ key: String) {
        guard entries.removeValue(forKey: key) != nil else { return }
        scheduleSave()
    }

    /// Writes now instead of on the timer: chat switch, `pagehide`, entering the background.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = entries
        Task {
            try? await DiskStore.shared.write(snapshot, at: DraftStore.path)
        }
    }

    /// Reads the table back. Drafts typed before the file arrived win — a restore must never
    /// overwrite something the user is in the middle of writing.
    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        guard let stored = await DiskStore.shared.read([String: DraftEntry].self, at: Self.path) else { return }
        for (key, value) in stored where entries[key] == nil {
            entries[key] = value
        }
        trimToCapacity()
    }

    // MARK: - Private

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            await JobClock.rest(DraftStore.debounce)
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            let snapshot = self.entries
            try? await DiskStore.shared.write(snapshot, at: DraftStore.path)
        }
    }

    /// LRU by last write, exactly like the web's `DRAFT_MAX`.
    private func trimToCapacity() {
        guard entries.count > Self.maximumEntries else { return }
        let ordered = entries.sorted { $0.value.at > $1.value.at }
        var kept: [String: DraftEntry] = [:]
        for pair in ordered.prefix(Self.maximumEntries) {
            kept[pair.key] = pair.value
        }
        entries = kept
    }
}

/// One stored draft. `at` is seconds since 1970 so the file needs no date decoding strategy.
struct DraftEntry: Codable, Sendable, Equatable {
    var text: String
    var at: Double

    init(text: String, at: Double) {
        self.text = text
        self.at = at
    }
}
