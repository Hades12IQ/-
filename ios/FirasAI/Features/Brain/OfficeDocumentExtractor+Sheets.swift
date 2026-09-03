import Foundation

/// One sheet as `workbook.xml` names it, still pointing at its relationship id.
struct OfficeSheetReference: Sendable, Equatable {
    let name: String
    let relationshipID: String
}

// MARK: - Excel

/// `xl/workbook.xml` → sheet names with their relationship ids, plus the 1904 date epoch flag.
final class OfficeWorkbookCollector: NSObject, XMLParserDelegate {

    private(set) var sheets: [OfficeSheetReference] = []
    private(set) var usesDate1904 = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch OfficeXML.local(elementName) {
        case "workbookPr":
            let flag = OfficeXML.attribute(attributeDict, "date1904") ?? "0"
            usesDate1904 = flag == "1" || flag.lowercased() == "true"
        case "sheet":
            let name = OfficeXML.attribute(attributeDict, "name") ?? ""
            let relationship = attributeDict["r:id"] ?? OfficeXML.attribute(attributeDict, "id") ?? ""
            sheets.append(
                OfficeSheetReference(
                    name: String(name.prefix(80)),
                    relationshipID: relationship
                )
            )
        default:
            break
        }
    }
}

/// `xl/sharedStrings.xml` → one entry per `<si>`, with every `<t>` run inside it joined.
final class OfficeSharedStringCollector: NSObject, XMLParserDelegate {

    private let itemLimit: Int
    private let characterLimit: Int
    private var insideItem = false
    private var capturing = false
    private var current = ""
    private var used = 0
    private(set) var items: [String] = []

    init(itemLimit: Int, characterLimit: Int) {
        self.itemLimit = itemLimit
        self.characterLimit = characterLimit
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch OfficeXML.local(elementName) {
        case "si":
            insideItem = true
            current = ""
        case "t":
            capturing = insideItem
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
        case "si":
            if items.count < itemLimit { items.append(current) }
            insideItem = false
            current = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturing, used < characterLimit else { return }
        let accepted = String(string.prefix(characterLimit - used))
        current += accepted
        used += accepted.count
    }
}

/// `xl/styles.xml` → which cell formats render a date, so a serial number is not indexed as
/// `45217` when the sheet shows `2023-10-05`.
final class OfficeStylesCollector: NSObject, XMLParserDelegate {

    private static let builtinDateFormats: Set<Int> = [
        14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47,
    ]

    private var customFormats: [Int: String] = [:]
    private var inCellXfs = false
    private var formatIDs: [Int] = []

    /// Style indices (`c/@s`) whose number format is a date or a time.
    private(set) var dateStyleIndices: Set<Int> = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch OfficeXML.local(elementName) {
        case "numFmt":
            if let raw = OfficeXML.attribute(attributeDict, "numFmtId"), let id = Int(raw) {
                customFormats[id] = OfficeXML.attribute(attributeDict, "formatCode") ?? ""
            }
        case "cellXfs":
            inCellXfs = true
        case "xf":
            guard inCellXfs else { return }
            let raw = OfficeXML.attribute(attributeDict, "numFmtId") ?? "0"
            formatIDs.append(Int(raw) ?? 0)
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
        guard OfficeXML.local(elementName) == "cellXfs" else { return }
        inCellXfs = false
        for (index, formatID) in formatIDs.enumerated() {
            if Self.builtinDateFormats.contains(formatID) {
                dateStyleIndices.insert(index)
            } else if let code = customFormats[formatID], Self.isDateCode(code) {
                dateStyleIndices.insert(index)
            }
        }
    }

    /// True when the format code still contains a date or time token once literals, bracketed
    /// sections and escapes are removed.
    static func isDateCode(_ code: String) -> Bool {
        var stripped = ""
        var inQuotes = false
        var inBrackets = false
        var escaped = false
        for character in code {
            if escaped { escaped = false; continue }
            switch character {
            case "\\": escaped = true
            case "\"": inQuotes.toggle()
            case "[": inBrackets = true
            case "]": inBrackets = false
            default:
                if !inQuotes && !inBrackets { stripped.append(character) }
            }
        }
        let lowered = stripped.lowercased()
        for token in ["d", "m", "y", "h", "s"] where lowered.contains(token) { return true }
        return false
    }
}

/// One worksheet: rows rebuilt from cell references so an empty cell stays empty, cells joined
/// by ` | `, shared strings resolved and date-styled numbers rendered as dates.
final class OfficeWorksheetCollector: NSObject, XMLParserDelegate {

    private let sharedStrings: [String]
    private let dateStyles: Set<Int>
    private let usesDate1904: Bool
    private let rowLimit: Int
    private let cellLimit: Int
    private let characterLimit: Int

    private var cells: [String] = []
    private var cellType = ""
    private var cellReference = ""
    private var cellStyle = -1
    private var value = ""
    private var capturing = false
    private var inlineText = false

