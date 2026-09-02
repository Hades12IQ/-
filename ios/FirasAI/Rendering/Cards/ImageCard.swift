import SwiftUI
import UIKit

/// The ```` ```firas-image ```` card (`web-media-ux.md §3.5–3.8`, `design-brief.md §7.12`).
///
/// At most 420 pt wide, radius 20 (the user bubble's `soft-radius`), the picture at its natural
/// ratio, the reader's caption underneath, and the four actions the web offers — save, share, edit,
/// regenerate — each drawn only when the host wired it.
///
/// The card never prints the prompt: the rewritten English prompt is machine text and belongs to
/// the filename and the accessibility label, nowhere else.
struct ImageCard: View {

    /// What the transcript knows about this picture right now. `rendering` is a job still in the
    /// queue; `failed` carries the server's error code, never its sentence.
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
    private let resolveImage: ((MediaMeta) async -> URL?)?
    private let onOpen: (() -> Void)?
    private let onSave: (() -> Void)?
    private let onShare: (() -> Void)?
    private let onEdit: (() -> Void)?
    private let onRetry: (() -> Void)?
    private let onRegenerate: (() -> Void)?

    @State private var picture: UIImage?
    @State private var loadFailed = false
    @State private var retried = false

    init(
        meta: MediaMeta,
        palette: FirasPalette,
        lang: AppLanguage,
        phase: Phase = .ready,
        motionOn: Bool = true,
        resolveImage: ((MediaMeta) async -> URL?)? = nil,
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
        self.resolveImage = resolveImage
        self.onOpen = onOpen
        self.onSave = onSave
        self.onShare = onShare
        self.onEdit = onEdit
        self.onRetry = onRetry
        self.onRegenerate = onRegenerate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        switch phase {
        case .failed(let code):
            failurePlate(code: code)
        case .rendering:
            loaderPlate
        case .ready:
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
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onTapGesture { onOpen?() }
                .accessibilityLabel(Text(accessibilityText))
                .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
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

    private var loaderPlate: some View {
        plate(ratio: placeholderRatio) {
            loaderLabel
        }
    }

    @ViewBuilder
    private var loaderLabel: some View {
        if motionOn {
            TimelineView(.periodic(from: Date(), by: ImageCard.wordInterval)) { context in
                FirasActivityLabel(
                    text: ImageCard.loaderWord(at: context.date, lang: lang),
                    palette: palette,
                    motionOn: true
                )
            }
        } else {
            FirasActivityLabel(
                text: ImageCard.loaderWords(lang)[0],
                palette: palette,
                motionOn: false
            )
        }
    }

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
            }
    }

    // MARK: - Caption and actions

    @ViewBuilder
    private var caption: some View {
        if let note = meta.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(note)
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: note, fallback: lang)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if showsActions {
            HStack(spacing: 4) {
                if let onSave {
                    FirasIconButton(
                        symbol: "square.and.arrow.down",
                        label: ImageCardCopy.save(lang),
                        palette: palette,
                        action: onSave
                    )
                }
                if let onShare {
                    FirasIconButton(
                        symbol: "square.and.arrow.up",
                        label: Strings.Common.share(lang),
                        palette: palette,
                        action: onShare
                    )
                }
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

    private var showsActions: Bool {
        guard picture != nil, phase == .ready else { return false }
        return onSave != nil || onShare != nil || onEdit != nil || onRegenerate != nil
    }

    // MARK: - Loading

    private var reloadKey: String { meta.key + "|" + String(describing: phase) }

    private func load() async {
        guard phase == .ready, let resolveImage else { return }
        loadFailed = false
        let url = await resolveImage(meta)
        guard let url else {
            picture = nil
            loadFailed = true
            return
        }
        let decoded = await ImageCache.shared.image(forFile: url)
        picture = decoded
        loadFailed = decoded == nil
    }

    // MARK: - Derived

    private static let maximumWidth: CGFloat = 420
    private static let wordInterval: TimeInterval = 2.6

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

    private var accessibilityText: String {
        if let note = meta.note, !note.isEmpty { return note }
        let prompt = String(meta.prompt.prefix(120))
        return prompt.isEmpty ? ImageCardCopy.picture(lang) : prompt
    }

    /// `imgWhyNet` / `imgWhyEngine` / `imgWhyQuota` / `imgWhySignin` — chosen by code, never by the
    /// server's sentence (`ARCHITECTURE.md §2.15`).
    private func reason(for code: String) -> String {
        switch code.lowercased() {
        case "network", "offline", "unreachable", "timeout":
            return ImageCardCopy.whyNetwork(lang)
        case "daily_limit", "quota", "rate_window", "site_media_ceiling":
            return Strings.Errors.imageQuotaCard(lang)
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

    private static func loaderWord(at date: Date, lang: AppLanguage) -> String {
        let words = loaderWords(lang)
        let ticks = Int(date.timeIntervalSinceReferenceDate / wordInterval)
        let index = ((ticks % words.count) + words.count) % words.count
        return words[index]
    }
}

// MARK: - Copy

/// `web-chat-ux.md` Appendix A (image card) and `web-media-ux.md §3.5`, Arabic verbatim.
private enum ImageCardCopy {
    static let failed = LText(ar: "تعذّر توليد الصورة", en: "Image generation failed")
    static let tryAgain = LText(ar: "إعادة المحاولة", en: "Try again")
    static let regenerate = LText(ar: "أعد التوليد", en: "Regenerate")
    static let save = LText(ar: "حفظ الصورة", en: "Save image")
    static let edit = LText(ar: "عدّل الصورة", en: "Edit image")
    static let picture = LText(ar: "صورة", en: "Picture")
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
