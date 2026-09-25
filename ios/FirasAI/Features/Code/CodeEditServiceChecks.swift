#if DEBUG
import Foundation

@MainActor
enum CodeEditServiceChecks {
    static func run() async -> [String] {
        var errors: [String] = []
        func check(_ value: Bool, _ label: String) { if !value { errors.append("Code service: " + label) } }
        let source = CodeProject(name: "مشروع 😀 / \"", files: [
            CodeFile(path: "z.swift", content: "hello\nworld"),
            CodeFile(path: "ä.txt", content: "النص 😀\t\\"),
            CodeFile(path: "A.swift", content: "line\u{2028}next")
        ])
        var stage = "sourceHash"
        do {
            let hash = try CodeEditService.sourceHash(source)
            // Computed with the website's real tools/code-edit.mjs codeEditHash, not the Swift implementation.
            check(hash == "7a698f7e5bfa6e739de41a789e7353dc3204fa9355136b57dd3795ff52de5874",
                  "canonical Unicode/source hash differs from website")
            let receipt = CodeEditReceipt(owner: "fixture-owner", conversationId: "fixture_project", cid: "fixture_turn", baseHash: hash)
            for model in [ModelTier.mini, .pro, .ultra, .max] {
                stage = "request/" + model.rawValue
                let request = try CodeEditService.request(receipt: receipt, task: "Explain my Swift code", attach: "",
                    selection: CodeModelSelection(model: model, depth: "deep"), lang: .english)
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
                check(object["tier"] as? String == model.rawValue && object["kind"] as? String == "codeedit",
                      "selected model lost in durable edit request")
                check(object["mgen"] as? String == "1.1", "selected generation lost in durable edit request")
                check(object["nomem"] == nil && object["baseHash"] as? String == hash,
                      "user answer sent to helper route or source binding omitted")
                check(object["think"] as? Bool == (model != .mini), "selected reasoning depth lost")
            }
            check((try? CodeEditService.request(receipt: receipt, task: "Build", attach: "",
                selection: CodeModelSelection(model: .omnix), lang: .english)) == nil,
                  "Omnix submitted through ordinary service")

            var proposal: [String: Any] = ["version": 1, "baseHash": hash, "answer": "Updated", "summary": "One file",
                                          "changes": [["path": "z.swift", "content": "new complete source"]], "dels": ["ä.txt"]]
            func fence(_ value: [String: Any]) throws -> String {
                "```firas-code-edit\n" + String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)! + "\n```"
            }
            stage = "editProposal"
            let proposalFence = try fence(proposal)
            check(FirasFence.firstFence(in: proposalFence) == nil,
                  "private edit protocol unexpectedly entered the ordinary rendering whitelist")
            check(FirasFence.firstFence(in: proposalFence, including: ["firas-code-edit"])?.name == "firas-code-edit",
                  "private edit fence was not recognized in the Code service scope")
            let plan = try CodeEditService.proposal(text: proposalFence, source: source, expectedBaseHash: hash)
            check(plan.writes.map(\.path) == ["z.swift"] && plan.deletes == ["ä.txt"], "valid proposal lost changes")
            proposal["baseHash"] = String(repeating: "0", count: 64)
            check((try? CodeEditService.proposal(text: fence(proposal), source: source, expectedBaseHash: hash)) == nil,
                  "wrong source hash accepted")
            proposal["baseHash"] = hash
            proposal["dels"] = ["absent.swift"]
            check((try? CodeEditService.proposal(text: fence(proposal), source: source, expectedBaseHash: hash)) == nil,
                  "deleting a nonexistent source file accepted")
            proposal["dels"] = [] as [String]
            proposal["changes"] = [["path": "../z.swift", "content": "escape"]]
            check((try? CodeEditService.proposal(text: fence(proposal), source: source, expectedBaseHash: hash)) == nil,
                  "proposal traversed project path")
            proposal["changes"] = [] as [[String: String]]
            proposal["summary"] = ""
            proposal["answer"] = "Read-only explanation"
            stage = "readOnlyProposal"
            let answer = try CodeEditService.proposal(text: fence(proposal), source: source, expectedBaseHash: hash)
            check(answer.isEmpty && answer.prose == "Read-only explanation", "question produced edits instead of its answer")
            errors += await admissionChecks(receipt)
        } catch {
            let code: String
            if let failure = error as? CodeEditService.Failure { code = String(describing: failure) }
            else if let failure = error as? CodeOmnixImportError { code = String(describing: failure) }
            else if error is EncodingError { code = "encoding" }
            else if error is DecodingError { code = "decoding" }
            else { code = "unexpected" }
            errors.append("Code service: fixture failed at " + stage + " (" + code + ")")
        }
        return errors
    }

    private static func admissionChecks(_ receipt: CodeEditReceipt) async -> [String] {
        var errors: [String] = []
        let acknowledgement = #"{"jobId":"fixture_job","phase":"completed","cid":"fixture_turn","chatId":"fixture_project"}"#
        let cases: [(String, [CodeEditFaultProtocol.Step], Bool)] = [
            ("lost acknowledgement", [.fault, .json(200, acknowledgement)], true),
            ("unknown admission", [.fault, .json(200, #"{"jobId":"","phase":"unknown"}"#)], false),
            ("wrong conversation", [.fault, .json(200, #"{"jobId":"fixture_job","phase":"completed","cid":"fixture_turn","chatId":"another_project"}"#)], false),
            ("wrong turn", [.fault, .json(200, #"{"jobId":"fixture_job","phase":"completed","cid":"another_turn","chatId":"fixture_project"}"#)], false),
            ("rejected request", [.json(422, #"{"error":"codeedit_project_invalid"}"#)], false),
            ("recovery auth expired", [.fault, .json(401, #"{"error":"unauthorized"}"#)], false),
            ("recovery forbidden", [.fault, .json(403, #"{"error":"forbidden"}"#)], false),
            ("recovery missing", [.fault, .json(404, #"{"error":"not_found"}"#)], false),
            ("recovery timed out", [.json(408, #"{"error":"timeout"}"#), .json(408, #"{"error":"timeout"}"#)], false),
            ("server error then forbidden read", [.json(500, #"{"error":"server_error"}"#), .json(403, #"{"error":"forbidden"}"#)], false)
        ]
        for (label, steps, succeeds) in cases {
            let host = CodeEditFaultProtocol.install(steps)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CodeEditFaultProtocol.self]
            config.httpCookieStorage = nil
            let session = URLSession(configuration: config)
            let api = APIClient(configuration: AppConfiguration(apiBaseURL: URL(string: "https://" + host)!), testingSession: session)
            do {
                let response = try await CodeEditService.submit(receipt: receipt, task: "Explain the code", attach: "",
                    selection: CodeModelSelection(model: .max), lang: .english, api: api, isCurrent: { true })
                if !succeeds || response.jobId != "fixture_job" || response.phase != "queued" {
                    errors.append("Code service: " + label + " recovery did not require authoritative full status")
                }
            } catch {
                if succeeds { errors.append("Code service: " + label + " did not recover") }
                let recoverable = CodeRequestAdmission.submitting.requiresRecovery(after: error, explicitlyRejected: CodeEditService.explicitlyRejected)
                if recoverable != (label != "rejected request") {
                    errors.append("Code service: " + label + " confused a status-read failure with a rejected submission")
                }
            }
            session.invalidateAndCancel()
            let calls = CodeEditFaultProtocol.finish(host)
            let expected = label == "rejected request" ? ["POST /api/chat/job"] : ["POST /api/chat/job", "GET /api/chat/job?cid=fixture_turn"]
            if calls != expected { errors.append("Code service: " + label + " replayed a mutation or changed receipt lookup") }
        }
        errors += await acceptedSaveFailureChecks(receipt, acknowledgement: acknowledgement)
        return errors
    }

    private static func acceptedSaveFailureChecks(_ receipt: CodeEditReceipt, acknowledgement: String) async -> [String] {
        let host = CodeEditFaultProtocol.install([.json(202, acknowledgement), .json(403, #"{"error":"forbidden"}"#), .json(200, acknowledgement)])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CodeEditFaultProtocol.self]
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        let api = APIClient(configuration: AppConfiguration(apiBaseURL: URL(string: "https://" + host)!), testingSession: session)
        var errors: [String] = []
        do {
            let response = try await CodeEditService.submit(receipt: receipt, task: "Explain the code", attach: "",
                selection: CodeModelSelection(model: .pro), lang: .english, api: api, isCurrent: { true })
            var bound = receipt; bound.jobId = response.jobId ?? ""
            let saved = try JSONDecoder().decode(CodeEditReceipt.self, from: JSONEncoder().encode(bound))
            do {
                try await api.updateChat(id: receipt.conversationId, UpdateChatRequest(title: "Project", messages: []))
                errors.append("Code service: accepted receipt PUT fault was not exercised")
            } catch {
                guard CodeRequestAdmission.accepted.requiresRecovery(after: error, explicitlyRejected: CodeEditService.explicitlyRejected),
                      CodeRequestAdmission.accepted.requiresRecovery(after: error, explicitlyRejected: { _ in true }) else {
                    throw CodeEditService.Failure.invalidReceipt
                }
                let recovered = try await CodeEditService.recover(receipt: saved, api: api)
                if recovered?.jobId != saved.jobId || saved.jobId != "fixture_job" {
                    errors.append("Code service: failed receipt PUT lost the acknowledged job identity")
                }
                if !CodeStore.shouldWatchCodeEdit(phase: "completed", savePending: true)
                    || CodeStore.shouldWatchCodeEdit(phase: "completed", savePending: false) {
                    errors.append("Code service: terminal persistence failure stopped its retry watcher")
                }
            }
        } catch { errors.append("Code service: acknowledged job could not reattach after receipt PUT failure") }
        session.invalidateAndCancel()
        let calls = CodeEditFaultProtocol.finish(host)
        if calls != ["POST /api/chat/job", "PUT /api/chats/fixture_project", "GET /api/chat/job?cid=fixture_turn"] {
            errors.append("Code service: accepted receipt failure replayed submission instead of reattaching")
        }
        return errors
    }
}

private final class CodeEditFaultProtocol: URLProtocol, @unchecked Sendable {
    enum Step { case fault; case json(Int, String) }
    private struct Scenario { var steps: [Step]; var calls: [String] = [] }
    private static let lock = NSLock()
    private static var scenarios: [String: Scenario] = [:]
    static func install(_ steps: [Step]) -> String {
        let host = "code-edit-" + UUID().uuidString.lowercased() + ".invalid"
        lock.lock(); defer { lock.unlock() }
        scenarios[host] = Scenario(steps: steps)
        return host
    }
    static func finish(_ host: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return scenarios.removeValue(forKey: host)?.calls ?? []
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        Self.lock.lock()
        var scenario = Self.scenarios[host] ?? Scenario(steps: [])
        scenario.calls.append((request.httpMethod ?? "") + " " + url.path + (url.query.map { "?" + $0 } ?? ""))
        let step = scenario.steps.isEmpty ? Step.fault : scenario.steps.removeFirst()
        Self.scenarios[host] = scenario
        Self.lock.unlock()
        switch step {
        case .fault:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .json(let status, let text):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}
#endif
