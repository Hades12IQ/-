import Foundation
import Observation

/// Everything about ONE conversation that is true only right now.
///
/// The transcript itself lives in `ChatStore.conversations`; this object holds the volatile half —
/// which phase the turn is in, which job is carrying it, the text that has arrived but is not yet
/// part of a stored message, and the plan cycle. Keeping the two apart is what lets a growing
/// answer repaint ten times a second without touching the stored array (and therefore without
/// re-evaluating every row in the transcript).
///
/// One instance per conversation id, created lazily by `ChatStore.state(for:)` and never thrown
/// away while the app is running: leaving a screen must not lose the fact that a job is live.
@MainActor
@Observable
final class ConversationState {

    /// Where the current turn is. `failed` carries an already-localized sentence — the store never
    /// puts a server sentence on screen.
    enum Phase: Equatable {
        case idle
        case searching
        case thinking
        case streaming
        case completing
        case failed(String)
    }

    let conversationID: String

    var phase: Phase = .idle
    /// The live job's id (`JobPointer.id`), when this turn is riding the durable queue.
    var jobPointerID: String?
    /// Plan mode for this conversation only — derived on open, mutated per turn.
    var plan: PlanCycle = .idle

    /// The answer as it is arriving. Published at most ten times a second by `StreamBuffer`.
    var liveText: String = ""
    var liveReasoning: String = ""

    /// A localized one-line failure shown above the composer; cleared on the next send.
    var errorStrip: String?

    /// Written by the transcript: true while the reader is pinned to the bottom. Autoscroll is
    /// allowed only then — a reader who scrolled up must not be yanked back by every tick.
    var isAtBottom: Bool = true

    /// Text the user selected and chose to quote in the next message.
    var pendingQuote: String?

    /// The assistant row `liveText` belongs to. Only that row re-renders while streaming, so the
    /// transcript reads it — it must stay observed.
    var streamingMessageID: String?

    /// The long-file worker's own progress for the turn in flight (`kind: "longfile"`).
    ///
    /// The snapshot has always carried it and the transcript has never seen it, which is why a
    /// document that takes minutes to write showed nothing at all while it was being written. The
    /// transcript reads this and hands it to the streaming row, so it must stay observed.
    var longFileProgress: LongFileProgress?

    // MARK: - Turn bookkeeping (additive; never read by views)

    /// The turn id currently in flight, so a late delivery for an older turn is ignored.
    @ObservationIgnored var activeCID: String?

    /// Set between the user tapping Stop and the turn settling, so a terminal that arrives in
    /// between is landed as "stopped" rather than as an answer.
    @ObservationIgnored var isStopping: Bool = false

    /// The user message the in-flight turn answers. A single automatic retry (engine-failure
    /// sentence or empty stream, `server-chat-jobs-chats.md §1.8`) re-runs from here.
    @ObservationIgnored var autoRetryUsedForMessageID: String?

    /// The full-resolution images of the most recent user turn, kept in memory only so a follow-up
    /// that refers to the picture can be re-attached. They are never persisted and never written
    /// into a stored message.
    @ObservationIgnored var lastTurnImages: [String] = []

    init(conversationID: String) {
        self.conversationID = conversationID
    }

    /// True while the user is waiting for something. The composer shows Stop, and a second send is
    /// refused for this conversation only — never app-wide.
    var isBusy: Bool {
        switch phase {
        case .searching, .thinking, .streaming, .completing:
            return true
        case .idle, .failed:
            return false
        }
    }

    /// Back to rest, keeping the plan cycle (a cycle survives a failed turn).
    func settle() {
        phase = .idle
        jobPointerID = nil
        liveText = ""
        liveReasoning = ""
        longFileProgress = nil
        streamingMessageID = nil
        activeCID = nil
        isStopping = false
    }

    func fail(_ message: String) {
        phase = .failed(message)
        errorStrip = message
        jobPointerID = nil
        liveText = ""
        liveReasoning = ""
        longFileProgress = nil
        streamingMessageID = nil
        activeCID = nil
        isStopping = false
    }
}
