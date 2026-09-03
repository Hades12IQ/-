import SwiftUI
import UIKit

/// One Brain answer: the markdown body with tappable `[Sn]` citations, the source list underneath
/// and the copy bar (`web-brain-ux.md §11.1–11.3`). A comparison arrives as two column bodies
/// separated by the compare marker and is laid out side by side when the width allows it.
///
/// ROUND 3 — NOTHING IN THE SOURCE LIST MAY EXCEED ITS CARD. «المصدر يخرج خارج البوكس».
/// Three separate ways a source row could push past the card it is printed on, all fixed here:
///
/// 1. Every label in the list was pinned to a hard point size (`.system(size: 14)`), so the list
///    ignored `حجم النص` completely while the answer above it grew. Each one now goes through
///    `FirasType.scaled(_:scale:)` like the rest of the app's reading text.
/// 2. Once the labels scale they must be able to fall onto a second line, so every one of them
///    carries `fixedSize(horizontal: false, vertical: true)`: the text wraps down, never out. The
///    title was `lineLimit(1)` — a hard truncation that hid the end of a filename even when there
///    was room for it underneath — and is now two wrapping lines.
/// 3. The copy bar was a plain `HStack` of two capsules. At the largest font size «نسخ مع الصفحات»
///    plus «نسخ الكل» is wider than a phone card, and an `HStack` does not wrap. It is now a
///    `ViewThatFits` that stacks the two buttons the moment the row cannot hold them.
struct BrainAnswerView: View {

    private let env: AppEnvironment
    private let markdown: String
    private let messageID: String
    private let streaming: Bool
    private let lang: AppLanguage
    private let palette: FirasPalette
    private let prefs: PreferencesStore
    private let onCitation: (BrainSource) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var copied = false
    @State private var picking = false
    @State private var exporting = false
    @State private var exported: ExportController.Export?

    init(
        env: AppEnvironment,
        markdown: String,
        messageID: String,
        streaming: Bool,
        lang: AppLanguage,
        palette: FirasPalette,
        prefs: PreferencesStore,
        onCitation: @escaping (BrainSource) -> Void
    ) {
        self.env = env
        self.markdown = markdown
        self.messageID = messageID
        self.streaming = streaming
        self.lang = lang
        self.palette = palette
        self.prefs = prefs
        self.onCitation = onCitation
    }

    private struct Parts {
        let columns: [String]
        let sources: [BrainSource]
    }

    private var scale: FontScale { prefs.fontScale }

