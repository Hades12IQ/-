import SwiftUI

/// The composer's round action button: send, stop, mic, call.
///
/// 36 pt circle inside a 44 pt hit target (`design-brief.md §7.3`). Chips and buttons inside the
/// composer are never glass themselves — they sit inside the composer's own glass slab.
struct ComposerActionButton: View {

    private let symbol: String
    private let label: String
    private let palette: FirasPalette
    private let prominent: Bool
    private let enabled: Bool
    private let action: () -> Void

    init(
        symbol: String,
        label: String,
        palette: FirasPalette,
        prominent: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.label = label
        self.palette = palette
        self.prominent = prominent
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(prominent ? palette.accent : Color.clear)
                    .frame(width: 36, height: 36)
                Image(systemName: symbol)
                    .font(.system(size: prominent ? 16 : 17, weight: .semibold))
                    .foregroundStyle(foreground)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(Text(label))
        .hoverEffect(.lift)
    }

    private var foreground: Color {
        prominent ? palette.onAccent : palette.textSecondary
    }
}

/// The `+` button: opens the add sheet, carries the attachment count, and shows an accent ring when
/// a tool (web search / thinking) is on, exactly like the web's `has-active` state.
struct ComposerPlusButton: View {

    private let count: Int
    private let toolsActive: Bool
    private let label: String
    private let palette: FirasPalette
    private let action: () -> Void

    init(
        count: Int,
        toolsActive: Bool,
        label: String,
        palette: FirasPalette,
        action: @escaping () -> Void
    ) {
        self.count = count
        self.toolsActive = toolsActive
        self.label = label
        self.palette = palette
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(toolsActive ? palette.accentRing : Color.clear, lineWidth: 1.5)
                    .frame(width: 34, height: 34)
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(toolsActive ? palette.accent : palette.textSecondary)
            }
            .frame(width: 44, height: 44)
            .overlay(alignment: .topTrailing) { badge }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .hoverEffect(.lift)
    }

    @ViewBuilder
    private var badge: some View {
        if count > 0 {
            Text(verbatim: String(count))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(palette.onAccent)
                .frame(minWidth: 16, minHeight: 16)
                .background { Capsule().fill(palette.accent) }
                .offset(x: -2, y: 4)
                .forceLTR()
                .accessibilityHidden(true)
        }
    }
}

/// A small icon toggle for the two inline tools (web search, thinking).
struct ComposerToolToggle: View {

    private let symbol: String
    private let label: String
    private let hint: String
    private let isOn: Bool
    private let palette: FirasPalette
    private let action: () -> Void

    init(
        symbol: String,
        label: String,
        hint: String,
        isOn: Bool,
        palette: FirasPalette,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.label = label
        self.hint = hint
        self.isOn = isOn
        self.palette = palette
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? palette.accent : palette.textMuted)
                .frame(width: 32, height: 32)
                .background {
                    Circle().fill(isOn ? palette.accentSoft : Color.clear)
                }
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(hint))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .hoverEffect(.lift)
    }
}

/// The pill that shows the passage the user is asking about (`selAskChip` flow).
struct ComposerQuotePill: View {

    private let quote: String
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let onRemove: () -> Void

    init(quote: String, palette: FirasPalette, lang: AppLanguage, onRemove: @escaping () -> Void) {
        self.quote = quote
        self.palette = palette
        self.lang = lang
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "quote.opening")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(quote)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(2)
                Text(Strings.Composer.quoteHint(lang))
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
            }
            .bidiIsland(for: quote, fallback: lang)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.textMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.Composer.quoteDrop(lang)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.accentSoft)
        }
    }
}
