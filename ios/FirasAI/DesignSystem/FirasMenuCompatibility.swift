import SwiftUI

enum FirasMenuOrder {
    case automatic, fixed, priority
}

extension View {
    /// iOS 15 retains its native menu ordering; later systems keep the existing explicit policy.
    @ViewBuilder
    func firasMenuOrder(_ order: FirasMenuOrder) -> some View {
        if #available(iOS 16, *), !FirasCompatibility.forceLegacyUI {
            switch order {
            case .automatic: menuOrder(.automatic)
            case .fixed: menuOrder(.fixed)
            case .priority: menuOrder(.priority)
            }
        } else {
            self
        }
    }
}
