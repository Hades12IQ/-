import Foundation
import CryptoKit

/// A model choice is recorded immediately, independently of the editor's debounce.
@MainActor
final class CodeSelectionPreferences {
    struct Pending: Codable, Equatable {
        let revision: String
        let selection: CodeModelSelection
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }

    func remembered(owner: String) -> CodeModelSelection {
        read(CodeModelSelection.self, key: key(owner: owner)) ?? CodeModelSelection()
    }
    @discardableResult
    func record(_ selection: CodeModelSelection, owner: String, projectID: String) -> Pending {
        let pending = Pending(revision: UUID().uuidString, selection: selection)
        defaults.set(try? JSONEncoder().encode(selection), forKey: key(owner: owner))
        defaults.set(try? JSONEncoder().encode(pending), forKey: key(owner: owner, projectID: projectID))
        return pending
    }
    func pending(owner: String, projectID: String) -> Pending? {
        read(Pending.self, key: key(owner: owner, projectID: projectID))
    }
    func acknowledge(_ pending: Pending, owner: String, projectID: String) {
        guard self.pending(owner: owner, projectID: projectID) == pending else { return }
        forget(owner: owner, projectID: projectID)
    }
    func forget(owner: String, projectID: String) {
        defaults.removeObject(forKey: key(owner: owner, projectID: projectID))
    }
    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func key(owner: String, projectID: String? = nil) -> String {
        let identity = owner + "\0" + (projectID ?? "")
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "firas.code.selection.v1." + (projectID == nil ? "account." : "pending.") + hash
    }
}

@MainActor
enum CodeSelectionPersistence {
    /// Read the current cloud conversation, changing only its selection, never a captured old project.
    static func save(selection: CodeModelSelection, projectID: String, lang: AppLanguage,
                     isCurrent: () -> Bool, fetch: () async throws -> ChatConversation,
                     commit: (UpdateChatRequest) async throws -> Void) async throws {
        guard isCurrent() else { throw APIError.cancelled }
        let saved = try await fetch()
        guard isCurrent(), saved.id == projectID, let parsed = CodeStore.parse(saved) else { throw APIError.cancelled }
        var thread = parsed.thread
        thread.selection = selection
        var messages = saved.messages.map(MessageSerializer.persisted)
        if let index = saved.messages.lastIndex(where: { CodeChatThread.decode(fromFence: $0.content) != nil }) {
            messages[index].content = thread.encodedFence()
        } else {
            messages.insert(PersistedMessage(role: "assistant", content: thread.encodedFence(), lang: lang.rawValue, reasoning: ""), at: min(1, messages.count))
        }
        try await commit(UpdateChatRequest(messages: messages))
        guard isCurrent() else { throw APIError.cancelled }
    }
}
