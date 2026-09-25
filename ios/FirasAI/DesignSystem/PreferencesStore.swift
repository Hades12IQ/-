import Foundation
import Perception
/// Every device preference, backed by `UserDefaults`. The keys are the ones the Codex build already
/// wrote, so an existing install keeps its theme, language and tier across the rewrite.
///
/// Each preference is a hand-written computed property over `@PerceptionIgnored` storage rather
/// than a stored property with a `didSet`: the `@Perceptible` macro turns every eligible stored
/// property into a computed one, and a property observer cannot coexist with the getter the macro
/// installs. `access(keyPath:)` / `withMutation(keyPath:)` are the macro's own entry points, so
/// observation behaves exactly as it would for a plain stored property, and the write to
/// `UserDefaults` happens on the same turn as the mutation.
@MainActor
@Perceptible
final class PreferencesStore {

    // MARK: - Appearance

    var theme: FirasTheme {
        get { access(keyPath: \.theme); return storedTheme }
        set {
            withMutation(keyPath: \.theme) { storedTheme = newValue }
            persist(newValue.rawValue, forKey: Keys.theme)
        }
    }

    var language: AppLanguage {
        get { access(keyPath: \.language); return storedLanguage }
        set {
            withMutation(keyPath: \.language) { storedLanguage = newValue }
            persist(newValue.rawValue, forKey: Keys.language)
        }
    }

    var fontScale: FontScale {
        get { access(keyPath: \.fontScale); return storedFontScale }
        set {
            withMutation(keyPath: \.fontScale) { storedFontScale = newValue }
            persist(newValue.rawValue, forKey: Keys.fontScale)
        }
    }

    var contentWidth: ContentWidth {
        get { access(keyPath: \.contentWidth); return storedContentWidth }
        set {
            withMutation(keyPath: \.contentWidth) { storedContentWidth = newValue }
            persist(newValue.rawValue, forKey: Keys.width)
        }
    }

    var motionPreference: MotionPreference {
        get { access(keyPath: \.motionPreference); return storedMotionPreference }
        set {
            withMutation(keyPath: \.motionPreference) { storedMotionPreference = newValue }
            persist(newValue.rawValue, forKey: Keys.motion)
        }
    }

    // MARK: - Chat

    var tier: ModelTier {
        get { access(keyPath: \.tier); return storedTier }
        set {
            withMutation(keyPath: \.tier) { storedTier = newValue }
            persist(newValue.rawValue, forKey: Keys.tier)
        }
    }

    var modelGeneration: ModelGeneration {
        get { access(keyPath: \.modelGeneration); return storedModelGeneration }
        set {
            withMutation(keyPath: \.modelGeneration) { storedModelGeneration = newValue }
            persist(newValue.rawValue, forKey: Keys.modelGeneration)
        }
    }

    var responseMode: ResponseMode {
        get { access(keyPath: \.responseMode); return storedResponseMode }
        set {
            withMutation(keyPath: \.responseMode) { storedResponseMode = newValue }
            persist(newValue.rawValue, forKey: Keys.responseMode)
        }
    }

    var webSearchEnabled: Bool {
        get { access(keyPath: \.webSearchEnabled); return storedWebSearchEnabled }
        set {
            withMutation(keyPath: \.webSearchEnabled) { storedWebSearchEnabled = newValue }
            persist(newValue, forKey: Keys.webSearch)
        }
    }

    var thinkingEnabled: Bool {
        get { access(keyPath: \.thinkingEnabled); return storedThinkingEnabled }
        set {
            withMutation(keyPath: \.thinkingEnabled) { storedThinkingEnabled = newValue }
            persist(newValue, forKey: Keys.thinking)
        }
    }

    var sendOnReturn: Bool {
        get { access(keyPath: \.sendOnReturn); return storedSendOnReturn }
        set {
            withMutation(keyPath: \.sendOnReturn) { storedSendOnReturn = newValue }
            persist(newValue, forKey: Keys.sendOnReturn)
        }
    }

    var sharpenImages: Bool {
        get { access(keyPath: \.sharpenImages); return storedSharpenImages }
        set {
            withMutation(keyPath: \.sharpenImages) { storedSharpenImages = newValue }
            persist(newValue, forKey: Keys.sharpenImages)
        }
    }

    // MARK: - Voice

    var callVoice: CallVoice {
        get { access(keyPath: \.callVoice); return storedCallVoice }
        set {
            withMutation(keyPath: \.callVoice) { storedCallVoice = newValue }
            persist(newValue.rawValue, forKey: Keys.callVoice)
        }
    }

