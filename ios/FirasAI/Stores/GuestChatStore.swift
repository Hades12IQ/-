import Foundation

/// A guest's conversations, on this device only.
///
/// The server stores nothing for a guest (`web-auth-account-settings.md §5.2`), so the whole
/// history is here: one JSON file per conversation under `guests/<guestID>/`, protected with
/// `.completeFileProtection` by `DiskStore` and excluded from backup.
///
/// Two rules come straight from the cookie: the guest identity lives seven days, so anything older
/// is deleted rather than shown to whoever holds the phone next; and the guest id is part of the
/// path, so a second guest session on the same device never reads the first one's chats.
actor GuestChatStore {

    /// Matches the `firas_guest` cookie's life.
    private static let timeToLive: TimeInterval = 7 * 24 * 60 * 60
    /// The web keeps 60 (`guestSaveChats`).
    private static let maximumChats = 60
    private static let root = "guests"

    private let disk: DiskStore

    init(disk: DiskStore) {
        self.disk = disk
    }

    // MARK: - API

    /// Every conversation this guest still has, newest first. Expired files are deleted on the way.
    func load(owner: String) async -> [ChatConversation] {
        let directory = Self.directory(owner: owner)
        guard !directory.isEmpty else { return [] }
        let names = await disk.list(directory: directory)
        var out: [ChatConversation] = []
        let cutoff = Date().addingTimeInterval(-Self.timeToLive)

        for name in names where name.hasSuffix(".json") {
            let path = directory + "/" + name
            if let modified = await modificationDate(of: path), modified < cutoff {
                await disk.delete(at: path)
                continue
            }
            if let record = await disk.read(ChatConversation.self, at: path) {
                out.append(record)
            } else {
                // Unreadable (a truncated write, or a shape from a much older build): dropping it
                // is better than showing an empty conversation that can never be repaired.
                await disk.delete(at: path)
            }
        }

        out.sort { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return (lhs.updatedAt ?? "") > (rhs.updatedAt ?? "")
        }
        return out
    }

    func save(_ c: ChatConversation, owner: String) async {
        let directory = Self.directory(owner: owner)
        guard !directory.isEmpty else { return }
        let file = Self.filename(c.id)
        guard !file.isEmpty else { return }
        var record = c
        record.updatedAt = Self.timestamp()
        if record.createdAt == nil { record.createdAt = record.updatedAt }
        try? await disk.write(record, at: directory + "/" + file)
        await enforceCap(directory: directory)
    }

    func delete(_ id: String, owner: String) async {
        let directory = Self.directory(owner: owner)
        let file = Self.filename(id)
        guard !directory.isEmpty, !file.isEmpty else { return }
        await disk.delete(at: directory + "/" + file)
    }

    /// Sweeps every guest folder. Called on boot and after a guest becomes a member.
    func purgeExpired() async {
        let owners = await disk.list(directory: Self.root)
        let cutoff = Date().addingTimeInterval(-Self.timeToLive)
        for owner in owners {
            let directory = Self.root + "/" + owner
            let names = await disk.list(directory: directory)
            for name in names where name.hasSuffix(".json") {
                let path = directory + "/" + name
                guard let modified = await modificationDate(of: path) else { continue }
                if modified < cutoff {
                    await disk.delete(at: path)
                }
            }
        }
    }

    // MARK: - Private

    /// Drops the oldest files once the folder is over the cap.
    private func enforceCap(directory: String) async {
        let names = await disk.list(directory: directory).filter { $0.hasSuffix(".json") }
        guard names.count > Self.maximumChats else { return }
        var dated: [(name: String, at: Date)] = []
        for name in names {
            let at = await modificationDate(of: directory + "/" + name) ?? Date.distantPast
            dated.append((name, at))
        }
        dated.sort { $0.at > $1.at }
        for entry in dated.dropFirst(Self.maximumChats) {
            await disk.delete(at: directory + "/" + entry.name)
        }
    }

    private func modificationDate(of path: String) async -> Date? {
        let url = await disk.fileURL(path)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else { return nil }
        return values.contentModificationDate
    }

    private static func directory(owner: String) -> String {
        let safe = sanitized(owner)
        guard !safe.isEmpty else { return "" }
        return root + "/" + safe
    }

    private static func filename(_ id: String) -> String {
        let safe = sanitized(id)
        guard !safe.isEmpty else { return "" }
        return safe + ".json"
    }

    /// Path components are minted by us, but an id that arrived from the server has no such
    /// promise: everything outside `[A-Za-z0-9_-]` is dropped so nothing can ever address a file
    /// outside the guest's own folder.
    private static func sanitized(_ raw: String) -> String {
        let filtered = raw.filter { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }
        return String(filtered.prefix(80))
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
