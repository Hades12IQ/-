import Foundation

nonisolated enum ChatRole: String, Codable, Equatable, Sendable {
    case system
    case user
    case assistant
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = ChatRole(rawValue: value) ?? .unknown
    }
}

nonisolated enum ChatMessageState: String, Codable, Equatable, Sendable {
    case sending
    case delivered
    case failed
    case stopped
}

nonisolated struct ChatAttachment: Codable, Equatable, Sendable {
    let name: String
    let kind: String?

    init(name: String, kind: String? = nil) {
        self.name = name
        self.kind = kind
    }
}

nonisolated struct RetryReference: Codable, Equatable, Sendable {
    let cid: String
    let tier: String
}

nonisolated struct AnswerVersion: Codable, Equatable, Sendable {
    let content: String
    let reasoning: String?
    let tier: String?
    let lang: String?
}

nonisolated struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var role: ChatRole
    var content: String
    var tier: String?
    var lang: String?
    var files: [ChatAttachment]?
    var askAnswered: Bool?
    var cid: String?
    var retryOf: RetryReference?
    var retried: Bool?
    var mode: String?
    var mergedFrom: String?
    var reasoning: String?
    var images: [String]?
    var imageThumbs: [String]?
    var fileText: String?
    var alts: [AnswerVersion]?
    var altAt: Int?
    var state: ChatMessageState

    init(
        id: String = UUID().uuidString,
        role: ChatRole,
        content: String,
        tier: String? = nil,
        lang: String? = nil,
        files: [ChatAttachment]? = nil,
        askAnswered: Bool? = nil,
        cid: String? = nil,
        retryOf: RetryReference? = nil,
        retried: Bool? = nil,
        mode: String? = nil,
        mergedFrom: String? = nil,
        reasoning: String? = nil,
        images: [String]? = nil,
        imageThumbs: [String]? = nil,
        fileText: String? = nil,
        alts: [AnswerVersion]? = nil,
        altAt: Int? = nil,
        state: ChatMessageState = .delivered
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.tier = tier
        self.lang = lang
        self.files = files
        self.askAnswered = askAnswered
        self.cid = cid
        self.retryOf = retryOf
        self.retried = retried
        self.mode = mode
        self.mergedFrom = mergedFrom
        self.reasoning = reasoning
        self.images = images
        self.imageThumbs = imageThumbs
        self.fileText = fileText
        self.alts = alts
        self.altAt = altAt
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case tier
        case lang
        case files
        case askAnswered
        case cid
        case retryOf
        case retried
        case mode
        case mergedFrom
        case reasoning
        case images
        case imageThumbs
        case fileText
        case alts
        case altAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(ChatRole.self, forKey: .role) ?? .user
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        tier = try container.decodeIfPresent(String.self, forKey: .tier)
        lang = try container.decodeIfPresent(String.self, forKey: .lang)
        files = try container.decodeIfPresent([ChatAttachment].self, forKey: .files)
        askAnswered = try container.decodeIfPresent(Bool.self, forKey: .askAnswered)
        cid = try container.decodeIfPresent(String.self, forKey: .cid)
        retryOf = try container.decodeIfPresent(RetryReference.self, forKey: .retryOf)
        retried = try container.decodeIfPresent(Bool.self, forKey: .retried)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        mergedFrom = try container.decodeIfPresent(String.self, forKey: .mergedFrom)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        images = try container.decodeIfPresent([String].self, forKey: .images)
        imageThumbs = try container.decodeIfPresent([String].self, forKey: .imageThumbs)
        fileText = try container.decodeIfPresent(String.self, forKey: .fileText)
        alts = try container.decodeIfPresent([AnswerVersion].self, forKey: .alts)
        altAt = try container.decodeIfPresent(Int.self, forKey: .altAt)
        // A persisted turn may use the same cid for its user and assistant
        // halves. Include the role so SwiftUI never receives duplicate row
        // identities after a conversation is decoded again.
        id = cid.map { "message-\(role.rawValue)-\($0)" } ?? UUID().uuidString
        state = .delivered
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(tier, forKey: .tier)
        try container.encodeIfPresent(lang, forKey: .lang)
        try container.encodeIfPresent(files, forKey: .files)
        try container.encodeIfPresent(askAnswered, forKey: .askAnswered)
        try container.encodeIfPresent(cid, forKey: .cid)
        try container.encodeIfPresent(retryOf, forKey: .retryOf)
        try container.encodeIfPresent(retried, forKey: .retried)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encodeIfPresent(mergedFrom, forKey: .mergedFrom)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(images, forKey: .images)
        try container.encodeIfPresent(imageThumbs, forKey: .imageThumbs)
        try container.encodeIfPresent(fileText, forKey: .fileText)
        try container.encodeIfPresent(alts, forKey: .alts)
        try container.encodeIfPresent(altAt, forKey: .altAt)
    }
}

