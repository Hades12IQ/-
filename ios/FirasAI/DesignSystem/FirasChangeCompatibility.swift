import SwiftUI

/// Preserves old/new values and initial delivery without an app-wide publisher or timer.
struct FirasChangeHistory<Value: Equatable> {
    private(set) var previous: Value
    private var appeared = false

    init(_ value: Value) { previous = value }

    mutating func initial(_ value: Value, enabled: Bool) -> (Value, Value)? {
        guard !appeared else { return nil }
        appeared = true
        previous = value
        return enabled ? (value, value) : nil
    }

    mutating func changed(to value: Value) -> (Value, Value)? {
        let old = previous
        previous = value
        return old == value ? nil : (old, value)
    }
}

private struct FirasLegacyChangeModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: (Value, Value) -> Void
    @State private var history: FirasChangeHistory<Value>

    init(value: Value, initial: Bool, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.initial = initial
        self.action = action
        _history = State(initialValue: FirasChangeHistory(value))
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let pair = history.initial(value, enabled: initial) { action(pair.0, pair.1) }
            }
            .onChange(of: value) { next in
                if let pair = history.changed(to: next) { action(pair.0, pair.1) }
            }
    }
}

extension View {
    @ViewBuilder
    func firasOnChange<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        perform action: @escaping (Value, Value) -> Void
    ) -> some View {
        if #available(iOS 17, *), !FirasCompatibility.forceLegacyUI {
            onChange(of: value, initial: initial, action)
        } else {
            modifier(FirasLegacyChangeModifier(value: value, initial: initial, action: action))
        }
    }

    func firasOnChange<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        perform action: @escaping () -> Void
    ) -> some View {
        firasOnChange(of: value, initial: initial) { _, _ in action() }
    }
}
