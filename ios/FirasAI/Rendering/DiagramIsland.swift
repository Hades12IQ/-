import SwiftUI
import UIKit
import WebKit

/// One drawing, drawn by the web's own renderer inside a caged `WKWebView`, reporting its rendered
/// height back so the card can size itself to the picture instead of guessing.
///
/// The island is deliberately offline. The website's figures are not drawn by a library — TikZ goes
/// through a hand-written mini interpreter (`app.js:7957-8175`) and every graph, geometry figure and
/// 3D surface through `parsePlotSpec` / `plotSvgString` / `plot3dSurfaceSvg` (`app.js:8322-9060`),
/// all of it plain JavaScript emitting SVG. That code is ported into `DiagramRuntime`, so the island
/// needs no CDN, no WASM download and no network at all: it draws instantly, in the air, in the
/// tunnel, and the picture it makes is the same picture the website makes.
///
/// One island per drawing, and the card tears it down when the row leaves the screen.
struct DiagramIsland: UIViewRepresentable {

    /// What the page reported about itself.
    enum Phase: Sendable, Equatable {
        /// Rendering, or waiting for the first frame.
        case loading
        /// The figure is on screen.
        case ready
        /// Held back on purpose: an implicit 3D solid, waiting for the reader to ask for it.
        case waitingToRun
        /// Nothing was drawn. The reason is one of `DiagramIsland.Reason`.
        case failed(reason: String)
    }

    /// Why a figure could not be drawn — chosen by the page, resolved to Arabic by the card, never
    /// a sentence sent from anywhere else.
    enum Reason {
        static let parse = "parse"
        static let empty = "empty"
        static let tikz = "tikz"
        static let engine = "engine"
    }

    private let spec: DiagramSpec
    private let palette: FirasPalette
    private let interactive: Bool
    private let runToken: Int
    private let link: DiagramIslandLink
    private let onHeight: @MainActor (CGFloat) -> Void
    private let onPhase: @MainActor (Phase) -> Void

    init(
        spec: DiagramSpec,
        palette: FirasPalette,
        interactive: Bool,
        runToken: Int,
        link: DiagramIslandLink,
        onHeight: @escaping @MainActor (CGFloat) -> Void,
        onPhase: @escaping @MainActor (Phase) -> Void
    ) {
        self.spec = spec
        self.palette = palette
        self.interactive = interactive
        self.runToken = runToken
        self.link = link
        self.onHeight = onHeight
        self.onPhase = onPhase
    }

    // MARK: - Representable

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = false
        configuration.userContentController.add(coordinator, name: DiagramIsland.channel)

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.bounces = false
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.showsHorizontalScrollIndicator = false
        view.scrollView.isScrollEnabled = false
        // Inline in a transcript the figure is a picture, not a toy: every touch belongs to the
        // list underneath it, and the reader opens the full-screen viewer to pan, zoom and rotate.
        view.isUserInteractionEnabled = interactive
        link.webView = view
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onHeight = onHeight
        coordinator.onPhase = onPhase
        link.webView = view

        let identity = spec.id + "|" + (interactive ? "i" : "s")
            + "|" + DiagramRuntime.paletteSignature(palette)
        if coordinator.loadedIdentity != identity {
            coordinator.loadedIdentity = identity
            coordinator.loadedRunToken = runToken
            let page = DiagramRuntime.page(
                spec: spec,
                palette: palette,
                interactive: interactive,
                autoRun: !spec.needsRunButton || runToken > 0
            )
            view.loadHTMLString(page, baseURL: nil)
            return
        }

        if coordinator.loadedRunToken != runToken {
            coordinator.loadedRunToken = runToken
            view.evaluateJavaScript(
                "window.__firasRun && window.__firasRun();",
                completionHandler: nil
            )
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: channel)
        view.configuration.userContentController.removeAllUserScripts()
    }

    /// The one message channel the page may speak on.
    fileprivate static let channel = "firasdiagram"

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, @preconcurrency WKNavigationDelegate,
        @preconcurrency WKScriptMessageHandler {

        var loadedIdentity = ""
        var loadedRunToken = -1
        var onHeight: @MainActor (CGFloat) -> Void = { _ in }
        var onPhase: @MainActor (Phase) -> Void = { _ in }

        // MARK: Navigation

        /// Nothing navigates. The document is the only thing this view ever shows, and a link inside
        /// a model-authored figure is not a reason to leave it.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = (navigationAction.request.url?.scheme ?? "").lowercased()
            decisionHandler(scheme == "about" || scheme.isEmpty ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            onPhase(.failed(reason: Reason.engine))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            onPhase(.failed(reason: Reason.engine))
        }

        // MARK: Messages

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == DiagramIsland.channel,
                  let payload = message.body as? [String: Any],
                  let type = payload["t"] as? String else {
                return
            }
            switch type {
            case "h":
                // A JavaScript number reaches here as an `NSNumber`; take either bridging.
                let raw = (payload["h"] as? Double) ?? (payload["h"] as? NSNumber)?.doubleValue
                guard let raw, raw.isFinite else { return }
                onHeight(CGFloat(min(max(raw, 0), 4000)))
            case "phase":
                let value = (payload["p"] as? String) ?? ""
                switch value {
                case "ready":
                    onPhase(.ready)
                case "run":
                    onPhase(.waitingToRun)
                case "loading":
                    onPhase(.loading)
                default:
                    onPhase(.failed(reason: (payload["why"] as? String) ?? Reason.engine))
                }
            default:
                break
            }
        }
    }
}

// MARK: - Link

/// Lets the card reach the live web view — for the snapshot behind Save and Share — without owning
/// it and without the view hierarchy leaking upward.
final class DiagramIslandLink {

    weak var webView: WKWebView?

    init() {}

    /// The figure exactly as the reader sees it. `nil` when the view is gone or the page has not
    /// painted yet.
    @MainActor
    func snapshot() async -> UIImage? {
        guard let webView, webView.bounds.width > 1, webView.bounds.height > 1 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
