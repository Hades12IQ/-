import SwiftUI

/// The reader for a durable long file (`kind:"longfile"`): the manifest, then every finished part,
/// each one checksum-verified before a single page of it is shown
/// (`server-chat-jobs-chats.md §4.2–4.4`).
///
/// The page bodies are never in the chat — they live only in the artifact store — so this screen is
/// the one place they are assembled. Three things follow from that, and they are the whole design:
///
/// * **Pages arrive as they are written.** The reader opens on part 0 the moment it exists and the
///   manifest is polled until the job is done; every new part appends without moving the page the
///   reader is on.
/// * **Coming back resumes.** Parts already verified are never fetched twice.
/// * **A finished job never shows a spinner.** The progress strip disappears the moment the
///   manifest says `complete`, and a job that finished with nothing says so.
///
/// Opening the document builds the real file — a PDF for a PDF artifact, a Word document for a DOCX
/// one — and hands it to QuickLook. A reader who asked for a Word file gets a Word file.
struct LongFileViewer: View {

    let env: AppEnvironment
    let jobID: String
    let providedTitle: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State var phase: LongFileViewerPhase = .loading
    @State var pages: [LongFilePage] = []
    @State var loadedParts: Int = 0
    @State var documentTitle: String = ""
    @State var documentFormat: String = "pdf"
    @State var progress: LongFileProgress?
    @State var isComplete: Bool = false
    @State private var pageIndex: Int = 0
    @State private var exporter: ExportController?
    @State private var route: SheetRoute?
    @State private var isBuilding = false

    /// One sheet, three destinations. Three separate `.sheet(item:)` modifiers on one view is the
    /// classic way to get a sheet that silently never presents.
    enum SheetRoute: Identifiable {
        case share(ExportController.Export)
        case preview(ExportController.Export)
        case save(ExportController.Export)

        var export: ExportController.Export {
            switch self {
            case .share(let export), .preview(let export), .save(let export):
                return export
            }
        }

        var id: String {
            switch self {
            case .share: return "share-" + export.id.uuidString
            case .preview: return "preview-" + export.id.uuidString
            case .save: return "save-" + export.id.uuidString
            }
        }
    }

    init(env: AppEnvironment, jobID: String, title: String? = nil) {
        self.env = env
        self.jobID = jobID
        self.providedTitle = title
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle(Text(navigationTitleText))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .firasSheetBackground(palette)
        .task(id: jobID) {
            await run()
        }
        .sheet(item: $route) { destination in
            sheetBody(destination)
        }
    }

    @ViewBuilder
    private func sheetBody(_ destination: SheetRoute) -> some View {
        switch destination {
        case .share(let export):
            // `export:` and not `url:`. A picture of a long document is written as several PNGs
            // now, and `url` is only the first of them — handing that one over leaves the rest
            // in the temp directory with nothing left to come back for them.
            FirasActivitySheet(export: export)
        case .preview(let export):
            previewSheet(export)
        case .save(let export):
            FirasFileSaver(export: export) { saved in
                route = nil
                if saved {
                    env.toasts.show(LongFileViewerCopy.saved(lang), isError: false)
                }
            }
        }
    }

    var palette: FirasPalette { env.prefs.palette }
    var lang: AppLanguage { env.prefs.lang }
    var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    private var navigationTitleText: String {
        documentTitle.isEmpty ? LongFileViewerCopy.untitled(lang) : documentTitle
    }

    private var isBusy: Bool {
        isBuilding || (exporter?.isWorking ?? false)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Text(Strings.Common.close(lang))
            }
            .foregroundStyle(palette.accent)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !pages.isEmpty {
                Button {
                    open()
                } label: {
                    if isBusy {
                        ProgressView()
                    } else {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .disabled(isBusy)
                .foregroundStyle(palette.accent)
                .accessibilityLabel(Text(LongFileViewerCopy.preview(lang)))
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !pages.isEmpty {
                exportMenu
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            Section {
                ForEach(ExportController.Format.allCases) { format in
                    Button {
                        export(format, then: .share)
                    } label: {
                        Text(format.label(lang))
                        Image(systemName: format.symbol)
                    }
                }
            } header: {
                Text(LongFileViewerCopy.exportSection(lang))
            }
            Button {
                export(artifactFormat, then: .saveToFiles)
            } label: {
                Text(LongFileViewerCopy.saveToFiles(lang))
                Image(systemName: "folder.badge.plus")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .semibold))
        }
        .menuOrder(.fixed)
        .disabled(isBusy)
        .foregroundStyle(palette.accent)
        .accessibilityLabel(Text(LongFileViewerCopy.export(lang)))
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            waitingState
        case .reading:
            readingState
        case .failed(let message):
            failedState(message)
        }
    }

