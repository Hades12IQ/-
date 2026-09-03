import Foundation

/// The Brain answer pipeline (`web-brain-ux.md §7`), off the main actor.
///
/// One `cid` per turn is shared by the whole-document read, every search and the answer stream, so
/// the server's Brain charge stays idempotent across the fallbacks (`server-brain.md §8`).
/// Order: whole-document read (members) → ranked search → bilingual retry → overview fallback →
/// grounded stream → citation renumbering → the `firas-sources` fence.
///
/// The stream is the cancellation handle: when the consumer's task is cancelled the
/// `AsyncStream` terminates and the work inside is cancelled with it, which is what Stop does.
final class BrainAsker: Sendable {

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    // MARK: - Turn and events

    struct Turn: Sendable {
        let question: String
        let outline: Bool
        let docIDs: [String]
        let range: ClosedRange<Int>?
        let compare: Bool
        let isMember: Bool
        let lang: AppLanguage
        let cid: String
        let history: [ChatMessage]

        init(
            question: String,
            outline: Bool,
            docIDs: [String],
            range: ClosedRange<Int>?,
            compare: Bool,
            isMember: Bool,
            lang: AppLanguage,
            cid: String,
            history: [ChatMessage]
        ) {
            self.question = question
            self.outline = outline
            self.docIDs = docIDs
            self.range = range
            self.compare = compare
            self.isMember = isMember
            self.lang = lang
            self.cid = cid
            self.history = history
        }
    }

    enum Event: Sendable {
        case pending(LText)
        case delta(String)
        case sources([BrainSource])
        case done(String)
        case failed(Error)
    }

    /// The fence that separates the two columns of a comparison. It never reaches Markdown:
    /// `BrainAnswerView` splits on it first (`web-brain-ux.md §7.7`).
    static let compareMarker = "```firas-cmp```"

    // MARK: - Entry

