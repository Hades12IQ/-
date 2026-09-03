import Foundation

/// `.xlsx` and `.csv`.
///
/// A spreadsheet made out of prose is useless, so the rule is the web's: **every markdown table in
/// the answer becomes a sheet**, in order, with the heading that introduced it as the sheet's name.
/// When the answer carries no table at all the document itself becomes one sheet — heading level and
/// text in two columns — which is still a file a person can sort and filter, and is far better than
/// refusing to export.
///
/// Strings are written inline (`t="inlineStr"`), so there is no shared-strings part to keep in sync
/// and no index that can drift.
enum ExportSheets {

    private static let mainNamespace =
        "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    /// One sheet: a name, an optional header row, and the body rows.
    struct Sheet: Sendable {
        var name: String
        var header: [String]
        var rows: [[String]]
    }

    // MARK: - Building sheets out of an answer

    /// Never empty: the fallback outline sheet always exists.
    static func sheets(title: String, blocks: [ExportBlock], outlineName: String) -> [Sheet] {
        var found: [Sheet] = []
        var pendingName: String?
        var index = 0

        for block in blocks {
            switch block {
            case .heading(_, let spans):
                pendingName = ExportMarkdown.plain(spans)
            case .table(let header, let rows):
                index += 1
                let name = sheetName(
                    pendingName ?? title,
                    fallbackIndex: index,
                    taken: found.map(\.name)
                )
                found.append(Sheet(name: name, header: header, rows: rows))
                pendingName = nil
            default:
                continue
            }
        }

        guard found.isEmpty else { return found }
        let name = sheetName(outlineName, fallbackIndex: 1, taken: [])
        return [outlineSheet(blocks: blocks, name: name)]
    }

    /// The document as a two-column sheet when it holds no table.
    private static func outlineSheet(blocks: [ExportBlock], name: String) -> Sheet {
        var rows: [[String]] = []
        for block in blocks {
            switch block {
            case .heading(let level, let spans):
                rows.append(["H" + String(level), ExportMarkdown.plain(spans)])
            case .paragraph(let spans):
                rows.append(["", ExportMarkdown.plain(spans)])
            case .bullet(_, let spans):
                rows.append(["\u{2022}", ExportMarkdown.plain(spans)])
            case .numbered(_, let number, let spans):
                rows.append([String(number), ExportMarkdown.plain(spans)])
            case .quote(let spans):
                rows.append(["\u{201C}", ExportMarkdown.plain(spans)])
            case .code(let language, let body):
                for line in body.components(separatedBy: "\n") {
                    rows.append([language, line])
                }
            case .table, .rule:
                continue
            }
        }
        return Sheet(name: name, header: [], rows: rows)
    }

