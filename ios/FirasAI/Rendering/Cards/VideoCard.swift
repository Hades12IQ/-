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
/// While it is being made it wears the same cover the picture card wears — the web's own comment on
/// `.video-card` says the two must "read as one family" (`styles.css:12386`) — so a video request
/// answers on the frame it is sent instead of sitting on an empty box.
///
/// The bytes are the local file the host downloaded once and hands over as a URL: never streamed
/// twice, never held as `Data`. And downloading is its own operation: a clip whose file does not
/// arrive says *that*, with a free retry, instead of borrowing the render's failure sentence.
struct VideoCard: View {

    /// `auto` reads the fence: a cache key means bytes exist, no key means the render is still
    /// running. `failed` carries the server's error code, never its sentence.
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
    @State private var downloadFailed = false
    @State private var reloadToken = 0
    @State private var since: Date

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
        _since = State(initialValue: startedAt ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mediaFrame
            captionRow
        }
        .frame(maxWidth: VideoCard.maximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: reloadKey) { await load() }
        .onChange(of: startedAt) { _, updated in
            if let updated { since = updated }
        }
        .onDisappear { player?.pause() }
    }

    // MARK: - Frame

    @ViewBuilder
    private var mediaFrame: some View {
        switch resolvedPhase {
        case .failed(let code):
            renderFailurePlate(code: code)
        case .rendering:
            renderingPlate
        case .auto, .ready:
            readyFrame
        }
    }

    @ViewBuilder
    private var readyFrame: some View {
        if let player {
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
        } else if downloadFailed {
            downloadFailurePlate
        } else if resolveFile == nil {
            unavailablePlate
        } else {
            cover
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

    // MARK: - Progress

    /// The cover, plus the one thing a video card must say that a picture card does not: this takes
    /// minutes, and it keeps running when you leave the screen (the job is the server's,
    /// `plan/Jobs.md`). The web's own «نصف دقيقة» is stale since the render moved to Wan-3
    /// (`web-media-ux.md §5.2` marks it so), so the verb is kept and the wait is told truthfully.
    private var renderingPlate: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let elapsed = VideoCard.seconds(from: since, to: context.date)
            if elapsed > renderCeiling {
                stalledPlate
            } else {
                cover.overlay(alignment: .bottomLeading) { waitLine(elapsed: elapsed) }
            }
        }
    }

    private var cover: some View {
        MediaCoverPlate(
            palette: palette,
            lang: lang,
            motionOn: motionOn,
            ratio: 16.0 / 9.0,
            cornerRadius: 14,
            words: [VideoCardCopy.working(lang)],
            startedAt: since
        )
    }

    private func waitLine(elapsed: Int) -> some View {
        HStack(spacing: 8) {
            Text(ArabicText.timer(elapsed))
                .font(FirasType.mono)
                .foregroundStyle(palette.textMuted)
                .forceLTR()
            Text(VideoCardCopy.keepsWorking(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .bidiIsland(for: VideoCardCopy.keepsWorking(lang), fallback: lang)
    }

    private var stalledPlate: some View {
        quietPlate(headline: VideoCardCopy.stalledHead(lang), isError: false)
            .overlay {
                plateBody(sentence: VideoCardCopy.stalled(lang), title: VideoCardCopy.regenerate(lang), action: onRegenerate)
            }
    }

    // MARK: - Failure

    private func renderFailurePlate(code: String) -> some View {
        quietPlate(headline: Strings.Errors.videoFailed(lang), isError: true)
            .overlay {
                plateBody(sentence: reason(for: code), title: VideoCardCopy.regenerate(lang), action: onRegenerate)
            }
    }

    /// The clip rendered; its file did not arrive. Its own headline and a free retry — never the
    /// render's sentence, and never an offer to pay for a second render of a clip that exists.
    private var downloadFailurePlate: some View {
        quietPlate(headline: VideoCardCopy.downloadFailedHead(lang), isError: true)
            .overlay {
                plateBody(
                    sentence: Strings.Media.downloadFailed(lang),
                    title: Strings.Common.retry(lang),
                    action: { reloadToken &+= 1 }
                )
            }
    }

    private var unavailablePlate: some View {
        quietPlate(headline: nil, isError: false)
            .overlay {
                Text(VideoCardCopy.unavailable(lang))
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .bidiIsland(for: VideoCardCopy.unavailable(lang), fallback: lang)
            }
    }

    private func quietPlate(headline: String?, isError: Bool) -> some View {
        MediaCoverPlate(
            palette: palette,
            lang: lang,
            motionOn: motionOn,
            ratio: 16.0 / 9.0,
            cornerRadius: 14,
            headline: headline,
            isError: isError,
            drawsField: false,
            startedAt: since
        )
    }

    private func plateBody(
        sentence: String,
        title: String,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 12) {
            Text(sentence)
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
            if let action {
                Button {
                    Haptics.select()
                    action()
                } label: {
                    Text(title)
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
        .padding(.horizontal, 18)
        .padding(.top, 46)
        .padding(.bottom, 16)
        .bidiIsland(for: sentence, fallback: lang)
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
            + "|" + String(reloadToken)
    }

    private func load() async {
        // Back to the cover on a regenerate: the previous clip must not stay under it.
        guard resolvedPhase == .ready else {
            player?.pause()
            player = nil
            fileURL = nil
            shareURL = nil
            poster = nil
            downloadFailed = false
            return
        }
        guard let resolveFile else { return }
        downloadFailed = false
        guard let url = await resolveFile(meta) else {
            player?.pause()
            player = nil
            fileURL = nil
            shareURL = nil
            poster = nil
            downloadFailed = true
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

    /// Twenty minutes — the server's own `VIDEO_JOB_MAX_MS` — when a job is genuinely live. Two
    /// minutes when nobody claims one is, so a keyless fence restored from another device settles
    /// quickly instead of pretending to render for a third of an hour.
    private var renderCeiling: Int {
        startedAt == nil ? 120 : 20 * 60
    }

    /// Bytes ⇒ ready. No bytes ⇒ the render is still running, which is what a video fence looks
    /// like on the frame it is sent and for the many minutes after it.
    private var resolvedPhase: Phase {
        switch phase {
        case .auto:
            if !meta.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .ready }
            return .rendering
        case .rendering, .ready, .failed:
            return phase
        }
    }

    /// The clip's own ratio once a frame has been read; 16:9 until then, clamped so a corrupt
    /// header cannot hand the layout a one-pixel-tall row.
    private var frameRatio: CGFloat {
        guard let posterRatio, posterRatio.isFinite, posterRatio > 0 else { return 16.0 / 9.0 }
        return min(max(posterRatio, 0.45), 2.4)
    }

    private static func seconds(from start: Date, to now: Date) -> Int {
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

/// `web-media-ux.md §5.2`, Arabic verbatim where the web has a sentence; the wait, stall and
/// download lines are new, and deliberately truthful about how long a Wan-3 render takes.
private enum VideoCardCopy {
    static let working = LText(ar: "يولّد الفيديو…", en: "Generating the video…")

    static let keepsWorking = LText(
        ar: "قد يستغرق عدة دقائق — يكمل العمل حتى لو غادرت الشاشة.",
        en: "This can take several minutes — it keeps going if you leave."
    )

    static let stalledHead = LText(ar: "طال الانتظار", en: "This is taking too long")

    static let stalled = LText(
        ar: "طال الانتظار أكثر من اللازم. المقطع قد يكون جاهزًا — أعد فتح المحادثة لاحقًا.",
        en: "That took far too long. The clip may still land — reopen the chat later."
    )

    /// Never «تعذّر توليد الفيديو»: the clip was made, its file did not come down.
    static let downloadFailedHead = LText(ar: "تعذّر تنزيل المقطع", en: "The clip did not download")

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
