import Foundation

/// Every kind of work that outlives the screen that started it.
///
/// The first six ride the chat queue (`POST /api/chat/job`); the last three are the media queues.
enum JobKind: String, Codable, Sendable, CaseIterable {
    case chat
    case longdoc
    case longfile
    case agentrun
    case codebuild
    case brainask
    case image
    case video
    case music

    /// Which product's screen the result lands on.
    var product: ProductKind {
        switch self {
        case .chat, .longdoc, .longfile: return .ai
        case .agentrun: return .agent
        case .codebuild: return .code
        case .brainask: return .brain
        case .image, .video, .music: return .studio
        }
    }

    /// True when the job is started and polled through `/api/chat/job`.
    var isChatQueue: Bool {
        switch self {
        case .chat, .longdoc, .longfile, .agentrun, .codebuild, .brainask: return true
        case .image, .video, .music: return false
        }
    }

    var mediaKind: MediaKind? {
        switch self {
        case .image: return .image
        case .video: return .video
        case .music: return .music
        case .chat, .longdoc, .longfile, .agentrun, .codebuild, .brainask: return nil
        }
    }

    /// The `product` string that goes on the wire for this kind — media always sends `"ai"`.
    var wireProduct: String { product.wireValue }
}

/// One vocabulary for the phases of every queue. The media queues say `done`/`fail`, the chat
/// queue says `completed`/`failed`, the agent view says `run`; `init(raw:)` folds them together.
enum JobPhase: String, Codable, Sendable {
    case queued
    case processing
    case completed
    case failed
    case unknown
    /// The client's own terminal state when a deadline passes.
    case expired
    /// The client's own state while a watcher is retrying a dead connection.
    case reconnecting

    init(raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "queued", "pending": self = .queued
        case "processing", "run", "running", "exec": self = .processing
        case "completed", "done", "complete", "ok": self = .completed
        case "failed", "fail", "error", "stopped", "cancelled", "canceled": self = .failed
        case "expired": self = .expired
        case "reconnecting": self = .reconnecting
        default: self = .unknown
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(raw: (try? container.decode(String.self)) ?? "")
    }

    /// A phase the watcher must stop on. `unknown` is deliberately not terminal here — how many
    /// unknown reads a kind tolerates is `JobKindSpec.unknownReadsBeforeTerminal`.
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .expired: return true
        case .queued, .processing, .unknown, .reconnecting: return false
        }
    }

    var isLive: Bool {
        switch self {
        case .queued, .processing, .reconnecting: return true
        case .completed, .failed, .expired, .unknown: return false
        }
    }
}

/// The on-disk record of one live job. Forty of these at most, per owner, in `jobs.json`.
///
/// Dates are encoded as `timeIntervalSince1970` by hand so no `JSONDecoder` date strategy is ever
/// needed and a file written by an older build still reads.
struct JobPointer: Codable, Sendable, Equatable, Identifiable {
    /// The server job id; for media it is the hex cache key the start returned.
    let id: String
    let kind: JobKind
    /// Which identity started it — a pointer belonging to another owner is suspended, not polled.
    let ownerID: String
    /// The turn id. Restarting with the same cid is idempotent on the server.
    let cid: String

    var conversationID: String
    var serverChatID: String?
    var assistantMessageID: String?
    var projectID: String?
    var creationID: String?

    var title: String
    var lang: String

    let startedAt: Date
    var deadline: Date

    var lastPhase: JobPhase
    var cancelRequested: Bool
    var notified: Bool
    /// How much of `text` has already been published, so a resumed watcher does not replay it.
    var lastTextCount: Int

    init(
        id: String,
        kind: JobKind,
        ownerID: String,
        cid: String,
        conversationID: String,
        serverChatID: String? = nil,
        assistantMessageID: String? = nil,
        projectID: String? = nil,
        creationID: String? = nil,
        title: String = "",
        lang: String = "ar",
        startedAt: Date = Date(),
        deadline: Date,
        lastPhase: JobPhase = .queued,
        cancelRequested: Bool = false,
        notified: Bool = false,
        lastTextCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.ownerID = ownerID
        self.cid = cid
        self.conversationID = conversationID
        self.serverChatID = serverChatID
        self.assistantMessageID = assistantMessageID
        self.projectID = projectID
        self.creationID = creationID
        self.title = title
        self.lang = lang
        self.startedAt = startedAt
        self.deadline = deadline
        self.lastPhase = lastPhase
        self.cancelRequested = cancelRequested
        self.notified = notified
        self.lastTextCount = lastTextCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = LenientJSON.string(container, "id") ?? ""
        kind = JobKind(rawValue: LenientJSON.string(container, "kind") ?? "") ?? .chat
        ownerID = LenientJSON.string(container, "ownerID") ?? ""
        cid = LenientJSON.string(container, "cid") ?? ""
        conversationID = LenientJSON.string(container, "conversationID") ?? ""
        serverChatID = LenientJSON.string(container, "serverChatID")
        assistantMessageID = LenientJSON.string(container, "assistantMessageID")
        projectID = LenientJSON.string(container, "projectID")
        creationID = LenientJSON.string(container, "creationID")
        title = LenientJSON.string(container, "title") ?? ""
        lang = LenientJSON.string(container, "lang") ?? "ar"
        startedAt = Date(timeIntervalSince1970: LenientJSON.double(container, "startedAt") ?? 0)
        deadline = Date(timeIntervalSince1970: LenientJSON.double(container, "deadline") ?? 0)
        lastPhase = JobPhase(raw: LenientJSON.string(container, "lastPhase") ?? "")
        cancelRequested = LenientJSON.bool(container, "cancelRequested") ?? false
        notified = LenientJSON.bool(container, "notified") ?? false
        lastTextCount = LenientJSON.int(container, "lastTextCount") ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(kind.rawValue, forKey: AnyCodingKey("kind"))
        try container.encode(ownerID, forKey: AnyCodingKey("ownerID"))
        try container.encode(cid, forKey: AnyCodingKey("cid"))
        try container.encode(conversationID, forKey: AnyCodingKey("conversationID"))
        try container.encodeIfPresent(serverChatID, forKey: AnyCodingKey("serverChatID"))
        try container.encodeIfPresent(assistantMessageID, forKey: AnyCodingKey("assistantMessageID"))
        try container.encodeIfPresent(projectID, forKey: AnyCodingKey("projectID"))
        try container.encodeIfPresent(creationID, forKey: AnyCodingKey("creationID"))
        try container.encode(title, forKey: AnyCodingKey("title"))
        try container.encode(lang, forKey: AnyCodingKey("lang"))
        try container.encode(startedAt.timeIntervalSince1970, forKey: AnyCodingKey("startedAt"))
        try container.encode(deadline.timeIntervalSince1970, forKey: AnyCodingKey("deadline"))
        try container.encode(lastPhase.rawValue, forKey: AnyCodingKey("lastPhase"))
        try container.encode(cancelRequested, forKey: AnyCodingKey("cancelRequested"))
        try container.encode(notified, forKey: AnyCodingKey("notified"))
        try container.encode(lastTextCount, forKey: AnyCodingKey("lastTextCount"))
    }

