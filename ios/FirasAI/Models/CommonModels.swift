import Foundation

nonisolated enum AppAPIValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: AppAPIValue])
    case array([AppAPIValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AppAPIValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AppAPIValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

nonisolated enum ModelTier: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case mini
    case pro
    case ultra
    case max

    var id: String { rawValue }

    var labelArabic: String {
        switch self {
        case .mini: "فِراس ميني"
        case .pro: "فِراس برو"
        case .ultra: "فِراس أولترا"
        case .max: "فِراس ماكس"
        }
    }

    var labelEnglish: String {
        switch self {
        case .mini: "Firas Mini"
        case .pro: "Firas Pro"
        case .ultra: "Firas Ultra"
        case .max: "Firas Max"
        }
    }

    var taglineArabic: String {
        switch self {
        case .mini: "سريع للأسئلة اليومية"
        case .pro: "متوازن وذكي"
        case .ultra: "قويّ جدًا — الأفضل للأكواد"
        case .max: "الأقوى — أعلى ذكاء وتفكير"
        }
    }

    var taglineEnglish: String {
        switch self {
        case .mini: "Fast for everyday questions"
        case .pro: "Balanced & smart"
        case .ultra: "Very powerful — best for code"
        case .max: "Strongest — top intelligence"
        }
    }

    @MainActor
    func label(language: AppLanguage) -> String {
        language == .arabic ? labelArabic : labelEnglish
    }

    @MainActor
    func tagline(language: AppLanguage) -> String {
        language == .arabic ? taglineArabic : taglineEnglish
    }
}

nonisolated enum ProductKind: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case ai
    case code
    case agent
    case brain

    var id: String { rawValue }
}
