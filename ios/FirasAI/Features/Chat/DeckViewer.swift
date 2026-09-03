import SwiftUI
import UIKit

/// The wording this feature needs. Kept beside it rather than in the shared string files: a deck is
/// one surface with six labels, and none of them are said anywhere else.
enum DeckCopy {
    static let open = LText(ar: "افتح العرض", en: "Open presentation")
    static let slides = LText(ar: "%@ شريحة", en: "%@ slides")
    static let building = LText(ar: "يُبنى العرض…", en: "Building the deck…")
    static let notes = LText(ar: "ملاحظات المُقدِّم", en: "Speaker notes")
    static let noNotes = LText(ar: "لا ملاحظات لهذه الشريحة", en: "No notes on this slide")
    static let save = LText(ar: "حفظ PDF", en: "Save as PDF")
    static let preparing = LText(ar: "يُجهَّز الملف…", en: "Preparing the file…")
    static let deck = LText(ar: "عرض تقديمي", en: "Presentation")
}

/// The deck, full screen, one slide at a time.
///
/// Paging is the whole interaction: swipe, and the slide that arrives plays its contents in. The
/// reveal is tied to *becoming* the current slide rather than to the view being created, so going
/// back and forward replays it instead of showing a slide that has already finished animating.
@MainActor
struct DeckViewer: View {

    let deck: DeckMeta
    let lang: AppLanguage
    let appPalette: FirasPalette
    let motionOn: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var current: Int = 0
    @State private var showsNotes = false
    @State private var chrome = true
    @State private var exported: URL?
    @State private var exporting = false

    private var palette: DeckPalette { DeckPalette.named(deck.theme) }

    var body: some View {
        ZStack {
            palette.ground.ignoresSafeArea()

            TabView(selection: $current) {
                ForEach(Array(deck.slides.enumerated()), id: \.offset) { pair in
                    DeckSlideView(
                        slide: pair.element,
                        deck: deck,
                        palette: palette,
                        index: pair.offset,
                        total: deck.slides.count,
                        reveal: current == pair.offset,
                        motionOn: motionOn
                    )
                    .padding(.horizontal, 8)
                    .tag(pair.offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .environment(\.layoutDirection, deck.isArabic ? .rightToLeft : .leftToRight)
            .ignoresSafeArea(edges: .bottom)

            if chrome {
                chromeLayer.transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) { chrome.toggle() }
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showsNotes) { notesSheet }
        .task(id: current) { await prefetchNeighbours() }
    }

    // MARK: - Chrome

    private var chromeLayer: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            circleButton("xmark") { dismiss() }
            Spacer(minLength: 0)
            Text(deck.title.isEmpty ? DeckCopy.deck.text(lang) : deck.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            if exporting {
                ProgressView().tint(palette.accent).frame(width: 38, height: 38)
            } else if let exported {
                ShareLink(item: exported) {
                    chip("square.and.arrow.up")
                }
                .accessibilityLabel(Text(Strings.Common.share(lang)))
            } else {
                circleButton("square.and.arrow.down") { Task { await export() } }
                    .accessibilityLabel(Text(DeckCopy.save.text(lang)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            circleButton("text.bubble") { showsNotes = true }
                .accessibilityLabel(Text(DeckCopy.notes.text(lang)))
            Spacer(minLength: 0)
            Text("\(current + 1) / \(deck.slides.count)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule(style: .continuous).fill(Color.black.opacity(0.30)))
            Spacer(minLength: 0)
            // A balancing slot, so the counter sits in the middle rather than beside the button.
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
    }

    private func circleButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            chip(symbol)
        }
        .buttonStyle(.plain)
    }

    private func chip(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.ink)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Color.black.opacity(0.32)))
            .contentShape(Circle())
    }

    // MARK: - Notes

    private var notesSheet: some View {
        let notes = deck.slides.indices.contains(current)
            ? deck.slides[current].notes.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return NavigationStack {
            ScrollView {
                Text(notes.isEmpty ? DeckCopy.noNotes.text(lang) : notes)
                    .font(.system(size: 16))
                    .foregroundStyle(notes.isEmpty ? appPalette.textMuted : appPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .bidiIsland(for: notes, fallback: lang)
            }
            .background(appPalette.background)
            .navigationTitle(DeckCopy.notes.text(lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { showsNotes = false } label: { Text(Strings.Common.done(lang)) }
                }
            }
        }
        .presentationDetents([.medium])
        .firasSheetBackground(appPalette)
        .tint(appPalette.accent)
    }

    // MARK: - Saving

    /// Pictures are fetched before the render, not during it: `ImageRenderer` draws one frame with
    /// whatever is already in memory, and an `AsyncImage` that has not finished loading would leave
    /// a grey plate on the page.
    private func prefetchNeighbours() async {
        // An empty deck never reaches this screen, but a range built from `count - 1` would trap
        // rather than do nothing if one ever did.
        guard !deck.slides.isEmpty else { return }
        let lower = max(0, current - 1)
        let upper = max(lower, min(deck.slides.count - 1, current + 2))
        await DeckImageCache.prefetch((lower...upper).map { deck.slides[$0].image })
    }

    private func export() async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        await DeckImageCache.prefetch(deck.slides.map(\.image))
        exported = DeckPDF.write(deck: deck, palette: palette)
        if exported != nil { Haptics.select() }
    }
}

/// The deck as a PDF, one slide to a page at the canvas size.
///
/// The same `DeckSlideView` draws the page, which is the point of laying slides out on a fixed
/// canvas: the file the reader saves is the presentation they were just looking at, not a second
/// implementation of it that drifts.
@MainActor
enum DeckPDF {

    static func write(deck: DeckMeta, palette: DeckPalette) -> URL? {
        guard !deck.slides.isEmpty else { return nil }
        let size = DeckSlideView.canvas
        let name = DeckPDF.filename(for: deck)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)

        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            return nil
        }

        for (index, slide) in deck.slides.enumerated() {
            let page = DeckSlideView(
                slide: slide,
                deck: deck,
                palette: palette,
                index: index,
                total: deck.slides.count,
                reveal: true,
                motionOn: false
            )
            .frame(width: size.width, height: size.height)

            let renderer = ImageRenderer(content: page)
            renderer.scale = 2
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return url
    }

    /// A filename made of the deck's own title, with everything a file system objects to removed.
    private static func filename(for deck: DeckMeta) -> String {
        let raw = deck.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = ""
        for character in raw.prefix(48) {
            if character.isLetter || character.isNumber || character == " " || character == "-" {
                cleaned.append(character)
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "deck" : cleaned) + ".pdf"
    }
}
