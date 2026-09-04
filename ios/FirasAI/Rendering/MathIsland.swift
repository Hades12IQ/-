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
/// 5. *A launch settled.* «من اطلع من التطبيق و ارجع تختفي المعادلات» — leave the app, come back,
///    and the equations of an old conversation are Unicode. Everything above depends on a READ to
///    ask again, and a read happens when a row is laid out again, and a row is laid out again when
///    this observed store changes. The first page of a launch is the coldest one there is — a web
///    content process that has never run, fonts that have never been through it, a window raised a
///    moment ago — and when it failed, the store never changed, so no row was ever redrawn, so no
///    read ever happened, so nothing ever asked a second time. Two dead ends followed from that
///    and both were permanent: a failed pass left its whole batch in `queued` with every key still
///    marked as carried, and `clearExpiredFailure` cleared the cooldown only when a reader asked;
///    and an equation that spent its three attempts stayed in `attempted` with no way back at all
///    on a conversation that is not streaming. So the island now asks on the reader's behalf —
///    `scheduleRecovery` after a cooldown, `grantAmnesty` after a retirement — and both are
///    counted, so a phone that genuinely cannot typeset stops trying and keeps the Unicode form.
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
    /// How long after an equation spends its attempts before the island offers it one more round.
    ///
    /* LONG ENOUGH TO BE A DIFFERENT PAGE. Everything that spends an attempt without a verdict
       from KaTeX is a fact about the page, not about the expression, and the page that produces
       those facts is the FIRST one of a launch: a cold web content process, fonts that have not
       been through it yet, a window that has just been raised. Three passes spend the whole
       budget inside two seconds of that page, so the round after it has to wait long enough for
       the phone to have finished launching. */
    private static let amnestyDelay: Double = 25
    /// How many rounds of amnesty one launch may grant. Three, and then the Unicode form stands.
    private static let maximumAmnesties = 3
    /// How many times the cooldown may expire on a timer of ours rather than on a reader's ask.
    private static let maximumRecoveries = 6
    /// How long the island waits for a scene to come on screen before asking again, and how many
    /// times. Thirty seconds of a launch, which is far longer than a launch.
    private static let stallDelay: Double = 2
    private static let maximumStalls = 15
    /// Retired equations remembered so the island can offer them that round.
    private static let maximumRetired = 400
    /// How many pages may come back with no ink in them at all before the island stops treating
    /// that as the page's fault and starts charging the equations for it.
    ///
    /* OR IT NEVER SETTLES. Refunding a blank page is right for the first few — a cold launch
       produces them and the equations did nothing wrong — but a phone that cannot paint at all
       would otherwise refund for ever, and every refund buys another boot and another render.
       After four, blanks spend attempts like anything else: the equations retire, the amnesty
       gives them three more rounds, and then the island falls quiet with the Unicode form on
       screen, which is a readable answer and costs nothing. */
    private static let maximumBlankRefunds = 4
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
    @ObservationIgnored private var persistentKeys: Set<String> = []

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
        var previewGroup: String? = nil
    }

    @ObservationIgnored private var queued: [Pending] = []
    /// Membership of `queued`. A read asks on every redraw of every row it appears in, and a
    /// linear scan of 240 pending equations per read is a scroll dropped on the floor.
    @ObservationIgnored private var queuedKeys: Set<String> = []
    @ObservationIgnored private var previewGroups: [String: String] = [:]
    // Only the current page can be promoted while it is outside `queued`; both sets are
    // bounded by chunkSize and are cleared when that page resolves.
    @ObservationIgnored private var inFlightKeys: Set<String> = []
    @ObservationIgnored private var inFlightPromotions: Set<String> = []
    /// Composite keys already sent to a page — drawn or refused. Never retried in the same style.
    @ObservationIgnored private var attempted: Set<String> = []
    /// The equations `attempted` is holding that nothing on screen can ever ask for again, with
    /// everything needed to ask on their behalf. See `retire`.
    @ObservationIgnored private var exhausted: [String: Pending] = [:]
    @ObservationIgnored private var amnesties = 0
    @ObservationIgnored private var isAmnestyArmed = false
    @ObservationIgnored private var recoveries = 0
    @ObservationIgnored private var recoveryToken = 0
    /// A pass put off because there was no scene to paint into, and how many in a row.
    @ObservationIgnored private var isDeferred = false
    @ObservationIgnored private var stalls = 0
    /// Pages so far forgiven for coming back with nothing in them. Reset by a page that draws.
    @ObservationIgnored private var blankRefunds = 0
    /// Which island a pass belongs to. Bumped by `reset`, so work that was already in flight when
    /// the reader signed out cannot put their equations back afterwards.
    @ObservationIgnored private var epoch = 0
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

