import SwiftUI
import UIKit

/// One Brain answer: the markdown body with tappable `[Sn]` citations, the source list underneath
/// and the copy bar (`web-brain-ux.md §11.1–11.3`). A comparison arrives as two column bodies
/// separated by the compare marker and is laid out side by side when the width allows it.
struct BrainAnswerView: View {

    private let markdown: String
    private let messageID: String
    private let streaming: Bool
    private let lang: AppLanguage
    private let palette: FirasPalette
    private let prefs: PreferencesStore
    private let onCitation: (BrainSource) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var copied = false

    init(
        markdown: String,
        messageID: String,
        streaming: Bool,
        lang: AppLanguage,
        palette: FirasPalette,
        prefs: PreferencesStore,
        onCitation: @escaping (BrainSource) -> Void
    ) {
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
            Text(Strings.Brain.sources(lang))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textSecondary)

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

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    if let snippet = source.s, !snippet.isEmpty {
                        Text(String(snippet.prefix(160)))
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(2)
                    }
                    Text(Self.locationLabel(source, lang: lang))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: source.title, fallback: lang)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func locationLabel(_ source: BrainSource, lang: AppLanguage) -> String {
        var text = Strings.Brain.unitAndNumber(source.documentUnit, source.page, lang)
        if let label = source.label, !label.isEmpty {
            text += " · " + label
        }
        return text
    }

    // MARK: - Copy bar

    private func copyBar(_ parts: Parts) -> some View {
        HStack(spacing: 8) {
            Button {
                copy(Self.plainText(parts, lang: lang, withPages: false))
            } label: {
                barLabel(copied ? Strings.Common.copied(lang) : Strings.Brain.copyAll(lang), symbol: "doc.on.doc")
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

            Spacer(minLength: 0)
        }
    }

    private func barLabel(_ text: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
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