    var body: some View {
        let parts = Self.parse(markdown)
        return VStack(alignment: .leading, spacing: 14) {
            columns(parts)
            if !parts.sources.isEmpty {
                sourceList(parts.sources)
            }
            if !streaming {
                copyBar(parts)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $picking) {
            ExportFormatPicker(lang: lang, palette: palette, isWorking: exporting) { format in
                export(format, parts: Self.parse(markdown))
            }
        }
        .sheet(item: $exported) { file in
            FirasActivitySheet(url: file.url)
        }
        .environment(\.openURL, OpenURLAction { url in
            open(url, in: parts.sources)
        })
    }

    // MARK: - Body

    @ViewBuilder
    private func columns(_ parts: Parts) -> some View {
        if parts.columns.count > 1 && sizeClass == .regular {
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(parts.columns.indices), id: \.self) { index in
                    column(parts.columns[index], index: index)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(parts.columns.indices), id: \.self) { index in
                    column(parts.columns[index], index: index)
                }
            }
        }
    }

    private func column(_ text: String, index: Int) -> some View {
        MarkdownView(
            markdown: Self.decorate(text),
            messageID: messageID + "-c\(index)",
            streaming: streaming,
            lang: lang,
            palette: palette,
            prefs: prefs,
            background: palette.surface,
            onFence: { fence in
                if case .sources = fence { return AnyView(EmptyView()) }
                return nil
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sources

    private func sourceList(_ sources: [BrainSource]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: Strings.Brain.sources(lang))
                .font(FirasType.scaled(13, scale: scale, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)

            ForEach(sources) { source in
                sourceRow(source)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(palette)
    }

    private func sourceRow(_ source: BrainSource) -> some View {
        Button {
            onCitation(source)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                CitationChip(
                    number: source.n,
                    subtitle: source.title,
                    palette: palette,
                    action: { onCitation(source) }
                )
                .allowsHitTesting(false)

                sourceText(source)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Wrapping, never truncating sideways: the column is whatever is left after the chip, and
    /// every line inside it grows downwards.
    private func sourceText(_ source: BrainSource) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: source.title)
                .font(FirasType.scaled(14, scale: scale, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let snippet = source.s, !snippet.isEmpty {
                Text(verbatim: String(snippet.prefix(160)))
                    .font(FirasType.scaled(13, scale: scale))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(verbatim: Self.locationLabel(source, lang: lang))
                .font(FirasType.scaled(12, scale: scale))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bidiIsland(for: source.title, fallback: lang)
    }

    static func locationLabel(_ source: BrainSource, lang: AppLanguage) -> String {
        var text = Strings.Brain.unitAndNumber(source.documentUnit, source.page, lang)
        if let label = source.label, !label.isEmpty {
            text += " · " + label
        }
        return text
    }

    // MARK: - Copy bar

    /// Two capsules side by side while they fit, stacked the moment they do not. `ViewThatFits`
    /// measures the row's *ideal* width — the untruncated labels — so the fall to the stacked
    /// variant happens before anything is clipped, in either language and at any font size.
    private func copyBar(_ parts: Parts) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                copyButtons(parts)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                copyButtons(parts)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func copyButtons(_ parts: Parts) -> some View {
        Button {
            copy(Self.plainText(parts, lang: lang, withPages: false))
        } label: {
            barLabel(
                copied ? Strings.Common.copied(lang) : Strings.Brain.copyAll(lang),
                symbol: "doc.on.doc"
            )
        }
        .buttonStyle(.plain)

        if !parts.sources.isEmpty {
            Button {
                copy(Self.plainText(parts, lang: lang, withPages: true))
            } label: {
                barLabel(Strings.Brain.copyWithPages(lang), symbol: "text.quote")
            }
            .buttonStyle(.plain)
        }

        /* THE SAME EXPORT THE CHAT HAS. Nine formats, each with its own sentence, behind
           the screen that already exists for choosing one — Brain does not get a second
           implementation of a thing the app can already do. */
        Button {
            Haptics.select()
            picking = true
        } label: {
            barLabel(Strings.Brain.exportAnswer(lang), symbol: "square.and.arrow.down")
        }
        .buttonStyle(.plain)
        .disabled(exporting)
    }

    // MARK: - Export

    /// The answer WITH its pages. An exported answer that dropped the citations would be
    /// worth less than the copy button beside it.
    private func export(_ format: ExportController.Format, parts: Parts) {
        guard !exporting else { return }
        exporting = true
        picking = false
        let controller = ExportController(env: env)
        let source = Self.plainText(parts, lang: lang, withPages: true)
        let title = Self.exportTitle(parts, lang: lang)
        Task {
            await controller.export(format, markdown: source, title: title)
            exporting = false
            if let finished = controller.result { exported = finished }
        }
    }

    /// The answer's own first line, which is the heading the model wrote, or the product's
    /// name when the answer opens with prose.
    private static func exportTitle(_ parts: Parts, lang: AppLanguage) -> String {
        let first = (parts.columns.first ?? "")
            .components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        var line = first.trimmingCharacters(in: .whitespacesAndNewlines)
        while let head = line.first, head == "#" || head == " " { line.removeFirst() }
        line = String(line.prefix(70)).trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? Strings.Brain.heroTitle(lang) : line
    }

    private func barLabel(_ text: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(FirasType.scaled(12, scale: scale, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(palette.textSecondary)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background {
            Capsule(style: .continuous).fill(palette.surfaceSunken)
        }
        .contentShape(Capsule(style: .continuous))
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        Haptics.select()
        copied = true
        // A plain main-queue hop: the label goes back to "copy" without a sleep anywhere.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            copied = false
        }
    }

    // MARK: - Citation routing

    private func open(_ url: URL, in sources: [BrainSource]) -> OpenURLAction.Result {
        guard url.scheme == "firas-cite" else { return .systemAction }
        let raw = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let number = Int(raw), let source = sources.first(where: { $0.n == number }) else {
            return .handled
        }
        onCitation(source)
        return .handled
    }

    // MARK: - Parsing

    /// Splits the compare columns and lifts the ```` ```firas-sources ```` fence out of the body.
    private static func parse(_ markdown: String) -> Parts {
        var sources: [BrainSource] = []
        var body: [String] = []
        var fence: [String] = []
        var insideFence = false

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if insideFence {
                if trimmed == "```" {
                    insideFence = false
                    let json = fence.joined(separator: "\n")
                    if let data = json.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode([BrainSource].self, from: data) {
                        sources = decoded
                    }
                    fence = []
                } else {
                    fence.append(line)
                }
                continue
            }
            if trimmed == "```firas-sources" {
                insideFence = true
                continue
            }
            body.append(line)
        }

        let text = body.joined(separator: "\n")
        let columns = text
            .components(separatedBy: BrainAsker.compareMarker)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return Parts(columns: columns.isEmpty ? [""] : columns, sources: sources)
    }

    /// `[S3]` becomes a link the answer view can route; markers that survive renumbering always
    /// have a source, and the ones that do not were already dropped by `BrainAsker`.
    static func decorate(_ text: String) -> String {
        guard text.contains("[S") else { return text }
        var out = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            if characters[index] == "[",
               index + 2 < characters.count,
               characters[index + 1] == "S",
               characters[index + 2].isNumber {
                var cursor = index + 2
                var digits = ""
                while cursor < characters.count, characters[cursor].isNumber {
                    digits.append(characters[cursor])
                    cursor += 1
                }
                if cursor < characters.count, characters[cursor] == "]", !digits.isEmpty {
                    out += "[ " + digits + " ](firas-cite://" + digits + ")"
                    index = cursor + 1
                    continue
                }
            }
            out.append(characters[index])
            index += 1
        }
        return out
    }

    /// The copy-bar text (`§11.3`): the visible answer without markers, then the source lines.
    private static func plainText(_ parts: Parts, lang: AppLanguage, withPages: Bool) -> String {
        var body = parts.columns.joined(separator: "\n\n")
        if withPages {
            for source in parts.sources {
                body = body.replacingOccurrences(
                    of: "[S\(source.n)]",
                    with: " (" + Strings.Brain.unitAndNumber(source.documentUnit, source.page, lang) + ")"
                )
            }
        }
        for source in parts.sources {
            body = body.replacingOccurrences(of: "[S\(source.n)]", with: "")
        }

        guard !parts.sources.isEmpty else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var tail = "\n\n" + Strings.Brain.copySourcesHeading(lang)
        for source in parts.sources {
            tail += "\n" + String(source.n) + ". " + source.title
                + " — " + Strings.Brain.unitAndNumber(source.documentUnit, source.page, lang)
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines) + tail
    }
}
