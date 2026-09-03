//
//  PlanCycle.swift
//  FirasAI
//
//  Plan mode as a state machine that belongs to ONE conversation — the native design in
//  web-plan-mode.md §7, not the web's behaviour.
//
//  The web reads a device-global toggle at reply time (`state.mode`), so switching to Auto
//  between the plan and the approval silently removes the plan instructions from the execute
//  request (§6 D7); the plan instructions are sent on every turn forever, so a follow-up after
//  delivery is answered with fresh questions (D12); and a finished Agent or Code deliverable gets
//  an "ابدأ التنفيذ" pill because the row was stamped `mode:"plan"` (D14).
//
//  Here the mode is SNAPSHOTTED onto the cycle when it starts, the cycle ends at `delivered`, and
//  every entry point takes the product so nothing outside the `ai` chat is ever evaluated.
//
//  Round-2 rule from the owner's own report — «ما تطلعلي الخيارات… حط ستارت تحته»: the Start pill
//  must NEVER stand in for the questions. A reply that carries a `firas-ask` fence is an ASK turn
//  even when the JSON inside it did not parse, so the phase becomes `awaitingAnswers` (no pill,
//  and `AssistantTurnView` is told to retry the tolerant parse) instead of `awaitingApproval`.
//  A reply with nothing in it is not a plan either, and leaves the phase where it was.
//

import Foundation

/// Which system text this turn gets (web-plan-mode.md §7.3).
enum PlanTurnKind: Sendable, Equatable {
    /// Ordinary Auto turn: build rules in, no plan instructions.
    case auto
    /// STEP 1 / STEP 2: base WITHOUT build rules + planSystem.
    case clarifyOrPlan
    /// STEP 3: base WITH build rules + planSystem + the EXECUTE note; routing resolves the
    /// deliverable from the ORIGIN request, never from the approval sentence.
    case execute(originID: String)
    /// The user answered the plan with a change instead of an approval.
    case revision
    /// Two ask rounds have happened; stop asking and produce the plan.
    case forcedPlan
}

enum PlanPhase: Equatable, Sendable, Codable {
    case none
    case awaitingAnswers(askMessageID: String)
    case awaitingApproval(planMessageID: String)
    case executing(originID: String)
    case delivered(originID: String)
}

struct PlanCycle: Sendable, Equatable, Codable {

    var phase: PlanPhase = .none
    /// The device mode captured when this cycle started. It, not the live toggle, decides the
    /// rest of the cycle.
    var snapshotMode: ResponseMode = .auto
    /// How many times the model has already answered with a `firas-ask` block in this cycle.
    /// Counted in ONE place — `assistantFinished` — so a live cycle and a cycle rebuilt by
    /// `derive` always agree, and the third round is forced to produce the plan (§7.3c).
    var askRounds: Int = 0
    /// The user message that started the cycle — the actual request, not the approval.
    var originID: String? = nil
    /// Set while a voice call is in progress; the phase is restored on hang-up.
    var pausedPhase: PlanPhase? = nil

    static let idle = PlanCycle()

    /// The Start pill lives under a finished plan and nowhere else.
    var showsStartPill: Bool {
        if case .awaitingApproval = phase { return true }
        return false
    }

    /// A cycle that has been started but whose first reply has not landed yet. `PlanPhase` has no
    /// in-flight case, so `startCycle` leaves `phase == .none`; without this, a second send in the
    /// same breath would look like a brand-new request and reset `originID` — the very thing that
    /// makes the web execute a plan against the approval sentence instead of the request (D4/D5).
    var isArmed: Bool {
        guard snapshotMode == .plan, pausedPhase == nil else { return false }
        if case .none = phase { return originID != nil }
        return true
    }

    // MARK: - Transitions (web-plan-mode.md §7.2)

