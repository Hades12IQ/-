import SwiftUI

/// The only place in the app that spells `glassEffect` / `Glass`.
///
/// Three levels, nothing else (`design-brief.md §2.3`). `.floating` deliberately uses `Glass.clear`
/// with a 0.035–0.05 tint and a very thin wash instead of the default `.regular` slab — the owner's
/// "make it more transparent" note (`§2.4`). Reduce Transparency falls to a solid `surface` with the
/// same radii and shadow so nothing moves.
enum FirasGlass {
    enum Level: Sendable {
        case chrome
        case floating
        case sheet
    }

    /// The one and only `Glass.clear` site. If a future SDK rejects it, this body becomes
    /// `Glass.regular.tint(tint)` and the whole app follows.
    @available(iOS 26.0, *)
    fileprivate static func clearGlass(tint: Color) -> Glass {
        Glass.clear.tint(tint).interactive()
    }

    @available(iOS 26.0, *)
    fileprivate static func sheetGlass(tint: Color) -> Glass {
        Glass.regular.tint(tint)
    }
}

extension View {
    func firasGlass(
        _ level: FirasGlass.Level,
        palette: FirasPalette,
        in shape: AnyShape = AnyShape(Capsule())
    ) -> some View {
        modifier(FirasGlassModifier(level: level, shape: shape, palette: palette))
    }

    /// `.sheet`-level background for a presented sheet. iOS 26 keeps the system glass sheet
    /// (setting a solid `presentationBackground` there turns the glass off).
    func firasSheetBackground(_ palette: FirasPalette) -> some View {
        modifier(FirasSheetBackgroundModifier(palette: palette))
    }

    /// A bidirectional island inside the fixed-LTR shell: direction comes from the first strong
    /// character of `text`, falling back to the UI language.
    func bidiIsland(for text: String, fallback lang: AppLanguage) -> some View {
        let direction = BidiText.direction(of: text)
            ?? (lang == .arabic ? LayoutDirection.rightToLeft : LayoutDirection.leftToRight)
        return self
            .environment(\.layoutDirection, direction)
            .multilineTextAlignment(.leading)
    }

    /// Timers, code, ids, versions — always Latin digits, always left to right.
    func forceLTR() -> some View {
        environment(\.layoutDirection, LayoutDirection.leftToRight)
    }

    /// Centres reading content in the column width Settings asks for.
    func readingColumn(_ width: ContentWidth) -> some View {
        frame(maxWidth: width.maxWidth)
            .frame(maxWidth: .infinity)
    }
}

private struct FirasGlassModifier: ViewModifier {
    let level: FirasGlass.Level
    let shape: AnyShape
    let palette: FirasPalette

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        switch level {
        case .chrome:
            chrome(content)
        case .floating:
            floating(content)
        case .sheet:
            sheetSurface(content)
        }
    }

    // MARK: - Levels

    @ViewBuilder
    private func chrome(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.toolbarBackground(Material.ultraThin, for: .navigationBar)
        }
    }

    private func floating(_ content: Content) -> some View {
        floatingSurface(content)
            .shadow(color: palette.glassShadow, radius: 24, y: 8)
    }

    @ViewBuilder
    private func floatingSurface(_ content: Content) -> some View {
        if reduceTransparency {
            solid(content, fill: palette.surface, lineWidth: 1)
        } else {
            translucentFloating(content)
        }
    }

    @ViewBuilder
    private func translucentFloating(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(FirasGlass.clearGlass(tint: palette.glassTint), in: shape)
                .overlay { wash }
                .overlay { hairline(0.5) }
        } else {
            content
                .background { shape.fill(palette.surface.opacity(0.28)) }
                .background(Material.ultraThin.opacity(0.62), in: shape)
                .overlay { wash }
                .overlay { hairline(1) }
        }
    }

    @ViewBuilder
    private func sheetSurface(_ content: Content) -> some View {
        if reduceTransparency {
            solid(content, fill: palette.surface, lineWidth: 1)
        } else {
            translucentSheet(content)
        }
    }

    /* A SHEET IS NOT GLASS ANY MORE, at the owner's direction: "احسك مكثر ليكويد كلاس، خلي نفس
       كلود، اشياء بسيطة". Glass earns its place when you need to see what is behind it; a sheet
       covers the screen precisely so you can stop looking at what is behind it, and translucency
       there only makes the text harder to read over a moving conversation. Claude's sheets are
       opaque. `.floating` — the composer, a toast, a pill riding over the transcript — keeps its
       glass, which is the whole point of having a level system. */
    private func translucentSheet(_ content: Content) -> some View {
        solid(content, fill: palette.surface, lineWidth: 0.5)
    }

    // MARK: - Pieces

    private func solid(_ content: Content, fill: Color, lineWidth: CGFloat) -> some View {
        content
            .background { shape.fill(fill) }
            .overlay { hairline(lineWidth) }
    }

    /// The dimming layer Apple's clear-glass guidance asks for — a wash, never a scrim.
    ///
    /// `allowsHitTesting(false)` is load-bearing, not defensive. A filled SwiftUI `Shape` is
    /// hit-testable no matter how transparent its fill is, and this one is an `.overlay`, which
    /// means it sits ABOVE the content. Without this line the wash silently ate every tap on
    /// anything wearing glass — the landing screen's two buttons, the composer's controls, every
    /// sheet — and the buttons read as decoration. Decoration must never take a touch.
    @ViewBuilder
    private var wash: some View {
        if palette.washBlendsLighter {
            shape.fill(palette.glassWash).blendMode(.plusLighter).allowsHitTesting(false)
        } else {
            shape.fill(palette.glassWash).allowsHitTesting(false)
        }
    }

    /// The hairline that separates glass from what is behind it. A stroke is a filled shape too,
    /// so it takes touches along the border for the same reason the wash did.
    private func hairline(_ lineWidth: CGFloat) -> some View {
        shape.stroke(palette.glassStroke, lineWidth: lineWidth).allowsHitTesting(false)
    }
}

private struct FirasSheetBackgroundModifier: ViewModifier {
    let palette: FirasPalette

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.presentationBackground(palette.background)
        } else {
            translucent(content)
        }
    }

    @ViewBuilder
    private func translucent(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.presentationBackground {
                ZStack {
                    Rectangle().fill(Material.ultraThin)
                    Rectangle().fill(palette.surface.opacity(0.55))
                }
                .ignoresSafeArea()
            }
        }
    }
}
