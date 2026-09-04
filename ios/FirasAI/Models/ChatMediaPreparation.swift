import Foundation

/// Transient UI state before MediaStore has placed its live card. This is not a job or an
/// assistant message: no prompt, invented progress, or temporary placeholder is persisted.
struct ChatMediaPreparation: Equatable {
    let questionID: String
    let kind: MediaKind

    func label(_ lang: AppLanguage) -> String {
        switch kind {
        case .image: return lang == .arabic ? "تجهيز الصورة…" : "Preparing the image…"
        case .video: return lang == .arabic ? "تجهيز الفيديو…" : "Preparing the video…"
        case .music: return lang == .arabic ? "يتم كتابة الأغنية…" : "Writing the song…"
        }
    }

    /// Earlier cards do not count. Only the card after this exact question replaces its status.
    func hasCard(in messages: [ChatMessage]) -> Bool {
        guard let question = messages.firstIndex(where: { $0.id == questionID && $0.role == .user }) else { return false }
        return messages[messages.index(after: question)...].contains { message in
            guard message.role == .assistant,
                  let fence = FirasFence.firstFence(in: message.content) else { return false }
            return fence.name == kind.fenceName
        }
    }

    static func unavailable(_ kind: MediaKind, lang: AppLanguage) -> String {
        switch kind {
        case .image: return lang == .arabic
            ? "صناعة الصور غير متاحة الآن. حاول لاحقاً."
            : "Image generation is unavailable right now. Try again later."
        case .video: return lang == .arabic
            ? "صناعة الفيديو غير متاحة الآن. حاول لاحقاً."
            : "Video generation is unavailable right now. Try again later."
        case .music: return lang == .arabic
            ? "صناعة الأغاني غير متاحة الآن. حاول لاحقاً."
            : "Song generation is unavailable right now. Try again later."
        }
    }
}
