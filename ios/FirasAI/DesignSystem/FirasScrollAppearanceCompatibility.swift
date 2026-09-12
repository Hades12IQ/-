import SwiftUI
import UIKit

enum FirasScrollBounceBehavior: Equatable { case automatic, always, basedOnSize }
enum FirasScrollIndicatorVisibility: Equatable { case automatic, visible, hidden }

extension View {
    @ViewBuilder
    func firasScrollBounceBehavior(_ behavior: FirasScrollBounceBehavior, axes: Axis.Set = .vertical) -> some View {
        if #available(iOS 16.4, *), !FirasCompatibility.forceLegacyUI {
            switch behavior {
            case .automatic: scrollBounceBehavior(.automatic, axes: axes)
            case .always: scrollBounceBehavior(.always, axes: axes)
            case .basedOnSize: scrollBounceBehavior(.basedOnSize, axes: axes)
            }
        } else {
            background(FirasLegacyScrollAppearance(bounce: behavior, indicators: nil, axes: axes))
        }
    }

    @ViewBuilder
    func firasScrollIndicators(_ visibility: FirasScrollIndicatorVisibility,
                               axes: Axis.Set = [.horizontal, .vertical]) -> some View {
        if #available(iOS 16, *), !FirasCompatibility.forceLegacyUI {
            switch visibility {
            case .automatic: scrollIndicators(.automatic, axes: axes)
            case .visible: scrollIndicators(.visible, axes: axes)
            case .hidden: scrollIndicators(.hidden, axes: axes)
            }
        } else {
            background(FirasLegacyScrollAppearance(bounce: nil, indicators: visibility, axes: axes))
        }
    }
}

private struct FirasLegacyScrollAppearance: UIViewRepresentable {
    let bounce: FirasScrollBounceBehavior?
    let indicators: FirasScrollIndicatorVisibility?
    let axes: Axis.Set

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.policy = self
        view.scheduleApply()
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.restore() }

    final class Probe: UIView {
        var policy: FirasLegacyScrollAppearance?
        private weak var configured: UIScrollView?
        private var original: Values?
        private var applied: Values?
        private var queued = false

        private struct Values {
            let bounces: Bool
            let horizontalBounce: Bool
            let verticalBounce: Bool
            let horizontalIndicator: Bool
            let verticalIndicator: Bool
            init(_ scroll: UIScrollView) {
                bounces = scroll.bounces
                horizontalBounce = scroll.alwaysBounceHorizontal
                verticalBounce = scroll.alwaysBounceVertical
                horizontalIndicator = scroll.showsHorizontalScrollIndicator
                verticalIndicator = scroll.showsVerticalScrollIndicator
            }
        }

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
            if let scroll = configured, let original, let applied, let policy {
                if policy.bounce != nil {
                    if scroll.bounces == applied.bounces { scroll.bounces = original.bounces }
                    if policy.axes.contains(.horizontal), scroll.alwaysBounceHorizontal == applied.horizontalBounce {
                        scroll.alwaysBounceHorizontal = original.horizontalBounce
                    }
                    if policy.axes.contains(.vertical), scroll.alwaysBounceVertical == applied.verticalBounce {
                        scroll.alwaysBounceVertical = original.verticalBounce
                    }
                }
                if policy.indicators != nil {
                    if policy.axes.contains(.horizontal), scroll.showsHorizontalScrollIndicator == applied.horizontalIndicator {
                        scroll.showsHorizontalScrollIndicator = original.horizontalIndicator
                    }
                    if policy.axes.contains(.vertical), scroll.showsVerticalScrollIndicator == applied.verticalIndicator {
                        scroll.showsVerticalScrollIndicator = original.verticalIndicator
                    }
                }
            }
            configured = nil
            original = nil
            applied = nil
        }

        private func apply() {
            guard let policy, let scroll = FirasUIKitScrollScope.nearest(to: self, accepting: { !($0 is UITextView) }) else { return }
            if configured !== scroll {
                restore()
                configured = scroll
                original = Values(scroll)
            }
            guard let original else { return }
            if let bounce = policy.bounce {
                switch bounce {
                case .automatic:
                    scroll.bounces = original.bounces
                    if policy.axes.contains(.horizontal) { scroll.alwaysBounceHorizontal = original.horizontalBounce }
                    if policy.axes.contains(.vertical) { scroll.alwaysBounceVertical = original.verticalBounce }
                case .always, .basedOnSize:
                    scroll.bounces = true
                    let always = bounce == .always
                    if policy.axes.contains(.horizontal) { scroll.alwaysBounceHorizontal = always }
                    if policy.axes.contains(.vertical) { scroll.alwaysBounceVertical = always }
                }
            }
            if let visibility = policy.indicators {
                if policy.axes.contains(.horizontal) {
                    scroll.showsHorizontalScrollIndicator = visibility == .automatic ? original.horizontalIndicator : visibility == .visible
                }
                if policy.axes.contains(.vertical) {
                    scroll.showsVerticalScrollIndicator = visibility == .automatic ? original.verticalIndicator : visibility == .visible
                }
            }
            applied = Values(scroll)
        }
    }
}
