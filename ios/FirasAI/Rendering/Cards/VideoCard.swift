import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// The ```` ```firas-video ```` card (`web-media-ux.md §5.2`, `design-brief.md §7.12`).
///
/// A clip in a transcript is a **poster first**: the frame the render actually produced, at the
/// clip's own ratio, with one play glyph over it. Nothing is loaded into an `AVPlayer` until the
/// reader asks for it, so scrolling past ten clips costs ten thumbnails rather than ten decoders.
///
/// The bytes are the local file the host downloaded once and hands over as a URL — never streamed
/// twice, never held as `Data`. Save is the host's (Photos needs its permission); share is this
/// card's own `ShareLink` over that same file when the host wired nothing.
struct VideoCard: View {

    /// `auto` reads the fence: a cache key means bytes exist, no key means a render nobody
    /// finished watching. `failed` carries the server's error code, never its sentence.
    enum Phase: Sendable, Equatable {
        case auto
        case rendering
        case ready
        case failed(code: String)
    }

    private let meta: MediaMeta
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let phase: Phase
    private let motionOn: Bool
    private let startedAt: Date?
    private let resolveFile: ((MediaMeta) async -> URL?)?
    private let resolveShareFile: ((MediaMeta) async -> URL?)?
    private let onSave: (() -> Void)?
    private let onShare: (() -> Void)?
    private let onRegenerate: (() -> Void)?

    @State private var fileURL: URL?
    @State private var shareURL: URL?
    @State private var poster: UIImage?
    @State private var posterRatio: CGFloat?
    @State private var player: AVPlayer?
    @State private var loadFailed = false
    @State private var since: Date?

    init(
        meta: MediaMeta,
        palette: FirasPalette,
        lang: AppLanguage,
        phase: Phase = .auto,
        motionOn: Bool = true,
        startedAt: Date? = nil,
        resolveFile: ((MediaMeta) async -> URL?)? = nil,
        resolveShareFile: ((MediaMeta) async -> URL?)? = nil,
        onSave: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil,
        onRegenerate: (() -> Void)? = nil
    ) {
        self.meta = meta
        self.palette = palette
        self.lang = lang
        self.phase = phase
        self.motionOn = motionOn
        self.startedAt = startedAt
        self.resolveFile = resolveFile
        self.resolveShareFile = resolveShareFile
        self.onSave = onSave
        self.onShare = onShare
        self.onRegenerate = onRegenerate
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
        switch resolvedPhase {
        case .failed(let code):
            plate { failureBody(code: code) }
        case .rendering:
            renderingPlate
        case .auto, .ready:
            readyFrame
        }
    }

