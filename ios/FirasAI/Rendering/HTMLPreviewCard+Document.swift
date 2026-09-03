import SwiftUI

/// Turning a fenced block into a complete document the island can render — the port of the web's
/// `previewDocumentFor` / `previewShell` / `ensureHtmlDocument` / `projPreviewHtml`
/// (`app.js:35456-35690`, `app.js:50941-51025`).
///
/// Two rules come straight from there and are the reason this is not one `String(format:)`:
///
/// * A **full document is passed through untouched** so the page renders exactly as authored;
///   only a fragment is wrapped in a themed shell. A stylesheet, a script and a JSON blob each get
///   their own shell, because a bare `.css` file shows nothing and a bare script shows an empty
///   white box — both read as "the preview is broken".
/// * **Companion fences are folded in.** When an answer writes the page across three blocks —
///   ```` ```html ````, ```` ```css ````, ```` ```js ```` — the page's own `<link>` and
///   `<script src>` point at files that do not exist inside the island, so they are stripped
///   (`cwLiveStrip`) and the companion bodies are inlined instead (`projPreviewHtml`).
extension HTMLPreviewCard {

    enum Document {

        // MARK: - Inputs

        /// Another fenced block from the same answer that belongs to this page.
        struct Companion: Sendable, Hashable {
            let language: String
            let filename: String?
            let code: String

            init(language: String, filename: String? = nil, code: String) {
                self.language = language
                self.filename = filename
                self.code = code
            }

            var isStylesheet: Bool {
                switch CodeHighlighter.normalized(language) {
                case "css", "scss", "sass", "less": return true
                default: return false
                }
            }

            var isScript: Bool {
                switch CodeHighlighter.normalized(language) {
                case "js", "javascript", "mjs", "cjs", "jsx", "node": return true
                default: return false
                }
            }
        }

        /// What a block previews as. Absent means there is nothing to show, and the card offers no
        /// Preview side at all — better than a button that opens an empty white box.
        enum Kind: String, Sendable, Equatable {
            case html
            case svg
            case css
            case javascript
            case json
        }

        /// The five literal colours the shell paints with. The island cannot see the app's
        /// stylesheet, so a `var(--token)` in there would resolve to nothing.
        struct Theme: Sendable {
            let background: String
            let text: String
            let surface: String
            let hair: String
            let accent: String
            let muted: String
            let good: String
            let bad: String

            static let light = Theme(
                background: "#FFFFFF", text: "#1A1A18", surface: "#F0EEE6", hair: "#E6E4DA",
                accent: "#237A68", muted: "#6B6A63", good: "#2E7D5B", bad: "#B3261E"
            )

            static let dark = Theme(
                background: "#1F1E1D", text: "#ECEAE3", surface: "#262624", hair: "#3A3A36",
                accent: "#57AE9C", muted: "#9A978E", good: "#6FC48B", bad: "#E06A60"
            )

            static func matching(_ palette: FirasPalette) -> Theme {
                palette.isLightFamily ? .light : .dark
            }
        }

        // MARK: - Classification

        /// The web's `previewKindOf`: the tag first, then a sniff of the source, because models
        /// label a whole HTML document `code` often enough to matter.
        static func kind(language: String?, code: String) -> Kind? {
            switch CodeHighlighter.normalized(language) {
            case "html", "htm", "xhtml", "vue": return .html
            case "svg": return .svg
            case "css", "scss", "sass", "less": return .css
            case "js", "javascript", "mjs", "cjs", "jsx", "node": return .javascript
            case "json", "jsonc", "geojson": return .json
            default: break
            }
            // Only the ends of the block are sniffed, and only ever a bounded slice of them: this
            // runs on every render of every code box in a transcript, and lowercasing forty
            // kilobytes of source each time would be a frame nobody gets back.
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let head = String(trimmed.prefix(sniffWindow)).lowercased()
            let tail = String(trimmed.suffix(sniffWindow)).lowercased()
            if head.hasPrefix("<svg"), tail.hasSuffix("</svg>") { return .svg }
            if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return .html }
            if looksLikeMarkup(head: head, tail: tail) { return .html }
            return nil
        }

        private static let sniffWindow = 900

        /// A body fragment with real structure — the same best-effort test as `looksLikeHtml`.
        private static let openers = ["<body", "<head", "<div", "<section", "<main", "<article",
                                      "<h1", "<h2", "<table", "<ul", "<ol", "<form", "<canvas", "<svg"]
        private static let closers = ["</div>", "</section>", "</main>", "</article>", "</body>",
                                      "</html>", "</p>", "</table>", "</ul>", "</ol>"]

        private static func looksLikeMarkup(head: String, tail: String) -> Bool {
            var opened = false
            for tag in openers where head.contains(tag) {
                opened = true
                break
            }
            guard opened else { return false }
            for tag in closers where tail.contains(tag) || head.contains(tag) { return true }
            return false
        }

        /// A page big enough that running it without being asked is rude. Past this the card shows
        /// a Run button instead of loading the island.
        static let autoRunByteLimit = 30_000

