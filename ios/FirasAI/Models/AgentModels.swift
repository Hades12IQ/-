import Foundation

/// The phase of a mission as `agentJobViewPayload` reports it. The server's own synonyms
/// (`completed`, `failed`, `processing`, `exec`) fold into the four the client draws.
enum AgentJobPhase: String, Codable, Sendable, Equatable {
    case queued
    case run
    case done
    case fail

    init(raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "queued", "pending": self = .queued
        case "done", "completed", "complete": self = .done
        case "fail", "failed", "error", "stopped", "cancelled", "canceled": self = .fail
        default: self = .run
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(raw: (try? container.decode(String.self)) ?? "")
    }

    var isTerminal: Bool { self == .done || self == .fail }

    var jobPhase: JobPhase {
        switch self {
        case .queued: return .queued
        case .run: return .processing
        case .done: return .completed
        case .fail: return .failed
        }
    }
}

/// `task` draws the plan card; `conversation` is a greeting or a direct answer and renders as an
/// ordinary assistant bubble.
enum AgentPresentation: String, Codable, Sendable, Equatable {
    case task
    case conversation

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = AgentPresentation(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .conversation
    }
}

/// One step's state.
enum AgentStepStatus: String, Codable, Sendable, Equatable {
    case todo
    case run
    case done
    case fail

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = AgentStepStatus(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .todo
    }
}

/// One row of the plan. `kind` is always `"write"` on the server path and `out` is always empty —
/// the deliverable is `AgentJob.final`, never per-step text.
struct AgentStep: Codable, Sendable, Equatable {
    let title: String
    let s: AgentStepStatus
    let kind: String?
    let out: String?

    init(title: String, s: AgentStepStatus, kind: String? = nil, out: String? = nil) {
        self.title = title
        self.s = s
        self.kind = kind
        self.out = out
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        title = LenientJSON.string(container, "title") ?? ""
        s = AgentStepStatus(rawValue: LenientJSON.string(container, "s") ?? "") ?? .todo
        kind = LenientJSON.string(container, "kind")
        out = LenientJSON.string(container, "out")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(title, forKey: AnyCodingKey("title"))
        try container.encode(s.rawValue, forKey: AnyCodingKey("s"))
        try container.encodeIfPresent(kind, forKey: AnyCodingKey("kind"))
        try container.encodeIfPresent(out, forKey: AnyCodingKey("out"))
    }
}

/// One narration line. `kind` is `status`, `message` or `tool`; `plan` events never reach a client.
struct AgentEvent: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let kind: String
    let text: String
    let name: String
    let arg: String
    let toolKind: String
    let action: String
    let status: String
    let url: String
    let step: Int
    /// Epoch milliseconds.
    let at: Double

    init(
        id: String,
        kind: String = "",
        text: String = "",
        name: String = "",
        arg: String = "",
        toolKind: String = "",
        action: String = "",
        status: String = "",
        url: String = "",
        step: Int = -1,
        at: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.name = name
        self.arg = arg
        self.toolKind = toolKind
        self.action = action
        self.status = status
        self.url = url
        self.step = step
        self.at = at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let decodedID = LenientJSON.string(container, "id") ?? ""
        id = decodedID.isEmpty ? UUID().uuidString : decodedID
        kind = LenientJSON.string(container, "kind") ?? ""
        text = LenientJSON.string(container, "text") ?? ""
        name = LenientJSON.string(container, "name") ?? ""
        arg = LenientJSON.string(container, "arg") ?? ""
        toolKind = LenientJSON.string(container, "toolKind") ?? ""
        action = LenientJSON.string(container, "action") ?? ""
        status = LenientJSON.string(container, "status") ?? ""
        url = LenientJSON.string(container, "url") ?? ""
        step = LenientJSON.int(container, "step") ?? -1
        at = LenientJSON.double(container, "at") ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(kind, forKey: AnyCodingKey("kind"))
        try container.encode(text, forKey: AnyCodingKey("text"))
        try container.encode(name, forKey: AnyCodingKey("name"))
        try container.encode(arg, forKey: AnyCodingKey("arg"))
        try container.encode(toolKind, forKey: AnyCodingKey("toolKind"))
        try container.encode(action, forKey: AnyCodingKey("action"))
        try container.encode(status, forKey: AnyCodingKey("status"))
        try container.encode(url, forKey: AnyCodingKey("url"))
        try container.encode(step, forKey: AnyCodingKey("step"))
        try container.encode(at, forKey: AnyCodingKey("at"))
    }
}

/// One entry of the tool strip.
struct AgentTool: Codable, Sendable, Equatable {
    let name: String
    let arg: String
    let toolKind: String
    let action: String
    let url: String

