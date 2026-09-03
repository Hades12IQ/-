import SwiftUI

/// `[MDBlock]` → SwiftUI. The document view of an answer: no bubble, no glass, one bidi island per
/// block so an English heading inside an Arabic reply does not drag the paragraph around with it.
///
/// This is the one place every renderer of this wave becomes *reachable*. A block that stays a
/// string because nothing draws it is the bug the owner reported four different ways:
///
/// * a fenced block reaches `CodeBlockView`, which hands a page, a stylesheet, a script or a JSON
///   document to `HTMLPreviewCard` — «مربع الكودات» and «المعاينه» arriving together;
/// * a `$$…$$` block reaches `MathBlockView`, which typesets it with KaTeX — «لاتكس ما يتحول»;
/// * a ```plot / ```tikz / ```graph / ```funcplot block, and a ```tex block carrying a
///   `tikzpicture`, reach `DiagramCard` — «عدنا رسم تو دي و ثري دي».
///
/// `drawsIslands` is the one switch a caller needs. `ExportController` renders this view off-screen
/// through `ImageRenderer`, and a `WKWebView` does not rasterise into a PDF page or a PNG: an export
/// therefore keeps the code box and the Unicode equation, which is exactly what its own contract
/// already promises. Everything on screen leaves it at its default.
struct MarkdownView: View {

    private let markdown: String
    private let messageID: String
    private let streaming: Bool
    private let lang: AppLanguage
    private let palette: FirasPalette
    private let prefs: PreferencesStore
    private let drawsIslands: Bool
    /* THE GROUND THIS IS DRAWN ON, which is not always the page's. A KaTeX snapshot is
       opaque and carries the colour it was rendered against, so an equation drawn for the
       transcript and shown on a card is a rectangle of the wrong shade. Every caller that
       renders markdown on a surface rather than on the page says so. */
    private let ground: Color?
    private let onFence: (FirasFence) -> AnyView?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        markdown: String,
        messageID: String,
        streaming: Bool,
        lang: AppLanguage,
        palette: FirasPalette,
        prefs: PreferencesStore,
        drawsIslands: Bool = true,
        background: Color? = nil,
        onFence: @escaping (FirasFence) -> AnyView?
    ) {
        self.markdown = markdown
        self.messageID = messageID
        self.streaming = streaming
        self.lang = lang
        self.palette = palette
        self.prefs = prefs
        self.drawsIslands = drawsIslands
        self.ground = background
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
        let scale = prefs.fontScale
        let prose = FirasType.prose(lang, scale: scale)
        let style = MarkdownStyle(
            palette: palette,
            lang: lang,
            font: prose.font,
            lineSpacing: prose.lineSpacing,
            scale: scale,
            messageID: messageID,
            motionOn: FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion),
            drawsIslands: drawsIslands,
            codeCompanions: companions
        )
        let settled = parsed.settled
        let tail = parsed.tail

        // Captured as values so the priming task holds no reference to the view or to the store.
        let source = markdown
        let identity = messageID
        let paint = palette
        let draws = drawsIslands
        let primeKey = identity + "#" + String(source.utf8.count) + "#" + scale.rawValue

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
        .task(id: primeKey) {
            guard draws else { return }
            await MathBlockView.prime(
                markdown: source,
                messageID: identity,
                palette: paint,
                background: ground ?? paint.background,
                fontScale: scale
            )
        }
    }

    /// Every `css` and `js` fence of the same answer, so a page split across three blocks previews
    /// as one page. Skipped while the answer is still arriving: it is an O(n) scan of the whole
    /// message, and the preview side is not what a reader is watching mid-stream.
    private var companions: [HTMLPreviewCard.Document.Companion] {
        guard !streaming, markdown.contains("```") || markdown.contains("~~~") else { return [] }
        return HTMLPreviewCard.Document.companions(in: markdown)
    }
}

// MARK: - Shared style

private struct MarkdownStyle {
    let palette: FirasPalette
    let lang: AppLanguage
    let font: Font
    let lineSpacing: CGFloat
    /// The Settings reading size. Headings and paragraph rhythm both scale with it.
    let scale: FontScale
    /// The math island key: every equation of one answer is typeset by one page.
    let messageID: String
    let motionOn: Bool
    /// False while exporting, where a `WKWebView` rasterises as a blank rectangle.
    let drawsIslands: Bool
    let codeCompanions: [HTMLPreviewCard.Document.Companion]
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
        case .paragraph: return FirasType.proseParagraphSpacing(style.lang, scale: style.scale)
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
            return AnyView(
                textBlock(text, font: FirasType.heading(level, scale: style.scale), weight: .semibold)
            )
        case .list(let ordered, let start, let items):
            return AnyView(listBlock(ordered: ordered, start: start, items: items))
        case .quote(let blocks):
            return AnyView(quoteBlock(blocks))
        case .table(let header, let rows):
            return AnyView(TableBlockView(header: header, rows: rows, palette: style.palette))
        case .code(let language, let body):
            return AnyView(codeBlock(language: language, body: body))
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

