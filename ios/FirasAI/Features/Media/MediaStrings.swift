import Foundation

enum MediaStrings {
    static let title = LocalizedStringResource("media.title", table: "Media")
    static let subtitle = LocalizedStringResource("media.subtitle", table: "Media")
    static let hero = LocalizedStringResource("media.hero", table: "Media")
    static let heroDetail = LocalizedStringResource("media.hero.detail", table: "Media")
    static let image = LocalizedStringResource("media.kind.image", table: "Media")
    static let video = LocalizedStringResource("media.kind.video", table: "Media")
    static let music = LocalizedStringResource("media.kind.music", table: "Media")
    static let prompt = LocalizedStringResource("media.prompt", table: "Media")
    static let imagePrompt = LocalizedStringResource("media.prompt.image", table: "Media")
    static let videoPrompt = LocalizedStringResource("media.prompt.video", table: "Media")
    static let musicPrompt = LocalizedStringResource("media.prompt.music", table: "Media")
    static let lyrics = LocalizedStringResource("media.lyrics", table: "Media")
    static let lyricsOptional = LocalizedStringResource("media.lyrics.optional", table: "Media")
    static let aspect = LocalizedStringResource("media.aspect", table: "Media")
    static let duration = LocalizedStringResource("media.duration", table: "Media")
    static let create = LocalizedStringResource("media.create", table: "Media")
    static let signIn = LocalizedStringResource("media.signIn", table: "Media")
    static let runningCloud = LocalizedStringResource("media.runningCloud", table: "Media")
    static let recent = LocalizedStringResource("media.recent", table: "Media")
    static let creating = LocalizedStringResource("media.creating", table: "Media")
    static let preparingResult = LocalizedStringResource("media.preparingResult", table: "Media")
    static let save = LocalizedStringResource("media.save", table: "Media")
    static let share = LocalizedStringResource("media.share", table: "Media")
    static let retry = LocalizedStringResource("media.retry", table: "Media")
    static let remove = LocalizedStringResource("media.remove", table: "Media")
    static let dismiss = LocalizedStringResource("media.dismiss", table: "Media")
    static let account = LocalizedStringResource("media.account", table: "Media")
    static let result = LocalizedStringResource("media.result", table: "Media")
    static let pausedPlayback = LocalizedStringResource("media.play", table: "Media")
    static let pausePlayback = LocalizedStringResource("media.pause", table: "Media")

    static func aspect(_ preset: ImageAspectPreset) -> LocalizedStringResource {
        switch preset {
        case .square: LocalizedStringResource("media.aspect.square", table: "Media")
        case .portrait: LocalizedStringResource("media.aspect.portrait", table: "Media")
        case .landscape: LocalizedStringResource("media.aspect.landscape", table: "Media")
        case .story: LocalizedStringResource("media.aspect.story", table: "Media")
        case .banner: LocalizedStringResource("media.aspect.banner", table: "Media")
        case .cover: LocalizedStringResource("media.aspect.cover", table: "Media")
        }
    }
}
