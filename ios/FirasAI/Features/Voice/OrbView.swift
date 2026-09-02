import SwiftUI

/// The call orb: one `Canvas` pass driven by the audio level, no glass, no halo outside the
/// circle (`design-brief.md §3.1, §7.13`).
///
/// The motion constants are the web's, verbatim (`web-voice-call-mic.md §2.3`): the level is eased
/// with a rise factor of 0.45 and a fall of 0.10 per frame, and the aurora rotates at
/// `0.30 + level × 2.4` rad/s. With motion off the orb stops turning and only its brightness
/// answers the level — it never freezes into a dead disc.
struct OrbView: View {

    enum Mode: Equatable, Sendable {
        case idle
        case connecting
        case listening
        case thinking
        case speaking
    }

    private let level: Float
    private let mode: Mode
    private let palette: FirasPalette
    private let motionOn: Bool
    private let size: CGFloat

    @State private var state = OrbMotionState()

    init(level: Float, mode: Mode, palette: FirasPalette, motionOn: Bool, size: CGFloat) {
        self.level = level
        self.mode = mode
        self.palette = palette
        self.motionOn = motionOn
        self.size = size
    }

    var body: some View {
        Group {
            if motionOn {
                TimelineView(.animation) { timeline in
                    canvas(now: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                canvas(now: 0)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Canvas

    private func canvas(now: Double) -> some View {
        let motion = motionOn
        let target = Double(min(max(level, 0), 1))
        let phaseFloor = mode.levelFloor
        let colors = OrbColors(palette: palette)
        let orbState = state
        let currentMode = mode

        return Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, canvasSize in
            let sample = orbState.advance(target: max(target, phaseFloor), now: now, moving: motion)
            OrbPainter.draw(
                in: &context,
                canvasSize: canvasSize,
                level: sample.level,
                rotation: sample.rotation,
                pulse: sample.pulse,
                colors: colors,
                mode: currentMode,
                moving: motion
            )
        }
    }
}

// MARK: - Motion state

/// Frame-to-frame easing. Held in `@State` and mutated inside the renderer, which is exactly
/// where the web keeps it too: nothing here is observed, so writing it never invalidates a view.
private final class OrbMotionState {

    struct Sample {
        let level: Double
        let rotation: Double
        let pulse: Double
    }

    private var eased: Double = 0
    private var rotation: Double = 0
    private var lastNow: Double = 0

    func advance(target: Double, now: Double, moving: Bool) -> Sample {
        // Rise fast, fall slowly — the web's 0.45 / 0.10 factors, applied per frame.
        let factor = target > eased ? 0.45 : 0.10
        eased += (target - eased) * factor
        if eased < 0.0005 { eased = 0 }

        guard moving else {
            lastNow = now
            return Sample(level: eased, rotation: 0, pulse: 0)
        }

        let delta: Double
        if lastNow > 0, now > lastNow, now - lastNow < 0.5 {
            delta = now - lastNow
        } else {
            delta = 1.0 / 60.0
        }
        lastNow = now

        rotation += (0.30 + eased * 2.4) * delta
        if rotation > .pi * 2 { rotation -= .pi * 2 }

        return Sample(level: eased, rotation: rotation, pulse: now)
    }
}

// MARK: - Colours

private struct OrbColors {
    let deep: Color
    let base: Color
    let bright: Color
    let ink: Color

    init(palette: FirasPalette) {
        deep = palette.accentDeep
        base = palette.accent
        bright = palette.accentHover
        ink = palette.onAccent
    }
}

// MARK: - Painter

private enum OrbPainter {

    static func draw(
        in context: inout GraphicsContext,
        canvasSize: CGSize,
        level: Double,
        rotation: Double,
        pulse: Double,
        colors: OrbColors,
        mode: OrbView.Mode,
        moving: Bool
    ) {
        let side = min(canvasSize.width, canvasSize.height)
        guard side > 4 else { return }
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let radius = side / 2

        body(in: &context, center: center, radius: radius, level: level, colors: colors)
        aurora(
            in: &context,
            center: center,
            radius: radius,
            level: level,
            rotation: rotation,
            colors: colors,
            moving: moving
        )
        rings(
            in: &context,
            center: center,
            radius: radius,
            level: level,
            pulse: pulse,
            colors: colors,
            mode: mode,
            moving: moving
        )
    }

    // MARK: Pieces

    private static func body(
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        level: Double,
        colors: OrbColors
    ) {
        let bodyRadius = radius * (0.78 + 0.05 * CGFloat(level))
        let rect = CGRect(
            x: center.x - bodyRadius,
            y: center.y - bodyRadius,
            width: bodyRadius * 2,
            height: bodyRadius * 2
        )
        let gradient = Gradient(colors: [
            colors.bright.opacity(0.95),
            colors.base.opacity(0.92),
            colors.deep.opacity(0.98),
        ])
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                gradient,
                center: CGPoint(x: center.x - bodyRadius * 0.22, y: center.y - bodyRadius * 0.28),
                startRadius: 0,
                endRadius: bodyRadius * 1.25
            )
        )
    }

    private static func aurora(
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        level: Double,
        rotation: Double,
        colors: OrbColors,
        moving: Bool
    ) {
        let bodyRadius = radius * 0.78
        let blobRadius = bodyRadius * CGFloat(0.42 + level * 0.16)
        let orbit = bodyRadius * CGFloat(0.26 + level * 0.14)
        let clip = Path(
            ellipseIn: CGRect(
                x: center.x - bodyRadius,
                y: center.y - bodyRadius,
                width: bodyRadius * 2,
                height: bodyRadius * 2
            )
        )

        context.drawLayer { layer in
            layer.clip(to: clip)
            layer.addFilter(.blur(radius: bodyRadius * 0.28))

            let tints = [colors.bright, colors.ink, colors.deep]
            for index in 0..<3 {
                let angle = rotation + (Double(index) * 2.0 * .pi / 3.0)
                let point = CGPoint(
                    x: center.x + orbit * CGFloat(cos(angle)),
                    y: center.y + orbit * CGFloat(sin(angle * 1.13))
                )
                let rect = CGRect(
                    x: point.x - blobRadius,
                    y: point.y - blobRadius,
                    width: blobRadius * 2,
                    height: blobRadius * 2
                )
                let opacity = moving ? 0.28 + level * 0.34 : 0.18 + level * 0.30
                layer.fill(
                    Path(ellipseIn: rect),
                    with: .color(tints[index].opacity(opacity))
                )
            }
        }
    }

    private static func rings(
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        level: Double,
        pulse: Double,
        colors: OrbColors,
        mode: OrbView.Mode,
        moving: Bool
    ) {
        let spread = mode.ringSpread
        for index in 0..<3 {
            let step = CGFloat(index)
            let breathing: Double
            if moving {
                breathing = sin(pulse * (1.1 + Double(index) * 0.37) + Double(index)) * 0.5 + 0.5
            } else {
                breathing = 0.5
            }
            let ringRadius = radius * (0.82 + step * 0.06) + CGFloat(level * 4 + breathing * 2) * spread
            guard ringRadius > 1 else { continue }
            let rect = CGRect(
                x: center.x - ringRadius,
                y: center.y - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            )
            let opacity = (0.30 - Double(index) * 0.07) * (0.55 + level * 0.85)
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(colors.bright.opacity(max(0.04, opacity))),
                lineWidth: max(0.6, radius * 0.012)
            )
        }
    }
}

// MARK: - Mode tuning

private extension OrbView.Mode {

    /// A resting amount of life so the orb is never a flat disc while the engine is quiet.
    var levelFloor: Double {
        switch self {
        case .idle: return 0.04
        case .connecting: return 0.16
        case .listening: return 0.10
        case .thinking: return 0.30
        case .speaking: return 0.20
        }
    }

    /// How far the rings travel from the body.
    var ringSpread: CGFloat {
        switch self {
        case .idle: return 0.4
        case .connecting: return 0.8
        case .listening: return 1.0
        case .thinking: return 0.6
        case .speaking: return 1.4
        }
    }
}
