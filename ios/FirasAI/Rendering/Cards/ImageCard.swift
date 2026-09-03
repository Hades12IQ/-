import SwiftUI
import UIKit

/// The ```` ```firas-image ```` card (`web-media-ux.md §3.5–3.8`, `design-brief.md §7.12`).
///
/// It is the website's card, state for state:
///
/// | state | plate | width |
/// |---|---|---|
/// | rendering | the cover — dot field, pulse, one rotating word | 300 pt, square |
/// | ready | the picture at its own ratio, radius 20 | 420 pt |
/// | generation failed | the same plate, no field, `تعذّر توليد الصورة` in error ink | 340 pt, 4:3 |
/// | download failed | the same plate, `تعذّر تنزيل الصورة` | 340 pt, 4:3 |
///
/// Three defects the owner hit on a device are fixed here and each one is a rule now:
///
/// 1. **A creation shows its cover on the first frame.** `phase == .auto` with no cache key used to
///    resolve to `.failed(code: "timeout")` unless the host had already wired `startedAt`, so
///    pressing send painted a failure plate — «من ارسل يوقف، ما يطلع الغلاف مالها». A fence with a
///    prompt and no key is a render, not a failure; it resolves to `.rendering`, and only the
///    ceiling (90 s when nobody claims a job is live, 5 min when one is) may end that wait.
/// 2. **Download is its own operation with its own errors.** Bytes that will not arrive used to
///    print `تعذّر توليد الصورة` over a picture that generated perfectly well — «من تحمل الصورة
///    يكلي image generation failed». The two states are now separate, they carry different
///    sentences, and the download plate's button retries the *download* (free) rather than buying a
///    fresh render.
/// 3. **The request is readable while the render runs.** The web deliberately never prints the
///    prompt on a finished card (it is machine-rewritten English); while the cover is up it is the
///    only thing that says which picture this is, so it appears there and disappears on arrival.
struct ImageCard: View {

    /// What the transcript knows about this picture right now.
    ///
    /// `auto` is the honest default: a fence that carries a cache key has bytes, one that does not
    /// is a render. `failed` carries the server's error code, never its sentence — the sentence is
    /// chosen here (`ARCHITECTURE.md §2.15`).
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
    private let showsPrompt: Bool
    private let resolveImage: ((MediaMeta) async -> URL?)?
    private let resolveShareFile: ((MediaMeta) async -> URL?)?
    private let onOpen: (() -> Void)?
    private let onSave: (() -> Void)?
    private let onShare: (() -> Void)?
    private let onEdit: (() -> Void)?
    private let onRetry: (() -> Void)?
    private let onRegenerate: (() -> Void)?

    @State private var picture: UIImage?
    @State private var shareURL: URL?
    /// The bytes did not arrive. Deliberately not the same flag as a failed render.
    @State private var downloadFailed = false
    @State private var downloadAttempts = 0
    @State private var reloadToken = 0
    @State private var retried = false
    @State private var since: Date

