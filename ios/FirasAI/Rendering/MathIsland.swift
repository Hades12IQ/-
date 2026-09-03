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
/// 4. *A miss settled.* «من اروح لغير محادثة و ارجع، نصهم يرجعون لاتكس عادي» — leave the
///    conversation, come back, and half the equations are Unicode again. Everything above keeps a
///    bitmap that exists; nothing asked for one that had gone. Every request fired exactly once —
///    a display row's `.task(id:)` when the row appeared, the priming pass when the view was
///    built — and inline mathematics never requested at all, it only read. So an eviction, a lost
///    race, or a style the priming pass never rendered left the reader with the Unicode form and
///    nothing in the app able to ask again. `glyph(for:style:)` now re-opens its own request on a
///    miss, `known` keeps the TeX a reader does not hold, and `retries` stops that from becoming a
///    page that never settles.
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
    /// How many times one equation may be handed back for another attempt.
    ///
    /* A MISS MUST RE-REQUEST, AND IT MUST NOT RE-REQUEST FOREVER. Everything that is not a
       verdict from KaTeX — a snapshot of a page WebKit had not painted yet, a frame the page
       never reported at all, a box measured against a canvas that has since grown — is worth
       another look and is worth exactly three of them. Past that the equation keeps its Unicode
       form, which is a readable answer, rather than a page that never stops loading. */
    private static let maximumRetries = 3
    /// Expressions remembered by id so a *read* can re-open a request. Bounded because it holds
    /// the source of every equation the reader has scrolled past this launch.
    private static let maximumKnown = 1500
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

    /// Every expression the island has ever been asked to draw, by content id.
    ///
    /* THIS IS WHAT LETS A MISS ASK AGAIN — and a miss that cannot ask again is the whole of
       «من اروح لغير محادثة و ارجع، نصهم يرجعون لاتكس عادي». A reader holds an id and a style
       and nothing else: a paragraph collecting its inline glyphs never had the TeX, and a
       display row's `.task(id:)` fires once, when the row appears, and never again. So every
       path that lost its bitmap afterwards — evicted by the LRU out from under a row still on
       screen, lost to a page that had not painted, or asked for in a style the priming pass
       never rendered — settled on the Unicode form for the rest of the launch with nothing left
       in the app able to ask a second time. The island keeps the TeX, so the read *is* the
       request. */
    @ObservationIgnored private var known: [String: MathIslandItem] = [:]
    /// How many times each composite key has been handed back for another attempt.
    @ObservationIgnored private var retries: [String: Int] = [:]

    // MARK: - Queue

    private struct Pending {
        let item: MathIslandItem
        let style: MathIslandStyle
    }

    @ObservationIgnored private var queued: [Pending] = []
    /// Membership of `queued`. A read asks on every redraw of every row it appears in, and a
    /// linear scan of 240 pending equations per read is a scroll dropped on the floor.
    @ObservationIgnored private var queuedKeys: Set<String> = []
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
        guard let found = store[composite] else {
            reopen(id: id, style: style, composite: composite)
            return nil
        }
        clock &+= 1
        lastUse[composite] = clock
        return found
    }

    /// A read that found nothing puts the equation back in the queue.
    ///
    /* THE FAILURE MODE IS NOW SAFE, WHICH IS THE POINT. Every other way into the island fires
       exactly once — a display row's `.task(id:)` when the row appears, the whole-message
       priming pass when the view is built — so a bitmap that went missing after that was
       missing for good. Three ways it went missing, all of them silent:
       * the LRU evicted it out from under a row that is still on screen, and the row, already
         laid out, never asks again;
       * it lost a race to a page WebKit had not painted into yet;
       * it was drawn in one style and read in another — a card renders its markdown on
         `palette.surface` and every row inside it reads on `palette.background`, so every key
         misses by the ground it was baked against.
       Inline mathematics had no request path at all: `MarkdownBlockRow` only ever *reads* the
       island. Now the read is the request, and the worst a miss costs is the Unicode form for
       one more beat. `attempted` still has the last word, so an expression KaTeX genuinely
       refuses is asked for once and never again, and `retries` bounds everything else. */
    private func reopen(id: String, style: MathIslandStyle, composite: String) {
        guard !attempted.contains(composite), !queuedKeys.contains(composite) else { return }
        guard let item = known[id] else { return }
        clearExpiredFailure()
        guard !isUnavailable, queued.count < Self.maximumQueue else { return }
        queued.append(Pending(item: item, style: style))
        queuedKeys.insert(composite)
        schedule()
    }

    // MARK: - Requesting

    /// Register equations. Calls coalesce: every block of one answer lands in the same batch, and a
    /// batch that arrives while a page is already open is picked up by the pass after it.
    ///
    /// Nothing here removes anything. An equation that has been drawn stays drawn.
    func request(_ items: [MathIslandItem], style: MathIslandStyle) {
        guard !items.isEmpty else { return }

        /* REGISTERED BEFORE ANYTHING BELOW IS ALLOWED TO REFUSE THEM. `known` is the only way a
           later read can re-open a request, so an answer that arrived while the CDN was
           unreachable has to leave its expressions here anyway — otherwise the cooldown expires
           and not one thing on screen is able to ask a second time. */
        for item in items where !item.tex.isEmpty && MathScanner.isTypesettable(item.tex) {
            register(item)
        }

        clearExpiredFailure()
        guard !isUnavailable else { return }

        var added = false
        for item in items {
            guard !item.tex.isEmpty, MathScanner.isTypesettable(item.tex) else { continue }
            let composite = Self.key(item.id, style)
            if attempted.contains(composite) || store[composite] != nil { continue }
            if queuedKeys.contains(composite) { continue }
            guard queued.count < Self.maximumQueue else { break }
            queued.append(Pending(item: item, style: style))
            queuedKeys.insert(composite)
            added = true
        }
        guard added else { return }
        schedule()
    }

    /// A message that failed while the phone was in a lift is allowed to try again later. The
    /// retry is driven by a reader asking again, never by a timer of our own.
    private func clearExpiredFailure() {
        guard isUnavailable, let at = unavailableAt else { return }
        guard Date().timeIntervalSince(at) > Self.failureCooldown else { return }
        isUnavailable = false
        unavailableAt = nil
    }

    private func register(_ item: MathIslandItem) {
        // A flush costs nothing a reader can see: the priming pass and every display row put
        // their own expressions straight back the next time they are laid out.
        if known.count >= Self.maximumKnown, known[item.id] == nil { known.removeAll() }
        known[item.id] = item
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
        /* AND THE LOST RACES ARE FORGIVEN. `retries` caps how many times one key may be handed
           back; the end of a stream, a regenerate or a version switch is the moment to let an
           equation that lost three of them start its count over. What this deliberately does
           NOT clear is `attempted` — an expression KaTeX looked at and refused stays refused,
           so nothing here can turn into a page that reloads forever. */
        retries.removeAll()
        if !queued.isEmpty { schedule() }
    }

    /// Sign-out and "delete my data": every bitmap goes, and so does the page.
    func reset() {
        store.removeAll()
        lastUse.removeAll()
        bytes = 0
        clock = 0
        queued.removeAll()
        queuedKeys.removeAll()
        attempted.removeAll()
        retries.removeAll()
        known.removeAll()
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
            var taken: Set<String> = []
            for pending in queued {
                guard pending.style.key == style.key, items.count < Self.chunkSize else {
                    rest.append(pending)
                    continue
                }
                /* AND THE KEY STAYS SET WHILE THE BATCH IS IN FLIGHT. `queuedKeys` is what a
                   read consults before it re-opens a request, and the gap between leaving this
                   array and being marked `attempted` is a page boot plus a render — fourteen
                   seconds of a reader being told nobody is drawing this. It is cleared where
                   the batch is resolved, not where it is picked up. What is dropped here is
                   dropped for good, so its key goes with it. */
                let composite = Self.key(pending.item.id, pending.style)
                if attempted.contains(composite) || store[composite] != nil {
                    queuedKeys.remove(composite)
                    continue
                }
                guard taken.insert(pending.item.id).inserted else { continue }
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
        for item in items { queuedKeys.insert(Self.key(item.id, style)) }
        if queued.count > Self.maximumQueue {
            let excess = queued.count - Self.maximumQueue
            for pending in queued.suffix(excess) {
                queuedKeys.remove(Self.key(pending.item.id, pending.style))
            }
            queued.removeLast(excess)
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

        /* ATTEMPTED BEFORE THE CAPTURE, NOT AFTER IT. An expression KaTeX refuses is not asked
           twice — that is what this set is for — but the capture is also the one place that
           HANDS A KEY BACK when the equation only lost a race. Marking the whole batch after
           the capture returned overwrote every one of those releases the instant they were
           made, so «مرات يطفر» never actually got the second chance this file promises it. */
        for item in items {
            let composite = Self.key(item.id, style)
            attempted.insert(composite)
            // The batch is resolved: it is no longer in flight, and a key `release` hands back
            // below has to be one a read is allowed to ask for again.
            queuedKeys.remove(composite)
        }

        /* AND A SILENCE IS NOT A REFUSAL. The page reports one frame per element it can find;
           an item it never mentioned — an element that was not there when it measured, a batch
           whose canvas grew out from under the measurement — carries no verdict at all, and
           retiring it on silence is how an equation reverts with nothing left to ask. */
        var reported: Set<Int> = []
        for frame in frames where frame.index >= 0 && frame.index < items.count {
            reported.insert(frame.index)
        }
        for index in items.indices where !reported.contains(index) {
            release(Self.key(items[index].id, style))
        }

        let drawn = await capture(frames, items: items, style: style, view: view)
        // The page said it drew something and not one pixel came back: the snapshot side is broken,
        // not the LaTeX. Worth exactly one fresh page before the island gives up.
        return wanted == 0 || drawn > 0
    }

    /// Hand one key back so a later pass may draw it — up to `maximumRetries` times.
    ///
    /// Answers `false` once the equation has spent its attempts, which is the moment it settles
    /// into its Unicode form on purpose rather than by accident.
    @discardableResult
    private func release(_ key: String) -> Bool {
        let count = (retries[key] ?? 0) + 1
        guard count <= Self.maximumRetries else { return false }
        retries[key] = count
        attempted.remove(key)
        return true
    }

    private func capture(
        _ frames: [MathIslandFrame],
        items: [MathIslandItem],
        style: MathIslandStyle,
        view: WKWebView
    ) async -> Int {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            // There is no page to read pixels out of. Not one of these is the LaTeX's fault.
            for frame in frames where frame.ok && frame.index >= 0 && frame.index < items.count {
                release(Self.key(items[frame.index].id, style))
            }
            return 0
        }

        var drawn = 0
        for frame in frames {
            guard frame.index >= 0, frame.index < items.count else { continue }
            let key = Self.key(items[frame.index].id, style)
            // KaTeX read this expression and refused it. That verdict is final, on purpose.
            guard frame.ok else { continue }

            let box = frame.rect
            guard box.width > 1, box.height > 1,
                  box.minX >= -0.5, box.minY >= -0.5,
                  box.maxX <= bounds.width + 0.5, box.maxY <= bounds.height + 0.5 else {
                // Measured against a canvas that is no longer this shape. Ask on the next page.
                release(key)
                continue
            }

            let padded = box.insetBy(dx: -1, dy: -1).intersection(bounds)
            guard padded.width > 1, padded.height > 1 else {
                release(key)
                continue
            }

            let configuration = WKSnapshotConfiguration()
            configuration.rect = padded
            guard let image = await snapshot(view, configuration: configuration) else {
                release(key)
                continue
            }
            // A BLANK BITMAP IS WORSE THAN NO BITMAP. It has the right size and a right
            // baseline, so it is accepted and drawn, and it replaces the Unicode form the
            // reader was already reading with an empty gap of exactly the same height.
            //
            /* AND A REFUSAL HERE MUST NOT BE FINAL. WebKit may simply not have painted this
               region yet, and `attempted` never asks twice — so one unlucky frame would leave
               that equation in its Unicode form for the rest of the launch. That is the
               «مرات يطفر» the owner reports: not some equations failing, the same equation
               losing a race. One more look after a beat, and if it is still empty the key is
               released so a later pass can try again on a page that has settled. */
            var ready = Self.hasInk(image)
            var bitmap = image
            // Two more looks, the second further out. One beat was enough for a page that had
            // been up for a while; a page raised a moment ago — which is every page after the
            // reader left the conversation and the island idled itself away — is still laying
            // out its fonts on the first, and that is exactly the visit that came back raw.
            var beat: UInt64 = 200_000_000
            var look = 0
            while !ready && look < 2 {
                try? await Task.sleep(nanoseconds: beat)
                if let again = await snapshot(view, configuration: configuration), Self.hasInk(again) {
                    bitmap = again
                    ready = true
                }
                beat += 300_000_000
                look += 1
            }
            guard ready else {
                release(key)
                continue
            }

            let baseline = frame.baseline + (box.minY - padded.minY)
            remember(
                MathGlyph(
                    image: bitmap,
                    size: bitmap.size,
                    baseline: max(0, min(bitmap.size.height, baseline))
                ),
                key: key
            )
            drawn += 1
        }
        return drawn
    }

    /// Does this bitmap carry anything at all?
    ///
    /// `takeSnapshot` hands back an image of the requested size whether or not WebKit painted
    /// into it, so a page it has stopped painting yields a flawless blank. Sixteen by sixteen
    /// is plenty: an equation has dark pixels somewhere and a flat field has none anywhere.
    /// Anything that cannot be measured is accepted — refusing on a failure to look would
    /// throw away good glyphs on the strength of no evidence.
    private static func hasInk(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return true }
        return pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return true
            }
            context.interpolationQuality = .low
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes.count >= 4 else { return true }
            let red = Int(bytes[0])
            let green = Int(bytes[1])
            let blue = Int(bytes[2])
            let alpha = Int(bytes[3])
            var index = 0
            while index + 3 < bytes.count {
                let delta = abs(Int(bytes[index]) - red)
                    + abs(Int(bytes[index + 1]) - green)
                    + abs(Int(bytes[index + 2]) - blue)
                    + abs(Int(bytes[index + 3]) - alpha)
                if delta > 24 { return true }
                index += 4
            }
            return false
        }
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
        /* EVICTED PAST THE LINE, NOT UP TO IT. A read now re-opens a request for whatever it
           cannot find, so stopping the moment the cache is one byte inside its budget means the
           next bitmap evicts the one before it, that one is read and asked for again, and the
           island renders in a circle. A tenth of headroom is a quiet cache. */
        let countFloor = (Self.maximumGlyphs * 9) / 10
        let byteFloor = (Self.maximumBytes / 10) * 9
        for entry in lastUse.sorted(by: { $0.value < $1.value }) {
            guard store.count > countFloor || bytes > byteFloor else { break }
            if let victim = store.removeValue(forKey: entry.key) { bytes -= Self.cost(victim) }
            lastUse.removeValue(forKey: entry.key)
            /* AND THE KEY IS RELEASED. `request` refuses anything already in `attempted`, so
               dropping a bitmap without dropping its key meant the equation could never be
               drawn again for the rest of the launch: it reverted to its Unicode form and
               nothing would ever ask for it a second time. Eviction is supposed to make room,
               not retire an equation — and a bitmap that existed is proof this expression
               draws, so it does not spend one of the attempts a lost race would. */
            attempted.remove(entry.key)
            retries.removeValue(forKey: entry.key)
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

        /* NO WINDOW, NO PAGE. WebKit does not paint a view that belongs to no window, and
           `takeSnapshot` answers that with a flawless blank rather than with an error — so a
           page raised while the scene was between states used to spend a whole batch of
           equations manufacturing empty rectangles, and every one of them was retired. Failing
           here costs a beat and keeps the Unicode form; carrying on costs the equations. */
        guard attach(view, to: window) else {
            teardownPage()
            return nil
        }

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
        /* AND IT MUST NOT BE OPAQUE, or WebKit composites the page onto white before the
           snapshot is taken and hands back the very rectangle transparency exists to
           avoid. All three have to agree: the document paints nothing, the web view is
           not opaque, and the scroll view underneath it is clear. */
        view.isOpaque = false
        view.backgroundColor = UIColor.clear
        view.scrollView.backgroundColor = UIColor.clear
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
    ///
    /* AND RENDERED, WHICH IT WAS NOT. Held at alpha 0.012 behind the app, the page was
       present and, to WebKit, invisible — and WebKit stops painting a view it believes
       nobody can see. `takeSnapshot` then hands back a frame with nothing in it, which is
       precisely the "the page said it drew something and not one pixel came back" case
       this file already knows about. Every equation fell through to the Unicode
       approximation, every time, forever.
       So it gets a window of its own, one level BELOW the app's, at full opacity: WebKit
       paints it exactly as it paints anything on screen, and the app's opaque window sits
       over the whole of it. A separate window rather than a buried subview also keeps it
       away from the app's glass, which samples whatever shares its layer tree. */
    private func attach(_ view: WKWebView, to window: UIWindow?) -> Bool {
        guard let scene = window?.windowScene else { return false }
        let host = UIWindow(windowScene: scene)
        host.windowLevel = UIWindow.Level.normal - 1
        host.backgroundColor = UIColor.clear
        host.isUserInteractionEnabled = false
        host.frame = CGRect(origin: .zero, size: canvas)
        host.isHidden = false
        view.alpha = 1
        view.frame = CGRect(origin: .zero, size: canvas)
        host.addSubview(view)
        islandWindow = host
        return true
    }

    /// The window the page lives in. Held so teardown can put it away; a stray window left
    /// behind would sit under the app for the rest of the launch.
    private var islandWindow: UIWindow?

    /// The foreground scene first. A window belonging to a scene that is not on screen has no
    /// compositor behind it, and a page hung off one snapshots as an empty rectangle.
    private static func hostWindow() -> UIWindow? {
        var fallback: UIWindow?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let found = windowScene.windows.first(where: { $0.isKeyWindow })
                ?? windowScene.windows.first
            guard let found else { continue }
            if windowScene.activationState == .foregroundActive { return found }
            if fallback == nil { fallback = found }
        }
        return fallback
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
        // Outside the `if`: a page that failed before its view was kept would otherwise leave
        // its window under the app for the rest of the launch.
        islandWindow?.isHidden = true
        islandWindow = nil
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
