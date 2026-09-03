import Foundation

// Firas Agent: mission snapshot, the SSE channel, the Manus credit ledger and artifact downloads.
// Wire shapes: server-agent.md §7, §8, §10.2, §12.4 (verified against server.mjs 8960-8972,
// 12100-12139, 12183-12291, 12419-12476). Missions are started through `startChatJob` with
// `kind: "agentrun"`; there is no separate start route.

extension APIClient {

    /// `GET /api/agent/job?id=` → `{ "job": … }`, or `{ "job": null }` when the record expired
    /// (6 h) or never existed. `403` means the job belongs to someone else — forget it silently.
    /// The snapshot already carries `credits`, so the ledger rarely needs its own fetch.
    func agentJob(id: String) async throws -> AgentJob? {
        let envelope = try await json(
            .get,
            "/api/agent/job",
            query: ["id": id],
            budget: .poll,
            as: AgentJobEnvelope.self
        )
        return envelope.job
    }

    /// `GET /api/agent/job-stream?id=` — SSE. Named events: `snapshot` (`{"job": …}`, the same
    /// shape as `agentJob`), `terminal` (`{"id","phase"}`, the connection closes right after) and
    /// `agent-error` (`{"error","retryable"}`). Auth and ownership are checked before the headers
    /// are committed, so a refusal arrives as ordinary JSON, not as a frame.
    func agentJobStream(id: String) -> AsyncThrowingStream<SSEFrame, Error> {
        stream(.get, "/api/agent/job-stream", query: ["id": id])
    }

    /// `GET /api/agent/credits` — the Manus ledger for the signed-in member; a guest gets a locked
    /// zero-remaining view rather than an error.
    func agentCredits() async throws -> AgentCredits {
        try await json(
            .get,
            "/api/agent/credits",
            budget: .interactive,
            as: AgentCredits.self
        )
    }

    /// `GET /api/agent/artifact?id=&index=[&download=1]` — one mission file, buffered server-side.
    /// The route rejects any query key other than these three, and it serves no ranges, so this
    /// is a plain download to a temp file the caller moves.
    func agentArtifact(
        jobID: String,
        index: Int,
        download: Bool
    ) async throws -> (url: URL, filename: String, mime: String?) {
        var query = ["id": jobID, "index": String(index)]
        if download { query["download"] = "1" }
        return try await self.download("/api/agent/artifact", query: query)
    }
}
