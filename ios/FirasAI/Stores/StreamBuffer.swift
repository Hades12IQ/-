import Foundation
import QuartzCore

/// The coalescer between an arriving answer and the screen — the **data** half of the streaming
/// feel. The pacing half is `Rendering/StreamingText.swift`, which walks a display cursor towards
/// whatever this object has already received.
///
/// Two sources feed it and they behave differently: the live SSE stream delivers *deltas* to be
/// appended, while a job poll delivers the whole answer *so far* — a snapshot that must replace
/// what we hold, and that must never shorten it (an older, slower read overtaking a newer one is
/// how a half-written answer suddenly loses its tail).
///
/// Updates are coalesced into `ConversationState` at ten times a second, with the first visible
/// answer published immediately even if thinking just published. That ceiling is
/// the fix for `audit-ios-chat.md §Critical C5`: the server writes its snapshot every 2.5 s and the
/// stream can deliver hundreds of frames a second, and repainting a 50 000-character `Text` on
/// every one of them is what made the app read as frozen. The ceiling is not what the reader sees —
/// `StreamingText` interpolates between these publishes, so ten targets a second still read as
/// continuous typing.
///
/// It also owns the one transform the wire needs: some engines put their thinking inside
/// `<think>…</think>` in `content` instead of in `reasoning` (`server-chat-jobs-chats.md §1.7`), so
/// the split happens here, once, rather than in every renderer.
///
/// That split used to run over the **whole** answer every time anything read `text` — and
/// `SendPipeline` reads `text` once per SSE frame to decide `.thinking` vs `.streaming`, which made
/// a long answer quadratic in the number of frames. It is now incremental: each delta is fed
/// through a small state machine that knows whether it is inside a `<think>` block, so appending
/// costs the length of the delta and reading costs nothing. An extending job snapshot feeds only
/// its new suffix through that same machine; a replacement snapshot rebuilds it.
@MainActor
final class StreamBuffer {

    /// The publish ceiling: 10 Hz.
    private static let interval: TimeInterval = 0.1

    /// The two tags the incremental splitter looks for. Held as constants so the "is this tail the
    /// beginning of a tag?" test cannot drift from the tags themselves.
    private static let openTag = "<think>"
    private static let closeTag = "</think>"
    private static let openTagBytes = Array(openTag.utf8)
    private static let closeTagBytes = Array(closeTag.utf8)

    private weak var state: ConversationState?

    /// The raw answer as it arrived, before the `<think>` split. Kept because a job snapshot is
    /// compared against it, and because `receivedCount` is defined on it.
    private var rawText: String = ""
    private var rawReasoning: String = ""

    // MARK: Incremental think-tag split

    /// The answer with every `<think>` block removed — grown delta by delta.
    private var splitText: String = ""
    /// The thinking found inside `content`, in arrival order.
    private var splitReasoning: String = ""
    /// True while an opening tag has been seen and its closer has not.
    private var thinkOpen = false
    /// A tail that is a proper prefix of the tag we are looking for next (`<thi`, `</think`, …).
    /// It is held back rather than painted, so a tag never flashes as answer text while its
    /// remaining characters are still on the wire. `finish()` flushes it — nothing is ever lost.
    private var carry: String = ""

    private var publishTask: Task<Void, Never>?
    private var lastPublish: CFTimeInterval = -.infinity

    #if DEBUG
    /// Work counters for the simulator fixture; never contain the answer itself.
    private(set) var debugIngestedBytes = 0
    private(set) var debugPublishCount = 0
    #endif

    init(state: ConversationState) {
        self.state = state
    }

    // MARK: - Reading

    /// The answer text with any inline thinking removed. O(1): the split is maintained as the text
    /// arrives, not recomputed on read.
    var text: String { splitText }

    /// Everything the model called thinking, from either channel.
    var reasoning: String { mergedReasoning() }

    var isEmpty: Bool { rawText.isEmpty && rawReasoning.isEmpty }

    /// True as soon as one visible character of the answer exists. The cheap form of
    /// `!text.isEmpty` for the per-frame phase decision in `SendPipeline`.
    var hasText: Bool { !splitText.isEmpty }

