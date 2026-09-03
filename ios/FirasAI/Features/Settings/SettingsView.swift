import SwiftUI

/// The settings sheet.
///
/// iPhone: a grouped `List` of rows that push detail pages — the shape every iOS user already
/// knows. The Codex build put a five-tab `TabView` inside a modal, which no Apple app does and
/// which grows a second floating glass slab on iOS 26 (`audit-ios-shell-settings-design.md F13`).
///
/// iPad: a `NavigationSplitView` inside a form-sized sheet, sections on the left, the page on the
/// right (`design-brief.md §8`).
@MainActor
struct SettingsView: View {

    private let env: AppEnvironment

    /// A destination inside the sheet.
    ///
    /// `SettingsSection` is frozen at five cases (`INTERFACES.md`) because it is a *route* — a
    /// deep link and `⌘,` both carry one. Privacy is a sixth **page**, not a sixth route: it is
    /// reached by tapping, never by a link, so the list and the stack speak in `Page` values and
    /// the frozen enum stays exactly as it is.
    private enum Page: Hashable {
        case section(SettingsSection)
        case privacy
    }

    /// The page on screen. On iPad it is the split selection; on iPhone it seeds the pushed page.
    @State private var section: Page
    @State private var path: [Page]

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss

    init(env: AppEnvironment, section: SettingsSection) {
        self.env = env
        _section = State(initialValue: .section(section))
        // `.account` is the default value of the route, not a request: the gear button and `⌘,`
        // both carry it. Anything else came from a deep link or a "manage this" button, and is
        // pushed straight away.
        let initial: [Page] = section == .account ? [] : [.section(section)]
        _path = State(initialValue: initial)
    }

    var body: some View {
        sized(layout)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .firasSheetBackground(env.prefs.palette)
            .tint(env.prefs.palette.accent)
            .preferredColorScheme(env.prefs.theme.isLight ? .light : .dark)
    }

    // MARK: - Layout

    @ViewBuilder
    private var layout: some View {
        if sizeClass == .regular {
            splitLayout
        } else {
            stackLayout
        }
    }

    private var stackLayout: some View {
        NavigationStack(path: $path) {
            sectionList
                .navigationTitle(Strings.Settings.title(lang))
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Page.self) { destination($0) }
                .toolbar { doneButton }
        }
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sectionList
                .navigationTitle(Strings.Settings.title(lang))
                .navigationBarTitleDisplayMode(.inline)
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 300)
        } detail: {
            NavigationStack {
                destination(section)
                    .toolbar { doneButton }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Pieces

    /* THE SELECTION BINDING BELONGS TO THE iPad ONLY. A `List(selection:)` treats a row tap as a
       selection, which on a compact width beat the `NavigationLink` inside the row to the touch —
       so every row in Settings highlighted and went nowhere, and the whole panel read as dead. The
       split view genuinely needs the binding to drive its detail column; the stack does not, and
       giving it one costs the user every button on the screen. */
    @ViewBuilder
    private var sectionList: some View {
        if sizeClass == .regular {
            List(selection: selectionBinding) { sectionListBody }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 52)
        } else {
            List { sectionListBody }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 52)
        }
    }

    @ViewBuilder
    private var sectionListBody: some View {
        Group {
            Section {
                ForEach(Self.pages, id: \.self) { item in
                    row(item)
                }
            } header: {
                Text(Strings.Settings.subtitle(lang))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textMuted)
                    .textCase(nil)
                    .bidiIsland(for: Strings.Settings.subtitle(lang), fallback: lang)
            }
            .listRowBackground(palette.surface)
        }
    }

    @ViewBuilder
    private func row(_ item: Page) -> some View {
        if sizeClass == .regular {
            rowContent(item).tag(item)
        } else {
            NavigationLink(value: item) { rowContent(item) }
        }
    }

    private func rowContent(_ item: Page) -> some View {
        let title = Self.pageTitle(item)(lang)
        return HStack(spacing: 12) {
            Image(systemName: Self.pageSymbol(item))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                Text(Self.pageSubtitle(item)(lang))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .bidiIsland(for: title, fallback: lang)
    }

    @ViewBuilder
    private func destination(_ item: Page) -> some View {
        page(item)
            .navigationTitle(Self.pageTitle(item)(lang))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.clear)
    }

    @ViewBuilder
    private func page(_ item: Page) -> some View {
        switch item {
        case .section(.account):
            AccountSettingsView(env: env)
        case .section(.appearance):
            AppearanceSettingsView(env: env)
        case .section(.chat):
            ChatSettingsView(env: env)
        case .section(.voice):
            VoiceSettingsView(env: env)
        case .section(.data):
            DataSettingsView(env: env)
        case .privacy:
            PrivacySettingsView(env: env)
        }
    }

    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button {
                env.router.sheet = nil
                dismiss()
            } label: {
                Text(Strings.Common.done(lang))
                    .font(.system(size: 16, weight: .semibold))
            }
        }
    }

    // MARK: - Page metadata
    //
    // Kept here rather than in `Strings+Settings.swift`: `SettingsSection` is a navigation type,
    // and the localization layer is not allowed to depend on `App/`.

    /// Privacy sits last, after Data: it is the page a reader goes looking for, not one they pass
    /// through, and the five routed sections keep the order every earlier build had.
    private static var pages: [Page] {
        SettingsSection.allCases.map { Page.section($0) } + [Page.privacy]
    }

    private static func pageTitle(_ item: Page) -> LText {
        switch item {
        case .section(.account): return Strings.Settings.tabAccount
        case .section(.appearance): return Strings.Settings.tabAppearance
        case .section(.chat): return Strings.Settings.tabChat
        case .section(.voice): return Strings.Settings.tabVoice
        case .section(.data): return Strings.Settings.tabData
        case .privacy: return Strings.Settings.tabPrivacy
        }
    }

    private static func pageSubtitle(_ item: Page) -> LText {
        switch item {
        case .section(.account): return Strings.Settings.tabAccountSub
        case .section(.appearance): return Strings.Settings.tabAppearanceSub
        case .section(.chat): return Strings.Settings.tabChatSub
        case .section(.voice): return Strings.Settings.tabVoiceSub
        case .section(.data): return Strings.Settings.tabDataSub
        case .privacy: return Strings.Settings.tabPrivacySub
        }
    }

    private static func pageSymbol(_ item: Page) -> String {
        switch item {
        case .section(.account): return "person.crop.circle"
        case .section(.appearance): return "paintpalette"
        case .section(.chat): return "bubble.left.and.bubble.right"
        case .section(.voice): return "waveform"
        case .section(.data): return "externaldrive"
        case .privacy: return "hand.raised"
        }
    }

    // MARK: - Plumbing

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    /// The split view's selection. A `nil` write (deselecting a row) keeps the current page rather
    /// than emptying the detail column.
    private var selectionBinding: Binding<Page?> {
        Binding(
            get: { section },
            set: { newValue in
                guard let newValue else { return }
                section = newValue
            }
        )
    }

    /// `.form` sizing is an iPad affordance; a compact sheet is always full width.
    @ViewBuilder
    private func sized<V: View>(_ view: V) -> some View {
        if sizeClass == .regular {
            view.presentationSizing(.form)
        } else {
            view
        }
    }
}
