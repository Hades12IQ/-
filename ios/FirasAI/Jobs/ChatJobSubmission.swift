import Foundation

/// Reconciles an uncertain acknowledgement by owner + cid. Current servers provide a read-only
/// receipt lookup; callers without that capability retain the bounded same-cid compatibility
/// replay. This never appends another question, creates a new turn, or starts a stream.
@MainActor
enum ChatJobSubmission {
    static func submit(
        _ request: ChatJobRequest,
        ownerIsCurrent: () -> Bool,
        lookup: ((String) async throws -> ChatJobStartResponse?)? = nil,
        operation: (ChatJobRequest) async throws -> ChatJobStartResponse
    ) async throws -> ChatJobStartResponse {
        try Task.checkCancellation()
        guard ownerIsCurrent() else { throw CancellationError() }
        do {
            let response = try await operation(request)
            try Task.checkCancellation()
            guard ownerIsCurrent() else { throw CancellationError() }
            return response
        } catch {
            // A lost acknowledgement is not permission to send a new generation. Current servers
            // have a read-only receipt lookup; even an uncertain 5xx/decode can be reconciled there.
            if let lookup, hasReplayKey(request.cid), canReconcile(after: error) {
                try Task.checkCancellation()
                guard ownerIsCurrent() else { throw CancellationError() }
                let receipt = try await lookup(request.cid)
                try Task.checkCancellation()
                guard ownerIsCurrent() else { throw CancellationError() }
                guard let receipt else { throw error }
                return receipt
            }
            // An absent key has no idempotency guarantee. Definite HTTP refusals (including
            // quota/auth/storage errors) and decoding failures must not trigger generation again.
            guard hasReplayKey(request.cid), canReplay(after: error) else { throw error }
            try Task.checkCancellation()
            guard ownerIsCurrent() else { throw CancellationError() }
            try await Task.sleep(nanoseconds: 250_000_000)
            try Task.checkCancellation()
            guard ownerIsCurrent() else { throw CancellationError() }
            let response = try await operation(request)
            try Task.checkCancellation()
            guard ownerIsCurrent() else { throw CancellationError() }
            return response
        }
    }

    static func canReconcile(after error: Error) -> Bool {
        if canReplay(after: error) { return true }
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .http(let status, _, _): return status >= 500
        case .decoding: return true
        default: return false
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
