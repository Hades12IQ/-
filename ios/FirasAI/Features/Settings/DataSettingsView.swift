import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Conversations (backup) → device storage → notifications → memory → about
/// (`web-auth-account-settings.md §6.5`, `audit-ios-shell-settings-design.md F20–F23`).
///
/// Notifications and memory are pushed pages rather than a sixth tab: `SettingsSection` has five
/// cases and they are part of the navigation contract.
@MainActor
struct DataSettingsView: View {

    let env: AppEnvironment

    @State var exportDocument: FirasChatBackupDocument?
    @State var showsExporter = false
    @State var showsImporter = false
    @State var pendingImport: FirasChatBackup?
    @State var confirmsImport = false
    @State var confirmsClear = false
    @State var isPreparingExport = false
    @State var isImporting = false
    @State var notice: Notice?
    @State var serverBuild: String?

    init(env: AppEnvironment) {
        self.env = env
    }

    var body: some View {
        SettingsPageBody(palette: palette) {
            conversationsPanel
            storagePanel
            morePanel
            aboutPanel
        }
        .task { await loadServerBuild() }
        .fileExporter(
            isPresented: $showsExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: ChatBackupFileReader.defaultFilename(for: Date())
        ) { result in
            exportDocument = nil
            switch result {
            case .success:
                notice = Notice(text: Strings.Settings.Storage.exported(lang), kind: .success)
            case .failure:
                notice = Notice(text: Strings.Errors.generic(lang), kind: .error)
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handlePickedFile(result)
        }
        .confirmationDialog(
            Text(Strings.Settings.Storage.importConfirm(lang)),
            isPresented: $confirmsImport,
            titleVisibility: .visible
        ) {
            Button {
                runImport()
            } label: {
                Text(Strings.Settings.Storage.importButton(lang))
            }
            Button(role: .cancel) {
                pendingImport = nil
            } label: {
                Text(Strings.Common.cancel(lang))
            }
        }
        .confirmationDialog(
            Text(Strings.Settings.Storage.clearConfirm(lang)),
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                env.prefs.resetToDefaults()
                notice = Notice(text: Strings.Settings.Storage.cleared(lang), kind: .success)
            } label: {
                Text(Strings.Settings.Storage.clearButton(lang))
            }
            Button(role: .cancel) {} label: {
                Text(Strings.Common.cancel(lang))
            }
        }
    }

    // MARK: - Conversations

    private var conversationsPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Storage.conversationsHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsNote(text: Strings.Settings.Storage.conversationsNote(lang), palette: palette)

            VStack(spacing: 10) {
                SettingsSubmitButton(
                    title: isPreparingExport
                        ? Strings.Settings.Storage.exporting(lang)
                        : Strings.Settings.Storage.exportButton(lang),
                    symbol: "square.and.arrow.up",
                    palette: palette,
                    isWorking: isPreparingExport,
                    isDisabled: isImporting,
                    action: { prepareExport() }
                )

                SettingsSubmitButton(
                    title: isImporting
                        ? Strings.Settings.Storage.importing(lang)
                        : Strings.Settings.Storage.importButton(lang),
                    symbol: "square.and.arrow.down",
                    palette: palette,
                    prominent: false,
                    isWorking: isImporting,
                    isDisabled: isPreparingExport,
                    action: { showsImporter = true }
                )

                if let notice {
                    SettingsNoticeBanner(text: notice.text, kind: notice.kind, palette: palette)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Device storage

    private var storagePanel: some View {
        SettingsPanel(
            title: Strings.Settings.Storage.storageHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsNote(
                text: env.session.isGuest
                    ? Strings.Settings.Storage.storageNoteGuest(lang)
                    : Strings.Settings.Storage.storageNote(lang),
                palette: palette
            )

            SettingsSubmitButton(
                title: Strings.Settings.Storage.clearButton(lang),
                symbol: "arrow.counterclockwise",
                palette: palette,
                prominent: false,
                destructive: true,
                action: { confirmsClear = true }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Notifications and memory

    private var morePanel: some View {
        SettingsPanel(
            title: Strings.Settings.Notifications.header(lang),
            palette: palette,
            lang: lang
        ) {
            NavigationLink {
                NotificationSettingsView(env: env)
            } label: {
                linkRow(
                    title: Strings.Settings.Notifications.header(lang),
                    detail: notificationStatusText,
                    symbol: "bell.badge"
                )
            }
            .buttonStyle(.plain)

            SettingsDivider(palette: palette)

            NavigationLink {
                MemorySettingsView(env: env)
            } label: {
                linkRow(
                    title: Strings.Settings.Memory.open(lang),
                    detail: nil,
                    symbol: "sparkles.rectangle.stack"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func linkRow(title: String, detail: String?, symbol: String) -> some View {
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
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .bidiIsland(for: title, fallback: lang)
    }

    private var notificationStatusText: String {
        switch env.notifications.authorization {
        case .authorized, .provisional, .ephemeral:
            return Strings.Settings.Notifications.statusOn(lang)
        case .denied:
            return Strings.Settings.Notifications.statusOff(lang)
        default:
            return Strings.Settings.Notifications.statusUnknown(lang)
        }
    }

    // MARK: - About

    private var aboutPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Storage.aboutHeader(lang),
            palette: palette,
            lang: lang
        ) {
            SettingsValueRow(title: Strings.Settings.Storage.versionLabel(lang), palette: palette) {
                Text(Self.bundleVersion)
                    .font(FirasType.mono)
                    .foregroundStyle(palette.textSecondary)
                    .forceLTR()
            }

            SettingsDivider(palette: palette)

            SettingsValueRow(title: Strings.Settings.Storage.serverLabel(lang), palette: palette) {
                Text(serverBuild ?? "—")
                    .font(FirasType.mono)
                    .foregroundStyle(palette.textMuted)
                    .forceLTR()
            }

            SettingsDivider(palette: palette)

            SettingsSubmitButton(
                title: Strings.Settings.Storage.updatesLink(lang),
                symbol: "megaphone",
                palette: palette,
                prominent: false,
                action: { env.router.sheet = .announcements }
            )
            .padding(.horizontal, 14)
            .padding(.top, 12)

            SettingsNote(text: Strings.Settings.Storage.company(lang), palette: palette)
        }
    }

    // MARK: - About plumbing

    /// The bundle version, not `/api/version`: that route reports the newest mtime of the web
    /// assets and means nothing in an app binary (`web-auth-account-settings.md §12.8`).
    private static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != short else {
            return short
        }
        return short + " (" + build + ")"
    }

    private func loadServerBuild() async {
        guard serverBuild == nil else { return }
        let answered = (try? await env.api.version()) ?? ""
        serverBuild = answered.isEmpty ? nil : answered
    }

    // MARK: - Plumbing

    var palette: FirasPalette { env.prefs.palette }
    var lang: AppLanguage { env.prefs.lang }

    struct Notice {
        let text: String
        let kind: SettingsNoticeBanner.Kind
    }
}
