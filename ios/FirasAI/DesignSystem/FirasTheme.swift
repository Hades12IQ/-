import Foundation
import SwiftUI

/// The six themes (`ARCHITECTURE.md §2.7`, `design-brief.md §6`), retuned for calm.
///
/// The owner's note — «شيل الخضار الي يصير بالمحادثة، خلي ناعم نفس كلود» — is the brief for this file.
/// The token *names* are frozen (every screen reads them); only the *values* moved, along one rule:
///
/// 1. One ground, one barely-tinted surface, one accent. The accent earns its saturation by being
///    rare — a send button, a live dot, a link — so it is muted enough to sit next to prose all day.
/// 2. Ink comes in three weights of the same neutral (`textPrimary` / `textSecondary` / `textMuted`),
///    never in a hue. `textMuted` still clears 4.5:1 on both `background` and `surface`.
/// 3. Borders are hairlines you notice only when you look for them.
/// 4. Semantic colour survives — `success`, `error`, `codeWarn`, `codeOk`, the tier violet, the plan
///    metals, the conversation tags — at roughly half its former chroma. Muted, not fluorescent.
/// 5. The six themes differ in *ground and accent*, not in how loud they are.
enum FirasTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case light
    case dark
    case black
    case midnight
    case graphite
    case amber

    var id: String { rawValue }

    /// Only `light` belongs to the light family; it is the one theme that drives `preferredColorScheme(.light)`.
    var isLight: Bool { self == .light }

    var title: LText {
        switch self {
        case .light: LText(ar: "نهاري", en: "Light")
        case .dark: LText(ar: "ليلي", en: "Dark")
        case .black: LText(ar: "أسود", en: "Black")
        case .midnight: LText(ar: "نيلي", en: "Midnight")
        case .graphite: LText(ar: "كربوني", en: "Graphite")
        case .amber: LText(ar: "عنبري", en: "Amber")
        }
    }

    var palette: FirasPalette {
        switch self {
        case .light:
            // Warm paper, evergreen accent. The grounds are the web's own; the accent lost half its
            // chroma and the two greys were pulled apart so they read as steps, not as one blur.
            FirasPalette(
                background: "FAF9F5", backgroundSubtle: "F0EEE6", surface: "FFFFFF",
                surfaceSunken: "F2F0E8", sidebar: "F5F4EE", textPrimary: "1A1A18",
                textSecondary: "5C5B54", textMuted: "75746C", border: "E9E7DE",
                borderStrong: "DAD8CE", accent: "35695E", accentHover: "2B594F",
                accentDeep: "2C5A50", onAccent: "FFFFFF", success: "3F7359", error: "9E4A40",
                accentSoftAlpha: 0.05, accentRingAlpha: 0.34, glassTintAlpha: 0.018,
                washAlpha: 0.022, strokeAlpha: 0.07, shadowAlpha: 0.06,
                userFill: "EEECE3", maxTierText: "6B5A96", planGold: "8F6F2E", planDiamond: "42688C",
                callGround: "FAF9F5", codeWarn: "9E4A40", codeOk: "3F7359",
                grainOpacity: 0.022, haloOpacity: 0.050, isLightFamily: true
            )
        case .dark:
            // Claude's warm graphite. Accent is a grey-green that never competes with the text.
            FirasPalette(
                background: "262624", backgroundSubtle: "1F1E1D", surface: "30302E",
                surfaceSunken: "1F1E1D", sidebar: "1F1E1D", textPrimary: "ECEAE3",
                textSecondary: "A6A39A", textMuted: "9A978E", border: "363532",
                borderStrong: "45443E", accent: "7BA79C", accentHover: "8FB8AD",
                accentDeep: "55786C", onAccent: "1B1A19", success: "7BA894", error: "CE8A80",
                accentSoftAlpha: 0.08, accentRingAlpha: 0.36, glassTintAlpha: 0.028,
                washAlpha: 0.035, strokeAlpha: 0.09, shadowAlpha: 0.14,
                userFill: "3A3A37", maxTierText: "9E8ECB", planGold: "BFA06A", planDiamond: "8AA6C4",
                callGround: "172220", codeWarn: "C9A24E", codeOk: "7BA894",
                grainOpacity: 0.030, haloOpacity: 0.055, isLightFamily: false
            )
        case .black:
            // True black for OLED. Slightly stronger hairlines, because black eats them.
            FirasPalette(
                background: "000000", backgroundSubtle: "0A0A0A", surface: "161616",
                surfaceSunken: "0A0A0A", sidebar: "000000", textPrimary: "F2F2F0",
                textSecondary: "ABABA6", textMuted: "8C8C87", border: "202020",
                borderStrong: "2E2E2C", accent: "82AFA4", accentHover: "96BFB5",
                accentDeep: "5A8175", onAccent: "000000", success: "7BA894", error: "CE8A80",
                accentSoftAlpha: 0.09, accentRingAlpha: 0.36, glassTintAlpha: 0.030,
                washAlpha: 0.050, strokeAlpha: 0.12, shadowAlpha: 0.24,
                userFill: "1E1E1D", maxTierText: "9E8ECB", planGold: "BFA06A", planDiamond: "8AA6C4",
                callGround: "000000", codeWarn: "C9A24E", codeOk: "7BA894",
                grainOpacity: 0, haloOpacity: 0.035, isLightFamily: false
            )
        case .midnight:
            // Ink blue ground, dusty blue accent.
            FirasPalette(
                background: "0F1522", backgroundSubtle: "0A0E19", surface: "182133",
                surfaceSunken: "0A0E19", sidebar: "0A0E19", textPrimary: "E6ECF5",
                textSecondary: "9FACC2", textMuted: "8695AE", border: "202B3E",
                borderStrong: "303B52", accent: "85A2BC", accentHover: "9AB4CB",
                accentDeep: "55738D", onAccent: "0A0E19", success: "7BA894", error: "CE8A80",
                accentSoftAlpha: 0.08, accentRingAlpha: 0.36, glassTintAlpha: 0.028,
                washAlpha: 0.035, strokeAlpha: 0.09, shadowAlpha: 0.16,
                userFill: "29354A", maxTierText: "9E8ECB", planGold: "BFA06A", planDiamond: "8AA6C4",
                callGround: "0F1522", codeWarn: "C4A25E", codeOk: "7BA894",
                grainOpacity: 0.026, haloOpacity: 0.055, isLightFamily: false
            )
        case .graphite:
            // Neutral, colder than `dark`; the accent leans slate so the two never look identical
            // — side by side in the theme picker, `dark` reads green and `graphite` reads steel.
            FirasPalette(
                background: "171719", backgroundSubtle: "101012", surface: "202023",
                surfaceSunken: "101012", sidebar: "101012", textPrimary: "ECECEE",
                textSecondary: "A5A5AA", textMuted: "8B8B90", border: "282829",
                borderStrong: "38383C", accent: "7C9FAD", accentHover: "90B1BE",
                accentDeep: "52707D", onAccent: "101012", success: "7BA894", error: "CE8A80",
                accentSoftAlpha: 0.08, accentRingAlpha: 0.36, glassTintAlpha: 0.028,
                washAlpha: 0.035, strokeAlpha: 0.09, shadowAlpha: 0.16,
                userFill: "2B2B2F", maxTierText: "9E8ECB", planGold: "BFA06A", planDiamond: "8AA6C4",
                callGround: "171719", codeWarn: "C6A45F", codeOk: "7BA894",
                grainOpacity: 0.022, haloOpacity: 0.050, isLightFamily: false
            )
        case .amber:
            // Warm brown ground, sand accent. The one theme whose accent is warm.
            FirasPalette(
                background: "1B1713", backgroundSubtle: "141110", surface: "241F19",
                surfaceSunken: "141110", sidebar: "141110", textPrimary: "F0E7D8",
                textSecondary: "B3A793", textMuted: "9C907C", border: "2E2822",
                borderStrong: "40382E", accent: "BFA37F", accentHover: "CFB392",
                accentDeep: "8A7150", onAccent: "1B1713", success: "8FA87C", error: "CE8A80",
                accentSoftAlpha: 0.08, accentRingAlpha: 0.36, glassTintAlpha: 0.026,
                washAlpha: 0.030, strokeAlpha: 0.08, shadowAlpha: 0.16,
                userFill: "342D25", maxTierText: "9E8ECB", planGold: "BFA06A", planDiamond: "8AA6C4",
                callGround: "1B1713", codeWarn: "CBA765", codeOk: "8FA87C",
                grainOpacity: 0.030, haloOpacity: 0.050, isLightFamily: false
            )
        }
    }
}

