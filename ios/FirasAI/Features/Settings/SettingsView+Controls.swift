import SwiftUI

// Buttons, fields, notices and the page shell every Settings page ends up using. Split from
// `SettingsView+Components.swift` only to keep both files readable.

// MARK: - Buttons

/// The one button shape settings uses: full width, 44 pt, optional spinner in place of the label.
@MainActor
struct SettingsSubmitButton: View {

    private let title: String
    private let symbol: String?
    private let palette: FirasPalette
    private let prominent: Bool
    private let destructive: Bool
    private let isWorking: Bool
    private let isDisabled: Bool
    private let action: () -> Void

    init(
        title: String,
        symbol: String? = nil,
        palette: FirasPalette,
        prominent: Bool = true,
        destructive: Bool = false,
        isWorking: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.palette = palette
        self.prominent = prominent
        self.destructive = destructive
        self.isWorking = isWorking
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background { background }
            .overlay { border }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isWorking)
        .opacity(isDisabled ? 0.5 : 1)
    }

    private var accentColor: Color { destructive ? palette.error : palette.accent }

    private var foreground: Color {
        prominent ? (destructive ? Color.white : palette.onAccent) : accentColor
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(prominent ? accentColor : palette.surfaceSunken)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(prominent ? Color.clear : accentColor.opacity(0.35), lineWidth: 1)
    }
}

// MARK: - Fields

/// A single-line field styled like the rest of the panel. A password field is a `SecureField`,
/// which is a different type from `TextField` and cannot share its modifiers, so each `Kind`
/// spells out its own branch.
@MainActor
struct SettingsField: View {

    enum Kind: Sendable { case plain, email, password }

    private let title: String
    private let placeholder: String
    private let kind: Kind
    private let palette: FirasPalette
    @Binding private var text: String

    init(
        title: String,
        placeholder: String = "",
        kind: Kind = .plain,
        text: Binding<String>,
        palette: FirasPalette
    ) {
        self.title = title
        self.placeholder = placeholder
        self.kind = kind
        self._text = text
        self.palette = palette
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.textSecondary)

            field
                .font(.system(size: 16))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.surfaceSunken)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 1)
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var field: some View {
        switch kind {
        case .plain:
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.sentences)
        case .email:
            TextField(placeholder, text: $text)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .forceLTR()
        case .password:
            SecureField(placeholder, text: $text)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .forceLTR()
        }
    }
}

// MARK: - Notice

/// The one inline message strip: a result, a refusal, or a warning. Never a server sentence.
@MainActor
struct SettingsNoticeBanner: View {

    enum Kind: Sendable { case info, success, error }

    let text: String
    let kind: Kind
    let palette: FirasPalette

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch kind {
        case .info: return palette.accent
        case .success: return palette.success
        case .error: return palette.error
        }
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Page shell

/// Every settings page is the same scroll view: one column, reading width, glass sheet behind.
@MainActor
struct SettingsPageBody<Content: View>: View {

    private let palette: FirasPalette
    private let content: Content

    init(palette: FirasPalette, @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }
}

// MARK: - Choice row

/// A radio row: symbol, label, tagline, optional badge, check mark. Used for the four tiers and
/// the two reply styles.
@MainActor
struct SettingsChoiceRow: View {

    let title: String
    let hint: String?
    let badge: String?
    let symbol: String
    let selected: Bool
    let palette: FirasPalette
    let lang: AppLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? palette.accent : palette.textMuted)
                    .frame(width: 22)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                        if let badge, !badge.isEmpty {
                            Text(badge)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background {
                                    Capsule(style: .continuous).fill(palette.accentSoft)
                                }
                        }
                    }
                    if let hint, !hint.isEmpty {
                        Text(hint)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? palette.accent : palette.border)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .bidiIsland(for: title, fallback: lang)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
