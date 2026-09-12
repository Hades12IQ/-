import Foundation
import CryptoKit

/// Stored before admission. A lost response resumes by cid, never by submitting again.
struct CodeEditReceipt: Codable, Sendable, Equatable {
    var owner: String
    var conversationId: String
    var cid: String
    var jobId: String = ""
    var baseHash: String

    var isValid: Bool {
        !owner.isEmpty && owner.utf16.count <= 128
        && OmnixReceipt.matches(conversationId, #"^[A-Za-z0-9_-]{1,64}$"#)
        && OmnixReceipt.matches(cid, #"^[A-Za-z0-9_-]{1,64}$"#)
        && OmnixReceipt.matches(baseHash, #"^[a-f0-9]{64}$"#)
        && (jobId.isEmpty || OmnixReceipt.matches(jobId, #"^[A-Za-z0-9_-]{1,100}$"#))
    }
}

@MainActor
enum CodeEditService {
    enum Failure: Error, Equatable {
        case invalidRequest
        case admissionUnconfirmed
        case admissionRejected(Int)
        case invalidReceipt
        case invalidProposal
        case sourceChanged
    }

    struct Request: Encodable, Sendable {
        let kind = "codeedit"
        let product = "code"
        let task: String
        let attach: String
        let baseHash: String
        let cid: String
        let chatId: String
        let tier: String
        let think: Bool
        let lang: String
        let messages: [OutgoingMessage]
        // No nomem flag: this is the user's answer, not an internal helper-model request.
    }

    private struct ReceiptResponse: Decodable, Sendable {
        let jobId: String
        let phase: String
        var cid: String?
        var chatId: String?
    }

    static func request(
        receipt: CodeEditReceipt, task: String, attach: String,
        selection: CodeModelSelection, lang: AppLanguage
    ) throws -> Request {
        guard receipt.isValid, receipt.jobId.isEmpty, selection.model != .omnix,
              !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.utf16.count <= 60_000, attach.utf16.count <= 24_000 else { throw Failure.invalidRequest }
        return Request(task: task, attach: attach, baseHash: receipt.baseHash, cid: receipt.cid,
            chatId: receipt.conversationId, tier: selection.model.rawValue, think: selection.think,
            lang: lang.rawValue, messages: [OutgoingMessage(role: "user", content: task)])
    }

    static func submit(
        receipt: CodeEditReceipt, task: String, attach: String,
        selection: CodeModelSelection, lang: AppLanguage, api: APIClient,
        isCurrent: @MainActor () -> Bool
    ) async throws -> ChatJobStartResponse {
        let request = try request(receipt: receipt, task: task, attach: attach, selection: selection, lang: lang)
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        do {
            let response = try await api.json(.post, "/api/chat/job", body: request,
                budget: .interactive, as: ChatJobStartResponse.self)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            guard validID(response.jobId) else { throw Failure.invalidReceipt }
            return response
        } catch {
            try Task.checkCancellation()
            guard isCurrent(), !(error is CancellationError) else { throw CancellationError() }
            if let failure = error as? APIError, failure.isCancellation { throw CancellationError() }
            if let failure = error as? APIError, let status = failure.status, (400..<500).contains(status), status != 408 {
                throw Failure.admissionRejected(status)
            }
            // Receipt GET also covers an invalid/lost acknowledgement without spending a second run.
            do {
                let recovered = try await recover(receipt: receipt, api: api)
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                guard let recovered else { throw Failure.admissionUnconfirmed }
                return recovered
            } catch {
                try Task.checkCancellation()
                guard isCurrent(), !(error is CancellationError) else { throw CancellationError() }
                // A status read has no authority to say whether the earlier POST was accepted.
                throw Failure.admissionUnconfirmed
            }
        }
    }

    nonisolated static func explicitlyRejected(_ error: Error) -> Bool {
        if case Failure.admissionRejected = error { return true }
        return false
    }

    static func recover(receipt: CodeEditReceipt, api: APIClient) async throws -> ChatJobStartResponse? {
        guard receipt.isValid else { throw Failure.invalidReceipt }
        let response = try await api.json(.get, "/api/chat/job", query: ["cid": receipt.cid],
            budget: .poll, as: ReceiptResponse.self)
        if response.jobId.isEmpty && response.phase == "unknown" { return nil }
        guard validID(response.jobId), response.cid == receipt.cid, response.chatId == receipt.conversationId,
              receipt.jobId.isEmpty || receipt.jobId == response.jobId else { throw Failure.invalidReceipt }
        // This endpoint has no answer body, even when phase is completed. Always read the full job.
        let bytes = try JSONSerialization.data(withJSONObject: ["jobId": response.jobId, "phase": "queued"])
        return try JSONDecoder().decode(ChatJobStartResponse.self, from: bytes)
    }

    static func status(receipt: CodeEditReceipt, api: APIClient) async throws -> ChatJobStatus {
        guard receipt.isValid, !receipt.jobId.isEmpty else { throw Failure.invalidReceipt }
        return try await api.chatJobStatus(id: receipt.jobId)
    }

    /// Matches tools/code-edit.mjs exactly: fixed key order, UTF-16 path sort, UTF-8 SHA-256.
    static func sourceHash(_ source: CodeProject) throws -> String {
        try CodeOmnixImport.validateProject(source)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func quoted(_ value: String) throws -> String {
            guard let string = String(data: try encoder.encode(value), encoding: .utf8) else { throw Failure.invalidRequest }
            return string
        }
        let rows = try source.files.sorted { $0.path.utf16.lexicographicallyPrecedes($1.path.utf16) }.map {
            "{\"path\":" + (try quoted($0.path)) + ",\"content\":" + (try quoted($0.content)) + "}"
        }.joined(separator: ",")
        let json = "{\"name\":" + (try quoted(source.name)) + ",\"files\":[" + rows + "]}"
        return SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Proposal: Decodable {
        struct File: Decodable { let path: String; let content: String }
        let version: Int
        let baseHash: String
        let answer: String
        let summary: String
        let changes: [File]
        let dels: [String]
    }

    static func proposal(text: String, source: CodeProject, expectedBaseHash: String) throws -> CodeEditPlan {
        guard try sourceHash(source) == expectedBaseHash else { throw Failure.sourceChanged }
        guard let fence = FirasFence.firstFence(in: text, including: ["firas-code-edit"]), fence.name == "firas-code-edit",
              fence.body.utf16.count <= 190_000 else { throw Failure.invalidProposal }
        let bytes = Data(fence.body.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == Set(["version", "baseHash", "answer", "summary", "changes", "dels"]),
              let result = try? JSONDecoder().decode(Proposal.self, from: bytes), result.version == 1,
              result.baseHash == expectedBaseHash, result.answer.utf16.count <= 60_000,
              result.summary.utf16.count <= 2_000, result.changes.count <= 30, result.dels.count <= 30,
              Set(result.dels).count == result.dels.count else { throw Failure.invalidProposal }
        let writes = result.changes.map { CodeFile(path: $0.path, content: $0.content) }
        try CodeOmnixImport.validateProject(CodeProject(name: source.name, files: writes))
        guard result.dels.allSatisfy({ path in
            source.files.contains(where: { $0.path == path }) && !writes.contains(where: { $0.path == path })
        }) else { throw Failure.invalidProposal }
        var merged = source.files.filter { !result.dels.contains($0.path) }
        for file in writes {
            if let index = merged.firstIndex(where: { $0.path == file.path }) { merged[index] = file }
            else { merged.append(file) }
        }
        try CodeOmnixImport.validateProject(CodeProject(name: source.name, files: merged))
        let answer = result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty || !summary.isEmpty || !writes.isEmpty || !result.dels.isEmpty else { throw Failure.invalidProposal }
        let prose = answer.isEmpty ? summary : answer + (summary.isEmpty || answer == summary ? "" : "\n\n" + summary)
        return CodeEditPlan(writes: writes.map { CodeFileBlock(path: $0.path, content: $0.content) },
                            deletes: result.dels, prose: prose)
    }

    private static func validID(_ id: String?) -> Bool {
        id.map { OmnixReceipt.matches($0, #"^[A-Za-z0-9_-]{1,100}$"#) } ?? false
    }
}
