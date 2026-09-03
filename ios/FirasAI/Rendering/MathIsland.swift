import Foundation
import Observation
import SwiftUI
import UIKit
import WebKit

/// One equation handed to an island. `id` is derived from the TeX itself, so the same formula in
/// the same message is rendered once no matter how many call sites ask for it.
struct MathIslandItem: Hashable, Sendable {

    let id: String
    let tex: String
    let isDisplay: Bool

    init(tex: String, isDisplay: Bool) {
        let trimmed = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tex = trimmed
        self.isDisplay = isDisplay
        self.id = MathScanner.identifier(tex: trimmed, isDisplay: isDisplay)
    }

    init(span: MathScanner.Span) {
        self.init(tex: span.tex, isDisplay: span.isDisplay)
    }
}

/// Everything the island needs to look like the rest of the app: the six themes' ink, the colour
/// the equation sits on, the error red the web uses, and the prose size Settings asks for.
struct MathIslandStyle: Hashable, Sendable {

    let textHex: String
    let backgroundHex: String
    let errorHex: String
    let fontSize: Double

    /// Stable identity for `.task(id:)` — a theme or font-scale change must re-render, nothing else.
    var key: String {
        textHex + "|" + backgroundHex + "|" + errorHex + "|" + String(Int((fontSize * 10).rounded()))
    }

    init(textHex: String, backgroundHex: String, errorHex: String, fontSize: Double) {
        self.textHex = textHex
        self.backgroundHex = backgroundHex
        self.errorHex = errorHex
        self.fontSize = fontSize
    }

    init(palette: FirasPalette, background: Color, fontScale: FontScale) {
        let dark = !palette.isLightFamily
        self.init(
            textHex: MathIslandStyle.hex(palette.textPrimary, dark: dark, fallback: dark ? "#ECECEC" : "#151515"),
            backgroundHex: MathIslandStyle.hex(background, dark: dark, fallback: dark ? "#101010" : "#FFFFFF"),
            errorHex: MathIslandStyle.hex(palette.error, dark: dark, fallback: "#CC0000"),
            fontSize: Double(17 * fontScale.factor)
        )
    }

    /// SwiftUI `Color` → a CSS hex. The palette is built from literal sRGB components, so this
    /// resolves exactly; a colour that refuses to give up its components falls back to the ink of
    /// the family rather than to black on black.
    static func hex(_ color: Color, dark: Bool, fallback: String) -> String {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return fallback }
        return "#" + channel(red) + channel(green) + channel(blue)
    }

    private static func channel(_ value: CGFloat) -> String {
        let clamped = Int((min(max(value, 0), 1) * 255).rounded())
        let text = String(clamped, radix: 16, uppercase: true)
        return text.count == 1 ? "0" + text : text
    }
}

/// A typeset equation: the bitmap KaTeX drew, its size in points, and where its baseline sits
/// inside that bitmap so an inline formula can sit on the line of the sentence around it.
struct MathGlyph {
    let image: UIImage
    let size: CGSize
    let baseline: CGFloat
}

/// What the page reports back over the bridge. Strictly sequential: the island asks for one thing
/// and waits for exactly one answer.
private enum MathIslandSignal {
    case booted
    case done([MathIslandFrame], CGSize)
    case failed
}

private struct MathIslandFrame {
    let index: Int
    let rect: CGRect
    let baseline: CGFloat
    let ok: Bool
}

/// **One `WKWebView` per message.** Never one per equation.
///
/// `MathText.unicode` gives correct glyphs, not typeset layout, and the owner is right that it is
/// not what the website shows — the site typesets with KaTeX 0.16.11 (`index.html`, `typesetMath`).
/// This is that renderer, brought over intact: the same version, the same macro table, the same
/// `mathTidyTex` / `mathRepairTex` / `\operatorname` repair ladder, the same `mhchem` extension.
///
/// The architecture note that a KaTeX web view was "a freeze risk" was about *a web view per
/// equation inside a lazy stack*. So the island is per **message**: every equation of one answer is
/// rendered in a single offscreen page, snapshotted to a bitmap each, and the page is thrown away.
/// A row draws an image; nothing in the transcript owns a live web view, and a message that has
/// already been typeset costs nothing to scroll past.
///
/// Every failure — no network, a blocked CDN, a load timeout, an expression KaTeX still refuses —
/// leaves the glyph absent, and `MathBlockView` keeps showing the `MathText.unicode` form it was
/// already showing. There is no state in which an equation renders as blank space or as an error.
@MainActor
@Observable
final class MathIsland {

    // MARK: - Tuning

