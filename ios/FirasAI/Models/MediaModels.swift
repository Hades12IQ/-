import Foundation

/// The three things the studio makes. Each has its own queue and its own fence.
enum MediaKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case image
    case video
    case music

    var id: String { rawValue }

    var jobKind: JobKind {
        switch self {
        case .image: return .image
        case .video: return .video
        case .music: return .music
        }
    }

    /// The fence a finished creation is persisted as.
    var fenceName: String {
        switch self {
        case .image: return "firas-image"
        case .video: return "firas-video"
        case .music: return "firas-music"
        }
    }

    var featureKey: FeatureKey {
        switch self {
        case .image: return .image
        case .video: return .video
        case .music: return .music
        }
    }

    init?(fenceName: String) {
        switch fenceName.lowercased() {
        case "firas-image": self = .image
        case "firas-video": self = .video
        case "firas-music": self = .music
        default: return nil
        }
    }
}

/// The three image shapes the picker offers. Pixels are chosen so the Replicate rung actually
/// renders the ratio the label promises.
enum ImageShape: String, Codable, Sendable, CaseIterable, Identifiable {
    case square
    case tall
    case wide

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .square: return 1024
        case .tall: return 1024
        case .wide: return 1536
        }
    }

    var height: Int {
        switch self {
        case .square: return 1024
        case .tall: return 1536
        case .wide: return 1024
        }
    }

    var label: LText {
        switch self {
        case .square: return LText(ar: "مربّعة", en: "Square")
        case .tall: return LText(ar: "طولية", en: "Portrait")
        case .wide: return LText(ar: "عرضية", en: "Landscape")
        }
    }

    /// The shape a `w`/`h` pair came from, for a fence written elsewhere.
    static func matching(width: Int?, height: Int?) -> ImageShape {
        guard let width, let height, width > 0, height > 0 else { return .square }
        if height > width { return .tall }
        if width > height { return .wide }
        return .square
    }
}

/// `POST /api/image/job`. Never send `image` — a truthy value answers 501; edits go to
/// `/api/image/edit`.
struct ImageJobRequest: Encodable, Sendable {
    var prompt: String
    var w: Int
    var h: Int
    var chatId: String?

    init(prompt: String, w: Int, h: Int, chatId: String? = nil) {
        self.prompt = String(prompt.prefix(1_000))
        self.w = min(max(w, 256), 1280)
        self.h = min(max(h, 256), 1280)
        self.chatId = chatId
    }
}

/// `POST /api/video/job`. `image` is the first frame and must be a full
/// `data:image/(png|jpe?g|webp|bmp);base64,…` URI (or an `https://` URL) — raw base64 is refused
/// with `bad_image`. Keep the whole body under ~11.5 M characters.
struct VideoJobRequest: Encodable, Sendable {
    var prompt: String
    var seconds: Int
    var image: String?
    var chatId: String?

    init(prompt: String, seconds: Int, image: String? = nil, chatId: String? = nil) {
        self.prompt = String(prompt.prefix(2_000))
        self.seconds = min(max(seconds, 2), 30)
        self.image = image
        self.chatId = chatId
    }
}

/// `POST /api/music/job`. `prompt` is the English style/arrangement tag line, not a description of
/// the song; empty `lyrics` means instrumental.
struct MusicJobRequest: Encodable, Sendable {
    var prompt: String
    var lyrics: String
    var seconds: Int
    var chatId: String?

    init(prompt: String, lyrics: String, seconds: Int, chatId: String? = nil) {
        self.prompt = String(prompt.prefix(2_000))
        self.lyrics = String(lyrics.prefix(6_000))
        self.seconds = min(max(seconds, 10), 600)
        self.chatId = chatId
    }
}

/// A media start. `phase: "done"` with a `key` is a cache hit — the bytes already exist and
/// nothing was charged.
struct MediaJobStartResponse: Decodable, Sendable {
    var ok: Bool?
    var jobId: String
    var phase: String?
    var key: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        ok = LenientJSON.bool(container, "ok")
        jobId = LenientJSON.string(container, "jobId") ?? ""
        phase = LenientJSON.string(container, "phase")
        key = LenientJSON.string(container, "key")
    }

    var isAlreadyDone: Bool { (phase ?? "") == "done" && !(key ?? "").isEmpty }
}

/// A media status read. `running` is also the answer for an id the server has forgotten, which is
/// why every media watcher needs its own deadline.
struct MediaJobStatusResponse: Decodable, Sendable, Equatable {
    var phase: String
    var key: String?
    var error: String?
    var reason: String?
    var url: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        phase = LenientJSON.string(container, "phase") ?? "running"
        key = LenientJSON.string(container, "key")
        error = LenientJSON.string(container, "error")
        reason = LenientJSON.string(container, "reason")
        url = LenientJSON.string(container, "url")
    }

    var jobPhase: JobPhase { JobPhase(raw: phase) }
}

