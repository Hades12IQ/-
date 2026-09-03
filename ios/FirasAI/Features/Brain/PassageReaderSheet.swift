import SwiftUI
import UIKit

/// The cited passage, exactly as it sits in the document: the two chunks before it, the chunk the
/// citation points at, and the two after (`web-brain-ux.md §11.4`, `server-brain.md §9`).
///
/// The hit's closest sentences to the question are marked offline and deterministically — nothing
/// here asks a model anything. When the document has been deleted the reader falls back to the
/// ≤ 400-character snippet the answer stored with the citation, then to the "no longer available"
/// sentence.
///
/// iPhone presents it as a sheet; on iPad the same view is the trailing inspector
/// (`design-brief.md §8`), which is what `embedded` is for.
struct PassageReaderSheet: View {

    private let env: AppEnvironment
    private let source: BrainSource
    private let question: String?
    private let embedded: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var passage: BrainPassage?
    @State private var isLoading = true
    @State private var didLoad = false

    init(
        env: AppEnvironment,
        source: BrainSource,
        question: String? = nil,
        embedded: Bool = false
    ) {
        self.env = env
        self.source = source
        self.question = question
        self.embedded = embedded
    }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content.toolbar { closeToolbar } }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .firasSheetBackground(env.prefs.palette)
            }
        }
        .task { await load() }
    }

    // MARK: - Layout

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    passageBody
                }
                .padding(.horizontal, embedded ? 12 : 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(env.prefs.palette.background)
            .safeAreaInset(edge: .bottom) { actionBar }
            .onChange(of: didLoad) { _, loaded in
                guard loaded else { return }
                withAnimation(FirasMotion.fade) { proxy.scrollTo(Self.hitAnchor, anchor: .center) }
            }
        }
        .navigationTitle(Text(source.title))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ToolbarContentBuilder
    private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
            }
            .tint(env.prefs.palette.textSecondary)
            .accessibilityLabel(Text(Strings.Common.close(env.prefs.lang)))
        }
    }

    private var header: some View {
        let palette = env.prefs.palette
        let lang = env.prefs.lang
        return VStack(alignment: .leading, spacing: 4) {
            Text(source.title)
                .font(FirasType.scaled(17, scale: env.prefs.fontScale, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .bidiIsland(for: source.title, fallback: lang)
            Text(subtitle)
                .font(FirasType.scaled(12, scale: env.prefs.fontScale))
                .foregroundStyle(palette.textMuted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var passageBody: some View {
        if isLoading {
            HStack {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(env.prefs.palette.accent)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
            .accessibilityHidden(true)
        } else if let passage {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(passage.before, id: \.ci) { neighbour in
                    contextParagraph(neighbour.t)
                }
                hitParagraph(passage.text)
                    .id(Self.hitAnchor)
                ForEach(passage.after, id: \.ci) { neighbour in
                    contextParagraph(neighbour.t)
                }
            }
        } else if let snippet = source.s, !snippet.trimmingCharacters(in: .whitespaces).isEmpty {
            hitParagraph(snippet).id(Self.hitAnchor)
        } else {
            Text(Strings.Brain.gone(env.prefs.lang))
                .font(FirasType.scaled(14, scale: env.prefs.fontScale))
                .foregroundStyle(env.prefs.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 18)
                .id(Self.hitAnchor)
        }
    }

    private func contextParagraph(_ text: String) -> some View {
        let (font, spacing) = FirasType.prose(env.prefs.lang, scale: env.prefs.fontScale)
        return Text(text)
            .font(font)
            .lineSpacing(spacing)
            .foregroundStyle(env.prefs.palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bidiIsland(for: text, fallback: env.prefs.lang)
    }

    private func hitParagraph(_ text: String) -> some View {
        let (font, spacing) = FirasType.prose(env.prefs.lang, scale: env.prefs.fontScale)
        let palette = env.prefs.palette
        return Text(highlighted(text))
            .font(font)
            .lineSpacing(spacing)
            .foregroundStyle(palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .surfaceCard(palette, radius: 7)
            .bidiIsland(for: text, fallback: env.prefs.lang)
            .accessibilityLabel(Text(text))
            .accessibilityHint(Text(Strings.Brain.matchHint(env.prefs.lang)))
    }

    private var actionBar: some View {
        let palette = env.prefs.palette
        let lang = env.prefs.lang
        return HStack(spacing: 10) {
            Button { copy() } label: {
                Label {
                    Text(Strings.Common.copy(lang))
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
                .font(FirasType.scaled(14, scale: env.prefs.fontScale, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.textSecondary)
            .frame(minHeight: 44)

            Spacer(minLength: 0)

            Button { openSource() } label: {
                Text(Strings.Brain.openSource(lang))
                    .font(FirasType.scaled(14, scale: env.prefs.fontScale, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .background { Capsule(style: .continuous).fill(palette.accent) }
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.backgroundSubtle)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.border).frame(height: 0.5)
        }
    }

    // MARK: - Content

    private static let hitAnchor = "firas-passage-hit"

    private var subtitle: String {
        let lang = env.prefs.lang
        let unit = passage?.unit ?? source.documentUnit
        let page = passage?.page ?? source.page
        var text = Strings.Brain.unitAndNumber(unit, page, lang)
        let label = passage?.label ?? source.label ?? ""
        if !label.isEmpty { text += " · " + label }
        return text
    }

    private var plainText: String {
        if let passage { return passage.text }
        return source.s ?? ""
    }

    private func highlighted(_ text: String) -> AttributedString {
        let ranges = BrainPassageHighlighter.spans(in: text, question: question ?? "")
        guard !ranges.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var cursor = text.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                result.append(AttributedString(String(text[cursor..<range.lowerBound])))
            }
            var piece = AttributedString(String(text[range]))
            piece.backgroundColor = env.prefs.palette.accent.opacity(0.18)
            result.append(piece)
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result.append(AttributedString(String(text[cursor...])))
        }
        return result
    }

    // MARK: - Actions

    private func load() async {
        guard !didLoad else { return }
        isLoading = true
        passage = await env.brain.passage(docID: source.docId, index: source.ci)
        isLoading = false
        didLoad = true
    }

    private func copy() {
        let text = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            env.toasts.show(Strings.Common.copyFailed(env.prefs.lang), isError: true)
            return
        }
        UIPasteboard.general.string = text
        Haptics.select()
        env.toasts.show(Strings.Common.copied(env.prefs.lang))
    }

    /// The native reading of `فتح المصدر`: put this document back inside the search and get out of
    /// the way, so the next question is answered from it.
    private func openSource() {
        if env.brain.excluded.contains(source.docId) {
            env.brain.toggleExcluded(source.docId)
        }
        Haptics.select()
        if !embedded { dismiss() }
    }
}

// MARK: - Highlighting

/// `brainMarkAnswerSpans` (app.js:89674): the one or two sentences of a passage whose folded term
/// set best covers the question. Deterministic, offline, and silent when it is unsure — a wrong
/// highlight is worse than none, so a tie marks nothing.
enum BrainPassageHighlighter {

    static func spans(in text: String, question: String) -> [Range<String.Index>] {
        let terms = self.terms(in: question)
        guard terms.count >= 2, !text.isEmpty else { return [] }

        let sentences = self.sentences(in: text)
        guard sentences.count > 1 else { return [] }

        var present: [Set<String>] = []
        present.reserveCapacity(sentences.count)
        for range in sentences {
            let folded = self.terms(in: String(text[range]))
            present.append(terms.intersection(folded))
        }

        // A term that shows up nearly everywhere says nothing about which sentence answers.
        var frequency: [String: Int] = [:]
        for set in present {
            for term in set { frequency[term, default: 0] += 1 }
        }
        let ceiling = max(1, Int(Double(sentences.count) * 0.6))
        let useful = terms.filter { (frequency[$0] ?? 0) <= ceiling }
        guard !useful.isEmpty else { return [] }

        var scores: [Int] = []
        scores.reserveCapacity(sentences.count)
        for set in present { scores.append(set.intersection(useful).count) }

        let floor = max(2, min(4, 1 + terms.count / 4))
        guard let best = scores.max(), best >= floor else { return [] }
        let winners = scores.indices.filter { scores[$0] == best }
        guard winners.count <= 2 else { return [] }
        return winners.map { sentences[$0] }.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Sentence ranges covering the whole string, in order, with the terminator and the space
    /// after it kept on the sentence they close.
    static func sentences(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\n" || ".!?؟۔".contains(character) {
                var end = next
                while end < text.endIndex, text[end].isWhitespace {
                    end = text.index(after: end)
                }
                if start < end { ranges.append(start..<end) }
                start = end
                index = end
            } else {
                index = next
            }
        }
        if start < text.endIndex { ranges.append(start..<text.endIndex) }
        return ranges
    }

    /// Folded content words: harakat and tatweel gone, `أإآ→ا`, `ى→ي`, `ة→ه` (`ArabicText.normalize`),
    /// three characters or longer.
    static func terms(in text: String) -> Set<String> {
        let folded = ArabicText.normalize(text).lowercased()
        var terms: Set<String> = []
        for piece in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            guard piece.count >= 3 else { continue }
            terms.insert(String(piece))
        }
        return terms
    }
}
