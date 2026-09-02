import Foundation
import SwiftUI

/// The six web themes, token for token (`ARCHITECTURE.md §2.7`, `design-brief.md §6`).
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
            FirasPalette(
                background: "FAF9F5", backgroundSubtle: "F0EEE6", surface: "FFFFFF",
                surfaceSunken: "F0EEE6", sidebar: "F5F4EE", textPrimary: "1A1A18",
                textSecondary: "6B6A63", textMuted: "6E6C64", border: "E6E4DA",
                borderStrong: "D8D6CB", accent: "237A68", accentHover: "1A6253",
                accentDeep: "14544A", onAccent: "FFFFFF", success: "2E7D5B", error: "B3261E",
                accentSoftAlpha: 0.08, accentRingAlpha: 0.40, glassTintAlpha: 0.035,
                washAlpha: 0.025, strokeAlpha: 0.08, shadowAlpha: 0.08,
                userFill: "2A6055", maxTierText: "7C3AED", planGold: "B8862A", planDiamond: "3E7CB1",
                callGround: "FAF9F5", codeWarn: "B3261E", codeOk: "2E7D5B",
                grainOpacity: 0.030, haloOpacity: 0.16, isLightFamily: true
            )
        case .dark:
            FirasPalette(
                background: "262624", backgroundSubtle: "1F1E1D", surface: "30302E",
                surfaceSunken: "1F1E1D", sidebar: "1F1E1D", textPrimary: "ECEAE3",
                textSecondary: "A6A39A", textMuted: "9A978E", border: "3A3A36",
                borderStrong: "46453F", accent: "57AE9C", accentHover: "6BC0AE",
                accentDeep: "2F6F62", onAccent: "1F1E1D", success: "4BA784", error: "E06A60",
                accentSoftAlpha: 0.14, accentRingAlpha: 0.45, glassTintAlpha: 0.05,
                washAlpha: 0.04, strokeAlpha: 0.10, shadowAlpha: 0.18,
                userFill: "2F6D60", maxTierText: "A78BFA", planGold: "D8B45A", planDiamond: "8FB4E0",
                callGround: "14201D", codeWarn: "E3B341", codeOk: "6FC48B",
                grainOpacity: 0.042, haloOpacity: 0.16, isLightFamily: false
            )
        case .black:
            FirasPalette(
                background: "000000", backgroundSubtle: "0A0A0A", surface: "161616",
                surfaceSunken: "0A0A0A", sidebar: "000000", textPrimary: "F2F2F0",
                textSecondary: "ABABA6", textMuted: "8C8C87", border: "232323",
                borderStrong: "343432", accent: "5FBBA7", accentHover: "74CFBB",
                accentDeep: "2F6F62", onAccent: "000000", success: "4BA784", error: "E06A60",
                accentSoftAlpha: 0.15, accentRingAlpha: 0.45, glassTintAlpha: 0.05,
                washAlpha: 0.06, strokeAlpha: 0.14, shadowAlpha: 0.30,
                userFill: "2E6C5F", maxTierText: "A78BFA", planGold: "D8B45A", planDiamond: "8FB4E0",
                callGround: "000000", codeWarn: "E3B341", codeOk: "6FC48B",
                grainOpacity: 0, haloOpacity: 0.08, isLightFamily: false
            )
        case .midnight:
            FirasPalette(
                background: "0F1522", backgroundSubtle: "0A0E19", surface: "182133",
                surfaceSunken: "0A0E19", sidebar: "0A0E19", textPrimary: "E6ECF5",
                textSecondary: "9FACC2", textMuted: "8695AE", border: "232E44",
                borderStrong: "33405A", accent: "5AA9E6", accentHover: "7CBEF0",
                accentDeep: "2C6394", onAccent: "0A0E19", success: "4BA784", error: "E06A60",
                accentSoftAlpha: 0.15, accentRingAlpha: 0.45, glassTintAlpha: 0.05,
                washAlpha: 0.04, strokeAlpha: 0.10, shadowAlpha: 0.20,
                userFill: "2B5F8E", maxTierText: "A78BFA", planGold: "D8B45A", planDiamond: "8FB4E0",
                callGround: "0F1522", codeWarn: "E0B45C", codeOk: "6FC48B",
                grainOpacity: 0.035, haloOpacity: 0.16, isLightFamily: false
            )
        case .graphite:
            FirasPalette(
                background: "171719", backgroundSubtle: "101012", surface: "202023",
                surfaceSunken: "101012", sidebar: "101012", textPrimary: "ECECEE",
                textSecondary: "A5A5AA", textMuted: "8B8B90", border: "2A2A2E",
                borderStrong: "3A3A3F", accent: "57AE9C", accentHover: "6BC0AE",
                accentDeep: "2F6F62", onAccent: "101012", success: "4BA784", error: "E06A60",
                accentSoftAlpha: 0.14, accentRingAlpha: 0.45, glassTintAlpha: 0.05,
                washAlpha: 0.04, strokeAlpha: 0.10, shadowAlpha: 0.20,
                userFill: "2E6C5F", maxTierText: "A78BFA", planGold: "D8B45A", planDiamond: "8FB4E0",
                callGround: "171719", codeWarn: "DDB45F", codeOk: "77C191",
                grainOpacity: 0.030, haloOpacity: 0.16, isLightFamily: false
            )
        case .amber:
            FirasPalette(
                background: "1B1713", backgroundSubtle: "141110", surface: "241F19",
                surfaceSunken: "141110", sidebar: "141110", textPrimary: "F0E7D8",
                textSecondary: "B3A793", textMuted: "9C907C", border: "332C23",
                borderStrong: "453C30", accent: "D9A05B", accentHover: "E8B475",
                accentDeep: "8A6234", onAccent: "1B1713", success: "8FBF6F", error: "E06A60",
                accentSoftAlpha: 0.15, accentRingAlpha: 0.45, glassTintAlpha: 0.045,
                washAlpha: 0.035, strokeAlpha: 0.09, shadowAlpha: 0.20,
                userFill: "866032", maxTierText: "A78BFA", planGold: "D8B45A", planDiamond: "8FB4E0",
                callGround: "1B1713", codeWarn: "E8B552", codeOk: "7CC596",
                grainOpacity: 0.050, haloOpacity: 0.16, isLightFamily: false
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
    /// Opacity of the accent radial painted by `FirasBackground` (0.08 on `black`).
    let haloOpacity: Double
    /// `true` only for the `light` theme.
    let isLightFamily: Bool

    /// Settings tile swatch, in the web's order.
    var swatch: [Color] { [background, surface, accent] }

    /// Fixed conversation colour tags, identical across the six themes.
    static let tagColors: [String: Color] = [
        "red": Color(hex: "C0503F"),
        "amber": Color(hex: "B0842C"),
        "green": Color(hex: "4E8A46"),
        "teal": Color(hex: "2E8A82"),
        "blue": Color(hex: "4A72B8"),
        "purple": Color(hex: "8A5FB0"),
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
        let overlayInk: Color = isLightFamily ? Color.black : Color.white

        self.background = Color(hex: background)
        self.backgroundSubtle = Color(hex: backgroundSubtle)
        self.surface = Color(hex: surface)
        self.surfaceSunken = Color(hex: surfaceSunken)
        self.sidebar = Color(hex: sidebar)
        self.textPrimary = Color(hex: textPrimary)
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
        self.userFill = Color(hex: userFill)
        self.userInk = Color.white
        self.userEdge = accentColor.opacity(0.40)
        self.userSheen = Color.white.opacity(0.16)
        self.maxTierText = Color(hex: maxTierText)
        self.maxTierDot = Color(hex: "8B5CF6")
        self.maxTierBg = Color(.sRGB, red: 139 / 255, green: 92 / 255, blue: 246 / 255, opacity: 0.13)
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
