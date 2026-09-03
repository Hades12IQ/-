import Foundation

/// The creating half of `MediaStore`: guest gate, allowance pre-check, prompt pipeline, then the
/// job. Split out of `MediaStore.swift` for length only — every member here is part of that class.
///
/// The order in each method is the order the web uses and it is not cosmetic: refusing a guest
/// before any call is what makes the upsell instant, reading the image quota first is what turns a
/// spent day into a sentence rather than a failed render, and rewriting the prompt before the job
/// starts is what the engines are actually good at.
extension MediaStore {

    /// Guest gate → quota pre-check → English rewrite → shape → job. The rewrite is what turns
    /// «اصنع لي شعارًا» into a prompt the engines actually render well; the shape is read from the
    /// **raw** Arabic, never from the rewrite.
    func createImage(prompt: String, shape: ImageShape?, in conversationID: String?,
                     recordQuestion: Bool = true) async {
        let raw = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requirePrompt(raw), requireMember(.image), !isSubmitting else { return }
        setSubmitting(true)
        defer { setSubmitting(false) }

        await refreshQuota()
        if imageQuotaBlocked {
            if let limit = imageQuotaLimit {
                present(Strings.Errors.imageDailyLimit.fmt(lang, ArabicText.count(limit, lang)))
            } else {
                present(Strings.Media.imageWhyQuota(lang))
            }
            return
        }

        let target = await resolveConversation(conversationID)
        let cid = IDs.cid()
        /* ONLY WHEN NOBODY ELSE HAS ASKED. A request typed into the chat already has the
           reader's sentence in the transcript — writing it again put the same words on screen
           twice for the whole planning round trip, and then took one away. */
        if recordQuestion {
            await chat.appendUserTurn(ChatMessage.user(raw, cid: cid, lang: lang), in: target.local)
        }
        await placeCard(kind: .image, meta: MediaMeta(kind: .image, prompt: raw), target: target, cid: cid)
        let english = await MediaPromptPipeline.imagePrompt(api: api, rawText: raw, lang: lang)
        let chosen = shape ?? MediaPromptPipeline.pickShape(raw)

        let meta = MediaMeta(kind: .image, prompt: english, w: chosen.width, h: chosen.height)
        let request = ImageJobRequest(prompt: english, w: chosen.width, h: chosen.height, chatId: target.server)
        await start(kind: .image, meta: meta, request: request, target: target, cid: cid, rawText: raw)
    }

    /// A clip. The first frame, when there is one, is part of the job's identity on the server, so
    /// the same description with a different photo is a different render.
    func createVideo(prompt: String, seconds: Int, firstFrameJPEGBase64: String?,
                     in conversationID: String?, recordQuestion: Bool = true) async {
        let raw = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requirePrompt(raw), requireMember(.video), !isSubmitting else { return }
        setSubmitting(true)
        defer { setSubmitting(false) }

        let clamped = min(max(seconds, 2), 30)
        let frame = Self.dataURI(from: firstFrameJPEGBase64)
        let target = await resolveConversation(conversationID)
        let cid = IDs.cid()
        /* ONLY WHEN NOBODY ELSE HAS ASKED. A request typed into the chat already has the
           reader's sentence in the transcript — writing it again put the same words on screen
           twice for the whole planning round trip, and then took one away. */
        if recordQuestion {
            await chat.appendUserTurn(ChatMessage.user(raw, cid: cid, lang: lang), in: target.local)
        }
        await placeCard(kind: .video, meta: MediaMeta(kind: .video, prompt: raw), target: target, cid: cid)
        let english = await MediaPromptPipeline.videoPrompt(
            api: api,
            rawText: raw,
            seconds: clamped,
            hasPhoto: frame != nil
        )

        let meta = MediaMeta(kind: .video, prompt: english, seconds: clamped, src: frame == nil ? nil : "photo")
        let request = VideoJobRequest(prompt: english, seconds: clamped, image: frame, chatId: target.server)
        await start(kind: .video, meta: meta, request: request, target: target, cid: cid, rawText: raw)
    }

