import Foundation

/// An error saving a receipt cannot undo a request the server already accepted.
enum CodeRequestAdmission {
    case preparing
    case submitting
    case accepted

    func requiresRecovery(after error: Error, explicitlyRejected: (Error) -> Bool) -> Bool {
        switch self {
        case .preparing: return false
        case .submitting: return !explicitlyRejected(error)
        case .accepted: return true
        }
    }
}
