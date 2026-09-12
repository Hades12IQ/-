import Perception
import SwiftUI
import UIKit

/// Keeps the existing share button and native 16+ preview while sharing the same item on iOS 15.
struct FirasShareLink<Label: View>: View {
    private let item: Item
    private let label: () -> Label
    @State private var anchor = FirasShareAnchor()

    init(item: URL, @ViewBuilder label: @escaping () -> Label) {
        self.item = .url(item)
        self.label = label
    }

    init(item: String, @ViewBuilder label: @escaping () -> Label) {
        self.item = .text(item)
        self.label = label
    }

    init(image: UIImage, title: String, @ViewBuilder label: @escaping () -> Label) {
        self.item = .image(image, title)
        self.label = label
    }

    var body: some View {
        WithPerceptionTracking {
            if #available(iOS 16, *), !FirasCompatibility.forceLegacyUI {
                modernLink
            } else {
                Button(action: shareLegacy) {
                    WithPerceptionTracking { label() }
                }
                .background(FirasShareAnchorView(anchor: anchor).allowsHitTesting(false))
            }
        }
    }

    @available(iOS 16, *)
    @ViewBuilder
    private var modernLink: some View {
        switch item {
        case .url(let url):
            ShareLink(item: url) { WithPerceptionTracking { label() } }
        case .text(let text):
            ShareLink(item: text) { WithPerceptionTracking { label() } }
        case .image(let image, let title):
            ShareLink(item: Image(uiImage: image), preview: SharePreview(title, image: Image(uiImage: image))) {
                WithPerceptionTracking { label() }
            }
        }
    }

    private func shareLegacy() {
        let sheet: FirasActivitySheet
        switch item {
        case .url(let url): sheet = FirasActivitySheet(url: url)
        case .text(let text): sheet = FirasActivitySheet(text: text)
        case .image(let image, let title): sheet = FirasActivitySheet(image: image, title: title)
        }
        let controller = sheet.makeActivityController()
        // Let the action finish before presenting; a context menu may remove its label immediately.
        DispatchQueue.main.async {
            FirasSharePresenter.present(controller, source: anchor.view)
        }
    }

    private enum Item {
        case url(URL)
        case text(String)
        case image(UIImage, String)
    }
}

@MainActor
private final class FirasShareAnchor {
    weak var view: UIView?
}

private struct FirasShareAnchorView: UIViewRepresentable {
    let anchor: FirasShareAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        anchor.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { anchor.view = uiView }
}

@MainActor
private enum FirasSharePresenter {
    static func present(_ controller: UIActivityViewController, source: UIView?) {
        let window = source?.window ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        guard var presenter = window?.rootViewController else { return }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        if let popover = controller.popoverPresentationController {
            if let source, source.window === window, !source.bounds.isEmpty {
                popover.sourceView = source
                popover.sourceRect = source.bounds
            } else {
                // Context-menu labels can already be gone. A centered, arrowless popover remains
                // attached to this scene instead of guessing a stale button's coordinates.
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                            y: presenter.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
        }
        presenter.present(controller, animated: true)
    }
}
