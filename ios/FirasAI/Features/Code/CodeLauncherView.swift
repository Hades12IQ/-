import SwiftUI
import UniformTypeIdentifiers

/// Firas Code's home: the hero, the create card, and the grid of projects.
///
/// The create card *is* the first-run empty state (`design-brief.md §7.9`) — a user who has never
/// built anything is not shown an apology, they are shown the box that starts a project. Once
/// projects exist the grid appears under it, and deleting the last one brings back the
/// "had some, now none" line rather than the first-run copy.
struct CodeLauncherView: View {

    private let env: AppEnvironment

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var name = ""
    @State private var brief = ""
    @State private var attachments: [PreparedAttachment] = []
    @State private var isImporting = false
    @State private var isReadingAttachments = false
    @State private var deleteCandidate: ChatSummary?

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var code: CodeStore { env.code }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                createCard
                liveBuildsStrip
                projectsSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 40)
            .readingColumn(env.prefs.contentWidth)
        }
        .background {
            FirasBackground(palette: palette, showHalo: true).ignoresSafeArea()
        }
        .navigationTitle(Strings.Code.title(lang))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await code.loadProjects()
        }
        .refreshable {
            await code.loadProjects()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: Self.acceptedTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .alert(Strings.Code.deleteProjectConfirm(lang), isPresented: deleteBinding) {
            Button(Strings.Common.cancel(lang), role: .cancel) { deleteCandidate = nil }
            Button(Strings.Common.delete(lang), role: .destructive) {
                let target = deleteCandidate
                deleteCandidate = nil
                guard let target else { return }
                Task { await code.delete(target.id) }
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                Text(Strings.Code.title(lang))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .forceLTR()
            }
            Text(Strings.Code.heroSubtitle(lang))
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .bidiIsland(for: Strings.Code.heroSubtitle(lang), fallback: lang)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: - Create card

    private var createCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(Strings.Code.namePlaceholder(lang), text: $name)
                .font(.system(size: 15))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.surfaceSunken)
                }
                .bidiIsland(for: name.isEmpty ? Strings.Code.namePlaceholder(lang) : name, fallback: lang)
                .onChange(of: name) { _, value in
                    if value.count > 60 { name = String(value.prefix(60)) }
                }

            TextField(Strings.Code.briefPlaceholder(lang), text: $brief, axis: .vertical)
                .font(.system(size: 15))
                .textFieldStyle(.plain)
                .lineLimit(4...8)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.surfaceSunken)
                }
                .bidiIsland(for: brief.isEmpty ? Strings.Code.briefPlaceholder(lang) : brief, fallback: lang)
                .onChange(of: brief) { _, value in
                    if value.count > 1_500 { brief = String(value.prefix(1_500)) }
                }

            attachmentRow
            actionRow

            if code.isGuest {
                Text(Strings.Code.guestLocalNotice(lang))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .firasGlass(.sheet, palette: palette, in: AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
    }

    private var attachmentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    isImporting = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 13, weight: .semibold))
                        Text(Strings.Code.attachFile(lang))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)

                if isReadingAttachments {
                    FirasActivityLabel(
                        text: Strings.Code.attachmentsReading(lang),
                        palette: palette,
                        motionOn: motionOn
                    )
                } else {
                    Text(Strings.Code.attachHint(lang))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textMuted)
                }
                Spacer(minLength: 0)
            }

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments, id: \.name) { attachment in
                            attachmentChip(attachment)
                        }
                    }
                }
            }
        }
    }

    private func attachmentChip(_ attachment: PreparedAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .accessibilityHidden(true)
            Text(attachment.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                attachments.removeAll { $0.name == attachment.name }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.Code.attachRemove(lang)))
        }
        .foregroundStyle(palette.textSecondary)
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(minHeight: 30)
        .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await start(withBrief: false) }
            } label: {
                Text(Strings.Code.blankProject(lang))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.surfaceSunken)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(code.isCreating)

            Button {
                Task { await start(withBrief: true) }
            } label: {
                HStack(spacing: 8) {
                    if code.isCreating {
                        ProgressView().controlSize(.small).tint(palette.onAccent)
                    }
                    Text(code.isCreating ? Strings.Code.buildingNow(lang) : Strings.Code.buildWithAI(lang))
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(palette.onAccent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 46)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.accent)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(code.isCreating || isReadingAttachments)
        }
    }

    // MARK: - Live builds

    @ViewBuilder
    private var liveBuildsStrip: some View {
        let live = env.jobs.pointers.filter { $0.kind == .codebuild && $0.lastPhase.isLive }
        if !live.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(live, id: \.id) { pointer in
                    Button {
                        guard let projectID = pointer.projectID else { return }
                        env.router.open(.code(projectID: projectID))
                    } label: {
                        HStack(spacing: 10) {
                            LiveDot(palette: palette, motionOn: motionOn)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pointer.title.isEmpty ? Strings.Code.projectFallbackName(lang) : pointer.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(palette.textPrimary)
                                    .lineLimit(1)
                                    .bidiIsland(for: pointer.title, fallback: lang)
                                Text(Strings.Code.serverKeep(lang))
                                    .font(.system(size: 12))
                                    .foregroundStyle(palette.textMuted)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Text(Strings.Code.stillBuilding(lang))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.accent)
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .surfaceCard(palette)
                }
            }
        }
    }

    // MARK: - Projects

    @ViewBuilder
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.Code.yourProjects(lang))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            if code.isLoadingProjects, code.projects.isEmpty {
                SkeletonView(kind: .tiles, palette: palette, motionOn: motionOn)
            } else if let error = code.listError, code.projects.isEmpty {
                EmptyStateView(
                    title: error,
                    subtitle: nil,
                    buttonTitle: Strings.Common.retry(lang),
                    palette: palette
                ) {
                    Task { await code.loadProjects() }
                }
            } else if code.projects.isEmpty {
                EmptyStateView(
                    title: code.deletedLastProject
                        ? Strings.Code.noProjectsLeft(lang)
                        : Strings.Code.noProjects(lang),
                    subtitle: nil,
                    buttonTitle: nil,
                    palette: palette,
                    action: nil
                )
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(code.projects) { summary in
                        projectCard(summary)
                    }
                }
            }
        }
    }

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private func projectCard(_ summary: ChatSummary) -> some View {
        Button {
            env.router.open(.code(projectID: summary.id))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(verbatim: "</>")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.accent)
                        .forceLTR()
                    Spacer(minLength: 0)
                    if code.isBuilding(projectID: summary.id) {
                        LiveDot(palette: palette, motionOn: motionOn)
                    }
                }
                Text(summary.title.isEmpty ? Strings.Code.projectFallbackName(lang) : summary.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .bidiIsland(for: summary.title, fallback: lang)

                Text(Strings.Code.fileCount(code.fileCount(for: summary.id) ?? 0, lang))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textMuted)
            }
            .padding(12)
            .frame(height: 108, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surfaceCard(palette)
        .contextMenu {
            Button(role: .destructive) {
                deleteCandidate = summary
            } label: {
                Label(Strings.Common.delete(lang), systemImage: "trash")
            }
        }
        .accessibilityLabel(Text(summary.title.isEmpty ? Strings.Code.projectFallbackName(lang) : summary.title))
    }

    // MARK: - Actions

    private func start(withBrief useBrief: Bool) async {
        guard !isReadingAttachments else {
            env.toasts.show(Strings.Code.attachmentsReading(lang))
            return
        }
        let text = useBrief ? brief : ""
        let files = useBrief ? attachments : []
        guard let id = await code.create(name: name, brief: text, attachments: files) else { return }
        name = ""
        brief = ""
        attachments = []
        env.router.open(.code(projectID: id))
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )
    }

    /// Documents only, read entirely off the main actor by the composer's own processor. A
    /// screenshot has no vision reader on this path — the build request carries text, never image
    /// bytes (`server-code-brainask.md §2.1`) — so pictures are not offered here at all.
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        isReadingAttachments = true
        Task {
            var prepared: [PreparedAttachment] = []
            var remaining = CodeStore.attachmentCharacterCap
            var failure: String?

            for url in urls.prefix(ChatAttachmentProcessor.maxFiles) {
                do {
                    let imported = try await ChatAttachmentProcessor.file(
                        url: url,
                        remainingCharacters: max(0, remaining)
                    )
                    remaining -= imported.attachment.text?.count ?? 0
                    prepared.append(imported.attachment)
                } catch let error as ChatAttachmentError {
                    failure = error.message(lang)
                } catch {
                    failure = Strings.Code.attachUnsupported(lang)
                }
            }

            attachments.append(contentsOf: prepared)
            isReadingAttachments = false
            if !prepared.isEmpty { Haptics.attach() }
            if let failure { env.toasts.show(failure, isError: true) }
        }
    }

    /// The web's accept list without the image types (`CW_ATT_ACCEPT`, minus `image/*`).
    private static let acceptedTypes: [UTType] = [
        .plainText, .sourceCode, .json, .html, .xml, .commaSeparatedText, .pdf, .data
    ]
}
