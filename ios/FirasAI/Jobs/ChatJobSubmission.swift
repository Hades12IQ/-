import Foundation

/// Only retries an uncertain acknowledgement, using the exact owner + cid + payload. This is
/// below the send path: it never appends another question, creates a new turn, or starts a stream.
@MainActor
enum ChatJobSubmission {
    static func submit(
        _ request: ChatJobRequest,
        ownerIsCurrent: () -> Bool,
        operation: (ChatJobRequest) async throws -> ChatJobStartResponse
    ) async throws -> ChatJobStartResponse {
        try Task.checkCancellation()
        guard ownerIsCurrent() else { throw CancellationError() }
        do {
            return try await operation(request)
        } catch {
            // An absent key has no idempotency guarantee. Definite HTTP refusals (including
            // quota/auth/storage errors) and decoding failures must not trigger generation again.
            guard hasReplayKey(request.cid), canReplay(after: error) else { throw error }
            try Task.checkCancellation()
            guard ownerIsCurrent() else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            guard ownerIsCurrent() else { throw CancellationError() }
            return try await operation(request)
        }
    }

    static func hasReplayKey(_ cid: String) -> Bool {
        !cid.isEmpty && cid.utf8.count <= 64 && cid.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func canReplay(after error: Error) -> Bool {
        if let apiError = error as? APIError {
            switch apiError {
            case .offline:
                // APIClient groups a mid-transfer connection loss with the offline family. A single
                // replay can recover an already committed job; there is no repeated offline loop.
                return true
            case .transport(let error): return transient(error)
            default: return false
            }
        }
        return (error as? URLError).map(transient) ?? false
    }

    private static func transient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
}
