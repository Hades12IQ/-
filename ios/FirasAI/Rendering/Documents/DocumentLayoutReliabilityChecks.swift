#if DEBUG
import Foundation
import PDFKit
import UIKit

@MainActor
enum DocumentLayoutReliabilityChecks {
    static func run() async -> (failures: [String], report: [String: Any]) {
        var failures: [String] = []
        let formulas = [
            #"\int_0^1\frac{\ln x}{1-x}\,dx=-\frac{\pi^2}{6}"#,
            #"\sum_{n=1}^{\infty}\frac1{n^4}=\frac{\pi^4}{90}"#,
            #"\int_0^{\pi/4}\ln(1+\tan x)\,dx=\frac{\pi\ln2}{8}"#,
            #"\zeta(s)=\frac1{\Gamma(s)}\int_0^{\infty}\frac{x^{s-1}}{e^x-1}\,dx"#,
            #"\Gamma(z)\Gamma(1-z)=\frac{\pi}{\sin(\pi z)}"#,
            #"\int_0^{\infty}\frac{\sin x}{x}\,dx=\frac\pi2"#,
            #"\sum_{n=1}^{\infty}\frac{(-1)^{n-1}}{n^2}=\frac{\pi^2}{12}"#,
            #"\int_0^{\infty}\frac{\ln x}{1+x^2}\,dx=0"#,
            #"\prod_p\frac1{1-p^{-s}}=\zeta(s)"#,
            #"\int_{-\infty}^{\infty}e^{-x^2}\,dx=\sqrt\pi"#
        ]
        var rows = ""
        for index in stride(from: 0, to: formulas.count, by: 3) {
            rows += "<tr>"
            for item in index..<min(index + 3, formulas.count) {
                rows += "<td><p>Equation \(item + 1)</p><div>$$" + formulas[item] + "$$</div></td>"
            }
            rows += "</tr>"
        }
        let source = """
        <!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><style>
        @page{size:A4;margin:20mm 18mm}body{font-size:13pt;line-height:1.8}
        main{padding:20px;background:#0d101b;color:#eceef5;border:2px solid #ceac39}
        h1{font-size:26pt;color:#ceac39}table{border-collapse:collapse;width:100%;table-layout:fixed}
        td,th{width:33.333%;border:1px solid #ceac39;padding:16px 8px}td{font-size:16pt}
        figure{margin:20px 0}figcaption{font-size:11pt}img{width:180px}
        </style></head><body><main><h1>معادلات ورسوم توضيحية</h1>
        <p>اختبار تصميم الملف: الصيغ تبقى كاملة، والصور الحقيقية والرسوم المتجهة مضمّنة.</p>
        <table><thead><tr><th colspan="3">Ten equations</th></tr></thead><tbody>\(rows)</tbody></table>
        <figure><img src="firas-asset:qa-image" alt="Two-colour test image"><figcaption>EMBEDDED-IMAGE-PRESENT</figcaption></figure>
        <figure><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 120" role="img"><title>Vector parabola</title><path d="M20 15V100H285" fill="none" stroke="#eeeeff"/><path d="M25 20 Q150 180 275 20" fill="none" stroke="#ceac39" stroke-width="3"/></svg><figcaption>VECTOR-FIGURE-PRESENT</figcaption></figure>
        <p>DOCUMENT-END-MARKER</p></main></body></html>
        """
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 120)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 120, y: 0, width: 120, height: 120))
        }
        let bytes = image.pngData() ?? Data()
        let embedded = DocumentHTML.embeddingImages(in: source, assets: ["qa-image": bytes])
        if embedded.contains("firas-asset:qa-image") || !embedded.contains("data:image/") {
            failures.append("Document image ID did not become an embedded real image")
        }
        if DocumentHTML.embeddingImages(in: source, assets: ["qa": bytes]) != source {
            failures.append("Document image substitution matched an ID prefix")
        }
        let printer = DocumentPrinter()
        guard let pdf = await printer.pdf(html: DocumentHTML.printable(authored: embedded)),
              let document = PDFDocument(data: pdf) else {
            return (["Content-aware document layout failed to export"] + failures, ["diagnostics": printer.diagnostics])
        }
        let text = document.string ?? ""
        for marker in ["EMBEDDED-IMAGE-PRESENT", "VECTOR-FIGURE-PRESENT", "DOCUMENT-END-MARKER"] where !text.contains(marker) {
            failures.append("Reflowed document lost a final figure or content marker")
        }
        if document.pageCount < 2 { failures.append("Ten readable equations unexpectedly fit in one page") }
        let layout: [String: Any] = (printer.diagnostics["layout"] as? [String: Any]) ?? Dictionary()
        if (layout["reflowedMathTables"] as? NSNumber)?.intValue != 1 {
            failures.append("The submitted PDF's narrow equation gallery was not reflowed")
        }
        let page: [String: Any] = (printer.diagnostics["page"] as? [String: Any]) ?? Dictionary()
        if (page["mathCount"] as? NSNumber)?.intValue != formulas.count || (page["mathErrors"] as? NSNumber)?.intValue != 0 {
            failures.append("A reflowed document equation was omitted or failed to typeset")
        }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = directory.appendingPathComponent("reliability-document-layout.pdf")
        do { try pdf.write(to: url, options: .atomic) }
        catch { failures.append("Could not save the document layout regression PDF") }
        let missing = DocumentPrinter()
        if await missing.pdf(html: DocumentHTML.printable(authored: source)) != nil {
            failures.append("An unresolved document image was silently exported as a blank slot")
        }
        return (failures, ["diagnostics": printer.diagnostics, "missingImageDiagnostics": missing.diagnostics,
                           "pageCount": document.pageCount, "pdfPath": url.path, "pdfBytes": pdf.count])
    }
}
#endif
