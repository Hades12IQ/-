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
        view.tintColor = UIColor(palette.accent)
        let text = attributedText()
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
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var selection: FirasTextSelection?
        var lang: AppLanguage = .arabic
        var openURL: OpenURLAction?

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

    private func attributedText() -> NSAttributedString {
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
               let glyph = glyphs[span.id], glyph.size.width <= 240, glyph.size.height <= 120 {
                let attachment = NSTextAttachment()
                attachment.image = glyph.image
                attachment.bounds = CGRect(x: 0, y: -(glyph.size.height - glyph.baseline),
                                           width: glyph.size.width, height: glyph.size.height)
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
