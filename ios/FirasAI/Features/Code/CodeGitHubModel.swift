import Foundation
import Observation
import UIKit

// MARK: - Wire shapes (`server.mjs` handleGithub*)

/// `GET /api/github/status` — every field optional on the wire, so every field is defaulted here.
struct CodeGitHubStatus: Decodable, Sendable, Equatable {
    let configured: Bool
    let connected: Bool
    let login: String
    let avatar: String
    let scope: String

    init(configured: Bool, connected: Bool, login: String, avatar: String, scope: String) {
        self.configured = configured
        self.connected = connected
        self.login = login
        self.avatar = avatar
        self.scope = scope
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        configured = LenientJSON.bool(c, "configured") ?? false
        connected = LenientJSON.bool(c, "connected") ?? false
        login = LenientJSON.string(c, "login") ?? ""
        avatar = LenientJSON.string(c, "avatar") ?? ""
        scope = LenientJSON.string(c, "scope") ?? ""
    }
}

/// One row of `GET /api/github/repos`. `private` is a Swift keyword, so the flag is `isPrivate`
/// and the decoder reads the server's `private` key by hand.
struct CodeGitHubRepo: Decodable, Sendable, Equatable, Hashable, Identifiable {
    let fullName: String
    let name: String
    let owner: String
    let isPrivate: Bool
    let defaultBranch: String
    let summary: String
    let pushedAt: Double

    var id: String { fullName }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        fullName = LenientJSON.string(c, "fullName") ?? ""
        name = LenientJSON.string(c, "name") ?? ""
        owner = LenientJSON.string(c, "owner") ?? ""
        isPrivate = LenientJSON.bool(c, "private") ?? false
        defaultBranch = LenientJSON.string(c, "defaultBranch") ?? "main"
        summary = LenientJSON.string(c, "description") ?? ""
        pushedAt = LenientJSON.double(c, "pushedAt") ?? 0
    }
}

/// One blob in a repository tree (`GET /api/github/tree`). Directories never arrive: the server
/// filters to `type: "blob"` and caps the answer at 2 000 entries before it replies.
struct CodeGitHubTreeEntry: Decodable, Sendable, Equatable, Hashable, Identifiable {
    let path: String
    /// Bytes, as GitHub reports them. Zero for an entry GitHub did not size.
    let size: Int

    var id: String { path }

    /// The last path component — what the list draws large and what a request is matched against.
    var name: String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    init(path: String, size: Int) {
        self.path = path
        self.size = size
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        path = LenientJSON.string(c, "path") ?? ""
        size = LenientJSON.int(c, "size") ?? 0
    }
}

private struct CodeGitHubTreeEnvelope: Decodable, Sendable {
    let tree: [CodeGitHubTreeEntry]
    let truncated: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        tree = LenientJSON.array(c, "tree", of: CodeGitHubTreeEntry.self) ?? []
        truncated = LenientJSON.bool(c, "truncated") ?? false
    }
}

private struct CodeGitHubFileEnvelope: Decodable, Sendable {
    let path: String
    let content: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        path = LenientJSON.string(c, "path") ?? ""
        content = LenientJSON.string(c, "content") ?? ""
    }
}

/// The repository a session is pointed at. Device-local: the server keeps the token, never the
/// per-project choice.
struct CodeGitHubLink: Codable, Sendable, Equatable, Hashable {
    var repo: String
    var branch: String

    init(repo: String, branch: String) {
        self.repo = repo
        self.branch = branch
    }

    /// `owner/repo · branch`, the string the context pill and the session row both show.
    var label: String {
        branch.isEmpty ? repo : repo + " · " + branch
    }
}

private struct CodeGitHubStartEnvelope: Decodable, Sendable {
    let url: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        url = LenientJSON.string(c, "url") ?? ""
    }
}

private struct CodeGitHubReposEnvelope: Decodable, Sendable {
    let repos: [CodeGitHubRepo]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        repos = LenientJSON.array(c, "repos", of: CodeGitHubRepo.self) ?? []
    }
}

private struct CodeGitHubBranchesEnvelope: Decodable, Sendable {
    let branches: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        branches = LenientJSON.array(c, "branches", of: String.self) ?? []
    }
}