    func run(_ turn: Turn) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let work = Task {
                await self.execute(turn, continuation: continuation)
            }
            continuation.onTermination = { _ in
                work.cancel()
            }
        }
    }

    // MARK: - Pipeline

    private func execute(_ turn: Turn, continuation: AsyncStream<Event>.Continuation) async {
        let question = turn.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            continuation.finish()
            return
        }

        continuation.yield(.pending(Strings.Brain.thinking))

        do {
            if turn.compare && turn.docIDs.count == 2 {
                try await runCompare(question, turn: turn, continuation: continuation)
                continuation.finish()
                return
            }

            if turn.isMember, turn.docIDs.count == 1 {
                if let whole = try await runWholeRead(question, turn: turn, continuation: continuation) {
                    continuation.yield(.done(whole))
                    continuation.finish()
                    return
                }
            }

            try await runRetrieval(question, turn: turn, continuation: continuation)
        } catch is CancellationError {
            // The consumer pressed Stop; it keeps whatever text it already has.
        } catch {
            continuation.yield(.failed(error))
        }

        continuation.finish()
    }

    /// `POST /api/brain/whole` — members only, one active document. A 429 carrying a quota is a
    /// real refusal and is rethrown; every other failure is a decline and retrieval answers instead.
    private func runWholeRead(
        _ question: String,
        turn: Turn,
        continuation: AsyncStream<Event>.Continuation
    ) async throws -> String? {
        guard let docID = turn.docIDs.first else { return nil }
        continuation.yield(.pending(Strings.Brain.wholeReading))

        do {
            let request = BrainWholeRequest(
                docId: docID,
                question: question,
                cid: turn.cid,
                lang: turn.lang.rawValue,
                outline: turn.outline ? true : nil
            )
            let response = try await api.brainWhole(request)
            let answer = (response.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return answer.isEmpty ? nil : answer
        } catch let error as APIError {
            if error.status == 429, error.server?.quota != nil { throw error }
            if error.status == 401 { throw error }
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func runRetrieval(
        _ question: String,
        turn: Turn,
        continuation: AsyncStream<Event>.Continuation
    ) async throws {
        let quiz = !turn.outline && Self.isQuizQuery(question)
        let harvest = !turn.outline && !quiz && Self.isHarvestQuery(question)
        let overviewQuery = !quiz && !harvest && Self.isOverviewQuery(question)
        let reasoning = !overviewQuery && !quiz && !harvest && Self.isReasoningQuery(question)

        // A harvest ("list every definition") needs the whole corpus in front of the model, so it
        // takes the overview sample with the extraction rules (`web-brain-ux.md §7.2, §7.6`).
        let wantsOverview = turn.outline || quiz || overviewQuery || harvest
        var mode: BrainGroundingMode = turn.outline
            ? .outline
            : (quiz ? .quiz : (overviewQuery ? .overview : (reasoning ? .reason : .extract)))

        var response = try await search(
            question,
            turn: turn,
            resultCount: wantsOverview ? nil : (reasoning ? 12 : 8),
            mode: wantsOverview ? .overview : nil
        )
        var hits = response.hits
        let rangeEmpty = response.isRangeEmpty

        if !wantsOverview && !rangeEmpty && hits.count < 2 {
            continuation.yield(.pending(Strings.Brain.searching))
            if let keywords = await expandQuery(question, turn: turn), !keywords.isEmpty {
                response = try await search(
                    question + " " + keywords,
                    turn: turn,
                    resultCount: 8,
                    mode: nil
                )
                if response.hits.count > hits.count { hits = response.hits }
            }
        }

        if hits.isEmpty && !rangeEmpty {
            let fallback = try await search(question, turn: turn, resultCount: nil, mode: .overview)
            if !fallback.hits.isEmpty {
                hits = fallback.hits
                mode = turn.outline ? .outline : (quiz ? .quiz : .overview)
            }
        }

        guard !hits.isEmpty else {
            let text = rangeEmpty
                ? Strings.Brain.rangeEmpty.fmt(turn.lang, Self.rangeLabel(turn.range, lang: turn.lang))
                : Strings.Brain.noHits(turn.lang)
            continuation.yield(.done(text))
            return
        }

        let answer = try await streamAnswer(
            question,
            turn: turn,
            hits: hits,
            mode: mode,
            continuation: continuation
        )

        let renumbered = Self.renumberCitations(answer, hits: hits, lang: turn.lang)
        if !renumbered.sources.isEmpty {
            continuation.yield(.sources(renumbered.sources))
        }
        continuation.yield(.done(renumbered.text + Self.encodeSources(renumbered.sources)))
    }

    /// Two documents, one question, two columns, one merged source list (`web-brain-ux.md §7.7`).
    private func runCompare(
        _ question: String,
        turn: Turn,
        continuation: AsyncStream<Event>.Continuation
    ) async throws {
        var columns: [String] = []
        var merged: [BrainSource] = []

        for (index, docID) in turn.docIDs.prefix(2).enumerated() {
            continuation.yield(.pending(Self.progress(Strings.Brain.compareWorking, index + 1, 2)))

            let scoped = Turn(
                question: question,
                outline: false,
                docIDs: [docID],
                range: turn.range,
                compare: false,
                isMember: turn.isMember,
                lang: turn.lang,
                cid: turn.cid + "-" + String(index),
                history: []
            )

            let found = try await search(question, turn: scoped, resultCount: 8, mode: nil)
            var hits = found.hits
            if hits.isEmpty {
                let retry = try await search(question, turn: scoped, resultCount: nil, mode: .overview)
                hits = retry.hits
            }

            let title = hits.first?.title ?? ""
            var column = "### " + (title.isEmpty ? docID : title) + "\n\n"
            if index > 0 {
                continuation.yield(.delta("\n\n" + Self.compareMarker + "\n\n"))
            }
            continuation.yield(.delta(column))

            if hits.isEmpty {
                let empty = found.isRangeEmpty
                    ? Strings.Brain.rangeEmpty.fmt(turn.lang, Self.rangeLabel(turn.range, lang: turn.lang))
                    : Strings.Brain.noHits(turn.lang)
                column += empty
                continuation.yield(.delta(empty))
                columns.append(column)
                continue
            }

            let answer = try await streamAnswer(
                question,
                turn: scoped,
                hits: hits,
                mode: .extract,
                continuation: continuation
            )

            let renumbered = Self.renumberCitations(
                answer,
                hits: hits,
                lang: turn.lang,
                startingAt: merged.count + 1
            )
            merged.append(contentsOf: renumbered.sources)
            column += renumbered.text
            columns.append(column)
        }

        let body = columns.joined(separator: "\n\n" + Self.compareMarker + "\n\n")

        if !merged.isEmpty {
            continuation.yield(.sources(merged))
        }
        continuation.yield(.done(body + Self.encodeSources(merged)))
    }

    // MARK: - Server calls

    private func search(
        _ query: String,
        turn: Turn,
        resultCount: Int?,
        mode: BrainSearchMode?
    ) async throws -> BrainSearchResponse {
        try Task.checkCancellation()
        let request = BrainSearchRequest(
            query: query,
            resultCount: resultCount,
            documentIDs: turn.docIDs.isEmpty ? nil : turn.docIDs,
            cid: turn.cid,
            mode: mode,
            fromPage: turn.range?.lowerBound,
            toPage: turn.range?.upperBound,
            offset: nil,
            limit: nil
        )
        return try await api.brainSearch(request)
    }

    /// The grounded answer stream (`POST /api/chat`, `nomem:true`). Pieces are forwarded as they
    /// arrive so the reader sees the answer being written.
    private func streamAnswer(
        _ question: String,
        turn: Turn,
        hits: [BrainHit],
        mode: BrainGroundingMode,
        continuation: AsyncStream<Event>.Continuation
    ) async throws -> String {
        try Task.checkCancellation()

        let system = Self.groundingBlock(hits: hits, lang: turn.lang, mode: mode)
        var messages: [OutgoingMessage] = [OutgoingMessage(role: "system", content: system)]
        messages.append(contentsOf: Self.historyMessages(turn.history, question: question))

        let request = ChatStreamRequest(
            messages: messages,
            tier: ModelTier.pro.rawValue,
            think: false,
            cid: turn.cid,
            chatId: nil,
            product: ProductKind.brain.wireValue,
            nomem: true,
            nokb: true,
            agent: nil
        )

        var answer = ""
        let frames = await api.chatStream(request)
        for try await frame in frames {
            try Task.checkCancellation()
            guard let piece = Self.content(of: frame) else { continue }
            if piece.isEmpty { continue }
            answer += piece
            continuation.yield(.delta(piece))
        }
        return answer
    }

    /// The bilingual keyword expansion (`web-brain-ux.md §7.4`) — always tier `mini`, never fatal.
    private func expandQuery(_ question: String, turn: Turn) async -> String? {
        let system = OutgoingMessage(role: "system", content: Self.expansionSystemPrompt)
        let user = OutgoingMessage(role: "user", content: String(question.prefix(500)))
        let request = ChatStreamRequest(
            messages: [system, user],
            tier: ModelTier.mini.rawValue,
            think: false,
            cid: turn.cid + "-x",
            chatId: nil,
            product: ProductKind.brain.wireValue,
            nomem: true,
            nokb: true,
            agent: nil
        )

        var text = ""
        do {
            let frames = await api.chatStream(request)
            for try await frame in frames {
                guard let piece = Self.content(of: frame) else { continue }
                text += piece
            }
        } catch {
            return nil
        }

        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? nil : String(flattened.prefix(600))
    }

    private static let expansionSystemPrompt = "You expand a user's question into SEARCH KEYWORDS for a keyword-matching index. Output ONLY space-separated keywords and short phrases — no sentences, no punctuation, no explanation. Give them in BOTH Arabic and English regardless of the question's language, because the documents may be in either. Include obvious synonyms and the technical/domain term for each concept. Maximum 40 words total."

}
