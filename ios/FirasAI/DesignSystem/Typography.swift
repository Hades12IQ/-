import SwiftUI

/// System font only. `Font.system` resolves to SF Pro for Latin and SF Arabic for Arabic glyphs with
/// correct joining and tashkeel metrics; a custom family would break both (`design-brief.md §4.1`).
enum FirasType {
    /// Assistant and user prose. Arabic gets the taller leading (≈1.9) it needs, Latin ≈1.7.
    /// The Settings font scale multiplies the OS Dynamic Type size, it never replaces it.
    static func prose(_ lang: AppLanguage, scale: FontScale) -> (font: Font, lineSpacing: CGFloat) {
        let factor = scale.factor
        let leading: CGFloat = lang == .arabic ? 9 : 6
        return (Font.system(size: 17 * factor), leading * factor)
    }

    /// Code, paths, model ids, timers. Always paired with `forceLTR()` for anything numeric.
    static let mono: Font = .system(.body, design: .monospaced)

    static let caption: Font = .system(.caption)

    /// UI labels on glass: `.medium`, never grey, never light (the vibrancy rule in §4.1).
    static let label: Font = .system(.subheadline, weight: .medium)

    /// A point size that still follows Dynamic Type, multiplied by the Settings scale.
    static func scaled(_ size: CGFloat, scale: FontScale, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size * scale.factor, weight: weight)
    }
}

extension Text {
    /// Latin display type may be tightened; Arabic never gets tracking — it tears the joins.
    func firasTracking(for text: String) -> Text {
        FirasScript.containsArabic(text) ? self : tracking(-0.3)
    }
}

private enum FirasScript {
    static func containsArabic(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0x0870...0x089F, 0x08A0...0x08FF,
                 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                return true
            default:
                continue
            }
        }
        return false
    }
}
