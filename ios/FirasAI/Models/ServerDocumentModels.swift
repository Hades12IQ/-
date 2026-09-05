import Foundation

struct DocumentJobImage: Encodable, Sendable, Equatable {
    let id: String
    let base64: String
}

extension FileMeta {
    /// References never control the URL: the downloader uses the fixed authenticated route.
    var hasVerifiedPDFReference: Bool {
        guard serverPdf == true, format == "pdf", let artifactId,
              Self.validArtifactID(artifactId), let sha256,
              sha256.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil,
              let pdfBytes, pdfBytes > 5, pdfBytes <= 256 * 1_024 * 1_024,
              let pages, pages > 0 else { return false }
        if partial == true {
            guard let completedItems, let expectedItems, let remainingItems,
                  completedItems > 0, expectedItems > completedItems,
                  remainingItems == expectedItems - completedItems else { return false }
        }
        return true
    }

    static func validArtifactID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{1,160}$"#, options: .regularExpression) != nil
    }

    static func document(in message: ChatMessage?) -> FileMeta? {
        guard let message else { return nil }
        return document(inContent: message.visibleContent)
    }

    static func document(inContent content: String) -> FileMeta? {
        guard let fence = FirasFence.firstFence(in: content),
              fence.name == "firas-file", case .file(let meta)? = FirasFence.parse(name: fence.name, body: fence.body) else { return nil }
        return meta
    }

    func partialLabel(_ lang: AppLanguage) -> String? {
        guard partial == true, let completedItems, let expectedItems, let remainingItems else { return nil }
        return lang == .arabic
            ? "نسخة جزئية: اكتمل \(completedItems) من \(expectedItems)، بقي \(remainingItems). اكتب «كمل» لإكمال الملف."
            : "Partial: \(completedItems) of \(expectedItems) completed; \(remainingItems) remaining. Say “continue” to finish."
    }
}

struct ServerDocumentManifest: Decodable, Sendable {
    struct PDF: Decodable, Sendable {
        let ready: Bool?
        let sha256: String?
        let bytes: Int?
        let pageCount: Int?
    }
    struct Artifact: Decodable, Sendable {
        let kind: String?
        let artifactId: String?
        let complete: Bool?
        let partial: Bool?
        let pdf: PDF?
    }
    let ok: Bool?
    let artifact: Artifact?
}

struct ServerDocumentSource: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let id: String
        let mime: String
        let base64: String
    }
    let ok: Bool?
    let sourceHtml: String
    let sourceSha256: String
    let expectedItems: Int?
    let requiresSolutions: Bool?
    let solutionsAtEnd: Bool?
    let assets: [Asset]?
}