    /// Equations rendered in one page. Sixteen at ~40 pt each stay far inside the canvas.
    private static let chunkSize = 16
    /// Ceiling per message, so a pathological answer cannot fill memory with bitmaps.
    private static let maximumGlyphs = 96
    /// Live islands kept; the oldest is disposed. Each holds bitmaps only — no web view.
    private static let maximumIslands = 24
    /// Accepted theme / font-scale changes per message, as an anti-thrash floor.
    private static let maximumStyleFlips = 8
    private static let bridgeName = "firasMath"

    // MARK: - Observed state

    private(set) var glyphs: [String: MathGlyph] = [:]
    /// `true` once this message's math has been proven un-typesettable — the Unicode path owns it.
    private(set) var isUnavailable = false

    // MARK: - Private state

    @ObservationIgnored private let messageID: String
    @ObservationIgnored private var style: MathIslandStyle?
    @ObservationIgnored private var queued: [MathIslandItem] = []
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var styleFlips = 0
    @ObservationIgnored private var unavailableAt: Date?
    @ObservationIgnored private var isRendering = false
    @ObservationIgnored private var isScheduled = false
    @ObservationIgnored private var isBooted = false
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var bridge: MathIslandBridge?
    @ObservationIgnored private var waiter: CheckedContinuation<MathIslandSignal, Never>?
    @ObservationIgnored private var waitToken = 0
    @ObservationIgnored private var canvas = CGSize(width: 390, height: 2400)

    private init(messageID: String) {
        self.messageID = messageID
    }

    // MARK: - Registry

    private static var registry: [String: MathIsland] = [:]
    private static var order: [String] = []

    /// The island that owns one message's math. Cheap: a dictionary read on the main actor.
    static func island(for messageID: String) -> MathIsland {
        if let existing = registry[messageID] {
            return existing
        }
        let island = MathIsland(messageID: messageID)
        registry[messageID] = island
        order.append(messageID)
        while order.count > maximumIslands {
            let victim = order.removeFirst()
            registry[victim]?.dispose()
            registry[victim] = nil
        }
        return island
    }

    /// Regenerate, version switch, edit: the old bitmaps describe text that no longer exists.
    static func invalidate(messageID: String) {
        guard let island = registry[messageID] else { return }
        island.dispose()
        registry[messageID] = nil
        order.removeAll { $0 == messageID }
    }

    static func invalidateAll() {
        for island in registry.values { island.dispose() }
        registry.removeAll()
        order.removeAll()
    }

    // MARK: - Reading

    func glyph(for id: String) -> MathGlyph? {
        glyphs[id]
    }

    // MARK: - Requesting

    /// Register equations for this message. Calls coalesce: every block of one answer lands in the
    /// same batch, and a batch that arrives while a page is already open is picked up after it.
    func request(_ items: [MathIslandItem], style: MathIslandStyle) {
        guard !items.isEmpty else { return }

        if self.style == nil {
            self.style = style
        } else if self.style != style, styleFlips < Self.maximumStyleFlips {
            // A theme or font-scale change: everything already drawn is the wrong colour or size.
            // Bounded, because two call sites that disagreed about the background would otherwise
            // clear each other's work forever.
            styleFlips += 1
            self.style = style
            glyphs.removeAll()
            attempted.removeAll()
            queued.removeAll()
            isUnavailable = false
            unavailableAt = nil
        }

        // A message that failed while the phone was in a lift is allowed to try again later; the
        // retry is driven by the reader scrolling back to it, never by a timer of our own.
        var revived = false
        if isUnavailable, let at = unavailableAt, Date().timeIntervalSince(at) > 120 {
            isUnavailable = false
            unavailableAt = nil
            revived = true
        }
        guard !isUnavailable, attempted.count < Self.maximumGlyphs else { return }

        var added = false
        for item in items where !item.tex.isEmpty && !attempted.contains(item.id) {
            if queued.contains(where: { $0.id == item.id }) { continue }
            queued.append(item)
            added = true
        }
        guard added || (revived && !queued.isEmpty) else { return }
        schedule()
    }

    /// Convenience for the transcript: hand the island every span of a message at once, before any
    /// row has asked for one. This is what makes a message a *single* render pass.
    func prime(markdown: String, style: MathIslandStyle) {
        let spans = MathScanner.spans(in: markdown)
        guard !spans.isEmpty else { return }
        request(spans.map { MathIslandItem(span: $0) }, style: style)
    }

