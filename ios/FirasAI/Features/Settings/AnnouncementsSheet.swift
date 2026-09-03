import SwiftUI
import UIKit

/// The site-updates feed: pinned first, then newest, with the built-in launch post merged in
/// (`web-auth-account-settings.md §8.2–8.3`, `design-brief.md §7.18`).
///
/// The sheet opens on the frame it is asked for and fills in behind a skeleton — a tap on the bell
/// must never look dead. Opening it also clears the dot, before the network answers, because the
/// reader has seen whatever was already there.
@MainActor
struct AnnouncementsSheet: View {

    private let env: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment) {
        self.env = env
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Strings.Settings.Announcements.title(lang))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            env.router.sheet = nil
                            dismiss()
                        } label: {
                            Text(Strings.Common.done(lang))
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .firasSheetBackground(palette)
        .tint(palette.accent)
        .preferredColorScheme(env.prefs.theme.isLight ? .light : .dark)
        .task { await open() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                subtitle

                if let failure = env.announcements.failure, env.announcements.items.isEmpty {
                    SettingsNoticeBanner(text: failure(lang), kind: .error, palette: palette)
                    retryButton
                }

                if env.announcements.items.isEmpty {
                    if env.announcements.isLoading {
                        SkeletonView(kind: .sidebar, palette: palette, motionOn: motionOn)
                            .padding(.top, 8)
                    } else {
                        EmptyStateView(
                            title: Strings.Settings.Announcements.empty(lang),
                            subtitle: nil,
                            buttonTitle: nil,
                            palette: palette,
                            action: nil
                        )
                    }
                } else {
                    ForEach(env.announcements.items) { item in
                        NavigationLink {
                            AnnouncementReader(env: env, announcement: item)
                        } label: {
                            AnnouncementRow(announcement: item, palette: palette, lang: lang)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private var subtitle: some View {
        Text(Strings.Settings.Announcements.subtitle(lang))
            .font(.system(size: 13))
            .foregroundStyle(palette.textMuted)
            .bidiIsland(for: Strings.Settings.Announcements.subtitle(lang), fallback: lang)
    }

    private var retryButton: some View {
        SettingsSubmitButton(
            title: Strings.Common.retry(lang),
            symbol: "arrow.clockwise",
            palette: palette,
            prominent: false,
            isWorking: env.announcements.isLoading,
            action: { Task { await env.announcements.load() } }
        )
    }

    // MARK: - Actions

    private func open() async {
        env.announcements.markSeen()
        await env.announcements.load()
        env.announcements.markSeen()
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }
}

// MARK: - Row

/// One feed row: thumbnail, badges, title, excerpt, date and time.
@MainActor
struct AnnouncementRow: View {

    let announcement: Announcement
    let palette: FirasPalette
    let lang: AppLanguage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let image = announcement.image, !image.isEmpty {
                AnnouncementImageView(source: image, palette: palette)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 5) {
                badges
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                Text(excerpt)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(2)
                Text(AnnouncementFormat.stamp(announcement.date, lang: lang))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textMuted)
                .padding(.top, 4)
                .accessibilityHidden(true)
        }
        .padding(12)
        .surfaceCard(palette)
        .bidiIsland(for: title, fallback: lang)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badges: some View {
        if announcement.pinned || (announcement.video?.isEmpty == false) {
            HStack(spacing: 6) {
                if announcement.pinned {
                    badge(Strings.Settings.Announcements.pinned(lang), symbol: "pin.fill")
                }
                if announcement.video?.isEmpty == false {
                    badge(Strings.Settings.Announcements.video(lang), symbol: "play.fill")
                }
            }
        }
    }

    private func badge(_ text: String, symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(palette.accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background { Capsule(style: .continuous).fill(palette.accentSoft) }
        .accessibilityHidden(true)
    }

    private var title: String {
        let localized = announcement.localizedTitle(lang)
        return localized.isEmpty ? Strings.Settings.Announcements.untitled(lang) : localized
    }

    private var excerpt: String {
        let body = announcement.localizedBody(lang)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(body.prefix(160))
    }
}

// MARK: - Image

/// An announcement picture. The source is either a `data:` URL (the admin composer downscales to a
/// JPEG data URL) or an http(s) link, so both paths exist; the base-64 decode never runs on the
/// main actor.
@MainActor
struct AnnouncementImageView: View {

    private let source: String
    private let palette: FirasPalette

    @State private var decoded: UIImage?

    init(source: String, palette: FirasPalette) {
        self.source = source
        self.palette = palette
    }

    var body: some View {
        Group {
            if let decoded {
                Image(uiImage: decoded)
                    .resizable()
                    .scaledToFill()
            } else if let remote = AnnouncementImageView.remoteURL(source) {
                AsyncImage(url: remote) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .clipped()
        .task { await decodeIfNeeded() }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Rectangle().fill(palette.surfaceSunken)
    }

    private func decodeIfNeeded() async {
        guard decoded == nil, source.hasPrefix("data:") else { return }
        decoded = await AnnouncementImageView.decode(dataURL: source)
    }

    /// Runs off the main actor: a 450 KB base-64 payload is a visible hitch otherwise.
    nonisolated static func decode(dataURL: String) async -> UIImage? {
        guard let comma = dataURL.firstIndex(of: ","), dataURL.hasPrefix("data:") else { return nil }
        let header = dataURL[dataURL.startIndex..<comma]
        guard header.contains(";base64") else { return nil }
        let payload = String(dataURL[dataURL.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return UIImage(data: data)
    }

    nonisolated static func remoteURL(_ source: String) -> URL? {
        guard source.hasPrefix("http://") || source.hasPrefix("https://") else { return nil }
        return URL(string: source)
    }
}

// MARK: - Dates

/// `toLocaleDateString() · toLocaleTimeString()`, the web's stamp, in the reader's language.
enum AnnouncementFormat {

    static func stamp(_ date: Date, lang: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = lang.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