    var bargeInEnabled: Bool {
        get { access(keyPath: \.bargeInEnabled); return storedBargeInEnabled }
        set {
            withMutation(keyPath: \.bargeInEnabled) { storedBargeInEnabled = newValue }
            persist(newValue, forKey: Keys.bargeIn)
        }
    }

    var dictationDialect: DictationDialect {
        get { access(keyPath: \.dictationDialect); return storedDictationDialect }
        set {
            withMutation(keyPath: \.dictationDialect) { storedDictationDialect = newValue }
            persist(newValue.rawValue, forKey: Keys.dictationDialect)
        }
    }

    var uiSoundsEnabled: Bool {
        get { access(keyPath: \.uiSoundsEnabled); return storedUISoundsEnabled }
        set {
            withMutation(keyPath: \.uiSoundsEnabled) { storedUISoundsEnabled = newValue }
            persist(newValue, forKey: Keys.uiSounds)
        }
    }

    // MARK: - Lifecycle flags

    // Not offered in Settings; never cleared by `resetToDefaults`.

    var guestActive: Bool {
        get { access(keyPath: \.guestActive); return storedGuestActive }
        set {
            withMutation(keyPath: \.guestActive) { storedGuestActive = newValue }
            persist(newValue, forKey: Keys.guestActive)
        }
    }

    var consentAccepted: Bool {
        get { access(keyPath: \.consentAccepted); return storedConsentAccepted }
        set {
            withMutation(keyPath: \.consentAccepted) { storedConsentAccepted = newValue }
            persist(newValue, forKey: Keys.consentAccepted)
        }
    }

    var notificationsExplained: Bool {
        get { access(keyPath: \.notificationsExplained); return storedNotificationsExplained }
        set {
            withMutation(keyPath: \.notificationsExplained) { storedNotificationsExplained = newValue }
            persist(newValue, forKey: Keys.notificationsExplained)
        }
    }

    var lastSeenAnnouncementAt: Double {
        get { access(keyPath: \.lastSeenAnnouncementAt); return storedLastSeenAnnouncementAt }
        set {
            withMutation(keyPath: \.lastSeenAnnouncementAt) { storedLastSeenAnnouncementAt = newValue }
            persist(newValue, forKey: Keys.lastSeenAnnouncementAt)
        }
    }

    // MARK: - Derived

    var palette: FirasPalette { theme.palette }

    var lang: AppLanguage { language }

    var motionEnabled: Bool {
        get { motionPreference == .full }
        set { motionPreference = newValue ? .full : .reduced }
    }

    // MARK: - Storage

    @PerceptionIgnored private let defaults: UserDefaults

    @PerceptionIgnored private var storedTheme: FirasTheme
    @PerceptionIgnored private var storedLanguage: AppLanguage
    @PerceptionIgnored private var storedFontScale: FontScale
    @PerceptionIgnored private var storedContentWidth: ContentWidth
    @PerceptionIgnored private var storedMotionPreference: MotionPreference
    @PerceptionIgnored private var storedModelGeneration: ModelGeneration
    @PerceptionIgnored private var storedTier: ModelTier
    @PerceptionIgnored private var storedResponseMode: ResponseMode
    @PerceptionIgnored private var storedWebSearchEnabled: Bool
    @PerceptionIgnored private var storedThinkingEnabled: Bool
    @PerceptionIgnored private var storedSendOnReturn: Bool
    @PerceptionIgnored private var storedSharpenImages: Bool
    @PerceptionIgnored private var storedCallVoice: CallVoice
    @PerceptionIgnored private var storedBargeInEnabled: Bool
    @PerceptionIgnored private var storedDictationDialect: DictationDialect
    @PerceptionIgnored private var storedUISoundsEnabled: Bool
    @PerceptionIgnored private var storedGuestActive: Bool
    @PerceptionIgnored private var storedConsentAccepted: Bool
    @PerceptionIgnored private var storedNotificationsExplained: Bool
    @PerceptionIgnored private var storedLastSeenAnnouncementAt: Double

