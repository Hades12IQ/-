#if DEBUG
import Foundation
import UIKit
import CryptoKit

@MainActor
enum CountedDocumentReliabilityChecks {
    static func failures() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) { if !condition { failures.append("counted-document-" + name) } }
        let original = "Create a PDF with 10 very hard JEE integrals, three per row, with solutions at the end."
        let edit = "I don’t like it i want the integrals very hard with new ideas and a very pro design"
        let question = ChatMessage.user(original, cid: "count-original", lang: .english)
        let html = "<!DOCTYPE html><html><head><title>Original</title></head><body><p>COMPLETE ORIGINAL SOURCE</p></body></html>"
        let legacy = ChatMessage(role: .assistant, content: "```firas-file\n{\"format\":\"pdf\",\"filename\":\"original.pdf\"}\n```\n```html\n" + html + "\n```", cid: "count-original")
        let history = [question, legacy]
        let prior = DocumentRevisionContext.latestMessage(in: history, request: edit)
        let format = DocumentRevisionContext.format(for: edit, candidate: prior, history: history)
        check(format == "pdf", "screenshot-feedback-retains-pdf")
        check(DocumentRevisionContext.completeSource(from: prior)?.source == html, "revision-retains-entire-source")
        let requirements = CountedDocumentPlan.originalRequirements(previous: prior, history: history)
        check(requirements == original && requirements.contains("10") && requirements.contains("three per row"), "revision-retains-count-and-layout")
        check(CountedDocumentPlan.resolve(request: edit, kind: .file(format: "pdf", explicitPages: nil),
            history: history, previous: prior, isRevision: true) == nil, "legacy-source-never-discarded-by-count-router")
        check(RequestClassifier.documentRevisionFormat("Why don’t I like this design?", hasPreviousDocument: true) == nil,
            "question-is-not-edit")
        check(RequestClassifier.documentRevisionFormat(edit, hasPreviousDocument: false) == nil, "feedback-needs-real-document")

        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("ACTUAL VERIFIED PDF" as NSString).draw(at: CGPoint(x: 25, y: 30),
                withAttributes: [.font: UIFont.systemFont(ofSize: 17)])
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let meta = FileMeta(format: "pdf", name: "fixture.pdf", pages: 1, artifactId: "fixture-artifact",
            artifactEndpoint: "/api/chat/job/file?id=fixture-artifact", serverPdf: true, counteddoc: true,
            sha256: digest, pdfBytes: data.count, expectedItems: 10, requiresSolutions: true, solutionsAtEnd: true)
        check(meta.hasVerifiedPDFReference && !meta.isDurableLongFile, "complete-pdf-never-enters-parts-reader")
        func fence(_ value: FileMeta) -> String {
            "```firas-file\n" + String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8)! + "\n```"
        }
        check(FileMeta.document(inContent: fence(meta)) == meta || FileMeta.document(inContent: fence(meta))?.hasVerifiedPDFReference == true,
            "server-reference-roundtrip")
        let server = ChatMessage(role: .assistant, content: fence(meta), cid: "count-original")
        let serverHistory = [question, server]
        let revision = CountedDocumentPlan.resolve(request: edit, kind: .file(format: "pdf", explicitPages: nil),
            history: serverHistory, previous: server, isRevision: true)
        check(revision?.revisionOf == meta.artifactId && revision?.items.count == 10 && revision?.items.requiresSolutions == true,
            "large-server-revision-keeps-original-item-target")
        var partial = meta
        partial.partial = true; partial.completedItems = 4; partial.remainingItems = 6; partial.resumeJobId = "original-job"
        var partialRow = ChatMessage(role: .assistant, content: fence(partial), cid: "partial", status: .failed("generation error"))
        check(DocumentCardReadiness.evaluate(message: partialRow, meta: partial, request: original,
            isStreaming: false, lang: .english).canOpen, "real-error-partial-can-open-and-save")
        check(!DocumentCardReadiness.evaluate(message: partialRow, meta: partial, request: original,
            isStreaming: true, lang: .english).canOpen, "partial-stream-not-yet-ready")
        check(partial.partialLabel(.english)?.contains("4 of 10") == true, "partial-count-is-visible")
        for text in ["اي كمل", "كمل", "yes continue", "Please finish it"] {
            let resumed = CountedDocumentPlan.resolve(request: text, kind: .chat, history: [question, partialRow],
                previous: partialRow, isRevision: false)
            check(resumed?.resumeFrom == "original-job" && resumed?.items.count == 10, "resume-" + text)
        }
        let image = ChatMessage(role: .assistant, content: "```firas-image\n{\"key\":\"latest-image\"}\n```", cid: "new-image")
        check(CountedDocumentPlan.resolve(request: "continue", kind: .chat, history: [question, partialRow, image],
            previous: partialRow, isRevision: false) == nil, "resume-cannot-cross-newer-artifact")
        partialRow.content = fence(meta)
        check(!DocumentCardReadiness.evaluate(message: partialRow, meta: meta, request: original,
            isStreaming: false, lang: .english).canOpen, "unlabelled-failed-file-remains-blocked")

        let longTask = "Create a PDF with 1000 integrals and all solutions at the end. " + String(repeating: "Keep this complete requirement. ", count: 400)
        let plan = CountedDocumentPlan.resolve(request: longTask, kind: .file(format: "pdf", explicitPages: nil),
            history: [], previous: nil, isRevision: false)
        check(plan?.items.count == 1000, "initial-thousand-items")
        let context = ChatTurnContext(conversationID: "chat", product: .ai, userMessageID: "new-user",
            turnCID: "new-cid", planTurn: .auto, tier: .mini, isAutoRetry: false)
        let output = PromptOutput(messages: [], tier: .mini, think: false, trimmed: false)
        let request = SendPipeline.jobRequest(output: output, context: context, kind: .file(format: "pdf", explicitPages: nil),
            jobKind: .counteddoc, chatID: "chat", title: "Fixture", task: longTask, lang: .english, counted: plan)
        check(request.kind == "counteddoc" && request.expectedItems == 1000 && request.pages == nil && request.targetPages == nil,
            "item-count-is-never-pages")
        check(request.task == longTask && (request.task?.count ?? 0) > 8_000 && request.cid == "new-cid", "task-is-not-truncated")
        check(SendPipeline.fitsDurableQueue(request, isTemporary: false, hasStorage: true)
            && !SendPipeline.fitsDurableQueue(request, isTemporary: true, hasStorage: true), "queue-preserves-temporary-privacy")
        var invalid = request; invalid.task = String(repeating: "ع", count: 60_001)
        check(!SendPipeline.fitsDurableQueue(invalid, isTemporary: false, hasStorage: true), "task-limit-is-utf8-bytes")
        let started = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let pointer = JobPointer(id: "old-count-job", kind: .counteddoc, ownerID: "owner", cid: "cid",
            conversationID: "chat",
            startedAt: started, deadline: started.addingTimeInterval(7 * 24 * 60 * 60))
        check(!pointer.isExpired && JobKindSpecs.spec(.counteddoc).cancelable, "server-live-state-outranks-client-age")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url)
            let verified = try ServerDocumentService.verifyPDF(url: url, meta: meta)
            check(verified.pages == 1 && verified.bytes == data.count, "actual-pdf-sha-size-pages")
            var badHash = meta; badHash.sha256 = String(repeating: "0", count: 64)
            do { _ = try ServerDocumentService.verifyPDF(url: url, meta: badHash); check(false, "tampered-pdf-was-accepted") }
            catch { }
            var badPages = meta; badPages.pages = 2
            do { _ = try ServerDocumentService.verifyPDF(url: url, meta: badPages); check(false, "wrong-page-count-was-accepted") }
            catch { }
        } catch { check(false, "actual-pdf-fixture-failed") }
        return failures
    }
}
#endif