    /// The notification thread id the server would use, capped at the APNs limit.
    var threadID: String {
        let scope = serverChatID ?? (conversationID.isEmpty ? id : conversationID)
        let base = "firas-" + kind.product.wireValue + "-" + scope
        return String(base.prefix(64))
    }

    var isExpired: Bool { Date() >= deadline }
}

/// One read of a live job, normalised across the queues.
struct JobSnapshot: Sendable, Equatable {
    let pointerID: String
    let phase: JobPhase
    let text: String
    let reasoning: String
    let progress: LongFileProgress?
    let surface: AppAPIValue?
    let agent: AgentJob?
    /// The media cache key, once the bytes exist.
    let mediaKey: String?

    init(
        pointerID: String,
        phase: JobPhase,
        text: String = "",
        reasoning: String = "",
        progress: LongFileProgress? = nil,
        surface: AppAPIValue? = nil,
        agent: AgentJob? = nil,
        mediaKey: String? = nil
    ) {
        self.pointerID = pointerID
        self.phase = phase
        self.text = text
        self.reasoning = reasoning
        self.progress = progress
        self.surface = surface
        self.agent = agent
        self.mediaKey = mediaKey
    }
}

/// How a job ended. `refused` carries the server's own refusal so it takes the same
/// `ErrorPresenter` path as a live 429.
enum JobTerminal: Sendable, Equatable {
    case completed(JobSnapshot)
    case refused(status: Int, error: ServerError)
    case failed(code: String, partial: JobSnapshot?)
    case cancelled
    /// Deadline reached, N unknown reads, or `{job:null}` twice.
    case expired
    case unauthorized
    case forbidden

    var isSuccess: Bool {
        if case .completed = self { return true }
        return false
    }

    /// The snapshot the store should land, when there is one.
    var snapshot: JobSnapshot? {
        switch self {
        case .completed(let snapshot): return snapshot
        case .failed(_, let partial): return partial
        case .refused, .cancelled, .expired, .unauthorized, .forbidden: return nil
        }
    }
}

/// The result of one driver read.
enum DriverRead: Sendable {
    case running(JobSnapshot)
    case terminal(JobTerminal)
    /// The id has no record right now — the caller counts these against
    /// `JobKindSpec.unknownReadsBeforeTerminal`.
    case unknown
}

/// The polling recipe for one kind (`ARCHITECTURE.md §2.4`).
struct JobKindSpec: Sendable {
    let kind: JobKind
    /// The foreground ladder: from `after` seconds since start, poll every `interval` seconds.
    let cadence: [(after: TimeInterval, interval: TimeInterval)]
    let backgroundInterval: TimeInterval
    let deadline: TimeInterval
    let cancelable: Bool
    /// chat 3, codebuild/brainask 1, agentrun 2 (`{job:null}`).
    let unknownReadsBeforeTerminal: Int
    let usesSSE: Bool

    init(
        kind: JobKind,
        cadence: [(after: TimeInterval, interval: TimeInterval)],
        backgroundInterval: TimeInterval,
        deadline: TimeInterval,
        cancelable: Bool,
        unknownReadsBeforeTerminal: Int,
        usesSSE: Bool
    ) {
        self.kind = kind
        self.cadence = cadence
        self.backgroundInterval = backgroundInterval
        self.deadline = deadline
        self.cancelable = cancelable
        self.unknownReadsBeforeTerminal = unknownReadsBeforeTerminal
        self.usesSSE = usesSSE
    }

    /// The interval to use `elapsed` seconds into the job.
    func interval(elapsed: TimeInterval, inBackground: Bool) -> TimeInterval {
        if inBackground { return backgroundInterval }
        var chosen = cadence.first?.interval ?? 2
        for step in cadence where elapsed >= step.after {
            chosen = step.interval
        }
        return chosen
    }
}
