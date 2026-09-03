import Foundation
import SwiftUI

/// The console pane: level chips with counts, a text filter, a clock toggle, clear, and the
/// "fix it with AI" hand-off that carries the runtime errors into the AI bar
/// (`web-code-ux.md §5.5`, `design-brief.md §7.9`).
///
/// Filtering hides rows, it never removes them — the buffer stays whole so the fix prompt always
/// has the real errors.
struct ConsoleView: View {

    enum Level: String, CaseIterable, Identifiable, Sendable {
        case all, error, warn, log

        var id: String { rawValue }

        var title: LText {
            switch self {
            case .all: return Strings.CodeUI.consoleAll
            case .error: return Strings.CodeUI.consoleErrors
            case .warn: return Strings.CodeUI.consoleWarnings
            case .log: return Strings.CodeUI.consoleLogs
            }
        }
    }

    /// The number of error lines the fix prompt carries, matching `cwState.liveErrors`.
    private static let fixErrorBudget = 30

    private let env: AppEnvironment
    private let onFix: ((String) -> Void)?
    private let onRun: (() -> Void)?

    @State private var level: Level = .all
    @State private var filter: String = ""
    @State private var showsClock = false

    init(env: AppEnvironment, onFix: ((String) -> Void)? = nil, onRun: (() -> Void)? = nil) {
        self.env = env
        self.onFix = onFix
        self.onRun = onRun
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var lines: [ConsoleLine] { env.code.consoleLines }

    private var errorLines: [ConsoleLine] { lines.filter { $0.level == "error" } }
    private var warningCount: Int { lines.filter { $0.level == "warn" }.count }
    private var logCount: Int { lines.filter { $0.level != "error" && $0.level != "warn" }.count }

    private var visible: [ConsoleLine] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lines.filter { line in
            guard matchesLevel(line) else { return false }
            guard !needle.isEmpty else { return true }
            return line.text.lowercased().contains(needle)
        }
    }

    private func matchesLevel(_ line: ConsoleLine) -> Bool {
        switch level {
        case .all: return true
        case .error: return line.level == "error"
        case .warn: return line.level == "warn"
        case .log: return line.level != "error" && line.level != "warn"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            filterField
            rowList(for: visible)
            fixBar
        }
        .background(palette.surfaceSunken)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(.all, count: lines.count)
                chip(.error, count: errorLines.count)
                chip(.warn, count: warningCount)
                chip(.log, count: logCount)

                Divider().frame(height: 20)

                FirasIconButton(
                    symbol: showsClock ? "clock.fill" : "clock",
                    label: Strings.CodeUI.consoleClock(lang),
                    palette: palette
                ) {
                    Haptics.select()
                    showsClock.toggle()
                }

                FirasIconButton(
                    symbol: "trash",
                    label: Strings.CodeUI.consoleClear(lang),
                    palette: palette
                ) {
                    Haptics.select()
                    env.code.consoleLines = []
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 0.5)
        }
    }

    private func chip(_ kind: Level, count: Int) -> some View {
        FirasPill(
            text: kind.title(lang) + " " + ArabicText.count(count, lang),
            symbol: nil,
            selected: level == kind,
            palette: palette
        ) {
            Haptics.select()
            level = kind
        }
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12))
                .foregroundStyle(palette.textMuted)
                .accessibilityHidden(true)

            TextField(
                text: $filter,
                prompt: Text(verbatim: Strings.CodeUI.consoleFilter(lang))
            ) {
                Text(verbatim: Strings.CodeUI.consoleFilter(lang))
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(palette.textPrimary)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .submitLabel(.done)

            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: Strings.Common.close(lang)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 0.5)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowList(for rows: [ConsoleLine]) -> some View {
        if lines.isEmpty {
            EmptyStateView(
                title: Strings.CodeUI.consoleEmptyTitle(lang),
                subtitle: Strings.CodeUI.consoleEmptyBody(lang),
                buttonTitle: onRun == nil ? nil : Strings.CodeUI.consoleRunProject(lang),
                palette: palette,
                action: onRun
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            EmptyStateView(
                title: Strings.CodeUI.consoleNoMatch(lang),
                subtitle: nil,
                buttonTitle: nil,
                palette: palette,
                action: nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { line in
                        row(line)
                    }
                }
                .padding(.vertical, 6)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ line: ConsoleLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(color(for: line.level))
                .frame(width: 2, height: 15)
                .accessibilityHidden(true)

            if showsClock {
                Text(verbatim: Self.clockText(line.at))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.textMuted)
                    .forceLTR()
            }

            Text(verbatim: line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color(for: line.level))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: line.text, fallback: lang)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for level: String) -> Color {
        switch level {
        case "error": return palette.error
        case "warn": return palette.codeWarn
        case "info", "run": return palette.planDiamond
        case "ok": return palette.codeOk
        default: return palette.textSecondary
        }
    }

    private static func clockText(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(
            format: "%02ld:%02ld:%02ld",
            locale: nil,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    // MARK: - Fix with AI

    @ViewBuilder
    private var fixBar: some View {
        if let onFix, !errorLines.isEmpty {
            Button {
                Haptics.select()
                onFix(errorDigest())
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: Strings.CodeUI.consoleFix(lang))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(palette.onAccent)
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
                .background { Capsule(style: .continuous).fill(palette.accent) }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(palette.surface)
            .overlay(alignment: .top) {
                Rectangle().fill(palette.border).frame(height: 0.5)
            }
        }
    }

    /// The error buffer, deduplicated and newest-last like the web's `liveErrors`. The caller adds
    /// its own instruction line in front of it (`cwDeckFixAsk`).
    func errorDigest() -> String {
        var seen: Set<String> = []
        var kept: [String] = []
        for line in errorLines.suffix(120) {
            let text = String(line.text.prefix(600))
            if seen.contains(text) { continue }
            seen.insert(text)
            kept.append(text)
        }
        return kept.suffix(Self.fixErrorBudget).map { "• " + $0 }.joined(separator: "\n")
    }
}