    private func schedule() {
        guard !isScheduled, !isRendering else { return }
        isScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isScheduled = false
                self.begin()
            }
        }
    }

    private func begin() {
        guard !isRendering, !queued.isEmpty, !isUnavailable, style != nil else { return }
        isRendering = true
        Task { await self.runPasses() }
    }

    // MARK: - Rendering

    private func runPasses() async {
        guard let style else {
            isRendering = false
            return
        }
        var pending = queued
        queued.removeAll()
        if pending.count > Self.maximumGlyphs { pending = Array(pending.prefix(Self.maximumGlyphs)) }
        guard !pending.isEmpty else {
            isRendering = false
            return
        }

        guard await MathIslandAssets.shared.prepare() else {
            requeue(pending)
            markUnavailable()
            isRendering = false
            return
        }

        var healthy = true
        while !pending.isEmpty, healthy {
            let chunk = Array(pending.prefix(Self.chunkSize))
            pending.removeFirst(chunk.count)
            healthy = await renderChunk(chunk, style: style)
            if healthy {
                // Attempted, not necessarily drawn: an expression KaTeX refuses is not asked twice.
                for item in chunk { attempted.insert(item.id) }
            } else {
                requeue(chunk)
            }
        }
        if !pending.isEmpty { requeue(pending) }

        teardown()
        if !healthy {
            markUnavailable()
        }
        isRendering = false
        if !queued.isEmpty, !isUnavailable {
            schedule()
        }
    }

    private func requeue(_ items: [MathIslandItem]) {
        for item in items where !attempted.contains(item.id) {
            if queued.contains(where: { $0.id == item.id }) { continue }
            queued.append(item)
        }
    }

    /// One page-load worth of equations. Returns `false` only when the *page* failed — an
    /// expression KaTeX could not parse is a missing glyph, not an unhealthy island.
    private func renderChunk(_ items: [MathIslandItem], style: MathIslandStyle) async -> Bool {
        guard let json = Self.payload(items: items, style: style) else { return false }
        guard let view = await bootedWebView() else { return false }

        view.evaluateJavaScript("window.firasRun(" + json + ");", completionHandler: nil)
        guard case .done(let firstFrames, let size) = await wait(seconds: 10) else { return false }

        var frames = firstFrames
        if size.width > canvas.width + 0.5 || size.height > canvas.height + 0.5 {
            let width = min(1400, max(canvas.width, size.width + 8))
            let height = min(6000, max(canvas.height, size.height + 8))
            canvas = CGSize(width: width, height: height)
            view.frame = CGRect(origin: .zero, size: canvas)
            view.evaluateJavaScript("window.firasMeasure();", completionHandler: nil)
            guard case .done(let grown, _) = await wait(seconds: 8) else { return false }
            frames = grown
        }

        await capture(frames, items: items, view: view)
        return true
    }

    private func capture(_ frames: [MathIslandFrame], items: [MathIslandItem], view: WKWebView) async {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        for frame in frames {
            guard frame.ok, frame.index >= 0, frame.index < items.count else { continue }
            let box = frame.rect
            guard box.width > 1, box.height > 1 else { continue }
            guard box.minX >= -0.5, box.minY >= -0.5 else { continue }
            guard box.maxX <= bounds.width + 0.5, box.maxY <= bounds.height + 0.5 else { continue }

            let padded = box.insetBy(dx: -1, dy: -1).intersection(bounds)
            guard padded.width > 1, padded.height > 1 else { continue }

            let configuration = WKSnapshotConfiguration()
            configuration.rect = padded
            guard let image = await snapshot(view, configuration: configuration) else { continue }

            let baseline = frame.baseline + (box.minY - padded.minY)
            glyphs[items[frame.index].id] = MathGlyph(
                image: image,
                size: image.size,
                baseline: max(0, min(image.size.height, baseline))
            )
        }
    }

    private func snapshot(_ view: WKWebView, configuration: WKSnapshotConfiguration) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            view.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - The page

    private func bootedWebView() async -> WKWebView? {
        if let view = webView, isBooted { return view }
        teardown()

        let window = Self.hostWindow()
        let width = max(360, min(1200, window?.bounds.width ?? 390))
        canvas = CGSize(width: width, height: 2400)

        let bridge = MathIslandBridge(island: self)
        guard let view = makeWebView(bridge: bridge) else { return nil }
        self.bridge = bridge
        self.webView = view
        attach(view, to: window)

        guard let url = URL(string: MathIslandAssets.scheme + "://katex/index.html") else {
            teardown()
            return nil
        }
        view.load(URLRequest(url: url))

        if case .booted = await wait(seconds: 14) {
            isBooted = true
            return view
        }
        teardown()
        return nil
    }

    private func makeWebView(bridge: MathIslandBridge) -> WKWebView? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = true
        configuration.setURLSchemeHandler(MathIslandAssets.shared, forURLScheme: MathIslandAssets.scheme)
        configuration.userContentController.add(bridge, name: Self.bridgeName)

        let view = WKWebView(frame: CGRect(origin: .zero, size: canvas), configuration: configuration)
        view.navigationDelegate = bridge
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        view.isUserInteractionEnabled = false
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    /// A web view renders reliably only inside a window, so the island lives *behind* the app: the
    /// bottom-most subview of the key window, invisible, untouchable and hidden from VoiceOver.
    private func attach(_ view: WKWebView, to window: UIWindow?) {
        guard let window else { return }
        view.alpha = 0.012
        window.insertSubview(view, at: 0)
    }

    private static func hostWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) { return key }
            if let any = windowScene.windows.first { return any }
        }
        return nil
    }

    private func teardown() {
        if let view = webView {
            view.stopLoading()
            view.navigationDelegate = nil
            view.configuration.userContentController.removeAllUserScripts()
            view.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
            view.removeFromSuperview()
        }
        webView = nil
        bridge?.island = nil
        bridge = nil
        isBooted = false
        resume(.failed)
    }

    private func dispose() {
        teardown()
        glyphs.removeAll()
        queued.removeAll()
        attempted.removeAll()
    }

    /// The queue is kept, not thrown away: these are the equations to try again if the reader comes
    /// back to this message after the network does.
    private func markUnavailable() {
        isUnavailable = true
        unavailableAt = Date()
    }

    // MARK: - Bridge

    /// Waits for exactly one message from the page. The watchdog resolves the wait if the page
    /// never answers — a blocked CDN must cost one timeout, never a stuck island.
    private func wait(seconds: Double) async -> MathIslandSignal {
        waitToken += 1
        let token = waitToken
        return await withCheckedContinuation { (continuation: CheckedContinuation<MathIslandSignal, Never>) in
            waiter = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.waitToken == token, self.waiter != nil else { return }
                    self.resume(.failed)
                }
            }
        }
    }

    private func resume(_ signal: MathIslandSignal) {
        guard let continuation = waiter else { return }
        waiter = nil
        waitToken += 1
        continuation.resume(returning: signal)
    }

    fileprivate func receive(_ payload: [String: Any]) {
        switch (payload["type"] as? String) ?? "" {
        case "boot":
            resume(.booted)
        case "done":
            let raw = (payload["items"] as? [[String: Any]]) ?? []
            var frames: [MathIslandFrame] = []
            frames.reserveCapacity(raw.count)
            for entry in raw {
                let index = Self.number(entry["i"]).map { Int($0) } ?? -1
                let x = Self.number(entry["x"]) ?? 0
                let y = Self.number(entry["y"]) ?? 0
                let width = Self.number(entry["w"]) ?? 0
                let height = Self.number(entry["h"]) ?? 0
                let baseline = Self.number(entry["b"]) ?? 0
                let ok = (entry["ok"] as? NSNumber)?.boolValue ?? false
                frames.append(
                    MathIslandFrame(
                        index: index,
                        rect: CGRect(x: x, y: y, width: width, height: height),
                        baseline: CGFloat(baseline),
                        ok: ok
                    )
                )
            }
            let size = CGSize(
                width: CGFloat(Self.number(payload["width"]) ?? 0),
                height: CGFloat(Self.number(payload["height"]) ?? 0)
            )
            resume(.done(frames, size))
        default:
            resume(.failed)
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    // MARK: - Payload

    private static func payload(items: [MathIslandItem], style: MathIslandStyle) -> String? {
        var entries: [[String: Any]] = []
        entries.reserveCapacity(items.count)
        for item in items {
            entries.append(["tex": item.tex, "display": item.isDisplay])
        }
        let styleFields: [String: Any] = [
            "color": style.textHex,
            "background": style.backgroundHex,
            "error": style.errorHex,
            "fontSize": style.fontSize,
        ]
        let body: [String: Any] = [
            "items": entries,
            "style": styleFields,
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: []),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // Legal in JSON, historically illegal inside a JS source literal.
        return text
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

// MARK: - Bridge

/// The page's only way to reach Swift. Holds the island weakly: the island owns the web view, the
/// web view's content controller owns this.
@MainActor
private final class MathIslandBridge: NSObject, @preconcurrency WKScriptMessageHandler, @preconcurrency WKNavigationDelegate {

    weak var island: MathIsland?

    init(island: MathIsland) {
        self.island = island
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let payload = message.body as? [String: Any] else { return }
        island?.receive(payload)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        island?.receive(["type": "fail"])
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        island?.receive(["type": "fail"])
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let scheme = (navigationAction.request.url?.scheme ?? "").lowercased()
        decisionHandler(scheme == MathIslandAssets.scheme || scheme == "about" ? .allow : .cancel)
    }
}
