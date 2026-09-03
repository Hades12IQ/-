import SwiftUI

/// The five products, as five rows (`web-chat-ux.md §2`, `design-brief.md §7.2`).
///
/// This is the only way into Agent, Code, Brain and the Studio, so each row carries its own
/// one-line subtitle rather than an icon a reader has to decode. A product with a job running
/// shows the live dot — or the count once more than one is in flight (`web-agent-ux.md §10`).
@MainActor
struct SidebarProductSwitcher: View {

    private let env: AppEnvironment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    var body: some View {
        VStack(spacing: 2) {
            /* NO STUDIO ROW. The owner asked twice: "الستوديو شنو هذا ما اريده، اني اريد
               الصنع بس يكون داخل فراس جات". A picture, a video and a song are things you ask for in the
               conversation, and they come back in it; a separate destination for them was a second
               place to look for one feature. The product itself still exists so a deep link and the
               media viewer keep working — it just is not a place you navigate to on purpose. */
            ForEach(ProductKind.allCases.filter { $0 != .studio }) { product in
                row(for: product)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Strings.Shell.productsHeader(lang)))
    }

    // MARK: - Row

    private func row(for product: ProductKind) -> some View {
        let selected = env.router.product == product
        let live = env.jobs.liveCount(product: product)
        return Button {
            guard !selected else {
                env.router.drawerOpen = false
                return
            }
            Haptics.select()
            env.router.switchTo(product: product)
        } label: {
            rowBody(product: product, selected: selected, live: live)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(Text(product.title(lang)))
        .accessibilityValue(Text(accessibilityValue(product: product, live: live)))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func rowBody(product: ProductKind, selected: Bool, live: Int) -> some View {
        HStack(spacing: 11) {
            Image(systemName: product.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? palette.accent : palette.textSecondary)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(product.title(lang))
                    .font(.system(size: 15, weight: selected ? .semibold : .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Text(Strings.Shell.subtitle(for: product).text(lang))
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            activity(live: live)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? palette.accentSoft : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? palette.accentRing : Color.clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private func activity(live: Int) -> some View {
        if live > 1 {
            Text(ArabicText.count(live, lang))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 7)
                .frame(minHeight: 18)
                .background { Capsule(style: .continuous).fill(palette.accentSoft) }
                .accessibilityHidden(true)
        } else if live == 1 {
            LiveDot(palette: palette, motionOn: motionOn)
        }
    }

    private func accessibilityValue(product: ProductKind, live: Int) -> String {
        let subtitle = Strings.Shell.subtitle(for: product).text(lang)
        guard live > 0 else { return subtitle }
        let running = live == 1
            ? Strings.Shell.runningOne(lang)
            : Strings.Shell.runningMany.fmt(lang, ArabicText.count(live, lang))
        return subtitle + " — " + running
    }
}
