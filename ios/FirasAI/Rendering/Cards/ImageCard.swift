import SwiftUI
import UIKit

/// The ```` ```firas-image ```` card (`web-media-ux.md §3.5–3.8`, `design-brief.md §7.12`).
///
/// It is the website's card, state for state:
///
/// | state | plate | width |
/// |---|---|---|
/// | rendering | the cover — dot field, pulse, one rotating word | 300 pt, square |
/// | resolving | the plate's ground, still and silent, at the fence's ratio | 420 pt |
/// | downloading | the cover, one honest word: «أنزّل الصورة…» | 420 pt |
/// | ready | the picture at its own ratio, radius 20 | 420 pt |
/// | generation failed | the same plate, no field, `تعذّر توليد الصورة` in error ink | 340 pt, 4:3 |
/// | download failed | the same plate, `تعذّر تنزيل الصورة` | 340 pt, 4:3 |
///
/// Five defects the owner hit on a device are fixed here and each one is a rule now:
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
/// 3. **A resolver that answers `nil` has not failed — not yet.** This is the defect in the owner's
///    screenshot: the render succeeded, the day's allowance was charged, the toast said «تم إنشاء
///    الصورة», and the card underneath it said the file could not be downloaded. The host's
///    resolver answers `nil` for three different things — the creation is not filed in the library
///    yet, a fetch for the same bytes is *already in flight*, or the fetch genuinely failed — and
///    only the third is a download failure. The first two are the ordinary case on the very frame a
///    render lands, because the store warms the file itself the moment it writes the fence. So the
///    card asks again, on a backoff, for as long as `fetchBudget`, and only then says it failed.
/// 4. **The machine prompt is not body text — in any state.** The web prints it on no card at all;
///    after the rewriter it is «a wall of machine text nobody wrote» (`app.js:6209-6212`). This card
///    used to keep one exception, the running render, on the theory that nothing else said which
///    picture it was. That exception WAS the defect: the fence is rewritten with the English prompt
///    the instant the rewriter answers, so the line the reader sat and watched was a model's
///    sentence about their sentence. The cover says what is happening and the reader's own caption
///    says what the picture is; nothing else is written under it.
/// 5. **A picture already on this device never wears a render cover.** That plate is animated and
///    it is what a *generation* looks like, and it was being drawn for the two or three frames it
///    takes to find a file in a folder — so scrolling back through an old conversation looked like
///    the app regenerating everything in it. The waiting plate is silent and still now, at the
///    picture's own ratio, and only becomes the cover if the wait turns out to be real.
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
    /// The first ask for the bytes came back empty, so the wait is real and worth naming. A picture
    /// already on disk answers the first ask, and must not be given a cover to sit behind.
    @State private var fetchIsSlow = false
    @State private var retried = false
    @State private var since: Date

    init(
        meta: MediaMeta,
        palette: FirasPalette,
        lang: AppLanguage,
        phase: Phase = .auto,
        motionOn: Bool = true,
        startedAt: Date? = nil,
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
            downloadingCover
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
    private func cover(ratio: CGFloat, words: [String]) -> some View {
        MediaCoverPlate(
            palette: palette,
            lang: lang,
            motionOn: motionOn,
            ratio: ratio,
            cornerRadius: 20,
            words: words,
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
                cover(ratio: 1, words: ImageCard.loaderWords(lang))
            }
        }
    }

    /// The wait for the bytes, and it has two faces on purpose.
    ///
    /// A picture this device already holds resolves in the time it takes to look in a folder, and
    /// for those two or three frames this branch is what is on screen. Drawing the animated cover
    /// there is what made returning to an old conversation look like the app rendering it all over
    /// again — «مو يرجع يولدهم من جديد او يطلع الغلاف من جديد». So the first face says nothing at
    /// all: the plate's ground, at the picture's own ratio, with nothing moving on it.
    ///
    /// Only once an ask has genuinely come back empty is the wait real, and then it is named — with
    /// «أنزّل الصورة…» and never «أُركّب المشهد», because this picture already exists.
    @ViewBuilder
    private var downloadingCover: some View {
        if fetchIsSlow {
            cover(ratio: declaredRatio, words: [Strings.Media.fetchingImage(lang)])
        } else {
            MediaCoverPlate(
                palette: palette,
                lang: lang,
                motionOn: motionOn,
                ratio: declaredRatio,
                cornerRadius: 20,
                drawsField: false,
                startedAt: since
            )
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

    /// How long the card is willing to keep asking for bytes before it calls the fetch failed.
    ///
    /// It has to be measured in *tens of seconds*, not in one attempt, because the very first ask
    /// almost always comes back empty: the store writes the fence into the conversation and then
    /// warms the file itself, and while that warm-up runs the resolver answers `nil` to everybody
    /// else. Thirty seconds covers a picture arriving over a slow cellular link; past it something
    /// is genuinely wrong and the reader is owed a sentence and a button.
    private static let fetchBudget: TimeInterval = 30

    /// Downloading is its own operation. Every exit here sets `downloadFailed`, never a render
    /// failure, and never touches `phase`.
    ///
    /// `nil` from the resolver is **not** an answer — it is "not yet", and it is the ordinary
    /// reading on the frame the render lands. So the loop keeps asking on a backoff. Bytes that
    /// arrive and then will not decode *are* an answer: the same file cannot decode better on a
    /// second look, so that one breaks out immediately.
    private func load() async {
        // A regenerate takes the card back to the cover, and the cover must not sit on top of the
        // picture the previous render left behind.
        guard resolvedPhase == .ready else {
            picture = nil
            shareURL = nil
            downloadFailed = false
            fetchIsSlow = false
            return
        }
        guard let resolveImage else { return }
        downloadFailed = false
        fetchIsSlow = false

        var backoff = Backoff(initial: 0.4, max: 3.5)
        let deadline = Date().addingTimeInterval(ImageCard.fetchBudget)

        while !Task.isCancelled {
            if let url = await resolveImage(meta) {
                guard let decoded = await ImageCache.shared.image(forFile: url) else { break }
                downloadAttempts = 0
                downloadFailed = false
                fetchIsSlow = false
                picture = decoded
                if let resolveShareFile {
                    shareURL = await resolveShareFile(meta) ?? url
                } else {
                    shareURL = url
                }
                return
            }
            guard Date() < deadline else { break }
            // The first empty answer is what turns a silent placeholder into a stated wait.
            fetchIsSlow = true
            await JobClock.rest(backoff.next())
        }

        // A cancelled task is a row that scrolled away or a card that changed state under us.
        // Neither is a failed download, and neither may leave an error plate behind.
        guard !Task.isCancelled else { return }
        failDownload()
    }

    private func failDownload() {
        picture = nil
        shareURL = nil
        fetchIsSlow = false
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
            // The picture's own width from the first frame. Growing from the cover's 300 to 420 the
            // instant the bytes decoded was a jolt on every appearance of an old card, and there is
            // nothing to grow out of: the fence already says this picture exists.
            if downloadFailed || resolveImage == nil { return 340 }
            return 420
        }
    }

    /// The picture's ratio as the fence declares it, so the placeholder is already the shape the
    /// picture will be and the row does not resize under the reader.
    private var declaredRatio: CGFloat {
        guard let width = meta.w, let height = meta.h, width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
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

    /// What VoiceOver says. The reader's caption when they wrote one, and otherwise the word
    /// «صورة» — never the prompt: an Arabic screen reader spelling out a paragraph of machine
    /// English is the same defect as printing it, only louder.
    private var accessibilityText: String {
        let note = (meta.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? ImageCardCopy.picture(lang) : note
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
