import Foundation

/// A message role. Anything the server has not promised decodes as `unknown` rather than throwing.
enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = ChatRole(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .unknown
    }
}

/// Where a row is in its life. Client-only: the server has no notion of delivery.
enum DeliveryStatus: Codable, Sendable, Equatable {
    case delivered
    case sending
    case streaming
    case failed(String)
    case stopped
    case queuedOffline

    var isTerminal: Bool {
        switch self {
        case .delivered, .stopped: return true
        case .failed: return true
        case .sending, .streaming, .queuedOffline: return false
        }
    }

    var isWorking: Bool {
        switch self {
        case .sending, .streaming: return true
        case .delivered, .stopped, .failed, .queuedOffline: return false
        }
    }
}

/// An attachment chip. The server keeps names only (`files[{name ≤200}]`, ≤12) and accepts a bare
/// string, which it wraps.
struct FileChip: Codable, Sendable, Equatable {
    let name: String
    var kind: String?

    init(name: String, kind: String? = nil) {
        self.name = name
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let bare = try? container.decode(String.self) {
            name = bare
            kind = nil
            return
        }
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = LenientJSON.string(container, "name") ?? ""
        kind = LenientJSON.string(container, "kind")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(name, forKey: AnyCodingKey("name"))
        try container.encodeIfPresent(kind, forKey: AnyCodingKey("kind"))
    }
}

/// The link a stronger-model retry keeps back to the answer it replaced.
struct RetryReference: Codable, Sendable, Equatable {
    let cid: String
    let tier: String

    init(cid: String, tier: String) {
        self.cid = cid
        self.tier = tier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        cid = LenientJSON.string(container, "cid") ?? ""
        tier = LenientJSON.string(container, "tier") ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(cid, forKey: AnyCodingKey("cid"))
        try container.encode(tier, forKey: AnyCodingKey("tier"))
    }
}

/// One version of an answer. Kept only when there are at least two (`sanitizeMessages`), max 5.
struct AnswerVersion: Codable, Sendable, Equatable {
    var content: String
    var reasoning: String?
    var tier: String?
    var lang: String?

    init(content: String, reasoning: String? = nil, tier: String? = nil, lang: String? = nil) {
        self.content = content
        self.reasoning = reasoning
        self.tier = tier
        self.lang = lang
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        content = LenientJSON.string(container, "content") ?? ""
        reasoning = LenientJSON.string(container, "reasoning")
        tier = LenientJSON.string(container, "tier")
        lang = LenientJSON.string(container, "lang")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(content, forKey: AnyCodingKey("content"))
        try container.encodeIfPresent(reasoning, forKey: AnyCodingKey("reasoning"))
        try container.encodeIfPresent(tier, forKey: AnyCodingKey("tier"))
        try container.encodeIfPresent(lang, forKey: AnyCodingKey("lang"))
    }
}

