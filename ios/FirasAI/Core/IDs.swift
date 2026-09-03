import Foundation

/// Identifier minting and the two server sanitisers.
///
/// The server sanitises what it receives (`cid` → `[^A-Za-z0-9_-]` removed, capped at 64;
/// media job ids → `[^a-f0-9]` removed, capped at 64). We mint ids that survive both
/// untouched, and we run the same sanitisers before sending anything we did not mint.
enum IDs {

    private static let cidAlphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    private static let hexAlphabet: Set<Character> = Set("abcdef0123456789")
    private static let maxLength = 64

    /// A per-turn id: 16 characters from `[A-Za-z0-9_-]`.
    static func cid() -> String {
        var characters: [Character] = []
        characters.reserveCapacity(16)
        for _ in 0..<16 {
            characters.append(cidAlphabet.randomElement() ?? "x")
        }
        return String(characters)
    }

    /// A conversation that exists only on this device until the server gives it an id.
    static func localConversationID() -> String {
        "ios_" + UUID().uuidString.lowercased()
    }

    /// The server's `cid` sanitiser, applied client-side so we always know the id the
    /// server will store.
    static func sanitizedCid(_ raw: String) -> String {
        let filtered = raw.filter { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }
        return String(filtered.prefix(maxLength))
    }

    /// The media sanitiser: job ids are SHA-1 hex cache keys; anything else is stripped.
    static func sanitizedMediaKey(_ raw: String) -> String {
        let filtered = raw.filter { hexAlphabet.contains($0) }
        return String(filtered.prefix(maxLength))
    }
}
