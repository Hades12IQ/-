import SwiftUI

/// System font only. `Font.system` resolves to SF Pro for Latin and SF Arabic for Arabic glyphs with
/// correct joining and tashkeel metrics; a custom family would break both (`design-brief.md §4.1`).
///
/// The rhythm here is the reading rhythm of the whole app. Arabic is a connected script whose
/// ascenders, descenders and tashkeel all live outside the x-height band, so it needs more air
/// between lines than Latin does at the same point size — set too tight it looks like a wall, and a
/// wall is what makes a long answer feel heavy. The numbers below give Arabic ≈1.85 line-height and
/// Latin ≈1.65 at the default OS size, and both scale with the Settings font size.
enum FirasType {

    // MARK: - Reading

    /// Assistant and user prose.
    ///
    /// The Settings font scale multiplies the OS Dynamic Type size, it never replaces it: both the
    /// point size and the extra leading move together, so the paragraph keeps its proportions at
    /// every step of `حجم النص`.
    static func prose(_ lang: AppLanguage, scale: FontScale) -> (font: Font, lineSpacing: CGFloat) {
        let factor = scale.factor
        let leading: CGFloat = lang == .arabic ? Metrics.arabicLeading : Metrics.latinLeading
        return (Font.system(size: Metrics.proseSize * factor), leading * factor)
    }

    /// Space between two paragraphs of prose. One clear beat — wider than the line gap, narrower
    /// than a section break — so the eye finds the next paragraph without the page feeling airy.
    static func proseParagraphSpacing(_ lang: AppLanguage, scale: FontScale) -> CGFloat {
        let base: CGFloat = lang == .arabic ? 18 : 16
        return base * scale.factor
    }

    /// The heading ladder for rendered markdown. Four calm steps, all `.semibold`: at 17 pt body the
    /// jumps are 22 → 19 → 17 → 16, which reads as hierarchy without any level shouting. Arabic in
    /// particular gains weight fast, so a heavier or larger top step turns a short answer into a
    /// poster.
    static func heading(_ level: Int, scale: FontScale) -> Font {
        let size: CGFloat
        switch level {
        case 1: size = 22
        case 2: size = 19
        case 3: size = 17
        default: size = 16
        }
        return Font.system(size: size * scale.factor, weight: .semibold)
    }

    // MARK: - UI

    /// Code, paths, model ids, timers. Always paired with `forceLTR()` for anything numeric.
    static let mono: Font = .system(.body, design: .monospaced)

    static let caption: Font = .system(.caption)

    /// UI labels on glass: `.medium`, never grey, never light (the vibrancy rule in §4.1).
    static let label: Font = .system(.subheadline, weight: .medium)

    /// A point size that still follows Dynamic Type, multiplied by the Settings scale.
    static func scaled(_ size: CGFloat, scale: FontScale, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size * scale.factor, weight: weight)
    }

    private enum Metrics {
        static let proseSize: CGFloat = 17
        /// 17 pt SF Arabic sets on ≈20.3 pt lines; +11 gives ≈31 pt, a line-height of ≈1.85.
        static let arabicLeading: CGFloat = 11
        /// ≈1.65 for Latin, which sets tighter and does not need the same room.
        static let latinLeading: CGFloat = 7.5
    }
}

extension Text {
    /// Latin display type may be tightened; Arabic never gets tracking — it tears the joins.
    func firasTracking(for text: String) -> Text {
        FirasScript.containsArabic(text) ? self : tracking(-0.2)
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
