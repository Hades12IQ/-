import Foundation
import ZIPFoundation

/// Everything that turns a project into a file: the ZIP the share sheet hands over, the single
/// self-contained HTML document the preview renders, and the temporary copy Safari can open.
///
/// All of it is `nonisolated` and pure. A project is up to 180 000 characters and a ZIP walks the
/// file system, so `zip(project:fallbackName:)` runs on a detached task and never on the main
/// thread (`ARCHITECTURE.md §3.7`).
enum CodeExport {

    enum ExportError: Error, Sendable {
        case noFiles
        case writeFailed
    }

    // MARK: - ZIP

    /// `folder + "/" + path` entries inside `folder.zip`, exactly the layout the web produces.
    static func zip(project: CodeProject, fallbackName: String) async throws -> URL {
        let raw = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folderName(raw.isEmpty ? fallbackName : raw)
        let files = project.files
        guard !files.isEmpty else { throw ExportError.noFiles }
        return try await Task.detached(priority: .userInitiated) {
            try writeArchive(files: files, folder: folder)
        }.value
    }

    /// Arabic letters are kept (the web's `[^\w؀-ۿ .-]` rule); everything else — whitespace
    /// included — becomes `-`, runs collapse, and an empty result falls back to `project`.
    static func folderName(_ raw: String) -> String {
        var out = ""
        for character in raw {
            if character.isLetter || character.isNumber || character == "." || character == "-"
                || character == "_" {
                out.append(character)
            } else {
                out.append("-")
            }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        let trimmed = String(out.prefix(60))
        return trimmed.isEmpty ? "project" : trimmed
    }

    private static func writeArchive(files: [CodeFile], folder: String) throws -> URL {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("firas-code-" + UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var wrote = false
        for file in files {
            let path = file.path
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else { continue }
            let destination = directory.appendingPathComponent(path)
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(file.content.utf8).write(to: destination, options: .atomic)
            wrote = true
        }
        guard wrote else { throw ExportError.noFiles }

        let archive = root.appendingPathComponent(folder + ".zip")
        try manager.zipItem(at: directory, to: archive, shouldKeepParent: true)
        return archive
    }

    // MARK: - Temporary document

    /// Writes an assembled document so `UIApplication.open` (Safari) can read it.
    static func writeTemporaryDocument(_ html: String, name: String) throws -> URL {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("firas-preview-" + UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw ExportError.writeFailed
        }
        let url = root.appendingPathComponent(folderName(name) + ".html")
        do {
            try Data(html.utf8).write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed
        }
        return url
    }

    // MARK: - Preview assembly

    /// `projPreviewHtml`: one self-contained document. Local stylesheets become `<style>`, local
    /// classic scripts become inline `<script>`, and external (CDN) references are left alone.
    ///
    /// Returns `nil` when the project has no HTML page at all — that is the preview's empty state,
    /// not an error.
    static func previewDocument(for project: CodeProject, entryPath: String?) -> String? {
        guard let entry = entryFile(of: project, preferring: entryPath) else { return nil }
        var html = entry.content
        html = inlineStylesheets(in: html, project: project)
        html = inlineScripts(in: html, project: project)
        html = ensuringViewport(html)
        return html
    }

    static func entryFile(of project: CodeProject, preferring path: String?) -> CodeFile? {
        if let path, let match = project.files.first(where: { $0.path == normalized(path) || $0.path == path }),
           match.ext == "html" || match.ext == "htm" {
            return match
        }
        if let index = project.files.first(where: {
            let lower = $0.path.lowercased()
            return lower.hasSuffix("index.html") || lower.hasSuffix("index.htm")
        }) {
            return index
        }
        return project.files.first { $0.ext == "html" || $0.ext == "htm" }
    }

    // MARK: - Inlining

    private static func inlineStylesheets(in html: String, project: CodeProject) -> String {
        replaceMatches(
            of: "<link[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>",
            in: html
        ) { whole, reference in
            guard whole.range(of: "stylesheet", options: .caseInsensitive) != nil else { return nil }
            guard !isExternal(reference) else { return nil }
            guard let asset = findAsset(reference, ext: "css", in: project) else { return nil }
            return "<style>\n" + asset.content + "\n</style>"
        }
    }

    private static func inlineScripts(in html: String, project: CodeProject) -> String {
        replaceMatches(
            of: "<script[^>]*src\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>\\s*</script>",
            in: html
        ) { whole, reference in
            guard !isExternal(reference) else { return nil }
            let ext = reference.hasSuffix(".mjs") ? "mjs" : "js"
            guard let asset = findAsset(reference, ext: ext, in: project) else { return nil }
            let isModule = whole.range(of: "type\\s*=\\s*[\"']module[\"']", options: [.regularExpression, .caseInsensitive]) != nil
            let openTag = isModule ? "<script type=\"module\">" : "<script>"
            return openTag + "\n" + asset.content + "\n</script>"
        }
    }

    /// `cwEnsureViewport`: a full document without a viewport meta renders at desktop width on a
    /// phone, which makes every preview look broken.
    private static func ensuringViewport(_ html: String) -> String {
        guard html.range(of: "<html", options: .caseInsensitive) != nil else { return html }
        guard html.range(of: "name=\"viewport\"", options: .caseInsensitive) == nil,
              html.range(of: "name='viewport'", options: .caseInsensitive) == nil else { return html }
        let meta = "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            return html.replacingCharacters(in: head, with: String(html[head]) + "\n" + meta)
        }
        return meta + "\n" + html
    }

    // MARK: - Asset lookup

    /// Exact path, then case-insensitive path, then the same basename anywhere, then the only
    /// file of that extension in the project.
    static func findAsset(_ reference: String, ext: String, in project: CodeProject) -> CodeFile? {
        let wanted = normalized(reference)
        if let exact = project.files.first(where: { $0.path == wanted }) { return exact }
        if let insensitive = project.files.first(where: { $0.path.lowercased() == wanted.lowercased() }) {
            return insensitive
        }
        let base = basename(wanted).lowercased()
        if let sameName = project.files.first(where: { basename($0.path).lowercased() == base }) {
            return sameName
        }
        let ofKind = project.files.filter { $0.ext == ext }
        return ofKind.count == 1 ? ofKind.first : nil
    }

    static func normalized(_ reference: String) -> String {
        var path = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    static func isExternal(_ reference: String) -> Bool {
        let lower = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("//") || lower.hasPrefix("data:") || lower.hasPrefix("blob:")
    }

    private static func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// One regular-expression pass, replacing from the end so earlier ranges stay valid. The
    /// transform returns `nil` to leave a match untouched (an external CDN reference).
    private static func replaceMatches(
        of pattern: String,
        in text: String,
        transform: (_ whole: String, _ capture: String) -> String?
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            guard let whole = Range(match.range, in: text),
                  let capture = Range(match.range(at: 1), in: text) else { continue }
            guard let replacement = transform(String(text[whole]), String(text[capture])) else { continue }
            guard let target = Range(match.range, in: result) else { continue }
            result = result.replacingCharacters(in: target, with: replacement)
        }
        return result
    }
}
