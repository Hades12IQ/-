import Foundation

/// The reading half of the ported engine: the expression compiler, the geometry commands and the
/// view arithmetic. `DiagramIsland+Grammar.swift` carries the rest of this same script.
///
/// Every function here is a transcription of the website's own, named after it so the two stay
/// comparable line by line:
///
/// | app.js | here |
/// |---|---|
/// | `compilePlotN` / `compilePlotExpr` (`8322`, `8388`) | `FD.compile` |
/// | `plotParseNum` (`8680`) | `FD.parseNum` |
/// | `parseShapeSpec` (`8693`) | `FD.parseShapes` |
/// | `shapePoints` (`8713`) | `FD.shapePoints` |
/// | `plotPointsBounds` (`8849`) | `FD.pointsBounds` |
/// | `plotAutoY` (`8865`) | `FD.autoY` |
/// | `plotHomeView` (`9006`) | `FD.homeView` |
extension DiagramRuntime {

    static let engineJS = #"""
    window.FD = window.FD || {};
    (function (FD) {
      "use strict";

      /* Figure geometry, in the SVG's own units — the web's PLOT_* constants. */
      FD.W = 480; FD.H = 300; FD.L = 46; FD.R = 16; FD.T = 16; FD.B = 28;
      FD.PW = FD.W - FD.L - FD.R;
      FD.PH = FD.H - FD.T - FD.B;
      FD.AR = FD.PW / FD.PH;
      FD.PAL = ["var(--c1,#237a68)", "var(--c2,#3b82f6)", "var(--c3,#ef4444)",
        "var(--c4,#d97706)", "var(--c5,#7c3aed)"];

      FD.escapeHtml = function (value) {
        return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;")
          .replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
      };

      /* ── EXPRESSION COMPILER ────────────────────────────────────────────────────────────────
         One recursive-descent parser for every arity. `vars` names the free variables in order,
         so ["x"] is a curve, ["theta"] a polar radius, ["x","y"] a surface and ["x","y","z"] an
         implicit solid. Implicit multiplication is handled in the parser, never by a regex, so a
         function name that contains the variable letter (exp, sqrt, atan) survives. An unknown
         single letter is the constant 2 — that is what lets `x^2+y^2+z^2 = r^2` still draw. */
      FD.compile = function (src, vars) {
        var F = {
          sin: Math.sin, cos: Math.cos, tan: Math.tan, asin: Math.asin, acos: Math.acos,
          atan: Math.atan, arcsin: Math.asin, arccos: Math.acos, arctan: Math.atan, tg: Math.tan,
          cot: function (v) { return 1 / Math.tan(v); },
          cotan: function (v) { return 1 / Math.tan(v); },
          ctg: function (v) { return 1 / Math.tan(v); },
          sec: function (v) { return 1 / Math.cos(v); },
          csc: function (v) { return 1 / Math.sin(v); },
          cosec: function (v) { return 1 / Math.sin(v); },
          sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh, asinh: Math.asinh,
          acosh: Math.acosh, atanh: Math.atanh, exp: Math.exp, ln: Math.log,
          log: function (v) { return Math.log(v) / Math.LN10; },
          lg: function (v) { return Math.log(v) / Math.LN10; },
          log2: function (v) { return Math.log(v) / Math.LN2; },
          log10: function (v) { return Math.log(v) / Math.LN10; },
          sqrt: Math.sqrt, cbrt: Math.cbrt, abs: Math.abs, sign: Math.sign,
          floor: Math.floor, ceil: Math.ceil, round: Math.round
        };
        var C = { pi: Math.PI, e: Math.E, tau: 2 * Math.PI };
        var s = String(src).replace(/\s+/g, "").toLowerCase();
        if (!s) { return null; }
        s = s.replace(/²/g, "^2").replace(/³/g, "^3").replace(/\*\*/g, "^");

        var names = (vars || ["x"]).map(function (v) { return String(v).toLowerCase(); });
        var pick = [
          function (x) { return x; },
          function (x, y) { return y; },
          function (x, y, z) { return z; }
        ];
        var FN = Object.keys(F).sort(function (a, b) { return b.length - a.length; });
        var LONG = [];
        names.forEach(function (n, k) { if (n.length > 1) { LONG.push({ n: n, k: k }); } });
        LONG.sort(function (a, b) { return b.n.length - a.n.length; });

        var i = 0;
        /* `let`, not `var`, for every binding a closure below captures: `var` is function-scoped,
           so on the SECOND `+` of `x^2+y^2+z^2` the first closure's A and B would be rebound to the
           new operands — the sum would reference itself and recurse until the stack gave out, and
           the whole expression would silently fail to compile. Each iteration needs its own pair. */
        function expr() {
          var a = term();
          while (s[i] === "+" || s[i] === "-") {
            const o = s[i++], A = a, B = term();
            a = o === "+"
              ? function (x, y, z) { return A(x, y, z) + B(x, y, z); }
              : function (x, y, z) { return A(x, y, z) - B(x, y, z); };
          }
          return a;
        }
        function term() {
          var a = unary();
          while (i < s.length) {
            if (s[i] === "*" || s[i] === "/") {
              const o = s[i++], A = a, B = unary();
              a = o === "*"
                ? function (x, y, z) { return A(x, y, z) * B(x, y, z); }
                : function (x, y, z) { return A(x, y, z) / B(x, y, z); };
            } else if (/[0-9.a-z(]/.test(s[i])) {
              const A = a, B = unary();
              a = function (x, y, z) { return A(x, y, z) * B(x, y, z); };
            } else { break; }
          }
          return a;
        }
        function unary() {
          if (s[i] === "-") { i++; var A = unary(); return function (x, y, z) { return -A(x, y, z); }; }
          if (s[i] === "+") { i++; return unary(); }
          return power();
        }
        function power() {
          var a = atom();
          if (s[i] === "^") {
            i++;
            var b = unary(), A = a, B = b;
            return function (x, y, z) { return Math.pow(A(x, y, z), B(x, y, z)); };
          }
          return a;
        }
        function atom() {
          if (s[i] === "(") {
            i++;
            var e = expr();
            if (s[i] !== ")") { throw 0; }
            i++;
            return e;
          }
          var m = /^[0-9]*\.?[0-9]+/.exec(s.slice(i));
          if (m) {
            i += m[0].length;
            var v = parseFloat(m[0]);
            return function () { return v; };
          }
          if (/[a-z_]/.test(s[i])) {
            for (var k = 0; k < FN.length; k++) {
              var fname = FN[k];
              if (s.startsWith(fname, i) && s[i + fname.length] === "(") {
                i += fname.length + 1;
                var a = expr();
                if (s[i] !== ")") { throw 0; }
                i++;
                var f = F[fname], A = a;
                return function (x, y, z) { return f(A(x, y, z)); };
              }
            }
            for (var q = 0; q < LONG.length; q++) {
              if (s.startsWith(LONG[q].n, i)) { i += LONG[q].n.length; return pick[LONG[q].k]; }
            }
            var consts = ["tau", "pi"];
            for (var c = 0; c < consts.length; c++) {
              if (s.startsWith(consts[c], i)) {
                i += consts[c].length;
                var cv = C[consts[c]];
                return function () { return cv; };
              }
            }
            var ch = s[i];
            i++;
            var vi = names.indexOf(ch);
            if (vi >= 0 && vi < 3) { return pick[vi]; }
            if (ch === "e") { return function () { return Math.E; }; }
            return function () { return 2; };
          }
          throw 0;
        }
        try {
          var fn = expr();
          if (i !== s.length) { return null; }
          var probe = fn(0.4, 0.6, 0.5);
          if (typeof probe !== "number") { return null; }
          return fn;
        } catch (_) { return null; }
      };

      /* Is this line a sentence rather than an expression?
         The compiler is forgiving by design: an unknown single letter is the constant 2, which is
         what lets `x^2+y^2+z^2 = r^2` draw a radius-2 sphere. Read char by char, that same rule
         turns "draw me a nice house please" into a valid product of twos and paints a flat line at
         y ≈ 19 452 809 — a figure that is worse than no figure. So: strip the names we know, and if
         three or more letters are still standing next to each other, this is prose. Two-letter runs
         stay legal (`2ab`, `xk`), which is the only place symbolic constants actually appear. */
      FD.looksLikeProse = function (text) {
        var s = String(text).toLowerCase().replace(/\s+/g, "")
          .replace(/arcsin|arccos|arctan|asinh|acosh|atanh|sinh|cosh|tanh|asin|acos|atan|sin|cos|tan|sec|cosec|csc|cotan|cot|ctg|tg|exp|ln|log10|log2|log|lg|sqrt|cbrt|abs|sign|floor|ceil|round|theta|tau|pi/g, " ");
        return /[a-z]{3,}/.test(s);
      };

      /* "2*pi", "pi/2", "-1.5" → a number. */
      FD.parseNum = function (text) {
        var f = FD.compile(String(text).replace(/π/g, "pi"), ["_none_"]);
        if (!f) { return NaN; }
        try { var v = f(0, 0, 0); return isFinite(v) ? v : NaN; } catch (_) { return NaN; }
      };

      /* ── GEOMETRY COMMANDS ──────────────────────────────────────────────────────────────── */
      FD.parseShapes = function (lines) {
        var shapes = [];
        var coords = function (ln) {
          var out = [], re = /\(\s*(-?\d*\.?\d+)\s*,\s*(-?\d*\.?\d+)\s*\)/g, m;
          while ((m = re.exec(ln)) !== null) { out.push([parseFloat(m[1]), parseFloat(m[2])]); }
          return out;
        };
        var lbl = function (ln) {
          var q = /["'“”„]([^"'“”„]+)["'“”„]/.exec(ln);
          if (q) { return q[1]; }
          var w = /(?:label|name)\s*[:=]\s*([^\s,]+)/i.exec(ln);
          return w ? w[1] : null;
        };
        var colr = function (ln) {
          var c = /(?:color|colour|stroke)\s*[:=]\s*(#[0-9a-fA-F]{3,8}|[a-z]+)/i.exec(ln);
          return c ? c[1] : null;
        };
        var num = function (ln, key) {
          var m = new RegExp(key + "\\s*[:=]\\s*(-?\\d*\\.?\\d+)", "i").exec(ln);
          return m ? parseFloat(m[1]) : null;
        };
        lines.forEach(function (ln) {
          var p = coords(ln), lb = lbl(ln), col = colr(ln);
          var dash = /\bdash(ed)?\b/i.test(ln), fill = /\bfill(ed)?\b/i.test(ln);
          if (/^point\b/i.test(ln) && p.length >= 1) {
            shapes.push({ t: "point", p: p[0], lb: lb, col: col });
          } else if (/^(text|label)\b/i.test(ln) && p.length >= 1 && lb) {
            shapes.push({ t: "text", p: p[0], lb: lb, col: col });
          } else if (/^vector\b/i.test(ln) && p.length >= 2) {
            shapes.push({ t: "vector", a: p[0], b: p[1], lb: lb, col: col });
          } else if (/^(segment|seg|line|ray)\b/i.test(ln) && p.length >= 2) {
            shapes.push({
              t: /^(line|ray)\b/i.test(ln) ? "line" : "segment",
              a: p[0], b: p[1], lb: lb, col: col, dash: dash,
              extend: /^line\b/i.test(ln)
            });
          } else if (/^circle\b/i.test(ln) && p.length >= 1) {
            var r = num(ln, "r");
            if (r === null && p.length >= 2) {
              r = Math.sqrt(Math.pow(p[1][0] - p[0][0], 2) + Math.pow(p[1][1] - p[0][1], 2));
            }
            if (r === null) {
              var bn = /circle\s*\([^)]*\)\s*(-?\d*\.?\d+)/i.exec(ln);
              if (bn) { r = parseFloat(bn[1]); }
            }
            if (r !== null && isFinite(r) && r > 0) {
              shapes.push({ t: "circle", c: p[0], r: r, lb: lb, col: col, dash: dash, fill: fill });
            }
          } else if (/^ellipse\b/i.test(ln) && p.length >= 1) {
            var rx = num(ln, "rx"); if (rx === null) { rx = num(ln, "a"); }
            var ry = num(ln, "ry"); if (ry === null) { ry = num(ln, "b"); }
            if (rx && ry) {
              shapes.push({ t: "ellipse", c: p[0], rx: rx, ry: ry, lb: lb, col: col, dash: dash, fill: fill });
            }
          } else if (/^arc\b/i.test(ln) && p.length >= 1) {
            var ar = num(ln, "r");
            var am = /(-?\d*\.?\d+)\s*(?:\.\.|,|to)\s*(-?\d*\.?\d+)\s*(?:deg|°)?/i
              .exec(ln.replace(/r\s*[:=]\s*-?\d*\.?\d+/i, ""));
            if (ar && am) {
              shapes.push({ t: "arc", c: p[0], r: ar, a1: parseFloat(am[1]), a2: parseFloat(am[2]), col: col, dash: dash });
            }
          } else if (/^angle\b/i.test(ln) && p.length >= 3) {
            shapes.push({ t: "angle", a: p[0], v: p[1], b: p[2], lb: lb, col: col });
          } else if (/^triangle\b/i.test(ln) && p.length >= 3) {
            shapes.push({ t: "poly", pts: p.slice(0, 3), lb: lb, col: col, dash: dash, fill: true });
          } else if (/^(rectangle|rect|square)\b/i.test(ln) && p.length >= 2) {
            var a = p[0], b = p[1];
            shapes.push({
              t: "poly",
              pts: [[a[0], a[1]], [b[0], a[1]], [b[0], b[1]], [a[0], b[1]]],
              lb: lb, col: col, dash: dash, fill: true
            });
          } else if (/^(polygon|poly|quad|quadrilateral)\b/i.test(ln) && p.length >= 3) {
            shapes.push({ t: "poly", pts: p, lb: lb, col: col, dash: dash, fill: fill });
          }
        });
        return shapes;
      };

      FD.shapePoints = function (s) {
        if (s.t === "point" || s.t === "text") { return [s.p]; }
        if (s.t === "vector" || s.t === "segment" || s.t === "line") { return [s.a, s.b]; }
        if (s.t === "angle") { return [s.a, s.v, s.b]; }
        if (s.t === "poly") { return s.pts; }
        if (s.t === "circle" || s.t === "arc") {
          return [[s.c[0] - s.r, s.c[1]], [s.c[0] + s.r, s.c[1]],
            [s.c[0], s.c[1] - s.r], [s.c[0], s.c[1] + s.r]];
        }
        if (s.t === "ellipse") {
          return [[s.c[0] - s.rx, s.c[1]], [s.c[0] + s.rx, s.c[1]],
            [s.c[0], s.c[1] - s.ry], [s.c[0], s.c[1] + s.ry]];
        }
        return [];
      };

      /* ── VIEWS ──────────────────────────────────────────────────────────────────────────── */
      FD.pointsBounds = function (pts, equalAspect) {
        var xmin = Infinity, xmax = -Infinity, ymin = Infinity, ymax = -Infinity;
        pts.forEach(function (p) {
          if (p[0] < xmin) { xmin = p[0]; }
          if (p[0] > xmax) { xmax = p[0]; }
          if (p[1] < ymin) { ymin = p[1]; }
          if (p[1] > ymax) { ymax = p[1]; }
        });
        if (!isFinite(xmin)) { return { xmin: -1, xmax: 1, ymin: -1, ymax: 1 }; }
        var padX = (xmax - xmin) * 0.1 || 1, padY = (ymax - ymin) * 0.1 || 1;
        xmin -= padX; xmax += padX; ymin -= padY; ymax += padY;
        if (equalAspect) {
          var cx = (xmin + xmax) / 2, cy = (ymin + ymax) / 2;
          var halfY = Math.max((ymax - ymin) / 2, (xmax - xmin) / 2 / FD.AR);
          var halfX = halfY * FD.AR;
          xmin = cx - halfX; xmax = cx + halfX; ymin = cy - halfY; ymax = cy + halfY;
        }
        return { xmin: xmin, xmax: xmax, ymin: ymin, ymax: ymax };
      };

      FD.autoY = function (fns, x0, x1) {
        var N = 500, all = [];
        for (var k = 0; k <= N; k++) {
          var x = x0 + (x1 - x0) * k / N;
          for (var j = 0; j < fns.length; j++) {
            var y;
            try { y = fns[j].fn(x); } catch (_) { y = NaN; }
            if (typeof y === "number" && isFinite(y)) { all.push(y); }
          }
        }
        if (!all.length) { return { ymin: -1, ymax: 1 }; }
        all.sort(function (a, b) { return a - b; });
        var ymin = all[Math.floor(all.length * 0.02)];
        var ymax = all[Math.min(all.length - 1, Math.ceil(all.length * 0.98))];
        if (!(ymin < ymax)) { ymin = all[0]; ymax = all[all.length - 1]; }
        if (!(ymin < ymax)) { ymin -= 1; ymax += 1; }
        var pad = (ymax - ymin) * 0.1 || 1;
        ymin -= pad; ymax += pad;
        if (ymin > 0 && ymin < pad * 4) { ymin = 0; }
        if (ymax < 0 && ymax > -pad * 4) { ymax = 0; }
        return { ymin: ymin, ymax: ymax };
      };

      FD.homeView = function (p) {
        if (p.bounds) { return p.bounds; }
        var ay = FD.autoY(p.fns, p.dom[0], p.dom[1]);
        return { xmin: p.dom[0], xmax: p.dom[1], ymin: ay.ymin, ymax: ay.ymax };
      };

    })(window.FD);
    """#
}
