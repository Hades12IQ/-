import SwiftUI

/// Fence → card. `MarkdownView` asks for one of these per `firas-*` block; returning `nil` lets it
/// fall back to a plain code block, which is exactly what an unknown fence should look like.
///
/// Every card is built by the `Rendering/Cards` group and receives its palette and language
/// explicitly — nothing in `Rendering/` reads the environment (`plan/Rendering.md`).
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
            return AnyView(SongCard(meta: meta, palette: palette, lang: lang, motionOn: motionOn))
        case .agent(let job):
            return AnyView(agentCard(job))
        case .sources(let sources):
            return AnyView(SourcesCard(sources: sources, palette: palette, lang: lang))
        case .project, .ask, .plot:
            return nil
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

    private func fileCard(_ meta: FileMeta) -> some View {
        FileCard(
            meta: meta,
            palette: palette,
            lang: lang,
            motionOn: motionOn,
            onOpen: {
                if let jobID = meta.jobId, !jobID.isEmpty {
                    env.router.sheet = .longFile(jobID: jobID)
                }
            }
        )
    }

    // MARK: - Media

    private func imageCard(_ meta: MediaMeta) -> some View {
        ImageCard(
            meta: meta,
            palette: palette,
            lang: lang,
            motionOn: motionOn,
            resolveImage: { requested in await mediaFileURL(for: requested) },
            onOpen: {
                if let creation = creation(for: meta) {
                    env.router.cover = .mediaViewer(creationID: creation.id)
                }
            },
            onSave: { save(meta) },
            onRegenerate: { regenerate(meta) }
        )
    }

    private func videoCard(_ meta: MediaMeta) -> some View {
        VideoCard(
            meta: meta,
            palette: palette,
            lang: lang,
            motionOn: motionOn,
            resolveFile: { requested in await mediaFileURL(for: requested) },
            onSave: { save(meta) }
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
        env.media.creations.first { candidate in
            candidate.meta.key == meta.key && !meta.key.isEmpty
        }
    }

    private func mediaFileURL(for meta: MediaMeta) async -> URL? {
        guard let creation = creation(for: meta) else { return nil }
        return await env.media.localURL(for: creation)
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
}
