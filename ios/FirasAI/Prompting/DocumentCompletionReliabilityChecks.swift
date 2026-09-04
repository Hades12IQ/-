#if DEBUG
import Foundation

@MainActor
enum DocumentCompletionReliabilityChecks {
    static let exactRequest = "اصنعلي ملف pdf احترافي وقوي يكون بي 100 تكامل رياضيات صعب جدا بدون تكرار ويكون كلشي انكليزي واريده ملف قوي حرفيا كل 3 تكاملات اريدها مرتبة ب3 اسطر و بعد الانتهاء اريد حلول التكاملات كلها بالنهاية ومرتبة ايضا وكلشي مرقم اريد وقوي واحترافي و الخط مكبر"

    static func failures() -> [String] {
        var failures: [String] = []
        func expect(_ passes: Bool, _ message: String) {
            if !passes { failures.append(message) }
        }
        let request = DocumentItemRequest.parse(exactRequest)
        expect(request?.count == 100 && request?.requiresSolutions == true && request?.solutionsAtEnd == true,
            "Exact Arabic 100-integral request lost its content count or final solutions")
        expect(RequestClassifier.parseExplicitPageCount(exactRequest) == nil,
            "Item/line counts were mistaken for a requested page count")
        expect(RequestClassifier.classify(exactRequest, hasImages: false, lang: .arabic) == .file(format: "pdf", explicitPages: nil),
            "Exact integral document request stopped selecting PDF")
        let parserFixtures: [(String, Int?, Bool)] = [
            ("Create a PDF with 100 very difficult unique integrals, every 3 integrals on 3 lines, with solutions at the end.", 100, true),
            ("اصنع ملف فيه ١٠٠ تكامل مع الحلول كل ٣ تكاملات بثلاثة أسطر", 100, true),
            ("Make a PDF with ۱۰۰ integrals without solutions.", 100, false),
            ("Make a 100-page PDF, three items per row", nil, false),
            ("Make a PDF about mathematics in 2026 with a 14pt font", nil, false),
            ("Arrange every 3 integrals on separate lines", nil, false),
            ("Make 50 integrals and 20 equations", nil, false),
            ("Explain problem 100 and equation 3", nil, false)
        ]
        for (text, count, solutions) in parserFixtures {
            let parsed = DocumentItemRequest.parse(text)
            expect(parsed?.count == count && (parsed?.requiresSolutions ?? false) == solutions,
                "Document quantity parser misread fixture: " + text)
        }

        func html(_ body: String) -> String { "<!DOCTYPE html><html><head><title>Fixture</title></head><body>" + body + "</body></html>" }
        func item(_ n: Int, _ text: String? = nil) -> String {
            "<div data-firas-item=\"\(n)\"><b>\(n).</b> " + (text ?? "$$\\int x^{\(n)}\\,dx$$") + "</div>"
        }
        func solution(_ n: Int) -> String {
            "<div data-firas-solution=\"\(n)\"><b>\(n).</b> $$\\frac{x^{\(n + 1)}}{\(n + 1)}+C$$</div>"
        }
        let items = (1...100).map { item($0) }.joined()
        let solutions = (1...100).map { solution($0) }.joined()
        let complete = html(items + "<h2>Solutions</h2>" + solutions)
        let good = DocumentCompletionChecks.validate(markdown: complete, request: exactRequest)
        expect(good.isVerified && good.itemCount == 100 && good.solutionCount == 100,
            "Complete actual 100-item/100-solution source was rejected")
        let cases: [(String, String)] = [
            (html((1...99).map { item($0) }.joined() + solutions), "missing final problem"),
            (html(items + (1...99).map { solution($0) }.joined()), "missing final solution"),
            (html(items + item(1) + solutions), "duplicate item ID"),
            (html(item(2) + item(1) + (3...100).map { item($0) }.joined() + solutions), "out-of-order item IDs"),
            (html(items + solution(2) + solution(1) + (3...100).map { solution($0) }.joined()), "out-of-order solution IDs"),
            (html((1...99).map { item($0) }.joined() + item(100, "$$\\int x^{1}\\,dx$$") + solutions), "repeated actual statement"),
            (html((1...99).map { item($0) }.joined() + item(100, "TODO") + solutions), "placeholder statement"),
            (html((1...99).map { item($0) }.joined() + "<p data-firas-item=\"100\">100.</p>" + solutions), "empty statement behind number"),
            (html(solutions + items), "solutions before problems"),
            (html("<!--" + items + "--><script>" + solutions + "</script><p>100 completed items</p>"), "comment/script metadata claim"),
            (html("<section hidden>" + items + solutions + "</section>"), "hidden source items"),
            ("```firas-file\n{\"filename\":\"100-integrals\",\"title\":\"100 problems and solutions\"}\n```", "metadata-only document")
        ]
        for (source, label) in cases {
            let result = DocumentCompletionChecks.validate(markdown: source, request: exactRequest)
            expect(!result.isComplete && result.message(lang: .english) != nil,
                "Count completion accepted " + label)
        }
        expect(DocumentCompletionChecks.validate(markdown: "A short report", request: "Make a PDF about mathematics").isComplete,
            "Uncounted legacy PDF was blocked by an unrelated completeness gate")
        let cssNumbered = html("<style>.problem:before{counter-increment:p;content:counter(p)}</style>"
            + "<div class=\"problem\">$$\\int x\\,dx$$</div><div class=\"problem\">$$\\int x^2\\,dx$$</div>")
        let unknown = DocumentCompletionChecks.validate(markdown: cssNumbered, request: "Create 2 integrals in a PDF")
        expect(unknown.isComplete && !unknown.verificationAvailable && !unknown.isVerified,
            "Legacy CSS numbering was blocked or falsely reported as verified")
        let legacy = html("<h1>Problems</h1><ol><li>$$\\int x\\,dx$$</li><li>$$\\int x^2\\,dx$$</li></ol>"
            + "<h2>Solutions</h2><ol><li>$$x^2/2+C$$</li><li>$$x^3/3+C$$</li></ol>")
        expect(DocumentCompletionChecks.validate(markdown: legacy, request: "Create 2 integrals with solutions at the end in a PDF").isComplete,
            "Legacy numbered HTML problem/solution lists were rejected")
        let headings = html("<h3>Problem 1</h3><p>$$\\int x\\,dx$$</p><h3>Problem 2</h3><p>$$\\int x^2\\,dx$$</p>"
            + "<h2>Solutions</h2><h3>Solution 1</h3><p>$$x^2/2+C$$</p><h3>Solution 2</h3><p>$$x^3/3+C$$</p>")
        expect(DocumentCompletionChecks.validate(markdown: headings, request: "Create 2 integrals with solutions at the end in a PDF").isComplete,
            "Legacy numbered headings lost their following statement content")
        let repeatedLabel = html("<p data-firas-item=\"1\">Integral #1: $$\\int x\\,dx$$</p>"
            + "<p data-firas-item=\"2\">Problem-002: $$\\int x\\,dx$$</p>")
        expect(!DocumentCompletionChecks.validate(markdown: repeatedLabel, request: "Create 2 integrals in a PDF").isComplete,
            "Alternate item-label spelling concealed a duplicate statement")
        let parameters = html("<p data-firas-item=\"1\">1.5x + C</p><p data-firas-item=\"2\">2.5x + C</p>")
        expect(DocumentCompletionChecks.validate(markdown: parameters, request: "Create 2 equations in a PDF").isComplete,
            "Duplicate normalization erased a mathematical decimal parameter")
        let envelope = "```firas-file\n{\"filename\":\"collection\",\"title\":\"Integrals\"}\n```\n" + complete
        expect(DocumentHTML.authored(in: envelope) == complete && DocumentCompletionChecks.validate(markdown: envelope, request: exactRequest).isComplete,
            "Metadata followed by a bare HTML document lost its authored body")
        let crlfEnvelope = envelope.replacingOccurrences(of: "\n", with: "\r\n")
        expect(DocumentHTML.bareAuthoredCandidate(in: crlfEnvelope) == complete,
            "CRLF file envelope lost its exact bare HTML source")
        let crlfFence = "```html\r\n" + complete + "\r\n```"
        expect(DocumentHTML.authored(in: crlfFence)?.trimmingCharacters(in: .whitespacesAndNewlines) == complete,
            "CRLF HTML fence was not recognized as a complete document")
        expect(DocumentHTML.hasIncompleteAuthoredDocument(in: envelope.replacingOccurrences(of: "</html>", with: "")),
            "Truncated bare HTML after metadata was treated as complete")
        expect(DocumentHTML.authored(in: "Example code follows:\n" + complete) == nil,
            "Ordinary prose was searched for quoted HTML as a document")

        let user = ChatMessage(role: .user, content: exactRequest, cid: "counted-pdf-fixture")
        let input = PromptInput(tier: .pro, product: .ai, mode: .auto, lang: .arabic, thinkToggle: false,
            kind: .file(format: "pdf", explicitPages: nil), planTurn: .auto, askRounds: 0,
            searchContext: nil, searchWasEmpty: false, history: [], lastUser: user, reattachImages: nil)
        let prompt = PromptBuilder.build(input).messages.map(\.content).joined(separator: "\n")
        expect(prompt.contains("data-firas-item") && prompt.contains("data-firas-solution") && prompt.contains("ALL 100 matching worked solutions") && prompt.contains(exactRequest),
            "Actual PDF request omitted exact-count/source-completion instructions")
        expect(!prompt.contains("THIS TURN IS A PROBLEM-LIST REQUEST"),
            "PDF with solutions activated the problem-only short-answer contract")
        return failures
    }
}
#endif
