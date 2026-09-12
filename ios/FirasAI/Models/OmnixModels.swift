import Foundation
import Perception
/// This receipt, saved on the assistant row before admission, is the authority for recovery.
/// A session is reused only inside its original conversation. There is no automatic session roll.
struct OmnixReceipt: Codable, Sendable, Equatable {
    var owner: String
    var conversationId: String
    var requestKey: String
    var jobId: String = ""
    var sessionId: String = ""
    var submission: String? = nil

    init(owner: String, conversationId: String, requestKey: String, jobId: String = "", sessionId: String = "", submission: String? = nil) {
        self.owner = owner; self.conversationId = conversationId; self.requestKey = requestKey
        self.jobId = jobId; self.sessionId = sessionId; self.submission = submission
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(String.self, forKey: .owner)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        requestKey = try c.decode(String.self, forKey: .requestKey)
        jobId = try c.decodeIfPresent(String.self, forKey: .jobId) ?? ""
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        submission = try c.decodeIfPresent(String.self, forKey: .submission)
    }

    var isValid: Bool {
        !owner.isEmpty && owner.count <= 128 && Self.matches(conversationId, #"^[A-Za-z0-9_-]{1,128}$"#)
        && Self.matches(requestKey, #"^[A-Za-z0-9_-]{16,128}$"#)
        && (jobId.isEmpty || Self.matches(jobId, #"^omxj_[a-f0-9]{32}$"#))
        && (sessionId.isEmpty || Self.matches(sessionId, #"^omxs_[a-f0-9]{32}$"#))
    }
    func accepts(_ job: OmnixJob) -> Bool {
        isValid && job.conversationId == conversationId && job.requestKey == requestKey
        && Self.matches(job.jobId, #"^omxj_[a-f0-9]{32}$"#)
        && Self.matches(job.sessionId, #"^omxs_[a-f0-9]{32}$"#)
        && (jobId.isEmpty || jobId == job.jobId)
        && (sessionId.isEmpty || sessionId == job.sessionId)
    }
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

struct OmnixAccess: Codable, Sendable, Equatable {
    var status: String
    var canRequest: Bool?
    var canUseDesktop: Bool?
}
struct OmnixCloudStatus: Decodable, Sendable { let ready: Bool; let state: String }
struct OmnixConversationJobs: Decodable, Sendable {
    let conversationId: String
    let jobs: [OmnixJob]
    let cancelledRequests: [String]?
}
struct OmnixJob: Codable, Sendable, Equatable {
    let jobId: String
    let sessionId: String
    let conversationId: String
    let requestKey: String
    let state: String
    var createdAt: Double?
    var updatedAt: Double?
    var cancellationRequested: Bool?
    var result: OmnixResult?
    var progress: OmnixProgress?
    var isTerminal: Bool { ["completed", "failed", "cancelled", "canceled", "interrupted"].contains(state) }
    /// Conversation discovery has no result, even for a completed job.
    var needsFullRefresh: Bool { !isTerminal || result == nil || result?.filesStatus == "unavailable" }
    var visibleText: String {
        if let output = result?.output, !output.isEmpty { return output }
        return progress?.says?.joined(separator: "\n\n") ?? ""
    }
}
struct OmnixResult: Codable, Sendable, Equatable {
    var output: String?
    var files: [OmnixFile]?
    var filesStatus: String?
    var approval: OmnixApproval?
}
struct OmnixApproval: Codable, Sendable, Equatable {
    let requestId: String
    let command: String
    let commandComplete: Bool
    let reason: String
    let choices: [String]
}
struct OmnixProgress: Codable, Sendable, Equatable {
    var engine: String?
    var phase: String?
    var state: String?
    var startedAt: Double?
    var plan: [OmnixStep]?
    var says: [String]?
    var events: [OmnixEvent]?
}
struct OmnixStep: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let s: String
    var observed: Bool?
    var inputPreview: String?
    var resultPreview: String?
    var durationMs: Double?
}
struct OmnixEvent: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let kind: String
    var text: String?
}
struct OmnixFile: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    var size: Int?
    var url: String?
    var sha256: String?
    /// Part of the server's workspace-file identity, used to detect a later run's overwrite.
    var modifiedAt: Double?
    var downloadPath: String? {
        guard OmnixReceipt.matches(id, #"^[a-f0-9]{64}$"#),
              let url, url == "/api/omnix/files/" + id else { return nil }
        return url
    }
}
struct OmnixSubmission: Encodable, Sendable {
    let requestKey: String
    let text: String
    let product: String
    let conversationId: String
    let sessionId: String?
    let attachments: [String]?
}
struct OmnixCancelRequest: Encodable, Sendable { let requestKey: String }
struct OmnixCancellation: Decodable, Sendable {
    var requestKey: String?
    var cancelled: Bool?
    var job: OmnixJob?
}
struct OmnixApprovalRequest: Encodable, Sendable { let requestId: String; let choice: String }
struct OmnixAccessRequest: Encodable, Sendable { let reason: String }
struct OmnixEmpty: Codable, Sendable {}
struct OmnixInputReceipt: Decodable, Sendable {
    let id: String
    let requestKey: String
    let name: String
    let mime: String
    let size: Int
    let sha256: String
}

@MainActor @Perceptible
final class OmnixState {
    var owner: String?
    var generation = 0
    var access: OmnixAccess?
    var ready = false
    var jobs: [String: OmnixJob] = [:]
    var notices: [String: String] = [:]
    var approvalBusy: Set<String> = []
    var notified: Set<String> = []
    func reset(owner: String?) {
        self.owner = owner
        generation += 1
        access = nil; ready = false; jobs = [:]; notices = [:]; approvalBusy = []; notified = []
    }
}

enum OmnixCopy {
    static let temporary = LText(ar: "أومنكس يحتاج محادثة محفوظة لمتابعة العمل والملفات. افتح محادثة عادية؛ بقي طلبك هنا.", en: "Omnix needs a saved conversation to follow tasks and files. Open a regular chat; your draft stays here.")
    static let unavailable = LText(ar: "أومنكس غير جاهز لهذا الحساب حاليًا. راجع حالة الوصول.", en: "Omnix is not ready for this account. Check access status.")
    static let checking = LText(ar: "جارٍ تأكيد استلام الطلب…", en: "Confirming delivery…")
    static let reconnect = LText(ar: "تعذّر تحديث الحالة. العمل يستمر في السحابة ونعيد الاتصال تلقائيًا.", en: "Status could not refresh. Work continues in the cloud; reconnecting automatically.")
    static let notStarted = LText(ar: "لم يبدأ هذا الطلب. يمكنك إرساله مجددًا.", en: "This request did not start. You can send it again.")
    static let stopped = LText(ar: "تم إيقاف الطلب.", en: "The request was stopped.")
    static let tooLarge = LText(ar: "الطلب يتجاوز 60,000 حرف أو حدود المرفقات. بقي طلبك هنا.", en: "The request exceeds 60,000 characters or attachment limits. Your draft stays here.")
}
