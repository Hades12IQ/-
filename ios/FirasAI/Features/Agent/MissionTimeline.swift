import SwiftUI

/// The mission's activity feed: the structured `surface.events`, the unique source URLs they
/// visited, and the raw `surface.live` narration behind a disclosure.
///
/// Rows are keyed by `event.id` — the server already de-duplicates by id — so only genuinely new
/// rows animate in (`server-agent.md §6.2`, `web-agent-ux.md §8`).
struct MissionTimeline: View {

    private let job: AgentJob
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let motionOn: Bool

    @State private var eventsExpanded = true
    @State private var sourcesExpanded = false
    @State private var logExpanded = false

    init(job: AgentJob, palette: FirasPalette, lang: AppLanguage, motionOn: Bool) {
        self.job = job
        self.palette = palette
        self.lang = lang
        self.motionOn = motionOn
    }

    private var events: [AgentEvent] {
        let all = job.surface?.events ?? []
        let planned = job.steps.indices
        let global = all.filter { !planned.contains($0.step) }
        let rows = job.steps.isEmpty ? all : global
        return Array(rows.suffix(100))
    }

    private var sources: [MissionSource] {
        var seen: Set<String> = []
        var out: [MissionSource] = []
        for event in (job.surface?.events ?? []).reversed() where event.url.hasPrefix("http") {
            guard !MissionTimeline.isBlockedHost(event.url), seen.insert(event.url).inserted else { continue }
            out.append(MissionSource(url: event.url, label: event.text.isEmpty ? event.arg : event.text))
            if out.count >= 12 { break }
        }
        return out
    }

    private var liveLines: [String] {
        Array((job.surface?.live ?? []).suffix(40))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            eventsGroup
            sourcesGroup
            logGroup
        }
    }

    // MARK: - Events

    @ViewBuilder
    private var eventsGroup: some View {
        if events.isEmpty {
            if job.phase == .run || job.phase == .queued {
                Text(Strings.Agent.noActivity(lang))
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            DisclosureGroup(isExpanded: $eventsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(events) { event in
                        MissionEventRow(
                            event: event,
                            isLatest: event.id == events.last?.id,
                            missionIsLive: job.phase == .run || job.phase == .queued,
                            palette: palette,
                            lang: lang
                        )
                        .transition(FirasMotion.revealTransition)
                    }
                }
                .padding(.top, 8)
                .animation(FirasMotion.gated(FirasMotion.reveal, motionOn: motionOn), value: events.count)
            } label: {
                groupLabel(Strings.Agent.executionLog(lang), count: events.count)
            }
            .tint(palette.accent)
        }
    }

    // MARK: - Sources

    @ViewBuilder
    private var sourcesGroup: some View {
        if !sources.isEmpty {
            DisclosureGroup(isExpanded: $sourcesExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sources) { source in
                        if let url = URL(string: source.url) {
                            Link(destination: url) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(MissionTimeline.host(of: source.url))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(palette.accent)
                                        .forceLTR()
                                    if !source.label.isEmpty {
                                        Text(String(source.label.prefix(180)))
                                            .font(FirasType.caption)
                                            .foregroundStyle(palette.textMuted)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                groupLabel(Strings.Agent.sourcesGroup(lang), count: sources.count)
            }
            .tint(palette.accent)
        }
    }

    // MARK: - Raw log

    @ViewBuilder
    private var logGroup: some View {
        if !liveLines.isEmpty {
            DisclosureGroup(isExpanded: $logExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(liveLines.indices, id: \.self) { index in
                        Text(liveLines[index])
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 8)
            } label: {
                groupLabel(Strings.Agent.activityLog(lang), count: liveLines.count)
            }
            .tint(palette.accent)
        }
    }

    private func groupLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(FirasType.label)
                .foregroundStyle(palette.textPrimary)
            Text(ArabicText.count(count, lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
        }
    }

    // MARK: - URL helpers

    /// The provider is never named: an upstream host is dropped rather than shown
    /// (`server-agent.md §6.1`).
    static func isBlockedHost(_ raw: String) -> Bool {
        host(of: raw).lowercased().contains("manus")
    }

    static func host(of raw: String) -> String {
        guard let components = URLComponents(string: raw), let host = components.host else { return raw }
        return host
    }
}

/// One row of the sources group.
struct MissionSource: Identifiable, Equatable, Sendable {
    let url: String
    let label: String
    var id: String { url }
}

// MARK: - Event row

private struct MissionEventRow: View {

    let event: AgentEvent
    let isLatest: Bool
    let missionIsLive: Bool
    let palette: FirasPalette
    let lang: AppLanguage

    @State private var expanded = false

    private var kind: MissionEventKind { MissionEventKind.of(event) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .bidiIsland(for: detail, fallback: lang)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let url = sourceURL {
                    Link(destination: url) {
                        Text(Strings.Agent.openSource(lang) + " ↗")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.accent)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !hint.isEmpty {
                        Text(hint)
                            .font(FirasType.caption)
                            .foregroundStyle(palette.textMuted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                Text(statusWord)
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textMuted)
            }
        }
        .tint(palette.accent)
    }

    private var title: String {
        if event.kind == "message" && !event.text.isEmpty {
            return String(event.text.prefix(180))
        }
        return MissionEventKind.title(for: event, kind: kind, lang: lang)
    }

    private var hint: String {
        let raw = event.arg.isEmpty ? "" : event.arg
        return String(raw.prefix(120))
    }

    private var detail: String {
        let candidates = [event.arg, event.text, event.action]
        for candidate in candidates where !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(candidate.prefix(900))
        }
        return Strings.Agent.noDetail(lang)
    }

    private var isFailure: Bool {
        let status = event.status.lowercased()
        return status.contains("fail") || status.contains("error")
    }

    private var statusWord: String {
        if isFailure { return Strings.Agent.failedShort(lang) }
        if isLatest && missionIsLive { return Strings.Agent.running(lang) }
        return Strings.Agent.completed(lang)
    }

    private var statusColor: Color {
        if isFailure { return palette.error }
        if isLatest && missionIsLive { return palette.accent }
        return palette.textSecondary
    }

    private var sourceURL: URL? {
        guard event.url.hasPrefix("http"), !MissionTimeline.isBlockedHost(event.url) else { return nil }
        return URL(string: event.url)
    }
}

