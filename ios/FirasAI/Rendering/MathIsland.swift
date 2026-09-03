import Foundation
import Observation
import SwiftUI
import UIKit
import WebKit

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

/// **One `WKWebView` for the whole app, created once and updated in place.**
///
/// The owner's report — «اللاتكس ما تتحول عدل، تتحول شكل غريب و تختفي»: a formula renders while the
/// answer streams and then disappears. Three things caused that, and all three are fixed here.
///
/// 1. *The bitmaps were thrown away when the stream ended.* `AssistantTurnView` calls
///    `MathBlockView.invalidate(messageID:)` the moment `isStreaming` goes false, and the old
///    island answered that by disposing itself. Nothing re-requested afterwards — the row is still
///    on screen, so its `.task(id:)` never fires again — and the equation fell back to the
///    `MathText.unicode` form for good. Glyphs are now **content-addressed**
///    (`style.key + "/" + FNV(tex)`): text changing under a message id cannot make an existing
///    bitmap wrong, so nothing is ever removed for a message that is still being read. `invalidate`
///    only clears the failure state.
/// 2. *The page was rebuilt on every streamed chunk.* Each render pass used to end in `teardown()`,
///    so a message whose equations arrived one at a time booted a web view per equation. The page
///    is now kept between passes and disposed 30 s after the last one.
/// 3. *A theme change wiped everything.* The style is part of the cache key instead, so the new
///    colour renders beside the old bitmap rather than in place of it.
///
/// The architecture note that a KaTeX web view is "a freeze risk" was about *a web view per
/// equation inside a lazy stack*. Here every equation of every visible answer goes through one
/// offscreen page, is snapshotted to a bitmap, and the page goes away when the reading stops. A row
/// only ever draws an image.
///
/// Every failure — no network, a blocked CDN, a load timeout, an expression KaTeX still refuses —
/// leaves the glyph absent, and `MathBlockView` keeps showing the Unicode form it was already
/// showing. There is no state in which an equation renders as blank space or as an error box.
@MainActor
@Observable
final class MathIsland {

    // MARK: - Tuning

    /// Equations rendered in one page load. Twelve at ~40 pt each stay far inside the canvas.
    private static let chunkSize = 12
    /// Pending equations. A pathological answer waits its turn instead of growing without bound.
    private static let maximumQueue = 240
    /// Bitmaps kept, evicted least-recently-*drawn* first. Reading a glyph touches it, so an
    /// equation that is on screen is always the newest entry and can never be the victim.
    private static let maximumGlyphs = 320
    private static let maximumBytes = 24 * 1024 * 1024
    /// How long the page survives with nothing to do.
    private static let idleTeardown: Double = 30
    /// How long a CDN failure is believed before the next request may try again.
    private static let failureCooldown: Double = 60
    private static let bridgeName = "firasMath"

    /// The one island. Per-*message* islands were the bug: they were created and destroyed with the
    /// message's stream state, which is exactly the lifetime a bitmap cache must not have.
    static let shared = MathIsland()

    // MARK: - Glyphs

    /// Observed. A view reads it through `glyph(for:style:)`, so a landed bitmap redraws the rows
    /// that were waiting for one. Entries are only ever added, or evicted by the LRU below.
    private var store: [String: MathGlyph] = [:]

    @ObservationIgnored private var lastUse: [String: Int] = [:]
    @ObservationIgnored private var clock = 0
    @ObservationIgnored private var bytes = 0

    // MARK: - Queue

    private struct Pending {
        let item: MathIslandItem
        let style: MathIslandStyle
    }

    @ObservationIgnored private var queued: [Pending] = []
    /// Composite keys already sent to a page — drawn or refused. Never retried in the same style.
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var isRendering = false
    @ObservationIgnored private var isScheduled = false
    @ObservationIgnored private var isUnavailable = false
    @ObservationIgnored private var unavailableAt: Date?

    // MARK: - Page

    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var bridge: MathIslandBridge?
    @ObservationIgnored private var isBooted = false
    @ObservationIgnored private var waiter: CheckedContinuation<MathIslandSignal, Never>?
    @ObservationIgnored private var waitToken = 0
    @ObservationIgnored private var idleToken = 0
    @ObservationIgnored private var canvas = CGSize(width: 390, height: 2400)

    private init() {}

    // MARK: - Reading

    /// The bitmap for one equation in one style, or `nil` while it is still being drawn — and
    /// forever, if it can never be drawn. `nil` is not an error state: the caller is already
    /// showing the Unicode form.
    func glyph(for id: String, style: MathIslandStyle) -> MathGlyph? {
        let composite = Self.key(id, style)
        guard let found = store[composite] else { return nil }
        clock &+= 1
        lastUse[composite] = clock
        return found
    }

    // MARK: - Requesting

