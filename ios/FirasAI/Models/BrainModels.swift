import Foundation

/// `BRAIN_KINDS`. The server stores whatever the client sent on part 1, defaulting to `text`.
enum BrainDocumentKind: String, CaseIterable, Codable, Sendable, Equatable {
    case pdf
    case docx
    case pptx
    case xlsx
    case text
    case image

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = BrainDocumentKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .text
    }
}

/// `BRAIN_UNITS`. The server never derives the unit from the kind — the client must send it.
enum BrainDocumentUnit: String, CaseIterable, Codable, Sendable, Equatable {
    case page
    case slide
    case sheet
    case section

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = BrainDocumentUnit(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .page
    }

    /// The word that goes in a citation marker, e.g. `[صفحة ٤٢]`.
    var noun: LText {
        switch self {
        case .page: return LText(ar: "صفحة", en: "page")
        case .slide: return LText(ar: "شريحة", en: "slide")
        case .sheet: return LText(ar: "ورقة", en: "sheet")
        case .section: return LText(ar: "قسم", en: "section")
        }
    }
}

/// `brainMetaOf` — the document shape every Brain endpoint returns.
struct BrainDocument: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let kind: BrainDocumentKind
    let unit: BrainDocumentUnit
    let pages: Int
    let indexed: Int
    let ocr: Int
    let chunks: Int
    let chars: Int
    /// Epoch milliseconds of the last write; the library is sorted by this, newest first.
    let ts: Double

    init(
        id: String,
        title: String = "",
        kind: BrainDocumentKind = .text,
        unit: BrainDocumentUnit = .page,
        pages: Int = 0,
        indexed: Int = 0,
        ocr: Int = 0,
        chunks: Int = 0,
        chars: Int = 0,
        ts: Double = 0
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.unit = unit
        self.pages = pages
        self.indexed = indexed
        self.ocr = ocr
        self.chunks = chunks
        self.chars = chars
        self.ts = ts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = LenientJSON.string(container, "id") ?? ""
        title = LenientJSON.string(container, "title") ?? ""
        kind = BrainDocumentKind(rawValue: (LenientJSON.string(container, "kind") ?? "").lowercased()) ?? .text
        unit = BrainDocumentUnit(rawValue: (LenientJSON.string(container, "unit") ?? "").lowercased()) ?? .page
        pages = LenientJSON.int(container, "pages") ?? 0
        indexed = LenientJSON.int(container, "indexed") ?? 0
        ocr = LenientJSON.int(container, "ocr") ?? 0
        chunks = LenientJSON.int(container, "chunks") ?? 0
        chars = LenientJSON.int(container, "chars") ?? 0
        ts = LenientJSON.double(container, "ts") ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(title, forKey: AnyCodingKey("title"))
        try container.encode(kind.rawValue, forKey: AnyCodingKey("kind"))
        try container.encode(unit.rawValue, forKey: AnyCodingKey("unit"))
        try container.encode(pages, forKey: AnyCodingKey("pages"))
        try container.encode(indexed, forKey: AnyCodingKey("indexed"))
        try container.encode(ocr, forKey: AnyCodingKey("ocr"))
        try container.encode(chunks, forKey: AnyCodingKey("chunks"))
        try container.encode(chars, forKey: AnyCodingKey("chars"))
        try container.encode(ts, forKey: AnyCodingKey("ts"))
    }
}

/// `limits` on the library response. `pagesPerDay` is `-1` for members (hide the line);
/// `visionLeft` is the site-wide OCR budget left today and is `0` with no Gemini key.
struct BrainLibraryLimits: Codable, Sendable, Equatable {
    let docs: Int
    let pagesPerDay: Int
    let visionLeft: Int

    init(docs: Int = 20, pagesPerDay: Int = -1, visionLeft: Int = 0) {
        self.docs = docs
        self.pagesPerDay = pagesPerDay
        self.visionLeft = visionLeft
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        docs = LenientJSON.int(container, "docs") ?? 20
        pagesPerDay = LenientJSON.int(container, "pagesPerDay") ?? -1
        visionLeft = LenientJSON.int(container, "visionLeft") ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(docs, forKey: AnyCodingKey("docs"))
        try container.encode(pagesPerDay, forKey: AnyCodingKey("pagesPerDay"))
        try container.encode(visionLeft, forKey: AnyCodingKey("visionLeft"))
    }
}

/// `used` on the library response. `pagesToday` is always 0 for members.
struct BrainLibraryUsage: Codable, Sendable, Equatable {
    let docs: Int
    let pagesToday: Int

