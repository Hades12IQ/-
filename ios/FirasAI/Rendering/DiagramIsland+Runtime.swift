import Foundation
import SwiftUI
import UIKit

/// The document the island loads: a themed page, the ported drawing engine, and a bootstrap that
/// reports the figure's real height back to SwiftUI.
///
/// Everything is inline. No stylesheet, no script and no font is fetched, so the page renders with
/// the aeroplane mode on and there is no frame in which the card shows an empty box waiting for a
/// network round trip.
enum DiagramRuntime {

    /// The whole document, ready for `loadHTMLString`.
    static func page(
        spec: DiagramSpec,
        palette: FirasPalette,
        interactive: Bool
    ) -> String {
        let config = configJSON(spec: spec, interactive: interactive)
        return head(palette: palette)
            + "<body><div id=\"stage\" class=\"" + spec.kind.rawValue + "\"></div>"
            + "<script>window.__FIRAS_DIAGRAM=" + config + ";</script>"
            + "<script>" + engineJS + "</script>"
            + "<script>" + grammarJS + "</script>"
            + "<script>" + drawJS + "</script>"
            + "<script>" + tikzJS + "</script>"
            + "<script>" + bootstrapJS + "</script>"
            + "</body></html>"
    }

    /// The theme tokens the page paints with, as one short string. The island reloads when this
    /// changes and stays put when anything else does — so every token `head` actually writes into
    /// the stylesheet has to appear here, or a theme that moves only the grid colour leaves the
    /// figure painted in the old one.
    static func paletteSignature(_ palette: FirasPalette) -> String {
        cssColor(palette.surfaceSunken) + cssColor(palette.textPrimary)
            + cssColor(palette.textSecondary) + cssColor(palette.border) + cssColor(palette.accent)
    }

    // MARK: - Head

    private static func head(palette: FirasPalette) -> String {
        let ink = cssColor(palette.textPrimary)
        let muted = cssColor(palette.textSecondary)
        let plotBackground = cssColor(palette.surfaceSunken)
        let border = cssColor(palette.border)
        let accent = cssColor(palette.accent)
        // The four companions of the accent are the web's own plot palette (`app.js:8675`,
        // `PLOT_PAL`); only the first slot follows the theme, exactly as `--plot-c1` does there.
        let style = ":root{"
            + "--ink:" + ink + ";"
            + "--muted:" + muted + ";"
            + "--bg:" + plotBackground + ";"
            + "--halo:" + plotBackground + ";"
            + "--grid:" + border + ";"
            + "--axis:" + muted + ";"
            + "--edge:" + border + ";"
            + "--c1:" + accent + ";"
            + "--c2:#3B82F6;--c3:#EF4444;--c4:#D97706;--c5:#7C3AED}"
            + "*{box-sizing:border-box}"
            + "html,body{margin:0;padding:0;background:transparent;"
            + "-webkit-text-size-adjust:100%;overflow:hidden}"
            + "body{font:13px/1.5 -apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif;"
            + "color:var(--ink)}"
            + "#stage{width:100%;padding:0;margin:0}"
            + "#stage.plot svg{width:100%;height:auto;display:block}"
            + "#stage.tikz svg{max-width:100%;height:auto;display:block;margin:0 auto}"
            + ".plot-bg{fill:var(--bg);stroke:var(--edge);stroke-width:1}"
            + ".plot-grid{stroke:var(--grid);stroke-width:1;fill:none;opacity:.75}"
            + ".plot-axis{stroke:var(--axis);stroke-width:1.4}"
            + ".plot-arrow{fill:var(--axis)}"
            + ".plot-tick{fill:var(--muted);font-size:9px}"
            + ".plot-axislabel{fill:var(--axis);font-size:10.5px;font-style:italic}"
            + ".plot-curve{fill:none;stroke-width:2.1;stroke-linecap:round;stroke-linejoin:round}"
            + ".tikz-lbl{fill:var(--ink);font-size:12px;"
            + "font-family:-apple-system,BlinkMacSystemFont,sans-serif}"
            + ".legend{direction:ltr;text-align:left;margin:8px 2px 0;display:flex;"
            + "flex-direction:column;gap:4px}"
            + ".legend-row{display:flex;align-items:center;gap:7px;font:12px/1.4 "
            + "ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted)}"
            + ".legend-sw{width:14px;height:3px;border-radius:2px;flex:0 0 auto}"
            + ".legend-lb{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}"
            + ".reset{position:absolute;top:8px;inset-inline-end:8px;width:30px;height:30px;"
            + "border-radius:15px;border:1px solid var(--edge);background:var(--bg);"
            + "color:var(--muted);font-size:14px;line-height:1;padding:0;cursor:pointer}"
            + ".wrap{position:relative}"
            + ".grabbing{cursor:grabbing}"
        return "<!DOCTYPE html><html lang=\"en\" dir=\"ltr\"><head><meta charset=\"utf-8\">"
            + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,"
            + "maximum-scale=1,user-scalable=no\">"
            + "<style>" + style + "</style></head>"
    }

    // MARK: - Config