    /// Register equations. Calls coalesce: every block of one answer lands in the same batch, and a
    /// batch that arrives while a page is already open is picked up by the pass after it.
    ///
    /// Nothing here removes anything. An equation that has been drawn stays drawn.
    func request(_ items: [MathIslandItem], style: MathIslandStyle) {
        guard !items.isEmpty else { return }

        // A message that failed while the phone was in a lift is allowed to try again later. The
        // retry is driven by a reader asking again, never by a timer of our own.
        if isUnavailable, let at = unavailableAt, Date().timeIntervalSince(at) > Self.failureCooldown {
            isUnavailable = false
            unavailableAt = nil
        }
        guard !isUnavailable else { return }

        var added = false
        for item in items {
            guard !item.tex.isEmpty, MathScanner.isTypesettable(item.tex) else { continue }
            let composite = Self.key(item.id, style)
            if attempted.contains(composite) || store[composite] != nil { continue }
            if queued.contains(where: { $0.item.id == item.id && $0.style.key == style.key }) { continue }
            guard queued.count < Self.maximumQueue else { break }
            queued.append(Pending(item: item, style: style))
            added = true
        }
        guard added else { return }
        schedule()
    }

    /// Hand the island every **complete** span of a message at once, before any row has asked for
    /// one. This is what makes an answer a single render pass instead of one page per equation.
    ///
    /// Safe to call on every streamed tick: `MathScanner.spans` only ever returns a run whose
    /// closing delimiter has actually arrived, so a `$$` still being typed is not a span yet and is
    /// never typeset. `messageID` is carried for the call site's benefit; the cache is keyed by the
    /// expression, not by the message, so the same formula in two answers costs one render.
    func prime(markdown: String, messageID: String, style: MathIslandStyle) {
        guard !markdown.isEmpty else { return }
        let spans = MathScanner.spans(in: markdown)
        guard !spans.isEmpty else { return }
        request(spans.map { MathIslandItem(span: $0) }, style: style)
    }

    /// Regenerate, version switch, edit, end of stream. Deliberately **not** a cache flush: a glyph
    /// describes its own TeX, so nothing under this id can have gone stale. All this does is let a
    /// message that failed try again.
    func allowRetry() {
        isUnavailable = false
        unavailableAt = nil
        if !queued.isEmpty { schedule() }
    }

    /// Sign-out and "delete my data": every bitmap goes, and so does the page.
    func reset() {
        store.removeAll()
        lastUse.removeAll()
        bytes = 0
        clock = 0
        queued.removeAll()
        attempted.removeAll()
        isUnavailable = false
        unavailableAt = nil
        teardownPage()
    }

    private static func key(_ id: String, _ style: MathIslandStyle) -> String {
        style.key + "/" + id
    }

    // MARK: - Scheduling

