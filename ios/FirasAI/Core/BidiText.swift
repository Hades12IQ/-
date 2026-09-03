import Foundation
import SwiftUI

/// First-strong-character direction, the rule every bidi island uses.
///
/// The shell is fixed LTR; only islands (message bodies, composer field, titles, card
/// text) flip, and they flip from their own content — never from the UI language.
enum BidiText {

    /// `.rightToLeft` when the first strong character is Arabic/Hebrew/Syriac/Thaana,
    /// `.leftToRight` when it is Latin/Greek/Cyrillic (or any other strong LTR letter),
    /// `nil` when the text carries no strong character at all (digits, punctuation, emoji).
    static func direction(of text: String) -> LayoutDirection? {
        for scalar in text.unicodeScalars {
            if isRightToLeft(scalar) { return .rightToLeft }
            if isLeftToRight(scalar) { return .leftToRight }
        }
        return nil
    }

    /// True when the text carries more Arabic letters than Latin letters.
    static func isArabicDominant(_ text: String) -> Bool {
        var arabic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if isArabicLetter(scalar) {
                arabic += 1
            } else if isLatinLetter(scalar) {
                latin += 1
            }
        }
        return arabic > latin
    }

    // MARK: - Private

    private static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF,          // Hebrew
             0x0600...0x06FF,          // Arabic
             0x0700...0x074F,          // Syriac
             0x0750...0x077F,          // Arabic Supplement
             0x0780...0x07BF,          // Thaana
             0x07C0...0x08FF,          // NKo … Arabic Extended-A
             0xFB1D...0xFDFF,          // Hebrew / Arabic presentation forms A
             0xFE70...0xFEFF,          // Arabic presentation forms B
             0x10800...0x10FFF,        // Cypriot … Arabic supplementary planes
             0x1E800...0x1EFFF:        // Arabic mathematical alphabetic symbols
            return true
        default:
            return false
        }
    }

    private static func isLeftToRight(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A,          // A–Z
             0x0061...0x007A,          // a–z
             0x00C0...0x024F,          // Latin-1 supplement letters … Latin Extended-B
             0x0370...0x03FF,          // Greek
             0x1F00...0x1FFF,          // Greek Extended
             0x0400...0x052F,          // Cyrillic
             0x1E00...0x1EFF,          // Latin Extended Additional
             0x2C60...0x2C7F,          // Latin Extended-C
             0x3040...0x30FF,          // Kana
             0x4E00...0x9FFF,          // CJK
             0xAC00...0xD7AF:          // Hangul
            return true
        default:
            return false
        }
    }

    private static func isArabicLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0620...0x064A,
             0x066E...0x06D3,
             0x06FA...0x06FF,
             0x0750...0x077F,
             0xFB50...0xFDFF,
             0xFE70...0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A,
             0x0061...0x007A,
             0x00C0...0x024F,
             0x1E00...0x1EFF:
            return true
        default:
            return false
        }
    }
}
