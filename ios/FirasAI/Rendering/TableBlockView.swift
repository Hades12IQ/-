import SwiftUI

/// A markdown table. It scrolls inside its own container so a five-column comparison never pushes
/// the reading column sideways, and each cell gets its own direction — a table of Arabic terms
/// with English identifiers has both in the same row.
struct TableBlockView: View {

    private let header: [AttributedString]
    private let rows: [[AttributedString]]
    private let palette: FirasPalette

    init(header: [AttributedString], rows: [[AttributedString]], palette: FirasPalette) {
        self.header = header
        self.rows = rows
        self.palette = palette
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                if !header.isEmpty {
                    GridRow {
                        ForEach(Array(header.indices), id: \.self) { column in
                            cell(header[column], isHeader: true)
                        }
                    }
                }
                ForEach(Array(rows.indices), id: \.self) { row in
                    GridRow {
                        ForEach(Array(0..<columnCount), id: \.self) { column in
                            cell(value(row: row, column: column), isHeader: false)
                        }
                    }
                }
            }
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        )
    }

    private var columnCount: Int {
        var count = header.count
        for row in rows where row.count > count { count = row.count }
        return max(count, 1)
    }

    private func value(row: Int, column: Int) -> AttributedString {
        let cells = rows[row]
        guard column < cells.count else { return AttributedString() }
        return cells[column]
    }

    private func cell(_ text: AttributedString, isHeader: Bool) -> some View {
        let plain = String(text.characters)
        let font: Font = isHeader ? Font.subheadline.weight(.semibold) : Font.subheadline
        return Text(MarkdownInline.styled(text, palette: palette))
            .font(font)
            .foregroundStyle(isHeader ? palette.textPrimary : palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minWidth: 96, maxWidth: 320, alignment: .leading)
            .background(isHeader ? palette.surfaceSunken : palette.surface)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(palette.border)
                    .frame(height: isHeader ? 1 : 0.5)
            }
            .bidiIsland(for: plain, fallback: .arabic)
    }
}
