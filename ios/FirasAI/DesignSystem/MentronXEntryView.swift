import Foundation
import SwiftUI

/// The MentronX signature that plays over the ground on first run and on a cold
/// authentication, while `/api/auth/me` is in flight. It *is* the loading state
/// — never put a spinner over it.
///
/// The original ran ~3.9 s and could not be skipped
/// (`audit-ios-shell-settings-design.md §2 F28`); this one finishes inside
/// 1.2 s, 0.9 s with motion off, and a tap ends it immediately. `onFinished` is
/// called exactly once, and a safety timer guarantees it fires even if the
/// animation completions never arrive.
struct MentronXEntryView: View {

    private let overridePalette: FirasPalette?
    private let onFinished: () -> Void

    @Environment(PreferencesStore.self) private var preferences: PreferencesStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var primaryProgress: CGFloat = 0
    @State private var crossProgress: CGFloat = 0
    @State private var lockupVisible = false
    @State private var contentOpacity: Double = 0
    @State private var finished = false
    @State private var started = false

    init(palette: FirasPalette? = nil, onFinished: @escaping () -> Void) {
        self.overridePalette = palette
        self.onFinished = onFinished
    }

    var body: some View {
        let palette = resolvedPalette

        return ZStack {
            palette.background
                .ignoresSafeArea()

            HStack(spacing: lockupVisible ? 13 : 0) {
                MentronXMark(
                    primaryProgress: primaryProgress,
                    crossProgress: crossProgress,
                    palette: palette
                )
                .frame(
                    width: lockupVisible ? 62 : 198,
                    height: lockupVisible ? 50 : 160
                )

                if lockupVisible {
                    lockup(palette: palette)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "BY MentronX"))
            .accessibilityAddTraits(.isButton)
            .opacity(contentOpacity)
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .onAppear { start() }
    }

    private func lockup(palette: FirasPalette) -> some View {
        HStack(spacing: 7) {
            Text(verbatim: "BY")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .tracking(2.8)
                .foregroundStyle(palette.textMuted)

            Text(verbatim: "MentronX")
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .tracking(-0.8)
                .foregroundStyle(palette.textPrimary)
        }
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .move(edge: .leading)),
                removal: .opacity
            )
        )
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

    private var motionOn: Bool {
        (preferences?.motionEnabled ?? true) && !reduceMotion
    }

    // MARK: - Playback

    private func start() {
        guard !started else { return }
        started = true

        if motionOn {
            scheduleSafety(after: 1.45)
            playFull()
        } else {
            scheduleSafety(after: 1.15)
            playReduced()
        }
    }

    private func playFull() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { contentOpacity = 1 }

        withAnimation(.timingCurve(0.50, 0.05, 0.30, 1, duration: 0.50)) {
            primaryProgress = 1
        } completion: {
            guard !finished else { return }
            withAnimation(.timingCurve(0.40, 0, 0.30, 1, duration: 0.22)) {
                crossProgress = 1
            } completion: {
                guard !finished else { return }
                withAnimation(.timingCurve(0.22, 0.80, 0.28, 1, duration: 0.32)) {
                    lockupVisible = true
                } completion: {
                    fadeOut(duration: 0.16)
                }
            }
        }
    }

    private func playReduced() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            primaryProgress = 1
            crossProgress = 1
            lockupVisible = true
            contentOpacity = 0
        }

        withAnimation(.easeOut(duration: 0.70)) {
            contentOpacity = 1
        } completion: {
            fadeOut(duration: 0.20)
        }
    }

    private func fadeOut(duration: Double) {
        guard !finished else { return }
        withAnimation(.easeOut(duration: duration)) {
            contentOpacity = 0
        } completion: {
            finish()
        }
    }

    private func scheduleSafety(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { self.finish() }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinished()
    }
}

// MARK: - Mark

private struct MentronXMark: View {

    let primaryProgress: CGFloat
    let crossProgress: CGFloat
    let palette: FirasPalette

    var body: some View {
        ZStack {
            MentronXPrimaryStroke()
                .trim(from: 0, to: primaryProgress)
                .stroke(
                    LinearGradient(
                        colors: [
                            palette.accent,
                            palette.accentHover,
                            palette.textPrimary
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    ),
                    style: StrokeStyle(
                        lineWidth: 5.2,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

            MentronXCrossStroke()
                .trim(from: 0, to: crossProgress)
                .stroke(
                    palette.accent,
                    style: StrokeStyle(
                        lineWidth: 5.2,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        }
        .padding(5)
    }
}

/// Original MentronX mark path: `M8 52 18 12 30 44 42 12 54 52 78 12`.
private struct MentronXPrimaryStroke: Shape {
    func path(in rect: CGRect) -> Path {
        mentronXScaledPath(
            [
                CGPoint(x: 8, y: 52),
                CGPoint(x: 18, y: 12),
                CGPoint(x: 30, y: 44),
                CGPoint(x: 42, y: 12),
                CGPoint(x: 54, y: 52),
                CGPoint(x: 78, y: 12)
            ],
            in: rect
        )
    }
}

/// Original MentronX cross stroke: `M54 12 78 52`.
private struct MentronXCrossStroke: Shape {
    func path(in rect: CGRect) -> Path {
        mentronXScaledPath(
            [CGPoint(x: 54, y: 12), CGPoint(x: 78, y: 52)],
            in: rect
        )
    }
}

private nonisolated func mentronXScaledPath(_ points: [CGPoint], in rect: CGRect) -> Path {
    var path = Path()
    guard let first = points.first else { return path }

    let designBounds = CGRect(x: 5, y: 8, width: 76, height: 48)
    let scale = min(
        rect.width / designBounds.width,
        rect.height / designBounds.height
    )
    let renderedSize = CGSize(
        width: designBounds.width * scale,
        height: designBounds.height * scale
    )
    let origin = CGPoint(
        x: rect.midX - renderedSize.width / 2,
        y: rect.midY - renderedSize.height / 2
    )

    func map(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: origin.x + (point.x - designBounds.minX) * scale,
            y: origin.y + (point.y - designBounds.minY) * scale
        )
    }

    path.move(to: map(first))
    for point in points.dropFirst() {
        path.addLine(to: map(point))
    }
    return path
}