#if DEBUG
    /// Evidence must observe the mounted view's requests, never create a request by polling.
    func peekForReliability(_ id: String, style: MathIslandStyle) -> MathGlyph? {
        store[Self.key(id, style)]
    }

    /// Exercise the real queue/retry paths without booting a page or changing shared state.
    static func previewReliabilityFailures(style: MathIslandStyle) -> [String] {
        let island = MathIsland()
        let item = MathIslandItem(tex: "\\frac{47}{83}", isDisplay: false)
        let newer = MathIslandItem(tex: "\\frac{47}{83}+x", isDisplay: false)
        let key = Self.key(item.id, style)
        let pending = Pending(item: item, style: style, previewGroup: "first")
        var failures: [String] = []

        island.previewGroups["first"] = Self.key(newer.id, style)
        island.queuedKeys.insert(key) // A page had already picked up the older prefix.
        island.requeue([pending])
        if !island.queued.isEmpty || island.queuedKeys.contains(key) {
            failures.append("Superseded math preview survived page retry")
        }
        if island.release(pending, era: island.epoch) || !island.retries.isEmpty {
            failures.append("Superseded math preview spent another snapshot attempt")
        }
        island.exhausted[key] = pending
        if island.forgiveRetired() || !island.queued.isEmpty {
            failures.append("Retired math preview returned after its source changed")
        }

        island.previewGroups["second"] = key
        island.requeue([pending])
        if island.queued.first?.previewGroup != "second" {
            failures.append("Shared math preview lost its remaining visible owner")
        }
        island.queued.removeAll()
        island.queuedKeys.removeAll()
        island.previewGroups.removeAll()
        island.inFlightPromotions.insert(key)
        island.requeue([pending])
        if island.queued.count != 1 || island.queued.first?.previewGroup != nil {
            failures.append("Closing a live formula failed to promote its in-flight preview")
        }

        island.queued.removeAll()
        island.queuedKeys.removeAll()
        island.inFlightPromotions.removeAll()
        let previousEra = island.epoch
        island.epoch &+= 1
        let completed = Pending(item: item, style: style)
        if island.release(completed, era: previousEra) || !island.queued.isEmpty || !island.retries.isEmpty {
            failures.append("Old-owner snapshot repopulated the queue after identity reset")
        }
        return failures
    }
