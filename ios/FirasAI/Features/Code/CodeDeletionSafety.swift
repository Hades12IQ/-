import Foundation

@MainActor
enum CodeDeletionSafety {
    struct Requests {
        var edits: [CodeEditReceipt] = []
        var omnix: [OmnixReceipt] = []
    }

    static func requests(thread: CodeChatThread, owner: String, conversationID: String,
                         completedOmnix: Set<String>) -> Requests {
        var result = Requests()
        var seenEdits: Set<String> = [], seenOmnix: Set<String> = []
        for turn in thread.messages.reversed() where turn.role == "ai" {
            if let edit = turn.edit, edit.isValid, edit.owner == owner, edit.conversationId == conversationID,
               !CodeStore.editIsTerminal(turn.editPhase), seenEdits.insert(edit.cid).inserted { result.edits.append(edit) }
            if let receipt = turn.omnix, receipt.isValid, receipt.owner == owner, receipt.conversationId == conversationID,
               receipt.submission != "not_admitted", !completedOmnix.contains(receipt.requestKey),
               seenOmnix.insert(receipt.requestKey).inserted { result.omnix.append(receipt) }
        }
        return result
    }

    /// A read or cancellation failure preserves the project and its recovery receipts.
    static func confirm(_ requests: Requests, isCurrent: () -> Bool,
                        cancelEdit: (CodeEditReceipt) async throws -> Bool,
                        cancelOmnix: (OmnixReceipt) async throws -> Bool) async -> Bool {
        do {
            for receipt in requests.edits {
                guard isCurrent(), try await cancelEdit(receipt), isCurrent() else { return false }
            }
            for receipt in requests.omnix {
                guard isCurrent(), try await cancelOmnix(receipt), isCurrent() else { return false }
            }
            return isCurrent()
        } catch { return false }
    }
}

#if DEBUG
@MainActor
enum CodeDeletionSafetyChecks {
    static func run() async -> [String] {
        let edit = CodeEditReceipt(owner: "owner", conversationId: "project", cid: "turn", baseHash: String(repeating: "a", count: 64))
        let omnix = OmnixReceipt(owner: "owner", conversationId: "project", requestKey: String(repeating: "b", count: 32))
        var editTurn = CodeChatMessage(role: "ai", content: ""); editTurn.edit = edit; editTurn.editPhase = "queued"
        var omnixTurn = CodeChatMessage(role: "ai", content: ""); omnixTurn.omnix = omnix
        var foreign = editTurn; foreign.edit?.owner = "other-owner"
        var completed = editTurn; completed.edit?.cid = "old-turn"; completed.editPhase = "completed"
        var otherProject = omnixTurn; otherProject.omnix?.conversationId = "other-project"
        let requests = CodeDeletionSafety.requests(thread: CodeChatThread(messages: [foreign, completed, editTurn, editTurn, omnixTurn, otherProject]),
            owner: "owner", conversationID: "project", completedOmnix: [])
        var errors: [String] = []
        if requests.edits != [edit] || requests.omnix != [omnix] { errors.append("Code deletion crossed receipt ownership, duplicated a stop, or stopped a completed turn") }
        var calls: [String] = []
        let unresolved = await CodeDeletionSafety.confirm(requests, isCurrent: { true }, cancelEdit: { _ in calls.append("edit"); return false },
            cancelOmnix: { _ in calls.append("omnix"); return true })
        if unresolved || calls != ["edit"] { errors.append("Code deletion discarded a project with an unconfirmed stop") }
        calls = []
        var current = true
        let changed = await CodeDeletionSafety.confirm(requests, isCurrent: { current }, cancelEdit: { _ in calls.append("edit"); current = false; return true },
            cancelOmnix: { _ in calls.append("omnix"); return true })
        if changed || calls != ["edit"] { errors.append("Code deletion continued stopping tasks after an account change") }
        let confirmed = await CodeDeletionSafety.confirm(requests, isCurrent: { true }, cancelEdit: { _ in true }, cancelOmnix: { _ in true })
        if !confirmed { errors.append("Code deletion rejected confirmed owned cancellations") }
        return errors
    }
}
#endif
