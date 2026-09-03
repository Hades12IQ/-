import Foundation
import Photos

/// The half of `MediaStore` that runs after the render is out of the app's hands: terminal
/// delivery, writing the fence into the conversation, fetching the bytes with the session cookie,
/// and handing a file to Photos or the share sheet.
///
/// `JobManager` calls `job(_:didFinish:)` on the main actor **before** it forgets the pointer, and
/// the boolean answer is what says "the result is safely in the model". Everything here returns
/// `true` only once the fence is in the conversation.
extension MediaStore {

    // MARK: - JobObserver

    func job(_ pointer: JobPointer, didProgress snapshot: JobSnapshot) {
        guard let id = pointer.creationID, var item = creation(id: id) else { return }
        guard item.phase != snapshot.phase else { return }
        item.phase = snapshot.phase
        upsert(item)
    }

    func job(_ pointer: JobPointer, didFinish terminal: JobTerminal) async -> Bool {
        guard let kind = pointer.kind.mediaKind else { return false }
        let creationID = pointer.creationID ?? ("media:" + pointer.cid)

        switch terminal {
        case .completed(let snapshot):
            let key = (snapshot.mediaKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var meta = creation(id: creationID)?.meta ?? MediaMeta(kind: kind, prompt: pointer.title)
            meta.kind = kind
            meta.key = key.isEmpty ? pointer.id : key
            meta.jobId = nil
            await land(
                meta: meta,
                kind: kind,
                conversationID: pointer.conversationID,
                cid: pointer.cid,
                creationID: creationID,
                ownerID: pointer.ownerID
            )
            return true

        case .refused(_, let server):
            markFailed(creationID, kind: kind, code: server.code, pointer: pointer)
            apply(
                ErrorPresenter.presentJobTerminal(
                    terminal,
                    kind: pointer.kind,
                    isGuest: session.isGuest,
                    lang: lang
                ),
                kind: kind
            )
            await landFailure(kind: kind, code: server.code, pointer: pointer)
            if let minutes = server.freesInMin { noteFreesIn(minutes) }
            return true

        case .failed(let code, _):
            markFailed(creationID, kind: kind, code: code, pointer: pointer)
            present(Strings.Media.failureText(kind, code: code, lang: lang))
            await landFailure(kind: kind, code: code, pointer: pointer)
            return true

        case .expired:
            // Not proof of failure: the server answers `running` forever for an id it has forgotten,
            // and the bytes may still land in its cache. The manager keeps the pointer for one more
            // look, and the tile offers a regenerate rather than pretending it is still working.
            markFailed(creationID, kind: kind, code: "timeout", pointer: pointer)
            await landFailure(kind: kind, code: "timeout", pointer: pointer)
            return true

        case .cancelled, .unauthorized, .forbidden:
            markFailed(creationID, kind: kind, code: nil, pointer: pointer)
            return true
        }
    }

    // MARK: - Landing

    /// Writes the finished render into the conversation as one assistant turn carrying the fence,
    /// then files it in the library and warms the local copy.
    ///
    /// Re-entrant on purpose: a redelivery after a relaunch must not append a second card, so the
    /// message id is derived from the turn's `cid` and checked before writing.
    func land(
        meta: MediaMeta,
        kind: MediaKind,
        conversationID: String,
        cid: String,
        creationID: String,
        ownerID: String
    ) async {
        let messageID = ChatMessage.identity(role: .assistant, cid: cid)
        /* WRITTEN UNCONDITIONALLY. `start` now puts a keyless placeholder fence here the moment
           the reader asks, so a message with this id already exists by the time the job lands —
           and the old `if !alreadyWritten` would therefore have frozen that placeholder for ever
           and never shown the finished picture. `appendAssistantTurn` replaces by id, so writing
           over it is exactly right. */
        do {
            let message = ChatMessage(
                id: messageID,
                role: .assistant,
                content: meta.encodedFence(),
                tier: ModelTier.pro.rawValue,
                lang: lang.rawValue,
                cid: cid,
                mode: "auto",
                status: .delivered
            )
            await chat.appendAssistantTurn(message, in: conversationID)
        }

        var item = creation(id: creationID) ?? MediaCreation(
            id: creationID,
            ownerID: ownerID,
            kind: kind,
            meta: meta,
            conversationID: conversationID
        )
        item.meta = meta
        item.messageID = messageID
        item.phase = .completed
        item.errorCode = nil
        upsert(item)
        await persistIndex()

        announceCompletion(kind)
        _ = await localURL(for: item)
    }

    /// A render that failed used to leave the reader with their own question and silence: the only
    /// sign was a toast, and a toast is gone by the time anyone scrolls back to the conversation.
    ///
    /// This writes ONE assistant turn carrying the Arabic sentence for the server's code, under the
    /// same derived id a success would have used — so a redelivery after a relaunch can never
    /// append it twice, and a later success for the same turn is written in its place rather than
    /// under it.
    private func landFailure(kind: MediaKind, code: String?, pointer: JobPointer) async {
        let conversationID = pointer.conversationID
        guard !conversationID.isEmpty, !pointer.cid.isEmpty else { return }
        let messageID = ChatMessage.identity(role: .assistant, cid: pointer.cid)
        /* No guard here either: `start` leaves a placeholder under this id, so refusing to write
           when one exists would leave a failed render showing a cover for ever. */

        let message = ChatMessage(
            id: messageID,
            role: .assistant,
            content: Strings.Media.failureText(kind, code: code, lang: lang),
            tier: ModelTier.pro.rawValue,
            lang: lang.rawValue,
            cid: pointer.cid,
            mode: "auto",
            status: .delivered
        )
        await chat.appendAssistantTurn(message, in: conversationID)
    }

    private func markFailed(_ creationID: String, kind: MediaKind, code: String?, pointer: JobPointer) {
        var item = creation(id: creationID) ?? MediaCreation(
            id: creationID,
            ownerID: pointer.ownerID,
            kind: kind,
            meta: MediaMeta(kind: kind, prompt: pointer.title),
            conversationID: pointer.conversationID
        )
        item.phase = code == "timeout" ? .expired : .failed
        item.errorCode = code
        upsert(item)
        Task { [weak self] in
            await self?.persistIndex()
        }
    }

    private func noteFreesIn(_ minutes: Int) {
        present(Strings.Media.quotaFreesIn.fmt(lang, ArabicText.count(minutes, lang)))
    }

    /// The success line. Images additionally print the remaining allowance, which is the only place
    /// the user ever learns the number.
    private func announceCompletion(_ kind: MediaKind) {
        guard kind == .image, let quota = imageQuota, let limit = quota.limit, limit > 0 else {
            toasts.show(Strings.Media.createdText(kind)(lang))
            return
        }
        let remaining = max(0, (quota.remaining ?? limit) - 1)
        toasts.show(
            Strings.Media.imageRemaining.fmt(
                lang,
                ArabicText.count(remaining, lang),
                ArabicText.count(limit, lang)
            )
        )
    }

    // MARK: - Bytes

    /// The local file for a creation, downloading it once if this device has not seen it.
    ///
    /// Never a `Data` round trip: `APIClient.download` streams to a temp file and the repository
    /// moves it, so a 200 MB clip costs no memory. Image bytes need the member cookie, which is
    /// exactly why nothing here ever hands a raw URL to `AsyncImage`.
    func localURL(for creation: MediaCreation) async -> URL? {
        if let filename = creation.localFilename, await assets.exists(filename: filename) {
            return await assets.url(forFilename: filename)
        }
        let key = creation.meta.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        /* THE BYTES MAY ALREADY BE ON THIS DEVICE UNDER THEIR OWN NAME. A render is filed as
           `<key>.<ext>`, so the file can be found from the fence alone — which is all a creation
           adopted from a reopened conversation has. Without this the app went back to the network
           for a picture it was already holding, and the reader watched a cover for it. */
        if let held = await storedFile(forKey: key, kind: creation.kind) {
            remember(filename: held.filename, for: creation.id)
            return held.url
        }
        /* JOIN, do not refuse. Whoever asks second awaits the fetch already running rather than
           receiving the `nil` that also means "this failed" — the ambiguity that put a permanent
           download error over an arriving picture. */
        if let running = inFlightDownload(creation.id) {
            return await running.value
        }
        beginDownload(creation.id)
        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.performDownload(for: creation, key: key)
        }
        setInFlightDownload(creation.id, task)
        let url = await task.value
        setInFlightDownload(creation.id, nil)
        endDownload(creation.id)
        return url
    }

