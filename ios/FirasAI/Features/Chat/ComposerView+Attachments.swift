import SwiftUI

/// The composer's side of picking a file: limits first, then an off-main import per item, then the
/// tray row flips from `reading` to `ready`. Nothing is ever processed on the main actor, and a
/// refusal always says which limit it hit (`web-chat-ux.md §7.3`, `audit-ios-chat.md §M15–M16`).
extension ComposerView {

    func ingest(_ pick: ComposerAttachmentPick) {
        switch pick {
        case .images(let payloads):
            addImages(payloads)
        case .files(let urls):
            addFiles(urls)
        }
    }

    func addImages(_ payloads: [Data]) {
        let used = attachments.filter { $0.isImage }.count
        let room = ChatAttachmentProcessor.maxImages - used
        guard room > 0 else {
            toast(Strings.Composer.maxImages, error: true)
            return
        }
        if payloads.count > room {
            toast(Strings.Composer.maxImages, error: true)
        }
        for payload in payloads.prefix(room) {
            let item = ComposerAttachmentItem(name: "image.jpg", kind: "image")
            attachments.append(item)
            Task {
                do {
                    let prepared = try await ChatAttachmentProcessor.image(data: payload, name: item.name)
                    land(prepared, for: item.id, percentSent: 100)
                } catch {
                    fail(item.id, error: error)
                }
            }
        }
    }

    func addFiles(_ urls: [URL]) {
        for url in urls {
            if ChatAttachmentProcessor.isImageFile(url) {
                addImageFile(url)
            } else {
                addDocument(url)
            }
        }
    }

    func addImageFile(_ url: URL) {
        let used = attachments.filter { $0.isImage }.count
        guard used < ChatAttachmentProcessor.maxImages else {
            toast(Strings.Composer.maxImages, error: true)
            return
        }
        let item = ComposerAttachmentItem(name: url.lastPathComponent, kind: "image")
        attachments.append(item)
        Task {
            do {
                let prepared = try await ChatAttachmentProcessor.image(url: url)
                land(prepared, for: item.id, percentSent: 100)
            } catch {
                fail(item.id, error: error)
            }
        }
    }

    func addDocument(_ url: URL) {
        let documents = attachments.filter { !$0.isImage }.count
        guard documents < ChatAttachmentProcessor.maxFiles else {
            toast(Strings.Composer.maxFiles, error: true)
            return
        }
        let spent = attachments.reduce(0) { $0 + $1.textCost }
        let remaining = ChatAttachmentProcessor.maxTotalFileCharacters - spent
        guard remaining > 0 else {
            toast(Strings.Composer.filesTooLarge, error: true)
            return
        }

        let ext = url.pathExtension.lowercased()
        let kind = ext == "xlsm" ? "xlsx" : (["pdf", "docx", "pptx", "xlsx"].contains(ext) ? ext : "code")
        let item = ComposerAttachmentItem(name: url.lastPathComponent, kind: kind)
        attachments.append(item)
        Task {
            do {
                let result = try await ChatAttachmentProcessor.file(url: url, remainingCharacters: remaining)
                land(result.attachment, for: item.id, percentSent: result.percentSent)
                if result.attachment.truncated {
                    explainTruncation(percent: result.percentSent)
                }
            } catch {
                fail(item.id, error: error)
            }
        }
    }

    func land(_ prepared: PreparedAttachment, for id: UUID, percentSent: Int) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].status = .ready(prepared)
        attachments[index].percentSent = percentSent
        Haptics.attach()
    }

    func fail(_ id: UUID, error: Error) {
        attachments.removeAll { $0.id == id }
        let message = (error as? ChatAttachmentError)?.message ?? Strings.Composer.unreadableFile
        toast(message, error: true)
    }

    func remove(_ id: UUID) {
        attachments.removeAll { $0.id == id }
        Haptics.select()
    }

    func explainTruncation(_ item: ComposerAttachmentItem) {
        explainTruncation(percent: item.percentSent)
    }

    func explainTruncation(percent: Int) {
        env.toasts.show(
            Strings.Composer.truncatedFile.fmt(lang, ArabicText.count(percent, lang))
        )
    }

    func explainLength() {
        env.toasts.show(
            Strings.Composer.lengthTip.fmt(
                lang,
                ArabicText.count(ChatAttachmentProcessor.hardComposerCharacters, lang)
            )
        )
    }

}
