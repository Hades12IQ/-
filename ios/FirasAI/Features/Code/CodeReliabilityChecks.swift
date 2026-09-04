#if DEBUG
import Foundation

/// Runs actual request builders, parsers and protected cache code in the simulator.
/// It never contacts an API or charges an account.
@MainActor
enum CodeReliabilityChecks {
    static func failures() async -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) {
            if !condition { failures.append("Code: " + label) }
        }
        let owner = "code-smoke-" + UUID().uuidString
        let projectID = "ios_code_smoke_" + UUID().uuidString
        var ticket = CodeBuildTicket(projectID: projectID, cid: "smoke", ownerID: owner,
                                     name: "Example", brief: "Build a native SwiftUI iPhone app",
                                     attach: "", lang: "en", startedAt: Date().timeIntervalSince1970,
                                     plannedPaths: ["main.swift", "README.md"])
        let swift = CodeFile(path: "main.swift", content: "import SwiftUI\nstruct ContentView: View { var body: some View { Text(\"Hello\") } }\n")
        let readme = CodeFile(path: "README.md", content: "Open the project in Xcode.\n")
        let whole = CodeProject(name: "Example", files: [swift, readme])
        let request = CodeBuildHandoff.request(ticket: ticket, checkpoint: nil)
        check(request.kind == JobKind.chat.rawValue, "native builds must use generic durable worker")
        check(CodeBuildHandoff.pointerKind == .codebuild, "durable native result must reach Code observer")
        check(request.nomem == true && request.nokb == true, "code helper excludes personal memory and KB")
        check(request.chatId.isEmpty, "raw project output must not be appended to chat by worker")
        check(CodeBuildHandoff.isComplete(whole, ticket: ticket), "valid complete native plan rejected")
        check(!CodeBuildHandoff.isComplete(CodeProject(name: "Example", files: [swift]), ticket: ticket), "missing planned file accepted")
        check(!CodeBuildHandoff.isComplete(CodeProject(name: "Example", files: [swift, CodeFile(path: "README.md", content: "")]), ticket: ticket), "empty planned file accepted")
        check(!CodeBuildHandoff.isComplete(CodeProject(name: "Example", files: [CodeFile(path: "../secret.swift", content: "x")]), ticket: nil), "unsafe file path accepted")
        check((try? CodeProject.decode(fromJobText: whole.encodedFence())) == whole, "project fence round trip failed")
        check((try? CodeProject.decode(fromJobText: "```firas-project\n{\"files\":[")) == nil, "unfinished fence accepted")
        check((try? CodeProject.decode(fromJobText: "```firas-project\n{\"files\":[\n```")) == nil, "unfinished JSON accepted")

        ticket.completedPaths = [swift.path]
        let checkpoint = CodeProject(name: "Example", files: [swift])
        let altered = CodeProject(name: "Example", files: [CodeFile(path: swift.path, content: "truncated"), readme])
        let merged = CodeBuildHandoff.mergingCompletedFiles(altered, checkpoint: checkpoint, ticket: ticket)
        check(merged.files.first(where: { $0.path == swift.path }) == swift, "background answer overwrote completed source")
        var python = ticket
        python.brief = "Build a Python CLI that writes an HTML and PDF report"
        python.plannedPaths = []
        check(CodeSpec.detect(python.brief).lang == "python", "output format overrode Python runtime")
        check(CodeBuildHandoff.request(ticket: python, checkpoint: nil).kind == JobKind.chat.rawValue, "Python handoff became a website")
        check(CodeAskAI.route(python.brief, lang: .english) == .edit, "PDF generator source was redirected to Chat")
        var website = ticket
        website.brief = "Build a simple website"
        check(CodeBuildHandoff.request(ticket: website, checkpoint: nil).kind == JobKind.codebuild.rawValue, "small browser project lost specialized worker")
        website.brief += String(repeating: " detailed requirement", count: 500)
        check(CodeBuildHandoff.request(ticket: website, checkpoint: nil).kind == JobKind.chat.rawValue, "long requirements silently hit specialized task cap")

        for path in [".env", "config/.env.production", ".ssh/config", ".aws/credentials", "firebase-service-account.json", "signing.p12"] {
            check(CodeEngineeringGuidance.isSensitivePath(path), "sensitive path allowed: " + path)
        }
        check(!CodeEngineeringGuidance.isSensitivePath(".env.example"), "safe env template excluded")
        check(CodeEngineeringGuidance.containsPrivateKey("-----BEGIN PRIVATE KEY-----"), "private key content not recognized")
        for title in [".", "..", "../", " .. "] {
            check(CodeExport.folderName(title) == "project", "export title escaped temporary folder: " + title)
        }

        let oversized = CodeProject(name: "Large", files: [CodeFile(path: "main.swift", content: String(repeating: "a", count: 60_001) + "END")])
        if case .success = oversized.validatedForSave() { failures.append("Code: oversized source passed cloud validation") }
        let cache = CodeProjectCache(disk: DiskStore.shared)
        check(await cache.save(oversized, id: projectID, ownerID: owner), "complete source could not be cached")
        let sameOwner = await cache.load(id: projectID, ownerID: owner)
        let otherOwner = await cache.load(id: projectID, ownerID: owner + "-other")
        check(sameOwner == oversized, "cache truncated oversized source")
        check(otherOwner == nil, "project cache leaked between identities")
        let otherRecords = await cache.records(ownerID: owner + "-other")
        check(!otherRecords.contains(where: { $0.id == projectID }), "project index leaked between identities")
        let conversation = CodeChatThread(messages: [CodeChatMessage(role: "user", content: "private source question")])
        await cache.saveThread(conversation, id: projectID, ownerID: owner)
        let otherThread = await cache.loadThread(id: projectID, ownerID: owner + "-other")
        check(otherThread == nil, "Code conversation leaked between identities")
        await cache.delete(id: projectID, ownerID: owner)
        return failures
    }
}
#endif
