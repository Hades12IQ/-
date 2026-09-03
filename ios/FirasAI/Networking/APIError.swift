import Foundation

/// The quota envelope the server attaches to a 429 (`{"error":"daily quota reached",
/// "quota":{"product":"ai","used":180,"limit":180,"plan":"guest"}}`).
struct QuotaInfo: Decodable, Sendable, Equatable {
    var product: String?
    var used: Int?
    var limit: Int?
    var plan: String?

    init(product: String? = nil, used: Int? = nil, limit: Int? = nil, plan: String? = nil) {
        self.product = product
        self.used = used
        self.limit = limit
        self.plan = plan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        product = LenientJSON.string(c, "product")
        used = LenientJSON.int(c, "used")
        limit = LenientJSON.int(c, "limit")
        plan = LenientJSON.string(c, "plan")
    }
}

/// The mission the server says is already running when an agent start is refused with 409
/// `agent_busy`.
struct AgentActiveJob: Decodable, Sendable, Equatable {
    var jobId: String?
    var chatId: String?
    var cid: String?
    var title: String?

    init(jobId: String? = nil, chatId: String? = nil, cid: String? = nil, title: String? = nil) {
        self.jobId = jobId
        self.chatId = chatId
        self.cid = cid
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        jobId = LenientJSON.string(c, "jobId")
        chatId = LenientJSON.string(c, "chatId")
        cid = LenientJSON.string(c, "cid")
        title = LenientJSON.string(c, "title")
    }
}

/// Everything a Firas refusal can carry, all of it optional.
///
/// Two shapes reach this type. Most refusals are JSON `{"error":"<code>", …}`; a good number are
/// written with a bare `res.end("text")` and have no content type at all (`auth required`,
/// `not found`, `rate limited`, `daily limit reached`). `parse(_:)` accepts both and never throws,
/// so a body the server invented yesterday still yields a usable `code`.
///
/// `code` is a machine key for `ErrorPresenter`, never something a user reads: Arabic UI must
/// never show an English server sentence and vice versa.
struct ServerError: Decodable, Sendable, Equatable {
    var code: String?
    var ok: Bool?
    var feature: String?
    var guest: Bool?
    var scope: String?
    var quota: QuotaInfo?
    var limit: Int?
    var used: Int?
    var remaining: Int?
    var windowMin: Int?
    var freesInMin: Int?
    var activeJob: AgentActiveJob?
    var credits: AgentCredits?
    var retryRequiresNewCid: Bool?
    var maxPages: Int?
    var chars: Int?
    var cap: Int?

    init(code: String? = nil) {
        self.code = code
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        code = LenientJSON.string(c, "error") ?? LenientJSON.string(c, "reason")
        ok = LenientJSON.bool(c, "ok")
        feature = LenientJSON.string(c, "feature")
        guest = LenientJSON.bool(c, "guest")
        scope = LenientJSON.string(c, "scope")
        quota = LenientJSON.nested(c, "quota", as: QuotaInfo.self)
        limit = LenientJSON.int(c, "limit")
        used = LenientJSON.int(c, "used")
        remaining = LenientJSON.int(c, "remaining")
        windowMin = LenientJSON.int(c, "windowMin")
        freesInMin = LenientJSON.int(c, "freesInMin")
        activeJob = LenientJSON.nested(c, "activeJob", as: AgentActiveJob.self)
        credits = LenientJSON.nested(c, "credits", as: AgentCredits.self)
        retryRequiresNewCid = LenientJSON.bool(c, "retryRequiresNewCid")
        maxPages = LenientJSON.int(c, "maxPages")
        chars = LenientJSON.int(c, "chars")
        cap = LenientJSON.int(c, "cap")

        // The guest network bucket reports its scope at the top level; be tolerant of a server
        // that ever moves it inside `quota`.
        if scope == nil,
           let quotaContainer = try? c.nestedContainer(
               keyedBy: AnyCodingKey.self,
               forKey: AnyCodingKey("quota")
           ) {
            scope = LenientJSON.string(quotaContainer, "scope")
        }
    }

    /// `signin_required` and `account_required` are the two 403 codes that mean "make an account",
    /// not "you are forbidden".
    var isSignInRequired: Bool {
        code == "signin_required" || code == "account_required"
    }

    /// Normalised body → `ServerError`. Never throws: a body that is neither JSON nor short text
    /// yields an empty envelope and the caller falls back to the status code alone.
    static func parse(_ data: Data) -> ServerError {
        guard !data.isEmpty else { return ServerError() }
        if let decoded = try? JSONDecoder().decode(ServerError.self, from: data) {
            // A JSON body that carried none of the known keys is still better described by its
            // text (some handlers send `"auth required"` as a bare JSON string).
            if decoded.code != nil { return decoded }
            if decoded.ok != nil || decoded.quota != nil || decoded.limit != nil { return decoded }
        }
        guard let text = String(data: data.prefix(2048), encoding: .utf8) else { return ServerError() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return ServerError() }
        // A JSON object we failed to key on is not a code.
        guard !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else { return ServerError() }
        return ServerError(code: trimmed.replacingOccurrences(of: "\"", with: ""))
    }

    /// Job records keep their refusal as a JSON *string* in `error`
    /// (`{"error":"credits_reserved"}`). Bare codes (`agent_busy`) are accepted too.
    static func parse(jsonString: String) -> ServerError? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) {
            if let decoded = try? JSONDecoder().decode(ServerError.self, from: data) {
                return decoded
            }
            return ServerError()
        }
        guard trimmed.count <= 200 else { return ServerError() }
        return ServerError(code: trimmed)
    }
}

/// Every failure the transport layer can produce. `ErrorPresenter` decides the user-facing copy
/// from the status and the `ServerError.code`, never from a server sentence.
enum APIError: Error, Sendable {
    case invalidURL
    case transport(URLError)
    case http(status: Int, server: ServerError, raw: String)
    case decoding(String)
    case offline
    case cancelled
    case deadline

    var status: Int? {
        if case .http(let status, _, _) = self { return status }
        return nil
    }

    var server: ServerError? {
        if case .http(_, let server, _) = self { return server }
        return nil
    }

    /// True when retrying the exact same request could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .transport, .offline:
            return true
        case .http(let status, _, _):
            return status >= 500 || status == 408
        case .invalidURL, .decoding, .cancelled, .deadline:
            return false
        }
    }

    /// A cancelled request is never surfaced to the user.
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
