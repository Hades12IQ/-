import SwiftUI

/// The character-class predicates, the little searches, and the coloured output buffer the three
/// scanners are built from.
///
/// Split out of `CodeHighlighter.swift` so the scanners read as scanners: nothing in here knows
/// what a keyword is, and nothing in there compares a byte to a number.
extension CodeHighlighter {

    // MARK: - Byte helpers

    /// Named ASCII bytes, so no scanner line reads `b[i] == 60`.
    enum Byte {
        static let newline: UInt8 = 0x0A
        static let carriageReturn: UInt8 = 0x0D
        static let tab: UInt8 = 0x09
        static let space: UInt8 = 0x20
        static let doubleQuote = UInt8(ascii: "\"")
        static let singleQuote = UInt8(ascii: "'")
        static let backtick = UInt8(ascii: "`")
        static let backslash = UInt8(ascii: "\\")
        static let slash = UInt8(ascii: "/")
        static let hash = UInt8(ascii: "#")
        static let dash = UInt8(ascii: "-")
        static let dot = UInt8(ascii: ".")
        static let at = UInt8(ascii: "@")
        static let colon = UInt8(ascii: ":")
        static let semicolon = UInt8(ascii: ";")
        static let percent = UInt8(ascii: "%")
        static let less = UInt8(ascii: "<")
        static let greater = UInt8(ascii: ">")
        static let openBrace = UInt8(ascii: "{")
        static let closeBrace = UInt8(ascii: "}")
    }

    static func text(_ b: [UInt8], _ from: Int, _ to: Int) -> String {
        guard to > from, from >= 0, to <= b.count else { return "" }
        return String(decoding: b[from..<to], as: UTF8.self)
    }

    static func matches(_ b: [UInt8], _ index: Int, _ end: Int, _ needle: String) -> Bool {
        let bytes = Array(needle.utf8)
        guard !bytes.isEmpty, index + bytes.count <= end else { return false }
        var k = 0
        while k < bytes.count {
            if b[index + k] != bytes[k] { return false }
            k += 1
        }
        return true
    }

    /// The index of `needle` at or after `from`, or `end` when it is not there.
    static func find(_ b: [UInt8], _ from: Int, _ end: Int, _ needle: String) -> Int {
        let bytes = Array(needle.utf8)
        guard !bytes.isEmpty else { return end }
        var i = max(from, 0)
        let last = end - bytes.count
        while i <= last {
            if b[i] == bytes[0] {
                var k = 1
                while k < bytes.count, b[i + k] == bytes[k] { k += 1 }
                if k == bytes.count { return i }
            }
            i += 1
        }
        return end
    }

    /// Same, folding ASCII case — HTML closing tags are written both ways.
    static func findIgnoringCase(_ b: [UInt8], _ from: Int, _ end: Int, _ needle: String) -> Int {
        let bytes = Array(needle.lowercased().utf8)
        guard !bytes.isEmpty else { return end }
        var i = max(from, 0)
        let last = end - bytes.count
        while i <= last {
            var k = 0
            while k < bytes.count, lowered(b[i + k]) == bytes[k] { k += 1 }
            if k == bytes.count { return i }
            i += 1
        }
        return end
    }

    static func lowered(_ c: UInt8) -> UInt8 {
        (c >= 65 && c <= 90) ? c + 32 : c
    }

    static func lineEnd(_ b: [UInt8], _ from: Int, _ end: Int) -> Int {
        var j = from
        while j < end, b[j] != Byte.newline { j += 1 }
        return j
    }

    static func startsLine(_ b: [UInt8], _ index: Int, _ lower: Int) -> Bool {
        var k = index - 1
        while k >= lower {
            let d = b[k]
            if d == Byte.space || d == Byte.tab { k -= 1; continue }
            return d == Byte.newline || d == Byte.carriageReturn
        }
        return true
    }

    static func stringEnd(_ b: [UInt8], _ from: Int, _ end: Int, quote: UInt8, multiline: Bool) -> Int {
        var j = from + 1
        while j < end {
            let d = b[j]
            if d == Byte.backslash { j += 2; continue }
            if d == quote { return min(j + 1, end) }
            if !multiline, d == Byte.newline { return j }
            j += 1
        }
        return end
    }

    static func isTripleQuote(_ b: [UInt8], _ index: Int, _ end: Int) -> Bool {
        guard index + 2 < end else { return false }
        let c = b[index]
        guard c == Byte.doubleQuote || c == Byte.singleQuote else { return false }
        return b[index + 1] == c && b[index + 2] == c
    }

