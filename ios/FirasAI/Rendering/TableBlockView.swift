import SwiftUI
import UIKit

/// A markdown table.
///
/// The previous version handed the whole grid to SwiftUI inside a horizontal `ScrollView` and let
/// it work the widths out. Inside a horizontal scroll view SwiftUI proposes *no* width at all, and
/// three separate failures follow from that one fact:
///
/// * **Cells were cropped, not wrapped.** With an unbounded proposal a `Text` reports the width of
///   its longest single line; the `.frame(maxWidth: 320)` around it then cut that line off at 320
///   instead of asking it to wrap, so a sentence ended mid-word and the row stayed one line tall
///   while the glyphs spilled into the row below. Every column here is measured up front and given
///   an exact width, so wrapping is a decision this view makes rather than something it suffers.
/// * **What did not fit was lost, not scrolled.** The content was never actually wider than the
///   viewport — it was the same width with its text clipped — so there was nothing to scroll to.
///   Now the columns are as wide as they say they are, and a table that cannot fit genuinely
///   overflows its own scroll view. It still never widens the page: the scroll view takes the width
///   it is offered and no more.
/// * **The two grounds pulled apart.** The header used `surfaceSunken`, which on the five dark
///   themes is *darker* than the page while the body `surface` is lighter — a header that read as a
///   hole. It now leans one derived step from the body surface toward whichever ink the running
///   theme uses, which lands on the correct side on paper and on true black alike.
///
/// Direction is the table's own, taken from every cell rather than from the first one, and each
/// cell still gets its own island on top of that so an Arabic row can carry a Latin identifier.
struct TableBlockView: View {

    private let header: [MDTableCell]
    private let rows: [[MDTableCell]]
    private let palette: FirasPalette

    /// What each column would need to set all of its cells on a single line. Measured once, in
    /// `init`, because it depends only on the text — not on how much room the table ends up with.
    private let natural: [CGFloat]

    /// The whole table's reading direction, decided by the whole table's content.
    private let direction: LayoutDirection

    /// The width the reading column offers. Zero until the first layout reports it, and the table
    /// simply uses its natural columns until then.
    @State private var available: CGFloat = 0

    init(header: [MDTableCell], rows: [[MDTableCell]], palette: FirasPalette) {
        self.header = header
        self.rows = rows
        self.palette = palette

        var columns = header.count
        for row in rows where row.count > columns { columns = row.count }

        let bodyFont = UIFont.preferredFont(forTextStyle: .subheadline)
        let headerFont = UIFont.systemFont(ofSize: bodyFont.pointSize, weight: .semibold)

        var widths = [CGFloat](repeating: 0, count: columns)
        var sample = ""
        for column in 0..<columns {
            var widest: CGFloat = 0
            if column < header.count {
                let plain = header[column].plain
                sample += plain + " "
                widest = max(widest, TableBlockView.measure(plain, font: headerFont))
            }
            for row in rows where column < row.count {
                let plain = row[column].plain
                sample += plain + " "
                widest = max(widest, TableBlockView.measure(plain, font: bodyFont))
            }
            widths[column] = widest + Metrics.padX * 2
        }

        self.natural = widths
        self.direction = TableBlockView.reading(sample)
    }

    // MARK: - Body