    /// A song. `prompt` on the wire is the English production tag line and `lyrics` the sung words —
    /// putting an Arabic description in `prompt` is the single worst media bug the old app had.
    func createMusic(prompt: String, lyrics: String?, seconds: Int, in conversationID: String?,
                     recordQuestion: Bool = true) async {
        let raw = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let supplied = (lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard requirePrompt(raw.isEmpty ? supplied : raw), requireMember(.music), !isSubmitting else { return }
        setSubmitting(true)
        defer { setSubmitting(false) }

        let clamped = min(max(seconds, 10), 150)
        let target = await resolveConversation(conversationID)
        let cid = IDs.cid()
        let userText = raw.isEmpty ? supplied : raw
        /* ONLY WHEN NOBODY ELSE HAS ASKED. A request typed into the chat already has the
           reader's sentence in the transcript — writing it again put the same words on screen
           twice for the whole planning round trip, and then took one away. */
        if recordQuestion {
            await chat.appendUserTurn(ChatMessage.user(userText, cid: cid, lang: lang), in: target.local)
        }
        await placeCard(kind: .music, meta: MediaMeta(kind: .music, prompt: raw.isEmpty ? supplied : raw), target: target, cid: cid)
        let plan = await MediaPromptPipeline.songPlan(
            api: api,
            rawText: raw,
            userLyrics: supplied.isEmpty ? nil : supplied,
            genreHint: nil,
            lang: lang
        )


        let meta = MediaMeta(
            kind: .music,
            prompt: plan.style,
            seconds: clamped,
            lyrics: plan.lyrics,
            title: plan.title,
            // The card's style line falls back to `prompt` when this is nil, which is why every
            // song used to be labelled with the raw request instead of its genre.
            style: plan.style
        )
        let request = MusicJobRequest(
            prompt: plan.style,
            lyrics: plan.lyrics,
            seconds: clamped,
            chatId: target.server
        )
        await start(kind: .music, meta: meta, request: request, target: target, cid: cid, rawText: userText)
        // The author coming back empty no longer refuses the song — it makes an instrumental and
        // says so, AFTER the job is under way so the notice annotates work in progress.
        if let notice = plan.notice { present(notice(lang)) }
    }

    /// Creates a song from a genre chip the user picked, bypassing the keyword table.
    func createMusic(prompt: String, lyrics: String?, seconds: Int, styleOverride: String,
                     in conversationID: String?, recordQuestion: Bool = true) async {
        let raw = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let supplied = (lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard requirePrompt(raw.isEmpty ? supplied : raw), requireMember(.music), !isSubmitting else { return }
        setSubmitting(true)
        defer { setSubmitting(false) }

        let clamped = min(max(seconds, 10), 150)
        let target = await resolveConversation(conversationID)
        let cid = IDs.cid()
        let userText = raw.isEmpty ? supplied : raw
        /* ONLY WHEN NOBODY ELSE HAS ASKED. A request typed into the chat already has the
           reader's sentence in the transcript — writing it again put the same words on screen
           twice for the whole planning round trip, and then took one away. */
        if recordQuestion {
            await chat.appendUserTurn(ChatMessage.user(userText, cid: cid, lang: lang), in: target.local)
        }
        await placeCard(kind: .music, meta: MediaMeta(kind: .music, prompt: raw.isEmpty ? supplied : raw), target: target, cid: cid)
        let plan = await MediaPromptPipeline.songPlan(
            api: api,
            rawText: raw,
            userLyrics: supplied.isEmpty ? nil : supplied,
            genreHint: styleOverride,
            lang: lang
        )

        let meta = MediaMeta(
            kind: .music,
            prompt: plan.style,
            seconds: clamped,
            lyrics: plan.lyrics,
            title: plan.title,
            style: plan.style
        )
        let request = MusicJobRequest(prompt: plan.style, lyrics: plan.lyrics, seconds: clamped, chatId: target.server)
        await start(kind: .music, meta: meta, request: request, target: target, cid: cid, rawText: userText)
        if let notice = plan.notice { present(notice(lang)) }
    }

    /// A re-roll. Identical inputs are the same cache key on the server, so the prompt has to
    /// change or the user is handed back the picture they already have (`server-media.md §6.8`).
    func regenerate(_ creationID: String) async {
        guard let item = creation(id: creationID) else { return }
        let attempt = MediaPromptPipeline.rerollAttempt(in: item.meta.prompt) + 1
        let conversation = item.conversationID.isEmpty ? nil : item.conversationID

        switch item.kind {
        case .image:
            guard requireMember(.image), !isSubmitting else { return }
            setSubmitting(true)
            defer { setSubmitting(false) }
            let prompt = MediaPromptPipeline.rerolled(item.meta.prompt, attempt: attempt)
            let shape = ImageShape.matching(width: item.meta.w, height: item.meta.h)
            let target = await resolveConversation(conversation)
            let cid = IDs.cid()
            let meta = MediaMeta(kind: .image, prompt: prompt, w: shape.width, h: shape.height)
            let request = ImageJobRequest(prompt: prompt, w: shape.width, h: shape.height, chatId: target.server)
            await start(kind: .image, meta: meta, request: request, target: target, cid: cid, rawText: prompt)

        case .video:
            guard requireMember(.video), !isSubmitting else { return }
            setSubmitting(true)
            defer { setSubmitting(false) }
            let prompt = MediaPromptPipeline.rerolled(item.meta.prompt, attempt: attempt)
            let seconds = min(max(item.meta.seconds ?? videoDefaultSeconds, 2), 30)
            let target = await resolveConversation(conversation)
            let cid = IDs.cid()
            let meta = MediaMeta(kind: .video, prompt: prompt, seconds: seconds)
            let request = VideoJobRequest(prompt: prompt, seconds: seconds, image: nil, chatId: target.server)
            await start(kind: .video, meta: meta, request: request, target: target, cid: cid, rawText: prompt)

        case .music:
            guard requireMember(.music), !isSubmitting else { return }
            setSubmitting(true)
            defer { setSubmitting(false) }
            let style = MediaPromptPipeline.rerolled(item.meta.prompt, attempt: attempt)
            let words = item.meta.lyrics ?? ""
            let seconds = min(max(item.meta.seconds ?? 150, 10), 150)
            let target = await resolveConversation(conversation)
            let cid = IDs.cid()
            let meta = MediaMeta(
                kind: .music,
                prompt: style,
                seconds: seconds,
                lyrics: words,
                title: item.meta.title
            )
            let request = MusicJobRequest(prompt: style, lyrics: words, seconds: seconds, chatId: target.server)
            await start(kind: .music, meta: meta, request: request, target: target, cid: cid, rawText: item.meta.title ?? style)
        }
    }

    /* THE CARD BEFORE THE PLANNING CALL. Every path here opened with a live model round trip
       — translate the prompt into English, plan the song's style and words — and only once it
       returned did it file the creation and write the fence. So the reader pressed send and
       watched nothing at all happen for those seconds. The card goes up first, carrying the
       reader's own words, and the planned metadata replaces it where it stands: the cid is the
       same, so `upsert` addresses the same creation and `appendAssistantTurn` the same row.
       A keyless fence is what all three cards already read as "rendering", which is exactly
       what this is. */
    private func placeCard(
        kind: MediaKind,
        meta: MediaMeta,
        target: (local: String, server: String?),
        cid: String
    ) async {
        upsert(
            MediaCreation(
                id: "media:" + cid,
                ownerID: session.identityID ?? "",
                kind: kind,
                meta: meta,
                conversationID: target.local,
                messageID: nil,
                createdAt: Date(),
                phase: .queued
            )
        )
        await chat.appendAssistantTurn(
            ChatMessage(
                id: ChatMessage.identity(role: .assistant, cid: cid),
                role: .assistant,
                content: meta.encodedFence(),
                tier: ModelTier.pro.rawValue,
                lang: lang.rawValue,
                cid: cid,
                mode: "auto",
                status: .streaming
            ),
            in: target.local
        )
    }

    // MARK: - Starting the job

    /// Files the creation, persists it, then starts the job — pointer first, always, so a crash
    /// between the two cannot orphan a render the user is still being charged for.
    private func start(
        kind: MediaKind,
        meta: MediaMeta,
        request: any Encodable & Sendable,
        target: (local: String, server: String?),
        cid: String,
        rawText: String
    ) async {
        let owner = session.identityID ?? ""
        let creationID = "media:" + cid
        let draftCreation = MediaCreation(
            id: creationID,
            ownerID: owner,
            kind: kind,
            meta: meta,
            conversationID: target.local,
            messageID: nil,
            createdAt: Date(),
            phase: .queued
        )
        upsert(draftCreation)
        /* THE COVER, ON THE FRAME THE READER ASKS. The finished fence is written by `land()`,
           which runs when the job is over — so without this the transcript held a question and
           nothing else for the whole render, and the app looked as though it had not heard.
           The fence is the same one `land()` writes, minus the key; all three cards already read
           a keyless fence as "rendering" and draw their cover from the prompt inside it. */
        await chat.appendAssistantTurn(
            ChatMessage(
                id: ChatMessage.identity(role: .assistant, cid: cid),
                role: .assistant,
                content: meta.encodedFence(),
                tier: ModelTier.pro.rawValue,
                lang: lang.rawValue,
                cid: cid,
                mode: "auto",
                status: .streaming
            ),
            in: target.local
        )
        await persistIndex()

        let spec = JobKindSpecs.spec(kind.jobKind)
        let started = Date()
        let draft = JobPointer(
            id: creationID,
            kind: kind.jobKind,
            ownerID: owner,
            cid: cid,
            conversationID: target.local,
            serverChatID: target.server,
            assistantMessageID: ChatMessage.identity(role: .assistant, cid: cid),
            projectID: nil,
            creationID: creationID,
            title: String(rawText.prefix(120)),
            lang: lang.rawValue,
            startedAt: started,
            deadline: started.addingTimeInterval(spec.deadline),
            lastPhase: .queued
        )

        do {
            let pointer = try await jobs.startMediaJob(kind: kind, request: request, pointer: draft)
            if var live = creation(id: creationID) {
                live.jobID = pointer.id
                if live.phase.isLive { live.phase = pointer.lastPhase }
                upsert(live)
                await persistIndex()
            }
            clearFailure()
        } catch {
            if var live = creation(id: creationID) {
                live.phase = .failed
                live.errorCode = (error as? APIError)?.server?.code
                upsert(live)
                await persistIndex()
            }
            presentFailure(error, kind: kind)
        }
    }

    /// Empty prompts never reach the wire: the server answers `400 bad_request` and the user
    /// learns nothing from it.
    private func requirePrompt(_ text: String) -> Bool {
        guard text.isEmpty else { return true }
        present(Strings.Media.promptRequired(lang))
        return false
    }
}
