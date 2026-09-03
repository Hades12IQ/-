import Foundation
import ZIPFoundation

/// Reads `.docx`, `.pptx` and `.xlsx` on the device, without shipping the original archive to a
/// third party. Only the few XML parts that carry text are inflated — a 60 MB deck with embedded
/// video costs the same as a 200 KB one — and every entry is checked for traversal, symlinks and
/// size before a single byte is read (`web-brain-ux.md §6.2`, `audit-ios-brain-media.md §B.2`).
enum OfficeDocumentExtractor {

    // MARK: - Limits

    private static let maximumArchiveBytes = 96_000_000
    private static let maximumEntryBytes: UInt64 = 64_000_000
    private static let maximumInflatedBytes: UInt64 = 160_000_000
    private static let maximumEntries = 20_000
    private static let maximumDocumentCharacters = 8_000_000

    /// Word sections: cut at a sentence end after 2 000 characters, hard cut at 4 000.
    private static let sectionCharacters = 4_000
    private static let sectionSoftFloor = 2_000
    /// Spreadsheets: one record per ~700 characters so the server's 700-char chunker keeps rows
    /// whole, with the header line repeated in each record.
    private static let rowGroupCharacters = 700
    private static let rowGroupRunt = 60
    private static let sheetRowLimit = 20_000
    private static let sheetCellLimit = 200_000
    private static let sheetCharacterLimit = 450_000
    private static let workbookCharacterLimit = 3_000_000
    private static let maximumRecords = 4_000

    /// The literal the web writes above a slide's speaker notes so a citation says where the
    /// sentence came from (`web-brain-ux.md §6.2`, PPTX).
    private static let speakerNotesLabel = "[ملاحظات المحاضر · Speaker notes]"

    // MARK: - Entry point

    static func extract(
        data: Data,
        filename: String,
        kind: BrainDocumentKind
    ) throws -> ExtractedBrainDocument {
        guard !data.isEmpty, data.count <= maximumArchiveBytes else {
            throw BrainExtractionError.unreadableDocument
        }
        let title = BrainDocumentExtractor.title(fromFilename: filename)

        let manager = FileManager.default
        let workspace = manager.temporaryDirectory
            .appendingPathComponent("FirasOffice", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: workspace) }

        let archiveURL = workspace.appendingPathComponent("document.zip")
        try data.write(to: archiveURL, options: [.atomic])

        let archive = try Archive(url: archiveURL, accessMode: .read)
        let package = try Package(archive: archive)

