//
//  PromptBuilder.swift
//  FirasAI
//
//  ONE system message, then the conversation. That is the whole contract.
//
//  The web sends up to nine system rows and splices new ones in at index 1 (web-prompt-builder.md
//  §6). `server.mjs` merges the identity block and the user's memory into the FIRST system message
//  only, and its own comment says why: "some models (e.g. the coder model on Ultra) ignore a
//  second system message" (web-plan-mode.md §6 D2) — which is exactly why plan mode is silently
//  Auto on some tiers today. So everything that must be honoured is CONCATENATED here:
//
//      persona … userReqRule + dfxRule        (PromptCatalog.systemPrompt)
//      + planSystem                           (any plan turn)
//      + EXECUTE note                         (the approved turn — and the build rules come back,
//                                              which the web drops while STEP 3 refers to them, D3)
//      + forced-plan note                     (after two ask rounds)
//      + fileGuidance(fmt)                    (a document turn that is not a clarify/plan turn)
//      + no-search-results note                (explicit search, nothing came back)
//
//  The identity block is NEVER sent: the server prepends it and marks it authoritative.
//  Retrieved web text is a `user` message right after the system message, never `system`.
//

import Foundation

struct PromptInput: Sendable {
    let tier: ModelTier
    let product: ProductKind
    let mode: ResponseMode
    let lang: AppLanguage
    let thinkToggle: Bool
    let kind: RequestKind
    let planTurn: PlanTurnKind
    let askRounds: Int
    let searchContext: String?
    let searchWasEmpty: Bool
    let history: [ChatMessage]
    let lastUser: ChatMessage
    let reattachImages: [String]?
    /// True when the search that produced `searchContext` was EXPLICIT (the toggle, or search
    /// intent in the message). Only an explicit search downgrades the tier; a silent one never
    /// does (app.js:42489). Defaulted so the frozen initialiser keeps compiling.
    var explicitSearch: Bool = false
}

struct PromptOutput: Sendable {
    let messages: [OutgoingMessage]
    let tier: ModelTier
    let think: Bool
    let trimmed: Bool
}

enum PromptBuilder {

    /// web-plan-mode.md §7.3b — restores the build rules STEP 3 refers to.
    static let executeNote =
        "The user has APPROVED the plan above. You are now in STEP 3: execute the FULL deliverable now, in one reply, following the agreed plan and the user's answers exactly. Do not ask anything, do not restate the plan."

    /// web-plan-mode.md §7.3c — after two rounds of questions, stop asking.
    static let forcedPlanNote =
        "Do NOT ask further questions; assume the recommended options and give the plan now (STEP 2)."

    // MARK: - Build

    static func build(_ input: PromptInput) -> PromptOutput {
        let hasImages = !(input.lastUser.images ?? []).isEmpty || !(input.reattachImages ?? []).isEmpty
        let tier = effectiveTier(input)
        let think = input.thinkToggle && tier.showThinking && !hasImages
        let planning = isPlanningTurn(input.planTurn)

        var system = PromptCatalog.systemPrompt(
            tier: tier.rawValue,
            product: input.product.wireValue,
            mode: planning ? "plan" : "auto",
            lang: input.lang.rawValue,
            think: think,
            requestKind: catalogRequestKind(input.kind)
        )
        system += planAddendum(input, planning: planning)
        if !planning, let format = documentFormat(input.kind) {
            system += "\n\n" + fileGuidance(format: format, lang: input.lang)
        }
        if input.searchWasEmpty {
            system += "\n\n" + PromptCatalog.noSearchResultsNote(lang: input.lang.rawValue)
        }

        var messages: [OutgoingMessage] = []
        messages.reserveCapacity(input.history.count + 3)
        messages.append(OutgoingMessage(role: "system", content: system, images: nil))

        if let context = input.searchContext, !context.isEmpty {
            messages.append(OutgoingMessage(role: "user", content: context, images: nil))
        }

        let window = HistoryWindow.window(input.history)
        for row in window.kept {
            guard row.role != .system else { continue }
            if row.role == .assistant && row.content.isEmpty { continue }
            // Pictures ride on the last user turn only; an old turn's base64 would blow the job
            // payload ceiling for nothing.
            let wire = MessageSerializer.outgoing(row, reattachImages: nil)
            messages.append(OutgoingMessage(role: wire.role, content: wire.content, images: nil))
        }

        messages.append(MessageSerializer.outgoing(input.lastUser, reattachImages: input.reattachImages))

        return PromptOutput(messages: messages, tier: tier, think: think, trimmed: window.trimmed)
    }

    /// The per-turn document instructions. The web's text is English and language-independent;
    /// `lang` is accepted for symmetry with the rest of the builder.
    static func fileGuidance(format: String, lang: AppLanguage) -> String {
        return PromptCatalog.fileGuidance(format: format)
    }

    // MARK: - Private

    private static func isPlanningTurn(_ turn: PlanTurnKind) -> Bool {
        switch turn {
        case .clarifyOrPlan, .revision, .forcedPlan: return true
        case .auto, .execute: return false
        }
    }

    private static func planAddendum(_ input: PromptInput, planning: Bool) -> String {
        let planSystem = PromptCatalog.planSystemMessage(lang: input.lang.rawValue)
        switch input.planTurn {
        case .auto:
            return ""
        case .clarifyOrPlan:
            // The cycle caps clarifying rounds at two; `askRounds` is the safety net for a caller
            // that derived the turn kind from a loaded conversation.
            if input.askRounds >= 2 { return "\n\n" + planSystem + "\n\n" + forcedPlanNote }
            return "\n\n" + planSystem
        case .revision:
            return "\n\n" + planSystem
        case .forcedPlan:
            return "\n\n" + planSystem + "\n\n" + forcedPlanNote
        case .execute:
            return "\n\n" + planSystem + "\n\n" + executeNote
        }
    }

    /// An explicit web search downgrades every tier but `max` to `pro` for that request; a silent
    /// search never changes the tier.
    private static func effectiveTier(_ input: PromptInput) -> ModelTier {
        guard input.explicitSearch, input.tier != .max else { return input.tier }
        return .pro
    }

    /// The catalog's `requestKind` vocabulary: `code` replaces the whole prompt with the code
    /// deliverable brief, `document` and `image` keep the chat prompt (their extra text is added
    /// separately), everything else is an ordinary chat turn.
    private static func catalogRequestKind(_ kind: RequestKind) -> String {
        switch kind {
        case .code: return "code"
        case .file, .longfile: return "document"
        case .image, .imageEdit: return "image"
        case .chat, .video, .music, .longdoc, .irab: return "chat"
        }
    }

    private static func documentFormat(_ kind: RequestKind) -> String? {
        switch kind {
        case .file(let format, _): return format
        case .longfile(let format, _): return format
        default: return nil
        }
    }
}