    init(docs: Int = 0, pagesToday: Int = 0) {
        self.docs = docs
        self.pagesToday = pagesToday
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        docs = LenientJSON.int(container, "docs") ?? 0
        pagesToday = LenientJSON.int(container, "pagesToday") ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(docs, forKey: AnyCodingKey("docs"))
        try container.encode(pagesToday, forKey: AnyCodingKey("pagesToday"))
    }
}

/// `GET /api/brain/docs`.
struct BrainLibraryResponse: Decodable, Sendable, Equatable {
    let docs: [BrainDocument]
    let guest: Bool
    let limits: BrainLibraryLimits
    let used: BrainLibraryUsage

    init(
        docs: [BrainDocument] = [],
        guest: Bool = false,
        limits: BrainLibraryLimits = BrainLibraryLimits(),
        used: BrainLibraryUsage = BrainLibraryUsage()
    ) {
        self.docs = docs
        self.guest = guest
        self.limits = limits
        self.used = used
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        docs = LenientJSON.array(container, "docs", of: BrainDocument.self) ?? []
        guest = LenientJSON.bool(container, "guest") ?? false
        limits = LenientJSON.nested(container, "limits", as: BrainLibraryLimits.self) ?? BrainLibraryLimits()
        used = LenientJSON.nested(container, "used", as: BrainLibraryUsage.self) ?? BrainLibraryUsage()
    }
}

/// One ingested unit. `p` is 1-based; several records may share one `p`.
struct BrainPage: Codable, Sendable, Equatable {
    let p: Int
    let l: String?
    let text: String

    init(page: Int, label: String? = nil, text: String) {
        p = max(1, page)
        l = label.map { String($0.prefix(80)) }
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        p = max(1, LenientJSON.int(container, "p") ?? 1)
        l = LenientJSON.string(container, "l")
        text = LenientJSON.string(container, "text") ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(p, forKey: AnyCodingKey("p"))
        try container.encodeIfPresent(l, forKey: AnyCodingKey("l"))
        try container.encode(text, forKey: AnyCodingKey("text"))
    }
}

/// `POST /api/brain/doc` — one part of an upload. `kind` rides on every part (it picks the
/// splitter); `unit` and `ocr` matter on part 1 only, and `docId` on every continuation.
struct BrainUploadRequest: Encodable, Sendable {
    let title: String
    let kind: BrainDocumentKind
    let unit: BrainDocumentUnit
    let pages: [BrainPage]
    let docId: String?
    let ocr: Int?

    init(
        title: String,
        kind: BrainDocumentKind,
        unit: BrainDocumentUnit,
        pages: [BrainPage],
        docId: String? = nil,
        ocr: Int? = nil
    ) {
        self.title = title
        self.kind = kind
        self.unit = unit
        self.pages = pages
        self.docId = docId
        self.ocr = ocr
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(title, forKey: AnyCodingKey("title"))
        try container.encode(kind.rawValue, forKey: AnyCodingKey("kind"))
        try container.encode(unit.rawValue, forKey: AnyCodingKey("unit"))
        try container.encode(pages, forKey: AnyCodingKey("pages"))
        try container.encodeIfPresent(docId, forKey: AnyCodingKey("docId"))
        try container.encodeIfPresent(ocr, forKey: AnyCodingKey("ocr"))
    }
}

/// `chunks` = chunks added by this part; `total` = the document's chunk count after it.
struct BrainUploadResponse: Decodable, Sendable, Equatable {
    let ok: Bool
    let id: String
    let title: String
    let chunks: Int
    let total: Int
    let doc: BrainDocument?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        ok = LenientJSON.bool(container, "ok") ?? false
        id = LenientJSON.string(container, "id") ?? ""
        title = LenientJSON.string(container, "title") ?? ""
        chunks = LenientJSON.int(container, "chunks") ?? 0
        total = LenientJSON.int(container, "total") ?? 0
        doc = LenientJSON.nested(container, "doc", as: BrainDocument.self)
    }
}

/// Search modes. Anything other than `all` / `overview` is a plain search.
enum BrainSearchMode: String, Codable, Sendable, Equatable {
    case search
    case all
    case overview
}

/// `POST /api/brain/search`. Every call charges one Brain answer, including `all` and `overview`
/// and calls with an empty `q` — reuse one `cid` for a whole turn.
struct BrainSearchRequest: Encodable, Sendable {
    let q: String
    let k: Int?
    let docIds: [String]?
    let cid: String
    let mode: BrainSearchMode?
    let fromPage: Int?
    let toPage: Int?
    let offset: Int?
    let limit: Int?

