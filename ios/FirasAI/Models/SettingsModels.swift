import Foundation

/// `POST /api/auth/change-email`.
struct ChangeEmailRequest: Encodable, Sendable {
    let current: String
    let email: String

    init(currentPassword: String, newEmail: String) {
        current = currentPassword
        email = newEmail
    }
}

/// `POST /api/auth/change-password`.
struct ChangePasswordRequest: Encodable, Sendable {
    let current: String
    let password: String

    init(currentPassword: String, newPassword: String) {
        current = currentPassword
        password = newPassword
    }
}

/// `POST /api/auth/delete-account`.
struct DeleteAccountRequest: Encodable, Sendable {
    let current: String

    init(currentPassword: String) {
        current = currentPassword
    }
}

/// `POST /api/redeem`.
struct RedeemRequest: Encodable, Sendable {
    let code: String

    init(code: String) {
        self.code = String(code.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(40))
    }
}

/// Why an imported backup was refused.
enum ChatBackupValidationError: Error, Sendable, Equatable {
    case fileTooLarge
    case unsupportedFormat
    case noChats
    case tooManyChats
}

/// The website's `{app, format, exportedAt, chats}` backup file.
///
/// Server identifiers are deliberately omitted: importing always creates new conversations owned
/// by whoever is signed in.
struct FirasChatBackup: Codable, Sendable, Equatable {
    static let currentFormat = 1
    static let maximumFileBytes = 50 * 1_024 * 1_024
    static let maximumChats = 500

    let app: String
    let format: Int
    let exportedAt: String?
    let chats: [FirasChatBackupEntry]

    init(chats: [FirasChatBackupEntry], exportedAt: String) {
        app = "Firas AI"
        format = Self.currentFormat
        self.exportedAt = exportedAt
        self.chats = chats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        app = LenientJSON.string(container, "app") ?? ""
        format = LenientJSON.int(container, "format") ?? 0
        exportedAt = LenientJSON.string(container, "exportedAt")
        chats = LenientJSON.array(container, "chats", of: FirasChatBackupEntry.self) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(app, forKey: AnyCodingKey("app"))
        try container.encode(format, forKey: AnyCodingKey("format"))
        try container.encodeIfPresent(exportedAt, forKey: AnyCodingKey("exportedAt"))
        try container.encode(chats, forKey: AnyCodingKey("chats"))
    }

    static func decodeValidated(from data: Data) throws -> FirasChatBackup {
        guard data.count <= maximumFileBytes else {
            throw ChatBackupValidationError.fileTooLarge
        }
        guard let decoded = try? JSONDecoder().decode(FirasChatBackup.self, from: data) else {
            throw ChatBackupValidationError.unsupportedFormat
        }
        return try decoded.validatedForImport()
    }

    func validatedForImport() throws -> FirasChatBackup {
        guard app == "Firas AI", format == Self.currentFormat else {
            throw ChatBackupValidationError.unsupportedFormat
        }
        guard !chats.isEmpty else {
            throw ChatBackupValidationError.noChats
        }
        guard chats.count <= Self.maximumChats else {
            throw ChatBackupValidationError.tooManyChats
        }
        return FirasChatBackup(
            chats: chats.map { $0.sanitizedForImport },
            exportedAt: exportedAt ?? ISO8601DateFormatter().string(from: Date())
        )
    }
}

/// One conversation inside a backup. Messages are stored in the `PersistedMessage` whitelist
/// shape, so an exported file is byte-compatible with what the server would have kept.
struct FirasChatBackupEntry: Codable, Sendable, Equatable {
    let title: String
    let pinned: Bool?
    let agent: Bool?
    let codeProj: Bool?
    let brainNb: Bool?
    let messages: [PersistedMessage]

    static let maximumMessagesPerChat = 2_000
    static let maximumContentCharacters = 200_000
    static let maximumThumbnailCharacters = 300_000