/// One row of a conversation.
///
/// The stored fields above the divider are the server's `sanitizeMessages` whitelist; the ones
/// below it are client-only and `MessageSerializer` drops them before anything is written.
/// Encoding writes the whitelist only, so a backup file stays loadable by the web.
struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    /// The client-side identity: `"<role>-<cid>"` when there is a cid, else a fresh UUID.
    ///
    /// The role qualifier is not decoration. A turn's user half and its assistant half share one
    /// `cid` (`user(_:cid:lang:)` and `assistant(cid:…)` are called with the same value, and `cid`
    /// is on the server's persist whitelist), so a bare `id = cid` puts two rows of a reloaded
    /// conversation under one identifier — duplicate ids in a `ForEach`, and one shared
    /// `MarkdownRenderer` cache slot for two different texts.
    let id: String

    /// The identity rule, in one place.
    static func identity(role: ChatRole, cid: String?) -> String {
        guard let cid, !cid.isEmpty else { return UUID().uuidString }
        return role.rawValue + "-" + cid
    }

    var role: ChatRole
    var content: String
    var tier: String?
    var lang: String?
    var reasoning: String?
    var cid: String?
    var files: [FileChip]?
    var imageThumbs: [String]?
    var mode: String?
    var askAnswered: Bool?
    var retryOf: RetryReference?
    var retried: Bool?
    var mergedFrom: String?
    var alts: [AnswerVersion]?
    var altAt: Int?

    // client-only — never persisted, never sent except `images` on the wire
    var images: [String]?
    var fileText: String?
    var intent: String?
    var status: DeliveryStatus

    init(
        id: String? = nil,
        role: ChatRole,
        content: String,
        tier: String? = nil,
        lang: String? = nil,
        reasoning: String? = nil,
        cid: String? = nil,
        files: [FileChip]? = nil,
        imageThumbs: [String]? = nil,
        mode: String? = nil,
        askAnswered: Bool? = nil,
        retryOf: RetryReference? = nil,
        retried: Bool? = nil,
        mergedFrom: String? = nil,
        alts: [AnswerVersion]? = nil,
        altAt: Int? = nil,
        images: [String]? = nil,
        fileText: String? = nil,
        intent: String? = nil,
        status: DeliveryStatus = .delivered
    ) {
        self.id = id ?? ChatMessage.identity(role: role, cid: cid)
        self.role = role
        self.content = content
        self.tier = tier
        self.lang = lang
        self.reasoning = reasoning
        self.cid = cid
        self.files = files
        self.imageThumbs = imageThumbs
        self.mode = mode
        self.askAnswered = askAnswered
        self.retryOf = retryOf
        self.retried = retried
        self.mergedFrom = mergedFrom
        self.alts = alts
        self.altAt = altAt
        self.images = images
        self.fileText = fileText
        self.intent = intent
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        if let raw = LenientJSON.string(container, "role") {
            role = ChatRole(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .unknown
        } else {
            role = .user
        }
        content = LenientJSON.string(container, "content") ?? ""
        tier = LenientJSON.string(container, "tier")
        lang = LenientJSON.string(container, "lang")
        reasoning = LenientJSON.string(container, "reasoning")
        let decodedCID = LenientJSON.string(container, "cid")
        cid = decodedCID
        files = LenientJSON.array(container, "files", of: FileChip.self)
        imageThumbs = LenientJSON.array(container, "imageThumbs", of: String.self)
        mode = LenientJSON.string(container, "mode")
        askAnswered = LenientJSON.bool(container, "askAnswered")
        retryOf = LenientJSON.nested(container, "retryOf", as: RetryReference.self)
        retried = LenientJSON.bool(container, "retried")
        mergedFrom = LenientJSON.string(container, "mergedFrom")
        alts = LenientJSON.array(container, "alts", of: AnswerVersion.self)
        altAt = LenientJSON.int(container, "altAt")
        images = nil
        fileText = nil
        intent = nil
        status = .delivered

        id = ChatMessage.identity(role: role, cid: decodedCID)
    }

    /// Writes the `sanitizeMessages` whitelist and nothing else.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(role.rawValue, forKey: AnyCodingKey("role"))
        try container.encode(content, forKey: AnyCodingKey("content"))
        try container.encodeIfPresent(tier, forKey: AnyCodingKey("tier"))
        try container.encodeIfPresent(lang, forKey: AnyCodingKey("lang"))
        try container.encodeIfPresent(reasoning, forKey: AnyCodingKey("reasoning"))
        try container.encodeIfPresent(cid, forKey: AnyCodingKey("cid"))
        try container.encodeIfPresent(files, forKey: AnyCodingKey("files"))
        try container.encodeIfPresent(imageThumbs, forKey: AnyCodingKey("imageThumbs"))
        try container.encodeIfPresent(mode, forKey: AnyCodingKey("mode"))
        try container.encodeIfPresent(askAnswered, forKey: AnyCodingKey("askAnswered"))
        try container.encodeIfPresent(retryOf, forKey: AnyCodingKey("retryOf"))
        try container.encodeIfPresent(retried, forKey: AnyCodingKey("retried"))
        try container.encodeIfPresent(mergedFrom, forKey: AnyCodingKey("mergedFrom"))
        try container.encodeIfPresent(alts, forKey: AnyCodingKey("alts"))
        try container.encodeIfPresent(altAt, forKey: AnyCodingKey("altAt"))
    }

    /// The answer text actually on screen — the selected version when there are alternatives.
    var visibleContent: String {
        guard let alts, alts.count > 1 else { return content }
        let index = min(max(altAt ?? alts.count - 1, 0), alts.count - 1)
        return alts[index].content
    }

    static func user(_ content: String, cid: String, lang: AppLanguage) -> ChatMessage {
        ChatMessage(
            role: .user,
            content: content,
            lang: lang.rawValue,
            cid: cid,
            status: .sending
        )
    }

    static func assistant(cid: String, tier: ModelTier, lang: AppLanguage, mode: ResponseMode) -> ChatMessage {
        ChatMessage(
            role: .assistant,
            content: "",
            tier: tier.rawValue,
            lang: lang.rawValue,
            cid: cid,
            mode: mode == .plan ? "plan" : "auto",
            status: .streaming
        )
    }
}

