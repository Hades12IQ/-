import SwiftUI
import UIKit
import WebKit

/// The one reusable `WKWebView` wrapper in `Rendering/`: a sealed island that renders a string of
/// HTML and reports how tall it turned out.
///
/// It is deliberately crippled, in the same way the web's preview iframe is
/// (`server-code-brainask.md §2.9`): a non-persistent data store, a private `firas-island://` base
/// URL, and a navigation delegate that cancels every navigation that is not the document itself, so
/// a generated page can never reach the network, the session cookie, or another window. JavaScript
/// is on, because a preview that cannot run the script it was handed is not a preview.
///
/// Height comes back through a script message rather than a polling timer: the injected snippet
/// measures the document on load and again whenever a `ResizeObserver` fires, so a page that grows
/// after its images decode still sizes correctly. Nothing here retains the web view, and
/// `dismantleUIView` removes the message handler, so the island is gone the moment SwiftUI takes it
/// off screen.
///
/// `DiagramIsland` is the sibling of this type for drawings; this one is for pages the model wrote.
struct WebIsland: UIViewRepresentable {

    /// The complete document to render. Changing it reloads the island.
    private let html: String
    /// `false` hands vertical gestures back to the transcript — the card turns it on only when the
    /// document is taller than the height the card is willing to give it.
    private let scrollEnabled: Bool
    /// Measured content height, in points, whenever it changes.
    private let onHeight: @MainActor (CGFloat) -> Void
    /// `true` when the document finished loading, `false` when it failed.
    private let onFinish: @MainActor (Bool) -> Void

    init(
        html: String,
        scrollEnabled: Bool = false,
        onHeight: @escaping @MainActor (CGFloat) -> Void = { _ in },
        onFinish: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.html = html
        self.scrollEnabled = scrollEnabled
        self.onHeight = onHeight
        self.onFinish = onFinish
    }

    /// The scheme the island's own document is served under. Anything else is refused.
    static let scheme = "firas-island"

    /// The one message channel the page may speak on.
    fileprivate static let channel = "firasisland"

    // MARK: - Representable

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        // A page that starts playing sound the moment a transcript row scrolls past is the one
        // thing an inline preview must never do.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = false
        configuration.userContentController.add(coordinator, name: WebIsland.channel)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebIsland.measureScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.bounces = false
        view.scrollView.showsHorizontalScrollIndicator = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onHeight = onHeight
        coordinator.onFinish = onFinish
        view.scrollView.isScrollEnabled = scrollEnabled

        guard coordinator.loadedHTML != html else { return }
        coordinator.loadedHTML = html
        view.loadHTMLString(html, baseURL: URL(string: WebIsland.scheme + "://page/"))
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.onHeight = { _ in }
        coordinator.onFinish = { _ in }
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: channel)
        view.configuration.userContentController.removeAllUserScripts()
    }

    // MARK: - Injected measurement

    /// Reports the document height on load, on every layout change, and at three fixed moments
    /// afterwards — the belt and braces a page whose fonts or images land late needs.
    private static let measureScript = """
    (function () {
      var last = -1;
      function post() {
        try {
          var de = document.documentElement;
          var body = document.body;
          var h = 0;
          if (de) { h = Math.max(h, de.scrollHeight, de.offsetHeight); }
          if (body) { h = Math.max(h, body.scrollHeight, body.offsetHeight); }
          h = Math.ceil(h);
          if (h === last) { return; }
          last = h;
          window.webkit.messageHandlers.\(channel).postMessage(h);
        } catch (e) {}
      }
      post();
      document.addEventListener('DOMContentLoaded', post);
      window.addEventListener('load', post);
      window.addEventListener('resize', post);
      try {
        if (window.ResizeObserver && document.documentElement) {
          new ResizeObserver(post).observe(document.documentElement);
        }
      } catch (e) {}
      setTimeout(post, 80);
      setTimeout(post, 400);
      setTimeout(post, 1200);
    })();
    """

    // MARK: - Coordinator

    /// Holds the callbacks and nothing else — never the web view, so the configuration's strong
    /// reference to this object cannot close a cycle.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency WKNavigationDelegate,
        @preconcurrency WKScriptMessageHandler {

        var loadedHTML: String?
        var onHeight: @MainActor (CGFloat) -> Void = { _ in }
        var onFinish: @MainActor (Bool) -> Void = { _ in }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // A page opening a new window has no target frame, and the island has no second window
            // to give it — following that outside would defeat the whole cage.
            guard navigationAction.targetFrame != nil else {
                decisionHandler(.cancel)
                return
            }
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            if scheme == nil || scheme == WebIsland.scheme || scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish(true)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            onFinish(false)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onFinish(false)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == WebIsland.channel else { return }
            let value: Double
            if let number = message.body as? NSNumber {
                value = number.doubleValue
            } else if let text = message.body as? String, let parsed = Double(text) {
                value = parsed
            } else {
                return
            }
            guard value.isFinite, value > 0 else { return }
            onHeight(CGFloat(value))
        }
    }
}
