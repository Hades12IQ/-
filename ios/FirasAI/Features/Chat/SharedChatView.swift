import SwiftUI
import UIKit

/// The `?share=` target: a read-only snapshot of a conversation — or of a single answer — fetched
/// without any credential at all (`GET /api/share?id=` is the one public endpoint) plus the CTA the
/// web page shows (`web-auth-account-settings.md §9.4`).
///
/// Only `data:image/` thumbnails are rendered, exactly as the web does: a share snapshot must not be
/// able to make the reader's device fetch a remote URL.
struct SharedChatView: View {

    private let env: AppEnvironment
    private let shareID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase: SharedChatPhase = .loading
    @State private var messages: [ChatMessage] = []
    @State private var snapshotTitle: String = ""
    @State private var isSingleAnswer = false

    init(env: AppEnvironment, shareID: String) {
        self.env = env
        self.shareID = shareID
    }

    /// The router spells this route `AppRoute.sharedChat(id:)`; both labels resolve to the same id.
    init(env: AppEnvironment, id: String) {
        self.env = env
        self.shareID = id
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle(Text(navigationTitleText))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .firasSheetBackground(palette)
        .task(id: shareID) {
            await load()
        }
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    private var navigationTitleText: String {
        snapshotTitle.isEmpty ? SharedChatCopy.title(lang) : snapshotTitle
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Text(Strings.Common.close(lang))
            }
            .foregroundStyle(palette.accent)
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            loadingState
        case .failed(let message):
            failedState(message)
        case .ready:
            readyState
        }
    }

    private var loadingState: some View {
        SkeletonView(kind: .transcript, palette: palette, motionOn: motionOn)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .accessibilityLabel(Text(SharedChatCopy.loading(lang)))
    }

    private func failedState(_ message: String) -> some View {
        EmptyStateView(
            title: SharedChatCopy.missingTitle(lang),
            subtitle: message,
            buttonTitle: Strings.Common.retry(lang),
            palette: palette,
            action: { reload() }
        )
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var readyState: some View {
        if messages.isEmpty {
            EmptyStateView(
                title: SharedChatCopy.emptyTitle(lang),
                subtitle: SharedChatCopy.emptyBody(lang),
                buttonTitle: SharedChatCopy.cta(lang),
                palette: palette,
                action: { startFree() }
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    ForEach(Array(messages.indices), id: \.self) { index in
                        row(messages[index])
                    }
                    callToAction
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .readingColumn(env.prefs.contentWidth)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 32)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            FirasBrandMark(size: 22, showsWordmark: true, palette: palette)
            if isSingleAnswer {
                Text(SharedChatCopy.eyebrow(lang))
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textMuted)
            }
            if !snapshotTitle.isEmpty {
                Text(snapshotTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .bidiIsland(for: snapshotTitle, fallback: lang)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            userRow(message)
        case .assistant:
            assistantRow(message)
        default:
            EmptyView()
        }
    }

    private func userRow(_ message: ChatMessage) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            thumbnails(message)
            if !message.content.isEmpty {
                Text(message.content)
                    .font(FirasType.prose(lang, scale: env.prefs.fontScale).font)
                    .lineSpacing(FirasType.prose(lang, scale: env.prefs.fontScale).lineSpacing)
                    .foregroundStyle(palette.userInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleShape.fill(palette.userFill))
                    .overlay(bubbleShape.stroke(palette.userEdge, lineWidth: 1))
                    .bidiIsland(for: message.content, fallback: lang)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: 20,
            bottomTrailingRadius: 7,
            topTrailingRadius: 20,
            style: .continuous
        )
    }

    private func assistantRow(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnails(message)
            MarkdownView(
                markdown: message.content,
                messageID: "shared-" + shareID + "-" + message.id,
                streaming: false,
                lang: messageLanguage(message),
                palette: palette,
                prefs: env.prefs,
                onFence: { _ in nil }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func thumbnails(_ message: ChatMessage) -> some View {
        let thumbs = (message.imageThumbs ?? []).filter { $0.hasPrefix("data:image/") }
        if !thumbs.isEmpty {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 76), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(Array(thumbs.indices), id: \.self) { index in
                    SharedThumbnailView(dataURL: thumbs[index], palette: palette)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
        }
    }

    private func messageLanguage(_ message: ChatMessage) -> AppLanguage {
        guard let raw = message.lang else { return lang }
        return raw.lowercased().hasPrefix("en") ? .english : .arabic
    }

    // MARK: - CTA

    private var callToAction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isSingleAnswer ? SharedChatCopy.noteOne(lang) : SharedChatCopy.noteAll(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                startFree()
            } label: {
                Text(SharedChatCopy.cta(lang))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 44)
                    .background(Capsule(style: .continuous).fill(palette.accent))
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .surfaceCard(palette)
        .padding(.top, 6)
    }

    // MARK: - Actions

    private func startFree() {
        dismiss()
        env.router.open(.auth(mode: .signup))
    }

    private func reload() {
        Task { await load() }
    }

    private func load() async {
        phase = .loading
        do {
            let snapshot = try await env.api.getShare(id: shareID)
            snapshotTitle = (snapshot.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            isSingleAnswer = snapshot.one
            messages = snapshot.messages.filter { message in
                switch message.role {
                case .user, .assistant:
                    return !message.content.isEmpty || !(message.imageThumbs ?? []).isEmpty
                default:
                    return false
                }
            }
            phase = .ready
        } catch {
            phase = .failed(errorMessage(for: error))
        }
    }

    private func errorMessage(for error: Error) -> String {
        if let apiError = error as? APIError, (apiError.status ?? 0) == 404 {
            return SharedChatCopy.missingBody(lang)
        }
        switch ErrorPresenter.present(
            error,
            feature: nil,
            isGuest: env.session.isGuest,
            lang: lang
        ) {
        case .toast(let copy):
            return copy(lang)
        case .toastText(let text):
            return text
        default:
            return Strings.Errors.generic(lang)
        }
    }
}

// MARK: - Phase

private enum SharedChatPhase: Equatable {
    case loading
    case ready
    case failed(String)
}

// MARK: - Thumbnail

/// A `data:image/` thumbnail from the snapshot. The base64 is decoded off the main actor; only the
/// bytes cross back, because `UIImage` is not `Sendable`.
private struct SharedThumbnailView: View {

    let dataURL: String
    let palette: FirasPalette

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(palette.surfaceSunken)
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        .task {
            if let data = await SharedThumbnailView.decode(dataURL) {
                image = UIImage(data: data)
            }
        }
        .accessibilityHidden(true)
    }

    private static func decode(_ dataURL: String) async -> Data? {
        await Task.detached(priority: .utility) { () -> Data? in
            guard dataURL.hasPrefix("data:image/"),
                  let comma = dataURL.firstIndex(of: ","),
                  dataURL.index(after: comma) < dataURL.endIndex else {
                return nil
            }
            let payload = String(dataURL[dataURL.index(after: comma)...])
            return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        }.value
    }
}

// MARK: - Copy

/// `shareOneEyebrow`, `shareOneNote` and the missing-link sentence are verbatim
/// (`web-auth-account-settings.md §9.3–9.4`); the CTA is the web page's own button.
private enum SharedChatCopy {
    static let title = LText(ar: "محادثة مشتركة", en: "Shared conversation")
    static let loading = LText(ar: "جارٍ التحضير…", en: "Preparing…")
    static let eyebrow = LText(ar: "إجابة واحدة من محادثة", en: "One answer from a conversation")
    static let cta = LText(ar: "جرّب فِراس مجانًا", en: "Try Firas AI free")

    static let noteOne = LText(
        ar: "من يفتح الرابط يقرأ هذه الإجابة وحدها، ولا يرى بقيّة المحادثة.",
        en: "Whoever opens the link reads this answer only — the rest of the conversation isn't there."
    )
    static let noteAll = LText(
        ar: "أي شخص يملك الرابط يستطيع قراءة هذه المحادثة.",
        en: "Anyone with the link can read this conversation."
    )

    static let missingTitle = LText(ar: "تعذّر فتح الرابط", en: "Couldn't open the link")
    static let missingBody = LText(
        ar: "هذا الرابط غير موجود أو حُذف.",
        en: "This shared chat doesn't exist or was removed."
    )

    static let emptyTitle = LText(ar: "لا شيء هنا", en: "Nothing here")
    static let emptyBody = LText(
        ar: "هذه المحادثة المشتركة فارغة.",
        en: "This shared conversation is empty."
    )
}
