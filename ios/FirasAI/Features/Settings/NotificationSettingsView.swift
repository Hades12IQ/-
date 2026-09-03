import SwiftUI
import UIKit
import UserNotifications

/// The notification page, and the one-line explainer sheet shown before the system prompt
/// (`AppSheet.notificationExplainer`, `audit-ios-shell-settings-design.md F2, F22`).
///
/// The promise here is the one the app can actually keep: the **server** keeps a long job running
/// after the app is gone, and this device is told "usually within minutes" when it next gets a
/// slice of background time. There is no APNs entitlement in this build, so nothing here claims
/// instant delivery, and nothing here calls `registerForRemoteNotifications` (F1).
@MainActor
struct NotificationSettingsView: View {

    private let env: AppEnvironment

    @State private var isRequesting = false

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

            VStack(alignment: .leading, spacing: 10) {
                if isAuthorized {
                    SettingsNoticeBanner(
                        text: Strings.Settings.Notifications.onNote(lang),
                        kind: .success,
                        palette: palette
                    )
                } else if isDenied {
                    SettingsNoticeBanner(
                        text: Strings.Settings.Notifications.deniedNote(lang),
                        kind: .info,
                        palette: palette
                    )
                    SettingsSubmitButton(
                        title: Strings.Settings.Notifications.openSystemSettings(lang),
                        symbol: "gearshape",
                        palette: palette,
                        action: { openSystemSettings() }
                    )
                } else {
                    SettingsSubmitButton(
                        title: Strings.Settings.Notifications.enableButton(lang),
                        symbol: "bell.badge",
                        palette: palette,
                        isWorking: isRequesting,
                        action: { request() }
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Actions

    /// The explainer has been on screen the whole time this page was, so the flag is set before the
    /// system prompt — `NotificationManager.requestIfNeeded()` refuses to ask otherwise.
    private func request() {
        guard !isRequesting else { return }
        isRequesting = true
        env.prefs.notificationsExplained = true
        Task {
            let granted = await env.notifications.requestIfNeeded()
            isRequesting = false
            if granted {
                Haptics.undo()
            } else {
                await env.notifications.refreshAuthorization()
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

    private var isAuthorized: Bool {
        switch env.notifications.authorization {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    private var isDenied: Bool { env.notifications.authorization == .denied }

    private var statusText: String {
        if isAuthorized { return Strings.Settings.Notifications.statusOn(lang) }
        if isDenied { return Strings.Settings.Notifications.statusOff(lang) }
        return Strings.Settings.Notifications.statusUnknown(lang)
    }

    private var statusSymbol: String {
        if isAuthorized { return "checkmark.circle.fill" }
        if isDenied { return "bell.slash.fill" }
        return "bell"
    }

    private var statusColor: Color {
        if isAuthorized { return palette.success }
        if isDenied { return palette.error }
        return palette.textSecondary
    }
}