// MARK: - The model

/// The GitHub half of Firas Code: is an account linked, which repositories does it have, and which
/// repository is a given session pointed at.
///
/// It is a `shared` singleton rather than an `AppEnvironment` member because the launcher and the
/// session screen are siblings in `AppShell` — a `@State` in either one would not reach the other,
/// and `AppEnvironment` is owned by another engineer this wave. Nothing here is cached to disk
/// except the per-session repository choice; the token never leaves the server.
///
/// The OAuth hand-off opens Safari rather than `ASWebAuthenticationSession`: the server's callback
/// is an ordinary `https://` page (it answers with HTML, not a custom-scheme redirect), so a web
/// authentication session would never see a callback it could match and would sit there until the
/// reader dismissed it. `refreshStatus(api:force:)` on the next foreground is the completion signal.
@MainActor
@Observable
final class CodeGitHubModel {

    static let shared = CodeGitHubModel()

    private static let linksKey = "firas.code.github.links"

    private(set) var status: CodeGitHubStatus?
    private(set) var repos: [CodeGitHubRepo] = []
    private(set) var branches: [String] = []
    private(set) var branchesRepo = ""

    /// The file tree of the repository last asked for, and the `owner/repo@ref` it belongs to.
    /// One at a time: a session points at one repository, and keeping more only ages them.
    private(set) var tree: [CodeGitHubTreeEntry] = []
    private(set) var treeKey = ""
    /// GitHub stopped listing before the end. Said out loud rather than pretending the tree is whole.
    private(set) var treeTruncated = false

    private(set) var isLoadingStatus = false
    private(set) var isLoadingRepos = false
    private(set) var isLoadingBranches = false
    private(set) var isLoadingTree = false
    private(set) var isStarting = false
    private(set) var hasLoadedStatus = false

    /// Resolved at render time, never in the store: this object does not see the language.
    private(set) var failure: LText?

    private(set) var links: [String: CodeGitHubLink] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastStatusRead: Date?

    /// Blob bodies already read, keyed `owner/repo@ref:path`, newest last. A ref is a moving
    /// target, so this is a per-launch cache and never reaches disk: the point is that asking two
    /// questions about the same file does not read it twice, not that yesterday's HEAD is still true.
    @ObservationIgnored private var fileBodies: [String: String] = [:]
    @ObservationIgnored private var fileBodyOrder: [String] = []

    /// How many blob bodies stay in memory. Six per question, a handful more from the browser.
    static let fileCacheLimit = 40

    /// Where the server slices the tree before it answers. Repeated here rather than inferred,
    /// because a list that stops at exactly this length is the only evidence the client is given
    /// that a repository was cut — GitHub's own `truncated` flag says nothing about our slice.
    static let treeEntryLimit = 2_000

    init(defaults: UserDefaults = UserDefaults.standard) {
        self.defaults = defaults
        self.links = Self.readLinks(from: defaults)
    }

    // MARK: - Reading

    /// True until the server says otherwise, so the Connect row never flashes on a cold start.
    var isConfigured: Bool { status?.configured ?? true }
    var isConnected: Bool { status?.connected ?? false }
    var login: String { status?.login ?? "" }

    /// The Connect row is offered only when the server has the feature and nobody is linked yet.
    var shouldOfferConnect: Bool {
        guard let status else { return false }
        return status.configured && !status.connected
    }

    func link(for projectID: String) -> CodeGitHubLink? {
        guard !projectID.isEmpty else { return nil }
        return links[projectID]
    }

    func setLink(_ link: CodeGitHubLink?, for projectID: String) {
        guard !projectID.isEmpty else { return }
        if let link, !link.repo.isEmpty {
            links[projectID] = link
        } else {
            links.removeValue(forKey: projectID)
        }
        writeLinks()
    }

    func clearFailure() {
        failure = nil
    }

    // MARK: - Status

