import Foundation
import WebKit

/// The KaTeX bundle, fetched once and kept.
///
/// `index.html` loads its stylesheet, its script and its fonts from `firas-katex://katex/…`, and
/// every one of those requests lands here. This type is the only thing that talks to the CDN: it
/// pulls the pinned 0.16.11 build over its own `URLSession` — a session with a real `URLCache` and
/// `returnCacheDataElseLoad`, which is what makes the *second* message (and the next launch, and an
/// aeroplane) cost nothing. `APIClient`'s sessions deliberately run with `urlCache = nil`, so this
/// one is separate on purpose; it carries no cookies and never touches the Firas API.
///
/// `prepare()` is the gate: the stylesheet and the script must be in hand *before* a page is
/// created, so a blocked CDN costs one 15-second attempt and a 90-second cooldown, never a web view
/// that hangs on a `<script>` tag. Fonts are warmed in the background and served from memory when
/// the page asks; anything still missing is fetched on demand, and `document.fonts.ready` on the
/// page side keeps the measurement honest either way.
@MainActor
final class MathIslandAssets: NSObject, @preconcurrency WKURLSchemeHandler {

    static let shared = MathIslandAssets()

    /// Must not collide with `PreviewAssembler.scheme` (`firas-proj`).
    static let scheme = "firas-katex"

    /// The exact build `index.html` loads on the website (`katex@0.16.11`), served here from
    /// cdnjs. Pinned: an equation must not change shape because a CDN moved a tag.
    private static let version = "0.16.11"
    private static let base = "https://cdnjs.cloudflare.com/ajax/libs/KaTeX/" + MathIslandAssets.version + "/"

    private static let stylesheetPath = "katex.min.css"
    private static let scriptPath = "katex.min.js"
    private static let chemistryPath = "contrib/mhchem.min.js"

    private enum State {
        case idle
        case loading
        case ready
        case unavailable
    }

    private let session: URLSession
    private var memory: [String: Data] = [:]
    private var state: State = .idle
    private var cooldownUntil: Date?
    private var fontsWarmed = false
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    private var active: Set<ObjectIdentifier> = []

