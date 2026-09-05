import Foundation
import CryptoKit
import PDFKit

/// Complete PDFs use the same preview/save path as locally authored files. They never enter the
/// physical-part reader and their HTML is never reprinted on the phone.
@MainActor
enum ServerDocumentService {
    struct Download: Sendable { let url: URL; let bytes: Int; let pages: Int }
    static let unavailable = LText(ar: "تعذّر تنزيل نسخة PDF كاملة ومطابقة. الملف محفوظ على الخادم؛ حاول فتحه مرة أخرى.",
        en: "The PDF could not be downloaded and verified. It remains on the server; try opening it again.")

    static func download(meta: FileMeta, api: APIClient, owner: String?,
                         currentOwner: () -> String?) async throws -> Download {
        guard owner != nil, currentOwner() == owner, meta.hasVerifiedPDFReference,
              let id = meta.artifactId else { throw APIError.cancelled }
        let manifest = try await api.json(.get, "/api/chat/job/file", query: ["id": id], as: ServerDocumentManifest.self)
        guard currentOwner() == owner, !Task.isCancelled else { throw APIError.cancelled }
        guard manifest.ok == true, let artifact = manifest.artifact,
              artifact.artifactId == id,
              artifact.kind == "counteddoc" || artifact.kind == "documentexport",
              artifact.complete == true || meta.partial == true,
              let pdf = artifact.pdf, pdf.ready == true,
              pdf.sha256?.lowercased() == meta.sha256?.lowercased(), pdf.bytes == meta.pdfBytes,
              pdf.pageCount == meta.pages else { throw APIError.decoding("document_integrity") }
        let downloaded = try await api.download("/api/chat/job/file", query: ["id": id, "binary": "pdf"])
        defer { try? FileManager.default.removeItem(at: downloaded.url) }
        guard currentOwner() == owner, !Task.isCancelled else { throw APIError.cancelled }
        let verified = try await Task.detached(priority: .userInitiated) {
            try verifyPDF(url: downloaded.url, meta: meta)
        }.value
        guard currentOwner() == owner, !Task.isCancelled else { throw APIError.cancelled }
        let ownerHash = SHA256.hash(data: Data((owner ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("firas-server-pdf/" + ownerHash, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = (meta.name ?? "Firas-document.pdf").replacingOccurrences(of: #"[^\p{L}\p{N}._ -]"#, with: "-", options: .regularExpression)
        let stem = (safe as NSString).deletingPathExtension
        let destination = directory.appendingPathComponent(UUID().uuidString + "-" + String(stem.prefix(140)) + ".pdf")
        try FileManager.default.copyItem(at: downloaded.url, to: destination)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: destination.path)
        return Download(url: destination, bytes: verified.bytes, pages: verified.pages)
    }

    nonisolated static func verifyPDF(url: URL, meta: FileMeta) throws -> (bytes: Int, pages: Int) {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes == meta.pdfBytes, meta.hasVerifiedPDFReference else { throw APIError.decoding("document_size") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var headerChecked = false
        while let chunk = try handle.read(upToCount: 512 * 1_024), !chunk.isEmpty {
            if !headerChecked {
                guard chunk.starts(with: Data("%PDF-".utf8)) else { throw APIError.decoding("document_magic") }
                headerChecked = true
            }
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == meta.sha256?.lowercased(), let pdf = PDFDocument(url: url),
              !pdf.isLocked, pdf.pageCount == meta.pages else { throw APIError.decoding("document_integrity") }
        return (bytes, pdf.pageCount)
    }

    static func source(meta: FileMeta, api: APIClient, owner: String?,
                       currentOwner: () -> String?) async throws -> ServerDocumentSource {
        guard owner != nil, currentOwner() == owner, meta.hasVerifiedPDFReference,
              let id = meta.artifactId else { throw APIError.cancelled }
        let (data, _) = try await api.raw(.get, "/api/chat/job/file", query: ["id": id, "source": "html"])
        guard currentOwner() == owner, !Task.isCancelled else { throw APIError.cancelled }
        guard data.count <= 32 * 1_024 * 1_024 else { throw APIError.decoding("document_source_too_large") }
        let source = try JSONDecoder().decode(ServerDocumentSource.self, from: data)
        let digest = SHA256.hash(data: Data(source.sourceHtml.utf8)).map { String(format: "%02x", $0) }.joined()
        guard source.ok == true, digest == source.sourceSha256.lowercased(),
              DocumentHTML.authored(in: source.sourceHtml) != nil else { throw APIError.decoding("document_source_integrity") }
        return source
    }
}
