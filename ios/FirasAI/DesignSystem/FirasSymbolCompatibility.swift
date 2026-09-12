import UIKit

enum FirasSymbols {
    /// Resolve before constructing Image(systemName:) so an older symbol catalogue cannot
    /// silently remove an action's icon. Call sites provide the closest semantic fallback.
    static func availableName(_ requested: String, fallback: String) -> String {
        if UIImage(systemName: requested) != nil { return requested }
        if UIImage(systemName: fallback) != nil { return fallback }
        return "questionmark.circle"
    }
}
