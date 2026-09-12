import SwiftUI
import Perception
import UIKit

/// Test the actual fallback on a current Simulator without changing the production OS branch.
enum TranscriptScrollCompatibility {
    static var forceLegacy: Bool {
#if DEBUG
        FirasCompatibility.forceLegacyUI || ProcessInfo.processInfo.arguments.contains("--firas-force-legacy-scroll")
#else
        false
#endif
    }
}

struct LegacyTranscriptGeometry: Equatable {
    let height: CGFloat
    let viewport: CGFloat
    let minimumY: CGFloat
    let maximumY: CGFloat
    let offsetY: CGFloat

    init(height: CGFloat, viewport: CGFloat, offsetY: CGFloat, topInset: CGFloat, bottomInset: CGFloat) {
        self.height = max(0, height)
        self.viewport = max(0, viewport)
        minimumY = -topInset
        maximumY = max(-topInset, height + bottomInset - viewport)
        self.offsetY = offsetY
    }

    var distance: CGFloat { max(0, maximumY - offsetY) }
    func clamp(_ y: CGFloat) -> CGFloat { min(maximumY, max(minimumY, y)) }
}

private struct LegacyTranscriptContext: Equatable {
    let identity: String
    let latestUserID: String?
    let sending: Bool
}

/// Uses the real SwiftUI scroll view and lazy layout on iOS15–17. UIKit supplies only geometry,
/// edge scrolling and gesture observation; its delegate remains owned by SwiftUI.
struct LegacyTranscriptScroll<Content: View, JumpButton: View>: View {
    private let context: LegacyTranscriptContext
    private let motionOn: Bool
    private let onPinned: (Bool) -> Void
    private let content: Content
    private let jumpButton: (@escaping () -> Void) -> JumpButton
    @StateObject private var controller: LegacyTranscriptScrollController

    init(identity: String, latestUserID: String?, sending: Bool = false, motionOn: Bool,
         pinnedThreshold: CGFloat = 72, chipThreshold: CGFloat = 72,
         controller: LegacyTranscriptScrollController? = nil,
         onPinned: @escaping (Bool) -> Void = { _ in },
         @ViewBuilder jumpButton: @escaping (@escaping () -> Void) -> JumpButton,
         @ViewBuilder content: () -> Content) {
        context = LegacyTranscriptContext(identity: identity, latestUserID: latestUserID, sending: sending)
        self.motionOn = motionOn
        self.onPinned = onPinned
        self.content = content()
        self.jumpButton = jumpButton
        _controller = StateObject(wrappedValue: controller ?? LegacyTranscriptScrollController(
            pinnedThreshold: pinnedThreshold, chipThreshold: chipThreshold))
    }

    var body: some View {
        return WithPerceptionTracking {
        ScrollView {
            content.background(LegacyTranscriptScrollLocator(controller: controller))
        }
        .environment(\.legacyTranscriptScrollController, controller)
        .onAppear {
            controller.observe(context, animated: false)
            onPinned(controller.pinned)
        }
        .firasOnChange(of: context) { _, value in controller.observe(value, animated: motionOn) }
        .firasOnChange(of: controller.pinned) { _, value in onPinned(value) }
        .overlay(alignment: .bottom) {
            if controller.showsChip {
                jumpButton { controller.jump(animated: motionOn, dismissKeyboard: true) }
            }
        }
            }
    }
}

private struct LegacyTranscriptControllerKey: EnvironmentKey {
    static let defaultValue: LegacyTranscriptScrollController? = nil
}

private extension EnvironmentValues {
    var legacyTranscriptScrollController: LegacyTranscriptScrollController? {
        get { self[LegacyTranscriptControllerKey.self] }
        set { self[LegacyTranscriptControllerKey.self] = newValue }
    }
}

extension View {
    /// A stable message anchor only in the legacy branch; modern rows get no additional UIKit view.
    func legacyTranscriptRowAnchor(_ id: String) -> some View {
        return WithPerceptionTracking {
        modifier(LegacyTranscriptAnchorModifier(id: id))
            }
    }
}

private struct LegacyTranscriptAnchorModifier: ViewModifier {
    let id: String
    @Environment(\.legacyTranscriptScrollController) private var controller
    func body(content: Content) -> some View {
        return WithPerceptionTracking {
        if let controller {
            content.background(LegacyTranscriptRowProbe(id: id, controller: controller))
        } else { content }
            }
    }
}

@MainActor
final class LegacyTranscriptScrollController: NSObject, ObservableObject {
    @Published private(set) var pinned = true
    @Published private(set) var showsChip = false
    private let pinnedThreshold: CGFloat
    private let chipThreshold: CGFloat
    private weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var previousDismissMode: UIScrollView.KeyboardDismissMode?
    private var context: LegacyTranscriptContext?
    private var followsTail = true
    private var initialBottom = true
    private var programmatic = false
    private var animationDeadline: TimeInterval = 0
    private var correcting = false
    private var queuedRefresh = false
    private var layoutChanged = false
    private var displayLink: CADisplayLink?
    private var displayTarget: LegacyTranscriptDisplayTarget?
    private var savedAnchor: (id: String, relativeY: CGFloat)?
    private var anchors: [String: WeakLegacyTranscriptView] = [:]
#if DEBUG
    private(set) var debugRefreshCount = 0
#endif

