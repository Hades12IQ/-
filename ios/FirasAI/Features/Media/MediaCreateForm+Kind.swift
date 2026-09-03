import Foundation

// MARK: - What the form can make

/// The four things the Studio can make, as one picker.
///
/// Only the controls the pipeline actually honours are exposed (`web-media-ux.md §12.2`): a shape
/// override for images, a source for an edit, a first frame and a duration for a clip, own-lyrics
/// and a genre for a song. There is deliberately **no count control** — every route returns exactly
/// one item, and identical inputs return the cached one.
///
/// Four kinds, three `MediaKind`s: an edit is an image render on `/api/image/edit`, so it shares
/// the image quota, the image fence and the image tile. `mediaKind` is the only place that mapping
/// is written down.
///
/// It lives in its own file rather than on top of `MediaCreateForm.swift` because it is a top-level
/// type with no view state in it, and the form file is at its length budget.
enum MediaCreateKind: String, CaseIterable, Identifiable, Sendable {
    case image
    case edit
    case video
    case song

    var id: String { rawValue }

    var mediaKind: MediaKind {
        switch self {
        case .image, .edit: return .image
        case .video: return .video
        case .song: return .music
        }
    }

    var label: LText {
        switch self {
        case .image: return Strings.Media.kindImage
        case .edit: return Strings.Media.kindEdit
        case .video: return Strings.Media.kindVideo
        case .song: return Strings.Media.kindSong
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .edit: return "wand.and.stars"
        case .video: return "video"
        case .song: return "music.note"
        }
    }

    var placeholder: LText {
        switch self {
        case .image: return Strings.Media.promptPlaceholderImage
        case .edit: return Strings.Media.promptPlaceholderEdit
        case .video: return Strings.Media.promptPlaceholderVideo
        case .song: return Strings.Media.promptPlaceholderSong
        }
    }
}