    /// `force` is for the pull-to-refresh and the return-from-Safari path; everything else is
    /// happy with a reading from the last two minutes.
    func refreshStatus(api: APIClient, force: Bool = false) async {
        if !force, let last = lastStatusRead, Date().timeIntervalSince(last) < 120, hasLoadedStatus {
            return
        }
        guard !isLoadingStatus else { return }
        isLoadingStatus = true
        defer { isLoadingStatus = false }
        do {
            let value = try await api.json(.get, "/api/github/status", as: CodeGitHubStatus.self)
            status = value
            hasLoadedStatus = true
            lastStatusRead = Date()
            failure = nil
            if !value.connected { forgetRepositoryData() }
        } catch {
            hasLoadedStatus = true
            lastStatusRead = Date()
            // A signed-out reader is not a GitHub failure: the Connect row simply does not appear.
            if Self.statusCode(of: error) == 401 {
                status = CodeGitHubStatus(
                    configured: false,
                    connected: false,
                    login: "",
                    avatar: "",
                    scope: ""
                )
                failure = nil
            } else {
                failure = Self.text(for: error)
            }
        }
    }

    // MARK: - Repositories and branches

    func loadRepos(api: APIClient, force: Bool = false) async {
        guard isConnected else { return }
        if !force, !repos.isEmpty { return }
        guard !isLoadingRepos else { return }
        isLoadingRepos = true
        defer { isLoadingRepos = false }
        do {
            let envelope = try await api.json(.get, "/api/github/repos", as: CodeGitHubReposEnvelope.self)
            repos = envelope.repos.sorted { $0.pushedAt > $1.pushedAt }
            failure = nil
        } catch {
            failure = Self.text(for: error)
            if Self.statusCode(of: error) == 409 { markDisconnected() }
        }
    }

    func loadBranches(api: APIClient, repo: String) async {
        guard isConnected, !repo.isEmpty else { return }
        guard !isLoadingBranches || branchesRepo != repo else { return }
        branchesRepo = repo
        isLoadingBranches = true
        defer { isLoadingBranches = false }
        do {
            let envelope = try await api.json(
                .get,
                "/api/github/branches",
                query: ["repo": repo],
                as: CodeGitHubBranchesEnvelope.self
            )
            guard branchesRepo == repo else { return }
            branches = envelope.branches
            failure = nil
        } catch {
            guard branchesRepo == repo else { return }
            branches = []
            failure = Self.text(for: error)
            if Self.statusCode(of: error) == 409 { markDisconnected() }
        }
    }

    // MARK: - The tree, and the files in it

    /// `owner/repo@ref`. An empty branch is the repository's own default, which is what the server
    /// resolves `HEAD` to, so the two must not be cached under different keys.
    static func refKey(repo: String, ref: String) -> String {
        repo + "@" + (ref.isEmpty ? "HEAD" : ref)
    }

    /// The whole file list of one branch, in one call. Cached until the reader asks for another
    /// repository or pulls to refresh: a tree is up to 2 000 rows and nothing in a session changes
    /// it, so re-reading it per question would spend the reader's hourly GitHub budget on nothing.
    func loadTree(api: APIClient, repo: String, ref: String, force: Bool = false) async {
        guard isConnected, !repo.isEmpty else { return }
        let key = Self.refKey(repo: repo, ref: ref)
        if !force, treeKey == key, !tree.isEmpty { return }
        guard !isLoadingTree else { return }
        // A list left over from the branch that was on screen before this one is not this branch's
        // list. Kept for the length of the round trip it would be drawn under the new repository's
        // name, and every row of it would be tappable — asking the new repository for a path that
        // only the old one has.
        if treeKey != key {
            tree = []
            treeTruncated = false
        }
        isLoadingTree = true
        treeKey = key
        defer { isLoadingTree = false }

        var query = ["repo": repo]
        if !ref.isEmpty { query["ref"] = ref }
        do {
            let envelope = try await api.json(
                .get,
                "/api/github/tree",
                query: query,
                as: CodeGitHubTreeEnvelope.self
            )
            // The reader may have picked another repository while this was in flight; the answer
            // to a question nobody is asking any more must not become the tree on screen.
            guard treeKey == key else { return }
            let kept = envelope.tree.filter { !$0.path.isEmpty }
            tree = kept
            // `truncated` on the wire is GitHub's flag, and GitHub does not know about the 2 000-row
            // slice the server takes afterwards. A list that fills that cap exactly was cut by
            // somebody, so it is reported as cut rather than handed over as a whole repository.
            treeTruncated = envelope.truncated || kept.count >= Self.treeEntryLimit
            failure = nil
        } catch {
            guard treeKey == key else { return }
            tree = []
            treeTruncated = false
            failure = Self.text(for: error)
            if Self.statusCode(of: error) == 409 { markDisconnected() }
        }
    }

