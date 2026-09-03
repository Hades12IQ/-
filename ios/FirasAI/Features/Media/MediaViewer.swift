import AVKit
import SwiftUI
import UIKit

/// The full-screen look at one creation, and the only place the file itself is handed anywhere:
/// Photos, the share sheet, an edit, a re-roll.
///
/// Paging is horizontal across the whole library so a picture is never a dead end — the same
/// gesture the Photos app teaches. Video plays from the local file (downloaded once with the
/// session cookie); songs get the transport bar and their words.
@MainActor
struct MediaViewer: View {

    private let env: AppEnvironment
    private let creationID: String

    @State private var selection: String
    @State private var isSaving = false

    init(env: AppEnvironment, creationID: String) {
        self.env = env
        self.creationID = creationID
        _selection = State(initialValue: creationID)
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var items: [MediaCreation] { env.media.creations.filter { !$0.meta.key.isEmpty } }
    private var current: MediaCreation? { items.first { $0.id == selection } }

    var body: some View {
        ZStack(alignment: .top) {
            palette.background.ignoresSafeArea()
            pages
            header
        }
        .overlay(alignment: .bottom) { actionBar }
        .task { await prepare() }
    }

    /// A main-actor method rather than an inline `.task` body: that body is `@Sendable` and does
    /// not inherit this view's isolation, so `selection` may not be written inside it.
    private func prepare() async {
        await env.media.reload()
        // The creation this cover was opened for may still be rendering, and a TabView with a tag
        // nothing matches shows an empty page. Fall back to the newest finished item.
        if current == nil, let first = items.first(where: { $0.id == creationID }) ?? items.first {
            selection = first.id
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var pages: some View {
        if items.isEmpty {
            EmptyStateView(
                title: Strings.Media.libraryEmptyTitle(lang),
                subtitle: Strings.Media.libraryEmptyBody(lang),
                buttonTitle: nil,
                palette: palette,
                action: nil
            )
        } else {
            TabView(selection: $selection) {
                ForEach(items) { item in
                    MediaViewerPage(env: env, creation: item)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                SongPlayer.shared.stop()
                env.router.cover = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .firasGlass(.floating, palette: palette, in: AnyShape(Circle()))
            .accessibilityLabel(Text(Strings.Common.close(lang)))

            Spacer(minLength: 8)

            if let current {
                Text(Strings.Media.kindLabel(current.kind)(lang))
                    .font(FirasType.label)
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .firasGlass(.floating, palette: palette)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var actionBar: some View {
        if let current {
            MediaActionBar(
                env: env,
                creation: current,
                isSaving: $isSaving
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
    }
}

// MARK: - One page

/// One creation, rendered by kind. Every page owns its own file lookup so paging never blocks on a
/// neighbour's download.
///
/// `@MainActor` is load-bearing: `palette` and `lang` read `env.prefs`, which is main-actor
/// isolated, so a nonisolated page could not even declare them.
@MainActor
private struct MediaViewerPage: View {

    let env: AppEnvironment
    let creation: MediaCreation

    @State private var fileURL: URL?
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            content
            caption
            Spacer(minLength: 96)
        }
        .frame(maxWidth: .infinity)
        .task(id: creation.localFilename ?? creation.id) { await load() }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var content: some View {
        switch creation.kind {
        case .image: imageContent
        case .video: videoContent
        case .music: songContent
        }
    }

    // MARK: Image

    @ViewBuilder
    private var imageContent: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(zoomGesture)
                .simultaneousGesture(panGesture)
                .onTapGesture(count: 2) { resetZoom() }
                .padding(.horizontal, 12)
                .accessibilityLabel(Text(accessibilityText))
        } else {
            placeholder
        }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(committedZoom * value, 1), 6)
            }
            .onEnded { _ in
                committedZoom = zoom
                if zoom <= 1.01 { resetZoom() }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1.01 else { return }
                offset = value.translation
            }
            .onEnded { _ in
                if zoom <= 1.01 { offset = .zero }
            }
    }

    private func resetZoom() {
        zoom = 1
        committedZoom = 1
        offset = .zero
    }

    // MARK: Video

    @ViewBuilder
    private var videoContent: some View {
        if let player {
            VideoPlayer(player: player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 12)
                .accessibilityLabel(Text(accessibilityText))
        } else {
            placeholder
        }
    }

    // MARK: Song

    private var songContent: some View {
        SurfaceCard(palette: palette) {
            VStack(alignment: .leading, spacing: 14) {
                Text(creation.meta.title ?? Strings.Media.songUntitled(lang))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .bidiIsland(for: creation.meta.title ?? "", fallback: lang)

                SongPlayerBar(
                    creationID: creation.id,
                    url: fileURL,
                    palette: palette,
                    lang: lang,
                    tts: env.tts
                )

                if let words = creation.meta.lyrics, !words.isEmpty {
                    Divider().overlay(palette.border)
                    Text(Strings.Media.lyricsSectionTitle(lang))
                        .font(FirasType.label)
                        .foregroundStyle(palette.textMuted)
                    ScrollView {
                        Text(words)
                            .font(.system(size: 15))
                            .foregroundStyle(palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .bidiIsland(for: words, fallback: lang)
                    }
                    .frame(maxHeight: 260)
                }
            }
            .padding(16)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Shared

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 12) {
            if failed {
                Text(Strings.Media.downloadFailed(lang))
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textSecondary)
                Button {
                    failed = false
                    Task { await load() }
                } label: {
                    Text(Strings.Media.retryAgain(lang))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.onAccent)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background { Capsule(style: .continuous).fill(palette.accent) }
                }
                .buttonStyle(.plain)
            } else {
                ProgressView().tint(palette.accent)
                Text(Strings.Media.preparingFile(lang))
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textMuted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(24)
    }

    @ViewBuilder
    private var caption: some View {
        if let note = creation.meta.note, !note.isEmpty {
            Text(note)
                .font(.system(size: 14))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .bidiIsland(for: note, fallback: lang)
        }
    }

    private var accessibilityText: String {
        let prompt = String(creation.meta.prompt.prefix(120))
        return Strings.Media.tileLabel(creation.kind).fmt(lang, prompt)
    }

    private func load() async {
        failed = false
        guard let url = await env.media.localURL(for: creation) else {
            failed = true
            return
        }
        fileURL = url
        switch creation.kind {
        case .image:
            image = await MediaImageLoader.image(at: url, maxPixel: 2_048)
            if image == nil { failed = true }
        case .video:
            player = AVPlayer(url: url)
        case .music:
            break
        }
    }
}

// MARK: - Actions

/// Save, share, open, edit, re-roll — a floating glass row, never a solid slab over the picture.
@MainActor
struct MediaActionBar: View {

    let env: AppEnvironment
    let creation: MediaCreation
    @Binding var isSaving: Bool

    @State private var shareURL: URL?

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    var body: some View {
        HStack(spacing: 8) {
            if creation.kind != .music {
                action(symbol: "square.and.arrow.down", label: Strings.Media.saveToPhotos(lang)) {
                    Task {
                        isSaving = true
                        _ = await env.media.saveToPhotos(creation.id)
                        isSaving = false
                    }
                }
                .disabled(isSaving)
            }
            shareButton
            action(symbol: "bubble.left.and.text.bubble.right", label: Strings.Media.openInChat(lang)) {
                env.media.openInChat(creation.id)
            }
            if creation.kind == .image {
                action(symbol: "wand.and.stars", label: Strings.Media.editPicture(lang)) {
                    // The create form reads this once and opens on the edit tab with the picture
                    // already chosen as the source.
                    env.media.pendingEditSourceID = creation.id
                    SongPlayer.shared.stop()
                    env.router.cover = nil
                    env.router.switchTo(product: .studio)
                }
            }
            action(symbol: "arrow.triangle.2.circlepath", label: Strings.Media.regenerateItem(lang)) {
                Task { await env.media.regenerate(creation.id) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .firasGlass(.floating, palette: palette, in: AnyShape(Capsule(style: .continuous)))
        .task(id: creation.id) { await refreshShareFile() }
    }

    /// Same reason as everywhere else in this file: the `.task` body is `@Sendable`, so the write
    /// to `shareURL` happens inside a main-actor method instead.
    private func refreshShareFile() async {
        shareURL = await env.media.shareFile(for: creation)
    }

    @ViewBuilder
    private var shareButton: some View {
        if let shareURL {
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

    private func action(symbol: String, label: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}
