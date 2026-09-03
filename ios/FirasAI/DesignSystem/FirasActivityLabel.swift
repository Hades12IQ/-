import SwiftUI

/// The "still working" label: a short sentence with an accent sweep travelling
/// through it while the app is busy.
///
/// The old implementation drove a `TimelineView(.animation(minimumInterval: 1/30))`
/// for the whole streaming duration, re-evaluating the view 30 times a second on
/// every visible label (`audit-ios-shell-settings-design.md §2 F29`). This one
/// hands a single `repeatForever` animation to the render server and then does
/// nothing.
///
/// With motion off the sweep is replaced by a 1.5 s opacity pulse (0.32 ↔ 1)
/// rather than static text: a busy indicator that stops moving reads as a hung
/// app (`design-brief.md §3.3`).
struct FirasActivityLabel: View {

    private let text: String
    private let palette: FirasPalette
    private let motionOn: Bool

    @State private var sweep: CGFloat = 0
    @State private var dimmed = false

    init(text: String, palette: FirasPalette, motionOn: Bool) {
        self.text = text
        self.palette = palette
        self.motionOn = motionOn
    }

    var body: some View {
        base
            .opacity(motionOn ? 1 : (dimmed ? 0.32 : 1))
            .overlay { sweepLayer }
            .onAppear { restart() }
            .onChange(of: motionOn) { _, _ in restart() }
            .onChange(of: text) { _, _ in restart() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(text))
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var base: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.textSecondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var sweepLayer: some View {
        if motionOn {
            GeometryReader { proxy in
                let band = max(42, proxy.size.width * 0.48)
                LinearGradient(
                    colors: [
                        Color.clear,
                        palette.accent.opacity(0.88),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: band)
                .offset(x: -band + (proxy.size.width + band) * sweep)
            }
            .mask { base }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func restart() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            sweep = 0
            dimmed = false
        }

        if motionOn {
            withAnimation(.linear(duration: 1.65).repeatForever(autoreverses: false)) {
                sweep = 1
            }
        } else {
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        }
    }
}