    /// How much text has been received, in characters — the comparison a watcher uses to decide
    /// whether a snapshot is newer than what we already hold.
    var receivedCount: Int { rawText.count }

    /// The same measure in UTF-8 bytes, which is O(1) and therefore safe to read per frame.
    var receivedBytes: Int { rawText.utf8.count }

    // MARK: - Writing

    func reset() {
        publishTask?.cancel()
        publishTask = nil
        rawText = ""
        rawReasoning = ""
        splitText = ""
        splitReasoning = ""
        thinkOpen = false
        carry = ""
        lastPublish = -.infinity
        #if DEBUG
        debugIngestedBytes = 0
        debugPublishCount = 0
        #endif
        state?.liveText = ""
        state?.liveReasoning = ""
    }

    /// A live SSE delta.
    func append(content: String, reasoning: String) {
        guard !content.isEmpty || !reasoning.isEmpty else { return }
        if !content.isEmpty {
            rawText += content
            ingest(content)
        }
        if !reasoning.isEmpty {
            rawReasoning += reasoning
        }
        schedulePublish()
    }

    /// A job snapshot: the whole answer so far. Shorter than what we hold means the read is stale,
    /// and a stale read is dropped rather than painted.
    func adopt(text: String, reasoning: String) {
        var changed = false
        let previousBytes = rawText.utf8.count
        if text.utf8.count > previousBytes {
            let extends = text.utf8.starts(with: rawText.utf8)
            rawText = text
            if extends {
                // The previous string ends on a UTF-8 scalar boundary, even when the new suffix
                // adds a combining mark to its final grapheme. Decode only that valid suffix.
                ingest(String(decoding: text.utf8.dropFirst(previousBytes), as: UTF8.self))
            } else {
                rebuildSplit(from: text)
            }
            changed = true
        }
        if reasoning.utf8.count > rawReasoning.utf8.count {
            rawReasoning = reasoning
            changed = true
        }
        guard changed else { return }
        schedulePublish()
    }

    /// Flushes whatever is pending and answers with the final pair. The caller writes these into
    /// the stored message; nothing else may.
    ///
    /// The held-back tag fragment is released here, which is why a turn that ends mid-tag keeps its
    /// last characters instead of dropping them.
    @discardableResult
    func finish() -> (text: String, reasoning: String) {
        publishTask?.cancel()
        publishTask = nil
        flushCarry()
        let thinking = mergedReasoning()
        state?.liveText = splitText
        state?.liveReasoning = thinking
        lastPublish = CACurrentMediaTime()
        return (splitText, thinking)
    }

    // MARK: - Publishing

    private func schedulePublish() {
        let elapsed = CACurrentMediaTime() - lastPublish
        let firstAnswer = !splitText.isEmpty && state?.liveText.isEmpty == true
        if firstAnswer || elapsed >= Self.interval {
            publish()
            return
        }
        guard publishTask == nil else { return }
        let wait = Self.interval - elapsed
        publishTask = Task { [weak self] in
            await JobClock.rest(wait)
            guard let self, !Task.isCancelled else { return }
            self.publishTask = nil
            self.publish()
        }
    }

    private func publish() {
        // A first-answer publish can overtake a queued thinking update. Do not leave that older
        // timer alive to publish again a few milliseconds later.
        publishTask?.cancel()
        publishTask = nil
        lastPublish = CACurrentMediaTime()
        guard let state else { return }
        #if DEBUG
        debugPublishCount += 1
        #endif
        if state.liveText != splitText { state.liveText = splitText }
        let thinking = mergedReasoning()
        if state.liveReasoning != thinking { state.liveReasoning = thinking }
    }

    private func mergedReasoning() -> String {
        if splitReasoning.isEmpty { return rawReasoning }
        if rawReasoning.isEmpty { return splitReasoning }
        return rawReasoning + splitReasoning
    }

    // MARK: - The incremental splitter