    private static func configJSON(
        spec: DiagramSpec,
        interactive: Bool
    ) -> String {
        let payload: [String: Any] = [
            "kind": spec.kind.rawValue,
            "mode": spec.mode.rawValue,
            "source": spec.source,
            "interactive": interactive,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        // A model-authored figure may legitimately contain the characters `</script>`; escaping the
        // solidus keeps the JSON valid and keeps the tag from closing itself early.
        return text.replacingOccurrences(of: "</", with: "<\\/")
    }

    // MARK: - Colours

    /// A palette token as `#RRGGBB`. The six themes are built from fixed hex, so nothing here has to
    /// resolve a trait collection.
    static func cssColor(_ color: Color) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#808080"
        }
        let byte: (CGFloat) -> String = { value in
            let scaled = Int((min(max(value, 0), 1) * 255).rounded())
            let digits = String(scaled, radix: 16, uppercase: true)
            return digits.count == 1 ? "0" + digits : digits
        }
        return "#" + byte(red) + byte(green) + byte(blue)
    }

    // MARK: - Bootstrap

    /// Draws, restores the axis numbers, then measures, then tells SwiftUI.
    static let bootstrapJS = #"""
    (function () {
      "use strict";
      var CFG = window.__FIRAS_DIAGRAM || {};
      var stage = document.getElementById("stage");
      function post(message) {
        try { window.webkit.messageHandlers.firasdiagram.postMessage(message); } catch (_) {}
      }

      /* THE NUMBERS ON THE AXES.
         `FD.plotSvg` puts the grid lines and every tick label in one group, and then draws that
         group inside the figure's clip rectangle. The web does not: `plotSvgString` emits
         `grid + ax + <g clip-path>curves + shapes</g>` (`app.js:9013`), and it cannot clip the
         grid, because a tick label is deliberately placed OUTSIDE the frame — the x numbers 14px
         below it and the y numbers 5px to its left, in the two gutters the figure reserves for
         exactly that. The SVG has its own fixed axes and is always drawn left to right, whatever
         the language around it, so left and below are literal here. Clipping that group erased
         every number on both axes: a curve, a grid, and two empty gutters where the scale should
         be — a graph nobody can read a value off.
         So put the two gutters back: a label that sits left of the frame or below it belongs to an
         axis and is lifted into the <svg> itself, where the web has it. A label INSIDE the frame is
         a polar ring's radius, and it stays clipped along with its ring — that clip is this app's
         own and worth keeping, because on a card whose ground is darker than the page a ring
         running past the frame reads as a scratch, and a radius floating beside a ring that was
         cut away is worse than no radius at all.
         Idempotent: a label that has been lifted is no longer inside a clipped group. */
      function liftTicks() {
        if (!stage) { return; }
        var svgs = stage.querySelectorAll("svg");
        for (var s = 0; s < svgs.length; s++) {
          var svg = svgs[s];
          var frame = svg.querySelector("clipPath > rect");
          if (!frame) { continue; }
          var left = parseFloat(frame.getAttribute("x"));
          var foot = parseFloat(frame.getAttribute("y")) + parseFloat(frame.getAttribute("height"));
          if (!isFinite(left) || !isFinite(foot)) { continue; }
          var clipped = svg.querySelectorAll("g[clip-path] > text.plot-tick");
          for (var t = 0; t < clipped.length; t++) {
            var label = clipped[t];
            var lx = parseFloat(label.getAttribute("x"));
            var ly = parseFloat(label.getAttribute("y"));
            if (lx < left || ly > foot) { svg.appendChild(label); }
          }
        }
      }

      function measure() {
        var h = stage ? stage.getBoundingClientRect().height : 0;
        post({ t: "h", h: Math.ceil(h) });
      }
      function fail(why) {
        if (stage) { stage.innerHTML = ""; }
        post({ t: "phase", p: "failed", why: why || "engine" });
        post({ t: "h", h: 0 });
      }
      function draw() {
        if (!stage || typeof FD === "undefined" || typeof FD.render !== "function") {
          fail("engine");
          return;
        }
        post({ t: "phase", p: "loading" });
        var outcome;
        try { outcome = FD.render(stage, CFG); } catch (_) { outcome = null; }
        if (!outcome || !outcome.ok) { fail(outcome ? outcome.why : "engine"); return; }
        liftTicks();
        post({ t: "phase", p: "ready" });
        requestAnimationFrame(function () { requestAnimationFrame(measure); });
      }

      window.addEventListener("resize", function () {
        requestAnimationFrame(measure);
      });
      if (typeof ResizeObserver === "function" && stage) {
        try { new ResizeObserver(function () { measure(); }).observe(stage); } catch (_) {}
      }
      /* The full-screen viewer replaces the whole <svg> on every pan and pinch frame, so the
         labels have to be lifted again each time one appears. The pass that follows our own
         appendChild finds nothing left to move and stops there. */
      if (typeof MutationObserver === "function" && stage) {
        try {
          new MutationObserver(function (records) {
            for (var r = 0; r < records.length; r++) {
              if (records[r].addedNodes.length) { liftTicks(); return; }
            }
          }).observe(stage, { childList: true, subtree: true });
        } catch (_) {}
      }
      draw();
    })();
    """#
}
