import SwiftUI
import UIKit
import UserNotifications

/// The notification page, and the destination of `AppSheet.notificationExplainer`
/// (`audit-ios-shell-settings-design.md F2, F22`).
///
/// The promise here is the one the app can actually keep: the **server** keeps a long job running
/// after the app is gone, and this device is told "usually within minutes" when it next gets a
/// slice of background time. There is no APNs entitlement in this build, so nothing here claims
/// instant delivery, and nothing here calls `registerForRemoteNotifications` (F1).
///
/// Every authorization state has a screen: not asked (one button), authorized (what you will get),
/// provisional/ephemeral (quiet delivery, and how to make it loud), denied (the button that opens
/// system settings, because nothing inside the app can undo a denial).
@MainActor
struct NotificationSettingsView: View {

    private let env: AppEnvironment

    @Environment(\.scenePhase) private var scenePhase

    @State private var isRequesting = false
    /// The system prompt was answered with "Don't Allow" during this visit — worth one extra line
    /// so the button that just did nothing is explained.
    @State private var wasDeclinedHere = false

    init(env: AppEnvironment) {
        self.env = env
    }

    var body: some View {
        SettingsPageBody(palette: palette) {
            explainerPanel
            statusPanel
        }
        .navigationTitle(Strings.Settings.Notifications.header(lang))
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.notifications.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the system settings app is the only way `denied` ever becomes
            // `authorized`, so the status has to be re-read rather than remembered.
            guard phase == .active else { return }
            Task { await env.notifications.refreshAuthorization() }
        }
    }

    // MARK: - Explainer

    private var explainerPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Notifications.header(lang),
            palette: palette,
            lang: lang
        ) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                Text(Strings.Settings.Notifications.explainer(lang))
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .bidiIsland(for: Strings.Settings.Notifications.explainer(lang), fallback: lang)

            SettingsDivider(palette: palette)

            SettingsNote(text: Strings.Settings.Notifications.whenNote(lang), palette: palette)

            SettingsDivider(palette: palette)

            SettingsNote(text: Strings.Settings.Notifications.sampleNote(lang), palette: palette)
        }
    }

    // MARK: - Status

    private var statusPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Notifications.statusLabel(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsValueRow(title: Strings.Settings.Notifications.statusLabel(lang), palette: palette) {
                HStack(spacing: 6) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(statusText)
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(statusColor)
            }

            SettingsDivider(palette: palette)

            actions
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch env.notifications.authorization {
            case .authorized:
                SettingsNoticeBanner(
                    text: Strings.Settings.Notifications.onNote(lang),
                    kind: .success,
                    palette: palette
                )
            case .provisional, .ephemeral:
                SettingsNoticeBanner(
                    text: Strings.Settings.Notifications.quietNote(lang),
                    kind: .info,
                    palette: palette
                )
                SettingsSubmitButton(
                    title: Strings.Settings.Notifications.openSystemSettings(lang),
                    symbol: "gearshape",
                    palette: palette,
                    action: { openSystemSettings() }
                )
            case .denied:
                SettingsNoticeBanner(
                    text: wasDeclinedHere
                        ? Strings.Settings.Notifications.justDenied(lang)
                        : Strings.Settings.Notifications.deniedNote(lang),
                    kind: .info,
                    palette: palette
                )
                SettingsSubmitButton(
                    title: Strings.Settings.Notifications.openSystemSettings(lang),
                    symbol: "gearshape",
                    palette: palette,
                    action: { openSystemSettings() }
                )
            default:
                SettingsSubmitButton(
                    title: Strings.Settings.Notifications.enableButton(lang),
                    symbol: "bell.badge",
                    palette: palette,
                    isWorking: isRequesting,
                    action: { request() }
                )
            }
        }
    }

    // MARK: - Actions

    /// This page **is** the explanation, so the flag is set before the system prompt and the
    /// separate one-line explainer never appears afterwards.
    private func request() {
        guard !isRequesting else { return }
        isRequesting = true
        wasDeclinedHere = false
        env.prefs.notificationsExplained = true
        Task {
            let granted = await env.notifications.askSystem()
            isRequesting = false
            if granted {
                Haptics.undo()
            } else {
                wasDeclinedHere = true
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Plumbing

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    private var statusText: String {
        switch env.notifications.authorization {
        case .authorized:
            return Strings.Settings.Notifications.statusOn(lang)
        case .provisional, .ephemeral:
            return Strings.Settings.Notifications.statusQuiet(lang)
        case .denied:
            return Strings.Settings.Notifications.statusOff(lang)
        default:
            return Strings.Settings.Notifications.statusUnknown(lang)
        }
    }

    private var statusSymbol: String {
        switch env.notifications.authorization {
        case .authorized:
            return "checkmark.circle.fill"
        case .provisional, .ephemeral:
            return "bell.badge.slash"
        case .denied:
            return "bell.slash.fill"
        default:
            return "bell"
        }
    }

    private var statusColor: Color {
        switch env.notifications.authorization {
        case .authorized:
            return palette.success
        case .provisional, .ephemeral:
            return palette.accent
        case .denied:
            return palette.error
        default:
            return palette.textSecondary
        }
    }
}
