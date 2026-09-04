import SwiftUI
import UIKit

/// The reader's own turn: one compact bubble on the trailing edge.
///
/// Calm, not decorated. The bubble is a soft rounded rectangle on a single quiet tinted ground —
/// no gradient, no sheen hairline, no coloured ring, no drop shadow. Those four layers were four
/// things competing with the six words the reader actually typed, and stacked on every turn they
/// made the conversation loud ("شيل الخضار الي يصير بالمحادثة، خلي ناعم نفس كلود"). What is left is
/// the shape, the ground and the ink, which is all a bubble has ever needed to say "this was you".
///
/// The corner radius is uniform. The old 7 pt bottom-trailing notch pointed at the composer in
/// Arabic and away from it in English, because a physical corner cannot be mirrored by
/// `layoutDirection` — a uniform radius is right in both directions (the web reached the same
/// conclusion: `styles.css` — "uniform — no asymmetric corner (RTL-safe)").
///
/// Width follows the web: it hugs its content, never crosses 544 pt, and always leaves a leading
/// gutter — so on iPad a three-word question stays a three-word bubble instead of a banner.
///
/// Order inside: image thumbnails → file chips → text (clamped at 12 lines with `عرض المزيد`) →
/// status. Long-press opens the copy menu; there is no edit-and-resend and there are no reactions,
/// because the web has neither (`web-chat-ux.md §8.1`).
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
    @State private var opened: ThumbnailPreview?
    @State private var thumbnails: [UIImage] = []

    /// The bubble never grows past this on any device (the web's `min(80%, 544px)`).
    private static let maxWidth: CGFloat = 544
    /// The gutter left open on the leading side, so a bubble still reads as a bubble on iPad.
    private static let gutter: CGFloat = 56
    private static let radius: CGFloat = 20
    /// Past this many lines the text is clamped and offered an expander.
    private static let clampLines = 12

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
            // THE PAINT IS PART OF THE ROW. Without this a theme change redraws nothing
            // that is already on screen, and the answer keeps yesterday's ink.
            && lhs.palette.id == rhs.palette.id
            && lhs.scale == rhs.scale
            && lhs.motionOn == rhs.motionOn
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: UserTurnView.gutter)
            bubble
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .task(id: message.imageThumbs?.count ?? 0) { await loadThumbnails() }
        .fullScreenCover(item: $opened) { preview in
            AttachedImageViewer(image: preview.image, palette: palette, lang: lang) { opened = nil }
        }
    }

    // MARK: - Bubble

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: UserTurnView.radius, style: .continuous)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            imageGrid
            fileChips
            text
            statusLine
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        /* THE GROUND IS PAINTED BEFORE THE CAP, AND THAT IS THE WHOLE BUG.
           `.frame(maxWidth:)` does not hug its content. SwiftUI sizes a flexible frame to
           `clamp(proposal, minWidth, maxWidth)` — the CHILD'S width never enters the calculation.
           On a phone the proposal is already well under 544, so the frame took the entire row every
           single time, and `.background` painted behind the frame filled all of it. The
           `alignment: .leading` that used to sit on that line was the confession: an alignment only
           means something when the frame is bigger than what is inside it.
           This is why removing `maxWidth: .infinity` from the text below changed nothing. The text
           was never the greedy one — the bubble's own frame was.
           Now the ground is drawn around the padded content, which does hug, and the cap comes
           afterwards where it may expand as much as it likes without being seen. It still does its
           real work: the content is proposed at most 544 points, so a long paragraph wraps there
           instead of running the width of an iPad. */
        .background { shape.fill(palette.userFill) }
        .clipShape(shape)
        .contextMenu {
            MessageContextMenu(
                env: env,
                message: message,
                conversationID: conversationID,
                product: product
            )
        }
        .frame(maxWidth: UserTurnView.maxWidth, alignment: .trailing)
        .accessibilityElement(children: .contain)
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
                    .lineLimit(expanded ? nil : UserTurnView.clampLines)
                    .fixedSize(horizontal: false, vertical: true)
                    /* NO `maxWidth: .infinity` HERE. It was the reason a bubble holding the word
                       «مرحبا» ran the width of the screen: the text demanded every point offered, the
                       VStack grew to match, and the 544 cap above stopped being a CAP and became
                       the SIZE. A bubble has to be the shape of what is in it — the owner has asked
                       for that more than once. Alignment comes from the VStack, which is already
                       `.leading`, so nothing is lost by letting the text be its own width. */

                if isClampable(plain) {
                    expander
                }
            }
            .bidiIsland(for: plain, fallback: lang)
        }
    }

    private var expander: some View {
        Button {
            withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                expanded.toggle()
            }
        } label: {
            Text((expanded ? Strings.Chat.showLess : Strings.Chat.showMore)(lang))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.userInk.opacity(0.78))
                .padding(.top, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isClampable(_ body: String) -> Bool {
        var lines = 1
        for character in body where character == "\n" {
            lines += 1
            if lines > UserTurnView.clampLines { return true }
        }
        return body.count > 700
    }

    /// One attached picture, opened full screen. `Identifiable` because `fullScreenCover(item:)
    /// asks for it, and the index keeps two identical pictures apart.
    struct ThumbnailPreview: Identifiable {
        let index: Int
        let image: UIImage
        var id: Int { index }
    }

    /// Anything the image grid is already showing. Matched on the chip’s own kind first and on
    /// the extension only as a fallback, because a chip built from a picker URL may carry no kind.
    static func isImageChip(_ file: FileChip) -> Bool {
        let kind = (file.kind ?? "").lowercased()
        if ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "image"].contains(kind) { return true }
        let ext = (file.name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif"].contains(ext)
    }

    // MARK: - Attachments

    @ViewBuilder
    private var imageGrid: some View {
        if !thumbnails.isEmpty {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 66, maximum: 96), spacing: 6)],
                spacing: 6
            ) {
                ForEach(Array(thumbnails.indices), id: \.self) { index in
                    Button {
                        Haptics.select()
                        opened = ThumbnailPreview(index: index, image: thumbnails[index])
                    } label: {
                        Image(uiImage: thumbnails[index])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 66, height: 66)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(Strings.Chat.attachedImage(lang)))
                }
            }
            .frame(maxWidth: 300, alignment: .leading)
        } else if let count = message.imageThumbs?.count, count > 0 {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.userInk.opacity(0.12))
                .frame(width: 66, height: 66)
                .accessibilityLabel(Text(Strings.Chat.attachedImage(lang)))
        }
    }

    @ViewBuilder
    private var fileChips: some View {
        /* AN IMAGE IS NOT ALSO A FILE. A picture attached to a message arrives BOTH as a thumbnail
           and as a file chip, so under every photo sat a grey pill reading «image.png» — the name
           the picker invented, printed on top of the picture it names. The reader can see what
           they attached; the chip is for a document they cannot. */
        let files = (message.files ?? []).filter { !UserTurnView.isImageChip($0) }
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(files.indices), id: \.self) { index in
                    chip(files[index])
                }
            }
        }
    }

    /// Chip grounds are drawn from `userInk`, not from white: the ink is whatever reads on the
    /// bubble's ground, so a chip built from it stays legible whichever way the palette is tuned.
    private func chip(_ file: FileChip) -> some View {
        HStack(spacing: 6) {
            Text(kindTag(file))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(palette.userInk.opacity(0.9))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(palette.userInk.opacity(0.16))
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.userInk.opacity(0.10))
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
        case .failed:
            statusText(Strings.Chat.messageFailed(lang), symbol: "exclamationmark.triangle")
        case .sending, .delivered, .streaming, .stopped:
            /* Nothing under a message that is simply on its way. This used to print «يكتب فِراس»
               beneath the READER'S OWN words, which is both untrue — Firas is not writing the
               reader's message — and noise on every single turn. The assistant's own turn already
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
        .foregroundStyle(palette.userInk.opacity(0.82))
        /* Same rule: a status line that claims the full width would widen the bubble around it.
           It is only ever a few words. */
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
