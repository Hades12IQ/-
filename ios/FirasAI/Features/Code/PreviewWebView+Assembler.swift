import Foundation

/// One assembled preview: the entry document plus every project file, keyed by normalised path so
/// the scheme handler can answer `assets/x.json` and `./styles.css` alike.
struct PreviewDocument: Equatable, Sendable {
    let entry: String
    let html: String
    let files: [String: String]
}

/// The port of `projPreviewHtml` (`web-code-ux.md §5.4`).
///
/// Two deliberate differences from the web, both sanctioned by the report's "native mapping" note:
/// module scripts and relative assets are served by the `firas-proj://` scheme handler instead of
/// being rewritten into blob URLs, and the console hook is a `WKUserScript` at document start
/// rather than a string spliced in after `<head>` — it runs strictly earlier, which is what the
/// web's insertion was buying.
enum PreviewAssembler {

    static let scheme = "firas-proj"
    static let host = "project"

    /// Nonisolated and pure: the caller runs it off the main actor for a 180 000-character project.
    static func assemble(project: CodeProject, entryPath: String?) -> PreviewDocument? {
        let files = table(for: project)
        guard let entry = entry(in: files, preferred: entryPath) else { return nil }
        guard var html = files[entry] else { return nil }

        html = inlineStylesheets(html, files: files)
        html = inlineClassicScripts(html, files: files)
        html = ensureViewport(html)
        html = ensureMath(html)
        return PreviewDocument(entry: entry, html: html, files: files)
    }

    /* KATEX, BUT ONLY FOR A PAGE THAT HAS MATHEMATICS IN IT.
       A document Firas designs writes its equations as LaTeX, because the printed page
       typesets them — and the preview did not, so the reader saw the source. Same
       document, same delimiters, two different answers depending on which surface was
       looking at it.
       The gate is the whole safety of this: a preview of an ordinary web page contains no
       delimiters, so nothing at all is added and nothing about that preview can change.
       It also keeps a page whose visible text happens to say "$5" away from a renderer
       that would read it as an equation — the same trap the transcript's own scanner
       was built to avoid.
       Served from the bundle over the island's scheme, so a preview typesets with no
       network, exactly as the printed page does. */
    static func ensureMath(_ html: String) -> String {
        guard hasMathDelimiters(html) else { return html }
        let scheme = MathIslandAssets.scheme + "://katex/"
        var head = "<link rel=\"stylesheet\" href=\"" + scheme + "katex.min.css\">"
        head += "<script src=\"" + scheme + "katex.min.js\"></script>"
        head += "<script src=\"" + scheme + "mhchem.min.js\"></script>"

        /* THE SAME SCRIPT THE PRINTER USES, and it has to be the same one.
           My first version of this called `renderMathInElement`, which does not exist here: the
           auto-render extension is a separate KaTeX file and is not in `Resources/KaTeX/`. It
           would have failed silently and shown the source, which is the very thing being fixed.
           `DocumentHTML.mathAndReadyScript` walks the delimiters itself, by the app's own rules
           rather than auto-render's - a run of digits either side is currency, Arabic left over
           is a sentence - so a design PREVIEWED and the same design PRINTED typeset identically.
           A reader who proofreads one and receives the other would never forgive the difference,
           and it would be invisible until it mattered. */
        let script = DocumentHTML.mathAndReadyScript()

        if let close = html.range(of: "</head>", options: .caseInsensitive) {
            var out = html
            out.replaceSubrange(close, with: head + "</head>")
            return out + script
        }
        if let body = html.range(of: "<body", options: .caseInsensitive) {
            var out = html
            out.replaceSubrange(body, with: head + "<body")
            return out + script
        }
        return head + html + script
    }

    /// Does this page carry LaTeX delimiters at all?
    static func hasMathDelimiters(_ html: String) -> Bool {
        html.contains("$$") || html.contains("\\(") || html.contains("\\[")
    }

    /// The MIME type the scheme handler answers with.
    static func mimeType(forPath path: String) -> String {
        switch fileExtension(of: path) {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs", "cjs": return "text/javascript"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "xml": return "application/xml"
        case "csv": return "text/csv"
        default: return "text/plain"
        }
    }

    // MARK: - Files

    static func table(for project: CodeProject) -> [String: String] {
        var files: [String: String] = [:]
        for file in project.files {
            files[normalize(file.path)] = file.content
        }
        return files
    }

