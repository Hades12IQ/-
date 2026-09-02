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

    // MARK: - Transitions (web-plan-mode.md §7.2)

    /// Called with the user turn about to be sent. Mutates the phase and answers with the system
    /// text this turn needs.
    mutating func userSent(_ m: ChatMessage, liveMode: ResponseMode, product: ProductKind) -> PlanTurnKind {
        // Plan mode is a feature of the `ai` chat product only (D14).
        guard product == .ai else {
            self = PlanCycle.idle
            return .auto
        }

        switch phase {
        case .none:
            return startOrStayAuto(m, liveMode: liveMode)

        case .delivered:
            // A follow-up after delivery is an Auto turn. Only a genuinely new deliverable
            // re-arms the cycle (D12); the classifier's verdict rides on the message.
            let intent = m.intent ?? ""
            let isNewDeliverable = !intent.isEmpty && intent != "chat" && intent != "unavailable"
            if liveMode == .plan && isNewDeliverable {
                return startCycle(m)
            }
            phase = .none
            originID = nil
            askRounds = 0
            snapshotMode = .auto
            return .auto

        case .awaitingAnswers:
            // Submit, or the user typing the answer instead of tapping — same turn either way.
            askRounds += 1
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
        if case .executing(let origin) = phase {
            phase = .delivered(originID: origin)
            return
        }
        guard snapshotMode == .plan else {
            phase = .none
            return
        }
        if ask != nil {
            phase = .awaitingAnswers(askMessageID: m.id)
        } else {
            phase = .awaitingApproval(planMessageID: m.id)
        }
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

        guard let lastIndex = messages.lastIndex(where: { $0.role == .assistant && !$0.content.isEmpty }) else {
            return cycle
        }
        let last = messages[lastIndex]
        // A missing `mode` means Auto (web semantics) unless the conversation snapshot says the
        // row came out of a plan cycle.
        let isPlanRow = (last.mode == "plan") || (last.mode == nil && snapshot == .plan)

        let boundary = cycleStart(in: messages, before: lastIndex)
        let origin = messages[boundary...lastIndex].first(where: { $0.role == .user })?.id
        cycle.originID = origin
        cycle.askRounds = messages[boundary...lastIndex].reduce(into: 0) { total, m in
            if m.role == .assistant, AskSpec.parse(m.content) != nil { total += 1 }
        }

        // 1. An unanswered ask panel.
        if last.askAnswered != true, AskSpec.parse(last.content) != nil {
            cycle.snapshotMode = .plan
            cycle.phase = .awaitingAnswers(askMessageID: last.id)
            return cycle
        }
        guard isPlanRow else {
            cycle.phase = .none
            return cycle
        }
        // 2/3. Approved already → delivered; otherwise the plan is waiting for approval.
        let previousUser = messages[..<lastIndex].last(where: { $0.role == .user })
        cycle.snapshotMode = .plan
        if let previousUser, ApprovalMatcher.isApproval(previousUser.content) {
            cycle.phase = .delivered(originID: origin ?? previousUser.id)
        } else {
            cycle.phase = .awaitingApproval(planMessageID: last.id)
        }
        return cycle
    }

    // MARK: - Private

    private mutating func startOrStayAuto(_ m: ChatMessage, liveMode: ResponseMode) -> PlanTurnKind {
        guard liveMode == .plan else {
            snapshotMode = .auto
            originID = nil
            askRounds = 0
            return .auto
        }
        return startCycle(m)
    }

    private mutating func startCycle(_ m: ChatMessage) -> PlanTurnKind {
        snapshotMode = .plan
        askRounds = 0
        originID = m.id
        phase = .none          // the reply decides whether it becomes an ask or a plan
        return .clarifyOrPlan
    }

    /// The first index of the current plan run: everything after the newest assistant row that is
    /// explicitly an Auto turn.
    private static func cycleStart(in messages: [ChatMessage], before lastIndex: Int) -> Int {
        var index = lastIndex - 1
        while index >= 0 {
            let m = messages[index]
            if m.role == .assistant, m.mode == "auto" { return index + 1 }
            index -= 1
        }
        return 0
    }
}
