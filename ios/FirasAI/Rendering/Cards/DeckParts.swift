import SwiftUI
import UIKit

/// A slide's picture. The model writes either a `data:` URI or an ordinary link, so both are
/// handled here rather than at four call sites — and neither is allowed to leave a hole in the
/// slide: a picture that will not load becomes a quiet plate with its alt text.
@MainActor
struct DeckImage: View {

    let source: String
    let palette: DeckPalette

    var body: some View {
        if let ready = DeckImageCache.image(for: source) ?? DeckImage.inlineImage(source) {
            Image(uiImage: ready)
                .resizable()
                .scaledToFill()
        } else if let url = DeckImage.remoteURL(source) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                case .empty:
                    ZStack {
                        placeholder
                        ProgressView().tint(palette.accent)
                    }
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(palette.isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.06))
            Image(systemName: "photo")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(palette.inkMuted)
        }
    }

    /// `data:image/png;base64,…` — decoded here rather than handed to `AsyncImage`, which does not
    /// take data URIs.
    static func inlineImage(_ source: String) -> UIImage? {
        guard source.hasPrefix("data:") else { return nil }
        guard let comma = source.firstIndex(of: ",") else { return nil }
        let payload = String(source[source.index(after: comma)...])
        guard source[..<comma].contains("base64") else { return nil }
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else { return nil }
        return UIImage(data: data)
    }

    static func remoteURL(_ source: String) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        return URL(string: trimmed)
    }
}

/// Slide pictures already in memory.
///
/// It exists for one reason: `ImageRenderer` draws a single frame from what is there *now*, so a
/// slide whose picture is still in flight would be exported as a grey plate. The player fills this
/// ahead of the render, and `DeckImage` reads it first, which also means paging back to a slide
/// does not re-fetch its picture.
@MainActor
enum DeckImageCache {

    private static var store: [String: UIImage] = [:]
    /// A ceiling, not a policy: a deck is at most 48 slides and this is temporary either way.
    private static let limit = 64

    static func image(for source: String) -> UIImage? {
        guard !source.isEmpty else { return nil }
        return store[source]
    }

    static func prefetch(_ sources: [String]) async {
        for source in sources {
            let key = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, store[key] == nil else { continue }
            if let inline = DeckImage.inlineImage(key) {
                put(inline, for: key)
                continue
            }
            guard let url = DeckImage.remoteURL(key) else { continue }
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { continue }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
            guard let image = UIImage(data: data) else { continue }
            put(image, for: key)
        }
    }

    private static func put(_ image: UIImage, for key: String) {
        if store.count >= limit { store.removeAll() }
        store[key] = image
    }
}

/// A slide's chart: bars grow, a line draws itself, a doughnut fills — the same three the web
/// animates (`app.js:34448`), drawn with Shapes rather than a web view so a slide stays one
/// rasterisable view and can be exported as a page.
struct DeckChartView: View {

    let chart: DeckChart
    let palette: DeckPalette
    let reveal: Bool
    let motionOn: Bool
    let arabic: Bool

    /// 0 → 1 as the chart draws. Without motion it starts finished.
    private var progress: CGFloat { (reveal || !motionOn) ? 1 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !chart.title.isEmpty {
                Text(chart.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(palette.inkMuted)
            }
            plot
                .animation(motionOn ? .easeOut(duration: 0.9) : nil, value: reveal)
            if chart.kind != .doughnut {
                labelsRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var plot: some View {
        switch chart.kind {
        case .bar: bars
        case .line: line
        case .doughnut: doughnut
        }
    }

    // MARK: - Bar

    private var bars: some View {
        GeometryReader { geo in
            let values = chart.series.first?.data ?? []
            let peak = max(values.map(abs).max() ?? 1, 0.0001)
            let slot = geo.size.width / CGFloat(max(values.count, 1))
            let width = min(slot * 0.55, 84)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { pair in
                    let height = geo.size.height * CGFloat(abs(pair.element) / peak) * progress
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [palette.accent, palette.accent.opacity(0.55)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: width, height: max(height, 2))
                        .frame(width: slot, alignment: .center)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }

    // MARK: - Line

    private var line: some View {
        GeometryReader { geo in
            let values = chart.series.first?.data ?? []
            let peak = max(values.map(abs).max() ?? 1, 0.0001)
            ZStack {
                DeckLinePath(values: values, peak: peak)
                    .trim(from: 0, to: progress)
                    .stroke(palette.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                DeckLinePath(values: values, peak: peak, closed: true)
                    .fill(
                        LinearGradient(
                            colors: [palette.accent.opacity(0.30), palette.accent.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(Double(progress))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Doughnut

    private var doughnut: some View {
        let values = (chart.series.first?.data ?? []).map { abs($0) }
        let total = max(values.reduce(0, +), 0.0001)
        return GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(Array(values.enumerated()), id: \.offset) { pair in
                    let start = values.prefix(pair.offset).reduce(0, +) / total
                    let end = start + pair.element / total
                    Circle()
                        .trim(from: CGFloat(start) * progress, to: CGFloat(end) * progress)
                        .stroke(
                            palette.accent.opacity(1 - Double(pair.offset) * 0.16),
                            style: StrokeStyle(lineWidth: side * 0.20, lineCap: .butt)
                        )
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: side * 0.8, height: side * 0.8)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    // MARK: - Labels

    private var labelsRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(chart.labels.enumerated()), id: \.offset) { pair in
                Text(pair.element)
                    .font(.system(size: 20))
                    .foregroundStyle(palette.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The line itself. `closed` returns the same line dropped to the baseline and sealed, which is the
/// area fill underneath it.
private struct DeckLinePath: Shape {

    let values: [Double]
    let peak: Double
    var closed: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let x = rect.minX + step * CGFloat(index)
            let y = rect.maxY - rect.height * CGFloat(abs(value) / peak)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}
