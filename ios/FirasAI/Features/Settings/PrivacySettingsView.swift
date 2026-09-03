import Foundation
import SwiftUI

/// The privacy page: the one switch that decides whether this reader's conversations may be used
/// by the Firas AI team to train and improve the models, plus the two other places privacy is
/// actually decided (what Firas remembers, and the two legal documents).
///
/// The switch is not a preference in the ordinary sense — it is a record of an answer the reader
/// gave — so it does not live in `PreferencesStore` and `resetToDefaults()` can never flip it back
/// on behind their back. `TrainingConsent` below owns the record.
///
/// The copy says only what is true today: the answer is kept on this device. There is no server
/// route to carry it yet (`server.mjs` has no preferences or consent endpoint), so the page does
/// not promise that anything happens elsewhere.
@MainActor
struct PrivacySettingsView: View {

    private let env: AppEnvironment

    /// The answer on screen. Mirrored into `TrainingConsent` on every change; read once here so
    /// the row paints on the first frame without touching `UserDefaults` inside `body`.
    @State private var choice: TrainingConsent

    /// Whether an answer was ever recorded on this device. An install that predates the question
    /// has none, and the page says so instead of showing a silent, meaningless "off".
    @State private var hasAnswer: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment) {
        self.env = env
        _choice = State(initialValue: TrainingConsent.effective)
        _hasAnswer = State(initialValue: TrainingConsent.recorded != nil)
    }

    var body: some View {
        SettingsPageBody(palette: palette) {
            trainingPanel
            elsewherePanel
        }
    }

    // MARK: - Training

    private var trainingPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Privacy.trainingHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsToggleRow(
                title: Strings.Settings.Privacy.trainingToggle(lang),
                hint: Strings.Settings.Privacy.trainingToggleHint(lang),
                isOn: trainingBinding,
                palette: palette
            )

            SettingsDivider(palette: palette)

            SettingsNote(text: meaningText, palette: palette)

            SettingsNote(text: Strings.Settings.Privacy.deviceNote(lang), palette: palette)

            if !hasAnswer {
                SettingsNote(text: Strings.Settings.Privacy.notAnsweredNote(lang), palette: palette)
            }
        }
    }

    /// One sentence that describes the state the switch is in right now — the answer to "so what
    /// does this actually do?", which a hint under a switch never quite gives.
    private var meaningText: String {
        choice == .accepted
            ? Strings.Settings.Privacy.meaningOn(lang)
            : Strings.Settings.Privacy.meaningOff(lang)
    }

    // MARK: - The rest of privacy

    private var elsewherePanel: some View {
        SettingsPanel(
            title: Strings.Settings.Privacy.elsewhereHeader(lang),
            palette: palette,
            lang: lang
        ) {
            NavigationLink {
                MemorySettingsView(env: env)
            } label: {
                pushRow(
                    title: Strings.Settings.Memory.open(lang),
                    symbol: "sparkles.rectangle.stack"
                )
            }
            .buttonStyle(.plain)

            SettingsDivider(palette: palette)

            legalRow(
                title: Strings.Auth.privacyTitle(lang),
                address: Strings.Auth.privacyURL,
                symbol: "hand.raised"
            )

            SettingsDivider(palette: palette)

            legalRow(
                title: Strings.Auth.termsTitle(lang),
                address: Strings.Auth.termsURL,
                symbol: "doc.text"
            )
        }
    }

    // MARK: - Rows

    private func pushRow(title: String, symbol: String) -> some View {
        row(title: title, symbol: symbol, trailing: "chevron.forward")
    }

    @ViewBuilder
    private func legalRow(title: String, address: String, symbol: String) -> some View {
        if let url = URL(string: address) {
            Link(destination: url) {
                row(title: title, symbol: symbol, trailing: "arrow.up.forward")
            }
            .buttonStyle(.plain)
        } else {
            row(title: title, symbol: symbol, trailing: nil)
                .opacity(0.5)
        }
    }

    private func row(title: String, symbol: String, trailing: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 22)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.textPrimary)

            Spacer(minLength: 8)

            if let trailing {
                Image(systemName: trailing)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .bidiIsland(for: title, fallback: lang)
    }

    // MARK: - Plumbing

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    private var trainingBinding: Binding<Bool> {
        Binding(
            get: { choice == .accepted },
            set: { newValue in apply(newValue ? .accepted : .declined) }
        )
    }

    private func apply(_ newChoice: TrainingConsent) {
        guard newChoice != choice || !hasAnswer else { return }
        Haptics.select()
        withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
            choice = newChoice
            hasAnswer = true
        }
        TrainingConsent.record(newChoice)
        env.toasts.show(Strings.Settings.Privacy.saved(lang))
    }
}

// MARK: - The record

/// The reader's answer to the one question the app asks about their data: may the Firas AI team
/// use their conversations to train and improve the models?
///
/// It is deliberately **not** a `PreferencesStore` property. Consent is a record, not a taste:
/// `resetToDefaults()` clears preferences, and an answer of "no" that a Clear button silently
/// turns back into "yes" is not consent at all. `nil` means nobody has been asked on this device,
/// and `effective` reads that as `.declined` — never asked is never agreed.
enum TrainingConsent: String, Sendable, Hashable, CaseIterable {

    case accepted
    case declined

    /// The recorded answer, or `nil` when this device has never answered.
    static var recorded: TrainingConsent? {
        guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return nil }
        return TrainingConsent(rawValue: raw)
    }

    /// The answer the app acts on. Absent an answer, the privacy-preserving reading wins.
    static var effective: TrainingConsent {
        recorded ?? .declined
    }

    /// The one question callers outside this file ask.
    static var isAllowed: Bool {
        effective == .accepted
    }

    static func record(_ choice: TrainingConsent) {
        UserDefaults.standard.set(choice.rawValue, forKey: storageKey)
    }

    private static let storageKey = "trainingConsent"
}
