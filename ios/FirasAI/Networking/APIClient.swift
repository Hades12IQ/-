import Foundation

nonisolated enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

nonisolated enum APIError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case invalidRequest(String)
    case transport(code: Int, message: String)
    case invalidResponse
    case httpStatus(code: Int, message: String)
    case encoding(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The API URL is invalid."
        case .invalidRequest(let message):
            message
        case .transport(_, let message):
            message
        case .invalidResponse:
            "The server returned an invalid response."
        case .httpStatus(_, let message):
            message
        case .encoding(let message):
            message
        case .decoding(let message):
            message
        }
    }

    var statusCode: Int? {
        guard case .httpStatus(let code, _) = self else { return nil }
        return code
    }
}

private nonisolated struct ServerErrorEnvelope: Decodable, Sendable {
    let error: String?
}

actor APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseURL: URL) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration)

        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func request<Response: Decodable & Sendable>(
        _ method: HTTPMethod,
        path: String,
        query: [URLQueryItem] = [],
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> Response {
        let request = try makeRequest(
            method,
            path: path,
            query: query,
            body: nil,
            cachePolicy: cachePolicy
        )
        return try await execute(request)
    }

    func request<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        _ method: HTTPMethod,
        path: String,
        query: [URLQueryItem] = [],
        body: Body,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> Response {
        let data: Data
        do {
            data = try encoder.encode(body)
        } catch {
            throw APIError.encoding("The request could not be encoded.")
        }

        let request = try makeRequest(
            method,
            path: path,
            query: query,
            body: data,
            cachePolicy: cachePolicy
        )
        return try await execute(request)
    }

    func download(
        path: String,
        query: [URLQueryItem]
    ) async throws -> AgentArtifactDownload {
        let request = try makeRequest(
            .get,
            path: path,
            query: query,
            body: nil,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        let (data, response) = try await perform(request)
        try validate(response: response, data: data)

        let mimeType = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init) ?? "application/octet-stream"
        let filename = suggestedFilename(
            from: response.value(forHTTPHeaderField: "Content-Disposition")
        )

        return AgentArtifactDownload(
            data: data,
            mimeType: mimeType,
            suggestedFilename: filename
        )
    }

    private func execute<Response: Decodable & Sendable>(
        _ request: URLRequest
    ) async throws -> Response {
        let (data, response) = try await perform(request)
        try validate(response: response, data: data)

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding("The server response did not match the expected format.")
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            return (data, httpResponse)
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            throw APIError.transport(code: error.errorCode, message: error.localizedDescription)
        } catch {
            throw APIError.transport(code: -1, message: error.localizedDescription)
        }
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            let envelope = try? decoder.decode(ServerErrorEnvelope.self, from: data)
            let message = envelope?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw APIError.httpStatus(code: response.statusCode, message: message)
        }
    }

    private func makeRequest(
        _ method: HTTPMethod,
        path: String,
        query: [URLQueryItem],
        body: Data?,
        cachePolicy: URLRequest.CachePolicy
    ) throws -> URLRequest {
        var url = baseURL
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(component))
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let finalURL = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: finalURL, cachePolicy: cachePolicy)
        request.httpMethod = method.rawValue
        request.httpShouldHandleCookies = true
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func suggestedFilename(from disposition: String?) -> String {
        guard let disposition else { return "firas-artifact" }

        if let encodedRange = disposition.range(of: "filename*=UTF-8''", options: .caseInsensitive) {
            let encoded = disposition[encodedRange.upperBound...]
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
                return safeFilename(decoded)
            }
        }

        if let filenameRange = disposition.range(of: "filename=", options: .caseInsensitive) {
            let value = disposition[filenameRange.upperBound...]
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"")) ?? ""
            if !value.isEmpty {
                return safeFilename(value)
            }
        }

        return "firas-artifact"
    }

    private func safeFilename(_ value: String) -> String {
        let clean = value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "firas-artifact" : String(clean.prefix(180))
    }
}
