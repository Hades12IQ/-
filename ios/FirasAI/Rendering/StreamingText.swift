import Foundation
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// The **pacing** half of the streaming feel: text that arrives in lumps and reads as typing.
///
/// `StreamBuffer` publishes what has *arrived* at up to ten times a second, and a job poll can
/// deliver 2.5 seconds of answer in one go. Painting that directly is what the owner reads as
/// broken — the answer lurches forward a paragraph at a time and then sits still. This view keeps a
/// display cursor between the reader and the buffer: incoming text becomes a target, and the cursor
/// walks towards it on the display link. It catches up within a short window instead of replaying
/// a server snapshot for several seconds after the words have already arrived.
///
/// Wrap it around anything that renders a growing answer — the closure is handed one revealed
/// prefix and draws it, e.g. `MarkdownView(markdown: shown, messageID: …, streaming: …)`. What it
/// guarantees to whatever it wraps:
///
/// * The string handed to `content` is always a **grapheme-cluster prefix** of the text that has
///   arrived, so an Arabic letter never appears without the harakah that belongs to it and a
///   markdown block splitter never sees half a character.
/// * It only ever grows, unless the answer itself was replaced mid-turn (a retry), in which case it
///   restarts rather than splicing two attempts together.
/// * It repaints at a capped rate that falls as the answer gets longer — 60 Hz for a short reply,
///   12 Hz past 32 000 bytes — so a long answer reveals in slightly larger runs instead of melting
///   the phone. The renderer's own block cache does the rest: only the tail block re-parses.
/// * When the turn ends the remaining characters always land, inside about a sixth of a second, or
///   at once when there are too many left to read anyway.
/// * With Reduce Motion on — the system switch or the in-app one — there is no cursor at all.
struct StreamingText<Content: View>: View {

    private let text: String
    private let isStreaming: Bool
    private let motionOn: Bool
    private let identity: String
    private let content: (String) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var reveal = StreamReveal()

    /// - Parameters:
    ///   - text: everything that has arrived so far. Grows during a turn; may be replaced whole.
    ///   - isStreaming: true while more text is still expected for this turn.
    ///   - motionOn: `FirasMotion.isOn(prefs:reduceMotion:)`. The system Reduce Motion switch is
    ///     read here as well, so a caller that forgets it still behaves.
    ///   - identity: the message id. Changing it throws the cursor away rather than continuing one
    ///     answer into another.
    ///   - content: draws one revealed prefix.
    init(
        text: String,
        isStreaming: Bool,
        motionOn: Bool,
        identity: String = "",
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.motionOn = motionOn
        self.identity = identity
        self.content = content
    }

    var body: some View {
        content(shown)
            .onAppear { reveal.resume(); apply() }
            .onChange(of: text) { _, _ in apply() }
            .onChange(of: isStreaming) { _, _ in apply() }
            .onChange(of: animates) { _, _ in apply() }
            .onChange(of: identity) { _, _ in
                reveal.reset()
                apply()
            }
            .onDisappear { reveal.pause() }
    }

    /// Both switches, one answer (`design-brief.md §3.3`).
    private var animates: Bool { motionOn && !reduceMotion }

    /// Reading `isRevealing` and `visible` on every pass is deliberate: they are the two observed
    /// properties of the driver, and the body has to depend on both or a later advance would not
    /// invalidate this view.
    private var shown: String {
        let live = reveal.visible
        let revealing = reveal.isRevealing
        guard animates else { return text }
        if revealing { return live }
        // Nothing is being paced: either the turn is over (`live` is the whole answer and equals
        // `text`), or it has not started (a settled message paints at once; a live one starts
        // empty rather than flashing its first chunk whole).
        return isStreaming ? live : text
    }

    private func apply() {
        reveal.present(text: text, isStreaming: isStreaming, animated: animates)
    }
}

// MARK: - The driver

/// The display cursor. Owns a `CADisplayLink` and two observed outputs; everything else is
/// deliberately outside observation so sixty callbacks a second stay one invalidation per painted
/// frame. Driven from the main run loop only — the link fires there, and `StreamingText` touches it
/// from `body`-adjacent callbacks. Not `@MainActor`, because SwiftUI has to build it inside a
/// `@State` initializer: the shape `OrbMotionState` and `CodeEditorLink` already use here.
@Observable
final class StreamReveal {

    /// The revealed prefix. Always ends on a grapheme-cluster boundary.
    private(set) var visible: String = ""

    /// True while the cursor is behind and pacing itself forward. The view uses it to decide
    /// whether it is looking at a paced prefix or at the plain text.
    private(set) var isRevealing: Bool = false

