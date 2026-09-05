import Foundation

/// What a screen should do about a failure. The presenter decides; the screen only obeys.
enum ErrorAction: Equatable, Sendable {
    /// Show a toast with localized copy.
    case toast(LText)
    /// Show a toast with copy that had to be formatted (a quota sentence, a limit number).
    case toastText(String)
    /// Open the sign-up prompt for this feature (guests only).
    case signUpPrompt(FeatureKey)
    /// The member's session is gone; `SessionStore` has already reacted.
    case sessionExpired
    /// Agent refused because another mission holds the credits.
    case blockedAgent(AgentActiveJob?, AgentCredits?)
    /// Agent refused because today's credits are spent or reserved.
    case creditsBlocked(AgentCredits?)
    /// The deployment has not configured this feature — hide it for this launch.
    case hideFeature(FeatureKey)
    /// Say nothing.
    case silent
}

/// The single place that turns an `Error` into user-visible copy.
///
/// It maps **by HTTP status and error code**, never by the server's sentence: the server answers in
/// English for auth and in Arabic for account management, and the app must never leak either into
/// the wrong UI language. The table is `ARCHITECTURE.md §2.15`.
enum ErrorPresenter {

    // MARK: - Live errors

    static func present(_ error: Error, feature: FeatureKey?, isGuest: Bool, lang: AppLanguage) -> ErrorAction {
        if error is CancellationError { return .silent }
        if error is DeadlineError { return .toast(Strings.Errors.timeout) }

        if let urlError = error as? URLError {
            return transportAction(urlError)
        }

        guard let apiError = error as? APIError else {
            return .toast(Strings.Errors.generic)
        }

        switch apiError {
        case .invalidURL, .decoding:
            return .toast(Strings.Errors.generic)
        case .offline:
            return .toast(Strings.Errors.offline)
        case .cancelled:
            return .silent
        case .deadline:
            return .toast(Strings.Errors.timeout)
        case .transport(let urlError):
            return transportAction(urlError)
        case .http(let status, let server, _):
            return httpAction(status: status, server: server, feature: feature, isGuest: isGuest, lang: lang)
        }
    }

    private static func transportAction(_ error: URLError) -> ErrorAction {
        switch error.code {
        case .cancelled: return .silent
        case .timedOut: return .toast(Strings.Errors.timeout)
        default: return .toast(Strings.Errors.offline)
        }
    }

    // MARK: - Job terminals

    static func presentJobTerminal(_ terminal: JobTerminal, kind: JobKind, isGuest: Bool, lang: AppLanguage) -> ErrorAction {
        let feature = featureKey(for: kind)
        switch terminal {
        case .completed:
            return .silent
        case .cancelled:
            return .silent
        case .expired:
            return .toast(Strings.Errors.timeout)
        case .forbidden:
            return .silent
        case .unauthorized:
            return isGuest ? .signUpPrompt(feature) : .sessionExpired
        case .refused(let status, let server):
            return httpAction(status: status, server: server, feature: feature, isGuest: isGuest, lang: lang)
        case .failed(let code, _):
            return failedAction(code: normalized(code), kind: kind, feature: feature, isGuest: isGuest, lang: lang)
        }
    }

    // MARK: - Quota copy

    /// The member 🚦 sentence, with the limit in Arabic-Indic digits for Arabic.
    static func quotaText(product: String?, limit: Int?, lang: AppLanguage) -> String {
        let name = Strings.Errors.productName(product).text(lang)
        let limitText = ArabicText.count(limit ?? 0, lang)
        return Strings.Errors.quotaMember.fmt(lang, name, limitText)
    }

    /// Same, but a guest gets the sign-up sentence instead of a number they cannot raise.
    static func quotaText(product: String?, limit: Int?, isGuest: Bool, scope: String?, lang: AppLanguage) -> String {
        guard isGuest else { return quotaText(product: product, limit: limit, lang: lang) }
        if normalized(scope ?? "") == "network" {
            return Strings.Errors.guestNetworkLimit(lang)
        }
        return Strings.Errors.guestLimitReached(lang)
    }

    // MARK: - Status table

