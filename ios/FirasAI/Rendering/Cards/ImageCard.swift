import SwiftUI
import UIKit

/// The ```` ```firas-image ```` card (`web-media-ux.md §3.5–3.8`, `design-brief.md §7.12`).
///
/// A generated picture gets a cover, not a thumbnail: at most 420 pt wide, radius 20 (the user
/// bubble's `soft-radius`), the picture at its **own** ratio rather than a crop, the request
/// readable underneath it, and the four actions the web offers — save, share, edit, regenerate.
///
/// Two rules keep it calm rather than colourful (the owner's «شيل الخضار»): one accent lives on the
/// card at a time, and every control is a plain 44 pt glyph on the card's own ground. Nothing here
/// is tinted for decoration.
///
/// Sharing does not need the host: once the bytes are on disk the card owns a file URL and offers a
/// real `ShareLink`. `onShare` is still honoured first, for a host that wants its own sheet.
struct ImageCard: View {

    /// What the transcript knows about this picture right now.
    ///
    /// `auto` is the honest default: a fence that carries a cache key has bytes, one that does not
    /// is a render nobody finished watching. `failed` carries the server's error code, never its
    /// sentence — the sentence is chosen here (`ARCHITECTURE.md §2.15`).
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
    @State private var fileURL: URL?
    @State private var loadFailed = false
    @State private var retried = false
    @State private var since: Date?

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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            mediaFrame
            caption
            actions
        }
        .frame(maxWidth: ImageCard.maximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: reloadKey) { await load() }
    }

    // MARK: - Frame

    @ViewBuilder
    private var mediaFrame: some View {
        switch resolvedPhase {
        case .failed(let code):
            failurePlate(code: code)
        case .rendering:
            loaderPlate
        case .auto, .ready:
            readyFrame
        }
    }

    @ViewBuilder
    private var readyFrame: some View {
        if let picture = picture {
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
                .animation(
                    FirasMotion.gated(.easeOut(duration: 0.22), motionOn: motionOn),
                    // The state, not the unwrapped binding above it: comparing the non-optional
                    // `UIImage` to nil is always true, so the fade never ran.
                    value: self.picture != nil
                )
        } else if loadFailed {
            failurePlate(code: "network")
        } else if resolveImage == nil {
            unavailablePlate
        } else {
            loaderPlate
        }
    }

    private var unavailablePlate: some View {
        plate(ratio: 4.0 / 3.0) {
            Text(ImageCardCopy.unavailable(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .bidiIsland(for: ImageCardCopy.unavailable(lang), fallback: lang)
        }
    }

    // MARK: - Progress

    /// Honest progress: the rotating word the web shows, the seconds actually spent, and — once the
    /// render has run past every plausible budget — the sentence that says so, with a way out. A
    /// spinner that can never stop is the one state this card refuses to draw.
    private var loaderPlate: some View {
        plate(ratio: placeholderRatio) {
            TimelineView(.periodic(from: since ?? Date(), by: 1)) { context in
                loaderBody(elapsed: ImageCard.seconds(from: since, to: context.date))
            }
        }
    }

    @ViewBuilder
    private func loaderBody(elapsed: Int) -> some View {
        if elapsed > ImageCard.renderCeiling {
            stalledBody
        } else {
            VStack(spacing: 8) {
                FirasActivityLabel(
                    text: ImageCard.loaderWord(atSecond: elapsed, lang: lang),
                    palette: palette,
                    motionOn: motionOn
                )
                progressLine(elapsed: elapsed)
            }
            .padding(.horizontal, 18)
        }
    }

    private func progressLine(elapsed: Int) -> some View {
        HStack(spacing: 8) {
            Text(ArabicText.timer(elapsed))
                .font(FirasType.mono)
                .foregroundStyle(palette.textMuted)
                .forceLTR()
            Text(ImageCardCopy.usually(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .lineLimit(1)
        }
        .bidiIsland(for: ImageCardCopy.usually(lang), fallback: lang)
    }

    private var stalledBody: some View {
        VStack(spacing: 10) {
            Text(ImageCardCopy.stalled(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
            retryButton
        }
        .padding(.horizontal, 18)
        .bidiIsland(for: ImageCardCopy.stalled(lang), fallback: lang)
    }

    // MARK: - Failure

    private func failurePlate(code: String) -> some View {
        plate(ratio: 4.0 / 3.0) {
            VStack(spacing: 10) {
                Text(ImageCardCopy.failed(lang))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(reason(for: code))
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                retryButton
            }
            .padding(.horizontal, 18)
            .bidiIsland(for: reason(for: code), fallback: lang)
        }
    }

    @ViewBuilder
    private var retryButton: some View {
        if onRetry != nil || onRegenerate != nil {
            Button {
                Haptics.select()
                if retried || onRetry == nil {
                    onRegenerate?()
                } else {
                    retried = true
                    onRetry?()
                }
            } label: {
                Text(retryTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(palette.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private func plate<Content: View>(
        ratio: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(palette.surfaceSunken)
            .aspectRatio(ratio > 0 ? ratio : 1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { content() }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    // MARK: - Caption and actions

    /// The reader's own caption when there is one; otherwise the request that made the picture, so
    /// a card in a long thread still says what it is. Two lines, muted, never competing with the
    /// picture above it.
    @ViewBuilder
    private var caption: some View {
        if !captionText.isEmpty {
            Text(captionText)
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: captionText, fallback: lang)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if showsActions {
            HStack(spacing: 2) {
                if let onSave {
                    FirasIconButton(
                        symbol: "square.and.arrow.down",
                        label: ImageCardCopy.save(lang),
                        palette: palette,
                        action: onSave
                    )
                }
                shareControl
                if let onEdit {
                    FirasIconButton(
                        symbol: "wand.and.stars",
                        label: ImageCardCopy.edit(lang),
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
        }
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
        } else if let fileURL {
            ShareLink(item: fileURL) {
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
        guard picture != nil, resolvedPhase == .ready else { return false }
        return onSave != nil || onShare != nil || fileURL != nil || onEdit != nil || onRegenerate != nil
    }

    // MARK: - Loading

    private var reloadKey: String { meta.key + "|" + String(describing: resolvedPhase) }

    private func load() async {
        if since == nil { since = startedAt ?? Date() }
        guard resolvedPhase == .ready, let resolveImage else { return }
        loadFailed = false
        let url = await resolveImage(meta)
        guard let url else {
            picture = nil
            fileURL = nil
            loadFailed = true
            return
        }
        let decoded = await ImageCache.shared.image(forFile: url)
        picture = decoded
        loadFailed = decoded == nil
        if decoded == nil {
            fileURL = nil
        } else if let resolveShareFile {
            fileURL = await resolveShareFile(meta) ?? url
        } else {
            fileURL = url
        }
    }

    // MARK: - Derived

    private static let maximumWidth: CGFloat = 420
    private static let wordInterval: Int = 3
    /// Five minutes. The image budget on the server is far shorter; past this the render is either
    /// finished in the cache or gone, and either way waiting longer teaches the reader nothing.
    private static let renderCeiling: Int = 300

    /// Bytes ⇒ ready. No bytes and nobody told this card a render is running ⇒ the picture never
    /// landed here, which is a finished, explainable state — never a spinner that starts fresh every
    /// time the row scrolls back on screen.
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

    private static func seconds(from start: Date?, to now: Date) -> Int {
        guard let start else { return 0 }
        let elapsed = now.timeIntervalSince(start)
        return elapsed > 0 ? Int(elapsed) : 0
    }

    private static func ratio(of image: UIImage) -> CGFloat {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return 1 }
        return size.width / size.height
    }

    private var placeholderRatio: CGFloat {
        guard let width = meta.w, let height = meta.h, width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }

    private var retryTitle: String {
        if retried || onRetry == nil { return ImageCardCopy.regenerate(lang) }
        return ImageCardCopy.tryAgain(lang)
    }

    private var captionText: String {
        let note = (meta.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return note }
        guard showsPrompt else { return "" }
        let prompt = meta.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(prompt.prefix(200))
    }

    private var accessibilityText: String {
        let text = captionText
        return text.isEmpty ? ImageCardCopy.picture(lang) : text
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

    private static func loaderWords(_ lang: AppLanguage) -> [String] {
        switch lang {
        case .arabic:
            return ["أقرأ طلبك", "أُركّب المشهد", "أضبط الضوء", "أصقل التفاصيل"]
        case .english:
            return ["Reading your prompt", "Composing the scene", "Setting the light", "Refining details"]
        }
    }

    private static func loaderWord(atSecond second: Int, lang: AppLanguage) -> String {
        let words = loaderWords(lang)
        guard !words.isEmpty else { return "" }
        let step = max(0, second) / wordInterval
        return words[step % words.count]
    }
}

// MARK: - Copy

/// `web-chat-ux.md` Appendix A (image card) and `web-media-ux.md §3.5`, Arabic verbatim where the
/// web has a sentence; the progress and stall lines are new, in the same voice.
private enum ImageCardCopy {
    static let failed = LText(ar: "تعذّر توليد الصورة", en: "Image generation failed")
    static let tryAgain = LText(ar: "إعادة المحاولة", en: "Try again")
    static let regenerate = LText(ar: "أعد التوليد", en: "Regenerate")
    static let save = LText(ar: "حفظ الصورة", en: "Save image")
    static let edit = LText(ar: "عدّل الصورة", en: "Edit image")
    static let picture = LText(ar: "صورة", en: "Picture")

    static let usually = LText(
        ar: "عادةً أقل من نصف دقيقة",
        en: "usually under half a minute"
    )

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

    static let whyNetwork = LText(
        ar: "تعذّر الوصول إلى الصورة — تحقّق من اتّصالك.",
        en: "The picture could not be fetched — check your connection."
    )

    static let whySignIn = LText(
        ar: "انتهت جلستك. سجّل الدخول ثمّ أعد المحاولة.",
        en: "Your session ended. Sign in and try again."
    )
}
