import Foundation

/// What actually leaves the device in a `messages` array. The server reads `role`, `content` and
/// `images` and nothing else (`server-chat-jobs-chats.md §1.2`).
struct OutgoingMessage: Encodable, Sendable, Equatable {
    let role: String
    let content: String
    /// Raw base64, no data-URL prefix, at most 10 across the whole request, last user turn only.
    let images: [String]?

    init(role: String, content: String, images: [String]? = nil) {
        self.role = role
        self.content = content
        self.images = images
    }
}

/// Exactly the `sanitizeMessages` whitelist — the only fields that survive a write to `/api/chats`
/// (`server-chat-jobs-chats.md §5.2`). Nothing else may be added here: `images`, `fileText`,
/// `intent`, `ts` and `think` are dropped by the server anyway.
struct PersistedMessage: Codable, Sendable, Equatable {
    var role: String
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

    init(
        role: String,
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
        altAt: Int? = nil
    ) {
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        role = LenientJSON.string(container, "role") ?? "user"
        content = LenientJSON.string(container, "content") ?? ""
        tier = LenientJSON.string(container, "tier")
        lang = LenientJSON.string(container, "lang")
        reasoning = LenientJSON.string(container, "reasoning")
        cid = LenientJSON.string(container, "cid")
        files = LenientJSON.array(container, "files", of: FileChip.self)
        imageThumbs = LenientJSON.array(container, "imageThumbs", of: String.self)
        mode = LenientJSON.string(container, "mode")
        askAnswered = LenientJSON.bool(container, "askAnswered")
        retryOf = LenientJSON.nested(container, "retryOf", as: RetryReference.self)
        retried = LenientJSON.bool(container, "retried")
        mergedFrom = LenientJSON.string(container, "mergedFrom")
        alts = LenientJSON.array(container, "alts", of: AnswerVersion.self)
        altAt = LenientJSON.int(container, "altAt")
    }
}

/// `POST /api/chat` — the live SSE turn.
struct ChatStreamRequest: Encodable, Sendable {
    var messages: [OutgoingMessage]
    var tier: String
    var think: Bool
    var cid: String
    var chatId: String?
    var product: String
    var nomem: Bool?
    var nokb: Bool?
    var agent: Bool?

    init(
        messages: [OutgoingMessage],
        tier: String,
        think: Bool,
        cid: String,
        chatId: String? = nil,
        product: String,
        nomem: Bool? = nil,
        nokb: Bool? = nil,
        agent: Bool? = nil
    ) {
        self.messages = messages
        self.tier = tier
        self.think = think
        self.cid = cid
        self.chatId = chatId
        self.product = product
        self.nomem = nomem
        self.nokb = nokb
        self.agent = agent
    }
}

/// `POST /api/chat/job` — every chat-queue kind (`chat`, `longdoc`, `longfile`, `agentrun`,
/// `codebuild`, `brainask`). Fields the kind does not use stay nil and are never encoded.
struct ChatJobRequest: Encodable, Sendable {
    var messages: [OutgoingMessage]
    var tier: String
    var think: Bool
    var cid: String
    /// `""` for guests and for `codebuild`; a server chat id otherwise.
    var chatId: String
    var product: String
    /// `JobKind.rawValue`.
    var kind: String
    var lang: String
    var title: String?
    var task: String?
    /// `longdoc` only, 3…120.
    var sections: Int?
    // longfile
    var format: String?
    var pages: Int?
    var targetPages: Int?
    var prompt: String?
    /// Internal Code helpers omit personal memory and use the helper-model route.
    var nomem: Bool?
    var nokb: Bool?
    var agent: Bool?

    init(
        messages: [OutgoingMessage],
        tier: String,
        think: Bool,
        cid: String,
        chatId: String,
        product: String,
        kind: String,
        lang: String,
        title: String? = nil,
        task: String? = nil,
        sections: Int? = nil,
        format: String? = nil,
        pages: Int? = nil,
        targetPages: Int? = nil,
        prompt: String? = nil,
        nomem: Bool? = nil,
        nokb: Bool? = nil,
        agent: Bool? = nil
    ) {
        self.messages = messages
        self.tier = tier
        self.think = think
        self.cid = cid
        self.chatId = chatId
        self.product = product
        self.kind = kind
        self.lang = lang
        self.title = title
        self.task = task
        self.sections = sections
        self.format = format
        self.pages = pages
        self.targetPages = targetPages
        self.prompt = prompt
        self.nomem = nomem
        self.nokb = nokb
        self.agent = agent
    }
}

