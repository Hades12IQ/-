import SwiftUI

/// The ```` ```firas-file ```` deliverable card (`web-chat-ux.md §8.5`,
/// `server-chat-jobs-chats.md §4.3`).
///
/// One quiet plate, the shape of every other card in the transcript: a muted glyph tile, the name
/// the model chose, one line of facts under it — the format, how many pages or sheets or slides,
/// how big the file is — and the three things a person actually does with a file: open it, send it,
/// keep it.
///
/// Four states, all real. While the server is still writing, the same plate carries the stage
/// sentence and, for a durable long file, the page counter and a Stop. When the file is ready the
/// actions appear. When the fence names a format this build cannot write, the plate says so instead
/// of pretending. When the job failed, the reason is on the card.
struct FileCard: View {

    /// The document pipeline's stages (`web-chat-ux.md §8.4`, `fileStageText`). `creating` is the
    /// generic label the web shows before the first stage arrives.
    enum Stage: String, Sendable, Equatable, CaseIterable {
        case creating
        case extract
        case plan
        case content
        case validate
        case assemble

        var label: LText {
            switch self {
            case .creating: return FileCardCopy.stageCreating
            case .extract: return FileCardCopy.stageExtract
            case .plan: return FileCardCopy.stagePlan
            case .content: return FileCardCopy.stageContent
            case .validate: return FileCardCopy.stageValidate
            case .assemble: return FileCardCopy.stageAssemble
            }
        }

        /// The server's stage word, whatever case it arrives in.
        init(raw: String) {
            self = Stage(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) ?? .creating
        }
    }

    let meta: FileMeta
    let palette: FirasPalette
    let lang: AppLanguage

    let stage: Stage?
    let progress: LongFileProgress?
    let sizeBytes: Int?

    private let errorText: String?
    private let isCancelling: Bool
    private let isPreparing: Bool
    private let motionOn: Bool
    private let onOpen: (() -> Void)?
    private let onShare: (() -> Void)?
    private let onSaveToFiles: (() -> Void)?
    private let onStop: (() -> Void)?

    init(
        meta: FileMeta,
        palette: FirasPalette,
        lang: AppLanguage,
        stage: Stage? = nil,
        progress: LongFileProgress? = nil,
        sizeBytes: Int? = nil,
        errorText: String? = nil,
        isCancelling: Bool = false,
        isPreparing: Bool = false,
        motionOn: Bool = true,
        onOpen: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil,
        onSaveToFiles: (() -> Void)? = nil,
        onStop: (() -> Void)? = nil
    ) {
        self.meta = meta
        self.palette = palette
        self.lang = lang
        self.stage = stage
        self.progress = progress
        self.sizeBytes = sizeBytes
        self.errorText = errorText
        self.isCancelling = isCancelling
        self.isPreparing = isPreparing
        self.motionOn = motionOn
        self.onOpen = onOpen
        self.onShare = onShare
        self.onSaveToFiles = onSaveToFiles
        self.onStop = onStop
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(palette)
    }

    @ViewBuilder
    private var content: some View {
        if isWorking {
            working
        } else if !FileCardKind.isKnown(meta.format) {
            unavailable
        } else {
            ready
        }
    }

    private var isWorking: Bool {
        guard errorText == nil else { return false }
        if stage != nil { return true }
        guard let progress else { return false }
        return !progress.complete && !progress.cancelled && progress.stage != "complete"
    }

    // MARK: - Ready

    private var ready: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            if let errorText, !errorText.isEmpty {
                failure(errorText)
            }
            if hasActions {
                actions
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(FileCardCopy.ready(lang) + " \u{2014} " + displayName))
    }

    private var headline: some View {
        HStack(alignment: .center, spacing: 12) {
            glyph(symbol: FileCardKind.symbol(meta.format), tint: palette.accent, fill: palette.accentSoft)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .bidiIsland(for: displayName, fallback: lang)

                Text(factsLine)
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .bidiIsland(for: factsLine, fallback: lang)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private var hasActions: Bool {
        onOpen != nil || onShare != nil || onSaveToFiles != nil
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let onOpen {
                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        if isPreparing {
                            ProgressView().controlSize(.small).tint(palette.onAccent)
                        } else {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text(FileCardCopy.open(lang))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 34)
                    .background(Capsule().fill(palette.accent))
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isPreparing)
                .accessibilityLabel(Text(FileCardCopy.open(lang)))
            }

            if let onShare {
                ghost(symbol: "square.and.arrow.up", title: Strings.Common.share(lang), action: onShare)
            }

            if let onSaveToFiles {
                ghost(
                    symbol: "folder.badge.plus",
                    title: FileCardCopy.saveToFiles(lang),
                    action: onSaveToFiles
                )
            }

            Spacer(minLength: 0)
        }
    }

    private func ghost(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Capsule().fill(palette.surfaceSunken))
            .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1).allowsHitTesting(false))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isPreparing)
        .accessibilityLabel(Text(title))
    }

    // MARK: - Working

    private var working: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                glyph(
                    symbol: FileCardKind.symbol(meta.format),
                    tint: palette.textMuted,
                    fill: palette.surfaceSunken
                )
                VStack(alignment: .leading, spacing: 3) {
                    FirasActivityLabel(text: stageText, palette: palette, motionOn: motionOn)
                        .bidiIsland(for: stageText, fallback: lang)
                    if !workingSubtitle.isEmpty {
                        Text(workingSubtitle)
                            .font(FirasType.caption)
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(1)
                            .bidiIsland(for: workingSubtitle, fallback: lang)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }

            if let fraction {
                bar(fraction)
                counter
            }

            if let onStop {
                stopButton(onStop)
            }
        }
    }

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
        .animation(motionOn ? FirasMotion.standard : FirasMotion.fade, value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(counterText))
    }

    private var counter: some View {
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

    private func stopButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(isCancelling ? FileCardCopy.stopping(lang) : Strings.Common.stop(lang))
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isCancelling ? palette.textMuted : palette.textSecondary)
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .background(Capsule().fill(palette.surfaceSunken))
            .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1).allowsHitTesting(false))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isCancelling)
        .accessibilityLabel(Text(Strings.Common.stop(lang)))
    }

    // MARK: - Unavailable

    private var unavailable: some View {
        HStack(alignment: .center, spacing: 12) {
            glyph(symbol: "doc", tint: palette.textMuted, fill: palette.surfaceSunken)
            Text(FileCardCopy.unavailable(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: FileCardCopy.unavailable(lang), fallback: lang)
        }
    }

    private func failure(_ text: String) -> some View {
        Text(text)
            .font(FirasType.caption)
            .foregroundStyle(palette.error)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bidiIsland(for: text, fallback: lang)
    }

    private func glyph(symbol: String, tint: Color, fill: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
            .accessibilityHidden(true)
    }
}
