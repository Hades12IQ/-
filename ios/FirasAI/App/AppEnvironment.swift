import Foundation
import Observation
import SwiftUI

/// The one place every store is built.
///
/// Construction order is a dependency order, not a taste: the transport and the device preferences
/// come first, then the objects that only need those, then the identity, then the job spine, then
/// the feature stores that all hand work to the spine, and finally the voice objects (the call
/// engine needs the TTS player it displaces).
///
/// `ISOLATED_DEFAULT_VALUES=YES` is why nothing here is a stored-property default: every store is
/// built inside this `@MainActor init` and handed to its dependents explicitly.
@MainActor
final class AppEnvironment {

    // MARK: - Stores

    let config: AppConfiguration
    let api: APIClient
    let prefs: PreferencesStore
    let network: NetworkMonitor
    let toasts: ToastCenter
    let router: Router
    let notifications: NotificationManager
    let session: SessionStore
    let jobs: JobManager
    let drafts: DraftStore
    let guestChats: GuestChatStore
    let chat: ChatStore
    let agent: AgentStore
    let code: CodeStore
    let brain: BrainStore
    let media: MediaStore
    let announcements: AnnouncementStore
    let memory: MemoryStore
    let call: CallEngine
    let tts: TTSPlayer
    let dictation: DictationController

    // MARK: - Support objects
    //
    // Not injected into the view tree: they are actors (or a one-shot task runner) that only their
    // owning store talks to.

    private let disk: DiskStore
    private let codeCache: CodeProjectCache
    private let mediaAssets: MediaAssetRepository
    private let guestMigration: GuestMigration

    /// The identity whose job pointers are currently being watched. `nil` before the first
    /// successful identity call, and after a sign-out.
    private var adoptedOwner: String?
    private var isAdoptingIdentity = false

    // MARK: - Construction

    init(config: AppConfiguration) {
        // 1. Transport, device preferences, and the objects that depend on neither.
        let api = APIClient(configuration: config)
        let prefs = PreferencesStore(defaults: UserDefaults.standard)
        let network = NetworkMonitor()
        let toasts = ToastCenter()
        let router = Router()
        let notifications = NotificationManager(prefs: prefs)

        // 2. Identity, then the job spine. `JobManager` installs its own `session.onUnauthorized`
        //    handler in its initialiser — it is the only object that knows which owner is active,
        //    so this file must not overwrite that hook.
        let session = SessionStore(api: api, prefs: prefs, network: network)
        let jobs = JobManager(
            api: api,
            session: session,
            prefs: prefs,
            notifications: notifications,
            network: network
        )

        // 3. Local persistence the feature stores read through.
        let disk = DiskStore.shared
        let drafts = DraftStore()
        let guestChats = GuestChatStore(disk: disk)
        let codeCache = CodeProjectCache(disk: disk)
        let mediaAssets = MediaAssetRepository(disk: disk)

        // 4. Chat first: every other feature store files its result as a turn in a conversation.
        let chat = ChatStore(
            api: api,
            session: session,
            jobs: jobs,
            prefs: prefs,
            drafts: drafts,
            guestChats: guestChats,
            toasts: toasts,
            router: router,
            network: network
        )
        let agent = AgentStore(
            api: api,
            session: session,
            jobs: jobs,
            chat: chat,
            prefs: prefs,
            toasts: toasts,
            router: router
        )
        let code = CodeStore(
            api: api,
            session: session,
            jobs: jobs,
            chat: chat,
            prefs: prefs,
            toasts: toasts,
            router: router,
            cache: codeCache
        )
        let brain = BrainStore(
            api: api,
            session: session,
            jobs: jobs,
            chat: chat,
            prefs: prefs,
            toasts: toasts,
            router: router
        )
        let media = MediaStore(
            api: api,
            session: session,
            jobs: jobs,
            chat: chat,
            prefs: prefs,
            toasts: toasts,
            router: router,
            assets: mediaAssets
        )

        // 5. Ambient content.
        let announcements = AnnouncementStore(api: api, prefs: prefs)
        let memory = MemoryStore(api: api)

        // 6. Voice. The call engine takes the TTS player so a call can silence it.
        let tts = TTSPlayer(api: api, prefs: prefs, toasts: toasts)
        let dictation = DictationController(
            api: api,
            prefs: prefs,
            toasts: toasts,
            network: network
        )
        let call = CallEngine(
            api: api,
            session: session,
            prefs: prefs,
            jobs: jobs,
            notifications: notifications,
            tts: tts
        )

        let guestMigration = GuestMigration(
            api: api,
            guestChats: guestChats,
            chat: chat,
            toasts: toasts
        )

        self.config = config
        self.api = api
        self.prefs = prefs
        self.network = network
        self.toasts = toasts
        self.router = router
        self.notifications = notifications
        self.session = session
        self.jobs = jobs
        self.drafts = drafts
        self.guestChats = guestChats
        self.chat = chat
        self.agent = agent
        self.code = code
        self.brain = brain
        self.media = media
        self.announcements = announcements
        self.memory = memory
        self.call = call
        self.tts = tts
        self.dictation = dictation
        self.disk = disk
        self.codeCache = codeCache
        self.mediaAssets = mediaAssets
        self.guestMigration = guestMigration

        registerJobObservers()
        wireGuestHandoff()
        wireMediaHandoff()
        wireMemoryHandoff()
        wireCallHandoff()
        session.onWillSignOut = { [weak code, weak session] in
            let owner = session?.identityID
            await code?.prepareForSignOut()
            if let owner { await DocumentAssetCache.shared.clear(ownerID: owner) }
        }

        // Idempotent, and the only call site that is guaranteed to run whatever shell renders:
        // offline state must come from the monitor, never from a stalled request.
        network.start()

        // The job spine watches exactly one owner; this keeps that owner in step with the session
        // without any screen having to remember to say so.
        observeIdentity()
    }

