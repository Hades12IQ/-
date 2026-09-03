import Foundation

/// The rest of the reading half: the two implicit solvers and the `plot` grammar itself.
///
/// Split out of `DiagramIsland+Engine.swift` only for file size — this is the second half of one
/// script, and the page concatenates the two before either runs.
///
/// | app.js | here |
/// |---|---|
/// | `implicitCurvePoints` (`8447`) | `FD.implicitCurve` |
/// | `implicitSurfaceSheets` (`8482`) | `FD.implicitSheets` |
/// | `parsePlotSpec` (`8725`) | `FD.parseSpec` |
extension DiagramRuntime {

    static let grammarJS = #"""
    window.FD = window.FD || {};
    (function (FD) {
      "use strict";

      /* ── IMPLICIT 2D — marching squares over h(x,y)=0. ───────────────────────────────────── */
      FD.implicitCurve = function (h, x0, x1, y0, y1) {
        var N = 150, pts = [], V = [], i, j;
        for (i = 0; i <= N; i++) {
          V[i] = [];
          for (j = 0; j <= N; j++) {
            var x = x0 + (x1 - x0) * i / N, y = y0 + (y1 - y0) * j / N, v;
            try { v = h(x, y); } catch (_) { v = NaN; }
            V[i][j] = isFinite(v) ? v : NaN;
          }
        }
        var X = function (n) { return x0 + (x1 - x0) * n / N; };
        var Y = function (n) { return y0 + (y1 - y0) * n / N; };
        var lerp = function (pa, va, pb, vb) { return pa + (pb - pa) * (va / (va - vb)); };
        for (i = 0; i < N; i++) {
          for (j = 0; j < N; j++) {
            var v00 = V[i][j], v10 = V[i + 1][j], v11 = V[i + 1][j + 1], v01 = V[i][j + 1];
            if (!isFinite(v00) || !isFinite(v10) || !isFinite(v11) || !isFinite(v01)) { continue; }
            var cross = [];
            if ((v00 < 0) !== (v10 < 0)) { cross.push([lerp(X(i), v00, X(i + 1), v10), Y(j)]); }
            if ((v10 < 0) !== (v11 < 0)) { cross.push([X(i + 1), lerp(Y(j), v10, Y(j + 1), v11)]); }
            if ((v01 < 0) !== (v11 < 0)) { cross.push([lerp(X(i), v01, X(i + 1), v11), Y(j + 1)]); }
            if ((v00 < 0) !== (v01 < 0)) { cross.push([X(i), lerp(Y(j), v00, Y(j + 1), v01)]); }
            if (cross.length === 2) {
              pts.push(cross[0], cross[1], [NaN, NaN]);
            } else if (cross.length === 4) {
              var c;
              try { c = h((X(i) + X(i + 1)) / 2, (Y(j) + Y(j + 1)) / 2); } catch (_) { c = NaN; }
              if ((c < 0) === (v00 < 0)) {
                pts.push(cross[0], cross[3], [NaN, NaN], cross[1], cross[2], [NaN, NaN]);
              } else {
                pts.push(cross[0], cross[1], [NaN, NaN], cross[2], cross[3], [NaN, NaN]);
              }
            }
          }
        }
        return pts.length > 2 ? pts : null;
      };

      /* ── IMPLICIT 3D — z-root sheets through the surface mesh. ───────────────────────────── */
      FD.implicitSheets = function (h, xr, yr, zr) {
        var K = 40;
        var rootsAt = function (x, y) {
          var out = [], pz = zr[0], pv;
          try { pv = h(x, y, pz); } catch (_) { pv = NaN; }
          for (var k = 1; k <= K; k++) {
            var z = zr[0] + (zr[1] - zr[0]) * k / K, v;
            try { v = h(x, y, z); } catch (_) { v = NaN; }
            if (isFinite(pv) && isFinite(v) && (pv * v < 0 || v === 0)) {
              var a = pz, b = z, fa = pv;
              for (var t = 0; t < 22; t++) {
                var mid = (a + b) / 2, fm;
                try { fm = h(x, y, mid); } catch (_) { break; }
                if (!isFinite(fm)) { break; }
                if ((fa < 0) !== (fm < 0)) { b = mid; } else { a = mid; fa = fm; }
              }
              out.push((a + b) / 2);
            }
            pv = v; pz = z;
          }
          return out;
        };
        var multi = false, any = false;
        for (var i = 0; i <= 8 && !multi; i++) {
          for (var j = 0; j <= 8; j++) {
            var r = rootsAt(xr[0] + (xr[1] - xr[0]) * i / 8, yr[0] + (yr[1] - yr[0]) * j / 8);
            if (r.length) { any = true; }
            if (r.length > 1) { multi = true; break; }
          }
        }
        if (!any) { return []; }
        var lo = function (x, y) { var rr = rootsAt(x, y); return rr.length ? rr[0] : NaN; };
        var hi = function (x, y) { var rr = rootsAt(x, y); return rr.length ? rr[rr.length - 1] : NaN; };
        return multi ? [lo, hi] : [lo];
      };

      /* ── THE `plot` GRAMMAR ─────────────────────────────────────────────────────────────── */
      FD.parseSpec = function (spec) {
        var lines = String(spec).split(/\r?\n/)
          .map(function (l) { return l.trim(); })
          .filter(function (l) { return l && !/^(#|\/\/)/.test(l); });

        var shapeHead = /^(point|text|label|vector|segment|seg|line|ray|circle|ellipse|arc|angle|triangle|rectangle|rect|square|polygon|poly|quad|quadrilateral)\b/i;
        if (lines.some(function (l) { return shapeHead.test(l); })) {
          var shapes = FD.parseShapes(lines);
          if (shapes.length) {
            var cloud = [];
            shapes.forEach(function (s) {
              FD.shapePoints(s).forEach(function (pt) { cloud.push(pt); });
            });
            return {
              mode: "geometry", shapes: shapes, fns: [],
              bounds: FD.pointsBounds(cloud.length ? cloud : [[-1, -1], [1, 1]], true)
            };
          }
        }

        var dom = null, ydom = null, zdom = null, pdom = null;
        var polarSrc = null, px = null, py = null, surfSrc = null, implicitSrc = null;
        var cart = [];
        var hasVar = function (v, text) {
          return String(text).toLowerCase().replace(/[²³]/g, "^")
            .replace(/arcsin|arccos|arctan|asinh|acosh|atanh|sinh|cosh|tanh|asin|acos|atan|sin|cos|tan|sec|cosec|csc|cotan|cot|ctg|tg|exp|ln|log10|log2|log|lg|sqrt|cbrt|abs|sign|floor|ceil|round|theta|tau|pi/g, " ")
            .indexOf(v) >= 0;
        };

        lines.forEach(function (ln) {
          var zm = /^z\s*:\s*(-?[0-9.]+)\s*(?:\.\.|,|to)\s*(-?[0-9.]+)\s*$/i.exec(ln);
          if (zm) {
            var za = parseFloat(zm[1]), zb = parseFloat(zm[2]);
            if (isFinite(za) && isFinite(zb) && za < zb) { zdom = [za, zb]; }
            return;
          }
          var sm = /^z\s*(?:\(\s*x\s*,\s*y\s*\))?\s*=\s*(.+)$/i.exec(ln);
          if (sm && /[xy]/i.test(sm[1]) && !hasVar("z", sm[1])) { surfSrc = sm[1].trim(); return; }

          var ym2 = /^y\s*[:=]\s*(-?[0-9.]+)\s*(?:\.\.|,|to|:)\s*(-?[0-9.]+)\s*$/i.exec(ln);
          if (ym2 && surfSrc) {
            var ya = parseFloat(ym2[1]), yb = parseFloat(ym2[2]);
            if (isFinite(ya) && isFinite(yb) && ya < yb) { ydom = [ya, yb]; }
            return;
          }
          var m = /^(?:domain|x)\s*[:=]\s*(-?[0-9.]+)\s*(?:\.\.|,|to|:)\s*(-?[0-9.]+)/i.exec(ln)
            || /^(-?[0-9.]+)\s*(?:\.\.|to)\s*(-?[0-9.]+)$/i.exec(ln);
          if (m && !/theta|θ|\bt\b/i.test(ln)) {
            var xa = parseFloat(m[1]), xb = parseFloat(m[2]);
            if (isFinite(xa) && isFinite(xb) && xa < xb) { dom = [xa, xb]; }
            return;
          }
          var pm = /^(?:theta|θ|t)\s*[:=]\s*([^\s]+)\s*(?:\.\.|,|to|:)\s*([^\s]+)$/i.exec(ln);
          if (pm) {
            var pa = FD.parseNum(pm[1]), pb = FD.parseNum(pm[2]);
            if (isFinite(pa) && isFinite(pb) && pa < pb) { pdom = [pa, pb]; }
            return;
          }
          var rm = /^(?:polar\s*:?\s*)?r\s*(?:\(\s*(?:theta|θ|t)\s*\))?\s*=\s*(.+)$/i.exec(ln);
          if (rm && /theta|θ|\bt\b/i.test(rm[1])) {
            polarSrc = rm[1].replace(/θ/g, "theta").trim();
            return;
          }
          var xm = /^x\s*(?:\(\s*t\s*\))?\s*=\s*(.+)$/i.exec(ln);
          var ymP = /^y\s*(?:\(\s*t\s*\))?\s*=\s*(.+)$/i.exec(ln);
          if (xm && /\bt\b/i.test(xm[1])) { px = xm[1].trim(); return; }
          if (ymP && /\bt\b/i.test(ymP[1]) && px) { py = ymP[1].trim(); return; }

          if (!implicitSrc && ln.split("=").length === 2
            && !/^[a-z]\s*(?:\(\s*[a-z ,]*\))?\s*=/i.test(ln)) {
            var halves = ln.split("=");
            var is3d = hasVar("z", ln);
            var ok = is3d ? (hasVar("x", ln) || hasVar("y", ln)) : (hasVar("x", ln) && hasVar("y", ln));
            if (ok && !FD.looksLikeProse(ln)) {
              implicitSrc = { L: halves[0].trim(), R: halves[1].trim(), z: is3d, expr: ln.trim() };
              return;
            }
          }

          var e = ln.replace(/^[a-z]\s*\(\s*x\s*\)\s*=/i, "").replace(/^y\s*=/i, "").trim();
          if (FD.looksLikeProse(e)) { return; }
          var fn = FD.compile(e, ["x"]);
          if (fn) { cart.push({ fn: fn, expr: e, color: FD.PAL[cart.length % FD.PAL.length] }); }
        });

        if (surfSrc) {
          var sf = FD.compile(surfSrc, ["x", "y"]);
          if (sf) {
            return {
              fns: [{ surf: sf, expr: "z = " + surfSrc, color: FD.PAL[0] }],
              mode: "surface", xr: dom || [-3, 3], yr: ydom || dom || [-3, 3]
            };
          }
        }

        if (implicitSrc) {
          var legend = implicitSrc.expr.replace(/\*\*/g, "^");
          if (implicitSrc.z) {
            var Lf = FD.compile(implicitSrc.L, ["x", "y", "z"]);
            var Rf = FD.compile(implicitSrc.R, ["x", "y", "z"]);
            if (Lf && Rf) {
              var h3 = function (x, y, z) { return Lf(x, y, z) - Rf(x, y, z); };
              var xr2 = dom || [-4, 4], yr2 = ydom || dom || [-4, 4];
              var M = Math.max(Math.abs(xr2[0]), Math.abs(xr2[1]), Math.abs(yr2[0]), Math.abs(yr2[1]));
              var zr2 = zdom || [-M * 1.08, M * 1.08];
              var sheets = FD.implicitSheets(h3, xr2, yr2, zr2), fxr = xr2, fyr = yr2;
              if (sheets.length && !dom && !zdom) {
                try {
                  var xlo = Infinity, xhi = -Infinity, ylo = Infinity, yhi = -Infinity;
                  var zlo = Infinity, zhi = -Infinity, found = 0, PB = 20;
                  for (var i2 = 0; i2 <= PB; i2++) {
                    for (var j2 = 0; j2 <= PB; j2++) {
                      var xq = xr2[0] + (xr2[1] - xr2[0]) * i2 / PB;
                      var yq = yr2[0] + (yr2[1] - yr2[0]) * j2 / PB;
                      for (var q2 = 0; q2 < sheets.length; q2++) {
                        var zq = sheets[q2](xq, yq);
                        if (isFinite(zq)) {
                          found++;
                          if (xq < xlo) { xlo = xq; }
                          if (xq > xhi) { xhi = xq; }
                          if (yq < ylo) { ylo = yq; }
                          if (yq > yhi) { yhi = yq; }
                          if (zq < zlo) { zlo = zq; }
                          if (zq > zhi) { zhi = zq; }
                        }
                      }
                    }
                  }
                  if (found > 4 && isFinite(xlo) && (xhi - xlo) > 1e-6
                    && (xhi - xlo) < (xr2[1] - xr2[0]) * 0.85) {
                    var pxp = (xhi - xlo) * 0.10;
                    var pyp = (yhi - ylo) * 0.10 + 1e-6;
                    var pzp = (zhi - zlo) * 0.10 + 1e-6;
                    var nx = [xlo - pxp, xhi + pxp];
                    var ny = [ylo - pyp, yhi + pyp];
                    var nz = [zlo - pzp, zhi + pzp];
                    var s2 = FD.implicitSheets(h3, nx, ny, nz);
                    if (s2.length) { sheets = s2; fxr = nx; fyr = ny; }
                  }
                } catch (_) {}
              }
              if (sheets.length) {
                return {
                  fns: sheets.map(function (sfn) {
                    return { surf: sfn, expr: legend, color: FD.PAL[0] };
                  }),
                  mode: "surface", xr: fxr, yr: fyr
                };
              }
            }
          } else {
            var Lf2 = FD.compile(implicitSrc.L, ["x", "y"]);
            var Rf2 = FD.compile(implicitSrc.R, ["x", "y"]);
            if (Lf2 && Rf2) {
              var h2 = function (x, y) { return Lf2(x, y) - Rf2(x, y); };
              var d2 = dom || [-6, 6], yd = ydom || d2;
              var ipts = FD.implicitCurve(h2, d2[0], d2[1], yd[0], yd[1]);
              if (ipts) {
                return {
                  fns: [{ points: ipts, expr: legend, color: FD.PAL[0] }],
                  mode: "implicit", bounds: FD.pointsBounds(ipts.filter(function (p) {
                    return isFinite(p[0]) && isFinite(p[1]);
                  }), true)
                };
              }
            }
          }
        }

        if (polarSrc) {
          var rf = FD.compile(polarSrc, ["theta"]);
          if (rf) {
            var pr = pdom || [0, 2 * Math.PI], NP = 720, ppts = [];
            for (var kp = 0; kp <= NP; kp++) {
              var th = pr[0] + (pr[1] - pr[0]) * kp / NP, rv;
              try { rv = rf(th); } catch (_) { rv = NaN; }
              if (isFinite(rv)) { ppts.push([rv * Math.cos(th), rv * Math.sin(th)]); }
            }
            if (ppts.length > 2) {
              return {
                fns: [{ points: ppts, expr: "r = " + polarSrc, color: FD.PAL[0] }],
                mode: "polar", bounds: FD.pointsBounds(ppts, true)
              };
            }
          }
        }

        if (px && py) {
          var fx = FD.compile(px, ["t"]), fy = FD.compile(py, ["t"]);
          if (fx && fy) {
            var tr = pdom || [0, 2 * Math.PI], NT = 720, tpts = [];
            for (var kt = 0; kt <= NT; kt++) {
              var tv = tr[0] + (tr[1] - tr[0]) * kt / NT, xv, yv;
              try { xv = fx(tv); yv = fy(tv); } catch (_) { xv = NaN; yv = NaN; }
              if (isFinite(xv) && isFinite(yv)) { tpts.push([xv, yv]); }
            }
            if (tpts.length > 2) {
              return {
                fns: [{ points: tpts, expr: "x = " + px + ", y = " + py, color: FD.PAL[0] }],
                mode: "parametric", bounds: FD.pointsBounds(tpts, false)
              };
            }
          }
        }

        if (!cart.length) { return null; }
        return { fns: cart, dom: dom || [-6, 6], mode: "cartesian" };
      };
    })(window.FD);
    """#
}
