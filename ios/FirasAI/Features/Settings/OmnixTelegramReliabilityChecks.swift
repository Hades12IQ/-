#if DEBUG
import Foundation

@MainActor
enum OmnixTelegramReliabilityChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let connection = "omxt_" + String(repeating: "a", count: 32)
        let code = String(repeating: "b", count: 32)
        let token = "12345:" + String(repeating: "fixture_", count: 5)
        func data(_ fields: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: fields)) ?? Data() }
        func fields(_ phase: OmnixTelegramPhase) -> [String: Any] {
            ["ok": true, "state": phase.rawValue, "connectionId": connection,
             "bot": ["id": 12345, "username": "FirasFixtureBot"], "telegramUserId": 123456789]
        }
        var paired = fields(.pairing)
        paired["pairing"] = ["code": code, "expiresAt": (now.timeIntervalSince1970 + 600) * 1000]
        do {
            let reply = try JSONDecoder().decode(OmnixTelegramReply.self, from: data(paired))
            guard let secret = OmnixTelegramPairing(owner: "fixture-owner", reply: reply, now: now) else {
                return ["Telegram rejected its one-time owner pairing response"]
            }
            if secret.command(owner: "fixture-owner", status: reply.status, now: now) != "/start " + code {
                failures.append("Telegram changed the server-issued pairing command")
            }
            let url = secret.botURL(owner: "fixture-owner", status: reply.status, now: now)
            if url?.absoluteString != "https://t.me/FirasFixtureBot?start=" + code {
                failures.append("Telegram pairing escaped the validated bot URL")
            }
            if secret.command(owner: "other-owner", status: reply.status, now: now) != nil
                || secret.command(owner: "fixture-owner", status: reply.status, now: now.addingTimeInterval(601)) != nil {
                failures.append("Telegram exposed an expired or foreign-owner pairing code")
            }
            var foreign = reply.status
            foreign.connectionId = "omxt_" + String(repeating: "c", count: 32)
            if secret.botURL(owner: "fixture-owner", status: foreign, now: now) != nil {
                failures.append("Telegram reused a code for a different connection")
            }
            for phase in OmnixTelegramPhase.allCases {
                let status = try JSONDecoder().decode(OmnixTelegramStatus.self, from: data(fields(phase)))
                if !status.isValid { failures.append("Telegram rejected known state " + phase.rawValue) }
                if phase != .pairing && secret.command(owner: "fixture-owner", status: status, now: now) != nil {
                    failures.append("Telegram retained a pairing code after leaving the pairing state")
                }
                if status.mayConfigure { failures.append("Telegram enabled linking without server readiness") }
            }
            for phase in [OmnixTelegramPhase.notConfigured, .disconnected, .connected, .setupUncertain] {
                var readyFields = fields(phase); readyFields["cloudReady"] = true; readyFields["canConfigure"] = true
                let ready = try JSONDecoder().decode(OmnixTelegramStatus.self, from: data(readyFields))
                if ready.mayConfigure != [.notConfigured, .disconnected].contains(phase) {
                    failures.append("Telegram permitted replacing an unremoved connection")
                }
            }
            for bad in ["../../other", "GoodBot?start=other", "GoodBot\n", "GoodBot@evil.test"] {
                var badFields = paired; badFields["bot"] = ["id": 12345, "username": bad]
                let badReply = try JSONDecoder().decode(OmnixTelegramReply.self, from: data(badFields))
                if OmnixTelegramPairing(owner: "fixture-owner", reply: badReply, now: now) != nil {
                    failures.append("Telegram accepted an unsafe returned bot name")
                }
            }
            for badCode in [code + "\n", "short", String(repeating: "/", count: 32)] {
                var badFields = paired; badFields["pairing"] = ["code": badCode, "expiresAt": (now.timeIntervalSince1970 + 600) * 1000]
                let badReply = try JSONDecoder().decode(OmnixTelegramReply.self, from: data(badFields))
                if OmnixTelegramPairing(owner: "fixture-owner", reply: badReply, now: now) != nil {
                    failures.append("Telegram accepted a malformed pairing secret")
                }
            }
        } catch { failures.append("Telegram known response fixtures did not decode") }
        if (try? JSONDecoder().decode(OmnixTelegramReply.self, from: data(["ok": true, "state": "unknown_future_state"]))) != nil {
            failures.append("Telegram guessed the meaning of an unknown state")
        }
        for input in ["123456789", "١٢٣٤٥٦٧٨٩", "۱۲۳۴۵۶۷۸۹", " 123456789 "] {
            if OmnixTelegramService.userID(input) != 123456789 { failures.append("Telegram numeric ID normalization failed") }
        }
        for input in ["0", "-123", "+9647700000000", "@username", "012345", "4503599627370496", "1.5", "123\n456"] {
            if OmnixTelegramService.userID(input) != nil { failures.append("Telegram accepted an invalid personal ID") }
        }
        if !OmnixTelegramService.validToken(token) || OmnixTelegramService.validToken(token + "\n") {
            failures.append("Telegram bot-token syntax validation failed")
        }

        let statusBytes = data(["ok": true, "state": "not_configured", "cloudReady": true, "canConfigure": true])
        let configuredBytes = data(paired)
        let scenario = TelegramFixtureProtocol.scenario([.response(statusBytes), .response(configuredBytes), .response(data(["ok": true, "state": "disconnected"]))])
        do {
            let api = client(scenario)
            _ = try await OmnixTelegramService.status(api: api)
            _ = try await OmnixTelegramService.configure(token: token, userID: 123456789, api: api)
            _ = try await OmnixTelegramService.disconnect(api: api)
        } catch { failures.append("Telegram service could not use its exact native endpoint contract") }
        let calls = TelegramFixtureProtocol.finish(scenario)
        if calls.map(\.method) != ["GET", "POST", "POST"]
            || calls.map(\.path) != ["/api/omnix/telegram", "/api/omnix/telegram", "/api/omnix/telegram/disconnect"]
            || calls.contains(where: { $0.query != nil }) {
            failures.append("Telegram endpoint contract changed or acquired query parameters")
        }
        if calls.count == 3 {
            let configure = calls[1].body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let disconnect = calls[2].body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if configure?.count != 2 || configure?["botToken"] as? String != token
                || configure?["telegramUserId"] as? Int != 123456789 || disconnect?.isEmpty != true {
                failures.append("Telegram mutation body did not match the approved schema")
            }
        }
        let uncertain = TelegramFixtureProtocol.scenario([.timeout, .response(statusBytes)])
        let uncertainAPI = client(uncertain)
        do {
            _ = try await OmnixTelegramService.configure(token: token, userID: 123456789, api: uncertainAPI)
            failures.append("Telegram invented confirmation for a lost acknowledgement")
        } catch {}
        do { _ = try await OmnixTelegramService.status(api: uncertainAPI) }
        catch { failures.append("Telegram could not read status after uncertain submission") }
        if TelegramFixtureProtocol.finish(uncertain).map(\.method) != ["POST", "GET"] {
            failures.append("Telegram automatically replayed an uncertain mutation")
        }
        return failures
    }

    private static func client(_ host: String) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TelegramFixtureProtocol.self]; config.httpCookieStorage = nil; config.urlCache = nil
        return APIClient(configuration: AppConfiguration(apiBaseURL: URL(string: "https://" + host)!), testingSession: URLSession(configuration: config))
    }
}

