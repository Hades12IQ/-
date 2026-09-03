import SwiftUI

/// The Firas mark (an "F" cut from a stem and two beams) and, optionally, the
/// `Firas AI` wordmark beside it.
///
/// The palette is read from the environment when the view sits inside the app
/// shell, and can be passed explicitly for surfaces that render before the
/// preferences store is injected (the intro, the consent door).
struct FirasBrandMark: View {

    private let size: CGFloat
    private let showsWordmark: Bool
    private let overridePalette: FirasPalette?

    @Environment(PreferencesStore.self) private var preferences: PreferencesStore?

    init(size: CGFloat, showsWordmark: Bool = false, palette: FirasPalette? = nil) {
        self.size = size
        self.showsWordmark = showsWordmark
        self.overridePalette = palette
    }

    var body: some View {
        let palette = resolvedPalette
        let accent = palette.accent
        let deep = palette.accentDeep

        return HStack(spacing: max(8, size * 0.22)) {
            Canvas { context, canvasSize in
                let scaleX = canvasSize.width / 32
                let scaleY = canvasSize.height / 44

                var stem = Path()
                stem.addRect(CGRect(x: 0, y: 0, width: 6.5 * scaleX, height: 44 * scaleY))

                var upperBeam = Path()
                upperBeam.move(to: CGPoint(x: 6.5 * scaleX, y: 0))
                upperBeam.addLine(to: CGPoint(x: 32 * scaleX, y: 0))
                upperBeam.addLine(to: CGPoint(x: 27 * scaleX, y: 8.5 * scaleY))
                upperBeam.addLine(to: CGPoint(x: 6.5 * scaleX, y: 8.5 * scaleY))
                upperBeam.closeSubpath()

                var lowerBeam = Path()
                lowerBeam.move(to: CGPoint(x: 6.5 * scaleX, y: 17 * scaleY))
                lowerBeam.addLine(to: CGPoint(x: 24 * scaleX, y: 17 * scaleY))
                lowerBeam.addLine(to: CGPoint(x: 19.5 * scaleX, y: 25.5 * scaleY))
                lowerBeam.addLine(to: CGPoint(x: 6.5 * scaleX, y: 25.5 * scaleY))
                lowerBeam.closeSubpath()

                context.fill(stem, with: .color(accent))
                context.fill(upperBeam, with: .color(accent))
                context.fill(lowerBeam, with: .color(deep))
            }
            .frame(width: size * 32 / 44, height: size)
            .accessibilityHidden(true)

            if showsWordmark {
                wordmark(palette: palette)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Firas AI"))
    }

    private func wordmark(palette: FirasPalette) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: "Firas")
                .foregroundStyle(palette.textPrimary)
            Text(verbatim: "AI")
                .foregroundStyle(palette.accent)
        }
        .font(.system(size: size * 0.60, weight: .semibold, design: .rounded))
        .tracking(-0.5)
    }

    private var resolvedPalette: FirasPalette {
        if let overridePalette {
            return overridePalette
        }
        if let preferences {
            return preferences.palette
        }
        return FirasTheme.dark.palette
    }
}
