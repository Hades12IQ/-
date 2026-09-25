import SwiftUI
import Perception

struct ExecutionStepRow: View {
    let step: ExecutionStep
    let lang: AppLanguage
    let palette: FirasPalette
    let streaming: Bool
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: step.symbol).frame(width: 22).foregroundStyle(palette.accent)
                    Text(step.title(lang)).font(.subheadline).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if step.state == "live" && streaming { ProgressView().scaleEffect(0.7) }
                    else if step.state == "fail" { Image(systemName: "exclamationmark.circle").foregroundStyle(palette.error) }
                    else if step.state == "unknown" { Text(lang == .arabic ? "غير مؤكد" : "Unconfirmed").font(.caption) }
                    else if step.state == "done" { Image(systemName: "checkmark").font(.caption) }
                    if let detail = step.detail, !detail.isEmpty { Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2) }
                }.frame(minHeight: 36).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let fact = step.fact, !fact.isEmpty { Text(fact).font(.caption).foregroundStyle(palette.textMuted) }
            if expanded, let detail = step.detail, !detail.isEmpty {
                Text(detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .foregroundStyle(palette.textSecondary).padding(.leading, 32)
            }
        }.foregroundStyle(palette.textSecondary)
    }
}

/// Server offsets use UTF-16, as JavaScript strings do. Slice only on scalar boundaries.
struct ExecutionTimelineView: View {
    let text: String
    let steps: [ExecutionStep]
    let identity: String
    let streaming: Bool
    let lang: AppLanguage
    let prefs: PreferencesStore

    private struct Part: Identifiable {
        let id: String
        var text: String = ""
        var step: ExecutionStep?
    }
    private var parts: [Part] {
        var out: [Part] = [], cursor = text.startIndex
        for step in steps {
            let offset = min(max(step.at ?? 0, 0), text.utf16.count)
            var mark = String.Index(utf16Offset: offset, in: text)
            if mark.samePosition(in: text.unicodeScalars) == nil { mark = cursor }
            if mark < cursor { mark = cursor }
            if mark > cursor { out.append(Part(id: "before-" + step.id, text: String(text[cursor..<mark]))) }
            out.append(Part(id: "step-" + step.id, step: step)); cursor = mark
        }
        if cursor < text.endIndex { out.append(Part(id: "tail", text: String(text[cursor...]))) }
        return out
    }
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(parts) { part in
                    if let step = part.step {
                        ExecutionStepRow(step: step, lang: lang, palette: prefs.palette, streaming: streaming)
                    } else if !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownView(markdown: part.text, messageID: identity + "-" + part.id,
                            streaming: streaming, lang: lang, palette: prefs.palette, prefs: prefs, onFence: { _ in nil })
                    }
                }
            }
        }
    }
}