    init(
        title: String,
        pinned: Bool? = nil,
        agent: Bool? = nil,
        codeProj: Bool? = nil,
        brainNb: Bool? = nil,
        messages: [PersistedMessage]
    ) {
        self.title = title
        self.pinned = pinned
        self.agent = agent
        self.codeProj = codeProj
        self.brainNb = brainNb
        self.messages = messages
    }

    init(summary: ChatSummary, messages: [PersistedMessage]) {
        self.init(
            title: summary.title,
            pinned: summary.pinned,
            agent: summary.agent,
            codeProj: summary.codeProj,
            brainNb: summary.brainNb,
            messages: messages
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        title = LenientJSON.string(container, "title") ?? ""
        pinned = LenientJSON.bool(container, "pinned")
        agent = LenientJSON.bool(container, "agent")
        codeProj = LenientJSON.bool(container, "codeProj")
        brainNb = LenientJSON.bool(container, "brainNb")
        messages = LenientJSON.array(container, "messages", of: PersistedMessage.self) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(title, forKey: AnyCodingKey("title"))
        try container.encodeIfPresent(pinned, forKey: AnyCodingKey("pinned"))
        try container.encodeIfPresent(agent, forKey: AnyCodingKey("agent"))
        try container.encodeIfPresent(codeProj, forKey: AnyCodingKey("codeProj"))
        try container.encodeIfPresent(brainNb, forKey: AnyCodingKey("brainNb"))
        try container.encode(messages, forKey: AnyCodingKey("messages"))
    }

    /// The entry with every bound the server would apply already applied, so an import can never
    /// be refused for size after the fact.
    var sanitizedForImport: FirasChatBackupEntry {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedTitle = cleanTitle.isEmpty ? "Firas AI" : String(cleanTitle.prefix(120))

        let keptMessages = messages
            .filter { $0.role == "user" || $0.role == "assistant" }
            .prefix(Self.maximumMessagesPerChat)
            .map { Self.sanitized($0) }

        return FirasChatBackupEntry(
            title: boundedTitle,
            pinned: pinned == true,
            agent: agent == true,
            codeProj: codeProj == true,
            brainNb: brainNb == true,
            messages: Array(keptMessages)
        )
    }

    private static func sanitized(_ message: PersistedMessage) -> PersistedMessage {
        let versions = (message.alts ?? [])
            .prefix(5)
            .map { version in
                AnswerVersion(
                    content: String(version.content.prefix(maximumContentCharacters)),
                    reasoning: version.reasoning.map { String($0.prefix(maximumContentCharacters)) },
                    tier: version.tier.map { String($0.prefix(20)) },
                    lang: version.lang.map { String($0.prefix(5)) }
                )
            }
        let keptVersions = versions.count > 1 ? Array(versions) : nil

        return PersistedMessage(
            role: message.role,
            content: String(message.content.prefix(maximumContentCharacters)),
            tier: message.tier.map { String($0.prefix(20)) },
            lang: message.lang.map { String($0.prefix(5)) },
            reasoning: message.reasoning.map { String($0.prefix(maximumContentCharacters)) },
            cid: message.cid.map { String($0.prefix(64)) },
            files: message.files.map { chips in
                Array(chips.prefix(12)).map { FileChip(name: String($0.name.prefix(200))) }
            },
            imageThumbs: message.imageThumbs.map { thumbs in
                Array(thumbs.filter { $0.count <= maximumThumbnailCharacters }.prefix(6))
            },
            mode: message.mode.map { String($0.prefix(20)) },
            askAnswered: message.askAnswered == true ? true : nil,
            retryOf: message.retryOf.map {
                RetryReference(cid: String($0.cid.prefix(64)), tier: String($0.tier.prefix(20)))
            },
            retried: message.retried == true ? true : nil,
            mergedFrom: message.mergedFrom.map { String($0.prefix(120)) },
            alts: keptVersions,
            altAt: keptVersions.map { min(max(message.altAt ?? $0.count - 1, 0), $0.count - 1) }
        )
    }
}