    // MARK: - Lifecycle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        storedTheme = FirasTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .dark
        storedLanguage = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "")
            ?? AppLanguage.deviceDefault
        storedFontScale = FontScale(rawValue: defaults.string(forKey: Keys.fontScale) ?? "") ?? .medium
        storedContentWidth = ContentWidth(rawValue: defaults.string(forKey: Keys.width) ?? "") ?? .normal

        if let rawMotion = defaults.string(forKey: Keys.motion),
           let savedMotion = MotionPreference(rawValue: rawMotion) {
            storedMotionPreference = savedMotion
        } else if let legacyMotion = defaults.object(forKey: Keys.motion) as? Bool {
            storedMotionPreference = legacyMotion ? .full : .reduced
        } else {
            storedMotionPreference = .full
        }

        storedModelGeneration = .preference(defaults.string(forKey: Keys.modelGeneration))
        storedTier = ModelTier(rawValue: defaults.string(forKey: Keys.tier) ?? "") ?? .pro
        storedResponseMode = ResponseMode(rawValue: defaults.string(forKey: Keys.responseMode) ?? "") ?? .auto
        storedWebSearchEnabled = defaults.object(forKey: Keys.webSearch) as? Bool ?? false
        storedThinkingEnabled = defaults.object(forKey: Keys.thinking) as? Bool ?? false
        storedSendOnReturn = defaults.object(forKey: Keys.sendOnReturn) as? Bool ?? false
        storedSharpenImages = defaults.object(forKey: Keys.sharpenImages) as? Bool ?? false

        storedCallVoice = CallVoice(rawValue: defaults.string(forKey: Keys.callVoice) ?? "") ?? .cedar
        /* ON by default since 2026-09-03. The web defaults it off, and that inheritance produced
           the complaint: "المكالمة من اقاطعه ما يتقاطع، يكمل كلامه عادي". A phone call you cannot
           cut into is not a conversation, and every voice assistant a person has used lets them
           cut in. A device that switched it off keeps it off — the `object(forKey:)` read tells a
           stored false apart from never-asked. */
        storedBargeInEnabled = defaults.object(forKey: Keys.bargeIn) as? Bool ?? true
        storedDictationDialect = PreferencesStore.storedDialect(defaults.string(forKey: Keys.dictationDialect))
        /* The app has its own two-note bell now, and a completion you cannot hear is a completion
           you wait for. Off stays off on a device that chose it. */
        storedUISoundsEnabled = defaults.object(forKey: Keys.uiSounds) as? Bool ?? true

        storedGuestActive = defaults.object(forKey: Keys.guestActive) as? Bool ?? false
        storedConsentAccepted = defaults.object(forKey: Keys.consentAccepted) as? Bool ?? false
        storedNotificationsExplained = defaults.object(forKey: Keys.notificationsExplained) as? Bool ?? false
        storedLastSeenAnnouncementAt = defaults.object(forKey: Keys.lastSeenAnnouncementAt) as? Double ?? 0
    }

    /// Resets the preferences Settings offers. Session cookies, chats, drafts, imports, the guest
    /// flag and the consent record are untouched.
    func resetToDefaults() {
        theme = .dark
        language = AppLanguage.deviceDefault
        fontScale = .medium
        contentWidth = .normal
        motionPreference = .full

        tier = .pro
        modelGeneration = .current
        responseMode = .auto
        webSearchEnabled = false
        thinkingEnabled = false
        sendOnReturn = false
        sharpenImages = false

        callVoice = .cedar
        bargeInEnabled = true
        dictationDialect = .auto
        uiSoundsEnabled = true

        for key in Keys.resettable {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Plumbing

    private func persist(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    /// The Codex build stored `automatic|arabic|english` under the same key; map those forward once.
    private static func storedDialect(_ raw: String?) -> DictationDialect {
        guard let raw, !raw.isEmpty else { return .auto }
        if let dialect = DictationDialect(rawValue: raw) { return dialect }
        switch raw {
        case "automatic": return .auto
        case "arabic": return .ar
        case "english": return .en
        default: return .auto
        }
    }

    private enum Keys {
        static let theme = "theme"
        static let language = "lang"
        static let modelGeneration = "modelGeneration"
        static let tier = "tier"
        static let responseMode = "responseMode"
        static let fontScale = "fontSize"
        static let width = "width"
        static let webSearch = "webSearch"
        static let thinking = "thinking"
        static let motion = "motion"
        static let sendOnReturn = "enterSend"
        static let sharpenImages = "imageSharpening"
        static let callVoice = "callVoice"
        static let bargeIn = "bargeIn"
        static let dictationDialect = "dictationLanguage"
        static let uiSounds = "uiSounds"
        static let guestActive = "guestActive"
        static let consentAccepted = "consentAccepted"
        static let notificationsExplained = "notificationsExplained"
        static let lastSeenAnnouncementAt = "lastSeenAnnouncementAt"

        static let resettable: [String] = [
            theme, language, tier, modelGeneration, responseMode, fontScale, width, webSearch, thinking,
            motion, sendOnReturn, sharpenImages, callVoice, bargeIn, dictationDialect, uiSounds,
        ]
    }
}
