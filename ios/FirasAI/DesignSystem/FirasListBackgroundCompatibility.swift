import SwiftUI
import UIKit

enum FirasScrollContentVisibility { case automatic, visible, hidden }

extension View {
    @ViewBuilder
    func firasScrollContentBackground(_ visibility: FirasScrollContentVisibility) -> some View {
        if #available(iOS 16, *), !FirasCompatibility.forceLegacyUI {
            switch visibility {
            case .automatic: scrollContentBackground(.automatic)
            case .visible: scrollContentBackground(.visible)
            case .hidden: scrollContentBackground(.hidden)
            }
        } else {
            background(FirasLegacyListBackground(visibility: visibility))
        }
    }
}

/// Changes the containing List/Form only, preserving every row's existing palette/style.
private struct FirasLegacyListBackground: UIViewRepresentable {
    let visibility: FirasScrollContentVisibility

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        view.visibility = visibility
        view.scheduleApply()
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.restore() }

    final class Probe: UIView {
        var visibility: FirasScrollContentVisibility = .automatic
        private weak var configured: UIScrollView?
        private var original: UIColor?
        private var appliedHidden = false
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
            if let configured, appliedHidden, configured.backgroundColor == .clear {
                configured.backgroundColor = original
            }
            configured = nil
            original = nil
            appliedHidden = false
        }

        private func apply() {
            guard let list = FirasUIKitScrollScope.nearest(to: self, accepting: {
                $0 is UITableView || $0 is UICollectionView
            }) else { return }
            if configured !== list {
                restore()
                configured = list
                original = list.backgroundColor
            }
            switch visibility {
            case .hidden:
                list.backgroundColor = .clear
                appliedHidden = true
            case .automatic, .visible:
                if appliedHidden, list.backgroundColor == .clear { list.backgroundColor = original }
                appliedHidden = false
            }
        }
    }
}
