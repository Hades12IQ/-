#if DEBUG
import Foundation

@MainActor
enum CodeModelSelectionChecks {
    static func run() -> [String] {
        var failures: [String] = []
        for tier in ModelTier.allCases {
            let selection = CodeModelSelection(model: tier, depth: "deep")
            var turn = CodeChatMessage(role: "ai", content: "نتيجة محفوظة")
            turn.model = tier.rawValue
            if tier == .omnix {
                turn.omnix = OmnixReceipt(owner: "fixture-owner", conversationId: "fixture-chat", requestKey: String(repeating: "a", count: 32))
            }
            let thread = CodeChatThread(messages: [turn], selection: selection)
            let decoded = CodeChatThread.decode(fromFence: thread.encodedFence())
            if decoded?.selection != selection || decoded?.messages.first?.model != tier.rawValue || decoded?.messages.first?.omnix != turn.omnix {
                failures.append("Code selection/Omnix receipt did not survive the website thread fence")
            }
            if selection.think != (tier != .mini && tier != .omnix) { failures.append("Code thinking ignored the selected model's capability") }
            if tier != .omnix {
                let ticket = CodeBuildTicket(projectID: "fixture-chat", cid: "fixture-cid", ownerID: "fixture-owner", name: "Project",
                    brief: "Build a simple website", attach: "", lang: "en", startedAt: 1, selection: selection)
                for brief in ["Build a simple website", "Build a Python CLI"] {
                    var requestTicket = ticket; requestTicket.brief = brief
                    let request = CodeBuildHandoff.request(ticket: requestTicket, checkpoint: nil)
                    if request.tier != tier.rawValue || request.think != selection.think || request.nomem == true {
                        failures.append("Code durable build silently changed the selected model or work depth")
                    }
                }
                if let encoded = try? JSONEncoder().encode(ticket), let restored = try? JSONDecoder().decode(CodeBuildTicket.self, from: encoded) {
                    if restored.selection != selection { failures.append("Code recovery lost the selected build model") }
                } else { failures.append("Code selected build ticket did not encode") }
            }
        }
        let unicode = #"{"model":"omnix","depth":"managed","turns":[{"role":"user","text":"اكتب برنامجًا 😀"}]}"#
        let u16 = "```firas-code-chat\nu16:" + (unicode.data(using: .utf16LittleEndian)?.base64EncodedString() ?? "") + "\n```"
        if CodeChatThread.decode(fromFence: u16)?.messages.first?.content != "اكتب برنامجًا 😀" { failures.append("Code could not reopen the current website's UTF-16 thread encoding") }
        let old = CodeChatThread.decode(fromFence: "```firas-code-chat\n" + Data(#"{"turns":[]}"#.utf8).base64EncodedString() + "\n```")
        if old?.selection != CodeModelSelection() { failures.append("Legacy Code projects lost the website's Pro default") }
        return failures
    }
}
#endif
