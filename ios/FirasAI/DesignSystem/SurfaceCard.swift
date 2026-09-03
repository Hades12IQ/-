import SwiftUI

/// The only card container in the app. Opaque on purpose: glass belongs to floating chrome, never to
/// content, so text contrast is measurable (`design-brief.md §2.3, §2.5`).
///
/// Nearly flat by design. A card is separated from the page by *one* hairline and a touch of surface
/// lift — not by a coloured fill, not by an elevation stack. Ten of these down a conversation have to
/// look like ten quiet blocks of the same paper, so the shadow is barely a shadow: enough to keep the
/// edge from dissolving on the light theme, and almost nothing on the dark ones, where a black blur
/// only muddies the ground it sits on.
///
/// Radius 9 for a card, 7 for anything nested inside one.
struct SurfaceCard<Content: View>: View {
    private let palette: FirasPalette
    private let radius: CGFloat
    private let content: Content

    init(palette: FirasPalette, radius: CGFloat = 9, @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        content.modifier(SurfaceCardModifier(palette: palette, radius: radius))
    }
}

extension View {
    func surfaceCard(_ palette: FirasPalette, radius: CGFloat = 9) -> some View {
        modifier(SurfaceCardModifier(palette: palette, radius: radius))
    }
}

private struct SurfaceCardModifier: ViewModifier {
    let palette: FirasPalette
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background { shape.fill(palette.surface) }
            .clipShape(shape)
            /* The border is decoration and must not take a touch: a stroked SwiftUI shape is
               hit-testable, and this one is an overlay, so without this it eats taps that land on
               the outer edge of a card that is itself a button. Same rule as the glass wash. */
            .overlay { shape.strokeBorder(palette.border, lineWidth: 1).allowsHitTesting(false) }
            .shadow(color: Color.black.opacity(shadowOpacity), radius: 2, y: 1)
    }

    /// Light paper takes a whisper of a drop shadow; the five dark themes take almost none, because
    /// on a dark ground a shadow reads as smudge, not as depth.
    private var shadowOpacity: Double {
        palette.isLightFamily ? 0.035 : 0.10
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