    init(pinnedThreshold: CGFloat, chipThreshold: CGFloat) {
        self.pinnedThreshold = pinnedThreshold
        self.chipThreshold = chipThreshold
        super.init()
    }

    fileprivate func observe(_ next: LegacyTranscriptContext, animated: Bool) {
        guard context?.identity == next.identity else {
            context = next
            followsTail = true
            initialBottom = true
            savedAnchor = nil
            requestRefresh(layout: true)
            return
        }
        let sent = next.latestUserID != context?.latestUserID || (next.sending && context?.sending != true)
        context = next
        if sent { jump(animated: animated, dismissKeyboard: true) }
    }

    func jump(animated: Bool, dismissKeyboard: Bool) {
        if dismissKeyboard { Keyboard.dismiss() }
        followsTail = true
        savedAnchor = nil
        initialBottom = true
        showsChip = false
        guard let scrollView, scrollView.bounds.height > 0 else { return }
        initialBottom = false
        programmatic = animated
        animationDeadline = ProcessInfo.processInfo.systemUptime + 0.6
        moveToBottom(scrollView, animated: animated)
        if animated { startDisplayLink() }
        requestRefresh(layout: false)
    }

    fileprivate func attach(_ scroll: UIScrollView) {
        guard scrollView !== scroll else { requestRefresh(layout: true); return }
        detach()
        scrollView = scroll
        previousDismissMode = scroll.keyboardDismissMode
        scroll.keyboardDismissMode = .interactive
        scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged))
        observations = [
            scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.requestRefresh(layout: false) }
            },
            scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.requestRefresh(layout: true) }
            },
            scroll.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
                // contentOffset also changes bounds.origin. Width/height are the layout signal.
                guard let old = change.oldValue, let new = change.newValue, old.size != new.size else { return }
                Task { @MainActor in self?.requestRefresh(layout: true) }
            },
            scroll.observe(\.contentInset, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.requestRefresh(layout: true) }
            }
        ]
        requestRefresh(layout: true)
    }

    fileprivate func detach(from scroll: UIScrollView? = nil) {
        if let scroll, scrollView !== scroll { return }
        observations.removeAll()
        if let scrollView {
            scrollView.panGestureRecognizer.removeTarget(self, action: #selector(panChanged))
            if let previousDismissMode { scrollView.keyboardDismissMode = previousDismissMode }
        }
        scrollView = nil
        previousDismissMode = nil
        stopDisplayLink()
    }

    fileprivate func register(_ view: UIView, id: String) {
        anchors[id] = WeakLegacyTranscriptView(view)
        requestRefresh(layout: true)
    }

    fileprivate func unregister(_ view: UIView, id: String) {
        if anchors[id]?.view === view { anchors.removeValue(forKey: id) }
    }

    fileprivate func requestRefresh(layout: Bool) {
        guard !correcting else { return }
        layoutChanged = layoutChanged || layout
        guard !queuedRefresh else { return }
        queuedRefresh = true
        // Defer to completed layout and coalesce KVO/row callbacks. Never publish during body/layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queuedRefresh = false
            self.refresh()
        }
    }

    private func geometry(_ scroll: UIScrollView) -> LegacyTranscriptGeometry {
        LegacyTranscriptGeometry(height: scroll.contentSize.height, viewport: scroll.bounds.height,
            offsetY: scroll.contentOffset.y, topInset: scroll.adjustedContentInset.top,
            bottomInset: scroll.adjustedContentInset.bottom)
    }

    private func refresh() {
        guard let scrollView, scrollView.bounds.height > 0 else { return }
#if DEBUG
        debugRefreshCount += 1
#endif
        let changed = layoutChanged
        layoutChanged = false
        let interacting = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        if !interacting {
            if initialBottom || (changed && followsTail) {
                initialBottom = false
                moveToBottom(scrollView, animated: programmatic)
            } else if changed, !followsTail, let savedAnchor, let view = anchors[savedAnchor.id]?.view,
                      view.window != nil {
                let frame = view.convert(view.bounds, to: scrollView)
                let y = geometry(scrollView).clamp(frame.minY - savedAnchor.relativeY - scrollView.adjustedContentInset.top)
                if abs(y - scrollView.contentOffset.y) > 0.5 {
                    correcting = true
                    scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
                    correcting = false
                }
            }
        }
        let measurement = geometry(scrollView)
        let isPinned = measurement.distance <= pinnedThreshold
        if pinned != isPinned { pinned = isPinned }
        let away = measurement.distance > chipThreshold && !programmatic
        if showsChip != away { showsChip = away }
        if !followsTail, !changed || interacting { captureAnchor(scrollView) }
    }

    private func moveToBottom(_ scroll: UIScrollView, animated: Bool) {
        let y = geometry(scroll).maximumY
        guard abs(y - scroll.contentOffset.y) > 0.5 else { return }
        correcting = true
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: animated)
        correcting = false
    }

    private func captureAnchor(_ scroll: UIScrollView) {
        let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
        let bottom = scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom
        anchors = anchors.filter { $0.value.view != nil }
        let visible = anchors.compactMap { id, box -> (String, CGRect)? in
            guard let view = box.view, view.window != nil else { return nil }
            let frame = view.convert(view.bounds, to: scroll)
            guard frame.maxY > top, frame.minY < bottom else { return nil }
            return (id, frame)
        }.min { $0.1.minY < $1.1.minY }
        savedAnchor = visible.map { (id: $0.0, relativeY: $0.1.minY - top) }
    }

    @objc private func panChanged() {
        guard let scrollView else { return }
        switch scrollView.panGestureRecognizer.state {
        case .began, .changed:
            followsTail = false
            initialBottom = false
            programmatic = false
            captureAnchor(scrollView)
            startDisplayLink()
        case .ended, .cancelled, .failed:
            startDisplayLink()
        default: break
        }
        requestRefresh(layout: false)
    }

    fileprivate func displayTick() {
        guard let scrollView else { stopDisplayLink(); return }
        let interacting = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        if !interacting {
            if programmatic {
                if geometry(scrollView).distance > 1 {
                    if ProcessInfo.processInfo.systemUptime < animationDeadline { return }
                    // Native animation can be interrupted by a keyboard/layout pass. Settle at
                    // the measured edge once, and never keep a display link alive while idle.
                    moveToBottom(scrollView, animated: false)
                }
                programmatic = false
            }
            followsTail = geometry(scrollView).distance <= pinnedThreshold
            stopDisplayLink()
        }
        requestRefresh(layout: false)
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let target = LegacyTranscriptDisplayTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(LegacyTranscriptDisplayTarget.tick))
        displayTarget = target
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayTarget = nil
    }

