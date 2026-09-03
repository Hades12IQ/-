import Foundation

/// The plan on a user's `sub`. Every plan is unmetered today (`PLAN_LIMITS` are all `-1`); the
/// distinction survives only for the badge colour and the account row.
enum PlanKind: String, Codable, Sendable {
    case free
    case gold
    case diamond
    case unlimited
    case guest

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = PlanKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .free
    }

    /// `CLIENT_PLANS` names, verbatim (`server-auth-session-account.md §3.4`).
    var title: LText {
        switch self {
        case .free: return LText(ar: "المجانية", en: "Free")
        case .gold: return LText(ar: "Gold", en: "Gold")
        case .diamond: return LText(ar: "Diamond", en: "Diamond")
        case .unlimited: return LText(ar: "غير محدودة", en: "Unlimited")
        case .guest: return LText(ar: "زائر", en: "Guest")
        }
    }
}

/// One of the three counter objects on `subInfo` (`limits` / `used` / `remaining`).
///
/// `-1` means unmetered. A missing object is supplied by `SubInfo` — `.unmetered` for limits and
/// remaining, `.zero` for used — because one struct cannot know which of the three it is.
struct QuotaCounts: Codable, Sendable, Equatable {
    var ai: Int
    var code: Int
    var agent: Int
    var brain: Int

    /// Every counter unmetered — the shape the server sends for `limits` and `remaining`.
    static let unmetered = QuotaCounts(ai: -1, code: -1, agent: -1, brain: -1)

    /// Nothing spent — the shape a missing `used` object falls back to.
    static let zero = QuotaCounts(ai: 0, code: 0, agent: 0, brain: 0)

    init(ai: Int, code: Int, agent: Int, brain: Int) {
        self.ai = ai
        self.code = code
        self.agent = agent
        self.brain = brain
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        ai = LenientJSON.int(container, "ai") ?? 0
        code = LenientJSON.int(container, "code") ?? 0
        agent = LenientJSON.int(container, "agent") ?? 0
        brain = LenientJSON.int(container, "brain") ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(ai, forKey: AnyCodingKey("ai"))
        try container.encode(code, forKey: AnyCodingKey("code"))
        try container.encode(agent, forKey: AnyCodingKey("agent"))
        try container.encode(brain, forKey: AnyCodingKey("brain"))
    }

    /// The counter that belongs to a product; `studio` shares the `ai` bucket.
    func value(for product: ProductKind) -> Int {
        switch product {
        case .ai, .studio: return ai
        case .code: return code
        case .agent: return agent
        case .brain: return brain
        }
    }
}

/// `subInfo(user)` — the only entitlement shape the app receives
/// (`server-auth-session-account.md §3.3`).
struct SubInfo: Codable, Sendable, Equatable {
    var plan: PlanKind
    /// Epoch **milliseconds**, or `nil`. Always `nil` for `free` and `unlimited`.
    var expiresAt: Double?
    var daysLeft: Int?
    var limits: QuotaCounts
    var used: QuotaCounts
    var remaining: QuotaCounts

    init(
        plan: PlanKind = .free,
        expiresAt: Double? = nil,
        daysLeft: Int? = nil,
        limits: QuotaCounts = .unmetered,
        used: QuotaCounts = .zero,
        remaining: QuotaCounts = .unmetered
    ) {
        self.plan = plan
        self.expiresAt = expiresAt
        self.daysLeft = daysLeft
        self.limits = limits
        self.used = used
        self.remaining = remaining
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        if let raw = LenientJSON.string(container, "plan") {
            plan = PlanKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .free
        } else {
            plan = .free
        }
        expiresAt = LenientJSON.double(container, "expiresAt")
        daysLeft = LenientJSON.int(container, "daysLeft")
        limits = LenientJSON.nested(container, "limits", as: QuotaCounts.self) ?? .unmetered
        used = LenientJSON.nested(container, "used", as: QuotaCounts.self) ?? .zero
        remaining = LenientJSON.nested(container, "remaining", as: QuotaCounts.self) ?? .unmetered
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(plan.rawValue, forKey: AnyCodingKey("plan"))
        try container.encodeIfPresent(expiresAt, forKey: AnyCodingKey("expiresAt"))
        try container.encodeIfPresent(daysLeft, forKey: AnyCodingKey("daysLeft"))
        try container.encode(limits, forKey: AnyCodingKey("limits"))
        try container.encode(used, forKey: AnyCodingKey("used"))
        try container.encode(remaining, forKey: AnyCodingKey("remaining"))
    }

