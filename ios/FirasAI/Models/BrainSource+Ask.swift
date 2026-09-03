import Foundation

/// `POST /api/brain/whole` — the member-only whole-corpus answer. `outline` maps to the
/// Summarize button; the answer carries `[صفحة N]` markers and never a sources fence.
struct BrainWholeRequest: Encodable, Sendable {
    var docId: String
    var question: String
    var cid: String
    var lang: String
    var outline: Bool?

    init(docId: String, question: String, cid: String, lang: String, outline: Bool? = nil) {
        self.docId = docId
        self.question = question
        self.cid = cid
        self.lang = lang
        self.outline = outline
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(String(question.prefix(4_000)), forKey: AnyCodingKey("q"))
        try container.encode(docId.isEmpty ? [] : [docId], forKey: AnyCodingKey("docIds"))
        try container.encode(cid, forKey: AnyCodingKey("cid"))
        try container.encode(lang, forKey: AnyCodingKey("lang"))
        if outline == true {
            try container.encode("outline", forKey: AnyCodingKey("mode"))
        }
    }
}

/// Anything but a 200 with a non-empty `answer` is a decline: the retrieval path answers instead.
struct BrainWholeResponse: Decodable, Sendable {
    var answer: String?
    var ok: Bool?
    var error: String?
    var docs: Int?
    var pieces: Int?
    var chars: Int?
    var mode: String?
    var kind: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        answer = LenientJSON.string(container, "answer")
        ok = LenientJSON.bool(container, "ok")
        error = LenientJSON.string(container, "error")
        docs = LenientJSON.int(container, "docs")
        pieces = LenientJSON.int(container, "pieces")
        chars = LenientJSON.int(container, "chars")
        mode = LenientJSON.string(container, "mode")
        kind = LenientJSON.string(container, "kind")
    }
}

/// The lean source pointer persisted in an answer's ```` ```firas-sources ```` fence.
/// The wire keys are one letter each, exactly as the web writes them.
struct BrainSource: Codable, Sendable, Equatable, Identifiable {
    var n: Int
    var docId: String
    var title: String
    var page: Int
    var label: String?
    var ci: Int
    /// The first 400 characters of the hit, kept so a deleted document still shows something.
    var s: String?
    var unit: String?

    var id: String { "\(docId)-\(ci)-\(n)" }

    init(
        n: Int,
        docId: String,
        title: String,
        page: Int,
        label: String? = nil,
        ci: Int,
        s: String? = nil,
        unit: String? = nil
    ) {
        self.n = n
        self.docId = docId
        self.title = title
        self.page = page
        self.label = label
        self.ci = ci
        self.s = s
        self.unit = unit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        n = LenientJSON.int(container, "n") ?? 0
        docId = LenientJSON.string(container, "d") ?? LenientJSON.string(container, "docId") ?? ""
        title = LenientJSON.string(container, "t") ?? LenientJSON.string(container, "title") ?? ""
        page = LenientJSON.int(container, "p") ?? LenientJSON.int(container, "page") ?? 0
        label = LenientJSON.string(container, "l") ?? LenientJSON.string(container, "label")
        ci = LenientJSON.int(container, "c") ?? LenientJSON.int(container, "ci") ?? 0
        s = LenientJSON.string(container, "s")
        unit = LenientJSON.string(container, "u") ?? LenientJSON.string(container, "unit")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(n, forKey: AnyCodingKey("n"))
        try container.encode(docId, forKey: AnyCodingKey("d"))
        try container.encode(title, forKey: AnyCodingKey("t"))
        try container.encodeIfPresent(unit, forKey: AnyCodingKey("u"))
        try container.encode(page, forKey: AnyCodingKey("p"))
        try container.encode(label ?? "", forKey: AnyCodingKey("l"))
        try container.encode(ci, forKey: AnyCodingKey("c"))
        try container.encodeIfPresent(s, forKey: AnyCodingKey("s"))
    }

    var documentUnit: BrainDocumentUnit { BrainDocumentUnit(rawValue: unit ?? "page") ?? .page }
}

/// `POST /api/chat/job` with `kind:"brainask"` — the answer that survives leaving the app.
/// `error` comes back as a free-form string matched by prefix (`brain_search_429`, `brainask_…`).
struct BrainAskJobRequest: Encodable, Sendable {
    var kind: String
    var task: String
    var cid: String
    var chatId: String
    var product: String
    var lang: String
    var tier: String
    var docIds: [String]?
    var messages: [OutgoingMessage]

    init(
        kind: String = JobKind.brainask.rawValue,
        task: String,
        cid: String,
        chatId: String,
        product: String = ProductKind.brain.wireValue,
        lang: String,
        tier: String = ModelTier.pro.rawValue,
        docIds: [String]? = nil,
        messages: [OutgoingMessage]
    ) {
        self.kind = kind
        self.task = String(task.prefix(8_000))
        self.cid = cid
        self.chatId = chatId
        self.product = product
        self.lang = lang
        self.tier = tier
        self.docIds = docIds.map { Array($0.prefix(20)) }
        self.messages = messages
    }
}
