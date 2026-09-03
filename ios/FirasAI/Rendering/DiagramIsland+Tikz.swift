import Foundation

/// The mini TikZ interpreter and the engine's entry point.
///
/// `renderTikzToSvg` (`app.js:8143`) reads the explicit-coordinate subset of TikZ the model
/// actually writes — coordinate definitions, draw / fill paths chained with `--`, Bezier
/// `..controls..`, `cycle`, `circle`, `ellipse`, `rectangle`, node labels and `foreach` loops —
/// and refuses everything else, so the caller falls back rather than draws a lie. Its bail-out
/// list is the website's, plus one: circuitikz's `to[R=…]` components, which the web draws and
/// this port does not.
///
/// Where the web hands a refusal to the TikZJax WebAssembly engine, the app hands it to the card's
/// explanatory plate. Downloading a TeX engine per figure over a phone connection is not a better
/// answer than telling the reader, in Arabic, that the picture could not be drawn and showing what
/// the model actually wrote.
///
/// The same colour tokens, the same 42 pt/cm scale, the same label transliteration.
///
/// | app.js | here |
/// |---|---|
/// | `renderTikzToSvg` (`8143`) | `FD.tikzSvg` |
/// | `tikzLabelText` (`7997`) | `labelText` |
/// | `tikzExpandForeach` (`8018`) | `expandForeach` |
/// | `tikzParsePath` (`8056`) | `parsePath` |
/// | `tikzEmit` (`8127`) | `emit` |
/// | `plotifyCodeBlock` (`12882`) | `FD.render` |
extension DiagramRuntime {