    @ViewBuilder
    private var readyFrame: some View {
        if let player = player {
            VideoPlayer(player: player)
                .aspectRatio(frameRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel(Text(accessibilityText))
        } else if fileURL != nil {
            posterFrame
        } else if loadFailed {
            plate { failureBody(code: "network") }
        } else if resolveFile == nil {
            plate { unavailableBody }
        } else {
            plate { preparingBody }
        }
    }

    /// The frame the render produced, with one play glyph. Tapping it is what creates the player.
    private var posterFrame: some View {
        ZStack {
            Color.black
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            playGlyph
        }
        .aspectRatio(frameRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { startPlayback() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(.isButton)
    }

    private var playGlyph: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 58, height: 58)
            .background {
                Circle().fill(Color.black.opacity(0.42))
            }
            .overlay {
                Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private func plate<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(palette.surfaceSunken)
            .aspectRatio(frameRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { content() }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    // MARK: - Progress

    /// Honest progress. The web's own line says «نصف دقيقة», which has not been true since the
    /// render moved to Wan-3 (`web-media-ux.md §5.2` marks it stale), so the card keeps the verb
    /// and tells the truth about the wait — and says out loud that the render survives leaving the
    /// screen, which it does (the job is the server's, `plan/Jobs.md`).
    private var renderingPlate: some View {
        plate {
            TimelineView(.periodic(from: since ?? Date(), by: 1)) { context in
                renderingBody(elapsed: VideoCard.seconds(from: since, to: context.date))
            }
        }
    }

    @ViewBuilder
    private func renderingBody(elapsed: Int) -> some View {
        if elapsed > VideoCard.renderCeiling {
            stalledBody
        } else {
            VStack(spacing: 8) {
                FirasActivityLabel(
                    text: VideoCardCopy.working(lang),
                    palette: palette,
                    motionOn: motionOn
                )
                HStack(spacing: 8) {
                    Text(ArabicText.timer(elapsed))
                        .font(FirasType.mono)
                        .foregroundStyle(palette.textMuted)
                        .forceLTR()
                    Text(VideoCardCopy.keepsWorking(lang))
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .bidiIsland(for: VideoCardCopy.keepsWorking(lang), fallback: lang)
            }
            .padding(.horizontal, 18)
        }
    }

    private var stalledBody: some View {
        VStack(spacing: 10) {
            Text(VideoCardCopy.stalled(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
            regenerateButton
        }
        .padding(.horizontal, 18)
        .bidiIsland(for: VideoCardCopy.stalled(lang), fallback: lang)
    }

    // MARK: - Failure

    private func failureBody(code: String) -> some View {
        VStack(spacing: 10) {
            Text(reason(for: code))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
            regenerateButton
        }
        .padding(.horizontal, 18)
        .bidiIsland(for: reason(for: code), fallback: lang)
    }

    /// The web offers no retry on this card, so the button exists only for a host that wired one.
    @ViewBuilder
    private var regenerateButton: some View {
        if let onRegenerate {
            Button {
                Haptics.select()
                onRegenerate()
            } label: {
                Text(VideoCardCopy.regenerate(lang))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(palette.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var preparingBody: some View {
        FirasActivityLabel(
            text: VideoCardCopy.preparing(lang),
            palette: palette,
            motionOn: motionOn
        )
        .padding(.horizontal, 18)
        .bidiIsland(for: VideoCardCopy.preparing(lang), fallback: lang)
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
        HStack(spacing: 2) {
            Text(captionText)
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: captionText, fallback: lang)

            if fileURL != nil, let onSave {
                FirasIconButton(
                    symbol: "square.and.arrow.down",
                    label: VideoCardCopy.save(lang),
                    palette: palette,
                    action: onSave
                )
            }
            shareControl
        }
    }

    @ViewBuilder
    private var shareControl: some View {
        if fileURL != nil, let onShare {
            FirasIconButton(
                symbol: "square.and.arrow.up",
                label: Strings.Common.share(lang),
                palette: palette,
                action: onShare
            )
        } else if let shareURL {
            ShareLink(item: shareURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel(Text(Strings.Common.share(lang)))
        }
    }

    // MARK: - Transport

    private func startPlayback() {
        guard let fileURL else { return }
        Haptics.select()
        let started = AVPlayer(url: fileURL)
        started.actionAtItemEnd = .pause
        player = started
        started.play()
    }

    // MARK: - Loading

    private var reloadKey: String {
        meta.key + "|" + (meta.jobId ?? "") + "|" + String(describing: resolvedPhase)
    }

    private func load() async {
        if since == nil { since = startedAt ?? Date() }
        guard resolvedPhase == .ready, let resolveFile else { return }
        loadFailed = false
        let url = await resolveFile(meta)
        guard let url else {
            player?.pause()
            player = nil
            fileURL = nil
            shareURL = nil
            poster = nil
            loadFailed = true
            return
        }
        player?.pause()
        player = nil
        fileURL = url
        if let resolveShareFile {
            shareURL = await resolveShareFile(meta) ?? url
        } else {
            shareURL = url
        }
        let frame = await VideoCard.firstFrame(of: url)
        poster = frame?.image
        posterRatio = frame?.ratio
    }

    /// The first usable frame, decoded off the main actor. A clip whose poster cannot be read still
    /// plays — the frame is a nicety, the file is the thing.
    private nonisolated static func firstFrame(of url: URL) async -> (image: UIImage, ratio: CGFloat)? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        let time = CMTime(seconds: 0.3, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        let cgImage = result.image
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }
        return (UIImage(cgImage: cgImage), width / height)
    }

    // MARK: - Derived

    private static let maximumWidth: CGFloat = 520
    /// Twenty minutes — the server's own `VIDEO_JOB_MAX_MS`. Past it the render is terminal one way
    /// or the other and a spinner would be a lie.
    private static let renderCeiling: Int = 20 * 60

    /// Bytes ⇒ ready. No bytes and no live render behind the card ⇒ the clip never landed here. A
    /// keyless fence in a conversation from another device is that case, and the honest answer is
    /// the sentence, not a spinner restarted by every scroll.
    private var resolvedPhase: Phase {
        switch phase {
        case .auto:
            if !meta.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .ready }
            return startedAt == nil ? .failed(code: "timeout") : .rendering
        case .rendering, .ready:
            return phase
        case .failed:
            return phase
        }
    }

    /// The clip's own ratio once a frame has been read; 16:9 until then, clamped so a corrupt
    /// header cannot hand the layout a one-pixel-tall row.
    private var frameRatio: CGFloat {
        guard let posterRatio, posterRatio.isFinite, posterRatio > 0 else { return 16.0 / 9.0 }
        return min(max(posterRatio, 0.45), 2.4)
    }

    private static func seconds(from start: Date?, to now: Date) -> Int {
        guard let start else { return 0 }
        let elapsed = now.timeIntervalSince(start)
        return elapsed > 0 ? Int(elapsed) : 0
    }

    private var captionText: String {
        let note = (meta.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return String(note.prefix(160)) }
        return String(meta.prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }

    private var accessibilityText: String {
        captionText.isEmpty ? VideoCardCopy.clip(lang) : captionText
    }

    /// The card's sentences, by code (`web-media-ux.md §5.2`).
    private func reason(for code: String) -> String {
        switch code.lowercased() {
        case "daily_limit":
            return Strings.Errors.videoDailyLimit(lang)
        case "rate_window", "site_media_ceiling":
            return Strings.Errors.musicRateWindow(lang)
        case "rate_limited":
            return Strings.Errors.tooFast(lang)
        case "bad_image", "image_too_large":
            return Strings.Errors.badImage(lang)
        case "timeout", "expired":
            return VideoCardCopy.stalled(lang)
        case "network", "offline", "unreachable":
            return VideoCardCopy.whyNetwork(lang)
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

/// `web-media-ux.md §5.2`, Arabic verbatim where the web has a sentence; the wait and stall lines
/// are new, and deliberately truthful about how long a Wan-3 render takes.
private enum VideoCardCopy {
    static let working = LText(ar: "يولّد الفيديو…", en: "Generating the video…")

    static let keepsWorking = LText(
        ar: "قد يستغرق عدة دقائق — يكمل العمل حتى لو غادرت الشاشة.",
        en: "This can take several minutes — it keeps going if you leave."
    )

    static let stalled = LText(
        ar: "طال الانتظار أكثر من اللازم. المقطع قد يكون جاهزًا — أعد فتح المحادثة لاحقًا.",
        en: "That took far too long. The clip may still land — reopen the chat later."
    )

    static let preparing = LText(ar: "يجهّز المقطع…", en: "Preparing the clip…")
    static let regenerate = LText(ar: "أعد التوليد", en: "Regenerate")
    static let signIn = LText(ar: "أنشئ حسابًا لتوليد الفيديو", en: "Create an account to generate video")
    static let save = LText(ar: "حفظ الفيديو", en: "Save video")
    static let clip = LText(ar: "مقطع فيديو", en: "Video clip")

    static let whyNetwork = LText(
        ar: "تعذّر الوصول إلى المقطع — تحقّق من اتّصالك.",
        en: "The clip could not be fetched — check your connection."
    )

    static let unavailable = LText(
        ar: "المقطع غير متاح للتشغيل هنا.",
        en: "This clip cannot be played here."
    )
}
