import Foundation

/// The entry point every surface uses to turn an answer into blocks, and the reason a 50 000
/// character reply does not re-parse ten times a second while it streams.
///
/// The chunk strings from `MarkdownBlocks.split` are compared by index against the previous parse:
/// everything that still matches is reused verbatim, and only the blocks from the first difference
/// onward are parsed again. In practice that is the last block and nothing else.
enum MarkdownRenderer {

    /// One message's last parse. Immutable, so it is safe to hand between reads of the cache.
    final class ParsedBlocks: Sendable {
        let chunks: [String]
        let blocks: [MDBlock]

        init(chunks: [String], blocks: [MDBlock]) {
            self.chunks = chunks
            self.blocks = blocks
        }
    }

    private static let cache: NSCache<NSString, ParsedBlocks> = {
        let cache = NSCache<NSString, ParsedBlocks>()
        cache.countLimit = 160
        cache.totalCostLimit = 6_000_000
        return cache
    }()

    /// While `streaming`, the last block is returned separately as the live tail: the caller draws
    /// the caret on it and everything before it is settled and cheap.
    static func blocks(
        for markdown: String,
        messageID: String,
        streaming: Bool,
        lang: AppLanguage
    ) -> (settled: [MDBlock], tail: MDBlock?) {
        let chunks = MarkdownBlocks.split(markdown, streaming: streaming)
        guard !chunks.isEmpty else { return ([], nil) }

        let key = cacheKey(messageID: messageID, lang: lang)
        var parsed: [MDBlock] = []
        parsed.reserveCapacity(chunks.count)

        var reused = 0
        var cachedChunks = -1
        if let key, let previous = cache.object(forKey: key) {
            cachedChunks = previous.chunks.count
            let limit = min(previous.chunks.count, min(previous.blocks.count, chunks.count))
            while reused < limit, previous.chunks[reused] == chunks[reused] { reused += 1 }
            if reused > 0 { parsed.append(contentsOf: previous.blocks[0..<reused]) }
        }

        var index = reused
        while index < chunks.count {
            parsed.append(MarkdownBlocks.parse(chunks[index], lang: lang))
            index += 1
        }

        /* WRITTEN ONLY WHEN SOMETHING MOVED. A message is re-laid-out for reasons that have
           nothing to do with its text — a maths glyph landing redraws every answer on screen at
           once, because they all read the same observed store — and every one of those redraws
           came back through here to write an identical parse: a fresh `ParsedBlocks`, a fresh
           cost, and a fresh eviction decision, per message, per frame. When every chunk was
           reused and the entry already describes exactly this list, there is nothing to say. */
        if let key, reused < chunks.count || cachedChunks != chunks.count {
            cache.setObject(
                ParsedBlocks(chunks: chunks, blocks: parsed),
                forKey: key,
                cost: max(1, markdown.utf8.count)
            )
        }

        if streaming, let last = parsed.last {
            return (Array(parsed.dropLast()), last)
        }
        return (parsed, nil)
    }

    /// Called when a message is regenerated, edited, or switched to another version — the text
    /// under the same id changed in a way the prefix comparison must not paper over.
    static func invalidate(messageID: String) {
        guard !messageID.isEmpty else { return }
        for lang in AppLanguage.allCases {
            if let key = cacheKey(messageID: messageID, lang: lang) {
                cache.removeObject(forKey: key)
            }
        }
    }

    static func invalidateAll() {
        cache.removeAllObjects()
    }

    private static func cacheKey(messageID: String, lang: AppLanguage) -> NSString? {
        guard !messageID.isEmpty else { return nil }
        return NSString(string: messageID + "|" + lang.rawValue)
    }
}
