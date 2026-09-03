import SwiftUI

/// The iPhone drawer: the sidebar as an interruptible overlay (`design-brief.md §3.1–3.2, §7.2`).
///
/// It owns all three layers — the 30 % scrim, the `.floating` glass panel, and the 20 pt edge zone
/// that starts an opening drag — so the shell stays a two-line `ZStack`. The offset is driven by a
/// `@GestureState`, never by a boolean flipped after an animation, which is what makes the gesture
/// grabbable mid-flight. The release decision uses Apple's deceleration projection.
@MainActor
struct CompactDrawer: View {

    private let env: AppEnvironment

    @Binding private var isOpen: Bool

    @GestureState private var dragTranslation: CGFloat = 0
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
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    var body: some View {
        GeometryReader { proxy in
            let width = Self.panelWidth(for: proxy.size.width)
            let offset = liveOffset(width: width)
            let progress = 1 + (offset / width)

            ZStack(alignment: .leading) {
                scrim(progress: progress)
                edgeGrabber(width: width)
                panel(width: width)
                    .offset(x: offset)
                    .allowsHitTesting(progress > 0.02)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    // MARK: - Layers

    /// `allowsHitTesting` is the **outermost** modifier on purpose: `contentShape` and the tap
    /// gesture are applied first, so putting the switch inside them would leave a fully transparent
    /// but tappable sheet of glass over the whole conversation while the drawer is closed.
    private func scrim(progress: CGFloat) -> some View {
        Color.black
            .opacity(0.30 * Double(max(0, min(1, progress))))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { close() }
            .accessibilityLabel(Text(Strings.Shell.closeSidebar(lang)))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { close() }
            .accessibilityHidden(progress <= 0.02)
            .allowsHitTesting(progress > 0.02)
    }

    /// A transparent strip on the leading edge. It exists only while the drawer is closed, so it
    /// never steals a horizontal swipe from the conversation underneath once the panel is out.
    @ViewBuilder
    private func edgeGrabber(width: CGFloat) -> some View {
        if !isOpen {
            Color.clear
                .frame(width: Self.edgeZone)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(drag(width: width))
                .accessibilityHidden(true)
        }
    }

    /// The glass sits in a background layer that bleeds through the bottom safe area while the
    /// sidebar's own content stays inside it — a drawer that stops above the home indicator reads
    /// as a bug, and a footer under it cannot be tapped.
    ///
    /// The close drag lives on a 24 pt strip at the trailing edge rather than on the whole panel:
    /// a full-panel `DragGesture` competes with the history list's vertical scrolling and wins
    /// often enough to feel broken.
    private func panel(width: CGFloat) -> some View {
        SidebarView(env: env)
            .frame(width: width)
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
            .shadow(color: palette.glassShadow, radius: 22, x: 6, y: 0)
            .overlay(alignment: .trailing) {
                Color.clear
                    .frame(width: 24)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(drag(width: width))
                    .accessibilityHidden(true)
            }
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel(Text(Strings.Shell.drawerTitle(lang)))
    }

    // MARK: - Gesture

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .updating($dragTranslation) { value, state, _ in
                // A drag that starts in the edge zone but travels vertically belongs to whatever
                // is scrolling underneath, not to the drawer.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation.width
            }
            .onEnded { value in
                settle(value: value, width: width)
            }
    }

    private func liveOffset(width: CGFloat) -> CGFloat {
        let base: CGFloat = isOpen ? 0 : -width
        return min(0, max(-width, base + dragTranslation))
    }

    private func settle(value: DragGesture.Value, width: CGFloat) {
        guard abs(value.translation.width) > abs(value.translation.height) else { return }
        let base: CGFloat = isOpen ? 0 : -width
        let projected = value.translation.width + value.velocity.width * Self.projectionFactor
        let landing = base + projected
        let shouldOpen = landing > -(width / 2)

        if shouldOpen != isOpen {
            Haptics.select()
        }
        withAnimation(FirasMotion.gated(FirasMotion.drawerFlick, motionOn: motionOn)) {
            isOpen = shouldOpen
        }
    }

    private func close() {
        Haptics.select()
        withAnimation(FirasMotion.gated(FirasMotion.sheet, motionOn: motionOn)) {
            isOpen = false
        }
    }

    // MARK: - Geometry

    /// `min(360, max(286, width − 44))` — the drawer always leaves a thumb's worth of the
    /// conversation visible.
    static func panelWidth(for containerWidth: CGFloat) -> CGFloat {
        let usable = max(0, containerWidth - 44)
        return min(360, max(286, usable))
    }
}
