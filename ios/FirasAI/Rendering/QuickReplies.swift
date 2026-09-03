import SwiftUI

/// The follow-up chips under a finished answer (`web-chat-ux.md §8.2`, item 8).
///
/// Topics are lifted from the answer's own headings and bullet leads — never invented — and each
/// chip hands the composer one sentence: `اشرح لي «…» بتفصيل أكثر`. The row draws nothing at all
/// when the answer is a card turn (any recognised `firas-*` fence) or when no structural line was
/// found, which is how the web hides it on card, truncated and plan turns.
///
/// The caller decides the other two hiding rules it owns — a visible Start pill or an open ask
/// panel — by simply not placing this view.
struct QuickReplies: View {

    private let markdown: String
    private let lang: AppLanguage
    private let palette: FirasPalette
    private let onPick: (String) -> Void

    init(
        from markdown: String,
        lang: AppLanguage,
        palette: FirasPalette,
        onPick: @escaping (String) -> Void
    ) {
        self.markdown = markdown
        self.lang = lang
        self.palette = palette
        self.onPick = onPick
    }

    var body: some View {
        chips(QuickReplies.topics(in: markdown))
    }

    // MARK: - Row

    @ViewBuilder
    private func chips(_ topics: [String]) -> some View {
        if topics.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(topics, id: \.self) { topic in
                        FirasPill(
                            text: topic,
                            symbol: nil,
                            selected: false,
                            palette: palette
                        ) {
                            Haptics.select()
                            onPick(QuickReplyCopy.ask.fmt(lang, topic))
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .bidiIsland(for: topics.joined(separator: " "), fallback: lang)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(QuickReplyCopy.aria(lang)))
        }
    }

    // MARK: - Topic extraction

    /// At most four topics, in the order they appear: `##`…`####` headings first-come, then bullet
    /// and numbered-list leads. Anything inside a fenced code block is skipped.
    static func topics(in markdown: String) -> [String] {
        guard FirasFence.firstFence(in: markdown) == nil else { return [] }

        var found: [String] = []
        var seen: Set<String> = []
        var insideFence = false

        for rawLine in markdown.components(separatedBy: "\n") {
            if found.count >= maximumChips { break }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            if insideFence { continue }
            guard let topic = candidate(in: trimmed) else { continue }
            let key = ArabicText.normalize(topic).lowercased()
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            found.append(topic)
        }
        return found
    }

    private static let maximumChips = 4
    private static let minimumLength = 3
    private static let maximumLength = 48

    private static func candidate(in trimmed: String) -> String? {
        guard !trimmed.isEmpty else { return nil }

        var body: String
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            guard hashes >= 2, hashes <= 4 else { return nil }
            body = String(trimmed.dropFirst(hashes))
        } else if let bullet = bulletBody(trimmed) {
            body = bullet
        } else {
            return nil
        }

        body = cleaned(body)
        let count = body.count
        guard count >= minimumLength, count <= maximumLength else { return nil }
        return body
    }

    /// `- text`, `* text`, `+ text`, `1. text`, `2) text` — and nothing else.
    private static func bulletBody(_ trimmed: String) -> String? {
        var characters = Array(trimmed)
        guard characters.count > 2 else { return nil }

        if characters[0] == "-" || characters[0] == "*" || characters[0] == "+" {
            guard characters[1] == " " else { return nil }
            return String(characters.dropFirst(2))
        }

        var index = 0
        while index < characters.count, characters[index].isNumber, index < 3 {
            index += 1
        }
        guard index > 0, index + 1 < characters.count else { return nil }
        guard characters[index] == "." || characters[index] == ")" else { return nil }
        guard characters[index + 1] == " " else { return nil }
        characters.removeFirst(index + 2)
        return String(characters)
    }

    /// Strips list checkboxes and inline markdown, keeps the part before a colon or dash, and trims
    /// stray punctuation from both ends.
    private static func cleaned(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)

        for marker in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count))
        }

        var stripped = ""
        stripped.reserveCapacity(text.count)
        for character in text where !markdownNoise.contains(character) {
            stripped.append(character)
        }

        for separator in [":", "：", "—", "–", " - "] {
            if let range = stripped.range(of: separator), range.lowerBound != stripped.startIndex {
                stripped = String(stripped[stripped.startIndex..<range.lowerBound])
                break
            }
        }

        var result = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, trailingNoise.contains(last) {
            result.removeLast()
        }
        while let first = result.first, trailingNoise.contains(first) {
            result.removeFirst()
        }

        // Collapse runs of whitespace so a chip never carries a tab or a double space.
        let pieces = result.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return pieces.joined(separator: " ")
    }

    private static let markdownNoise: Set<Character> = ["*", "_", "`", "#", "~"]
    private static let trailingNoise: Set<Character> = [".", "،", ":", "؛", ";", "-", "–", "—", " "]
}

/// The two strings this row needs. They stay `LText` so the view never holds a bare literal, and
/// the wording is the web's `qreplyAsk` / `qreplyAria` verbatim (`web-chat-ux.md` Appendix A).
private enum QuickReplyCopy {
    /// `qreplyAsk` — `{q}` is `%@` here so it goes through `LText.fmt`.
    static let ask = LText(
        ar: "اشرح لي «%@» بتفصيل أكثر",
        en: "Explain “%@” in more detail"
    )
    static let aria = LText(ar: "أسئلة متابعة مقترحة", en: "Suggested follow-ups")
}
