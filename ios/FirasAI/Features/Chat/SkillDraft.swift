import Foundation
import Perception

struct SkillMention: Equatable {
    var id: String
    var range: NSRange
}

struct SkillSlashToken: Equatable {
    var range: NSRange
    var query: String

    static func scan(_ text: String, selection: NSRange) -> SkillSlashToken? {
        let source = text as NSString
        guard selection.length == 0, selection.location <= source.length, selection.location >= 0 else { return nil }
        let before = source.substring(to: selection.location)
        var fence: String?
        let lines = before.components(separatedBy: "\n")
        for line in lines.dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence { if trimmed.hasPrefix(active) { fence = nil } }
            else if trimmed.hasPrefix("```") { fence = "```" }
            else if trimmed.hasPrefix("~~~") { fence = "~~~" }
        }
        guard fence == nil, let line = lines.last, !line.trimmingCharacters(in: .whitespaces).hasPrefix("```"),
              !line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~"),
              let slash = line.lastIndex(of: "/") else { return nil }
        let prefix = line[..<slash]
        guard prefix.isEmpty || prefix.last?.isWhitespace == true,
              prefix.filter({ $0 == "`" }).count % 2 == 0 else { return nil }
        let query = String(line[line.index(after: slash)...])
        guard !query.contains(where: \.isWhitespace), !query.contains("/"), query.utf16.count <= 80 else { return nil }
        return SkillSlashToken(range: NSRange(location: selection.location - query.utf16.count - 1, length: query.utf16.count + 1), query: query)
    }
}

@MainActor @Perceptible
final class SkillDraft {
    private(set) var mentions: [SkillMention] = []
    private(set) var previous = ""
    var pastes: [PastedTextItem] = []
    var selection = NSRange(location: 0, length: 0)
    var dismissedStart: Int?
    var highlighted = 0

    func synchronize(_ text: String) {
        guard text != previous else { return }
        if mentions.isEmpty {
            previous = text; highlighted = 0
            if SkillSlashToken.scan(text, selection: selection) == nil { dismissedStart = nil }
            return
        }
        let old = Array(previous.utf16), new = Array(text.utf16)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        while suffix < min(old.count, new.count) - prefix, old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let removedEnd = old.count - suffix
        let delta = new.count - old.count
        mentions = mentions.compactMap { mention in
            var value = mention
            if NSMaxRange(value.range) <= prefix { return value }
            if value.range.location >= removedEnd { value.range.location += delta; return value }
            return nil // Editing any part of a name removes its binding; it becomes ordinary text.
        }
        previous = text
        highlighted = 0
        if SkillSlashToken.scan(text, selection: selection) == nil { dismissedStart = nil }
    }
    func token(_ text: String) -> SkillSlashToken? {
        guard let token = SkillSlashToken.scan(text, selection: selection), token.range.location != dismissedStart,
              !mentions.contains(where: { NSIntersectionRange($0.range, token.range).length > 0 }) else { return nil }
        return token
    }
    func insert(_ skill: AccountSkill, token: SkillSlashToken, into text: String) -> String? {
        synchronize(text)
        guard SkillSlashToken.scan(text, selection: selection) == token,
              mentions.count < 3, !mentions.contains(where: { $0.id == skill.id }) else { return nil }
        let name = "/" + skill.name
        let next = (text as NSString).replacingCharacters(in: token.range, with: name + " ")
        synchronize(next)
        mentions.append(SkillMention(id: skill.id, range: NSRange(location: token.range.location, length: name.utf16.count)))
        selection = NSRange(location: token.range.location + name.utf16.count + 1, length: 0)
        dismissedStart = nil
        return next
    }
    func snapshot(text: String, store: AccountSkillsStore) -> [AccountSkill] {
        synchronize(text)
        return store.selected(mentions.map(\.id))
    }
    func retainValid(skills: [AccountSkill], text: String) {
        let source = text as NSString
        mentions.removeAll { mention in
            guard mention.range.location >= 0, NSMaxRange(mention.range) <= source.length,
                  let skill = skills.first(where: { $0.id == mention.id && $0.enabled }) else { return true }
            return source.substring(with: mention.range) != "/" + skill.name
        }
    }
    func reset() { mentions = []; pastes = []; previous = ""; selection = NSRange(location: 0, length: 0); dismissedStart = nil; highlighted = 0 }
}
