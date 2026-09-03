import SwiftUI

/// The deck as it sits in the conversation: the cover slide at a glance, its title, how many slides
/// there are, and a way in.
///
/// The card draws the real first slide rather than an icon — the same `DeckSlideView` the player
/// and the PDF use — so the reader sees the presentation, not a placeholder for one. While the
/// agent is still writing slides into the deck the card says so and keeps updating; the deck is
/// openable throughout, because a half-built deck is still worth reading.
@MainActor
struct DeckCard: View {

    let deck: DeckMeta
    let palette: FirasPalette
    let lang: AppLanguage
    let motionOn: Bool

    @State private var open = false

    private var deckPalette: DeckPalette { DeckPalette.named(deck.theme) }

    var body: some View {
        VStack(spacing: 0) {
            cover
            footer
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { present() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(deck.title.isEmpty ? DeckCopy.deck.text(lang) : deck.title))
        .accessibilityHint(Text(DeckCopy.open.text(lang)))
        .fullScreenCover(isPresented: $open) {
            DeckViewer(deck: deck, lang: lang, appPalette: palette, motionOn: motionOn)
        }
    }

    // MARK: - Cover

    @ViewBuilder
    private var cover: some View {
        if let first = deck.slides.first {
            ZStack(alignment: .bottomTrailing) {
                DeckSlideView(
                    slide: first,
                    deck: deck,
                    palette: deckPalette,
                    index: 0,
                    total: deck.slides.count,
                    // A cover is a still. It is not the moment of arriving at a slide, and a card
                    // that animates every time the transcript re-lays-out is noise.
                    reveal: true,
                    motionOn: false,
                    showsFooter: false
                )
                playBadge
                    .padding(12)
            }
        }
    }

    private var playBadge: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Color.black.opacity(0.42)))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(deck.title.isEmpty ? DeckCopy.deck.text(lang) : deck.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if deck.isBuilding {
                ProgressView().controlSize(.small).tint(palette.accent)
            } else {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bidiIsland(for: deck.title, fallback: lang)
    }

    private var subtitle: String {
        if deck.isBuilding { return DeckCopy.building.text(lang) }
        if !deck.subtitle.isEmpty { return deck.subtitle }
        return DeckCopy.slides.fmt(lang, "\(deck.slides.count)")
    }

    private func present() {
        guard !deck.slides.isEmpty else { return }
        Haptics.select()
        open = true
    }
}
