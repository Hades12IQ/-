#if DEBUG
import Foundation
import QuartzCore
import SwiftUI
import UIKit

@MainActor
enum RenderingPerformanceChecks {
    struct Result {
        let failures: [String]
        let metrics: [String: Double]
    }

    static func run(sample: String, style: MathIslandStyle, palette: FirasPalette,
                    pointSize: CGFloat) -> Result {
        var failures: [String] = []
        var metrics: [String: Double] = [:]
        let source = MarkdownInline.attributed(sample, lang: .arabic, palette: palette)
        var glyphs: [String: MathGlyph] = [:]
        for span in MathScanner.spans(in: sample) {
            if let glyph = MathIsland.shared.peekForReliability(span.id, style: style) { glyphs[span.id] = glyph }
        }
        let wideCount = glyphs.values.filter { $0.size.width > 240 }.count
        metrics["glyphsWiderThanOldCutoff"] = Double(wideCount)
        if wideCount == 0 { failures.append("Wide equation fixture never exceeded the former 240pt cutoff") }
        let view = FirasSelectableText(source: source, glyphs: glyphs, pointSize: pointSize,
            semibold: false, lineSpacing: 5, palette: palette, lang: .arabic)
        for width: CGFloat in [280, 390, 600] {
            let output = view.attributedText(maximumMathWidth: width)
            var attachments = 0
            output.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.length)) { value, _, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                attachments += 1
                if attachment.bounds.width > width || attachment.bounds.height <= 0 {
                    failures.append("Mathematical attachment exceeded its text container at \(width)pt")
                }
            }
            if attachments != MathScanner.spans(in: sample).count {
                failures.append("A rendered equation fell back to plain text at \(width)pt")
            }
            metrics["attachmentsAt\(Int(width))pt"] = Double(attachments)
        }

        let id = "parser-performance-evidence"
        let first = MarkdownRenderer.blocks(for: "First $x^2$\n\nSecond", messageID: id, streaming: true, lang: .english)
        let next = MarkdownRenderer.blocks(for: "First $x^2$\n\nSecond paragraph", messageID: id, streaming: true, lang: .english)
        let final = MarkdownRenderer.blocks(for: next.source, messageID: id, streaming: false, lang: .english)
        if first.rows.map(\.id) != next.rows.map(\.id) || next.rows.map(\.id) != final.rows.map(\.id) {
            failures.append("Streamed markdown rows remounted at completion")
        }
        MarkdownRenderer.invalidate(messageID: id)
        let restored = MarkdownRenderer.blocks(for: final.source, messageID: id, streaming: false, lang: .english)
        if restored.rows.map(\.id) != final.rows.map(\.id) { failures.append("Cache eviction changed visible row identities") }
        let started = CACurrentMediaTime()
        for _ in 0..<1_000 {
            if MarkdownRenderer.blocks(for: restored.source, messageID: id, streaming: false, lang: .english) !== restored {
                failures.append("Unchanged markdown was reparsed"); break
            }
        }
        metrics["cachedParse1000Milliseconds"] = (CACurrentMediaTime() - started) * 1000
        let repeated = MarkdownRenderer.blocks(for: "$x$ then $y$ then $x", messageID: "preview-repeat-check", streaming: true, lang: .english)
        if repeated.previewMathID != nil {
            failures.append("A repeated live prefix demoted a completed equation to provisional")
        }
        return Result(failures: failures, metrics: metrics)
    }
}
#endif
