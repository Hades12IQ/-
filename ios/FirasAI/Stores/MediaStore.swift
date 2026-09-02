import Foundation
import Observation

/// Everything the Studio knows: what has been made, what is being made, and what the day's
/// allowance looks like.
///
/// The one architectural decision that makes this store worth having
/// (`web-media-ux.md §12.2`, `audit-ios-brain-media.md §B.3` finding 28): **a creation is a
/// conversation turn.** The user's request is appended as a user message and the finished render as
/// an assistant message carrying a `firas-image` / `firas-video` / `firas-music` fence. That single
/// rule is what keeps the library, sharing, the web, other devices, reattachment after a relaunch
/// and the completion notification all working from one record instead of five.
///
/// The store never polls. It hands the job to `JobManager` and is called back on the main actor
/// when the render is terminal — which is why closing the app mid-render loses nothing.
@MainActor
@Observable
final class MediaStore: JobObserver {

    // MARK: - Published state

    /// Newest first. Merged from the on-disk index and from every media fence found in the
    /// conversations the chat store has loaded.
    private(set) var creations: [MediaCreation] = []

    /// `POST /api/image/quota`, the only read-only allowance the server exposes.
    private(set) var imageQuota: ImageQuota?

    /// The quota call answered 429 — the day is spent. `imageQuota` stays nil because the frozen
    /// model has no memberwise initialiser to build a synthetic one from the error body.
    private(set) var imageQuotaBlocked = false
    private(set) var imageQuotaLimit: Int?

    /// `GET /api/video/quota` — only `seconds` is trustworthy there (`server-media.md §2.4`).
    private(set) var videoDefaultSeconds: Int = 10

    private(set) var isReloading = false
    private(set) var isSubmitting = false

    /// The last refusal, already localized, for the create form's inline plate.
    private(set) var lastFailureText: String?

    /// Kinds the deployment has not configured (`503 not_configured`); their controls hide.
    private(set) var unavailableKinds: Set<MediaKind> = []

    /// `freesInMin` from the most recent 429 `rate_window`, per kind.
    private(set) var freesInMinutes: [String: Int] = [:]

    /// Set by the viewer's Edit action, consumed once by the create form. This is what makes
    /// "edit this picture" a real path rather than a button that only changes screens.
    var pendingEditSourceID: String?

    // MARK: - Dependencies

    // Deliberately `internal`, not `private`: the landing half of this store lives in
    // `MediaStore+Landing.swift`, and a file-private reference would not compile across the two
    // (COMPILE-RISK RULE 17 — no cross-file `private` reliance).
    let api: APIClient
    let session: SessionStore
    let jobs: JobManager
    let chat: ChatStore
    let prefs: PreferencesStore
    let toasts: ToastCenter
    let router: Router
    let assets: MediaAssetRepository

    @ObservationIgnored private var downloading: Set<String> = []
    @ObservationIgnored private var indexLoaded = false

    static let indexPath = "media/index.json"
    static let keptAssets = 200

    init(
        api: APIClient,
        session: SessionStore,
        jobs: JobManager,
        chat: ChatStore,
        prefs: PreferencesStore,
        toasts: ToastCenter,
        router: Router,
        assets: MediaAssetRepository
    ) {
        self.api = api
        self.session = session
        self.jobs = jobs
        self.chat = chat
        self.prefs = prefs
        self.toasts = toasts
        self.router = router
        self.assets = assets
    }

    var lang: AppLanguage { prefs.lang }

    // MARK: - Reading

    func creation(id: String) -> MediaCreation? {
        creations.first { $0.id == id }
    }

    func creations(kind: MediaKind?) -> [MediaCreation] {
        guard let kind else { return creations }
        return creations.filter { $0.kind == kind }
    }

    /// The tiles that are still rendering — the "still rendering" strip and the skeletons.
    var liveCreations: [MediaCreation] {
        creations.filter { $0.phase.isLive }
    }

    var editableImages: [MediaCreation] {
        creations.filter { $0.kind == .image && !$0.meta.key.isEmpty }
    }

    func conversationTitle(_ id: String) -> String {
        let title = chat.conversations[id]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        let summary = chat.summaries.first { $0.id == id }?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return summary.isEmpty ? Strings.Media.untitledConversation(lang) : summary
    }

    // MARK: - Loading

    /// Rebuilds the library: the persisted index first (it carries the real dates and the local
    /// filenames), then every media fence in the conversations already in memory, deduplicated by
    /// cache key so a creation this device made does not appear twice.
    func reload() async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        let owner = session.identityID ?? ""
        let stored = await DiskStore.shared.read([MediaCreation].self, at: Self.indexPath) ?? []
        indexLoaded = true

        var merged = stored.filter { owner.isEmpty || $0.ownerID.isEmpty || $0.ownerID == owner }
        var seen = Set(merged.map { Self.dedupeKey($0) })