    private static func httpAction(
        status: Int,
        server: ServerError,
        feature: FeatureKey?,
        isGuest: Bool,
        lang: AppLanguage
    ) -> ErrorAction {
        let code = normalized(server.code ?? "")
        let resolvedFeature = feature ?? featureKey(named: server.feature) ?? .generic

        switch status {
        case 401:
            return isGuest ? .signUpPrompt(resolvedFeature) : .sessionExpired

        case 403:
            if server.isSignInRequired { return .signUpPrompt(resolvedFeature) }
            if code == "not_yours" || code == "forbidden" { return .silent }
            return genericAction(code: code, lang: lang)

        case 409:
            if code == "agent_busy" { return .blockedAgent(server.activeJob, server.credits) }
            return genericAction(code: code, lang: lang)

        case 429:
            return rateAction(code: code, server: server, feature: resolvedFeature, isGuest: isGuest, lang: lang)

        case 400:
            return badRequestAction(code: code, server: server, lang: lang)

        case 413:
            if code == "image_too_large" || code == "bad_image" { return .toast(Strings.Errors.badImage) }
            return genericAction(code: code, lang: lang)

        case 501:
            if code == "not_configured" { return .hideFeature(resolvedFeature) }
            return genericAction(code: code, lang: lang)

        case 502, 503:
            if code == "not_configured" { return .hideFeature(resolvedFeature) }
            return .toast(Strings.Errors.serverBusy)

        default:
            return genericAction(code: code, lang: lang)
        }
    }

    private static func rateAction(
        code: String,
        server: ServerError,
        feature: FeatureKey,
        isGuest: Bool,
        lang: AppLanguage
    ) -> ErrorAction {
        if code == "credits_reserved" || code == "credits_exhausted" {
            return .creditsBlocked(server.credits)
        }
        if code == "daily_limit" {
            return .toastText(dailyLimitText(feature: feature, limit: server.limit, lang: lang))
        }
        if code == "rate_window" {
            if let minutes = server.freesInMin {
                return .toastText(Strings.Errors.mediaRateWindow.fmt(lang, ArabicText.count(minutes, lang)))
            }
            return .toast(Strings.Errors.musicRateWindow)
        }
        if code == "site_media_ceiling" {
            return .toast(Strings.Errors.mediaBusyToday)
        }
        if code.contains("daily max") {
            return .toastText(Strings.Errors.maxLimit.fmt(lang, ArabicText.count(server.limit ?? 0, lang)))
        }

        let quota = server.quota
        let isQuotaDenial = quota != nil
            || code == "daily quota reached"
            || code == "guest daily limit reached"
        if isQuotaDenial {
            let guestDenial = isGuest || server.guest == true || normalized(quota?.plan ?? "") == "guest"
            if guestDenial { return .signUpPrompt(feature) }
            return .toastText(quotaText(product: quota?.product, limit: quota?.limit ?? server.limit, lang: lang))
        }

        if code.contains("too many attempts") {
            return .toast(Strings.Errors.tooManyAttempts)
        }
        return .toast(Strings.Errors.tooFast)
    }

    private static func dailyLimitText(feature: FeatureKey, limit: Int?, lang: AppLanguage) -> String {
        switch feature {
        case .video:
            return Strings.Errors.videoDailyLimit(lang)
        case .music:
            return Strings.Errors.musicRateWindow(lang)
        default:
            guard let limit else { return Strings.Errors.imageQuotaCard(lang) }
            return Strings.Errors.imageDailyLimit.fmt(lang, ArabicText.count(limit, lang))
        }
    }

    private static func badRequestAction(code: String, server: ServerError, lang: AppLanguage) -> ErrorAction {
        let raw = server.code ?? ""
        if raw.contains("يسجّل عبر Google") || raw.contains("يسجل عبر Google") {
            return .toast(Strings.Errors.googleAccount)
        }
        if code.contains("name is required") { return .toast(Strings.Errors.nameRequired) }
        if code.contains("valid email") { return .toast(Strings.Errors.emailInvalid) }
        if code.contains("password must be") { return .toast(Strings.Errors.passwordShort) }
        if code.contains("already registered") { return .toast(Strings.Errors.emailTaken) }
        if code.contains("invalid email or password") { return .toast(Strings.Errors.credentials) }
        if code == "bad_image" { return .toast(Strings.Errors.badImage) }
        return genericAction(code: code, lang: lang)
    }

    // MARK: - Per-kind failure tables