    /// Feeds one delta through the think-tag state machine. Costs the length of the delta plus the
    /// few characters held over from the previous one.
    private func ingest(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        #if DEBUG
        debugIngestedBytes += chunk.utf8.count
        #endif
        var work = carry + chunk
        carry = ""

        while true {
            let marker = thinkOpen ? Self.closeTag : Self.openTag
            guard let found = work.range(of: marker) else { break }
            let head = String(work[work.startIndex..<found.lowerBound])
            if thinkOpen {
                splitReasoning += head
            } else {
                splitText += head
            }
            thinkOpen.toggle()
            work = String(work[found.upperBound...])
        }

        let hold = Self.partialTagLength(in: work, expectingClose: thinkOpen)
        if hold > 0 {
            let cut = work.index(work.endIndex, offsetBy: -hold)
            carry = String(work[cut...])
            work = String(work[work.startIndex..<cut])
        }

        guard !work.isEmpty else { return }
        if thinkOpen {
            splitReasoning += work
        } else {
            splitText += work
        }
    }

    /// A replacement snapshot restarts the machine. Ordinary extending snapshots never come here.
    private func rebuildSplit(from raw: String) {
        splitText = ""
        splitReasoning = ""
        thinkOpen = false
        carry = ""
        ingest(raw)
    }

    private func flushCarry() {
        guard !carry.isEmpty else { return }
        if thinkOpen {
            splitReasoning += carry
        } else {
            splitText += carry
        }
        carry = ""
    }

    /// How many trailing characters of `work` are the beginning of the tag we are waiting for.
    /// Zero when the tail cannot possibly grow into one, which is the overwhelmingly common case.
    private static func partialTagLength(in work: String, expectingClose: Bool) -> Int {
        guard !work.isEmpty else { return 0 }
        let marker = expectingClose ? closeTagBytes : openTagBytes
        // Both markers are ASCII. Inspect at most seven bytes, never count every grapheme in a
        // large paragraph merely to decide whether its very last characters begin a tag.
        let tail = Array(work.utf8.suffix(marker.count - 1))
        var length = tail.count
        while length > 0 {
            if tail.suffix(length).elementsEqual(marker.prefix(length)) { return length }
            length -= 1
        }
        return 0
    }

    // MARK: - Wire helpers

    /// One `data:` payload of `POST /api/chat` → its two deltas.
    ///
    /// The frame shape is `{"choices":[{"delta":{"content":"…","reasoning":"…"}}]}`; both keys may
    /// appear in one frame. `[DONE]` and anything malformed answer `nil` — the contract says the
    /// client must tolerate broken JSON rather than end the turn on it.
    nonisolated static func delta(fromData data: String) -> (content: String, reasoning: String)? {
        let payload = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let bytes = payload.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else { return nil }
        guard let delta = first["delta"] as? [String: Any] else { return nil }
        let content = (delta["content"] as? String) ?? ""
        let reasoning = (delta["reasoning"] as? String) ?? ""
        if content.isEmpty && reasoning.isEmpty { return nil }
        return (content, reasoning)
    }

    /// Pulls every `<think>…</think>` block out of a finished answer, in one pass.
    ///
    /// The live path no longer calls this — it keeps the same split incrementally — but a caller
    /// holding a whole stored answer still needs the one-shot form, and both must agree: an
    /// unterminated opening tag means the model is still thinking, so everything after it is
    /// reasoning until the closing tag arrives.
    /// The tags are spelled out rather than read from the constants above: this method is
    /// `nonisolated` and those constants belong to the main actor.
    nonisolated static func splitThink(_ raw: String) -> (text: String, reasoning: String) {
        guard raw.contains("<think>") else { return (raw, "") }
        var text = ""
        var reasoning = ""
        var rest = Substring(raw)
        var scanning = true
        while scanning, let start = rest.range(of: "<think>") {
            text += String(rest[rest.startIndex..<start.lowerBound])
            let after = rest[start.upperBound...]
            if let end = after.range(of: "</think>") {
                reasoning += String(after[after.startIndex..<end.lowerBound])
                rest = after[end.upperBound...]
            } else {
                reasoning += String(after)
                scanning = false
                rest = Substring("")
            }
        }
        text += String(rest)
        return (text, reasoning)
    }
}
