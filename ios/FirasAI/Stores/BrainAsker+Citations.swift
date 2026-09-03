import Foundation

// The deterministic half of an ask (`web-brain-ux.md §7.5`, `§11.2`): reading SSE frames, trimming
// the history that rides with the grounding block, renumbering `[Sn]` markers to the hits the
// answer actually used, and writing the `firas-sources` fence the thread reads back.
extension BrainAsker {

    // MARK: - SSE

    /// `data: {"choices":[{"delta":{"content":"…"}}]}` — malformed frames are ignored, `[DONE]`
    /// ends the stream on its own when the socket closes (`server-chat-jobs-chats.md §1.7`).
    static func content(of frame: SSEFrame) -> String? {
        let payload = frame.data.trimmingCharacters(in: .whitespaces)
        if payload.isEmpty || payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let choices = object["choices"] as? [[String: Any]] else { return nil }
        guard let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }

    // MARK: - History

    /// The last 8 non-system turns with their fences stripped, then the question itself when the
    /// caller did not already put it in the history.
    static func historyMessages(_ history: [ChatMessage], question: String) -> [OutgoingMessage] {
        var kept: [OutgoingMessage] = []
        let recent = history.filter { $0.role == .user || $0.role == .assistant }.suffix(8)
        for message in recent {
            let content = stripFences(message.visibleContent).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            kept.append(OutgoingMessage(role: message.role.rawValue, content: content))
        }
        let last = kept.last
        if last == nil || last?.role != ChatRole.user.rawValue || last?.content != question {
            kept.append(OutgoingMessage(role: ChatRole.user.rawValue, content: question))
        }
        return kept
    }

    /// Drops every ```` ```firas-*``` ```` block; the model never needs to see a card's JSON.
    static func stripFences(_ markdown: String) -> String {
        guard markdown.contains("```firas-") else { return markdown }
        var out = ""
        var inFence = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inFence {
                if trimmed == "```" { inFence = false }
                continue
            }
            if trimmed.hasPrefix("```firas-") {
                if trimmed.hasSuffix("```") && trimmed.count > 9 && trimmed != "```firas-" {
                    // A single-line fence such as the compare marker.
                    continue
                }
                inFence = true
                continue
            }
            out += line + "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Citations

    struct Renumbered: Sendable {
        let text: String
        let sources: [BrainSource]
    }

    /// Keeps the hits the answer actually cited, in first-citation order, renumbers them `[S1…Sn]`
    /// and drops markers that point at nothing (`web-brain-ux.md §7.5`).
    static func renumberCitations(
        _ answer: String,
        hits: [BrainHit],
        lang: AppLanguage,
        startingAt first: Int = 1
    ) -> Renumbered {
        guard !hits.isEmpty else {
            return Renumbered(text: answer.trimmingCharacters(in: .whitespacesAndNewlines), sources: [])
        }

        let markers = citationOrder(in: answer)
        var order: [Int] = []
        for marker in markers where marker >= 1 && marker <= hits.count {
            if !order.contains(marker) { order.append(marker) }
        }
        if order.isEmpty {
            order = Array(1...min(3, hits.count))
        }

        var mapping: [Int: Int] = [:]
        for (offset, original) in order.enumerated() {
            mapping[original] = first + offset
        }

        let text = rewriteMarkers(answer, mapping: mapping)

        var sources: [BrainSource] = []
        for original in order {
            let index = original - 1
            guard index >= 0 && index < hits.count, let number = mapping[original] else { continue }
            let hit = hits[index]
            sources.append(
                BrainSource(
                    n: number,
                    docId: hit.docId,
                    title: hit.title,
                    page: hit.page,
                    label: hit.label,
                    ci: hit.ci,
                    s: String(hit.text.prefix(400)),
                    unit: hit.unit
                )
            )
        }
        return Renumbered(text: text.trimmingCharacters(in: .whitespacesAndNewlines), sources: sources)
    }

    /// Every `[S<n>]` in the order it appears.
    private static func citationOrder(in text: String) -> [Int] {
        var found: [Int] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            guard characters[index] == "[",
                  index + 2 < characters.count,
                  characters[index + 1] == "S",
                  characters[index + 2].isNumber else {
                index += 1
                continue
            }
            var cursor = index + 2
            var digits = ""
            while cursor < characters.count, characters[cursor].isNumber {
                digits.append(characters[cursor])
                cursor += 1
            }
            if cursor < characters.count, characters[cursor] == "]", let value = Int(digits) {
                found.append(value)
                index = cursor + 1
            } else {
                index += 1
            }
        }
        return found
    }

    private static func rewriteMarkers(_ text: String, mapping: [Int: Int]) -> String {
        var out = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            if characters[index] == "[",
               index + 2 < characters.count,
               characters[index + 1] == "S",
               characters[index + 2].isNumber {
                var cursor = index + 2
                var digits = ""
                while cursor < characters.count, characters[cursor].isNumber {
                    digits.append(characters[cursor])
                    cursor += 1
                }
                if cursor < characters.count, characters[cursor] == "]", let value = Int(digits) {
                    if let mapped = mapping[value] {
                        out += "[S\(mapped)]"
                    }
                    index = cursor + 1
                    continue
                }
            }
            out.append(characters[index])
            index += 1
        }
        return out
    }

    /// The persisted ```` ```firas-sources ```` block. Empty list → nothing at all.
    static func encodeSources(_ sources: [BrainSource]) -> String {
        guard !sources.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(sources),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return "\n\n```firas-sources\n" + json + "\n```"
    }

    // MARK: - Small helpers

    static func rangeLabel(_ range: ClosedRange<Int>?, lang: AppLanguage) -> String {
        guard let range else { return "" }
        if range.upperBound <= 0 || range.upperBound >= 1_000_000_000 {
            return ArabicText.count(range.lowerBound, lang) + "+"
        }
        return ArabicText.count(range.lowerBound, lang) + "–" + ArabicText.count(range.upperBound, lang)
    }

    /// A bilingual "d/t" notice: both languages are rendered now so the thread can follow the
    /// question's language rather than the UI's.
    static func progress(_ template: LText, _ done: Int, _ total: Int) -> LText {
        LText(
            ar: template.fmt(.arabic, ArabicText.count(done, .arabic), ArabicText.count(total, .arabic)),
            en: template.fmt(.english, ArabicText.count(done, .english), ArabicText.count(total, .english))
        )
    }
}
