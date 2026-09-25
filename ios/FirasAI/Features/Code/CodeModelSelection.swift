import Foundation

/// The web's per-project `model` / `depth` record. A turn snapshots this before any await.
struct CodeModelSelection: Codable, Sendable, Equatable {
    var gen: String = "1.1"
    var generation: ModelGeneration { .history(gen) }
    var model: ModelTier
    var depth: String
    init(model: ModelTier = .pro, depth: String = "standard", generation: ModelGeneration = .current) {
        self.gen = generation.rawValue
        self.model = model
        self.depth = model == .omnix ? "managed" : model != .mini && depth == "deep" ? "deep" : "standard"
    }
    var think: Bool { model != .mini && model != .omnix && depth == "deep" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let model = ModelTier(rawValue: LenientJSON.string(c, "model") ?? "") ?? .pro
        let gen = LenientJSON.string(c, "gen")
        self.init(model: model,
                  depth: LenientJSON.string(c, "depth") ?? "standard",
                  generation: model == .omnix && gen == nil ? .legacy : .preference(gen))
    }
}
