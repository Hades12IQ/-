import Foundation
import UIKit
import WebKit

/// Turns a composed page into PDF bytes, through the print engine the device already has.
///
/// `WKWebView.createPDF` is the whole point of this file. Everything the hand-written renderer got
/// wrong — the margins, the page breaks, tables split across pages, Arabic shaping, and above all
/// the mathematics — WebKit gets right because it is a browser, and the equations are typeset by
/// the same KaTeX build the transcript uses.
///
/// **Nothing here is a cliff.** Every failure path returns `nil`, and the caller keeps the renderer
/// it has. A reader who asked for a document gets a document even on the day WebKit refuses.
@MainActor
final class DocumentPrinter {

    /// The page is 794 × 1123 points — A4 at 96 dpi, which is the size a browser means by A4. The
    /// PAPER, though, is the stylesheet's business: `@page` in the template decides the sheet and
    /// its margins, and setting a rect here would silently overrule it. This size only gives the
    /// layout a sensible width to lay out against before printing.
    private static let layout = CGSize(width: 794, height: 1123)

    /// How long the page is given to load, typeset its mathematics and settle its fonts. A document
    /// with fifty equations is doing real work; a document whose KaTeX never finishes must still
    /// print. Both are served by waiting and then printing anyway.
    private static let patience: TimeInterval = 12

    private var window: UIWindow?
    private var webView: WKWebView?
    private var delegate: LoadDelegate?

    // MARK: - Printing

    /// The PDF for `html`, or `nil` if WebKit would not produce one.
    func pdf(html: String) async -> Data? {
        guard let view = await page(for: html) else { return nil }
        await settle(view)
        let configuration = WKPDFConfiguration()
        do {
            let data = try await view.pdf(configuration: configuration)
            teardown()
            return data.isEmpty ? nil : data
        } catch {
            Log.ui.error("document pdf failed: \(String(describing: error), privacy: .public)")
            teardown()
            return nil
        }
    }

    /// The same page as an image, for the picture export. One tall snapshot, not paginated.
    func image(html: String, scale: CGFloat = 2) async -> UIImage? {
        guard let view = await page(for: html) else { return nil }
        await settle(view)
        let height = await contentHeight(view)
        view.frame = CGRect(origin: .zero, size: CGSize(width: DocumentPrinter.layout.width, height: height))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view.bounds
        configuration.snapshotWidth = NSNumber(value: Double(DocumentPrinter.layout.width * scale / UIScreen.main.scale))
        do {
            let image = try await view.takeSnapshot(configuration: configuration)
            teardown()
            return image
        } catch {
            Log.ui.error("document image failed: \(String(describing: error), privacy: .public)")
            teardown()
            return nil
        }
    }

    // MARK: - The page

    /// Loads the html and returns the view once `didFinish` has fired, or `nil` on failure.
    ///
    /// /* IN ITS OWN WINDOW, AT FULL OPACITY, and this is not decoration. WebKit stops painting a
    ///    view it believes nobody can see, and an unpainted page prints as an empty sheet — the
    ///    exact trap `MathIsland` documents and solves the same way. The window sits one level
    ///    below the app's, which is opaque and covers every pixel of it, so it renders properly and
    ///    is seen by nobody. A separate window rather than a buried subview also keeps it clear of
    ///    the app's glass, which samples whatever shares its layer tree. */
    private func page(for html: String) async -> WKWebView? {
        DocumentHTML.headingCount = 0

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(MathIslandAssets.shared, forURLScheme: MathIslandAssets.scheme)

        // The bundle has to be in memory before the page asks for it: a stylesheet that arrives
        // after layout is a measurement taken on the wrong fonts.
        _ = await MathIslandAssets.shared.prepare()

        let view = WKWebView(frame: CGRect(origin: .zero, size: DocumentPrinter.layout), configuration: configuration)
        view.isOpaque = true
        view.backgroundColor = UIColor.white
        view.scrollView.backgroundColor = UIColor.white
        view.isUserInteractionEnabled = false
        view.scrollView.isScrollEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true

        let loader = LoadDelegate()
        view.navigationDelegate = loader
        self.delegate = loader
        self.webView = view

        if let scene = DocumentPrinter.hostScene() {
            let host = UIWindow(windowScene: scene)
            host.windowLevel = UIWindow.Level.normal - 1
            host.backgroundColor = UIColor.white
            host.isUserInteractionEnabled = false
            host.frame = CGRect(origin: .zero, size: DocumentPrinter.layout)
            host.isHidden = false
            host.addSubview(view)
            self.window = host
        }

        /* A BASE URL ON THE KATEX SCHEME, so a relative `href` in the page resolves to the handler
           rather than to nothing. `loadHTMLString` with a nil base gives the page an opaque origin
           and every relative asset 404s silently — which would print a document with its
           mathematics as source and no error anywhere. */
        let base = URL(string: MathIslandAssets.scheme + "://katex/")
        view.loadHTMLString(html, baseURL: base)

        guard await loader.finished(within: DocumentPrinter.patience) else {
            teardown()
            return nil
        }
        return view
    }

    /// Waits for the page to say its mathematics is drawn, then prints regardless.
    ///
    /// The flag is raised by the composer's own script after KaTeX has run and the fonts have
    /// settled. Polling is deliberate: a page that throws before raising it must not hold a
    /// document hostage, so the wait has a ceiling and expiry means print what is there.
    private func settle(_ view: WKWebView) async {
        let deadline = Date().addingTimeInterval(DocumentPrinter.patience)
        while Date() < deadline {
            let ready = (try? await view.evaluateJavaScript("window." + DocumentHTML.readyFlag + " === true")) as? Bool
            if ready == true { return }
            await JobClock.rest(0.12)
        }
        Log.ui.error("document page never reported ready; printing as it stands")
    }

    private func contentHeight(_ view: WKWebView) async -> CGFloat {
        let value = (try? await view.evaluateJavaScript("document.body.scrollHeight")) as? NSNumber
        let height = CGFloat(value?.doubleValue ?? 0)
        guard height > 1 else { return DocumentPrinter.layout.height }
        return min(height, 16_000)
    }

    private func teardown() {
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        delegate = nil
        window?.isHidden = true
        window = nil
    }

    private static func hostScene() -> UIWindowScene? {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene { return windowScene }
        }
        return nil
    }

    // MARK: - Load gate

    /// `didFinish` once, or a timeout. A navigation failure resolves as `false` rather than hanging.
    private final class LoadDelegate: NSObject, @preconcurrency WKNavigationDelegate {

        private var waiting: [CheckedContinuation<Bool, Never>] = []
        private var settled: Bool?

        @MainActor
        func finished(within seconds: TimeInterval) async -> Bool {
            if let settled { return settled }
            let timeout = Task { [weak self] in
                await JobClock.rest(seconds)
                self?.resolve(false)
            }
            let value = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiting.append(continuation)
            }
            timeout.cancel()
            return value
        }

        @MainActor
        private func resolve(_ value: Bool) {
            guard settled == nil else { return }
            settled = value
            let pending = waiting
            waiting.removeAll()
            for continuation in pending { continuation.resume(returning: value) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            resolve(true)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            resolve(false)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            resolve(false)
        }

        /// The page may talk to the bundle and to nothing else. A document being printed has no
        /// business reaching the network, and a model that wrote `<img src="http://…">` into it
        /// must not be able to make a request from the reader's device.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = (navigationAction.request.url?.scheme ?? "").lowercased()
            let allowed = scheme == MathIslandAssets.scheme || scheme == "about" || scheme == "data"
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}