    // MARK: Cursor state

    /// The part of the answer that has arrived and has not been revealed yet. A `Substring` so the
    /// per-tick slice is O(the run revealed) instead of O(the answer). Both lengths below are in
    /// UTF-8 bytes and are tracked rather than measured, so no per-frame count walks the string.
    @ObservationIgnored private var pending: Substring = ""
    @ObservationIgnored private var pendingBytes: Int = 0
    @ObservationIgnored private var revealedBytes: Int = 0
    @ObservationIgnored private var trailingGraphemeBytes: Int = 0

    // MARK: Pacing state

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var ticker: StreamRevealTicker?
    @ObservationIgnored private var lastTickAt: CFTimeInterval = 0
    @ObservationIgnored private var lastArrivalAt: CFTimeInterval = 0
    /// Bytes per second the answer is arriving at, and seconds between arrivals — both smoothed.
    /// The cursor never runs slower than the first, which keeps it from draining the buffer and
    /// stalling; the second tells it whether it is being fed by a stream (~0.1 s) or a job (~2.5 s).
    @ObservationIgnored private var arrivalRate: Double = 0
    @ObservationIgnored private var arrivalInterval: Double = 0
    @ObservationIgnored private var isFinishing = false
    @ObservationIgnored private var finishDeadline: CFTimeInterval = 0
    @ObservationIgnored private var catchupDeadline: CFTimeInterval = 0
    @ObservationIgnored private var isPaused = false
    private let clock: () -> CFTimeInterval

    // MARK: Constants

    /// Seconds to close the gap, before any cadence has been measured, then its clamp.
    private static let defaultTau: Double = 0.16
    private static let minimumTau: Double = 0.10
    private static let maximumTau: Double = 0.24
    private static let catchupWindow: CFTimeInterval = 0.24
    /// Slowest and fastest the cursor may move, in UTF-8 bytes per second. The floor is about 40
    /// Arabic letters a second; the ceiling keeps a burst reading as writing, not teleporting.
    private static let minimumRate: Double = 80
    private static let maximumRate: Double = 64_000
    /// Past this much unrevealed text there is nothing to be gained by pacing: the reader has
    /// already missed it, and crawling through it is worse than showing it. Then the same
    /// judgement at the end of a turn.
    private static let snapGap: Int = 12_000
    private static let finishSnapGap: Int = 4_000
    /// A tick this far after the previous one means the link was asleep — backgrounded, or the row
    /// was off screen. Catch up in one step rather than replaying a backlog.
    private static let suspendedGap: CFTimeInterval = 0.5
    /// The window the last characters get once the turn is over.
    private static let finishWindow: CFTimeInterval = 0.16

    init(clock: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.clock = clock
    }

    // MARK: - Input

    /// The whole contract with the view: here is everything that has arrived, here is whether more
    /// is coming, here is whether we are allowed to animate at all.
    func present(text: String, isStreaming: Bool, animated: Bool) {
        guard animated, !isPaused else {
            snap(to: text)
            return
        }
        if !isStreaming {
            // A settled message this driver never streamed is drawn at once — only a turn that was
            // actually being paced gets a paced ending. So is a final text that is not what we have
            // been revealing: the store adopts the server's copy of an answer when it lands, and a
            // turn must never end by blanking and re-typing itself.
            if !isRevealing || !Self.utf8Prefix(text, matches: visible, bytes: revealedBytes) {
                snap(to: text)
                return
            }
        }
        if isStreaming {
            isFinishing = false
            finishDeadline = 0
            if !isRevealing { isRevealing = true }
        }
        push(text)
        if isStreaming {
            // Show the beginning on arrival, including after a thinking-only response. The final
            // grapheme is still held so a following harakah or emoji joiner stays intact.
            if visible.isEmpty { consume(bytes: min(24, availableBytes())) }
            if availableBytes() > 0 { start() } else { stop() }
        } else {
            finish()
        }
    }

    /// Throws the cursor away — a different message is about to use this driver.
    func reset() {
        stop()
        pending = ""
        pendingBytes = 0
        revealedBytes = 0
        trailingGraphemeBytes = 0
        isFinishing = false
        finishDeadline = 0
        catchupDeadline = 0
        arrivalRate = 0
        arrivalInterval = 0
        lastArrivalAt = 0
        if isRevealing { isRevealing = false }
        if !visible.isEmpty { visible = "" }
    }

    /// Offscreen rows catch up without running a display link. Reappearing never replays words
    /// that arrived while the reader was elsewhere in the conversation.
    func pause() {
        isPaused = true
        settle()
    }

    func resume() { isPaused = false }

