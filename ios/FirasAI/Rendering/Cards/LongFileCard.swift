import SwiftUI

/// The durable long-file card (`server-chat-jobs-chats.md §4.2, §4.4`).
///
/// A `longfile` job writes an exact-page PDF or DOCX over minutes, so this card *is* the answer
/// until the reference fence arrives: the stage sentence the web shows verbatim, the `done / total`
/// page counter, a percent bar, the page being written right now, and Stop — the one chat-queue
/// kind whose cancel the server actually honours. When the artifact is complete the same card
/// becomes the door to it, and when the job was stopped or failed it says so instead of spinning
/// forever.
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
            if isRunning {
                if let fraction {
                    bar(fraction)
                }
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
        if hasError {
            /* A job that failed used to keep the animated «يخطط هيكل الملف…» label above its own
               error line, because the stage branch was the `else` of complete/cancelled and an
               error is neither. A card cannot say "still planning" and "it failed" at once. */
            Text(LongFileCopy.failed(lang))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: LongFileCopy.failed(lang), fallback: lang)
        } else if isComplete {
            HStack(alignment: .center, spacing: 12) {
                glyph
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(completeSubtitle)
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: title, fallback: lang)
                Spacer(minLength: 0)
            }
        } else if isCancelled {
            Text(LongFileCopy.cancelled(lang))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: LongFileCopy.cancelled(lang), fallback: lang)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                FirasActivityLabel(text: stageText, palette: palette, motionOn: motionOn)
                    .bidiIsland(for: stageText, fallback: lang)
                if !currentTitle.isEmpty {
                    Text(currentTitle)
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                        .bidiIsland(for: currentTitle, fallback: lang)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var glyph: some View {
        Image(systemName: FileCardKind.symbol(meta?.format ?? "pdf"))
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(palette.accent)
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.accentSoft))
            .accessibilityHidden(true)
    }

    // MARK: - Progress

    private func bar(_ fraction: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.surfaceSunken)
                Capsule()
                    .fill(palette.accent)
                    .frame(width: max(4, proxy.size.width * fraction))
            }
        }
        .frame(height: 5)
        .animation(motionOn ? FirasMotion.standard : nil, value: fraction)
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
        if isComplete, progress?.itemsTotal == nil, let onOpen {
            Button(action: onOpen) {
                Text(LongFileCopy.open(lang))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 38)
                    .background(Capsule().fill(palette.accent))
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LongFileCopy.open(lang)))
        } else if isRunning, let onStop {
            Button(action: onStop) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(isCancelling ? FileCardCopy.stopping(lang) : Strings.Common.stop(lang))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(isCancelling ? palette.textMuted : palette.textSecondary)
                .padding(.horizontal, 18)
                .frame(minHeight: 38)
                .background(Capsule().fill(palette.surfaceSunken))
                .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1).allowsHitTesting(false))
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
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bidiIsland(for: text, fallback: lang)
    }

    // MARK: - Derived

    private var stage: String {
        (progress?.stage ?? "queued").trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var hasError: Bool {
        !(errorText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isComplete: Bool {
        if hasError { return false }
        if progress?.complete == true { return true }
        if stage == "complete" { return true }
        return progress == nil && meta != nil
    }

    private var isCancelled: Bool {
        progress?.cancelled == true || stage == "cancelled"
    }

    private var isRunning: Bool {
        !isComplete && !isCancelled && !hasError
    }

    /// `app.js:41348` — planning / writing / final, verbatim. `queued` shows the planning line
    /// because that is the work the server is about to start.
    private var stageText: String {
        if progress?.itemsTotal != nil {
            switch stage {
            case "writing", "generating":
                return lang == .arabic ? "يكتب العناصر والحلول المطلوبة…" : "Writing the requested items and solutions…"
            case "qa", "validating", "reviewing":
                return lang == .arabic ? "يتحقق من اكتمال العناصر وصحة الحلول…" : "Checking every item and solution…"
            case "rendering", "exporting", "assembling":
                return lang == .arabic ? "يجهّز ملف PDF للمعاينة…" : "Preparing the PDF for preview…"
            default: return FileCardCopy.longPlanning(lang)
            }
        }
        switch stage {
        case "writing": return FileCardCopy.longWriting(lang)
        case "qa": return FileCardCopy.longReviewing(lang)
        default: return FileCardCopy.longPlanning(lang)
        }
    }

    private var currentTitle: String {
        progress?.currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var pagesDone: Int { max(0, progress?.itemsDone ?? progress?.pagesDone ?? 0) }

    private var pagesTotal: Int {
        if let total = progress?.itemsTotal { return max(0, total) }
        let total = progress?.pagesTotal ?? 0
        if total > 0 { return total }
        let target = progress?.targetPages ?? 0
        return target > 0 ? target : 0
    }

    private var fraction: Double? {
        if let percent = progress?.percent, percent > 0 {
            return min(1, Double(percent) / 100)
        }
        guard pagesTotal > 0, pagesDone > 0 else { return nil }
        return min(1, Double(pagesDone) / Double(pagesTotal))
    }

    /// The web appends `" done / total"` to the stage line; on a phone it reads better as its own
    /// left-to-right row under the bar.
    private var counterText: String {
        guard pagesTotal > 0 else { return ArabicText.count(pagesDone, lang) }
        let count = ArabicText.count(pagesDone, lang) + " / " + ArabicText.count(pagesTotal, lang)
        return progress?.itemsTotal == nil ? count : count + (lang == .arabic ? " عنصر" : " items")
    }

    private var percentText: String {
        let value = ArabicText.count(Int(((fraction ?? 0) * 100).rounded()), lang)
        return lang == .arabic ? value + "\u{066A}" : value + "%"
    }

    private var title: String {
        if let title = meta?.title, !title.isEmpty { return title }
        if let name = meta?.name, !name.isEmpty { return name }
        if !currentTitle.isEmpty { return currentTitle }
        return LongFileCopy.untitled(lang)
    }

    private var completeSubtitle: String {
        let pages: Int? = meta?.pages ?? (progress?.itemsTotal == nil && pagesTotal > 0 ? pagesTotal : nil)
        guard let pages, pages > 0 else { return LongFileCopy.readySimple(lang) }
        return LongFileCopy.ready.fmt(lang, ArabicText.count(pages, lang))
    }
}

// MARK: - Copy

/// The ready sentence is the server's own `longFileReference` note
/// (`server-chat-jobs-chats.md §4.3`); the stage words live in `FileCardCopy` so the two file cards
/// can never drift apart.
private enum LongFileCopy {
    static let cancelled = LText(ar: "أُوقف إنشاء الملف.", en: "The file was stopped.")
    static let failed = LText(ar: "تعذّر إنشاء الملف", en: "The file could not be created")
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
