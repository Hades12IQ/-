import SwiftUI

/// The ```` ```firas-music ```` card (`web-media-ux.md §6.4`, `design-brief.md §7.12`).
///
/// Full width on `surface`: the ♪ title line, the style line, a transport with an LTR
/// `elapsed / total` readout, the lyrics behind a disclosure, and Download / Regenerate.
///
/// The card draws the transport but never owns the audio. Only one song may be audible at a time
/// and a song has to duck TTS and stop for a call — decisions that belong to the app's single audio
/// owner — so playback state arrives in `Playback` and every control is a callback.
struct SongCard: View {

    /// What the host's player is doing right now.
    struct Playback: Sendable, Equatable {
        var isPlaying: Bool
        var isLoading: Bool
        var elapsed: Double
        var duration: Double

        init(isPlaying: Bool = false, isLoading: Bool = false, elapsed: Double = 0, duration: Double = 0) {
            self.isPlaying = isPlaying
            self.isLoading = isLoading
            self.elapsed = elapsed
            self.duration = duration
        }
    }

    /// `rendering` is a queued render, `failed` carries the server's error code.
    enum Phase: Sendable, Equatable {
        case rendering
        case ready
        case failed(code: String)
    }

    private let meta: MediaMeta
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let phase: Phase
    private let motionOn: Bool
    private let playback: Playback
    private let onPlayPause: (() -> Void)?
    private let onSeek: ((Double) -> Void)?
    private let onDownload: (() -> Void)?
    private let onRegenerate: (() -> Void)?

    @State private var lyricsShown = false

