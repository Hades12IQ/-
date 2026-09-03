import SwiftUI

/// The drawer's search field (`web-chat-ux.md §11`).
///
/// A plain field, not a search tab: it filters titles on every keystroke and, from three
/// characters, `ChatStore.search` also reads the message text of conversations already loaded.
/// `⌘K` focuses it through `ShellSignals` — `SidebarView.init(env:)` is frozen, so there is no
/// binding to pass down.
@MainActor
struct SidebarSearch: View {

    private let env: AppEnvironment

    @Binding private var query: String
    @FocusState private var focused: Bool

    init(env: AppEnvironment, query: Binding<String>) {
        self.env = env
        _query = query
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var signals: ShellSignals { ShellSignals.shared }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textMuted)
                .accessibilityHidden(true)

            TextField(text: $query) {
                Text(Strings.Shell.searchPlaceholder(lang))
                    .foregroundStyle(palette.textMuted)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .foregroundStyle(palette.textPrimary)
            .submitLabel(.search)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .focused($focused)
            .accessibilityLabel(Text(Strings.Shell.searchPlaceholder(lang)))

            if !query.isEmpty {
                Button {
                    query = ""
                    focused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Strings.Shell.searchClear(lang)))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background {
            Capsule(style: .continuous).fill(palette.surfaceSunken)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(focused ? palette.accentRing : palette.border, lineWidth: 1)
        }
        .onAppear { consumeFocusRequest() }
        .onChange(of: signals.wantsSearchFocus) { _, _ in consumeFocusRequest() }
    }

    private func consumeFocusRequest() {
        guard signals.wantsSearchFocus else { return }
        signals.wantsSearchFocus = false
        focused = true
    }
}
