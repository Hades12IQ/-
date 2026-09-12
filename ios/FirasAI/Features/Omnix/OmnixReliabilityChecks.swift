#if DEBUG
import Foundation
import UIKit

@MainActor
enum OmnixReliabilityChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        let key = String(repeating: "a", count: 32)
        let jobID = "omxj_" + String(repeating: "b", count: 32)
        let sessionID = "omxs_" + String(repeating: "c", count: 32)
        let pending = OmnixReceipt(owner: "owner-one", conversationId: "chat-one", requestKey: key)
        let job = OmnixJob(jobId: jobID, sessionId: sessionID, conversationId: "chat-one", requestKey: key, state: "completed")
        if !job.needsFullRefresh { failures.append("Omnix skipped the full result after discovering a completed receipt") }
        var hydrated = job
        hydrated.result = OmnixResult(output: "Complete answer", files: [], filesStatus: "ready")
        if hydrated.needsFullRefresh { failures.append("Omnix kept polling an already complete, inventoried result") }
        if !pending.isValid || !pending.accepts(job) { failures.append("Omnix rejected its own accepted receipt") }
        let foreign = OmnixJob(jobId: jobID, sessionId: sessionID, conversationId: "chat-two", requestKey: key, state: "completed")
        if pending.accepts(foreign) { failures.append("Omnix accepted a different conversation run") }
        let otherRequest = OmnixJob(jobId: jobID, sessionId: sessionID, conversationId: "chat-one", requestKey: String(repeating: "d", count: 32), state: "running")
        if pending.accepts(otherRequest) { failures.append("Omnix accepted a different request key") }
        let bound = OmnixReceipt(owner: pending.owner, conversationId: pending.conversationId, requestKey: key, jobId: jobID, sessionId: sessionID)
        let otherSession = OmnixJob(jobId: jobID, sessionId: "omxs_" + String(repeating: "e", count: 32), conversationId: "chat-one", requestKey: key, state: "running")
        if bound.accepts(otherSession) { failures.append("Omnix silently rolled a bound session") }
        let missingDefaults = Data(("{\"owner\":\"owner-one\",\"conversationId\":\"chat-one\",\"requestKey\":\"" + key + "\"}").utf8)
        do {
            let receipt = try JSONDecoder().decode(OmnixReceipt.self, from: missingDefaults)
            if receipt != pending { failures.append("Omnix pending receipt defaults changed across decoding") }
        } catch { failures.append("Omnix could not restore a pre-admission receipt without optional IDs") }
        let malformed = OmnixReceipt(owner: pending.owner, conversationId: "../chat-one", requestKey: key)
        if malformed.isValid { failures.append("Omnix accepted a path traversal in a conversation ID") }
        for terminal in ["completed", "failed", "cancelled", "canceled", "interrupted"] {
            let value = OmnixJob(jobId: jobID, sessionId: sessionID, conversationId: "chat-one", requestKey: key, state: terminal)
            if !value.isTerminal { failures.append("Omnix kept a terminal state running: " + terminal) }
        }
        let pendingJob = OmnixJob(jobId: jobID, sessionId: sessionID, conversationId: "chat-one", requestKey: key, state: "waiting_for_approval")
        if pendingJob.isTerminal { failures.append("Omnix treated approval as completion") }
        let fileID = String(repeating: "f", count: 64)
        let file = OmnixFile(id: fileID, name: "task.pdf", size: 100, url: "/api/omnix/files/" + fileID)
        let external = OmnixFile(id: fileID, name: "task.pdf", size: 100, url: "https://example.com/api/omnix/files/" + fileID)
        if file.downloadPath == nil || external.downloadPath != nil { failures.append("Omnix private download origin validation failed") }
        let query = OmnixFile(id: fileID, name: "task.pdf", size: 100, url: "/api/omnix/files/" + fileID + "?token=foreign")
        if query.downloadPath != nil { failures.append("Omnix accepted a query on its private download route") }
        let refusal = APIError.http(status: 409, server: ServerError(code: "cloud_state_changed"), raw: #"{"error":"cloud_state_changed","admitted":false}"#)
        if !OmnixService.definitelyNotAdmitted(refusal) || OmnixService.definitelyNotAdmitted(APIError.offline) {
            failures.append("Omnix confused a lost acknowledgement with a confirmed rejection")
        }
        do {
            let original = Data("Original Arabic source: المعادلة".utf8)
            let attachment = PreparedAttachment(name: "source.txt", kind: "text", text: "truncated summary", truncated: true,
                originalData: original, originalMime: "text/plain")
            let inputs = try OmnixService.inputs([attachment])
            if inputs.first?.bytes != original || inputs.first?.name != "source.txt" { failures.append("Omnix uploaded extracted text instead of the original file") }
            let extracted = PreparedAttachment(name: "old.pdf", kind: "pdf", text: "Exact extracted text")
            let old = try OmnixService.inputs([extracted])
            if old.first?.name != "old.pdf.txt" { failures.append("Omnix misrepresented extracted text as a PDF original") }
        } catch { failures.append("Omnix rejected valid original input data") }
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        if let png = pixel.pngData() {
            do {
                for sourceName in ["photo.png", "photo.heic"] {
                    let prepared = try await ChatAttachmentProcessor.image(data: png, name: sourceName)
                    let input = try OmnixService.inputs([prepared]).first
                    if prepared.name != sourceName || input?.name != "photo.jpg" || input?.mime != "image/jpeg"
                        || input?.bytes != prepared.originalData {
                        failures.append("Omnix uploaded a re-encoded photo under its original incompatible extension")
                    }
                }
                let prepared = PreparedAttachment(name: "original.jpeg", kind: "image", originalData: png, originalMime: "image/png")
                let input = try OmnixService.inputs([prepared]).first
                if input?.name != "original.png" || input?.mime != "image/png" || input?.bytes != png {
                    failures.append("Omnix changed original PNG bytes or kept an incompatible upload extension")
                }
            } catch { failures.append("Omnix rejected a valid prepared photo") }
            for attachment in [
                PreparedAttachment(name: "wrong.png", kind: "image", originalData: png, originalMime: "image/jpeg"),
                PreparedAttachment(name: "broken.png", kind: "image", imageBase64: Data("not an image".utf8).base64EncodedString()),
                PreparedAttachment(name: "unsupported.heic", kind: "image", originalData: Data("not an image".utf8), originalMime: "image/heic")
            ] {
                do {
                    _ = try OmnixService.inputs([attachment])
                    failures.append("Omnix accepted unsupported or mismatched image bytes")
                } catch { }
            }
        } else { failures.append("Omnix image fixture could not be created") }
        do {
            _ = try OmnixService.inputs([PreparedAttachment(name: "unsafe.pdf", kind: "pdf", text: "cut content", truncated: true)])
            failures.append("Omnix silently uploaded a truncated document")
        } catch { }
        let state = OmnixState()
        state.reset(owner: "owner-one"); state.jobs[key] = job; state.ready = true
        let generation = state.generation
        state.reset(owner: "owner-two")
        if state.generation == generation || !state.jobs.isEmpty || state.ready { failures.append("Omnix identity change retained another owner's live data") }
        do {
            let payload = OmnixSubmission(requestKey: key, text: "Continue the same task", product: "ai", conversationId: "chat-one", sessionId: sessionID, attachments: nil)
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
            if json?["sessionId"] as? String != sessionID || json?["model"] != nil || json?["reasoning_effort"] != nil {
                failures.append("Omnix native request replaced server model/effort/session policy")
            }
        } catch { failures.append("Omnix request encoding failed") }
        return failures
    }
}
#endif
