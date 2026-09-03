import Foundation

/// HTTP verbs the Firas API uses. The server matches `req.url.split("?")[0]` exactly and does not
/// answer 405: a wrong verb on a known path falls through to `serveStatic` and returns 200 with
/// `text/html`, so a mistake here shows up as a decoding failure, never as a status.
enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

/// Per-call transport budget. Every endpoint helper picks one deliberately; nothing uses a
/// blanket default. The timeout is applied to `URLRequest.timeoutInterval`, which URLSession
/// treats as an *idle* timeout (time to wait for more data), so `.stream` means "300 s without a
/// single SSE byte", re-armed by the transport on every frame.
enum RequestBudget: Sendable {
    case interactive
    case poll
    case upload
    case download
    case stream

    /// Idle timeout handed to `URLRequest.timeoutInterval`.
    var timeout: TimeInterval {
        switch self {
        case .interactive: return 12
        case .poll: return 30
        case .upload: return 300
        case .download: return 60
        case .stream: return 300
        }
    }

    /// Which of the three sessions carries this call.
    var role: NetworkSessionRole {
        switch self {
        case .interactive, .poll, .stream: return .standard
        case .upload: return .upload
        case .download: return .download
        }
    }

    /// `Accept` header for the call.
    var accept: String {
        switch self {
        case .stream: return "text/event-stream"
        case .download: return "*/*"
        case .interactive, .poll, .upload: return "application/json"
        }
    }
}

/// The three `URLSession`s `APIClient` owns. All of them share `HTTPCookieStorage.shared` —
/// the signed `firas_session` / `firas_guest` cookies are the only credential and must be sent
/// exactly as received on every call, whichever session makes it.
enum NetworkSessionRole: Sendable {
    case standard
    case upload
    case download

    /// Session-wide fallback for `timeoutIntervalForRequest`; every request overrides it with its
    /// own budget, so this only covers a request built without one.
    var defaultRequestTimeout: TimeInterval {
        switch self {
        case .standard: return 60
        case .upload: return 300
        case .download: return 60
        }
    }

    /// Ceiling for a whole transfer. Long enough that a 15-minute SSE answer, a 30 MB Brain
    /// upload or a multi-megabyte video download is never cut off by the session itself.
    var resourceTimeout: TimeInterval {
        switch self {
        case .standard: return 3600
        case .upload: return 3600
        case .download: return 3600
        }
    }
}

enum NetworkSessionFactory {
    static func makeConfiguration(_ role: NetworkSessionRole) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        // Offline is reported by NetworkMonitor, never by a stalled request.
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = role.defaultRequestTimeout
        configuration.timeoutIntervalForResource = role.resourceTimeout
        // The server sends no Cache-Control; never let URLCache serve a stale identity.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsCellularAccess = true
        configuration.networkServiceType = role == .standard ? .responsiveData : .default
        return configuration
    }

    static func makeSession(_ role: NetworkSessionRole) -> URLSession {
        URLSession(configuration: makeConfiguration(role))
    }
}
