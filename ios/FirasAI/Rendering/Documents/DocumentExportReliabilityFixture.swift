#if DEBUG
import Foundation

/// A deterministic stress document for the reported 100-item request. It exercises the real
/// card/export flow; it does not claim to measure a paid model's problem-generation quality.
enum DocumentExportReliabilityFixture {
    static let request = "اصنعلي ملف pdf احترافي وقوي يكون بي 100 تكامل رياضيات صعب جدا بدون تكرار ويكون كلشي انكليزي واريده ملف قوي حرفيا كل 3 تكاملات اريدها مرتبة ب3 اسطر و بعد الانتهاء اريد حلول التكاملات كلها بالنهاية ومرتبة ايضا وكلشي مرقم اريد وقوي واحترافي و الخط مكبر"

    static var expectedMarkers: [String] {
        (1...100).flatMap { [String(format: "PROBLEM-%03d", $0), String(format: "SOLUTION-%03d", $0)] }
            + ["INTEGRALS-DOCUMENT-END"]
    }

    static var markdown: String {
        var questions = "", solutions = ""
        for number in 1...100 {
            // Distinct parameters with an exact Gamma identity keep the fixture internally valid.
            let tex = #"\int_0^{\infty}x^{"# + String(number) + #"}e^{-2x}\,dx"#
            let answer = #"\frac{\Gamma("# + String(number + 1) + #")}{2^{"# + String(number + 1) + "}}"
            questions += "<section class='problem' data-firas-item='\(number)'><p>"
                + String(format: "PROBLEM-%03d", number) + "</p><p><span>$" + tex + "$</span></p></section>"
            solutions += "<section data-firas-solution='\(number)'><p>"
                + String(format: "SOLUTION-%03d", number)
                + "</p><p>Using the Gamma integral with the substitution t = 2x, <span>$"
                + tex + "=" + answer + "$</span>.</p></section>"
        }
        return """
        ```firas-file
        {"format":"pdf","filename":"advanced_integrals_collection.pdf","title":"100 Integrals"}
        ```
        ```html
        <!doctype html><html lang="en"><head><meta charset="utf-8"><style>
        @page{size:A4;margin:20mm 18mm}body{font-size:14pt;line-height:1.55;color:#14242a}
        .book{width:210mm;padding:12mm;background:white}.problems{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
        section{break-inside:avoid;border-bottom:1px solid #d5e0e2;padding-bottom:6pt;margin-bottom:12pt}
        h1{font-size:26pt}h2{font-size:21pt;break-before:page}.problem span{font-size:18pt}
        </style></head><body><div class="book"><h1>100 Integrals</h1>
        <p>Full document export regression: problems first, complete answer key last.</p>
        <div class="problems">\(questions)</div><h2>Solutions</h2>\(solutions)
        <p>INTEGRALS-DOCUMENT-END</p></div></body></html>
        ```
        """
    }
}
#endif
