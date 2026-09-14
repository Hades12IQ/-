import Foundation
import Perception

@MainActor @Perceptible
final class AccountSkillsStore {
    private var entries: [AccountSkill] = []
    private(set) var skills: [AccountSkill] {
        get { session.isMember && owner == session.identityID ? entries : [] }
        set { entries = newValue }
    }
    private(set) var loading = false
    private(set) var mutating = false
    private(set) var loaded = false
    private(set) var failure: String?
    @PerceptionIgnored private let api: APIClient
    @PerceptionIgnored private let session: SessionStore
    @PerceptionIgnored private var owner: String?
    @PerceptionIgnored private var epoch = 0
    @PerceptionIgnored private var revision = 0
    @PerceptionIgnored private var lastLoaded = Date.distantPast

    init(api: APIClient, session: SessionStore) { self.api = api; self.session = session }
    func identityDidChange() {
        let current = session.isMember ? session.identityID : nil
        guard owner != current else { return }
        owner = current; epoch += 1
        skills = []; loaded = false; loading = false; mutating = false; failure = nil
        lastLoaded = .distantPast
    }
    private func isCurrent(_ value: Int) -> Bool {
        value == epoch && session.isMember && owner == session.identityID
    }
    func load(force: Bool = false) async {
        identityDidChange()
        guard session.isMember, !loading, !mutating, force || !loaded || Date().timeIntervalSince(lastLoaded) > 30 else { return }
        let version = epoch
        let requestedRevision = revision
        loading = true
        defer { if isCurrent(version) { loading = false } }
        do {
            let result = try await api.json(.get, "/api/skills", as: AccountSkillsResponse.self)
            guard isCurrent(version), requestedRevision == revision else { return }
            skills = result.skills; loaded = true; failure = nil; lastLoaded = Date()
        } catch { if isCurrent(version) { failure = Self.code(error) } }
    }
    func library(query: String = "", domain: String = "") async throws -> SkillLibraryResponse {
        identityDidChange()
        guard session.isMember else { throw APIError.cancelled }
        let version = epoch
        var parameters = ["scope": "library"]
        if !query.isEmpty { parameters["q"] = String(query.prefix(200)) }
        else if !domain.isEmpty { parameters["domain"] = domain }
        let result = try await api.json(.get, "/api/skills", query: parameters, as: SkillLibraryResponse.self)
        guard isCurrent(version) else { throw APIError.cancelled }
        return result
    }
    func save(_ skill: AccountSkill) async throws -> AccountSkill {
        identityDidChange()
        guard session.isMember, !mutating else { throw APIError.cancelled }
        let version = epoch
        mutating = true
        defer { if isCurrent(version) { mutating = false } }
        let response = try await api.json(.post, "/api/skills", body: SkillSaveRequest(skill), as: AccountSkillResponse.self)
        guard isCurrent(version) else { throw APIError.cancelled }
        upsert(response.skill)
        return response.skill
    }
    func toggle(_ skill: AccountSkill) async {
        identityDidChange()
        guard session.isMember, !mutating else { return }
        let version = epoch
        mutating = true
        defer { if isCurrent(version) { mutating = false } }
        do {
            let response = try await api.json(.patch, "/api/skills", body: SkillToggleRequest(id: skill.id, enabled: !skill.enabled), as: AccountSkillResponse.self)
            guard isCurrent(version) else { return }
            upsert(response.skill); failure = nil
        } catch { if isCurrent(version) { failure = Self.code(error) } }
    }
    func delete(_ skill: AccountSkill) async {
        identityDidChange()
        guard session.isMember, !mutating else { return }
        let version = epoch
        mutating = true
        defer { if isCurrent(version) { mutating = false } }
        do {
            _ = try await api.raw(.delete, "/api/skills", query: ["id": skill.id])
            guard isCurrent(version) else { return }
            skills.removeAll { $0.id == skill.id }; failure = nil
            revision += 1
        } catch { if isCurrent(version) { failure = Self.code(error) } }
    }
    private func upsert(_ skill: AccountSkill) {
        revision += 1
        if let index = skills.firstIndex(where: { $0.id == skill.id }) { skills[index] = skill }
        else { skills.append(skill) }
    }
    func selected(_ ids: [String]) -> [AccountSkill] {
        identityDidChange()
        return Array(ids.prefix(3)).compactMap { id in skills.first { $0.id == id && $0.enabled } }
    }
    static func code(_ error: Error) -> String {
        if case APIError.http(let status, let server, _) = error {
            if status == 401 { return "signin" }
            return server.skillProblems?.first ?? server.code ?? "unavailable"
        }
        return "unavailable"
    }
    #if DEBUG
    func seedForGallery(_ entries: [AccountSkill]) { skills = entries; loaded = true }
    #endif
}