    // MARK: - Target

    private func push(_ next: String) {
        guard !next.isEmpty else {
            pending = ""
            pendingBytes = 0
            revealedBytes = 0
            trailingGraphemeBytes = 0
            catchupDeadline = 0
            if !visible.isEmpty { visible = "" }
            return
        }

        // A retry replaces the partial answer instead of extending it. Never splice two attempts.
        if !Self.utf8Prefix(next, matches: visible, bytes: revealedBytes) {
            visible = ""
            revealedBytes = 0
            pendingBytes = 0
            pending = ""
            trailingGraphemeBytes = 0
            catchupDeadline = 0
        }

        let total = next.utf8.count
        let arrived = total - (revealedBytes + pendingBytes)
        if arrived > 0 {
            let now = clock()
            if catchupDeadline == 0 || availableBytes() == 0 {
                catchupDeadline = now + Self.catchupWindow
            }
            if lastArrivalAt > 0 {
                let dt = max(0.016, now - lastArrivalAt)
                let rate = Double(arrived) / dt
                arrivalRate = arrivalRate <= 0 ? rate : arrivalRate * 0.7 + rate * 0.3
                arrivalInterval = arrivalInterval <= 0 ? dt : arrivalInterval * 0.7 + dt * 0.3
            }
            lastArrivalAt = now
        }

        pendingBytes = max(0, total - revealedBytes)
        if pendingBytes > 0 {
            // Sliced from its own storage, so every later advance is O(the run revealed) rather
            // than O(the answer): `pending` keeps that storage alive and re-slices itself.
            let remainder = String(decoding: next.utf8.dropFirst(revealedBytes), as: UTF8.self)
            pending = remainder[remainder.startIndex...]
            trailingGraphemeBytes = pending.suffix(1).utf8.count
        } else {
            pending = ""
            trailingGraphemeBytes = 0
        }
    }

    private func finish() {
        if pendingBytes <= 0 {
            settle()
            return
        }
        if pendingBytes >= Self.finishSnapGap {
            settle()
            return
        }
        isFinishing = true
        finishDeadline = clock() + Self.finishWindow
        start()
    }

    /// Everything at once: Reduce Motion, a version switch, a message this driver never paced.
    private func snap(to text: String) {
        stop()
        pending = ""
        pendingBytes = 0
        trailingGraphemeBytes = 0
        isFinishing = false
        finishDeadline = 0
        catchupDeadline = 0
        revealedBytes = text.utf8.count
        if isRevealing { isRevealing = false }
        if visible != text { visible = text }
    }

    /// Puts the rest of the answer on screen and comes to rest.
    private func settle() {
        if pendingBytes > 0 {
            visible.append(contentsOf: pending)
            revealedBytes += pendingBytes
            pending = ""
            pendingBytes = 0
        }
        trailingGraphemeBytes = 0
        isFinishing = false
        finishDeadline = 0
        catchupDeadline = 0
        if isRevealing { isRevealing = false }
        stop()
    }

    // MARK: - The link

