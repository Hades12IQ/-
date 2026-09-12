#if DEBUG
import Foundation

/// Real URLSession/APIClient requests intercepted before DNS. No cookies, account, or model calls.
@MainActor
enum NetworkReliabilityChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        let prompt = "Create a professional PDF with 100 difficult integrals and all 100 solutions in English."
        let kind = RequestClassifier.classify(prompt, hasImages: false, lang: .arabic)
        if kind != .file(format: "pdf", explicitPages: nil) {
            failures.append("100 integrals were confused with an explicit page count")
        }
        if SendPipeline.shouldStreamFirst(kind: kind, planTurn: .auto, readerIsPresent: true)
            || SendPipeline.shouldStreamFirst(kind: kind, planTurn: .execute(originID: "origin"), readerIsPresent: true) {
            failures.append("Document generation still depended on the visible screen's live socket")
        }
        if SendPipeline.shouldStreamFirst(kind: kind, planTurn: .clarifyOrPlan, readerIsPresent: true)
            || SendPipeline.shouldStreamFirst(kind: .chat, planTurn: .auto, readerIsPresent: true)
            || !SendPipeline.shouldStreamFirst(kind: .chat, planTurn: .auto, readerIsPresent: true, isTemporary: true)
            || !SendPipeline.shouldStreamFirst(kind: kind, planTurn: .clarifyOrPlan, readerIsPresent: true, isTemporary: true) {
            failures.append("Persistent chat did not use durable transport or temporary chat lost its private stream")
        }
        let request = ChatJobRequest(messages: [
            OutgoingMessage(role: "system", content: "Keep the complete PDF design and requested count."),
            OutgoingMessage(role: "user", content: prompt, images: ["c3ludGhldGljLWltYWdl"])
        ], tier: "pro", think: false, cid: "network-smoke-stable-cid", chatId: "fixture-chat",
            product: "ai", kind: "chat", lang: "en", title: "Integral collection", task: prompt)
        if !SendPipeline.fitsDurableQueue(request, isTemporary: false, hasStorage: true)
            || SendPipeline.fitsDurableQueue(request, isTemporary: true, hasStorage: true) {
            failures.append("Document queue eligibility lost image support or temporary-chat privacy")
        }
        let success = Data(#"{"ok":true,"jobId":"fixture-existing-job","phase":"queued"}"#.utf8)

        for code in [URLError.Code.timedOut, .networkConnectionLost] {
            let scenario = NetworkFaultProtocol.scenario([.fault(code), .response(200, success)])
            let api = client(for: scenario)
            do {
                let response = try await ChatJobSubmission.submit(request, ownerIsCurrent: { true },
                    operation: { try await api.startChatJob($0) })
                if response.jobId != "fixture-existing-job" { failures.append("Uncertain acknowledgement lost the existing job") }
            } catch { failures.append("A transient job acknowledgement did not recover") }
            let calls = NetworkFaultProtocol.finish(scenario)
            if calls.count != 2 { failures.append("Acknowledgement recovery did not make exactly one replay") }
            let payloads = calls.compactMap { $0.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary } }
            if payloads.count != 2 || payloads.first != payloads.last {
                failures.append("Job acknowledgement replay changed its cid or original payload")
            }
            for call in calls {
                if call.path != "/api/chat/job" || call.method != "POST" {
                    failures.append("Acknowledgement recovery escaped into chat creation or a second send path")
                }
            }
            if let body = payloads.first {
                let messages = body["messages"] as? [[String: Any]] ?? []
                if body["cid"] as? String != request.cid || body["tier"] as? String != "pro"
                    || body["lang"] as? String != "en" || body["chatId"] as? String != request.chatId
                    || body["nomem"] != nil || messages.filter({ $0["role"] as? String == "user" }).count != 1
                    || messages.last?["content"] as? String != prompt
                    || messages.last?["images"] as? [String] != request.messages.last?.images {
                    failures.append("A replay duplicated the user payload or changed quota/language/image context")
                }
            }
        }

        let quota = Data(#"{"error":"daily quota reached","quota":{"product":"ai","limit":20,"plan":"free"}}"#.utf8)
        for status in [401, 429, 503] {
            let scenario = NetworkFaultProtocol.scenario([.response(status, quota), .response(200, success)])
            let api = client(for: scenario)
            do {
                _ = try await ChatJobSubmission.submit(request, ownerIsCurrent: { true },
                    operation: { try await api.startChatJob($0) })
                failures.append("A definite HTTP refusal was treated as an accepted job")
            } catch {
                if (error as? APIError)?.status != status { failures.append("Job submission changed a definite HTTP refusal") }
            }
            if NetworkFaultProtocol.finish(scenario).count != 1 { failures.append("A quota/auth/server refusal was automatically replayed") }
        }
        let repeated = NetworkFaultProtocol.scenario([.fault(.timedOut), .fault(.timedOut), .response(200, success)])
        let repeatedAPI = client(for: repeated)
        do {
            _ = try await ChatJobSubmission.submit(request, ownerIsCurrent: { true },
                operation: { try await repeatedAPI.startChatJob($0) })
            failures.append("Repeated acknowledgement failures escaped the retry bound")
        } catch {}
        if NetworkFaultProtocol.finish(repeated).count != 2 { failures.append("Job acknowledgement retry was not bounded to two attempts") }

        var currentOwner = true
        let switched = NetworkFaultProtocol.scenario([.fault(.timedOut), .response(200, success)])
        let switchedAPI = client(for: switched)
        do {
            _ = try await ChatJobSubmission.submit(request, ownerIsCurrent: { currentOwner }, operation: { body in
                do { return try await switchedAPI.startChatJob(body) }
                catch { currentOwner = false; throw error }
            })
            failures.append("Job acknowledgement was replayed after its account changed")
        } catch {
            if !(error is CancellationError) { failures.append("Account change did not cancel an acknowledgement replay") }
        }
        if NetworkFaultProtocol.finish(switched).count != 1 { failures.append("Account change sent the old payload again") }
        let cancelled = NetworkFaultProtocol.scenario([.response(200, success)])
        let cancelledAPI = client(for: cancelled)
        let task = Task {
            try await ChatJobSubmission.submit(request, ownerIsCurrent: { true },
                operation: { try await cancelledAPI.startChatJob($0) })
        }
        task.cancel()
        do { _ = try await task.value; failures.append("A cancelled job submission still started") }
        catch { if !(error is CancellationError) { failures.append("Cancelled submission lost cancellation identity") } }
        if !NetworkFaultProtocol.finish(cancelled).isEmpty { failures.append("Cancellation sent a job request") }
        let timeouts: [Error] = [URLError(.timedOut), APIError.transport(URLError(.timedOut))]
        for error in timeouts {
            if ErrorPresenter.present(error, feature: .generic, isGuest: false, lang: .arabic) != .toast(Strings.Errors.timeout) {
                failures.append("A timeout was still reported as loss of Internet connectivity")
            }
        }
        if ErrorPresenter.present(APIError.offline, feature: .generic, isGuest: false, lang: .english) != .toast(Strings.Errors.offline)
            || ChatJobSubmission.canReplay(after: CancellationError()) {
            failures.append("Offline/cancellation semantics changed during acknowledgement recovery")
        }
        if ChatJobSubmission.hasReplayKey("") || ChatJobSubmission.hasReplayKey("!!!")
            || ChatJobSubmission.hasReplayKey(String(repeating: "a", count: 65)) {
            failures.append("An absent or server-rewritten cid was accepted for automatic replay")
        }
        failures += await checkJobTails()
        failures += await checkJobReceipts(request)
        failures += await checkBinaryUpload()
        failures += await checkOfficeDelivery()
        failures += await checkSelectedModelPartial()
        let terminalState = ConversationState(conversationID: "terminal-correction-fixture")
        let terminalBuffer = StreamBuffer(state: terminalState)
        terminalBuffer.append(content: "A long stale draft from before the server restarted.", reasoning: "old reasoning")
        let corrected = terminalBuffer.finish(authoritativeText: "<think>new</think>OK", reasoning: "")
        if corrected.text != "OK" || corrected.reasoning != "new" || terminalState.liveText != "OK"
            || terminalState.liveReasoning != "new" {
            failures.append("A shorter terminal correction kept a stale streamed answer or reasoning")
        }
        let equalLength = terminalBuffer.finish(authoritativeText: "NO", reasoning: "")
        if equalLength.text != "NO" || !equalLength.reasoning.isEmpty {
            failures.append("An equal-length terminal correction was ignored")
        }
        return failures
    }

    private static func checkJobReceipts(_ request: ChatJobRequest) async -> [String] {
        var failures: [String] = []
        let receipt = Data(#"{"jobId":"accepted-job","phase":"completed","chatId":"fixture-chat"}"#.utf8)
        for first in [NetworkFaultProtocol.Step.fault(.timedOut), .response(503, Data(#"{"error":"storage_unavailable"}"#.utf8))] {
            let scenario = NetworkFaultProtocol.scenario([first, .response(200, receipt)])
            let api = client(for: scenario)
            do {
                let result = try await ChatJobSubmission.submit(request, ownerIsCurrent: { true },
                    lookup: { try await api.chatJobReceipt(cid: $0, chatID: request.chatId) },
                    operation: { try await api.startChatJob($0) })
                if result.jobId != "accepted-job" || result.phase != "queued" {
                    failures.append("A completed admission receipt was not attached for an authoritative answer read")
                }
            } catch { failures.append("Read-only receipt recovery failed") }
            let calls = NetworkFaultProtocol.finish(scenario)
            if calls.count != 2 || calls.first?.method != "POST" || calls.last?.method != "GET"
                || calls.last?.query["cid"] != request.cid {
                failures.append("Receipt reconciliation repeated generation instead of looking up its cid")
            }
        }
        let absent = NetworkFaultProtocol.scenario([.fault(.timedOut),
            .response(200, Data(#"{"jobId":"","phase":"unknown"}"#.utf8))])
        let absentAPI = client(for: absent)
        do {
            _ = try await ChatJobSubmission.submit(request, ownerIsCurrent: { true },
                lookup: { try await absentAPI.chatJobReceipt(cid: $0, chatID: request.chatId) },
                operation: { try await absentAPI.startChatJob($0) })
            failures.append("An unknown admission receipt was treated as accepted")
        } catch {}
        let absentCalls = NetworkFaultProtocol.finish(absent)
        if absentCalls.count != 2 || absentCalls.filter({ $0.method == "POST" }).count != 1 {
            failures.append("An unknown receipt triggered a replacement generation")
        }
        let wrong = NetworkFaultProtocol.scenario([.response(200,
            Data(#"{"jobId":"accepted-job","phase":"completed","chatId":"another-chat"}"#.utf8))])
        do {
            _ = try await client(for: wrong).chatJobReceipt(cid: request.cid, chatID: request.chatId)
            failures.append("A receipt from another conversation was attached")
        } catch {}
        _ = NetworkFaultProtocol.finish(wrong)
        return failures
    }

    private struct UploadReceipt: Decodable, Sendable { let ok: Bool }

    private static func checkOfficeDelivery() async -> [String] {
        var failures: [String] = []
        let pointer = JobPointer(id: "office-job", kind: .officefile, ownerID: "fixture-owner",
            cid: "office-cid", conversationID: "fixture-chat", deadline: .distantPast)
        let draft = "Internal author plan and unfinished ```firas-file"
        let ready = "```firas-file\n{\"format\":\"docx\",\"filename\":\"lesson.docx\"}\n```\n\nA complete document."
        let packets: [[String: String]] = [
            ["phase": "processing", "text": draft, "reasoning": "private preparation"],
            ["phase": "completed", "text": draft],
            ["phase": "completed", "text": ready]
        ]
        let scenario = NetworkFaultProtocol.scenario(packets.map {
            .response(200, (try? JSONSerialization.data(withJSONObject: $0)) ?? Data())
        })
        let api = client(for: scenario), driver = ChatJobDriver(kind: .officefile)
        do {
            let first = try await driver.read(pointer, api: api)
            if case .running(let snapshot) = first {
                if !snapshot.text.isEmpty || !snapshot.reasoning.isEmpty { failures.append("Office draft preparation leaked into the conversation") }
            } else { failures.append("A processing Office document was treated as terminal") }
            let second = try await driver.read(pointer, api: api)
            if case .terminal(.failed(let code, let partial)) = second {
                if code != "invalid_document" || partial != nil { failures.append("Malformed Office result remained saveable") }
            } else { failures.append("Malformed Office result was presented as a complete file") }
            let third = try await driver.read(pointer, api: api)
            if case .terminal(.completed(let snapshot)) = third {
                if snapshot.text != ready { failures.append("A validated Office result lost its source") }
            } else { failures.append("A complete Office document could not be delivered") }
        } catch { failures.append("Office queue result checks did not complete") }
        _ = NetworkFaultProtocol.finish(scenario)
        if !JobKindSpecs.hasServerOwnedLifetime(.officefile) || JobManager.driver(for: .officefile).kind != .officefile {
            failures.append("Office queue lost its durable driver or lifetime")
        }
        return failures
    }

    private static func checkSelectedModelPartial() async -> [String] {
        var failures: [String] = []
        let pointer = JobPointer(id: "selected-job", kind: .chat, ownerID: "fixture-owner",
            cid: "selected-cid", conversationID: "fixture-chat", deadline: .distantFuture)
        for code in ["selected_model_unavailable", "selected_model_incomplete", "selected_outcome_unknown"] {
            let fields: [String: Any] = ["phase": "failed", "status": 503,
                "error": "{\"error\":\"" + code + "\"}", "text": "Useful partial answer.", "reasoning": "earlier reasoning"]
            let scenario = NetworkFaultProtocol.scenario([.response(200,
                (try? JSONSerialization.data(withJSONObject: fields)) ?? Data())])
            do {
                let read = try await ChatJobDriver(kind: .chat).read(pointer, api: client(for: scenario))
                if case .terminal(.failed(let actual, let partial)) = read {
                    if actual != code || partial?.text != "Useful partial answer." || partial?.reasoning != "earlier reasoning" {
                        failures.append("Selected-model failure changed its code or partial answer")
                    }
                } else { failures.append("Selected-model interruption discarded its partial answer") }
            } catch { failures.append("Selected-model partial could not be recovered") }
            let calls = NetworkFaultProtocol.finish(scenario)
            if calls.count != 1 || calls.first?.method != "GET" { failures.append("Recovering a partial answer triggered new work") }
        }
        return failures
    }

    private static func checkBinaryUpload() async -> [String] {
        var failures: [String] = []
        let scenario = NetworkFaultProtocol.scenario([.response(200, Data(#"{"ok":true}"#.utf8))])
        let api = client(for: scenario)
        do {
            let result = try await api.uploadBytes("/api/omnix/inputs/fixture-request/fixture-file",
                data: Data("fixture".utf8), headers: ["Content-Type": "text/plain", "x-omnix-size": "7",
                    "x-omnix-conversation": "fixture-chat"], as: UploadReceipt.self)
            if !result.ok { failures.append("Private binary upload lost its acknowledgement") }
        } catch { failures.append("Private binary upload failed") }
        let calls = NetworkFaultProtocol.finish(scenario)
        if calls.count != 1 || calls.first?.method != "PUT"
            || calls.first?.headers["content-type"] != "text/plain"
            || calls.first?.headers["x-omnix-conversation"] != "fixture-chat"
            || calls.first?.timeout != RequestBudget.upload.timeout {
            failures.append("Private binary upload changed method, metadata, or timeout")
        }
        let rejected = NetworkFaultProtocol.scenario([])
        do {
            _ = try await client(for: rejected).uploadBytes("/api/omnix/inputs/fixture-request/fixture-file",
                data: Data(), headers: ["Cookie": "untrusted"], as: UploadReceipt.self)
            failures.append("Binary upload permitted a credential header override")
        } catch {}
        if !NetworkFaultProtocol.finish(rejected).isEmpty { failures.append("Invalid upload headers reached the network") }
        return failures
    }

    /// Exercises the actual APIClient request/decoder, including JavaScript's UTF-16 cursor units.
    /// A shorter restarted answer is the next cursor even if the view retains its longer text.
    private static func checkJobTails() async -> [String] {
        var failures: [String] = []
        func payload(_ fields: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
        }
        let initial = "أهلاً 👨‍👩‍👧‍👦 ", thinking = "فكرة 🧠"
        let suffix = "الحل \\(x^2\\)", reasonTail = " جديدة"
        let replacement = "بدء 🔄", finalTail = " من جديد"
        let scenario = NetworkFaultProtocol.scenario([
            .response(200, payload(["phase": "processing", "text": initial, "reasoning": thinking,
                                   "from": 0, "fromR": 0, "textLen": initial.utf16.count,
                                   "reasoningLen": thinking.utf16.count])),
            .response(200, payload(["phase": "processing", "text": suffix, "reasoning": reasonTail,
                                   "from": initial.utf16.count, "fromR": thinking.utf16.count,
                                   "textLen": (initial + suffix).utf16.count,
                                   "reasoningLen": (thinking + reasonTail).utf16.count])),
            .response(200, payload(["phase": "processing", "text": replacement, "reasoning": "",
                                   "from": 0, "fromR": 0, "textLen": replacement.utf16.count,
                                   "reasoningLen": 0])),
            .response(200, payload(["phase": "completed", "text": finalTail, "reasoning": "",
                                   "from": replacement.utf16.count, "fromR": 0,
                                   "textLen": (replacement + finalTail).utf16.count, "reasoningLen": 0]))
        ])
        let api = client(for: scenario)
        var previous = ChatJobStatus()
        let expected = [(initial, thinking), (initial + suffix, thinking + reasonTail),
                        (replacement, ""), (replacement + finalTail, "")]
        do {
            for pair in expected {
                previous = try await api.chatJobStatus(id: "tail-job", previousText: previous.text,
                                                       previousReasoning: previous.reasoning)
                if previous.text != pair.0 || previous.reasoning != pair.1 {
                    failures.append("Tail polling duplicated, truncated or mixed restarted answer/reasoning")
                }
            }
            if previous.phase != "completed" { failures.append("Tail polling lost terminal status") }
        } catch { failures.append("Native UTF-16 tail requests did not complete") }
        let calls = NetworkFaultProtocol.finish(scenario)
        let cursors = [(0, 0), (initial.utf16.count, thinking.utf16.count),
                       ((initial + suffix).utf16.count, (thinking + reasonTail).utf16.count),
                       (replacement.utf16.count, 0)]
        if calls.count != cursors.count { failures.append("Valid tail polling made unnecessary full reads") }
        for (call, cursor) in zip(calls, cursors) {
            if call.method != "GET" || call.path != "/api/chat/job" || call.query["id"] != "tail-job"
                || call.query["from"] != String(cursor.0) || call.query["fromR"] != String(cursor.1)
                || call.timeout != 8 {
                failures.append("Job tail request used a wrong endpoint or non-UTF-16 cursor")
            }
        }

        let oldWhole = "An older server returns the whole answer."
        let old = NetworkFaultProtocol.scenario([.response(200, payload([
            "phase": "completed", "text": oldWhole, "reasoning": "whole reasoning"
        ]))])
        do {
            let status = try await client(for: old).chatJobStatus(id: "old-server", previousText: "An older")
            if status.text != oldWhole || status.reasoning != "whole reasoning" {
                failures.append("An older server's whole answer was appended as a tail")
            }
        } catch { failures.append("Tail polling rejected an older server") }
        if NetworkFaultProtocol.finish(old).count != 1 { failures.append("Older server compatibility required redundant reads") }

        for mismatch in [payload(["phase": "processing", "text": "bad", "from": 1]),
                         payload(["phase": "processing", "text": "bad", "from": initial.utf16.count, "textLen": 999])] {
            let bad = NetworkFaultProtocol.scenario([.response(200, mismatch), .response(200, payload([
                "phase": "completed", "text": "Authoritative result"
            ]))])
            do {
                let status = try await client(for: bad).chatJobStatus(id: "bad-tail", previousText: initial)
                if status.text != "Authoritative result" { failures.append("A malformed tail was published") }
            } catch { failures.append("A malformed tail did not recover with a full read") }
            let reads = NetworkFaultProtocol.finish(bad)
            if reads.count != 2 || reads.last?.query["from"] != nil || reads.last?.method != "GET" {
                failures.append("Tail recovery was not one read-only full snapshot request")
            }
        }
        return failures
    }

    private static func client(for host: String) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkFaultProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return APIClient(configuration: AppConfiguration(apiBaseURL: URL(string: "https://" + host)!),
            testingSession: URLSession(configuration: configuration))
    }
}

private final class NetworkFaultProtocol: URLProtocol, @unchecked Sendable {
    enum Step { case fault(URLError.Code), response(Int, Data) }
    struct Call {
        let method: String; let path: String; let query: [String: String]
        let headers: [String: String]; let timeout: TimeInterval; let body: Data?
    }
    private struct Scenario { var steps: [Step]; var calls: [Call] = [] }
    // URLProtocol callbacks can run on arbitrary threads; all fixture state is behind this lock.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var scenarios: [String: Scenario] = [:]
    }
    private static let state = State()

    static func scenario(_ steps: [Step]) -> String {
        let host = UUID().uuidString.lowercased() + ".network-smoke.invalid"
        state.lock.lock(); defer { state.lock.unlock() }
        state.scenarios[host] = Scenario(steps: steps)
        return host
    }

    static func finish(_ host: String) -> [Call] {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.scenarios.removeValue(forKey: host)?.calls ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".network-smoke.invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data?
        if let data = request.httpBody { body = data }
        else if let input = request.httpBodyStream {
            input.open(); defer { input.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while data.count < 600_000 {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { body = nil }
        let step: Step
        Self.state.lock.lock()
        if let host = request.url?.host, var scenario = Self.state.scenarios[host] {
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            let query = items.reduce(into: [String: String]()) { $0[$1.name] = $1.value ?? "" }
            let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) {
                $0[$1.key.lowercased()] = $1.value
            }
            scenario.calls.append(Call(method: request.httpMethod ?? "", path: request.url?.path ?? "",
                query: query, headers: headers, timeout: request.timeoutInterval, body: body))
            step = scenario.steps.isEmpty ? .fault(.badServerResponse) : scenario.steps.removeFirst()
            Self.state.scenarios[host] = scenario
        } else { step = .fault(.badServerResponse) }
        Self.state.lock.unlock()
        switch step {
        case .fault(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let data):
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
#endif