    private static func failedAction(
        code: String,
        kind: JobKind,
        feature: FeatureKey,
        isGuest: Bool,
        lang: AppLanguage
    ) -> ErrorAction {
        switch kind {
        case .agentrun:
            return agentFailure(code: code, isGuest: isGuest)
        case .codebuild:
            return codeFailure(code: code)
        case .brainask:
            return brainFailure(code: code, isGuest: isGuest)
        case .image, .video, .music:
            return mediaFailure(code: code, kind: kind, feature: feature, lang: lang)
        case .chat, .longdoc, .longfile, .counteddoc:
            if code == "engine_failed" || code == "no_answer" { return .toast(Strings.Errors.serverBusy) }
            return genericAction(code: code, lang: lang)
        }
    }

    /// `server-agent.md §5.5` codes → `server-agent.md §11.2` copy (verbatim).
    private static func agentFailure(code: String, isGuest: Bool) -> ErrorAction {
        switch code {
        case "account_required", "signin_required":
            return isGuest ? .signUpPrompt(.agent) : .toast(Strings.Errors.agentSignIn)
        case "agent_busy":
            return .toast(Strings.Errors.agentBusy)
        case "credits_exhausted":
            return .toast(Strings.Errors.agentCreditsSpent)
        case "credits_reserved":
            return .toast(Strings.Errors.agentCreditsReserved)
        case "capacity", "agent_unavailable", "agent_start_unconfirmed", "storage_unavailable":
            return .toast(Strings.Errors.serverBusy)
        case "forbidden", "job_not_found":
            return .silent
        case "rate_limited":
            return .toast(Strings.Errors.tooFast)
        default:
            return .toast(Strings.Errors.agentFailed)
        }
    }

    /// `server-code-brainask.md §2.7`.
    private static func codeFailure(code: String) -> ErrorAction {
        switch code {
        case "storage_unavailable", "payload_missing", "user_not_found":
            return .toast(Strings.Errors.serverBusy)
        case "no_answer":
            return .toast(Strings.Errors.codeEngineUnreachable)
        default:
            return .toast(Strings.Errors.codeBuildFailed)
        }
    }

    /// `server-code-brainask.md §3.4`.
    private static func brainFailure(code: String, isGuest: Bool) -> ErrorAction {
        if code.hasPrefix("brain_search_429") {
            if code.contains("guest daily limit") { return .signUpPrompt(.brain) }
            return .toast(Strings.Errors.tooFast)
        }
        if code.hasPrefix("brain_search_403") {
            return isGuest ? .signUpPrompt(.brain) : .sessionExpired
        }
        switch code {
        case "storage_unavailable", "payload_missing", "user_not_found":
            return .toast(Strings.Errors.serverBusy)
        default:
            return .toast(Strings.Errors.brainEngineFailed)
        }
    }

    /// `server-media.md §1.8 / §2.7 / §3.6 / §5`.
    private static func mediaFailure(code: String, kind: JobKind, feature: FeatureKey, lang: AppLanguage) -> ErrorAction {
        if code == "signin_required" || code == "account_required" {
            return .signUpPrompt(feature)
        }
        if code == "not_configured" {
            return .hideFeature(feature)
        }
        if code == "daily_limit" {
            return .toastText(dailyLimitText(feature: feature, limit: nil, lang: lang))
        }
        if code == "rate_window" || code == "site_media_ceiling" {
            return kind == .music
                ? .toast(Strings.Errors.musicRateWindow)
                : .toast(Strings.Errors.mediaBusyToday)
        }
        if code == "bad_image" || code == "image_too_large" {
            return .toast(Strings.Errors.badImage)
        }
        switch kind {
        case .video:
            return .toast(Strings.Errors.videoFailed)
        case .music:
            return .toast(Strings.Errors.musicFailed)
        default:
            return .toast(Strings.Errors.imageEngineFailed)
        }
    }

    // MARK: - Helpers

    /// Which sign-up prompt a job belongs to.
    static func featureKey(for kind: JobKind) -> FeatureKey {
        switch kind {
        case .image: return .image
        case .video: return .video
        case .music: return .music
        case .agentrun: return .agent
        case .brainask: return .brain
        case .chat, .longdoc, .longfile, .counteddoc, .codebuild: return .generic
        }
    }

    /// The server's `feature` field, when it sends one.
    static func featureKey(named raw: String?) -> FeatureKey? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return FeatureKey(rawValue: trimmed)
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The generic line. The raw server code is only ever shown in a DEBUG build.
    private static func genericAction(code: String, lang: AppLanguage) -> ErrorAction {
        #if DEBUG
        if !code.isEmpty {
            return .toastText(Strings.Errors.generic(lang) + " [" + code + "]")
        }
        #endif
        return .toast(Strings.Errors.generic)
    }
}
