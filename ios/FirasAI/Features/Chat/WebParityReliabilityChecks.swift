#if DEBUG
import Foundation

enum WebParityReliabilityChecks {
    static func failures() -> [String] {
        var failures: [String] = []
        func require(_ passed: Bool, _ detail: String) {
            if !passed { failures.append("Website parity: " + detail) }
        }
        let expected: [(ModelTier, String)] = [(.mini, "luma 1"), (.pro, "nova 1"),
            (.ultra, "titan 1"), (.max, "atlas 1"), (.omnix, "omnix 1")]
        for (tier, name) in expected {
            require(tier.label(.arabic) == name && tier.label(.english) == name,
                    "Current model identity differs for " + tier.rawValue)
            require(ModelTier.lenient(tier.rawValue) == tier, "Saved model did not round-trip")
            if tier != .omnix {
                require(PromptCatalog.persona(tier: tier.rawValue).hasPrefix("You are " + name),
                        "Prompt still names an obsolete model")
            }
        }
        require(!ModelTier.omnix.showThinking, "Cloud worker exposed an unsupported think toggle")
        for tier in ModelTier.allCases {
            let expectedVoiceTier: ModelTier = tier == .mini ? .mini : .pro
            require(ThreeHopCall.responseTier(for: tier) == expectedVoiceTier,
                    "Voice fallback leaked an unsupported model tier: " + tier.rawValue)
        }
        require(PromptCatalog.langRule.contains("IRAQI & REGIONAL ARABIC"), "Updated dialect guidance missing")
        require(PromptCatalog.mathRule.contains("complete factors and operators inside one math span"),
                "Website synchronization removed the native math fix")

        let request = "ios_" + String(repeating: "a", count: 32)
        let pending = OmnixReceipt(owner: "fixture-owner", conversationId: "c_fixture", requestKey: request)
        var accepted = pending
        accepted.jobId = "omxj_" + String(repeating: "b", count: 32)
        accepted.sessionId = "omxs_" + String(repeating: "c", count: 32)
        let local = ChatMessage(role: .assistant, content: "", tier: "omnix", cid: request, omnix: pending)
        let server = ChatMessage(role: .assistant, content: "", tier: "omnix", cid: request, omnix: accepted)
        for selected in ModelTier.allCases where selected != .omnix {
            require(SendPipeline.legacyRetryReference(for: server, requestedTier: selected, fallbackTier: .pro) == nil,
                    "An Omnix request entered the legacy retry ledger")
            var tierOnly = server
            tierOnly.omnix = nil
            require(SendPipeline.legacyRetryReference(for: tierOnly, requestedTier: selected, fallbackTier: .pro) == nil,
                    "An Omnix model tag entered the legacy retry ledger without a receipt")
            var receiptOnly = server
            receiptOnly.tier = nil
            require(SendPipeline.legacyRetryReference(for: receiptOnly, requestedTier: selected, fallbackTier: .pro) == nil,
                    "A cloud receipt without a tier entered the legacy retry ledger")
            for previous in ModelTier.allCases where previous != .omnix {
                let old = ChatMessage(role: .assistant, content: "Answer", tier: previous.rawValue, cid: "legacy-cid")
                let reference = SendPipeline.legacyRetryReference(for: old, requestedTier: selected, fallbackTier: .omnix)
                let expected = selected == previous ? nil : RetryReference(cid: "legacy-cid", tier: previous.rawValue)
                require(reference == expected, "A legacy-to-legacy model retry lost its original ledger reference")
            }
        }
        require(MessageSerializer.merge(local: [], server: [server]).count == 1,
                "Receipt-only cloud turn disappeared on reload")
        require(MessageSerializer.merge(local: [local], server: [server]).first?.omnix == accepted,
                "Pending receipt did not adopt its acknowledged job")
        var conflict = server
        conflict.omnix?.jobId = "omxj_" + String(repeating: "d", count: 32)
        require(MessageSerializer.merge(local: [server], server: [conflict]).first?.omnix == accepted,
                "A conflicting receipt replaced the active cloud job")
        var bad = server
        bad.omnix?.jobId = "https://foreign.invalid/job"
        require(MessageSerializer.persisted(bad).omnix == nil, "Malformed receipt was saved")
        require(MessageSerializer.merge(local: [], server: [bad]).isEmpty,
                "Malformed receipt left an empty transcript row")
        do {
            let encoded = try JSONEncoder().encode(server)
            let restored = try JSONDecoder().decode(ChatMessage.self, from: encoded)
            require(restored.omnix == accepted, "Cloud receipt lost during backup decode")
            let persisted = try JSONEncoder().encode(MessageSerializer.persisted(server))
            let saved = try JSONDecoder().decode(PersistedMessage.self, from: persisted)
            require(saved.omnix == accepted, "Cloud receipt lost in server persistence shape")
        } catch { failures.append("Website parity: receipt encoding failed") }
        return failures
    }
}
#endif
