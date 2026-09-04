import Foundation

/// Palette-independent parsing. Layout and glyph notifications reuse the exact parsed document;
/// only changed source rebuilds its live tail and discovers new mathematical spans.
enum MarkdownRenderer {
    struct Row: Identifiable, Sendable {
        let id: Int
        let block: MDBlock
    }

    final class ParsedBlocks: Sendable {
        let source: String
        let renderingSource: String
        let streaming: Bool
        let chunks: [String]
        let rows: [Row]
        let mathItems: [MathIslandItem]
        let mathKey: String
        let previewMathID: String?

        init(source: String, renderingSource: String, streaming: Bool, chunks: [String], rows: [Row]) {
            self.source = source
            self.renderingSource = renderingSource
            self.streaming = streaming
            self.chunks = chunks
            self.rows = rows
            var seen: Set<String> = []
            let spans = MathScanner.spans(in: renderingSource)
            self.mathItems = spans.map { MathIslandItem(span: $0) }.filter { seen.insert($0.id).inserted }
            self.mathKey = mathItems.map(\.id).joined(separator: "|")
            if renderingSource != source, let candidate = spans.last?.id,
               !MathScanner.spans(in: source).contains(where: { $0.id == candidate }) {
                self.previewMathID = candidate
            } else {
                // A repeated provisional prefix can share a glyph with a real completed span.
                // That completed occurrence already permits persistence and normal queue ownership.
                self.previewMathID = nil
            }
        }
    }

    private static let cache: NSCache<NSString, ParsedBlocks> = {
        let cache = NSCache<NSString, ParsedBlocks>()
        cache.countLimit = 160
        cache.totalCostLimit = 6_000_000
        return cache
    }()

    static func blocks(for markdown: String, messageID: String, streaming: Bool, lang: AppLanguage) -> ParsedBlocks {
        let key = cacheKey(messageID: messageID, lang: lang)
        let previous = key.flatMap { cache.object(forKey: $0) }
        if let previous, previous.source == markdown, previous.streaming == streaming { return previous }

        // Synthetic closure belongs only to this preview, never to the stored message.
        let renderingSource = streaming ? MathScanner.streamingPreview(markdown) : markdown
        let chunks = MarkdownBlocks.split(renderingSource, streaming: streaming)
        var rows: [Row] = []
        rows.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            if let previous, index < previous.chunks.count, previous.chunks[index] == chunk {
                rows.append(previous.rows[index])
            } else {
                // Position is scoped to this message's ForEach. It survives stream completion
                // and parser-cache eviction; source/style checks still update the row's content.
                rows.append(Row(id: index, block: MarkdownBlocks.parse(chunk, lang: lang)))
            }
        }
        let parsed = ParsedBlocks(source: markdown, renderingSource: renderingSource,
            streaming: streaming, chunks: chunks, rows: rows)
        if let key { cache.setObject(parsed, forKey: key, cost: max(1, markdown.utf8.count * 2)) }
        return parsed
    }

    static func invalidate(messageID: String) {
        guard !messageID.isEmpty else { return }
        for lang in AppLanguage.allCases {
            if let key = cacheKey(messageID: messageID, lang: lang) { cache.removeObject(forKey: key) }
        }
    }

    static func invalidateAll() { cache.removeAllObjects() }

    private static func cacheKey(messageID: String, lang: AppLanguage) -> NSString? {
        guard !messageID.isEmpty else { return nil }
        return NSString(string: messageID + "|" + lang.rawValue)
    }
}
