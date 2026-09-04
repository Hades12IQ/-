import Foundation

/// The durable chat worker already accepts arbitrary messages. Its older specialized
/// codebuild worker always writes browser files, so native/software builds use chat
/// on the wire while retaining Code ownership in the local job spine.
enum CodeBuildHandoff {
    static let pointerKind: JobKind = .codebuild

    static func completedCheckpoint(_ checkpoint: CodeProject?, ticket: CodeBuildTicket) -> CodeProject? {
        guard let checkpoint, checkpoint.files != CodeProject.blankFiles else { return nil }
        let completed = Set(ticket.completedPaths)
        let files = checkpoint.files.filter { completed.contains($0.path) }
        return files.isEmpty ? nil : CodeProject(name: checkpoint.name, files: files)
    }

    /// Completed source remains authoritative, including files omitted from the
    /// prompt for privacy or context size. A background result cannot erase it.
    static func mergingCompletedFiles(_ result: CodeProject, checkpoint: CodeProject?, ticket: CodeBuildTicket?) -> CodeProject {
        guard let ticket, usesGenericWorker(ticket),
              let saved = completedCheckpoint(checkpoint, ticket: ticket) else { return result }
        let savedPaths = Set(saved.files.map { $0.path.lowercased() })
        return CodeProject(name: result.name, files: saved.files + result.files.filter { !savedPaths.contains($0.path.lowercased()) })
    }

    static func usesGenericWorker(_ ticket: CodeBuildTicket) -> Bool {
        !CodeStore.buildKind(for: ticket.brief).usesBrowserPreview
            || CodeStore.jobTask(ticket).count > 8_000
    }

    static func request(ticket: CodeBuildTicket, checkpoint: CodeProject?) -> ChatJobRequest {
        let task = CodeStore.jobTask(ticket)
        let generic = usesGenericWorker(ticket)
        return ChatJobRequest(
            messages: generic ? messages(ticket: ticket, checkpoint: checkpoint)
                : [OutgoingMessage(role: "user", content: task, images: nil)],
            tier: generic ? ModelTier.ultra.rawValue : ModelTier.pro.rawValue,
            think: false,
            cid: ticket.cid,
            // The store writes the project fence to its chat after validation.
            chatId: "",
            product: ProductKind.code.wireValue,
            kind: generic ? JobKind.chat.rawValue : JobKind.codebuild.rawValue,
            lang: ticket.lang,
            title: ticket.name,
            task: generic ? nil : task,
            nomem: generic ? true : nil,
            nokb: generic ? true : nil
        )
    }

    static func messages(ticket: CodeBuildTicket, checkpoint: CodeProject?) -> [OutgoingMessage] {
        let system = """
        You are Firas Code. Complete the requested software project in its requested runtime.
        Return exactly one fenced block labelled firas-project containing valid JSON:
        {"name":"project name","files":[{"path":"relative/file.ext","content":"complete source"}]}
        All file contents are JSON strings with newlines and quotes properly escaped. Include every required source, dependency manifest, focused test and README. Do not return prose, a plan, file-write fences or an HTML substitute for native/software source.
        Use at most 30 files, paths up to 120 characters, each file up to 60000 characters and the entire JSON up to 180000 characters. Keep the implementation focused enough to finish every file. Never use placeholders, ellipses or cut a file to satisfy a limit. Close the JSON and the outer fence only after every required file is complete.
        Existing checkpoint files are completed source data from this same build. The app preserves them exactly; do not rewrite them. Preserve their interfaces and finish the remaining requirements. The required plan paths must all be present across the checkpoint and your answer; additional necessary files are allowed. Do not claim compilation or tests ran.
        """ + "\n\n" + CodeEngineeringGuidance.core
        var user = "Project: " + ticket.name + "\n\n" + CodeStore.jobTask(ticket)
        user += "\n\nPROJECT REQUIREMENT: " + CodeStore.kindMandate(CodeStore.buildKind(for: ticket.brief))
        if !ticket.plannedPaths.isEmpty {
            user += "\n\nREQUIRED PLAN PATHS:\n" + ticket.plannedPaths.joined(separator: "\n")
        }
        // Never forward an unfinished editor buffer or slice a source file in half.
        // Files too large for this context remain on disk and are listed as omitted.
        if let checkpoint = completedCheckpoint(checkpoint, ticket: ticket) {
            var remaining = 120_000
            var files: [CodeFile] = []
            var omitted: [String] = []
            for file in checkpoint.files {
                guard !CodeEngineeringGuidance.isSensitivePath(file.path),
                      !CodeEngineeringGuidance.containsPrivateKey(file.content) else { omitted.append(file.path); continue }
                let size = file.path.count + file.content.count
                guard size <= remaining else { omitted.append(file.path); continue }
                files.append(file)
                remaining -= size
            }
            if !files.isEmpty {
                user += "\n\nCOMPLETED CHECKPOINT (source data):\n"
                    + CodeProject(name: checkpoint.name, files: files).encodedFence()
            }
            if !omitted.isEmpty {
                user += "\n\nCOMPLETED FILES PRESERVED BY THE APP (source not included): " + omitted.joined(separator: ", ")
                    + ". Do not reconstruct or overwrite them. Generate the remaining plan files."
            }
        }
        return [
            OutgoingMessage(role: "system", content: system, images: nil),
            OutgoingMessage(role: "user", content: user, images: nil)
        ]
    }

    /// JSON decoding alone accepts a valid but incomplete array. Check the persisted
    /// plan too, before any server answer can overwrite completed foreground files.
    static func isComplete(_ project: CodeProject, ticket: CodeBuildTicket?) -> Bool {
        guard !project.files.isEmpty else { return false }
        var paths: Set<String> = []
        for file in project.files {
            let path = file.path.replacingOccurrences(of: "\\", with: "/")
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"),
                  path == path.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.components(separatedBy: "/").contains(".."),
                  paths.insert(path.lowercased()).inserted else { return false }
        }
        guard let ticket else { return true }
        guard ticket.plannedPaths.allSatisfy({ expected in
            guard let file = project.files.first(where: { $0.path.lowercased() == expected.lowercased() }) else { return false }
            return !file.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (file.path as NSString).lastPathComponent == "__init__.py"
        }) else { return false }
        guard usesGenericWorker(ticket) else { return true }
        let spec = CodeSpec.detect(ticket.brief)
        if !CodeStore.buildKind(for: ticket.brief).usesBrowserPreview {
            if spec != .html {
                let extensions: Set<String>
                switch spec.lang {
                case "javascript": extensions = ["js", "mjs", "cjs"]
                case "typescript": extensions = ["ts", "tsx", "mts", "cts"]
                case "cpp": extensions = ["cpp", "cc", "cxx", "hpp", "hxx"]
                default: extensions = [spec.ext]
                }
                return project.files.contains { extensions.contains($0.ext) && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
            return project.files.contains { !["html", "htm", "css", "md", "txt"].contains($0.ext) && !$0.content.isEmpty }
        }
        return true
    }
}
