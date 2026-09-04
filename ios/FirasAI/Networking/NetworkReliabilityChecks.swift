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
        if !SendPipeline.shouldStreamFirst(kind: kind, planTurn: .clarifyOrPlan, readerIsPresent: true)
            || !SendPipeline.shouldStreamFirst(kind: .chat, planTurn: .auto, readerIsPresent: true) {
            failures.append("Document durability changed ordinary chat or plan clarification streaming")
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
    struct Call { let method: String; let path: String; let body: Data? }
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
            scenario.calls.append(Call(method: request.httpMethod ?? "", path: request.url?.path ?? "", body: body))
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
