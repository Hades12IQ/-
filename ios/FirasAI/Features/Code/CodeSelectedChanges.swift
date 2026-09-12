import Foundation

@MainActor
enum CodeSelectedChanges {
    static func project(source: CodeProject, plan: CodeEditPlan, selected: Set<String>) throws -> CodeProject {
        var files = source.files.filter { !plan.deletes.contains($0.path) || !selected.contains($0.path) }
        for rename in plan.renames where selected.contains(rename.from) || selected.contains(rename.to) {
            guard let index = files.firstIndex(where: { $0.path == rename.from }) else { throw CodeEditService.Failure.invalidProposal }
            files[index] = CodeFile(path: rename.to, content: files[index].content)
        }
        for write in plan.writes where selected.contains(write.path) {
            if let index = files.firstIndex(where: { $0.path == write.path }) {
                files[index] = CodeFile(path: write.path, content: write.content)
            } else { files.append(CodeFile(path: write.path, content: write.content)) }
        }
        let candidate = CodeProject(name: source.name, files: files)
        try CodeOmnixImport.validateProject(candidate)
        return candidate
    }
}

#if DEBUG
@MainActor
enum CodeSelectedChangesChecks {
    static func run() -> [String] {
        var errors: [String] = []
        let source = CodeProject(name: "Full project", files: (0..<30).map { CodeFile(path: "file\($0).swift", content: "let value = \($0)") })
        let plan = CodeEditPlan(writes: [CodeFileBlock(path: "new.swift", content: "let newValue = 1")], deletes: ["file0.swift"])
        if let changed = try? CodeSelectedChanges.project(source: source, plan: plan, selected: ["file0.swift", "new.swift"]) {
            if changed.files.count != 30 || !changed.files.contains(where: { $0.path == "new.swift" }) || changed.files.contains(where: { $0.path == "file0.swift" }) {
                errors.append("Code selected changes dropped an addition at the project file limit")
            }
        } else { errors.append("Code selected changes rejected a valid deletion plus addition") }
        if (try? CodeSelectedChanges.project(source: source, plan: plan, selected: ["new.swift"])) != nil {
            errors.append("Code selected changes accepted an over-capacity checkbox subset")
        }
        let invalid = CodeEditPlan(writes: [CodeFileBlock(path: "../escape.swift", content: "escape")])
        if (try? CodeSelectedChanges.project(source: source, plan: invalid, selected: ["../escape.swift"])) != nil {
            errors.append("Code selected changes accepted an invalid selected path")
        }
        if source.files.count != 30 || source.files.first?.path != "file0.swift" {
            errors.append("Rejected Code selection mutated the original source")
        }
        return errors
    }
}
#endif