#endif

    /// The bitmap for one equation in one style, or `nil` while it is still being drawn — and
    /// forever, if it can never be drawn. `nil` is not an error state: the caller is already
    /// showing the Unicode form.
    func glyph(for id: String, style: MathIslandStyle) -> MathGlyph? {
        let composite = Self.key(id, style)
        guard let found = store[composite] else {
            // Return synchronously so a restored conversation paints its final math immediately.
            // Do not repopulate the observed LRU from a body read: more visible equations than
            // its limit would continually evict and reinsert one another, moving the scroll view.
            if let saved = MathGlyphDiskCache.read(composite) {
                return saved
            }
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
       one more beat. `attempted` still has the last word here, so an expression KaTeX genuinely
       refuses is asked for once and never again, and `retries` bounds everything else.
       WHAT THIS CANNOT DO is notice a launch in which nothing was ever drawn. A read happens
       when a row is laid out again, and a row is laid out again when the observed store
       changes; an island that failed its first page changes nothing in that store, so no read
       ever comes and no miss is ever seen. `scheduleRecovery` and `grantAmnesty` are the other
       half of this function — the island asking on the reader's behalf. */
    private func reopen(id: String, style: MathIslandStyle, composite: String) {
        clearExpiredFailure()

        // Drawn and refused both live here. Only `grantAmnesty` may undo that, and it arms
        // itself the moment an equation is retired — never a read, or a refusal would loop.
        guard !attempted.contains(composite) else { return }

        /* ALREADY CARRIED — BUT CARRIED BY WHAT? A key sitting in `queuedKeys` used to end this
           function, on the reasonable assumption that something was going to draw it. Nothing
           guaranteed that. A pass that failed twice requeues its whole batch, sets the cooldown
           and BREAKS out of its loop, leaving every one of those keys marked as carried with no
           pass, no timer and no schedule behind them. From then on this guard refused every
           read, `request` found nothing new to add and returned before scheduling, and the
           island sat with a full queue and no reason ever to run again.
           That is «من اطلع من التطبيق و ارجع تختفي المعادلات» exactly: the first page of a
           launch is the likeliest one to fail, and failing it twice used to cost the whole
           launch. A carried key now kicks the pump instead of trusting it. */
        if queuedKeys.contains(composite) {
            pump()
            return
        }
        guard let item = known[id] else { return }
        guard !isUnavailable, queued.count < Self.maximumQueue else { return }
        queued.append(Pending(item: item, style: style))
        queuedKeys.insert(composite)
        schedule()
    }

    /// Make sure a queue that has work in it is actually going to be looked at.
    ///
    /// The one call every recovery path ends in. `schedule` re-states these guards; saying them
    /// here as well is what makes each caller's intent readable at the call site.
    private func pump() {
        guard !queued.isEmpty, !isRendering, !isScheduled, !isUnavailable else { return }
        schedule()
    }

    // MARK: - Requesting

    /// Register equations. Calls coalesce: every block of one answer lands in the same batch, and a
    /// batch that arrives while a page is already open is picked up by the pass after it.
    ///
    /// Drawn equations stay drawn. Superseded, unfinished previews need no further page work.
    func request(_ items: [MathIslandItem], style: MathIslandStyle, persist: Bool = false,
                 previewGroup: String? = nil, previewID: String? = nil) {
        if let previewGroup {
            previewGroups[previewGroup] = previewID.map { Self.key($0, style) }
        }
        // Promotion must precede pruning: the closing delimiter can turn the same prefix
        // into a complete expression while its page is still awaiting a snapshot.
        for item in items where item.id != previewID {
            let composite = Self.key(item.id, style)
            if inFlightKeys.contains(composite) { inFlightPromotions.insert(composite) }
            for index in queued.indices where Self.key(queued[index].item.id, queued[index].style) == composite {
                queued[index].previewGroup = nil
            }
            if var pending = exhausted[composite] {
                pending.previewGroup = nil
                exhausted[composite] = pending
            }
        }
        pruneObsoletePreviews()
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
            if persist && item.id != previewID {
                persistentKeys.insert(composite)
                if let glyph = store[composite] { MathGlyphDiskCache.write(glyph, key: composite) }
            }
            if store[composite] == nil, let saved = MathGlyphDiskCache.read(composite) {
                remember(saved, key: composite)
            }
            if attempted.contains(composite) || store[composite] != nil { continue }
            if queuedKeys.contains(composite) {
                continue
            }
            guard queued.count < Self.maximumQueue else { break }
            queued.append(Pending(item: item, style: style, previewGroup: item.id == previewID ? previewGroup : nil))
            queuedKeys.insert(composite)
            added = true
        }
        /* AND THE PUMP IS KICKED EVEN WHEN NOTHING WAS ADDED. `added` is false precisely when
           every expression of this answer is already carried by the queue — which is the state a
           stranded pass leaves behind, and returning here without a word was the second half of
           what made that state permanent. Opening the conversation again, or scrolling the row
           back on screen, now restarts the island instead of confirming its silence. */
        if added || !queued.isEmpty { schedule() }
    }

    /// An in-flight preview keeps its ownership through retries. Another visible message
    /// asking for the same expression can take ownership; a completed request makes it normal.
    private func currentPending(_ pending: Pending) -> Pending? {
        guard let group = pending.previewGroup else { return pending }
        let composite = Self.key(pending.item.id, pending.style)
        if inFlightPromotions.contains(composite) {
            return Pending(item: pending.item, style: pending.style)
        }
        if previewGroups[group] == composite { return pending }
        guard let other = previewGroups.first(where: { $0.value == composite }) else { return nil }
        return Pending(item: pending.item, style: pending.style, previewGroup: other.key)
    }

    private func pruneObsoletePreviews() {
        let oldKeys = Set(queued.map { Self.key($0.item.id, $0.style) })
        queued = queued.compactMap { currentPending($0) }
        let keptKeys = Set(queued.map { Self.key($0.item.id, $0.style) })
        for key in oldKeys.subtracting(keptKeys) where !inFlightKeys.contains(key) {
            queuedKeys.remove(key)
        }
        exhausted = exhausted.compactMapValues { currentPending($0) }
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
    func prime(markdown: String, messageID: String, style: MathIslandStyle, persist: Bool = false) {
        guard !markdown.isEmpty else { return }
        let spans = MathScanner.spans(in: markdown)
        guard !spans.isEmpty else { return }
        request(spans.map { MathIslandItem(span: $0) }, style: style, persist: persist)
    }

    /// Regenerate, version switch, edit, end of stream. Deliberately **not** a cache flush: a glyph
    /// describes its own TeX, so nothing under this id can have gone stale. All this does is let a
    /// message that failed try again.
    func allowRetry() {
        isUnavailable = false
        unavailableAt = nil
        /* AND THE LOST RACES ARE FORGIVEN. `retries` caps how many times one key may be handed
           back; the end of a stream, a regenerate or a version switch is the moment to let an
           equation that lost three of them start its count over — counts first, and then the
           equations those counts retired, which `forgiveRetired` puts back in the queue.
           What this still does NOT do is clear `attempted` wholesale: an expression KaTeX looked
           at and refused is not in `exhausted`, stays refused, and nothing here can therefore
           turn into a page that reloads forever. */
        retries.removeAll()
        forgiveRetired()
        // A new answer is proof the app is on screen and working; the environment's budgets
        // start over with it. `amnesties` is moot — `forgiveRetired` has just emptied the set
        // it counts rounds for.
        stalls = 0
        recoveries = 0
        blankRefunds = 0
        pump()
    }

    /// Sign-out and "delete my data": every bitmap goes, and so does the page.
    func reset() {
        // Before anything is cleared, so a pass already in flight resolves into nothing rather
        // than into the reader who has just signed out.
        epoch &+= 1
        persistentKeys.removeAll()
        MathGlyphDiskCache.clear()
        store.removeAll()
        lastUse.removeAll()
        bytes = 0
        clock = 0
        queued.removeAll()
        queuedKeys.removeAll()
        previewGroups.removeAll()
        inFlightKeys.removeAll()
        inFlightPromotions.removeAll()
        attempted.removeAll()
        retries.removeAll()
        exhausted.removeAll()
        amnesties = 0
        recoveries = 0
        recoveryToken &+= 1
        stalls = 0
        blankRefunds = 0
        known.removeAll()
        isUnavailable = false
        unavailableAt = nil
        teardownPage()
    }

    // MARK: - Amnesty

    /// An equation that spent its attempts without ever getting a verdict from KaTeX.
    ///
    /* WHICH IS NOT THE SAME THING AS A REFUSAL, and treating it as one is the other half of the
       equations that do not come back. Every path that spends an attempt here is a fact about
       the PAGE — a snapshot of a view WebKit had not painted into, a frame the measurement never
       mentioned, a box measured against a canvas that has since changed shape — and every one of
       them is likeliest on the FIRST page of a launch, when the web content process is cold and
       the fonts have not yet been through it. Three passes spend the budget in a couple of
       seconds of that page; the key then stayed in `attempted`, `allowRetry` cleared the counts
       but never the set, and on a conversation opened from cold nothing calls `allowRetry` at
       all. The reader got the Unicode form for the rest of the launch.
       So the item and its style are kept, and the island asks again itself once the page has had
       time to become an ordinary warm page. */
    private func retire(_ key: String, pending: Pending) {
        if exhausted.count >= Self.maximumRetired, exhausted[key] == nil { exhausted.removeAll() }
        exhausted[key] = pending
        scheduleAmnesty()
    }

    private func scheduleAmnesty() {
        guard !isAmnestyArmed, amnesties < Self.maximumAmnesties else { return }
        isAmnestyArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.amnestyDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAmnestyArmed = false
                self.grantAmnesty()
            }
        }
    }

    /// One more round for every equation the island gave up on, asked for by the island itself.
    ///
    /* BECAUSE NOTHING ON SCREEN CAN ASK. A read re-opens a request, and a read happens when a row
       is laid out again — which happens when the observed store changes. An island that retired
       every equation of a launch changes nothing in that store, so no row is ever redrawn, so no
       read ever happens, so the retirement is permanent by construction and no amount of
       scrolling can shake it loose. The island therefore asks on the reader's behalf: three
       rounds, twenty-five seconds apart, and then the Unicode form stands on purpose. */
    private func grantAmnesty() {
        guard amnesties < Self.maximumAmnesties else { return }
        clearExpiredFailure()
        guard !isUnavailable else {
            // Mid-cooldown: a round spent on a queue nothing is going to look at is a round
            // wasted. `scheduleRecovery` owns this window; wait it out and ask again after.
            scheduleAmnesty()
            return
        }
        guard forgiveRetired() else { return }
        amnesties += 1
        pump()
    }

    /// Hand every retired equation that still has no bitmap back to the queue. Answers whether
    /// anything was actually put back, so a round that would change nothing is not spent.
    @discardableResult
    private func forgiveRetired() -> Bool {
        guard !exhausted.isEmpty else { return false }
        let retired = exhausted
        exhausted.removeAll()
        var added = false
        for (key, oldPending) in retired {
            guard let pending = currentPending(oldPending) else { continue }
            // It may have been drawn since, by a pass for another row asking the same thing.
            guard store[key] == nil else { continue }
            attempted.remove(key)
            retries.removeValue(forKey: key)
            guard !queuedKeys.contains(key), queued.count < Self.maximumQueue else { continue }
            queued.append(pending)
            queuedKeys.insert(key)
            added = true
        }
        return added
    }

    /// Give an attempt back. See the caller: a page that produced no ink at all is one bad page,
    /// not twelve bad equations, and charging the equations for it is how a launch runs out of
    /// attempts before the phone has finished starting up.
    private func refund(_ key: String) {
        exhausted.removeValue(forKey: key)
        attempted.remove(key)
        if let count = retries[key] {
            if count <= 1 {
                retries.removeValue(forKey: key)
            } else {
                retries[key] = count - 1
            }
        }
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
        let pending: [Pending]
        let style: MathIslandStyle
        var items: [MathIslandItem] { pending.map(\.item) }
    }

    /// The next page's worth of work: up to `chunkSize` equations that share one style, because the
    /// page paints its ink and its ground once per run.
    private func nextBatch() -> Batch? {
        pruneObsoletePreviews()
        while !queued.isEmpty {
            let style = queued[0].style
            var items: [Pending] = []
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
                items.append(pending)
            }
            queued = rest
            if !items.isEmpty { return Batch(pending: items, style: style) }
        }
        return nil
    }

    private func requeue(_ pending: [Pending]) {
        var existing = Set(queued.map { Self.key($0.item.id, $0.style) })
        let back = pending.compactMap { currentPending($0) }.filter {
            existing.insert(Self.key($0.item.id, $0.style)).inserted
        }
        let kept = Set(back.map { Self.key($0.item.id, $0.style) })
        for item in pending {
            let composite = Self.key(item.item.id, item.style)
            if !kept.contains(composite), !existing.contains(composite) { queuedKeys.remove(composite) }
        }
        queued.insert(contentsOf: back, at: 0)
        for item in back { queuedKeys.insert(Self.key(item.item.id, item.style)) }
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
        var stalled = false
        while !isUnavailable, let batch = nextBatch() {
            inFlightKeys = Set(batch.pending.map { Self.key($0.item.id, $0.style) })
            inFlightPromotions.removeAll()
            defer {
                inFlightKeys.removeAll()
                inFlightPromotions.removeAll()
            }
            /* NOWHERE TO PAINT IS NOT THE SAME AS FAILING TO PAINT, and confusing the two is
               how a launch loses its equations. A cold launch delivers the first rows — and
               therefore the first request — while the scene is still `foregroundInactive`;
               `hostWindow` says in its own comment that a page hung off a scene which is not on
               screen snapshots as an empty rectangle, and then hands one back anyway. So the
               island spent a fourteen-second boot and a twelve-second render on a page WebKit
               was never going to paint, collected a batch of flawless blanks, called that two
               failures and went unavailable for a minute — all before the app had finished
               coming up. The equations came back only if something later happened to ask.
               Waiting two seconds for the scene instead costs nothing and spends nothing:
               no attempt, no failure, no cooldown. */
            guard Self.hasForegroundScene() else {
                requeue(batch.pending)
                stalled = true
                break
            }
            // A pass that got as far as starting is proof the screen came back.
            stalls = 0
            /* WHICH ISLAND THIS PASS BELONGS TO. `reset()` — sign-out, "delete my data" — can
               land inside any of the awaits below, and a pass that was already in flight would
               otherwise put the previous reader's equations back into a queue that had just been
               emptied on purpose, and their bitmaps into a store that had just been cleared. A
               pass from a spent era resolves nothing and requeues nothing. */
            let era = epoch
            guard await MathIslandAssets.shared.prepare() else {
                guard era == epoch else { break }
                requeue(batch.pending)
                markUnavailable()
                break
            }
            let rendered = await renderChunk(batch, era: era)
            guard era == epoch else { break }
            if rendered {
                failures = 0
                continue
            }
            requeue(batch.pending)
            teardownPage()
            failures += 1
            if failures >= 2 { markUnavailable() }
        }

        isRendering = false
        if stalled {
            deferPass()
        } else if !isUnavailable, !queued.isEmpty {
            schedule()
        } else {
            scheduleIdleTeardown()
        }
    }

    /// Is there a scene on screen for a page to be painted into?
    ///
    /// `hostWindow` prefers one and settles for any; this asks the question without settling,
    /// because the answer decides whether a pass is worth starting at all.
    private static func hasForegroundScene() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            if scene.activationState == .foregroundActive { return true }
        }
        return false
    }

    /// The queue is fine, the island is fine, the screen is not there yet. Come back on a slow
    /// beat — never the 120 ms one, which against a scene that is still coming up is a spin.
    ///
    /// Bounded, and the bound resets on the first pass that renders anything: a phone that is
    /// genuinely not showing this app stops being asked, and the next read restarts it — a read
    /// is exactly what a returning scene produces, when SwiftUI lays every visible row out again.
    private func deferPass() {
        guard !isDeferred, stalls < Self.maximumStalls else { return }
        isDeferred = true
        stalls += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stallDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isDeferred = false
                self.pump()
            }
        }
    }

    /// One page-load worth of equations. Returns `false` only when the *page* failed — an
    /// expression KaTeX could not parse is a missing glyph, not an unhealthy island.
    private func renderChunk(_ original: Batch, era: Int) async -> Bool {
        guard let view = await bootedWebView() else { return false }
        guard era == epoch else { return true }
        // Asset/page boot can span many streamed prefixes. Only the latest wanted work
        // reaches JavaScript, and stale keys must stop claiming they are still in flight.
        let pending = original.pending.compactMap { currentPending($0) }
        let kept = Set(pending.map { Self.key($0.item.id, $0.style) })
        for item in original.pending {
            let key = Self.key(item.item.id, item.style)
            if !kept.contains(key) { queuedKeys.remove(key) }
        }
        guard !pending.isEmpty else { return true }
        let batch = Batch(pending: pending, style: original.style)
        let items = batch.items
        let style = batch.style
        guard let json = Self.payload(items: items, style: style) else { return false }

        view.evaluateJavaScript("window.firasRun(" + json + ");", completionHandler: nil)
        guard case .done(let firstFrames, let size) = await wait(seconds: 12) else { return false }
        guard era == epoch else { return true }

        var frames = firstFrames
        if size.width > canvas.width + 0.5 || size.height > canvas.height + 0.5 {
            let width = min(1400, max(canvas.width, size.width + 8))
            let height = min(6000, max(canvas.height, size.height + 8))
            canvas = CGSize(width: width, height: height)
            view.frame = CGRect(origin: view.frame.origin, size: canvas)
            view.evaluateJavaScript("window.firasMeasure();", completionHandler: nil)
            guard case .done(let grown, _) = await wait(seconds: 10) else { return false }
            guard era == epoch else { return true }
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
            release(batch.pending[index], era: era)
        }

        let drawn = await capture(frames, pending: batch.pending, style: style, view: view, era: era)
        guard era == epoch else { return true }

        /* A PAGE THAT DREW NOTHING AT ALL IS ONE BAD PAGE, NOT TWELVE BAD EQUATIONS. Every
           equation of the batch has just been charged an attempt for a failure they share and
           none of them caused, and three such pages — which is what a cold launch can produce
           inside two seconds — retired every equation on screen. The attempt is handed back; the
           batch is requeued by the caller and tried on a page that has been given a fresh
           start. `failures` still counts, so this cannot become a page that reloads forever. */
        if drawn > 0 { blankRefunds = 0 }
        if wanted > 0, drawn == 0, blankRefunds < Self.maximumBlankRefunds {
            blankRefunds += 1
            // Except the ones KaTeX itself turned down. That verdict came from the expression
            // and survives a bad page; refunding it would put a refusal back on the wheel.
            var refused: Set<Int> = []
            for frame in frames where !frame.ok && frame.index >= 0 && frame.index < items.count {
                refused.insert(frame.index)
            }
            for index in items.indices where !refused.contains(index) {
                refund(Self.key(items[index].id, style))
            }
        }

        // The page said it drew something and not one pixel came back: the snapshot side is broken,
        // not the LaTeX. Worth exactly one fresh page before the island gives up.
        return wanted == 0 || drawn > 0
    }

    /// Hand one key back so a later pass may draw it — up to `maximumRetries` times.
    ///
    /// Answers `false` once the equation has spent its attempts. That is no longer the end of it:
    /// the expression is retired into `exhausted` with the style it was asked in, and the island
    /// offers it one more round in `grantAmnesty`. Settling into the Unicode form has to be
    /// something the island decides three times over, not something a cold first page does once.
    @discardableResult
    private func release(_ original: Pending, era: Int) -> Bool {
        guard era == epoch, let pending = currentPending(original) else { return false }
        let key = Self.key(pending.item.id, pending.style)
        let count = (retries[key] ?? 0) + 1
        guard count <= Self.maximumRetries else {
            retire(key, pending: pending)
            return false
        }
        retries[key] = count
        attempted.remove(key)
        /* AND PUT BACK, not merely un-marked. "Handed back so a later pass may draw it" was only
           half of a promise: the key was un-marked and then left for a READER to notice, and a
           reader notices when a row is laid out again, and a row is laid out again when the
           observed store changes — which is precisely what does not happen on a pass that drew
           nothing. A whole batch could be released into a queue nobody was ever going to refill,
           and the equations sat there un-asked-for with the island perfectly healthy. The island
           keeps hold of them; `maximumRetries` still says how many times. */
        if !queuedKeys.contains(key), queued.count < Self.maximumQueue {
            queued.append(pending)
            queuedKeys.insert(key)
        }
        return true
    }

    private func capture(
        _ frames: [MathIslandFrame],
        pending: [Pending],
        style: MathIslandStyle,
        view: WKWebView,
        era: Int
    ) async -> Int {
        guard era == epoch else { return 0 }
        let items = pending.map(\.item)
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            // There is no page to read pixels out of. Not one of these is the LaTeX's fault.
            for frame in frames where frame.ok && frame.index >= 0 && frame.index < items.count {
                release(pending[frame.index], era: era)
            }
            return 0
        }

        var drawn = 0
        var batch: [String: MathGlyph] = [:]
        for frame in frames {
            guard frame.index >= 0, frame.index < items.count else { continue }
            let item = items[frame.index]
            let key = Self.key(item.id, style)
            // KaTeX read this expression and refused it. That verdict is final, on purpose: it is
            // the one outcome no amount of waiting for a warmer page can change, and the reason
            // `attempted` may never be forgiven wholesale.
            guard frame.ok else { continue }

            let box = frame.rect
            guard box.width > 1, box.height > 1,
                  box.minX >= -0.5, box.minY >= -0.5,
                  box.maxX <= bounds.width + 0.5, box.maxY <= bounds.height + 0.5 else {
                // Measured against a canvas that is no longer this shape. Ask on the next page.
                release(pending[frame.index], era: era)
                continue
            }

            let padded = box.insetBy(dx: -1, dy: -1).intersection(bounds)
            guard padded.width > 1, padded.height > 1 else {
                release(pending[frame.index], era: era)
                continue
            }

            let configuration = WKSnapshotConfiguration()
            configuration.rect = padded
            let snapshotImage = await snapshot(view, configuration: configuration)
            guard era == epoch else { return 0 }
            guard let image = snapshotImage else {
                release(pending[frame.index], era: era)
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
                guard era == epoch else { return 0 }
                let again = await snapshot(view, configuration: configuration)
                guard era == epoch else { return 0 }
                if let again, Self.hasInk(again) {
                    bitmap = again
                    ready = true
                }
                beat += 300_000_000
                look += 1
            }
            guard ready else {
                release(pending[frame.index], era: era)
                continue
            }

            let baseline = frame.baseline + (box.minY - padded.minY)
            /* HELD, NOT PUBLISHED. See the commit below. */
            batch[key] = MathGlyph(
                image: bitmap,
                size: bitmap.size,
                baseline: max(0, min(bitmap.size.height, baseline))
            )
            drawn += 1
        }

        /* THE WHOLE PASS AT ONCE, and this is the difference between an answer that
           settles and one that rearranges itself while it is being read.
           `store` is observed, so publishing a glyph redraws every row waiting on it. A
           typeset fraction is taller than the run of characters it replaces, so each
           publication changed the height of a paragraph — and a message with ten
           equations was therefore ten separate reflows, each one moving whatever the
           reader was looking at. That is «ترجع لاتكس و ترجع رياضيات جميلة، بيها
           نزول وصعود»: not two renderings competing, one rendering arriving in ten
           instalments.
           Committing the pass together makes every one of those rows redraw on the same
           frame: one reflow for the message, whatever it contains. */
        guard era == epoch else { return 0 }
        for (key, glyph) in batch { remember(glyph, key: key) }
        return drawn
    }

    /// Does this bitmap carry anything at all?
    ///
    /// `takeSnapshot` hands back an image of the requested size whether or not WebKit painted
    /// into it, so a page it has stopped painting yields a flawless blank. An equation has marks
    /// somewhere and a flat field has none anywhere, which is the whole test.
    /// Anything that cannot be measured is accepted — refusing on a failure to look would
    /// throw away good glyphs on the strength of no evidence.
    private static func hasInk(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        /* IS THIS FIELD UNIFORM? That is the only question that is correct for both an opaque
           frame and a transparent one, and the answer is the same either way: an equation is a
           scattering of marks and therefore varies; a blank does not vary at all.
           The version before this asked "is any pixel opaque", which is true of every pixel of
           a blank opaque page — it would have accepted every blank there is. The version
           before THAT compared a sixteenth-scale downscale, which averages a hairline into the
           ground it is being compared against and could refuse a good equation.
           Sampled at native resolution with interpolation off, so a stroke is either hit or
           missed rather than blended. Anything unmeasurable is accepted: refusing on a failure
           to look would throw away good glyphs on no evidence at all. */
        guard cg.width > 0, cg.height > 0 else { return false }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return true }

        /* IN THE SHAPE OF THE EQUATION, not squeezed into a square. The grid was a flat 48×48
           whatever came in, which for an inline `x` is an upscale and costs nothing, but for a
           display equation twelve hundred points wide is forty-eight columns standing in for
           twelve hundred — nearest neighbour, so each one is a single pixel, and a sparse
           formula of hairlines can fall between all of them. A frame that carries ink and is
           read as blank spends one of the equation's attempts, and three of those retire it.
           Anything inside the budget is now measured at ITS OWN resolution, which is what the
           paragraph above has been claiming all along; anything larger is reduced with its
           proportions intact and with more samples than the square ever gave it. */
        var width = cg.width
        var height = cg.height
        let budget = 96 * 96
        let native = cg.width * cg.height
        if native > budget {
            let shrink = (Double(budget) / Double(native)).squareRoot()
            width = max(1, min(cg.width, Int((Double(cg.width) * shrink).rounded())))
            height = max(1, min(cg.height, Int((Double(cg.height) * shrink).rounded())))
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let boxWidth = width
        let boxHeight = height
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: boxWidth,
                    height: boxHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: boxWidth * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(cg, in: CGRect(x: 0, y: 0, width: boxWidth, height: boxHeight))
            return true
        }
        guard drawn, pixels.count >= 4 else { return true }

        let red = Int(pixels[0])
        let green = Int(pixels[1])
        let blue = Int(pixels[2])
        let alpha = Int(pixels[3])
        var index = 0
        while index + 3 < pixels.count {
            let delta = abs(Int(pixels[index]) - red)
                + abs(Int(pixels[index + 1]) - green)
                + abs(Int(pixels[index + 2]) - blue)
                + abs(Int(pixels[index + 3]) - alpha)
            if delta > 24 { return true }
            index += 4
        }
        return false
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
        if persistentKeys.contains(key) { MathGlyphDiskCache.write(glyph, key: key) }
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
        /* OPAQUE. The transparent variant is the reason equations stopped surviving a
           restart: a snapshot of a non-opaque view is not guaranteed to carry alpha, and
           a frame that arrives uniformly transparent is indistinguishable from a blank.
           The page paints the theme's ground and the view shows it. */
        view.isOpaque = true
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
        scheduleRecovery()
    }

    /// The cooldown, cleared by something.
    ///
    /* IT NEVER WAS. `clearExpiredFailure` is honest about the sixty seconds, but it only runs
       when a reader asks — and a reader asks when a row is laid out again, and a row is laid out
       again when the observed store changes, and an island that has just declared itself
       unavailable changes nothing in that store. So the flag outlived its own cooldown, the
       queue it stranded stayed stranded, and the launch spent the rest of its life one guard
       away from working. A timer of our own is what makes the sixty seconds mean sixty seconds.
       Bounded, because an island that has failed six pages in six minutes is not going to
       succeed on the seventh, and the reader still has the Unicode form in front of them. */
    private func scheduleRecovery() {
        guard recoveries < Self.maximumRecoveries else { return }
        recoveries += 1
        recoveryToken &+= 1
        let token = recoveryToken
        // A second past the cooldown, so `clearExpiredFailure` reads it as expired rather than as
        // one tick short of it.
        let after: Double = Self.failureCooldown + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.recoveryToken == token else { return }
                self.clearExpiredFailure()
                guard !self.isUnavailable else { return }
                // Nothing may be queued: everything could have been retired instead. Both roads
                // out of a dead island are taken here, and both are bounded.
                self.forgiveRetired()
                self.pump()
            }
        }
    }

    // MARK: - Bridge

    /// Waits for exactly one message from the page. The watchdog resolves the wait if the page
    /// never answers — a blocked CDN must cost one timeout, never a stuck island.
    private func wait(seconds: Double) async -> MathIslandSignal {
        /* NEVER TWO CONTINUATIONS IN ONE SLOT. `waiter` holds exactly one, and overwriting it
           would strand the first: a `CheckedContinuation` that is never resumed is a pass that
           never returns, `isRendering` true for the rest of the launch, and every schedule after
           it refused at the door — the same silence, arrived at from a different direction.
           Passes are serialised, so this should never fire; it costs a comparison to make sure
           that "should" is not the only thing holding the island up. */
        resume(.failed)
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
