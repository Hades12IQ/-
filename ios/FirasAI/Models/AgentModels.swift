import Foundation

nonisolated enum AgentJobPhase: String, Codable, Equatable, Sendable {
    case queued
    case run
    case done
    case fail

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "queued": self = .queued
        case "done", "completed": self = .done
        case "fail", "failed": self = .fail
        case "run", "processing", "exec": self = .run
        default: self = .run
        }
    }

    var isTerminal: Bool { self == .done || self == .fail }
}

nonisolated enum AgentPresentation: String, Codable, Equatable, Sendable {
    case task
    case conversation

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = AgentPresentation(rawValue: value) ?? .conversation
    }
}

nonisolated enum AgentStepStatus: String, Codable, Equatable, Sendable {
    case todo
    case run
    case done
    case fail

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = AgentStepStatus(rawValue: value) ?? .todo
    }
}

nonisolated struct AgentStep: Codable, Equatable, Sendable {
    let title: String
    let s: AgentStepStatus
    let kind: String?
    let out: String?
}

nonisolated struct AgentEvent: Codable, Equatable, Sendable {
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
    let at: Int64
}

nonisolated struct AgentTool: Codable, Equatable, Sendable {
    let name: String
    let arg: String
    let toolKind: String
    let action: String
    let url: String
}

nonisolated struct AgentFile: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let type: String
    let url: String

    var id: String { url }
}

nonisolated struct AgentActivity: Codable, Equatable, Sendable {
    let startedAt: Int64
    let endedAt: Int64
    let events: [AgentEvent]
    let tools: [AgentTool]
    let says: [String]
    let files: [AgentFile]
    let live: [String]
}

nonisolated struct AgentCredits: Codable, Equatable, Sendable {
    let remaining: Double
    let allowance: Double
    let used: Double
    let held: Double
    let resetAt: String
    let period: String
    let configured: Bool
}

nonisolated struct AgentJob: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let phase: AgentJobPhase
    let presentation: AgentPresentation
    let title: String
    let task: String
    let lang: String
    let steps: [AgentStep]
    let surface: AgentActivity?
    let final: String
    let error: String
    let credits: AgentCredits?
}

nonisolated struct AgentJobEnvelope: Decodable, Equatable, Sendable {
    let job: AgentJob?
}

nonisolated struct AgentArtifactDownload: Equatable, Sendable {
    let data: Data
    let mimeType: String
    let suggestedFilename: String
}
