import Foundation

/// Pure mission helpers: the refusal card the enqueue path writes, the artifact file move, the
/// mission title and the Markdown export. Everything here is `nonisolated` and value-only, so it
/// can run off the main actor.
extension AgentStore {

    // MARK: - The "never started" card (`web-agent-ux.md §9.7`)

    nonisolated static func unavailableMission(
        task: String,
        title: String,
        cid: String,
        lang: AppLanguage
    ) -> AgentJob {
        let now = Date().timeIntervalSince1970 * 1000
        return AgentJob(
            id: cid,
            phase: .fail,
            presentation: .task,
            title: title,
            task: task,
            lang: lang.rawValue,
            steps: [AgentStep(title: Strings.Agent.startFailedStep(lang), s: .fail, kind: "write")],
            surface: AgentActivity(startedAt: now, endedAt: now),
            error: "task_unavailable"
        )
    }

    // MARK: - Artifact storage

    /// Moves the download out of `URLSession`'s temp slot into our own artifact folder. Runs off
    /// the main actor: a `nonisolated async` function never inherits the caller's executor.
    nonisolated static func persistArtifact(
        temporary: URL,
        jobID: String,
        index: Int,
        filename: String,
        download: Bool
    ) async -> URL? {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory
            .appendingPathComponent("FirasArtifacts", isDirectory: true)
            .appendingPathComponent(sanitizedPathComponent(jobID), isDirectory: true)
        let cleaned = sanitizedPathComponent(filename)
        let name = cleaned.isEmpty ? "artifact-" + String(index + 1) : cleaned
        let target = folder.appendingPathComponent((download ? "dl-" : "") + String(index) + "-" + name)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            if manager.fileExists(atPath: target.path) {
                try manager.removeItem(at: target)
            }
            try manager.moveItem(at: temporary, to: target)
            return target
        } catch {
            return nil
        }
    }

    nonisolated static func sanitizedPathComponent(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped == "." || stripped == ".." { return "_" }
        return String(stripped.prefix(120))
    }

    // MARK: - Title

    /// `agentTitleFrom`: the leading politeness / command verb is stripped, then 160 chars.
    nonisolated static func missionTitle(from task: String) -> String {
        let firstLine = task.components(separatedBy: "\n").first ?? task
        let base = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = base
        let leading = [
            "من فضلك", "لو سمحت", "please", "ابحث عن", "ابحث", "اكتب لي", "اكتب", "سوّي لي",
            "سوّي", "اعمل لي", "اعمل", "جهّز لي", "جهّز", "أريد", "اريد", "search for", "search",
            "write me", "write", "make me", "make", "build me", "build", "create"
        ]
        for prefix in leading where text.lowercased().hasPrefix(prefix.lowercased()) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if text.isEmpty { text = base }
        return text.count > 160 ? String(text.prefix(160)) : text
    }

    // MARK: - Markdown export (`web-agent-ux.md §7.7`)

    nonisolated static func markdown(for job: AgentJob, lang: AppLanguage) -> String {
        var out = ""
        let title = job.title.isEmpty ? Strings.Agent.mdUntitled(lang) : job.title
        out += "# " + title + "\n\n"
        out += "*" + metaLine(for: job, lang: lang) + "*\n\n"

        if !job.task.isEmpty {
            out += "## " + Strings.Agent.mdTaskHeading(lang) + "\n\n"
            for line in job.task.components(separatedBy: "\n") {
                out += "> " + line + "\n"
            }
            out += "\n"
        }

        if !job.steps.isEmpty {
            out += planSection(for: job, lang: lang)
            out += stepsSection(for: job, lang: lang)
        }

        if !job.final.isEmpty {
            out += "## " + Strings.Agent.mdResultHeading(lang) + "\n\n" + job.final + "\n\n"
        }

        let files = job.surface?.files ?? []
        if !files.isEmpty {
            out += "## " + Strings.Agent.mdFilesHeading(lang) + "\n\n"
            for file in files {
                out += "- " + (file.name.isEmpty ? file.url : file.name) + "\n"
            }
            out += "\n"
        }

        let sources = uniqueSourceURLs(in: job)
        if !sources.isEmpty {
            out += "## " + Strings.Agent.mdSourcesHeading(lang) + "\n\n"
            for url in sources { out += "- " + url + "\n" }
        }
        return out
    }

    nonisolated static func uniqueSourceURLs(in job: AgentJob) -> [String] {
        var seen: Set<String> = []
        var sources: [String] = []
        for event in job.surface?.events ?? [] where event.url.hasPrefix("http") {
            if seen.insert(event.url).inserted { sources.append(event.url) }
        }
        for tool in job.surface?.tools ?? [] where tool.url.hasPrefix("http") {
            if seen.insert(tool.url).inserted { sources.append(tool.url) }
        }
        return sources
    }

    nonisolated private static func metaLine(for job: AgentJob, lang: AppLanguage) -> String {
        let phaseLabel: LText
        switch job.phase {
        case .done: phaseLabel = Strings.Agent.phaseDone
        case .fail: phaseLabel = Strings.Agent.phaseFail
        case .queued: phaseLabel = Strings.Agent.phasePlan
        case .run: phaseLabel = Strings.Agent.phaseRun
        }
        let counts = Strings.Agent.mdStepsLabel(lang) + ": "
            + ArabicText.count(job.doneStepCount, lang) + "/" + ArabicText.count(job.steps.count, lang)
        let formatter = DateFormatter()
        formatter.locale = lang.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return Strings.Agent.mdExportedFrom(lang) + " · " + phaseLabel(lang) + " · " + counts
            + " · " + formatter.string(from: Date())
    }

    nonisolated private static func planSection(for job: AgentJob, lang: AppLanguage) -> String {
        var out = "## " + Strings.Agent.mdPlanHeading(lang) + "\n\n"
        for (index, step) in job.steps.enumerated() {
            let box = step.s == .done ? "[x]" : "[ ]"
            out += "- " + box + " " + String(index + 1) + ". " + step.title + "\n"
        }
        return out + "\n"
    }

    nonisolated private static func stepsSection(for job: AgentJob, lang: AppLanguage) -> String {
        var out = "## " + Strings.Agent.mdStepsHeading(lang) + "\n\n"
        for (index, step) in job.steps.enumerated() {
            out += "### " + Strings.Agent.mdStepHeading.fmt(lang, String(index + 1)) + " — " + step.title + "\n\n"
            switch step.s {
            case .todo: out += "*" + Strings.Agent.mdNotRun(lang) + "*\n\n"
            case .fail: out += "*" + Strings.Agent.mdStepFailed(lang) + "*\n\n"
            case .run, .done: break
            }
            let output = (step.out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            out += (output.isEmpty ? Strings.Agent.mdEmptyStep(lang) : output) + "\n\n"
        }
        return out
    }
}
