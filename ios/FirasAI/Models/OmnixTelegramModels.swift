import Foundation

enum OmnixTelegramPhase: String, Decodable, Sendable, CaseIterable {
    case notConfigured = "not_configured", pairing, connected
    case setupUncertain = "setup_uncertain", approvalExpired = "approval_expired"
    case ownerIDRequired = "owner_id_required", disconnecting
    case disconnectUncertain = "disconnect_uncertain", disconnected, settingUp = "setting_up"

    var canDisconnect: Bool {
        [.pairing, .connected, .setupUncertain, .approvalExpired, .ownerIDRequired, .settingUp].contains(self)
    }
    var awaitingChange: Bool { [.pairing, .disconnecting, .settingUp].contains(self) }
}

/// Public account state only. The one-time code is deliberately absent and cannot be saved here.
struct OmnixTelegramStatus: Decodable, Sendable, Equatable {
    struct Bot: Decodable, Sendable, Equatable { let id: Int64; let username: String? }
    let ok: Bool
    let state: OmnixTelegramPhase
    var connectionId: String?
    var bot: Bot?
    var telegramUserId: Int64?
    var cloudReady: Bool?
    var canConfigure: Bool?
    var pairingExpiresAt: Double?

    var mayConfigure: Bool {
        ok && cloudReady == true && canConfigure == true && [.notConfigured, .disconnected].contains(state)
    }
    var isValid: Bool {
        ok && (connectionId == nil || Self.matches(connectionId!, #"omxt_[a-f0-9]{32}"#))
        && (telegramUserId == nil || OmnixTelegramService.isUserID(telegramUserId!))
        && (![.pairing, .connected].contains(state) || connectionId != nil)
        && (bot?.username == nil || Self.matches(bot!.username!, #"[A-Za-z][A-Za-z0-9_]{4,31}"#))
    }
    static func matches(_ text: String, _ expression: String) -> Bool {
        // Anchors must consume the entire value, including a possible trailing newline.
        guard let range = text.range(of: "\\A(?:" + expression + ")\\z", options: .regularExpression) else { return false }
        return range == text.startIndex..<text.endIndex
    }
}

/// Not Encodable: tokens and pairing codes never enter preferences, chat history or caches.
struct OmnixTelegramReply: Decodable, Sendable {
    struct Pairing: Decodable, Sendable { let code: String; let expiresAt: Double }
    let status: OmnixTelegramStatus
    let pairing: Pairing?
    private enum CodingKeys: String, CodingKey { case pairing }
    init(from decoder: Decoder) throws {
        status = try OmnixTelegramStatus(from: decoder)
        pairing = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Pairing.self, forKey: .pairing)
    }
}

struct OmnixTelegramPairing: Sendable {
    let owner: String
    let connectionID: String
    private let code: String
    let expiresAt: Date

    init?(owner: String, reply: OmnixTelegramReply, now: Date = .now) {
        guard !owner.isEmpty, reply.status.isValid, reply.status.state == .pairing,
              let connectionID = reply.status.connectionId, let pairing = reply.pairing,
              OmnixTelegramStatus.matches(pairing.code, #"[A-Za-z0-9_-]{32}"#),
              pairing.expiresAt.isFinite, pairing.expiresAt.rounded() == pairing.expiresAt,
              pairing.expiresAt > now.timeIntervalSince1970 * 1000, pairing.expiresAt < 9_007_199_254_740_991 else { return nil }
        self.owner = owner; self.connectionID = connectionID; code = pairing.code
        expiresAt = Date(timeIntervalSince1970: pairing.expiresAt / 1000)
    }
    func isValid(owner: String?, status: OmnixTelegramStatus?, now: Date = .now) -> Bool {
        self.owner == owner && status?.isValid == true && status?.state == .pairing
            && status?.connectionId == connectionID && expiresAt > now
    }
    func command(owner: String?, status: OmnixTelegramStatus?, now: Date = .now) -> String? {
        isValid(owner: owner, status: status, now: now) ? "/start " + code : nil
    }
    func botURL(owner: String?, status: OmnixTelegramStatus?, now: Date = .now) -> URL? {
        guard isValid(owner: owner, status: status, now: now), let username = status?.bot?.username,
              OmnixTelegramStatus.matches(username, #"[A-Za-z][A-Za-z0-9_]{4,31}"#) else { return nil }
        var url = URLComponents()
        url.scheme = "https"; url.host = "t.me"; url.path = "/" + username
        url.queryItems = [URLQueryItem(name: "start", value: code)]
        return url.url
    }
}
