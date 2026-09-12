#if DEBUG
import Foundation

@MainActor
enum CodeOmnixImportChecks {
    static func run() async -> [String] {
        var errors: [String] = []
        func check(_ value: Bool, _ label: String) {
            if !value { errors.append("Code Omnix import: " + label) }
        }
        let a = String(repeating: "a", count: 64)
        let b = String(repeating: "b", count: 64)
        let receipt = OmnixReceipt(owner: "fixture", conversationId: "code_fixture",
            requestKey: "code_request_12345678", jobId: "omxj_" + String(repeating: "c", count: 32),
            sessionId: "omxs_" + String(repeating: "d", count: 32))
        let main = OmnixFile(id: a, name: "output/main.swift", size: 5, url: "/api/omnix/files/" + a, modifiedAt: 1_000)
        let readme = OmnixFile(id: b, name: "output/README.md", size: 4, url: "/api/omnix/files/" + b, modifiedAt: 1_000)
        let files = [main, readme]
        let source = CodeProject(name: "Native", files: [CodeFile(path: "main.swift", content: "old")])
        let job = OmnixJob(jobId: receipt.jobId, sessionId: receipt.sessionId,
            conversationId: receipt.conversationId, requestKey: receipt.requestKey, state: "completed",
            result: OmnixResult(output: "Ready", files: files, filesStatus: "ready"))
        do {
            let plan = try CodeOmnixImport.planFiles(job)
            check(plan.map(\.path) == ["main.swift", "README.md"], "common output folder was not removed")
            var inventory = files
            inventory[0].url = nil; inventory[1].url = nil
            check(CodeOmnixImport.manifestMatches(plan, inventory: inventory), "URL-free server inventory was rejected")
            inventory[0].modifiedAt = 1_001
            check(!CodeOmnixImport.manifestMatches(plan, inventory: inventory), "later overwrite with same size was accepted")
            check(!CodeOmnixImport.manifestMatches(plan, inventory: files + [main]), "duplicate inventory identity accepted")
            var calls: [String] = []
            let result = try await CodeOmnixImport.prepare(receipt: receipt, source: source,
                isCurrent: { true }, fetchJob: { calls.append("job"); return job },
                fetchInventory: { calls.append("manifest"); return files },
                fetchBytes: { file in calls.append(file.name); return Data((file.id == a ? "hello" : "read").utf8) })
            check(result.writes.map(\.path) == ["main.swift", "README.md"] && result.deletes.isEmpty,
                  "verified files did not produce review-only writes")
            check(calls == ["job", "manifest", "output/main.swift", "output/README.md", "manifest"],
                  "manifest checks did not surround the downloads")
            check(source.files[0].content == "old", "source was altered before review")
        } catch { errors.append("Code Omnix import: valid round trip failed") }

        var manifestCalls = 0
        do {
            _ = try await CodeOmnixImport.prepare(receipt: receipt, source: source, isCurrent: { true },
                fetchJob: { job }, fetchInventory: {
                    manifestCalls += 1
                    var inventory = files
                    if manifestCalls == 2 { inventory[0].modifiedAt = 2_000 }
                    return inventory
                }, fetchBytes: { Data(($0.id == a ? "hello" : "read").utf8) })
            errors.append("Code Omnix import: manifest change during download was accepted")
        } catch { check(error as? CodeOmnixImportError == .unavailable, "manifest change reported incorrectly") }

        var current = true
        var downloads = 0
        do {
            _ = try await CodeOmnixImport.prepare(receipt: receipt, source: source, isCurrent: { current },
                fetchJob: { job }, fetchInventory: { files }, fetchBytes: { _ in
                    downloads += 1; current = false; return Data("hello".utf8)
                })
            errors.append("Code Omnix import: owner/project change during download was accepted")
        } catch { check(error as? CodeOmnixImportError == .projectChanged && downloads == 1,
                        "stale owner did not stop the next download") }

        let duplicate = OmnixFile(id: b, name: "output/MAIN.swift", size: 1, url: "/api/omnix/files/" + b, modifiedAt: 1_000)
        var ambiguous = job
        ambiguous.result?.files = [main, duplicate]
        check((try? CodeOmnixImport.planFiles(ambiguous)) == nil, "case-insensitive duplicate output path accepted")
        var missingStamp = job
        missingStamp.result?.files?[0].modifiedAt = nil
        check((try? CodeOmnixImport.planFiles(missingStamp)) == nil, "unversioned file accepted for editor import")
        for name in ["../main.swift", "output/.secret.swift", "output/evil\\main.swift", "output/main\u{202e}.swift"] {
            var invalid = job
            invalid.result?.files = [OmnixFile(id: a, name: name, size: 1, url: "/api/omnix/files/" + a, modifiedAt: 1_000)]
            check((try? CodeOmnixImport.planFiles(invalid)) == nil, "unsafe path accepted")
        }
        check((try? CodeOmnixImport.text(Data([0xff, 0xfe]))) == nil, "invalid UTF-8 accepted")
        check((try? CodeOmnixImport.text(Data([65, 0, 66]))) == nil, "NUL bytes accepted as source")
        check((try? CodeOmnixImport.text(Data(String(repeating: "😀", count: 30_001).utf8))) == nil,
              "UTF-16 file limit counted graphemes")
        check((try? CodeOmnixImport.text(Data())) == "", "intentional empty file was lost")
        let oversized = CodeProject(name: "Unicode", files: [CodeFile(path: "main.swift", content: String(repeating: "😀", count: 30_001))])
        do { try CodeOmnixImport.validateProject(oversized); errors.append("Code Omnix import: over-capacity project accepted") }
        catch { }
        return errors
    }
}
#endif
