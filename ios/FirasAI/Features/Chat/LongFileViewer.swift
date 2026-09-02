import SwiftUI
import UIKit
import CryptoKit

/// The reader for a durable long file (`kind:"longfile"`): the manifest, then every finished part,
/// each one checksum-verified before a single page of it is shown
/// (`server-chat-jobs-chats.md §4.2–4.4`).
///
/// The page bodies are never in the chat — they live only in the artifact store — so this screen is
/// the one place they are assembled. Question-bank runs carry `<!-- FIRAS_QUESTION_… -->` markers
/// inside `markdown`; they are stripped before rendering, exactly as the web does.
struct LongFileViewer: View {

    private let env: AppEnvironment
    private let jobID: String
    private let providedTitle: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase: LongFileViewerPhase = .loading
    @State private var pages: [LongFilePage] = []
    @State private var documentTitle: String = ""
    @State private var pageIndex: Int = 0
    @State private var exporter: ExportController?
    @State private var exportResult: ExportController.Export?

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
            await load()
        }
        .sheet(item: $exportResult) { export in
            FirasActivitySheet(url: export.url)
        }
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    private var navigationTitleText: String {
        documentTitle.isEmpty ? LongFileViewerCopy.untitled(lang) : documentTitle
    }

    private var isBusy: Bool {
        if case .loading = phase { return true }
        return exporter?.isWorking ?? false
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
            if case .ready = phase {
                exportMenu
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            ForEach(ExportController.Format.allCases) { format in
                Button {
                    export(format)
                } label: {
                    Label {
                        Text(format.label(lang))
                    } icon: {
                        Image(systemName: format.symbol)
                    }
                }
            }
        } label: {
            if isBusy {
                ProgressView()
            } else {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
            }
        }
        .disabled(isBusy)
        .foregroundStyle(palette.accent)
        .accessibilityLabel(Text(LongFileViewerCopy.export(lang)))
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            loadingState
        case .ready:
            readyState
        case .notReady(let note):
            notReadyState(note)
        case .failed(let message):
            failedState(message)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 18) {
            FirasActivityLabel(
                text: LongFileViewerCopy.assembling(lang),
                palette: palette,
                motionOn: motionOn
            )
            SkeletonView(kind: .transcript, palette: palette, motionOn: motionOn)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    private func notReadyState(_ note: String) -> some View {
        EmptyStateView(
            title: LongFileViewerCopy.notReadyTitle(lang),
            subtitle: note,
            buttonTitle: Strings.Common.retry(lang),
            palette: palette,
            action: { reload() }
        )
        .frame(maxHeight: .infinity)
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

    @ViewBuilder
    private var readyState: some View {
        if pages.isEmpty {
            EmptyStateView(
                title: LongFileViewerCopy.emptyTitle(lang),
                subtitle: LongFileViewerCopy.emptyBody(lang),
                buttonTitle: Strings.Common.retry(lang),
                palette: palette,
                action: { reload() }
            )
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                pageBody
                pager
            }
        }
    }

    private var currentPage: LongFilePage? {
        guard pageIndex >= 0, pageIndex < pages.count else { return pages.first }
        return pages[pageIndex]
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
        Task { await load() }
    }

    private func export(_ format: ExportController.Format) {
        guard let exporter, !pages.isEmpty else { return }
        let document = LongFileAssembly.document(title: documentTitle, pages: pages)
        let title = documentTitle.isEmpty ? LongFileViewerCopy.untitled(lang) : documentTitle
        Task {
            await exporter.export(format, markdown: document, title: title)
            exportResult = exporter.result
        }
    }

    // MARK: - Loading

    private func load() async {
        if exporter == nil { exporter = ExportController(env: env) }
        phase = .loading
        pages = []
        pageIndex = 0
        do {
            let manifest = try await env.api.longFileManifest(jobID: jobID)
            documentTitle = firstNonEmpty(manifest.title, providedTitle, manifest.filename) ?? ""
            let partCount = max(0, manifest.partsDone)
            guard partCount > 0 else {
                phase = .notReady(progressNote(manifest.progress))
                return
            }

            var collected: [LongFilePage] = []
            for index in 0..<partCount {
                let part = try await env.api.longFilePart(jobID: jobID, index: index)
                switch await LongFileAssembly.pages(from: part) {
                case .success(let items):
                    collected.append(contentsOf: items)
                case .failure:
                    phase = .failed(LongFileViewerCopy.checksum(lang))
                    return
                }
            }
            collected.sort { $0.number < $1.number }
            pages = collected
            pageIndex = 0
            phase = .ready
        } catch {
            if let apiError = error as? APIError, (apiError.status ?? 0) == 409 {
                phase = .notReady(LongFileViewerCopy.stillWriting(lang))
                return
            }
            phase = .failed(errorMessage(for: error))
        }
    }

    private func progressNote(_ progress: LongFileProgress?) -> String {
        guard let progress else { return LongFileViewerCopy.stillWriting(lang) }
        let stage: LText
        switch progress.stage {
        case "planning", "queued": stage = LongFileViewerCopy.planning
        case "qa": stage = LongFileViewerCopy.reviewing
        case "cancelled": return LongFileViewerCopy.cancelled(lang)
        default: stage = LongFileViewerCopy.writing
        }
        guard progress.pagesTotal > 0 else { return stage(lang) }
        let done = ArabicText.count(max(0, progress.pagesDone), lang)
        let total = ArabicText.count(progress.pagesTotal, lang)
        return stage(lang) + " " + LongFileViewerCopy.pageCounter.fmt(lang, done, total)
    }

    private func errorMessage(for error: Error) -> String {
        switch ErrorPresenter.present(
            error,
            feature: nil,
            isGuest: env.session.isGuest,
            lang: lang
        ) {
        case .toast(let copy):
            return copy(lang)
        case .toastText(let text):
            return text
        case .sessionExpired:
            return Strings.Errors.sessionExpired(lang)
        default:
            return Strings.Errors.generic(lang)
        }
    }

    private func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Phases

private enum LongFileViewerPhase: Equatable {
    case loading
    case ready
    /// The artifact exists but no part is finished yet; the string is the progress line.
    case notReady(String)
    case failed(String)
}

// MARK: - One page

private struct LongFilePage: Identifiable, Sendable, Equatable {
    let id: Int
    let number: Int
    let title: String
    let markdown: String
}

private enum LongFileAssemblyError: Error, Sendable {
    case checksum
}

/// Part verification and document assembly. Everything here is pure and runs off the main actor:
/// a 12-page part is a few hundred kilobytes of Arabic text to hash.
private enum LongFileAssembly {

    static func pages(from part: LongFilePart) async -> Result<[LongFilePage], LongFileAssemblyError> {
        await Task.detached(priority: .userInitiated) { () -> Result<[LongFilePage], LongFileAssemblyError> in
            if let expected = part.sha256, !expected.isEmpty {
                let actual = LongFileAssembly.sha256Hex(part.records)
                guard actual == expected.lowercased() else { return .failure(.checksum) }
            }
            let built = part.records.map { record in
                LongFilePage(
                    id: record.pageNumber,
                    number: record.pageNumber,
                    title: LongFileAssembly.stripMarkers(record.title)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    markdown: LongFileAssembly.stripMarkers(record.markdown)
                )
            }
            return .success(built)
        }.value
    }

    /// `SHA-256(JSON.stringify(records.map(r => [pageNumber, title, markdown])))`, lowercase hex
    /// (`server-chat-jobs-chats.md §4.4`). The JSON is written by hand because Foundation's writer
    /// escapes `/` and JavaScript's does not — one escaped slash and every checksum fails.
    static func sha256Hex(_ records: [LongFilePart.Record]) -> String {
        var canonical = "["
        for (index, record) in records.enumerated() {
            if index > 0 { canonical += "," }
            canonical += "["
            canonical += String(record.pageNumber)
            canonical += ","
            canonical += jsonString(record.title)
            canonical += ","
            canonical += jsonString(record.markdown)
            canonical += "]"
        }
        canonical += "]"

        let digest = SHA256.hash(data: Data(canonical.utf8))
        var hex = ""
        hex.reserveCapacity(64)
        for byte in digest {
            hex += String(format: "%02x", Int(byte))
        }
        return hex
    }

    /// `JSON.stringify` semantics for a string: only the seven mandatory escapes plus `\u00xx`
    /// for the remaining control characters. Everything else stays as raw UTF-8.
    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\u{08}":
                out += "\\b"
            case "\u{0C}":
                out += "\\f"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", Int(scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    /// Drops every `<!-- FIRAS_… -->` comment (question-bank markers, page markers) and keeps any
    /// ordinary HTML comment the author wrote.
    static func stripMarkers(_ markdown: String) -> String {
        guard markdown.contains("<!--") else { return markdown }
        var output = ""
        var rest = Substring(markdown)

        while let open = rest.range(of: "<!--") {
            output += String(rest[rest.startIndex..<open.lowerBound])
            guard let close = rest.range(of: "-->", range: open.upperBound..<rest.endIndex) else {
                output += String(rest[open.lowerBound...])
                return output
            }
            let inner = String(rest[open.upperBound..<close.lowerBound])
            if !inner.contains("FIRAS_") {
                output += "<!--" + inner + "-->"
            }
            rest = rest[close.upperBound...]
        }

        output += String(rest)
        return output
    }

    /// The whole file as one markdown document, for export.
    static func document(title: String, pages: [LongFilePage]) -> String {
        var parts: [String] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            parts.append("# " + trimmedTitle)
        }
        for page in pages {
            if !page.title.isEmpty {
                parts.append("## " + page.title)
            }
            let body = page.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                parts.append(body)
            }
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Copy

/// Progress wording is `app.js:41348` verbatim (`server-chat-jobs-chats.md §4.2`); the rest is new
/// copy in the same voice, because the web has no long-file reader to borrow it from.
private enum LongFileViewerCopy {
    static let untitled = LText(ar: "ملف فِراس", en: "Firas document")
    static let export = LText(ar: "تصدير", en: "Download")
    static let assembling = LText(ar: "يجمع صفحات الملف…", en: "Assembling the file's pages…")

    static let planning = LText(ar: "يخطط هيكل الملف…", en: "Planning the file's structure…")
    static let writing = LText(ar: "يكتب صفحات الملف…", en: "Writing the file's pages…")
    static let reviewing = LText(ar: "يراجع ويجمّع الملف…", en: "Reviewing and assembling the file…")
    static let cancelled = LText(ar: "أُوقف إنشاء الملف.", en: "The file was stopped.")

    static let notReadyTitle = LText(ar: "الملف لم يكتمل بعد", en: "The file isn't finished yet")
    static let stillWriting = LText(
        ar: "ما زال فِراس يكتب صفحات هذا الملف — افتحه بعد قليل.",
        en: "Firas is still writing this file's pages — open it again shortly."
    )

    static let failedTitle = LText(ar: "تعذّر فتح الملف", en: "Couldn't open the file")
    static let checksum = LText(
        ar: "وصل جزء من الملف تالفًا ولم يُعرض. أعد المحاولة.",
        en: "One part of the file arrived corrupted and was not shown. Try again."
    )

    static let emptyTitle = LText(ar: "لا توجد صفحات", en: "No pages")
    static let emptyBody = LText(
        ar: "لم يصل أي محتوى من هذا الملف.",
        en: "No content came back for this file."
    )

    static let previousPage = LText(ar: "الصفحة السابقة", en: "Previous page")
    static let nextPage = LText(ar: "الصفحة التالية", en: "Next page")
    /// `%@ / %@` — both numbers arrive already in Arabic-Indic digits when the UI is Arabic.
    static let pageCounter = LText(ar: "%@ / %@", en: "%@ / %@")
}
