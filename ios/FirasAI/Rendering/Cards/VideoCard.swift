import AVKit
import SwiftUI

/// The ```` ```firas-video ```` card (`web-media-ux.md §5.2`, `design-brief.md §7.12`).
///
/// A 16:9 frame at most 520 pt wide holding an `AVPlayer` over the clip's **local** file — the
/// bytes are downloaded once by the host and handed here as a file URL, never streamed twice and
/// never held as `Data`. Nothing here starts playback: the transport belongs to the person
/// watching. The web has no retry on this card and neither does this one; save and share are the
/// only actions, and each appears only when the host wired it.
struct VideoCard: View {

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
    private let resolveFile: ((MediaMeta) async -> URL?)?
    private let onSave: (() -> Void)?
    private let onShare: (() -> Void)?

    @State private var player: AVPlayer?
    @State private var loadFailed = false

    init(
        meta: MediaMeta,
        palette: FirasPalette,
        lang: AppLanguage,
        phase: Phase = .ready,
        motionOn: Bool = true,
        resolveFile: ((MediaMeta) async -> URL?)? = nil,
        onSave: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil
    ) {
        self.meta = meta
        self.palette = palette
        self.lang = lang
        self.phase = phase
        self.motionOn = motionOn
        self.resolveFile = resolveFile
        self.onSave = onSave
        self.onShare = onShare
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mediaFrame
            captionRow
        }
        .frame(maxWidth: VideoCard.maximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: reloadKey) { await load() }
        .onDisappear { player?.pause() }
    }

    // MARK: - Frame

    @ViewBuilder
    private var mediaFrame: some View {
        switch phase {
        case .failed(let code):
            plate { failureBody(code: code) }
        case .rendering:
            plate { loaderBody }
        case .ready:
            readyFrame
        }
    }

    @ViewBuilder
    private var readyFrame: some View {
        if let player = player {
            VideoPlayer(player: player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 1)
                }
                .accessibilityLabel(Text(accessibilityText))
        } else if loadFailed {
            plate { failureBody(code: "network") }
        } else if resolveFile == nil {
            plate { unavailableBody }
        } else {
            plate { loaderBody }
        }
    }

    private func plate<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(palette.surfaceSunken)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { content() }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            }
    }

    private var loaderBody: some View {
        FirasActivityLabel(
            text: VideoCardCopy.working(lang),
            palette: palette,
            motionOn: motionOn
        )
        .padding(.horizontal, 18)
        .bidiIsland(for: VideoCardCopy.working(lang), fallback: lang)
    }

    private func failureBody(code: String) -> some View {
        Text(reason(for: code))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(palette.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .bidiIsland(for: reason(for: code), fallback: lang)
    }

    private var unavailableBody: some View {
        Text(VideoCardCopy.unavailable(lang))
            .font(FirasType.caption)
            .foregroundStyle(palette.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .bidiIsland(for: VideoCardCopy.unavailable(lang), fallback: lang)
    }

    // MARK: - Caption

    private var captionRow: some View {
        HStack(spacing: 4) {
            Text(captionText)
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: captionText, fallback: lang)

            if player != nil, let onSave {
                FirasIconButton(
                    symbol: "square.and.arrow.down",
                    label: VideoCardCopy.save(lang),
                    palette: palette,
                    action: onSave
                )
            }
            if player != nil, let onShare {
                FirasIconButton(
                    symbol: "square.and.arrow.up",
                    label: Strings.Common.share(lang),
                    palette: palette,
                    action: onShare
                )
            }
        }
    }

    // MARK: - Loading

    private var reloadKey: String { meta.key + "|" + (meta.jobId ?? "") + "|" + String(describing: phase) }

    private func load() async {
        guard phase == .ready, let resolveFile else { return }
        loadFailed = false
        let url = await resolveFile(meta)
        guard let url else {
            player?.pause()
            player = nil
            loadFailed = true
            return
        }
        player?.pause()
        player = AVPlayer(url: url)
    }

    // MARK: - Derived

    private static let maximumWidth: CGFloat = 520

    private var captionText: String {
        let note = meta.note ?? ""
        if !note.isEmpty { return String(note.prefix(120)) }
        return String(meta.prompt.prefix(80))
    }

    private var accessibilityText: String {
        let text = captionText
        return text.isEmpty ? VideoCardCopy.clip(lang) : text
    }

    /// The card's sentences, by code (`web-media-ux.md §5.2`).
    private func reason(for code: String) -> String {
        switch code.lowercased() {
        case "daily_limit":
            return Strings.Errors.videoDailyLimit(lang)
        case "signin_required", "account_required", "unauthorized":
            return VideoCardCopy.signIn(lang)
        case "not_configured":
            return Strings.Errors.videoNotConfigured(lang)
        default:
            return Strings.Errors.videoFailed(lang)
        }
    }
}

// MARK: - Copy

/// `web-media-ux.md §5.2`, Arabic verbatim.
private enum VideoCardCopy {
    static let working = LText(
        ar: "يولّد الفيديو… قد يستغرق نحو نصف دقيقة",
        en: "Generating video… this takes about half a minute"
    )
    static let signIn = LText(ar: "أنشئ حسابًا لتوليد الفيديو", en: "Create an account to generate video")
    static let save = LText(ar: "حفظ الفيديو", en: "Save video")
    static let clip = LText(ar: "مقطع فيديو", en: "Video clip")
    static let unavailable = LText(
        ar: "المقطع غير متاح للتشغيل هنا.",
        en: "This clip cannot be played here."
    )
}
