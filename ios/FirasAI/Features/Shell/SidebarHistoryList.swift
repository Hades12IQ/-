import SwiftUI

/// The conversation history, filtered to the product on screen (`web-chat-ux.md §11`,
/// `design-brief.md §7.2`).
///
/// Pinned first, then the web's five date groups. A row carries the live dot while a job is still
/// running for it, renames in place, pins and deletes by swipe, and offers the same four verbs in
/// its context menu. Deleting is instant with a seven-second undo — `ChatStore.delete` owns both
/// halves of that, including the toast, so nothing here schedules a server call.
@MainActor
struct SidebarHistoryList: View {

    private let env: AppEnvironment
    private let query: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var renamingID: String?
    @State private var draftTitle: String = ""
    @FocusState private var renameFocused: Bool

    init(env: AppEnvironment, query: String) {
        self.env = env
        self.query = query
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }
    private var product: ProductKind { env.router.product }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        let visible = rows
        if visible.isEmpty {
            centred { placeholder }
        } else {
            list(buckets(of: visible))
        }
    }

    private func centred<C: View>(@ViewBuilder _ inner: () -> C) -> some View {
        ScrollView {
            inner().padding(.top, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - The list

    private func list(_ sections: [Bucket]) -> some View {
        List {
            ForEach(sections) { bucket in
                Section {
                    ForEach(bucket.rows) { row in
                        rowView(row)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                            .swipeActions(edge: .leading, allowsFullSwipe: true) { pinAction(row) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteAction(row) }
                            .contextMenu { menu(for: row) }
                    }
                } header: {
                    Text(bucket.title.text(lang))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textMuted)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 40)
    }

    // MARK: - Row

    @ViewBuilder
    private func rowView(_ row: ChatSummary) -> some View {
        if renamingID == row.id {
            renameField(row)
        } else {
            Button {
                Haptics.select()
                env.router.select(conversationID: row.id, product: product)
            } label: {
                rowBody(row)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(Text(displayTitle(row)))
            .accessibilityValue(Text(env.jobs.isLive(conversationID: row.id)
                ? Strings.Shell.stillWorking.text(lang)
                : ""))
            .accessibilityAddTraits(
                env.router.selectedConversationID == row.id ? [.isButton, .isSelected] : .isButton
            )
        }
    }

    private func rowBody(_ row: ChatSummary) -> some View {
        let selected = env.router.selectedConversationID == row.id
        let title = displayTitle(row)
        return HStack(spacing: 8) {
            if env.jobs.isLive(conversationID: row.id) {
                LiveDot(palette: palette, motionOn: motionOn)
            } else if row.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                    .frame(width: 8)
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(.system(size: 14.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? palette.textPrimary : palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: title, fallback: lang)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? palette.accentSoft : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func renameField(_ row: ChatSummary) -> some View {
        TextField(text: $draftTitle) {
            Text(Strings.Shell.renamePrompt(lang))
                .foregroundStyle(palette.textMuted)
        }
        .textFieldStyle(.plain)
        .font(.system(size: 14.5))
        .foregroundStyle(palette.textPrimary)
        .focused($renameFocused)
        .submitLabel(.done)
        .onSubmit { commitRename(row) }
        .onChange(of: renameFocused) { _, focused in
            if !focused { commitRename(row) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.surfaceSunken)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.accentRing, lineWidth: 1)
        }
        .accessibilityLabel(Text(Strings.Shell.renamePrompt(lang)))
    }

    // MARK: - Actions

    @ViewBuilder
    private func pinAction(_ row: ChatSummary) -> some View {
        Button {
            Haptics.select()
            Task { await env.chat.pin(row.id, !row.pinned) }
        } label: {
            Label {
                Text(row.pinned ? Strings.Shell.unpin.text(lang) : Strings.Shell.pin.text(lang))
            } icon: {
                Image(systemName: row.pinned ? "pin.slash" : "pin")
            }
        }
        .tint(palette.accent)
    }

    @ViewBuilder
    private func deleteAction(_ row: ChatSummary) -> some View {
        Button(role: .destructive) {
            delete(row)
        } label: {
            Label {
                Text(Strings.Common.delete(lang))
            } icon: {
                Image(systemName: "trash")
            }
        }
    }

    @ViewBuilder
    private func menu(for row: ChatSummary) -> some View {
        Button {
            beginRename(row)
        } label: {
            Label {
                Text(Strings.Common.rename(lang))
            } icon: {
                Image(systemName: "pencil")
            }
        }

        Button {
            Task { await env.chat.pin(row.id, !row.pinned) }
        } label: {
            Label {
                Text(row.pinned ? Strings.Shell.unpin.text(lang) : Strings.Shell.pin.text(lang))
            } icon: {
                Image(systemName: row.pinned ? "pin.slash" : "pin")
            }
        }

        Button {
            env.router.sheet = .share(conversationID: row.id, messageCID: nil)
        } label: {
            Label {
                Text(Strings.Common.share(lang))
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }

        Divider()

        Button(role: .destructive) {
            delete(row)
        } label: {
            Label {
                Text(Strings.Common.delete(lang))
            } icon: {
                Image(systemName: "trash")
            }
        }
    }

    private func beginRename(_ row: ChatSummary) {
        draftTitle = row.title
        renamingID = row.id
        // The field does not exist until this update lands; focusing it in the same turn is a
        // no-op, so the request waits one main-actor turn.
        Task { renameFocused = true }
    }

    private func commitRename(_ row: ChatSummary) {
        guard renamingID == row.id else { return }
        let wanted = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingID = nil
        renameFocused = false
        draftTitle = ""
        guard !wanted.isEmpty, wanted != row.title else { return }
        Task { await env.chat.rename(row.id, title: wanted) }
    }

    private func delete(_ row: ChatSummary) {
        if renamingID == row.id {
            renamingID = nil
            draftTitle = ""
        }
        Haptics.select()
        Task { await env.chat.delete(row.id) }
    }

    // MARK: - Placeholders

    @ViewBuilder
    private var placeholder: some View {
        if env.chat.isLoadingList {
            SkeletonView(kind: .sidebar, palette: palette, motionOn: motionOn)
                .padding(.horizontal, 12)
        } else if let error = env.chat.listError {
            EmptyStateView(
                title: Strings.Chat.chatsLoadError.text(lang),
                subtitle: error,
                buttonTitle: Strings.Common.retry(lang),
                palette: palette
            ) {
                Task { await env.chat.loadConversations() }
            }
        } else if !trimmedQuery.isEmpty {
            EmptyStateView(
                title: Strings.Shell.searchEmptyTitle.text(lang),
                subtitle: Strings.Shell.searchEmptySubtitle.text(lang),
                buttonTitle: nil,
                palette: palette,
                action: nil
            )
        } else {
            EmptyStateView(
                title: Strings.Shell.emptyHistory(for: product).text(lang),
                subtitle: nil,
                buttonTitle: Strings.Chat.newChat(lang),
                palette: palette
            ) {
                env.router.newConversation(in: product)
            }
        }
    }

    // MARK: - Data

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rows: [ChatSummary] {
        let wanted: ProductKind = (product == .studio) ? .ai : product
        guard !trimmedQuery.isEmpty else {
            return env.chat.summaries(for: wanted)
        }
        return env.chat.search(trimmedQuery).filter { $0.product == wanted }
    }

    private struct Bucket: Identifiable {
        let id: String
        let title: LText
        let rows: [ChatSummary]
    }

    private func buckets(of all: [ChatSummary]) -> [Bucket] {
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
            guard let stamp = Self.date(from: row.updatedAt) ?? Self.date(from: row.createdAt) else {
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

    private func displayTitle(_ row: ChatSummary) -> String {
        let trimmed = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Strings.Shell.untitledChat.text(lang) : trimmed
    }

    private static func date(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFraction.date(from: raw) { return parsed }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
