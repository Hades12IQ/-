#if DEBUG
import Foundation

@MainActor
enum DocumentRevisionChecks {
    static func failures() -> [String] {
        var failures: [String] = []
        let originalPixels = "cGhvdG8tb3JpZ2luYWwtcGl4ZWxz"
        let screenshotPixels = "cmV2aXNpb24tc2NyZWVuc2hvdC1waXhlbHM="
        let thumbnail = "data:image/jpeg;base64,dGh1bWJuYWls"
        let question = ChatMessage(role: .user, content: "Create a PDF using this photo.", cid: "doc-photo",
            imageThumbs: [thumbnail], images: [originalPixels])
        let firstAssets = DocumentAssetInventory.entries(in: [question])
        guard let first = firstAssets.first else { return ["Document inventory omitted the supplied photograph"] }
        let source = "<html><head><style>.keep{color:#a12030}</style></head><body><h1>Keep this design</h1><img src=\"firas-asset:\(first.id)\"><p>Complete final paragraph 83719.</p></body></html>"
        let document = ChatMessage(role: .assistant, content: "```html\n" + source + "\n```", cid: "doc-photo")
        let change = ChatMessage(role: .user,
            content: "Remove the title marked in this screenshot from the same document.", cid: "doc-revision",
            imageThumbs: [thumbnail], images: [screenshotPixels])
        let messages = [question, document, change]
        let candidate = DocumentRevisionContext.latestMessage(in: [question, document], request: change.content)
        guard let revision = DocumentRevisionContext.completeSource(from: candidate) else {
            return ["Document revision did not recover the complete authored HTML"]
        }
        if revision.source.trimmingCharacters(in: .whitespacesAndNewlines) != source {
            failures.append("Document revision changed its original HTML before the model request")
        }
        let assets = DocumentAssetInventory.entries(in: messages)
        if assets.count != 2 || assets.last?.role != .revisionReference {
            failures.append("Revision screenshot became a document photograph")
        }
        let offered = DocumentAssetInventory.promptEntries(assets, retaining: revision.source)
        if offered.map(\.id) != [first.id] {
            failures.append("Document image inventory lost the original photo or offered screenshot evidence")
        }
        if let data = try? JSONEncoder().encode(question), let restored = try? JSONDecoder().decode(ChatMessage.self, from: data) {
            let restoredAssets = DocumentAssetInventory.entries(in: [restored])
            if restoredAssets.first?.id != first.id || restoredAssets.first?.isThumbnail != true {
                failures.append("Document asset identity changed after transcript persistence")
            }
        } else { failures.append("Document inventory persistence fixture could not round trip") }

        var history = [question, document]
        for index in 0..<30 {
            history.append(ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                content: String(repeating: "Intervening context. ", count: 500), cid: "context-\(index)"))
        }
        let input = PromptInput(tier: .pro, product: .ai, mode: .auto, lang: .english,
            thinkToggle: false, kind: .file(format: "pdf", explicitPages: nil), planTurn: .auto, askRounds: 0,
            searchContext: nil, searchWasEmpty: false, history: history, lastUser: change,
            reattachImages: nil, documentRevision: revision, documentAssets: assets)
        let output = PromptBuilder.build(input)
        let text = output.messages.map(\.content).joined(separator: "\n")
        if text.components(separatedBy: revision.source).count - 1 != 1 {
            failures.append("Document source was duplicated or evicted by the inference history window")
        }
        if !output.trimmed { failures.append("Document revision history fixture did not exercise windowing") }
        if text.contains(originalPixels) || text.contains(screenshotPixels) {
            failures.append("Document prompt exposed image base64 as text")
        }
        let vision = output.messages.last?.images ?? []
        if vision != [screenshotPixels, originalPixels] {
            failures.append("Revision vision inputs lost the correction screenshot or the original photograph")
        }

