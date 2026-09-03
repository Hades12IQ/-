import Foundation
import CoreGraphics
import ImageIO
@preconcurrency import PDFKit
@preconcurrency import UIKit
@preconcurrency import Vision

/// One file read on this device, ready to be split into `POST /api/brain/doc` parts.
///
/// `deviceOCRPages` counts pages whose text came from **on-device** Vision. It is deliberately not
/// the same number as `serverOCRPages`: the server adds whatever arrives in `ocr` to the site-wide
/// Gemini budget (`server-brain.md §6.9`), so reporting locally recognised pages would burn a
/// shared quota for work the server never did (`web-brain-ux.md §15.1`). Only `serverOCRPages`
/// may ride on the upload.
struct ExtractedBrainDocument: Sendable, Equatable {
    let title: String
    let kind: BrainDocumentKind
    let unit: BrainDocumentUnit
    let pages: [BrainPage]
    let deviceOCRPages: Int
    let serverOCRPages: Int
    /// Pages the quality gate wanted the server to read, before the budget was applied.
    let visionWanted: Int
    /// How many of those the budget actually allowed us to try.
    let visionAttempted: Int

    init(
        title: String,
        kind: BrainDocumentKind,
        unit: BrainDocumentUnit,
        pages: [BrainPage],
        deviceOCRPages: Int = 0,
        serverOCRPages: Int = 0,
        visionWanted: Int = 0,
        visionAttempted: Int = 0
    ) {
        self.title = title
        self.kind = kind
        self.unit = unit
        self.pages = pages
        self.deviceOCRPages = deviceOCRPages
        self.serverOCRPages = serverOCRPages
        self.visionWanted = visionWanted
        self.visionAttempted = visionAttempted
    }
}

/// Why a file could not become pages. Every case has one sentence in `Strings.Brain`.
enum BrainExtractionError: Error, Sendable, Equatable {
    /// The extension is not one of the six kinds (`web-brain-ux.md §6.1`).
    case unsupportedType(String)
    /// The bytes are not the format the extension promised.
    case unreadableDocument
    /// Parsed fine, but there is no text anywhere in it.
    case emptyDocument
    /// Every page went to a reader and every reader came back empty (`app.js` `ocr_all_empty`).
    case visionEngineBusy
}

/// PDF, image and plain-text reading. Office archives are delegated to `OfficeDocumentExtractor`.
///
/// Everything here is `nonisolated` and CPU-bound on purpose: the pipeline calls it from
/// `Task.detached`, so no page is ever rasterised on the main thread.
enum BrainDocumentExtractor {

    // MARK: - Constants (web parity, `web-brain-ux.md §6.2`)

    /// `BRAIN_TEXT_PAGE_MIN` — under this many non-whitespace characters a page is a scan.
    static let textPageMinimum = 40
    /// `BRAIN_ARABIC_MIN_QUALITY` — below this the extracted Arabic decoded badly.
    static let arabicMinimumQuality = 0.62
    /// A page the readers could not fill: fewer than this many characters is "nothing".
    static let recognisedTextFloor = 20
    /// `BRAIN_OCR_EDGE` — longest edge of the rendered page handed to a reader.
    static let visionEdge: CGFloat = 2_200
    /// `BRAIN_OCR_MAX_PAGES` — hard cap on server-vision pages per document.
    static let serverVisionPageCap = 300
    /// Plain text is cut into fixed blocks so the same file always cites the same block.
    static let textBlockCharacters = 3_000
    /// The server refuses a document above this many characters (`BRAIN_MAX_CHARS_PER_DOC`).
    static let maximumDocumentCharacters = 8_000_000

    // MARK: - Kind, unit, title