    /// The fetch itself. Split out so `localURL` can hand the same task to every caller.
    private func performDownload(for creation: MediaCreation, key: String) async -> URL? {
        do {
            let result = try await api.downloadMedia(kind: creation.kind, key: key)
            let ext = creation.kind.fileExtension(forMIME: result.mime)
            let filename = try await assets.store(temp: result.url, key: key, ext: ext)
            remember(filename: filename, for: creation.id)
            await assets.trim(keepingNewest: Self.keptAssets)
            return await assets.url(forFilename: filename)
        } catch {
            return nil
        }
    }

    /// The one place a local filename is written into the library — and then straight to disk,
    /// because a filename that is only in memory is a file this device will fetch again after the
    /// next launch.
    private func remember(filename: String, for creationID: String) {
        guard var item = creation(id: creationID), item.localFilename != filename else { return }
        item.localFilename = filename
        upsert(item)
        Task { [weak self] in
            await self?.persistIndex()
        }
    }

    /// The stored file for a cache key, if this device already holds it. The repository names a
    /// render after its key and picks the extension from the response's MIME, so the handful a kind
    /// can produce are tried in turn — five `fileExists` calls against a network round trip.
    private func storedFile(forKey key: String, kind: MediaKind) async -> (filename: String, url: URL)? {
        let stem = IDs.sanitizedMediaKey(key)
        guard !stem.isEmpty else { return nil }
        for ext in Self.storedExtensions(for: kind) {
            let filename = stem + "." + ext
            if await assets.exists(filename: filename) {
                return (filename, await assets.url(forFilename: filename))
            }
        }
        return nil
    }

