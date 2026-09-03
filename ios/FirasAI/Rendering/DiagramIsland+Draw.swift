import Foundation

/// The drawing half of the ported engine: the 2D figure, the isometric 3D surface, and the touch
/// handling the full-screen viewer turns on. `DiagramIsland+Tikz.swift` carries the TikZ path and
/// the entry point.
///
/// | app.js | here |
/// |---|---|
/// | `plotSvgString` (`8880`) | `FD.plotSvg` |
/// | `plot3dSurfaceSvg` (`8514`) | `FD.surfaceSvg` |
/// | `clipSegToView` (`8996`) | `FD.clipSeg` |
/// | `makePlotInteractive` (`9020`) | `FD.attachPlot` |
/// | `make3dInteractive` (`8586`) | `FD.attach3D` |
///
/// The 3D path is the website's own: an isometric, height-shaded, painter-sorted wireframe emitted
/// as SVG. That is what "عدنا رسم تو دي و ثري دي" means on the web — there is no WebGL scene in a
/// chat answer there, and putting one here would be a different product.
extension DiagramRuntime {

    static let drawJS = #"""
    window.FD = window.FD || {};
    (function (FD) {
      "use strict";

      var CS = window.getComputedStyle(document.documentElement);
      var TOK = function (name, fallback) {
        var v = CS.getPropertyValue(name);
        v = v ? v.trim() : "";
        return v || fallback;
      };
      var INK = TOK("--ink", "#111827");
      var HALO = TOK("--halo", "#faf9f5");
      var EDGE = TOK("--edge", "#e5e7eb");
      var C1 = TOK("--c1", "#237a68");
      var C3 = TOK("--c3", "#ef4444");
      var C4 = TOK("--c4", "#d97706");
      var C5 = TOK("--c5", "#7c3aed");
      var seq = 0;

      /* ── Liang–Barsky clip, for an infinite `line` command. ──────────────────────────────── */
      FD.clipSeg = function (a, b, xmin, xmax, ymin, ymax) {
        var t0 = 0, t1 = 1, dx = b[0] - a[0], dy = b[1] - a[1];
        var clip = function (p, q) {
          if (Math.abs(p) < 1e-12) { return q >= 0; }
          var r = q / p;
          if (p < 0) { if (r > t1) { return false; } if (r > t0) { t0 = r; } }
          else { if (r < t0) { return false; } if (r < t1) { t1 = r; } }
          return true;
        };
        if (clip(-dx, a[0] - xmin) && clip(dx, xmax - a[0])
          && clip(-dy, a[1] - ymin) && clip(dy, ymax - a[1])) {
          return [[a[0] + t0 * dx, a[1] + t0 * dy], [a[0] + t1 * dx, a[1] + t1 * dy]];
        }
        return null;
      };

      /* ── THE 2D FIGURE ──────────────────────────────────────────────────────────────────── */
      FD.plotSvg = function (fns, view, opts) {
        opts = opts || {};
        var xmin = view.xmin, xmax = view.xmax, ymin = view.ymin, ymax = view.ymax;
        var W = FD.W, H = FD.H, L = FD.L, T = FD.T, pw = FD.PW, ph = FD.PH;
        var sx = function (x) { return L + (x - xmin) / (xmax - xmin) * pw; };
        var sy = function (y) { return T + (ymax - y) / (ymax - ymin) * ph; };
        var nice = function (range, n) {
          var raw = range / n;
          var mag = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10));
          var u = raw / mag;
          return (u < 1.5 ? 1 : u < 3 ? 2 : u < 7 ? 5 : 10) * mag;
        };
        var fmt = function (v) {
          var r = Math.round(v * 1000) / 1000;
          return String(Math.abs(r) < 1e-9 ? 0 : r);
        };
        var xStep = nice(xmax - xmin, 8), yStep = nice(ymax - ymin, 6);
        var id = "pl" + (seq++);
        var grid = "", ax = "", curves = "", x, y, X, Y;

        if (opts.polar) {
          var cx = sx(0), cy = sy(0);
          var rMax = Math.max(Math.abs(xmin), Math.abs(xmax), Math.abs(ymin), Math.abs(ymax));
          var rStep = nice(rMax, 5), pxX = pw / (xmax - xmin), pxY = ph / (ymax - ymin);
          for (var r = rStep; r <= rMax * 1.02; r += rStep) {
            grid += '<ellipse class="plot-grid" cx="' + cx.toFixed(1) + '" cy="' + cy.toFixed(1)
              + '" rx="' + (r * pxX).toFixed(1) + '" ry="' + (r * pxY).toFixed(1) + '" fill="none"/>';
            grid += '<text class="plot-tick" x="' + (cx + r * pxX + 3).toFixed(1)
              + '" y="' + (cy - 3).toFixed(1) + '">' + fmt(r) + '</text>';
          }
          for (var deg = 0; deg < 360; deg += 30) {
            var an = deg * Math.PI / 180;
            grid += '<line class="plot-grid" x1="' + cx.toFixed(1) + '" y1="' + cy.toFixed(1)
              + '" x2="' + (cx + Math.cos(an) * rMax * pxX).toFixed(1)
              + '" y2="' + (cy - Math.sin(an) * rMax * pxY).toFixed(1) + '"/>';
          }
          ax += '<line class="plot-axis" x1="' + L + '" y1="' + cy.toFixed(1) + '" x2="'
            + (L + pw).toFixed(1) + '" y2="' + cy.toFixed(1) + '" marker-end="url(#' + id + 'a)"/>';
          ax += '<line class="plot-axis" x1="' + cx.toFixed(1) + '" y1="' + (T + ph).toFixed(1)
            + '" x2="' + cx.toFixed(1) + '" y2="' + T + '" marker-end="url(#' + id + 'a)"/>';
        } else {
          for (x = Math.ceil(xmin / xStep) * xStep; x <= xmax + 1e-9; x += xStep) {
            X = sx(x);
            grid += '<line class="plot-grid" x1="' + X.toFixed(1) + '" y1="' + T + '" x2="'
              + X.toFixed(1) + '" y2="' + (T + ph).toFixed(1) + '"/>';
            if (Math.abs(x) > 1e-9) {
              grid += '<text class="plot-tick" x="' + X.toFixed(1) + '" y="'
                + (T + ph + 14).toFixed(1) + '" text-anchor="middle">' + fmt(x) + '</text>';
            }
          }
          for (y = Math.ceil(ymin / yStep) * yStep; y <= ymax + 1e-9; y += yStep) {
            Y = sy(y);
            grid += '<line class="plot-grid" x1="' + L + '" y1="' + Y.toFixed(1) + '" x2="'
              + (L + pw).toFixed(1) + '" y2="' + Y.toFixed(1) + '"/>';
            if (Math.abs(y) > 1e-9) {
              grid += '<text class="plot-tick" x="' + (L - 5).toFixed(1) + '" y="'
                + (Y + 3).toFixed(1) + '" text-anchor="end">' + fmt(y) + '</text>';
            }
          }
          if (0 >= ymin && 0 <= ymax) {
            Y = sy(0);
            ax += '<line class="plot-axis" x1="' + L + '" y1="' + Y.toFixed(1) + '" x2="'
              + (L + pw).toFixed(1) + '" y2="' + Y.toFixed(1) + '" marker-end="url(#' + id + 'a)"/>'
              + '<text class="plot-axislabel" x="' + (L + pw - 3).toFixed(1) + '" y="'
              + (Y - 6).toFixed(1) + '" text-anchor="end">x</text>';
          }
          if (0 >= xmin && 0 <= xmax) {
            X = sx(0);
            ax += '<line class="plot-axis" x1="' + X.toFixed(1) + '" y1="' + (T + ph).toFixed(1)
              + '" x2="' + X.toFixed(1) + '" y2="' + T + '" marker-end="url(#' + id + 'a)"/>'
              + '<text class="plot-axislabel" x="' + (X + 7).toFixed(1) + '" y="'
              + (T + 9).toFixed(1) + '">y</text>';
          }
        }

        var N = 500, span = ymax - ymin;
        fns.forEach(function (f) {
          var d = "", up = true;
          if (f.points) {
            f.points.forEach(function (p) {
              var xv = p[0], yv = p[1];
              if (!isFinite(xv) || !isFinite(yv) || xv < xmin - span || xv > xmax + span
                || yv < ymin - span || yv > ymax + span) { up = true; return; }
              d += (up ? "M" : "L")
                + sx(Math.max(xmin, Math.min(xmax, xv))).toFixed(1) + " "
                + sy(Math.max(ymin, Math.min(ymax, yv))).toFixed(1) + " ";
              up = false;
            });
          } else {
            for (var k = 0; k <= N; k++) {
              var xk = xmin + (xmax - xmin) * k / N, yk;
              try { yk = f.fn(xk); } catch (_) { yk = NaN; }
              if (typeof yk !== "number" || !isFinite(yk) || yk < ymin - span || yk > ymax + span) {
                up = true;
                continue;
              }
              d += (up ? "M" : "L") + sx(xk).toFixed(1) + " "
                + sy(Math.max(ymin, Math.min(ymax, yk))).toFixed(1) + " ";
              up = false;
            }
          }
          if (d) {
            curves += '<path class="plot-curve" style="stroke:' + f.color + '" d="' + d + '"/>';
          }
        });

        var shapesSvg = "";
        if (opts.shapes && opts.shapes.length) {
          var pX = pw / (xmax - xmin), pY = ph / (ymax - ymin);
          var SX = function (p) { return sx(p[0]); };
          var SY = function (p) { return sy(p[1]); };
          var fillOf = function (col) {
            var hx = String(col).replace("#", "");
            if (hx.length === 6) {
              return "rgba(" + parseInt(hx.slice(0, 2), 16) + "," + parseInt(hx.slice(2, 4), 16)
                + "," + parseInt(hx.slice(4, 6), 16) + ",0.13)";
            }
            return "rgba(59,130,246,0.13)";
          };
          var dashA = function (s) { return s.dash ? ' stroke-dasharray="5 4"' : ""; };
          var txt = function (tx, ty, str, col, anchor) {
            return '<text x="' + tx.toFixed(1) + '" y="' + ty.toFixed(1) + '" fill="' + col
              + '" font-size="13" font-weight="600"'
              + (anchor ? ' text-anchor="' + anchor + '"' : "")
              + ' style="font-family:-apple-system,BlinkMacSystemFont,sans-serif"'
              + ' paint-order="stroke" stroke="' + HALO + '" stroke-width="2.6"'
              + ' stroke-linejoin="round">' + FD.escapeHtml(str) + '</text>';
          };
          var head = function (x1, y1, x2, y2, col) {
            var dx = x2 - x1, dy = y2 - y1, len = Math.sqrt(dx * dx + dy * dy) || 1;
            var ux = dx / len, uy = dy / len, sz = 9, wd = 4.2;
            var bx = x2 - ux * sz, by = y2 - uy * sz;
            return '<polygon points="' + x2.toFixed(1) + " " + y2.toFixed(1) + " "
              + (bx - uy * wd).toFixed(1) + " " + (by + ux * wd).toFixed(1) + " "
              + (bx + uy * wd).toFixed(1) + " " + (by - ux * wd).toFixed(1)
              + '" fill="' + col + '"/>';
          };
          opts.shapes.forEach(function (s) {
            var c = s.col || null, col, aX, aY, bX, bY, dd, k, t;
            if (s.t === "point") {
              col = c || C3;
              aX = SX(s.p); aY = SY(s.p);
              shapesSvg += '<circle cx="' + aX.toFixed(1) + '" cy="' + aY.toFixed(1)
                + '" r="3.7" fill="' + col + '" stroke="' + HALO + '" stroke-width="1.3"/>';
              if (s.lb) { shapesSvg += txt(aX + 7, aY - 7, s.lb, col); }
            } else if (s.t === "text") {
              shapesSvg += txt(SX(s.p), SY(s.p), s.lb, c || INK, "middle");
            } else if (s.t === "segment" || s.t === "line" || s.t === "vector") {
              var pa = s.a, pb = s.b;
              if (s.extend) {
                var cl = FD.clipSeg(pa, pb, xmin, xmax, ymin, ymax);
                if (cl) { pa = cl[0]; pb = cl[1]; }
              }
              col = c || (s.t === "vector" ? C5 : INK);
              aX = SX(pa); aY = SY(pa); bX = SX(pb); bY = SY(pb);
              shapesSvg += '<line x1="' + aX.toFixed(1) + '" y1="' + aY.toFixed(1) + '" x2="'
                + bX.toFixed(1) + '" y2="' + bY.toFixed(1) + '" stroke="' + col
                + '" stroke-width="2.1" stroke-linecap="round"' + dashA(s) + '/>';
              if (s.t === "vector") { shapesSvg += head(aX, aY, bX, bY, col); }
              if (s.lb) { shapesSvg += txt((aX + bX) / 2 + 6, (aY + bY) / 2 - 6, s.lb, col); }
            } else if (s.t === "circle") {
              col = c || C1; aX = SX(s.c); aY = SY(s.c);
              shapesSvg += '<ellipse cx="' + aX.toFixed(1) + '" cy="' + aY.toFixed(1) + '" rx="'
                + (s.r * pX).toFixed(1) + '" ry="' + (s.r * pY).toFixed(1) + '" fill="'
                + (s.fill ? fillOf(col) : "none") + '" stroke="' + col + '" stroke-width="2"'
                + dashA(s) + '/>';
              shapesSvg += '<circle cx="' + aX.toFixed(1) + '" cy="' + aY.toFixed(1)
                + '" r="2.4" fill="' + col + '"/>';
              if (s.lb) { shapesSvg += txt(aX, aY - s.r * pY - 6, s.lb, col, "middle"); }
            } else if (s.t === "ellipse") {
              col = c || C1; aX = SX(s.c); aY = SY(s.c);
              shapesSvg += '<ellipse cx="' + aX.toFixed(1) + '" cy="' + aY.toFixed(1) + '" rx="'
                + (s.rx * pX).toFixed(1) + '" ry="' + (s.ry * pY).toFixed(1) + '" fill="'
                + (s.fill ? fillOf(col) : "none") + '" stroke="' + col + '" stroke-width="2"'
                + dashA(s) + '/>';
              if (s.lb) { shapesSvg += txt(aX, aY - s.ry * pY - 6, s.lb, col, "middle"); }
            } else if (s.t === "poly") {
              col = c || C1;
              var pl = s.pts.map(function (p) {
                return SX(p).toFixed(1) + "," + SY(p).toFixed(1);
              }).join(" ");
              shapesSvg += '<polygon points="' + pl + '" fill="'
                + (s.fill ? fillOf(col) : "none") + '" stroke="' + col
                + '" stroke-width="2" stroke-linejoin="round"' + dashA(s) + '/>';
              if (s.lb) {
                var mx = s.pts.reduce(function (a2, p) { return a2 + p[0]; }, 0) / s.pts.length;
                var my = s.pts.reduce(function (a2, p) { return a2 + p[1]; }, 0) / s.pts.length;
                shapesSvg += txt(SX([mx, my]), SY([mx, my]), s.lb, col, "middle");
              }
            } else if (s.t === "arc") {
              col = c || C1;
              var a1 = s.a1 * Math.PI / 180, a2 = s.a2 * Math.PI / 180;
              dd = "";
              for (k = 0; k <= 48; k++) {
                t = a1 + (a2 - a1) * k / 48;
                var ap = [s.c[0] + s.r * Math.cos(t), s.c[1] + s.r * Math.sin(t)];
                dd += (k ? "L" : "M") + SX(ap).toFixed(1) + " " + SY(ap).toFixed(1) + " ";
              }
              shapesSvg += '<path d="' + dd + '" fill="none" stroke="' + col
                + '" stroke-width="2"' + dashA(s) + '/>';
            } else if (s.t === "angle") {
              col = c || C4;
              var vX = SX(s.v), vY = SY(s.v);
              var ang1 = Math.atan2(SY(s.a) - vY, SX(s.a) - vX);
              var ang2 = Math.atan2(SY(s.b) - vY, SX(s.b) - vX);
              var dA = ang2 - ang1;
              while (dA > Math.PI) { dA -= 2 * Math.PI; }
              while (dA < -Math.PI) { dA += 2 * Math.PI; }
              var rr = 22;
              dd = "";
              for (k = 0; k <= 24; k++) {
                t = ang1 + dA * k / 24;
                dd += (k ? "L" : "M") + (vX + rr * Math.cos(t)).toFixed(1) + " "
                  + (vY + rr * Math.sin(t)).toFixed(1) + " ";
              }
              shapesSvg += '<path d="' + dd + '" fill="none" stroke="' + col + '" stroke-width="2"/>';
              if (s.lb) {
                var mt = ang1 + dA / 2;
                shapesSvg += txt(vX + (rr + 13) * Math.cos(mt),
                  vY + (rr + 13) * Math.sin(mt) + 4, s.lb, col, "middle");
              }
            }
          });
        }

        return '<svg viewBox="0 0 ' + W + " " + H + '" width="' + W + '" height="' + H
          + '" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="figure">'
          + '<defs><clipPath id="' + id + 'c"><rect x="' + L + '" y="' + T + '" width="' + pw
          + '" height="' + ph + '"/></clipPath>'
          + '<marker id="' + id + 'a" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6.5"'
          + ' markerHeight="6.5" orient="auto-start-reverse">'
          + '<path class="plot-arrow" d="M0 0L10 5L0 10z"/></marker></defs>'
          + '<rect class="plot-bg" x="' + L + '" y="' + T + '" width="' + pw + '" height="' + ph
          + '" rx="6"/>'
          /* The grid is clipped here and is NOT on the web. There the page ground and the plot
             ground are the same colour, so a polar ring running past the frame is invisible; on a
             dark card over a lighter surface it reads as a scratch. The axes stay unclipped — their
             arrowheads live a few pixels outside the frame by design. */
          + '<g clip-path="url(#' + id + 'c)">' + grid + '</g>' + ax
          + '<g clip-path="url(#' + id + 'c)">' + curves + shapesSvg + '</g></svg>';
      };

