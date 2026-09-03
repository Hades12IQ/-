import SwiftUI

/// The ```` ```firas-project ```` block: a whole little codebase the model wrote inside one answer.
///
/// Until this card existed the fence rendered as **nothing at all** — `fenceView` returned `nil`,
/// no branch of the markdown renderer claimed it, and the reader was left with the prose around a
/// hole. That is the same class of bug as «مربع الكودات ماكو», one level up.
///
/// The card is a file list, not a workspace: the project name, how many files it holds, one row per
/// file with its path and its size, and a tapped row that opens the file inline in the same
/// `CodeBlockView` every other listing uses — so an `index.html` inside a project gets the exact
/// `معاينة / الكود` toggle a bare ```` ```html ```` fence gets. `onOpen` is offered to the host on
/// top of that for the surfaces that own a real editor.
struct ProjectCard: View {

    private let project: CodeProject
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let motionOn: Bool
    private let onOpen: (() -> Void)?

    /// The path of the file currently expanded. One at a time: a project of twelve files opened all
    /// at once is a scroll, not a card.
    @State private var openPath: String?

    init(
        project: CodeProject,
        palette: FirasPalette,
        lang: AppLanguage,
        motionOn: Bool = true,
        onOpen: (() -> Void)? = nil
    ) {
        self.project = project
        self.palette = palette
        self.lang = lang
        self.motionOn = motionOn
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            divider
            files
            if let onOpen {
                divider
                openRow(onOpen)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(palette)
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.border)
            .frame(height: 1)
    }

    // MARK: - Head

    private var head: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
            Text(titleText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(countText)
                .font(.system(size: 11))
                .foregroundStyle(palette.textMuted)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .bidiIsland(for: titleText, fallback: lang)
    }

    private var titleText: String {
        let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? ProjectCardCopy.untitled(lang) : name
    }

    private var countText: String {
        ProjectCardCopy.fileCount.fmt(lang, ArabicText.count(project.files.count, lang))
    }

    // MARK: - Files

    @ViewBuilder
    private var files: some View {
        if project.files.isEmpty {
            Text(ProjectCardCopy.empty(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .bidiIsland(for: ProjectCardCopy.empty(lang), fallback: lang)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(project.files.enumerated()), id: \.offset) { pair in
                    if pair.offset > 0 { divider }
                    fileRow(pair.element)
                }
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: CodeFile) -> some View {
        let isOpen = openPath == file.path

        VStack(alignment: .leading, spacing: 0) {
            Button {
                let target = isOpen ? nil : file.path
                withAnimation(FirasMotion.gated(FirasMotion.reveal, motionOn: motionOn)) {
                    openPath = target
                }
                Haptics.select()
            } label: {
                HStack(spacing: 10) {
                    /* Two symbols rather than one rotated one, the same way the song card's lyric
                       disclosure does it: `rotationEffect` is not mirrored for a right-to-left
                       layout, so a rotated `chevron.right` points *up* in Arabic when the file is
                       open. `chevron.forward` mirrors on its own, and `chevron.down` is down in
                       both directions. */
                    Image(systemName: isOpen ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.textMuted)
                    Text(file.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .forceLTR()
                    Spacer(minLength: 8)
                    Text(sizeText(file))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textMuted)
                        .monospacedDigit()
                        .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: file.path))

            if isOpen {
                CodeBlockView(
                    code: file.content,
                    language: file.ext.isEmpty ? nil : file.ext,
                    palette: palette,
                    collapsible: true,
                    lang: lang,
                    filename: file.path
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    /// The file's size, in the same words every other card in this folder uses
    /// (`٣٤٠ كيلوبايت`). It was a bare character count before, which rendered as a five-digit
    /// number beside a filename and read as a line number, a version, or nothing at all.
    /// `utf8.count` is the byte count and is also cheaper than `count`, which walks graphemes.
    private func sizeText(_ file: CodeFile) -> String {
        FileCardKind.size(file.content.utf8.count, lang: lang)
    }

    // MARK: - Open

    private func openRow(_ action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.select()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                Text(ProjectCardCopy.open(lang))
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .bidiIsland(for: ProjectCardCopy.open(lang), fallback: lang)
    }
}

// MARK: - Copy

/// Internal rather than private so the card can be split later without widening its storage, the
/// same reason `SongCardCopy` and `FileCardCopy` are module-level names.
enum ProjectCardCopy {
    static let untitled = LText(ar: "مشروع", en: "Project")
    static let fileCount = LText(ar: "%@ ملف", en: "%@ files")
    static let empty = LText(ar: "لا توجد ملفات في هذا المشروع.", en: "This project has no files.")
    static let open = LText(ar: "فتح في فِراس كود", en: "Open in Firas Code")
}
