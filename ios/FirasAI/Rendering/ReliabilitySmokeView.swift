#if DEBUG
import Foundation
import PDFKit
import SwiftUI
import UIKit

/// Local, unauthenticated simulator evidence. Only reachable with --reliability-smoke in DEBUG.
struct ReliabilitySmokeView: View {
    let env: AppEnvironment
    @State private var ran = false
    @State private var status = "Checking document pagination and mathematical rendering…"
    @State private var selection = FirasTextSelection()
    @State private var showMath = false
    @State private var liveSource = ""
    @State private var liveFinished = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Firas AI · Reliability").font(.headline)
                Text(status).font(.caption).foregroundStyle(env.prefs.palette.textMuted)
                if showMath {
                    StreamingText(text: liveSource, isStreaming: !liveFinished, motionOn: true,
                        identity: "live-math-smoke") { shown in
                        MarkdownView(markdown: shown, messageID: "live-math-smoke", streaming: !liveFinished,
                            lang: .arabic, palette: env.prefs.palette, prefs: env.prefs, onFence: { _ in nil })
                    }
                    MarkdownView(markdown: Self.sample, messageID: "reliability-smoke", streaming: false,
                        lang: .arabic, palette: env.prefs.palette, prefs: env.prefs, onFence: { _ in nil })
                }
            }
            .padding(20)
        }
        .background(env.prefs.palette.background)
        .foregroundStyle(env.prefs.palette.textPrimary)
        .environment(\.firasTextSelection, selection)
        .task {
            guard !ran else { return }
            ran = true
            await run()
        }
    }

    private static let sample = #"""
    ## رياضيات واضحة وثابتة
    $dv = \cot\theta\,d\theta \Rightarrow v=\ln(\sin\theta)$

    عند التعويض: $\frac{\pi}{4}\ln(\sin(\pi/4))=\frac{\pi}{4}\ln(1/\sqrt{2})=-\frac{\pi}{8}\ln2$.

    dv = cotθ dθ ⇒ v = ln(sinθ)

    يمكن تحديد أي كلمة ونسخها أو اختيار **اسأل فِراس**. المساحة $A = \pi r^2$، والتكامل $\int_0^1 x\,dx=\frac12$.

    $$x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}$$

    $$\ce{2H2 + O2 -> 2H2O}$$

    $$\begin{pmatrix}1&2\\3&4\end{pmatrix}$$

    English, Ελληνικά, Русский — mixed-language text keeps its own direction.
    The cost is $5 and coffee is $3. These prices remain text.
    """#

    @MainActor private func checkLiveMath(directory: URL) async -> RenderingPerformanceChecks.Result {
        var failures: [String] = []
        var metrics: [String: Double] = [:]
        let style = MathIslandStyle(palette: env.prefs.palette, background: env.prefs.palette.background, fontScale: env.prefs.fontScale)
        failures += MathIsland.previewReliabilityFailures(style: style)
        let open = #"الحل $z^{17}$ ثم $\frac{47}{83}"#
        let initial = MathScanner.spans(in: MathScanner.streamingPreview(open))
        guard initial.count == 2 else { return .init(failures: ["Live fixture did not contain both expressions"], metrics: [:]) }
        let start = Date()
        liveSource = open
        while Date().timeIntervalSince(start) < 35 {
            if initial.allSatisfy({ MathIsland.shared.peekForReliability($0.id, style: style) != nil }) { break }
            await JobClock.rest(0.1)
        }
        metrics["initialMathMilliseconds"] = Date().timeIntervalSince(start) * 1000
        let settled = MathIsland.shared.peekForReliability(initial[0].id, style: style)
        if settled == nil || MathIsland.shared.peekForReliability(initial[1].id, style: style) == nil {
            failures.append("Mounted streaming view did not draw mathematics before its closing delimiter")
        }
        await MathGlyphDiskCache.flushPendingWrites()
        if MathGlyphDiskCache.readPersisted(style.key + "/" + initial[1].id) != nil {
            failures.append("A synthetic live preview was persisted as a completed expression")
        }
        saveScreen(directory.appendingPathComponent("streaming-math.png"))
        liveSource = open + #" + \theta"#
        guard let grown = MathScanner.spans(in: MathScanner.streamingPreview(liveSource)).last else {
            return .init(failures: failures + ["Growing preview disappeared from scanner"], metrics: metrics)
        }
        let growingStart = Date()
        while Date().timeIntervalSince(growingStart) < 20 {
            if let settled, MathIsland.shared.peekForReliability(initial[0].id, style: style)?.image !== settled.image {
                failures.append("Completed equation changed while another equation streamed"); break
            }
            if MathIsland.shared.peekForReliability(grown.id, style: style) != nil { break }
            await JobClock.rest(0.1)
        }
        if MathIsland.shared.peekForReliability(grown.id, style: style) == nil {
            failures.append("Mounted view failed to update its unfinished formula")
        }
        liveSource += "$ ثم يستمر الشرح."
        let promotionDeadline = Date().addingTimeInterval(5)
        while Date() < promotionDeadline {
            await JobClock.rest(0.1)
            await MathGlyphDiskCache.flushPendingWrites()
            if MathGlyphDiskCache.readPersisted(style.key + "/" + grown.id) != nil { break }
        }
        if MathGlyphDiskCache.readPersisted(style.key + "/" + grown.id) == nil {
            failures.append("Completed live formula was not persisted while the answer continued")
        }
        liveFinished = true
        metrics["completedFormulaStayedStable"] = failures.contains(where: { $0.contains("Completed equation changed") }) ? 0 : 1
        metrics["renderedBeforeDelimiter"] = MathIsland.shared.peekForReliability(initial[1].id, style: style) == nil ? 0 : 1
        return .init(failures: failures, metrics: metrics)
    }

    @MainActor private func saveScreen(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: \.isKeyWindow) else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let bytes = renderer.pngData { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try? bytes.write(to: url, options: .atomic)
    }

    @MainActor private func run() async {
        var errors = ChatReliabilityChecks.failures()
        errors += await CodeReliabilityChecks.failures()
        var report: [String: Any] = [:]
        errors += MathScannerReliabilityChecks.failures()
        errors += DocumentRevisionChecks.failures()
        errors += await DocumentAssetCache.reliabilityFailures()
        let streamChecks = StreamPerformanceChecks.run()
        errors += streamChecks.failures
        report["streamPerformance"] = streamChecks.metrics
        let cacheChecks = await MathCachePerformanceChecks.run()
        errors += cacheChecks.failures
        report["cachePerformance"] = cacheChecks.metrics
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { errors.append("Could not create smoke output directory") }
        let viewerChecks = await MediaViewerReliabilityChecks.run(env: env)
        errors += viewerChecks.failures
        report["mediaViewer"] = viewerChecks.metrics
        showMath = true
        let liveChecks = await checkLiveMath(directory: directory)
        errors += liveChecks.failures
        report["liveMath"] = liveChecks.metrics

        let selectable = SelectableTextView()
        selectable.isEditable = false
        selectable.isSelectable = true
        let selectionSource = "هذه كلمة مختارة داخل شرح English، دون نسخ الفقرة كلها."
        selectable.attributedText = NSAttributedString(string: selectionSource)
        let wordRange = (selectionSource as NSString).range(of: "مختارة")
        selectable.selectedRange = wordRange
        let selectedWord = selectable.selectedPlainText(wordRange)
        if selectedWord != "مختارة" { errors.append("Native text selection did not preserve the selected Arabic word") }
        selectable.copy(nil)
        if UIPasteboard.general.string != "مختارة" { errors.append("Copy used the whole answer instead of the selected word") }
        let coordinator = FirasSelectableText.Coordinator()
        coordinator.selection = selection
        coordinator.lang = .arabic
        let menu = coordinator.textView(selectable, editMenuForTextIn: wordRange, suggestedActions: [])
        let hasAskAction = menu?.children.contains { ($0 as? UIAction)?.title == "اسأل فِراس" } == true
        if !hasAskAction { errors.append("Native selection menu is missing Ask Firas") }
        selection.ask(selectedWord)
        if selection.request?.text != selectedWord { errors.append("Ask Firas lost the selected quotation") }
        let attachmentText = NSMutableAttributedString(string: "القيمة \u{FFFC}")
        attachmentText.addAttribute(NSAttributedString.Key("firasCopyText"), value: "x²",
            range: NSRange(location: attachmentText.length - 1, length: 1))
        selectable.attributedText = attachmentText
        if selectable.selectedPlainText(NSRange(location: 0, length: attachmentText.length)) != "القيمة x²" {
            errors.append("Copy lost the mathematical attachment's text")
        }
        report["nativeWordSelection"] = selectedWord == "مختارة"
        report["nativeAskMenu"] = hasAskAction

        let fixtures: [(String, Int)] = [
            (#"التكلفة $ ثم $x^2$ و $\int_0^1 x\,dx=\frac12$ و $$e^{i\pi}+1=0$$"#, 3),
            ("Tea is $5 and coffee is $3.", 0),
            (#"`$x$` and $y$"#, 1),
            (#"$$\ce{CuSO4 . 5H2O}$$"#, 1),
            (#"$$\frac{1}{"#, 0)
        ]
        for (index, fixture) in fixtures.enumerated() {
            if MathScanner.spans(in: fixture.0).count != fixture.1 { errors.append("Math scanner fixture \(index) failed") }
        }
        let completeHTML = "<!doctype html><html><body><p>Finished</p></body></html>"
        let completeWithoutFence = "```html\n" + completeHTML
        let incompleteWithFence = "```html\n<!doctype html><html><body><p>Unfinished\n```"
        if DocumentHTML.authored(in: completeWithoutFence) == nil {
            errors.append("A complete HTML document lost only its closing fence")
        }
        if !DocumentHTML.hasIncompleteAuthoredDocument(in: incompleteWithFence)
            || DocumentHTML.authored(in: incompleteWithFence) != nil {
            errors.append("A truncated designed document was accepted for export")
        }
        if DocumentHTML.hasIncompleteAuthoredDocument(in: "Ordinary transcript with $x^2$.") {
            errors.append("Ordinary transcript was mistaken for an incomplete document")
        }
        let style = MathIslandStyle(palette: env.prefs.palette, background: env.prefs.palette.background, fontScale: env.prefs.fontScale)
        let items = MathScanner.spans(in: Self.sample).map { MathIslandItem(span: $0) }
        let deadline = Date().addingTimeInterval(35)
        var rendered = 0
        while Date() < deadline {
            rendered = items.filter { MathIsland.shared.peekForReliability($0.id, style: style) != nil }.count
            if rendered == items.count { break }
            await JobClock.rest(0.2)
        }
        report["mathGlyphCount"] = rendered
        report["mathExpectedCount"] = items.count
        if rendered != items.count { errors.append("Some mathematical glyphs never completed") }

        // Read actual on-disk records, bypassing the island's memory dictionary.
        await MathGlyphDiskCache.flushPendingWrites()
        let diskCount = items.filter { MathGlyphDiskCache.readPersisted(style.key + "/" + $0.id) != nil }.count
        report["persistedMathGlyphCount"] = diskCount
        if diskCount != items.count { errors.append("Completed glyphs did not persist") }
        if let first = items.first,
           MathGlyphDiskCache.readPersisted(style.key + "different-theme/" + first.id) != nil {
            errors.append("Disk glyph key failed to distinguish the theme")
        }
        let wideChecks = RenderingPerformanceChecks.run(sample: Self.sample, style: style,
            palette: env.prefs.palette, pointSize: 17 * env.prefs.fontScale.factor)
        errors += wideChecks.failures
        report["renderingPerformance"] = wideChecks.metrics

        var table = "<table><thead><tr><th>السطر</th><th>المحتوى</th></tr></thead><tbody>"
        for row in 1...100 {
            table += "<tr><td>\(row)</td><td>هذا سطر عربي قابل للقراءة. Physics: $E=mc^2$.</td></tr>"
        }
        table += "</tbody></table>"
        let authored = #"""
        <!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
        <style>@page{size:A4;margin:20mm 18mm}body{font-family:'Firas Document Arabic','Firas Document Sans',sans-serif;font-size:13pt;line-height:1.8;color:#17202a}h1{font-size:24pt}h2{font-size:17pt}table{width:100%;border-collapse:collapse}td,th{padding:6pt;border:1px solid #bac2c9}th{background:#e8edf0}p{margin:0 0 12pt}</style></head><body>
        <h1>اختبار مستند طويل</h1><p>هذا الملف يفحص تقسيم الصفحات، الهوامش، الخط العربي والمعادلات.</p>
        <p>$$\frac{-b\pm\sqrt{b^2-4ac}}{2a}$$</p>
        <p>$$\ce{2H2 + O2 -> 2H2O}$$</p>
        <h2 dir="ltr">Scientific results</h2>
        """# + table + "<p dir='ltr'>FIRAS-END-MARKER-9427</p></body></html>"
        let html = DocumentHTML.printable(authored: authored)
        if !html.contains("data:font/ttf;base64,") { errors.append("Bundled document fonts are missing") }
        let printer = DocumentPrinter()
        let pdfBytes = await printer.pdf(html: html)
        report["pdfDiagnostics"] = printer.diagnostics
        if let bytes = pdfBytes, let document = PDFDocument(data: bytes) {
            let output = directory.appendingPathComponent("reliability-long-arabic.pdf")
            do { try bytes.write(to: output, options: .atomic) }
            catch { errors.append("Could not write PDF evidence") }
            report["pdfPath"] = output.path
            report["pdfPageCount"] = document.pageCount
            report["pdfBytes"] = bytes.count
            if document.pageCount < 2 { errors.append("Long document was not paginated") }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { errors.append("Missing PDF page"); continue }
                let box = page.bounds(for: .mediaBox)
                if abs(box.width - 595.28) > 2 || abs(box.height - 841.89) > 2 {
                    errors.append("PDF page \(index + 1) is not physical A4")
                }
            }
            if document.string?.contains("FIRAS-END-MARKER-9427") != true {
                errors.append("The PDF lost its final paragraph")
            }
        } else { errors.append("Native PDF printer failed") }

        let documentChecks = await DocumentLayoutReliabilityChecks.run()
        errors += documentChecks.failures
        report["documentLayout"] = documentChecks.report
        report["status"] = errors.isEmpty ? "passed" : "failed"
        report["errors"] = errors
        status = errors.isEmpty ? "Passed · paginated PDF and persisted mathematics" : errors.joined(separator: " · ")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("reliability-smoke.json"), options: .atomic)
        }
    }
}
#endif
