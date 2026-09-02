import SwiftUI

/// `[MDBlock]` → SwiftUI. The document view of an answer: no bubble, no glass, one bidi island per
/// block so an English heading inside an Arabic reply does not drag the paragraph around with it.
struct MarkdownView: View {

    private let markdown: String
    private let messageID: String
    private let streaming: Bool
    private let lang: AppLanguage
    private let palette: FirasPalette
    private let prefs: PreferencesStore
    private let onFence: (FirasFence) -> AnyView?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        markdown: String,
        messageID: String,
        streaming: Bool,
        lang: AppLanguage,
        palette: FirasPalette,
        prefs: PreferencesStore,
        onFence: @escaping (FirasFence) -> AnyView?
    ) {
        self.markdown = markdown
        self.messageID = messageID
        self.streaming = streaming
        self.lang = lang
        self.palette = palette
        self.prefs = prefs
        self.onFence = onFence
    }

    var body: some View {
        content
    }

    private var content: some View {
        let parsed = MarkdownRenderer.blocks(
            for: markdown,
            messageID: messageID,
            streaming: streaming,
            lang: lang
        )
        let prose = FirasType.prose(lang, scale: prefs.fontScale)
        let style = MarkdownStyle(
            palette: palette,
            lang: lang,
            font: prose.font,
            lineSpacing: prose.lineSpacing,
            motionOn: FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion)
        )
        let settled = parsed.settled
        let tail = parsed.tail

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(settled.indices), id: \.self) { index in
                MarkdownBlockRow(
                    block: settled[index],
                    style: style,
                    isFirst: index == 0,
                    showsCaret: false,
                    onFence: onFence
                )
            }
            if let tail {
                MarkdownBlockRow(
                    block: tail,
                    style: style,
                    isFirst: settled.isEmpty,
                    showsCaret: streaming,
                    onFence: onFence
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared style

private struct MarkdownStyle {
    let palette: FirasPalette
    let lang: AppLanguage
    let font: Font
    let lineSpacing: CGFloat
    let motionOn: Bool
}

// MARK: - One block

private struct MarkdownBlockRow: View {

    let block: MDBlock
    let style: MarkdownStyle
    let isFirst: Bool
    let showsCaret: Bool
    let onFence: (FirasFence) -> AnyView?

    var body: some View {
        blockBody
            .padding(.top, isFirst ? 0 : topSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topSpacing: CGFloat {
        switch block {
        case .heading: return 16
        case .rule: return 10
        case .code, .table, .fence, .mathDisplay: return 14
        default: return 12
        }
    }

    // AnyView on purpose: lists and quotes contain blocks, and a recursive `some View` cannot
    // describe itself.
    private var blockBody: AnyView {
        switch block {
        case .paragraph(let text):
            return AnyView(textBlock(text, font: style.font, weight: nil))
        case .heading(let level, let text):
            return AnyView(textBlock(text, font: headingFont(level), weight: .semibold))
        case .list(let ordered, let start, let items):
            return AnyView(listBlock(ordered: ordered, start: start, items: items))
        case .quote(let blocks):
            return AnyView(quoteBlock(blocks))
        case .table(let header, let rows):
            return AnyView(TableBlockView(header: header, rows: rows, palette: style.palette))
        case .code(let language, let body):
            return AnyView(
                CodeBlockView(
                    code: body,
                    language: language,
                    palette: style.palette,
                    collapsible: false,
                    lang: style.lang
                )
            )
        case .rule:
            return AnyView(
                Rectangle()
                    .fill(style.palette.border)
                    .frame(height: 1)
                    .padding(.vertical, 4)
            )
        case .mathDisplay(let tex):
            return AnyView(mathBlock(tex))
        case .fence(let fence):
            return AnyView(fenceBlock(fence))
        case .raw(let text):
            return AnyView(rawBlock(text))
        }
    }

    // MARK: Text

    private func textBlock(_ text: AttributedString, font: Font, weight: Font.Weight?) -> some View {
        let plain = String(text.characters)
        var label = Text(MarkdownInline.styled(text, palette: style.palette))
            .font(font)
        if let weight { label = label.fontWeight(weight) }
        return HStack(alignment: .bottom, spacing: 4) {
            label
                .lineSpacing(style.lineSpacing)
                .foregroundStyle(style.palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if showsCaret {
                StreamCaret(palette: style.palette, motionOn: style.motionOn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bidiIsland(for: plain, fallback: style.lang)
    }

    private func rawBlock(_ text: String) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            Text(text)
                .font(style.font)
                .lineSpacing(style.lineSpacing)
                .foregroundStyle(style.palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if showsCaret {
                StreamCaret(palette: style.palette, motionOn: style.motionOn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bidiIsland(for: text, fallback: style.lang)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }

    // MARK: Lists and quotes

    private func listBlock(ordered: Bool, start: Int, items: [[MDBlock]]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.indices), id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(ordered: ordered, start: start, index: index))
                        .font(style.font)
                        .monospacedDigit()
                        .foregroundStyle(style.palette.textMuted)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items[index].indices), id: \.self) { inner in
                            MarkdownBlockRow(
                                block: items[index][inner],
                                style: style,
                                isFirst: true,
                                showsCaret: false,
                                onFence: onFence
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .bidiIsland(for: sampleText(items.first?.first), fallback: style.lang)
    }

    private func marker(ordered: Bool, start: Int, index: Int) -> String {
        guard ordered else { return "•" }
        return ArabicText.count(start + index, style.lang) + "."
    }

    private func quoteBlock(_ blocks: [MDBlock]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(style.palette.accent.opacity(0.5))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.indices), id: \.self) { index in
                    MarkdownBlockRow(
                        block: blocks[index],
                        style: style,
                        isFirst: true,
                        showsCaret: false,
                        onFence: onFence
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bidiIsland(for: sampleText(blocks.first), fallback: style.lang)
    }

    // MARK: Math and fences

    private func mathBlock(_ tex: String) -> some View {
        let flattened = MathText.unicode(tex)
        return Text(flattened.isEmpty ? tex : flattened)
            .font(FirasType.mono)
            .foregroundStyle(style.palette.textPrimary)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
            .forceLTR()
    }

    private func fenceBlock(_ fence: FirasFence) -> some View {
        Group {
            if let card = onFence(fence) {
                card
            } else if case .code(let meta, let body) = fence {
                CodeBlockView(
                    code: body,
                    language: meta.lang,
                    palette: style.palette,
                    collapsible: true,
                    lang: style.lang
                )
            } else {
                EmptyView()
            }
        }
    }

    private func sampleText(_ block: MDBlock?) -> String {
        guard let block else { return "" }
        switch block {
        case .paragraph(let text): return String(text.characters)
        case .heading(_, let text): return String(text.characters)
        case .raw(let text): return text
        case .quote(let inner): return sampleText(inner.first)
        case .list(_, _, let items): return sampleText(items.first?.first)
        default: return ""
        }
    }
}

// MARK: - Streaming caret

private struct StreamCaret: View {

    let palette: FirasPalette
    let motionOn: Bool

    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(palette.accent)
            .frame(width: 2, height: 16)
            .opacity(dim ? 0.2 : 1)
            .onAppear {
                guard motionOn else { return }
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
            .accessibilityHidden(true)
    }
}
