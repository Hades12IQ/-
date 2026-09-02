import Foundation

struct AppConfiguration: Sendable {
    let apiBaseURL: URL

    static let live: AppConfiguration = {
        let configuredValue = Bundle.main.object(
            forInfoDictionaryKey: "FIRAS_API_BASE_URL"
        ) as? String
        let value = configuredValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value,
              let url = URL(string: value),
              let scheme = url.scheme,
              scheme == "https" || isLocalDevelopmentURL(url)
        else {
            return AppConfiguration(apiBaseURL: URL(string: "https://firasai.org")!)
        }

        return AppConfiguration(apiBaseURL: url)
    }()

    private static func isLocalDevelopmentURL(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