    /// The expiry as a date, when the server sent one.
    var expiryDate: Date? {
        guard let expiresAt, expiresAt > 0 else { return nil }
        return Date(timeIntervalSince1970: expiresAt / 1000)
    }
}

/// `publicUser(u)` — the only user shape the app ever receives. `provider` is deliberately not
/// exposed by the server, so the account screen must tolerate discovering a Google account only
/// from a 400.
struct User: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var email: String
    var admin: Bool
    /// Members never carry the key at all; guests carry `"guest": true`.
    var guest: Bool
    var sub: SubInfo

    init(
        id: String,
        name: String = "",
        email: String = "",
        admin: Bool = false,
        guest: Bool = false,
        sub: SubInfo = SubInfo()
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.admin = admin
        self.guest = guest
        self.sub = sub
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = LenientJSON.string(container, "id") ?? ""
        name = LenientJSON.string(container, "name") ?? ""
        email = LenientJSON.string(container, "email") ?? ""
        admin = LenientJSON.bool(container, "admin") ?? false
        guest = LenientJSON.bool(container, "guest") ?? false
        sub = LenientJSON.nested(container, "sub", as: SubInfo.self) ?? SubInfo()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(name, forKey: AnyCodingKey("name"))
        try container.encode(email, forKey: AnyCodingKey("email"))
        try container.encode(admin, forKey: AnyCodingKey("admin"))
        try container.encode(guest, forKey: AnyCodingKey("guest"))
        try container.encode(sub, forKey: AnyCodingKey("sub"))
    }

    /// A guest either by the flag or by the `g_` id the server mints.
    var isGuest: Bool { guest || sub.plan == .guest || id.hasPrefix("g_") }

    var firstName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(separator: " ").first else { return trimmed }
        return String(first)
    }

    /// One character for the account pill; falls back to the email, then to a bullet.
    var initial: String {
        let source = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? email.trimmingCharacters(in: .whitespacesAndNewlines)
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let character = source.first else { return "•" }
        return String(character).uppercased()
    }
}

/// The result of a signup: either a pending verification (`pid` + email) or, when the server
/// signed the account in directly, the user.
struct PendingSignup: Sendable, Equatable {
    let pid: String
    let email: String
    let user: User?

    init(pid: String, email: String, user: User? = nil) {
        self.pid = pid
        self.email = email
        self.user = user
    }
}

/// The four outcomes of a `verify-status` poll (`server-auth-session-account.md §4.3`).
enum VerificationStatus: String, Sendable {
    case pending
    case verified
    case expired
    case gone

    init(raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "verified", "ok", "true": self = .verified
        case "expired": self = .expired
        case "gone", "missing": self = .gone
        default: self = .pending
        }
    }
}

/// The body of `POST /api/auth/verify-status`: `{verified}` plus at most one of `expired` / `gone`,
/// and `user` on the single poll that wins.
struct VerificationStatusResponse: Decodable, Sendable {
    var status: String?
    var verified: Bool?
    var expired: Bool?
    var gone: Bool?
    var user: User?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        status = LenientJSON.string(container, "status")
        verified = LenientJSON.bool(container, "verified")
        expired = LenientJSON.bool(container, "expired")
        gone = LenientJSON.bool(container, "gone")
        user = LenientJSON.nested(container, "user", as: User.self)
    }

    /// The status the poller should act on.
    var resolved: VerificationStatus {
        if verified == true { return .verified }
        if expired == true { return .expired }
        if gone == true { return .gone }
        if let status { return VerificationStatus(raw: status) }
        return .pending
    }
}