    /// `./x`, `/x`, `x?v=2`, `x#top` all name the same file.
    static func normalize(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        if let query = value.firstIndex(of: "?") { value = String(value[..<query]) }
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasPrefix("/") { value.removeFirst() }
        return value
    }

    static func fileExtension(of path: String) -> String {
        let name = normalize(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    static func basename(of path: String) -> String {
        let name = normalize(path)
        guard let slash = name.lastIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// Rule 1 of §5.4: the named entry, else an `index.html` at any depth, else the first page.
    static func entry(in files: [String: String], preferred: String?) -> String? {
        if let preferred {
            let normalized = normalize(preferred)
            if files[normalized] != nil, isHTML(normalized) { return normalized }
        }
        let paths = files.keys.sorted()
        if let index = paths.first(where: { basename(of: $0) == "index.html" || basename(of: $0) == "index.htm" }) {
            return index
        }
        return paths.first(where: { isHTML($0) })
    }

    static func isHTML(_ path: String) -> Bool {
        let ext = fileExtension(of: path)
        return ext == "html" || ext == "htm"
    }

    /// Rule 2: exact → case-insensitive → same basename anywhere → the only file of that type.
    static func findAsset(_ reference: String, ext: String, files: [String: String]) -> String? {
        let normalized = normalize(reference)
        guard !normalized.isEmpty else { return nil }
        if files[normalized] != nil { return normalized }

        let lowered = normalized.lowercased()
        if let match = files.keys.first(where: { $0.lowercased() == lowered }) { return match }

        let name = basename(of: normalized).lowercased()
        if let match = files.keys.first(where: { basename(of: $0).lowercased() == name }) { return match }

        let sameKind = files.keys.filter { fileExtension(of: $0) == ext }
        return sameKind.count == 1 ? sameKind.first : nil
    }

    static func isExternal(_ reference: String) -> Bool {
        let value = reference.trimmingCharacters(in: .whitespaces).lowercased()
        return value.hasPrefix("http://") || value.hasPrefix("https://")
            || value.hasPrefix("//") || value.hasPrefix("data:") || value.hasPrefix("blob:")
    }

    // MARK: - Rewriting

    /// Rule 3: every resolvable local stylesheet becomes an inline `<style>`.
    static func inlineStylesheets(_ html: String, files: [String: String]) -> String {
        rewrite(html, tag: "link", closingTag: nil) { tag in
            guard let href = attribute("href", in: tag), !isExternal(href) else { return nil }
            guard let path = findAsset(href, ext: "css", files: files), let css = files[path] else { return nil }
            return "<style data-fcw-path=\"" + escapeAttribute(path) + "\">\n" + css + "\n</style>"
        }
    }

    /// Rule 5, classic scripts only. Module scripts keep their `src` — the scheme handler serves
    /// them, which also makes their own relative imports resolve.
    static func inlineClassicScripts(_ html: String, files: [String: String]) -> String {
        rewrite(html, tag: "script", closingTag: "</script>") { tag in
            guard let src = attribute("src", in: tag), !isExternal(src) else { return nil }
            if let type = attribute("type", in: tag), type.lowercased().contains("module") { return nil }
            let ext = fileExtension(of: src)
            guard ext == "js" || ext == "mjs" || ext.isEmpty else { return nil }
            guard let path = findAsset(src, ext: "js", files: files), let source = files[path] else { return nil }
            guard source.range(of: "</script", options: [.caseInsensitive]) == nil else { return nil }
            return "<script data-fcw-path=\"" + escapeAttribute(path) + "\">\n" + source + "\n</script>"
        }
    }

    /// `cwEnsureViewport` — a full document without the meta tag renders at 980 px on a phone.
    static func ensureViewport(_ html: String) -> String {
        guard html.range(of: "name=\"viewport\"", options: [.caseInsensitive]) == nil,
              html.range(of: "name='viewport'", options: [.caseInsensitive]) == nil else {
            return html
        }
        let meta = "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        if let head = html.range(of: "<head", options: [.caseInsensitive]),
           let close = html.range(of: ">", range: head.upperBound..<html.endIndex) {
            return String(html[..<close.upperBound]) + "\n" + meta + String(html[close.upperBound...])
        }
        return meta + "\n" + html
    }

    // MARK: - A very small tag scanner

    /// Walks the document once looking for `<tag …>`; no regular expression touches a 180 000
    /// character buffer here.
    static func rewrite(
        _ html: String,
        tag: String,
        closingTag: String?,
        transform: (String) -> String?
    ) -> String {
        var output = ""
        var index = html.startIndex
        let opening = "<" + tag

        while let open = html.range(of: opening, options: [.caseInsensitive], range: index..<html.endIndex) {
            output += html[index..<open.lowerBound]

            let afterName = open.upperBound
            let boundaryIsClean: Bool
            if afterName < html.endIndex {
                let next = html[afterName]
                boundaryIsClean = next == " " || next == ">" || next == "\n" || next == "\t" || next == "/"
            } else {
                boundaryIsClean = false
            }

            guard boundaryIsClean,
                  let close = html.range(of: ">", range: afterName..<html.endIndex) else {
                output += html[open.lowerBound..<afterName]
                index = afterName
                continue
            }

            var consumed = close.upperBound
            var element = String(html[open.lowerBound..<close.upperBound])

            if let closingTag,
               let end = html.range(of: closingTag, options: [.caseInsensitive], range: close.upperBound..<html.endIndex) {
                element = String(html[open.lowerBound..<end.upperBound])
                consumed = end.upperBound
            }

            output += transform(element) ?? element
            index = consumed
        }

        output += html[index...]
        return output
    }

    /// The value of `name="…"` / `name='…'` / `name=value` inside one element.
    static func attribute(_ name: String, in element: String) -> String? {
        guard let found = element.range(of: name + "=", options: [.caseInsensitive]) else { return nil }
        var rest = element[found.upperBound...]
        guard let first = rest.first else { return nil }
        if first == "\"" || first == "'" {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: first) else { return nil }
            return String(rest[..<end])
        }
        let end = rest.firstIndex(where: { $0 == " " || $0 == ">" || $0 == "\n" || $0 == "\t" }) ?? rest.endIndex
        return String(rest[..<end])
    }

    static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    // MARK: - Console hook

    /// `CW_CONSOLE_HOOK` (`web-code-ux.md §5.4`), same payload keys so the client side is the port
    /// it describes. It also carries `__fcwCss` for the live stylesheet push.
    static let consoleHook: String = #"""
    (function () {
      if (window.__fcwHooked) { return; }
      window.__fcwHooked = 1;
      var post = function (payload) {
        try { window.webkit.messageHandlers.fcw.postMessage(payload); } catch (e) {}
      };
      var fmt = function (value) {
        try {
          if (value && typeof value === 'object') { return JSON.stringify(value).slice(0, 300); }
          return String(value);
        } catch (e) { return String(value); }
      };
      ['log', 'warn', 'error', 'info'].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          var parts = [];
          for (var i = 0; i < arguments.length; i++) { parts.push(fmt(arguments[i])); }
          post({ __fcw: 1, t: level, m: parts.join(' ').slice(0, 600) });
          if (original) { original.apply(console, arguments); }
        };
      });
      window.addEventListener('error', function (e) {
        post({
          __fcw: 1, t: 'error',
          m: String(e.message) + ' @ line ' + (e.lineno || 0),
          file: e.filename || '', line: e.lineno || 0, col: e.colno || 0,
          stack: (e.error && e.error.stack) ? String(e.error.stack).slice(0, 1200) : ''
        });
      });
      window.addEventListener('unhandledrejection', function (e) {
        var r = e.reason || {};
        post({
          __fcw: 1, t: 'error',
          m: 'Promise: ' + (r.message || r),
          file: r.fileName || '', line: r.lineNumber || 0, col: r.columnNumber || 0,
          stack: r.stack ? String(r.stack).slice(0, 1200) : ''
        });
      });
      window.__fcwCss = function (path, text) {
        try {
          var id = 'fcw-live-' + encodeURIComponent(path);
          var live = document.getElementById(id);
          if (!live) {
            live = document.createElement('style');
            live.id = id;
            (document.head || document.documentElement).appendChild(live);
          }
          live.textContent = text;
          var old = document.querySelectorAll('style[data-fcw-path="' + path + '"]');
          for (var i = 0; i < old.length; i++) {
            if (old[i] !== live) { old[i].disabled = true; }
          }
        } catch (e) {}
      };
    })();
    """#
}
