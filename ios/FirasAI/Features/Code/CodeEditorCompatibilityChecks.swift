#if DEBUG
import UIKit

@MainActor
enum CodeEditorCompatibilityChecks {
    static func run() -> [String] {
        let view = CodeUITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), textContainer: nil)
        view.text = "😀 let قيمة = 1\nlet VALUE = 2\nlet value = 3"
        var errors: [String] = []
        let source = (view.text ?? "") as NSString
        let first = source.range(of: "VALUE")
        let last = source.range(of: "value", options: .backwards)
        if !view.find(query: "value", forward: true, restart: true) || view.selectedRange != first {
            errors.append("Code legacy find lost a case-insensitive match after Unicode text")
        }
        if !view.find(query: "value", forward: true) || view.selectedRange != last {
            errors.append("Code legacy find did not move to the next match")
        }
        if !view.find(query: "value", forward: true) || view.selectedRange != first {
            errors.append("Code legacy find did not wrap forward")
        }
        if !view.find(query: "value", forward: false) || view.selectedRange != last {
            errors.append("Code legacy find did not wrap backward")
        }
        let selection = view.selectedRange
        if view.find(query: "missing-token", forward: true) || view.selectedRange != selection || view.text != (source as String) {
            errors.append("Code legacy find mutated code or selection for a missing match")
        }
        return errors
    }
}
#endif