    init(
        meta: MediaMeta,
        palette: FirasPalette,
        lang: AppLanguage,
        phase: Phase = .ready,
        motionOn: Bool = true,
        playback: Playback = Playback(),
        onPlayPause: (() -> Void)? = nil,
        onSeek: ((Double) -> Void)? = nil,
        onDownload: (() -> Void)? = nil,
        onRegenerate: (() -> Void)? = nil
    ) {
        self.meta = meta
        self.palette = palette
        self.lang = lang
        self.phase = phase
        self.motionOn = motionOn
        self.playback = playback
        self.onPlayPause = onPlayPause
        self.onSeek = onSeek
        self.onDownload = onDownload
        self.onRegenerate = onRegenerate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            stateBody
            lyricsDisclosure
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(palette)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "♪")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)

                if !styleLine.isEmpty {
                    Text(styleLine)
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bidiIsland(for: title, fallback: lang)
    }

    // MARK: - States

    @ViewBuilder
    private var stateBody: some View {
        switch phase {
        case .rendering:
            FirasActivityLabel(text: SongCardCopy.working(lang), palette: palette, motionOn: motionOn)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: SongCardCopy.working(lang), fallback: lang)
        case .failed(let code):
            failedBody(code: code)
        case .ready:
            readyBody
        }
    }

    private func failedBody(code: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(reason(for: code))
                .font(FirasType.caption)
                .foregroundStyle(palette.error)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: reason(for: code), fallback: lang)

            if let onRegenerate {
                capsuleButton(
                    title: SongCardCopy.regenerate(lang),
                    symbol: "arrow.clockwise",
                    prominent: true,
                    action: onRegenerate
                )
            }
        }
    }

    @ViewBuilder
    private var readyBody: some View {
        if onPlayPause == nil && onSeek == nil {
            Text(SongCardCopy.unavailable(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: SongCardCopy.unavailable(lang), fallback: lang)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                transport
                actionRow
            }
        }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 12) {
            playButton

            VStack(spacing: 4) {
                scrubber
                times
            }
            .frame(maxWidth: .infinity)
        }
        .forceLTR()
    }

    private var playButton: some View {
        Button {
            Haptics.select()
            onPlayPause?()
        } label: {
            Image(systemName: playSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.onAccent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(palette.accent))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(onPlayPause == nil || playback.isLoading)
        .accessibilityLabel(
            Text(playback.isPlaying ? SongCardCopy.pause(lang) : SongCardCopy.play(lang))
        )
    }

    @ViewBuilder
    private var scrubber: some View {
        if onSeek != nil, upperBound > 0.05 {
            Slider(value: seekBinding, in: 0...upperBound)
                .tint(palette.accent)
                .accessibilityLabel(Text(SongCardCopy.seek(lang)))
        } else {
            Capsule()
                .fill(palette.surfaceSunken)
                .frame(height: 4)
                .accessibilityHidden(true)
        }
    }

    private var times: some View {
        HStack(spacing: 6) {
            Text(elapsedText)
                .font(FirasType.mono)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 4)
            Text(durationText)
                .font(FirasType.mono)
                .foregroundStyle(palette.textMuted)
        }
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 8) {
            if let onDownload {
                capsuleButton(
                    title: Strings.Common.download(lang),
                    symbol: "square.and.arrow.down",
                    prominent: false,
                    action: onDownload
                )
            }
            if let onRegenerate {
                capsuleButton(
                    title: SongCardCopy.regenerate(lang),
                    symbol: "arrow.clockwise",
                    prominent: false,
                    action: onRegenerate
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func capsuleButton(
        title: String,
        symbol: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(prominent ? palette.onAccent : palette.textSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Capsule().fill(prominent ? palette.accent : palette.surfaceSunken))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : palette.border, lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    // MARK: - Lyrics

    @ViewBuilder
    private var lyricsDisclosure: some View {
        if !lyricsText.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(motionOn ? FirasMotion.standard : FirasMotion.fade) {
                        lyricsShown.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: lyricsShown ? "chevron.down" : "chevron.forward")
                            .font(.system(size: 11, weight: .semibold))
                        Text(SongCardCopy.lyrics(lang))
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(palette.textSecondary)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(lyricsShown ? .isSelected : [])

                if lyricsShown {
                    Text(lyricsText)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(palette.surfaceSunken)
                        )
                        .bidiIsland(for: lyricsText, fallback: lang)
                }
            }
        }
    }

    // MARK: - Derived

    private var title: String {
        let candidate = meta.title ?? ""
        if !candidate.isEmpty { return String(candidate.prefix(90)) }
        if !meta.prompt.isEmpty { return String(meta.prompt.prefix(90)) }
        return SongCardCopy.untitled(lang)
    }

    private var styleLine: String {
        let style = meta.style ?? ""
        if !style.isEmpty { return String(style.prefix(90)) }
        if meta.title != nil, !meta.prompt.isEmpty { return String(meta.prompt.prefix(90)) }
        return ""
    }

    private var lyricsText: String {
        (meta.lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var playSymbol: String {
        if playback.isLoading { return "hourglass" }
        return playback.isPlaying ? "pause.fill" : "play.fill"
    }

    private var upperBound: Double {
        let duration = playback.duration
        if duration > 0 { return duration }
        return Double(meta.seconds ?? 0)
    }

    private var seekBinding: Binding<Double> {
        Binding(
            get: { min(max(playback.elapsed, 0), max(upperBound, 0.05)) },
            set: { onSeek?($0) }
        )
    }

    private var elapsedText: String { ArabicText.timer(Int(max(0, playback.elapsed))) }

    private var durationText: String {
        upperBound > 0 ? ArabicText.timer(Int(upperBound)) : "--:--"
    }

    /// `web-media-ux.md §6.4`, chosen by code.
    private func reason(for code: String) -> String {
        switch code.lowercased() {
        case "not_configured":
            return Strings.Errors.musicNotConfigured(lang)
        case "rate_window", "daily_limit":
            return Strings.Errors.musicRateWindow(lang)
        case "signin_required", "account_required", "unauthorized":
            return SongCardCopy.signIn(lang)
        default:
            return Strings.Errors.musicFailed(lang)
        }
    }
}

// MARK: - Copy

/// `web-media-ux.md §6.4`, Arabic verbatim.
private enum SongCardCopy {
    static let working = LText(ar: "يلحّن الأغنية… حوالي دقيقة", en: "Composing… about a minute")
    static let play = LText(ar: "تشغيل", en: "Play")
    static let pause = LText(ar: "إيقاف مؤقّت", en: "Pause")
    static let seek = LText(ar: "موضع التشغيل", en: "Seek")
    static let regenerate = LText(ar: "أعد التلحين", en: "Regenerate")
    static let signIn = LText(ar: "سجّل دخولك حتى تصنع أغنية", en: "Sign in to make a song")
    static let lyrics = LText(ar: "الكلمات", en: "Lyrics")
    static let untitled = LText(ar: "أغنية فِراس", en: "Firas song")
    static let unavailable = LText(
        ar: "الأغنية غير متاحة للتشغيل هنا.",
        en: "This song cannot be played here."
    )
}
