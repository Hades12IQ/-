import Foundation

extension AgentJob {
    /// The persisted mission card: ```` ```firas-agent ```` around the public surface JSON.
    ///
    /// A message that does not start with the fence is an ordinary markdown answer. When the JSON
    /// was truncated by the content cap, the first complete top-level object is brace-matched out.
    static func parseFence(_ markdown: String) -> AgentJob? {
        guard let fence = FirasFence.firstFence(in: markdown), fence.name == "firas-agent" else { return nil }
        return decodeBody(fence.body)
    }

    /// The fence body (or a bare JSON object) decoded into a job.
    static func decodeBody(_ body: String) -> AgentJob? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let job = try? JSONDecoder().decode(AgentJob.self, from: data) {
            return job
        }
        guard let repaired = firstBalancedObject(in: trimmed),
              let data = repaired.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentJob.self, from: data)
    }

    /// The first complete `{…}` in `text`, honouring strings and escapes.
    private static func firstBalancedObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = inString
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The mission card written back into a chat message.
    func encodedFence() -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "```firas-agent\n" + json + "\n```"
    }
}

/// The 409 `agent_busy` / 429 `credits_reserved` body: the mission already running and the ledger.
struct AgentBusyResponse: Sendable, Equatable {
    let activeJob: AgentActiveJob?
    let credits: AgentCredits?

    init(activeJob: AgentActiveJob?, credits: AgentCredits?) {
        self.activeJob = activeJob
        self.credits = credits
    }

    /// Built from the refusal the API client already decoded.
    init(server: ServerError) {
        activeJob = server.activeJob
        credits = server.credits
    }
}

/// `GET /api/agent/job` answers `{job: <view>}` or `{job: null}` for an expired id.
struct AgentJobEnvelope: Decodable, Sendable {
    let job: AgentJob?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        job = LenientJSON.nested(container, "job", as: AgentJob.self)
    }
}
