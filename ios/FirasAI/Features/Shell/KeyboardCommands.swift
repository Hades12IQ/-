import Observation
import SwiftUI

/// The cross-screen signals the shell cannot pass down as arguments.
///
/// `SidebarView`'s initialiser is frozen at `init(env:)`, so `⌘K` cannot hand the search field a
/// binding. One main-actor observable, one flag: the keyboard layer raises it, the search field
/// lowers it the moment it takes focus.
@MainActor
@Observable
final class ShellSignals {

    static let shared = ShellSignals()

    /// Raised by `⌘K`. `SidebarSearch` consumes it on appear and on change.
    var wantsSearchFocus: Bool = false

    private init() {}

    func requestSearchFocus() {
        wantsSearchFocus = true
    }
}

/// The hardware-keyboard layer (`design-brief.md §8`).
///
/// A zero-sized, clipped stack of real buttons: `.keyboardShortcut` only exists on a live control,
/// and a control that is `.hidden()` stops responding. The stack is clipped to nothing and takes no
/// touches, so it is invisible to a finger and to VoiceOver while every shortcut stays armed.
///
/// `⌘↩` (send) is not here — it belongs to the composer's own text field, which owns the draft.
@MainActor
struct KeyboardCommands: View {

    private let env: AppEnvironment

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(env: AppEnvironment) {
        self.env = env
    }

    private var lang: AppLanguage { env.prefs.lang }

    var body: some View {
        ZStack {
            newChatButton
            searchButton
            settingsButton
            sidebarButton
            callButton
            copyAnswerButton
            stopButton
            productButtons
        }
        .frame(width: 0, height: 0)
        .clipped()
        .accessibilityHidden(true)
    }

    // MARK: - Commands

    private var newChatButton: some View {
        Button(Strings.Shell.kbNewChat(lang)) {
            Haptics.select()
            env.router.newConversation(in: env.router.product)
        }
        .keyboardShortcut("n", modifiers: .command)
    }

    private var searchButton: some View {
        Button(Strings.Shell.kbSearch(lang)) {
            /* No `withAnimation` here, and none in the two commands below: `CompactDrawer` watches
               `drawerOpen` and animates its own travel on a spring that is already gated by Reduce
               Motion. An outer transaction wrapped around the flag animates nothing — the drawer's
               `openness` has not moved yet when it commits — and it is not gated, so it was a
               spring offered to a reader who asked for none. */
            if horizontalSizeClass == .compact {
                env.router.drawerOpen = true
            }
            Task { ShellSignals.shared.requestSearchFocus() }
        }
        .keyboardShortcut("k", modifiers: .command)
    }

    private var settingsButton: some View {
        Button(Strings.Shell.kbSettings(lang)) {
            env.router.sheet = .settings(.account)
        }
        .keyboardShortcut(",", modifiers: .command)
    }

    private var sidebarButton: some View {
        Button(Strings.Shell.kbToggleSidebar(lang)) {
            Haptics.select()
            env.router.drawerOpen.toggle()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
    }

    private var callButton: some View {
        Button(Strings.Shell.kbCall(lang)) {
            guard env.router.product == .ai else { return }
            env.router.cover = .call
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
    }

    private var copyAnswerButton: some View {
        Button(Strings.Shell.kbCopyAnswer(lang)) {
            copyLastAnswer()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
    }

    private var stopButton: some View {
        Button(Strings.Shell.kbStop(lang)) {
            stopOrClose()
        }
        .keyboardShortcut(.escape, modifiers: [])
    }

    private var productButtons: some View {
        ForEach(ProductKind.allCases) { product in
            productButton(product)
        }
    }

    @ViewBuilder
    private func productButton(_ product: ProductKind) -> some View {
        if let key = Self.shortcutKey(for: product) {
            Button(Strings.Shell.kbProduct.fmt(lang, product.title(lang))) {
                Haptics.select()
                env.router.switchTo(product: product)
            }
            .keyboardShortcut(key, modifiers: .command)
        }
    }

    // MARK: - Behaviour

    private func copyLastAnswer() {
        guard
            let id = env.router.selectedConversationID,
            let conversation = env.chat.conversations[env.chat.resolve(id)],
            let answer = conversation.messages.last(where: { $0.role == .assistant })
        else {
            env.toasts.show(Strings.Shell.copyNoAnswer(lang))
            return
        }
        let body = answer.visibleContent
        guard ChatTurnActions.copy(body, env: env) else { return }
        env.toasts.show(Strings.Common.copied(lang))
    }

    /// `esc` means "get out of what is in front of me", in the order a reader expects.
    private func stopOrClose() {
        if env.router.sheet != nil {
            env.router.sheet = nil
            return
        }
        if env.router.drawerOpen {
            env.router.drawerOpen = false
            return
        }
        guard let id = env.router.selectedConversationID else { return }
        let key = env.chat.resolve(id)
        guard env.chat.states[key]?.isBusy == true else { return }
        Haptics.stop()
        Task { await env.chat.stop(in: key) }
    }

    private static func shortcutKey(for product: ProductKind) -> KeyEquivalent? {
        guard let index = ProductKind.allCases.firstIndex(of: product), index < 9 else { return nil }
        let digits: [KeyEquivalent] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
        return digits[index]
    }
}
