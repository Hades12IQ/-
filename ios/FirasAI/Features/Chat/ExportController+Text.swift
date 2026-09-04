import Foundation

/// Everything that has to happen to markdown before it becomes a file, and the two lines the app
/// says when it cannot.
///
/// Shared with `ExportController` and its detached build task, so nothing here is isolated to an
/// actor and nothing here touches SwiftUI.
enum ExportText {

    /// `$…$`, `$$…$$`, `\(…\)`, `\[…\]` → Unicode maths, through the one scanner.
    static func flattenMath(_ markdown: String) -> String {
        let protected = MathScanner.protect(markdown)
        guard !protected.spans.isEmpty else { return markdown }
        let flattened = protected.spans.map { span -> String in
            let unicode = MathText.unicode(span)
            return unicode.isEmpty ? span : unicode
        }
        return MathScanner.restore(protected.text, spans: flattened)
    }

    /// The heading the file carries. The caller's title wins; when it has none — a single answer
    /// exported on its own — the document's first heading becomes the title rather than a file
    /// called `firas`.
    static func documentTitle(_ title: String, markdown: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let blocks = ExportMarkdown.blocks(from: String(markdown.prefix(4_000)))
        return ExportMarkdown.inferredTitle(blocks) ?? ""
    }

    /// Markdown → readable plain text: fences keep their contents, decorations go.
    static func plain(_ markdown: String) -> String {
        var output: [String] = []
        var insideFence = false

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            if insideFence {
                output.append(rawLine)
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                output.append("")
                continue
            }
            output.append(strippingInlineMarkers(strippingBlockMarkers(rawLine)))
        }

        return output.joined(separator: "\n")
    }

    private static func strippingBlockMarkers(_ line: String) -> String {
        var working = Substring(line)
        let indent = working.prefix(while: { $0 == " " || $0 == "\t" })
        working = working.dropFirst(indent.count)

        while working.first == ">" {
            working = working.dropFirst()
            if working.first == " " { working = working.dropFirst() }
        }
        if working.first == "#" {
            let hashes = working.prefix(while: { $0 == "#" })
            if hashes.count <= 6 {
                working = working.dropFirst(hashes.count)
                if working.first == " " { working = working.dropFirst() }
            }
        }
        if working.hasPrefix("- ") || working.hasPrefix("* ") || working.hasPrefix("+ ") {
            return String(indent) + "\u{2022} " + String(working.dropFirst(2))
        }
        return String(indent) + String(working)
    }

    private static func strippingInlineMarkers(_ line: String) -> String {
        var working = expandingLinks(line)
        working = working.replacingOccurrences(of: "**", with: "")
        working = working.replacingOccurrences(of: "__", with: "")
        working = working.replacingOccurrences(of: "`", with: "")
        return working
    }

    /// `[label](target)` → `label (target)`. Hand-written: a bare-slash regex literal is off in
    /// Swift 5 language mode, and `NSRegularExpression` around Arabic is a trap.
    private static func expandingLinks(_ line: String) -> String {
        guard line.contains("]("), line.contains("[") else { return line }
        var output = ""
        var rest = Substring(line)

        while let open = rest.firstIndex(of: "[") {
            output += String(rest[rest.startIndex..<open])
            let afterOpen = rest.index(after: open)
            guard afterOpen <= rest.endIndex,
                  let close = rest[afterOpen...].firstIndex(of: "]"),
                  rest.index(after: close) < rest.endIndex,
                  rest[rest.index(after: close)] == "(" else {
                output += "["
                rest = rest[afterOpen...]
                continue
            }
            let bodyStart = rest.index(close, offsetBy: 2)
            guard let paren = rest[bodyStart...].firstIndex(of: ")") else {
                output += "["
                rest = rest[afterOpen...]
                continue
            }
            let label = String(rest[afterOpen..<close])
            let target = String(rest[bodyStart..<paren])
            if label.isEmpty {
                output += target
            } else if target.isEmpty {
                output += label
            } else {
                output += label + " (" + target + ")"
            }
            rest = rest[rest.index(after: paren)...]
        }

        output += String(rest)
        return output
    }

    /// `تقرير الأداء.docx` → `تقرير الأداء`. The model routinely puts the extension in the name it
    /// chose, and `safeFilename` would otherwise weld it onto the word before appending the real
    /// one (`…docx.docx`).
    static func withoutExtension(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = trimmed.lastIndex(of: ".") else { return trimmed }
        let suffix = String(trimmed[trimmed.index(after: dot)...]).lowercased()
        let known = [
            "pdf", "docx", "doc", "xlsx", "xls", "pptx", "ppt", "csv",
            "html", "htm", "md", "markdown", "txt", "png", "jpg", "jpeg"
        ]
        guard known.contains(suffix) else { return trimmed }
        return String(trimmed[trimmed.startIndex..<dot]).trimmingCharacters(in: .whitespaces)
    }

    /// A name a file system and a share sheet both accept. Arabic letters survive.
    static func safeFilename(_ title: String) -> String {
        var output = ""
        for character in title {
            if character.isLetter || character.isNumber {
                output.append(character)
            } else if character == " " || character == "-" || character == "_" {
                output.append("-")
            }
            if output.count >= 48 { break }
        }
        while output.contains("--") {
            output = output.replacingOccurrences(of: "--", with: "-")
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "firas" : trimmed
    }

    static func temporaryURL(name: String, extension ext: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirasExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        _ = try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent(name + "." + ext, isDirectory: false)
    }

    static func byteCount(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }
}

// MARK: - Copy

/// Verbatim `exportEmpty` / `formatUnavailable` from the web STR table.
enum ExportCopy {
    static let empty = LText(ar: "لا يوجد محتوى للتصدير.", en: "Nothing to export.")
    static let unavailable = LText(
        ar: "هذا التنسيق غير متاح حاليًا.",
        en: "That format is unavailable right now."
    )

    static let writeFailed = LText(ar: "تعذر حفظ الملف. تأكد من وجود مساحة كافية ثم أعد المحاولة.",
                                  en: "The file could not be saved. Check available storage and retry.")

    static func pdfFailure(stage: String?) -> LText {
        switch stage {
        case "document-overflow":
            return LText(ar: "تعذر احتواء أحد عناصر المستند ضمن الصفحة. اطلب إعادة تنسيق العنصر العريض ثم افتح الملف.",
                         en: "A document element still exceeds the page. Ask Firas to reflow the wide element, then open the file.")
        case "missing-document-image":
            return LText(ar: "إحدى صور المستند غير متاحة. أعد إرفاقها أو اطلب استبدالها ثم افتح الملف.",
                         en: "A document image is unavailable. Attach it again or ask to replace it, then open the file.")
        case "page-limit":
            return LText(ar: "تجاوز المستند حد 500 صفحة. اطلب تقسيمه إلى ملفات أصغر.",
                         en: "The document exceeds 500 pages. Ask to split it into smaller files.")
        case "completed": return writeFailed
        default:
            return LText(ar: "تعذر تجهيز صفحات PDF على الجهاز. أبقِ التطبيق مفتوحاً وأعد المحاولة؛ محتوى المستند محفوظ.",
                         en: "The PDF pages could not be prepared on this device. Keep the app open and retry; the document source is retained.")
        }
    }
}