    /// Not a bare spinner: the server tells us the stage and the page count, so the wait says what
    /// is being written and how far it has got.
    private var waitingState: some View {
        VStack(spacing: 18) {
            progressStrip
            SkeletonView(kind: .transcript, palette: palette, motionOn: motionOn)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private func failedState(_ message: String) -> some View {
        EmptyStateView(
            title: LongFileViewerCopy.failedTitle(lang),
            subtitle: message,
            buttonTitle: Strings.Common.retry(lang),
            palette: palette,
            action: { reload() }
        )
        .frame(maxHeight: .infinity)
    }

    private var readingState: some View {
        VStack(spacing: 0) {
            if !isComplete {
                progressStrip
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }
            pageBody
            pager
        }
    }

    /// The stage sentence, the page counter and the bar — the same words the transcript card shows,
    /// so the reader is never told two different stories about one job.
    @ViewBuilder
    private var progressStrip: some View {
        if let progress, !isComplete {
            VStack(alignment: .leading, spacing: 8) {
                FirasActivityLabel(text: stageText(progress), palette: palette, motionOn: motionOn)
                    .bidiIsland(for: stageText(progress), fallback: lang)

                if let fraction = fraction(progress) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.surfaceSunken)
                            Capsule()
                                .fill(palette.accent)
                                .frame(width: max(4, proxy.size.width * fraction))
                        }
                    }
                    .frame(height: 5)
                    .animation(motionOn ? FirasMotion.standard : FirasMotion.fade, value: fraction)
                }

                Text(counterText(progress))
                    .font(FirasType.mono)
                    .foregroundStyle(palette.textMuted)
                    .forceLTR()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else if !isComplete {
            FirasActivityLabel(
                text: LongFileViewerCopy.assembling(lang),
                palette: palette,
                motionOn: motionOn
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var currentPage: LongFilePage? {
        guard !pages.isEmpty else { return nil }
        let index = min(max(0, pageIndex), pages.count - 1)
        return pages[index]
    }

    private var pageBody: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if let page = currentPage {
                    if !page.title.isEmpty {
                        Text(page.title)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .bidiIsland(for: page.title, fallback: lang)
                    }
                    MarkdownView(
                        markdown: page.markdown,
                        messageID: "longfile-" + jobID + "-" + String(page.number),
                        streaming: false,
                        lang: lang,
                        palette: palette,
                        prefs: env.prefs,
                        onFence: { _ in nil }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .readingColumn(env.prefs.contentWidth)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var pager: some View {
        HStack(spacing: 14) {
            pagerButton(symbol: "chevron.left", label: LongFileViewerCopy.previousPage(lang)) {
                step(-1)
            }
            .disabled(pageIndex <= 0)
            .opacity(pageIndex <= 0 ? 0.35 : 1)

            Text(pagerLabel)
                .font(FirasType.label)
                .monospacedDigit()
                .foregroundStyle(palette.textSecondary)
                .frame(minWidth: 92)

            pagerButton(symbol: "chevron.right", label: LongFileViewerCopy.nextPage(lang)) {
                step(1)
            }
            .disabled(pageIndex >= pages.count - 1)
            .opacity(pageIndex >= pages.count - 1 ? 0.35 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .firasGlass(.floating, palette: palette, in: AnyShape(Capsule(style: .continuous)))
        .padding(.bottom, 14)
        .forceLTR()
    }

    private var pagerLabel: String {
        let shown = ArabicText.count(min(pageIndex + 1, max(pages.count, 1)), lang)
        let total = ArabicText.count(pages.count, lang)
        return LongFileViewerCopy.pageCounter.fmt(lang, shown, total)
    }

    private func pagerButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.accent)
        .accessibilityLabel(Text(label))
    }

    // MARK: - The document itself

    private func previewSheet(_ export: ExportController.Export) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    route = nil
                } label: {
                    Text(Strings.Common.close(lang))
                        .font(.system(size: 16, weight: .medium))
                }
                .foregroundStyle(palette.accent)

                Spacer(minLength: 12)

                Button {
                    route = .save(export)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text(LongFileViewerCopy.saveToFiles(lang))
                            .font(.system(size: 15, weight: .medium))
                    }
                }
                .foregroundStyle(palette.accent)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(palette.surface)

            Divider().overlay(palette.border)

            FirasDocumentPreview(export: export)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Actions

    private func step(_ delta: Int) {
        let next = pageIndex + delta
        guard next >= 0, next < pages.count else { return }
        Haptics.select()
        withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
            pageIndex = next
        }
    }

    private func reload() {
        pages = []
        loadedParts = 0
        pageIndex = 0
        phase = .loading
        Task { await run() }
    }

    /// The artifact's own format when this build can write it, else a PDF — the format the reader
    /// asked for is the one they should get back.
    private var artifactFormat: ExportController.Format {
        ExportController.Format.named(documentFormat) ?? .pdf
    }

    private func open() {
        export(artifactFormat, then: .preview)
    }

    enum ExportDestination {
        case share
        case preview
        case saveToFiles
    }

    private func export(_ format: ExportController.Format, then destination: ExportDestination) {
        guard !isBuilding, !pages.isEmpty else { return }
        if exporter == nil { exporter = ExportController(env: env) }
        guard let exporter else { return }

        let document = LongFileAssembly.document(title: documentTitle, pages: pages)
        let title = documentTitle.isEmpty ? LongFileViewerCopy.untitled(lang) : documentTitle
        let meta = FileMeta(format: format.rawValue, name: nil, title: title)
        isBuilding = true
        Task {
            let built = await exporter.document(for: meta, markdown: document, title: title)
            isBuilding = false
            guard let built else { return }
            switch destination {
            case .share: route = .share(built)
            case .preview: route = .preview(built)
            case .saveToFiles: route = .save(built)
            }
        }
    }
}
