import Foundation
import SwiftUI

/// **The cover** — the plate a generated picture or clip sits on before its bytes exist.
///
/// This is the one thing the owner said was missing: «صناعة الصور ما يطلع الغلاف الي بالموقع» and
/// «من ارسل يوقف، ما يطلع الغلاف مالها». The website answers a creation request with a *cover* on
/// the very first frame — a small square plate, a field of accent dots on a slow radial wave, a
/// pulsing dot and one rotating word — and only grows into the picture at the end. The app drew a
/// centred spinner, or nothing at all, so a send looked like a stall.
///
/// This is that plate, ported from `app.js:5233-5330` / `styles.css:4155-4295` rather than
/// reinvented: spacing 15 pt, radii 0.5 → 2.2 pt, alpha `0.05 + f^1.8 · 0.6` with
/// `f = (sin(t·0.88 + d + i·0.12) + 1) / 2` and `d = |p − centre| · 0.02`, the word cycling every
/// 2.6 s, the pulse ring over 2.2 s. Every colour is read from the palette at paint time, so the
/// field is teal on Dark, navy on Midnight and brass on Amber for free.
///
/// Three rules the web keeps too:
///
/// 1. **Nothing rotates, bounces or flashes.** A generation is looked at for minutes, and what is
///    looked at for minutes must be calm.
/// 2. **Reduced motion freezes the wave but keeps the field.** A busy plate that stops being drawn
///    reads as a hung app; a still, composed plate is the honest thing to show.
/// 3. **The failure plate is the same plate.** `drawsField: false` plus an error `headline` turns
///    it into the web's `is-error` state without a second code path, so nothing jumps when a
///    render fails — the card simply stops claiming that work is happening.
///
/// It draws the ground and the head and nothing else: a caller that needs a sentence and a button
/// puts them in its own `.overlay`.
struct MediaCoverPlate: View {

    private let palette: FirasPalette
    private let lang: AppLanguage
    private let motionOn: Bool
    private let ratio: CGFloat
    private let cornerRadius: CGFloat
    private let words: [String]
    private let headline: String?
    private let isError: Bool
    private let drawsField: Bool
    private let startedAt: Date?

    /// The wave's zero point. Stored rather than recomputed so a parent that re-evaluates every
    /// second (the stall watch) cannot restart the animation under the reader's eyes.
    @State private var base: Date

    init(
        palette: FirasPalette,
        lang: AppLanguage,
        motionOn: Bool,
        ratio: CGFloat = 1,
        cornerRadius: CGFloat = 20,
        words: [String] = [],
        headline: String? = nil,
        isError: Bool = false,
        drawsField: Bool = true,
        startedAt: Date? = nil
    ) {
        self.palette = palette
        self.lang = lang
        self.motionOn = motionOn
        self.ratio = ratio
        self.cornerRadius = cornerRadius
        self.words = words
        self.headline = headline
        self.isError = isError
        self.drawsField = drawsField
        self.startedAt = startedAt
        _base = State(initialValue: startedAt ?? Date())
    }