    // MARK: - Job delivery

    /// Every terminal job is delivered to exactly one store, on the main actor, before the pointer
    /// is forgotten. A kind with no observer would land its result nowhere.
    private func registerJobObservers() {
        jobs.register(chat, for: .chat)
        jobs.register(chat, for: .longdoc)
        jobs.register(chat, for: .longfile)
        jobs.register(agent, for: .agentrun)
        jobs.register(code, for: .codebuild)
        jobs.register(brain, for: .brainask)
        jobs.register(media, for: .image)
        jobs.register(media, for: .video)
        jobs.register(media, for: .music)
    }

    // MARK: - Identity

    /// Re-attaches the job watchers (and the conversation list) to whoever is signed in now.
    ///
    /// Idempotent by design: `JobManager.resumeAll` re-uses live watchers, so calling this on every
    /// foreground costs nothing. A signed-out device suspends its watchers — it never cancels the
    /// server-side work, which keeps running and is picked up again after re-authentication.
    func adoptCurrentIdentity() async {
        code.identityDidChange(to: session.identityID)
        chat.identityDidChange(to: session.identityID)
        media.identityDidChange(to: session.identityID)
        guard !isAdoptingIdentity else { return }
        isAdoptingIdentity = true
        defer {
            isAdoptingIdentity = false
            // An identity notification may arrive while disk/network work is suspended.
            if session.identityID != adoptedOwner {
                Task { @MainActor [weak self] in await self?.adoptCurrentIdentity() }
            }
        }

        guard let owner = session.identityID, !owner.isEmpty else {
            if let previous = adoptedOwner {
                jobs.suspend(owner: previous)
                adoptedOwner = nil
                dropRenderedText()
            }
            return
        }

        let changed = (adoptedOwner != owner)
        if changed, adoptedOwner != nil { dropRenderedText() }
        adoptedOwner = owner
        if changed {
            await DocumentAssetCache.shared.activate(ownerID: owner)
            guard session.identityID == owner else { return }
        }
        await jobs.resumeAll(owner: owner)

        // `SidebarView` loads the same list from its own `.task(id: identityID)`. `ChatStore` sets
        // `isLoadingList` synchronously before its first `await`, so whichever of the two arrives
        // first wins and the other does not repeat the GET.
        if changed, !chat.isLoadingList {
            await chat.loadConversations()
        }
        if changed { await media.reload() }
    }

    /// Signing out, deleting one's data, or switching accounts must leave nothing of the previous
    /// reader on screen or in memory. Both caches are keyed by message id, and a message id is not
    /// unique across accounts — so a parsed paragraph or a typeset equation could otherwise be
    /// handed to the next person to open the app.
    private func dropRenderedText() {
        MarkdownRenderer.invalidateAll()
        MathBlockView.invalidateAll()
    }

