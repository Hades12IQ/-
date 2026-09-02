import Foundation

/// The two languages the app speaks. Arabic is the product's first language; English is the
/// fallback for a device that asks for it.
///
/// `Models` never imports SwiftUI, so there is deliberately no `layoutDirection` here — direction
/// is decided per island by `BidiText.direction(of:)`.
enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case arabic = "ar"
    case english = "en"

    var id: String { rawValue }

    var locale: Locale { Locale(identifier: rawValue) }

    var isArabic: Bool { self == .arabic }

    /// The other language — used by the language toggle.
    var toggled: AppLanguage { self == .arabic ? .english : .arabic }

    /// The web's boot rule (`app.js`): English only when the device's first preferred language is
    /// an English variant; everything else gets Arabic.
    static var deviceDefault: AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? "ar"
        return preferred.lowercased().hasPrefix("en") ? .english : .arabic
    }
}

/// The four model tiers of the web `MODELS` table (`web-chat-ux.md §3.1`).
///
/// No tier is locked to a plan — every tier is free for everyone.
enum ModelTier: String, CaseIterable, Codable, Sendable, Identifiable {
    case mini
    case pro
    case ultra
    case max

    var id: String { rawValue }

    /// `mini` never streams reasoning; the web sends `think = toggle && showThinking`.
    var showThinking: Bool { self != .mini }

    /// `max_tokens` from the web table.
    var tokenCap: Int {
        switch self {
        case .mini: return 2048
        case .pro, .ultra, .max: return 16384
        }
    }

    var label: LText {
        switch self {
        case .mini: return LText(ar: "فِراس ميني", en: "Firas Mini")
        case .pro: return LText(ar: "فِراس برو", en: "Firas Pro")
        case .ultra: return LText(ar: "فِراس أولترا", en: "Firas Ultra")
        case .max: return LText(ar: "فِراس ماكس", en: "Firas Max")
        }
    }

    var short: LText {
        switch self {
        case .mini: return LText(ar: "ميني", en: "Mini")
        case .pro: return LText(ar: "برو", en: "Pro")
        case .ultra: return LText(ar: "أولترا", en: "Ultra")
        case .max: return LText(ar: "ماكس", en: "Max")
        }
    }

    var tagline: LText {
        switch self {
        case .mini: return LText(ar: "سريع للأسئلة اليومية", en: "Fast for everyday questions")
        case .pro: return LText(ar: "متوازن وذكي", en: "Balanced & smart")
        case .ultra: return LText(ar: "قويّ جدًا — الأفضل للأكواد", en: "Very powerful — best for code")
        case .max: return LText(ar: "الأقوى — أعلى ذكاء وتفكير", en: "Strongest — top intelligence")
        }
    }

    /// `TIER_BADGE` — only `max` and `ultra` carry one, and only inside the picker.
    var badge: LText? {
        switch self {
        case .max: return LText(ar: "الأقوى", en: "Strongest")
        case .ultra: return LText(ar: "للأكواد", en: "For code")
        case .mini, .pro: return nil
        }
    }

    /// `TIER_ICON` translated to SF Symbols.
    var symbol: String {
        switch self {
        case .mini: return "bolt.fill"
        case .pro: return "bolt.horizontal.fill"
        case .ultra: return "star.fill"
        case .max: return "crown.fill"
        }
    }

    /// Unknown server strings silently become `pro`, exactly like the server (`:12767`).
    static func lenient(_ raw: String?) -> ModelTier {
        guard let raw, let tier = ModelTier(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return .pro
        }
        return tier
    }
}

/// The five destinations of the product switcher. `studio` is native-only and never leaves the
/// device: media requests are sent with `product: "ai"`.
enum ProductKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case ai
    case agent
    case code
    case brain
    case studio

    var id: String { rawValue }

    /// What goes on the wire in a `product` field.
    var wireValue: String { self == .studio ? "ai" : rawValue }

    var title: LText {
        switch self {
        case .ai: return LText(ar: "فِراس AI", en: "Firas AI")
        case .agent: return LText(ar: "فِراس Agent", en: "Firas Agent")
        case .code: return LText(ar: "فِراس Code", en: "Firas Code")
        case .brain: return LText(ar: "فِراس Brain", en: "Firas Brain")
        case .studio: return LText(ar: "الاستوديو", en: "Studio")
        }
    }

    var symbol: String {
        switch self {
        case .ai: return "message.fill"
        case .agent: return "sparkles"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .brain: return "brain"
        case .studio: return "photo.on.rectangle.angled"
        }
    }

    /// A server `product` string back into a product; anything unknown is `ai` (`:12882`).
    static func lenient(_ raw: String?) -> ProductKind {
        guard let raw else { return .ai }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "agent": return .agent
        case "code": return .code
        case "brain": return .brain
        default: return .ai
        }
    }
}

/// The composer's answer mode. `plan` is the ask → plan → approve → execute cycle
/// (`web-plan-mode.md`); it is a device preference snapshotted onto a conversation when a cycle
/// starts, and it is only ever evaluated inside the chat product.
enum ResponseMode: String, Codable, Sendable {
    case auto
    case plan
}

/// Which sign-up prompt / which feature a refusal belongs to. Raw values match the server's
/// `feature` field.
enum FeatureKey: String, Sendable {
    case generic
    case image
    case video
    case music
    case live
    case agent
    case brain
    case brainWhole = "brain_whole"
    case share
    case memory
}

/// A JSON value of a shape the server has not promised to keep stable — the `surface` blob on a
/// job status, mostly. Decoding never throws on an unexpected shape.
enum AppAPIValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([AppAPIValue])
    case object([String: AppAPIValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AppAPIValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AppAPIValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> AppAPIValue? {
        guard case .object(let dictionary) = self else { return nil }
        return dictionary[key]
    }

    subscript(index: Int) -> AppAPIValue? {
        guard case .array(let items) = self, index >= 0, index < items.count else { return nil }
        return items[index]
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            // `Int(_:)` traps on a finite double outside Int's range, and a `surface` blob is
            // server-shaped: a number the size of a timestamp in nanoseconds must not crash a read.
            guard value.isFinite, value >= -9.2e18, value <= 9.2e18 else { return nil }
            return Int(value.rounded())
        case .string(let value): return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool(let value): return value ? 1 : 0
        case .null, .array, .object: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool(let value): return value ? 1 : 0
        case .null, .array, .object: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1", "on": return true
            case "false", "no", "0", "off": return false
            default: return nil
            }
        case .null, .array, .object: return nil
        }
    }

    var arrayValue: [AppAPIValue]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    var objectValue: [String: AppAPIValue]? {
        guard case .object(let dictionary) = self else { return nil }
        return dictionary
    }

    var isNull: Bool { self == .null }
}
