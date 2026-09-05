import CryptoKit
import Foundation

/// Stable references travel in authored HTML. Pixels remain in attachment/cache storage and
/// never become thousands of base64 characters inside a model's text instructions.
enum DocumentAssetInventory {
    enum Source: Sendable, Equatable {
        case attached(String)
        case generated(key: String)
    }

    enum Role: String, Sendable {
        case content, revisionReference
    }

    struct Entry: Identifiable, Sendable {
        let id: String
        let messageID: String
        let source: Source
        let role: Role
        let isThumbnail: Bool
    }

    static func entries(in conversation: ChatConversation, throughMessageID: String? = nil) -> [Entry] {
        entries(in: conversation.messages, throughMessageID: throughMessageID)
    }

    static func entries(in messages: [ChatMessage], throughMessageID: String? = nil) -> [Entry] {
        var entries: [Entry] = []
        var seen: Set<String> = []
        for (messageIndex, message) in messages.enumerated() {
            if message.role == .user {
                let originals = message.images ?? []
                let thumbnails = message.imageThumbs ?? []
                let previous = (originals.isEmpty && thumbnails.isEmpty) ? nil
                    : DocumentRevisionContext.latestMessage(in: Array(messages[..<messageIndex]), request: message.content)
                let revising = RequestClassifier.documentRevisionFormat(message.content,
                    hasPreviousDocument: previous != nil) != nil
                let role: Role = revising && !asksToIncludeImage(message.content) ? .revisionReference : .content
                for index in 0..<max(originals.count, thumbnails.count) {
                    let original = index < originals.count ? originals[index] : ""
                    let thumbnail = index < thumbnails.count ? thumbnails[index] : ""
                    let pixels = original.isEmpty ? thumbnail : original
                    guard !pixels.isEmpty else { continue }
                    let id = "attached-" + digest(message.id + "|attached|" + String(index))
                    entries.append(Entry(id: id, messageID: message.id, source: .attached(pixels),
                        role: role, isThumbnail: original.isEmpty))
                    seen.insert(id)
                }
            } else if message.role == .assistant {
                var remaining = message.content
                while let fence = FirasFence.firstFence(in: remaining) {
                    if fence.name == "firas-image",
                       let meta = MediaMeta.parse(fenceName: fence.name, body: fence.body), !meta.key.isEmpty {
                        let id = "generated-" + digest(meta.key)
                        if seen.insert(id).inserted {
                            entries.append(Entry(id: id, messageID: message.id, source: .generated(key: meta.key),
                                role: .content, isThumbnail: false))
                        }
                    }
                    remaining = String(remaining[fence.range.upperBound...])
                }
            }
            if message.id == throughMessageID { break }
        }
        return entries
    }

    /// A screenshot marking a deletion is evidence, unless the user explicitly wants it inserted.
    static func asksToIncludeImage(_ text: String) -> Bool {
        let pattern = #"(?:\b(?:add|insert|include|place|embed|use)\b.{0,50}\b(?:photo|image|picture|screenshot)s?\b|(?:أضف|اضف|ضيف|أدرج|ادرج|حط|ضع|استخدم).{0,45}(?:الصورة|صورة|الصور|اللقطة|لقطة))"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func referencedIDs(in html: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: #"firas-asset:(?://)?([A-Za-z0-9_-]{1,180})["']"#) else { return [] }
        let source = html as NSString
        return Set(expression.matches(in: html, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range(at: 1)) })
    }

    static func promptEntries(_ entries: [Entry], retaining html: String?) -> [Entry] {
        let retained = html.map(referencedIDs(in:)) ?? []
        let recent = Set(entries.filter { $0.role == .content }.suffix(10).map(\.id))
        return entries.filter { $0.role == .content && (retained.contains($0.id) || recent.contains($0.id)) }
    }

    static func instruction(for entries: [Entry]) -> String {
        guard !entries.isEmpty else {
            return "No supplied image assets are available for placement. Use text, CSS or original inline SVG diagrams where appropriate; never invent a photo URL or a firas-asset ID. A screenshot attached as revision evidence must not be pasted into the document."
        }
        let lines = entries.enumerated().map { index, entry in
            "\(index + 1). firas-asset:\(entry.id) — "
                + (entry.isThumbnail ? "saved low-resolution preview" : "supplied image")
        }.joined(separator: "\n")
        return """
        Real image assets available to this document, in conversation order:
        \(lines)
        Use only relevant supplied assets the user requests, with exact <img src="firas-asset:ID" alt="meaningful description"> references and appropriate captions. The app embeds their actual pixels. Preserve existing references during a revision. Never invent IDs, external photo URLs or base64. Low-resolution previews must remain small; do not claim print-resolution originals. Current screenshot attachments marking corrections are reference evidence, not document content, unless the user explicitly requests their insertion. Draw new explanatory charts/diagrams as semantic inline SVG when suitable; do not pretend an SVG is a supplied photograph.
        """
    }

    private static func digest(_ value: String) -> String {
        String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
    }
}
