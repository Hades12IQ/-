import Foundation

/// One structural block of a Word document, in reading order.
struct OfficeBlock: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case paragraph
        case heading
        case list
        case table
    }

    let kind: Kind
    let text: String
}

/// Shared helpers for every collector below. `shouldProcessNamespaces` is off (namespace-aware
/// parsing of OOXML is slower and buys nothing), so element and attribute names arrive prefixed:
/// `w:p`, `a:t`, `r:id`. Everything is compared on the local half.
enum OfficeXML {

    static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    static func attribute(_ attributes: [String: String], _ name: String) -> String? {
        if let direct = attributes[name] { return direct }
        for (key, value) in attributes where local(key) == name { return value }
        return nil
    }

    /// Parses `data` with `delegate`. Never resolves external entities.
    static func parse(_ data: Data, with delegate: XMLParserDelegate) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        return parser.parse()
    }
}

// MARK: - Plain paragraphs (speaker notes, fallbacks)

/// Every `<*:t>` run, grouped into one line per `<*:p>`.
final class OfficeTextCollector: NSObject, XMLParserDelegate {

    private let limit: Int
    private var capturing = false
    private var current = ""
    private var used = 0
    private(set) var paragraphs: [String] = []

    init(limit: Int) {
        self.limit = limit
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch OfficeXML.local(elementName) {
        case "p": flush()
        case "t": capturing = true
        case "br", "cr": append("\n")
        case "tab": append("\t")
        default: break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch OfficeXML.local(elementName) {
        case "t": capturing = false
        case "p": flush()
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { append(string) }
    }

    private func append(_ value: String) {
        guard used < limit else { return }
        let accepted = String(value.prefix(limit - used))
        current += accepted
        used += accepted.count
    }

    private func flush() {
        let clean = current.trimmingCharacters(in: .whitespacesAndNewlines)
        current = ""
        guard !clean.isEmpty else { return }
        paragraphs.append(clean)
    }
}

// MARK: - Word

/// `word/document.xml` → ordered blocks. Headings keep their style so the section splitter can
/// turn them into labels; tables become one line per row with cells joined by ` | `; list items
/// keep a bullet so they read as a list in the indexed text.
final class OfficeDocxCollector: NSObject, XMLParserDelegate {

    private let limit: Int
    private var used = 0

    private var capturing = false
    private var skipping = false
    private var run = ""

    private var paragraphStyle: String?
    private var isListItem = false
    private var listDepth = 0

    private var tableDepth = 0
    private var cellDepth = 0
    private var cellParagraphs: [String] = []
    private var rowCells: [String] = []
    private var tableRows: [String] = []

    private(set) var blocks: [OfficeBlock] = []

    init(limit: Int) {
        self.limit = limit
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch OfficeXML.local(elementName) {
        case "tbl":
            tableDepth += 1
        case "tr":
            if tableDepth > 0 { rowCells.removeAll(keepingCapacity: true) }
        case "tc":
            if tableDepth > 0 {
                cellDepth += 1
                cellParagraphs.removeAll(keepingCapacity: true)
            }
        case "p":
            run = ""
            paragraphStyle = nil
            isListItem = false
        case "pStyle":
            paragraphStyle = OfficeXML.attribute(attributeDict, "val")
        case "numPr":
            isListItem = true
        case "ilvl":
            if let raw = OfficeXML.attribute(attributeDict, "val"), let level = Int(raw) {
                listDepth = min(4, max(0, level))
            }
        case "instrText", "delText":
            skipping = true
        case "t":
            capturing = !skipping
        case "br", "cr":
            append("\n")
        case "tab":
            append("\t")
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch OfficeXML.local(elementName) {
        case "t":
            capturing = false
        case "instrText", "delText":
            skipping = false
        case "p":
            closeParagraph()
        case "tc":
            if cellDepth > 0 {
                cellDepth -= 1
                rowCells.append(cellParagraphs.joined(separator: " "))
                cellParagraphs.removeAll(keepingCapacity: true)
            }
        case "tr":
            if tableDepth > 0 {
                while rowCells.last?.isEmpty == true { rowCells.removeLast() }
                let line = rowCells.joined(separator: " | ")
                    .trimmingCharacters(in: .whitespaces)
                rowCells.removeAll(keepingCapacity: true)
                if !line.isEmpty { tableRows.append(line) }
            }
        case "tbl":
            if tableDepth > 0 { tableDepth -= 1 }
            if tableDepth == 0, !tableRows.isEmpty {
                emit(.table, tableRows.joined(separator: "\n"))
                tableRows.removeAll(keepingCapacity: true)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { append(string) }
    }

    // MARK: - Private

    private func append(_ value: String) {
        guard used < limit else { return }
        let accepted = String(value.prefix(limit - used))
        run += accepted
        used += accepted.count
    }

    private func closeParagraph() {
        let text = run.trimmingCharacters(in: .whitespacesAndNewlines)
        run = ""
        guard !text.isEmpty else { return }

        if cellDepth > 0 {
            cellParagraphs.append(text)
            return
        }
        if isListItem {
            let indent = String(repeating: "  ", count: listDepth)
            emit(.list, indent + "- " + text)
            return
        }
        if let style = paragraphStyle, Self.isHeadingStyle(style) {
            emit(.heading, text)
            return
        }
        emit(.paragraph, text)
    }

    private func emit(_ kind: OfficeBlock.Kind, _ text: String) {
        guard !text.isEmpty else { return }
        blocks.append(OfficeBlock(kind: kind, text: text))
    }

    /// `Heading1…Heading3`, `Title` and `Subtitle` in every casing Word has ever written them.
    static func isHeadingStyle(_ style: String) -> Bool {
        let folded = style.lowercased().replacingOccurrences(of: " ", with: "")
        if folded == "title" || folded == "subtitle" { return true }
        guard folded.hasPrefix("heading") else { return false }
        let level = folded.dropFirst("heading".count)
        guard let number = Int(level) else { return level.isEmpty }
        return number >= 1 && number <= 3
    }
}

// MARK: - PowerPoint

/// One slide: its tables first (one line per row), then its text lines, with slide-number, date
/// and footer placeholders dropped and the title placeholder kept aside as the label.
final class OfficeSlideCollector: NSObject, XMLParserDelegate {

    private static let droppedPlaceholders: Set<String> = ["sldnum", "dt", "ftr"]
    private static let titlePlaceholders: Set<String> = ["title", "ctrtitle"]

    private let limit: Int
    private var used = 0

    private var capturing = false
    private var run = ""
    private var placeholder: String?
    private var inShape = false

    private var cellDepth = 0
    private var cellParagraphs: [String] = []
    private var rowCells: [String] = []
    private var tableRows: [String] = []

    private(set) var lines: [String] = []
    private(set) var tables: [String] = []
    private(set) var title: String?

    init(limit: Int) {
        self.limit = limit
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch OfficeXML.local(elementName) {
        case "sp":
            inShape = true
            placeholder = nil
        case "ph":
            placeholder = OfficeXML.attribute(attributeDict, "type")?.lowercased()
        case "tbl":
            tableRows.removeAll(keepingCapacity: true)
        case "tr":
            rowCells.removeAll(keepingCapacity: true)
        case "tc":
            cellDepth += 1
            cellParagraphs.removeAll(keepingCapacity: true)
        case "p":
            run = ""
        case "t":
            capturing = true
        case "br":
            append(" ")
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch OfficeXML.local(elementName) {
        case "t":
            capturing = false
        case "p":
            closeParagraph()
        case "tc":
            if cellDepth > 0 {
                cellDepth -= 1
                rowCells.append(cellParagraphs.joined(separator: " "))
                cellParagraphs.removeAll(keepingCapacity: true)
            }
        case "tr":
            while rowCells.last?.isEmpty == true { rowCells.removeLast() }
            let line = rowCells.joined(separator: " | ").trimmingCharacters(in: .whitespaces)
            rowCells.removeAll(keepingCapacity: true)
            if !line.isEmpty { tableRows.append(line) }
        case "tbl":
            if !tableRows.isEmpty { tables.append(tableRows.joined(separator: "\n")) }
            tableRows.removeAll(keepingCapacity: true)
        case "sp":
            inShape = false
            placeholder = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { append(string) }
    }

    // MARK: - Private

    private func append(_ value: String) {
        guard used < limit else { return }
        let accepted = String(value.prefix(limit - used))
        run += accepted
        used += accepted.count
    }

    private func closeParagraph() {
        let text = run.trimmingCharacters(in: .whitespacesAndNewlines)
        run = ""
        guard !text.isEmpty else { return }

        if cellDepth > 0 {
            cellParagraphs.append(text)
            return
        }
        if let placeholder, Self.droppedPlaceholders.contains(placeholder) { return }
        if inShape, let placeholder, Self.titlePlaceholders.contains(placeholder) {
            if title == nil { title = String(text.prefix(80)) }
        }
        lines.append(text)
    }
}

// MARK: - Package relationships

/// `_rels/*.rels` → relationship id to target, so slides and sheets are read in the order the
/// package declares rather than the order their file names happen to sort in.
final class OfficeRelationshipCollector: NSObject, XMLParserDelegate {

    private(set) var targets: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard OfficeXML.local(elementName) == "Relationship" else { return }
        guard let id = OfficeXML.attribute(attributeDict, "Id"),
              let target = OfficeXML.attribute(attributeDict, "Target")
        else { return }
        targets[id] = target
    }
}

/// `ppt/presentation.xml` → the `sldIdLst` relationship ids, in presentation order.
final class OfficePresentationCollector: NSObject, XMLParserDelegate {

    private var inList = false
    private(set) var slideRelationshipIDs: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch OfficeXML.local(elementName) {
        case "sldIdLst":
            inList = true
        case "sldId":
            // `<p:sldId id="256" r:id="rId2"/>` — the relationship id is the one that resolves.
            guard inList, let relationship = attributeDict["r:id"] else { return }
            slideRelationshipIDs.append(relationship)
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if OfficeXML.local(elementName) == "sldIdLst" { inList = false }
    }
}
