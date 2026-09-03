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
    /* THE FETCH ITSELF, not merely a flag that one is running. A second caller for the same
       bytes awaits this task; before it existed, `localURL` answered `nil` — the same `nil` it
       returns for a real failure — and the card drew a download error over a picture that was
       on its way. Keyed by creation id, cleared when the task settles. */
    @ObservationIgnored private var inFlight: [String: Task<URL?, Never>] = [:]
    @ObservationIgnored private var indexLoaded = false

    /// Armed once; re-armed from its own callback for as long as the app lives.
    @ObservationIgnored private var observingConversations = false
    /// How many messages of each loaded transcript have already been read for fences. A live answer
    /// rewrites its last row thousands of times, and re-reading a whole transcript on each of those
    /// is the difference between this being free and this being a stutter.
    @ObservationIgnored private var scannedMessageCounts: [String: Int] = [:]
    @ObservationIgnored private var adoptionScheduled = false

    /* NOT INSIDE `media/`. The index used to live in the very folder `MediaAssetRepository` keeps
       the renders in, which made it an asset as far as that folder is concerned: the newest-200
       trim counted it, and `removeAll()` deleted it. It sits beside that folder now, and the old
       path is read once so nobody loses a library on the update. */
    static let indexPath = "media-index.json"
    static let legacyIndexPath = "media/index.json"
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

    /// The creation a fence in a transcript belongs to.
    ///
    /// **The turn first, the cache key second, and that order is the whole point.** A fence gets its
    /// key when the render lands, so for the entire time a render is actually running there is no
    /// key to match on — and a card that cannot find its creation is told `phase: .auto` and
    /// `startedAt: nil`, which is the card's signal that *nobody claims a job is live*. Every card
    /// then falls back to its short ceiling (90 s for a picture, 120 s for a clip) and puts «طال
    /// الانتظار» over a render the server is still working on, with a regenerate button under it
    /// that charges for a second one.
    ///
    /// The turn is the identity that exists from the first frame (`MediaStore+Creating.placeCard`),
    /// so it is what the host should ask with.
    func creation(inConversation conversationID: String, messageID: String, key: String) -> MediaCreation? {
        if !messageID.isEmpty {
            let match = creations.first { item in
                item.messageID == messageID && item.conversationID == conversationID
            }
            if let match { return match }
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return creations.first { $0.meta.key == trimmed }
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
        var stored = await DiskStore.shared.read([MediaCreation].self, at: Self.indexPath) ?? []
        if stored.isEmpty {
            stored = await DiskStore.shared.read([MediaCreation].self, at: Self.legacyIndexPath) ?? []
        }
        indexLoaded = true

        var merged = stored.filter { owner.isEmpty || $0.ownerID.isEmpty || $0.ownerID == owner }
        var positions: [String: Int] = [:]
        for (position, item) in merged.enumerated() { positions[item.id] = position }
        var seen = Set(merged.map { Self.dedupeKey($0) })
        var turns = Set(merged.compactMap { Self.turnKey($0) })

        /* MEMORY IS NEVER OLDER THAN DISK — the index is written FROM this array. A creation that
           is here and not there is a render that started before the read came back, and the old
           rebuild simply dropped it: its card was left on a phase nothing could ever update, and
           the picture that eventually landed had no record to be filed under. */
        for item in creations where owner.isEmpty || item.ownerID.isEmpty || item.ownerID == owner {
            if let position = positions[item.id] {
                merged[position] = item
                continue
            }
            let key = Self.dedupeKey(item)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            if let turn = Self.turnKey(item) { turns.insert(turn) }
            positions[item.id] = merged.count
            merged.append(item)
        }

        for conversation in chat.conversations.values {
            scannedMessageCounts[conversation.id] = conversation.messages.count
            for item in Self.scan(conversation: conversation, owner: owner) {
                guard Self.absorb(item, into: &seen, turns: &turns) else { continue }
                merged.append(item)
            }
        }
        creations = merged.sorted { $0.createdAt > $1.createdAt }
        observeConversations()
        await refreshQuota()
    }

    // MARK: - Adopting the fences in a transcript the reader opens

    /// **Why this exists.** A member's transcripts are fetched one at a time, the first time each is
    /// opened (`ChatStore.open`) — and nothing told the library about it. `reload()` runs at boot,
    /// when `chat.conversations` is still empty, so every picture, clip and song in a chat opened
    /// later had no `MediaCreation` behind it at all. The cards resolve their bytes through that
    /// record, so the resolver answered `nil` for ever: the reader watched a cover turn over a
    /// picture that was sitting finished on the server, and then pressed regenerate and paid for it
    /// twice. «خليها تنحفظ … من ارجعلهم الكاهم مباشرة مو يرجع يولدهم من جديد».
    ///
    /// One-shot observation re-armed from its own callback — the shape `AppEnvironment` uses for
    /// identity, because `Observation` delivers each tracked change exactly once.
    private func observeConversations() {
        guard !observingConversations else { return }
        observingConversations = true
        armConversationObservation()
    }

    private func armConversationObservation() {
        let transcripts = self.chat
        withObservationTracking {
            _ = transcripts.conversations
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let store = self else { return }
                store.armConversationObservation()
                store.scheduleAdoption()
            }
        }
    }

    /// Coalesced. `conversations` is rewritten on every appended message and on every frame of a
    /// live answer; adopting is worth doing once the burst is over, not during it.
    private func scheduleAdoption() {
        guard !adoptionScheduled else { return }
        adoptionScheduled = true
        Task { @MainActor [weak self] in
            await JobClock.rest(0.6)
            guard let store = self else { return }
            store.adoptionScheduled = false
            await store.adoptLoadedFences()
        }
    }

    /// Files a creation for every media fence in a transcript that is in memory and has not been
    /// read yet. Only the tail of each transcript is scanned, so a streaming answer costs nothing.
    func adoptLoadedFences() async {
        let owner = session.identityID ?? ""
        var seen = Set(creations.map { Self.dedupeKey($0) })
        var turns = Set(creations.compactMap { Self.turnKey($0) })
        var adopted: [MediaCreation] = []

        for conversation in chat.conversations.values {
            let count = conversation.messages.count
            let scanned = scannedMessageCounts[conversation.id]
            guard scanned != count else { continue }
            scannedMessageCounts[conversation.id] = count
            // One row back: the last message is rewritten in place while it streams, and it is the
            // one that grows a fence.
            let from = Swift.max(0, (scanned ?? 0) - 1)
            for item in Self.scan(conversation: conversation, owner: owner, from: from) {
                guard Self.absorb(item, into: &seen, turns: &turns) else { continue }
                adopted.append(item)
            }
        }

        guard !adopted.isEmpty else { return }
        creations.append(contentsOf: adopted)
        creations.sort { $0.createdAt > $1.createdAt }
        await persistIndex()
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
    func inFlightDownload(_ id: String) -> Task<URL?, Never>? { inFlight[id] }
    func setInFlightDownload(_ id: String, _ task: Task<URL?, Never>?) {
        if let task { inFlight[id] = task } else { inFlight.removeValue(forKey: id) }
    }

    /* NEVER BEFORE THE READ. The old guard also wrote whenever `creations` merely had something in
       it, so a single render that started before `reload()` came back replaced the whole on-disk
       library with that one row — and every earlier creation lost the local filename that is the
       only reason reopening a conversation is instant. */
    func persistIndex() async {
        guard indexLoaded else { return }
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

    /// The conversation turn a creation was written into. Two records for one turn are one record,
    /// whatever their ids say — and until a render finishes, its key is empty, so `dedupeKey` alone
    /// cannot see that the live creation and the placeholder fence beside it are the same thing.
    /// Without this the library grew a second, permanently "timed out" tile beside every render in
    /// flight.
    nonisolated static func turnKey(_ item: MediaCreation) -> String? {
        guard let messageID = item.messageID, !messageID.isEmpty else { return nil }
        return item.conversationID + "|" + messageID
    }

    /// True when `item` is genuinely new, having claimed both of its identities. Written as one
    /// helper because the rebuild and the incremental adoption must not disagree about it.
    nonisolated static func absorb(
        _ item: MediaCreation,
        into seen: inout Set<String>,
        turns: inout Set<String>
    ) -> Bool {
        let key = dedupeKey(item)
        guard !seen.contains(key) else { return false }
        if let turn = turnKey(item) {
            guard !turns.contains(turn) else { return false }
            turns.insert(turn)
        }
        seen.insert(key)
        return true
    }

    /// Every media fence in one conversation, in message order, from `from` onwards.
    nonisolated static func scan(
        conversation: ChatConversation,
        owner: String,
        from: Int = 0
    ) -> [MediaCreation] {
        var found: [MediaCreation] = []
        let base = date(fromISO: conversation.updatedAt) ?? Date(timeIntervalSince1970: 0)
        let messages = conversation.messages
        let first = Swift.max(0, Swift.min(from, messages.count))
        for index in first..<messages.count {
            let message = messages[index]
            guard message.role == .assistant else { continue }
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

    /// The file extensions a kind's bytes can land under, newest engine first. A stored render is
    /// filed as `<key>.<ext>`, so this is what lets the store find bytes it already holds from a
    /// fence alone — see `localURL(for:)`.
    nonisolated static func storedExtensions(for kind: MediaKind) -> [String] {
        switch kind {
        case .image: return ["png", "jpg", "webp"]
        case .video: return ["mp4", "mov", "webm"]
        case .music: return ["mp3", "m4a", "wav", "flac", "ogg"]
        }
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
