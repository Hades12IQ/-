import SwiftUI

/// The settings sheet.
///
/// iPhone: a grouped `List` of five rows that push detail pages — the shape every iOS user already
/// knows. The Codex build put a five-tab `TabView` inside a modal, which no Apple app does and
/// which grows a second floating glass slab on iOS 26 (`audit-ios-shell-settings-design.md F13`).
///
/// iPad: a `NavigationSplitView` inside a form-sized sheet, sections on the left, the page on the
/// right (`design-brief.md §8`).
@MainActor
struct SettingsView: View {

    private let env: AppEnvironment

    /// The page on screen. On iPad it is the split selection; on iPhone it seeds the pushed page.
    @State private var section: SettingsSection
    @State private var path: [SettingsSection]

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss

    init(env: AppEnvironment, section: SettingsSection) {
        self.env = env
        _section = State(initialValue: section)
        // `.account` is the default value of the route, not a request: the gear button and `⌘,`
        // both carry it. Anything else came from a deep link or a "manage this" button, and is
        // pushed straight away.
        _path = State(initialValue: section == .account ? [] : [section])
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
                .navigationDestination(for: SettingsSection.self) { destination($0) }
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

    private var sectionList: some View {
        List(selection: selectionBinding) {
            Section {
                ForEach(SettingsSection.allCases, id: \.self) { item in
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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 52)
    }

    @ViewBuilder
    private func row(_ item: SettingsSection) -> some View {
        if sizeClass == .regular {
            rowContent(item).tag(item)
        } else {
            NavigationLink(value: item) { rowContent(item) }
        }
    }

    private func rowContent(_ item: SettingsSection) -> some View {
        let title = Self.sectionTitle(item)(lang)
        return HStack(spacing: 12) {
            Image(systemName: Self.sectionSymbol(item))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                Text(Self.sectionSubtitle(item)(lang))
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
    private func destination(_ item: SettingsSection) -> some View {
        page(item)
            .navigationTitle(Self.sectionTitle(item)(lang))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.clear)
    }

    @ViewBuilder
    private func page(_ item: SettingsSection) -> some View {
        switch item {
        case .account:
            AccountSettingsView(env: env)
        case .appearance:
            AppearanceSettingsView(env: env)
        case .chat:
            ChatSettingsView(env: env)
        case .voice:
            VoiceSettingsView(env: env)
        case .data:
            DataSettingsView(env: env)
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

    // MARK: - Section metadata
    //
    // Kept here rather than in `Strings+Settings.swift`: `SettingsSection` is a navigation type,
    // and the localization layer is not allowed to depend on `App/`.

    private static func sectionTitle(_ section: SettingsSection) -> LText {
        switch section {
        case .account: return Strings.Settings.tabAccount
        case .appearance: return Strings.Settings.tabAppearance
        case .chat: return Strings.Settings.tabChat
        case .voice: return Strings.Settings.tabVoice
        case .data: return Strings.Settings.tabData
        }
    }

    private static func sectionSubtitle(_ section: SettingsSection) -> LText {
        switch section {
        case .account: return Strings.Settings.tabAccountSub
        case .appearance: return Strings.Settings.tabAppearanceSub
        case .chat: return Strings.Settings.tabChatSub
        case .voice: return Strings.Settings.tabVoiceSub
        case .data: return Strings.Settings.tabDataSub
        }
    }

    private static func sectionSymbol(_ section: SettingsSection) -> String {
        switch section {
        case .account: return "person.crop.circle"
        case .appearance: return "paintpalette"
        case .chat: return "bubble.left.and.bubble.right"
        case .voice: return "waveform"
        case .data: return "externaldrive"
        }
    }

    // MARK: - Plumbing

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    /// The split view's selection. A `nil` write (deselecting a row) keeps the current page rather
    /// than emptying the detail column.
    private var selectionBinding: Binding<SettingsSection?> {
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
