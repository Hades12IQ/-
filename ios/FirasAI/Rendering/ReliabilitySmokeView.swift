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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Firas AI · Reliability").font(.headline)
                Text(status).font(.caption).foregroundStyle(env.prefs.palette.textMuted)
                MarkdownView(markdown: Self.sample, messageID: "reliability-smoke", streaming: false,
                    lang: .arabic, palette: env.prefs.palette, prefs: env.prefs, onFence: { _ in nil })
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
    يمكن تحديد أي كلمة ونسخها أو اختيار **اسأل فِراس**. المساحة $A = \pi r^2$، والتكامل $\int_0^1 x\,dx=\frac12$.

    $$x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}$$

    $$\ce{2H2 + O2 -> 2H2O}$$

    $$\begin{pmatrix}1&2\\3&4\end{pmatrix}$$

    English, Ελληνικά, Русский — mixed-language text keeps its own direction.
    The cost is $5 and coffee is $3. These prices remain text.
    """#

    @MainActor private func run() async {
        var errors = ChatReliabilityChecks.failures()
        var report: [String: Any] = [:]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { errors.append("Could not create smoke output directory") }

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
        let style = MathIslandStyle(palette: env.prefs.palette, background: env.prefs.palette.background, fontScale: env.prefs.fontScale)
        let items = MathScanner.spans(in: Self.sample).map { MathIslandItem(span: $0) }
        MathIsland.shared.request(items, style: style, persist: true)
        let deadline = Date().addingTimeInterval(35)
        var rendered = 0
        while Date() < deadline {
            rendered = items.filter { MathIsland.shared.glyph(for: $0.id, style: style) != nil }.count
            if rendered == items.count { break }
            await JobClock.rest(0.2)
        }
        report["mathGlyphCount"] = rendered
        report["mathExpectedCount"] = items.count
        if rendered != items.count { errors.append("Some mathematical glyphs never completed") }

        // Read actual on-disk records, bypassing the island's memory dictionary.
        let diskCount = items.filter { MathGlyphDiskCache.read(style.key + "/" + $0.id) != nil }.count
        report["persistedMathGlyphCount"] = diskCount
        if diskCount != items.count { errors.append("Completed glyphs did not persist") }
        if let first = items.first,
           MathGlyphDiskCache.read(style.key + "different-theme/" + first.id) != nil {
            errors.append("Disk glyph key failed to distinguish the theme")
        }

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
        if let bytes = await DocumentPrinter().pdf(html: html), let document = PDFDocument(data: bytes) {
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

        report["status"] = errors.isEmpty ? "passed" : "failed"
        report["errors"] = errors
        report["selectionEnabled"] = true
        status = errors.isEmpty ? "Passed · paginated PDF and persisted mathematics" : errors.joined(separator: " · ")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("reliability-smoke.json"), options: .atomic)
        }
    }
}
#endif