    init(
        meta: MediaMeta,
        palette: FirasPalette,
        lang: AppLanguage,
        phase: Phase = .auto,
        motionOn: Bool = true,
        startedAt: Date? = nil,
        showsPrompt: Bool = true,
        resolveImage: ((MediaMeta) async -> URL?)? = nil,
        resolveShareFile: ((MediaMeta) async -> URL?)? = nil,
        onOpen: (() -> Void)? = nil,
        onSave: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil,
        onEdit: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil,
        onRegenerate: (() -> Void)? = nil
    ) {
        self.meta = meta
        self.palette = palette
        self.lang = lang
        self.phase = phase
        self.motionOn = motionOn
        self.startedAt = startedAt
        self.showsPrompt = showsPrompt
        self.resolveImage = resolveImage
        self.resolveShareFile = resolveShareFile
        self.onOpen = onOpen
        self.onSave = onSave
        self.onShare = onShare
        self.onEdit = onEdit
        self.onRetry = onRetry
        self.onRegenerate = onRegenerate
        _since = State(initialValue: startedAt ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mediaFrame
            noteLine
            promptLine
            actionBar
        }
        .frame(maxWidth: cardWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(
            FirasMotion.gated(.easeOut(duration: 0.5), motionOn: motionOn),
            value: cardWidth
        )
        .task(id: reloadKey) { await load() }
        .onChange(of: startedAt) { _, updated in
            if let updated { since = updated }
        }
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
        if let picture {
            pictureView(picture)
        } else if downloadFailed {
            downloadFailurePlate
        } else if resolveImage == nil {
            unavailablePlate
        } else {
            cover(ratio: 1)
        }
    }

    private func pictureView(_ picture: UIImage) -> some View {
        Image(uiImage: picture)
            .resizable()
            .aspectRatio(ImageCard.ratio(of: picture), contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onTapGesture { onOpen?() }
            .accessibilityLabel(Text(accessibilityText))
            .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
            .transition(.opacity)
    }

    // MARK: - The cover

    /// The website's plate, on the frame the request is sent — square, small, alive.
    private func cover(ratio: CGFloat) -> some View {
        MediaCoverPlate(
            palette: palette,
            lang: lang,
            motionOn: motionOn,
            ratio: ratio,
            cornerRadius: 20,
            words: ImageCard.loaderWords(lang),
            startedAt: since
        )
    }

    /// The cover with a watch on it: past the ceiling the render is either finished somewhere else
    /// or gone, and a plate that can never stop is the one state this card refuses to draw.
    private var renderingPlate: some View {
        TimelineView(.periodic(from: since, by: 5)) { context in
            if ImageCard.seconds(from: since, to: context.date) > renderCeiling {
                stalledPlate
            } else {
                cover(ratio: 1)
            }
        }
    }

    private var stalledPlate: some View {
        quietPlate(headline: ImageCardCopy.stalledHead(lang), isError: false)
            .overlay {
                plateBody(
                    sentence: ImageCardCopy.stalled(lang),
                    title: retryTitle,
                    action: renderRetryAction
                )
            }
    }

    // MARK: - Failure

    /// The render failed. The web's headline, the web's reason line, the web's cheap-first button.
    private func renderFailurePlate(code: String) -> some View {
        quietPlate(headline: ImageCardCopy.failed(lang), isError: true)
            .overlay {
                plateBody(
                    sentence: reason(for: code),
                    title: retryTitle,
                    action: renderRetryAction
                )
            }
    }

    /// The render worked and the bytes did not arrive. A different failure, so a different plate:
    /// its own headline, its own sentence, and a button that asks for the file again instead of
    /// spending an allowance slot on a picture that already exists.
    private var downloadFailurePlate: some View {
        quietPlate(headline: ImageCardCopy.downloadFailedHead(lang), isError: true)
            .overlay {
                plateBody(
                    sentence: downloadAttempts > 1
                        ? ImageCardCopy.downloadTwice(lang)
                        : Strings.Media.downloadFailed(lang),
                    title: Strings.Common.retry(lang),
                    action: { reloadToken &+= 1 }
                )
            }
    }

    private var unavailablePlate: some View {
        quietPlate(headline: nil, isError: false)
            .overlay {
                Text(ImageCardCopy.unavailable(lang))
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .bidiIsland(for: ImageCardCopy.unavailable(lang), fallback: lang)
            }
    }

    /// The same plate with the wave switched off: a card that is not working must not claim to be.
    private func quietPlate(headline: String?, isError: Bool) -> some View {
        MediaCoverPlate(
            palette: palette,
            lang: lang,
            motionOn: motionOn,
            ratio: 4.0 / 3.0,
            cornerRadius: 20,
            headline: headline,
            isError: isError,
            drawsField: false,
            startedAt: since
        )
    }

    /// A sentence and a way out, low in the plate so it never collides with the headline the plate
    /// is already carrying in its top corner.
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
        .padding(.bottom, 18)
        .bidiIsland(for: sentence, fallback: lang)
    }

    /// Cheap first: the host's own retry (a re-read of the same bytes) before the paid render.
    private var renderRetryAction: (() -> Void)? {
        guard onRetry != nil || onRegenerate != nil else { return nil }
        return {
            if retried || onRetry == nil {
                onRegenerate?()
            } else {
                retried = true
                onRetry?()
            }
        }
    }

    // MARK: - Caption and actions

    /// The reader's own caption, under the picture and above the buttons — the web's
    /// `.image-card__note`. It wraps: losing the tail of a sentence someone wrote themselves is the
    /// whole point going missing.
    @ViewBuilder
    private var noteLine: some View {
        let note = (meta.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            Text(note)
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: note, fallback: lang)
        }
    }

