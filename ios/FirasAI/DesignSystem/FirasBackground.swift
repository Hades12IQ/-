import SwiftUI
import UIKit

/// The ground every screen sits on (`design-brief.md §2.4 (7), §7.1`).
///
/// A ground, deliberately, and not a gradient: the theme colour, one very wide accent radial you are
/// meant to feel rather than see, a slight settling of the bottom edge, and a static film grain. The
/// welcome halo is the only thing that ever moves here, it fades once, and it is gone the moment a
/// conversation has content — nothing animates behind text the user is reading.
struct FirasBackground: View {
    private let palette: FirasPalette
    private let showHalo: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var haloProgress: Double = 0

    init(palette: FirasPalette, showHalo: Bool) {
        self.palette = palette
        self.showHalo = showHalo
    }

    var body: some View {
        GeometryReader { proxy in
            let extent = max(proxy.size.width, proxy.size.height)
            ZStack {
                palette.background
                accentRadial(extent: extent)
                halo(extent: extent)
                bottomSettle
                grain
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { settleHalo(animated: true) }
        .onChange(of: showHalo) { _, _ in settleHalo(animated: true) }
    }

    // MARK: - Layers

    /// The ambient tint. `haloOpacity` is between 0.035 and 0.055 across the six themes, and the
    /// radius is the full extent of the screen, so this is a barely-there warming of the top of the
    /// page rather than a visible arc of colour.
    private func accentRadial(extent: CGFloat) -> some View {
        RadialGradient(
            colors: [palette.accent.opacity(palette.haloOpacity), Color.clear],
            center: UnitPoint(x: 0.5, y: 0.10),
            startRadius: 0,
            endRadius: max(extent, 1)
        )
    }

    /// Welcome only. Always in the tree so it can fade *out* as well as in — a halo that vanished on
    /// the frame the first message arrived would read as a glitch.
    private func halo(extent: CGFloat) -> some View {
        RadialGradient(
            colors: [palette.accent.opacity(palette.haloOpacity * 1.6), Color.clear],
            center: UnitPoint(x: 0.5, y: 0.32),
            startRadius: 0,
            endRadius: max(extent * 0.62, 1)
        )
        .opacity(haloProgress)
    }

    /// Enough to keep the composer from floating on nothing; not a vignette.
    private var bottomSettle: some View {
        LinearGradient(
            stops: [
                Gradient.Stop(color: Color.clear, location: 0.6),
                Gradient.Stop(
                    color: Color.black.opacity(palette.isLightFamily ? 0.035 : 0.10),
                    location: 1
                ),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// A 128 pt tile of neutral speckle composited with `.overlay`, so it lightens and darkens by the
    /// same amount on every theme. Never animated; `black` sets `grainOpacity` to 0 and gets none.
    @ViewBuilder
    private var grain: some View {
        if palette.grainOpacity > 0 {
            FirasGrainTexture.tile
                .resizable(resizingMode: .tile)
                .opacity(palette.grainOpacity)
                .blendMode(.overlay)
        }
    }

    // MARK: - Halo

    private func settleHalo(animated: Bool) {
        let target: Double = showHalo ? 1 : 0
        guard animated, !reduceMotion else {
            haloProgress = target
            return
        }
        withAnimation(.easeOut(duration: showHalo ? 0.45 : 0.28)) {
            haloProgress = target
        }
    }
}

/// Built once, on first use, and reused for the life of the process.
private enum FirasGrainTexture {
    static let tile: Image = makeTile()

    private static func makeTile() -> Image {
        let side = 128
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        )
        let rendered = renderer.image { context in
            let cg = context.cgContext
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            for y in 0..<side {
                for x in 0..<side {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let value = Double((seed >> 33) & 0xFF) / 255
                    guard abs(value - 0.5) > 0.24 else { continue }
                    cg.setFillColor(UIColor(white: CGFloat(value), alpha: 1).cgColor)
                    cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return Image(uiImage: rendered)
    }
}
