import SwiftUI
import UIKit

/// A fenced block that the app can actually run, shown as the web shows it: a `معاينة / الكود`
/// toggle over one card, the live page on one side and the highlighted source on the other
/// (`app.js:35700-35760`, `web-chat-ux.md §8.6`).
///
/// Three rules keep it honest:
///
/// * **Nothing heavy runs by itself.** Past `Document.autoRunByteLimit` the preview side opens on a
///   Run button, so a thousand-line page never seizes the transcript the moment it streams in.
/// * **The island exists only while it is being looked at.** Switching to الكود removes the
///   `WebIsland` from the hierarchy, which tears the web view down; coming back rebuilds it.
/// * **The card sizes itself to the page.** The island reports its content height and the card
///   grows to it, clamped, with a Taller control for a page that wants more room.
struct HTMLPreviewCard: View {

    private let code: String
    private let language: String?
    private let filename: String?
    private let kind: Document.Kind
    private let companions: [Document.Companion]
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let collapsible: Bool

    @State private var side: Side
    @State private var document = ""
    @State private var running = false
    @State private var loaded = false
    @State private var failed = false
    @State private var measuredHeight: CGFloat = 0
    @State private var expanded = false
    @State private var listingExpanded = false
    @State private var copied = false
    @State private var runToken = 0

    init(
        code: String,
        language: String?,
        filename: String? = nil,
        kind: Document.Kind,
        companions: [Document.Companion] = [],
        palette: FirasPalette,
        lang: AppLanguage,
        collapsible: Bool = true
    ) {
        self.code = code
        self.language = language
        self.filename = filename
        self.kind = kind
        self.companions = companions
        self.palette = palette
        self.lang = lang
        self.collapsible = collapsible

        // A page opens on the page; a stylesheet, a script or a JSON document opens on its source,
        // because that is what the reader came for and the preview is the second opinion.
        let heavy = Document.isHeavy(code: code, companions: companions)
        let rendersFirst = (kind == .html || kind == .svg) && !heavy
        _side = State(initialValue: rendersFirst ? .preview : .code)
    }

    enum Side: Hashable {
        case preview
        case code
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            pane
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .forceLTR()
        .onAppear {
            if side == .preview { start() }
        }
        .onChange(of: side) { _, newValue in
            if newValue == .preview { start() }
        }
        .onChange(of: palette.isLightFamily) { _, _ in
            guard running else { return }
            rebuild()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.border)
            .frame(height: 1)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(CodeHighlighter.label(for: language))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textMuted)
                .lineLimit(1)
                .fixedSize()

