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

    private(set) var isLoadingStatus = false
    private(set) var isLoadingRepos = false
    private(set) var isLoadingBranches = false
    private(set) var isStarting = false
    private(set) var hasLoadedStatus = false

    /// Resolved at render time, never in the store: this object does not see the language.
    private(set) var failure: LText?

    private(set) var links: [String: CodeGitHubLink] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastStatusRead: Date?

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
            if !value.connected {
                repos = []
                branches = []
                branchesRepo = ""
            }
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
        repos = []
        branches = []
        branchesRepo = ""
        lastStatusRead = nil
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
