import Foundation
import Observation

/// The site-updates feed behind the drawer bell.
///
/// Two sources, one list: `GET /api/announcements` and the launch post that ships inside the app
/// (`Announcement.builtinLaunch`). The built-in record exists so the feed is never empty — not
/// offline, not on a fresh database — and a server record carrying the same id replaces it rather
/// than showing twice (`web-auth-account-settings.md §8.1`).
///
/// The unread dot is a timestamp comparison, never a count the server has to keep:
/// `prefs.lastSeenAnnouncementAt` holds the newest `ts` the reader has opened.
@MainActor
@Observable
final class AnnouncementStore {

    /// Pinned first, then newest — the order the server already answers in, re-applied locally
    /// because the built-in post is merged after the fact.
    private(set) var items: [Announcement] = [Announcement.builtinLaunch]

    private(set) var isLoading = false
    /// Kept as an `LText` so the sentence follows the language at render time, never the language
    /// that happened to be set when the request failed. Localized through `ErrorPresenter`; the
    /// server's own sentence is never shown.
    private(set) var failure: LText?
    /// True once a network answer (success or failure) has landed, so the sheet can tell
    /// "still loading" from "loaded and empty".
    private(set) var hasLoaded = false

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let prefs: PreferencesStore
    @ObservationIgnored private var translations: [TranslationKey: Translation] = [:]

    init(api: APIClient, prefs: PreferencesStore) {
        self.api = api
        self.prefs = prefs
    }

    // MARK: - Reading

    /// Anything newer than the last opened record.
    var unseenCount: Int {
        let seen = prefs.lastSeenAnnouncementAt
        return items.reduce(into: 0) { total, item in
            if item.at > seen { total += 1 }
        }
    }

    var hasUnseen: Bool { unseenCount > 0 }

    func item(id: String) -> Announcement? {
        items.first { $0.id == id }
    }

    // MARK: - Loading

    /// Never throws and never clears what is already on screen: a failed refresh keeps the last
    /// good list (or the built-in post) and puts one localizable line in `failure`.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let remote = try await api.announcements()
            items = Self.merged(remote)
            failure = nil
        } catch {
            failure = Self.message(for: error)
        }
        hasLoaded = true
    }

    /// Opening the panel clears the dot: the newest timestamp in the list becomes the watermark.
    func markSeen() {
        let newest = items.reduce(0.0) { Swift.max($0, $1.at) }
        guard newest > prefs.lastSeenAnnouncementAt else { return }
        prefs.lastSeenAnnouncementAt = newest
    }

    // MARK: - Translation

    /// `POST /api/translate` is member-only and takes one text at a time, so the title and the
    /// body are two calls. Results are cached for the life of the store: re-opening a reader must
    /// not spend the 40/min budget again.
    ///
    /// Returns `nil` when the record already carries authored copy in that language (the caller
    /// should read `localizedTitle`/`localizedBody` instead) or when the call failed.
    func translation(
        for announcement: Announcement,
        to language: AppLanguage
    ) async -> (title: String, body: String)? {
        let key = TranslationKey(id: announcement.id, language: language)
        if let cached = translations[key] {
            return (cached.title, cached.body)
        }

        do {
            let title = try await api.translate(text: announcement.title, to: language.rawValue)
            let body = try await api.translate(text: announcement.body, to: language.rawValue)
            let resolved = Translation(
                title: title.isEmpty ? announcement.title : title,
                body: body.isEmpty ? announcement.body : body
            )
            translations[key] = resolved
            return (resolved.title, resolved.body)
        } catch {
            return nil
        }
    }

    /// The full URL of a same-origin `/media/…` asset. Absolute URLs pass through.
    nonisolated static func mediaURL(_ path: String?, base: URL) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    // MARK: - Merging

    /// The built-in post is appended only when the server did not send a record with its id, then
    /// the whole list is ordered pinned-first, newest-first.
    nonisolated static func merged(_ remote: [Announcement]) -> [Announcement] {
        var all = remote
        if !remote.contains(where: { $0.id == Announcement.builtinLaunch.id }) {
            all.append(Announcement.builtinLaunch)
        }
        return all.sorted { left, right in
            if left.pinned != right.pinned { return left.pinned }
            return left.at > right.at
        }
    }

    // MARK: - Errors

    private static func message(for error: Error) -> LText {
        switch ErrorPresenter.present(error, feature: nil, isGuest: false, lang: .arabic) {
        case .toast(let text):
            return text
        case .sessionExpired:
            return Strings.Errors.sessionExpired
        default:
            return Strings.Settings.Announcements.loadFailed
        }
    }

    // MARK: - Cache keys

    private struct TranslationKey: Hashable, Sendable {
        let id: String
        let language: AppLanguage
    }

    private struct Translation: Sendable {
        let title: String
        let body: String
    }
}
