import Foundation

// MARK: - Speakable text

extension TTSPlayer {

    /// Markdown → something worth hearing: no fences, no tables, no link targets, no emphasis
    /// punctuation. `$` is deliberately left alone so "$5 for tea" is not mangled.
    nonisolated static func speakable(_ markdown: String) -> String {
        var lines: [String] = []
        var insideFence = false

        for raw in markdown.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            if insideFence { continue }
            if trimmed.isEmpty {
                lines.append("")
                continue
            }
            if trimmed.hasPrefix("|") { continue }
            if isRule(trimmed) { continue }
            let cleaned = inlineClean(stripLeaders(trimmed))
            if !cleaned.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(cleaned)
            }
        }

        let joined = lines.joined(separator: "\n")
        let spaced = joined.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )
        let tightened = spaced.replacingOccurrences(
            of: "\n{2,}",
            with: "\n",
            options: .regularExpression
        )
        return tightened.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `.!?؟،؛\n`, packed to ≤ 1 300 characters, never cut mid-sentence unless one sentence is
    /// longer than the whole budget (then it is cut on whitespace).
    nonisolated static func chunks(of text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?"
                || character == "؟" || character == "،" || character == "؛" || character == "\n" {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }

        var out: [String] = []
        var buffer = ""

        for sentence in sentences {
            var piece = sentence
            while piece.count > chunkLimit {
                if !buffer.isEmpty {
                    out.append(buffer)
                    buffer = ""
                }
                let cut = splitPoint(piece)
                out.append(String(piece.prefix(cut)))
                piece = String(piece.dropFirst(cut))
            }
            if buffer.count + piece.count > chunkLimit {
                out.append(buffer)
                buffer = piece
            } else {
                buffer += piece
            }
        }
        if !buffer.isEmpty { out.append(buffer) }

        return out
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Pieces

    nonisolated private static func splitPoint(_ piece: String) -> Int {
        let characters = Array(piece)
        var cut = min(chunkLimit, characters.count)
        var scan = cut - 1
        while scan > chunkLimit / 2 {
            if characters[scan] == " " || characters[scan] == "\n" {
                cut = scan + 1
                break
            }
            scan -= 1
        }
        return max(1, cut)
    }

    nonisolated private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let set: Set<Character> = ["-", "*", "_", " "]
        return line.allSatisfy { set.contains($0) }
    }

    nonisolated private static func stripLeaders(_ line: String) -> String {
        var body = line[line.startIndex...]
        while let first = body.first, first == "#" || first == ">" {
            body = body.dropFirst()
        }
        body = body.drop(while: { $0 == " " })

        if let first = body.first, first == "-" || first == "*" || first == "+" {
            let rest = body.dropFirst()
            if rest.first == " " { body = rest.dropFirst() }
        } else {
            let digits = body.prefix(while: { $0.isNumber })
            if !digits.isEmpty {
                let after = body.dropFirst(digits.count)
                if after.first == "." || after.first == ")" {
                    let tail = after.dropFirst()
                    if tail.first == " " { body = tail.dropFirst() }
                }
            }
        }
        return String(body)
    }

    nonisolated private static func inlineClean(_ input: String) -> String {
        let characters = Array(input)
        var out = ""
        var index = 0
        var htmlDepth = 0

        while index < characters.count {
            let character = characters[index]

            if character == "<" {
                htmlDepth += 1
                index += 1
                continue
            }
            if character == ">" {
                if htmlDepth > 0 { htmlDepth -= 1 }
                index += 1
                continue
            }
            if htmlDepth > 0 {
                index += 1
                continue
            }

            if character == "!", index + 1 < characters.count, characters[index + 1] == "[" {
                if let end = linkEnd(characters, from: index + 1) {
                    index = end
                    continue
                }
            }
            if character == "[" {
                if let end = linkEnd(characters, from: index) {
                    let closing = closingBracket(characters, from: index) ?? index
                    if closing > index + 1 {
                        out += String(characters[(index + 1)..<closing])
                    }
                    index = end
                    continue
                }
            }
            if character == "*" || character == "_" || character == "`" || character == "~" {
                index += 1
                continue
            }

            out.append(character)
            index += 1
        }

        return out
    }

    /// Index just past the `)` of a `[…](…)` pair starting at `start`, or `nil` when this `[` is
    /// not a link after all.
    nonisolated private static func linkEnd(_ characters: [Character], from start: Int) -> Int? {
        guard let closing = closingBracket(characters, from: start) else { return nil }
        guard closing + 1 < characters.count, characters[closing + 1] == "(" else { return nil }
        var scan = closing + 2
        while scan < characters.count {
            if characters[scan] == ")" { return scan + 1 }
            scan += 1
        }
        return nil
    }

    nonisolated private static func closingBracket(
        _ characters: [Character],
        from start: Int
    ) -> Int? {
        var scan = start + 1
        while scan < characters.count {
            if characters[scan] == "]" { return scan }
            if characters[scan] == "\n" { return nil }
            scan += 1
        }
        return nil
    }
}
