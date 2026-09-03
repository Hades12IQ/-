import Foundation

/// Arabic normalisation and number formatting.
///
/// `normalize` is the comparison form used by the approval matcher, search and every
/// keyword test: tashkeel and tatweel removed, hamza forms folded onto plain alef,
/// alef maqsura folded onto ya, ta marbuta onto ha, Latin lowercased, trimmed.
enum ArabicText {

    // Folding targets, written as escapes so the source stays ASCII-safe.
    private static let alef: Unicode.Scalar = "\u{0627}"        // ا
    private static let ya: Unicode.Scalar = "\u{064A}"          // ي
    private static let ha: Unicode.Scalar = "\u{0647}"          // ه

    static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.lowercased().unicodeScalars {
            switch scalar.value {
            case 0x064B...0x0652,       // tashkeel
                 0x0670,                // superscript alef
                 0x0640:                // tatweel
                continue
            case 0x0622, 0x0623, 0x0625, 0x0671:   // آ أ إ ٱ
                scalars.append(alef)
            case 0x0649:                            // ى
                scalars.append(ya)
            case 0x0629:                            // ة
                scalars.append(ha)
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A count for the UI: Arabic-Indic digits (٠١٢, never the Persian ۰۱۲) in Arabic,
    /// plain Latin digits in English. Never grouped — the web does not group counts.
    static func count(_ n: Int, _ lang: AppLanguage) -> String {
        switch lang {
        case .english:
            return String(n)
        case .arabic:
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "ar-IQ-u-nu-arab")
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            return formatter.string(from: NSNumber(value: n)) ?? String(n)
        }
    }

    /// `m:ss` with Latin digits. Callers wrap the label in an LTR island.
    static func timer(_ seconds: Int) -> String {
        let total = seconds > 0 ? seconds : 0
        let minutes = total / 60
        let remainder = total % 60
        let padded = remainder < 10 ? "0\(remainder)" : "\(remainder)"
        return "\(minutes):\(padded)"
    }
}

/// The six Arabic plural forms. English collapses to one/other.
enum ArabicPlurals {

    /// Picks the form for `n` and formats it with `%ld`. In Arabic the resulting digits
    /// are converted to Arabic-Indic so a counted string matches `ArabicText.count`.
    static func count(_ n: Int,
                      _ lang: AppLanguage,
                      zero: LText,
                      one: LText,
                      two: LText,
                      few: LText,
                      many: LText,
                      other: LText) -> String {
        let template = form(n, lang, zero: zero, one: one, two: two, few: few, many: many, other: other)
        let text = template.fmt(lang, n)
        return lang == .arabic ? arabicIndicDigits(text) : text
    }

    // MARK: - Private

    private static func form(_ n: Int,
                             _ lang: AppLanguage,
                             zero: LText,
                             one: LText,
                             two: LText,
                             few: LText,
                             many: LText,
                             other: LText) -> LText {
        let magnitude = n < 0 ? -n : n
        switch lang {
        case .english:
            return magnitude == 1 ? one : other
        case .arabic:
            if magnitude == 0 { return zero }
            if magnitude == 1 { return one }
            if magnitude == 2 { return two }
            let hundreds = magnitude % 100
            if hundreds >= 3 && hundreds <= 10 { return few }
            if hundreds >= 11 && hundreds <= 99 { return many }
            return other
        }
    }

    private static func arabicIndicDigits(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if character.isASCII, character.isNumber, let digit = character.wholeNumberValue,
               let scalar = Unicode.Scalar(UInt32(0x0660 + digit)) {
                out.append(Character(scalar))
            } else {
                out.append(character)
            }
        }
        return out
    }
}
