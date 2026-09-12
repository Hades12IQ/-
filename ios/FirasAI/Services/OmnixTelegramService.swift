import Foundation
import Observation

enum OmnixTelegramService {
    struct Configuration: Encodable, Sendable { let botToken: String; let telegramUserId: Int64 }
    static let path = "/api/omnix/telegram"

    static func isUserID(_ number: Int64) -> Bool { number > 0 && number < 4_503_599_627_370_496 }
    static func userID(_ input: String) -> Int64? {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { scalar -> String in
            if (0x0660...0x0669).contains(scalar.value) { return String(scalar.value - 0x0660) }
            if (0x06f0...0x06f9).contains(scalar.value) { return String(scalar.value - 0x06f0) }
            return String(scalar)
        }.joined()
        guard OmnixTelegramStatus.matches(normalized, #"[1-9][0-9]{0,15}"#),
              let value = Int64(normalized), isUserID(value) else { return nil }
        return value
    }
    static func validToken(_ value: String) -> Bool {
        OmnixTelegramStatus.matches(value, #"[1-9][0-9]{4,19}:[A-Za-z0-9_-]{30,200}"#)
    }
    static func status(api: APIClient) async throws -> OmnixTelegramReply {
        try await request(.get, path, api: api)
    }
    static func configure(token: String, userID: Int64, api: APIClient) async throws -> OmnixTelegramReply {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validToken(token), isUserID(userID) else { throw APIError.decoding("telegram_configuration_invalid") }
        return try await request(.post, path, body: Configuration(botToken: token, telegramUserId: userID), api: api)
    }
    static func disconnect(api: APIClient) async throws -> OmnixTelegramReply {
        try await request(.post, path + "/disconnect", body: OmnixEmpty(), api: api)
    }
    private static func request(_ method: HTTPMethod, _ path: String,
                                body: (any Encodable & Sendable)? = nil, api: APIClient) async throws -> OmnixTelegramReply {
        // One attempt only. An unconfirmed mutation is followed by GET, never a second POST.
        // Decode here to keep the one-time response out of APIClient's debug decode logging.
        let (bytes, _) = try await api.raw(method, path, body: body, budget: .poll)
        guard let result = try? JSONDecoder().decode(OmnixTelegramReply.self, from: bytes), result.status.isValid else {
            throw APIError.decoding("telegram_response_invalid")
        }
        return result
    }

    static func message(_ error: Error, lang: AppLanguage) -> String {
        let code: String?
        if case let APIError.http(_, server, _) = error { code = server.code } else { code = nil }
        let ar = lang == .arabic
        switch code {
        case "telegram_user_id_required": return ar ? "أدخل معرّف حسابك الشخصي الرقمي في تيليغرام؛ ليس رقم الهاتف أو اسم المستخدم." : "Enter your personal numeric Telegram user ID, not a phone number or username."
        case "telegram_private_bot_required": return ar ? "عطّل الانضمام للمجموعات عبر /setjoingroups في BotFather، وأوقف أوضاع inline وguest وbusiness." : "Disable group joining with /setjoingroups in BotFather, and turn off inline, guest and business modes."
        case "telegram_token_required", "telegram_token_invalid", "telegram_bot_invalid": return ar ? "تحقّق من رمز البوت الكامل الذي أعطاك إياه BotFather." : "Check the complete bot token supplied by BotFather."
        case "telegram_bot_already_linked": return ar ? "البوت مرتبط بالفعل. انتظر تأكيد إزالة الربط قبل المحاولة ببوت آخر." : "A bot is already linked. Wait for confirmed removal before trying another bot."
        case "omnix_approval_required", "omnix_cloud_preparing": return ar ? "تحتاج موافقة أومنكس ومساحة حساب سحابية جاهزة قبل الربط." : "Omnix approval and a ready cloud workspace are required before linking."
        default:
            if (error as? APIError)?.status == 429 { return ar ? "محاولات كثيرة. انتظر قليلًا ثم حدّث الحالة." : "Too many attempts. Wait a little, then refresh status." }
            if (error as? APIError)?.status == 401 { return ar ? "سجّل الدخول من جديد لعرض الربط الخاص بحسابك." : "Sign in again to view your account's connection." }
            return ar ? "لم تتأكد العملية. حدّث الحالة قبل المحاولة مجددًا؛ قد يكون الخادم استلم طلبك." : "The operation was not confirmed. Refresh before trying again; the server may have received your request."
        }
    }
}

/// Sheet-scoped; owner and generation checks discard every late response after leaving/sign-out.
@MainActor @Observable
final class OmnixTelegramSettingsModel {
    private(set) var status: OmnixTelegramStatus?
    private(set) var pairing: OmnixTelegramPairing?
    private(set) var busy = false
    private(set) var notice: String?
    private(set) var owner: String?
    private var generation = 0
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let session: SessionStore

    init(api: APIClient, session: SessionStore) { self.api = api; self.session = session }
    func activate() {
        deactivate()
        if session.isMember { owner = session.identityID }
    }
    func deactivate() {
        generation += 1; owner = nil; status = nil; pairing = nil; notice = nil; busy = false
    }
    private func current(_ owner: String, _ generation: Int) -> Bool {
        self.owner == owner && self.generation == generation && session.isMember && session.identityID == owner
    }
    func expirePairing(now: Date = .now) {
        if pairing?.isValid(owner: owner, status: status, now: now) != true { pairing = nil }
    }
    private func accept(_ reply: OmnixTelegramReply, owner: String, permitsPairing: Bool) {
        status = reply.status
        if permitsPairing { pairing = OmnixTelegramPairing(owner: owner, reply: reply) }
        expirePairing()
    }
    func refresh(lang: AppLanguage) async {
        guard !busy, let owner, session.identityID == owner, session.isMember else { return }
        let generation = self.generation
        busy = true; notice = nil
        defer { if current(owner, generation) { busy = false } }
        do {
            let reply = try await OmnixTelegramService.status(api: api)
            guard current(owner, generation) else { return }
            accept(reply, owner: owner, permitsPairing: false)
        } catch {
            guard current(owner, generation) else { return }
            // A stale ready flag must never permit another mutation after a failed refresh.
            status = nil; pairing = nil
            notice = OmnixTelegramService.message(error, lang: lang)
        }
    }
    func configure(token: String, userID: Int64, lang: AppLanguage) async {
        guard status?.mayConfigure == true else { return }
        await mutate(lang: lang) { [api] in try await OmnixTelegramService.configure(token: token, userID: userID, api: api) }
    }
    func disconnect(lang: AppLanguage) async {
        guard status?.state.canDisconnect == true else { return }
        await mutate(lang: lang) { [api] in try await OmnixTelegramService.disconnect(api: api) }
    }
    private func mutate(lang: AppLanguage, action: () async throws -> OmnixTelegramReply) async {
        guard !busy, let owner, session.identityID == owner, session.isMember else { return }
        let generation = self.generation
        busy = true; notice = nil; pairing = nil
        status = nil // No second submission is enabled until authoritative read-back.
        defer { if current(owner, generation) { busy = false } }
        var mutationError: String?
        do {
            let reply = try await action()
            guard current(owner, generation) else { return }
            accept(reply, owner: owner, permitsPairing: true)
        } catch {
            guard current(owner, generation) else { return }
            mutationError = OmnixTelegramService.message(error, lang: lang)
        }
        do {
            let reply = try await OmnixTelegramService.status(api: api)
            guard current(owner, generation) else { return }
            accept(reply, owner: owner, permitsPairing: false)
            notice = mutationError
        } catch {
            guard current(owner, generation) else { return }
            // A confirmed pairing response remains usable even if its immediate GET fails.
            // Its public response cannot enable configuration because it has no ready flags.
            notice = mutationError ?? OmnixTelegramService.message(error, lang: lang)
        }
    }
}
