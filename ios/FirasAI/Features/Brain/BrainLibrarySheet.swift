import SwiftUI
import UniformTypeIdentifiers

/// The Brain library: the hero, the add control, the sources and everything the web's rail shows
/// beside them (`web-brain-ux.md §5.1–5.3, §6.4`, `design-brief.md §7.10`).
///
/// On iPhone it is presented as a large sheet from the composer's `المصادر` button. On iPad the
/// same view is the persistent 280 pt sources column: pass `embedded: true` and it drops its own
/// navigation chrome.
struct BrainLibrarySheet: View {

    private let env: AppEnvironment
    private let embedded: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isPicking = false
    @State private var pendingDelete: BrainDocument?

    init(env: AppEnvironment, embedded: Bool = false) {
        self.env = env
        self.embedded = embedded
    }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content.toolbar { closeToolbar } }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .firasSheetBackground(env.prefs.palette)
            }
        }
        .task { await env.brain.loadLibrary() }
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: Self.contentTypes,
            allowsMultipleSelection: true
        ) { result in
            handlePick(result)
        }
        .confirmationDialog(
            Text(Strings.Brain.deleteConfirm(env.prefs.lang)),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(Strings.Common.delete(env.prefs.lang), role: .destructive) { confirmDelete() }
            Button(Strings.Common.cancel(env.prefs.lang), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.title ?? "")
        }
    }

    // MARK: - Layout

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                addSection
                quotaLine
                importRows
                listSection
            }
            .padding(.horizontal, embedded ? 12 : 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(env.prefs.palette.background)
        .navigationTitle(Text(Strings.Brain.sourcesHead(env.prefs.lang)))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ToolbarContentBuilder
    private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
            }
            .tint(env.prefs.palette.textSecondary)
            .accessibilityLabel(Text(Strings.Common.close(env.prefs.lang)))
        }
    }

    private var hero: some View {
        let palette = env.prefs.palette
        let lang = env.prefs.lang
        let title = Strings.Brain.heroTitle(lang)
        let blurb = Strings.Brain.heroBody(lang)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(FirasType.scaled(19, scale: env.prefs.fontScale, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .bidiIsland(for: title, fallback: lang)
            Text(blurb)
                .font(FirasType.scaled(14, scale: env.prefs.fontScale))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .bidiIsland(for: blurb, fallback: lang)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addSection: some View {
        let palette = env.prefs.palette
        let lang = env.prefs.lang
        return VStack(alignment: .leading, spacing: 10) {
            Button { isPicking = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                    Text(Strings.Brain.add(lang))
                        .font(FirasType.scaled(15, scale: env.prefs.fontScale, weight: .semibold))
                }
                .foregroundStyle(palette.onAccent)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background { Capsule(style: .continuous).fill(palette.accent) }
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)

            Text(Strings.Brain.addHint(lang))
                .font(FirasType.scaled(12, scale: env.prefs.fontScale))
                .foregroundStyle(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: visionBinding) {
                Text(Strings.Brain.ocrToggle(lang))
                    .font(FirasType.scaled(13, scale: env.prefs.fontScale))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tint(palette.accent)
        }
    }

    @ViewBuilder
    private var quotaLine: some View {
        if let text = quotaText {
            Text(text)
                .font(FirasType.scaled(12, scale: env.prefs.fontScale))
                .foregroundStyle(isLibraryFull ? env.prefs.palette.error : env.prefs.palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `المستندات: ٤/٢٠ · صفحات اليوم: ٤٠/١٢٠ · امتلأت المكتبة…` — the pages line only exists for
    /// guests, where `pagesPerDay` is positive (`server-brain.md §5`).
    private var quotaText: String? {
        guard let limits = env.brain.limits else { return nil }
        let lang = env.prefs.lang
        let used = env.brain.usage?.docs ?? env.brain.docs.count
        var pieces: [String] = [
            Strings.Brain.usageDocs(lang) + ": "
                + ArabicText.count(used, lang) + "/" + ArabicText.count(limits.docs, lang),
        ]
        if limits.pagesPerDay > 0 {
            pieces.append(
                Strings.Brain.usagePages(lang) + ": "
                    + ArabicText.count(env.brain.usage?.pagesToday ?? 0, lang)
                    + "/" + ArabicText.count(limits.pagesPerDay, lang)
            )
        }
        if isLibraryFull { pieces.append(Strings.Brain.usageFull(lang)) }
        return pieces.joined(separator: " · ")
    }

    private var isLibraryFull: Bool {
        guard let limits = env.brain.limits, limits.docs > 0 else { return false }
        return (env.brain.usage?.docs ?? env.brain.docs.count) >= limits.docs
    }

    @ViewBuilder
    private var importRows: some View {
        if !env.brain.imports.isEmpty {
            VStack(spacing: 8) {
                ForEach(env.brain.imports) { progress in
                    BrainLibraryImportRow(
                        progress: progress,
                        palette: env.prefs.palette,
                        lang: env.prefs.lang,
                        scale: env.prefs.fontScale,
                        motionOn: motionOn,
                        onStop: { env.brain.cancelImport(id: progress.id) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var listSection: some View {
        if env.brain.isLoadingLibrary, env.brain.docs.isEmpty {
            SkeletonView(kind: .sidebar, palette: env.prefs.palette, motionOn: motionOn)
        } else if let message = env.brain.libraryError, env.brain.docs.isEmpty {
            errorBanner(message)
        } else if env.brain.docs.isEmpty {
            EmptyStateView(
                title: Strings.Brain.noSources(env.prefs.lang),
                subtitle: Strings.Brain.noSourcesHint(env.prefs.lang),
                buttonTitle: Strings.Brain.add(env.prefs.lang),
                palette: env.prefs.palette,
                action: { isPicking = true }
            )
        } else {
            VStack(spacing: 8) {
                ForEach(env.brain.docs) { document in
                    BrainLibraryDocumentRow(
                        document: document,
                        isActive: !env.brain.excluded.contains(document.id),
                        isPinned: env.brain.pins.contains(document.id),
                        palette: env.prefs.palette,
                        lang: env.prefs.lang,
                        scale: env.prefs.fontScale,
                        onToggle: { toggle(document) },
                        onPin: { togglePin(document) },
                        onDelete: { pendingDelete = document }
                    )
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        let palette = env.prefs.palette
        let lang = env.prefs.lang
        return VStack(alignment: .leading, spacing: 10) {
            Text(message.isEmpty ? Strings.Brain.libraryLoadFailed(lang) : message)
                .font(FirasType.scaled(14, scale: env.prefs.fontScale))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Button(Strings.Common.retry(lang)) { Task { await env.brain.loadLibrary() } }
                .font(FirasType.scaled(14, scale: env.prefs.fontScale, weight: .semibold))
                .tint(palette.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(palette)
    }

    // MARK: - State

    private var motionOn: Bool {
        FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion)
    }

    private var visionBinding: Binding<Bool> {
        Binding(get: { env.brain.forceOCR }, set: { env.brain.forceOCR = $0 })
    }

    private func toggle(_ document: BrainDocument) {
        guard !env.brain.pins.contains(document.id) else { return }
        Haptics.select()
        env.brain.toggleExcluded(document.id)
    }

    private func togglePin(_ document: BrainDocument) {
        Haptics.select()
        env.brain.togglePin(document.id)
    }

    private func confirmDelete() {
        guard let document = pendingDelete else { return }
        pendingDelete = nil
        Task { await env.brain.deleteDoc(id: document.id) }
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Haptics.attach()
            Task {
                for url in urls { await env.brain.importFile(url: url) }
            }
        case .failure:
            env.toasts.show(Strings.Brain.readFail(env.prefs.lang), isError: true)
        }
    }

    /// `accept=".pdf,.docx,.pptx,.xlsx,.xlsm,.txt,.md,…,image/*"` (app.js:87175).
    private static let contentTypes: [UTType] = {
        var types: [UTType] = [.pdf, .plainText, .text, .image]
        for name in ["docx", "pptx", "xlsx", "xlsm", "md", "markdown", "csv", "json", "xml"] {
            if let type = UTType(filenameExtension: name) { types.append(type) }
        }
        return types
    }()
}

// MARK: - Rows

/// One file being read, with its phase, a determinate bar and Stop.
private struct BrainLibraryImportRow: View {

    let progress: BrainImportProgress
    let palette: FirasPalette
    let lang: AppLanguage
    let scale: FontScale
    let motionOn: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(progress.name)
                    .font(FirasType.scaled(14, scale: scale, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .bidiIsland(for: progress.name, fallback: lang)
                Text(phaseLine)
                    .font(FirasType.scaled(12, scale: scale))
                    .foregroundStyle(isFailed ? palette.error : palette.textMuted)
                    .lineLimit(2)
                ProgressView(value: fraction)
                    .tint(palette.accent)
                    .frame(height: 3)
            }
            if !isFinished {
                Button(Strings.Common.stop(lang)) { onStop() }
                    .font(FirasType.scaled(13, scale: scale, weight: .semibold))
                    .tint(palette.textSecondary)
            }
        }
        .padding(12)
        .surfaceCard(palette)
        .accessibilityElement(children: .combine)
    }

    private var isFailed: Bool {
        if case .failed = progress.stage { return true }
        return false
    }

    private var isFinished: Bool {
        switch progress.stage {
        case .done, .failed: return true
        case .reading, .ocr, .uploading: return false
        }
    }

    private var phaseLine: String {
        switch progress.stage {
        case .reading(let done, let total):
            return Strings.Brain.reading(lang) + " " + counter(done, total)
        case .ocr(let done, let total):
            return Strings.Brain.readingScanned(lang) + " " + counter(done, total)
        case .uploading(let done, let total):
            return Strings.Brain.uploading(lang) + " " + counter(done, total)
        case .done:
            return Strings.Brain.indexed(lang)
        case .failed(let message):
            return message
        }
    }

    private var fraction: Double {
        switch progress.stage {
        case .reading(let done, let total),
             .ocr(let done, let total),
             .uploading(let done, let total):
            guard total > 0 else { return 0 }
            return min(1, max(0, Double(done) / Double(total)))
        case .done:
            return 1
        case .failed:
            return 0
        }
    }

    private func counter(_ done: Int, _ total: Int) -> String {
        guard total > 1 || done > 0 else { return "" }
        return ArabicText.count(done, lang) + "/" + ArabicText.count(max(total, done), lang)
    }
}

/// One indexed document: kind tag, title, page/OCR meta, pin and delete.
private struct BrainLibraryDocumentRow: View {

    let document: BrainDocument
    let isActive: Bool
    let isPinned: Bool
    let palette: FirasPalette
    let lang: AppLanguage
    let scale: FontScale
    let onToggle: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) { rowBody }
                .buttonStyle(.plain)
                .allowsHitTesting(!isPinned)
                .accessibilityLabel(Text(document.title + " — " + meta))
                .accessibilityAddTraits(isActive ? .isSelected : [])

            Button(action: onPin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isPinned ? palette.accent : palette.textMuted)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(isPinned ? Strings.Brain.pinDrop(lang) : Strings.Brain.pinAdd(lang))
            )

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.Common.delete(lang)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .surfaceCard(palette)
        .opacity(isActive ? 1 : 0.62)
    }

    private var rowBody: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(isActive ? palette.accent : palette.borderStrong)
                .accessibilityHidden(true)

            Text(Strings.Brain.kindTag(document.kind))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(palette.surfaceSunken)
                }
                .forceLTR()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .font(FirasType.scaled(14, scale: scale, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                    .bidiIsland(for: document.title, fallback: lang)
                Text(meta)
                    .font(FirasType.scaled(11, scale: scale))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var meta: String {
        var parts: [String] = [
            Strings.Brain.pagesCount(document.pages, document.unit, lang),
        ]
        if document.ocr > 0 { parts.append("OCR " + ArabicText.count(document.ocr, lang)) }
        if isPinned { parts.append(Strings.Brain.pinLabel(lang)) }
        if !isActive { parts.append(Strings.Brain.excludedHint(lang)) }
        return parts.joined(separator: " · ")
    }
}
