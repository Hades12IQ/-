import Foundation

// One KaTeX macro and repair policy for chat, Brain, previews and PDF.
extension MathIslandAssets {
    static let typesettingScript = #"""
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
    """#
}