    var body: some View {
        let widths = columnWidths
        return ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                if !header.isEmpty {
                    line(header, widths: widths, isHeader: true, isLast: rows.isEmpty)
                }
                ForEach(Array(rows.indices), id: \.self) { index in
                    line(
                        rows[index],
                        widths: widths,
                        isHeader: false,
                        isLast: index == rows.count - 1
                    )
                }
            }
        }
        // A table that already fits has nothing to reveal, and rubber-banding it sideways only
        // makes the page feel loose.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .environment(\.layoutDirection, direction)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            available = width
        }
    }

    // MARK: - Rows and cells

    private func line(
        _ cells: [MDTableCell],
        widths: [CGFloat],
        isHeader: Bool,
        isLast: Bool
    ) -> some View {
        // `.top`, so a two-line cell does not drag the short cells beside it down the row with it.
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(widths.indices), id: \.self) { column in
                cell(at: column, in: cells, width: widths[column], isHeader: isHeader)
            }
        }
        .background { ground(isHeader: isHeader) }
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(isHeader ? palette.borderStrong : palette.border)
                    .frame(height: isHeader ? 1 : 0.5)
            }
        }
    }

    private func cell(at column: Int, in cells: [MDTableCell], width: CGFloat, isHeader: Bool) -> some View {
        let value = column < cells.count ? cells[column] : filler(for: column)
        let ink = isHeader ? palette.textPrimary : palette.textSecondary
        let font = isHeader ? Font.subheadline.weight(.semibold) : Font.subheadline

        return Text(MarkdownInline.styled(value.text, palette: palette))
            .font(font)
            .foregroundStyle(ink)
            // Spelled out because an ancestor in a chat row may have clamped the line count, and a
            // clamped table cell is the bug this file exists to fix.
            .lineLimit(nil)
            .multilineTextAlignment(value.align.textAlignment)
            .fixedSize(horizontal: false, vertical: true)
            // Not `bidiIsland`: that helper also forces `.leading`, and a `---:` column has to stay
            // on the far edge. The rule it uses — first strong character — is the same one here,
            // falling back to the table rather than to the UI language.
            .environment(\.layoutDirection, BidiText.direction(of: value.plain) ?? direction)
            // Outside the cell's own island on purpose: a column is aligned in the *table's*
            // direction, or one Latin cell would hang off the opposite edge from its neighbours.
            .frame(maxWidth: .infinity, alignment: value.align.frameAlignment)
            .padding(.horizontal, Metrics.padX)
            .padding(.vertical, Metrics.padY)
            .frame(width: width, alignment: .leading)
    }

    /// A row shorter than the table still owes the column an empty cell — otherwise every column
    /// after the gap slides one place over and the grid stops being a grid.
    private func filler(for column: Int) -> MDTableCell {
        let align = column < header.count ? header[column].align : MDTableAlign.natural
        return MDTableCell(AttributedString(), align: align)
    }

    /// The header's ground.
    ///
    /// It cannot be a named surface token. `surfaceSunken` is darker than the page on the five dark
    /// themes and lighter than it on `light`, so any fixed choice reads as a header on one family
    /// and as a hole on the other. `glassWash` is the *overlay ink of whichever family is running*
    /// — black over paper, white over ink — so one expression lands on the correct side of the body
    /// surface six times out of six, and `accentSoft` gives the row the same whisper of the theme's
    /// own hue the reader's bubble carries.
    @ViewBuilder
    private func ground(isHeader: Bool) -> some View {
        if isHeader {
            ZStack {
                palette.accentSoft
                palette.glassWash
            }
        } else {
            Color.clear
        }
    }

    // MARK: - Column widths

    /// Natural widths, clamped, then either stretched to fill the reading column or left wide
    /// enough to scroll — in that order, because a table that fits should look like it was made for
    /// the page it is on.
    private var columnWidths: [CGFloat] {
        guard !natural.isEmpty else { return [] }

        // On a phone one column may not eat the whole line; on an iPad it may be generous.
        let ceiling = available > 0
            ? max(Metrics.wrapFloor, min(Metrics.maxColumn, available * 0.72))
            : Metrics.maxColumn
        let ideal = natural.map { min(max($0, Metrics.minColumn), ceiling) }

        guard available > 0 else { return ideal }
        if ideal.reduce(0, +) <= available { return stretched(ideal, to: available) }

        // Too wide. Narrowing the widest columns is worth doing — reading a table without moving it
        // is better — but only down to the width at which a sentence stops wrapping and starts
        // falling apart into one word per line. Below that, scrolling is the honest answer.
        var low = Metrics.wrapFloor
        var high = ceiling
        for _ in 0..<20 {
            let mid = (low + high) / 2
            let fitted = ideal.reduce(CGFloat.zero) { $0 + min($1, mid) }
            if fitted <= available { low = mid } else { high = mid }
        }
        let capped = ideal.map { min($0, low) }
        return capped.reduce(0, +) <= available ? stretched(capped, to: available) : ideal
    }

    /// A table that fits takes the whole reading column, the way one does on the web. The surplus
    /// is shared in proportion to what each column asked for, so a «نعم / لا» column never ends up
    /// as wide as the sentence beside it.
    private func stretched(_ widths: [CGFloat], to target: CGFloat) -> [CGFloat] {
        let total = widths.reduce(0, +)
        guard total > 0, target > total else { return widths }
        let surplus = target - total
        var out = widths.map { $0 + surplus * ($0 / total) }
        // Rounding leaves a hairline of the container uncovered, which shows as a seam against the
        // border. The last column absorbs it. Read the drift into a constant first: `out[i] += f(out)`
        // reads the array while it is already being modified, which is an exclusivity violation.
        let drift = target - out.reduce(0, +)
        if let last = out.indices.last {
            out[last] += drift
        }
        return out
    }

    /// One cell, set on one line, in the face it will actually be drawn in.
    ///
    /// An estimate, and allowed to be one: an inline code run sets in a different face, and every
    /// column is clamped afterwards anyway. A column measured slightly narrow now costs a wrapped
    /// line, which is fine. The old failure was a column that was too narrow and *cropped*.
    private static func measure(_ text: String, font: UIFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let size = (text as NSString).size(withAttributes: [NSAttributedString.Key.font: font])
        return size.width.rounded(.up)
    }

    /// The table's reading direction.
    ///
    /// A table is not a sentence. First-strong — the rule a paragraph uses — reads only the opening
    /// cell, and an Arabic comparison whose first header is a Latin identifier would flip the whole
    /// grid on one word. So the whole grid votes; first-strong breaks the tie when neither script
    /// leads; and a table with no letters at all keeps the app's own first language.
    private static func reading(_ sample: String) -> LayoutDirection {
        if BidiText.isArabicDominant(sample) { return .rightToLeft }
        return BidiText.direction(of: sample) ?? .rightToLeft
    }

    private enum Metrics {
        static let padX: CGFloat = 12
        static let padY: CGFloat = 9
        static let radius: CGFloat = 10
        /// Room for «لا» and for a tick, and no less — a hairline column reads as a mistake.
        static let minColumn: CGFloat = 68
        /// Below this a wrapped sentence becomes a column of single words, so the table scrolls
        /// instead of squeezing any further.
        static let wrapFloor: CGFloat = 132
        static let maxColumn: CGFloat = 280
    }
}

private extension MDTableAlign {

    /// Where the cell's text box sits inside its column, resolved in the table's direction.
    var frameAlignment: Alignment {
        switch self {
        case .natural, .start: return .leading
        case .center: return .center
        case .end: return .trailing
        }
    }

    /// How the lines of a wrapped cell line up against each other, resolved in that cell's own
    /// direction — a wrapped Latin note inside an Arabic table stays flush with itself.
    var textAlignment: TextAlignment {
        switch self {
        case .natural, .start: return .leading
        case .center: return .center
        case .end: return .trailing
        }
    }
}
