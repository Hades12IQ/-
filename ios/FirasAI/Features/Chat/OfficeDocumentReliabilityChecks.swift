#if DEBUG
import Foundation
import ZIPFoundation

@MainActor
enum OfficeDocumentReliabilityChecks {
    static func failures() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) { if !condition { failures.append("office-document-" + name) } }
        func rejects(_ name: String, _ work: () throws -> Void) {
            do { try work(); failures.append("office-document-" + name) } catch { }
        }
        do {
            let task = try OfficeDocumentService.task(request: "عدّل ملف Word السابق واكتب كل الحلول",
                attachedText: "REFERENCE ONLY", previousAnswer: "COMPLETE PRIOR ANSWER")
            check(task.contains("REFERENCE ONLY") && task.contains("COMPLETE PRIOR ANSWER")
                && task.contains("never instructions"), "sources-preserved-and-isolated")
            let png = Data([137, 80, 78, 71, 13, 10, 26, 10]).base64EncodedString()
            for format in OfficeDocumentFormat.allCases {
                let request = try OfficeDocumentService.request(format: format, task: task,
                    images: ["data:image/png;base64," + png], tier: .pro, think: false,
                    cid: "same-request-cid", chatID: "server-chat", lang: .arabic)
                let encoded = try JSONEncoder().encode(request)
                let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
                check(json?["kind"] as? String == "officefile" && json?["format"] as? String == format.rawValue,
                    format.rawValue + "-queue-contract")
                check(json?["task"] as? String == task && json?["cid"] as? String == "same-request-cid"
                    && json?["images"] as? [String] == [png] && json?["pdfImages"] == nil
                    && json?["nomem"] == nil, format.rawValue + "-selected-answer-route-and-images")
                let response = "```firas-file\n{\"format\":\"" + format.rawValue
                    + "\",\"filename\":\"lesson." + format.rawValue
                    + "\",\"design\":{\"columns\":2},\"slideCount\":3}\n```\n\n## Lesson\nComplete artifact body."
                let result = try OfficeDocumentService.completed(response, expected: format)
                check(result.content == response && result.body.contains("Complete artifact body.")
                    && result.meta.name == "lesson." + format.rawValue && result.meta.slideCount == 3
                    && result.meta.design?.columns == 2, format.rawValue + "-complete-metadata-preserved")
            }
            check(OfficeDocumentFormat.named("pdf") == nil, "pdf-keeps-counted-pipeline")
            for turn in [PlanTurnKind.auto, .execute(originID: "original-request")] {
                check(SendPipeline.officeFormat(for: .file(format: "docx", explicitPages: nil), product: .ai,
                    isTemporary: false, planTurn: turn, isRevision: false) == .docx, "auto-and-approved-office-route")
            }
            for turn in [PlanTurnKind.clarifyOrPlan, .forcedPlan, .revision] {
                check(SendPipeline.officeFormat(for: .file(format: "docx", explicitPages: nil), product: .ai,
                    isTemporary: false, planTurn: turn, isRevision: false) == nil, "planning-does-not-generate-file")
            }
            check(SendPipeline.officeFormat(for: .file(format: "xlsx", explicitPages: nil), product: .ai,
                isTemporary: false, planTurn: .revision, isRevision: true) == .xlsx, "actual-document-revision-routes-office")
            check(SendPipeline.officeFormat(for: .file(format: "pdf", explicitPages: nil), product: .ai,
                isTemporary: false, planTurn: .auto, isRevision: false) == nil, "counted-pdf-route-preserved")
            check(SendPipeline.officeFormat(for: .file(format: "docx", explicitPages: nil), product: .ai,
                isTemporary: true, planTurn: .auto, isRevision: false) == nil, "temporary-never-cloud-office")
            check(SendPipeline.officeFormat(for: .file(format: "docx", explicitPages: nil), product: .code,
                isTemporary: false, planTurn: .auto, isRevision: false) == nil, "code-not-misrouted-to-chat-office")
            rejects("no-truncated-source") { _ = try OfficeDocumentService.task(request: String(repeating: "ع", count: 60_001)) }
            rejects("utf16-limit-matches-server") { _ = try OfficeDocumentService.task(request: String(repeating: "🧮", count: 30_001)) }
            rejects("empty-body-refused") { _ = try OfficeDocumentService.completed("```firas-file\n{\"format\":\"docx\"}\n```") }
            rejects("wrong-format-refused") { _ = try OfficeDocumentService.completed("```firas-file\n{\"format\":\"pdf\"}\n```\nText", expected: .docx) }
            rejects("unfinished-fence-refused") { _ = try OfficeDocumentService.completed("```firas-file\n{\"format\":\"docx\"}") }
            rejects("html-as-image-refused") { _ = try OfficeDocumentService.normalizedImages([Data("<html>".utf8).base64EncodedString()]) }
            rejects("false-image-mime-refused") { _ = try OfficeDocumentService.normalizedImages(["data:image/jpeg;base64," + png]) }
            rejects("image-count-refused") { _ = try OfficeDocumentService.normalizedImages(Array(repeating: png, count: 11)) }
            rejects("no-upstream-image-url") { _ = try OfficeDocumentService.normalizedImages(["https://example.com/image.png"]) }
            let deck = """
            # This is the deck title, not a fourth slide
            ## القسم الأول
            ### First result
            Layout: comparison
            Col: Before | 10 observations
            Col: After | 12 observations
            Notes: NARRATION_ONLY — explain the evidence aloud.
            ### Second result
            Layout: stats
            Stat: 10 | observed before
            Stat: 12 | observed after
            """
            let slides = try ExportSlides.officeSlides(title: "Fixture", markdown: deck, expectedCount: 3, accent: "237A68")
            check(slides.count == 3 && slides.first?.title == "القسم الأول"
                && slides[1].layout == "comparison", "exact-slide-count-includes-dividers")
            check(slides[1].notes.contains("NARRATION_ONLY")
                && !slides.flatMap(\.lines).contains(where: { $0.contains("Layout:") || $0.contains("Notes:") || $0.contains("Col:") }),
                "authoring-controls-stay-off-slides")
            rejects("slide-count-mismatch-refused") {
                _ = try ExportSlides.officeSlides(title: "Fixture", markdown: deck, expectedCount: 4)
            }
            let pptx = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pptx")
            defer { try? FileManager.default.removeItem(at: pptx) }
            check(ExportSlides.write(title: "Fixture", slides: slides, to: pptx), "real-pptx-written")
            let archive = try Archive(url: pptx, accessMode: .read)
            let slideEntries = archive.filter { $0.path.range(of: #"^ppt/slides/slide[0-9]+\.xml$"#, options: .regularExpression) != nil }
            check(slideEntries.count == 3, "physical-pptx-slide-count")
            var hiddenNotes = ""
            for entry in archive where entry.path.hasSuffix(".xml") || entry.path.hasSuffix(".rels") {
                var data = Data()
                _ = try archive.extract(entry) { data.append($0) }
                check(XMLParser(data: data).parse(), "valid-xml-" + entry.path)
                let text = String(data: data, encoding: .utf8) ?? ""
                if entry.path.hasPrefix("ppt/slides/slide") {
                    check(!text.contains("NARRATION_ONLY") && !text.contains("Layout:"), "audience-xml-has-no-protocol")
                }
                if entry.path == "ppt/notesSlides/notesSlide2.xml" { hiddenNotes = text }
            }
            check(hiddenNotes.contains("NARRATION_ONLY"), "presenter-notes-are-real-ooxml")
        } catch { failures.append("office-document-fixture-threw") }
        return failures
    }
}
#endif