/// `POST /api/image/quota` — a read-only pre-check that charges nothing. `remaining` is `-1` when
/// the limit is `-1`.
struct ImageQuota: Decodable, Sendable {
    var used: Int?
    var limit: Int?
    var remaining: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        used = LenientJSON.int(container, "used")
        limit = LenientJSON.int(container, "limit")
        remaining = LenientJSON.int(container, "remaining")
    }
}

/// `GET /api/video/quota`. Only `seconds` is trustworthy — `limit`/`used` count the legacy
/// synchronous path, not the job path. The web falls back to 6 when the call failed.
struct VideoQuota: Decodable, Sendable {
    var seconds: Int?
    var maxSeconds: Int?
    var limit: Int?
    var used: Int?
    var windowMin: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        seconds = LenientJSON.int(container, "seconds")
        maxSeconds = LenientJSON.int(container, "maxSeconds")
        limit = LenientJSON.int(container, "limit")
        used = LenientJSON.int(container, "used")
        windowMin = LenientJSON.int(container, "windowMin")
    }
}

/// `POST /api/image/edit` — synchronous, up to ~200 s. `image` is raw base64 (a data-URL prefix is
/// stripped server-side); the decoded bytes must be 1…20 MB.
struct ImageEditRequest: Encodable, Sendable {
    var image: String
    var prompt: String
    var chatId: String?

    init(image: String, prompt: String, chatId: String? = nil) {
        self.image = image
        self.prompt = String(prompt.prefix(1_000))
        self.chatId = chatId
    }
}

struct ImageEditResponse: Decodable, Sendable {
    var ok: Bool?
    var key: String?
    var jobId: String?
    var error: String?
    var cached: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        ok = LenientJSON.bool(container, "ok")
        key = LenientJSON.string(container, "key")
        jobId = LenientJSON.string(container, "jobId")
        error = LenientJSON.string(container, "error")
        cached = LenientJSON.bool(container, "cached")
    }
}

/// The body of a `firas-image` / `firas-video` / `firas-music` fence, exactly as the web writes it.
///
/// `kind` is carried by the fence name, so `encodedFence()` never writes it into the JSON.
struct MediaMeta: Codable, Sendable, Equatable {
    var kind: MediaKind
    /// The cache key; empty until the bytes exist.
    var key: String
    var prompt: String
    /// The user's caption comment, written under the picture.
    var note: String?
    var w: Int?
    var h: Int?
    var seconds: Int?
    var lyrics: String?
    var title: String?
    var style: String?
    /// A first-frame source marker (client-only).
    var src: String?
    /// Present on a video turn that already started its job: poll it, never start a second one.
    var jobId: String?

    init(
        kind: MediaKind,
        key: String = "",
        prompt: String = "",
        note: String? = nil,
        w: Int? = nil,
        h: Int? = nil,
        seconds: Int? = nil,
        lyrics: String? = nil,
        title: String? = nil,
        style: String? = nil,
        src: String? = nil,
        jobId: String? = nil
    ) {
        self.kind = kind
        self.key = key
        self.prompt = prompt
        self.note = note
        self.w = w
        self.h = h
        self.seconds = seconds
        self.lyrics = lyrics
        self.title = title
        self.style = style
        self.src = src
        self.jobId = jobId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        if let raw = LenientJSON.string(container, "kind"), let decoded = MediaKind(rawValue: raw) {
            kind = decoded
        } else {
            kind = .image
        }
        key = LenientJSON.string(container, "key") ?? ""
        prompt = LenientJSON.string(container, "prompt") ?? ""
        note = LenientJSON.string(container, "note")
        w = LenientJSON.int(container, "w")
        h = LenientJSON.int(container, "h")
        seconds = LenientJSON.int(container, "seconds")
        lyrics = LenientJSON.string(container, "lyrics")
        title = LenientJSON.string(container, "title")
        style = LenientJSON.string(container, "style")
        src = LenientJSON.string(container, "src")
        jobId = LenientJSON.string(container, "jobId")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(kind.rawValue, forKey: AnyCodingKey("kind"))
        try container.encode(key, forKey: AnyCodingKey("key"))
        try container.encode(prompt, forKey: AnyCodingKey("prompt"))
        try container.encodeIfPresent(note, forKey: AnyCodingKey("note"))
        try container.encodeIfPresent(w, forKey: AnyCodingKey("w"))
        try container.encodeIfPresent(h, forKey: AnyCodingKey("h"))
        try container.encodeIfPresent(seconds, forKey: AnyCodingKey("seconds"))
        try container.encodeIfPresent(lyrics, forKey: AnyCodingKey("lyrics"))
        try container.encodeIfPresent(title, forKey: AnyCodingKey("title"))
        try container.encodeIfPresent(style, forKey: AnyCodingKey("style"))
        try container.encodeIfPresent(src, forKey: AnyCodingKey("src"))
        try container.encodeIfPresent(jobId, forKey: AnyCodingKey("jobId"))
    }

