#if DEBUG
import Foundation

@MainActor
enum CodeSelectionPersistenceChecks {
    static func run() async -> [String] {
        var errors: [String] = []
        let suite = "firas.code.selection.fixture." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return ["Code selection: isolated defaults unavailable"] }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CodeSelectionPreferences(defaults: defaults)
        let atlas = CodeModelSelection(model: .max, depth: "deep")
        let old = preferences.record(atlas, owner: "alice", projectID: "project")
        let relaunched = CodeSelectionPreferences(defaults: defaults)
        if relaunched.remembered(owner: "alice") != atlas || relaunched.pending(owner: "alice", projectID: "project") != old {
            errors.append("Code selection: a quick close/relaunch lost the recorded choice")
        }
        if relaunched.remembered(owner: "bob") != CodeModelSelection() || relaunched.pending(owner: "bob", projectID: "project") != nil {
            errors.append("Code selection: an account inherited another account's choice")
        }
        let latest = preferences.record(CodeModelSelection(model: .omnix), owner: "alice", projectID: "project")
        preferences.acknowledge(old, owner: "alice", projectID: "project")
        if preferences.pending(owner: "alice", projectID: "project") != latest {
            errors.append("Code selection: an older acknowledgement removed a newer choice")
        }
        let project = CodeProject(name: "Current remote project", files: [CodeFile(path: "main.py", content: "print('latest')")])
        let remoteThread = CodeChatThread(messages: [CodeChatMessage(role: "ai", content: "A newer server answer")])
        let saved = ChatConversation(id: "project", title: project.name, messages: [
            ChatMessage(role: .assistant, content: project.encodedFence()),
            ChatMessage(role: .assistant, content: remoteThread.encodedFence()),
            ChatMessage(role: .assistant, content: "A saved edit proposal")
        ], codeProj: true)
        var captured: UpdateChatRequest?
        do {
            // The original view is already closed; ownership, not the open view, controls this save.
            try await CodeSelectionPersistence.save(selection: atlas, projectID: "project", lang: .english,
                isCurrent: { true }, fetch: { saved }, commit: { captured = $0 })
            let messages = captured?.messages ?? []
            if messages.count != saved.messages.count || messages.first?.content != saved.messages.first?.content
                || messages.last?.content != saved.messages.last?.content
                || CodeChatThread.decode(fromFence: messages[1].content)?.messages != remoteThread.messages
                || CodeChatThread.decode(fromFence: messages[1].content)?.selection != atlas {
                errors.append("Code selection: quick-close save replaced newer project files or thread content")
            }
            if captured?.title != nil { errors.append("Code selection: preference save changed the project title") }
        } catch { errors.append("Code selection: quick-close save failed") }
        var current = true
        var commits = 0
        do {
            try await CodeSelectionPersistence.save(selection: atlas, projectID: "project", lang: .english,
                isCurrent: { current }, fetch: { current = false; return saved }, commit: { _ in commits += 1 })
            errors.append("Code selection: stale account or choice was accepted")
        } catch { }
        if commits != 0 { errors.append("Code selection: a stale read committed after ownership changed") }
        current = true
        let otherProject = ChatConversation(id: "other-project", title: "Other project", messages: saved.messages, codeProj: true)
        do {
            try await CodeSelectionPersistence.save(selection: atlas, projectID: "project", lang: .english,
                isCurrent: { current }, fetch: { otherProject }, commit: { _ in commits += 1 })
            errors.append("Code selection: another project's conversation was accepted")
        } catch { }
        if commits != 0 { errors.append("Code selection: a delayed read overwrote another project") }
        current = true
        do {
            try await CodeSelectionPersistence.save(selection: latest.selection, projectID: "project", lang: .english,
                isCurrent: { current }, fetch: { saved }, commit: { _ in current = false })
            preferences.acknowledge(latest, owner: "alice", projectID: "project")
            errors.append("Code selection: delayed save completion survived an account/generation change")
        } catch { }
        if preferences.pending(owner: "alice", projectID: "project") != latest {
            errors.append("Code selection: delayed completion acknowledged an old account's pending choice")
        }
        current = true
        do {
            try await CodeSelectionPersistence.save(selection: latest.selection, projectID: "project", lang: .english,
                isCurrent: { current }, fetch: { throw URLError(.notConnectedToInternet) }, commit: { _ in commits += 1 })
            errors.append("Code selection: offline save unexpectedly succeeded")
        } catch { }
        let retryPreferences = CodeSelectionPreferences(defaults: defaults)
        guard let retry = retryPreferences.pending(owner: "alice", projectID: "project") else {
            errors.append("Code selection: an offline choice was not available for retry")
            return errors
        }
        do {
            try await CodeSelectionPersistence.save(selection: retry.selection, projectID: "project", lang: .english,
                isCurrent: { retryPreferences.pending(owner: "alice", projectID: "project") == retry },
                fetch: { saved }, commit: { captured = $0 })
            retryPreferences.acknowledge(retry, owner: "alice", projectID: "project")
            if CodeChatThread.decode(fromFence: captured?.messages?[1].content ?? "")?.selection != latest.selection {
                errors.append("Code selection: reopening did not retry the latest pending choice")
            }
        } catch { errors.append("Code selection: pending choice retry failed") }
        if preferences.pending(owner: "alice", projectID: "project") != nil || preferences.remembered(owner: "alice").model != .omnix {
            errors.append("Code selection: acknowledged project save lost the new-session default")
        }
        return errors
    }
}
#endif