    /// `brainKindOf` (app.js:85252): extension first, MIME only as a tie-breaker. Legacy
    /// `.doc/.ppt/.xls` are not supported.
    static func kind(forFilename name: String, mimeType: String? = nil) -> BrainDocumentKind? {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "docx": return .docx
        case "pptx": return .pptx
        case "xlsx", "xlsm": return .xlsx
        case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp":
            return .image
        case "txt", "md", "markdown", "text", "csv", "tsv", "json", "xml", "yml", "yaml",
             "html", "htm", "tex", "srt", "vtt", "log", "css", "js", "mjs", "ts", "tsx",
             "swift", "py", "java", "c", "h", "cpp", "hpp", "cs", "go", "rb", "php", "sh", "sql":
            return .text
        default:
            break
        }
        let mime = (mimeType ?? "").lowercased()
        if mime == "application/pdf" { return .pdf }
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("text/") { return .text }
        for token in ["json", "xml", "javascript", "typescript", "csv", "yaml", "x-sh", "x-python"]
        where mime.contains(token) {
            return .text
        }
        return nil
    }

    /// `brainUnitOf` (app.js:85262). The server never derives this — the client must send it.
    static func unit(for kind: BrainDocumentKind) -> BrainDocumentUnit {
        switch kind {
        case .pptx: return .slide
        case .xlsx: return .sheet
        case .docx: return .section
        case .pdf, .text, .image: return .page
        }
    }

    /// The file name without its extension, capped at the server's 200 characters.
    static func title(fromFilename name: String) -> String {
        let base = (name as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "document" : String(base.prefix(200))
    }

    /// Reads a picked file, holding its security-scoped access for exactly as long as the read.
    static func read(url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    // MARK: - Text

    /// Fixed 3 000-character blocks numbered from 1, unit `page` (`web-brain-ux.md §6.2`).
    static func extractText(data: Data, title: String) throws -> ExtractedBrainDocument {
        guard let decoded = decodeText(data) else { throw BrainExtractionError.unreadableDocument }
        let clean = String(decoded.prefix(maximumDocumentCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw BrainExtractionError.emptyDocument }

        let blocks = fixedBlocks(clean, limit: textBlockCharacters)
        var pages: [BrainPage] = []
        pages.reserveCapacity(blocks.count)
        for (index, block) in blocks.enumerated() {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            pages.append(BrainPage(page: index + 1, text: trimmed))
        }
        guard !pages.isEmpty else { throw BrainExtractionError.emptyDocument }
        return ExtractedBrainDocument(title: title, kind: .text, unit: .page, pages: pages)
    }

    /// UTF-8 → UTF-16 → Windows-1256 (Arabic files exported from old Windows tools) → Windows-1252.
    /// A decode that produced no Arabic and no Latin letter is treated as a failure rather than
    /// indexed as mojibake.
    static func decodeText(_ data: Data) -> String? {
        var candidates: [String.Encoding] = [.utf8, .utf16]
        if let arabic = windowsArabicEncoding { candidates.append(arabic) }
        candidates.append(contentsOf: [.windowsCP1252, .isoLatin1])
        for encoding in candidates {
            guard let text = String(data: data, encoding: encoding) else { continue }
            guard hasReadableLetters(text) else { continue }
            return text
        }
        return nil
    }

    /// O(n): every step advances the cursor, so a large file is walked exactly once.
    static func fixedBlocks(_ text: String, limit: Int) -> [String] {
        guard limit > 0 else { return [text] }
        var blocks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            blocks.append(String(text[start..<end]))
            start = end
        }
        return blocks.isEmpty ? [text] : blocks
    }

    // MARK: - Images

    /// One page, read on device. `serverOCRPages` stays 0: the caller may still hand
    /// `imageJPEGBase64` to the server reader when this comes back short.
    static func extractImage(data: Data, title: String) throws -> ExtractedBrainDocument {
        guard let image = cgImage(from: data) else { throw BrainExtractionError.unreadableDocument }
        let text = recognisedText(in: image)
        let pages = text.isEmpty ? [] : [BrainPage(page: 1, text: text)]
        return ExtractedBrainDocument(
            title: title,
            kind: .image,
            unit: .page,
            pages: pages,
            deviceOCRPages: text.isEmpty ? 0 : 1,
            serverOCRPages: 0,
            visionWanted: text.count < recognisedTextFloor ? 1 : 0,
            visionAttempted: 0
        )
    }

    /// A downscaled JPEG of an image file, base64 without a data-URL prefix — the shape
    /// `/api/chat` wants for a vision turn (`server-brain.md §6.9`).
    static func imageJPEGBase64(data: Data) -> String? {
        guard let image = cgImage(from: data) else { return nil }
        return jpegBase64(from: image)
    }

    // MARK: - Office

    static func extractOffice(
        data: Data,
        filename: String,
        kind: BrainDocumentKind
    ) throws -> ExtractedBrainDocument {
        do {
            return try OfficeDocumentExtractor.extract(data: data, filename: filename, kind: kind)
        } catch let error as BrainExtractionError {
            throw error
        } catch {
            throw BrainExtractionError.unreadableDocument
        }
    }

    // MARK: - PDF

    /// Text layer → on-device Vision → server vision, in that order.
    ///
    /// - `onReading` ticks every third page of the text layer pass.
    /// - `onVision` ticks once per candidate page in each reader pass.
    /// - `serverVision` is called with `(jpegBase64, pageNumber)` and returns the transcription,
    ///   or `nil` when the call failed; the pipeline owns that request so this file never touches
    ///   the network. Pages are rendered and sent three at a time.
    static func extractPDF(
        data: Data,
        title: String,
        forceVision: Bool,
        serverVisionBudget: Int,
        onReading: @Sendable (Int, Int) -> Void,
        onVision: @Sendable (Int, Int) -> Void,
        serverVision: @escaping @Sendable (String, Int) async -> String?
    ) async throws -> ExtractedBrainDocument {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw BrainExtractionError.unreadableDocument
        }
        let total = document.pageCount
        var texts = [String](repeating: "", count: total)

        for index in 0..<total {
            try Task.checkCancellation()
            if let page = document.page(at: index) {
                texts[index] = rejoinWrappedLines(page.string ?? "")
            }
            if index % 3 == 2 || index == total - 1 { onReading(index + 1, total) }
        }

        var candidates: [Int] = []
        for index in 0..<total {
            if forceVision
                || nonWhitespaceCount(texts[index]) < textPageMinimum
                || arabicQuality(texts[index]) < arabicMinimumQuality {
                candidates.append(index)
            }
        }

        var deviceRead = 0
        var serverCandidates: [Int] = []
        for (position, index) in candidates.enumerated() {
            try Task.checkCancellation()
            if let page = document.page(at: index), let image = render(page: page, edge: visionEdge) {
                let recognised = recognisedText(in: image)
                if recognised.count >= recognisedTextFloor {
                    texts[index] = recognised
                    deviceRead += 1
                } else if hasInk(image) {
                    serverCandidates.append(index)
                }
            }
            onVision(position + 1, candidates.count)
        }

        let budget = max(0, min(serverVisionPageCap, serverVisionBudget))
        let attempts = evenStride(serverCandidates, limit: budget)
        var serverRead = 0
        if !attempts.isEmpty {
            var done = 0
            var cursor = 0
            while cursor < attempts.count {
                try Task.checkCancellation()
                let slice = Array(attempts[cursor..<min(cursor + 3, attempts.count)])
                cursor += 3
                var rendered: [(index: Int, base64: String)] = []
                for index in slice {
                    guard let page = document.page(at: index),
                          let image = render(page: page, edge: visionEdge),
                          let base64 = jpegBase64(from: image)
                    else { continue }
                    rendered.append((index, base64))
                }
                let payload = rendered
                let results = await withTaskGroup(
                    of: (Int, String).self,
                    returning: [(Int, String)].self
                ) { group in
                    for item in payload {
                        group.addTask {
                            let text = await serverVision(item.base64, item.index + 1)
                            return (item.index, text ?? "")
                        }
                    }
                    var collected: [(Int, String)] = []
                    for await value in group { collected.append(value) }
                    return collected
                }
                for (index, text) in results where text.count >= recognisedTextFloor {
                    texts[index] = text
                    serverRead += 1
                }
                done += slice.count
                onVision(done, attempts.count)
            }
        }

        var pages: [BrainPage] = []
        pages.reserveCapacity(total)
        var budgetLeft = maximumDocumentCharacters
        for index in 0..<total {
            let text = texts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, budgetLeft > 0 else { continue }
            let accepted = String(text.prefix(budgetLeft))
            budgetLeft -= accepted.count
            pages.append(BrainPage(page: index + 1, text: accepted))
        }

        if pages.isEmpty {
            // A reader ran on every candidate and nothing came back: the web refuses the upload
            // with the "engine busy" sentence rather than indexing an empty document.
            if candidates.isEmpty { throw BrainExtractionError.emptyDocument }
            throw BrainExtractionError.visionEngineBusy
        }
        if !candidates.isEmpty,
           !pages.contains(where: { nonWhitespaceCount($0.text) >= recognisedTextFloor }) {
            throw BrainExtractionError.visionEngineBusy
        }

        return ExtractedBrainDocument(
            title: title,
            kind: .pdf,
            unit: .page,
            pages: pages,
            deviceOCRPages: deviceRead,
            serverOCRPages: serverRead,
            visionWanted: serverCandidates.count,
            visionAttempted: attempts.count
        )
    }

    // MARK: - Quality gate

    /// `brainArabicQuality` (app.js:84627). 1.0 is "decoded cleanly"; below 0.62 the page is
    /// re-read. Everything is a single character walk — no regular expression touches Arabic here.
    static func arabicQuality(_ text: String) -> Double {
        var arabicLetters = 0
        var characters = 0
        var doubleAlef = 0
        var brokenLam = 0
        var previous: Character?
        var beforePrevious: Character?

        for character in text {
            characters += 1
            if isArabicLetter(character) { arabicLetters += 1 }
            if character == "ا", previous == "ا" { doubleAlef += 1 }
            if character == "ل", let middle = previous, let head = beforePrevious,
               head == "ا", isArabicLetter(middle), middle != "ل" {
                brokenLam += 1
            }
            beforePrevious = previous
            previous = character
        }
        guard arabicLetters >= 60, characters > 0 else { return 1 }

        var words = 0
        var singles = 0
        var functionWords = 0
        for piece in text.split(whereSeparator: { $0.isWhitespace }) {
            words += 1
            if piece.count == 1, let only = piece.first, isArabicLetter(only) { singles += 1 }
            if Self.functionWords.contains(String(piece)) { functionWords += 1 }
        }
        guard words > 0 else { return 1 }

        var quality = 1.0
        quality -= min(0.55, 3.5 * (Double(singles) / Double(words)))
        let per1k = 1_000.0 / Double(characters)
        quality -= min(0.20, (Double(doubleAlef) * per1k) / 25.0)
        quality -= min(0.15, (Double(brokenLam) * per1k) / 25.0)
        if Double(functionWords) / Double(words) < 0.02 { quality -= 0.15 }
        return max(0, quality)
    }

    static func nonWhitespaceCount(_ text: String) -> Int {
        var count = 0
        for character in text where !character.isWhitespace { count += 1 }
        return count
    }

    // MARK: - Private

    private static let functionWords: Set<String> = [
        "في", "من", "على", "عن", "الى", "إلى", "التي", "الذي",
        "هذا", "هذه", "كان", "قال", "هو", "هي", "ما", "لا",
    ]

    private static var windowsArabicEncoding: String.Encoding? {
        let cf = CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    private static func hasReadableLetters(_ text: String) -> Bool {
        for character in text.prefix(4_000) {
            if isArabicLetter(character) { return true }
            if character.isLetter, character.isASCII { return true }
        }
        return text.isEmpty
    }

    private static func isArabicLetter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (scalar.value >= 0x0621 && scalar.value <= 0x064A)
            || (scalar.value >= 0x0671 && scalar.value <= 0x06D3)
    }

    /// `brainRejoinWrapped` without the geometry: a line is glued to the next only when it looks
    /// like a wrap — it is long for this page, it does not end on a terminator, and the next line
    /// does not open a new item. A trailing hyphen is dropped on the join.
    private static func rejoinWrappedLines(_ raw: String) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count > 1 else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }

        var widest = 0
        for line in lines { widest = max(widest, line.count) }
        guard widest >= 24 else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        let edge = Int(Double(widest) * 0.72)

        var output: [String] = []
        for line in lines {
            guard !line.isEmpty else {
                if output.last?.isEmpty == false { output.append("") }
                continue
            }
            if var previous = output.last, !previous.isEmpty,
               previous.count >= edge,
               !endsSentence(previous),
               !startsNewItem(line) {
                output.removeLast()
                if previous.hasSuffix("-") {
                    previous.removeLast()
                    output.append(previous + line)
                } else {
                    output.append(previous + " " + line)
                }
            } else {
                output.append(line)
            }
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func endsSentence(_ line: String) -> Bool {
        guard let last = line.last else { return true }
        return ".!?؟۔:;…»”\"')]".contains(last)
    }

    private static func startsNewItem(_ line: String) -> Bool {
        guard let first = line.first else { return true }
        if "-*•·".contains(first) { return true }
        if first.isNumber {
            let rest = line.dropFirst().drop(while: { $0.isNumber })
            if let next = rest.first, next == "." || next == ")" { return true }
        }
        if first.isUppercase {
            let rest = line.dropFirst()
            if let next = rest.first, next.isLowercase { return true }
        }
        return false
    }

    private static func evenStride(_ values: [Int], limit: Int) -> [Int] {
        guard limit > 0 else { return [] }
        guard values.count > limit else { return values }
        var picked: [Int] = []
        picked.reserveCapacity(limit)
        let step = Double(values.count) / Double(limit)
        for slot in 0..<limit {
            let index = min(values.count - 1, Int(Double(slot) * step))
            if picked.last != values[index] { picked.append(values[index]) }
        }
        return picked
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(visionEdge),
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return thumbnail
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func render(page: PDFPage, edge: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let longest = max(bounds.width, bounds.height)
        guard longest > 1 else { return nil }
        let scale = min(2.8, max(1, edge / longest))
        let size = CGSize(
            width: max(1, (bounds.width * scale).rounded()),
            height: max(1, (bounds.height * scale).rounded())
        )
        return page.thumbnail(of: size, for: .mediaBox).cgImage
    }

    private static func jpegBase64(from image: CGImage) -> String? {
        UIImage(cgImage: image).jpegData(compressionQuality: 0.85)?.base64EncodedString()
    }

    /// True when the rendered page has enough dark pixels to be worth another reader. A page that
    /// is blank never leaves the device, so the shared vision budget is not spent on white paper.
    private static func hasInk(_ image: CGImage) -> Bool {
        let side = 96
        let space = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 255, count: side * side)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: side,
                      height: side,
                      bitsPerComponent: 8,
                      bytesPerRow: side,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return true }
        var dark = 0
        for value in pixels where value < 216 { dark += 1 }
        return Double(dark) / Double(side * side) > 0.005
    }

    /// Vision with a language guard: a device whose installed revision does not carry Arabic
    /// throws on `perform`, so the pass is retried with automatic detection before giving up.
    private static func recognisedText(in image: CGImage) -> String {
        if let text = try? perform(on: image, languages: ["ar", "en-US"], automatic: false) {
            return text
        }
        if let text = try? perform(on: image, languages: [], automatic: true) {
            return text
        }
        return ""
    }

    private static func perform(
        on image: CGImage,
        languages: [String],
        automatic: Bool
    ) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = automatic
        if !automatic { request.recognitionLanguages = languages }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation -> String? in
            observation.topCandidates(1).first?.string
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
