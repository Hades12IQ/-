import SwiftUI

/// Batch 0 stub: brand mark, restore state, offline banner, nothing else.
///
/// Batch 2 replaces this with the real phase switch (`MentronXEntryView` → `ConsentView` /
/// `LandingView` / `AuthView` / `AppShell`) and the frozen `init(env: AppEnvironment)`. The stub
/// takes the three Batch 0 stores directly because `AppEnvironment` does not exist yet.
struct RootView: View {
    private let prefs: PreferencesStore
    private let session: SessionStore
    private let network: NetworkMonitor

    init(prefs: PreferencesStore, session: SessionStore, network: NetworkMonitor) {
        self.prefs = prefs
        self.session = session
        self.network = network
    }

    var body: some View {
        ZStack(alignment: .top) {
            FirasBackground(palette: prefs.palette, showHalo: true)
                .ignoresSafeArea()

            centreColumn

            if !network.isOnline {
                offlineBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .environment(prefs)
        .environment(session)
        .environment(network)
        .environment(\.layoutDirection, .leftToRight)
        .preferredColorScheme(prefs.theme.isLight ? .light : .dark)
        .task {
            await boot()
        }
    }

    // MARK: - Pieces

    private var centreColumn: some View {
        VStack(spacing: 24) {
            FirasBrandMark(size: 76, showsWordmark: true)
            statusView
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusView: some View {
        switch session.phase {
        case .booting:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(prefs.palette.accent)
                .accessibilityHidden(true)
        case .unreachable:
            unreachableCard
        case .member(let user), .guest(let user):
            Text(verbatim: user.firstName)
                .font(FirasType.label)
                .foregroundStyle(prefs.palette.textSecondary)
                .bidiIsland(for: user.firstName, fallback: prefs.lang)
        case .signedOut, .awaitingVerification:
            Color.clear.frame(height: 1)
        }
    }

    private var unreachableCard: some View {
        let message = Strings.Errors.offline(prefs.lang)
        let retry = Strings.Common.retry(prefs.lang)
        return VStack(spacing: 14) {
            Text(message)
                .font(FirasType.label)
                .foregroundStyle(prefs.palette.textSecondary)
                .multilineTextAlignment(.center)
                .bidiIsland(for: message, fallback: prefs.lang)

            Button {
                Task { await session.restore() }
            } label: {
                Text(retry)
                    .font(FirasType.label)
                    .foregroundStyle(prefs.palette.onAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(prefs.palette.accent))
            }
            .buttonStyle(.plain)
            .disabled(session.isRestoring)
            .opacity(session.isRestoring ? 0.5 : 1)
            .accessibilityLabel(retry)
        }
        .frame(maxWidth: 360)
    }

    private var offlineBanner: some View {
        let message = Strings.Errors.offline(prefs.lang)
        return HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(prefs.palette.textMuted)
                .accessibilityHidden(true)
            Text(message)
                .font(FirasType.label)
                .foregroundStyle(prefs.palette.textPrimary)
                .lineLimit(2)
                .bidiIsland(for: message, fallback: prefs.lang)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(prefs.palette.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(prefs.palette.border, lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Boot

    @MainActor
    private func boot() async {
        network.start()
        await session.restore()
    }
}
