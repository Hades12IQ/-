import SwiftUI

/// The whole conversation list, as its own page.
///
/// The sidebar shows only the ten most recent conversations, because a drawer is for getting back to
/// what you were just doing, not for browsing an archive. Everything past those ten lives here — and
/// the owner asked for it in Claude's shape: each conversation is a rounded card with its title
/// centred and the time it was last touched underneath, and a menu at the top switches between
/// «كل المحادثات» and «المثبّتة» with a checkmark on whichever is on.
///
/// It is deliberately not a second history implementation: `SidebarHistoryList.Row` owns the card,
/// the live dot, renaming, pinning, sharing and deleting; this page owns the filter, the search and
/// the spacing.
@MainActor
struct AllChatsView: View {

    /// The two things the top menu can show. The owner's screenshot has exactly these two.
    enum Filter: String, CaseIterable, Identifiable, Hashable {
        case all
        case pinned

        var id: String { rawValue }

        var title: LText {
            switch self {
            case .all: return Strings.Shell.allChats
            case .pinned: return Strings.Shell.groupPinned
            }
        }
    }

    private let env: AppEnvironment

    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var filter: Filter = .all

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SidebarSearch(env: env, query: $query)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 12)

                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { palette.background.ignoresSafeArea() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { filterMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text(Strings.Common.done(lang))
                    }
                }
            }
        }
        .tint(palette.accent)
    }

    // MARK: - The filter menu

    private var filterMenu: some View {
        Menu {
            ForEach(Filter.allCases) { option in
                Button {
                    guard option != filter else { return }
                    Haptics.select()
                    filter = option
                } label: {
                    if option == filter {
                        Label {
                            Text(option.title.text(lang))
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Text(option.title.text(lang))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(filter.title.text(lang))
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(palette.textPrimary)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(Strings.Shell.filterMenu.text(lang)))
        .accessibilityValue(Text(filter.title.text(lang)))
    }

    // MARK: - The cards

    @ViewBuilder
    private var content: some View {
        let rows = filtered
        if rows.isEmpty {
            ScrollView {
                SidebarHistoryList.Placeholder(
                    env: env,
                    query: query,
                    pinnedOnly: filter == .pinned
                )
                .padding(.top, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            cardList(rows)
        }
    }

    private func cardList(_ rows: [ChatSummary]) -> some View {
        List {
            if filter == .pinned {
                Section {
                    cards(rows)
                } header: {
                    header(Strings.Shell.groupPinned)
                }
            } else {
                ForEach(SidebarHistoryList.buckets(of: rows)) { bucket in
                    Section {
                        cards(bucket.rows)
                    } header: {
                        header(bucket.title)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 56)
    }

    private func cards(_ rows: [ChatSummary]) -> some View {
        ForEach(rows) { row in
            SidebarHistoryList.Row(env: env, summary: row, style: .card)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    SidebarHistoryList.pinButton(env: env, summary: row)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    SidebarHistoryList.deleteButton(env: env, summary: row)
                }
        }
    }

    private func header(_ title: LText) -> some View {
        Text(title.text(lang))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.textMuted)
            .textCase(nil)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    // MARK: - Data

    private var filtered: [ChatSummary] {
        let all = SidebarHistoryList.summaries(env: env, query: query)
        guard filter == .pinned else { return all }
        return all.filter { $0.pinned }
    }
}