    /// The fence body parsed. `parseImageMeta` requires `prompt`; music accepts `prompt` or
    /// `lyrics`.
    static func parse(fenceName: String, body: String) -> MediaMeta? {
        guard let kind = MediaKind(fenceName: fenceName) else { return nil }
        let payload = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return nil }
        guard var meta = try? JSONDecoder().decode(MediaMeta.self, from: data) else { return nil }
        meta.kind = kind
        switch kind {
        case .image, .video:
            guard !meta.prompt.isEmpty else { return nil }
        case .music:
            guard !meta.prompt.isEmpty || !(meta.lyrics ?? "").isEmpty else { return nil }
        }
        return meta
    }

    /// The card written into a chat message — one line of JSON, the keys the web writes for this
    /// kind and nothing else.
    func encodedFence() -> String {
        var fields: [(String, String)] = []
        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append((key, MediaMeta.quoted(value)))
        }
        func putNumber(_ key: String, _ value: Int?) {
            guard let value else { return }
            fields.append((key, String(value)))
        }

        switch kind {
        case .image:
            put("prompt", prompt)
            put("key", key)
            put("note", note)
            putNumber("w", w)
            putNumber("h", h)
        case .video:
            put("prompt", prompt)
            putNumber("seconds", seconds)
            put("jobId", jobId)
            put("key", key)
            put("note", note)
        case .music:
            put("prompt", prompt)
            put("lyrics", lyrics)
            putNumber("seconds", seconds)
            put("title", title)
            put("jobId", jobId)
            put("key", key)
        }

        let pairs = fields.map { field -> String in "\"" + field.0 + "\":" + field.1 }
        let json = "{" + pairs.joined(separator: ",") + "}"
        return "```" + kind.fenceName + "\n" + json + "\n```"
    }

    /// A JSON string literal, escaped exactly as `JSON.stringify` would.
    private static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", Int(scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

/// One thing the studio made, as the device remembers it.
///
/// `localFilename` is relative to the asset directory, never an absolute URL: the container's UUID
/// changes on every update and an absolute path would orphan every file.
struct MediaCreation: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let ownerID: String
    let kind: MediaKind
    var meta: MediaMeta
    var conversationID: String
    var messageID: String?
    var createdAt: Date
    var phase: JobPhase
    var jobID: String?
    var localFilename: String?
    var errorCode: String?

    init(
        id: String,
        ownerID: String,
        kind: MediaKind,
        meta: MediaMeta,
        conversationID: String,
        messageID: String? = nil,
        createdAt: Date = Date(),
        phase: JobPhase = .queued,
        jobID: String? = nil,
        localFilename: String? = nil,
        errorCode: String? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.kind = kind
        self.meta = meta
        self.conversationID = conversationID
        self.messageID = messageID
        self.createdAt = createdAt
        self.phase = phase
        self.jobID = jobID
        self.localFilename = localFilename
        self.errorCode = errorCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = LenientJSON.string(container, "id") ?? ""
        ownerID = LenientJSON.string(container, "ownerID") ?? ""
        kind = MediaKind(rawValue: LenientJSON.string(container, "kind") ?? "") ?? .image
        meta = LenientJSON.nested(container, "meta", as: MediaMeta.self) ?? MediaMeta(kind: .image)
        conversationID = LenientJSON.string(container, "conversationID") ?? ""
        messageID = LenientJSON.string(container, "messageID")
        createdAt = Date(timeIntervalSince1970: LenientJSON.double(container, "createdAt") ?? 0)
        phase = JobPhase(raw: LenientJSON.string(container, "phase") ?? "")
        jobID = LenientJSON.string(container, "jobID")
        localFilename = LenientJSON.string(container, "localFilename")
        errorCode = LenientJSON.string(container, "errorCode")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(ownerID, forKey: AnyCodingKey("ownerID"))
        try container.encode(kind.rawValue, forKey: AnyCodingKey("kind"))
        try container.encode(meta, forKey: AnyCodingKey("meta"))
        try container.encode(conversationID, forKey: AnyCodingKey("conversationID"))
        try container.encodeIfPresent(messageID, forKey: AnyCodingKey("messageID"))
        try container.encode(createdAt.timeIntervalSince1970, forKey: AnyCodingKey("createdAt"))
        try container.encode(phase.rawValue, forKey: AnyCodingKey("phase"))
        try container.encodeIfPresent(jobID, forKey: AnyCodingKey("jobID"))
        try container.encodeIfPresent(localFilename, forKey: AnyCodingKey("localFilename"))
        try container.encodeIfPresent(errorCode, forKey: AnyCodingKey("errorCode"))
    }

    var hasBytes: Bool { !(meta.key.isEmpty) || localFilename != nil }
}
