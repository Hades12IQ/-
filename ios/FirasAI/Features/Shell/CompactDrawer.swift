import Observation
import SwiftUI

/// The one number the drawer and the conversation behind it both read.
///
/// `CompactDrawer.init(env:isOpen:)` is frozen and cannot hand `AppShell` a live gesture value, but
/// a *pushing* drawer needs exactly that: the panel and the conversation have to move on the same
/// frame, from the same spring, or the seam between them tears. So the drawer publishes one
/// `openness` — 0 closed, 1 fully open — and both sides derive their offset from it.
///
/// `openness` is a real stored value rather than something derived from `isOpen`, and that is what
/// makes every entry point behave. `Router.newConversation`, `Router.select` and
/// `Router.switchTo` all set `drawerOpen = false` with no animation of their own; a derived offset
/// would snap for each of them, and the shell cannot wrap call sites it does not own. Here the
/// drawer notices the change and animates itself.
@MainActor
@Observable
final class DrawerMotion {

    static let shared = DrawerMotion()

    /// 0 = closed, 1 = fully open. Written directly by the drag (no animation, it tracks the
    /// finger) and inside a spring by every programmatic open or close.
    var openness: CGFloat = 0

    /// The panel width measured for the current container. `CompactDrawer` writes it; `AppShell`
    /// reads it so the conversation is pushed exactly as far as the panel travels.
    var panelWidth: CGFloat = 300

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
/// It owns three layers — the 30 % scrim, the solid panel, and the 20 pt edge zone that starts an
/// opening drag — and it publishes `DrawerMotion.shared` so the shell can move the conversation
/// with it. **The drawer pushes; it does not overlay.** That is the owner's note: «خروج السايد بار
/// مو نفس انميشن كلود، يدفع المحادثة يمين و يطلع بنفس الوقت و متناسق جدا». One value, one spring,
/// two views.
///
/// The travel is grabbable mid-flight because the drag writes `openness` directly instead of
/// flipping a boolean after an animation, and the release decision uses Apple's deceleration
/// projection.
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
    private static let edgeZone: CGFloat = 20

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motion: DrawerMotion { DrawerMotion.shared }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    var body: some View {
        GeometryReader { proxy in
            let measured = Self.panelWidth(for: proxy.size.width)

            ZStack(alignment: .leading) {
                scrim
                edgeGrabber
                panel
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

    /// A transparent strip on the leading edge. It is never removed from the tree — taking a view
    /// away mid-gesture cancels the gesture, which is exactly what an opening drag is. Once the
    /// panel is out it sits underneath it and cannot be touched anyway.
    private var edgeGrabber: some View {
        Color.clear
            .frame(width: Self.edgeZone)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(drag)
            .accessibilityHidden(true)
    }

    /// The glass sits in a background layer that bleeds through the bottom safe area while the
    /// sidebar's own content stays inside it — a drawer that stops above the home indicator reads
    /// as a bug, and a footer under it cannot be tapped.
    ///
    /// The close drag lives on a 24 pt strip at the trailing edge rather than on the whole panel:
    /// a full-panel `DragGesture` competes with the history list's vertical scrolling and wins
    /// often enough to feel broken.
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
            dragOrigin = motion.progress
            if motion.progress < 0.5 { Keyboard.dismiss() }
        }
        guard let origin = dragOrigin else { return }
        let width = max(1, motion.panelWidth)
        motion.openness = min(1, max(0, origin + value.translation.width / width))
    }

    private func settle(_ value: DragGesture.Value) {
        guard let origin = dragOrigin else { return }
        dragOrigin = nil

        let width = max(1, motion.panelWidth)
        let projected = origin * width
            + value.translation.width
            + value.velocity.width * Self.projectionFactor
        let shouldOpen = projected > width / 2

        if shouldOpen != isOpen { Haptics.select() }
        withAnimation(FirasMotion.gated(FirasMotion.drawerFlick, motionOn: motionOn)) {
            motion.openness = shouldOpen ? 1 : 0
        }
        /* Set after the spring, and deliberately outside it: `animate(to:)` sees the target is
           already reached and returns, so a released drag animates once, on the flick spring. */
        if isOpen != shouldOpen { isOpen = shouldOpen }
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

    /// `min(360, max(286, width − 44))` — the drawer always leaves a thumb's worth of the
    /// conversation visible.
    static func panelWidth(for containerWidth: CGFloat) -> CGFloat {
        let usable = max(0, containerWidth - 44)
        return min(360, max(286, usable))
    }
}
