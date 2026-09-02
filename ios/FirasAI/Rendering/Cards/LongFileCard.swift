import SwiftUI

/// The durable long-file progress card (`server-chat-jobs-chats.md §4.2, §4.4`).
///
/// A `longfile` job writes an exact-page PDF or DOCX over minutes, so this card is the whole
/// experience until the reference fence arrives: the stage sentence the web shows verbatim, the
/// `done / total` page counter, a percent bar, and Stop — the one chat-queue kind whose cancel the
/// UI is allowed to offer. When the artifact is complete the same card becomes the door to it.
struct LongFileCard: View {

    private let progress: LongFileProgress?
    private let meta: FileMeta?
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let motionOn: Bool
    private let isCancelling: Bool
    private let errorText: String?
    private let onStop: (() -> Void)?
    private let onOpen: (() -> Void)?

    init(
        progress: LongFileProgress?,
        meta: FileMeta? = nil,
        palette: FirasPalette,
        lang: AppLanguage,
        motionOn: Bool = true,
        isCancelling: Bool = false,
        errorText: String? = nil,
        onStop: (() -> Void)? = nil,
        onOpen: (() -> Void)? = nil
    ) {
        self.progress = progress
        self.meta = meta
        self.palette = palette
        self.lang = lang
        self.motionOn = motionOn
        self.isCancelling = isCancelling
        self.errorText = errorText
        self.onStop = onStop
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            if !isTerminal {
                bar
                counterRow
            }
            if let errorText, !errorText.isEmpty {
                failureLine(errorText)
            }
            footer
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(palette)
    }

    // MARK: - Headline

    @ViewBuilder
    private var headline: some View {
        if isComplete {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                Text(completeSubtitle)
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .bidiIsland(for: title, fallback: lang)
        } else if isCancelled {
            Text(LongFileCopy.cancelled(lang))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: LongFileCopy.cancelled(lang), fallback: lang)
        } else {
            FirasActivityLabel(text: stageText, palette: palette, motionOn: motionOn)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: stageText, fallback: lang)
        }
    }

    // MARK: - Progress

    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.surfaceSunken)
                Capsule()
                    .fill(palette.accent)
                    .frame(width: max(4, proxy.size.width * fraction))
            }
        }
        .frame(height: 6)
        .animation(motionOn ? FirasMotion.standard : FirasMotion.fade, value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(counterText))
    }

    private var counterRow: some View {
        HStack(spacing: 8) {
            Text(counterText)
                .font(FirasType.mono)
                .foregroundStyle(palette.textSecondary)
                .forceLTR()

            Spacer(minLength: 6)

            Text(percentText)
                .font(FirasType.mono)
                .foregroundStyle(palette.textMuted)
                .forceLTR()
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if isComplete, let onOpen {
            Button(action: onOpen) {
                Text(LongFileCopy.open(lang))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 40)
                    .background(Capsule().fill(palette.accent))
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LongFileCopy.open(lang)))
        } else if !isTerminal, let onStop {
            Button(action: onStop) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(isCancelling ? LongFileCopy.stopping(lang) : Strings.Common.stop(lang))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(isCancelling ? palette.textMuted : palette.textSecondary)
                .padding(.horizontal, 18)
                .frame(minHeight: 40)
                .background(Capsule().fill(palette.surfaceSunken))
                .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isCancelling)
            .accessibilityLabel(Text(Strings.Common.stop(lang)))
        }
    }

    private func failureLine(_ text: String) -> some View {
        Text(text)
            .font(FirasType.caption)
            .foregroundStyle(palette.error)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bidiIsland(for: text, fallback: lang)
    }

    // MARK: - Derived

    private var stage: String {
        (progress?.stage ?? "queued").trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var isComplete: Bool {
        if progress?.complete == true { return true }
        if stage == "complete" { return true }
        return progress == nil && meta != nil
    }

    private var isCancelled: Bool {
        progress?.cancelled == true || stage == "cancelled"
    }

    private var isTerminal: Bool { isComplete || isCancelled }

    /// `app.js:41348` — planning / writing / final, verbatim. `queued` shows the planning line
    /// because that is the work the server is about to start.
    private var stageText: String {
        switch stage {
        case "writing": return LongFileCopy.writing(lang)
        case "qa": return LongFileCopy.reviewing(lang)
        default: return LongFileCopy.planning(lang)
        }
    }

    private var pagesDone: Int { max(0, progress?.pagesDone ?? 0) }

    private var pagesTotal: Int {
        let total = progress?.pagesTotal ?? 0
        if total > 0 { return total }
        let target = progress?.targetPages ?? 0
        return target > 0 ? target : 0
    }

    private var fraction: Double {
        if let percent = progress?.percent, percent > 0 {
            return min(1, Double(percent) / 100)
        }
        guard pagesTotal > 0 else { return 0 }
        return min(1, Double(pagesDone) / Double(pagesTotal))
    }

    /// The web appends `" done / total"` to the stage line; on a phone it reads better as its own
    /// LTR row under the bar.
    private var counterText: String {
        guard pagesTotal > 0 else { return ArabicText.count(pagesDone, lang) }
        return ArabicText.count(pagesDone, lang) + " / " + ArabicText.count(pagesTotal, lang)
    }

    private var percentText: String {
        let value = ArabicText.count(Int((fraction * 100).rounded()), lang)
        return lang == .arabic ? value + "٪" : value + "%"
    }

    private var title: String {
        if let title = meta?.title, !title.isEmpty { return title }
        if let name = meta?.name, !name.isEmpty { return name }
        if let current = progress?.currentTitle, !current.isEmpty { return current }
        return LongFileCopy.untitled(lang)
    }

    private var completeSubtitle: String {
        let pages: Int? = meta?.pages ?? (pagesTotal > 0 ? pagesTotal : nil)
        guard let pages, pages > 0 else { return LongFileCopy.readySimple(lang) }
        return LongFileCopy.ready.fmt(lang, ArabicText.count(pages, lang))
    }
}

// MARK: - Copy

/// Progress wording is `app.js:41348` verbatim; the ready sentence is the server's own
/// `longFileReference` note (`server-chat-jobs-chats.md §4.3`).
private enum LongFileCopy {
    static let planning = LText(ar: "يخطط هيكل الملف…", en: "Planning the file's structure…")
    static let writing = LText(ar: "يكتب صفحات الملف…", en: "Writing the file's pages…")
    static let reviewing = LText(ar: "يراجع ويجمّع الملف…", en: "Reviewing and assembling the file…")

    static let cancelled = LText(ar: "أُوقف إنشاء الملف.", en: "The file was stopped.")
    static let stopping = LText(ar: "يُوقف…", en: "Stopping…")
    static let open = LText(ar: "افتح الملف", en: "Open the file")
    static let untitled = LText(ar: "ملف فِراس", en: "Firas document")

    /// `%@` is the page count, already in Arabic-Indic digits when the UI is Arabic.
    static let ready = LText(
        ar: "أصبح المستند الكامل المكوّن من %@ صفحة جاهزًا للمعاينة والتصدير.",
        en: "The complete %@-page document is ready for preview and export."
    )
    static let readySimple = LText(
        ar: "أصبح المستند جاهزًا للمعاينة والتصدير.",
        en: "The document is ready for preview and export."
    )
}
