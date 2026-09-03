import Foundation

/// One file the user attached, already turned into what a turn can actually carry.
///
/// The processing (ImageIO downsampling, text extraction, budgets) happens in
/// `Features/Chat/ChatAttachmentProcessor`; this is only the result it hands to the store, so the
/// store never sees a `UIImage`, a `URL` or a 48-megapixel original.
///
/// `imageBase64` is raw base64 without the `data:` prefix — the shape `POST /api/chat` expects —
/// while `thumbnailDataURL` is the small data URL that is allowed to be persisted (`imageThumbs`,
/// ≤ 6 per message). Full images are never stored anywhere.
struct PreparedAttachment: Sendable, Equatable {
    let name: String
    /// A coarse label for the chip: `image`, `pdf`, `docx`, `text`, …
    let kind: String
    /// Extracted text for a document; nil for a picture.
    let text: String?
    /// Raw base64 of a picture, no data-URL prefix; nil for a document.
    let imageBase64: String?
    /// A small `data:image/…` URL safe to persist.
    let thumbnailDataURL: String?
    let byteCount: Int
    /// True when the extracted text was cut to fit the request budget.
    let truncated: Bool

    init(
        name: String,
        kind: String,
        text: String? = nil,
        imageBase64: String? = nil,
        thumbnailDataURL: String? = nil,
        byteCount: Int = 0,
        truncated: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.text = text
        self.imageBase64 = imageBase64
        self.thumbnailDataURL = thumbnailDataURL
        self.byteCount = byteCount
        self.truncated = truncated
    }

    var isImage: Bool { !(imageBase64?.isEmpty ?? true) }
}

extension Strings {

    /// Copy the conversation stores speak with. Screen copy lives in `Strings.Chat`; these are the
    /// few sentences a store produces on its own — a default title, an undo toast, the two
    /// instruction turns the app writes on the user's behalf.
    enum ChatStoreCopy {

        /// The undo toast after a conversation is removed (`web-chat-ux.md §11`).
        static let deleted = LText(ar: "تم حذف المحادثة", en: "Conversation deleted")

        /// The "Continue" action's instruction turn — the message actually sent, not the button
        /// label (`Strings.Chat.continueAnswer`).
        static let continueInstruction = LText(
            ar: "أكمل من حيث توقّفت.",
            en: "Continue from where you stopped."
        )

        /// Verbatim from the web (`web-auth-account-settings.md §5.6`, `guestMigrated`).
        static let guestMigrated = LText(
            ar: "تم نقل محادثاتك إلى حسابك ✓",
            en: "Your chats were moved to your account ✓"
        )
    }
}
