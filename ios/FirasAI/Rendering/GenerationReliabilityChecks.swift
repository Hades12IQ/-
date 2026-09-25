#if DEBUG
import Foundation
import WebKit

@MainActor
enum GenerationReliabilityChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ message: String) { if !ok { failures.append("Generation 1.1: " + message) } }
        func json<T: Encodable>(_ value: T) -> [String: Any] {
            guard let data = try? JSONEncoder().encode(value), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return result
        }
        check(ModelGeneration.history(nil) == .legacy && ModelGeneration.preference(nil) == .current, "new preferences relabel old history")
        let request = ChatStreamRequest(messages: [], tier: "pro", mgen: "1.1", think: false, cid: "fixture", product: "ai")
        check(json(request)["mgen"] as? String == "1.1", "current generation missing on stream")
        check(json(ChatStreamRequest(messages: [], tier: "pro", think: false, cid: "fixture", product: "ai"))["mgen"] == nil, "legacy request upgraded implicitly")
        let oldCode = try? JSONDecoder().decode(CodeModelSelection.self, from: Data(#"{"model":"omnix"}"#.utf8))
        check(oldCode?.generation == .legacy, "old Omnix project changed generation")
        let freshCode = try? JSONDecoder().decode(CodeModelSelection.self, from: Data(#"{"model":"pro"}"#.utf8))
        check(freshCode?.generation == .current, "Code model migration missing")
        let start = ExecutionStep(id: "tool-1", kind: "search", state: "live", at: 4, say: "First")
        let end = ExecutionStep(id: "tool-1", kind: "search", state: "done", fact: "2 sources", at: 30)
        let merged = ExecutionStep.merge([start], [end])
        check(merged?.count == 1 && merged?.first?.at == 4 && merged?.first?.say == "First" && merged?.first?.state == "done", "step completion duplicated or moved the row")
        let version = AnswerVersion(content: "answer", mgen: "1.1", steps: merged)
        let restored = (try? JSONEncoder().encode(version)).flatMap { try? JSONDecoder().decode(AnswerVersion.self, from: $0) }
        check(restored == version, "answer alternative lost generation or activity")
        let progressJSON = #"{"timelineVersion":1,"events":[{"id":"speech","kind":"speech","text":"😀 نص","at":1},{"id":"tool-1","kind":"tool","at":2}],"plan":[{"id":"tool-1","title":"delegate_task","s":"done","observed":true,"error":false,"delegationOutcome":"dispatched"}]}"#
        let progress = try? JSONDecoder().decode(OmnixProgress.self, from: Data(progressJSON.utf8))
        check(progress != nil, "actual gateway boolean error breaks progress decoding")
        let activity = OmnixActivity(progress: progress, output: "😀 نص\nFinal", lang: .english)
        check(activity.narration == "😀 نص" && activity.body == "\nFinal" && activity.steps.first?.at == "😀 نص".utf16.count, "speech duplicated or UTF-16 offset changed")
        check(activity.steps.first?.text == "Launched the sub-task", "dispatch misreported as child completion")
        var incomplete = progress; incomplete?.droppedSpeech = true
        let fallback = OmnixActivity(progress: incomplete, output: "whole answer", lang: .english)
        check(fallback.narration.isEmpty && fallback.body == "whole answer", "truncated timeline duplicated narration")
        check(OmnixPreviewPacket.relative("site/css/main.css", root: "site") == "css/main.css", "relative project assets lost")
        for path in ["site/../secret", "site//x", "/site/x", "other/x", "site/a\\b", "site/https:x"] {
            check(OmnixPreviewPacket.relative(path, root: "site") == nil, "preview escaped project root: " + path)
        }
        check(PromptEngineering.request(in: "/prompteng اكتب طلبًا") == "اكتب طلبًا", "prompt command lost request")
        check(PromptEngineering.request(in: "https://example.com/prompteng") == nil, "URL intercepted as command")
        let prompt = String(repeating: "A cinematic photorealistic portrait with rim lighting and an 85mm lens. ", count: 5)
        check(GenerationIntentRouter.isFinishedImagePrompt(prompt), "pasted image prompt takes conversational fast path")
        check(!GenerationIntentRouter.isFinishedImagePrompt("Explain this: " + prompt), "question classified as image")
        failures += await previewChecks()
        return failures
    }
    private static func previewChecks() async -> [String] {
        let html = "<html><head><link rel='stylesheet' href='css/site.css'></head><body><p id='title'>Private site</p><script src='js/site.js'></script></body></html>"
        let packet = OmnixPreviewPacket(entry: "index.html", files: ["index.html": Data(html.utf8),
            "css/site.css": Data("#title { color: rgb(12, 34, 56); }".utf8),
            "js/site.js": Data("window.fixtureLoaded = true; fetch('https://example.invalid/private').then(() => window.networkBlocked = false).catch(() => window.networkBlocked = true);".utf8)])
        let coordinator = OmnixProjectPreview.Coordinator(packet: packet)
        let web = OmnixProjectPreview.makeWebView(packet: packet, coordinator: coordinator)
        defer { web.stopLoading(); web.navigationDelegate = nil }
        for _ in 0..<80 {
            let value = try? await web.evaluateJavaScript("Boolean(window.fixtureLoaded && window.networkBlocked && document.getElementById('title') && getComputedStyle(document.getElementById('title')).color === 'rgb(12, 34, 56)')")
            if value as? Bool == true { return [] }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return ["Generation 1.1: private preview did not load relative CSS/JS or block external fetch"]
    }
}
#endif
