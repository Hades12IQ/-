import SwiftUI

/// Fence → card. `MarkdownView` asks for one of these per `firas-*` block; returning `nil` lets it
/// fall back to a drawing or a plain code block, which is exactly what an unrecognised fence should
/// look like.
///
/// Every card is built by the `Rendering/Cards` group and receives its palette and language
/// explicitly — nothing in `Rendering/` reads the environment (`plan/Rendering.md`).
///
/// A card only draws the affordances its host wires. That is why the wiring below is long: an image
/// with no `onEdit` has no edit button, a song with no `onPlayPause` says «الأغنية غير متاحة
/// للتشغيل هنا», and a file with no `onShare` cannot be sent anywhere. The cards were finished; the
/// call site was where they were still mute.
extension AssistantTurnView {

    func fenceView(_ fence: FirasFence) -> AnyView? {
        switch fence {
        case .code(let meta, let body):
            return AnyView(codeCard(meta: meta, body: body))
        case .file(let meta):
            return AnyView(fileCard(meta))
        case .image(let meta):
            return AnyView(imageCard(meta))
        case .video(let meta):
            return AnyView(videoCard(meta))
        case .music(let meta):
            return AnyView(songCard(meta))
        case .agent(let job):
            return AnyView(agentCard(job))
        case .sources(let sources):
            return AnyView(SourcesCard(sources: sources, palette: palette, lang: lang))
        case .project(let project):
            return AnyView(
                ProjectCard(project: project, palette: palette, lang: lang, motionOn: motionOn)
            )
        case .plot(let body):
            // «عدنا رسم تو دي و ثري دي». `PromptCatalog` already promises the model a renderer for
            // ```plot, so these fences are arriving today; before this they fell through to a code
            // box. A body the grammar cannot read still falls through, which is the honest result.
            guard let spec = DiagramSpec.parse(name: "plot", body: body) else { return nil }
            return AnyView(
                DiagramCard(spec: spec, palette: palette, lang: lang, motionOn: motionOn)
            )
        case .ask:
            return nil

        case .deck(let deck):
            return AnyView(
                DeckCard(deck: deck, palette: palette, lang: lang, motionOn: motionOn)
            )
        }
    }

    // MARK: - Code

    private func codeCard(meta: CodeMeta, body: String) -> some View {
        CodeCard(
            meta: meta,
            code: body,
            palette: palette,
            lang: lang,
            isStreaming: isStreaming,
            motionOn: motionOn,
            onPreview: { _, _ in
                env.router.sheet = .codeViewer(messageID: message.id)
            },
            onContinue: {
                ChatTurnActions.continueAnswer(
                    messageID: message.id,
                    conversationID: conversationID,
                    env: env
                )
            }
        )
    }

    // MARK: - Files

    /// Two different files wear the same card.
    ///
    /// A **durable** one (`jobId`) was written by the server's long-file worker and has its own
    /// reader, which owns sharing and saving; the card only needs to open it. A **non-durable** one
    /// — the xlsx, pptx, csv, docx or html an ordinary answer promises — does not exist yet: it is
    /// built on demand from this turn's own markdown by `ExportController`, and then previewed,
    /// shared or saved. Before this wiring those two buttons were simply never drawn.
    private func fileCard(_ rawMeta: FileMeta) -> some View {
        // The ordinary `firas-file` block carries no `format` — the web reads it off the REQUEST
        // (`requestedFormatForAssistant`, app.js:3092). Without this the card could not know
        // whether it was holding a workbook or a PDF, and every export came out as a PDF.
        var meta = rawMeta
        if meta.format.trimmingCharacters(in: .whitespaces).isEmpty {
            meta.format = requestedDocumentFormat() ?? "pdf"
        }
        let durableJob = meta.jobId.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let isDurable = !durableJob.isEmpty && meta.serverPdf != true
        let readiness = documentReadiness(meta)

        // Written out rather than folded into the call: a `cond ? nil : { … }` expression is one of
        // the few places Swift's inference genuinely struggles, and nobody here can compile.
        var share: (() -> Void)?
        var saveToFiles: (() -> Void)?
        var size: Int?
        if !isDurable {
            share = { buildFile(meta, intent: .share) }
            saveToFiles = { buildFile(meta, intent: .save) }
            size = preparedFile?.byteCount ?? meta.pdfBytes
        }

        return FileCard(
            meta: meta,
            palette: palette,
            lang: lang,
            /* THE CARD MUST NOT OFFER A FILE THE ANSWER HAS NOT FINISHED DESCRIBING.
               `FileCard` grew this parameter for exactly this call and nothing was passing it,
               so it kept its default of `true` and the whole «الملف قيد التحضير…» plate was
               unreachable: Open and Save stood on a document turn for the entire minute its
               HTML design was still streaming, and pressing Open printed whatever fragment had
               landed. A DURABLE file is the one exception and keeps its Open: its bytes are on
               the server already and owe nothing to the text still arriving here. */
            isAnswerFinished: readiness.canOpen,
            sizeBytes: size,
            errorText: readiness.errorText ?? fileBuildError,
            isPreparing: isPreparingFile,
            motionOn: motionOn,
            onOpen: {
                if isDurable {
                    env.router.sheet = .longFile(jobID: durableJob)
                } else {
                    buildFile(meta, intent: .preview)
                }
            },
            onShare: share,
            onSaveToFiles: saveToFiles
        )
    }

