import Foundation

/// The web's per-project `model` / `depth` record. A turn snapshots this before any await.
struct CodeModelSelection: Codable, Sendable, Equatable {
    var model: ModelTier
    var depth: String
    init(model: ModelTier = .pro, depth: String = "standard") {
        self.model = model
        self.depth = model == .omnix ? "managed" : model != .mini && depth == "deep" ? "deep" : "standard"
    }
    var think: Bool { model != .mini && model != .omnix && depth == "deep" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.init(model: ModelTier(rawValue: LenientJSON.string(c, "model") ?? "") ?? .pro,
                  depth: LenientJSON.string(c, "depth") ?? "standard")
    }
}
