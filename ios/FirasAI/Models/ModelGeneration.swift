import Foundation

/// Missing metadata means generation one in history, but a new picker defaults to 1.1.
/// Provider names and routing remain server-owned.
enum ModelGeneration: String, Codable, CaseIterable, Sendable, Identifiable {
    case legacy = ""
    case current = "1.1"
    var id: String { rawValue }
    var wireValue: String? { self == .current ? rawValue : nil }
    static func history(_ raw: String?) -> Self { raw == "1.1" ? .current : .legacy }
    static func preference(_ raw: String?) -> Self { raw == "" ? .legacy : .current }
    func label(_ tier: ModelTier, _ lang: AppLanguage) -> String {
        let name = tier.label(lang)
        return self == .current && name.hasSuffix(" 1") ? String(name.dropLast(2)) + " 1.1" : name
    }
    func capabilities(tier: ModelTier, thinking: Bool) -> ModelCapabilities {
        ModelCapabilities(tools: self == .current && !(tier == .pro && thinking),
                          skills: self == .current, steps: self == .current,
                          thinking: tier != .mini && tier != .omnix)
    }
}

struct ModelCapabilities: Sendable, Equatable {
    let tools: Bool
    let skills: Bool
    let steps: Bool
    let thinking: Bool
}
