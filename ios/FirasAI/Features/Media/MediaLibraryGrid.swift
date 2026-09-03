import SwiftUI
import UIKit

/// One conversation's worth of creations, as a sticky-header section.
///
/// A struct rather than a tuple because `ForEach(_:id:)` needs a key path, and a key path onto a
/// tuple label does not exist in Swift.
struct MediaLibrarySection: Identifiable, Equatable {
    let id: String
    let items: [MediaCreation]
}

/// Everything this account has ever made, across every conversation.
///
/// The web's gallery is images only and only for the chat that is open; this is the generalisation
/// (`web-media-ux.md §12.2`): all three kinds, grouped by conversation with a sticky header, three
/// columns on iPhone and five on iPad. The record is still the fences — nothing here is a second
/// source of truth, which is why a picture made on the web shows up in it.
@MainActor
struct MediaLibraryGrid: View {

    private let env: AppEnvironment
    private let columns: Int
    private let onCreate: () -> Void

    @State private var filter: MediaKind?

    init(env: AppEnvironment, columns: Int, onCreate: @escaping () -> Void) {
        self.env = env
        self.columns = columns
        self.onCreate = onCreate
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { env.prefs.motionEnabled }

    private var items: [MediaCreation] {
        env.media.creations(kind: filter)
    }

    /// Conversation id → its creations, newest conversation first.
    private var groups: [MediaLibrarySection] {
        var order: [String] = []
        var buckets: [String: [MediaCreation]] = [:]
        for item in items {
            if buckets[item.conversationID] == nil {
                buckets[item.conversationID] = []
                order.append(item.conversationID)
            }
            buckets[item.conversationID]?.append(item)
        }
        return order.map { MediaLibrarySection(id: $0, items: buckets[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                filterRow
                if env.media.isReloading && items.isEmpty {
                    SkeletonView(kind: .tiles, palette: palette, motionOn: motionOn)
                        .padding(.horizontal, 16)
                } else if items.isEmpty {
                    emptyState
                } else {
                    ForEach(groups) { group in
                        Section {
                            grid(group.items)
                        } header: {
                            header(for: group)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(palette.background)
        .refreshable { await env.media.reload() }
        .task { await env.media.reload() }
    }

    // MARK: - Pieces

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FirasPill(
                    text: Strings.Media.libraryFilterAll(lang),
                    symbol: nil,
                    selected: filter == nil,
                    palette: palette
                ) {
                    Haptics.select()
                    filter = nil
                }
                ForEach(MediaKind.allCases) { kind in
                    FirasPill(
                        text: Strings.Media.kindLabel(kind)(lang),
                        symbol: Self.symbol(kind),
                        selected: filter == kind,
                        palette: palette
                    ) {
                        Haptics.select()
                        filter = (filter == kind) ? nil : kind
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            title: Strings.Media.libraryEmptyTitle(lang),
            subtitle: Strings.Media.libraryEmptyBody(lang),
            buttonTitle: Strings.Media.libraryEmptyAction(lang),
            palette: palette,
            action: onCreate
        )
        .padding(.top, 40)
    }

    private func header(for group: MediaLibrarySection) -> some View {
        let title = env.media.conversationTitle(group.id)
        return HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .bidiIsland(for: title, fallback: lang)
            Spacer(minLength: 8)
            Text(Strings.Media.conversationCount.fmt(lang, ArabicText.count(group.items.count, lang)))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(palette.background)
    }

    private func grid(_ items: [MediaCreation]) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 8),
                count: max(2, columns)
            ),
            spacing: 8
        ) {
            ForEach(items) { item in
                MediaTile(env: env, creation: item)
            }
        }
        .padding(.horizontal, 16)
    }

    static func symbol(_ kind: MediaKind) -> String {
        switch kind {
        case .image: return "photo"
        case .video: return "video"
        case .music: return "music.note"
        }
    }
}

// MARK: - One tile

/// A square tile: the picture (or a kind glyph for a song), a kind chip, and the whole context menu
/// the viewer offers, so a long press never needs the full screen.
@MainActor
struct MediaTile: View {

    let env: AppEnvironment
    let creation: MediaCreation

    @State private var thumbnail: UIImage?
    @State private var loaderStep = 0

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { env.prefs.motionEnabled }

    var body: some View {
        Button {
            // A tile that is still rendering has nothing to show full screen yet, and a failed or
            // expired one has no cache key at all. The viewer pages only over creations that carry
            // a key, so opening a keyless one selects nothing and the pager falls back to the
            // newest item — the reader taps a failure and lands on somebody else's picture. Both
            // cases stop here; the long press still works, which is where regenerate and remove
            // live.
            guard !creation.phase.isLive, !creation.meta.key.isEmpty else { return }
            Haptics.select()
            env.router.cover = .mediaViewer(creationID: creation.id)
        } label: {
            tile
        }
        .buttonStyle(.plain)
        .contextMenu { menu }
        .accessibilityLabel(Text(Strings.Media.tileLabel(creation.kind).fmt(lang, String(creation.meta.prompt.prefix(120)))))
        // Keyed on the local filename so the tile paints as soon as the bytes land, not only when
        // the row is first built.
        .task(id: creation.localFilename ?? creation.id) { await loadThumbnail() }
    }

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.surfaceSunken)
            content
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        .overlay(alignment: .topLeading) { kindChip }
    }

    @ViewBuilder
    private var content: some View {
        if creation.phase.isLive {
            renderingPlate
        } else if creation.phase == .failed || creation.phase == .expired {
            failurePlate
        } else if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            glyph
        }
    }

