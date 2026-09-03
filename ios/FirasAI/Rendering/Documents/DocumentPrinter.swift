import Foundation
import OSLog
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
    /// Named apart from `page(for:)` on purpose: a stored property and a method that share a
    /// base name compile, and read as a typo forever after.
    private var pageSource: PageHandler?

    /// The document's own scheme. Must not collide with the island's (`firas-katex`) or the
    /// code preview's (`firas-proj`).
    static let pageScheme = "firas-doc"

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

        /* REGISTERED BEFORE THE VIEW EXISTS. `setURLSchemeHandler` on a configuration a web
           view already copied has no effect, which is a silent failure and exactly the trap
           this whole file is trying to avoid. */
        let pageHandler = PageHandler(html: html)
        configuration.setURLSchemeHandler(pageHandler, forURLScheme: DocumentPrinter.pageScheme)
        self.pageSource = pageHandler

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

        /* SERVED, NOT INJECTED. `loadHTMLString` with a custom-scheme base URL is not a
           documented way to reach a scheme handler, and WebKit is free to decline: the page
           would load, KaTeX would never arrive, and the document would print with its
           mathematics as raw source and no error anywhere — the worst kind of failure, because
           it looks like a rendering opinion rather than a bug.
           `MathIsland` does not do that. It LOADS a url the handler answers, and that is the
           path proven to work in this app, so this takes it too: the document is handed to a
           handler of its own and fetched over `firas-doc://`, from which every relative asset
           resolves the ordinary way. */
        guard let url = URL(string: DocumentPrinter.pageScheme + "://document/index.html") else {
            teardown()
            return nil
        }
        view.load(URLRequest(url: url))

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
        pageSource = nil
        window?.isHidden = true
        window = nil
    }

    /// The scene that is actually on screen, and only then whatever else is connected.
    ///
    /* `connectedScenes` IS A SET, so "the first window scene" is not a scene, it is a coin toss —
       and the losing side is silent. A window hung off a scene that is not foreground has no
       compositor behind it, WebKit declines to paint a page it believes nobody can see, and the
       PDF comes back as blank sheets with no error anywhere. `MathIsland.hostWindow` learned this
       and says so at length; a printer that walks the same set unsorted was one Handoff, one
       external display or one background scene away from learning it again. */
    private static func hostScene() -> UIWindowScene? {
        var fallback: UIWindowScene?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if windowScene.activationState == .foregroundActive { return windowScene }
            if fallback == nil { fallback = windowScene }
        }
        return fallback
    }

    // MARK: - Serving the page

    /// Answers exactly one url with the composed document, and everything else with 404.
    ///
    /// A handler rather than `loadHTMLString` for two reasons: it is the path this app already
    /// proves works with a custom scheme, and it gives the page a real origin, so a relative
    /// `href` resolves the ordinary way instead of depending on undocumented behaviour.
    private final class PageHandler: NSObject, @preconcurrency WKURLSchemeHandler {

        private let data: Data
        private var active: Set<ObjectIdentifier> = []

        init(html: String) {
            self.data = Data(html.utf8)
            super.init()
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            let key = ObjectIdentifier(urlSchemeTask as AnyObject)
            active.insert(key)
            guard let url = urlSchemeTask.request.url else {
                active.remove(key)
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }
            let headers = [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": String(data.count),
                "Access-Control-Allow-Origin": "*",
            ]
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
            guard active.contains(key), let response else {
                active.remove(key)
                urlSchemeTask.didFailWithError(URLError(.cannotLoadFromNetwork))
                return
            }
            active.remove(key)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }

        /// A task WebKit stopped must never be written to again: doing so is an immediate crash,
        /// not an error.
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
            active.remove(ObjectIdentifier(urlSchemeTask as AnyObject))
        }
    }

    // MARK: - Load gate

    /// `didFinish` once, or a timeout. A navigation failure resolves as `false` rather than hanging.
    ///
    /// **On the main actor, like every other navigation delegate in this app.** A nested type does
    /// not inherit the enclosing type's global actor, so without this the callbacks below are
    /// nonisolated and cannot reach `resolve` at all — the same annotation `MathIsland`'s bridge and
    /// `DiagramIsland`'s coordinator carry, for the same reason.
    @MainActor
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
        ///
        /* AND THE DOCUMENT'S OWN SCHEME IS THE FIRST THING IT MAY TALK TO. This list was written
           when the page arrived by `loadHTMLString` with a `firas-katex://` base, so the only
           navigation it ever saw was on the island's scheme. The page is SERVED now, over
           `firas-doc://`, and that is a main-frame navigation like any other: leaving the scheme
           out cancelled it at the door, `didFailProvisionalNavigation` reported it as a load
           failure, `page(for:)` answered `nil`, and every PDF and every picture this printer
           makes came back empty — the composed transcript as much as the model's own design.
           The preview side hit the identical wall an hour later and fixed it there; this is the
           same fix, on the surface that had the bug first. */
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = (navigationAction.request.url?.scheme ?? "").lowercased()
            let allowed = scheme == DocumentPrinter.pageScheme
                || scheme == MathIslandAssets.scheme
                || scheme == "about"
                || scheme == "data"
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}
