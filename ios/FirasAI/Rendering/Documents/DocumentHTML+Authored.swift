import Foundation

/// A document the MODEL designed, printed as it was written.
///
/// This is the owner's instruction and it is not the same as the composer beside it: «فراس اي اي
/// يصمم ملف عبر اج تي ام ال سي بلس بلس ويحط بي كلشي حتى لو معادلات ويكون تصميم احترافي وراها يصدره
/// ك بي دي اف». Firas designs the file — its layout, its type, its colour, its cover — in HTML and
/// CSS, and the app's only job is to print what it designed.
///
/// The composer stays for the other path: an EXPORT of a conversation is a transcript, and a
/// transcript has no author to design it. Two different things, two different routes.
///
/// What this adds to the model's document, and it is deliberately almost nothing:
/// * KaTeX, so `$…$` in the design is typeset rather than left as source. The model cannot load it
///   itself — the page has no network — so the app hands it in.
/// * The ready flag the printer waits on.
/// * A `@page` rule ONLY when the design has none, because a document with no page size prints at
///   whatever the engine assumes and that is how a beautiful design comes out cropped.
/// Everything else is the model's and is left exactly as written.
extension DocumentHTML {

    /// The HTML the model wrote, if it wrote any.
    ///
    /// Two shapes are accepted, because a model asked for a document will produce either: a fenced
    /// ```html block, or a bare document that opens with `<!DOCTYPE` or `<html`. Anything else is
    /// not a design and the caller composes from markdown instead.
    static func authored(in markdown: String) -> String? {
        if let fenced = fencedHTML(in: markdown) { return fenced }
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.prefix(200).lowercased()
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return trimmed }
        return nil
    }

    /// The first ```html fence, whole.
    private static func fencedHTML(in markdown: String) -> String? {
        var lineStart = markdown.startIndex
        var opened: (marker: Character, bodyStart: String.Index)?
        var body = ""

        while lineStart < markdown.endIndex {
            let lineEnd = markdown[lineStart...].firstIndex(of: "\n") ?? markdown.endIndex
            let line = markdown[lineStart..<lineEnd]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let next = lineEnd == markdown.endIndex ? markdown.endIndex : markdown.index(after: lineEnd)

            if let open = opened {
                if let first = trimmed.first, first == open.marker, trimmed.count >= 3,
                   trimmed.allSatisfy({ $0 == open.marker }) {
                    return body.isEmpty ? nil : body
                }
                body += line + "\n"
            } else if let first = trimmed.first, first == "`" || first == "~", trimmed.count >= 3 {
                var name = Substring(trimmed)
                while let head = name.first, head == first { name = name.dropFirst() }
                let label = name.trimmingCharacters(in: .whitespaces).lowercased()
                if label == "html" || label == "html5" {
                    opened = (first, next)
                }
            }

            if lineEnd == markdown.endIndex { break }
            lineStart = next
        }
        // A truncated file is not a completed deliverable. Let the caller take its recovery path.
        return nil
    }

    /// The model's document, with the three things it cannot provide for itself put in.
    static func printable(authored html: String) -> String {
        var out = html
        let scheme = MathIslandAssets.scheme + "://katex/"

        let assets = [
            "<link rel=\"stylesheet\" href=\"" + scheme + "katex.min.css\">",
            "<script src=\"" + scheme + "katex.min.js\"></script>",
            "<script src=\"" + scheme + "mhchem.min.js\"></script>",
        ].joined(separator: "\n")

        /* A PAGE SIZE ONLY IF THE DESIGN HAS NONE. A model that wrote its own `@page` has decided
           the paper, and overruling it would crop the design it built to that size. */
        let paper = html.lowercased().contains("@page")
            ? ""
            : "\n<style>@page { size: A4; margin: 18mm 16mm; }</style>"

        let injection = assets + paper + "\n<style>" + documentFontCSS + "</style>"

        // Put the policy before any authored resource, rather than after it has already loaded.
        if let head = out.range(of: "<head>", options: .caseInsensitive) {
            out.insert(contentsOf: documentCSP, at: head.upperBound)
        } else { out = documentCSP + out }

        if let head = out.range(of: "</head>", options: .caseInsensitive) {
            out.replaceSubrange(head, with: injection + "\n</head>")
        } else if let openBody = out.range(of: "<body", options: .caseInsensitive) {
            // No head at all: put the assets in front of the body and let the parser build one.
            out.replaceSubrange(openBody, with: injection + "\n<body")
        } else {
            out = injection + "\n" + out
        }

        /* THE MATHEMATICS, AND THE FLAG THE PRINTER WAITS ON. Appended rather than injected into
           the model's own scripts: whatever it wrote runs first and untouched, and this runs after
           the document is parsed. The walk finds the equations wherever the design put them,
           because the app does not know how the model laid them out. */
        out += mathAndReadyScript()
        return out
    }

    /// KaTeX over the model's own page: the nodes it marked, then the delimiters it wrote.
    ///
    /* THE DELIMITERS ARE WALKED HERE, AND THEY HAVE TO BE. This script used to hand the page to
       `renderMathInElement` and, failing that, do nothing — and it always failed. Auto-render is a
       separate KaTeX extension: it is not in `Resources/KaTeX/`, `MathIslandAssets.remotePath` will
       not serve it, and `printable(authored:)` loads only `katex.min.js` and `mhchem.min.js`. So
       `window.renderMathInElement` was undefined on every document ever printed, the branch guarded
       by it never ran, and every equation in every document Firas designed came out as its own
       LaTeX source — while `PromptCatalog.documentBrief` promised the model, in as many words, that
       «KaTeX is loaded for you and typesets it before the page is printed» and told it to write
       `$…$`. The owner asked for a designed file «حتى لو معادلات»; this is the line where the
       equations were being lost.

       AND IT USES THE APP'S OWN RULES, not auto-render's. Auto-render pairs any two dollar signs,
       which is how «من 5,000$ إلى 8,000$» in a دراسة جدوى becomes an equation. `MathScanner`
       settled every one of those cases for the transcript already — a digit on both sides of the
       run is currency, Arabic left over once `\text{…}` is removed is a sentence, four words with
       no TeX construct among them is prose — so `acceptsInline` and `acceptsBracket` are ported
       below rule for rule. A document and a conversation now disagree about nothing.

       NOT for the composed page beside this one: there every equation is already a `data-tex` node
       that `MathScanner` ruled on in Swift, and turning a second scan loose over that markup would
       re-open the very question it answered. */
    /// Shared with the code preview: a design shown on screen and the same design printed must
    /// typeset by identical rules, or the reader proofreads one document and receives another.
    static func mathAndReadyScript() -> String {
        #"""

        <script>
        (function () {
          \#(MathIslandAssets.typesettingScript)
          // MathScanner.containsArabic, by code point. Ranges, not a character class: a
          // literal Arabic range in a regex puts U+FEFF in the source, invisibly.
          function arabic(s) {
            for (var i = 0; i < s.length; i++) {
              var v = s.charCodeAt(i);
              if (v >= 0x0600 && v <= 0x06FF) { return true; }
              if (v >= 0x0750 && v <= 0x077F) { return true; }
              if (v >= 0xFB50 && v <= 0xFDFF) { return true; }
              if (v >= 0xFE70 && v <= 0xFEFF) { return true; }
            }
            return false;
          }
          var TEXTGROUP = /\\(?:text|textrm|textbf|textit|mathrm|mbox|operatorname)\s*\{[^{}]*\}/g;
          var REACH = 4000;
          var SKIP = {
            script: 1, noscript: 1, style: 1, textarea: 1, option: 1,
            pre: 1, code: 1, kbd: 1, samp: 1, svg: 1, math: 1
          };

          function draw(node, tex, display) {
            try {
              if (attempt(tidy(tex), display, node, '#b3261e')) { return; }
              if (attempt(repair(tex), display, node, '#b3261e')) { return; }
              katex.render(tex, node, { displayMode: display, throwOnError: false, strict: false,
                trust: false, output: 'html', macros: copyMacros() });
            } catch (e) {
              node.textContent = tex;
            }
          }

          function marked(node) {
            var raw = node.getAttribute('data-tex') || node.textContent || '';
            var display = node.getAttribute('data-display') === '1'
              || (node.tagName || '').toLowerCase() === 'div';
            draw(node, raw, display);
          }

          // MathScanner.strippingTextGroups: Arabic is legitimate inside \text{…} and nowhere else.
          function stripped(body) {
            if (body.indexOf('\\') < 0) { return body; }
            var out = body, before = null, rounds = 0;
            while (out !== before && rounds < 6) {
              before = out;
              out = out.replace(TEXTGROUP, ' ');
              rounds += 1;
            }
            return out;
          }

          function breaks(body) {
            var count = 0;
            for (var i = 0; i < body.length; i++) {
              if (body.charAt(i) === '\n') { count += 1; }
            }
            return count;
          }

          function blank(body) { return /\n[ \t]*\n/.test(body); }
          function digit(c) { return c >= '0' && c <= '9'; }

          // MathScanner.acceptsBracket.
          function acceptsBracket(body, display) {
            if (!/\S/.test(body)) { return false; }
            if (arabic(stripped(body))) { return false; }
            if (display) { return true; }
            if (blank(body)) { return false; }
            return breaks(body) <= 2;
          }

          // MathScanner.acceptsInline. Every rule in it is a bug somebody reported.
          function acceptsInline(body, after) {
            if (!/\S/.test(body)) { return false; }
            var head = body.charAt(0);
            if (head === ' ' || head === '\t' || head === '\n') { return false; }
            if (blank(body)) { return false; }
            if (breaks(body) > 2) { return false; }
            if (digit(head) && after !== '' && digit(after)) { return false; }
            if (arabic(stripped(body))) { return false; }
            var words = body.split(/[ \t\n]+/), count = 0;
            for (var i = 0; i < words.length; i++) {
              if (words[i] !== '') { count += 1; }
            }
            if (count >= 4 && !/[\\^_{}=]/.test(body)) { return false; }
            return true;
          }

          var PAIRS = [
            { left: '$$', right: '$$', display: true, inline: false },
            { left: '\\[', right: '\\]', display: true, inline: false },
            { left: '\\(', right: '\\)', display: false, inline: false },
            { left: '$', right: '$', display: false, inline: true }
          ];

          // The earliest delimiter in the text, longest first: '$$' is offered before '$' so the
          // two never race for the same position.
          function opener(text, from) {
            var at = -1, pair = null;
            for (var i = 0; i < PAIRS.length; i++) {
              var left = PAIRS[i].left;
              var found = text.indexOf(left, from);
              while (found > 0 && left.charAt(0) === '$' && text.charAt(found - 1) === '\\') {
                found = text.indexOf(left, found + 1);
              }
              if (found >= 0 && (at < 0 || found < at)) { at = found; pair = PAIRS[i]; }
            }
            return pair === null ? null : { at: at, pair: pair };
          }

          // A backslash escapes the next character for a dollar run, exactly as the Swift scanner
          // has it — and never for '\]' or '\)', whose own delimiter opens with one.
          function closer(text, right, from) {
            var i = from, limit = Math.min(text.length, from + REACH);
            while (i < limit) {
              if (right.charAt(0) === '$' && text.charAt(i) === '\\') { i += 2; continue; }
              if (text.slice(i, i + right.length) === right) { return i; }
              i += 1;
            }
            return -1;
          }

          // null when there is no mathematics here at all, which leaves the text node untouched.
          function pieces(text) {
            var out = [], at = 0, found = 0;
            while (at < text.length) {
              var open = opener(text, at);
              if (open === null) { break; }
              var left = open.pair.left, right = open.pair.right;
              var from = open.at + left.length;
              var end = closer(text, right, from);
              if (end < 0) {
                // One unfinished delimiter must not prevent every later complete equation.
                out.push({ math: false, data: text.slice(at, from) });
                at = from;
                continue;
              }
              var body = text.slice(from, end);
              var after = end + right.length;
              var ok = open.pair.inline
                ? acceptsInline(body, after < text.length ? text.charAt(after) : '')
                : acceptsBracket(body, open.pair.display);
              if (open.at > at) { out.push({ math: false, data: text.slice(at, open.at) }); }
              if (ok) {
                out.push({ math: true, data: body, display: open.pair.display });
                found += 1;
                at = after;
              } else {
                // Refused: step past the OPENING mark only, so the '$' that closed a price is
                // still free to open a real equation.
                out.push({ math: false, data: text.slice(open.at, from) });
                at = from;
              }
            }
            if (found === 0) { return null; }
            if (at < text.length) { out.push({ math: false, data: text.slice(at) }); }
            return out;
          }

          function typeset(node) {
            var text = node.nodeValue || '';
            if (text.indexOf('$') < 0 && text.indexOf('\\(') < 0 && text.indexOf('\\[') < 0) { return; }
            var parts = pieces(text);
            if (parts === null || !node.parentNode) { return; }
            var frag = document.createDocumentFragment();
            for (var i = 0; i < parts.length; i++) {
              if (!parts[i].math) {
                frag.appendChild(document.createTextNode(parts[i].data));
                continue;
              }
              /* A SPAN, NEVER A DIV, even for a display equation. This runs inside whatever
                 element the designer wrote, and a div dropped into a <p> is a paragraph closed
                 early and a layout the model did not design. KaTeX's own .katex-display carries
                 the block it needs. */
              var host = document.createElement('span');
              host.setAttribute('dir', 'ltr');
              draw(host, parts[i].data, parts[i].display);
              frag.appendChild(host);
            }
            node.parentNode.replaceChild(frag, node);
          }

          function walk(element) {
            var child = element.firstChild;
            while (child) {
              // Held before the node is replaced: a fragment put in its place has no nextSibling
              // to ask, and the walk would stop at the first equation on the page.
              var next = child.nextSibling;
              if (child.nodeType === 3) {
                typeset(child);
              } else if (child.nodeType === 1) {
                var name = (child.tagName || '').toLowerCase();
                var cls = child.getAttribute('class') || '';
                if (SKIP[name] !== 1 && cls.indexOf('katex') < 0
                  && child.getAttribute('data-tex') === null) {
                  walk(child);
                }
              }
              child = next;
            }
          }

          try {
            var nodes = document.querySelectorAll('[data-tex]');
            for (var i = 0; i < nodes.length; i++) { marked(nodes[i]); }
            if (window.katex && document.body) { walk(document.body); }
          } catch (e) {}

          /* THE FLAG IS RAISED WHATEVER HAPPENED ABOVE. A single expression KaTeX will not set
             must not leave the printer waiting for a page that never says it is done. */
          function finish() {
            requestAnimationFrame(function () { requestAnimationFrame(function () {
              window.\#(readyFlag) = true;
            }); });
          }
          if (document.fonts && document.fonts.ready) {
            document.fonts.ready.then(finish).catch(finish);
          } else { finish(); }
        })();
        </script>

        """#
    }
}
