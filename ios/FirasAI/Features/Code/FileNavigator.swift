import SwiftUI

/// The project's file rail: folder headings in project order, a coloured badge per extension,
/// the active file highlighted, swipe to rename or delete, and `+` for a new file with the same
/// path validation the store enforces (`web-code-ux.md §5.2`).
///
/// Paths are code, so every row's text is an LTR island even in the Arabic UI; only the folder
/// heading's count follows the reading direction.
struct FileNavigator: View {

    private let env: AppEnvironment

    @State private var collapsed: Set<String> = []
    @State private var isAdding = false
    @State private var newPath = ""
    @State private var renamingFrom: String?
    @State private var renameText = ""
    @State private var deletingPath: String?

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var files: [CodeFile] { env.code.project?.files ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.border)
            content
        }
        .background(palette.sidebar)
        .alert(Strings.Code.newFilePrompt(lang), isPresented: $isAdding) {
            TextField(Strings.Code.newFilePrompt(lang), text: $newPath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            Button(Strings.Common.cancel(lang), role: .cancel) { newPath = "" }
            Button(Strings.Common.done(lang)) {
                let wanted = newPath
                newPath = ""
                guard !wanted.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                env.code.addFile(path: wanted)
            }
        }
        .alert(Strings.Code.renameTitle(lang), isPresented: renameBinding) {
            TextField(Strings.Code.renameTitle(lang), text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            Button(Strings.Common.cancel(lang), role: .cancel) { renamingFrom = nil }
            Button(Strings.Common.rename(lang)) {
                let from = renamingFrom
                let to = renameText
                renamingFrom = nil
                guard let from, !to.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                env.code.renameFile(from: from, to: to)
            }
        }
        .alert(Strings.Code.deleteFileConfirm(lang), isPresented: deleteBinding) {
            Button(Strings.Common.cancel(lang), role: .cancel) { deletingPath = nil }
            Button(Strings.Common.delete(lang), role: .destructive) {
                let path = deletingPath
                deletingPath = nil
                if let path { env.code.deleteFile(path: path) }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(Strings.Code.filesHeader(lang))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textSecondary)

            Text(Strings.Code.fileCount(files.count, lang))
                .font(.system(size: 12))
                .foregroundStyle(palette.textMuted)

            Spacer(minLength: 0)

            Button {
                newPath = ""
                isAdding = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.Code.newFile(lang)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if files.isEmpty {
            EmptyStateView(
                title: Strings.Code.noFilesTitle(lang),
                subtitle: Strings.Code.noFilesHint(lang),
                buttonTitle: Strings.Code.newFile(lang),
                palette: palette
            ) {
                newPath = ""
                isAdding = true
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(groups, id: \.directory) { group in
                    Section {
                        if !collapsed.contains(group.directory) {
                            ForEach(group.files) { file in
                                row(for: file)
                            }
                        }
                    } header: {
                        if !group.directory.isEmpty {
                            folderHeader(group)
                        }
                    }
                    .listRowBackground(palette.sidebar)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(palette.sidebar)
        }
    }

    private func folderHeader(_ group: FolderGroup) -> some View {
        Button {
            withAnimation(FirasMotion.fade) {
                if collapsed.contains(group.directory) {
                    collapsed.remove(group.directory)
                } else {
                    collapsed.insert(group.directory)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed.contains(group.directory) ? "chevron.forward" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                Text(group.directory)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(palette.textSecondary)
                    .forceLTR()
                Spacer(minLength: 0)
                Text(Strings.Code.fileCount(group.files.count, lang))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textMuted)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(for file: CodeFile) -> some View {
        let isActive = env.code.selectedPath == file.path
        return Button {
            Haptics.select()
            env.code.selectedPath = file.path
        } label: {
            HStack(spacing: 8) {
                badge(for: file)
                Text(Self.basename(file.path))
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isActive ? palette.textPrimary : palette.textSecondary)
                    .forceLTR()
                Spacer(minLength: 0)
                Text(Self.sizeLabel(file.content.count))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.textMuted)
                    .forceLTR()
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 38)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? palette.accentSoft : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(file.path))
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingPath = file.path
            } label: {
                Label(Strings.Common.delete(lang), systemImage: "trash")
            }
            Button {
                renameText = file.path
                renamingFrom = file.path
            } label: {
                Label(Strings.Common.rename(lang), systemImage: "pencil")
            }
            .tint(palette.accentDeep)
        }
        .contextMenu {
            Button {
                renameText = file.path
                renamingFrom = file.path
            } label: {
                Label(Strings.Common.rename(lang), systemImage: "pencil")
            }
            Button(role: .destructive) {
                deletingPath = file.path
            } label: {
                Label(Strings.Common.delete(lang), systemImage: "trash")
            }
        }
    }

    private func badge(for file: CodeFile) -> some View {
        let style = Self.badgeStyle(for: file.ext)
        return Text(style.glyph)
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(Color.white)
            .frame(width: 22, height: 18)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(hex: style.hex))
            }
            .accessibilityHidden(true)
    }

    // MARK: - Grouping

    private struct FolderGroup {
        let directory: String
        let files: [CodeFile]
    }

    /// Project order, never sorted: the build wrote the files in the order it planned them, and
    /// re-sorting them hides that structure.
    private var groups: [FolderGroup] {
        var order: [String] = []
        var buckets: [String: [CodeFile]] = [:]
        for file in files {
            let directory = Self.directory(of: file.path)
            if buckets[directory] == nil {
                buckets[directory] = []
                order.append(directory)
            }
            buckets[directory]?.append(file)
        }
        return order.map { FolderGroup(directory: $0, files: buckets[$0] ?? []) }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingFrom != nil },
            set: { if !$0 { renamingFrom = nil } }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deletingPath != nil },
            set: { if !$0 { deletingPath = nil } }
        )
    }

    // MARK: - Static helpers

    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    static func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    static func sizeLabel(_ characters: Int) -> String {
        let kilobytes = max(1, Int((Double(characters) / 1024).rounded()))
        return String(kilobytes) + "K"
    }

    /// `CW_FILE_BADGE`, keyed by lower-cased extension.
    static func badgeStyle(for ext: String) -> (hex: String, glyph: String) {
        switch ext {
        case "html", "htm": return ("#e34c26", "<>")
        case "css": return ("#8b5cf6", "#")
        case "js", "mjs": return ("#f7df1e", "JS")
        case "jsx": return ("#f7df1e", "JX")
        case "ts": return ("#3178c6", "TS")
        case "tsx": return ("#3178c6", "TX")
        case "json": return ("#a8a8a8", "{}")
        case "md", "markdown": return ("#519aba", "M")
        case "py": return ("#3572a5", "Py")
        case "svg": return ("#ffb13b", "◇")
        default: return ("#9aa0a6", "·")
        }
    }
}
