#if DEBUG
import Foundation
import Perception

@MainActor
enum FirasCompatibilityReliabilityChecks {
    static func failures() -> [String] {
        var failures: [String] = []
        func check(_ passed: Bool, _ name: String) {
            if !passed { failures.append("compatibility-" + name) }
        }

        var history = FirasChangeHistory(10)
        let initial = history.initial(11, enabled: true)
        check(initial?.0 == 11 && initial?.1 == 11, "initial-current-value")
        check(history.initial(12, enabled: true) == nil, "initial-once-per-identity")
        let change = history.changed(to: 20)
        check(change?.0 == 11 && change?.1 == 20, "old-new-transition")
        check(history.changed(to: 20) == nil, "same-value-does-not-invalidate")
        let next = history.changed(to: 21)
        check(next?.0 == 20 && next?.1 == 21, "successive-old-value")

        let state = ProbeState()
        let counter = Counter()
        withPerceptionTracking { _ = state.message } onChange: { counter.increment() }
        state.unrelated = 2
        check(counter.value == 0, "unread-property-does-not-invalidate")
        state.message = "first"
        check(counter.value == 1, "tracked-message-invalidates")
        state.message = "second"
        check(counter.value == 1, "tracking-is-one-shot")
        withPerceptionTracking { _ = state.message } onChange: { counter.increment() }
        state.message = "third"
        check(counter.value == 2, "tracking-can-rearm")

        check(FirasSymbols.availableName("firas.nonexistent.symbol", fallback: "arrow.down") == "arrow.down",
              "unavailable-symbol-has-semantic-fallback")
        return failures
    }

    @Perceptible
    fileprivate final class ProbeState {
        var message = ""
        var unrelated = 0
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}
#endif
