#if DEBUG
import Foundation

enum MathScannerReliabilityChecks {
    static func failures() -> [String] {
        var errors: [String] = []
        let bare = "dv = cotθ dθ ⇒ v = ln(sinθ)"
        let runs = MathScanner.spans(in: bare)
        if runs.count != 1 || runs.first?.raw != bare || runs.first?.isRecovered != true {
            errors.append("Undelimited differential/log chain was not recovered as one original span")
        }
        if let tex = runs.first?.tex,
           !tex.contains("\\cot") || !tex.contains("\\theta") || !tex.contains("\\ln") || !tex.contains("\\Rightarrow") {
            errors.append("Recovered Greek/function notation was not normalized for KaTeX")
        }
        let mixed = "بالتعويض: π/4 ln(sin(π/4)) = π/4 ln(1/(√2)) = -π/8\nln2. وهنا ننتهي."
        let mixedRuns = MathScanner.spans(in: mixed)
        if mixedRuns.count != 2 || mixedRuns.last?.raw != "ln2"
            || mixedRuns.first?.tex.contains("\\sqrt{2}") != true {
            errors.append("Mixed Arabic/Unicode logarithm derivation lost its math/prose boundaries")
        }
        for (index, source) in [bare, mixed, "المعادلة E=mc² هنا.", "The solution is x=2."].enumerated() {
            let protected = MathScanner.protect(source)
            if MathScanner.restore(protected.text, spans: protected.spans) != source {
                errors.append("Recovery changed source/copy text in fixture \(index)")
            }
        }
        let nonMath = [
            "Tea is $5 and coffee is $3.", "USD 50; total 20/30.", "The sin tax is a policy. Minimum and maximum are words.",
            "```swift\nlet x=2\n// E=mc²\n```", "```text\ndv = cotθ dθ", "`E=mc²`", "`x=2",
            "https://example.test/search?x=2&math=sin2", "www.example.test/q?x=2", "HTTPS://example.test/q?x=2", "[Open](relative?x=2)", "ordinary English and العربية Ελληνικά"
        ]
        for (index, source) in nonMath.enumerated() where !MathScanner.spans(in: source).isEmpty {
            errors.append("Recovery converted prose/currency/code/URL fixture \(index)")
        }
        let complete = #"$$\frac{\pi}{4}\ln\left(\sin\frac{\pi}{4}\right)=\frac{\pi}{4}\ln\frac{1}{\sqrt2}=-\frac{\pi}{8}\ln2$$"#
        if MathScanner.spans(in: complete).count != 1 || MathScanner.streamingPreview(complete) != complete {
            errors.append("Long properly delimited equation was altered or split")
        }
        let previews: [(String, String)] = [
            (#"Result $x^"#, #"Result $x$"#),
            (#"Result $x^\fr"#, #"Result $x$"#),
            (#"$$\frac{"#, #"$$\frac{}{}$$"#),
            (#"$$\frac{1}{"#, #"$$\frac{1}{}$$"#),
            (#"\[\int_0^{\pi"#, #"\[\int_0^{\pi}\]"#),
            (#"\(x + \fr"#, #"\(x +\)"#),
            (#"$$\sqrt"#, #"$$\sqrt{}$$"#),
            (#"$\ce{NaOH}"#, #"$\ce{NaOH}$"#),
            (#"$\ce{H2SO4"#, #"$\ce{H2SO4}$"#),
            (#"\(\pu{2.5 mol/L}"#, #"\(\pu{2.5 mol/L}\)"#),
            (#"$$\begin{aligned}a&=1\\b&=2"#, #"$$\begin{aligned}a&=1\\b&=2\end{aligned}$$"#)
        ]
        for (index, fixture) in previews.enumerated() {
            let preview = MathScanner.streamingPreview(fixture.0)
            if preview != fixture.1 { errors.append("Incomplete math preview fixture \(index) failed") }
            if MathScanner.spans(in: preview).count != 1 { errors.append("Math preview fixture \(index) did not yield one renderable span") }
        }
        let unchanged = ["The cost is $5", "Pay $50.00", "```tex\n$$\\frac{", "`$x^", #"Arabic $شرح عادي"#, "ordinary prose"]
        for (index, source) in unchanged.enumerated() where MathScanner.streamingPreview(source) != source {
            errors.append("Streaming preview changed currency/code/prose fixture \(index)")
        }
        if MathScanner.spans(in: #"A literal price $5 then \(x^2\)"#).count != 1 {
            errors.append("A literal currency symbol hid later bracket math")
        }
        if MathScanner.spans(in: #"[$x^2$](relative?x=2)"#).count != 1 {
            errors.append("Link destination protection hid its mathematical label")
        }
        return errors
    }
}
#endif
