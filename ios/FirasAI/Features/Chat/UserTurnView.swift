import SwiftUI
import UIKit

/// The user's own turn: one bubble on the trailing edge.
///
/// Image thumbnails, then file chips, then the text — clamped at 12 lines with `عرض المزيد`
/// (`web-chat-ux.md §8.1`). The fill, the sheen hairline and the 20 pt radius with a 7 pt
/// bottom-trailing corner come from `design-brief.md §7.6`. There is no edit-and-resend and there
/// are no reactions: the web has neither.
///
/// `Equatable` and rendered through `.equatable()` so a tick of the streaming answer below does not
/// re-evaluate every bubble above it (`audit-ios-chat.md §Critical C5`).
struct UserTurnView: View, Equatable {

    let env: AppEnvironment
    let message: ChatMessage
    let conversationID: String
    let product: ProductKind
    let palette: FirasPalette
    let lang: AppLanguage
    let scale: FontScale
    let motionOn: Bool

    @State private var expanded = false
    @State private var thumbnails: [UIImage] = []

    init(
        env: AppEnvironment,
        message: ChatMessage,
        conversationID: String,
        product: ProductKind,
        palette: FirasPalette,
        lang: AppLanguage,
        scale: FontScale,
        motionOn: Bool
    ) {
        self.env = env
        self.message = message
        self.conversationID = conversationID
        self.product = product
        self.palette = palette
        self.lang = lang
        self.scale = scale
        self.motionOn = motionOn
    }

    nonisolated static func == (lhs: UserTurnView, rhs: UserTurnView) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.content.utf8.count == rhs.message.content.utf8.count
            && lhs.message.status == rhs.message.status
            && lhs.message.imageThumbs?.count == rhs.message.imageThumbs?.count
            && lhs.message.files?.count == rhs.message.files?.count
            && lhs.lang == rhs.lang
            && lhs.scale == rhs.scale
            && lhs.motionOn == rhs.motionOn
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 40)
            bubble
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .task(id: message.imageThumbs?.count ?? 0) { await loadThumbnails() }
    }

    // MARK: - Bubble

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            imageGrid
            fileChips
            text
            statusLine
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 520, alignment: .leading)
        .background { fill }
        .overlay { sheen }
        .overlay { edge }
        .clipShape(bubbleShape)
        .shadow(color: palette.accentDeep.opacity(0.42), radius: 24, y: 10)
        .contextMenu {
            MessageContextMenu(
                env: env,
                message: message,
                conversationID: conversationID,
                product: product
            )
        }
        .accessibilityElement(children: .contain)
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

    private var fill: some View {
        bubbleShape.fill(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.09),
                    palette.userFill,
                    Color.black.opacity(0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .background { bubbleShape.fill(palette.userFill) }
    }

    private var sheen: some View {
        bubbleShape
            .inset(by: 0.5)
            .stroke(palette.userSheen, lineWidth: 1)
            .mask {
                LinearGradient(
                    colors: [Color.black, Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
    }

    private var edge: some View {
        bubbleShape.strokeBorder(palette.userEdge, lineWidth: 1)
    }

    // MARK: - Text

    @ViewBuilder
    private var text: some View {
        let plain = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !plain.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(plain)
                    .font(FirasType.prose(lang, scale: scale).font)
                    .lineSpacing(FirasType.prose(lang, scale: scale).lineSpacing)
                    .foregroundStyle(palette.userInk)
                    .lineLimit(expanded ? nil : 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isClampable(plain) {
                    Button {
                        withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                            expanded.toggle()
                        }
                    } label: {
                        Text((expanded ? Strings.Chat.showLess : Strings.Chat.showMore)(lang))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.userInk.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            .bidiIsland(for: plain, fallback: lang)
        }
    }

    private func isClampable(_ body: String) -> Bool {
        var lines = 1
        for character in body where character == "\n" {
            lines += 1
            if lines > 12 { return true }
        }
        return body.count > 700
    }

    // MARK: - Attachments

    @ViewBuilder
    private var imageGrid: some View {
        if !thumbnails.isEmpty {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 64, maximum: 96), spacing: 6)],
                spacing: 6
            ) {
                ForEach(Array(thumbnails.indices), id: \.self) { index in
                    Image(uiImage: thumbnails[index])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityLabel(Text(Strings.Chat.attachedImage(lang)))
                }
            }
            .frame(maxWidth: 300, alignment: .leading)
        } else if let count = message.imageThumbs?.count, count > 0 {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .frame(width: 64, height: 64)
                .accessibilityLabel(Text(Strings.Chat.attachedImage(lang)))
        }
    }

    @ViewBuilder
    private var fileChips: some View {
        if let files = message.files, !files.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(files.indices), id: \.self) { index in
                    chip(files[index])
                }
            }
        }
    }

    private func chip(_ file: FileChip) -> some View {
        HStack(spacing: 6) {
            Text(kindTag(file))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(palette.userInk.opacity(0.9))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                }
            Text(file.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.userInk)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.12))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(Strings.Chat.attachedFile(lang) + " " + file.name))
    }

    private func kindTag(_ file: FileChip) -> String {
        if let kind = file.kind, !kind.isEmpty { return kind.uppercased() }
        let ext = (file.name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "TXT" : ext
    }

    // MARK: - Status

    @ViewBuilder
    private var statusLine: some View {
        switch message.status {
        case .queuedOffline:
            statusText(Strings.Chat.outboxHeld(lang), symbol: "wifi.slash")
        case .failed(_):
            statusText(Strings.Chat.messageFailed(lang), symbol: "exclamationmark.triangle")
        case .sending, .delivered, .streaming, .stopped:
            /* Nothing under a message that is simply on its way. This used to print «يكتب فِراس»
               beneath the READER'S OWN words, which is both untrue — Firas is not writing the
               reader's message — and noise on every single turn. The assistant's own bubble already
               says it is thinking, which is where a person looks for it. Only a message that is
               held offline or has actually failed still says so, because those need an answer. */
            EmptyView()
        }
    }

    private func statusText(_ text: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(palette.userInk.opacity(0.85))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        guard let sources = message.imageThumbs, !sources.isEmpty else {
            if !thumbnails.isEmpty { thumbnails = [] }
            return
        }
        var decoded: [UIImage] = []
        for source in sources.prefix(10) {
            if let image = await ImageCache.shared.image(forDataURL: source) {
                decoded.append(image)
            }
        }
        thumbnails = decoded
    }
}