// MARK: - Event classification

/// `fcToolType` / `fcActivityTitle` ported: the icon and the human sentence for one event.
enum MissionEventKind: Sendable {
    case search
    case browser
    case read
    case click
    case file
    case generate
    case write
    case tool
    case say

    var symbol: String {
        switch self {
        case .search: return "magnifyingglass"
        case .browser: return "globe"
        case .read: return "doc.text"
        case .click: return "hand.tap"
        case .file: return "doc.badge.plus"
        case .generate: return "sparkles"
        case .write: return "square.and.pencil"
        case .tool: return "gearshape"
        case .say: return "quote.opening"
        }
    }

    var label: LText {
        switch self {
        case .search: return Strings.Agent.toolSearch
        case .browser: return Strings.Agent.toolBrowser
        case .read: return Strings.Agent.toolRead
        case .click: return Strings.Agent.toolClick
        case .file: return Strings.Agent.toolFile
        case .generate: return Strings.Agent.toolGenerate
        case .write: return Strings.Agent.toolWrite
        case .tool, .say: return Strings.Agent.toolGeneric
        }
    }

    static func of(_ event: AgentEvent) -> MissionEventKind {
        if event.kind == "message" { return .say }
        let haystack = ArabicText.normalize(
            [event.toolKind, event.name, event.action, event.text].joined(separator: " ")
        )
        if contains(haystack, ["search", "بحث", "يبحث"]) { return .search }
        if contains(haystack, ["browser", "browse", "navigate", "open_url", "تصفح", "يتصفح"]) { return .browser }
        if contains(haystack, ["read_page", "read", "قراءه", "قراءة", "يقرا"]) { return .read }
        if contains(haystack, ["click", "نقر", "ضغط"]) { return .click }
        if contains(haystack, ["image", "generate", "render", "صوره", "صورة", "انشاء"]) { return .generate }
        if contains(haystack, ["file", "attach", "ملف", "مرفق"]) { return .file }
        if contains(haystack, ["write", "edit", "كتابه", "كتابة", "يكتب"]) { return .write }
        return .tool
    }

    static func title(for event: AgentEvent, kind: MissionEventKind, lang: AppLanguage) -> String {
        switch kind {
        case .search:
            let haystack = ArabicText.normalize(event.name + " " + event.action + " " + event.arg)
            if contains(haystack, ["scholar", "academic", "arxiv", "pubmed", "اكاديم"]) {
                return Strings.Agent.actionAcademicSearch(lang)
            }
            return Strings.Agent.actionSearch(lang)
        case .browser:
            return Strings.Agent.actionBrowse(lang)
        case .read:
            return Strings.Agent.actionRead(lang)
        case .click:
            return Strings.Agent.actionOpen(lang)
        case .file:
            let name = event.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? Strings.Agent.actionFile(lang) : name
        case .generate:
            return Strings.Agent.imageCreated(lang)
        case .write:
            return Strings.Agent.actionWrite(lang)
        case .tool, .say:
            let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? Strings.Agent.actionFallback(lang) : String(text.prefix(180))
        }
    }

    private static func contains(_ haystack: String, _ needles: [String]) -> Bool {
        for needle in needles where haystack.contains(ArabicText.normalize(needle)) {
            return true
        }
        return false
    }
}