    private func schedule() {
        guard !isScheduled, !isRendering else { return }
        isScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isScheduled = false
                guard !self.isRendering, !self.isUnavailable, !self.queued.isEmpty else { return }
                Task { await self.runPasses() }
            }
        }
    }

    private struct Batch {
        let items: [MathIslandItem]
        let style: MathIslandStyle
    }

    /// The next page's worth of work: up to `chunkSize` equations that share one style, because the
    /// page paints its ink and its ground once per run.
    private func nextBatch() -> Batch? {
        while !queued.isEmpty {
            let style = queued[0].style
            var items: [MathIslandItem] = []
            var rest: [Pending] = []
            for pending in queued {
                guard pending.style.key == style.key, items.count < Self.chunkSize else {
                    rest.append(pending)
                    continue
                }
                let composite = Self.key(pending.item.id, pending.style)
                if attempted.contains(composite) || store[composite] != nil { continue }
                if items.contains(where: { $0.id == pending.item.id }) { continue }
                items.append(pending.item)
            }
            queued = rest
            if !items.isEmpty { return Batch(items: items, style: style) }
        }
        return nil
    }

    private func requeue(_ items: [MathIslandItem], style: MathIslandStyle) {
        let back = items.map { Pending(item: $0, style: style) }
        queued.insert(contentsOf: back, at: 0)
        if queued.count > Self.maximumQueue {
            queued.removeLast(queued.count - Self.maximumQueue)
        }
    }

    // MARK: - Rendering

    private func runPasses() async {
        guard !isRendering else { return }
        isRendering = true
        idleToken &+= 1

        var failures = 0
        while !isUnavailable, let batch = nextBatch() {
            guard await MathIslandAssets.shared.prepare() else {
                requeue(batch.items, style: batch.style)
                markUnavailable()
                break
            }
            if await renderChunk(batch.items, style: batch.style) {
                // Attempted, not necessarily drawn: an expression KaTeX refuses is not asked twice.
                for item in batch.items { attempted.insert(Self.key(item.id, batch.style)) }
                failures = 0
                continue
            }
            requeue(batch.items, style: batch.style)
            teardownPage()
            failures += 1
            if failures >= 2 { markUnavailable() }
        }

        isRendering = false
        if !isUnavailable, !queued.isEmpty {
            schedule()
        } else {
            scheduleIdleTeardown()
        }
    }

    /// One page-load worth of equations. Returns `false` only when the *page* failed — an
    /// expression KaTeX could not parse is a missing glyph, not an unhealthy island.
    private func renderChunk(_ items: [MathIslandItem], style: MathIslandStyle) async -> Bool {
        guard let json = Self.payload(items: items, style: style) else { return false }
        guard let view = await bootedWebView() else { return false }

        view.evaluateJavaScript("window.firasRun(" + json + ");", completionHandler: nil)
        guard case .done(let firstFrames, let size) = await wait(seconds: 12) else { return false }

        var frames = firstFrames
        if size.width > canvas.width + 0.5 || size.height > canvas.height + 0.5 {
            let width = min(1400, max(canvas.width, size.width + 8))
            let height = min(6000, max(canvas.height, size.height + 8))
            canvas = CGSize(width: width, height: height)
            view.frame = CGRect(origin: view.frame.origin, size: canvas)
            view.evaluateJavaScript("window.firasMeasure();", completionHandler: nil)
            guard case .done(let grown, _) = await wait(seconds: 10) else { return false }
            frames = grown
        }

        let wanted = frames.filter { $0.ok }.count
        let drawn = await capture(frames, items: items, style: style, view: view)
        // The page said it drew something and not one pixel came back: the snapshot side is broken,
        // not the LaTeX. Worth exactly one fresh page before the island gives up.
        return wanted == 0 || drawn > 0
    }

    private func capture(
        _ frames: [MathIslandFrame],
        items: [MathIslandItem],
        style: MathIslandStyle,
        view: WKWebView
    ) async -> Int {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return 0 }

        var drawn = 0
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
            remember(
                MathGlyph(
                    image: image,
                    size: image.size,
                    baseline: max(0, min(image.size.height, baseline))
                ),
                key: Self.key(items[frame.index].id, style)
            )
            drawn += 1
        }
        return drawn
    }

    private func snapshot(_ view: WKWebView, configuration: WKSnapshotConfiguration) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            view.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - The cache

    private func remember(_ glyph: MathGlyph, key: String) {
        if let old = store[key] { bytes -= Self.cost(old) }
        store[key] = glyph
        bytes += Self.cost(glyph)
        clock &+= 1
        lastUse[key] = clock
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        guard store.count > Self.maximumGlyphs || bytes > Self.maximumBytes else { return }
        for entry in lastUse.sorted(by: { $0.value < $1.value }) {
            guard store.count > Self.maximumGlyphs || bytes > Self.maximumBytes else { break }
            if let victim = store.removeValue(forKey: entry.key) { bytes -= Self.cost(victim) }
            lastUse.removeValue(forKey: entry.key)
        }
        if bytes < 0 { bytes = 0 }
    }

    private static func cost(_ glyph: MathGlyph) -> Int {
        if let bitmap = glyph.image.cgImage {
            return max(1, bitmap.bytesPerRow * bitmap.height)
        }
        let scale = max(CGFloat(1), glyph.image.scale)
        let area = glyph.size.width * scale * glyph.size.height * scale * 4
        // `Int(_:)` traps on a NaN or an out-of-range double, and a size is not always sane.
        guard area.isFinite, area > 1 else { return 1 }
        return Int(min(area, 64_000_000))
    }

    // MARK: - The page

    private func bootedWebView() async -> WKWebView? {
        if let view = webView, isBooted { return view }
        teardownPage()

        let window = Self.hostWindow()
        let width = max(360, min(1200, window?.bounds.width ?? 390))
        canvas = CGSize(width: width, height: 2400)

        let bridge = MathIslandBridge(island: self)
        guard let view = makeWebView(bridge: bridge) else { return nil }
        self.bridge = bridge
        self.webView = view
        attach(view, to: window)

        guard let url = URL(string: MathIslandAssets.scheme + "://katex/index.html") else {
            teardownPage()
            return nil
        }
        view.load(URLRequest(url: url))

        if case .booted = await wait(seconds: 14) {
            isBooted = true
            return view
        }
        teardownPage()
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
    /// The alpha is deliberately just above the 0.01 at which UIKit stops drawing a view at all.
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

    /// The page, not the cache. Every bitmap it produced stays exactly where it is.
    private func teardownPage() {
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

    private func scheduleIdleTeardown() {
        idleToken &+= 1
        let token = idleToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTeardown) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.idleToken == token else { return }
                guard !self.isRendering, self.queued.isEmpty else { return }
                self.teardownPage()
            }
        }
    }

    private func markUnavailable() {
        isUnavailable = true
        unavailableAt = Date()
        teardownPage()
    }

    // MARK: - Bridge

    /// Waits for exactly one message from the page. The watchdog resolves the wait if the page
    /// never answers — a blocked CDN must cost one timeout, never a stuck island.
    private func wait(seconds: Double) async -> MathIslandSignal {
        waitToken &+= 1
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
        waitToken &+= 1
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
                // `Int(_:)` traps on a NaN or an out-of-range double; `Int(exactly:)` answers nil.
                let index = Self.number(entry["i"]).flatMap { Int(exactly: $0.rounded()) } ?? -1
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