/// The answer to a job start. A replayed start with the same cid answers `completed` (with the
/// whole text) or `failed` + `retryRequiresNewCid`.
struct ChatJobStartResponse: Decodable, Sendable {
    var ok: Bool?
    var jobId: String?
    var phase: String?
    var text: String?
    var reasoning: String?
    var surface: AppAPIValue?
    var progress: LongFileProgress?
    var error: String?
    var retryRequiresNewCid: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        ok = LenientJSON.bool(container, "ok")
        jobId = LenientJSON.string(container, "jobId")
        phase = LenientJSON.string(container, "phase")
        text = LenientJSON.string(container, "text")
        reasoning = LenientJSON.string(container, "reasoning")
        surface = LenientJSON.nested(container, "surface", as: AppAPIValue.self)
        progress = LenientJSON.nested(container, "progress", as: LongFileProgress.self)
        error = LenientJSON.string(container, "error")
        retryRequiresNewCid = LenientJSON.bool(container, "retryRequiresNewCid")
    }
}

/// `GET /api/chat/job?id=` — always 200 unless auth or ownership fails. A vanished id answers
/// `{"phase":"unknown"}` and nothing else, which must decode.
struct ChatJobStatus: Decodable, Sendable, Equatable {
    var phase: String
    var text: String
    var reasoning: String
    /// On a refusal this is the JSON body `handleChat` would have written, as a string.
    var error: String
    /// On a refusal, the HTTP status `handleChat` would have returned.
    var status: Int
    var surface: AppAPIValue?
    var progress: LongFileProgress?

    init(
        phase: String = "unknown",
        text: String = "",
        reasoning: String = "",
        error: String = "",
        status: Int = 0,
        surface: AppAPIValue? = nil,
        progress: LongFileProgress? = nil
    ) {
        self.phase = phase
        self.text = text
        self.reasoning = reasoning
        self.error = error
        self.status = status
        self.surface = surface
        self.progress = progress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        phase = LenientJSON.string(container, "phase") ?? "unknown"
        text = LenientJSON.string(container, "text") ?? ""
        reasoning = LenientJSON.string(container, "reasoning") ?? ""
        error = LenientJSON.string(container, "error") ?? ""
        status = LenientJSON.int(container, "status") ?? 0
        surface = LenientJSON.nested(container, "surface", as: AppAPIValue.self)
        progress = LenientJSON.nested(container, "progress", as: LongFileProgress.self)
    }

    /// The refusal body parsed back out of `error`, when it is JSON.
    var refusal: ServerError? {
        guard status >= 400 else { return nil }
        return ServerError.parse(jsonString: error)
    }
}

/// `longFileProgressSurface` — every field optional on the wire, every field defaulted here.
struct LongFileProgress: Decodable, Sendable, Equatable {
    /// `queued | planning | writing | qa | complete | cancelled`.
    var stage: String
    var pagesDone: Int
    var pagesTotal: Int
    var targetPages: Int
    var currentPage: Int?
    var currentTitle: String?
    var partsDone: Int
    var partsTotal: Int
    var percent: Int
    var complete: Bool
    var cancelled: Bool
    var resumeAvailable: Bool?

    init(
        stage: String = "queued",
        pagesDone: Int = 0,
        pagesTotal: Int = 0,
        targetPages: Int = 0,
        currentPage: Int? = nil,
        currentTitle: String? = nil,
        partsDone: Int = 0,
        partsTotal: Int = 0,
        percent: Int = 0,
        complete: Bool = false,
        cancelled: Bool = false,
        resumeAvailable: Bool? = nil
    ) {
        self.stage = stage
        self.pagesDone = pagesDone
        self.pagesTotal = pagesTotal
        self.targetPages = targetPages
        self.currentPage = currentPage
        self.currentTitle = currentTitle
        self.partsDone = partsDone
        self.partsTotal = partsTotal
        self.percent = percent
        self.complete = complete
        self.cancelled = cancelled
        self.resumeAvailable = resumeAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        stage = LenientJSON.string(container, "stage") ?? "queued"
        pagesDone = LenientJSON.int(container, "pagesDone") ?? LenientJSON.int(container, "completedPages") ?? 0
        pagesTotal = LenientJSON.int(container, "pagesTotal") ?? 0
        targetPages = LenientJSON.int(container, "targetPages") ?? LenientJSON.int(container, "requestedPages") ?? 0
        currentPage = LenientJSON.int(container, "currentPage")
        currentTitle = LenientJSON.string(container, "currentTitle")
        partsDone = LenientJSON.int(container, "partsDone") ?? 0
        partsTotal = LenientJSON.int(container, "partsTotal") ?? 0
        percent = LenientJSON.int(container, "percent") ?? 0
        complete = LenientJSON.bool(container, "complete") ?? false
        cancelled = LenientJSON.bool(container, "cancelled") ?? false
        resumeAvailable = LenientJSON.bool(container, "resumeAvailable")
    }
}