    /// One blob, decoded to text. `nil` for anything the server would not hand over — a binary, a
    /// file past its 400 000-byte ceiling, a path that has since moved — and every caller simply
    /// leaves that file out rather than showing the reader a failure they cannot act on.
    func readFile(api: APIClient, repo: String, ref: String, path: String) async -> String? {
        guard isConnected, !repo.isEmpty, !path.isEmpty else { return nil }
        let key = Self.refKey(repo: repo, ref: ref) + ":" + path
        if let cached = fileBodies[key] { return cached }

        var query = ["repo": repo, "path": path]
        if !ref.isEmpty { query["ref"] = ref }
        do {
            let envelope = try await api.json(
                .get,
                "/api/github/file",
                query: query,
                as: CodeGitHubFileEnvelope.self
            )
            remember(envelope.content, for: key)
            return envelope.content
        } catch {
            if Self.statusCode(of: error) == 409 { markDisconnected() }
            return nil
        }
    }

    private func remember(_ body: String, for key: String) {
        if fileBodies[key] == nil { fileBodyOrder.append(key) }
        fileBodies[key] = body
        while fileBodyOrder.count > Self.fileCacheLimit {
            let oldest = fileBodyOrder.removeFirst()
            fileBodies[oldest] = nil
        }
    }

    // MARK: - Linking

    /// Asks the server for the authorize URL and hands it to Safari. Returns `true` when the
    /// browser actually took it, so the caller can show the "come back when you are done" hint.
    func connect(api: APIClient) async -> Bool {
        guard !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }
        failure = nil
        do {
            let envelope = try await api.json(.get, "/api/github/start", as: CodeGitHubStartEnvelope.self)
            guard !envelope.url.isEmpty,
                  let url = URL(string: envelope.url),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https"
            else {
                failure = Strings.Code.gitHubOpenFailed
                return false
            }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return true
        } catch {
            failure = Self.text(for: error)
            return false
        }
    }

    func disconnect(api: APIClient) async {
        do {
            _ = try await api.raw(.post, "/api/github/disconnect")
            markDisconnected()
            failure = nil
        } catch {
            failure = Self.text(for: error)
        }
    }

    private func markDisconnected() {
        let configured = status?.configured ?? true
        status = CodeGitHubStatus(
            configured: configured,
            connected: false,
            login: "",
            avatar: "",
            scope: ""
        )
        forgetRepositoryData()
        lastStatusRead = nil
    }

    /// Everything read with the token goes when the token does — the file bodies included. A
    /// private repository's source must not survive the account being unlinked.
    private func forgetRepositoryData() {
        repos = []
        branches = []
        branchesRepo = ""
        tree = []
        treeKey = ""
        treeTruncated = false
        fileBodies = [:]
        fileBodyOrder = []
    }

    // MARK: - Persistence

    private func writeLinks() {
        guard let data = try? JSONEncoder().encode(links) else { return }
        defaults.set(data, forKey: Self.linksKey)
    }

    private nonisolated static func readLinks(from defaults: UserDefaults) -> [String: CodeGitHubLink] {
        guard let data = defaults.data(forKey: linksKey),
              let decoded = try? JSONDecoder().decode([String: CodeGitHubLink].self, from: data)
        else { return [:] }
        return decoded
    }

    // MARK: - Errors

    /// Status and code only — never the server's sentence (`ARCHITECTURE.md §2.15`).
    private nonisolated static func text(for error: Error) -> LText {
        guard let api = error as? APIError else { return Strings.Code.gitHubFailed }
        switch api {
        case .offline, .transport:
            return Strings.Errors.offline
        case .deadline:
            return Strings.Errors.timeout
        case .cancelled:
            return Strings.Code.gitHubFailed
        case .decoding, .invalidURL:
            return Strings.Code.gitHubFailed
        case .http(let status, _, _):
            switch status {
            case 401: return Strings.Code.gitHubSignInFirst
            case 409: return Strings.Code.gitHubReconnect
            case 429: return Strings.Errors.tooFast
            case 503: return Strings.Code.gitHubUnavailable
            default: return Strings.Code.gitHubFailed
            }
        }
    }

    private nonisolated static func statusCode(of error: Error) -> Int? {
        (error as? APIError)?.status
    }
}

