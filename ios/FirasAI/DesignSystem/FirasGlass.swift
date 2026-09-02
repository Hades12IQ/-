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
                .overlay { shape.stroke(palette.glassStroke, lineWidth: 0.5) }
        } else {
            content
                .background { shape.fill(palette.surface.opacity(0.28)) }
                .background(Material.ultraThin.opacity(0.62), in: shape)
                .overlay { wash }
                .overlay { shape.stroke(palette.glassStroke, lineWidth: 1) }
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

    @ViewBuilder
    private func translucentSheet(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(FirasGlass.sheetGlass(tint: palette.glassTint), in: shape)
        } else {
            content
                .background { shape.fill(palette.surface.opacity(0.55)) }
                .background(Material.ultraThin, in: shape)
        }
    }

    // MARK: - Pieces

    private func solid(_ content: Content, fill: Color, lineWidth: CGFloat) -> some View {
        content
            .background { shape.fill(fill) }
            .overlay { shape.stroke(palette.glassStroke, lineWidth: lineWidth) }
    }

    /// The dimming layer Apple's clear-glass guidance asks for — a wash, never a scrim.
    @ViewBuilder
    private var wash: some View {
        if palette.washBlendsLighter {
            shape.fill(palette.glassWash).blendMode(.plusLighter)
        } else {
            shape.fill(palette.glassWash)
        }
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