    private func documentReadiness(_ meta: FileMeta) -> DocumentCardReadiness {
        DocumentCardReadiness.evaluate(message: message, meta: meta,
            request: DocumentCardReadiness.request(for: message.id, in: env.chat.conversation(conversationID)),
            isStreaming: isStreaming, lang: lang)
    }

    func buildFile(_ meta: FileMeta, intent: AssistantFileSheet.Intent) {
        guard !isPreparingFile, documentReadiness(meta).canOpen else { return }
        isPreparingFile = true
        fileBuildError = nil
        let buildID = UUID()
        fileBuildID = buildID
        let controller = ExportController(env: env)
        let source = ChatTurnActions.markdown(message)
        let title = conversationTitle
        let snapshot = DocumentCardSnapshot(message: message, ownerID: env.session.identityID)
        #if DEBUG
        fileCardProbe?.sourceReceived = source
        fileCardProbe?.exportStarted?()
        #endif
        Task {
            let built = await controller.document(for: meta, markdown: source, title: title,
                conversationID: conversationID, messageID: message.id)
            #if DEBUG
            fileCardProbe?.buildCompleted = true
            fileCardProbe?.diagnostics = controller.documentDiagnostics
            #endif
            let current = env.chat.conversation(conversationID)?.messages.first {
                $0.id == message.id && $0.role == .assistant
            }
            guard fileBuildID == buildID,
                  snapshot.matches(current, ownerID: env.session.identityID) else { return }
            fileBuildID = nil
            isPreparingFile = false
            guard let built else {
                fileBuildError = controller.lastError?.text(lang) ?? DocumentCardReadiness.failed(lang)
                return
            }
            preparedFile = built
            #if DEBUG
            fileCardProbe?.export = built
            #endif
            fileSheet = AssistantFileSheet.route(intent, export: built, answerFinished: true)
        }
    }

    /// The document format the user asked for in the turn this answer belongs to, or `nil` when
    /// the conversation is no longer in memory.
    func requestedDocumentFormat() -> String? {
        guard let conversation = env.chat.conversation(conversationID) else { return nil }
        guard let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else {
            return nil
        }
        return RequestClassifier.documentFormat(forAssistantAt: index, in: conversation.messages)
    }

    var conversationTitle: String {
        let stored = env.chat.conversation(conversationID)?.title
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? Strings.Chat.newChat(lang) : stored
    }

    // MARK: - Media

    private func imageCard(_ meta: MediaMeta) -> some View {
        let creation = creation(for: meta)
        return ImageCard(
            meta: meta,
            palette: palette,
            lang: lang,
            phase: imagePhase(creation),
            motionOn: motionOn,
            startedAt: startedAt(creation),
            resolveImage: { requested in await mediaFileURL(for: requested) },
            resolveShareFile: { requested in await mediaShareURL(for: requested) },
            onOpen: {
                if let creation {
                    env.router.cover = .mediaViewer(creationID: creation.id)
                }
            },
            onSave: { save(meta) },
            onEdit: { edit(meta) },
            onRegenerate: { regenerate(meta) }
        )
    }

    private func videoCard(_ meta: MediaMeta) -> some View {
        let creation = creation(for: meta)
        return VideoCard(
            meta: meta,
            palette: palette,
            lang: lang,
            phase: videoPhase(creation),
            motionOn: motionOn,
            startedAt: startedAt(creation),
            resolveFile: { requested in await mediaFileURL(for: requested) },
            resolveShareFile: { requested in await mediaShareURL(for: requested) },
            onSave: { save(meta) },
            onRegenerate: { regenerate(meta) }
        )
    }

