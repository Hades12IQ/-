import Foundation
import Perception
import SwiftUI
import UIKit

/// A screen owns the selection request and decides which composer receives the quotation.
@MainActor @Perceptible
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
        if #available(iOS 16, *), !FirasCompatibility.forceLegacyUI {
            view.onLegacyWidth = nil
            view.configureLegacyAskFiras(title: nil, action: nil)
        } else {
            view.configureLegacyAskFiras(title: selection == nil ? nil : (lang == .arabic ? "اسأل فِراس" : "Ask Firas"),
                action: selection == nil ? nil : { [weak coordinator = context.coordinator] quote in coordinator?.selection?.ask(quote) })
            view.onLegacyWidth = { [weak view, weak coordinator = context.coordinator] width in
                guard let view, let coordinator else { return }
                coordinator.layoutWidth = width
                updateText(view, coordinator: coordinator, width: width)
            }
        }
        updateText(view, coordinator: context.coordinator, width: context.coordinator.layoutWidth)
    }

    static func dismantleUIView(_ view: SelectableTextView, coordinator: Coordinator) {
        view.onLegacyWidth = nil
        view.configureLegacyAskFiras(title: nil, action: nil)
        view.delegate = nil
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

    @available(iOS 16, *)
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

        @available(iOS 17, *)
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, let openURL else { return defaultAction }
            return UIAction { _ in openURL(url) }
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            guard interaction == .invokeDefaultAction, let openURL else { return true }
            openURL(URL)
            return false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? SelectableTextView)?.refreshLegacySelectionMenu()
        }

        @available(iOS 16, *)
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
    var onLegacyWidth: ((CGFloat) -> Void)?
    private var lastLegacyWidth: CGFloat = 0
    private var legacyAskTitle: String?
    private var legacyAskAction: ((String) -> Void)?
    private var legacyAskItem: UIMenuItem?
    private static weak var legacyMenuOwner: SelectableTextView?

    /// The old system menu is shared by UIKit. Only the current responder leases one action;
    /// releasing it removes that exact item and preserves any menu owned by another feature.
    func configureLegacyAskFiras(title: String?, action: ((String) -> Void)?) {
        if legacyAskTitle != title || action == nil { releaseLegacySelectionMenu() }
        legacyAskTitle = title
        legacyAskAction = action
        refreshLegacySelectionMenu()
    }

    var canAskSelectedText: Bool {
        legacyAskAction != nil && !selectedPlainText(selectedRange).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refreshLegacySelectionMenu() {
        guard isFirstResponder, window != nil, canAskSelectedText, let title = legacyAskTitle else {
            releaseLegacySelectionMenu()
            return
        }
        guard Self.legacyMenuOwner !== self || legacyAskItem == nil else { return }
        Self.legacyMenuOwner?.releaseLegacySelectionMenu()
        let item = UIMenuItem(title: title, action: #selector(askFirasSelection(_:)))
        legacyAskItem = item
        Self.legacyMenuOwner = self
        UIMenuController.shared.menuItems = (UIMenuController.shared.menuItems ?? []) + [item]
        UIMenuController.shared.update()
    }

    private func releaseLegacySelectionMenu() {
        guard let item = legacyAskItem else { return }
        let remaining = (UIMenuController.shared.menuItems ?? []).filter { $0 !== item }
        UIMenuController.shared.menuItems = remaining.isEmpty ? nil : remaining
        legacyAskItem = nil
        if Self.legacyMenuOwner === self { Self.legacyMenuOwner = nil }
    }

    @objc func askFirasSelection(_ sender: Any?) {
        guard canAskSelectedText, let action = legacyAskAction else { return }
        let quote = selectedPlainText(selectedRange)
        releaseLegacySelectionMenu()
        _ = resignFirstResponder()
        action(quote)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(askFirasSelection(_:)) { return canAskSelectedText }
        return super.canPerformAction(action, withSender: sender)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { refreshLegacySelectionMenu() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { releaseLegacySelectionMenu() }
        return resigned
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { releaseLegacySelectionMenu() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let onLegacyWidth, bounds.width.isFinite, bounds.width > 0,
              abs(lastLegacyWidth - bounds.width) > 0.5 else { return }
        lastLegacyWidth = bounds.width
        onLegacyWidth(bounds.width)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        guard onLegacyWidth != nil, bounds.width.isFinite, bounds.width > 0 else { return super.intrinsicContentSize }
        let fitted = super.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fitted.height))
    }

    func selectedPlainText(_ range: NSRange) -> String {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= attributedText.length, range.length <= attributedText.length - range.location else { return "" }
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
