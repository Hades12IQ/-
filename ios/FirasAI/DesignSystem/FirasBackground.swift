import SwiftUI
import UIKit

/// The ground every screen sits on: theme colour, one accent radial, a soft bottom darkening, a
/// static film grain and — on Welcome — the halo bloom (`design-brief.md §2.4 (7), §7.1`).
/// Nothing here animates continuously; the halo blooms once and stops.
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
                bottomDarkening
                grain
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { startHalo(animated: true) }
        .onChange(of: showHalo) { _, _ in startHalo(animated: true) }
    }

    // MARK: - Layers

    private func accentRadial(extent: CGFloat) -> some View {
        RadialGradient(
            colors: [palette.accent.opacity(palette.haloOpacity), Color.clear],
            center: UnitPoint(x: 0.5, y: 0.12),
            startRadius: 0,
            endRadius: max(extent * 0.85, 1)
        )
    }

    @ViewBuilder
    private func halo(extent: CGFloat) -> some View {
        if showHalo {
            RadialGradient(
                colors: [palette.accent.opacity(palette.haloOpacity * 1.35), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.34),
                startRadius: 0,
                endRadius: max(extent * 0.55, 1)
            )
            .opacity(reduceMotion ? 0.55 : haloProgress)
        }
    }

    private var bottomDarkening: some View {
        LinearGradient(
            stops: [
                Gradient.Stop(color: Color.clear, location: 0.55),
                Gradient.Stop(
                    color: Color.black.opacity(palette.isLightFamily ? 0.05 : 0.16),
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

    // MARK: - Halo bloom

    private func startHalo(animated: Bool) {
        guard showHalo else {
            haloProgress = 0
            return
        }
        if reduceMotion || !animated {
            haloProgress = 0.55
            return
        }
        haloProgress = 0
        withAnimation(.easeOut(duration: 0.6)) {
            haloProgress = 1
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
