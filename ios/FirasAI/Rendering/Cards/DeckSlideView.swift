import SwiftUI

/// One slide, drawn natively.
///
/// Everything is laid out on a fixed 1280×720 canvas and then scaled to whatever space it is given.
/// That is what lets the same view be a thumbnail in the chat, a full screen in the player, and a
/// page in the exported PDF without three sets of font sizes that drift apart — and it is why a
/// deck looks the same on a phone, on an iPad and in the file the reader saves.
struct DeckSlideView: View {

    static let canvas = CGSize(width: 1280, height: 720)

    let slide: DeckSlide
    let deck: DeckMeta
    let palette: DeckPalette
    let index: Int
    let total: Int
    /// `false` holds the contents at their entry position; flipping it to `true` plays them in.
    /// The player flips it when a slide becomes the current one, so the animation belongs to
    /// arriving at a slide rather than to the view being created.
    let reveal: Bool
    let motionOn: Bool
    /// The footer is the presentation's, not the document's: the PDF keeps it, a 120 pt thumbnail
    /// does not.
    var showsFooter: Bool = true

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / Self.canvas.width, geo.size.height / Self.canvas.height)
            page
                .frame(width: Self.canvas.width, height: Self.canvas.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: Self.canvas.width * scale, height: Self.canvas.height * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .aspectRatio(Self.canvas.width / Self.canvas.height, contentMode: .fit)
    }

    // MARK: - The page

    private var page: some View {
        ZStack {
            ground
            body(for: slide.layout)
                .padding(.horizontal, 96)
                .padding(.top, slide.layout == .imagefull ? 0 : 84)
                .padding(.bottom, slide.layout == .imagefull ? 0 : 76)
            if showsFooter, slide.layout != .section, slide.layout != .imagefull {
                footer
            }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .environment(\.layoutDirection, deck.isArabic ? .rightToLeft : .leftToRight)
        .clipped()
    }

    private var ground: some View {
        ZStack {
            (slide.layout == .section ? palette.deep : palette.ground)
            // A single wide radial in the accent, at a whisper. It is what keeps a dark slide from
            // reading as a black rectangle without putting a gradient show behind the words.
            RadialGradient(
                colors: [palette.accent.opacity(palette.isLight ? 0.10 : 0.16), .clear],
                center: UnitPoint(x: deck.isArabic ? 0.88 : 0.12, y: 0.08),
                startRadius: 0,
                endRadius: 900
            )
        }
    }

    private var footer: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Text(deck.title)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(palette.inkMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(index + 1) / \(total)")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            .padding(.horizontal, 96)
            .padding(.bottom, 44)
        }
    }

    // MARK: - Layouts

    @ViewBuilder
    private func body(for layout: DeckLayout) -> some View {
        switch layout {
        case .section: sectionBody
        case .hero: heroBody
        case .quote: quoteBody
        case .stats: statsBody
        case .comparison, .twocol: columnsBody
        case .timeline: timelineBody
        case .process: processBody
        case .cards: cardsBody
        case .imagefull: imageFullBody
        case .content: contentBody
        }
    }

    private var sectionBody: some View {
        VStack(alignment: .leading, spacing: 26) {
            Spacer(minLength: 0)
            Rectangle()
                .fill(palette.accent)
                .frame(width: 132, height: 8)
                .entering(reveal, motionOn, order: 0)
            Text(slide.title)
                .font(.system(size: 78, weight: .bold))
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .entering(reveal, motionOn, order: 1)
            if let lead = slide.bullets.first {
                Text(lead)
                    .font(.system(size: 34))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .entering(reveal, motionOn, order: 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 0)
            Text(slide.title.isEmpty ? deck.title : slide.title)
                .font(.system(size: 86, weight: .heavy))
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .entering(reveal, motionOn, order: 0)
            if !deck.subtitle.isEmpty || !slide.bullets.isEmpty {
                Text(slide.bullets.first ?? deck.subtitle)
                    .font(.system(size: 36))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .entering(reveal, motionOn, order: 1)
            }
            Rectangle()
                .fill(palette.accent)
                .frame(width: 180, height: 6)
                .entering(reveal, motionOn, order: 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quoteBody: some View {
        VStack(alignment: .leading, spacing: 30) {
            Spacer(minLength: 0)
            Text("\u{201C}")
                .font(.system(size: 140, weight: .bold))
                .foregroundStyle(palette.accent.opacity(0.55))
                .frame(height: 90, alignment: .top)
                .entering(reveal, motionOn, order: 0)
            Text(slide.quote?.text ?? slide.title)
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(palette.ink)
                .lineSpacing(10)
                .fixedSize(horizontal: false, vertical: true)
                .entering(reveal, motionOn, order: 1)
            if let author = slide.quote?.author, !author.isEmpty {
                Text("— " + author)
                    .font(.system(size: 30))
                    .foregroundStyle(palette.inkMuted)
                    .entering(reveal, motionOn, order: 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statsBody: some View {
        VStack(alignment: .leading, spacing: 44) {
            heading
            HStack(alignment: .top, spacing: 34) {
                ForEach(Array(slide.stats.enumerated()), id: \.offset) { pair in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(pair.element.value)
                            .font(.system(size: 76, weight: .heavy))
                            .foregroundStyle(palette.accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(pair.element.label)
                            .font(.system(size: 26))
                            .foregroundStyle(palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                    .background(plate)
                    .entering(reveal, motionOn, order: pair.offset + 1)
                }
            }
            bulletsList(from: 1 + slide.stats.count, limit: 3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columnsBody: some View {
        VStack(alignment: .leading, spacing: 40) {
            heading
            HStack(alignment: .top, spacing: 30) {
                ForEach(Array(effectiveColumns.enumerated()), id: \.offset) { pair in
                    VStack(alignment: .leading, spacing: 16) {
                        if !pair.element.heading.isEmpty {
                            Text(pair.element.heading)
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(palette.accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(pair.element.points.enumerated()), id: \.offset) { point in
                            bulletRow(point.element, size: 27)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(30)
                    .background(plate)
                    .entering(reveal, motionOn, order: pair.offset + 1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timelineBody: some View {
        VStack(alignment: .leading, spacing: 34) {
            heading
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Array(effectiveSteps.enumerated()), id: \.offset) { pair in
                    HStack(alignment: .top, spacing: 22) {
                        ZStack {
                            Circle().fill(palette.accent).frame(width: 48, height: 48)
                            Text("\(pair.offset + 1)")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(palette.isLight ? Color.white : palette.deep)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pair.element.title)
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if !pair.element.desc.isEmpty {
                                Text(pair.element.desc)
                                    .font(.system(size: 25))
                                    .foregroundStyle(palette.inkMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .entering(reveal, motionOn, order: pair.offset + 1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var processBody: some View {
        VStack(alignment: .leading, spacing: 40) {
            heading
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(effectiveSteps.prefix(5).enumerated()), id: \.offset) { pair in
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(pair.offset + 1)")
                            .font(.system(size: 30, weight: .heavy))
                            .foregroundStyle(palette.accent)
                        Text(pair.element.title)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if !pair.element.desc.isEmpty {
                            Text(pair.element.desc)
                                .font(.system(size: 22))
                                .foregroundStyle(palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .background(plate)
                    .entering(reveal, motionOn, order: pair.offset + 1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardsBody: some View {
        VStack(alignment: .leading, spacing: 38) {
            heading
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22), count: 3), spacing: 22) {
                ForEach(Array(slide.cards.enumerated()), id: \.offset) { pair in
                    VStack(alignment: .leading, spacing: 10) {
                        if !pair.element.icon.isEmpty {
                            Text(pair.element.icon).font(.system(size: 40))
                        }
                        Text(pair.element.title)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if !pair.element.desc.isEmpty {
                            Text(pair.element.desc)
                                .font(.system(size: 22))
                                .foregroundStyle(palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(26)
                    .background(plate)
                    .entering(reveal, motionOn, order: pair.offset + 1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var imageFullBody: some View {
        ZStack(alignment: .bottomLeading) {
            DeckImage(source: slide.image, palette: palette)
                .frame(width: Self.canvas.width, height: Self.canvas.height)
                .clipped()
            if !slide.title.isEmpty {
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                Text(slide.title)
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 96)
                    .padding(.bottom, 84)
                    .fixedSize(horizontal: false, vertical: true)
                    .entering(reveal, motionOn, order: 0)
            }
        }
    }

    private var contentBody: some View {
        VStack(alignment: .leading, spacing: 34) {
            heading
            if hasImageBeside {
                HStack(alignment: .top, spacing: 38) {
                    VStack(alignment: .leading, spacing: 0) {
                        bulletsList(from: 1, limit: 8)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    DeckImage(source: slide.image, palette: palette)
                        .frame(width: 430, height: 330)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .entering(reveal, motionOn, order: 1)
                }
            } else {
                bulletsList(from: 1, limit: 9)
            }
            if let chart = slide.chart, chart.isDrawable {
                DeckChartView(chart: chart, palette: palette, reveal: reveal, motionOn: motionOn, arabic: deck.isArabic)
                    .frame(height: slide.bullets.isEmpty ? 400 : 250)
                    .entering(reveal, motionOn, order: 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var heading: some View {
        if !slide.title.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(slide.title)
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle()
                    .fill(palette.accent)
                    .frame(width: 88, height: 5)
            }
            .entering(reveal, motionOn, order: 0)
        }
    }

    private func bulletsList(from order: Int, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(slide.bullets.prefix(limit).enumerated()), id: \.offset) { pair in
                bulletRow(pair.element, size: 30)
                    .entering(reveal, motionOn, order: order + pair.offset)
            }
        }
    }

    private func bulletRow(_ text: String, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Circle()
                .fill(palette.accent)
                .frame(width: 12, height: 12)
                .offset(y: -size * 0.18)
            Text(text)
                .font(.system(size: size))
                .foregroundStyle(palette.ink.opacity(0.92))
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var plate: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(palette.isLight ? Color.black.opacity(0.045) : Color.white.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(palette.accent.opacity(0.22), lineWidth: 1.5)
            }
    }

    // MARK: - Data

    private var hasImageBeside: Bool {
        !slide.image.isEmpty && slide.layout == .content && !slide.bullets.isEmpty
    }

    /// A comparison slide whose `columns` never arrived still has to say something, so its bullets
    /// are split down the middle rather than left blank.
    private var effectiveColumns: [DeckColumn] {
        if !slide.columns.isEmpty { return Array(slide.columns.prefix(3)) }
        guard slide.bullets.count > 1 else { return [] }
        let half = (slide.bullets.count + 1) / 2
        return [
            DeckColumn(heading: "", points: Array(slide.bullets.prefix(half))),
            DeckColumn(heading: "", points: Array(slide.bullets.dropFirst(half))),
        ]
    }

    private var effectiveSteps: [DeckStep] {
        if !slide.steps.isEmpty { return slide.steps }
        return slide.bullets.map { DeckStep(title: $0, desc: "") }
    }
}

// MARK: - Entry animation

private extension View {
    /// The stagger. Each child arrives a beat after the one above it, and `motionOn == false`
    /// puts every child in place at once — Reduce Motion means no motion, not slower motion.
    @ViewBuilder
    func entering(_ reveal: Bool, _ motionOn: Bool, order: Int) -> some View {
        if motionOn {
            self
                .opacity(reveal ? 1 : 0)
                .offset(y: reveal ? 0 : 26)
                .animation(
                    .easeOut(duration: 0.42).delay(Double(min(order, 10)) * 0.075),
                    value: reveal
                )
        } else {
            self
        }
    }
}

// MARK: - Convenience initialisers used by the fallbacks above

extension DeckColumn {
    init(heading: String, points: [String]) {
        self.heading = heading
        self.points = points
    }
}

extension DeckStep {
    init(title: String, desc: String) {
        self.title = title
        self.desc = desc
    }
}
