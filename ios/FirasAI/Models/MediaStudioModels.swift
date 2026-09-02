import Foundation

nonisolated enum MediaStudioKind: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case image
    case video
    case music

    var id: String { rawValue }
}

nonisolated struct MediaPresentationRequest: Equatable, Sendable {
    let kind: MediaStudioKind
    let focusedJobID: String?

    init(kind: MediaStudioKind, focusedJobID: String? = nil) {
        self.kind = kind
        self.focusedJobID = focusedJobID
    }
}

nonisolated enum MediaJobPhase: String, Codable, Equatable, Sendable {
    case preparing
    case queued
    case running
    case completed
    case failed

    var isActive: Bool {
        self == .preparing || self == .queued || self == .running
    }

    var isTerminal: Bool { self == .completed || self == .failed }
}

nonisolated enum ImageAspectPreset: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case square
    case portrait
    case landscape
    case story
    case banner
    case cover

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .square: 1_024
        case .portrait: 1_024
        case .landscape: 1_280
        case .story: 720
        case .banner: 1_280
        case .cover: 1_280
        }
    }

    var height: Int {
        switch self {
        case .square: 1_024
        case .portrait: 1_280
        case .landscape: 720
        case .story: 1_280
        case .banner: 640
        case .cover: 853
        }
    }

    var ratio: Double { Double(width) / Double(height) }
}

nonisolated struct MediaImageJobRequest: Encodable, Equatable, Sendable {
    let prompt: String
    let w: Int
    let h: Int
}

nonisolated struct MediaVideoJobRequest: Encodable, Equatable, Sendable {
    let prompt: String
    let seconds: Int
}

nonisolated struct MediaMusicJobRequest: Encodable, Equatable, Sendable {
    let prompt: String
    let lyrics: String
    let seconds: Int
}

nonisolated struct MediaJobStartResponse: Decodable, Equatable, Sendable {
    let ok: Bool?
    let jobId: String
    let phase: String?
    let key: String?
}

nonisolated struct MediaJobStatusResponse: Decodable, Equatable, Sendable {
    let phase: String
    let key: String?
    let error: String?
    let reason: String?

    var resolvedError: String? { error ?? reason }
}

nonisolated struct MediaCreation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let ownerID: String
    let kind: MediaStudioKind
    let prompt: String
    let lyrics: String?
    let aspect: ImageAspectPreset?
    let seconds: Int?
    let createdAt: Date
    var updatedAt: Date
    var phase: MediaJobPhase
    var jobID: String?
    var resultKey: String?
    var localFileURL: URL?
    var errorCode: String?

    init(
        id: UUID = UUID(),
        ownerID: String,
        kind: MediaStudioKind,
        prompt: String,
        lyrics: String? = nil,
        aspect: ImageAspectPreset? = nil,
        seconds: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        phase: MediaJobPhase = .preparing,
        jobID: String? = nil,
        resultKey: String? = nil,
        localFileURL: URL? = nil,
        errorCode: String? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.kind = kind
        self.prompt = prompt
        self.lyrics = lyrics
        self.aspect = aspect
        self.seconds = seconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.phase = phase
        self.jobID = jobID
        self.resultKey = resultKey
        self.localFileURL = localFileURL
        self.errorCode = errorCode
    }
}
