import SwiftUI

/// The Manus daily ledger (`web-agent-ux.md §14`, `server-agent.md §10.1`).
///
/// `held` is **reserved for the running task**, never "spent": a running mission holds
/// `min(600, remaining)`, so `remaining` normally reads 0 while one runs. The sheet says so
/// explicitly instead of letting the reader think the allowance is gone.
struct CreditsSheet: View {

    private let env: AppEnvironment

    @State private var isRefreshing = false

    @Environment(\.dismiss) private var dismiss

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var credits: AgentCredits? { env.agent.credits }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(20)
                    .readingColumn(env.prefs.contentWidth)
            }
            .background(palette.background)
            .navigationTitle(Text(Strings.Agent.name(lang)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text(Strings.Common.close(lang))
                    }
                }
            }
        }
        .firasSheetBackground(palette)
        .presentationDetents([.medium, .large])
        .task { await refresh() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let credits {
            if credits.configured {
                ledger(credits)
            } else {
                EmptyStateView(
                    title: Strings.Errors.featureUnavailable(lang),
                    subtitle: nil,
                    buttonTitle: nil,
                    palette: palette,
                    action: nil
                )
            }
        } else if isRefreshing {
            VStack(spacing: 12) {
                ProgressView().tint(palette.accent)
                Text(Strings.Agent.creditsUpdating(lang))
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            EmptyStateView(
                title: Strings.Agent.creditsUnavailable(lang),
                subtitle: nil,
                buttonTitle: Strings.Common.retry(lang),
                palette: palette,
                action: { Task { await refresh() } }
            )
        }
    }

    private func ledger(_ credits: AgentCredits) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(credits)
            balance(credits)
            bar(credits)
            stats(credits)
            addButton
            note(credits)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ credits: AgentCredits) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.Agent.name(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .textCase(.uppercase)
            Text(credits.locked ? Strings.Agent.creditsTitleLocked(lang) : Strings.Agent.creditsTitle(lang))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
        }
    }

    private func balance(_ credits: AgentCredits) -> some View {
        let value = credits.locked ? credits.allowance : credits.remaining
        return VStack(alignment: .leading, spacing: 6) {
            Text(credits.locked ? Strings.Agent.creditsRemainingLocked(lang) : Strings.Agent.creditsRemaining(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ArabicText.count(Int(value.rounded()), lang))
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(
                    credits.locked
                        ? Strings.Agent.creditsDaily(lang)
                        : Strings.Agent.creditsOfAllowance.fmt(lang, ArabicText.count(Int(credits.allowance.rounded()), lang))
                )
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
            }
        }
    }

    private func bar(_ credits: AgentCredits) -> some View {
        let allowance = max(credits.allowance, 1)
        let fraction = min(max(credits.remaining / allowance, 0), 1)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(palette.surfaceSunken)
                Capsule(style: .continuous)
                    .fill(palette.accent)
                    .frame(width: max(4, proxy.size.width * fraction))
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel(Text(Strings.Agent.creditsBarLabel(lang)))
        .accessibilityValue(Text(ArabicText.count(Int(credits.remaining.rounded()), lang)))
    }

    private func stats(_ credits: AgentCredits) -> some View {
        VStack(spacing: 0) {
            statRow(
                Strings.Agent.creditsUsedToday(lang),
                value: ArabicText.count(Int(credits.used.rounded()), lang)
            )
            Divider().overlay(palette.border)
            statRow(
                Strings.Agent.creditsReservedLabel(lang),
                value: ArabicText.count(Int(credits.held.rounded()), lang)
            )
            Divider().overlay(palette.border)
            statRow(
                Strings.Agent.creditsNextRefresh(lang),
                value: CreditsSheet.refreshText(resetAt: credits.resetAt, lang: lang)
            )
        }
        .padding(.horizontal, 14)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.border, lineWidth: 1)
        }
    }

    private func statRow(_ title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.textPrimary)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var addButton: some View {
        Button {
            env.toasts.show(Strings.Agent.creditsAddSoon(lang))
        } label: {
            Text(Strings.Agent.creditsAdd(lang))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.onAccent)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background { Capsule(style: .continuous).fill(palette.accent) }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func note(_ credits: AgentCredits) -> some View {
        Text(credits.locked ? Strings.Agent.creditsNoteLocked(lang) : Strings.Agent.creditsNote(lang))
            .font(.system(size: 13))
            .foregroundStyle(palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Loading

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await env.agent.refreshCredits()
        isRefreshing = false
    }

    // MARK: - Reset time

    /// `resetAt` is the next Baghdad-local midnight as ISO-8601 UTC.
    static func refreshText(resetAt: String, lang: AppLanguage) -> String {
        guard let date = parseISO8601(resetAt) else {
            return Strings.Agent.creditsRefreshesDaily(lang)
        }
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return Strings.Agent.creditsRefreshesDaily(lang) }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return Strings.Agent.creditsRefreshesIn.fmt(
            lang,
            ArabicText.count(hours, lang),
            ArabicText.count(minutes, lang)
        )
    }

    static func parseISO8601(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}