        for conversation in chat.conversations.values {
            for item in Self.scan(conversation: conversation, owner: owner) {
                let key = Self.dedupeKey(item)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                merged.append(item)
            }
        }
        creations = merged.sorted { $0.createdAt > $1.createdAt }
        await refreshQuota()
    }

    /// The two allowance probes. Neither is required for a render to start — a failure leaves the
    /// panel saying so rather than blocking the form.
    func refreshQuota() async {
        guard session.isMember else {
            imageQuota = nil
            imageQuotaBlocked = false
            return
        }
        do {
            let quota = try await api.imageQuota()
            imageQuota = quota
            imageQuotaLimit = quota.limit
            imageQuotaBlocked = false
        } catch {
            let failure = error as? APIError
            if failure?.status == 429 {
                imageQuota = nil
                imageQuotaBlocked = true
                imageQuotaLimit = failure?.server?.limit
            } else {
                imageQuota = nil
            }
        }
        do {
            let video = try await api.videoQuota()
            if let seconds = video.seconds, seconds >= 2, seconds <= 30 {
                videoDefaultSeconds = seconds
            }
        } catch {
            // `limit`/`remaining` here count a dead legacy route anyway; only `seconds` mattered.
        }
    }

    // MARK: - Where a creation lands

    /// The conversation a creation lands in: the one the user picked, or a fresh one. Members get a
    /// server id here so the fence is on the account and not only on this device.
    func resolveConversation(_ id: String?) async -> (local: String, server: String?) {
        var local = (id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if local.isEmpty {
            local = chat.newConversation(
                product: .ai,
                flags: (agent: false, codeProj: false, brainNb: false)
            )
        }
        let server = await chat.ensureServerChat(local)
        return (local, server)
    }

    func upsert(_ item: MediaCreation) {
        if let index = creations.firstIndex(where: { $0.id == item.id }) {
            creations[index] = item
        } else {
            creations.insert(item, at: 0)
        }
    }

    func removeCreation(_ id: String) {
        creations.removeAll { $0.id == id }
    }

    /// `isSubmitting` is `private(set)`, so the landing file flips it through here.
    func setSubmitting(_ value: Bool) {
        isSubmitting = value
    }

    // One download per creation at a time: two tiles asking for the same 200 MB clip would
    // otherwise fetch it twice and race on the same destination file.
    func isDownloading(_ id: String) -> Bool { downloading.contains(id) }
    func beginDownload(_ id: String) { downloading.insert(id) }
    func endDownload(_ id: String) { downloading.remove(id) }

    func persistIndex() async {
        guard indexLoaded || !creations.isEmpty else { return }
        let snapshot = Array(creations.prefix(400))
        try? await DiskStore.shared.write(snapshot, at: Self.indexPath)
    }

    // MARK: - Gates and presentation

    /// Clears the inline plate once something works again.
    func clearFailure() {
        lastFailureText = nil
    }

    /// Guests never reach a creation route: the server refuses them with `signin_required`, and
    /// asking first is both faster and the only way to show the right upsell.
    func requireMember(_ kind: MediaKind) -> Bool {
        guard !session.isMember else { return true }
        lastFailureText = Strings.Media.guestBody(kind)(lang)
        router.showSignUp(feature: kind.featureKey)
        return false
    }

    func present(_ text: String) {
        lastFailureText = text
        toasts.show(text, isError: true)
    }

    /// Maps a start refusal through the shared policy, then keeps the numbers the panel needs.
    func presentFailure(_ error: Error, kind: MediaKind) {
        if let server = (error as? APIError)?.server {
            if let minutes = server.freesInMin { freesInMinutes[kind.rawValue] = minutes }
            if server.code == "not_configured" { unavailableKinds.insert(kind) }
        }
        let action = ErrorPresenter.present(
            error,
            feature: kind.featureKey,
            isGuest: session.isGuest,
            lang: lang
        )
        apply(action, kind: kind)
    }

    func apply(_ action: ErrorAction, kind: MediaKind) {
        switch action {
        case .toast(let text):
            present(text(lang))
        case .toastText(let text):
            present(text)
        case .signUpPrompt(let feature):
            lastFailureText = Strings.Media.guestBody(kind)(lang)
            router.showSignUp(feature: feature)
        case .sessionExpired:
            present(Strings.Media.imageWhySignIn(lang))
        case .hideFeature:
            unavailableKinds.insert(kind)
            present(Strings.Media.failureText(kind, code: "not_configured", lang: lang))
        case .blockedAgent, .creditsBlocked:
            present(Strings.Errors.serverBusy(lang))
        case .silent:
            lastFailureText = nil
        }
    }

    // MARK: - Static helpers

    /// A creation is the same thing twice when it points at the same bytes in the same chat.
    nonisolated static func dedupeKey(_ item: MediaCreation) -> String {
        let key = item.meta.key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return "id:" + item.id }
        return item.kind.rawValue + "|" + item.conversationID + "|" + key
    }

    /// Every media fence in one conversation, in message order.
    nonisolated static func scan(conversation: ChatConversation, owner: String) -> [MediaCreation] {
        var found: [MediaCreation] = []
        let base = date(fromISO: conversation.updatedAt) ?? Date(timeIntervalSince1970: 0)
        for (index, message) in conversation.messages.enumerated() where message.role == .assistant {
            guard let fence = FirasFence.firstFence(in: message.content) else { continue }
            guard let kind = MediaKind(fenceName: fence.name) else { continue }
            guard let meta = MediaMeta.parse(fenceName: fence.name, body: fence.body) else { continue }
            // A fence with no key is a render this device never finished watching. It is shown as a
            // timed-out item with a regenerate action, never as a spinner that can never stop.
            found.append(
                MediaCreation(
                    id: "fence:" + conversation.id + ":" + message.id,
                    ownerID: owner,
                    kind: kind,
                    meta: meta,
                    conversationID: conversation.id,
                    messageID: message.id,
                    createdAt: base.addingTimeInterval(Double(index) * 0.001),
                    phase: meta.key.isEmpty ? .expired : .completed,
                    jobID: meta.jobId
                )
            )
        }
        return found
    }

    /// `data:image/jpeg;base64,…` is the only shape `/api/video/job` accepts; a bare base64 string
    /// answers `400 bad_image`.
    nonisolated static func dataURI(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("data:image/") || trimmed.hasPrefix("https://") { return trimmed }
        return "data:image/jpeg;base64," + trimmed
    }

    nonisolated static func date(fromISO raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFraction.date(from: raw) { return parsed }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
