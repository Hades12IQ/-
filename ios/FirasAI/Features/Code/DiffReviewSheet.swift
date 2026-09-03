import Foundation
import SwiftUI

// MARK: - Model
//
// These three live at file scope, not nested inside `DiffReviewSheet`. `View` is `@MainActor`, so
// anything declared as a member of a conforming struct can inherit that isolation — and the diff is
// built by `nonisolated` static functions that have to construct these values off the main actor.
// At file scope they are unambiguously non-isolated; the type aliases inside the sheet keep every
// call site reading the way it did.

/// What an edit does to one file.
enum DiffChangeKind: String, Sendable {
    case new, edit, delete, rename

    var badge: LText {
        switch self {
        case .new: return Strings.CodeUI.diffNew
        case .edit: return Strings.CodeUI.diffEdit
        case .delete: return Strings.CodeUI.diffDelete
        case .rename: return Strings.CodeUI.diffRename
        }
    }
}

/// One rendered line of a file diff.
struct DiffChangeLine: Identifiable, Sendable, Equatable {
    enum Mark: String, Sendable { case same, added, removed, gap }
    let id: Int
    let mark: Mark
    let text: String
}

/// One reviewable file in an edit plan.
struct DiffChangeItem: Identifiable, Sendable, Equatable {
    let id: String
    let kind: DiffChangeKind
    let path: String
    let renamedTo: String?
    let added: Int
    let removed: Int
    let lines: [DiffChangeLine]
    /// Set when the file is new, or too large to diff line by line.
    let fullReplacement: String?
}

/// Beyond this many changed lines on either side the row shows a full replacement instead.
private let diffLineCap = 400
private let foldThreshold = 8
private let foldContext = 3
private let replacementPreview = 4_000

/// The diff review: one row per changed file with a checkbox and a line diff, and one Apply that
/// writes only what is ticked (`web-code-ux.md §6.5`).
///
/// Nothing an edit proposes reaches the project until it is reviewed here; applying leaves a 7 s
/// undo behind it.
struct DiffReviewSheet: View {

    typealias Kind = DiffChangeKind
    typealias Line = DiffChangeLine
    typealias Item = DiffChangeItem

    private let env: AppEnvironment
    private let plan: CodeEditPlan
    private let onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var items: [Item] = []
    @State private var isBuilding = true
    @State private var selected: Set<String> = []
    @State private var expanded: Set<String> = []