    static func hasLineComment(_ b: [UInt8], _ index: Int, _ end: Int, _ spec: Spec) -> Bool {
        for marker in spec.lineComments where matches(b, index, end, marker) { return true }
        return false
    }

    static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    static func isLowerLetter(_ c: UInt8) -> Bool { c >= 97 && c <= 122 }

    static func isUpperLetter(_ c: UInt8) -> Bool { c >= 65 && c <= 90 }

    static func isIdentifierStart(_ c: UInt8) -> Bool {
        isLowerLetter(c) || isUpperLetter(c) || c == UInt8(ascii: "_") || c == UInt8(ascii: "$") || c >= 0x80
    }

    static func isIdentifierPart(_ c: UInt8) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }

    static func isNumberPart(_ c: UInt8) -> Bool {
        isDigit(c) || c == Byte.dot || c == UInt8(ascii: "_")
            || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)
            || c == UInt8(ascii: "x") || c == UInt8(ascii: "X")
    }

    static func isTagNamePart(_ c: UInt8) -> Bool {
        isIdentifierPart(c) || c == Byte.dash || c == Byte.colon
    }

    static func isCSSNameStart(_ c: UInt8) -> Bool {
        isIdentifierStart(c) || c == Byte.dot || c == Byte.hash || c == Byte.dash
    }

    static func isCSSNamePart(_ c: UInt8) -> Bool {
        isIdentifierPart(c) || c == Byte.dash
    }

    /// A byte that can safely join the current punctuation run: it cannot open any other token.
    static func isFillerByte(_ c: UInt8) -> Bool {
        if c >= 0x80 { return false }
        if isIdentifierStart(c) || isDigit(c) { return false }
        switch c {
        case Byte.doubleQuote, Byte.singleQuote, Byte.backtick, Byte.slash, Byte.hash, Byte.dash:
            return false
        default:
            return true
        }
    }

    static func isCSSFillerByte(_ c: UInt8) -> Bool {
        if c >= 0x80 { return false }
        if isIdentifierStart(c) || isDigit(c) { return false }
        switch c {
        case Byte.doubleQuote, Byte.singleQuote, Byte.slash, Byte.hash, Byte.dash,
             Byte.at, Byte.openBrace, Byte.closeBrace, Byte.colon, Byte.semicolon, Byte.dot:
            return false
        default:
            return true
        }
    }

    // MARK: - Tones

    enum Tone: Equatable {
        case plain
        case comment
        case keyword
        case type
        case string
        case number
        case tag
        case attribute
        case punct
    }

    /// The nine colours a listing is allowed to use, all of them palette tokens.
    struct Tones {
        let plain: Color
        let comment: Color
        let keyword: Color
        let type: Color
        let string: Color
        let number: Color
        let tag: Color
        let attribute: Color
        let punct: Color

        init(palette: FirasPalette) {
            plain = palette.textPrimary
            comment = palette.textMuted
            // A lighter step of the accent's own hue. With the accent muted to a low-chroma
            // grey-green, `accent` and `plain` differ mostly in hue at nearly the same
            // lightness, and a listing with no lightness contrast reads flat.
            keyword = palette.accentHover
            type = palette.planDiamond
            string = palette.codeOk
            number = palette.planGold
            tag = palette.planDiamond
            attribute = palette.maxTierText
            punct = palette.textSecondary
        }

        func color(_ tone: Tone) -> Color {
            switch tone {
            case .plain: return plain
            case .comment: return comment
            case .keyword: return keyword
            case .type: return type
            case .string: return string
            case .number: return number
            case .tag: return tag
            case .attribute: return attribute
            case .punct: return punct
            }
        }
    }

    /// Buffers one tone at a time so a run of identical bytes becomes a single append.
    struct Emitter {
        private var out = AttributedString()
        private var buffer = ""
        private var tone: Tone = .plain
        private let tones: Tones

        init(tones: Tones) {
            self.tones = tones
        }

        mutating func add(_ piece: String, _ next: Tone) {
            if piece.isEmpty { return }
            if next == tone {
                buffer += piece
                return
            }
            flush()
            tone = next
            buffer = piece
        }

        mutating func flush() {
            guard !buffer.isEmpty else { return }
            var piece = AttributedString(buffer)
            piece.foregroundColor = tones.color(tone)
            out.append(piece)
            buffer = ""
        }

        mutating func finish() -> AttributedString {
            flush()
            return out
        }
    }
}
