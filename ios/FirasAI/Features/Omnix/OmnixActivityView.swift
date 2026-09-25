import SwiftUI
import Perception

/// The gateway's ordered observations, never a plan inferred from the final answer.
struct OmnixActivity {
    var narration = ""
    var steps: [ExecutionStep] = []
    var body: String

    init(progress: OmnixProgress?, output: String, lang: AppLanguage) {
        body = output
        guard let progress else { return }
        var offsets: [String: Int] = [:]
        if progress.timelineVersion == 1, progress.droppedSpeech != true {
            for event in progress.events ?? [] {
                if event.kind == "speech" { narration += event.text ?? "" }
                else if event.kind == "tool" { offsets[event.id] = narration.utf16.count }
            }
        }
        for item in (progress.plan ?? []).filter({ $0.observed == true }) {
            let delegate = item.kind == "delegate" || item.title == "delegate_task"
            let outcome: String
            if item.s == "fail" || item.error == true { outcome = "failed" }
            else if item.s == "unknown" { outcome = "unknown" }
            else if item.s == "run" { outcome = "running" }
            else if delegate { outcome = item.delegationOutcome ?? (item.kind == "delegate" && item.s == "done" ? "completed" : "unknown") }
            else { outcome = item.s == "done" ? "completed" : "unknown" }
            let state = outcome == "running" ? "live" : outcome == "failed" ? "fail" : outcome == "completed" || outcome == "dispatched" ? "done" : "unknown"
            let ar = lang == .arabic
            var title = item.title
            if delegate {
                switch outcome {
                case "dispatched": title = ar ? "أطلق المهمة الفرعية" : "Launched the sub-task"
                case "running": title = ar ? "يفوّض مهمة فرعية" : "Delegating a sub-task"
                case "completed": title = ar ? "أنهى المهمة الفرعية" : "Finished the sub-task"
                case "failed": title = ar ? "فشلت المهمة الفرعية" : "The sub-task failed"
                default: title = ar ? "المهمة الفرعية · غير مؤكدة" : "Sub-task · unconfirmed"
                }
            }
            let details = [item.inputPreview, item.resultPreview].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            var fact: String?
            if let ms = item.durationMs, ms.isFinite, ms >= 0 {
                fact = String(format: "%.1f", ms / 1000) + (ar ? " ثانية" : " seconds")
            }
            if item.resultPreviewTruncated == true { fact = (fact.map { $0 + " · " } ?? "") + (ar ? "مقتطف من النتيجة" : "Result excerpt") }
            steps.append(ExecutionStep(id: item.id, kind: delegate ? "skill" : "run", state: state,
                text: title, fact: fact, detail: details, at: offsets[item.id] ?? 0))
        }
        // Strip only an exact prefix. A separate final summary must remain intact.
        if !narration.isEmpty, output.hasPrefix(narration) { body = String(output.dropFirst(narration.count)) }
    }
}

struct OmnixActivityView: View {
    let progress: OmnixProgress?
    let output: String
    let identity: String
    let streaming: Bool
    let prefs: PreferencesStore
    var body: some View {
        WithPerceptionTracking {
            let activity = OmnixActivity(progress: progress, output: output, lang: prefs.lang)
            VStack(alignment: .leading, spacing: 12) {
                ExecutionTimelineView(text: activity.narration, steps: activity.steps, identity: identity + "-activity",
                    streaming: streaming, lang: prefs.lang, prefs: prefs)
                if !activity.body.isEmpty {
                    MarkdownView(markdown: activity.body, messageID: identity + "-answer", streaming: streaming,
                        lang: prefs.lang, palette: prefs.palette, prefs: prefs, onFence: { _ in nil })
                }
            }
        }
    }
}
