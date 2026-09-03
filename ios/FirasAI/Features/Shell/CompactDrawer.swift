import Observation
import SwiftUI
import UIKit

/// The one number the drawer and the conversation behind it both read.
///
/// `CompactDrawer.init(env:isOpen:)` is frozen and cannot hand `AppShell` a live gesture value, but
/// a *pushing* drawer needs exactly that: panel and conversation have to move on the same frame,
/// from the same spring, or the seam between them tears. So the drawer publishes one `openness` —
/// 0 closed, 1 fully open — and both sides derive their offset from it.
///
/// `openness` is a real stored value rather than something derived from `isOpen`, and that is what
/// makes every entry point behave: `Router.newConversation`, `Router.select` and `Router.switchTo`
/// all set `drawerOpen = false` with no animation of their own, a derived offset would snap for
/// each of them, and the shell cannot wrap call sites it does not own. Here the drawer notices the
/// change and animates itself.
@MainActor
@Observable
final class DrawerMotion {

    static let shared = DrawerMotion()

    /// 0 = closed, 1 = fully open. Written directly by the drag (no animation, it tracks the
    /// finger) and inside a spring by every programmatic open or close.
    var openness: CGFloat = 0

    /// The panel width measured for the current container. `CompactDrawer` writes it; `AppShell`
    /// reads it so the conversation is pushed exactly as far as the panel travels.
    var panelWidth: CGFloat = 292

    private init() {}

    /// Clamped, because a spring is allowed to overshoot past 1 and the offsets must not.
    var progress: CGFloat {
        min(1, max(0, openness))
    }

    /// The panel's own x: `-panelWidth` when closed, `0` when open.
    var panelOffset: CGFloat {
        (progress - 1) * panelWidth
    }

    /// How far the conversation is pushed. This is `panelOffset + panelWidth`, which is why the
    /// two edges stay flush at every point of the travel.
    var contentPush: CGFloat {
        progress * panelWidth
    }

    /// True once the panel is far enough out to own touches.
    var isEngaged: Bool {
        progress > 0.02
    }
}

/// The iPhone drawer (`design-brief.md §3.1–3.2, §7.2`).
///
/// It owns three layers — the 30 % scrim, the solid panel, and a **window-level** screen-edge
/// recognizer that starts an opening drag — and it publishes `DrawerMotion.shared` so the shell can
/// move the conversation with it. **The drawer pushes; it does not overlay** — the owner's «يدفع
/// المحادثة يمين و يطلع بنفس الوقت و متناسق جدا». One value, one spring, two views, grabbable
/// mid-flight because the drag writes `openness` directly instead of flipping a boolean after an
/// animation; the release decision uses Apple's deceleration projection.
@MainActor
struct CompactDrawer: View {

    private let env: AppEnvironment

    @Binding private var isOpen: Bool

