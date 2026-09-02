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
            if let minutes = server.freesInMin { noteFreesIn(minutes) }
            return true

        case .failed(let code, _):
            markFailed(creationID, kind: kind, code: code, pointer: pointer)
            present(Strings.Media.failureText(kind, code: code, lang: lang))
            return true

        case .expired:
            // Not proof of failure: the server answers `running` forever for an id it has forgotten,
            // and the bytes may still land in its cache. The manager keeps the pointer for one more
            // look, and the tile offers a regenerate rather than pretending it is still working.
            markFailed(creationID, kind: kind, code: "timeout", pointer: pointer)
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
        let existing = chat.conversations[conversationID]?.messages ?? []
        let alreadyWritten = existing.contains(where: { $0.id == messageID })
        if !alreadyWritten {
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
        guard !isDownloading(creation.id) else { return nil }
        beginDownload(creation.id)
        defer { endDownload(creation.id) }

        do {
            let result = try await api.downloadMedia(kind: creation.kind, key: key)
            let ext = creation.kind.fileExtension(forMIME: result.mime)
            let filename = try await assets.store(temp: result.url, key: key, ext: ext)
            if var item = self.creation(id: creation.id) {
                item.localFilename = filename
                upsert(item)
                await persistIndex()
            }
            await assets.trim(keepingNewest: Self.keptAssets)
            return await assets.url(forFilename: filename)
        } catch {
            return nil
        }
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
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return source
        }
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