        let broken = ChatMessage(role: .assistant, content: "```html\n<html><body>unfinished", cid: "broken")
        if DocumentRevisionContext.completeSource(from: broken) != nil {
            failures.append("Document revision accepted a truncated source")
        }
        let huge = ChatMessage(role: .assistant, content: "<html><body>"
            + String(repeating: "x", count: DocumentRevisionContext.maximumSourceBytes) + "</body></html>", cid: "large")
        if DocumentRevisionContext.completeSource(from: huge) != nil {
            failures.append("Document revision silently accepted an over-budget source")
        }
        let artifact = ChatMessage(role: .assistant,
            content: "```firas-file\n{\"format\":\"pdf\",\"artifactId\":\"fixture\"}\n```", cid: "artifact")
        if DocumentRevisionContext.latestMessage(in: [question, artifact], request: "Edit this document") == nil
            || DocumentRevisionContext.completeSource(from: artifact) != nil {
            failures.append("Artifact-only PDF was mistaken for available authored source")
        }

        let image = ChatMessage(role: .assistant,
            content: "```firas-image\n{\"key\":\"test-image\",\"prompt\":\"a photograph\"}\n```", cid: "image")
        if DocumentRevisionContext.latestMessage(in: [question, document, image], request: "شيل هذا") != nil {
            failures.append("A newer image edit revived an unrelated earlier document")
        }
        if DocumentRevisionContext.latestMessage(in: [question, document, image], request: "شيل هذا من الملف")?.id != document.id {
            failures.append("An explicit document revision lost its earlier source")
        }
        let explanation = ChatMessage(role: .assistant, content: "The first section explains the results.", cid: "explanation")
        if DocumentRevisionContext.latestMessage(in: [question, document, explanation], request: "Edit the same document")?.id != document.id {
            failures.append("A clarification hid the previous document from an explicit revision")
        }
        let terse = ChatMessage(role: .user, content: "Remove the heading", cid: "terse")
        let revised = ChatMessage(role: .assistant, content: "```html\n" + source + "\n```", cid: "terse")
        if DocumentRevisionContext.latestMessage(in: [question, document, terse, revised], request: "Change the color")?.id != revised.id {
            failures.append("A second terse revision lost the latest document's provenance after reload")
        }

        let wordQuestion = ChatMessage(role: .user, content: "Create a docx report.", cid: "word")
        let word = ChatMessage(role: .assistant,
            content: "```firas-file\n{\"format\":\"docx\",\"filename\":\"report.docx\"}\n```\n# Report\n\n| Item | Value |\n| --- | --- |\n| Keep | 8391 |\n\nKeep the final paragraph.", cid: "word")
        if let wordSource = DocumentRevisionContext.completeSource(from: word) {
            if wordSource.isHTML || wordSource.source != word.content {
                failures.append("Ordinary Word revision discarded its markdown or file metadata")
            }
        } else { failures.append("Ordinary Word file with complete markdown was unnecessarily blocked") }
        if DocumentRevisionContext.format(for: "Edit the same document", candidate: word, history: [wordQuestion, word]) != "docx" {
            failures.append("Implicit Word revision changed the original file format")
        }

        var many = [first]
        for index in 0..<12 {
            many.append(DocumentAssetInventory.Entry(id: "other-\(index)", messageID: "other-\(index)",
                source: .attached(originalPixels), role: .content, isThumbnail: false))
        }
        if !DocumentAssetInventory.promptEntries(many, retaining: source).contains(where: { $0.id == first.id }) {
            failures.append("Revision image window discarded an asset still used in the original source")
        }
        var job = ChatJobRequest(messages: output.messages, tier: "pro", think: false, cid: "document-check",
            chatId: "test-chat", product: "ai", kind: "chat", lang: "en")
        if !SendPipeline.fitsDurableQueue(job, isTemporary: false, hasStorage: true) {
            failures.append("A small image-bearing document revision could not continue in the ordinary chat job")
        }
        if SendPipeline.fitsDurableQueue(job, isTemporary: true, hasStorage: true) {
            failures.append("A temporary document revision was eligible for durable storage")
        }
        job.kind = "longfile"
        if SendPipeline.fitsDurableQueue(job, isTemporary: false, hasStorage: true) {
            failures.append("An image-bearing request entered a worker that discards its images")
        }
        job.kind = "chat"
        job.messages = [OutgoingMessage(role: "user", content: String(repeating: "ع", count: 280_000))]
        if SendPipeline.fitsDurableQueue(job, isTemporary: false, hasStorage: true) {
            failures.append("Durable queue measured characters instead of the actual UTF-8 JSON payload")
        }
        return failures
    }
}
#endif