/// Every colour the app is allowed to paint. Views read `prefs.palette`; nobody writes `.opacity(0.0x)` inline.
struct FirasPalette: Sendable {
    // Base tokens (`design-brief.md §6.1`).
    let background: Color
    let backgroundSubtle: Color
    let surface: Color
    let surfaceSunken: Color
    let sidebar: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let border: Color
    let borderStrong: Color
    let accent: Color
    let accentHover: Color
    let accentDeep: Color
    let onAccent: Color
    let success: Color
    let error: Color

    // Derived tokens (`design-brief.md §6.2`).
    let accentSoft: Color
    let accentRing: Color
    let glassTint: Color
    let glassWash: Color
    let glassStroke: Color
    let glassShadow: Color
    let userFill: Color
    let userInk: Color
    let userEdge: Color
    let userSheen: Color
    let maxTierText: Color
    let maxTierDot: Color
    let maxTierBg: Color
    let planGold: Color
    let planDiamond: Color
    let callGround: Color
    let codeWarn: Color
    let codeOk: Color

    let grainOpacity: Double
    /// `true` on the five dark families: the glass wash composites with `.plusLighter`.
    let washBlendsLighter: Bool
    let glassShadowOpacity: Double
    /// Opacity of the ambient accent radial painted by `FirasBackground`. A whisper by design: the
    /// ground is a ground, not a gradient show.
    let haloOpacity: Double
    /// `true` only for the `light` theme.
    let isLightFamily: Bool