        static func isHeavy(code: String, companions: [Companion]) -> Bool {
            var total = code.utf8.count
            for companion in companions { total += companion.code.utf8.count }
            return total > autoRunByteLimit
        }

        // MARK: - Assembly

        static func page(
            code: String,
            language: String?,
            companions: [Companion],
            palette: FirasPalette,
            lang: AppLanguage
        ) -> String {
            let theme = Theme.matching(palette)
            switch kind(language: language, code: code) ?? .html {
            case .html:
                return htmlPage(code, companions: companions, theme: theme)
            case .svg:
                return svgPage(code, theme: theme)
            case .css:
                return cssPage(code, theme: theme, lang: lang)
            case .javascript:
                return scriptPage(code, theme: theme, lang: lang)
            case .json:
                return jsonPage(code, theme: theme, lang: lang)
            }
        }

        // MARK: HTML

        private static func htmlPage(_ code: String, companions: [Companion], theme: Theme) -> String {
            let css = companions.filter { $0.isStylesheet }.map { $0.code }
            let js = companions.filter { $0.isScript }.map { $0.code }
            var body = code
            if !css.isEmpty || !js.isEmpty {
                body = strippingLocalAssetTags(body)
            }
            var document = ensureDocument(body)
            document = injectingIntoHead(document, markup: baseStyle(theme))
            for sheet in css {
                document = injectingIntoHead(document, markup: styleTag(sheet), atEnd: true)
            }
            for script in js {
                document = injectingBeforeBodyEnd(document, markup: scriptTag(script))
            }
            return document
        }

        /// The web's `ensureHtmlDocument`: a fragment becomes a document, a document is left alone.
        static func ensureDocument(_ code: String) -> String {
            let head = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if head.hasPrefix("<!doctype") || head.hasPrefix("<html") || head.contains("<html") {
                return code
            }
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
                + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
                + "</head><body>" + code + "</body></html>"
        }

        /// The canvas colour and a sane box model, first in the head so the page can override
        /// every line of it.
        private static func baseStyle(_ theme: Theme) -> String {
            styleTag(
                "html{background:" + theme.background + ";color:" + theme.text
                    + ";-webkit-text-size-adjust:100%}"
                    + "body{margin:0;font-family:-apple-system,system-ui,\"SF Pro Text\",sans-serif}"
                    + "img,svg,video,canvas{max-width:100%}"
            )
        }

        // MARK: SVG

        private static func svgPage(_ code: String, theme: Theme) -> String {
            let board = "background-image:linear-gradient(45deg," + theme.hair + " 25%,transparent 25%),"
                + "linear-gradient(-45deg," + theme.hair + " 25%,transparent 25%),"
                + "linear-gradient(45deg,transparent 75%," + theme.hair + " 75%),"
                + "linear-gradient(-45deg,transparent 75%," + theme.hair + " 75%);"
                + "background-size:18px 18px;background-position:0 0,0 9px,9px -9px,-9px 0"
            let css = "body{display:grid;place-items:center;padding:18px;" + board + "}"
                + ".wrap{max-width:100%;display:grid;place-items:center}"
                + ".wrap svg{max-width:100%;height:auto}"
            return shell(body: "<div class=\"wrap\">" + code + "</div>", theme: theme, css: css, pad: false)
        }

        // MARK: CSS

        private static func cssPage(_ code: String, theme: Theme, lang: AppLanguage) -> String {
            let say: (LText) -> String = { escapeHTML($0(lang)) }
            let specimen = "<article class=\"specimen\">"
                + "<h1>" + say(Copy.specimenHeading) + "</h1>"
                + "<p>" + say(Copy.specimenBody) + "</p>"
                + "<p><a href=\"#\">" + say(Copy.specimenLink) + "</a> · <strong>"
                + say(Copy.specimenBold) + "</strong> · <em>" + say(Copy.specimenItalic)
                + "</em> · <code>code</code></p>"
                + "<p><button type=\"button\">" + say(Copy.specimenButton) + "</button> "
                + "<input placeholder=\"" + say(Copy.specimenField) + "\"></p>"
                + "<ul><li>" + say(Copy.specimenItemOne) + "</li><li>"
                + say(Copy.specimenItemTwo) + "</li></ul>"
                + "<div class=\"card box container wrapper\">.card / .box / .container / .wrapper</div>"
                + "</article>"
            return shell(body: specimen + styleTag(code), theme: theme, css: "", pad: true)
        }

        // MARK: JavaScript