    /// Called with the user turn about to be sent. Mutates the phase and answers with the system
    /// text this turn needs.
    mutating func userSent(_ m: ChatMessage, liveMode: ResponseMode, product: ProductKind) -> PlanTurnKind {
        // Plan mode is a feature of the `ai` chat product only (D14).
        guard product == .ai else {
            self = PlanCycle.idle
            return .auto
        }
        // §7.2: a call forces Auto for its duration; the cycle is parked, not cancelled, and
        // `resumeAfterCall` puts the pill (or the panel) back exactly where it was.
        guard pausedPhase == nil else { return .auto }

        switch phase {
        case .none:
            // The reply to the opening turn never arrived (a stop, a failure, a relaunch). Keep the
            // cycle rather than starting a second one on top of it.
            if isArmed { return askRounds >= 2 ? .forcedPlan : .clarifyOrPlan }
            return startOrStayAuto(m, liveMode: liveMode)

        case .delivered:
            // A follow-up after delivery is an Auto turn. Only a genuinely new deliverable
            // re-arms the cycle (D12); the classifier's verdict rides on the message.
            let intent = m.intent ?? ""
            let isNewDeliverable = !intent.isEmpty && intent != "chat" && intent != "unavailable"
            if liveMode == .plan && isNewDeliverable {
                return startCycle(m)
            }
            endCycle()
            return .auto

        case .awaitingAnswers:
            // Submit, or the user typing the answer instead of tapping — same turn either way.
            // `askRounds` was already raised by the ask reply itself.
            return askRounds >= 2 ? .forcedPlan : .clarifyOrPlan

        case .awaitingApproval:
            if ApprovalMatcher.isApproval(m.content) {
                let origin = originID ?? m.id
                originID = origin
                phase = .executing(originID: origin)
                return .execute(originID: origin)
            }
            return .revision

        case .executing:
            // A message sent while the deliverable is still streaming is a revision of it.
            return .revision
        }
    }

    /// Called once the assistant turn has finished streaming. `ask` is `AskSpec.parse` of its
    /// content (`nil` when there is no parseable ask block).
    mutating func assistantFinished(_ m: ChatMessage, ask: AskSpec?) {
        guard m.role == .assistant else { return }
        // Parked for a call: whatever lands now belongs to the call's Auto turn, and touching the
        // phase here would be undone by `resumeAfterCall` anyway.
        guard pausedPhase == nil else { return }

        if case .executing(let origin) = phase {
            phase = .delivered(originID: origin)
            return
        }
        guard snapshotMode == .plan else {
            endCycle()
            return
        }

        let body = m.visibleContent
        // An empty answer (stopped, failed, or a placeholder that never filled) is not a plan.
        // Offering "ابدأ التنفيذ" under nothing is exactly the pill the owner reported.
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if ask != nil || AskSpec.hasAskFence(body) {
            askRounds += 1
            phase = .awaitingAnswers(askMessageID: m.id)
            return
        }
        phase = .awaitingApproval(planMessageID: m.id)
    }

    /// A call replaces the whole prompt with the voice system text, so the cycle steps aside and
    /// comes back afterwards. Both calls are idempotent.
    mutating func pauseForCall() {
        guard pausedPhase == nil else { return }
        if case .none = phase { return }
        pausedPhase = phase
        phase = .none
    }

    mutating func resumeAfterCall() {
        guard let resumed = pausedPhase else { return }
        phase = resumed
        pausedPhase = nil
    }

    // MARK: - Deriving the phase on load (web-plan-mode.md §7.5)