    init(name: String = "", arg: String = "", toolKind: String = "", action: String = "", url: String = "") {
        self.name = name
        self.arg = arg
        self.toolKind = toolKind
        self.action = action
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = LenientJSON.string(container, "name") ?? ""
        arg = LenientJSON.string(container, "arg") ?? ""
        toolKind = LenientJSON.string(container, "toolKind") ?? ""
        action = LenientJSON.string(container, "action") ?? ""
        url = LenientJSON.string(container, "url") ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(name, forKey: AnyCodingKey("name"))
        try container.encode(arg, forKey: AnyCodingKey("arg"))
        try container.encode(toolKind, forKey: AnyCodingKey("toolKind"))
        try container.encode(action, forKey: AnyCodingKey("action"))
        try container.encode(url, forKey: AnyCodingKey("url"))
    }
}

/// A file the mission produced. `url` is always the same-origin artifact route; the index inside it
/// is the position in the server's **internal** list and must never be recomputed from the array.
struct AgentFile: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let type: String
    let url: String

    var id: String { url }

    init(name: String = "", type: String = "", url: String = "") {
        self.name = name
        self.type = type
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = LenientJSON.string(container, "name") ?? ""
        type = LenientJSON.string(container, "type") ?? ""
        url = LenientJSON.string(container, "url") ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(name, forKey: AnyCodingKey("name"))
        try container.encode(type, forKey: AnyCodingKey("type"))
        try container.encode(url, forKey: AnyCodingKey("url"))
    }
}

extension AgentFile {
    /// The `index=` query value of `url`. The public file list can have gaps, so this is the only
    /// correct index to pass to `/api/agent/artifact`.
    var artifactIndex: Int? {
        guard let components = URLComponents(string: url) else { return nil }
        guard let raw = components.queryItems?.first(where: { $0.name == "index" })?.value else { return nil }
        return Int(raw)
    }

    /// The `id=` query value of `url` — the job key the artifact belongs to.
    var artifactJobID: String? {
        guard let components = URLComponents(string: url) else { return nil }
        return components.queryItems?.first(where: { $0.name == "id" })?.value
    }
}

/// The mission's live surface: what it said, what it used, what it made.
struct AgentActivity: Codable, Sendable, Equatable {
    /// Epoch milliseconds; `endedAt` stays 0 until the mission is terminal.
    let startedAt: Double
    let endedAt: Double
    let events: [AgentEvent]
    let tools: [AgentTool]
    let says: [String]
    let files: [AgentFile]
    let live: [String]

    init(
        startedAt: Double = 0,
        endedAt: Double = 0,
        events: [AgentEvent] = [],
        tools: [AgentTool] = [],
        says: [String] = [],
        files: [AgentFile] = [],
        live: [String] = []
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.events = events
        self.tools = tools
        self.says = says
        self.files = files
        self.live = live
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        startedAt = LenientJSON.double(container, "startedAt") ?? 0
        endedAt = LenientJSON.double(container, "endedAt") ?? 0
        events = LenientJSON.array(container, "events", of: AgentEvent.self) ?? []
        tools = LenientJSON.array(container, "tools", of: AgentTool.self) ?? []
        says = LenientJSON.array(container, "says", of: String.self) ?? []
        files = LenientJSON.array(container, "files", of: AgentFile.self) ?? []
        live = LenientJSON.array(container, "live", of: String.self) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(startedAt, forKey: AnyCodingKey("startedAt"))
        try container.encode(endedAt, forKey: AnyCodingKey("endedAt"))
        try container.encode(events, forKey: AnyCodingKey("events"))
        try container.encode(tools, forKey: AnyCodingKey("tools"))
        try container.encode(says, forKey: AnyCodingKey("says"))
        try container.encode(files, forKey: AnyCodingKey("files"))
        try container.encode(live, forKey: AnyCodingKey("live"))
    }
}

/// `manusCreditView(user)`. `held` is "reserved for the running task", never "spent" — a running
/// mission normally holds everything, so `remaining` reads 0 while it runs.
struct AgentCredits: Codable, Sendable, Equatable {
    let remaining: Double
    let allowance: Double
    let used: Double
    let held: Double
    /// ISO-8601 UTC of the next Baghdad-local midnight.
    let resetAt: String
    let period: String
    /// `false` means `MANUS_API_KEY` is unset and every mission will fail.
    let configured: Bool
    let guest: Bool
    let locked: Bool

