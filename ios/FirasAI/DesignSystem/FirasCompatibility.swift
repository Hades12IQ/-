import Foundation

enum FirasCompatibility {
    /// Exercises native legacy UI branches on an available modern simulator. This does not
    /// replace testing on iOS 15, whose SwiftUI/WebKit/Observation runtime differs.
    static let forceLegacyUI: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--reliability-legacy-ui")
        #else
        false
        #endif
    }()
}
