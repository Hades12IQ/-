import CryptoKit
import Foundation

/// Original document photographs stay outside transcript/model text. Files are isolated by
/// account and protected on disk; the bounded cache can fall back to the stored thumbnail.
actor DocumentAssetCache {
    static let shared = DocumentAssetCache()
    private let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("FirasDocumentAssets-v1", isDirectory: true)
    private let limit = 256 * 1024 * 1024
    private var signedOutOwners: Set<String> = []

    func activate(ownerID: String) { signedOutOwners.remove(ownerID) }

    func store(_ encoded: String, id: String, ownerID: String) {
        guard !signedOutOwners.contains(ownerID) else { return }
        let raw = encoded.hasPrefix("data:") ? String(encoded.split(separator: ",", maxSplits: 1).last ?? "") : encoded
        guard raw.utf8.count <= 28_000_000, let bytes = Data(base64Encoded: raw), !bytes.isEmpty,
              bytes.count <= 20_000_000, let url = file(id: id, ownerID: ownerID) else { return }
        write(bytes, to: url)
    }

    func store(_ bytes: Data, id: String, ownerID: String) {
        guard !signedOutOwners.contains(ownerID) else { return }
        guard !bytes.isEmpty, bytes.count <= 20_000_000, let url = file(id: id, ownerID: ownerID) else { return }
        write(bytes, to: url)
    }

    func data(id: String, ownerID: String) -> Data? {
        guard !signedOutOwners.contains(ownerID), let url = file(id: id, ownerID: ownerID),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 20_000_000 else { return nil }
        return try? Data(contentsOf: url)
    }

    func clear(ownerID: String) {
        signedOutOwners.insert(ownerID)
        guard let folder = folder(ownerID: ownerID),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "image" { try? FileManager.default.removeItem(at: file) }
    }

    private func write(_ bytes: Data, to url: URL) {
        do {
            var folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var flags = URLResourceValues()
            flags.isExcludedFromBackup = true
            try folder.setResourceValues(flags)
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            trim(folder)
        } catch { /* A cache failure must not discard the user's original attachment. */ }
    }

    private func folder(ownerID: String) -> URL? {
        guard !ownerID.isEmpty else { return nil }
        let hash = SHA256.hash(data: Data(ownerID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root?.appendingPathComponent(hash, isDirectory: true)
    }

    private func file(id: String, ownerID: String) -> URL? {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else { return nil }
        return folder(ownerID: ownerID)?.appendingPathComponent(id + ".image")
    }

    private func trim(_ folder: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let entries = files.filter { $0.pathExtension == "image" }.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > limit {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}

#if DEBUG
extension DocumentAssetCache {
    static func reliabilityFailures() async -> [String] {
        let firstOwner = "document-cache-smoke-" + UUID().uuidString
        let secondOwner = "document-cache-smoke-" + UUID().uuidString
        let id = "attached-original"
        let first = Data("original-pixels-a".utf8)
        let second = Data("original-pixels-b".utf8)
        var failures: [String] = []
        await shared.store(first.base64EncodedString(), id: id, ownerID: firstOwner)
        if await shared.data(id: id, ownerID: firstOwner) != first {
            failures.append("Original document image did not survive a disk roundtrip")
        }
        if await shared.data(id: id, ownerID: secondOwner) != nil {
            failures.append("Document image cache leaked across account IDs")
        }
        await shared.store(second, id: id, ownerID: secondOwner)
        await shared.clear(ownerID: firstOwner)
        await shared.store(first, id: id, ownerID: firstOwner)
        if await shared.data(id: id, ownerID: firstOwner) != nil {
            failures.append("Sign-out did not remove its original document images")
        }
        if await shared.data(id: id, ownerID: secondOwner) != second {
            failures.append("Clearing one document-image owner affected another")
        }
        await shared.activate(ownerID: firstOwner)
        if await shared.data(id: id, ownerID: firstOwner) != nil {
            failures.append("An old request rewrote original images after sign-out")
        }
        await shared.store(first, id: id, ownerID: firstOwner)
        if await shared.data(id: id, ownerID: firstOwner) != first {
            failures.append("Document image cache did not reactivate after signing in again")
        }
        await shared.clear(ownerID: firstOwner)
        await shared.clear(ownerID: secondOwner)
        return failures
    }
}
#endif