    /// The `openness` the current drag started from, and the flag that says a drag is live. `nil`
    /// means no drag has been accepted — a mostly-vertical drag never sets it, so a scroll in the
    /// conversation is never mistaken for a drawer pull.
    @State private var dragOrigin: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment, isOpen: Binding<Bool>) {
        self.env = env
        _isOpen = isOpen
    }

    /// UIKit's scroll deceleration rate, rearranged: `v × d / (1 − d) / 1000`.
    private static let projectionFactor: CGFloat = 0.998 / (1 - 0.998) / 1000

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motion: DrawerMotion { DrawerMotion.shared }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    var body: some View {
        GeometryReader { proxy in
            let measured = Self.panelWidth(for: proxy.size.width)

            ZStack(alignment: .leading) {
                scrim
                panel
                edgeSwipe
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .onAppear { adopt(width: measured) }
            .onChange(of: measured) { _, newValue in motion.panelWidth = newValue }
            .onChange(of: isOpen) { _, open in animate(to: open) }
            .onDisappear { dragOrigin = nil }
        }
    }

    // MARK: - Layers

    /// `allowsHitTesting` is the **outermost** modifier on purpose: `contentShape` and the tap
    /// gesture are applied first, so putting the switch inside them would leave a fully transparent
    /// but tappable sheet of glass over the whole conversation while the drawer is closed.
    ///
    /// The scrim also carries the closing drag, so the pushed conversation can be swiped back —
    /// `simultaneousGesture` rather than `gesture` so the tap-to-close survives beside it.
    private var scrim: some View {
        let engaged = motion.isEngaged
        return Color.black
            .opacity(0.30 * Double(motion.progress))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { close() }
            .simultaneousGesture(drag)
            .accessibilityLabel(Text(Strings.Shell.closeSidebar(lang)))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { close() }
            .accessibilityHidden(!engaged)
            .allowsHitTesting(engaged)
    }

    /// The glass sits in a background layer that bleeds through the bottom safe area while the
    /// sidebar's own content stays inside it — a drawer that stops above the home indicator reads
    /// as a bug, and a footer under it cannot be tapped.
    ///
    /// The close drag lives on a 24 pt strip at the trailing edge rather than on the whole panel:
    /// a full-panel `DragGesture` competes with the history list's scrolling and wins often enough
    /// to feel broken.
    private var panel: some View {
        SidebarView(env: env)
            .frame(width: motion.panelWidth)
            .frame(maxHeight: .infinity)
            /* SOLID, NOT GLASS, at the owner's direction: "السايد بار ما اريده ليكويد كلاس اريده
               نفس كلود". A drawer is a place you read a list of conversation titles in, and glass
               puts the conversation you are leaving behind directly underneath that text. Claude's
               drawer is opaque for the same reason. Glass is now reserved for things that genuinely
               float over content you still need to see — the composer and a toast. */
            .background {
                Rectangle()
                    .fill(palette.surface)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(palette.border)
                            .frame(width: 0.5)
                            .allowsHitTesting(false)
                    }
                    .ignoresSafeArea(edges: .bottom)
            }
            /* Faded in with the travel. A fixed shadow at x: 6 draws a dark band down the leading
               edge of the conversation while the panel is parked off-screen. */
            .shadow(
                color: palette.glassShadow.opacity(Double(min(1, motion.progress * 1.6))),
                radius: 22,
                x: 6,
                y: 0
            )
            .overlay(alignment: .trailing) {
                Color.clear
                    .frame(width: 24)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(drag)
                    .accessibilityHidden(true)
            }
            .offset(x: motion.panelOffset)
            .allowsHitTesting(motion.isEngaged)
            .accessibilityHidden(!motion.isEngaged)
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel(Text(Strings.Shell.drawerTitle(lang)))
    }

    /// The opening swipe — «من اسحب من اليسار لليمين يطلع السايد بار شلون كلود».
    ///
    /// A one-point, untouchable view that installs a `UIScreenEdgePanGestureRecognizer` on the
    /// window, and that indirection is the whole point. What used to be here was a transparent
    /// 20 pt strip with a `DragGesture` on it, laid over the leading edge of the conversation:
    /// SwiftUI hit-tests the top-most view first, so the strip quietly ate every ordinary tap in
    /// that band — the toolbar's own drawer button among them — and, being a plain drag rather
    /// than an edge recognizer, it fought the transcript's scrolling too.
    ///
    /// A window recognizer has neither problem: `cancelsTouchesInView = false` keeps taps flowing
    /// to whatever is under the finger, and UIKit starts it only from the physical screen edge. It
    /// reports the finger frame by frame, exactly like the closing drag, and hands the release to
    /// the same projection rule.
    private var edgeSwipe: some View {
        DrawerEdgeSwipe(
            isEnabled: isEdgeSwipeEnabled,
            onBegan: { beginDrag() },
            onChanged: { translation in apply(translation: translation) },
            onEnded: { translation, velocity in finish(translation: translation, velocity: velocity) },
            onCancelled: { cancelDrag() }
        )
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Off while the panel is already out (the scrim owns the closing drag from there), and off
    /// behind a sheet or a cover — a window recognizer does not know what is presented over it, and
    /// pulling the drawer open underneath Settings would be a ghost.
    private var isEdgeSwipeEnabled: Bool {
        !isOpen && env.router.sheet == nil && env.router.cover == nil
    }

    // MARK: - Gesture

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in track(value) }
            .onEnded { value in settle(value) }
    }

    /// The first mostly-horizontal frame claims the drag; everything after it rides the same
    /// origin, so the panel never jumps when the gesture is adopted late.
    private func track(_ value: DragGesture.Value) {
        if dragOrigin == nil {
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            beginDrag()
        }
        apply(translation: value.translation.width)
    }

    private func settle(_ value: DragGesture.Value) {
        guard dragOrigin != nil else { return }
        finish(translation: value.translation.width, velocity: value.velocity.width)
    }

    // MARK: - The travel, shared by both gestures

    private func beginDrag() {
        guard dragOrigin == nil else { return }
        dragOrigin = motion.progress
        if motion.progress < 0.5 { Keyboard.dismiss() }
    }

    /// Tracks the finger. No animation: the panel is *under* the touch, so it moves with it.
    private func apply(translation: CGFloat) {
        guard let origin = dragOrigin else { return }
        let width = max(1, motion.panelWidth)
        motion.openness = min(1, max(0, origin + translation / width))
    }

    private func finish(translation: CGFloat, velocity: CGFloat) {
        guard let origin = dragOrigin else { return }
        dragOrigin = nil

        let width = max(1, motion.panelWidth)
        let projected = origin * width + translation + velocity * Self.projectionFactor
        let shouldOpen = projected > width / 2

        if shouldOpen != isOpen { Haptics.select() }
        withAnimation(FirasMotion.gated(FirasMotion.drawerFlick, motionOn: motionOn)) {
            motion.openness = shouldOpen ? 1 : 0
        }
        /* Set after the spring, and deliberately outside it: `animate(to:)` sees the target is
           already reached and returns, so a released drag animates once, on the flick spring. */
        if isOpen != shouldOpen { isOpen = shouldOpen }
    }

    /// A cancelled recognizer (a phone call, a system gesture taking over) springs back to wherever
    /// the drag started rather than leaving the panel stranded half-way out.
    private func cancelDrag() {
        guard dragOrigin != nil else { return }
        finish(translation: 0, velocity: 0)
    }

    // MARK: - Programmatic travel

    private func close() {
        Haptics.select()
        withAnimation(FirasMotion.gated(FirasMotion.sheet, motionOn: motionOn)) {
            motion.openness = 0
        }
        if isOpen { isOpen = false }
    }

    /// Every other way the drawer opens or closes — a toolbar button, `⌘⇧O`, picking a
    /// conversation, switching product, starting a new chat — arrives here, animated or not.
    private func animate(to open: Bool) {
        let target: CGFloat = open ? 1 : 0
        guard motion.openness != target else { return }
        if open { Keyboard.dismiss() }
        withAnimation(FirasMotion.gated(FirasMotion.sheet, motionOn: motionOn)) {
            motion.openness = target
        }
    }

    /// First layout, and every rotation after it.
    private func adopt(width: CGFloat) {
        motion.panelWidth = width
        let target: CGFloat = isOpen ? 1 : 0
        if motion.openness != target { motion.openness = target }
    }

    // MARK: - Geometry

    /// `min(316, max(268, width − 92))` — narrower than it was, at the owner's direction: «عرض
    /// السايد بار صغره شوي نفس كلود». Claude's drawer leaves a good hand's width of the
    /// conversation showing rather than a sliver, which is also what makes the tap-to-close target
    /// obvious. On a 390 pt phone this is 298 pt (it was 346); the ceiling keeps a Pro Max from
    /// turning the list into a page, the floor keeps a title readable on the smallest phone.
    static func panelWidth(for containerWidth: CGFloat) -> CGFloat {
        let usable = max(0, containerWidth - 92)
        return min(316, max(268, usable))
    }
}