// MARK: - Copy

/// Copy for the repository half of Firas Code — browsing a linked repository's files, and telling
/// the reader when one of them is being read on their behalf.
///
/// It is its own namespace, in the file that owns the behaviour, for the same reason
/// `Strings.CodeUI` is: `Localization/Strings+Code.swift` belongs to another engineer this wave,
/// and two owners must never need the same file open.
extension Strings {

    enum CodeRepo {

        // MARK: Browsing

        static let filesTitle = LText(ar: "ملفات المستودع", en: "Repository files")
        static let filesLoading = LText(ar: "يقرأ شجرة الملفات…", en: "Reading the file tree…")
        static let filesEmpty = LText(ar: "لا ملفات في هذا الفرع.", en: "No files on this branch.")
        static let filesNoMatch = LText(ar: "لا ملف يطابق بحثك.", en: "No file matches your search.")
        static let filesSearch = LText(ar: "ابحث في ملفات المستودع", en: "Search repository files")
        static let filesTruncated = LText(
            ar: "المستودع أكبر من أن يُسرَد كاملًا — هذه أول ٢٠٠٠ ملف.",
            en: "This repository is too large to list in full — these are the first 2,000 files."
        )
        /// `%@` is a whole number of kilobytes, already rendered in the reader's digits.
        static let fileSize = LText(ar: "%@ ك.ب", en: "%@ KB")

        static let fileOpening = LText(ar: "يفتح الملف…", en: "Opening the file…")
        static let fileFailed = LText(
            ar: "تعذّر فتح هذا الملف — قد يكون ثنائيًا أو أكبر من حدّ القراءة.",
            en: "Could not open that file — it may be binary, or past the read limit."
        )
        /// The viewer stops where `CodeProject.maximumFileCharacters` does. `%@` is that number in
        /// the reader's digits — read from the constant, so the sentence cannot drift away from it.
        static let fileTruncated = LText(
            ar: "عُرض أول %@ حرف من هذا الملف فقط.",
            en: "Only the first %@ characters of this file are shown."
        )
        static let fileImport = LText(ar: "أضِفه إلى المشروع", en: "Add it to the project")
        /// `%@` is the file's path.
        static let fileImported = LText(
            ar: "أُضيف «%@» إلى المشروع ✓",
            en: "Added “%@” to the project ✓"
        )

        static let notLinkedTitle = LText(
            ar: "لا مستودع في هذه الجلسة",
            en: "No repository in this session"
        )
        static let notLinkedBody = LText(
            ar: "اربط الجلسة بمستودع لتتصفّح ملفاته، وليقرأها فِراس كود حين تسأله عنها.",
            en: "Point this session at a repository to browse its files — and to let Firas Code read them when you ask about them."
        )
        static let pickRepository = LText(ar: "اختر مستودعًا", en: "Pick a repository")

        // MARK: Reading, on the reader's behalf

        /// A console row while a question is being answered. `%@` is `owner/repo · branch`.
        static let contextReading = LText(ar: "يقرأ %@ من GitHub", en: "Reading %@ from GitHub")
        /// The row that follows it. `%@` is a file count from `Strings.Code.fileCount`, which
        /// agrees in the nominative — so this is a label with a colon, not a verb phrase, and the
        /// count never lands in a case the helper cannot produce.
        static let contextRead = LText(
            ar: "من المستودع: %@",
            en: "From the repository: %@"
        )
    }
}