        switch kind {
        case .docx:
            return try word(package: package, title: title)
        case .pptx:
            return try slides(package: package, title: title)
        case .xlsx:
            return try sheets(package: package, title: title)
        case .pdf, .text, .image:
            throw BrainExtractionError.unsupportedType(kind.rawValue)
        }
    }

    // MARK: - The package

    /// Every entry of the archive as a lazy reader keyed by its normalised path. Building it walks
    /// the central directory once; nothing is inflated until a reader is called.
    private struct Package {
        let readers: [String: () throws -> Data]

        init(archive: Archive) throws {
            var readers: [String: () throws -> Data] = [:]
            var count = 0
            var inflated: UInt64 = 0

            for entry in archive {
                count += 1
                let path = Package.normalise(entry.path)
                let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
                guard count <= OfficeDocumentExtractor.maximumEntries,
                      !path.hasPrefix("/"),
                      !pieces.contains(".."),
                      entry.type != .symlink,
                      entry.uncompressedSize <= OfficeDocumentExtractor.maximumEntryBytes
                else {
                    throw BrainExtractionError.unreadableDocument
                }
                let (next, overflow) = inflated.addingReportingOverflow(entry.uncompressedSize)
                guard !overflow, next <= OfficeDocumentExtractor.maximumInflatedBytes else {
                    throw BrainExtractionError.unreadableDocument
                }
                inflated = next
                guard entry.type == .file, !path.isEmpty else { continue }
                readers[path] = {
                    var buffer = Data()
                    buffer.reserveCapacity(Int(min(entry.uncompressedSize, 8_000_000)))
                    _ = try archive.extract(entry) { chunk in buffer.append(chunk) }
                    return buffer
                }
            }
            guard count > 0 else { throw BrainExtractionError.emptyDocument }
            self.readers = readers
        }

        func data(_ path: String) -> Data? {
            guard let reader = readers[path] else { return nil }
            return try? reader()
        }

        func paths(withPrefix prefix: String, suffix: String) -> [String] {
            readers.keys
                .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
                .sorted { partIndex($0) < partIndex($1) }
        }

        private func partIndex(_ path: String) -> Int {
            let name = (path as NSString).lastPathComponent
            let digits = name.filter(\.isNumber)
            return Int(digits) ?? Int.max
        }

        static func normalise(_ path: String) -> String {
            var value = path.replacingOccurrences(of: "\\", with: "/")
            while value.hasPrefix("./") { value.removeFirst(2) }
            return value
        }
    }

    /// Resolves a relationship target against the directory of the part that declared it.
    private static func resolve(target: String, base: String) -> String {
        var value = Package.normalise(target)
        if value.hasPrefix("/") { return String(value.dropFirst()) }
        var stack = base.split(separator: "/").map(String.init)
        while value.hasPrefix("../") {
            value.removeFirst(3)
            if !stack.isEmpty { stack.removeLast() }
        }
        stack.append(contentsOf: value.split(separator: "/").map(String.init))
        return stack.joined(separator: "/")
    }

    private static func relationships(in package: Package, at path: String) -> [String: String] {
        guard let data = package.data(path) else { return [:] }
        let collector = OfficeRelationshipCollector()
        guard OfficeXML.parse(data, with: collector) else { return [:] }
        return collector.targets
    }

    // MARK: - Word

    private static func word(package: Package, title: String) throws -> ExtractedBrainDocument {
        guard let document = package.data("word/document.xml") else {
            throw BrainExtractionError.unreadableDocument
        }
        let collector = OfficeDocxCollector(limit: maximumDocumentCharacters)
        guard OfficeXML.parse(document, with: collector) else {
            throw BrainExtractionError.unreadableDocument
        }

        var blocks = collector.blocks
        if blocks.isEmpty {
            let fallback = OfficeTextCollector(limit: maximumDocumentCharacters)
            if OfficeXML.parse(document, with: fallback) {
                blocks = fallback.paragraphs.map { OfficeBlock(kind: .paragraph, text: $0) }
            }
        }
        let pages = sectionPages(from: blocks)
        guard !pages.isEmpty else { throw BrainExtractionError.emptyDocument }
        return ExtractedBrainDocument(title: title, kind: .docx, unit: .section, pages: pages)
    }

    /// A `<h1>`–`<h3>` closes the section it follows and becomes the label of the next one; a
    /// section longer than 4 000 characters is cut at the last sentence end after 2 000 and the
    /// continuation keeps the same label (`web-brain-ux.md §6.2`, DOCX).
    private static func sectionPages(from blocks: [OfficeBlock]) -> [BrainPage] {
        var pages: [BrainPage] = []
        var label: String?
        var buffer = ""

        func close() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            guard !text.isEmpty else { return }
            for piece in splitSection(text) {
                guard pages.count < maximumRecords else { return }
                pages.append(BrainPage(page: pages.count + 1, label: label, text: piece))
            }
        }

        for block in blocks {
            if block.kind == .heading {
                close()
                label = String(block.text.prefix(80))
                buffer = block.text
            } else if buffer.isEmpty {
                buffer = block.text
            } else {
                buffer += "\n" + block.text
            }
        }
        close()
        return pages
    }

    private static func splitSection(_ text: String) -> [String] {
        guard text.count > sectionCharacters else { return [text] }
        var pieces: [String] = []
        var rest = text[...]

        while !rest.isEmpty {
            guard let hardEnd = rest.index(
                rest.startIndex,
                offsetBy: sectionCharacters,
                limitedBy: rest.endIndex
            ) else {
                let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { pieces.append(tail) }
                break
            }
            let window = rest[rest.startIndex..<hardEnd]
            guard let floorIndex = window.index(
                window.startIndex,
                offsetBy: sectionSoftFloor,
                limitedBy: window.endIndex
            ) else {
                pieces.append(String(window))
                rest = rest[hardEnd...]
                continue
            }
            var cut = hardEnd
            var cursor = window.endIndex
            var found = false
            while cursor > floorIndex {
                cursor = window.index(before: cursor)
                let character = window[cursor]
                if character == "\n" {
                    cut = window.index(after: cursor)
                    found = true
                    break
                }
                if ".?!؟۔".contains(character) {
                    let after = window.index(after: cursor)
                    if after < window.endIndex, window[after].isWhitespace {
                        cut = after
                        found = true
                        break
                    }
                }
            }
            if !found { cut = hardEnd }
            let piece = rest[rest.startIndex..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            rest = rest[cut...]
            if pieces.count >= maximumRecords { break }
        }
        return pieces.isEmpty ? [text] : pieces
    }

    // MARK: - PowerPoint

    private static func slides(package: Package, title: String) throws -> ExtractedBrainDocument {
        var slidePaths: [String] = []
        if let presentation = package.data("ppt/presentation.xml") {
            let order = OfficePresentationCollector()
            if OfficeXML.parse(presentation, with: order) {
                let rels = relationships(in: package, at: "ppt/_rels/presentation.xml.rels")
                for id in order.slideRelationshipIDs {
                    guard let target = rels[id] else { continue }
                    slidePaths.append(resolve(target: target, base: "ppt"))
                }
            }
        }
        if slidePaths.isEmpty {
            slidePaths = package.paths(withPrefix: "ppt/slides/slide", suffix: ".xml")
        }
        guard !slidePaths.isEmpty else { throw BrainExtractionError.emptyDocument }

        var pages: [BrainPage] = []
        var budget = maximumDocumentCharacters

        for (position, path) in slidePaths.enumerated() {
            guard budget > 0, pages.count < maximumRecords else { break }
            guard let data = package.data(path) else { continue }
            let collector = OfficeSlideCollector(limit: min(budget, 200_000))
            guard OfficeXML.parse(data, with: collector) else { continue }

            var lines = collector.tables
            lines.append(contentsOf: collector.lines)
            var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            if let notes = speakerNotes(package: package, slidePath: path), !notes.isEmpty {
                text += (text.isEmpty ? "" : "\n\n") + speakerNotesLabel + "\n" + notes
            }
            guard !text.isEmpty else { continue }
            let accepted = String(text.prefix(budget))
            budget -= accepted.count
            pages.append(
                BrainPage(page: position + 1, label: collector.title, text: accepted)
            )
        }
        guard !pages.isEmpty else { throw BrainExtractionError.emptyDocument }
        return ExtractedBrainDocument(title: title, kind: .pptx, unit: .slide, pages: pages)
    }

    private static func speakerNotes(package: Package, slidePath: String) -> String? {
        let directory = (slidePath as NSString).deletingLastPathComponent
        let name = (slidePath as NSString).lastPathComponent
        let relsPath = directory.isEmpty
            ? "_rels/" + name + ".rels"
            : directory + "/_rels/" + name + ".rels"
        let rels = relationships(in: package, at: relsPath)
        guard let target = rels.values.first(where: { $0.contains("notesSlide") }) else {
            return nil
        }
        guard let data = package.data(resolve(target: target, base: directory)) else { return nil }
        let collector = OfficeTextCollector(limit: 60_000)
        guard OfficeXML.parse(data, with: collector) else { return nil }
        let text = collector.paragraphs.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Excel

    private static func sheets(package: Package, title: String) throws -> ExtractedBrainDocument {
        guard let workbookData = package.data("xl/workbook.xml") else {
            throw BrainExtractionError.unreadableDocument
        }
        let workbook = OfficeWorkbookCollector()
        guard OfficeXML.parse(workbookData, with: workbook) else {
            throw BrainExtractionError.unreadableDocument
        }
        let rels = relationships(in: package, at: "xl/_rels/workbook.xml.rels")

        var sharedStrings: [String] = []
        if let data = package.data("xl/sharedStrings.xml") {
            let collector = OfficeSharedStringCollector(
                itemLimit: 300_000,
                characterLimit: 4_000_000
            )
            if OfficeXML.parse(data, with: collector) { sharedStrings = collector.items }
        }

        var dateStyles: Set<Int> = []
        if let data = package.data("xl/styles.xml") {
            let collector = OfficeStylesCollector()
            if OfficeXML.parse(data, with: collector) { dateStyles = collector.dateStyleIndices }
        }

        var references = workbook.sheets
        if references.isEmpty {
            references = package.paths(withPrefix: "xl/worksheets/sheet", suffix: ".xml")
                .enumerated()
                .map { OfficeSheetReference(name: "Sheet \($0.offset + 1)", relationshipID: "") }
        }

        var pages: [BrainPage] = []
        var budget = workbookCharacterLimit
        let fallbackPaths = package.paths(withPrefix: "xl/worksheets/sheet", suffix: ".xml")

        for (position, sheet) in references.enumerated() {
            guard budget > 0, pages.count < maximumRecords else { break }
            var data: Data?
            if let target = rels[sheet.relationshipID] {
                data = package.data(resolve(target: target, base: "xl"))
            }
            if data == nil, fallbackPaths.indices.contains(position) {
                data = package.data(fallbackPaths[position])
            }
            guard let sheetData = data else { continue }

            let collector = OfficeWorksheetCollector(
                sharedStrings: sharedStrings,
                dateStyles: dateStyles,
                usesDate1904: workbook.usesDate1904,
                rowLimit: sheetRowLimit,
                cellLimit: sheetCellLimit,
                characterLimit: min(budget, sheetCharacterLimit)
            )
            guard OfficeXML.parse(sheetData, with: collector) else { continue }
            guard !collector.rows.isEmpty else { continue }

            let label = sheet.name.isEmpty ? "Sheet \(position + 1)" : sheet.name
            var records = rowGroups(collector.rows)
            if collector.truncated, var last = records.last {
                last += "\n… [+more rows not indexed]"
                records[records.count - 1] = last
            }
            for record in records {
                guard budget > 0, pages.count < maximumRecords else { break }
                let accepted = String(record.prefix(budget))
                budget -= accepted.count
                pages.append(BrainPage(page: position + 1, label: label, text: accepted))
            }
        }
        guard !pages.isEmpty else { throw BrainExtractionError.emptyDocument }
        return ExtractedBrainDocument(title: title, kind: .xlsx, unit: .sheet, pages: pages)
    }

    /// Rows packed into ~700-character records that all carry the header line, so a citation from
    /// the middle of a sheet still shows what its columns mean. A trailing runt is folded back.
    private static func rowGroups(_ rows: [String]) -> [String] {
        guard let header = rows.first else { return [] }
        let repeatsHeader = header.count * 3 <= rowGroupCharacters
        var records: [String] = []
        var current = ""

        func flush() {
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !text.isEmpty else { return }
            records.append(text)
        }

        for (index, row) in rows.enumerated() {
            let opener = (repeatsHeader && index > 0) ? header + "\n" + row : row
            if current.isEmpty {
                current = opener
            } else if current.count + 1 + row.count > rowGroupCharacters {
                flush()
                current = opener
            } else {
                current += "\n" + row
            }
        }
        flush()

        if records.count > 1, let last = records.last, last.count < rowGroupRunt {
            records.removeLast()
            records[records.count - 1] += "\n" + last
        }
        return records
    }
}
