import SwiftUI

/// The only card container in the app. Opaque on purpose: glass belongs to floating chrome, never to
/// content, so text contrast is measurable (`design-brief.md §2.3, §2.5`).
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
            .overlay { shape.strokeBorder(palette.border, lineWidth: 1) }
            .shadow(color: Color.black.opacity(0.05), radius: 3, y: 1)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
