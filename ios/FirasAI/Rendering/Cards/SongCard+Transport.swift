import Foundation
import SwiftUI

/// The song card's transport, its two actions and the lyric sheet.
///
/// Split out of `SongCard.swift` for length only — every member here belongs to that struct. The
/// struct's storage is `internal` rather than `private` for exactly this reason: a `private` member
/// is visible to extensions **in the same file only**, so relying on one across a split is a
/// compile error rather than a style question (the same note `MediaStore` carries).
extension SongCard {

    // MARK: - Transport

    var transport: some View {
        HStack(spacing: 12) {
            playButton

            VStack(spacing: 2) {
                scrubber
                times
            }
            .frame(maxWidth: .infinity)
        }
        .forceLTR()
    }

    /// Grey and inert while the file is not reachable. This is the «ما يمشي المؤقت و الشريط» half
    /// that the card can honestly own: nothing here can make the player run, but a button that
    /// looks alive and answers no tap is what reads as a broken app.
    var playButton: some View {
        Button {
            Haptics.select()
            onPlayPause?()
        } label: {
            Image(systemName: playSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.onAccent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(playDisabled ? palette.textMuted : palette.accent))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(playDisabled)
        .accessibilityLabel(
            Text(playback.isPlaying ? SongCardCopy.pause(lang) : SongCardCopy.play(lang))
        )
    }

    var playDisabled: Bool {
        onPlayPause == nil || playback.isLoading || transportBlocked
    }

    /// A scrubber that works: the thumb follows the finger while it is down and the host is told
    /// once, on release. Seeking on every intermediate value would restart the decoder on each
    /// frame of the drag.
    var scrubber: some View {
        Slider(
            value: Binding(
                get: { displayedElapsed },
                set: { scrubValue = $0 }
            ),
            in: 0...max(upperBound, 1),
            onEditingChanged: { editing in
                if editing {
                    scrubValue = min(max(playback.elapsed, 0), max(upperBound, 0))
                    scrubbing = true
                } else {
                    scrubbing = false
                    onSeek?(scrubValue)
                }
            }
        )
        .tint(palette.accent)
        .disabled(onSeek == nil || upperBound <= 0.05 || transportBlocked)
        .accessibilityLabel(Text(SongCardCopy.seek(lang)))
    }

    var times: some View {
        HStack(spacing: 6) {
            Text(elapsedText)
                .font(FirasType.mono)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 4)
            Text(durationText)
                .font(FirasType.mono)
                .foregroundStyle(palette.textMuted)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    var actionRow: some View {
        HStack(spacing: 8) {
            downloadControl
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

    /// **The save the owner said was missing** («حفظ الاغنية ماكو»), and it is always on the card
    /// once the song is ready — never conditional on a fetch having already succeeded.
    ///
    /// A song is the one kind that cannot go to Photos (`MediaStore.saveToPhotos` refuses it and
    /// says so), so keeping one means the share sheet, and from there Files, Messages or anywhere
    /// else. The file is copied under the song's own title first, so what the reader saves is
    /// «أغنية العيد.mp3» and not a forty-character SHA-1.
    ///
    /// Four faces, in the order they occur: the host's own handler, the share sheet at the file,
    /// a free retry when the file never came, and — while it is still coming — a quiet disabled
    /// label rather than a hole where a button belongs.
    @ViewBuilder
    var downloadControl: some View {
        if let onDownload {
            capsuleButton(
                title: Strings.Media.saveSong(lang),
                symbol: "square.and.arrow.down",
                prominent: true,
                action: onDownload
            )
        } else if let shareURL {
            ShareLink(item: shareURL) {
                capsuleLabel(
                    title: Strings.Media.saveSong(lang),
                    symbol: "square.and.arrow.down",
                    prominent: true
                )
            }
            .accessibilityLabel(Text(Strings.Media.saveSong(lang)))
        } else if downloadFailed {
            capsuleButton(
                title: Strings.Common.retry(lang),
                symbol: "arrow.clockwise",
                prominent: true,
                action: { reloadToken &+= 1 }
            )
        } else if resolveShareFile != nil {
            capsuleLabel(
                title: Strings.Media.saveSong(lang),
                symbol: "hourglass",
                prominent: false
            )
            .opacity(0.55)
            .accessibilityLabel(Text(Strings.Media.fetchingSong(lang)))
        }
    }

    func capsuleButton(
        title: String,
        symbol: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            capsuleLabel(title: title, symbol: symbol, prominent: prominent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    func capsuleLabel(title: String, symbol: String, prominent: Bool) -> some View {
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

    // MARK: - Lyrics

    @ViewBuilder
    var lyricsDisclosure: some View {
        if !lyricsText.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
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
                        .lineSpacing(4)
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

}