    /// The URL to hand a share sheet.
    ///
    /// The stored file is named after its SHA-1 cache key, which is meaningless to a person, so a
    /// copy under a readable name goes to the temporary directory — the system cleans that up on
    /// its own, and the original stays where the library expects it.
    func shareFile(for creation: MediaCreation) async -> URL? {
        guard let source = await localURL(for: creation) else { return nil }
        let ext = source.pathExtension.isEmpty ? creation.kind.defaultFileExtension : source.pathExtension
        let name = Self.suggestedFilename(for: creation, ext: ext)
        return await Self.copyForSharing(source: source, named: name)
    }

    /// `nonisolated`, and off this actor entirely, because it copies the whole file.
    ///
    /// Every card asks for a share URL the moment it appears — that is how the share button comes
    /// to exist at all — and this ran on the main actor: scrolling past three clips meant three
    /// synchronous copies of tens of megabytes each, with the transcript frozen for the duration.
    nonisolated static func copyForSharing(source: URL, named name: String) async -> URL? {
        let work = Task.detached(priority: .utility) { () -> URL? in
            let manager = FileManager.default
            let destination = manager.temporaryDirectory.appendingPathComponent(name, isDirectory: false)
            if manager.fileExists(atPath: destination.path) { return destination }
            do {
                try manager.copyItem(at: source, to: destination)
                return destination
            } catch {
                return source
            }
        }
        return await work.value
    }

