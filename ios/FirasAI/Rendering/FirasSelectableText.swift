import Foundation
import Observation
import SwiftUI
import UIKit

/// A screen owns the selection request and decides which composer receives the quotation.
@MainActor @Observable
final class FirasTextSelection {
    struct Request: Equatable {
        let id = UUID()
        let text: String
    }
    var request: Request?

    func ask(_ text: String) {
        let quote = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return }
        request = Request(text: String(quote.prefix(8_000)))
    }
}

extension EnvironmentValues {
    @Entry var firasTextSelection: FirasTextSelection? = nil
    @Entry var firasMathPersistenceAllowed = true
}

/// UITextView supplies iOS word selection, selection handles and its native Copy menu.
/// A SwiftUI Text with interpolated Images cannot supply a selected mathematical expression.
struct FirasSelectableText: UIViewRepresentable {
    let source: AttributedString
    let glyphs: [String: MathGlyph]
    let pointSize: CGFloat
    let semibold: Bool
    let lineSpacing: CGFloat
    let palette: FirasPalette
    let lang: AppLanguage
    var streaming: Bool = false

    @Environment(\.firasTextSelection) private var selection
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> SelectableTextView {
        let view = SelectableTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: SelectableTextView, context: Context) {
        context.coordinator.selection = selection
        context.coordinator.lang = lang
        context.coordinator.openURL = openURL
        updateText(view, coordinator: context.coordinator, width: context.coordinator.layoutWidth)
    }