    private func start() {
        guard link == nil else { return }
        let target = StreamRevealTicker()
        target.owner = self
        let created = CADisplayLink(target: target, selector: #selector(StreamRevealTicker.tick(_:)))
        // No frame-rate hint: `minimumInterval` already decides how often a frame does any work, so
        // a 120 Hz link simply returns early on the frames in between.
        created.add(to: .main, forMode: .common)
        ticker = target
        link = created
        lastTickAt = clock()
    }

    private func stop() {
        link?.invalidate()
        link = nil
        ticker?.owner = nil
        ticker = nil
    }

    // MARK: - One frame

    fileprivate func step(at now: CFTimeInterval) {
        guard isRevealing else {
            stop()
            return
        }

        let elapsed = max(0, now - lastTickAt)
        let available = availableBytes()

        if available <= 0 {
            // No 60/120 Hz callbacks while waiting for the next network chunk. `present` restarts
            // the link when there is something to reveal, with a fresh clock and no banked credit.
            lastTickAt = now
            catchupDeadline = 0
            stop()
            if isFinishing, pendingBytes == 0 { settle() }
            return
        }

        if elapsed > Self.suspendedGap {
            lastTickAt = now
            consume(bytes: available)
            if isFinishing, pendingBytes == 0 { settle() }
            return
        }

        if !isFinishing, catchupDeadline > 0, now >= catchupDeadline {
            consume(bytes: available)
            return
        }

        // The repaint cap. Everything below runs at most this often, so the renderer's per-repaint
        // cost is what falls as the answer grows — not the reveal speed, which is preserved by
        // giving each tick a proportionally larger run.
        guard elapsed + 0.002 >= Self.minimumInterval(for: revealedBytes) else { return }
        lastTickAt = now

        if available >= Self.snapGap {
            consume(bytes: available)
            if isFinishing, pendingBytes == 0 { settle() }
            return
        }

        var rate = max(Double(available) / tau(), Self.minimumRate)
        if catchupDeadline > now {
            rate = max(rate, Double(available) / max(0.016, catchupDeadline - now))
        }
        if arrivalRate > 0 { rate = max(rate, arrivalRate * 1.15) }
        rate = min(rate, Self.maximumRate)
        if isFinishing {
            let left = max(0.05, finishDeadline - now)
            rate = max(rate, Double(available) / left)
        }

        var budget = Int((rate * elapsed).rounded())
        if budget < 1 { budget = 1 }
        consume(bytes: min(budget, available))

        if isFinishing, pendingBytes == 0 { settle() }
    }

    /// How far the cursor may go this frame. While text is still arriving the trailing grapheme is
    /// held back: a bare Arabic letter can still gain its harakah in the next chunk, and revealing
    /// it early is exactly the pop the owner is complaining about.
    private func availableBytes() -> Int {
        guard pendingBytes > 0 else { return 0 }
        if isFinishing { return pendingBytes }
        return max(0, pendingBytes - trailingGraphemeBytes)
    }

    /// Reveal by grapheme cluster, never by scalar and never by word: one cluster is one thing the
    /// reader sees, so nothing ever half-appears.
    private func consume(bytes budget: Int) {
        guard budget > 0, !pending.isEmpty else { return }
        var cursor = pending.startIndex
        var moved = 0
        while moved < budget, cursor < pending.endIndex {
            let next = pending.index(after: cursor)
            let width = pending[cursor..<next].utf8.count
            // At least one cluster always moves; after that, never overshoot the budget.
            if moved > 0, moved + width > budget { break }
            moved += width
            cursor = next
        }
        guard moved > 0 else { return }
        visible.append(contentsOf: pending[pending.startIndex..<cursor])
        pending = pending[cursor...]
        pendingBytes = max(0, pendingBytes - moved)
        revealedBytes += moved
        if availableBytes() == 0 {
            catchupDeadline = 0
            stop()
        }
    }

    /// How long the cursor should take to close the current gap, tuned to the cadence it is being
    /// fed at. Polling intervals must not add seconds of artificial delay to text that has already
    /// arrived; the short catch-up deadline bounds either delivery mode.
    private func tau() -> Double {
        guard arrivalInterval > 0 else { return Self.defaultTau }
        return min(Self.maximumTau, max(Self.minimumTau, arrivalInterval * 0.95))
    }

    /// The repaint cap, by how much is already on screen. Every repaint re-runs the block splitter
    /// over the revealed prefix, so this is the ceiling that keeps a 20 000-character answer cheap.
    private static func minimumInterval(for bytes: Int) -> CFTimeInterval {
        if bytes < 4_000 { return 1.0 / 60.0 }
        if bytes < 12_000 { return 1.0 / 30.0 }
        if bytes < 32_000 { return 1.0 / 20.0 }
        return 1.0 / 12.0
    }

    /// Does `next` still begin with what is already on screen? Compared as bytes, which is exact
    /// and needs no normalization pass over the whole answer.
    private static func utf8Prefix(_ next: String, matches visible: String, bytes: Int) -> Bool {
        guard bytes > 0 else { return true }
        guard next.utf8.count >= bytes else { return false }
        return next.utf8.prefix(bytes).elementsEqual(visible.utf8)
    }

    #if DEBUG
    var debugHasDisplayLink: Bool { link != nil }
    func debugAdvance(to time: CFTimeInterval) { step(at: time) }
    #endif
}

// MARK: - Display link target

/// `CADisplayLink` needs an Objective-C selector target, and it retains it. Keeping that one job in
/// its own object means the driver is not kept alive by the run loop: when the driver goes, the next
/// frame finds `owner` nil and tears the link down itself, so a scrolled-away row cannot leave a
/// timer burning for the rest of the session.
private final class StreamRevealTicker: NSObject {

    weak var owner: StreamReveal?

    @objc func tick(_ link: CADisplayLink) {
        // The driver is allowed to tear this link down from inside the call — settling does exactly
        // that — and invalidating a link releases its target. Hold this object for the duration
        // rather than trusting the run loop to.
        withExtendedLifetime(self) {
            guard let owner = self.owner else {
                link.invalidate()
                return
            }
            owner.step(at: link.timestamp)
        }
    }
}