    private var renderingPlate: some View {
        VStack(spacing: 8) {
            LiveDot(palette: palette, motionOn: motionOn)
            Text(Strings.Media.loaderText(creation.kind, step: loaderStep, lang: lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 6)
        }
        .task(id: creation.phase) { await rotateLoaderWords() }
    }

    /// The word rotates every 2.6 s, exactly as the web's plate does. When motion is off the words
    /// still change — a frozen plate reads as a hung render.
    ///
    /// A method rather than an inline `.task` body: that body is `@Sendable` and does not inherit
    /// the view's main-actor isolation, so `loaderStep` may not be touched inside it.
    private func rotateLoaderWords() async {
        while !Task.isCancelled {
            await JobClock.rest(2.6)
            loaderStep += 1
        }
    }

    private var failurePlate: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.error)
            Text(Strings.Media.failureText(creation.kind, code: creation.errorCode, lang: lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 6)
        }
    }

    private var glyph: some View {
        Image(systemName: MediaLibraryGrid.symbol(creation.kind))
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(palette.textMuted)
    }

    private var kindChip: some View {
        Image(systemName: MediaLibraryGrid.symbol(creation.kind))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.onAccent)
            .padding(5)
            .background { Circle().fill(palette.accentDeep.opacity(0.85)) }
            .padding(6)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var menu: some View {
        Button {
            env.media.openInChat(creation.id)
        } label: {
            Label(Strings.Media.openInChat(lang), systemImage: "bubble.left.and.text.bubble.right")
        }
        if creation.kind != .music, !creation.meta.key.isEmpty {
            Button {
                Task { _ = await env.media.saveToPhotos(creation.id) }
            } label: {
                Label(Strings.Media.saveToPhotos(lang), systemImage: "square.and.arrow.down")
            }
        }
        Button {
            Task { await env.media.regenerate(creation.id) }
        } label: {
            Label(Strings.Media.regenerateItem(lang), systemImage: "arrow.triangle.2.circlepath")
        }
        Button(role: .destructive) {
            Task { await env.media.remove(creation.id) }
        } label: {
            Label(Strings.Media.removeItem(lang), systemImage: "trash")
        }
    }

    private func loadThumbnail() async {
        guard creation.kind == .image, !creation.meta.key.isEmpty else { return }
        guard let url = await env.media.localURL(for: creation) else { return }
        thumbnail = await MediaImageLoader.image(at: url, maxPixel: 480)
    }
}