/// A row of `GET /api/chats` — no messages, no `createdAt`.
struct ChatSummary: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var title: String
    var updatedAt: String
    var createdAt: String?
    var pinned: Bool
    var agent: Bool
    var codeProj: Bool
    var brainNb: Bool
    /// Local only — the sidebar shows it once the messages have been loaded.
    var messageCount: Int?

    init(
        id: String,
        title: String = "",
        updatedAt: String = "",
        createdAt: String? = nil,
        pinned: Bool = false,
        agent: Bool = false,
        codeProj: Bool = false,
        brainNb: Bool = false,
        messageCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.pinned = pinned
        self.agent = agent
        self.codeProj = codeProj
        self.brainNb = brainNb
        self.messageCount = messageCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = LenientJSON.string(container, "id") ?? ""
        title = LenientJSON.string(container, "title") ?? ""
        updatedAt = LenientJSON.string(container, "updatedAt") ?? ""
        createdAt = LenientJSON.string(container, "createdAt")
        pinned = LenientJSON.bool(container, "pinned") ?? false
        agent = LenientJSON.bool(container, "agent") ?? false
        codeProj = LenientJSON.bool(container, "codeProj") ?? false
        brainNb = LenientJSON.bool(container, "brainNb") ?? false
        messageCount = LenientJSON.int(container, "messageCount")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(title, forKey: AnyCodingKey("title"))
        try container.encode(updatedAt, forKey: AnyCodingKey("updatedAt"))
        try container.encodeIfPresent(createdAt, forKey: AnyCodingKey("createdAt"))
        try container.encode(pinned, forKey: AnyCodingKey("pinned"))
        try container.encode(agent, forKey: AnyCodingKey("agent"))
        try container.encode(codeProj, forKey: AnyCodingKey("codeProj"))
        try container.encode(brainNb, forKey: AnyCodingKey("brainNb"))
        try container.encodeIfPresent(messageCount, forKey: AnyCodingKey("messageCount"))
    }

    /// The product is the trio of booleans, set only at creation.
    var product: ProductKind {
        if agent { return .agent }
        if codeProj { return .code }
        if brainNb { return .brain }
        return .ai
    }
}

