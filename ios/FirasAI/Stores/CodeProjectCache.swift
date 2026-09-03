import Foundation
import OSLog

/// One row of the on-disk project index.
///
/// The index exists for two reasons the per-project files cannot serve: a guest has no server
/// list at all, and a member opening the launcher offline must still see names and file counts
/// before any network call resolves.
struct CodeProjectRecord: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var fileCount: Int
    /// Epoch seconds of the last local write.
    var updatedAt: Double

    /// Guest projects (and any project minted before a server id existed) carry the local id
    /// prefix and never reach `/api/chats`.
    var isLocal: Bool { id.hasPrefix("ios_") }

    init(id: String, name: String, fileCount: Int, updatedAt: Double) {
        self.id = id
        self.name = name
        self.fileCount = fileCount
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = LenientJSON.string(container, "id") ?? ""
        name = LenientJSON.string(container, "name") ?? ""
        fileCount = LenientJSON.int(container, "fileCount") ?? 0
        updatedAt = LenientJSON.double(container, "updatedAt") ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(name, forKey: AnyCodingKey("name"))
        try container.encode(fileCount, forKey: AnyCodingKey("fileCount"))
        try container.encode(updatedAt, forKey: AnyCodingKey("updatedAt"))
    }
}

/// The offline mirror of every Firas Code project this device has opened.
///
/// A project's authoritative home is its `codeProj` chat on the server (`web-code-ux.md §0.1`);
/// this actor is the copy that makes the launcher instant, survives a dead network, and *is* the
/// only home a guest project ever has. Everything here is off the main actor: a project can be
/// 180 000 characters of JSON and encoding it on the main thread is a visible stall.
actor CodeProjectCache {

    private let disk: DiskStore
    private var index: [String: CodeProjectRecord]?

    private static let directory = "CodeProjects"
    private static let indexPath = "CodeProjects/index.json"

    init(disk: DiskStore) {
        self.disk = disk
    }

    // MARK: - Projects

    func load(id: String) async -> CodeProject? {
        let key = Self.key(for: id)
        guard !key.isEmpty else { return nil }
        return await disk.read(CodeProject.self, at: Self.projectPath(key))
    }

    func save(_ p: CodeProject, id: String) async {
        let key = Self.key(for: id)
        guard !key.isEmpty else { return }
        do {
            try await disk.write(p, at: Self.projectPath(key))
        } catch {
            Log.ui.error("code project cache write failed")
            return
        }
        var records = await loadIndex()
        records[id] = CodeProjectRecord(
            id: id,
            name: p.name,
            fileCount: p.files.count,
            updatedAt: Date().timeIntervalSince1970
        )
        await writeIndex(records)
    }

    func delete(id: String) async {
        let key = Self.key(for: id)
        guard !key.isEmpty else { return }
        await disk.delete(at: Self.projectPath(key))
        await disk.delete(at: Self.threadPath(key))
        var records = await loadIndex()
        records[id] = nil
        await writeIndex(records)
    }

    // MARK: - Thread

    /// `messages[1]` of the project chat, mirrored so the AI conversation survives an offline
    /// launch exactly as the files do.
    func loadThread(id: String) async -> CodeChatThread? {
        let key = Self.key(for: id)
        guard !key.isEmpty else { return nil }
        return await disk.read(CodeChatThread.self, at: Self.threadPath(key))
    }

    func saveThread(_ thread: CodeChatThread, id: String) async {
        let key = Self.key(for: id)
        guard !key.isEmpty else { return }
        do {
            try await disk.write(thread, at: Self.threadPath(key))
        } catch {
            Log.ui.error("code thread cache write failed")
        }
    }

    // MARK: - Index

    /// Newest first — the order the launcher grid draws.
    func records() async -> [CodeProjectRecord] {
        let records = await loadIndex()
        return records.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Renames the cached row without rewriting the whole project blob.
    func rename(id: String, to name: String) async {
        var records = await loadIndex()
        guard var record = records[id] else { return }
        record.name = name
        record.updatedAt = Date().timeIntervalSince1970
        records[id] = record
        await writeIndex(records)
    }

    // MARK: - Private

    private func loadIndex() async -> [String: CodeProjectRecord] {
        if let index { return index }
        let stored = await disk.read([CodeProjectRecord].self, at: Self.indexPath) ?? []
        var map: [String: CodeProjectRecord] = [:]
        for record in stored where !record.id.isEmpty {
            map[record.id] = record
        }
        index = map
        return map
    }

    private func writeIndex(_ records: [String: CodeProjectRecord]) async {
        index = records
        let list = records.values.sorted { $0.updatedAt > $1.updatedAt }
        do {
            try await disk.write(list, at: Self.indexPath)
        } catch {
            Log.ui.error("code project index write failed")
        }
    }

    /// Chat ids are `c_<clientId>` or `ios_<uuid>`, but a file name is not the place to trust a
    /// server string: everything outside the safe set becomes `-`.
    private static func key(for id: String) -> String {
        let safe = id.map { character -> Character in
            if character.isASCII, character.isLetter || character.isNumber || character == "_" || character == "-" {
                return character
            }
            return "-"
        }
        return String(String(safe).prefix(80))
    }

    private static func projectPath(_ key: String) -> String {
        directory + "/" + key + ".json"
    }

    private static func threadPath(_ key: String) -> String {
        directory + "/" + key + ".thread.json"
    }
}
