import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// One import: what the composer will send, plus how much of the source actually fitted.
///
/// `percentSent` is 100 unless the file was cut; the chip uses it for the web's
/// `الملف كبير — أُرسل نحو {pct}٪ …` notice.
struct ChatAttachmentImport: Sendable, Equatable {
    let attachment: PreparedAttachment
    let percentSent: Int
}

/// Why an import was refused. Every case carries the web's verbatim toast.
enum ChatAttachmentError: Error, Equatable, Sendable {
    case unreadableImage
    case unreadableFile
    case unsupportedFile
    case emptyFile

    var message: LText {
        switch self {
        case .unreadableImage: return Strings.Composer.unreadableImage
        case .unreadableFile: return Strings.Composer.unreadableFile
        case .unsupportedFile: return Strings.Composer.unsupportedFile
        case .emptyFile: return Strings.Composer.emptyFile
        }
    }
}

/// Turns a picked photo, camera shot or document into a `PreparedAttachment`, entirely off the main
/// actor (`audit-ios-chat.md §Major M15–M16`).
///
/// Images are downsampled through ImageIO — never `UIImage(data:)` on a 48 MP original — and encoded
/// as raw base64 JPEG **without** a `data:` prefix, because that is what `/api/chat` expects for
/// `images[]`. Only the thumbnail is a data URL, and it is the only piece that is ever persisted.
enum ChatAttachmentProcessor {

    // MARK: - Limits (web: `app.js:35893-36234`)

    static let maxImages = 10
    static let maxFiles = 5
    static let maxFileCharacters = 120_000
    static let maxTotalFileCharacters = 300_000
    /// `LENM_HARD_CHARS` — past this a saved message may be cut server-side.
    static let hardComposerCharacters = 200_000

    /// Longest edge of the image that goes to the model, and the JPEG quality it is re-encoded at.
    private static let maxImageEdge: CGFloat = 2_048
    private static let imageQuality: CGFloat = 0.82
    /// Above this the image is re-encoded smaller: a 10-image turn must still be sendable.
    private static let maxImageBase64Characters = 260_000
    private static let thumbnailEdge: CGFloat = 256
    private static let thumbnailQuality: CGFloat = 0.7
    private static let maxThumbnailCharacters = 300_000
    private static let maxPDFPages = 60
    private static let maxRawFileBytes = 24_000_000

    // MARK: - Picker configuration