      /* ── THE 3D SURFACE — isometric, height-shaded, painter-sorted. ──────────────────────── */
      FD.surfaceSvg = function (fns, xr, yr, view) {
        view = view || {};
        var az = view.az !== undefined ? view.az : -0.85;
        var el = view.el !== undefined ? view.el : 0.52;
        var zoom = view.zoom || 1;
        var x0 = xr[0], x1 = xr[1], y0 = yr[0], y1 = yr[1];
        var N = fns.length > 1 ? 56 : 34;
        var zmin = Infinity, zmax = -Infinity;
        var grids = fns.map(function (f) {
          var P = [];
          for (var i = 0; i <= N; i++) {
            P[i] = [];
            for (var j = 0; j <= N; j++) {
              var x = x0 + (x1 - x0) * i / N, y = y0 + (y1 - y0) * j / N, z;
              try { z = f(x, y); } catch (_) { z = NaN; }
              if (!isFinite(z)) { z = NaN; }
              P[i][j] = { x: x, y: y, z: z };
              if (isFinite(z)) {
                if (z < zmin) { zmin = z; }
                if (z > zmax) { zmax = z; }
              }
            }
          }
          return P;
        });
        if (!isFinite(zmin)) { zmin = -1; zmax = 1; }
        var zc = (zmax - zmin) || 1, span = Math.max(x1 - x0, y1 - y0) || 1;
        var zEx = Math.min(Math.max(span * 0.6 / zc, 1), span * 0.85 / zc, 2.4);
        var W = 480, H = 360, cx = W / 2, cy = H * 0.54;
        var scale = Math.min(W, H) * 0.46 / span * zoom;
        var mx = (x0 + x1) / 2, my = (y0 + y1) / 2, mz = (zmin + zmax) / 2;
        var ca = Math.cos(az), sa = Math.sin(az), ce = Math.cos(el), se = Math.sin(el);
        var world = function (x, y, z) {
          return [x - mx, y - my, ((isFinite(z) ? z : mz) - mz) * zEx];
        };
        var proj = function (w) {
          var xr1 = w[0] * ca - w[1] * sa, yr1 = w[0] * sa + w[1] * ca, z1 = w[2];
          var y2 = yr1 * ce - z1 * se, z2 = yr1 * se + z1 * ce;
          return [cx + xr1 * scale, cy - z2 * scale, y2];
        };
        var rot = function (v) {
          var xr1 = v[0] * ca - v[1] * sa, yr1 = v[0] * sa + v[1] * ca, z1 = v[2];
          return [xr1, yr1 * ce - z1 * se, yr1 * se + z1 * ce];
        };
        var Lv = [-0.32, -0.5, 0.8];
        var Ln = Math.sqrt(Lv[0] * Lv[0] + Lv[1] * Lv[1] + Lv[2] * Lv[2]);
        Lv[0] /= Ln; Lv[1] /= Ln; Lv[2] /= Ln;
        var col = function (z, shade) {
          var t = isFinite(z) ? Math.max(0, Math.min(1, (z - zmin) / zc)) : 0.5;
          var r = (48 + t * 210) * shade, g = (46 + t * 150) * shade, b = (130 - t * 80) * shade;
          return "rgb(" + Math.round(Math.min(255, r)) + "," + Math.round(Math.min(255, g))
            + "," + Math.round(Math.min(255, b)) + ")";
        };
        var quads = [];
        grids.forEach(function (P) {
          for (var i = 0; i < N; i++) {
            for (var j = 0; j < N; j++) {
              var corners = [P[i][j], P[i + 1][j], P[i + 1][j + 1], P[i][j + 1]]
                .filter(function (p) { return isFinite(p.z); });
              if (corners.length < 3) { continue; }
              var zlo = Infinity, zhi = -Infinity;
              corners.forEach(function (p) {
                if (p.z < zlo) { zlo = p.z; }
                if (p.z > zhi) { zhi = p.z; }
              });
              if (zhi - zlo > zc * 0.45) { continue; }
              var ws = corners.map(function (p) { return world(p.x, p.y, p.z); });
              var ux = ws[2][0] - ws[0][0], uy = ws[2][1] - ws[0][1], uz = ws[2][2] - ws[0][2];
              var vx = ws[1][0] - ws[0][0], vy = ws[1][1] - ws[0][1], vz = ws[1][2] - ws[0][2];
              var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
              var nl = Math.sqrt(nx * nx + ny * ny + nz * nz) || 1;
              var rn = rot([nx / nl, ny / nl, nz / nl]);
              var dot = Math.abs(rn[0] * Lv[0] + rn[1] * Lv[1] + rn[2] * Lv[2]);
              var shade = 0.52 + 0.48 * dot;
              var zAvg = corners.reduce(function (a, p) { return a + p.z; }, 0) / corners.length;
              var ps = ws.map(proj);
              var depth = ps.reduce(function (a, p) { return a + p[2]; }, 0) / ps.length;
              quads.push({
                depth: depth,
                d: "M" + ps.map(function (p) {
                  return p[0].toFixed(1) + " " + p[1].toFixed(1);
                }).join("L") + "Z",
                fill: col(zAvg, shade)
              });
            }
          }
        });
        quads.sort(function (p, q) { return q.depth - p.depth; });
        var faces = quads.map(function (q) {
          return '<path d="' + q.d + '" fill="' + q.fill + '" stroke="' + HALO
            + '" stroke-width="0.3" stroke-opacity="0.35"/>';
        }).join("");
        return '<svg viewBox="0 0 ' + W + " " + H + '" width="' + W + '" height="' + H
          + '" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="3D surface">'
          + '<rect x="0" y="0" width="' + W + '" height="' + H + '" fill="var(--bg)" rx="8"/>'
          + faces + '</svg>';
      };