/// A whole conversation. Members carry the server id in `id`; guests keep an `ios_…` local id and
/// leave `serverID` nil.
struct ChatConversation: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var serverID: String?
    var title: String
    var messages: [ChatMessage]
    var pinned: Bool
    var agent: Bool
    var codeProj: Bool
    var brainNb: Bool
    var createdAt: String?
    var updatedAt: String?
    /// Client-only: the response mode snapshotted when a plan cycle started.
    var planSnapshotMode: ResponseMode?
    /// Client-only: the temporary ("incognito") conversation the web calls `chat.ephemeral`.
    ///
    /// Read once, when the conversation is minted, and never again: a chat that began as
    /// temporary stays temporary for as long as it exists, because the alternative is a record
    /// that becomes saveable retroactively. Six independent refusals are what make "never
    /// written" true everywhere rather than true where somebody remembered — `persist`,
    /// `persistLocalOnly`, `ensureServerChat`, `autoTitleIfNeeded`, `rebuildSummaries` and the
    /// durable job path each check it on their own, and `SendPipeline` keeps the question out of
    /// long-term memory. It is deliberately **not encoded**: a mode whose whole claim is that
    /// nothing survives the session cannot be the one thing that survives it.
    var ephemeral: Bool = false

    init(
        id: String,
        serverID: String? = nil,
        title: String = "",
        messages: [ChatMessage] = [],
        pinned: Bool = false,
        agent: Bool = false,
        codeProj: Bool = false,
        brainNb: Bool = false,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        planSnapshotMode: ResponseMode? = nil,
        ephemeral: Bool = false
    ) {
        self.id = id
        self.serverID = serverID
        self.title = title
        self.messages = messages
        self.pinned = pinned
        self.agent = agent
        self.codeProj = codeProj
        self.brainNb = brainNb
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.planSnapshotMode = planSnapshotMode
        self.ephemeral = ephemeral
    }

    init(from decoder: Decoder) throws {
        // `ephemeral` is not read here on purpose: nothing that came back from disk or from the
        // server can be a temporary conversation, so it keeps its `false` default.
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = LenientJSON.string(container, "id") ?? ""
        serverID = LenientJSON.string(container, "serverID")
        title = LenientJSON.string(container, "title") ?? ""
        messages = LenientJSON.array(container, "messages", of: ChatMessage.self) ?? []
        pinned = LenientJSON.bool(container, "pinned") ?? false
        agent = LenientJSON.bool(container, "agent") ?? false
        codeProj = LenientJSON.bool(container, "codeProj") ?? false
        brainNb = LenientJSON.bool(container, "brainNb") ?? false
        createdAt = LenientJSON.string(container, "createdAt")
        updatedAt = LenientJSON.string(container, "updatedAt")
        if let raw = LenientJSON.string(container, "planSnapshotMode") {
            planSnapshotMode = ResponseMode(rawValue: raw)
        } else {
            planSnapshotMode = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encodeIfPresent(serverID, forKey: AnyCodingKey("serverID"))
        try container.encode(title, forKey: AnyCodingKey("title"))
        try container.encode(messages, forKey: AnyCodingKey("messages"))
        try container.encode(pinned, forKey: AnyCodingKey("pinned"))
        try container.encode(agent, forKey: AnyCodingKey("agent"))
        try container.encode(codeProj, forKey: AnyCodingKey("codeProj"))
        try container.encode(brainNb, forKey: AnyCodingKey("brainNb"))
        try container.encodeIfPresent(createdAt, forKey: AnyCodingKey("createdAt"))
        try container.encodeIfPresent(updatedAt, forKey: AnyCodingKey("updatedAt"))
        try container.encodeIfPresent(planSnapshotMode?.rawValue, forKey: AnyCodingKey("planSnapshotMode"))
    }

    var product: ProductKind {
        if agent { return .agent }
        if codeProj { return .code }
        if brainNb { return .brain }
        return .ai
    }

    /// A summary row for the sidebar, built from what is already loaded.
    var summary: ChatSummary {
        ChatSummary(
            id: id,
            title: title,
            updatedAt: updatedAt ?? "",
            createdAt: createdAt,
            pinned: pinned,
            agent: agent,
            codeProj: codeProj,
            brainNb: brainNb,
            messageCount: messages.count
        )
    }
}

/// `POST /api/chats`. `id` rides on the wire as `clientId`: a deterministic `c_<clientId>` id, so
/// a repeated create is safe — the migration of a guest's local chats depends on it.
struct CreateChatRequest: Encodable, Sendable {
    var title: String
    var messages: [PersistedMessage]
    var agent: Bool?
    var codeProj: Bool?
    var brainNb: Bool?
    var id: String?

    init(
        title: String,
        messages: [PersistedMessage],
        agent: Bool? = nil,
        codeProj: Bool? = nil,
        brainNb: Bool? = nil,
        id: String? = nil
    ) {
        self.title = title
        self.messages = messages
        self.agent = agent
        self.codeProj = codeProj
        self.brainNb = brainNb
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case messages
        case agent
        case codeProj
        case brainNb
        case id = "clientId"
    }
}

/// `PUT /api/chats/:id` — a merge of top-level keys and a full replacement of `messages`. Omit a
/// key to leave it untouched; sending an empty `messages` array erases the conversation.
struct UpdateChatRequest: Encodable, Sendable {
    var title: String?
    var messages: [PersistedMessage]?
    var pinned: Bool?

    init(title: String? = nil, messages: [PersistedMessage]? = nil, pinned: Bool? = nil) {
        self.title = title
        self.messages = messages
        self.pinned = pinned
    }
}