    /// Everything the web's `accept` attribute allows, expressed as UTTypes.
    static let acceptedFileTypes: [UTType] = {
        var types: [UTType] = [
            .image, .pdf, .plainText, .text, .sourceCode, .json, .xml, .html,
            .commaSeparatedText, .tabSeparatedText, .rtf
        ]
        let extras = [
            "docx", "pptx", "xlsx", "xlsm", "md", "markdown", "yml", "yaml", "toml",
            "ini", "log", "tex", "srt", "vtt", "swift", "ts", "tsx", "jsx", "py",
            "java", "kt", "go", "rs", "rb", "php", "cs", "sql", "sh"
        ]
        for ext in extras {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }()

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "xml", "yml", "yaml",
        "html", "htm", "css", "scss", "less", "js", "jsx", "mjs", "cjs", "ts", "tsx",
        "py", "java", "c", "h", "cpp", "cc", "hpp", "cs", "go", "rs", "rb", "php",
        "swift", "kt", "kts", "sql", "sh", "bash", "zsh", "ini", "toml", "cfg",
        "conf", "env", "log", "tex", "srt", "vtt", "rtf", "svg"
    ]

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif"
    ]

    static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// `brainKindTag` — the two- or three-letter tag on a file chip.
    static func kindTag(for kind: String) -> String {
        switch kind {
        case "pdf": return "PDF"
        case "docx": return "DOC"
        case "pptx": return "PPT"
        case "xlsx": return "XLS"
        case "image": return "IMG"
        default: return "TXT"
        }
    }

    // MARK: - Images

    static func image(data: Data, name: String) async throws -> PreparedAttachment {
        try await offMain {
            try Task.checkCancellation()
            guard !data.isEmpty else { throw ChatAttachmentError.unreadableImage }

            var edge = maxImageEdge
            var quality = imageQuality
            var jpeg = downsampledJPEG(data: data, maxEdge: edge, quality: quality)
            while let current = jpeg,
                  base64Length(of: current.count) > maxImageBase64Characters,
                  edge > 640 {
                try Task.checkCancellation()
                edge *= 0.78
                quality = max(0.5, quality - 0.06)
                jpeg = downsampledJPEG(data: data, maxEdge: edge, quality: quality)
            }
            guard let full = jpeg, !full.isEmpty else { throw ChatAttachmentError.unreadableImage }

            var thumbnail: String?
            if let thumb = downsampledJPEG(data: data, maxEdge: thumbnailEdge, quality: thumbnailQuality) {
                let encoded = "data:image/jpeg;base64," + thumb.base64EncodedString()
                if encoded.count <= maxThumbnailCharacters {
                    thumbnail = encoded
                }
            }

            return PreparedAttachment(
                name: cleanName(name.isEmpty ? "image.jpg" : name),
                kind: "image",
                text: nil,
                imageBase64: full.base64EncodedString(),
                thumbnailDataURL: thumbnail,
                byteCount: full.count,
                truncated: false
            )
        }
    }

    /// An image chosen through the Files browser rather than the photo picker. Reading and
    /// downsampling both happen off the main actor.
    static func image(url: URL) async throws -> PreparedAttachment {
        let payload = try await offMain { () -> Data in
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  !data.isEmpty,
                  data.count <= maxRawFileBytes
            else { throw ChatAttachmentError.unreadableImage }
            return data
        }
        return try await image(data: payload, name: url.lastPathComponent)
    }

    // MARK: - Documents

    /// - Parameter remainingCharacters: what is left of the 300 000-character total budget for this
    ///   turn. A file that does not fit is cut and reports the percentage that did.
    static func file(url: URL, remainingCharacters: Int) async throws -> ChatAttachmentImport {
        try await offMain {
            try Task.checkCancellation()
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            let ext = url.pathExtension.lowercased()
            let name = cleanName(url.lastPathComponent)
            let kind: String
            let raw: String

            switch ext {
            case "pdf":
                kind = "pdf"
                raw = try extractPDF(url: url)
            case "docx", "pptx", "xlsx", "xlsm":
                kind = ext == "xlsm" ? "xlsx" : ext
                raw = try extractOffice(url: url, ext: ext)
            default:
                guard textExtensions.contains(ext) || ext.isEmpty else {
                    throw ChatAttachmentError.unsupportedFile
                }
                kind = "code"
                raw = try extractText(url: url)
            }

            let clean = raw
                .replacingOccurrences(of: "\u{0000}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw ChatAttachmentError.emptyFile }
            try Task.checkCancellation()

            let total = clean.count
            let budget = max(0, min(maxFileCharacters, remainingCharacters))
            guard budget > 0 else { throw ChatAttachmentError.unsupportedFile }
            let body = total > budget ? String(clean.prefix(budget)) : clean
            let truncated = body.count < total
            let percent = total > 0
                ? max(1, min(100, Int((Double(body.count) / Double(total)) * 100.0)))
                : 100

            let attachment = PreparedAttachment(
                name: name,
                kind: kind,
                text: body,
                imageBase64: nil,
                thumbnailDataURL: nil,
                byteCount: body.utf8.count,
                truncated: truncated
            )
            return ChatAttachmentImport(attachment: attachment, percentSent: percent)
        }
    }

    // MARK: - Off-main plumbing

    private static func offMain<Output: Sendable>(
        _ operation: @escaping @Sendable () throws -> Output
    ) async throws -> Output {
        let worker = Task.detached(priority: .userInitiated) {
            try operation()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    // MARK: - Image plumbing (ImageIO, never UIImage)

    private static func downsampledJPEG(data: Data, maxEdge: CGFloat, quality: CGFloat) -> Data? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxEdge)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return encodeJPEG(image, quality: quality)
    }

    private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Data(referencing: output)
    }

    private static func base64Length(of byteCount: Int) -> Int {
        ((byteCount + 2) / 3) * 4
    }

    // MARK: - Text plumbing

    private static func extractPDF(url: URL) throws -> String {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw ChatAttachmentError.unreadableFile
        }
        var output = ""
        for index in 0 ..< min(document.pageCount, maxPDFPages) {
            guard let page = document.page(at: index),
                  let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { continue }
            output += "[Page \(index + 1)]\n" + text + "\n\n"
            if output.count >= maxFileCharacters { break }
        }
        return output
    }

    /// Office archives go through Firas Brain's extractor — the same reader, so a chat answer and a
    /// Brain citation describe the same slide or sheet (`audit-ios-chat.md §M16`).
    private static func extractOffice(url: URL, ext: String) throws -> String {
        let data = try readData(at: url)
        let kind: BrainDocumentKind
        switch ext {
        case "docx": kind = .docx
        case "pptx": kind = .pptx
        default: kind = .xlsx
        }
        guard let document = try? OfficeDocumentExtractor.extract(
            data: data,
            filename: url.lastPathComponent,
            kind: kind
        ) else {
            throw ChatAttachmentError.unreadableFile
        }

        let unit = unitLabel(for: document.unit)
        var output = ""
        for page in document.pages {
            let body = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            output += "[" + unit + " \(page.p)]\n" + body + "\n\n"
            if output.count >= maxFileCharacters { break }
        }
        guard !output.isEmpty else { throw ChatAttachmentError.emptyFile }
        return output
    }

    /// `OFFICE_UNIT` — the marker the web writes above each block.
    private static func unitLabel(for unit: BrainDocumentUnit) -> String {
        switch unit {
        case .slide: return "Slide"
        case .sheet: return "Sheet"
        case .section: return "Section"
        case .page: return "Page"
        }
    }

    private static func extractText(url: URL) throws -> String {
        let data = try readData(at: url)
        let encodings: [String.Encoding] = [
            .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .windowsCP1252, .isoLatin1
        ]
        for encoding in encodings {
            if let value = String(data: data, encoding: encoding), !value.isEmpty {
                return value
            }
        }
        throw ChatAttachmentError.unreadableFile
    }

    private static func readData(at url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw ChatAttachmentError.unreadableFile
        }
        guard !data.isEmpty, data.count <= maxRawFileBytes else {
            throw ChatAttachmentError.unreadableFile
        }
        return data
    }

    private static func cleanName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(trimmed.prefix(80))
        return clipped.isEmpty ? "file" : clipped
    }
}