      /* ── TOUCH — pan and pinch on a 2D figure, drag-rotate and pinch on a 3D one. ────────── */
      var swap = function (host, html) {
        var old = host.querySelector("svg");
        if (!old) { return; }
        var tmp = document.createElement("div");
        tmp.innerHTML = html;
        var next = tmp.firstElementChild;
        if (next) { host.replaceChild(next, old); }
      };
      var pointers = function (host, onPan, onPinch, onEnd) {
        var pts = new Map(), pan = null, pinch = null;
        host.style.touchAction = "none";
        host.addEventListener("pointerdown", function (e) {
          if (e.target.closest && e.target.closest(".reset")) { return; }
          try { host.setPointerCapture(e.pointerId); } catch (_) {}
          pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
          if (pts.size === 1) { pan = { x: e.clientX, y: e.clientY }; pinch = null; }
          else if (pts.size === 2) {
            var a = Array.from(pts.values());
            pinch = { d: Math.hypot(a[0].x - a[1].x, a[0].y - a[1].y) };
            pan = null;
          }
          host.classList.add("grabbing");
        });
        host.addEventListener("pointermove", function (e) {
          if (!pts.has(e.pointerId)) { return; }
          pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
          var a = Array.from(pts.values());
          if (a.length === 2 && pinch) {
            var nd = Math.hypot(a[0].x - a[1].x, a[0].y - a[1].y);
            if (nd > 0 && pinch.d > 0) { onPinch(pinch.d / nd); }
            pinch.d = nd;
          } else if (a.length === 1 && pan) {
            onPan(e.clientX - pan.x, e.clientY - pan.y);
            pan.x = e.clientX;
            pan.y = e.clientY;
          }
        });
        var stop = function (e) {
          pts.delete(e.pointerId);
          if (pts.size < 2) { pinch = null; }
          if (pts.size === 0) { pan = null; host.classList.remove("grabbing"); onEnd(); }
        };
        host.addEventListener("pointerup", stop);
        host.addEventListener("pointercancel", stop);
      };
      var resetButton = function (host, onReset) {
        var b = document.createElement("button");
        b.type = "button";
        b.className = "reset";
        b.textContent = "⟲";
        b.setAttribute("aria-label", "reset");
        b.addEventListener("click", function (e) { e.stopPropagation(); onReset(); });
        host.appendChild(b);
      };

