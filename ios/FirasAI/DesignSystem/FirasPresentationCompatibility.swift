import SwiftUI
import UIKit

enum FirasPresentationDetent: Hashable {
    case medium
    case large
    case height(CGFloat)

    @available(iOS 16, *)
    var native: PresentationDetent {
        switch self {
        case .medium: return .medium
        case .large: return .large
        case .height(let value): return .height(max(1, value))
        }
    }
}

enum FirasPresentationIndicator { case automatic, visible, hidden }
enum FirasPresentationSizing { case form }

extension View {
    @ViewBuilder
    func firasPresentationDetents(_ detents: Set<FirasPresentationDetent>) -> some View {
        if #available(iOS 16, *), !FirasCompatibility.forceLegacyUI {
            presentationDetents(Set(detents.map(\.native)))
        } else {
            background(FirasLegacySheetPolicy(detents: detents, indicator: nil))
        }
    }

    @ViewBuilder
    func firasPresentationDragIndicator(_ indicator: FirasPresentationIndicator) -> some View {
        if #available(iOS 16, *), !FirasCompatibility.forceLegacyUI {
            switch indicator {
            case .automatic: presentationDragIndicator(.automatic)
            case .visible: presentationDragIndicator(.visible)
            case .hidden: presentationDragIndicator(.hidden)
            }
        } else {
            background(FirasLegacySheetPolicy(detents: nil, indicator: indicator))
        }
    }

    @ViewBuilder
    func firasPresentationSizing(_ sizing: FirasPresentationSizing) -> some View {
        if #available(iOS 18, *), !FirasCompatibility.forceLegacyUI {
            presentationSizing(.form)
        } else {
            // SwiftUI's existing adaptive sheet remains native on older iPhones and iPads.
            self
        }
    }
}

/// Configures only the sheet containing this view; never changes UIKit appearance globally.
private struct FirasLegacySheetPolicy: UIViewControllerRepresentable {
    let detents: Set<FirasPresentationDetent>?
    let indicator: FirasPresentationIndicator?

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.detents = detents
        controller.indicator = indicator
        controller.applyPolicy()
    }

    final class Controller: UIViewController {
        var detents: Set<FirasPresentationDetent>?
        var indicator: FirasPresentationIndicator?

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyPolicy()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyPolicy()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyPolicy()
        }

        func applyPolicy() {
            var ancestor: UIViewController? = self
            while let controller = ancestor {
                if controller.presentingViewController != nil,
                   let sheet = controller.sheetPresentationController {
                    if let detents, !detents.isEmpty {
                        // iOS 15 only has system medium/large detents. A custom-height source
                        // reader uses medium, retaining a comfortable, scrollable native sheet.
                        let medium = detents.contains { $0 != .large }
                        var values: [UISheetPresentationController.Detent] = []
                        if medium { values.append(.medium()) }
                        if detents.contains(.large) { values.append(.large()) }
                        sheet.detents = values
                    }
                    if let indicator {
                        switch indicator {
                        case .automatic: break
                        case .visible: sheet.prefersGrabberVisible = true
                        case .hidden: sheet.prefersGrabberVisible = false
                        }
                    }
                    return
                }
                ancestor = controller.parent
            }
        }
    }
}
