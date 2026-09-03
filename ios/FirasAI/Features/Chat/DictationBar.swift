import SwiftUI

/// The recording row that replaces the composer's control row while dictation runs
/// (`design-brief.md §7.14`, `web-voice-call-mic.md §7.1`).
///
/// Cancel · red dot · 32-bar waveform · `m:ss` timer (always Latin digits, always LTR) · dialect
/// chip · done. Nothing here starts or stops audio: `DictationController` owns the recorder, this
/// view only shows it and reports the two taps.
struct DictationBar: View {

    private let dictation: DictationController
    private let dialect: DictationDialect
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let motionOn: Bool
    private let onCancel: () -> Void
    private let onFinish: () -> Void
    private let onPickDialect: () -> Void

    @State private var bars: [CGFloat] = Array(repeating: 0.08, count: DictationBar.barCount)

    private static let barCount = 32

    init(
        dictation: DictationController,
        dialect: DictationDialect,
        palette: FirasPalette,
        lang: AppLanguage,
        motionOn: Bool,
        onCancel: @escaping () -> Void,
        onFinish: @escaping () -> Void,
        onPickDialect: @escaping () -> Void
    ) {
        self.dictation = dictation
        self.dialect = dialect
        self.palette = palette
        self.lang = lang
        self.motionOn = motionOn
        self.onCancel = onCancel
        self.onFinish = onFinish
        self.onPickDialect = onPickDialect
    }

    var body: some View {
        HStack(spacing: 10) {
            cancelButton
            if isTranscribing {
                transcribingBody
            } else {
                recordingBody
            }
            doneButton
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
        .onChange(of: dictation.level) { _, newValue in
            push(level: newValue)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Pieces

    private var cancelButton: some View {
        FirasIconButton(
            symbol: "xmark",
            label: Strings.Composer.micCancel(lang),
            palette: palette,
            action: onCancel
        )
    }

    private var doneButton: some View {
        FirasIconButton(
            symbol: "checkmark",
            label: Strings.Composer.micDone(lang),
            palette: palette,
            prominent: true,
            action: onFinish
        )
        .opacity(isTranscribing ? 0.4 : 1)
        .disabled(isTranscribing)
    }

    private var recordingBody: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(palette.error)
                .frame(width: 8, height: 8)
                .opacity(motionOn ? 1 : 0.85)
                .accessibilityHidden(true)

            waveform

            Text(ArabicText.timer(dictation.seconds))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
                .monospacedDigit()
                .forceLTR()
                .accessibilityLabel(Text(Strings.Composer.micListening(lang)))

            dialectChip
        }
    }

    private var transcribingBody: some View {
        HStack(spacing: 8) {
            LiveDot(palette: palette, motionOn: motionOn)
            Text(Strings.Composer.micTranscribing(lang))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(bars.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(palette.accent.opacity(0.85))
                    .frame(width: 2, height: max(3, bars[index] * 22))
            }
        }
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .forceLTR()
        .animation(motionOn ? .linear(duration: 0.08) : nil, value: bars)
        .accessibilityHidden(true)
    }

    private var dialectChip: some View {
        Button(action: onPickDialect) {
            HStack(spacing: 4) {
                Text(verbatim: dialect.flag)
                    .font(.system(size: 12))
                Text(shortDialectLabel)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Composer.dictationLanguage(lang)))
        .accessibilityValue(Text(dialect.label(lang)))
    }

    // MARK: - State

    private var isTranscribing: Bool {
        dictation.state == .transcribing
    }

    /// The menu label is a whole sentence for `auto`; the chip only has room for the first word.
    private var shortDialectLabel: String {
        let full = dialect.label(lang)
        if let separator = full.range(of: " — ") {
            return String(full[full.startIndex..<separator.lowerBound])
        }
        return full
    }

    private func push(level: Float) {
        var next = bars
        next.removeFirst()
        next.append(CGFloat(min(max(level, 0), 1)))
        bars = next
    }
}