    static let tikzJS = #"""
    window.FD = window.FD || {};
    (function (FD) {
      "use strict";

      var CS = window.getComputedStyle(document.documentElement);
      var INK = (CS.getPropertyValue("--ink") || "").trim() || "#111827";
      var seq = 0;

      /* ── MINI TIKZ → SVG ────────────────────────────────────────────────────────────────── */
      var TC = {
        black: "#111827", white: "#ffffff", red: "#dc2626", green: "#16a34a", blue: "#2563eb",
        cyan: "#0891b2", magenta: "#c026d3", yellow: "#ca8a04", orange: "#ea7317",
        purple: "#7c3aed", violet: "#7c3aed", brown: "#92400e", pink: "#db2777",
        teal: "#0d9488", lime: "#65a30d", olive: "#6b7d1a", gray: "#6b7280", grey: "#6b7280",
        lightgray: "#d1d5db", darkgray: "#374151", none: "none"
      };
      var SUP = { "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶",
        "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "n": "ⁿ", "i": "ⁱ" };
      var SUB = { "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆",
        "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋", "a": "ₐ", "e": "ₑ", "x": "ₓ" };
      var GRK = { alpha: "α", beta: "β", gamma: "γ", delta: "δ", epsilon: "ε", theta: "θ",
        lambda: "λ", mu: "µ", nu: "ν", pi: "π", rho: "ρ", sigma: "σ", tau: "τ", phi: "φ",
        psi: "ψ", omega: "ω", Gamma: "Γ", Delta: "Δ", Theta: "Θ", Lambda: "Λ", Sigma: "Σ",
        Phi: "Φ", Psi: "Ψ", Omega: "Ω", infty: "∞", cdot: "·", times: "×", pm: "±", to: "→",
        rightarrow: "→", leftarrow: "←", approx: "≈", neq: "≠", leq: "≤", geq: "≥",
        degree: "°", circ: "∘", prime: "′", ldots: "…" };
      var uni = function (str, map) {
        return String(str).split("").map(function (c) { return map[c] || c; }).join("");
      };
      var labelText = function (raw) {
        var t = String(raw);
        t = t.replace(/\\displaystyle|\\limits|\\!|\\,|\\;|\\:|\\ /g, " ");
        t = t.replace(/\\(?:mathbf|mathrm|text|textbf|textit|mathit|boldsymbol|vec|hat|bar|overrightarrow)\s*\{([^{}]*)\}/g, "$1");
        t = t.replace(/\$/g, "");
        t = t.replace(/\^\{([^{}]*)\}/g, function (m, a) { return uni(a, SUP); })
          .replace(/\^(\S)/g, function (m, a) { return uni(a, SUP); });
        t = t.replace(/_\{([^{}]*)\}/g, function (m, a) { return uni(a, SUB); })
          .replace(/_(\S)/g, function (m, a) { return uni(a, SUB); });
        t = t.replace(/\\([a-zA-Z]+)/g, function (m, n) {
          return GRK[n] !== undefined ? GRK[n] : n;
        });
        return t.replace(/[{}]/g, "").replace(/\s+/g, " ").trim();
      };
      var mixHex = function (hex) {
        var h = String(hex).replace("#", "");
        if (h.length === 3) { h = h.split("").map(function (c) { return c + c; }).join(""); }
        return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
      };
      var tikzColor = function (spec) {
        var text = String(spec).trim();
        if (!text) { return null; }
        var parts = text.split("!");
        var base = TC[parts[0].toLowerCase()];
        if (base === undefined) {
          if (/^[0-9a-fA-F]{6}$/.test(parts[0])) { base = "#" + parts[0]; } else { return null; }
        }
        if (parts.length >= 2 && /^\d+$/.test(parts[1])) {
          var t = Math.max(0, Math.min(100, parseInt(parts[1], 10))) / 100;
          var other = parts[2] ? (TC[parts[2].toLowerCase()] || "#ffffff") : "#ffffff";
          var A = mixHex(base === "none" ? "#ffffff" : base), B = mixHex(other);
          return "#" + [0, 1, 2].map(function (i) {
            return Math.round(A[i] * t + B[i] * (1 - t)).toString(16).padStart(2, "0");
          }).join("");
        }
        return base;
      };
      var balanced = function (s, i) {
        if (s[i] !== "{") { return null; }
        var d = 0;
        for (var j = i; j < s.length; j++) {
          if (s[j] === "{") { d++; }
          else if (s[j] === "}") { d--; if (d === 0) { return { inner: s.slice(i + 1, j), end: j + 1 }; } }
        }
        return null;
      };
      var expandList = function (str) {
        var raw = str.split(",").map(function (s) { return s.trim(); })
          .filter(function (s) { return s !== ""; });
        var di = raw.indexOf("...");
        if (di <= 0 || di >= raw.length - 1) { return raw; }
        var before = raw.slice(0, di), b = parseFloat(raw[di + 1]);
        var a = parseFloat(before[before.length - 1]);
        var step = before.length >= 2 ? (a - parseFloat(before[before.length - 2])) : (a <= b ? 1 : -1);
        var list = before.slice();
        if (step) {
          for (var v = a + step; step > 0 ? v <= b + 1e-9 : v >= b - 1e-9; v += step) {
            list.push(String(Number(v.toFixed(6))));
          }
        }
        return list;
      };
      var expandForeach = function (body, depth) {
        depth = depth || 0;
        if (depth > 8) { return body; }
        var idx = body.search(/\\foreach\b/);
        if (idx < 0) { return body; }
        var head = /\\foreach\s*\\(\w+)\s*(?:\[[^\]]*\])?\s*in\s*\{([^{}]*)\}\s*/.exec(body.slice(idx));
        if (!head) { return body; }
        var bstart = idx + head.index + head[0].length, loopBody, after;
        if (body[bstart] === "{") {
          var bal = balanced(body, bstart);
          if (!bal) { return body; }
          loopBody = bal.inner;
          after = bal.end;
        } else {
          var semi = body.indexOf(";", bstart);
          if (semi < 0) { return body; }
          loopBody = body.slice(bstart, semi + 1);
          after = semi + 1;
        }
        var items = expandList(head[2]);
        var expanded = items.map(function (v) {
          return loopBody.replace(new RegExp("\\\\" + head[1] + "(?![a-zA-Z])", "g"), v);
        }).join("\n");
        return expandForeach(body.slice(0, idx) + expanded + body.slice(after), depth + 1);
      };
      var splitStatements = function (body) {
        var out = [], cur = "", d = 0;
        for (var i = 0; i < body.length; i++) {
          var c = body[i];
          if (c === "{" || c === "[" || c === "(") { d++; }
          else if (c === "}" || c === "]" || c === ")") { d = Math.max(0, d - 1); }
          if (c === ";" && d === 0) { out.push(cur); cur = ""; } else { cur += c; }
        }
        if (cur.trim()) { out.push(cur); }
        return out;
      };
      var tikzLen = function (s) {
        var m = String(s).match(/(-?[\d.]+)\s*(pt|cm|mm|em|ex)?/);
        if (!m) { return null; }
        var v = parseFloat(m[1]), u = m[2] || "cm";
        if (u === "pt") { v /= 28.45; }
        else if (u === "mm") { v /= 10; }
        else if (u === "em" || u === "ex") { v *= 0.35; }
        return v;
      };
      var tikzCoord = function (inner, coords) {
        var text = String(inner).trim();
        if (coords[text]) { return coords[text].slice(); }
        var p = text.split(",");
        if (p.length >= 2) {
          var ev = function (t) {
            var s = String(t).trim();
            if (/^-?[\d.]+$/.test(s)) { return parseFloat(s); }
            var fn = FD.compile(s, ["_none_"]);
            return fn ? fn(0, 0, 0) : parseFloat(s);
          };
          var x = ev(p[0]), y = ev(p[1]);
          if (isFinite(x) && isFinite(y)) { return [x, y]; }
        }
        return null;
      };
      var optStyle = function (opts, cmd) {
        var o = String(opts || "");
        var st = { stroke: INK, width: 1.2, fill: "none", dash: "", mS: false, mE: false };
        if (cmd === "fill") { st.fill = INK; st.stroke = "none"; }
        if (/<->|<\s*->/.test(o)) { st.mS = true; st.mE = true; }
        else { if (/->/.test(o)) { st.mE = true; } if (/<-/.test(o)) { st.mS = true; } }
        if (/ultra thick/.test(o)) { st.width = 2.6; }
        else if (/very thick/.test(o)) { st.width = 2; }
        else if (/\bthick\b/.test(o)) { st.width = 1.7; }
        else if (/very thin/.test(o)) { st.width = 0.5; }
        else if (/\bthin\b/.test(o)) { st.width = 0.7; }
        var lw = o.match(/line width\s*=\s*([\d.]+)\s*pt/);
        if (lw) { st.width = parseFloat(lw[1]) * 1.1; }
        if (/dashed/.test(o)) { st.dash = "6,4"; }
        else if (/dotted/.test(o)) { st.dash = "1.5,3"; }
        var fm = o.match(/fill\s*=\s*([a-zA-Z]+(?:!\d+(?:!\w+)?)?|[0-9a-fA-F]{6})/);
        if (fm) { var fc = tikzColor(fm[1]); if (fc) { st.fill = fc; } }
        var dm = o.match(/draw\s*=\s*([a-zA-Z]+(?:!\d+)?|[0-9a-fA-F]{6})/);
        if (dm) { var dc = tikzColor(dm[1]); if (dc) { st.stroke = dc; } }
        o.split(",").map(function (w) { return w.trim(); }).forEach(function (w) {
          if (w && !/=/.test(w) && TC[w.toLowerCase()] !== undefined) {
            st.stroke = tikzColor(w);
          }
        });
        return st;
      };
      var parsePath = function (st, coords, els, addPt) {
        var cmdMatch = st.match(/^\\(\w+)/);
        var cmd = cmdMatch ? cmdMatch[1] : "";
        var s = st.replace(/^\\\w+/, ""), opts = "";
        var om = s.match(/^\s*\[([^\]]*)\]/);
        if (om) { opts = om[1]; s = s.slice(om[0].length); }
        var style = optStyle(opts, cmd);
        var i = 0, cur = null, prev = null, start = null, rel = false;
        var skip = function () { while (i < s.length && /\s/.test(s[i])) { i++; } };
        var paren = function () {
          var d = 0, j = i;
          for (; j < s.length; j++) {
            if (s[j] === "(") { d++; }
            else if (s[j] === ")") { d--; if (d === 0) { j++; break; } }
          }
          var inner = s.slice(i + 1, j - 1);
          i = j;
          return inner;
        };
        var brace = function () {
          var d = 0, j = i;
          for (; j < s.length; j++) {
            if (s[j] === "{") { d++; }
            else if (s[j] === "}") { d--; if (d === 0) { j++; break; } }
          }
          var inner = s.slice(i + 1, j - 1);
          i = j;
          return inner;
        };
        var bracket = function () {
          var j = s.indexOf("]", i);
          var inner = s.slice(i + 1, j);
          i = j + 1;
          return inner;
        };
        var segs = [];
        while (i < s.length) {
          skip();
          if (i >= s.length || s[i] === ";") { break; }
          if (s[i] === "+") { rel = true; i++; if (s[i] === "+") { i++; } skip(); continue; }
          if (s[i] === "(") {
            var p = tikzCoord(paren(), coords);
            if (!p) { return false; }
            if (rel && cur) { p = [cur[0] + p[0], cur[1] + p[1]]; }
            rel = false;
            prev = cur;
            cur = p;
            if (!start) { start = p; }
            addPt(p[0], p[1]);
            segs.push({ t: segs.length ? "L" : "M", p: p });
            continue;
          }
          if (s.startsWith("--", i)) { i += 2; continue; }
          if (s.startsWith("..", i)) {
            i += 2; skip();
            var c1 = null, c2 = null;
            if (s.startsWith("controls", i)) {
              i += 8; skip();
              if (s[i] === "(") { c1 = tikzCoord(paren(), coords); }
              skip();
              if (s.startsWith("and", i)) {
                i += 3; skip();
                if (s[i] === "(") { c2 = tikzCoord(paren(), coords); }
              }
            }
            skip();
            if (s.startsWith("..", i)) { i += 2; skip(); }
            if (s[i] !== "(") { return false; }
            var pc = tikzCoord(paren(), coords);
            if (!pc || !cur) { return false; }
            var cc1 = c1 || cur, cc2 = c2 || c1 || pc;
            addPt(pc[0], pc[1]); addPt(cc1[0], cc1[1]); addPt(cc2[0], cc2[1]);
            segs.push({ t: "C", p: pc, c1: cc1, c2: cc2 });
            prev = cur; cur = pc;
            continue;
          }
          if (s.startsWith("cycle", i)) {
            i += 5;
            if (start) { segs.push({ t: "L", p: start }); }
            continue;
          }
          if (s.startsWith("circle", i)) {
            i += 6; skip();
            var rr = null;
            if (s[i] === "(") { rr = tikzLen(paren()); }
            else if (s[i] === "[") {
              var bo = bracket();
              var rm2 = bo.match(/radius\s*=\s*([\d.a-z]+)/);
              if (rm2) { rr = tikzLen(rm2[1]); }
            }
            if (rr === null || !cur) { return false; }
            els.push({ kind: "circle", c: cur, r: rr, style: style });
            addPt(cur[0] - rr, cur[1] - rr);
            addPt(cur[0] + rr, cur[1] + rr);
            continue;
          }
          if (s.startsWith("ellipse", i)) {
            i += 7; skip();
            if (s[i] !== "(") { return false; }
            var inner2 = paren();
            var em = inner2.match(/([\d.]+\s*[a-z]*)\s*and\s*([\d.]+\s*[a-z]*)/i);
            if (!em || !cur) { return false; }
            var rx = tikzLen(em[1]), ry = tikzLen(em[2]);
            els.push({ kind: "ellipse", c: cur, rx: rx, ry: ry, style: style });
            addPt(cur[0] - rx, cur[1] - ry);
            addPt(cur[0] + rx, cur[1] + ry);
            continue;
          }
          if (s.startsWith("rectangle", i)) {
            i += 9; skip();
            if (s[i] !== "(") { return false; }
            var p2 = tikzCoord(paren(), coords);
            if (!p2 || !cur) { return false; }
            els.push({ kind: "rect", a: cur, b: p2, style: style });
            addPt(p2[0], p2[1]);
            prev = cur; cur = p2;
            continue;
          }
          if (s.startsWith("node", i)) {
            i += 4; skip();
            var nopts = "";
            if (s[i] === "[") { nopts = bracket(); }
            skip();
            if (s[i] === "(") { paren(); skip(); }
            if (s[i] === "{") {
              var txt2 = brace();
              els.push({ kind: "node", at: cur, opts: nopts, text: txt2, seg: { a: prev, b: cur } });
            }
            continue;
          }
          return false;
        }
        if (segs.length >= 2) { els.unshift({ kind: "path", segs: segs, style: style }); }
        return true;
      };
      var parseNode = function (st, coords, els, addPt) {
        var m = st.match(/^\\node\s*(?:\[([^\]]*)\])?\s*(?:\(([^)]*)\)\s*)?(?:at\s*\(([^)]+)\))?\s*\{([\s\S]*)\}\s*$/);
        if (!m) { return false; }
        var opts = m[1] || "";
        var at = m[3] ? tikzCoord(m[3], coords)
          : (m[2] && coords[m[2].trim()] ? coords[m[2].trim()] : null);
        if (!at) { return false; }
        addPt(at[0], at[1]);
        els.push({ kind: "node", at: at, opts: opts, text: m[4], seg: null });
        return true;
      };
      var emit = function (e, sx, sy, PX, id) {
        var S = e.style || {};
        var attr = function (s) {
          return 'stroke="' + s.stroke + '" stroke-width="' + s.width + '" fill="' + s.fill + '"'
            + (s.dash ? ' stroke-dasharray="' + s.dash + '"' : "")
            + (s.mE ? ' marker-end="url(#' + id + 'e)"' : "")
            + (s.mS ? ' marker-start="url(#' + id + 's)"' : "");
        };
        if (e.kind === "path") {
          var d = e.segs.map(function (g) {
            if (g.t === "C") {
              return "C" + sx(g.c1[0]).toFixed(1) + " " + sy(g.c1[1]).toFixed(1) + " "
                + sx(g.c2[0]).toFixed(1) + " " + sy(g.c2[1]).toFixed(1) + " "
                + sx(g.p[0]).toFixed(1) + " " + sy(g.p[1]).toFixed(1);
            }
            return g.t + sx(g.p[0]).toFixed(1) + " " + sy(g.p[1]).toFixed(1);
          }).join(" ");
          return '<path d="' + d + '" ' + attr(S)
            + ' stroke-linecap="round" stroke-linejoin="round"/>';
        }
        if (e.kind === "circle") {
          return '<circle cx="' + sx(e.c[0]).toFixed(1) + '" cy="' + sy(e.c[1]).toFixed(1)
            + '" r="' + (e.r * PX).toFixed(1) + '" ' + attr(S) + '/>';
        }
        if (e.kind === "ellipse") {
          return '<ellipse cx="' + sx(e.c[0]).toFixed(1) + '" cy="' + sy(e.c[1]).toFixed(1)
            + '" rx="' + (e.rx * PX).toFixed(1) + '" ry="' + (e.ry * PX).toFixed(1) + '" '
            + attr(S) + '/>';
        }
        if (e.kind === "rect") {
          var x = Math.min(sx(e.a[0]), sx(e.b[0])), y = Math.min(sy(e.a[1]), sy(e.b[1]));
          var w = Math.abs(sx(e.b[0]) - sx(e.a[0])), h = Math.abs(sy(e.b[1]) - sy(e.a[1]));
          return '<rect x="' + x.toFixed(1) + '" y="' + y.toFixed(1) + '" width="' + w.toFixed(1)
            + '" height="' + h.toFixed(1) + '" rx="1.5" ' + attr(S) + '/>';
        }
        if (e.kind === "node") {
          var o = e.opts || "", at = e.at;
          if (/midway|pos\s*=|near/.test(o) && e.seg && e.seg.a && e.seg.b) {
            at = [(e.seg.a[0] + e.seg.b[0]) / 2, (e.seg.a[1] + e.seg.b[1]) / 2];
          }
          if (!at) { return ""; }
          var nx = sx(at[0]), ny = sy(at[1]) + 4, anchor = "middle";
          if (/above/.test(o)) { ny -= 13; }
          if (/below/.test(o)) { ny += 12; }
          if (/right/.test(o)) { nx += 8; anchor = "start"; }
          if (/left/.test(o)) { nx -= 8; anchor = "end"; }
          return '<text x="' + nx.toFixed(1) + '" y="' + ny.toFixed(1) + '" text-anchor="'
            + anchor + '" class="tikz-lbl">' + FD.escapeHtml(labelText(e.text)) + '</text>';
        }
        return "";
      };

      FD.tikzSvg = function (raw) {
        try {
          var M = /\\begin\{tikzpicture\}\s*(\[[^\]]*\])?([\s\S]*?)\\end\{tikzpicture\}/
            .exec(String(raw));
          var gOpts = "", body;
          if (M) { gOpts = M[1] || ""; body = M[2]; } else { body = String(raw); }
          body = body.replace(/(^|[^\\])%[^\n]*/g, "$1");
          var sm = /scale\s*=\s*([\d.]+)/.exec(gOpts);
          var scale = sm ? parseFloat(sm[1]) : 1;
          if (!isFinite(scale) || scale <= 0) { scale = 1; }
          body = expandForeach(body, 0);
          if (/\\begin\{/.test(body)) { return null; }
          if (/=\s*[\d.]+\s*(?:cm|pt|mm)?\s+of\s+/.test(body)) { return null; }
          if (/\)\s*\.\s*(?:east|west|north|south|center|anchor)/i.test(body)) { return null; }
          if (/\barc\b|\bplot\b|\bgrid\b|\\path|\\clip|\\shade|pic\s*\{/.test(body)) { return null; }
          if (/\bto\s*\[/.test(body)) { return null; }

          var coords = Object.create(null), els = [], pts = [];
          var addPt = function (x, y) {
            if (isFinite(x) && isFinite(y)) { pts.push([x, y]); }
          };
          var statements = splitStatements(body);
          for (var k = 0; k < statements.length; k++) {
            var st = statements[k].trim();
            if (!st) { continue; }
            if (/^\\coordinate\b/.test(st)) {
              var cm = st.match(/\\coordinate\s*(?:\[[^\]]*\])?\s*\(([^)]+)\)\s*at\s*\(([^)]+)\)/);
              if (!cm) { return null; }
              var cp = tikzCoord(cm[2], coords);
              if (!cp) { return null; }
              coords[cm[1].trim()] = cp;
              continue;
            }
            if (/^\\(draw|fill|filldraw)\b/.test(st)) {
              if (!parsePath(st, coords, els, addPt)) { return null; }
              continue;
            }
            if (/^\\node\b/.test(st)) {
              if (!parseNode(st, coords, els, addPt)) { return null; }
              continue;
            }
            if (/^\\(useasboundingbox|def|tikzset|pgfmath)/.test(st)) { continue; }
            if (/^\\/.test(st)) { return null; }
          }
          if (!els.length || !pts.length) { return null; }
          var minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9;
          pts.forEach(function (p) {
            minX = Math.min(minX, p[0]); maxX = Math.max(maxX, p[0]);
            minY = Math.min(minY, p[1]); maxY = Math.max(maxY, p[1]);
          });
          if (!(maxX > minX)) { maxX = minX + 1; }
          if (!(maxY > minY)) { maxY = minY + 1; }
          var PX = 42 * scale, pad = 22;
          var W = (maxX - minX) * PX + pad * 2, H = (maxY - minY) * PX + pad * 2;
          if (W > 6000 || H > 6000 || W < 8 || H < 8) { return null; }
          var sx = function (x) { return pad + (x - minX) * PX; };
          var sy = function (y) { return pad + (maxY - y) * PX; };
          var id = "tk" + (seq++);
          var g = "";
          els.forEach(function (e) { g += emit(e, sx, sy, PX, id); });
          if (!g) { return null; }
          return '<svg viewBox="0 0 ' + W.toFixed(1) + " " + H.toFixed(1) + '" width="'
            + W.toFixed(1) + '" height="' + H.toFixed(1)
            + '" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="figure">'
            + '<defs><marker id="' + id + 'e" viewBox="0 0 10 10" refX="8.5" refY="5"'
            + ' markerWidth="7.5" markerHeight="7.5" orient="auto-start-reverse">'
            + '<path d="M0 0L10 5L0 10z" fill="' + INK + '"/></marker>'
            + '<marker id="' + id + 's" viewBox="0 0 10 10" refX="1.5" refY="5"'
            + ' markerWidth="7.5" markerHeight="7.5" orient="auto-start-reverse">'
            + '<path d="M10 0L0 5L10 10z" fill="' + INK + '"/></marker></defs>'
            + g + '</svg>';
        } catch (_) { return null; }
      };

      /* ── ENTRY POINT ────────────────────────────────────────────────────────────────────── */
      var legend = function (stage, p) {
        if (p.mode === "geometry" || !p.fns || !p.fns.length) { return; }
        var rows = p.mode === "surface" ? p.fns.slice(0, 1) : p.fns;
        var box = document.createElement("div");
        box.className = "legend";
        rows.forEach(function (f) {
          var row = document.createElement("div");
          row.className = "legend-row";
          var sw = document.createElement("span");
          sw.className = "legend-sw";
          sw.style.background = f.color;
          var lb = document.createElement("span");
          lb.className = "legend-lb";
          lb.textContent = f.surf || f.points ? f.expr : "y = " + f.expr;
          row.appendChild(sw);
          row.appendChild(lb);
          box.appendChild(row);
        });
        stage.appendChild(box);
      };

      FD.render = function (stage, cfg) {
        stage.innerHTML = "";
        if (cfg.kind === "tikz") {
          var svg = FD.tikzSvg(cfg.source);
          if (!svg) { return { ok: false, why: "tikz" }; }
          stage.innerHTML = svg;
          return { ok: true };
        }
        var p;
        try { p = FD.parseSpec(cfg.source); } catch (_) { p = null; }
        if (!p) { return { ok: false, why: "parse" }; }
        var wrap = document.createElement("div");
        wrap.className = "wrap";
        if (p.mode === "surface") {
          var surfs = p.fns.map(function (f) { return f.surf; });
          var html = FD.surfaceSvg(surfs, p.xr, p.yr, null);
          if (html.indexOf("<path") < 0) { return { ok: false, why: "empty" }; }
          wrap.innerHTML = html;
          stage.appendChild(wrap);
          if (cfg.interactive) { FD.attach3D(wrap, surfs, p.xr, p.yr); }
        } else {
          var home = FD.homeView(p);
          var isPolar = p.mode === "polar" || p.mode === "parametric";
          var opts = { polar: isPolar, shapes: p.shapes };
          var flat = FD.plotSvg(p.fns, home, opts);
          var drew = flat.indexOf('class="plot-curve"') >= 0
            || (p.shapes && p.shapes.length > 0);
          if (!drew) { return { ok: false, why: "empty" }; }
          wrap.innerHTML = flat;
          stage.appendChild(wrap);
          if (cfg.interactive) { FD.attachPlot(wrap, p.fns, home, opts); }
        }
        legend(stage, p);
        return { ok: true };
      };
    })(window.FD);
    """#
}