    var body: some View {
        ground
            .aspectRatio(safeRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onChange(of: startedAt) { _, updated in
                if let updated { base = updated }
            }
    }

    /* NO CLOCK FOR A PLATE THAT DOES NOT MOVE. The cards now use this with no field, no headline
       and no words as the quiet placeholder a picture waits behind while its file is found on
       disk — and there may be a screenful of those. A `TimelineView(.animation)` around a plain
       rectangle still asks for thirty repaints a second each. */
    @ViewBuilder
    private var ground: some View {
        if isStill {
            palette.surfaceSunken
        } else {
            TimelineView(.animation(minimumInterval: MediaCoverPlate.frameInterval, paused: !motionOn)) { context in
                let elapsed = MediaCoverPlate.elapsed(from: base, to: context.date)
                ZStack(alignment: .topLeading) {
                    palette.surfaceSunken
                    if drawsField {
                        dotField(time: elapsed * MediaCoverPlate.waveSpeed)
                    }
                    head(elapsed: elapsed)
                }
            }
        }
    }

    private var isStill: Bool {
        !drawsField && headline == nil && words.isEmpty
    }

    // MARK: - The dot field

    private func dotField(time: Double) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let width = size.width
            let height = size.height
            guard width > 2, height > 2 else { return }

            let spacing = MediaCoverPlate.spacing
            let columns = Int((width / spacing).rounded(.up)) + 1
            let rows = Int((height / spacing).rounded(.up)) + 1
            guard columns > 0, rows > 0, columns * rows <= 4_000 else { return }

            let offsetX = (width - CGFloat(columns - 1) * spacing) / 2
            let offsetY = (height - CGFloat(rows - 1) * spacing) / 2
            let centreX = Double(width / 2)
            let centreY = Double(height / 2)
            let tint = palette.accent

            for column in 0..<columns {
                for row in 0..<rows {
                    let x = CGFloat(column) * spacing + offsetX
                    let y = CGFloat(row) * spacing + offsetY
                    let deltaX = Double(x) - centreX
                    let deltaY = Double(y) - centreY
                    let distance = (deltaX * deltaX + deltaY * deltaY).squareRoot() * 0.02
                    let wave = (sin(time * 0.88 + distance + Double(column) * 0.12) + 1) / 2
                    let alpha = 0.05 + pow(wave, 1.8) * 0.6
                    if alpha <= 0.005 { continue }
                    let radius = CGFloat(
                        MediaCoverPlate.minimumDot
                            + pow(wave, 2.2) * (MediaCoverPlate.maximumDot - MediaCoverPlate.minimumDot)
                    )
                    let box = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.fill(Path(ellipseIn: box), with: .color(tint.opacity(alpha)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - The head

    /// The pulse and the word, in the plate's leading top corner — the web's `inset-inline-start`,
    /// which in Arabic puts both on the right.
    @ViewBuilder
    private func head(elapsed: Double) -> some View {
        let line = word(at: elapsed)
        if !line.isEmpty {
            HStack(alignment: .center, spacing: 10) {
                if drawsField {
                    pulse(elapsed: elapsed)
                }
                Text(line)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isError ? palette.error : palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .contentTransition(.opacity)
                    .animation(
                        FirasMotion.gated(.easeOut(duration: 0.22), motionOn: motionOn),
                        value: wordIndex(at: elapsed)
                    )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bidiIsland(for: line, fallback: lang)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(line))
        }
    }

    /// A dot with one ring travelling out of it: `imgPulseRing`, scale 0.8 → 2.8 with the opacity
    /// gone by 80 % of the cycle. Driven from the timeline's own clock, so it costs no second
    /// animation and stops dead when motion is off.
    private func pulse(elapsed: Double) -> some View {
        let cycle = motionOn ? elapsed.truncatingRemainder(dividingBy: 2.2) / 2.2 : 0
        let progress = min(cycle / 0.8, 1)
        return ZStack {
            Circle()
                .fill(palette.accent)
                .frame(width: 6.5, height: 6.5)
            Circle()
                .strokeBorder(palette.accent, lineWidth: 1)
                .frame(width: 8, height: 8)
                .scaleEffect(CGFloat(0.8 + progress * 2))
                .opacity(motionOn ? 0.85 * (1 - progress) : 0.4)
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }

    // MARK: - Derived

    private static let frameInterval: Double = 1.0 / 30.0
    /// `t += 0.016` per frame at 60 fps in the browser, which is 0.96 per second of real time.
    private static let waveSpeed: Double = 0.96
    private static let wordInterval: Double = 2.6
    private static let spacing: CGFloat = 15
    private static let minimumDot: Double = 0.5
    private static let maximumDot: Double = 2.2

    private var safeRatio: CGFloat {
        guard ratio.isFinite, ratio > 0 else { return 1 }
        return min(max(ratio, 0.4), 2.6)
    }

    private func wordIndex(at elapsed: Double) -> Int {
        guard headline == nil, words.count > 1 else { return 0 }
        let step = Int(elapsed / MediaCoverPlate.wordInterval)
        return abs(step) % words.count
    }

    private func word(at elapsed: Double) -> String {
        if let headline { return headline }
        guard !words.isEmpty else { return "" }
        return words[wordIndex(at: elapsed)]
    }

    private static func elapsed(from start: Date, to now: Date) -> Double {
        let seconds = now.timeIntervalSince(start)
        return seconds > 0 ? seconds : 0
    }
}
