import SwiftUI

/// The selected passage stays visible beside the question until it is sent or removed.
struct QuotedTextContext: View {
    let text: String
    let palette: FirasPalette
    let lang: AppLanguage
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.quote")
                .foregroundStyle(palette.accent)
                .padding(.top, 12)
            Text(verbatim: text)
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .bidiIsland(for: text, fallback: lang)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.Common.close(lang)))
        }
        .padding(.leading, 12)
        .background(palette.surfaceSunken, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct TranscriptBottomButton: View {
    let palette: FirasPalette
    let lang: AppLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 44, height: 44)
                .firasGlass(.floating, palette: palette, in: AnyShape(Circle()))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Chat.scrollToBottom(lang)))
        .padding(.bottom, 12)
    }
}

struct TranscriptScrollMetrics: Equatable {
    let distance: CGFloat
    let height: CGFloat
    let viewport: CGFloat

    init(_ geometry: ScrollGeometry) {
        height = geometry.contentSize.height
        viewport = geometry.containerSize.height
        distance = max(0, height + geometry.contentInsets.bottom
            - geometry.contentOffset.y - viewport)
    }
}
