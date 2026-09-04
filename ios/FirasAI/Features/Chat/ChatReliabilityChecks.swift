#if DEBUG
import Foundation

enum ChatReliabilityChecks {
    /// Executed by the simulator smoke route; no requests or customer data are involved.
    static func failures() -> [String] {
        var failures: [String] = []
        failures += MediaIntentChecks.failures()
        let paragraphs = (0..<40).map { "فقرة \($0): شرح التجربة ونتائجها. A complete paragraph." }
        let long = paragraphs.joined(separator: "\n\n")
        let chunks = TranslationService.chunks(long, limit: 160)
        if chunks.count < 2 || chunks.joined(separator: "\n\n") != long {
            failures.append("translation-preserves-long-arabic-text")
        }
        let formula = #"$$\begin{aligned}E &= mc^2 \\ F &= ma\end{aligned}$$"#
        let fenced = "```python\nprint('do not translate code')\n```"
        let mixed = "First paragraph.\n\n" + formula + "\n\n" + fenced + "\n\nLast paragraph."
        let blocks = TranslationService.chunks(mixed, limit: 35)
        if !blocks.contains(where: { $0.contains(formula) }) || !blocks.contains(where: { $0.contains(fenced) }) {
            failures.append("translation-keeps-math-and-code-whole")
        }
        if !TranslationService.chunks(" \n\n ").isEmpty {
            failures.append("translation-empty-input")
        }
        let languages = TranslationLanguage.all(lang: .arabic)
        let ids = Set(languages.map(\.id))
        if languages.count < 100 || !Set(["ar", "en", "tr", "fa", "ckb", "zh-Hant", "fr"]).isSubset(of: ids) {
            failures.append("translation-language-coverage")
        }
        let question = ChatMessage.user("اصنع أغنية حزينة", cid: "smoke-media-question", lang: .arabic)
        let preparation = ChatMediaPreparation(questionID: question.id, kind: .music)
        let card = ChatMessage(
            id: "smoke-media-card", role: .assistant,
            content: MediaMeta(kind: .music, prompt: "private production tags").encodedFence()
        )
        if preparation.hasCard(in: [card, question]) || !preparation.hasCard(in: [question, card]) {
            failures.append("media-status-follows-its-own-question")
        }
        if preparation.label(.arabic).contains("private production tags") {
            failures.append("media-status-hides-production-prompt")
        }
        let ownerA = MediaCreation(
            id: "owner-a-image", ownerID: "owner-a", kind: .image,
            meta: MediaMeta(kind: .image, key: "fixture-a"), conversationID: "fixture-chat-a"
        )
        let ownerB = MediaCreation(
            id: "owner-b-image", ownerID: "owner-b", kind: .image,
            meta: MediaMeta(kind: .image, key: "fixture-b"), conversationID: "fixture-chat-b"
        )
        let library = [ownerA, ownerB]
        if MediaStore.ownedCreations(library, owner: "owner-a").map(\.id) != [ownerA.id]
            || !MediaStore.ownedCreations(library, owner: "").isEmpty
            || !MediaStore.ownedCreations(library, owner: "different-owner").isEmpty {
            failures.append("media-library-owner-isolation")
        }
        let pathA = MediaStore.ownerIndexPath("owner-a")
        if pathA != MediaStore.ownerIndexPath("owner-a")
            || pathA == MediaStore.ownerIndexPath("owner-b")
            || pathA.contains("owner-a") {
            failures.append("media-library-owner-scoped-path")
        }
        return failures
    }
}
#endif
