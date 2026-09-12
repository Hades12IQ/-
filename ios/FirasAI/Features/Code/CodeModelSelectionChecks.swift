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
            let webJSON = #"{"turns":[],"selection":{"model":""# + tier.rawValue + #"","depth":"deep"}}"#
            let webFence = "```firas-code-chat\n" + Data(webJSON.utf8).base64EncodedString() + "\n```"
            if CodeChatThread.decode(fromFence: webFence)?.selection != selection {
                failures.append("Real website nested model/depth did not survive reopening: " + tier.rawValue)
            }
            if let bytes = try? JSONEncoder().encode(thread), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                let nested = object["selection"] as? [String: String]
                if nested?["model"] != tier.rawValue || nested?["depth"] != selection.depth || object["model"] != nil {
                    failures.append("Native Code selection was not written in the website's nested format")
                }
            } else { failures.append("Code nested selection could not encode") }
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
        let historical = CodeChatThread.decode(fromFence: u16)
        if historical?.messages.first?.content != "اكتب برنامجًا 😀" || historical?.selection != CodeModelSelection(model: .omnix) {
            failures.append("Code could not reopen the historical flat UTF-16 thread and its model")
        }
        for payload in [#"{"turns":[]}"#, #"{"turns":[],"selection":null}"#] {
            let old = CodeChatThread.decode(fromFence: "```firas-code-chat\n" + Data(payload.utf8).base64EncodedString() + "\n```")
            if old?.selection != CodeModelSelection() { failures.append("Missing or null Code selection lost the Pro default") }
        }
        let both = #"{"turns":[],"model":"mini","depth":"standard","selection":{"model":"omnix","depth":"managed"}}"#
        let preferred = CodeChatThread.decode(fromFence: "```firas-code-chat\n" + Data(both.utf8).base64EncodedString() + "\n```")
        if preferred?.selection != CodeModelSelection(model: .omnix) { failures.append("The nested website selection did not supersede a historical flat choice") }
        return failures
    }
}
#endif
