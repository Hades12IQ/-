import Foundation
import SwiftUI
import UIKit

/// One equation handed to the island. `id` is derived from the TeX itself, so the same formula
/// asked for twice — by the whole-message pass and again by the block that draws it, or by two
/// different messages — is typeset once.
struct MathIslandItem: Hashable, Sendable {

    let id: String
    let tex: String
    let isDisplay: Bool

    init(tex: String, isDisplay: Bool) {
        let trimmed = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tex = trimmed
        self.isDisplay = isDisplay
        self.id = MathScanner.identifier(tex: trimmed, isDisplay: isDisplay)
    }

    init(span: MathScanner.Span) {
        self.init(tex: span.tex, isDisplay: span.isDisplay)
    }
}

/// Everything the page needs to look like the rest of the app: the six themes' ink, the colour the
/// equation sits on, the error red, and the prose size Settings asks for.
struct MathIslandStyle: Hashable, Sendable {

    let textHex: String
    let backgroundHex: String
    let errorHex: String
    let fontSize: Double

    /// Stable identity. It is part of every cache key, so a theme or reading-size change renders a
    /// *new* bitmap beside the old one instead of throwing the old one away — which is what stops
    /// an equation from blinking out of a message that is still on screen.
    var key: String {
        // `Int(_:)` traps on a NaN or an out-of-range double, and this initialiser is public.
        let tenths = fontSize.isFinite ? Int((min(max(fontSize, 1), 400) * 10).rounded()) : 170
        /* THE GROUND IS BACK IN THE KEY, because it is baked into the bitmap again. It
           was taken out when the page stopped painting one, and it returns with the
           ground: a glyph drawn for the transcript's shade is genuinely not the same
           bitmap as one drawn for a card's, and pretending otherwise would put the wrong
           rectangle behind an equation rather than merely a faint one. */
        return textHex + "|" + backgroundHex + "|" + errorHex + "|" + String(tenths)
    }

    init(textHex: String, backgroundHex: String, errorHex: String, fontSize: Double) {
        self.textHex = textHex
        self.backgroundHex = backgroundHex
        self.errorHex = errorHex
        self.fontSize = fontSize
    }

    init(palette: FirasPalette, background: Color, fontScale: FontScale) {
        let dark = !palette.isLightFamily
        self.init(
            textHex: MathIslandStyle.hex(palette.textPrimary, dark: dark, fallback: dark ? "#ECECEC" : "#151515"),
            backgroundHex: MathIslandStyle.hex(background, dark: dark, fallback: dark ? "#101010" : "#FFFFFF"),
            errorHex: MathIslandStyle.hex(palette.error, dark: dark, fallback: "#CC0000"),
            fontSize: Double(17 * fontScale.factor)
        )
    }

    /// SwiftUI `Color` → a CSS hex, the same way `DiagramRuntime.cssColor` reads one.
    ///
    /// Every `FirasPalette` token is built from literal sRGB components (`Color(hex:)`), so there is
    /// nothing dynamic to resolve against a trait collection — and `UITraitCollection` is UI-actor
    /// material this type must stay clear of, because a style is built wherever a block is laid out.
    /// `dark` therefore only chooses which fallback a colour that refuses to give up its components
    /// falls back to: the ink of its own family, never black on black.
    static func hex(_ color: Color, dark: Bool, fallback: String) -> String {
        let resolved = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return fallback }
        return "#" + channel(red) + channel(green) + channel(blue)
    }

    private static func channel(_ value: CGFloat) -> String {
        let clamped = Int((min(max(value, 0), 1) * 255).rounded())
        let text = String(clamped, radix: 16, uppercase: true)
        return text.count == 1 ? "0" + text : text
    }
}

/// A typeset equation: the bitmap KaTeX drew, its size in points, and where its baseline sits
/// inside that bitmap so an inline formula can sit on the line of the sentence around it.
struct MathGlyph {
    let image: UIImage
    let size: CGSize
    let baseline: CGFloat
}