    /// One-shot observation, re-armed from its own callback: `Observation` fires each tracked
    /// change exactly once, so the re-arm has to happen before the work.
    private func observeIdentity() {
        let session = self.session
        withObservationTracking {
            _ = session.identityID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let environment = self else { return }
                environment.observeIdentity()
                await environment.adoptCurrentIdentity()
            }
        }
    }

    // MARK: - Cross-store handoffs

    /// A guest who signs up keeps the conversations they wrote as a guest.
    private func wireGuestHandoff() {
        session.onGuestBecameMember = { [weak self] previousGuestID in
            guard let self else { return }
            await self.guestMigration.run(previousGuestID: previousGuestID)
        }
    }

    /// «اصنع لي صورة…» typed into an ordinary chat is a render, not a paragraph. `SendPipeline`
    /// classifies the turn and hands the verdict over here before it appends anything, so a guest
    /// still gets the sign-up prompt and a member gets a card instead of prose
    /// (`web-media-ux.md §1`, §12.1). `MediaStore` writes both halves of the turn itself.
    ///
    /// An unavailable engine produces an explicit status, never a prose answer with internal prompts.
    private func wireMediaHandoff() {
        chat.onMediaRequest = { [weak self] kind, prompt, conversationID in
            guard let self, let owner = self.session.identityID else { return false }
            let images = self.chat.state(for: conversationID).lastTurnImages
            let intent = RequestClassifier.classify(prompt, hasImages: !images.isEmpty, lang: self.prefs.lang)
            if self.media.unavailableKinds.contains(kind) {
                self.chat.state(for: conversationID).errorStrip = ChatMediaPreparation.unavailable(kind, lang: self.prefs.lang)
                return true
            }
            if self.media.isSubmitting {
                self.chat.state(for: conversationID).errorStrip = Strings.Chat.busyWait(self.prefs.lang)
                self.toasts.show(Strings.Chat.busyWait(self.prefs.lang), isError: true)
                return true
            }
            switch kind {
            case .image:
                if intent == .imageEdit, let encoded = images.first {
                    let raw = encoded.hasPrefix("data:") ? String(encoded.split(separator: ",", maxSplits: 1).last ?? "") : encoded
                    guard let bytes = Data(base64Encoded: raw), !bytes.isEmpty else {
                        self.chat.state(for: conversationID).errorStrip = Strings.Media.editBadImage(self.prefs.lang)
                        return true
                    }
                    await self.media.editImage(sourceData: bytes, prompt: prompt, in: conversationID, recordQuestion: false)
                } else {
                    await self.media.createImage(prompt: prompt, shape: nil, in: conversationID, recordQuestion: false)
                }
            case .video:
                await self.media.createVideo(
                    prompt: prompt,
                    seconds: self.media.videoDefaultSeconds,
                    firstFrameJPEGBase64: images.first,
                    in: conversationID,
                    recordQuestion: false
                )
            case .music:
                await self.media.createMusic(
                    prompt: prompt,
                    lyrics: nil,
                    seconds: 60,
                    in: conversationID,
                    recordQuestion: false
                )
            }
            guard self.session.identityID == owner else { return true }
            return true
        }
    }

    /// One question per landed answer goes to long-term memory. `ChatStore`'s frozen initialiser
    /// takes no `MemoryStore`, and the store fires and forgets, so this is the whole wire.
    private func wireMemoryHandoff() {
        chat.onAnswerLanded = { [weak self] question, _ in
            self?.memory.learn(question)
        }
    }

    /// A live call owns the audio session and the user's attention: spoken answers stop, completion
    /// cues stay silent, and any plan cycle waiting on an answer holds its place until the call ends.
    private func wireCallHandoff() {
        call.onPause = { [weak self] in
            self?.setCallActive(true)
        }
        call.onResume = { [weak self] in
            self?.setCallActive(false)
        }
    }

    private func setCallActive(_ active: Bool) {
        jobs.callActive = active
        tts.callActive = active
        SongPlayer.shared.callActive = active
        for state in chat.states.values {
            if active {
                state.plan.pauseForCall()
            } else {
                state.plan.resumeAfterCall()
            }
        }
    }

    // MARK: - Injection

    /// Applies every observable store to the view tree once, at the root. Screens read what they
    /// need with `@Environment(ChatStore.self)`; nobody constructs a store in a `@State`.
    ///
    /// The chain is erased in groups: eighteen nested `ModifiedContent`s in one expression is a
    /// type-checker cost that CI pays for, and `AnyView` here costs one extra layer at launch.
    func inject<V: View>(into view: V) -> AnyView {
        let base = AnyView(
            view
                .environment(prefs)
                .environment(network)
                .environment(toasts)
                .environment(router)
                .environment(notifications)
        )
        let identity = AnyView(
            base
                .environment(session)
                .environment(jobs)
                .environment(drafts)
        )
        let features = AnyView(
            identity
                .environment(chat)
                .environment(agent)
                .environment(code)
                .environment(brain)
                .environment(media)
        )
        return AnyView(
            features
                .environment(announcements)
                .environment(memory)
                .environment(call)
                .environment(tts)
                .environment(dictation)
        )
    }
}