    init(
        remaining: Double = 0,
        allowance: Double = 0,
        used: Double = 0,
        held: Double = 0,
        resetAt: String = "",
        period: String = "daily",
        configured: Bool = false,
        guest: Bool = false,
        locked: Bool = false
    ) {
        self.remaining = remaining
        self.allowance = allowance
        self.used = used
        self.held = held
        self.resetAt = resetAt
        self.period = period
        self.configured = configured
        self.guest = guest
        self.locked = locked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        remaining = LenientJSON.double(container, "remaining") ?? 0
        allowance = LenientJSON.double(container, "allowance") ?? 0
        used = LenientJSON.double(container, "used") ?? 0
        held = LenientJSON.double(container, "held") ?? 0
        resetAt = LenientJSON.string(container, "resetAt") ?? ""
        period = LenientJSON.string(container, "period") ?? "daily"
        configured = LenientJSON.bool(container, "configured") ?? false
        guest = LenientJSON.bool(container, "guest") ?? false
        locked = LenientJSON.bool(container, "locked") ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(remaining, forKey: AnyCodingKey("remaining"))
        try container.encode(allowance, forKey: AnyCodingKey("allowance"))
        try container.encode(used, forKey: AnyCodingKey("used"))
        try container.encode(held, forKey: AnyCodingKey("held"))
        try container.encode(resetAt, forKey: AnyCodingKey("resetAt"))
        try container.encode(period, forKey: AnyCodingKey("period"))
        try container.encode(configured, forKey: AnyCodingKey("configured"))
        try container.encode(guest, forKey: AnyCodingKey("guest"))
        try container.encode(locked, forKey: AnyCodingKey("locked"))
    }
}

/// One snapshot of a mission — `agentJobViewPayload`, and the body of the ```` ```firas-agent ````
/// fence the finished turn is persisted as.
struct AgentJob: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let phase: AgentJobPhase
    let presentation: AgentPresentation
    let title: String
    let task: String
    let lang: String
    let steps: [AgentStep]
    let surface: AgentActivity?
    /// Non-empty only when `phase == .done`.
    let final: String
    /// Non-empty only when `phase == .fail`.
    let error: String
    let credits: AgentCredits?

    init(
        id: String,
        phase: AgentJobPhase = .run,
        presentation: AgentPresentation = .task,
        title: String = "",
        task: String = "",
        lang: String = "ar",
        steps: [AgentStep] = [],
        surface: AgentActivity? = nil,
        final: String = "",
        error: String = "",
        credits: AgentCredits? = nil
    ) {
        self.id = id
        self.phase = phase
        self.presentation = presentation
        self.title = title
        self.task = task
        self.lang = lang
        self.steps = steps
        self.surface = surface
        self.final = final
        self.error = error
        self.credits = credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = LenientJSON.string(container, "id") ?? ""
        phase = AgentJobPhase(raw: LenientJSON.string(container, "phase") ?? "")
        if let raw = LenientJSON.string(container, "presentation") {
            presentation = AgentPresentation(rawValue: raw.lowercased()) ?? .conversation
        } else {
            presentation = .task
        }
        title = LenientJSON.string(container, "title") ?? ""
        task = LenientJSON.string(container, "task") ?? ""
        lang = LenientJSON.string(container, "lang") ?? "ar"
        steps = LenientJSON.array(container, "steps", of: AgentStep.self) ?? []
        surface = LenientJSON.nested(container, "surface", as: AgentActivity.self)
        final = LenientJSON.string(container, "final") ?? ""
        error = LenientJSON.string(container, "error") ?? ""
        credits = LenientJSON.nested(container, "credits", as: AgentCredits.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(phase.rawValue, forKey: AnyCodingKey("phase"))
        try container.encode(presentation.rawValue, forKey: AnyCodingKey("presentation"))
        try container.encode(title, forKey: AnyCodingKey("title"))
        try container.encode(task, forKey: AnyCodingKey("task"))
        try container.encode(lang, forKey: AnyCodingKey("lang"))
        try container.encode(steps, forKey: AnyCodingKey("steps"))
        try container.encodeIfPresent(surface, forKey: AnyCodingKey("surface"))
        try container.encode(final, forKey: AnyCodingKey("final"))
        try container.encode(error, forKey: AnyCodingKey("error"))
        try container.encodeIfPresent(credits, forKey: AnyCodingKey("credits"))
    }

    /// Elapsed milliseconds, or nil when the surface has not been published yet.
    var elapsedMilliseconds: Double? {
        guard let surface, surface.startedAt > 0 else { return nil }
        let end = surface.endedAt > 0 ? surface.endedAt : Date().timeIntervalSince1970 * 1000
        return max(0, end - surface.startedAt)
    }

    var doneStepCount: Int { steps.filter { $0.s == .done }.count }
}