    private var rowCount = 0
    private var cellCount = 0
    private var used = 0

    private(set) var rows: [String] = []
    private(set) var truncated = false

    init(
        sharedStrings: [String],
        dateStyles: Set<Int>,
        usesDate1904: Bool,
        rowLimit: Int,
        cellLimit: Int,
        characterLimit: Int
    ) {
        self.sharedStrings = sharedStrings
        self.dateStyles = dateStyles
        self.usesDate1904 = usesDate1904
        self.rowLimit = rowLimit
        self.cellLimit = cellLimit
        self.characterLimit = characterLimit
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch OfficeXML.local(elementName) {
        case "row":
            cells.removeAll(keepingCapacity: true)
        case "c":
            cellType = OfficeXML.attribute(attributeDict, "t") ?? ""
            cellReference = OfficeXML.attribute(attributeDict, "r") ?? ""
            cellStyle = Int(OfficeXML.attribute(attributeDict, "s") ?? "") ?? -1
            value = ""
        case "is":
            inlineText = true
        case "v":
            capturing = true
        case "t":
            capturing = true
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
        case "v", "t":
            capturing = false
        case "is":
            inlineText = false
        case "c":
            appendCell()
        case "row":
            flushRow()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { value += string }
    }

    // MARK: - Private

    private func appendCell() {
        guard rowCount < rowLimit, cellCount < cellLimit else {
            truncated = true
            return
        }
        if let column = Self.columnIndex(from: cellReference), column < 512 {
            while cells.count < column { cells.append("") }
        }
        cells.append(String(resolved().prefix(4_000)))
        cellCount += 1
    }

    private func resolved() -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        if cellType == "s", !inlineText, let index = Int(clean),
           sharedStrings.indices.contains(index) {
            return sharedStrings[index]
        }
        if cellType == "b" { return clean == "1" ? "TRUE" : "FALSE" }
        if cellType == "str" || cellType == "inlineStr" || inlineText { return clean }
        if cellStyle >= 0, dateStyles.contains(cellStyle), let serial = Double(clean) {
            return OfficeSerialDate.render(serial: serial, uses1904: usesDate1904) ?? clean
        }
        return clean
    }

    private func flushRow() {
        guard rowCount < rowLimit, used < characterLimit else {
            truncated = true
            cells.removeAll(keepingCapacity: true)
            return
        }
        while cells.last?.isEmpty == true { cells.removeLast() }
        let line = cells.joined(separator: " | ").trimmingCharacters(in: .whitespaces)
        cells.removeAll(keepingCapacity: true)
        rowCount += 1
        guard !line.isEmpty else { return }
        let accepted = String(line.prefix(max(0, characterLimit - used)))
        if accepted.count < line.count { truncated = true }
        guard !accepted.isEmpty else { return }
        rows.append(accepted)
        used += accepted.count + 1
    }

    /// `"BC17"` → 54. Returns nil for a reference the file did not carry.
    static func columnIndex(from reference: String) -> Int? {
        let letters = reference.prefix(while: { $0.isLetter })
        guard !letters.isEmpty else { return nil }
        var result = 0
        for scalar in letters.uppercased().unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            result = result * 26 + Int(scalar.value - 64)
        }
        return max(0, result - 1)
    }
}

/// Excel serial number → `YYYY-MM-DD[ HH:MM[:SS]]`, with both epochs and the phantom
/// 29 February 1900 handled. Deliberately arithmetic: no formatter, no time zone, no locale.
enum OfficeSerialDate {

    static func render(serial: Double, uses1904: Bool) -> String? {
        guard serial.isFinite, serial >= 0, serial < 2_958_466 else { return nil }
        var days = Int(serial.rounded(.down))
        let fraction = serial - Double(days)

        // 1900 workbooks count 1 as 1900-01-01 and wrongly contain 1900-02-29 at 60.
        var epochDays: Int
        if uses1904 {
            epochDays = daysFromCivil(year: 1904, month: 1, day: 1)
        } else {
            epochDays = daysFromCivil(year: 1899, month: 12, day: 31)
            if days > 59 { days -= 1 }
            days -= 1
        }
        let (year, month, day) = civilFromDays(epochDays + days)
        let datePart = pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)

        let seconds = Int((fraction * 86_400).rounded())
        guard seconds > 0 else { return datePart }
        let hours = min(23, seconds / 3_600)
        let minutes = (seconds % 3_600) / 60
        let rest = seconds % 60
        let timePart = pad(hours, 2) + ":" + pad(minutes, 2)
        return rest == 0
            ? datePart + " " + timePart
            : datePart + " " + timePart + ":" + pad(rest, 2)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        var text = String(max(0, value))
        while text.count < width { text = "0" + text }
        return text
    }

    /// Howard Hinnant's civil calendar algorithms, days relative to 1970-01-01.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ input: Int) -> (Int, Int, Int) {
        let z = input + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }
}