    init(
        query: String,
        resultCount: Int? = nil,
        documentIDs: [String]? = nil,
        cid: String,
        mode: BrainSearchMode? = nil,
        fromPage: Int? = nil,
        toPage: Int? = nil,
        offset: Int? = nil,
        limit: Int? = nil
    ) {
        q = String(query.prefix(4_000))
        k = resultCount
        docIds = documentIDs
        self.cid = cid
        self.mode = mode
        self.fromPage = fromPage
        self.toPage = toPage
        self.offset = offset
        self.limit = limit
    }
}

/// The window echoed back on `mode:"range_empty"`. `to` is literally 1000000000 when only
/// `fromPage` was sent.
struct BrainSearchRange: Decodable, Sendable, Equatable {
    let from: Int
    let to: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        from = LenientJSON.int(container, "from") ?? 0
        to = LenientJSON.int(container, "to") ?? 0
    }
}

/// One retrieved chunk. `near` marks a neighbour that was expanded in, never a genuine match.
struct BrainHit: Decodable, Sendable, Equatable, Identifiable {
    let matched: Int?
    let score: Double
    let text: String
    let docId: String
    let title: String
    let kind: String
    let unit: String
    let page: Int
    let label: String?
    /// The real index into the stored chunk array — the address for `/api/brain/passage`.
    let ci: Int
    let near: Bool?

    var id: String { "\(docId)-\(ci)" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        matched = LenientJSON.int(container, "matched")
        score = LenientJSON.double(container, "score") ?? 0
        text = LenientJSON.string(container, "text") ?? ""
        docId = LenientJSON.string(container, "docId") ?? ""
        title = LenientJSON.string(container, "title") ?? ""
        kind = LenientJSON.string(container, "kind") ?? ""
        unit = LenientJSON.string(container, "unit") ?? "page"
        page = LenientJSON.int(container, "page") ?? 0
        label = LenientJSON.string(container, "label")
        ci = LenientJSON.int(container, "ci") ?? 0
        near = LenientJSON.bool(container, "near")
    }

    var documentUnit: BrainDocumentUnit { BrainDocumentUnit(rawValue: unit) ?? .page }
}

/// `docs` is absent in `mode:"all"`; `total`/`offset` only in `all`; `range` only in
/// `range_empty`. `mode` ∈ `search | overview | all | none | range_empty`.
struct BrainSearchResponse: Decodable, Sendable, Equatable {
    let hits: [BrainHit]
    let docs: Int?
    let mode: String
    let total: Int?
    let offset: Int?
    let range: BrainSearchRange?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        hits = LenientJSON.array(container, "hits", of: BrainHit.self) ?? []
        docs = LenientJSON.int(container, "docs")
        mode = LenientJSON.string(container, "mode") ?? "search"
        total = LenientJSON.int(container, "total")
        offset = LenientJSON.int(container, "offset")
        range = LenientJSON.nested(container, "range", as: BrainSearchRange.self)
    }

    var isRangeEmpty: Bool { mode == "range_empty" }
    var hasNothingToSearch: Bool { mode == "none" }
}

/// A neighbouring chunk of a passage, on the same page.
struct BrainPassageNeighbour: Decodable, Sendable, Equatable {
    let ci: Int
    let t: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        ci = LenientJSON.int(container, "ci") ?? 0
        t = LenientJSON.string(container, "t") ?? ""
    }
}

/// `GET /api/brain/passage` — the cited chunk with its neighbours, for the reader sheet.
struct BrainPassage: Decodable, Sendable, Equatable {
    let docId: String
    let title: String
    let kind: BrainDocumentKind
    let unit: BrainDocumentUnit
    let page: Int
    let label: String
    let ci: Int
    let text: String
    let before: [BrainPassageNeighbour]
    let after: [BrainPassageNeighbour]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        docId = LenientJSON.string(container, "docId") ?? ""
        title = LenientJSON.string(container, "title") ?? ""
        kind = BrainDocumentKind(rawValue: (LenientJSON.string(container, "kind") ?? "").lowercased()) ?? .text
        unit = BrainDocumentUnit(rawValue: (LenientJSON.string(container, "unit") ?? "").lowercased()) ?? .page
        page = LenientJSON.int(container, "page") ?? 0
        label = LenientJSON.string(container, "label") ?? ""
        ci = LenientJSON.int(container, "ci") ?? 0
        text = LenientJSON.string(container, "text") ?? ""
        before = LenientJSON.array(container, "before", of: BrainPassageNeighbour.self) ?? []
        after = LenientJSON.array(container, "after", of: BrainPassageNeighbour.self) ?? []
    }
}
