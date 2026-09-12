import SwiftUI
import UIKit

enum FirasScrollKeyboardDismissMode { case automatic, immediately, interactively, never }

extension View {
    @ViewBuilder
    func firasScrollDismissesKeyboard(_ mode: FirasScrollKeyboardDismissMode) -> some View {
        if #available(iOS 16, *), !FirasCompatibility.forceLegacyUI {
            switch mode {
            case .automatic: scrollDismissesKeyboard(.automatic)
            case .immediately: scrollDismissesKeyboard(.immediately)
            case .interactively: scrollDismissesKeyboard(.interactively)
            case .never: scrollDismissesKeyboard(.never)
            }
        } else {
            background(FirasLegacyScrollKeyboardPolicy(mode: mode))
        }
    }
}

/// The legacy transcript owns its UIScrollView directly. This small scoped bridge is for
/// ordinary SwiftUI ScrollView/Form screens and never changes UIScrollView.appearance().
private struct FirasLegacyScrollKeyboardPolicy: UIViewRepresentable {
    let mode: FirasScrollKeyboardDismissMode

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        view.mode = mode
        view.scheduleApply()
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.restore() }

    final class Probe: UIView {
        var mode: FirasScrollKeyboardDismissMode = .automatic
        private weak var configured: UIScrollView?
        private var original: UIScrollView.KeyboardDismissMode?
        private var applied: UIScrollView.KeyboardDismissMode?
        private var queued = false

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { return nil }

        override func didMoveToWindow() { super.didMoveToWindow(); scheduleApply() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); scheduleApply() }

        func scheduleApply() {
            guard !queued else { return }
            queued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.queued = false
                guard self.window != nil else { self.restore(); return }
                self.apply()
            }
        }

        func restore() {
            if let configured, configured.keyboardDismissMode == applied, let original {
                configured.keyboardDismissMode = original
            }
            configured = nil
            original = nil
            applied = nil
        }

        private func apply() {
            guard let scroll = nearestScrollView() else { return }
            if configured !== scroll {
                restore()
                configured = scroll
                original = scroll.keyboardDismissMode
            }
            let value: UIScrollView.KeyboardDismissMode
            switch mode {
            case .automatic: value = original ?? .none
            case .immediately: value = .onDrag
            case .interactively: value = .interactive
            case .never: value = .none
            }
            scroll.keyboardDismissMode = value
            applied = value
        }

        private func nearestScrollView() -> UIScrollView? {
            FirasUIKitScrollScope.nearest(to: self) { !($0 is UITextView) }
        }
    }
}

/// Finds a single scroll view in the nearest containing scope. Ambiguity is refused rather
/// than changing a different pane, and traversal never reaches outside the containing window.
@MainActor
enum FirasUIKitScrollScope {
    static func nearest(to probe: UIView, accepting: (UIScrollView) -> Bool) -> UIScrollView? {
        var ancestor = probe.superview
        while let view = ancestor, !(view is UIWindow) {
            if let scroll = view as? UIScrollView, accepting(scroll) { return scroll }
            var matches: [UIScrollView] = []
            find(in: view, excluding: probe, depth: 3, accepting: accepting, results: &matches)
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { return nil }
            ancestor = view.superview
        }
        return nil
    }

    private static func find(in view: UIView, excluding probe: UIView, depth: Int,
                             accepting: (UIScrollView) -> Bool, results: inout [UIScrollView]) {
        guard depth > 0, results.count < 2, view !== probe else { return }
        for child in view.subviews {
            if let scroll = child as? UIScrollView, accepting(scroll) {
                results.append(scroll)
            } else {
                find(in: child, excluding: probe, depth: depth - 1, accepting: accepting, results: &results)
            }
            if results.count > 1 { return }
        }
    }
}
