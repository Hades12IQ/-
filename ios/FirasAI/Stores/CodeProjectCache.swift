import Foundation
import OSLog
import CryptoKit

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

/// The on-disk record of a build that started **in front of the reader**.
///
/// It exists for one reason. A Firas Code build is watched live — the app plans the files and
/// streams each one so the reader sees the project being written — but the moment the reader leaves,
/// the same turn has to continue on the server. This row is what makes that possible: it carries the
/// brief and the `cid`, it is written before the first model token, and it is deleted only once the
/// files are safely in the project. Every exit reads it and ends in the same call — `POST
/// /api/chat/job` with that same `cid` — and because the queue is idempotent per owner + `cid`
/// (`server-code-brainask.md §1.5`), that call adopts an existing job as readily as it starts a new
/// one. A doubled build is therefore not reachable.
///
/// It is deliberately **not** a `JobPointer`: a pointer means "the server owns this job", and
/// `JobManager` starts polling one the moment it hears about it. A codebuild pointer for an id the
/// server has never seen would answer `{"phase":"unknown"}` and expire on the first read
/// (`JobKindSpecs`: `unknownReadsBeforeTerminal = 1`). The ticket is the *pre*-pointer state, and it
/// only ever turns into a real pointer through `JobManager.startChatQueueJob`.
struct CodeBuildTicket: Codable, Sendable, Equatable, Identifiable {
    /// The project chat this build belongs to. One live build per project, so this is the key.
    let projectID: String
    /// The turn id, minted once and never re-minted — it is what makes the handover an adoption.
    let cid: String
    /// Which identity started it. Another owner's ticket is left alone, never handed anywhere.
    let ownerID: String
    var name: String
    var brief: String
    var attach: String
    var lang: String
    /// Epoch seconds. Never refreshed: the two-hour ceiling measures the age of the **build**.
    var startedAt: Double
    /// True once the durable queue has accepted the turn. From then on `JobManager` owns it and
    /// this row exists only so the pointer can be rebuilt if `jobs.json` is ever lost.
    var handedOff: Bool
    var jobID: String?

    var id: String { projectID }

