import Foundation

extension ExportController {
    /// Resolve only real assets explicitly used by this design, within its own conversation.
    /// A screenshot supplied as revision feedback is never inserted unless its ID was requested.
    func resolveDocumentImages(_ markdown: String, conversationID: String?, messageID: String?) async -> String {
        guard markdown.contains("firas-asset:"), let conversationID,
              let conversation = env.chat.conversations[env.chat.resolve(conversationID)] else { return markdown }
        let owner = env.session.identityID
        let referenced = DocumentAssetInventory.referencedIDs(in: markdown)
        let entries = DocumentAssetInventory.entries(in: conversation, throughMessageID: messageID)
            .filter { referenced.contains($0.id) }
        var assets: [String: Data] = [:]
        // A server-authored source can refer to image IDs restored from its owned source bundle.
        // These original pixels have no duplicate attachment row in the local transcript.
        if let owner {
            for id in referenced.subtracting(Set(entries.map(\.id))) {
                let cached = await DocumentAssetCache.shared.data(id: id, ownerID: owner)
                guard env.session.identityID == owner else { return markdown }
                if let cached { assets[id] = cached }
            }
        }
        for entry in entries {
            guard env.session.identityID == owner else { return markdown }
            if let owner {
                let cached = await DocumentAssetCache.shared.data(id: entry.id, ownerID: owner)
                guard env.session.identityID == owner else { return markdown }
                if let cached {
                    assets[entry.id] = cached
                    continue
                }
            }
            let bytes: Data?
            switch entry.source {
            case .attached(let encoded):
                bytes = await Task.detached(priority: .userInitiated) {
                    let raw = encoded.hasPrefix("data:") ? String(encoded.split(separator: ",", maxSplits: 1).last ?? "") : encoded
                    guard raw.utf8.count <= 28_000_000 else { return Optional<Data>.none }
                    return Data(base64Encoded: raw)
                }.value
            case .generated(let key):
                do {
                    let downloaded = try await env.api.downloadMedia(kind: .image, key: key)
                    bytes = await Task.detached(priority: .userInitiated) {
                        defer { try? FileManager.default.removeItem(at: downloaded.url) }
                        guard let size = try? downloaded.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                              size > 0, size <= 20_000_000 else { return Optional<Data>.none }
                        return try? Data(contentsOf: downloaded.url)
                    }.value
                } catch { bytes = nil }
            }
            guard env.session.identityID == owner else { return markdown }
            if let bytes, !bytes.isEmpty { assets[entry.id] = bytes }
        }
        return DocumentHTML.embeddingImages(in: markdown, assets: assets)
    }
}