    /// A paragraph, a heading, a list item — and the one place inline mathematics stops being an
    /// approximation. Where `MathIsland` has already drawn an equation of this string, `composed`
    /// puts the real glyph on the line instead of the `MathText.unicode` stand-in; everything it
    /// has not drawn keeps that stand-in and nothing waits on anything.
    private func textBlock(_ text: AttributedString, font: Font, weight: Font.Weight?) -> some View {
        let plain = String(text.characters)
        let painted = MarkdownInline.styled(text, palette: style.palette)
        let glyphs = inlineGlyphs(in: painted)
        var label = (glyphs.isEmpty ? Text(painted) : MarkdownInline.composed(painted, glyphs: glyphs))
            .font(font)
        if let weight { label = label.fontWeight(weight) }
        return HStack(alignment: .bottom, spacing: 4) {
            spoken(
                label
                    .lineSpacing(style.lineSpacing)
                    .foregroundStyle(style.palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true),
                as: plain,
                when: !glyphs.isEmpty
            )
            if showsCaret {
                StreamCaret(palette: style.palette, motionOn: style.motionOn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bidiIsland(for: plain, fallback: style.lang)
    }

    /// The bitmaps the island has already drawn for this string's inline equations.
    ///
    /// Reading the island here is also what subscribes this row to it: the glyph store is
    /// observed, so an equation that finishes rendering a moment later redraws this paragraph and
    /// becomes typeset in place. A miss costs nothing — the Unicode form is already on screen, and
    /// stays. Exports keep that form on purpose; a `WKWebView` never rasterises into a PDF page,
    /// so `drawsIslands` is the same switch here as everywhere else in this file.
    private func inlineGlyphs(in source: AttributedString) -> [String: MathGlyph] {
        /* AN EXPORT MAY HAVE THEM TOO. This refused inline glyphs on the grounds that a
           document cannot run a web view. True, and beside the point: by the time a page
           is drawn a glyph is a UIImage like any other picture, and `ExportController`
           fills the cache before it starts drawing — which is exactly how display
           equations have been reaching exported PDFs all along. Removing the guard is
           what puts «رياضيات جميلة» in the file rather than a Unicode approximation of
           it. A miss still falls back to that approximation, so nothing is risked. */
        let spans = MarkdownInline.mathSpans(in: source)
        guard !spans.isEmpty else { return [:] }
        let mathStyle = MathIslandStyle(
            palette: style.palette,
            background: style.palette.background,
            fontScale: style.scale
        )
        var found: [String: MathGlyph] = [:]
        for span in spans {
            guard found[span.id] == nil else { continue }
            guard let glyph = MathIsland.shared.glyph(for: span.id, style: mathStyle) else { continue }
            found[span.id] = glyph
        }
        return found
    }

    /// VoiceOver reads a bitmap as nothing at all. Where an equation became a glyph, the spoken
    /// label falls back to the whole line in text — `MathText.unicode` equations included.
    @ViewBuilder
    private func spoken<V: View>(_ view: V, as label: String, when condition: Bool) -> some View {
        if condition {
            view.accessibilityLabel(Text(verbatim: label))
        } else {
            view
        }
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

    // MARK: Code, drawings, math and fences

    /// An ordinary fenced block. A drawing language is drawn; everything else is a code box that
    /// can collapse and, when the app can run it, carries `معاينة` over the same listing.
    ///
    /// The live preview waits for the block to stop growing. `HTMLPreviewCard` builds its document
    /// once, when it appears, and has no reason to rebuild it when the source changes underneath —
    /// which was true of every caller it had, because a fenced block only becomes one after its
    /// closing fence has arrived. An UNFENCED document has no such moment: it is a code block from
    /// its first line, so without this it would hand a half-written page to the island and then
    /// hold that frozen page for good. `showsCaret` is the tail of a streaming answer and nothing
    /// else, so the box streams as a plain listing and becomes a preview on the frame it lands.
    @ViewBuilder
    private func codeBlock(language: String?, body: String) -> some View {
        if style.drawsIslands, let spec = DiagramSpec.parse(codeLanguage: language, body: body) {
            DiagramCard(
                spec: spec,
                palette: style.palette,
                lang: style.lang,
                motionOn: style.motionOn
            )
        } else {
            CodeBlockView(
                code: body,
                language: language,
                palette: style.palette,
                collapsible: true,
                lang: style.lang,
                companions: style.codeCompanions,
                allowsInlinePreview: style.drawsIslands && !showsCaret
            )
        }
    }

    private func mathBlock(_ tex: String) -> some View {
        MathBlockView(
            tex: tex,
            display: true,
            messageID: style.messageID,
            palette: style.palette,
            lang: style.lang,
            fontScale: style.scale,
            background: style.palette.background,
            motionOn: style.motionOn
        )
    }

    /// The host gets first refusal — a chat turn draws its own cards. What it declines still has to
    /// mean something: a `plot` fence is a drawing on every surface, and an unknown one shows its
    /// source rather than leaving a hole in the page.
    @ViewBuilder
    private func fenceBlock(_ fence: FirasFence) -> some View {
        if let card = onFence(fence) {
            card
        } else if style.drawsIslands, let spec = DiagramSpec.parse(fence: fence) {
            DiagramCard(
                spec: spec,
                palette: style.palette,
                lang: style.lang,
                motionOn: style.motionOn
            )
        } else if case .code(let meta, let body) = fence {
            CodeBlockView(
                code: body,
                language: meta.lang,
                palette: style.palette,
                collapsible: true,
                lang: style.lang,
                filename: meta.name,
                companions: style.codeCompanions,
                allowsInlinePreview: style.drawsIslands
            )
        } else if case .plot(let body) = fence {
            CodeBlockView(
                code: body,
                language: "plot",
                palette: style.palette,
                collapsible: true,
                lang: style.lang,
                allowsInlinePreview: false
            )
        } else {
            EmptyView()
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