// MARK: - The window-level edge recognizer

/// Installs one `UIScreenEdgePanGestureRecognizer` on the window and reports it to SwiftUI.
///
/// The view itself is inert — one point across, `isUserInteractionEnabled = false` — so it never
/// appears in a hit test. Everything happens on the window, where the recognizer watches the
/// physical left edge without covering a single point of the app.
private struct DrawerEdgeSwipe: UIViewRepresentable {

    let isEnabled: Bool
    let onBegan: @MainActor () -> Void
    let onChanged: @MainActor (CGFloat) -> Void
    let onEnded: @MainActor (CGFloat, CGFloat) -> Void
    let onCancelled: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = EdgeSwipeHostView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        push(into: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        push(into: context.coordinator)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Handed over on every update so the callbacks always close over the current view value.
    private func push(into coordinator: Coordinator) {
        coordinator.onBegan = onBegan
        coordinator.onChanged = onChanged
        coordinator.onEnded = onEnded
        coordinator.onCancelled = onCancelled
        coordinator.setEnabled(isEnabled)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency UIGestureRecognizerDelegate {

        var onBegan: @MainActor () -> Void = {}
        var onChanged: @MainActor (CGFloat) -> Void = { _ in }
        var onEnded: @MainActor (CGFloat, CGFloat) -> Void = { _, _ in }
        var onCancelled: @MainActor () -> Void = {}

        private var recognizer: UIScreenEdgePanGestureRecognizer?
        private var isEnabled = true

        func attach(to window: UIWindow?) {
            guard let window else {
                detach()
                return
            }
            if let recognizer, recognizer.view === window { return }
            detach()

            let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))
            /* Physical left: the shell is fixed left-to-right (`ARCHITECTURE §2.8`), so the drawer
               always comes from the left, in Arabic as in English. */
            pan.edges = .left
            /* The two lines that keep the rest of the app working: touches keep reaching the views
               under the finger, and nothing is delayed while UIKit makes up its mind. */
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delegate = self
            pan.isEnabled = isEnabled
            window.addGestureRecognizer(pan)
            recognizer = pan
        }

        func detach() {
            guard let recognizer else { return }
            recognizer.view?.removeGestureRecognizer(recognizer)
            self.recognizer = nil
        }

        func setEnabled(_ enabled: Bool) {
            isEnabled = enabled
            recognizer?.isEnabled = enabled
        }

        @objc
        private func handle(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view).x
            let velocity = recognizer.velocity(in: view).x
            switch recognizer.state {
            case .began:
                onBegan()
                onChanged(translation)
            case .changed:
                onChanged(translation)
            case .ended:
                onEnded(translation, velocity)
            case .cancelled, .failed:
                onCancelled()
            default:
                break
            }
        }

        /// A pushed screen owns the left edge: if a navigation stack can pop, its own edge
        /// recognizer wins and this one never starts. When there is nothing to pop that recognizer
        /// fails immediately and the drawer opens as it should.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer !== gestureRecognizer
                && otherGestureRecognizer is UIScreenEdgePanGestureRecognizer
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

/// The inert host. `didMoveToWindow` is the only reliable moment at which the window exists, both
/// on first layout and after the view is moved (a rotation, a scene restoring).
private final class EdgeSwipeHostView: UIView {

    weak var coordinator: DrawerEdgeSwipe.Coordinator?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        coordinator?.attach(to: window)
    }
}
