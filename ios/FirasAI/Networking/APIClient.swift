import Foundation
import os

/// The single door to `https://firasai.org`. No feature, store or view ever touches `URLSession`
/// directly; endpoint helpers live in `Networking/Endpoints/*.swift` as `extension APIClient`.
///
/// Credentials: the signed `firas_session` (30 d) / `firas_guest` (7 d) cookies are the *only*
/// credential. All three sessions share `HTTPCookieStorage.shared`, the jar replays them
/// verbatim, and nothing in this app ever reads, trims, copies or persists a cookie value.
///
/// Offline is decided by `NetworkMonitor`, never by a stalled request: `waitsForConnectivity` is
/// off everywhere and every call carries a `RequestBudget`.
actor APIClient {
    private let baseURL: URL
    private let standardSession: URLSession
    private let uploadSession: URLSession
    private let downloadSession: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// One element per 401 response. Consumed only by `SessionStore`; guests ignore it, because a
    /// guest 401 means "sign up", not "your session expired".
    nonisolated let unauthorized: AsyncStream<Void>
    private let unauthorizedContinuation: AsyncStream<Void>.Continuation

    init(configuration: AppConfiguration) {
        baseURL = configuration.apiBaseURL
        standardSession = NetworkSessionFactory.makeSession(.standard)
        uploadSession = NetworkSessionFactory.makeSession(.upload)
        downloadSession = NetworkSessionFactory.makeSession(.download)
        encoder = JSONEncoder()
        decoder = JSONDecoder()

        let pipe = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        unauthorized = pipe.stream
        unauthorizedContinuation = pipe.continuation
    }

    #if DEBUG
    /// A private-protocol session keeps native fault checks completely off the real network.
    init(configuration: AppConfiguration, testingSession: URLSession) {
        baseURL = configuration.apiBaseURL
        standardSession = testingSession
        uploadSession = testingSession
        downloadSession = testingSession
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        let pipe = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        unauthorized = pipe.stream
        unauthorizedContinuation = pipe.continuation
    }
    #endif

    // MARK: - Requests

    func json<T: Decodable & Sendable>(
        _ method: HTTPMethod,
        _ path: String,
        query: [String: String] = [:],
        body: (any Encodable & Sendable)? = nil,
        budget: RequestBudget = .interactive,
        as type: T.Type
    ) async throws -> T {
        let (data, _) = try await raw(method, path, query: query, body: body, budget: budget)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let detail = String(describing: error)
            #if DEBUG
            Log.net.error("decode failed for \(path): \(detail)")
            #endif
            throw APIError.decoding(detail)
        }
    }

    func raw(
        _ method: HTTPMethod,
        _ path: String,
        query: [String: String] = [:],
        body: (any Encodable & Sendable)? = nil,
        budget: RequestBudget = .interactive
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try makeRequest(method, path, query: query, body: body, budget: budget)
        do {
            let (data, response) = try await session(for: budget).data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.decoding("non-HTTP response for \(path)")
            }
            if http.statusCode == 401 {
                unauthorizedContinuation.yield(())
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(
                    status: http.statusCode,
                    server: ServerError.parse(data),
                    raw: Self.previewText(data)
                )
            }
            return (data, http)
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Server-sent events. Cancelling the consuming task closes the socket — for a live
    /// `/api/chat` stream that *is* the stop button; the server aborts upstream on close.
    func stream(
        _ method: HTTPMethod,
        _ path: String,
        query: [String: String] = [:],
        body: (any Encodable & Sendable)? = nil
    ) -> AsyncThrowingStream<SSEFrame, Error> {
        let prepared: URLRequest
        do {
            prepared = try makeRequest(method, path, query: query, body: body, budget: .stream)
        } catch {
            let failure = Self.mapped(error)
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: failure)
            }
        }

        let httpSession = standardSession
        let unauthorizedSink = unauthorizedContinuation

        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let (bytes, response) = try await httpSession.bytes(for: prepared)
                    guard let http = response as? HTTPURLResponse else {
                        throw APIError.decoding("non-HTTP response for stream")
                    }
                    if http.statusCode == 401 {
                        unauthorizedSink.yield(())
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Every 4xx/5xx arrives before the event-stream headers, so the body is
                        // an ordinary (short) JSON or text refusal.
                        let data = await APIClient.collect(bytes, limit: 8192)
                        throw APIError.http(
                            status: http.statusCode,
                            server: ServerError.parse(data),
                            raw: APIClient.previewText(data)
                        )
                    }
                    for try await frame in SSEParser.frames(from: bytes) {
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: APIClient.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Downloads to a temp file the caller must move. Video, music and artifacts are never held
    /// in memory as `Data`.
    func download(
        _ path: String,
        query: [String: String] = [:]
    ) async throws -> (url: URL, filename: String, mime: String?) {
        let request = try makeRequest(.get, path, query: query, body: nil, budget: .download)
        do {
            let (temporaryURL, response) = try await downloadSession.download(for: request)
            guard let http = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw APIError.decoding("non-HTTP response for \(path)")
            }
            if http.statusCode == 401 {
                unauthorizedContinuation.yield(())
            }
            guard (200..<300).contains(http.statusCode) else {
                let data = (try? Data(contentsOf: temporaryURL)) ?? Data()
                try? FileManager.default.removeItem(at: temporaryURL)
                throw APIError.http(
                    status: http.statusCode,
                    server: ServerError.parse(data),
                    raw: Self.previewText(data)
                )
            }

            let mime = Self.mimeType(from: http)
            let filename = Self.suggestedFilename(
                disposition: http.value(forHTTPHeaderField: "Content-Disposition"),
                url: http.url ?? request.url,
                mime: mime
            )
            let destination = Self.stableTemporaryURL(for: filename)
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                return (destination, filename, mime)
            } catch {
                // The system temp file is still valid; hand it over rather than losing the body.
                return (temporaryURL, filename, mime)
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    // MARK: - Building

    private func session(for budget: RequestBudget) -> URLSession {
        switch budget.role {
        case .standard: return standardSession
        case .upload: return uploadSession
        case .download: return downloadSession
        }
    }

    private func makeRequest(
        _ method: HTTPMethod,
        _ path: String,
        query: [String: String],
        body: (any Encodable & Sendable)?,
        budget: RequestBudget
    ) throws -> URLRequest {
        let url = try makeURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = budget.timeout
        request.httpShouldHandleCookies = true
        request.setValue(budget.accept, forHTTPHeaderField: "Accept")

        if method == .get {
            // The server sends no Cache-Control; never let URLCache answer with a stale identity.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }

        if let body {
            do {
                request.httpBody = try encoder.encode(APIEncodableBox(body))
            } catch {
                throw APIError.decoding("encode \(path): \(String(describing: error))")
            }
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func makeURL(path: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw APIError.invalidURL
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + (path.hasPrefix("/") ? path : "/" + path)

        if query.isEmpty {
            components.percentEncodedQuery = nil
        } else {
            // `URLComponents.queryItems` leaves `+` alone and the server's URLSearchParams reads
            // it as a space — a search for `C++` would arrive as `C  `.
            components.percentEncodedQueryItems = query.keys.sorted().map { key in
                URLQueryItem(
                    name: Self.escape(key),
                    value: Self.escape(query[key] ?? "")
                )
            }
        }

        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    // MARK: - Helpers (nonisolated: safe to call from the stream task)

    private nonisolated static func escape(_ value: String) -> String {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?#"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    nonisolated static func mapped(_ error: Error) -> APIError {
        if let apiError = error as? APIError { return apiError }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff:
                return .offline
            default:
                return .transport(urlError)
            }
        }
        return .transport(URLError(.unknown))
    }

    /// Reads at most `limit` bytes of an error body off a stream that never became a stream.
    private nonisolated static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            // A truncated refusal body is still better than none.
        }
        return data
    }

    /// A short, log-safe rendering of a body. Never shown to a user — `ErrorPresenter` decides
    /// copy from the status and the machine code.
    nonisolated static func previewText(_ data: Data) -> String {
        String(data: data.prefix(2048), encoding: .utf8) ?? ""
    }

    private nonisolated static func mimeType(from response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Content-Type") else { return nil }
        let value = header
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private nonisolated static func stableTemporaryURL(for filename: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("firas-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
            .appendingPathComponent("\(UUID().uuidString)-\(filename)", isDirectory: false)
    }

    /// `Content-Disposition` first (RFC 5987 form included), then the URL, then a constant.
    /// The result never contains a path separator.
    private nonisolated static func suggestedFilename(
        disposition: String?,
        url: URL?,
        mime: String?
    ) -> String {
        if let disposition {
            if let range = disposition.range(of: "filename*=UTF-8''", options: .caseInsensitive) {
                let encoded = disposition[range.upperBound...]
                    .split(separator: ";", maxSplits: 1)
                    .first
                    .map(String.init) ?? ""
                if let decoded = encoded.removingPercentEncoding {
                    let clean = safeFilename(decoded)
                    if !clean.isEmpty { return clean }
                }
            }
            if let range = disposition.range(of: "filename=", options: .caseInsensitive) {
                let value = disposition[range.upperBound...]
                    .split(separator: ";", maxSplits: 1)
                    .first
                    .map(String.init) ?? ""
                let clean = safeFilename(
                    value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
                )
                if !clean.isEmpty { return clean }
            }
        }

        if let url, !url.pathExtension.isEmpty {
            let candidate = safeFilename(url.lastPathComponent)
            if !candidate.isEmpty { return candidate }
        }

        switch mime ?? "" {
        case "image/png": return "firas-download.png"
        case "image/jpeg": return "firas-download.jpg"
        case "video/mp4": return "firas-download.mp4"
        case "audio/mpeg": return "firas-download.mp3"
        case "application/pdf": return "firas-download.pdf"
        default: return "firas-download"
        }
    }

    private nonisolated static func safeFilename(_ value: String) -> String {
        var clean = value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix(".") { clean.removeFirst() }
        return String(clean.prefix(180))
    }
}

/// Lets `APIClient` accept `any Encodable & Sendable` bodies without opening the existential at
/// every call site.
private struct APIEncodableBox: Encodable {
    private let write: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        write = { encoder in try value.encode(to: encoder) }
    }

    func encode(to encoder: Encoder) throws {
        try write(encoder)
    }
}