    override init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = MathIslandAssets.makeCache()
        // The pinned build is immutable, so a cached copy is always the right copy.
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = ["Accept": "*/*"]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 40
        configuration.allowsCellularAccess = true
        session = URLSession(configuration: configuration)
        super.init()
    }

    private static func makeCache() -> URLCache {
        let memory = 6 * 1024 * 1024
        let disk = 48 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let directory = caches?.appendingPathComponent("FirasKaTeX", isDirectory: true)
        return URLCache(memoryCapacity: memory, diskCapacity: disk, directory: directory)
    }

    // MARK: - Gate

    /// `true` once the stylesheet and the script are in memory. Joins an in-flight attempt rather
    /// than starting a second one, so twelve messages arriving at once make one round trip.
    func prepare() async -> Bool {
        switch state {
        case .ready:
            return true
        case .unavailable:
            if let until = cooldownUntil, until > Date() { return false }
            state = .idle
        case .loading:
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiting.append(continuation)
            }
        case .idle:
            break
        }

        state = .loading
        let core = [Self.stylesheetPath, Self.scriptPath, Self.chemistryPath].filter { memory[$0] == nil }
        if !core.isEmpty {
            let fetched = await Self.fetchAll(session: session, paths: core)
            for (path, data) in fetched { memory[path] = data }
        }

        let ok = memory[Self.stylesheetPath] != nil && memory[Self.scriptPath] != nil
        state = ok ? .ready : .unavailable
        cooldownUntil = ok ? nil : Date().addingTimeInterval(90)

        let pending = waiting
        waiting.removeAll()
        for continuation in pending { continuation.resume(returning: ok) }

        if ok { warmFonts() }
        return ok
    }

    /// Fonts are what make a formula look typeset rather than approximated, and a font arriving
    /// late is a measurement taken on the wrong glyph widths. Warmed once, in the background.
    private func warmFonts() {
        guard !fontsWarmed else { return }
        fontsWarmed = true
        let missing = Self.fontFiles.map { "fonts/" + $0 }.filter { memory[$0] == nil }
        guard !missing.isEmpty else { return }
        let session = self.session
        Task { [weak self] in
            let fetched = await MathIslandAssets.fetchAll(session: session, paths: missing)
            guard let self else { return }
            for (path, data) in fetched where self.memory[path] == nil {
                self.memory[path] = data
            }
        }
    }

    // MARK: - Fetching

    private nonisolated static func fetchAll(session: URLSession, paths: [String]) async -> [String: Data] {
        await withTaskGroup(of: (String, Data?).self) { group -> [String: Data] in
            for path in paths {
                group.addTask {
                    let data = await MathIslandAssets.fetch(session: session, path: path)
                    return (path, data)
                }
            }
            var out: [String: Data] = [:]
            for await pair in group {
                if let data = pair.1 { out[pair.0] = data }
            }
            return out
        }
    }

    private nonisolated static func fetch(session: URLSession, path: String) async -> Data? {
        guard let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    // MARK: - Scheme handler

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        active.insert(key)

        guard let url = urlSchemeTask.request.url else {
            active.remove(key)
            return
        }
        let path = url.path

        if path.isEmpty || path == "/" || path == "/index.html" {
            respond(key, urlSchemeTask, url: url, data: Data(Self.document.utf8), mime: "text/html")
            return
        }
        guard let remote = Self.remotePath(for: path) else {
            respond(key, urlSchemeTask, url: url, data: Data(), mime: "text/plain")
            return
        }
        if let cached = memory[remote] {
            respond(key, urlSchemeTask, url: url, data: cached, mime: Self.mime(for: remote))
            return
        }

        let session = self.session
        Task { [weak self] in
            let data = await MathIslandAssets.fetch(session: session, path: remote)
            guard let self else { return }
            if let data { self.memory[remote] = data }
            self.respond(
                key,
                urlSchemeTask,
                url: url,
                data: data ?? Data(),
                mime: MathIslandAssets.mime(for: remote)
            )
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    /// Messaging a stopped task raises an Objective-C exception that Swift cannot catch, so every
    /// response is gated on the task still being live.
    private func respond(
        _ key: ObjectIdentifier,
        _ task: any WKURLSchemeTask,
        url: URL,
        data: Data,
        mime: String
    ) {
        guard active.contains(key) else { return }
        active.remove(key)
        let encoding: String? = mime.hasPrefix("text/") ? "utf-8" : nil
        let response = URLResponse(
            url: url,
            mimeType: mime,
            expectedContentLength: data.count,
            textEncodingName: encoding
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// Allowlist. The island serves the pinned KaTeX build and nothing else: a page that asked for
    /// anything at all would otherwise have a proxy to the open internet.
    static func remotePath(for urlPath: String) -> String? {
        var path = urlPath
        if path.hasPrefix("/") { path.removeFirst() }
        if path == Self.stylesheetPath { return Self.stylesheetPath }
        if path == Self.scriptPath { return Self.scriptPath }
        if path == "mhchem.min.js" { return Self.chemistryPath }
        guard path.hasPrefix("fonts/") else { return nil }
        let name = String(path.dropFirst("fonts/".count))
        guard name.hasPrefix("KaTeX_"), !name.contains("/"), !name.contains("..") else { return nil }
        guard name.hasSuffix(".woff2") || name.hasSuffix(".woff") || name.hasSuffix(".ttf") else { return nil }
        return "fonts/" + name
    }

    static func mime(for path: String) -> String {
        if path.hasSuffix(".css") { return "text/css" }
        if path.hasSuffix(".js") { return "text/javascript" }
        if path.hasSuffix(".woff2") { return "font/woff2" }
        if path.hasSuffix(".woff") { return "font/woff" }
        if path.hasSuffix(".ttf") { return "font/ttf" }
        return "application/octet-stream"
    }

    /// The 0.16.11 font set, warmed so no measurement ever runs against a fallback face.
    private static let fontFiles: [String] = [
        "KaTeX_Main-Regular.woff2",
        "KaTeX_Main-Bold.woff2",
        "KaTeX_Main-Italic.woff2",
        "KaTeX_Main-BoldItalic.woff2",
        "KaTeX_Math-Italic.woff2",
        "KaTeX_Math-BoldItalic.woff2",
        "KaTeX_Size1-Regular.woff2",
        "KaTeX_Size2-Regular.woff2",
        "KaTeX_Size3-Regular.woff2",
        "KaTeX_Size4-Regular.woff2",
        "KaTeX_AMS-Regular.woff2",
        "KaTeX_Caligraphic-Regular.woff2",
        "KaTeX_Caligraphic-Bold.woff2",
        "KaTeX_Fraktur-Regular.woff2",
        "KaTeX_Fraktur-Bold.woff2",
        "KaTeX_SansSerif-Regular.woff2",
        "KaTeX_SansSerif-Bold.woff2",
        "KaTeX_SansSerif-Italic.woff2",
        "KaTeX_Script-Regular.woff2",
        "KaTeX_Typewriter-Regular.woff2",
    ]

    // MARK: - The page

    /// Identical for every island and every message — the payload arrives afterwards through
    /// `window.firasRun`, so the document itself is a constant and costs one parse.
    ///
    /// The repair ladder is the website's, command for command: `mathTidyTex` before the first
    /// attempt, `mathRepairTex` after a refusal, and KaTeX's own `Undefined control sequence`
    /// message turned into `\operatorname{…}` so `\Res` or `\myop` reads upright instead of red.
    /// What the site cannot draw it flattens to text; here it reports `ok:false` and Swift keeps
    /// the `MathText.unicode` form that was already on screen.
    static let document: String = #"""
    <!DOCTYPE html>
    <html lang="en" dir="ltr">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <link rel="stylesheet" href="katex.min.css">
    <style>
      html { -webkit-text-size-adjust: 100%; }
      html, body { margin: 0; padding: 0; background: #ffffff; }
      body {
        color: #151515;
        font-size: 17px;
        font-family: -apple-system, system-ui, "Helvetica Neue", Arial, sans-serif;
        -webkit-user-select: none;
        user-select: none;
        overflow: hidden;
      }
      #root { margin: 0; padding: 0; }
      .fi {
        display: block;
        width: -webkit-max-content;
        width: max-content;
        max-width: none;
        margin: 0 0 12px 0;
        padding: 2px 3px;
        white-space: nowrap;
      }
      .katex-display {
        margin: 0 !important;
        padding: 0 !important;
        text-align: left !important;
        overflow: visible !important;
      }
      .katex-display > .katex {
        display: inline-block !important;
        text-align: left !important;
        white-space: nowrap;
      }
      .pb { display: inline-block; width: 0; height: 0; vertical-align: baseline; }
    </style>
    </head>
    <body>
    <div id="root"></div>
    <script src="katex.min.js"></script>
    <script src="mhchem.min.js"></script>
    <script>
    (function () {
      var CH = null;
      try { CH = window.webkit.messageHandlers.firasMath; } catch (e) { CH = null; }
      function post(m) { try { if (CH) { CH.postMessage(m); } } catch (e) {} }

      var MACROS = {
        "\\R": "\\mathbb{R}", "\\N": "\\mathbb{N}", "\\Z": "\\mathbb{Z}",
        "\\Q": "\\mathbb{Q}", "\\C": "\\mathbb{C}", "\\E": "\\mathbb{E}",
        "\\eps": "\\varepsilon", "\\dd": "\\mathrm{d}", "\\diff": "\\mathrm{d}",
        "\\bm": "\\boldsymbol{#1}", "\\mathbbm": "\\mathbb{#1}",
        "\\abs": "\\left|#1\\right|", "\\norm": "\\left\\|#1\\right\\|",
        "\\set": "\\left\\{#1\\right\\}", "\\bra": "\\langle#1|", "\\ket": "|#1\\rangle",
        "\\braket": "\\langle#1\\rangle", "\\vv": "\\vec{#1}", "\\vect": "\\vec{#1}",
        "\\nicefrac": "{}^{#1}/_{#2}",
        "\\sgn": "\\operatorname{sgn}", "\\tr": "\\operatorname{tr}",
        "\\rank": "\\operatorname{rank}", "\\diag": "\\operatorname{diag}",
        "\\lcm": "\\operatorname{lcm}", "\\erf": "\\operatorname{erf}",
        "\\erfc": "\\operatorname{erfc}", "\\Res": "\\operatorname{Res}",
        "\\Var": "\\operatorname{Var}", "\\Cov": "\\operatorname{Cov}",
        "\\Corr": "\\operatorname{Corr}", "\\sech": "\\operatorname{sech}",
        "\\csch": "\\operatorname{csch}", "\\arcsec": "\\operatorname{arcsec}",
        "\\arccsc": "\\operatorname{arccsc}", "\\arccot": "\\operatorname{arccot}",
        "\\argmin": "\\operatorname*{arg\\,min}", "\\argmax": "\\operatorname*{arg\\,max}",
        "\\degree": "^{\\circ}", "\\celsius": "{}^{\\circ}\\mathrm{C}",
        "\\micro": "\\mu", "\\ohm": "\\Omega"
      };

      function copyMacros() {
        var out = {};
        for (var k in MACROS) {
          if (Object.prototype.hasOwnProperty.call(MACROS, k)) { out[k] = MACROS[k]; }
        }
        return out;
      }

      function tidy(tex) {
        var s = String(tex == null ? "" : tex);
        if (s.indexOf("\\") === -1) { return s; }
        s = s.replace(/\\(?:label|eqref|ref|cite|footnote|index)\s*\{[^{}]*\}/g, "");
        s = s.replace(/\\(?:noindent|centering|par|hfill|hfil|medskip|smallskip|bigskip|newpage|clearpage|linebreak|protect|leavevmode|displaylines)(?![a-zA-Z])/g, "");
        s = s.replace(/\\vspace\*?\s*\{[^{}]*\}/g, " ");
        s = s.replace(/\\mbox(?![a-zA-Z])/g, "\\text");
        s = s.replace(/\\begin\{(?:displaymath|math|subequations)\*?\}/g, "");
        s = s.replace(/\\end\{(?:displaymath|math|subequations)\*?\}/g, "");
        s = s.replace(/\\begin\{tabular\}/g, "\\begin{array}");
        s = s.replace(/\\end\{tabular\}/g, "\\end{array}");
        return s;
      }

      function repair(tex) {
        var s = tidy(tex);
        s = s.replace(/\\begin\{equation\*?\}/g, "").replace(/\\end\{equation\*?\}/g, "");
        s = s.replace(/\\begin\{(?:align|alignat|flalign|eqnarray|split)\*?\}(?:\s*\{[^{}]*\})?/g, "\\begin{aligned}");
        s = s.replace(/\\end\{(?:align|alignat|flalign|eqnarray|split)\*?\}/g, "\\end{aligned}");
        s = s.replace(/\\begin\{(?:gather|multline)\*?\}/g, "\\begin{gathered}");
        s = s.replace(/\\end\{(?:gather|multline)\*?\}/g, "\\end{gathered}");
        s = s.replace(/&\s*(=|<|>|\\(?:leq|le|geq|ge|neq|ne|approx|equiv|sim|simeq|cong|to|rightarrow|Rightarrow|Leftrightarrow|iff|implies|propto|subset|subseteq|in))\s*&/g, "& $1 ");
        var nL = (s.match(/\\left(?![a-zA-Z])/g) || []).length;
        var nR = (s.match(/\\right(?![a-zA-Z])/g) || []).length;
        if (nL !== nR) {
          s = s.replace(/\\(?:left|right)(?![a-zA-Z])\s*\./g, "");
          s = s.replace(/\\(?:left|right)(?![a-zA-Z])\s*/g, "");
        }
        s = s.replace(/(^|[^\\])\$+/g, "$1");
        return s;
      }

      function attempt(source, display, host, errorColor) {
        var body = source;
        for (var i = 0; i < 6; i++) {
          try {
            katex.render(body, host, {
              displayMode: !!display,
              throwOnError: true,
              strict: false,
              trust: false,
              output: "html",
              errorColor: errorColor,
              macros: copyMacros()
            });
            return true;
          } catch (e) {
            var message = String((e && e.message) || e || "");
            var m = /Undefined control sequence:\s*\\([a-zA-Z@]+)/.exec(message);
            if (!m) { return false; }
            var name = m[1].replace(/@/g, "");
            if (!name) { return false; }
            var next;
            try {
              next = body.replace(new RegExp("\\\\" + m[1] + "(?![a-zA-Z])", "g"), "\\operatorname{" + name + "}");
            } catch (x) { return false; }
            if (next === body) { return false; }
            body = next;
          }
        }
        return false;
      }

      /* The website's `math-degraded`: an unknown command with throwOnError:false is not an error
         at all — KaTeX draws the rest correctly and paints the command NAME in errorColor. A real
         render is never thrown away for flattened text, so the colour is taken off and the
         equation is kept; only a whole-expression `.katex-error` is a failure. */
      var ERR_RGB = null;
      function errorRgb(color) {
        if (ERR_RGB !== null) { return ERR_RGB; }
        ERR_RGB = "";
        try {
          var probe = document.createElement("span");
          probe.style.color = color;
          ERR_RGB = probe.style.color;
        } catch (e) { ERR_RGB = ""; }
        return ERR_RGB;
      }

      function degrade(source, display, host, errorColor) {
        try {
          katex.render(source, host, {
            displayMode: !!display,
            throwOnError: false,
            strict: false,
            trust: false,
            output: "html",
            errorColor: errorColor,
            macros: copyMacros()
          });
        } catch (e) { return false; }
        if (!host.firstChild) { return false; }
        if (host.querySelector(".katex-error")) { return false; }
        var red = errorRgb(errorColor);
        if (red) {
          var styled = host.querySelectorAll("[style]");
          for (var i = 0; i < styled.length; i++) {
            if (styled[i].style.color === red) { styled[i].style.color = ""; }
          }
        }
        return true;
      }

      function renderOne(tex, display, host, errorColor) {
        var source = tidy(String(tex == null ? "" : tex));
        if (!source.replace(/\s+/g, "")) { return false; }
        if (attempt(source, display, host, errorColor)) { return true; }
        var repaired = repair(source);
        if (repaired !== source && attempt(repaired, display, host, errorColor)) { return true; }
        if (degrade(source, display, host, errorColor)) { return true; }
        if (repaired !== source && degrade(repaired, display, host, errorColor)) { return true; }
        try { host.textContent = ""; } catch (e) {}
        return false;
      }

      var COUNT = 0;

      window.firasRun = function (payload) {
        try {
          var root = document.getElementById("root");
          root.innerHTML = "";
          var st = (payload && payload.style) || {};
          document.body.style.color = st.color || "#151515";
          document.body.style.background = st.background || "#ffffff";
          document.documentElement.style.background = st.background || "#ffffff";
          document.body.style.fontSize = (st.fontSize || 17) + "px";
          var errorColor = st.error || "#cc0000";
          var items = (payload && payload.items) || [];
          COUNT = items.length;
          for (var i = 0; i < items.length; i++) {
            var cell = document.createElement("div");
            cell.className = "fi";
            cell.id = "fi" + i;
            cell.setAttribute("dir", "ltr");
            root.appendChild(cell);
            var host = cell;
            if (!items[i].display) {
              var probe = document.createElement("span");
              probe.className = "pb";
              probe.id = "pb" + i;
              cell.appendChild(probe);
              host = document.createElement("span");
              cell.appendChild(host);
            }
            var ok = false;
            try { ok = renderOne(items[i].tex, items[i].display, host, errorColor); } catch (e) { ok = false; }
            if (!ok) { cell.setAttribute("data-bad", "1"); }
          }
          settle(measure);
        } catch (e) {
          post({ type: "fail" });
        }
      };

      window.firasMeasure = function () { settle(measure); };

      /* Fonts decide glyph widths, so a box measured before they land is the wrong box. */
      function settle(done) {
        var fired = false;
        var go = function () {
          if (fired) { return; }
          fired = true;
          requestAnimationFrame(function () { requestAnimationFrame(done); });
        };
        try {
          if (document.fonts && document.fonts.ready && typeof document.fonts.ready.then === "function") {
            document.fonts.ready.then(go);
            setTimeout(go, 1500);
          } else {
            go();
          }
        } catch (e) { go(); }
      }

      function measure() {
        var out = [], maxX = 0, maxY = 0;
        var ox = window.pageXOffset || 0, oy = window.pageYOffset || 0;
        for (var i = 0; i < COUNT; i++) {
          var el = document.getElementById("fi" + i);
          if (!el) { continue; }
          var r = el.getBoundingClientRect();
          var bad = el.getAttribute("data-bad") === "1" || !el.firstChild || !!el.querySelector(".katex-error");
          var x = r.left + ox, y = r.top + oy;
          var baseline = r.height;
          var probe = document.getElementById("pb" + i);
          if (probe) {
            var pr = probe.getBoundingClientRect();
            if (pr.bottom > 0) { baseline = pr.bottom + oy - y; }
          }
          if (x + r.width > maxX) { maxX = x + r.width; }
          if (y + r.height > maxY) { maxY = y + r.height; }
          out.push({
            i: i, x: x, y: y, w: r.width, h: r.height, b: baseline,
            ok: !bad && r.width > 1 && r.height > 1
          });
        }
        post({ type: "done", items: out, width: maxX, height: maxY });
      }

      if (typeof katex === "undefined" || !katex || typeof katex.render !== "function") {
        post({ type: "fail" });
      } else {
        post({ type: "boot" });
      }
    })();
    </script>
    </body>
    </html>
    """#
}