    init(env: AppEnvironment, plan: CodeEditPlan, onClose: (() -> Void)? = nil) {
        self.env = env
        self.plan = plan
        self.onClose = onClose
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    var body: some View {
        NavigationStack {
            content
                .background(palette.background)
                .navigationTitle(Text(verbatim: Strings.CodeUI.diffTitle(lang)))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            close()
                        } label: {
                            Text(verbatim: Strings.Common.cancel(lang))
                        }
                    }
                }
        }
        .firasSheetBackground(palette)
        .presentationDetents([.large])
        .task { await build() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isBuilding {
            loading
        } else if items.isEmpty {
            EmptyStateView(
                title: Strings.CodeUI.diffEmpty(lang),
                subtitle: nil,
                buttonTitle: Strings.Common.close(lang),
                palette: palette,
                action: { close() }
            )
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        summary
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                    .padding(16)
                }
                applyBar
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 12) {
            SkeletonView(
                kind: .tiles,
                palette: palette,
                motionOn: FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion)
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !plan.prose.isEmpty {
                Text(verbatim: plan.prose)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .bidiIsland(for: plan.prose, fallback: lang)
            }
            HStack(spacing: 8) {
                Text(verbatim: Strings.CodeUI.fileCount(items.count, lang))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                Text(verbatim: totalsText)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(palette.textMuted)
                    .forceLTR()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(palette, radius: 9)
    }

    private var totalsText: String {
        let added = items.reduce(0) { $0 + $1.added }
        let removed = items.reduce(0) { $0 + $1.removed }
        return Strings.CodeUI.diffCounts.fmt(
            lang,
            ArabicText.count(added, lang),
            ArabicText.count(removed, lang)
        )
    }

    // MARK: - Rows

    private func row(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(item)
            if expanded.contains(item.id) {
                diffBody(item)
            }
        }
        .padding(12)
        .surfaceCard(palette, radius: 9)
    }

    private func header(_ item: Item) -> some View {
        HStack(spacing: 10) {
            Button {
                toggleSelection(item)
            } label: {
                Image(systemName: selected.contains(item.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(selected.contains(item.id) ? palette.accent : palette.textMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: item.path))
            .accessibilityAddTraits(selected.contains(item.id) ? .isSelected : [])

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.renamedTo.map { item.path + " → " + $0 } ?? item.path)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .forceLTR()

                HStack(spacing: 8) {
                    Text(verbatim: item.kind.badge(lang))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(badgeColor(item.kind))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }

                    if item.added > 0 || item.removed > 0 {
                        Text(verbatim: Strings.CodeUI.diffCounts.fmt(
                            lang,
                            ArabicText.count(item.added, lang),
                            ArabicText.count(item.removed, lang)
                        ))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.textMuted)
                        .forceLTR()
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                toggleExpansion(item)
            } label: {
                Image(systemName: expanded.contains(item.id) ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: item.path))
        }
    }

    private func badgeColor(_ kind: Kind) -> Color {
        switch kind {
        case .new: return palette.codeOk
        case .edit: return palette.textSecondary
        case .delete: return palette.error
        case .rename: return palette.planDiamond
        }
    }

    @ViewBuilder
    private func diffBody(_ item: Item) -> some View {
        if let replacement = item.fullReplacement {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: Strings.CodeUI.diffReplaceAll(lang))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textMuted)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: replacement)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .forceLTR()
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(item.lines) { line in
                        Text(verbatim: prefix(for: line) + line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: line.mark))
                            .forceLTR()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func prefix(for line: Line) -> String {
        switch line.mark {
        case .added: return "+ "
        case .removed: return "− "
        case .gap: return ""
        case .same: return "  "
        }
    }

    private func color(for mark: Line.Mark) -> Color {
        switch mark {
        case .added: return palette.codeOk
        case .removed: return palette.error
        case .gap: return palette.textMuted
        case .same: return palette.textSecondary
        }
    }

    // MARK: - Apply

    private var applyBar: some View {
        HStack(spacing: 12) {
            Button {
                close()
            } label: {
                Text(verbatim: Strings.Common.cancel(lang))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                apply()
            } label: {
                Text(verbatim: Strings.CodeUI.diffApply(lang) + " (" + ArabicText.count(selected.count, lang) + ")")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background { Capsule(style: .continuous).fill(palette.accent) }
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
            .opacity(selected.isEmpty ? 0.45 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(palette.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.border).frame(height: 0.5)
        }
    }

    private func toggleSelection(_ item: Item) {
        Haptics.select()
        if selected.contains(item.id) {
            selected.remove(item.id)
        } else {
            selected.insert(item.id)
        }
    }

    private func toggleExpansion(_ item: Item) {
        Haptics.select()
        if expanded.contains(item.id) {
            expanded.remove(item.id)
        } else {
            expanded.insert(item.id)
        }
    }

    /// `CodeStore.apply` already fires the haptic and raises the «طُبّقت التعديلات ✓» toast with
    /// its own undo button, so the sheet deliberately raises neither: two identical toasts queued
    /// back to back is what the reader saw before, each carrying an undo that the second press
    /// could no longer honour.
    private func apply() {
        guard !selected.isEmpty else { return }
        env.code.apply(plan, selected: selected)
        close()
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    // MARK: - Building

    private func build() async {
        let project = env.code.project ?? CodeProject(name: "", files: [])
        let built = await Self.buildItems(plan: plan, project: project)
        items = built
        selected = Set(built.filter { $0.kind != .delete }.map { $0.id })
        expanded = built.count <= 2 ? Set(built.map { $0.id }) : []
        isBuilding = false
    }

    /// Nonisolated so a 30-file diff is computed off the main actor.
    private nonisolated static func buildItems(plan: CodeEditPlan, project: CodeProject) async -> [Item] {
        var existing: [String: String] = [:]
        for file in project.files { existing[file.path] = file.content }

        var items: [Item] = []
        var renamedFrom: Set<String> = []
        var seen: Set<String> = []

        for rename in plan.renames {
            renamedFrom.insert(rename.from)
            guard seen.insert(rename.from).inserted else { continue }
            items.append(
                Item(
                    id: rename.from,
                    kind: .rename,
                    path: rename.from,
                    renamedTo: rename.to,
                    added: 0,
                    removed: 0,
                    lines: [],
                    fullReplacement: nil
                )
            )
        }

        for block in plan.writes {
            let before = existing[block.path]
            if let before, before == block.content { continue }
            guard seen.insert(block.path).inserted else { continue }
            items.append(item(path: block.path, before: before, after: block.content))
        }

        for path in plan.deletes where !renamedFrom.contains(path) {
            guard existing[path] != nil, seen.insert(path).inserted else { continue }
            items.append(
                Item(
                    id: path,
                    kind: .delete,
                    path: path,
                    renamedTo: nil,
                    added: 0,
                    removed: 0,
                    lines: [],
                    fullReplacement: nil
                )
            )
        }

        return items
    }

    private nonisolated static func item(path: String, before: String?, after: String) -> Item {
        guard let before else {
            return Item(
                id: path,
                kind: .new,
                path: path,
                renamedTo: nil,
                added: after.components(separatedBy: "\n").count,
                removed: 0,
                lines: [],
                fullReplacement: String(after.prefix(replacementPreview))
            )
        }

        let oldLines = before.components(separatedBy: "\n")
        let newLines = after.components(separatedBy: "\n")
        guard let diff = lineDiff(oldLines, newLines) else {
            return Item(
                id: path,
                kind: .edit,
                path: path,
                renamedTo: nil,
                added: newLines.count,
                removed: oldLines.count,
                lines: [],
                fullReplacement: String(after.prefix(replacementPreview))
            )
        }

        let added = diff.filter { $0.mark == .added }.count
        let removed = diff.filter { $0.mark == .removed }.count
        return Item(
            id: path,
            kind: .edit,
            path: path,
            renamedTo: nil,
            added: added,
            removed: removed,
            lines: fold(diff),
            fullReplacement: nil
        )
    }

    /// Common prefix and suffix are trimmed first, so most edits diff a handful of lines. When the
    /// remaining block is still huge the row falls back to a full replacement, exactly like the
    /// web beyond 1 200 lines.
    private nonisolated static func lineDiff(_ old: [String], _ new: [String]) -> [Line]? {
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] {
            tail += 1
        }

        let oldMiddle = Array(old[head..<(old.count - tail)])
        let newMiddle = Array(new[head..<(new.count - tail)])
        guard oldMiddle.count <= diffLineCap, newMiddle.count <= diffLineCap else { return nil }

        var lines: [Line] = []
        var counter = 0
        func append(_ mark: Line.Mark, _ text: String) {
            lines.append(Line(id: counter, mark: mark, text: text))
            counter += 1
        }

        for index in 0..<head { append(.same, old[index]) }

        // Longest common subsequence over the changed middle only.
        let rows = oldMiddle.count
        let columns = newMiddle.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)
        if rows > 0 && columns > 0 {
            var i = rows - 1
            while i >= 0 {
                var j = columns - 1
                while j >= 0 {
                    table[i][j] = oldMiddle[i] == newMiddle[j]
                        ? table[i + 1][j + 1] + 1
                        : max(table[i + 1][j], table[i][j + 1])
                    j -= 1
                }
                i -= 1
            }
        }

        var i = 0
        var j = 0
        while i < rows, j < columns {
            if oldMiddle[i] == newMiddle[j] {
                append(.same, oldMiddle[i])
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                append(.removed, oldMiddle[i])
                i += 1
            } else {
                append(.added, newMiddle[j])
                j += 1
            }
        }
        while i < rows { append(.removed, oldMiddle[i]); i += 1 }
        while j < columns { append(.added, newMiddle[j]); j += 1 }

        for index in (new.count - tail)..<new.count { append(.same, new[index]) }
        return lines
    }

    /// Unchanged runs longer than eight lines fold to three, a gap marker, and three.
    private nonisolated static func fold(_ lines: [Line]) -> [Line] {
        var output: [Line] = []
        var counter = 0
        var run: [Line] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count > foldThreshold {
                for line in run.prefix(foldContext) {
                    output.append(Line(id: counter, mark: .same, text: line.text))
                    counter += 1
                }
                let hidden = run.count - foldContext * 2
                output.append(Line(id: counter, mark: .gap, text: "⋯ " + String(hidden) + " ⋯"))
                counter += 1
                for line in run.suffix(foldContext) {
                    output.append(Line(id: counter, mark: .same, text: line.text))
                    counter += 1
                }
            } else {
                for line in run {
                    output.append(Line(id: counter, mark: .same, text: line.text))
                    counter += 1
                }
            }
            run = []
        }

        for line in lines {
            if line.mark == .same {
                run.append(line)
            } else {
                flushRun()
                output.append(Line(id: counter, mark: line.mark, text: line.text))
                counter += 1
            }
        }
        flushRun()
        return output
    }
}