    /// Excel refuses `[ ] : * ? / \`, an empty name, a name over 31 characters, and duplicates.
    private static func sheetName(_ raw: String, fallbackIndex: Int, taken: [String]) -> String {
        var cleaned = ""
        for character in raw {
            if "[]:*?/\\'".contains(character) { continue }
            cleaned.append(character)
            if cleaned.count >= 28 { break }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { cleaned = "Sheet" + String(fallbackIndex) }
        var candidate = cleaned
        var suffix = 2
        while taken.contains(candidate) {
            candidate = String(cleaned.prefix(26)) + " " + String(suffix)
            suffix += 1
        }
        return candidate
    }

    // MARK: - CSV

    /// RFC 4180 with a UTF-8 BOM. The BOM is not decoration: without it Excel on Windows opens an
    /// Arabic CSV as mojibake, which is the single most common "your file is broken" report.
    static func csv(sheets: [Sheet]) -> String {
        guard let first = sheets.first else { return "" }
        var lines: [String] = []
        if !first.header.isEmpty {
            lines.append(first.header.map(field).joined(separator: ","))
        }
        for row in first.rows {
            lines.append(row.map(field).joined(separator: ","))
        }
        var out = "\u{FEFF}"
        out += lines.joined(separator: "\r\n")
        out += "\r\n"
        return out
    }

    private static func field(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard flattened.contains(",") || flattened.contains("\"") || flattened.contains(";") else {
            return flattened
        }
        var out = "\""
        out += flattened.replacingOccurrences(of: "\"", with: "\"\"")
        out += "\""
        return out
    }

    // MARK: - XLSX

    static func write(title: String, sheets: [Sheet], to url: URL) -> Bool {
        let usable = sheets.isEmpty ? [Sheet(name: "Sheet1", header: [], rows: [])] : sheets
        var sample = title
        for sheet in usable {
            sample += " "
            sample += sheet.name
            sample += " "
            sample += sheet.header.joined(separator: " ")
        }
        let rtl = ExportOOXML.isRightToLeft(sample)

        var parts: [ExportOOXML.Part] = []
        parts.append(ExportOOXML.Part("[Content_Types].xml", contentTypes(count: usable.count)))
        parts.append(ExportOOXML.Part("_rels/.rels", packageRelationships()))
        parts.append(
            ExportOOXML.Part("docProps/core.xml", ExportOOXML.coreProperties(title: title))
        )
        parts.append(ExportOOXML.Part("xl/workbook.xml", workbook(usable)))
        parts.append(
            ExportOOXML.Part(
                "xl/_rels/workbook.xml.rels",
                workbookRelationships(count: usable.count)
            )
        )
        parts.append(ExportOOXML.Part("xl/styles.xml", styles()))
        for (index, sheet) in usable.enumerated() {
            parts.append(
                ExportOOXML.Part(
                    "xl/worksheets/sheet" + String(index + 1) + ".xml",
                    worksheet(sheet, rtl: rtl)
                )
            )
        }
        return ExportOOXML.write(parts: parts, to: url)
    }

    private static func contentTypes(count: Int) -> String {
        var out = ExportOOXML.declaration
        out += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        out += "<Default Extension=\"rels\""
        out += " ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        out += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        out += "<Override PartName=\"/xl/workbook.xml\" ContentType=\""
        out += "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        out += "<Override PartName=\"/xl/styles.xml\" ContentType=\""
        out += "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        out += "<Override PartName=\"/docProps/core.xml\" ContentType=\""
        out += "application/vnd.openxmlformats-package.core-properties+xml\"/>"
        for index in 0..<max(1, count) {
            out += "<Override PartName=\"/xl/worksheets/sheet"
            out += String(index + 1)
            out += ".xml\" ContentType=\""
            out += "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        out += "</Types>"
        return out
    }

    private static func packageRelationships() -> String {
        ExportOOXML.relationships([
            ("rId1", ExportOOXML.officeRelationships + "/officeDocument", "xl/workbook.xml"),
            (
                "rId2",
                ExportOOXML.relationshipsNamespace + "/metadata/core-properties",
                "docProps/core.xml"
            )
        ])
    }

    private static func workbook(_ sheets: [Sheet]) -> String {
        var out = ExportOOXML.declaration
        out += "<workbook xmlns=\""
        out += mainNamespace
        out += "\" xmlns:r=\""
        out += ExportOOXML.officeRelationships
        out += "\"><sheets>"
        for (index, sheet) in sheets.enumerated() {
            out += "<sheet name=\""
            out += ExportOOXML.escapeInline(sheet.name)
            out += "\" sheetId=\""
            out += String(index + 1)
            out += "\" r:id=\"rId"
            out += String(index + 1)
            out += "\"/>"
        }
        out += "</sheets></workbook>"
        return out
    }

    private static func workbookRelationships(count: Int) -> String {
        var entries: [(String, String, String)] = []
        for index in 0..<max(1, count) {
            entries.append(
                (
                    "rId" + String(index + 1),
                    ExportOOXML.officeRelationships + "/worksheet",
                    "worksheets/sheet" + String(index + 1) + ".xml"
                )
            )
        }
        entries.append(
            (
                "rId" + String(max(1, count) + 1),
                ExportOOXML.officeRelationships + "/styles",
                "styles.xml"
            )
        )
        return ExportOOXML.relationships(entries)
    }

    /// Two formats: the default, and a bold one for the header row.
    private static func styles() -> String {
        var out = ExportOOXML.declaration
        out += "<styleSheet xmlns=\""
        out += mainNamespace
        out += "\">"
        out += "<fonts count=\"2\">"
        out += "<font><sz val=\"11\"/><name val=\"Calibri\"/></font>"
        out += "<font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font>"
        out += "</fonts>"
        out += "<fills count=\"2\">"
        out += "<fill><patternFill patternType=\"none\"/></fill>"
        out += "<fill><patternFill patternType=\"gray125\"/></fill>"
        out += "</fills>"
        out += "<borders count=\"1\">"
        out += "<border><left/><right/><top/><bottom/><diagonal/></border>"
        out += "</borders>"
        out += "<cellStyleXfs count=\"1\">"
        out += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>"
        out += "</cellStyleXfs>"
        out += "<cellXfs count=\"2\">"
        out += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
        out += "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>"
        out += "</cellXfs>"
        out += "</styleSheet>"
        return out
    }

    private static func worksheet(_ sheet: Sheet, rtl: Bool) -> String {
        var data = ""
        var rowNumber = 1
        if !sheet.header.isEmpty {
            data += row(sheet.header, number: rowNumber, styleIndex: 1)
            rowNumber += 1
        }
        for entry in sheet.rows {
            data += row(entry, number: rowNumber, styleIndex: 0)
            rowNumber += 1
        }

        var out = ExportOOXML.declaration
        out += "<worksheet xmlns=\""
        out += mainNamespace
        out += "\"><sheetViews><sheetView workbookViewId=\"0\""
        if rtl { out += " rightToLeft=\"1\"" }
        out += ">"
        if !sheet.header.isEmpty {
            out += "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"
        }
        out += "</sheetView></sheetViews>"
        out += "<sheetFormatPr defaultRowHeight=\"15\"/>"
        out += "<sheetData>"
        out += data
        out += "</sheetData></worksheet>"
        return out
    }

    private static func row(_ values: [String], number: Int, styleIndex: Int) -> String {
        var out = "<row r=\""
        out += String(number)
        out += "\">"
        for (index, value) in values.enumerated() {
            let reference = column(index) + String(number)
            var style = ""
            if styleIndex > 0 {
                style = " s=\"" + String(styleIndex) + "\""
            }
            if value.isEmpty {
                out += "<c r=\""
                out += reference
                out += "\""
                out += style
                out += "/>"
                continue
            }
            if let numberValue = numeric(value) {
                out += "<c r=\""
                out += reference
                out += "\""
                out += style
                out += "><v>"
                out += numberValue
                out += "</v></c>"
                continue
            }
            out += "<c r=\""
            out += reference
            out += "\""
            out += style
            out += " t=\"inlineStr\"><is><t xml:space=\"preserve\">"
            out += ExportOOXML.escapeInline(value)
            out += "</t></is></c>"
        }
        out += "</row>"
        return out
    }

    /// Only a plain Latin-digit number becomes a numeric cell. An Arabic-Indic numeral, a date, a
    /// percentage or anything with a separator stays text — a spreadsheet that silently
    /// reinterprets the answer's data is worse than one that does not.
    private static func numeric(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 15 else { return nil }
        var digits = 0
        var dots = 0
        for (index, character) in trimmed.enumerated() {
            if character.isASCII && character.isNumber {
                digits += 1
            } else if character == "." {
                dots += 1
            } else if character == "-" && index == 0 {
                continue
            } else {
                return nil
            }
        }
        guard digits > 0, dots <= 1 else { return nil }
        return trimmed
    }

    /// 0 → `A`, 25 → `Z`, 26 → `AA`. Capped at the sheet's real column limit.
    private static func column(_ index: Int) -> String {
        var value = min(max(0, index), 16_383)
        var name = ""
        repeat {
            let remainder = value % 26
            if let scalar = Unicode.Scalar(UInt32(65 + remainder)) {
                name = String(Character(scalar)) + name
            }
            value = value / 26 - 1
        } while value >= 0
        return name.isEmpty ? "A" : name
    }
}