    private func songCard(_ meta: MediaMeta) -> some View {
        let creation = creation(for: meta)
        return SongCard(
            meta: meta,
            palette: palette,
            lang: lang,
            phase: songPhase(creation),
            isPreparing: creation?.jobID == nil && creation?.phase.isLive == true,
            motionOn: motionOn,
            startedAt: startedAt(creation),
            playback: songPlayback(creation),
            resolveShareFile: { requested in await mediaShareURL(for: requested) },
            onPlayPause: { toggleSong(meta) },
            onSeek: { seconds in SongPlayer.shared.seek(to: seconds) },
            onGenerate: { regenerate(meta) },
            onRegenerate: { regenerate(meta) }
        )
    }

    private func agentCard(_ job: AgentJob) -> some View {
        AgentCard(
            job: job,
            palette: palette,
            lang: lang,
            motionOn: motionOn,
            onOpen: {
                env.router.open(.agent(conversationID: conversationID))
            }
        )
    }

    // MARK: - Media plumbing

    /// The creation this fence belongs to, if the media store has already scanned it in.
    private func creation(for meta: MediaMeta) -> MediaCreation? {
        env.media.creation(
            inConversation: env.chat.resolve(conversationID),
            messageID: message.id,
            key: meta.key
        )
    }

    /// A render that is genuinely in flight must show progress, not the timeout plate. Without a
    /// creation to read, `auto` lets the card decide from the fence alone, which is the old
    /// behaviour and still the right one for a turn restored from disk.
    private func imagePhase(_ creation: MediaCreation?) -> ImageCard.Phase {
        guard let creation else { return .auto }
        switch creation.phase {
        case .queued, .processing, .reconnecting: return .rendering
        case .failed, .expired: return .failed(code: creation.errorCode ?? "")
        case .completed, .unknown: return .auto
        }
    }

    private func videoPhase(_ creation: MediaCreation?) -> VideoCard.Phase {
        guard let creation else { return .auto }
        switch creation.phase {
        case .queued, .processing, .reconnecting: return .rendering
        case .failed, .expired: return .failed(code: creation.errorCode ?? "")
        case .completed, .unknown: return .auto
        }
    }

    private func songPhase(_ creation: MediaCreation?) -> SongCard.Phase {
        guard let creation else { return .auto }
        switch creation.phase {
        case .queued, .processing, .reconnecting: return .rendering
        case .failed, .expired: return .failed(code: creation.errorCode ?? "")
        case .completed, .unknown: return .auto
        }
    }

    private func startedAt(_ creation: MediaCreation?) -> Date? {
        guard let creation else { return nil }
        switch creation.phase {
        case .queued, .processing, .reconnecting: return creation.createdAt
        default: return nil
        }
    }

    private func songPlayback(_ creation: MediaCreation?) -> SongCard.Playback {
        let player = SongPlayer.shared
        guard let creation, player.isCurrent(creation.id) else { return SongCard.Playback() }
        return SongCard.Playback(
            isPlaying: player.isPlaying,
            isLoading: player.isLoading,
            elapsed: player.currentTime,
            duration: player.duration
        )
    }

    private func mediaFileURL(for meta: MediaMeta) async -> URL? {
        guard let creation = creation(for: meta) else { return nil }
        return await env.media.localURL(for: creation)
    }

    /// The same bytes as `mediaFileURL`, but under a name built from the prompt rather than from
    /// the SHA-1 cache key — which is what the reader sees in the share sheet.
    private func mediaShareURL(for meta: MediaMeta) async -> URL? {
        guard let creation = creation(for: meta) else { return nil }
        return await env.media.shareFile(for: creation)
    }

    private func toggleSong(_ meta: MediaMeta) {
        guard let creation = creation(for: meta) else { return }
        let media = env.media
        let tts = env.tts
        let id = creation.id
        Task {
            guard let url = await media.localURL(for: creation) else { return }
            await SongPlayer.shared.toggle(id: id, url: url, tts: tts)
        }
    }

    private func save(_ meta: MediaMeta) {
        guard let creation = creation(for: meta) else { return }
        let media = env.media
        let id = creation.id
        Task { _ = await media.saveToPhotos(id) }
    }

    private func regenerate(_ meta: MediaMeta) {
        guard let creation = creation(for: meta) else { return }
        let media = env.media
        let id = creation.id
        Task { await media.regenerate(id) }
    }

    /// The create form reads `pendingEditSourceID` once and opens on the edit tab with this picture
    /// already chosen as the source — the same handoff `MediaViewer` uses.
    private func edit(_ meta: MediaMeta) {
        guard let creation = creation(for: meta) else { return }
        env.media.pendingEditSourceID = creation.id
        env.router.switchTo(product: .studio)
    }
}