private final class TelegramFixtureProtocol: URLProtocol, @unchecked Sendable {
    enum Step { case response(Data), timeout }
    struct Call { let method: String; let path: String; let query: String?; let body: Data? }
    private struct Scenario { var steps: [Step]; var calls: [Call] = [] }
    private final class State: @unchecked Sendable { let lock = NSLock(); var scenarios: [String: Scenario] = [:] }
    private static let state = State()
    static func scenario(_ steps: [Step]) -> String {
        let host = UUID().uuidString.lowercased() + ".telegram-fixture.invalid"
        state.lock.lock(); defer { state.lock.unlock() }
        state.scenarios[host] = Scenario(steps: steps)
        return host
    }
    static func finish(_ host: String) -> [Call] {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.scenarios.removeValue(forKey: host)?.calls ?? []
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".telegram-fixture.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while bytes.count < 10_000 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
            body = bytes
        }
        let step: Step
        Self.state.lock.lock()
        if let host = request.url?.host, var row = Self.state.scenarios[host] {
            row.calls.append(Call(method: request.httpMethod ?? "", path: request.url?.path ?? "", query: request.url?.query, body: body))
            step = row.steps.isEmpty ? .timeout : row.steps.removeFirst()
            Self.state.scenarios[host] = row
        } else { step = .timeout }
        Self.state.lock.unlock()
        switch step {
        case .timeout: client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case .response(let bytes):
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
#endif
