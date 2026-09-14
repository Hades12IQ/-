import Foundation

struct AccountSkill: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var cues: [String]
    var rules: [String]
    var mode: String = "auto"
    var enabled: Bool = true
}

struct SkillLibraryEntry: Decodable, Identifiable, Sendable {
    var id: String
    var name: String
    var cues: [String]
    var rules: [String]
    var domain: String
    var section: String
    var origin: String?
    var editableCopy: AccountSkill { AccountSkill(id: "", name: name, cues: cues, rules: rules) }
}

struct SkillLibrarySection: Decodable, Identifiable, Sendable {
    var id: String
    var title: String
    var count: Int
}

struct SkillLibraryResponse: Decodable, Sendable {
    var sections: [SkillLibrarySection]?
    var library: [SkillLibraryEntry]?
    var total: Int
    var title: String?
    var origin: String?
}

struct AccountSkillsResponse: Decodable, Sendable { var skills: [AccountSkill] }
struct AccountSkillResponse: Decodable, Sendable { var skill: AccountSkill }
struct SkillSaveRequest: Encodable, Sendable {
    var id: String?
    var name: String
    var cues: [String]
    var rules: [String]
    var mode: String
    var enabled: Bool
    init(_ skill: AccountSkill) {
        id = skill.id.isEmpty ? nil : skill.id
        name = skill.name; cues = skill.cues; rules = skill.rules
        mode = skill.mode; enabled = skill.enabled
    }
}
struct SkillToggleRequest: Encodable, Sendable { var id: String; var enabled: Bool }

enum SkillSearch {
    // Search keys only; original text is always stored, displayed and sent verbatim.
    static func fold(_ text: String) -> String {
        var result = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        for (from, to) in [("أ", "ا"), ("إ", "ا"), ("آ", "ا"), ("ٱ", "ا"), ("ى", "ي"), ("ة", "ه"), ("ک", "ك"), ("ی", "ي"), ("ـ", "")] {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return String(result.unicodeScalars.filter { !CharacterSet.nonBaseCharacters.contains($0) })
    }
}

enum SkillValidation {
    static func problems(_ skill: AccountSkill) -> [String] {
        var errors: [String] = []
        let name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.utf16.count < 3 { errors.append("name_too_short") }
        if name.utf16.count > 80 { errors.append("name_too_long") }
        if skill.cues.count < 3 { errors.append("cues_too_few") }
        if skill.cues.count > 24 { errors.append("cues_too_many") }
        for (i, cue) in skill.cues.enumerated() where !(2...60).contains(cue.utf16.count) { errors.append("cue_length:\(i)") }
        if skill.rules.count < 4 { errors.append("rules_too_few") }
        if skill.rules.count > 24 { errors.append("rules_too_many") }
        for (i, rule) in skill.rules.enumerated() {
            if rule.utf16.count < 28 { errors.append("rule_too_short:\(i)") }
            if rule.utf16.count > 300 { errors.append("rule_too_long:\(i)") }
        }
        if skill.rules.map({ "- " + $0 }).joined(separator: "\n").utf16.count > 2600 { errors.append("rules_too_long_total") }
        return errors
    }
}
