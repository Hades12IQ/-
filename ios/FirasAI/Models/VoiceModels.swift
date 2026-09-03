import Foundation

/// `POST /api/live/token`. The OpenAI leg carries a `voice`; the Gemini leg does not (its voice is
/// chosen client-side at setup). `startWithinMs` bounds the dial, `maxMs` bounds the call.
struct LiveToken: Decodable, Sendable, Equatable {
    var provider: String
    var token: String
    var model: String
    var voice: String?
    /// The call ceiling in milliseconds. Nothing on the OpenAI side enforces it — the client's own
    /// hard timer is the only ceiling there.
    var maxMs: Int
    var guest: Bool
    /// Open the session within this many milliseconds (60 000).
    var startWithinMs: Int

    init(
        provider: String,
        token: String,
        model: String,
        voice: String? = nil,
        maxMs: Int = 600_000,
        guest: Bool = false,
        startWithinMs: Int = 60_000
    ) {
        self.provider = provider
        self.token = token
        self.model = model
        self.voice = voice
        self.maxMs = maxMs
        self.guest = guest
        self.startWithinMs = startWithinMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        provider = LenientJSON.string(container, "provider") ?? ""
        token = LenientJSON.string(container, "token") ?? ""
        model = LenientJSON.string(container, "model") ?? ""
        voice = LenientJSON.string(container, "voice")
        maxMs = LenientJSON.int(container, "maxMs") ?? 600_000
        guest = LenientJSON.bool(container, "guest") ?? false
        startWithinMs = LenientJSON.int(container, "startWithinMs") ?? 60_000
    }

    var isOpenAI: Bool { provider.lowercased() == "openai" }
    var isGemini: Bool { provider.lowercased() == "gemini" }
}

/// `CALL_VOICE_ALLOW` — the five voices the OpenAI realtime session accepts. Anything else is
/// silently replaced by the server default, `cedar`.
enum CallVoice: String, CaseIterable, Codable, Sendable, Identifiable {
    case cedar
    case ash
    case verse
    case echo
    case ballad

    var id: String { rawValue }

    var label: LText {
        switch self {
        case .cedar: return LText(ar: "سِدر", en: "Cedar")
        case .ash: return LText(ar: "رماد", en: "Ash")
        case .verse: return LText(ar: "بيت شعر", en: "Verse")
        case .echo: return LText(ar: "صدى", en: "Echo")
        case .ballad: return LText(ar: "موّال", en: "Ballad")
        }
    }
}