    init(
        projectID: String,
        cid: String,
        ownerID: String,
        name: String,
        brief: String,
        attach: String,
        lang: String,
        startedAt: Double,
        handedOff: Bool = false,
        jobID: String? = nil
    ) {
        self.projectID = projectID
        self.cid = cid
        self.ownerID = ownerID
        self.name = name
        self.brief = brief
        self.attach = attach
        self.lang = lang
        self.startedAt = startedAt
        self.handedOff = handedOff
        self.jobID = jobID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        projectID = LenientJSON.string(container, "projectID") ?? ""
        cid = LenientJSON.string(container, "cid") ?? ""
        ownerID = LenientJSON.string(container, "ownerID") ?? ""
        name = LenientJSON.string(container, "name") ?? ""
        brief = LenientJSON.string(container, "brief") ?? ""
        attach = LenientJSON.string(container, "attach") ?? ""
        lang = LenientJSON.string(container, "lang") ?? "ar"
        startedAt = LenientJSON.double(container, "startedAt") ?? 0
        handedOff = LenientJSON.bool(container, "handedOff") ?? false
        jobID = LenientJSON.string(container, "jobID")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(projectID, forKey: AnyCodingKey("projectID"))
        try container.encode(cid, forKey: AnyCodingKey("cid"))
        try container.encode(ownerID, forKey: AnyCodingKey("ownerID"))
        try container.encode(name, forKey: AnyCodingKey("name"))
        try container.encode(brief, forKey: AnyCodingKey("brief"))
        try container.encode(attach, forKey: AnyCodingKey("attach"))
        try container.encode(lang, forKey: AnyCodingKey("lang"))
        try container.encode(startedAt, forKey: AnyCodingKey("startedAt"))
        try container.encode(handedOff, forKey: AnyCodingKey("handedOff"))
        try container.encodeIfPresent(jobID, forKey: AnyCodingKey("jobID"))
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
    private var indexes: [String: [String: CodeProjectRecord]] = [:]
    private var ticketIndex: [CodeBuildTicket]?

    private static let directory = "CodeProjects"
    // Legacy CodeProjects/*.json remain untouched. Without an owner record,
    // they cannot safely be shown until the server confirms access. A successful
    // authorized fetch writes its canonical project into the scoped namespace.
    private static let ticketsPath = "CodeProjects/builds.json"

    /// The web keeps at most twenty build pointers (`LS_CODE_JOBS`); so do we.
    static let maximumTickets = 20
    /// `CW_JOB_MAX_MS`. A build older than two hours is past the client ceiling and past anything
    /// the queue would still be running, so its ticket is dropped unread rather than handed on.
    static let ticketMaximumAge: TimeInterval = 2 * 60 * 60

    init(disk: DiskStore) {
        self.disk = disk
    }

    // MARK: - Projects

    func load(id: String, ownerID: String) async -> CodeProject? {
        let key = Self.key(for: id)
        guard !key.isEmpty, !ownerID.isEmpty else { return nil }
        return await disk.read(CodeProject.self, at: Self.projectPath(key, ownerID: ownerID))
    }

    func save(_ p: CodeProject, id: String, ownerID: String) async {
        let key = Self.key(for: id)
        guard !key.isEmpty, !ownerID.isEmpty else { return }
        do {
            try await disk.write(p, at: Self.projectPath(key, ownerID: ownerID))
        } catch {
            Log.ui.error("code project cache write failed")
            return
        }
        var records = await loadIndex(ownerID: ownerID)
        records[id] = CodeProjectRecord(
            id: id,
            name: p.name,
            fileCount: p.files.count,
            updatedAt: Date().timeIntervalSince1970
        )
        await writeIndex(records, ownerID: ownerID)
    }

    func delete(id: String, ownerID: String) async {
        let key = Self.key(for: id)
        guard !key.isEmpty, !ownerID.isEmpty else { return }
        await disk.delete(at: Self.projectPath(key, ownerID: ownerID))
        await disk.delete(at: Self.threadPath(key, ownerID: ownerID))
        var records = await loadIndex(ownerID: ownerID)
        records[id] = nil
        await writeIndex(records, ownerID: ownerID)
        // A deleted project cannot have a build worth handing to the queue on the next launch.
        await deleteTicket(projectID: id)
    }

    // MARK: - Live-build tickets

    /// Every unfinished build this device knows about, for every identity.
    func tickets() async -> [CodeBuildTicket] {
        await loadTickets()
    }

    /// Written through immediately. A ticket that has not reached disk yet is a build that a crash
    /// — or a task the system kills while the reader is in another app — loses outright.
    func saveTicket(_ ticket: CodeBuildTicket) async {
        guard !ticket.projectID.isEmpty, !ticket.cid.isEmpty, !ticket.ownerID.isEmpty else { return }
        var rows = await loadTickets().filter { $0.projectID != ticket.projectID }
        rows.append(ticket)
        await writeTickets(rows)
    }

    /// The irreversible half of the pair: only ever called once the files are in the project, or
    /// once the queue has refused the turn outright.
    func deleteTicket(projectID: String) async {
        let rows = await loadTickets()
        guard rows.contains(where: { $0.projectID == projectID }) else { return }
        await writeTickets(rows.filter { $0.projectID != projectID })
    }

    private func loadTickets() async -> [CodeBuildTicket] {
        if let ticketIndex { return ticketIndex }
        let stored = await disk.read([CodeBuildTicket].self, at: Self.ticketsPath) ?? []
        let pruned = Self.pruned(stored)
        ticketIndex = pruned
        return pruned
    }

    private func writeTickets(_ rows: [CodeBuildTicket]) async {
        let pruned = Self.pruned(rows)
        ticketIndex = pruned
        do {
            try await disk.write(pruned, at: Self.ticketsPath)
        } catch {
            Log.ui.error("code build ticket write failed")
        }
    }

    /// Garbage and dead rows go before the cap, so the cap never evicts a live build in favour of
    /// a corpse — the same ordering `JobPointerStore.prune` uses, for the same reason.
    private static func pruned(_ rows: [CodeBuildTicket]) -> [CodeBuildTicket] {
        let now = Date().timeIntervalSince1970
        var kept = rows.filter { row in
            guard !row.projectID.isEmpty, !row.cid.isEmpty, !row.ownerID.isEmpty else { return false }
            return now - row.startedAt < ticketMaximumAge
        }
        var seen: Set<String> = []
        kept = kept.sorted { $0.startedAt > $1.startedAt }.filter { seen.insert($0.projectID).inserted }
        if kept.count > maximumTickets {
            kept.removeLast(kept.count - maximumTickets)
        }
        return kept.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Thread

    /// `messages[1]` of the project chat, mirrored so the AI conversation survives an offline
    /// launch exactly as the files do.
    func loadThread(id: String, ownerID: String) async -> CodeChatThread? {
        let key = Self.key(for: id)
        guard !key.isEmpty, !ownerID.isEmpty else { return nil }
        return await disk.read(CodeChatThread.self, at: Self.threadPath(key, ownerID: ownerID))
    }

    func saveThread(_ thread: CodeChatThread, id: String, ownerID: String) async {
        let key = Self.key(for: id)
        guard !key.isEmpty, !ownerID.isEmpty else { return }
        do {
            try await disk.write(thread, at: Self.threadPath(key, ownerID: ownerID))
        } catch {
            Log.ui.error("code thread cache write failed")
        }
    }

    // MARK: - Index

    /// Newest first — the order the launcher grid draws.
    func records(ownerID: String) async -> [CodeProjectRecord] {
        let records = await loadIndex(ownerID: ownerID)
        return records.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Renames the cached row without rewriting the whole project blob.
    func rename(id: String, to name: String, ownerID: String) async {
        var records = await loadIndex(ownerID: ownerID)
        guard var record = records[id] else { return }
        record.name = name
        record.updatedAt = Date().timeIntervalSince1970
        records[id] = record
        await writeIndex(records, ownerID: ownerID)
    }

    // MARK: - Private

    private func loadIndex(ownerID: String) async -> [String: CodeProjectRecord] {
        guard !ownerID.isEmpty else { return [:] }
        if let index = indexes[ownerID] { return index }
        let path = Self.scopedDirectory(ownerID) + "/index.json"
        let stored = await disk.read([CodeProjectRecord].self, at: path) ?? []
        var map: [String: CodeProjectRecord] = [:]
        for record in stored where !record.id.isEmpty {
            map[record.id] = record
        }
        indexes[ownerID] = map
        return map
    }

    private func writeIndex(_ records: [String: CodeProjectRecord], ownerID: String) async {
        guard !ownerID.isEmpty else { return }
        indexes[ownerID] = records
        let list = records.values.sorted { $0.updatedAt > $1.updatedAt }
        do {
            try await disk.write(list, at: Self.scopedDirectory(ownerID) + "/index.json")
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

    private static func scopedDirectory(_ ownerID: String) -> String {
        let ownerKey = SHA256.hash(data: Data(ownerID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory + "/owners/" + ownerKey
    }

    private static func projectPath(_ key: String, ownerID: String) -> String {
        scopedDirectory(ownerID) + "/" + key + ".json"
    }

    private static func threadPath(_ key: String, ownerID: String) -> String {
        scopedDirectory(ownerID) + "/" + key + ".thread.json"
    }
}
