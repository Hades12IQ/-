#if DEBUG
import Foundation
import QuartzCore

/// Real buffer/reveal fixtures used by the simulator smoke route. Timing is reported, not used as
/// a flaky pass/fail threshold; the work and latency limits below are deterministic.
@MainActor
enum StreamPerformanceChecks {
    struct Result {
        var failures: [String]
        var metrics: [String: Double]
    }

    static func run() -> Result {
        var failures: [String] = []
        var metrics: [String: Double] = [:]
        let state = ConversationState(conversationID: "stream-performance-fixture")
        let buffer = StreamBuffer(state: state)

        buffer.append(content: "", reasoning: "تفكير")
        buffer.append(content: "الجواب", reasoning: "")
        if state.liveText != "الجواب" {
            failures.append("first-answer-waits-behind-thinking-coalescer")
        }
        buffer.finish()
        buffer.reset()

        // Include split tags, combining marks and a joined emoji across snapshot boundaries.
        let source = "<think>مراجعة المسألة</think>" + String(repeating:
            "السؤال سَ والنتيجة 👨‍👩‍👧‍👦. Equation: $E=mc^2$.\n", count: 600)
            + "<think>تحقق أخير</think>انتهى."
        var snapshots: [String] = []
        var end = source.startIndex
        while end < source.endIndex {
            end = source.index(end, offsetBy: 113, limitedBy: source.endIndex) ?? source.endIndex
            snapshots.append(String(source[..<end]))
        }
        var baselineChecksum = 0
        let baselineStart = CACurrentMediaTime()
        for snapshot in snapshots {
            let split = StreamBuffer.splitThink(snapshot)
            baselineChecksum += split.text.utf8.count + split.reasoning.utf8.count
        }
        metrics["fullSnapshotSplitMilliseconds"] = (CACurrentMediaTime() - baselineStart) * 1_000
        metrics["fullSnapshotSplitChecksum"] = Double(baselineChecksum)
        let incrementalStart = CACurrentMediaTime()
        for snapshot in snapshots { buffer.adopt(text: snapshot, reasoning: "") }
        metrics["incrementalSnapshotMilliseconds"] = (CACurrentMediaTime() - incrementalStart) * 1_000
        metrics["snapshotCount"] = Double(snapshots.count)
        metrics["snapshotBytesWithoutIncremental"] = Double(snapshots.reduce(0) { $0 + $1.utf8.count })
        metrics["incrementalSnapshotScannedBytes"] = Double(buffer.debugIngestedBytes)
        if buffer.debugIngestedBytes != source.utf8.count {
            failures.append("extending-snapshots-rescan-old-answer")
        }
        let scansBeforeRepeat = buffer.debugIngestedBytes
        let publishesBeforeRepeat = buffer.debugPublishCount
        for _ in 0..<200 { buffer.adopt(text: source, reasoning: "") }
        if scansBeforeRepeat != buffer.debugIngestedBytes || publishesBeforeRepeat != buffer.debugPublishCount {
            failures.append("unchanged-snapshots-do-extra-work")
        }
        buffer.adopt(text: "stale", reasoning: "")
        let complete = buffer.finish()
        let expected = StreamBuffer.splitThink(source)
        if complete.text != expected.text || complete.reasoning != expected.reasoning {
            failures.append("snapshot-suffix-duplicates-or-loses-content")
        }

        buffer.reset()
        let fragments = ["<th", "ink>س", "َ", "</thi", "nk>", "الجواب 👨", "‍👩‍👧‍👦", "!", "<th"]
        for fragment in fragments {
            buffer.append(content: fragment, reasoning: "")
            if buffer.text.contains("<") { failures.append("partial-think-tag-leaked") }
        }
        let fragmented = buffer.finish()
        if fragmented.text != "الجواب 👨‍👩‍👧‍👦!<th" || fragmented.reasoning != "سَ" {
            failures.append("fragmented-tags-or-final-carry-lost")
        }
        buffer.reset()
        buffer.adopt(text: "first", reasoning: "")
        buffer.adopt(text: "replacement answer", reasoning: "")
        if buffer.finish().text != "replacement answer" { failures.append("replacement-snapshot-spliced") }

        var now: CFTimeInterval = 100
        let reveal = StreamReveal(clock: { now })
        reveal.present(text: "س", isStreaming: true, animated: true)
        reveal.present(text: "سَ", isStreaming: true, animated: true)
        if !reveal.visible.isEmpty || reveal.debugHasDisplayLink || !reveal.debugHasTrailingTimer {
            failures.append("held-grapheme-revealed-or-idle-link-running")
        }
        reveal.present(text: "سَ🙂", isStreaming: true, animated: true)
        if reveal.visible != "سَ" || reveal.debugHasDisplayLink {
            failures.append("first-grapheme-waits-or-idle-link-running")
        }
        reveal.present(text: "سَ🙂", isStreaming: false, animated: true)
        now += 0.20
        reveal.debugAdvance(to: now)
        if reveal.visible != "سَ🙂" || reveal.debugHasDisplayLink || reveal.debugHasTrailingTimer {
            failures.append("completion-drops-held-grapheme")
        }

        reveal.reset()
        let tailArrival = now
        let command = #"x + \theta"#
        reveal.present(text: command, isStreaming: true, animated: true)
        if reveal.visible != String(command.dropLast()) { failures.append("control-word-tail-not-initially-held") }
        now = tailArrival + 0.08
        reveal.present(text: command, isStreaming: true, animated: true)
        now = tailArrival + 0.119
        reveal.debugAdvance(to: now)
        if reveal.visible == command { failures.append("tail-released-before-joining-window") }
        now = tailArrival + 0.121
        reveal.debugAdvance(to: now)
        if reveal.visible != command || !reveal.isRevealing || reveal.debugHasDisplayLink || reveal.debugHasTrailingTimer {
            failures.append("idle-control-word-waits-for-next-arrival-or-completion")
        }
        metrics["idleControlWordVisibleMilliseconds"] = (now - tailArrival) * 1_000

        // The exact source that failed while mounted: growing a live formula must expose theta
        // while the response is still streaming, even if no closing dollar has arrived yet.
        reveal.reset()
        let formula = #"الحل $z^{17}$ ثم $\frac{47}{83} + \theta"#
        let formulaArrival = now
        reveal.present(text: formula, isStreaming: true, animated: true)
        now = formulaArrival + 0.25
        reveal.debugAdvance(to: now)
        let displayedSpans = MathScanner.spans(in: MathScanner.streamingPreview(reveal.visible))
        let expectedSpans = MathScanner.spans(in: MathScanner.streamingPreview(formula))
        if reveal.visible != formula || displayedSpans.map(\.id) != expectedSpans.map(\.id) || expectedSpans.count != 2 {
            failures.append("idle-reveal-loses-growing-formula-control-word")
        }

        // A close-spaced chunk still extends the held cluster without publishing a bare base.
        reveal.reset()
        let clusterArrival = now
        reveal.present(text: "س", isStreaming: true, animated: true)
        now = clusterArrival + 0.09
        reveal.present(text: "سَ", isStreaming: true, animated: true)
        now = clusterArrival + 0.13
        reveal.debugAdvance(to: now)
        if !reveal.visible.isEmpty { failures.append("new-harakah-did-not-rearm-idle-window") }
        now = clusterArrival + 0.211
        reveal.debugAdvance(to: now)
        if reveal.visible != "سَ" { failures.append("complete-arabic-cluster-never-released") }
        reveal.present(text: "سَ\u{0651}🙂", isStreaming: true, animated: true)
        if reveal.visible != "سَ\u{0651}" { failures.append("late-harakah-did-not-join-visible-cluster-atomically") }

        reveal.reset()
        let emojiArrival = now
        reveal.present(text: "👩", isStreaming: true, animated: true)
        now = emojiArrival + 0.121
        reveal.debugAdvance(to: now)
        reveal.present(text: "👩‍💻!", isStreaming: true, animated: true)
        if reveal.visible != "👩‍💻" { failures.append("late-emoji-joiner-was-sliced-from-its-visible-base") }
        reveal.reset()
        now += 0.2
        reveal.debugAdvance(to: now)
        if !reveal.visible.isEmpty || reveal.debugHasTrailingTimer || reveal.debugHasDisplayLink {
            failures.append("reset-retains-old-tail-work")
        }

        reveal.reset()
        let burst = String(repeating: "شرح عربي واضح. ", count: 300)
        let arrival = now
        reveal.present(text: burst, isStreaming: true, animated: true)
        if reveal.visible.isEmpty { failures.append("first-content-waits-for-display-tick") }
        for tick in 1...16 {
            now = arrival + Double(tick) / 60
            reveal.debugAdvance(to: now)
            if reveal.visible == burst {
                metrics["burstVisibleMilliseconds"] = (now - arrival) * 1_000
                break
            }
        }
        if reveal.visible != burst || reveal.debugHasDisplayLink || reveal.debugHasTrailingTimer {
            failures.append("received-burst-still-lagging-after-quarter-second")
        }
        reveal.pause()
        let offscreen = burst + "نص وصل أثناء التمرير."
        reveal.present(text: offscreen, isStreaming: true, animated: true)
        if reveal.visible != offscreen || reveal.debugHasDisplayLink || reveal.debugHasTrailingTimer {
            failures.append("offscreen-row-keeps-revealing")
        }
        reveal.resume()
        reveal.present(text: offscreen, isStreaming: true, animated: false)
        if reveal.visible != offscreen || reveal.debugHasDisplayLink || reveal.debugHasTrailingTimer {
            failures.append("reduce-motion-runs-reveal")
        }
        reveal.reset()
        return Result(failures: failures, metrics: metrics)
    }
}
#endif
