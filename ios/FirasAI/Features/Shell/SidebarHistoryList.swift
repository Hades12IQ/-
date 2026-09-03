import SwiftUI

/// The conversation history, filtered to the product on screen (`web-chat-ux.md §11`,
/// `design-brief.md §7.2`).
///
/// Pinned first, then the web's five date groups. A row carries the live dot while a job is still
/// running for it, renames in place, pins and deletes by swipe, and offers the same four verbs in
/// its context menu. Deleting is instant with a seven-second undo — `ChatStore.delete` owns both
/// halves of that, including the toast, so nothing here schedules a server call.
///
/// The row itself lives in `SidebarHistoryList+Row.swift` as `SidebarHistoryList.Row`, because the
/// full-page list (`AllChatsView`) shows the very same conversations as rounded cards and must not
/// be a second implementation of pinning, renaming and deleting.
@MainActor
struct SidebarHistoryList: View {

    private let env: AppEnvironment
    private let query: String
    /* How many rows the sidebar is allowed to show. `nil` means "all of them", which is what the
       full-page list passes. Ten is the sidebar's budget: a drawer is for getting back to what you
       were just doing, and a wall of two hundred titles is not that. */
    private let limit: Int?

    init(env: AppEnvironment, query: String, limit: Int? = 10) {
        self.env = env
        self.query = query
        self.limit = limit
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        let all = SidebarHistoryList.summaries(env: env, query: query)
        let visible = budgeted(all)
        if visible.isEmpty {
            ScrollView {
                Placeholder(env: env, query: query, pinnedOnly: false)
                    .padding(.top, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            list(SidebarHistoryList.buckets(of: visible), trimmed: visible.count < all.count)
        }
    }

    /// The sidebar's row budget. Pinned conversations are never trimmed away — someone pinned them
    /// precisely so they would be here — so the budget only spends itself on the rest; `nil` means
    /// "no budget", which is what the full-page list passes. A method rather than a closure inside
    /// `content`, so a multi-statement body is not type-checked as part of the `@ViewBuilder`.
    private func budgeted(_ all: [ChatSummary]) -> [ChatSummary] {
        guard let limit, all.count > limit else { return all }
        var kept = all.filter { $0.pinned }
        for row in all where !row.pinned {
            if kept.count >= limit { break }
            kept.append(row)
        }
        return kept
    }

    // MARK: - The list

    private func list(_ sections: [Bucket], trimmed: Bool) -> some View {
        List {
            ForEach(sections) { bucket in
                Section {
                    ForEach(bucket.rows) { row in
                        Row(env: env, summary: row, style: .compact)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                SidebarHistoryList.pinButton(env: env, summary: row)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                SidebarHistoryList.deleteButton(env: env, summary: row)
                            }
                    }
                } header: {
                    Text(bucket.title.text(lang))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textMuted)
                        .textCase(nil)
                }
            }

            /* The way out of the ten. Only when there is genuinely more to see — a row that opens a
               page listing the same ten would be a lie. */
            if trimmed {
                allChatsRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 10, trailing: 8))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 40)
    }

    /// «كل المحادثات» — opens the archive as its own page.
    private var allChatsRow: some View {
        Button {
            Haptics.select()
            env.router.sheet = .allChats
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                Text(Strings.Shell.allChats(lang))
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.5)
            }
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Shell.allChats(lang)))
    }

    // MARK: - Shared row actions

    /// The leading swipe verb. Shared with the full-page list so the two surfaces cannot drift.
    @ViewBuilder
    static func pinButton(env: AppEnvironment, summary: ChatSummary) -> some View {
        Button {
            Haptics.select()
            Task { await env.chat.pin(summary.id, !summary.pinned) }
        } label: {
            Label {
                Text(summary.pinned
                    ? Strings.Shell.unpin.text(env.prefs.lang)
                    : Strings.Shell.pin.text(env.prefs.lang))
            } icon: {
                Image(systemName: summary.pinned ? "pin.slash" : "pin")
            }
        }
        .tint(env.prefs.palette.accent)
    }

    /// The trailing swipe verb. `ChatStore.delete` owns the seven-second undo toast.
    @ViewBuilder
    static func deleteButton(env: AppEnvironment, summary: ChatSummary) -> some View {
        Button(role: .destructive) {
            Haptics.select()
            Task { await env.chat.delete(summary.id) }
        } label: {
            Label {
                Text(Strings.Common.delete(env.prefs.lang))
            } icon: {
                Image(systemName: "trash")
            }
        }
    }

    // MARK: - Data

    /// The conversations both surfaces list: the current product's, filtered by the search query.
    /// `ProductKind.studio` falls back to `.ai`, which is what `ChatStore.summaries(for:)` does.
    static func summaries(env: AppEnvironment, query: String) -> [ChatSummary] {
        let product = env.router.product
        let wanted: ProductKind = (product == .studio) ? .ai : product
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return env.chat.summaries(for: wanted)
        }
        return env.chat.search(needle).filter { $0.product == wanted }
    }

    struct Bucket: Identifiable {
        let id: String
        let title: LText
        let rows: [ChatSummary]
    }

    /// Pinned first, then the web's five date groups. Empty groups never draw a header.
    static func buckets(of all: [ChatSummary]) -> [Bucket] {
        let pinned = all.filter { $0.pinned }
        let rest = all.filter { !$0.pinned }

        var today: [ChatSummary] = []
        var yesterday: [ChatSummary] = []
        var week: [ChatSummary] = []
        var month: [ChatSummary] = []
        var older: [ChatSummary] = []

        let calendar = Calendar.current
        let now = Date()
        for row in rest {
            guard let stamp = timestamp(from: row.updatedAt) ?? timestamp(from: row.createdAt) else {
                older.append(row)
                continue
            }
            if calendar.isDateInToday(stamp) {
                today.append(row)
            } else if calendar.isDateInYesterday(stamp) {
                yesterday.append(row)
            } else {
                let days = now.timeIntervalSince(stamp) / 86_400
                if days < 7 {
                    week.append(row)
                } else if days < 30 {
                    month.append(row)
                } else {
                    older.append(row)
                }
            }
        }

        var out: [Bucket] = []
        if !pinned.isEmpty {
            out.append(Bucket(id: "pinned", title: Strings.Shell.groupPinned, rows: pinned))
        }
        if !today.isEmpty {
            out.append(Bucket(id: "today", title: Strings.Shell.groupToday, rows: today))
        }
        if !yesterday.isEmpty {
            out.append(Bucket(id: "yesterday", title: Strings.Shell.groupYesterday, rows: yesterday))
        }
        if !week.isEmpty {
            out.append(Bucket(id: "week", title: Strings.Shell.groupPrevious7, rows: week))
        }
        if !month.isEmpty {
            out.append(Bucket(id: "month", title: Strings.Shell.groupPrevious30, rows: month))
        }
        if !older.isEmpty {
            out.append(Bucket(id: "older", title: Strings.Shell.groupOlder, rows: older))
        }
        return out
    }

    /// Internal rather than `private` on purpose: `SidebarHistoryList+Row.swift` is a different file
    /// and a `private` member would not reach it.
    static func timestamp(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFraction.date(from: raw) { return parsed }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
