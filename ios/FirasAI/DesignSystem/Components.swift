import SwiftUI

// MARK: - FirasPill

/// A capsule chip: the composer's toggles, filters, saved-template chips.
///
/// Pills are deliberately **not** glass — a chip always sits on top of a
/// `.floating` surface and two stacked glass layers read as mud
/// (`design-brief.md §2.5`). The hit target is 44 pt tall even though the
/// visible capsule is 34 pt.
struct FirasPill: View {

    private let text: String
    private let symbol: String?
    private let selected: Bool
    private let palette: FirasPalette
    private let action: () -> Void

    init(
        text: String,
        symbol: String?,
        selected: Bool,
        palette: FirasPalette,
        action: @escaping () -> Void
    ) {
        self.text = text
        self.symbol = symbol
        self.selected = selected
        self.palette = palette
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            content
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(text))
        .accessibilityAddTraits(traits)
    }

    private var content: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(selected ? palette.accent : palette.textSecondary)
        .padding(.horizontal, 14)
        .frame(minHeight: 34)
        .background {
            Capsule(style: .continuous)
                .fill(selected ? palette.accentSoft : palette.surfaceSunken)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    selected ? palette.accentRing : palette.border,
                    lineWidth: 1
                )
        }
        .frame(minHeight: 44)
        .contentShape(Capsule(style: .continuous))
    }

    private var traits: AccessibilityTraits {
        selected ? .isSelected : []
    }
}

// MARK: - FirasIconButton

/// A 44 pt square icon button. `prominent` fills it with the accent colour for
/// the one primary action on a screen (send, start call).
struct FirasIconButton: View {

    private let symbol: String
    private let label: String
    private let palette: FirasPalette
    private let prominent: Bool
    private let action: () -> Void

    init(
        symbol: String,
        label: String,
        palette: FirasPalette,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.label = label
        self.palette = palette
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 17 : 16, weight: .semibold))
                .foregroundStyle(prominent ? palette.onAccent : palette.textPrimary)
                .frame(width: 44, height: 44)
                .background {
                    Circle().fill(prominent ? palette.accent : Color.clear)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - LiveDot

/// The "something is running" dot. It never freezes: with motion on it breathes
/// in scale and opacity, with motion off it pulses opacity only
/// (`design-brief.md §3.3`).
struct LiveDot: View {

    private let palette: FirasPalette
    private let motionOn: Bool

    @State private var breathing = false

    init(palette: FirasPalette, motionOn: Bool) {
        self.palette = palette
        self.motionOn = motionOn
    }

    var body: some View {
        Circle()
            .fill(palette.accent)
            .frame(width: 8, height: 8)
            .scaleEffect(motionOn && breathing ? 1.35 : 1)
            .opacity(breathing ? 0.38 : 1)
            .onAppear { restart() }
            .onChange(of: motionOn) { _, _ in restart() }
            .accessibilityHidden(true)
    }

    private func restart() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { breathing = false }

        let duration: Double = motionOn ? 0.7 : 0.75
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }
}

// MARK: - SkeletonView

/// Placeholder blocks for the ≤ 400 ms window between opening a list or a
/// conversation and having content. A shimmer travels through them while motion
/// is on; with motion off they are static blocks. Never a spinner.
struct SkeletonView: View {

    enum Kind: Sendable {
        case transcript
        case sidebar
        case tiles
    }

    private let kind: Kind
    private let palette: FirasPalette
    private let motionOn: Bool

    @State private var sweep: CGFloat = 0

    init(kind: Kind, palette: FirasPalette, motionOn: Bool) {
        self.kind = kind
        self.palette = palette
        self.motionOn = motionOn
    }

    var body: some View {
        blocks
            .overlay { shimmer }
            .onAppear { restart() }
            .onChange(of: motionOn) { _, _ in restart() }
            .accessibilityHidden(true)
    }

    // MARK: Shapes

    @ViewBuilder
    private var blocks: some View {
        switch kind {
        case .transcript:
            transcriptBlocks
        case .sidebar:
            sidebarBlocks
        case .tiles:
            tileBlocks
        }
    }

    private var transcriptBlocks: some View {
        VStack(alignment: .leading, spacing: 14) {
            bar(width: 300, height: 15)
            bar(width: 232, height: 15)
            bar(width: 158, height: 15)

            HStack(spacing: 0) {
                Spacer(minLength: 40)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(palette.surfaceSunken)
                    .frame(height: 40)
                    .frame(maxWidth: 210)
            }
            .padding(.vertical, 6)

            bar(width: 320, height: 15)
            bar(width: 264, height: 15)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebarBlocks: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<7, id: \.self) { index in
                bar(width: index.isMultiple(of: 2) ? 268 : 196, height: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tileBlocks: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 108), spacing: 10)],
            spacing: 10
        ) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(palette.surfaceSunken)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(palette.surfaceSunken)
            .frame(height: height)
            .frame(maxWidth: width, alignment: .leading)
    }

    // MARK: Shimmer

    @ViewBuilder
    private var shimmer: some View {
        if motionOn {
            GeometryReader { proxy in
                let band = max(72, proxy.size.width * 0.4)
                LinearGradient(
                    colors: [
                        Color.clear,
                        palette.textPrimary.opacity(0.07),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: band)
                .offset(x: -band + (proxy.size.width + band) * sweep)
            }
            .mask { blocks }
            .allowsHitTesting(false)
        }
    }

    private func restart() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { sweep = 0 }

        guard motionOn else { return }
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            sweep = 1
        }
    }
}

// MARK: - EmptyStateView

/// The house empty state: one line that says what is missing, an optional second
/// line that says why, and at most one action.
struct EmptyStateView: View {

    private let title: String
    private let subtitle: String?
    private let buttonTitle: String?
    private let palette: FirasPalette
    private let action: (() -> Void)?

    init(
        title: String,
        subtitle: String?,
        buttonTitle: String?,
        palette: FirasPalette,
        action: (() -> Void)?
    ) {
        self.title = title
        self.subtitle = subtitle
        self.buttonTitle = buttonTitle
        self.palette = palette
        self.action = action
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textSecondary)
            }

            actionButton
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let buttonTitle, let action, !buttonTitle.isEmpty {
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background {
                        Capsule(style: .continuous).fill(palette.accent)
                    }
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
    }
}
