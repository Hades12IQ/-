import Foundation
import OSLog

/// The four logging categories used across the app, plus the redaction helper every
/// call site must run over anything that may contain a cookie, a mint token or a
/// token-file path. Nothing here ever logs a raw credential.
enum Log {

    // MARK: - Categories

    private static let subsystem: String = Bundle.main.bundleIdentifier ?? "org.firasai.FirasAI"

    static let net = Logger(subsystem: Log.subsystem, category: "net")
    static let jobs = Logger(subsystem: Log.subsystem, category: "jobs")
    static let call = Logger(subsystem: Log.subsystem, category: "call")
    static let ui = Logger(subsystem: Log.subsystem, category: "ui")

    // MARK: - Redaction

    /// Replaces the value of every known credential marker with `•••`.
    ///
    /// Handled markers: the two session cookies (`firas_session=…`, `firas_guest=…`),
    /// ephemeral mint tokens (`ek_…`) and the server's token-file paths (`auth_tokens/…`).
    static func redacted(_ s: String) -> String {
        var out = s
        for cookie in ["firas_session", "firas_guest"] {
            out = mask(out, after: cookie + "=", isTerminator: isCookieTerminator)
            out = mask(out, after: cookie + "\": \"", isTerminator: isQuoteTerminator)
            out = mask(out, after: cookie + "\":\"", isTerminator: isQuoteTerminator)
        }
        out = mask(out, after: "auth_tokens/", isTerminator: isTokenTerminator)
        out = mask(out, after: "ek_", isTerminator: isTokenTerminator)
        return out
    }

    // MARK: - Private

    private static func isCookieTerminator(_ c: Character) -> Bool {
        c == ";" || c == "," || c == "\"" || c == "'" || c == " " || c == "\n" || c == "\r" || c == "\t"
    }

    private static func isQuoteTerminator(_ c: Character) -> Bool {
        c == "\"" || c == "\n" || c == "\r"
    }

    private static func isTokenTerminator(_ c: Character) -> Bool {
        !(c.isLetter || c.isNumber || c == "_" || c == "-")
    }

    /// Walks `text`, and after every occurrence of `marker` replaces the run of
    /// characters up to the first terminator with a fixed mask.
    private static func mask(_ text: String, after marker: String, isTerminator: (Character) -> Bool) -> String {
        guard !marker.isEmpty, text.range(of: marker) != nil else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var rest = Substring(text)
        while let found = rest.range(of: marker) {
            result.append(contentsOf: rest[rest.startIndex..<found.upperBound])
            var index = found.upperBound
            while index < rest.endIndex, !isTerminator(rest[index]) {
                index = rest.index(after: index)
            }
            if index > found.upperBound {
                result.append(contentsOf: "•••")
            }
            rest = rest[index...]
        }
        result.append(contentsOf: rest)
        return result
    }
}
