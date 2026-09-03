import SwiftUI

// The pieces every Settings page is built from. They are deliberately plain: a settings page is a
// column of flat opaque `SurfaceCard`s inside one glass sheet, never glass on glass
// (`design-brief.md §2.5`, `audit-ios-shell-settings-design.md F5`).

// MARK: - Panel

/// One titled section: a header outside the card, the rows inside it.
@MainActor
struct SettingsPanel<Content: View>: View {

    private let title: String
    private let subtitle: String?
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        palette: FirasPalette,
        lang: AppLanguage,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.palette = palette
        self.lang = lang
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(palette)
        }
        .bidiIsland(for: title, fallback: lang)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows

/// A switch with a label and an optional hint underneath.
@MainActor
struct SettingsToggleRow: View {

    private let title: String
    private let hint: String?
    private let palette: FirasPalette
    private let isDisabled: Bool
    @Binding private var isOn: Bool

    init(
        title: String,
        hint: String? = nil,
        isOn: Binding<Bool>,
        palette: FirasPalette,
        isDisabled: Bool = false
    ) {
        self.title = title
        self.hint = hint
        self._isOn = isOn
        self.palette = palette
        self.isDisabled = isDisabled
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isDisabled ? palette.textMuted : palette.textPrimary)
                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .tint(palette.accent)
        .disabled(isDisabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }
}

/// A label with any trailing value: a version number, a status word, a picker.
@MainActor
struct SettingsValueRow<Value: View>: View {

    private let title: String?
    private let hint: String?
    private let palette: FirasPalette
    private let value: Value

    /// `title` is optional for the same reason as on the segmented row: the panel header often
    /// already names the control.
    init(
        title: String? = nil,
        hint: String? = nil,
        palette: FirasPalette,
        @ViewBuilder value: () -> Value
    ) {
        self.title = title
        self.hint = hint
        self.palette = palette
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                }
                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            value
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }
}

/// A hairline between two rows inside the same card.
@MainActor
struct SettingsDivider: View {
    let palette: FirasPalette

    var body: some View {
        Rectangle()
            .fill(palette.border)
            .frame(height: 1)
            .padding(.leading, 14)
            .accessibilityHidden(true)
    }
}

/// A plain block of explanatory copy inside a card.
@MainActor
struct SettingsNote: View {
    let text: String
    let palette: FirasPalette

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
    }
}

// MARK: - Segmented control

/// A themed segmented control. `Picker(.segmented)` cannot be tinted per theme, and six themes ×
/// two families is exactly where the system control looks wrong.
@MainActor
struct SettingsSegmentedRow<Option: Hashable>: View {

    private let title: String?
    private let hint: String?
    private let options: [Option]
    private let label: (Option) -> String
    private let palette: FirasPalette
    private let motionOn: Bool
    @Binding private var selection: Option

    /// `title` is optional: when the panel header already names the control, repeating it inside
    /// the card is noise.
    init(
        title: String? = nil,
        hint: String? = nil,
        options: [Option],
        selection: Binding<Option>,
        label: @escaping (Option) -> String,
        palette: FirasPalette,
        motionOn: Bool
    ) {
        self.title = title
        self.hint = hint
        self.options = options
        self._selection = selection
        self.label = label
        self.palette = palette
        self.motionOn = motionOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                }
                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    segment(option)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func segment(_ option: Option) -> some View {
        let selected = option == selection
        return Button {
            guard !selected else { return }
            Haptics.select()
            withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                selection = option
            }
        } label: {
            Text(label(option))
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? palette.onAccent : palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 36)
                .background {
                    Capsule(style: .continuous)
                        .fill(selected ? palette.accent : palette.surfaceSunken)
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