      FD.attachPlot = function (host, fns, home, opts) {
        var view = { xmin: home.xmin, xmax: home.xmax, ymin: home.ymin, ymax: home.ymax };
        var raf = 0;
        var paint = function () {
          raf = 0;
          swap(host, FD.plotSvg(fns, view, opts));
        };
        var schedule = function () { if (!raf) { raf = requestAnimationFrame(paint); } };
        pointers(host, function (dx, dy) {
          var box = host.getBoundingClientRect();
          if (box.width < 1 || box.height < 1) { return; }
          var ux = dx / box.width * FD.W / FD.PW * (view.xmax - view.xmin);
          var uy = dy / box.height * FD.H / FD.PH * (view.ymax - view.ymin);
          view.xmin -= ux; view.xmax -= ux; view.ymin += uy; view.ymax += uy;
          schedule();
        }, function (factor) {
          var mx = (view.xmin + view.xmax) / 2, my = (view.ymin + view.ymax) / 2;
          var hx = (view.xmax - view.xmin) / 2 * factor, hy = (view.ymax - view.ymin) / 2 * factor;
          if (hx < 1e-7 || hx > 1e9 || hy < 1e-7 || hy > 1e9) { return; }
          view.xmin = mx - hx; view.xmax = mx + hx; view.ymin = my - hy; view.ymax = my + hy;
          schedule();
        }, function () {});
        resetButton(host, function () {
          view = { xmin: home.xmin, xmax: home.xmax, ymin: home.ymin, ymax: home.ymax };
          schedule();
        });
      };

      FD.attach3D = function (host, surfs, xr, yr) {
        var st = { az: -0.85, el: 0.52, zoom: 1 }, raf = 0;
        var paint = function () {
          raf = 0;
          swap(host, FD.surfaceSvg(surfs, xr, yr, st));
        };
        var schedule = function () { if (!raf) { raf = requestAnimationFrame(paint); } };
        pointers(host, function (dx, dy) {
          st.az += dx * 0.01;
          st.el = Math.max(-1.45, Math.min(1.45, st.el + dy * 0.01));
          schedule();
        }, function (factor) {
          st.zoom = Math.max(0.4, Math.min(5, st.zoom / factor));
          schedule();
        }, function () {});
        resetButton(host, function () {
          st.az = -0.85; st.el = 0.52; st.zoom = 1;
          schedule();
        });
      };

    })(window.FD);
    """#
}