    /// A chat written on the web, or recovered after a durable job, has no phase of its own: the
    /// worker's `saveAssistantTurn` stores only `{role, content, reasoning, tier, lang, cid}` and
    /// drops `mode` (D6). Rebuild the phase from the rows plus the conversation's snapshot.
    static func derive(from messages: [ChatMessage], snapshot: ResponseMode?) -> PlanCycle {
        var cycle = PlanCycle.idle
        cycle.snapshotMode = snapshot ?? .auto

        guard let lastIndex = messages.lastIndex(where: { row in
            row.role == .assistant && !row.visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            // Nothing has been answered yet: no phase to restore, and no origin to keep — an
            // `originID` without a phase would arm a cycle that does not exist.
            cycle.originID = nil
            return cycle
        }
        let last = messages[lastIndex]
        let body = last.visibleContent
        let start = cycleStart(in: messages, before: lastIndex)

        // 1. An ask panel nobody has answered — including one whose JSON never parsed, which must
        //    not fall through to a Start pill.
        if last.askAnswered != true, AskSpec.parse(body) != nil || AskSpec.hasAskFence(body) {
            cycle.snapshotMode = .plan
            cycle.originID = origin(in: messages, from: start, to: lastIndex)
            cycle.askRounds = askRoundCount(in: messages, from: start, to: lastIndex)
            cycle.phase = .awaitingAnswers(askMessageID: last.id)
            return cycle
        }

        guard isPlanRow(messages, at: lastIndex, snapshot: snapshot) else {
            cycle.originID = nil
            cycle.phase = .none
            return cycle
        }

        cycle.snapshotMode = .plan
        cycle.askRounds = askRoundCount(in: messages, from: start, to: lastIndex)
        let resolved = origin(in: messages, from: start, to: lastIndex)
        cycle.originID = resolved

        // 2/3. Approved already → delivered; otherwise the plan is waiting for approval.
        let previousUser = messages[..<lastIndex].last(where: { $0.role == .user })
        if let previousUser, ApprovalMatcher.isApproval(previousUser.content) {
            cycle.phase = .delivered(originID: resolved ?? previousUser.id)
        } else {
            cycle.phase = .awaitingApproval(planMessageID: last.id)
        }
        return cycle
    }

    // MARK: - Private

    private mutating func endCycle() {
        phase = .none
        originID = nil
        askRounds = 0
        snapshotMode = .auto
        pausedPhase = nil
    }

    private mutating func startOrStayAuto(_ m: ChatMessage, liveMode: ResponseMode) -> PlanTurnKind {
        guard liveMode == .plan else {
            endCycle()
            return .auto
        }
        return startCycle(m)
    }

    private mutating func startCycle(_ m: ChatMessage) -> PlanTurnKind {
        snapshotMode = .plan
        askRounds = 0
        originID = m.id
        pausedPhase = nil
        phase = .none          // the reply decides whether it becomes an ask or a plan
        return .clarifyOrPlan
    }

    /// §7.5: a missing `mode` means Auto (web semantics) — unless the row came out of a durable
    /// save inside a plan run, which is recognised by the nearest EARLIER assistant row that still
    /// carries a mode. With no such row, the conversation's own snapshot decides.
    private static func isPlanRow(_ messages: [ChatMessage], at index: Int, snapshot: ResponseMode?) -> Bool {
        let own = messages[index].mode ?? ""
        if own == "plan" { return true }
        if own == "auto" { return false }
        var cursor = index - 1
        while cursor >= 0 {
            let row = messages[cursor]
            if row.role == .assistant, let mode = row.mode, !mode.isEmpty {
                return mode == "plan"
            }
            cursor -= 1
        }
        return snapshot == .plan
    }

    /// The first index of the current plan run: everything after the newest assistant row that is
    /// explicitly an Auto turn.
    private static func cycleStart(in messages: [ChatMessage], before lastIndex: Int) -> Int {
        var index = lastIndex - 1
        while index >= 0 {
            let row = messages[index]
            if row.role == .assistant, row.mode == "auto" { return index + 1 }
            index -= 1
        }
        return 0
    }

    /// The request that opened the run: the first user turn inside it that is not itself an
    /// approval sentence (D4/D5 — the deliverable is resolved from the request, never from
    /// "ابدأ التنفيذ").
    private static func origin(in messages: [ChatMessage], from start: Int, to end: Int) -> String? {
        guard start <= end, start >= 0, end < messages.count else { return nil }
        for row in messages[start...end] where row.role == .user {
            if ApprovalMatcher.isApproval(row.content) { continue }
            return row.id
        }
        return messages[start...end].first(where: { $0.role == .user })?.id
    }

    private static func askRoundCount(in messages: [ChatMessage], from start: Int, to end: Int) -> Int {
        guard start <= end, start >= 0, end < messages.count else { return 0 }
        var rounds = 0
        for row in messages[start...end] where row.role == .assistant {
            if AskSpec.hasAskFence(row.visibleContent) || AskSpec.parse(row.visibleContent) != nil {
                rounds += 1
            }
        }
        return rounds
    }
}