    /// The request, while the request is all there is. It goes away the moment the picture lands —
    /// a finished card shows the picture and the reader's caption, never the machine's prompt.
    @ViewBuilder
    private var promptLine: some View {
        if showsPrompt, picture == nil, !promptText.isEmpty {
            Text(promptText)
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: promptText, fallback: lang)
        }
    }

    /// One solid pill for the thing most people came for, quiet 44 pt glyphs for the rest — the
    /// web's `.image-card__dl` beside its ghost `.image-card__note-btn`.
    @ViewBuilder
    private var actionBar: some View {
        if showsActions {
            HStack(spacing: 4) {
                if let onSave {
                    savePill(onSave)
                }
                shareControl
                if let onEdit {
                    FirasIconButton(
                        symbol: "wand.and.stars",
                        label: Strings.Media.editPicture(lang),
                        palette: palette,
                        action: onEdit
                    )
                }
                if let onRegenerate {
                    FirasIconButton(
                        symbol: "arrow.clockwise",
                        label: ImageCardCopy.regenerate(lang),
                        palette: palette,
                        action: onRegenerate
                    )
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func savePill(_ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                Text(Strings.Media.saveToPhotos(lang))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(palette.onAccent)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Capsule().fill(palette.accent))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Media.saveToPhotos(lang)))
    }

    /// The host's own share sheet when it wired one, otherwise the file this card already holds.
    @ViewBuilder
    private var shareControl: some View {
        if let onShare {
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

    private var showsActions: Bool {
        guard picture != nil else { return false }
        return onSave != nil || onShare != nil || shareURL != nil || onEdit != nil || onRegenerate != nil
    }

    // MARK: - Loading

    private var reloadKey: String {
        meta.key + "|" + String(describing: resolvedPhase) + "|" + String(reloadToken)
    }

    /// Downloading is its own operation. Every exit here sets `downloadFailed`, never a render
    /// failure, and never touches `phase`.
    private func load() async {
        // A regenerate takes the card back to the cover, and the cover must not sit on top of the
        // picture the previous render left behind.
        guard resolvedPhase == .ready else {
            picture = nil
            shareURL = nil
            downloadFailed = false
            return
        }
        guard let resolveImage else { return }
        downloadFailed = false

        guard let url = await resolveImage(meta) else {
            failDownload()
            return
        }
        guard let decoded = await ImageCache.shared.image(forFile: url) else {
            failDownload()
            return
        }

        downloadAttempts = 0
        picture = decoded
        if let resolveShareFile {
            shareURL = await resolveShareFile(meta) ?? url
        } else {
            shareURL = url
        }
    }

    private func failDownload() {
        picture = nil
        shareURL = nil
        downloadAttempts &+= 1
        downloadFailed = true
    }

    // MARK: - Derived

    /// The web's three widths: the cover is smaller than the picture it becomes, and a failed plate
    /// is not a picture so it does not take a picture's room.
    private var cardWidth: CGFloat {
        switch resolvedPhase {
        case .failed:
            return 340
        case .rendering:
            return 300
        case .auto, .ready:
            if picture != nil { return 420 }
            if downloadFailed || resolveImage == nil { return 340 }
            return 300
        }
    }

    /// Five minutes when a job is genuinely live, ninety seconds when nobody claims one is: a
    /// keyless fence restored from another device must not put a five-minute cover on the screen.
    private var renderCeiling: Int {
        startedAt == nil ? 90 : 300
    }

    /// Bytes ⇒ ready. No bytes ⇒ a render, because a fence with a prompt and no key is exactly
    /// what a creation looks like on the frame it is sent.
    private var resolvedPhase: Phase {
        switch phase {
        case .auto:
            if !meta.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .ready }
            return .rendering
        case .rendering, .ready, .failed:
            return phase
        }
    }

    private static func seconds(from start: Date, to now: Date) -> Int {
        let elapsed = now.timeIntervalSince(start)
        return elapsed > 0 ? Int(elapsed) : 0
    }

    private static func ratio(of image: UIImage) -> CGFloat {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return 1 }
        return size.width / size.height
    }

    private var retryTitle: String {
        if retried || onRetry == nil { return ImageCardCopy.regenerate(lang) }
        return ImageCardCopy.tryAgain(lang)
    }

    private var promptText: String {
        String(meta.prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }

    private var accessibilityText: String {
        let note = (meta.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return note }
        return promptText.isEmpty ? ImageCardCopy.picture(lang) : promptText
    }

    /// `imgWhyNet` / `imgWhyEngine` / `imgWhyQuota` / `imgWhySignin` — chosen by code, never by the
    /// server's sentence (`ARCHITECTURE.md §2.15`).
    private func reason(for code: String) -> String {
        switch code.lowercased() {
        case "network", "offline", "unreachable":
            return ImageCardCopy.whyNetwork(lang)
        case "timeout", "expired":
            return ImageCardCopy.stalled(lang)
        case "daily_limit", "quota", "rate_window", "site_media_ceiling":
            return Strings.Errors.imageQuotaCard(lang)
        case "rate_limited":
            return Strings.Errors.tooFast(lang)
        case "not_configured":
            return ImageCardCopy.notConfigured(lang)
        case "bad_image", "image_too_large":
            return Strings.Errors.badImage(lang)
        case "signin_required", "account_required", "unauthorized":
            return ImageCardCopy.whySignIn(lang)
        default:
            return Strings.Errors.imageEngineFailed(lang)
        }
    }

    /// Verbatim (`web-media-ux.md §3.5`): four words in the order the work happens.
    private static func loaderWords(_ lang: AppLanguage) -> [String] {
        switch lang {
        case .arabic:
            return ["أقرأ طلبك", "أُركّب المشهد", "أضبط الضوء", "أصقل التفاصيل"]
        case .english:
            return ["Reading your prompt", "Composing the scene", "Setting the light", "Refining details"]
        }
    }
}

// MARK: - Copy

/// `web-media-ux.md §3.5` and `app.js:793-801`, Arabic verbatim where the web has a sentence. The
/// download and stall headlines are new — the web has no separate download state to copy.
private enum ImageCardCopy {
    static let failed = LText(ar: "تعذّر توليد الصورة", en: "Image generation failed")
    static let tryAgain = LText(ar: "إعادة المحاولة", en: "Try again")
    static let regenerate = LText(ar: "أعد التوليد", en: "Regenerate")
    static let picture = LText(ar: "صورة", en: "Picture")

    /// The headline that must never say "generation": the picture exists, its bytes did not arrive.
    static let downloadFailedHead = LText(ar: "تعذّر تنزيل الصورة", en: "The picture did not download")

    static let downloadTwice = LText(
        ar: "ما زال التنزيل يفشل. الصورة محفوظة على الخادم — جرّب بعد قليل أو من اتّصال آخر.",
        en: "The download keeps failing. The picture is safe on the server — try again shortly, or on another connection."
    )

    static let stalledHead = LText(ar: "طال الانتظار", en: "This is taking too long")

    static let stalled = LText(
        ar: "طال الانتظار. الصورة قد تكون جاهزة في الذاكرة — أعد المحاولة.",
        en: "This is taking too long. The picture may already be cached — try again."
    )

    static let notConfigured = LText(
        ar: "محرّك الصور غير مهيّأ بعد على الخادم.",
        en: "The image engine is not configured on the server yet."
    )

    static let unavailable = LText(
        ar: "الصورة غير متاحة للعرض هنا.",
        en: "This picture is not available here."
    )

    /// `imgWhyNet` — verbatim.
    static let whyNetwork = LText(
        ar: "تعذّر الوصول إلى الصورة — تحقّق من اتّصالك.",
        en: "The picture could not be fetched — check your connection."
    )

    /// `imgWhySignin` — verbatim.
    static let whySignIn = LText(
        ar: "انتهت جلستك. سجّل الدخول ثمّ أعد المحاولة.",
        en: "Your session ended. Sign in and try again."
    )
}