    /// A file name a human would recognise in Files or a share sheet: the prompt, stripped of the
    /// characters a file system refuses, capped at 50 characters (`resolveImageName`).
    nonisolated static func suggestedFilename(for creation: MediaCreation, ext: String) -> String {
        let source = creation.kind == .music
            ? (creation.meta.title ?? creation.meta.prompt)
            : creation.meta.prompt
        var cleaned = source
        for character in "\\/:*?\"<>|\n\r\t" {
            cleaned = cleaned.replacingOccurrences(of: String(character), with: " ")
        }
        cleaned = RequestClassifier.replacingMatches("\\s+", in: cleaned, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "firas-" + creation.kind.rawValue : String(cleaned.prefix(50))
        return base + "." + ext
    }

    // MARK: - Photos and sharing

    /// Add-only Photos access: the app never reads the library, so it never asks to.
    func saveToPhotos(_ creationID: String) async -> Bool {
        guard let item = creation(id: creationID) else { return false }
        guard item.kind != .music else {
            toasts.show(Strings.Media.songNotSavable(lang), isError: true)
            return false
        }
        guard let url = await localURL(for: item) else {
            toasts.show(Strings.Media.downloadFailed(lang), isError: true)
            return false
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            toasts.show(Strings.Media.photosDenied(lang), isError: true)
            return false
        }
        let resourceType: PHAssetResourceType = item.kind == .video ? .video : .photo
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: resourceType, fileURL: url, options: options)
            }
            toasts.show(Strings.Media.savedToPhotos(lang))
            return true
        } catch {
            toasts.show(Strings.Media.saveFailed(lang), isError: true)
            return false
        }
    }

    // MARK: - Editing

    /// Edits a picture already in the library. The bytes are fetched with the member cookie, so a
    /// key from any of the user's own conversations is a valid source.
    func editImage(sourceKey: String, prompt: String, in conversationID: String?) async {
        let key = IDs.sanitizedMediaKey(sourceKey)
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            present(Strings.Media.sourceMissing(lang))
            return
        }
        guard !instruction.isEmpty else {
            present(Strings.Media.promptRequired(lang))
            return
        }
        guard requireMember(.image), !isSubmitting else { return }

        do {
            let downloaded = try await api.downloadMedia(kind: .image, key: key)
            let data = (try? Data(contentsOf: downloaded.url)) ?? Data()
            try? FileManager.default.removeItem(at: downloaded.url)
            guard let encoded = await MediaPromptPipeline.editSourceBase64(from: data) else {
                present(Strings.Media.editBadImage(lang))
                return
            }
            await submitEdit(imageBase64: encoded, instruction: instruction, in: conversationID)
        } catch {
            presentFailure(error, kind: .image)
        }
    }

    /// The same edit from a photo the user just picked.
    func editImage(sourceData: Data, prompt: String, in conversationID: String?) async {
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            present(Strings.Media.promptRequired(lang))
            return
        }
        guard requireMember(.image), !isSubmitting else { return }
        guard let encoded = await MediaPromptPipeline.editSourceBase64(from: sourceData) else {
            present(Strings.Media.editBadImage(lang))
            return
        }
        await submitEdit(imageBase64: encoded, instruction: instruction, in: conversationID)
    }

    /// `POST /api/image/edit` is **synchronous** — no job, no pointer, no push — and holds the
    /// request for as long as the engine takes (up to ~3 min). Losing the answer is survivable:
    /// the result is cached under `sha1(edit|engine|prompt|sha1(source))`, so repeating the same
    /// edit is free and instant rather than a second render.
    private func submitEdit(imageBase64: String, instruction: String, in conversationID: String?) async {
        setSubmitting(true)
        defer { setSubmitting(false) }

        let target = await resolveConversation(conversationID)
        let cid = IDs.cid()
        await chat.appendUserTurn(ChatMessage.user(instruction, cid: cid, lang: lang), in: target.local)

        do {
            let response = try await api.editImage(
                ImageEditRequest(image: imageBase64, prompt: instruction, chatId: target.server)
            )
            let key = (response.key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                present(Strings.Media.editErrorText(code: response.error, lang: lang))
                return
            }
            // The stored prompt of an edited picture is the instruction, exactly as the web keeps it.
            let meta = MediaMeta(kind: .image, key: key, prompt: instruction)
            await land(
                meta: meta,
                kind: .image,
                conversationID: target.local,
                cid: cid,
                creationID: "media:" + cid,
                ownerID: session.identityID ?? ""
            )
        } catch {
            let code = (error as? APIError)?.server?.code
            present(Strings.Media.editErrorText(code: code, lang: lang))
        }
    }

    // MARK: - Removing

    /// Drops a creation from the library and deletes its bytes. The conversation turn stays: the
    /// fence is the record, and the chat owns it.
    func remove(_ creationID: String) async {
        guard let item = creation(id: creationID) else { return }
        if let filename = item.localFilename {
            await assets.delete(filename: filename)
        }
        removeCreation(creationID)
        await persistIndex()
    }

    /// Opens the conversation this creation lives in.
    func openInChat(_ creationID: String) {
        guard let item = creation(id: creationID), !item.conversationID.isEmpty else { return }
        router.cover = nil
        router.select(conversationID: item.conversationID, product: .ai)
    }
}
