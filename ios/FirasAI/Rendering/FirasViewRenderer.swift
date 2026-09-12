import SwiftUI
import UIKit

struct FirasProposedSize {
    var width: CGFloat?
    var height: CGFloat?
}

/// Keeps modern vector exports and supplies a native hosting renderer on iOS 15.
@MainActor
final class FirasViewRenderer<Content: View> {
    let content: Content
    var proposedSize = FirasProposedSize(width: nil, height: nil)
    var scale: CGFloat = 1

    init(content: Content) { self.content = content }

    #if DEBUG
    func renderLegacyForReliability(_ action: (CGSize, (CGContext) -> Void) -> Void) {
        renderLegacy(action)
    }
    #endif

    func render(_ action: (CGSize, (CGContext) -> Void) -> Void) {
        if #available(iOS 16, *), !FirasCompatibility.forceLegacyUI {
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(width: proposedSize.width, height: proposedSize.height)
            renderer.scale = scale
            renderer.render(renderer: action)
        } else {
            renderLegacy(action)
        }
    }

    private func renderLegacy(_ action: (CGSize, (CGContext) -> Void) -> Void) {
        let host = UIHostingController(rootView: content
            .frame(width: proposedSize.width, height: proposedSize.height)
            .fixedSize(horizontal: proposedSize.width == nil, vertical: proposedSize.height == nil)
            // A document has its own margins. Inheriting the phone's safe area after mounting
            // shifts its first line down while retaining the earlier measured height.
            .ignoresSafeArea())
        host.loadViewIfNeeded()
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        // Mount outside the visible viewport so SwiftUI resolves its native text/layout tree.
        // Measure in that same mounted environment, not before it acquires window traits.
        let parent = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        parent?.addChild(host)
        let origin = CGPoint(x: (parent?.view.bounds.maxX ?? 0) + 100, y: 0)
        host.view.frame = CGRect(origin: origin, size: CGSize(width: proposedSize.width ?? 4096,
                                                            height: proposedSize.height ?? 1))
        parent?.view.addSubview(host.view)
        host.didMove(toParent: parent)
        defer {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        let fitting = host.sizeThatFits(in: CGSize(width: proposedSize.width ?? 4096,
                                                   height: proposedSize.height ?? 32768))
        let size = CGSize(width: proposedSize.width ?? ceil(fitting.width),
                          height: proposedSize.height ?? ceil(fitting.height))
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            action(.zero, { _ in })
            return
        }
        host.view.frame = CGRect(origin: origin, size: size)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        action(size) { context in
            context.saveGState()
            // ImageRenderer's drawing closure uses a bottom-left origin; CALayer uses top-left.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            host.view.layer.render(in: context)
            context.restoreGState()
        }
    }
}
