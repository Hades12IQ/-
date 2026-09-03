import AVKit
import Foundation
import SwiftUI

/// One announcement, full width: language toggle, video or image, title, date, markdown body
/// (`web-auth-account-settings.md §8.4`).
///
/// Authored `titleEn`/`bodyEn` seed the English view for free. Only when a language has no authored
/// copy does the reader spend a `POST /api/translate` — which is member-only, so a guest is told
/// that instead of being handed a 401.
@MainActor
struct AnnouncementReader: View {

    /// Which text the reader asked for. `original` is always free.
    enum Mode: String, CaseIterable, Hashable, Sendable {
        case original, arabic, english
    }

    private let env: AppEnvironment
    private let announcement: Announcement

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var mode: Mode = .original
    @State private var translatedTitle: String?
    @State private var translatedBody: String?
    @State private var isTranslating = false
    @State private var player: AVPlayer?

    init(env: AppEnvironment, announcement: Announcement) {
        self.env = env
        self.announcement = announcement
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                languageToggle
                media
                heading
                bodyText
            }
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 36)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle(Strings.Settings.Announcements.title(lang))
        .navigationBarTitleDisplayMode(.inline)
        .task { await preparePlayer() }
        .onDisappear { player?.pause() }
    }

    // MARK: - Language

    @ViewBuilder
    private var languageToggle: some View {
        SettingsSegmentedRow(
            options: Mode.allCases,
            selection: modeBinding,
            label: { modeLabel(for: $0) },
            palette: palette,
            motionOn: motionOn
        )
        .surfaceCard(palette)

        if isTranslating {
            FirasActivityLabel(
                text: Strings.Settings.Announcements.translating(lang),
                palette: palette,
                motionOn: motionOn
            )
        }
    }

    private func modeLabel(for mode: Mode) -> String {
        switch mode {
        case .original: return Strings.Settings.Announcements.original(lang)
        case .arabic: return Strings.Settings.Announcements.arabic(lang)
        case .english: return Strings.Settings.Announcements.english(lang)
        }
    }

    private var modeBinding: Binding<Mode> {
        Binding(
            get: { mode },
            set: { newValue in
                mode = newValue
                translate(for: newValue)
            }
        )
    }

    // MARK: - Media

    @ViewBuilder
    private var media: some View {
        if let player {
            VideoPlayer(player: player)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else if let image = announcement.image, !image.isEmpty {
            AnnouncementImageView(source: image, palette: palette)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    /// No autoplay: the reader taps play. The item is built once, not on every render.
    private func preparePlayer() {
        guard player == nil else { return }
        guard let url = AnnouncementStore.mediaURL(
            announcement.video,
            base: env.config.apiBaseURL
        ) else { return }
        player = AVPlayer(url: url)
    }

    // MARK: - Text

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(displayedTitle)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(stamp)
                .font(.system(size: 12))
                .foregroundStyle(palette.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bidiIsland(for: displayedTitle, fallback: lang)
    }

    private var bodyText: some View {
        MarkdownView(
            markdown: displayedBody,
            messageID: "announcement-" + announcement.id + "-" + mode.rawValue,
            streaming: false,
            lang: BidiText.isArabicDominant(displayedBody) ? .arabic : .english,
            palette: palette,
            prefs: env.prefs,
            onFence: { _ in nil }
        )
        .bidiIsland(for: displayedBody, fallback: lang)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stamp: String {
        let base = AnnouncementFormat.stamp(announcement.date, lang: lang)
        guard announcement.editedAt != nil else { return base }
        return base + " · " + Strings.Settings.Announcements.edited(lang)
    }

    // MARK: - Resolution

    private var displayedTitle: String {
        let resolved = resolvedTitle
        return resolved.isEmpty ? Strings.Settings.Announcements.untitled(lang) : resolved
    }

    private var resolvedTitle: String {
        switch mode {
        case .original:
            return announcement.title
        case .arabic:
            return isOriginallyArabic ? announcement.title : (translatedTitle ?? announcement.title)
        case .english:
            if let authored = announcement.titleEn, !authored.isEmpty { return authored }
            return translatedTitle ?? announcement.title
        }
    }

    private var displayedBody: String {
        switch mode {
        case .original:
            return announcement.body
        case .arabic:
            return isOriginallyArabic ? announcement.body : (translatedBody ?? announcement.body)
        case .english:
            if let authored = announcement.bodyEn, !authored.isEmpty { return authored }
            return translatedBody ?? announcement.body
        }
    }

    private var isOriginallyArabic: Bool {
        (announcement.lang ?? "ar").hasPrefix("ar")
    }

    /// Nothing is requested when the record already carries the language, and nothing at all is
    /// requested for a guest — `/api/translate` is member-only.
    private func translate(for newMode: Mode) {
        translatedTitle = nil
        translatedBody = nil

        let target: AppLanguage
        switch newMode {
        case .original:
            return
        case .arabic:
            guard !isOriginallyArabic else { return }
            target = .arabic
        case .english:
            let hasAuthored = (announcement.titleEn?.isEmpty == false)
                && (announcement.bodyEn?.isEmpty == false)
            guard !hasAuthored else { return }
            target = .english
        }

        guard env.session.isMember else {
            env.toasts.show(Strings.Settings.Announcements.translateMembersOnly(lang))
            mode = .original
            return
        }

        isTranslating = true
        Task {
            let result = await env.announcements.translation(for: announcement, to: target)
            isTranslating = false
            guard let result else {
                env.toasts.show(Strings.Settings.Announcements.translateFailed(lang), isError: true)
                mode = .original
                return
            }
            translatedTitle = result.title
            translatedBody = result.body
        }
    }

    // MARK: - Plumbing

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }
}