/// `GET /api/chat/job/file?id=` with no `part` — flattened out of the response's nested
/// `artifact` / `artifact.meta` objects.
struct LongFileManifest: Decodable, Sendable {
    var version: Int?
    var format: String?
    var filename: String?
    var title: String?
    var requestedPages: Int?
    var completedPages: Int?
    var partsDone: Int
    var partsTotal: Int
    var complete: Bool
    var progress: LongFileProgress?

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        let artifact = (try? root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("artifact")))
        let meta = artifact.flatMap { try? $0.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("meta")) }

        func int(_ key: String) -> Int? {
            if let value = LenientJSON.int(root, key) { return value }
            if let artifact, let value = LenientJSON.int(artifact, key) { return value }
            if let meta, let value = LenientJSON.int(meta, key) { return value }
            return nil
        }
        func string(_ key: String) -> String? {
            if let value = LenientJSON.string(root, key) { return value }
            if let artifact, let value = LenientJSON.string(artifact, key) { return value }
            if let meta, let value = LenientJSON.string(meta, key) { return value }
            return nil
        }
        func bool(_ key: String) -> Bool? {
            if let value = LenientJSON.bool(root, key) { return value }
            if let artifact, let value = LenientJSON.bool(artifact, key) { return value }
            return nil
        }

        version = int("artifactVersion") ?? int("version")
        format = string("format")
        filename = string("filename")
        title = string("title")
        requestedPages = int("requestedPages") ?? int("pageCount")
        completedPages = int("completedPages")
        partsDone = int("partsDone") ?? 0
        partsTotal = int("partsTotal") ?? 0
        complete = bool("complete") ?? false
        if let value = LenientJSON.nested(root, "progress", as: LongFileProgress.self) {
            progress = value
        } else if let artifact {
            progress = LenientJSON.nested(artifact, "progress", as: LongFileProgress.self)
        } else {
            progress = nil
        }
    }
}

/// One 0-based part of a long file. `sha256` is recomputed by the caller before the part is used.
struct LongFilePart: Decodable, Sendable {
    struct Record: Decodable, Sendable {
        var pageNumber: Int
        var title: String
        var markdown: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            pageNumber = LenientJSON.int(container, "pageNumber") ?? 0
            title = LenientJSON.string(container, "title") ?? ""
            markdown = LenientJSON.string(container, "markdown") ?? ""
        }
    }

    var partIndex: Int
    var startPage: Int
    var endPage: Int
    var records: [Record]
    var sha256: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        partIndex = LenientJSON.int(container, "part") ?? LenientJSON.int(container, "partIndex") ?? 0
        startPage = LenientJSON.int(container, "startPage") ?? 0
        endPage = LenientJSON.int(container, "endPage") ?? 0
        records = LenientJSON.array(container, "records", of: Record.self) ?? []
        sha256 = LenientJSON.string(container, "sha256")
    }
}

/// One result of `GET /api/search`.
struct WebSearchResult: Decodable, Sendable, Equatable {
    var title: String?
    var url: String?
    var snippet: String?
    var source: String?

    init(title: String? = nil, url: String? = nil, snippet: String? = nil, source: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        title = LenientJSON.string(container, "title")
        url = LenientJSON.string(container, "url")
        snippet = LenientJSON.string(container, "snippet")
        source = LenientJSON.string(container, "source")
    }
}

/// `POST /api/usage/charge` — the pre-charge before a Code build or an Agent mission.
struct UsageChargeResponse: Decodable, Sendable {
    var ok: Bool?
    var used: Int?
    var limit: Int?
    var remaining: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        ok = LenientJSON.bool(container, "ok")
        let sub = LenientJSON.nested(container, "sub", as: SubInfo.self)
        used = LenientJSON.int(container, "used") ?? sub?.used.ai
        limit = LenientJSON.int(container, "limit") ?? sub?.limits.ai
        remaining = LenientJSON.int(container, "remaining") ?? sub?.remaining.ai
    }
}

/// `POST /api/share`. Omit `cid` for a whole-chat share; with it, one assistant answer is shared
/// and the cid outranks any index.
struct ShareCreateRequest: Encodable, Sendable {
    var chatId: String
    var cid: String?
    var title: String?

    init(chatId: String, cid: String? = nil, title: String? = nil) {
        self.chatId = chatId
        self.cid = cid
        self.title = title
    }
}

/// A created share. The link is always the public site, never the API host.
struct ShareInfo: Codable, Sendable, Equatable {
    let id: String

    init(id: String) {
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = LenientJSON.string(container, "id") ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
    }

    /// `https://firasai.org/?share=<id>`.
    var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "firasai.org"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "share", value: id)]
        return components.url ?? URL(fileURLWithPath: "/")
    }
}

/// `GET /api/share?id=` — public, no auth. Only `role`, `content`, `lang`, `tier` and
/// `imageThumbs` survive the snapshot.
struct SharedChat: Decodable, Sendable {
    var title: String?
    var messages: [ChatMessage]
    /// Epoch milliseconds (`ts` on the wire).
    var createdAt: Double?
    /// `1` when the snapshot holds a single answer.
    var one: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        title = LenientJSON.string(container, "title")
        messages = LenientJSON.array(container, "messages", of: ChatMessage.self) ?? []
        createdAt = LenientJSON.double(container, "ts") ?? LenientJSON.double(container, "createdAt")
        one = LenientJSON.bool(container, "one") ?? false
    }
}