nonisolated struct ChatSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    let updatedAt: String
    let pinned: Bool
    let agent: Bool
    let codeProj: Bool
    let brainNb: Bool
}

nonisolated struct ChatConversation: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var messages: [ChatMessage]
}

nonisolated struct CreateChatRequest: Encodable, Equatable, Sendable {
    let clientId: String
    let title: String
    let messages: [ChatMessage]
    let pinned: Bool
    let agent: Bool
    let codeProj: Bool
    let brainNb: Bool
}

nonisolated struct CreateChatResponse: Decodable, Equatable, Sendable {
    let id: String
    let title: String
    let createdAt: String
    let updatedAt: String
}

nonisolated struct UpdateChatRequest: Encodable, Equatable, Sendable {
    let title: String?
    let messages: [ChatMessage]?
    let pinned: Bool?
}

nonisolated enum ChatJobKind: String, Codable, Equatable, Sendable {
    case chat
    case longDocument = "longdoc"
    case longFile = "longfile"
    case agentRun = "agentrun"
    case codeBuild = "codebuild"
    case brainAsk = "brainask"
}

nonisolated enum ChatJobPhase: String, Codable, Equatable, Sendable {
    case queued
    case processing
    case completed
    case done
    case failed
    case fail
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = ChatJobPhase(rawValue: value) ?? .unknown
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .done, .failed, .fail:
            true
        case .queued, .processing, .unknown:
            false
        }
    }

    var succeeded: Bool { self == .completed || self == .done }
}

nonisolated struct ChatJobRequest: Encodable, Equatable, Sendable {
    let messages: [ChatMessage]
    let tier: String
    let think: Bool
    let cid: String
    let product: ProductKind
    let chatId: String
    let kind: ChatJobKind?
    let lang: String?
    let nokb: Bool?
    let task: String?
    let title: String?
    let name: String?
    let attach: String?
    let format: String?
    let pages: Int?
    let targetPages: Int?
    let prompt: String?
    let sections: Int?

    init(
        messages: [ChatMessage],
        tier: ModelTier,
        thinking: Bool,
        cid: String,
        product: ProductKind,
        chatId: String = "",
        kind: ChatJobKind? = nil,
        languageCode: String? = nil,
        nokb: Bool? = nil,
        task: String? = nil,
        title: String? = nil,
        name: String? = nil,
        attach: String? = nil,
        format: String? = nil,
        pages: Int? = nil,
        targetPages: Int? = nil,
        prompt: String? = nil,
        sections: Int? = nil
    ) {
        self.messages = messages
        self.tier = tier.rawValue
        think = thinking
        self.cid = cid
        self.product = product
        self.chatId = chatId
        self.kind = kind
        lang = languageCode
        self.nokb = nokb
        self.task = task
        self.title = title
        self.name = name
        self.attach = attach
        self.format = format
        self.pages = pages
        self.targetPages = targetPages
        self.prompt = prompt
        self.sections = sections
    }
}

nonisolated struct ChatJobProgress: Decodable, Equatable, Sendable {
    let stage: String?
    let pagesDone: Int?
    let pagesTotal: Int?
    let targetPages: Int?
    let bodyPagesDone: Int?
    let bodyPagesTotal: Int?
    let coverPages: Int?
    let currentPage: Int?
    let currentTitle: String?
    let partsDone: Int?
    let partsTotal: Int?
    let percent: Double?
    let resumeAvailable: Bool?
    let complete: Bool?
    let cancelled: Bool?
}

nonisolated struct ChatJobStartResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let jobId: String
    let phase: ChatJobPhase
    let text: String?
    let reasoning: String?
    let surface: AppAPIValue?
    let progress: ChatJobProgress?
    let error: String?
    let retryRequiresNewCid: Bool?
}

nonisolated struct ChatJobStatus: Decodable, Equatable, Sendable {
    let phase: ChatJobPhase
    let text: String?
    let reasoning: String?
    let error: String?
    let status: Int?
    let surface: AppAPIValue?
    let progress: ChatJobProgress?
}

nonisolated struct CancelChatJobRequest: Encodable, Equatable, Sendable {
    let id: String
}

nonisolated struct CancelChatJobResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let stopped: Bool
}

nonisolated struct UsageChargeRequest: Encodable, Equatable, Sendable {
    let product: ProductKind
    let cid: String
}

nonisolated struct UsageChargeResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let sub: Subscription
}

nonisolated struct WebSearchResult: Decodable, Equatable, Sendable {
    let title: String
    let url: String
    let snippet: String
}

nonisolated struct WebSearchResponse: Decodable, Equatable, Sendable {
    let q: String
    let results: [WebSearchResult]
    let via: String
}
