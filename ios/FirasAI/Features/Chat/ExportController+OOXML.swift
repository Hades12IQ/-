import Foundation
import OSLog
import ZIPFoundation

/// The zip container every Office format shares, plus the string helpers that keep generated XML
/// well formed.
///
/// A `.docx`, `.xlsx` and `.pptx` are all one thing: a zip of XML parts. This writes the parts to a
/// staging directory and zips it with the archiver the app already ships — no new dependency, and
/// the same call `CodeExport` uses for a project download.
///
/// Everything here is pure and free of any actor; a 200-page document is a megabyte of XML to build
/// and none of it belongs on the main thread.
///
/// Every XML string in this group is assembled with `+=` rather than one long `+` chain. That is
/// not style: a twenty-term concatenation of string literals is the classic way to make the Swift
/// type checker give up on a file nobody can compile locally.
enum ExportOOXML {

    /// One part of the package: `word/document.xml`, `xl/worksheets/sheet1.xml`, …
    struct Part: Sendable {
        let path: String
        let xml: String

        init(_ path: String, _ xml: String) {
            self.path = path
            self.xml = xml
        }
    }

    /// Stages the parts on disk and zips them into `url`. Returns `false` on any file-system
    /// failure — the caller turns that into the web's `formatUnavailable` toast.
    static func write(parts: [Part], to url: URL) -> Bool {
        guard !parts.isEmpty else { return false }
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("firas-ooxml-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: staging) }

        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            for part in parts {
                let destination = staging.appendingPathComponent(part.path, isDirectory: false)
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(part.xml.utf8).write(to: destination, options: .atomic)
            }
            try? manager.removeItem(at: url)
            try manager.zipItem(at: staging, to: url, shouldKeepParent: false)
            return manager.fileExists(atPath: url.path)
        } catch {
            Log.ui.error("ooxml package failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Text

    /// XML text content. The five predefined entities plus every control character an engine's
    /// answer may carry — one raw `\u{0B}` makes Word refuse to open the file at all.
    static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count + 16)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\n", "\t":
                out.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 { continue }
                if scalar.value >= 0xFFFE && scalar.value <= 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// A single line of XML text: newlines and tabs collapse to spaces.
    static func escapeInline(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return escape(flattened)
    }

    /// True when the text is predominantly Arabic (or another right-to-left script), which is what
    /// decides `w:bidi`, a sheet's `rightToLeft` flag and a slide's paragraph direction.
    ///
    /// Dominant script, not first strong character: `"Next.js وتحسين الأداء"` is an Arabic line, and
    /// a first-strong test flips it on one leading Latin word.
    static func isRightToLeft(_ text: String) -> Bool {
        isRightToLeft(text, fallback: false)
    }

    /// The same question asked of one paragraph rather than of a document.
    ///
    /// `fallback` is what a block with no strong character in it gets — a row of figures, a page
    /// number, a bare URL. Those have no opinion, and answering `false` for them is how a single
    /// numeric line in an Arabic document flips itself, and its bullet, to the wrong edge.
    static func isRightToLeft(_ text: String, fallback: Bool) -> Bool {
        var rtl = 0
        var ltr = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                rtl += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F:
                ltr += 1
            default:
                continue
            }
        }
        guard rtl > 0 || ltr > 0 else { return fallback }
        return rtl > ltr
    }

    /// One `ExportBlock`'s own direction. Code and rules take the document's, always: a code sample
    /// is left to right in every language, and a rule has nothing to be a direction about.
    static func isRightToLeft(_ block: ExportBlock, fallback: Bool) -> Bool {
        switch block {
        case .heading(_, let spans), .paragraph(let spans), .bullet(_, let spans),
             .numbered(_, _, let spans), .quote(let spans):
            return isRightToLeft(ExportMarkdown.plain(spans), fallback: fallback)
        case .table(let header, let rows):
            var sample = header.joined(separator: " ")
            for row in rows.prefix(8) {
                sample += " "
                sample += row.joined(separator: " ")
            }
            return isRightToLeft(sample, fallback: fallback)
        case .code, .rule:
            return fallback
        }
    }

    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    static let relationshipsNamespace =
        "http://schemas.openxmlformats.org/package/2006/relationships"

    static let officeRelationships =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// One `<Relationships>` part out of `(id, type, target)` triples.
    static func relationships(_ entries: [(String, String, String)]) -> String {
        var out = declaration
        out += "<Relationships xmlns=\""
        out += relationshipsNamespace
        out += "\">"
        for entry in entries {
            out += "<Relationship Id=\""
            out += entry.0
            out += "\" Type=\""
            out += entry.1
            out += "\" Target=\""
            out += entry.2
            out += "\"/>"
        }
        out += "</Relationships>"
        return out
    }

    /// `docProps/core.xml` — the title and author a file inspector shows.
    static func coreProperties(title: String) -> String {
        let now = timestamp()
        var out = declaration
        out += "<cp:coreProperties"
        out += " xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\""
        out += " xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
        out += " xmlns:dcterms=\"http://purl.org/dc/terms/\""
        out += " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
        out += "<dc:title>"
        out += escapeInline(title)
        out += "</dc:title>"
        out += "<dc:creator>Firas AI</dc:creator>"
        out += "<cp:lastModifiedBy>Firas AI</cp:lastModifiedBy>"
        out += "<dcterms:created xsi:type=\"dcterms:W3CDTF\">"
        out += now
        out += "</dcterms:created>"
        out += "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">"
        out += now
        out += "</dcterms:modified>"
        out += "</cp:coreProperties>"
        return out
    }

    /// ISO-8601 in UTC, written by hand so no formatter locale can turn the digits Arabic-Indic —
    /// a `dcterms:created` with `٢٠٢٦` in it is a corrupt package.
    static func timestamp() -> String {
        var calendar = Calendar(identifier: .gregorian)
        if let zone = TimeZone(identifier: "UTC") { calendar.timeZone = zone }
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date()
        )
        func pad(_ value: Int?, _ width: Int) -> String {
            var text = String(max(0, value ?? 0))
            while text.count < width { text = "0" + text }
            return text
        }
        var out = pad(parts.year, 4)
        out += "-"
        out += pad(parts.month, 2)
        out += "-"
        out += pad(parts.day, 2)
        out += "T"
        out += pad(parts.hour, 2)
        out += ":"
        out += pad(parts.minute, 2)
        out += ":"
        out += pad(parts.second, 2)
        out += "Z"
        return out
    }
}