    private func updateText(_ view: SelectableTextView, coordinator: Coordinator, width: CGFloat) {
        let visibleGlyphs = coordinator.liveGlyphs(source: source, current: glyphs,
            streaming: streaming, pointSize: pointSize, ink: UIColor(palette.textPrimary))
        let signature = RenderSignature(source: source, glyphs: visibleGlyphs, pointSize: pointSize,
            semibold: semibold, lineSpacing: lineSpacing, palette: palette, lang: lang, width: width)
        // SwiftUI also visits unchanged paragraphs when another equation finishes. Comparing
        // inputs first avoids allocating new attachments and relaying out selected text each time.
        guard coordinator.signature != signature else { return }
        coordinator.signature = signature
        view.tintColor = UIColor(palette.accent)
        view.linkTextAttributes = [.foregroundColor: UIColor(palette.accent), .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.accessibilityValue = String(source.characters)
        let text = attributedText(maximumMathWidth: width, resolvedGlyphs: visibleGlyphs)
        guard !view.attributedText.isEqual(to: text) else { return }
        let previous = view.selectedRange
        view.attributedText = text
        if previous.location != NSNotFound, NSMaxRange(previous) <= text.length {
            view.selectedRange = previous
        }
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        if abs(context.coordinator.layoutWidth - width) > 0.5 {
            context.coordinator.layoutWidth = width
            updateText(uiView, coordinator: context.coordinator, width: width)
        }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        fileprivate var signature: RenderSignature?
        fileprivate var layoutWidth: CGFloat = 320
        private struct PreviousMath {
            let prefix: String
            let glyph: MathGlyph
            let pointSize: CGFloat
            let ink: UIColor
        }
        private var previousMath: PreviousMath?
        var selection: FirasTextSelection?
        var lang: AppLanguage = .arabic
        var openURL: OpenURLAction?

        fileprivate func liveGlyphs(source: AttributedString, current: [String: MathGlyph],
                                    streaming: Bool, pointSize: CGFloat, ink: UIColor) -> [String: MathGlyph] {
            guard streaming else { previousMath = nil; return current }
            var last: (String, MathScanner.Span)?
            for run in source.runs {
                if let raw = run[FirasMathAttribute.self], let span = MathScanner.span(for: raw) {
                    last = (String(source[..<run.range.lowerBound].characters), span)
                }
            }
            guard let (prefix, span) = last else { previousMath = nil; return current }
            if let glyph = current[span.id] {
                previousMath = PreviousMath(prefix: prefix, glyph: glyph, pointSize: pointSize, ink: ink)
                return current
            }
            guard let previousMath, previousMath.prefix == prefix,
                  previousMath.pointSize == pointSize, previousMath.ink == ink else { return current }
            var visible = current
            visible[span.id] = previousMath.glyph
            return visible
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, let openURL else { return defaultAction }
            return UIAction { _ in openURL(url) }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let view = textView as? SelectableTextView, let selection,
                  range.length > 0 else { return UIMenu(children: suggestedActions) }
            let quote = view.selectedPlainText(range)
            let ask = UIAction(title: lang == .arabic ? "اسأل فِراس" : "Ask Firas",
                               image: UIImage(systemName: "text.bubble")) { _ in
                selection.ask(quote)
            }
            return UIMenu(children: suggestedActions + [ask])
        }
    }

    func attributedText(maximumMathWidth: CGFloat, resolvedGlyphs: [String: MathGlyph]? = nil) -> NSAttributedString {
        let glyphs = resolvedGlyphs ?? self.glyphs
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .natural
        paragraph.baseWritingDirection = ExportOOXML.isRightToLeft(String(source.characters), fallback: lang == .arabic)
            ? .rightToLeft : .leftToRight
        for run in source.runs {
            let plain = String(source[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var font = UIFont.systemFont(ofSize: pointSize, weight: semibold || intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            if intent.contains(.emphasized), let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
                font = UIFont(descriptor: descriptor, size: pointSize)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: UIColor(palette.textPrimary), .paragraphStyle: paragraph
            ]
            if intent.contains(.code), run[FirasMathAttribute.self] == nil {
                attributes[.font] = UIFont.monospacedSystemFont(ofSize: pointSize * 0.94, weight: .regular)
                attributes[.backgroundColor] = UIColor(palette.surfaceSunken)
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = UIColor(palette.accent)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if let raw = run[FirasMathAttribute.self], let span = MathScanner.span(for: raw),
               let glyph = glyphs[span.id], glyph.size.width > 0, glyph.size.height > 0 {
                let attachment = NSTextAttachment()
                attachment.image = glyph.image
                let fit = Self.mathAttachmentScale(glyph.size, maximumWidth: maximumMathWidth)
                attachment.bounds = CGRect(x: 0, y: -(glyph.size.height - glyph.baseline) * fit,
                                           width: glyph.size.width * fit, height: glyph.size.height * fit)
                let piece = NSMutableAttributedString(attachment: attachment)
                attributes[.firasCopyText] = plain
                piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
                result.append(piece)
            } else {
                result.append(NSAttributedString(string: plain, attributes: attributes))
            }
        }
        return result
    }

    static func mathAttachmentScale(_ size: CGSize, maximumWidth: CGFloat) -> CGFloat {
        guard size.width.isFinite, size.width > 0, maximumWidth.isFinite, maximumWidth > 0 else { return 1 }
        return min(1, max(1, maximumWidth - 2) / size.width)
    }

    fileprivate struct RenderSignature: Equatable {
        struct Glyph: Equatable {
            let image: ObjectIdentifier
            let size: CGSize
            let baseline: CGFloat
        }
        let source: AttributedString
        let glyphs: [String: Glyph]
        let pointSize: CGFloat
        let semibold: Bool
        let lineSpacing: CGFloat
        let ink: UIColor
        let accent: UIColor
        let codeBackground: UIColor
        let lang: AppLanguage
        let width: CGFloat

        init(source: AttributedString, glyphs: [String: MathGlyph], pointSize: CGFloat,
             semibold: Bool, lineSpacing: CGFloat, palette: FirasPalette, lang: AppLanguage, width: CGFloat) {
            self.source = source
            self.glyphs = glyphs.mapValues { Glyph(image: ObjectIdentifier($0.image), size: $0.size, baseline: $0.baseline) }
            self.pointSize = pointSize
            self.semibold = semibold
            self.lineSpacing = lineSpacing
            self.ink = UIColor(palette.textPrimary)
            self.accent = UIColor(palette.accent)
            self.codeBackground = UIColor(palette.surfaceSunken)
            self.lang = lang
            self.width = width
        }
    }
}

private extension NSAttributedString.Key {
    static let firasCopyText = NSAttributedString.Key("firasCopyText")
}

final class SelectableTextView: UITextView {
    func selectedPlainText(_ range: NSRange) -> String {
        guard range.location != NSNotFound, NSMaxRange(range) <= attributedText.length else { return "" }
        let selected = attributedText.attributedSubstring(from: range)
        var result = ""
        selected.enumerateAttributes(in: NSRange(location: 0, length: selected.length)) { attributes, part, _ in
            result += attributes[.firasCopyText] as? String ?? (selected.string as NSString).substring(with: part)
        }
        return result
    }

    override func copy(_ sender: Any?) {
        let text = selectedPlainText(selectedRange)
        if !text.isEmpty { UIPasteboard.general.string = text }
    }
}
