import SwiftUI

/// "What Firas remembers about you" — the member-only memory list
/// (`web-auth-account-settings.md §7`, `server-auth-session-account.md §5.5`).
///
/// The web defines this screen and never opens it; the app does. Guests are stopped **before** the
/// request: `GET /api/memory` answers 401 for a guest, and a 401 is not an error the reader
/// deserves to see — it is a sign-up prompt.
@MainActor
struct MemorySettingsView: View {

    private let env: AppEnvironment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var confirmsClearAll = false

    init(env: AppEnvironment) {
        self.env = env
    }

    var body: some View {
        SettingsPageBody(palette: palette) {
            if env.session.isMember {
                memberBody
            } else {
                guestPanel
            }
        }
        .navigationTitle(Strings.Settings.Memory.title(lang))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadIfMember() }
        .confirmationDialog(
            Text(Strings.Settings.Memory.clearAllConfirm(lang)),
            isPresented: $confirmsClearAll,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                delete(id: nil)
            } label: {
                Text(Strings.Settings.Memory.clearAll(lang))
            }
            Button(role: .cancel) {} label: {
                Text(Strings.Common.cancel(lang))
            }
        }
    }

    // MARK: - Member

    @ViewBuilder
    private var memberBody: some View {
        SettingsPanel(
            title: Strings.Settings.Memory.title(lang),
            subtitle: Strings.Settings.Memory.subtitle(lang),
            palette: palette,
            lang: lang
        ) {
            if let failure = env.memory.failure, env.memory.entries.isEmpty {
                failureState(failure)
            } else if env.memory.entries.isEmpty {
                emptyState
            } else {
                entryRows
            }
        }

        if !env.memory.entries.isEmpty {
            footer
        }
    }

    private var entryRows: some View {
        ForEach(env.memory.entries) { entry in
            if entry.id != env.memory.entries.first?.id {
                SettingsDivider(palette: palette)
            }
            row(entry)
        }
    }

    private func row(_ entry: MemoryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.text)
                .font(.system(size: 15))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: entry.text, fallback: lang)

            Button {
                delete(id: entry.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.textMuted)
                    .frame(width: 30, height: 30)
                    .background { Circle().fill(palette.surfaceSunken) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(env.memory.isMutating)
            .accessibilityLabel(Text(Strings.Settings.Memory.deleteOne(lang)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Strings.Settings.Memory.count(env.memory.entries.count, lang))
                .font(.system(size: 13))
                .foregroundStyle(palette.textMuted)
                .padding(.horizontal, 4)

            SettingsSubmitButton(
                title: Strings.Settings.Memory.clearAll(lang),
                symbol: "trash",
                palette: palette,
                prominent: false,
                destructive: true,
                isWorking: env.memory.isMutating,
                action: { confirmsClearAll = true }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - States

    @ViewBuilder
    private var emptyState: some View {
        if env.memory.isLoading && !env.memory.hasLoaded {
            SkeletonView(kind: .sidebar, palette: palette, motionOn: motionOn)
                .padding(14)
        } else {
            EmptyStateView(
                title: Strings.Settings.Memory.empty(lang),
                subtitle: nil,
                buttonTitle: nil,
                palette: palette,
                action: nil
            )
        }
    }

    private func failureState(_ failure: LText) -> some View {
        VStack(spacing: 12) {
            SettingsNoticeBanner(text: failure(lang), kind: .error, palette: palette)
            SettingsSubmitButton(
                title: Strings.Common.retry(lang),
                symbol: "arrow.clockwise",
                palette: palette,
                prominent: false,
                isWorking: env.memory.isLoading,
                action: { Task { await env.memory.load() } }
            )
        }
        .padding(14)
    }

    // MARK: - Guest

    private var guestPanel: some View {
        SettingsPanel(
            title: Strings.Settings.Memory.title(lang),
            palette: palette,
            lang: lang
        ) {
            EmptyStateView(
                title: Strings.Settings.Memory.guestTitle(lang),
                subtitle: Strings.Settings.Memory.guestBody(lang),
                buttonTitle: Strings.Settings.Account.guestCTA(lang),
                palette: palette,
                action: { env.router.showSignUp(feature: .memory) }
            )
        }
    }

    // MARK: - Actions

    private func loadIfMember() async {
        guard env.session.isMember, !env.memory.hasLoaded else { return }
        await env.memory.load()
    }

    private func delete(id: String?) {
        Haptics.select()
        Task { await env.memory.delete(id: id) }
    }

    // MARK: - Plumbing

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }
}
