import Foundation

/// Static, launch-time configuration. Read once; never mutated.
///
/// The base URL comes from the `FIRAS_API_BASE_URL` Info.plist key. Only `https` is accepted, with a
/// single exception for plain `http` against a loopback host so a developer can point the app at a
/// local `server.mjs`. Anything else falls back to production.
struct AppConfiguration: Sendable {
    let apiBaseURL: URL

    static let live: AppConfiguration = AppConfiguration(apiBaseURL: AppConfiguration.resolvedBaseURL())

    /// `Bundle.main.bundleIdentifier` with a stable fallback: the sideload signer may rewrite the
    /// bundle id, and `BackgroundRefresh.identifier` is derived from this value at runtime.
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? defaultBundleID
    }

    static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: - Resolution

    private static let defaultBundleID = "org.firasai.FirasAI"
    private static let productionBaseURLString = "https://firasai.org"
    private static let infoDictionaryKey = "FIRAS_API_BASE_URL"

    private static func resolvedBaseURL() -> URL {
        if let configured = configuredBaseURL() {
            return configured
        }
        if let production = URL(string: productionBaseURLString) {
            return production
        }
        // Unreachable in practice (the literal above is a valid URL); no force unwrap, no crash.
        return URL(fileURLWithPath: "/")
    }

    private static func configuredBaseURL() -> URL? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String else {
            return nil
        }
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        guard !value.isEmpty,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              url.host != nil
        else {
            return nil
        }
        if scheme == "https" {
            return url
        }
        if scheme == "http" && isLoopbackHost(url.host) {
            return url
        }
        return nil
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}
