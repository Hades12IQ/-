import SwiftUI

enum FirasContentTransition { case opacity }

extension View {
    @ViewBuilder
    func firasContentTransition(_ transition: FirasContentTransition) -> some View {
        if #available(iOS 16, *), !FirasCompatibility.forceLegacyUI {
            contentTransition(.opacity)
        } else {
            self.transition(.opacity)
        }
    }
}

extension Animation {
    static func firasSnappy(duration: TimeInterval = 0.5, extraBounce: Double = 0) -> Animation {
        if #available(iOS 17, *), !FirasCompatibility.forceLegacyUI {
            return .snappy(duration: duration, extraBounce: extraBounce)
        }
        return .spring(response: max(0.01, duration), dampingFraction: max(0.1, min(1, 0.85 - extraBounce)))
    }
}