/// The dictation dialects. The raw value is the BCP-47-shaped device key that is persisted;
/// `serverKey` is the `STT_HINTS` key `/api/transcribe` understands, and `bcp47` is what
/// `SFSpeechRecognizer` gets when the server path is unavailable.
enum DictationDialect: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto
    case ar
    case arIQ = "ar-IQ"
    case arSA = "ar-SA"
    case arEG = "ar-EG"
    case arLB = "ar-LB"
    case arMA = "ar-MA"
    case arAE = "ar-AE"
    case en
    case enUS = "en-US"
    case enGB = "en-GB"
    case fr
    case de
    case tr

    var id: String { rawValue }

    /// The `STT_HINTS` key sent as `lang`; an unknown key means "no hint", which is `auto`.
    var serverKey: String {
        switch self {
        case .auto: return "auto"
        case .ar: return "msa"
        case .arIQ: return "iraqi"
        case .arSA, .arAE: return "gulf"
        case .arEG: return "egyptian"
        case .arLB: return "levant"
        case .arMA: return "maghrebi"
        case .en, .enUS, .enGB: return "en"
        case .fr: return "fr"
        case .de: return "de"
        case .tr: return "tr"
        }
    }

    /// The locale for the on-device recogniser. `auto` falls back to `ar-SA`.
    var bcp47: String {
        switch self {
        case .auto, .ar: return "ar-SA"
        case .arIQ: return "ar-IQ"
        case .arSA: return "ar-SA"
        case .arEG: return "ar-EG"
        case .arLB: return "ar-LB"
        case .arMA: return "ar-MA"
        case .arAE: return "ar-AE"
        case .en, .enUS: return "en-US"
        case .enGB: return "en-GB"
        case .fr: return "fr-FR"
        case .de: return "de-DE"
        case .tr: return "tr-TR"
        }
    }

    var label: LText {
        switch self {
        case .auto:
            return LText(ar: "تلقائي — يتعرّف على لغتك من كلامك", en: "Auto — detects your language")
        case .ar:
            return LText(ar: "العربية الفصحى", en: "Arabic (Fus'ha)")
        case .arIQ:
            return LText(ar: "عراقية", en: "Iraqi Arabic")
        case .arSA:
            return LText(ar: "خليجية", en: "Gulf Arabic")
        case .arEG:
            return LText(ar: "مصرية", en: "Egyptian Arabic")
        case .arLB:
            return LText(ar: "شامية", en: "Levantine Arabic")
        case .arMA:
            return LText(ar: "مغاربية", en: "Maghrebi Arabic")
        case .arAE:
            return LText(ar: "إماراتية", en: "Emirati Arabic")
        case .en:
            return LText(ar: "الإنجليزية", en: "English")
        case .enUS:
            return LText(ar: "الإنجليزية (أمريكا)", en: "English (US)")
        case .enGB:
            return LText(ar: "الإنجليزية (بريطانيا)", en: "English (UK)")
        case .fr:
            return LText(ar: "الفرنسية", en: "French")
        case .de:
            return LText(ar: "الألمانية", en: "German")
        case .tr:
            return LText(ar: "التركية", en: "Turkish")
        }
    }

    /// The short form for the dictation bar chip.
    var shortLabel: LText {
        switch self {
        case .auto: return LText(ar: "تلقائي", en: "Auto")
        case .ar: return LText(ar: "فصحى", en: "MSA")
        case .arIQ: return LText(ar: "عراقية", en: "Iraqi")
        case .arSA: return LText(ar: "خليجية", en: "Gulf")
        case .arEG: return LText(ar: "مصرية", en: "Egyptian")
        case .arLB: return LText(ar: "شامية", en: "Levantine")
        case .arMA: return LText(ar: "مغاربية", en: "Maghrebi")
        case .arAE: return LText(ar: "إماراتية", en: "Emirati")
        case .en: return LText(ar: "English", en: "English")
        case .enUS: return LText(ar: "English (US)", en: "English (US)")
        case .enGB: return LText(ar: "English (UK)", en: "English (UK)")
        case .fr: return LText(ar: "Français", en: "French")
        case .de: return LText(ar: "Deutsch", en: "German")
        case .tr: return LText(ar: "Türkçe", en: "Turkish")
        }
    }

    var flag: String {
        switch self {
        case .auto: return "🌐"
        case .ar: return "📖"
        case .arIQ: return "🇮🇶"
        case .arSA: return "🇸🇦"
        case .arEG: return "🇪🇬"
        case .arLB: return "🇱🇧"
        case .arMA: return "🇲🇦"
        case .arAE: return "🇦🇪"
        case .en, .enUS: return "🇺🇸"
        case .enGB: return "🇬🇧"
        case .fr: return "🇫🇷"
        case .de: return "🇩🇪"
        case .tr: return "🇹🇷"
        }
    }
}

/// `POST /api/transcribe`. An empty `text` means "nothing clear was heard", not an error.
struct TranscribeResponse: Decodable, Sendable {
    var text: String?
    var lang: String?
    var error: String?
    /// The answer to `{"probe": true}` — whether server-side transcription is configured at all.
    var ok: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        text = LenientJSON.string(container, "text")
        lang = LenientJSON.string(container, "lang")
        error = LenientJSON.string(container, "error")
        ok = LenientJSON.bool(container, "ok")
    }
}