    /// Settings tile swatch, in the web's order.
    var swatch: [Color] { [background, surface, accent] }

    /// Fixed conversation colour tags, identical across the six themes. Muted to sit quietly in a
    /// list of titles: these are 8 pt dots, they do not need to shout.
    static let tagColors: [String: Color] = [
        "red": Color(hex: "A8635A"),
        "amber": Color(hex: "9C8250"),
        "green": Color(hex: "6C8A5E"),
        "teal": Color(hex: "55837E"),
        "blue": Color(hex: "6483A8"),
        "purple": Color(hex: "8272A8"),
    ]

    init(
        background: String,
        backgroundSubtle: String,
        surface: String,
        surfaceSunken: String,
        sidebar: String,
        textPrimary: String,
        textSecondary: String,
        textMuted: String,
        border: String,
        borderStrong: String,
        accent: String,
        accentHover: String,
        accentDeep: String,
        onAccent: String,
        success: String,
        error: String,
        accentSoftAlpha: Double,
        accentRingAlpha: Double,
        glassTintAlpha: Double,
        washAlpha: Double,
        strokeAlpha: Double,
        shadowAlpha: Double,
        userFill: String,
        maxTierText: String,
        planGold: String,
        planDiamond: String,
        callGround: String,
        codeWarn: String,
        codeOk: String,
        grainOpacity: Double,
        haloOpacity: Double,
        isLightFamily: Bool
    ) {
        let accentColor = Color(hex: accent)
        let inkColor = Color(hex: textPrimary)
        let overlayInk: Color = isLightFamily ? Color.black : Color.white

        self.background = Color(hex: background)
        self.backgroundSubtle = Color(hex: backgroundSubtle)
        self.surface = Color(hex: surface)
        self.surfaceSunken = Color(hex: surfaceSunken)
        self.sidebar = Color(hex: sidebar)
        self.textPrimary = inkColor
        self.textSecondary = Color(hex: textSecondary)
        self.textMuted = Color(hex: textMuted)
        self.border = Color(hex: border)
        self.borderStrong = Color(hex: borderStrong)
        self.accent = accentColor
        self.accentHover = Color(hex: accentHover)
        self.accentDeep = Color(hex: accentDeep)
        self.onAccent = Color(hex: onAccent)
        self.success = Color(hex: success)
        self.error = Color(hex: error)

        self.accentSoft = accentColor.opacity(accentSoftAlpha)
        self.accentRing = accentColor.opacity(accentRingAlpha)
        self.glassTint = accentColor.opacity(glassTintAlpha)
        self.glassWash = overlayInk.opacity(washAlpha)
        self.glassStroke = overlayInk.opacity(strokeAlpha)
        self.glassShadow = Color.black.opacity(shadowAlpha)

        /* The user bubble is a quiet chip, not a brand block: a surface one step off the ground,
           carrying the same ink as the rest of the conversation. That is what makes a thread of ten
           turns readable instead of striped. Its edge is a hairline of the overlay ink, never the
           accent, and the sheen is only there to keep the top of the chip from looking cut out. */
        self.userFill = Color(hex: userFill)
        self.userInk = inkColor
        self.userEdge = overlayInk.opacity(isLightFamily ? 0.07 : 0.09)
        self.userSheen = Color.white.opacity(isLightFamily ? 0.55 : 0.06)

        self.maxTierText = Color(hex: maxTierText)
        self.maxTierDot = Color(hex: "8C7CBE")
        self.maxTierBg = Color(.sRGB, red: 140 / 255, green: 124 / 255, blue: 190 / 255, opacity: 0.10)
        self.planGold = Color(hex: planGold)
        self.planDiamond = Color(hex: planDiamond)
        self.callGround = Color(hex: callGround)
        self.codeWarn = Color(hex: codeWarn)
        self.codeOk = Color(hex: codeOk)

        self.grainOpacity = grainOpacity
        self.washBlendsLighter = !isLightFamily
        self.glassShadowOpacity = shadowAlpha
        self.haloOpacity = haloOpacity
        self.isLightFamily = isLightFamily
    }
}

/// Settings → `حجم النص`. Composes with the OS Dynamic Type size, never replaces it.
enum FontScale: String, CaseIterable, Codable, Identifiable, Sendable {
    case small = "sm"
    case medium = "md"
    case large = "lg"

    var id: String { rawValue }

    var factor: CGFloat {
        switch self {
        case .small: 0.92
        case .medium: 1
        case .large: 1.10
        }
    }
}

enum ContentWidth: String, CaseIterable, Codable, Identifiable, Sendable {
    case normal
    case wide

    var id: String { rawValue }

    var maxWidth: CGFloat { self == .wide ? 980 : 760 }
}

enum MotionPreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case full
    case reduced

    var id: String { rawValue }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        switch cleaned.count {
        case 8:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        default:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        }

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