#if DEBUG
    var debugGeometry: LegacyTranscriptGeometry? { scrollView.map(geometry) }
    var debugIsAnimating: Bool { programmatic }
    var debugAnchor: String? { savedAnchor?.id }
    var debugHasDisplayLink: Bool { displayLink != nil }
    func debugReattach() {
        guard let scrollView else { return }
        detach()
        attach(scrollView)
    }
    func debugRead(at y: CGFloat) {
        guard let scrollView else { return }
        followsTail = false
        initialBottom = false
        programmatic = false
        scrollView.setContentOffset(CGPoint(x: 0, y: geometry(scrollView).clamp(y)), animated: false)
        captureAnchor(scrollView)
        requestRefresh(layout: false)
    }
#endif
}

private final class WeakLegacyTranscriptView {
    weak var view: UIView?
    init(_ view: UIView) { self.view = view }
}

@MainActor
private final class LegacyTranscriptDisplayTarget: NSObject {
    weak var owner: LegacyTranscriptScrollController?
    init(owner: LegacyTranscriptScrollController) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.displayTick()
    }
}

private struct LegacyTranscriptScrollLocator: UIViewRepresentable {
    let controller: LegacyTranscriptScrollController
    func makeUIView(context: Context) -> LegacyTranscriptProbeView {
        LegacyTranscriptProbeView(controller: controller, anchorID: nil)
    }
    func updateUIView(_ view: LegacyTranscriptProbeView, context: Context) { view.connect() }
    static func dismantleUIView(_ view: LegacyTranscriptProbeView, coordinator: ()) { view.disconnect() }
}

private struct LegacyTranscriptRowProbe: UIViewRepresentable {
    let id: String
    let controller: LegacyTranscriptScrollController
    func makeUIView(context: Context) -> LegacyTranscriptProbeView {
        LegacyTranscriptProbeView(controller: controller, anchorID: id)
    }
    func updateUIView(_ view: LegacyTranscriptProbeView, context: Context) { view.connect() }
    static func dismantleUIView(_ view: LegacyTranscriptProbeView, coordinator: ()) { view.disconnect() }
}

private final class LegacyTranscriptProbeView: UIView {
    weak var controller: LegacyTranscriptScrollController?
    let anchorID: String?
    private weak var attachedScroll: UIScrollView?
    init(controller: LegacyTranscriptScrollController, anchorID: String?) {
        self.controller = controller
        self.anchorID = anchorID
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { return nil }
    override func didMoveToWindow() { super.didMoveToWindow(); connect() }
    override func layoutSubviews() { super.layoutSubviews(); connect() }
    func connect() {
        guard window != nil else { return }
        if let anchorID { controller?.register(self, id: anchorID) }
        else {
            var candidate = superview
            while let view = candidate {
                if let scroll = view as? UIScrollView {
                    attachedScroll = scroll
                    controller?.attach(scroll)
                    break
                }
                candidate = view.superview
            }
        }
    }
    func disconnect() {
        if let anchorID { controller?.unregister(self, id: anchorID) }
        else if let attachedScroll { controller?.detach(from: attachedScroll) }
    }
}