            if let name = trimmedFilename {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.border)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)
            toggle
            copyButton
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(minHeight: 38)
        .background(palette.surfaceSunken)
    }

    /// Two words in one capsule rather than a system segmented control: the card is small, the
    /// header is quiet, and a full-width picker in here would shout.
    private var toggle: some View {
        HStack(spacing: 0) {
            sideButton(.preview, title: CodeBlockCopy.preview(lang))
            sideButton(.code, title: CodeBlockCopy.code(lang))
        }
        .padding(2)
        .background(Capsule().fill(palette.background))
        .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1).allowsHitTesting(false))
    }

    private func sideButton(_ value: Side, title: String) -> some View {
        Button {
            guard side != value else { return }
            side = value
            Haptics.select()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: side == value ? .semibold : .regular))
                .foregroundStyle(side == value ? palette.onAccent : palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
                .background(
                    Capsule().fill(side == value ? palette.accent : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(side == value ? [.isSelected] : [])
    }

    private var copyButton: some View {
        Button(action: copyCode) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? palette.success : palette.textSecondary)
        .accessibilityLabel(Text(copied ? Strings.Common.copied(lang) : Strings.Common.copy(lang)))
    }

    // MARK: - Panes

    @ViewBuilder
    private var pane: some View {
        if side == .preview {
            previewPane
        } else {
            codePane
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        if running {
            VStack(spacing: 0) {
                island
                divider
                previewFooter
            }
        } else if isHeavy {
            runPrompt
        } else {
            // The single frame between `onAppear` and the island appearing. Showing the Run gate
            // here instead would flash a button nobody was ever going to press.
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(CodeBlockCopy.running(lang))
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textMuted)
            }
            .frame(maxWidth: .infinity)
            .frame(height: HTMLPreviewCard.restingHeight)
        }
    }

    private var isHeavy: Bool {
        Document.isHeavy(code: code, companions: companions)
    }

    private var island: some View {
        ZStack {
            WebIsland(
                html: document,
                scrollEnabled: measuredHeight > frameHeight + 1,
                onHeight: { height in
                    guard height > 0 else { return }
                    measuredHeight = height
                },
                onFinish: { success in
                    loaded = true
                    failed = !success
                }
            )
            .frame(height: frameHeight)
            .accessibilityLabel(Text(CodeBlockCopy.sandboxNote(lang)))

            if !loaded && !failed {
                veil {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(CodeBlockCopy.running(lang))
                            .font(FirasType.caption)
                            .foregroundStyle(palette.textMuted)
                    }
                }
            }

            if failed {
                veil {
                    VStack(spacing: 6) {
                        Text(CodeBlockCopy.failedTitle(lang))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text(CodeBlockCopy.failedBody(lang))
                            .font(FirasType.caption)
                            .foregroundStyle(palette.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .frame(height: frameHeight)
        .clipped()
    }

    private func veil<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.surface)
            .bidiIsland(for: CodeBlockCopy.failedBody(lang), fallback: lang)
    }

    private var previewFooter: some View {
        HStack(spacing: 4) {
            footerButton(title: CodeBlockCopy.refresh(lang), symbol: "arrow.clockwise") {
                runToken += 1
                rebuild()
            }
            if canGrow {
                footerButton(
                    title: expanded ? CodeBlockCopy.shorter(lang) : CodeBlockCopy.taller(lang),
                    symbol: expanded ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                ) {
                    expanded.toggle()
                }
            }
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(minHeight: 36)
        .background(palette.surfaceSunken)
    }

    private func footerButton(
        title: String,
        symbol: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.textSecondary)
        .accessibilityLabel(Text(title))
    }

    /// The gate a big document meets instead of running on sight.
    private var runPrompt: some View {
        VStack(spacing: 10) {
            Text(CodeBlockCopy.heavyTitle(lang))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text(CodeBlockCopy.heavyBody(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .multilineTextAlignment(.center)
            Button {
                start()
                Haptics.select()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(CodeBlockCopy.run(lang))
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(palette.onAccent)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(Capsule().fill(palette.accent))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .bidiIsland(for: CodeBlockCopy.heavyBody(lang), fallback: lang)
    }

    private var codePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            CodeListing(
                code: code,
                language: language,
                palette: palette,
                wrapped: false,
                lineLimit: shownLineLimit,
                fadesTail: isCollapsed
            )
            if isCollapsible {
                divider
                Button {
                    listingExpanded.toggle()
                    Haptics.select()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: listingExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                        Text(listingExpanded ? CodeBlockCopy.showLess(lang) : CodeBlockCopy.showMore(lang))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accent)
                .background(palette.surfaceSunken)
            }
        }
    }

    // MARK: - Sizing

    private static let restingHeight: CGFloat = 320
    private static let minimumHeight: CGFloat = 180
    private static let normalCeiling: CGFloat = 420
    private static let expandedCeiling: CGFloat = 680

    private var ceiling: CGFloat {
        expanded ? HTMLPreviewCard.expandedCeiling : HTMLPreviewCard.normalCeiling
    }

    private var frameHeight: CGFloat {
        guard measuredHeight > 0 else { return HTMLPreviewCard.restingHeight }
        return min(max(measuredHeight, HTMLPreviewCard.minimumHeight), ceiling)
    }

    private var canGrow: Bool {
        measuredHeight > HTMLPreviewCard.normalCeiling || expanded
    }

    // MARK: - Listing state

    private static let collapsedLineLimit = 16
    private static let hardCeiling = 150
    private static let hardShownLimit = 60

    private var lineCount: Int {
        var count = 1
        for character in code where character == "\n" { count += 1 }
        return count
    }

    private var isCollapsible: Bool {
        if collapsible { return lineCount > HTMLPreviewCard.collapsedLineLimit }
        return lineCount > HTMLPreviewCard.hardCeiling
    }

    private var isCollapsed: Bool { isCollapsible && !listingExpanded }

    private var shownLineLimit: Int? {
        guard isCollapsed else { return nil }
        return collapsible ? HTMLPreviewCard.collapsedLineLimit : HTMLPreviewCard.hardShownLimit
    }

    private var trimmedFilename: String? {
        guard let filename else { return nil }
        let cleaned = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Actions

    private func start() {
        guard !running else {
            loaded = false
            failed = false
            return
        }
        rebuild()
        running = true
    }

    /// The run token rides along as a trailing comment so a Refresh actually changes the string the
    /// island is holding — a byte-identical document is deliberately not reloaded.
    private func rebuild() {
        loaded = false
        failed = false
        measuredHeight = 0
        document = Document.page(
            code: code,
            language: language,
            companions: companions,
            palette: palette,
            lang: lang
        ) + "\n<!-- firas-run " + String(runToken) + " -->"
    }

    private func copyCode() {
        UIPasteboard.general.string = code
        Haptics.select()
        copied = true
        let flag = $copied
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            flag.wrappedValue = false
        }
    }
}