        private static func scriptPage(_ code: String, theme: Theme, lang: AppLanguage) -> String {
            let mono = "ui-monospace,\"SF Mono\",Menlo,Consolas,monospace"
            let runner = "(function(){"
                + "var box=document.getElementById('__lines');"
                + "function put(kind,args){var d=document.createElement('div');d.className='ln '+kind;"
                + "d.textContent=Array.prototype.map.call(args,function(a){"
                + "try{return typeof a==='string'?a:JSON.stringify(a,null,1);}catch(e){return String(a);}"
                + "}).join(' ');box.appendChild(d);}"
                + "['log','info','warn','error','debug'].forEach(function(k){var o=console[k];"
                + "console[k]=function(){put(k,arguments);try{o.apply(console,arguments);}catch(e){}};});"
                + "window.onerror=function(m,s,l){put('error',[m+'  (line '+l+')']);return false;};"
                + "window.addEventListener('unhandledrejection',function(e){"
                + "put('error',['Unhandled promise: '+e.reason]);});"
                + "try{(0,eval)(" + jsStringLiteral(code) + ");}"
                + "catch(e){put('error',[String((e&&e.stack)||e)]);}"
                + "if(!box.children.length)put('log',[" + jsStringLiteral(Copy.noOutput(lang)) + "]);"
                + "})();"
            let body = "<div id=\"__stage\"></div>"
                + "<div id=\"__con\"><div class=\"hd\">console</div><div id=\"__lines\"></div></div>"
                + "<script>" + runner + "</script>"
            let css = "body{direction:ltr;text-align:left}"
                + "#__stage{padding:16px}"
                + "#__con{border-top:1px solid " + theme.hair + ";background:" + theme.surface + "}"
                + "#__con .hd{color:" + theme.muted + ";font:600 11px/1 " + mono + ";"
                + "letter-spacing:.09em;text-transform:uppercase;padding:9px 14px;"
                + "border-bottom:1px solid " + theme.hair + "}"
                + "#__lines{padding:6px 0}"
                + ".ln{font:13px/1.55 " + mono + ";padding:3px 14px;white-space:pre-wrap;"
                + "word-break:break-word}"
                + ".ln.error{color:" + theme.bad + "}.ln.warn{color:#D9A441}"
                + ".ln.debug,.ln.info{color:" + theme.muted + "}"
            return shell(body: body, theme: theme, css: css, pad: false)
        }

        // MARK: JSON

        private static func jsonPage(_ code: String, theme: Theme, lang: AppLanguage) -> String {
            var pretty = code
            var failure: String?
            if let data = code.data(using: .utf8) {
                do {
                    let object = try JSONSerialization.jsonObject(
                        with: data,
                        options: [.fragmentsAllowed]
                    )
                    let out = try JSONSerialization.data(
                        withJSONObject: object,
                        options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
                    )
                    pretty = String(decoding: out, as: UTF8.self)
                } catch {
                    failure = error.localizedDescription
                }
            } else {
                failure = Copy.jsonUnreadable(lang)
            }
            let head = failure.map { "<div class=\"bad\">" + escapeHTML($0) + "</div>" }
                ?? ("<div class=\"good\">" + escapeHTML(Copy.jsonValid(lang)) + "</div>")
            let css = ".bad{color:" + theme.bad + ";font-weight:600;margin-bottom:12px}"
                + ".good{color:" + theme.good + ";font-weight:600;margin-bottom:12px}"
            return shell(
                body: head + "<pre>" + escapeHTML(pretty) + "</pre>",
                theme: theme,
                css: css,
                pad: true
            )
        }

        // MARK: - Shell

        /// The themed wrapper used for everything except raw HTML — the port of `previewShell`.
        static func shell(body: String, theme: Theme, css: String, pad: Bool) -> String {
            let mono = "ui-monospace,\"SF Mono\",Menlo,Consolas,monospace"
            let base = "*,*::before,*::after{box-sizing:border-box}"
                + "html,body{margin:0}"
                + "html{background:" + theme.background + "}"
                + "body{color:" + theme.text + ";padding:" + (pad ? "18px" : "0") + ";"
                + "font-family:-apple-system,system-ui,\"SF Pro Text\",sans-serif;"
                + "font-size:15px;line-height:1.7;-webkit-text-size-adjust:100%}"
                + "a{color:" + theme.accent + "}"
                + "code,pre,kbd,samp{font-family:" + mono + "}"
                + "pre{background:" + theme.surface + ";border:1px solid " + theme.hair + ";"
                + "border-radius:10px;padding:13px 15px;overflow:auto;direction:ltr;text-align:left}"
                + ":not(pre)>code{background:" + theme.surface + ";border:1px solid " + theme.hair
                + ";border-radius:5px;padding:.12em .38em;font-size:.92em}"
                + "table{border-collapse:collapse;width:100%;margin:1em 0}"
                + "th,td{border:1px solid " + theme.hair + ";padding:8px 11px;text-align:start}"
                + "th{background:" + theme.surface + "}"
                + "img,svg,video,canvas{max-width:100%}"
                + "h1,h2,h3{line-height:1.3;margin:1.1em 0 .5em}"
                + "h1{font-size:1.55em}h2{font-size:1.3em}h3{font-size:1.1em}"
            return "<!DOCTYPE html><html lang=\"en\" dir=\"ltr\"><head><meta charset=\"utf-8\">"
                + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
                + styleTag(base + css)
                + "</head><body>" + body + "</body></html>"
        }
    }
}
