import Foundation

/// The four formats authored/reviewed by the shared `officefile` cloud worker.
/// PDF deliberately belongs to the existing counted-document and server-PDF paths.
enum OfficeDocumentFormat: String, CaseIterable, Codable, Sendable {
    case docx, xlsx, pptx, csv

    static func named(_ value: String) -> OfficeDocumentFormat? {
        Self(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

enum OfficeDocumentError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest
    case sourceTooLarge
    case invalidImage
    case tooManyImages
    case invalidResult
    case wrongFormat

    var message: LText {
        switch self {
        case .sourceTooLarge:
            return LText(ar: "مصدر الملف أطول من الحد المتاح. قلّل المرفقات أو حدّد الجزء المطلوب؛ لم يبدأ إنشاء ملف ناقص.",
                         en: "The document source exceeds the available limit. Reduce attachments or choose a smaller section; no incomplete file was started.")
        case .invalidImage, .tooManyImages:
            return LText(ar: "تعذّر تجهيز صور الملف. أرفق حتى 10 صور بصيغة PNG أو JPEG أو WebP، وحاول مجددًا.",
                         en: "The document images could not be prepared. Attach up to 10 PNG, JPEG or WebP images and retry.")
        case .invalidResult, .wrongFormat:
            return LText(ar: "لم يصل ملف كامل بالتنسيق المطلوب. حدّث المحادثة للتحقق من النتيجة المحفوظة.",
                         en: "A complete document in the requested format has not arrived. Refresh the conversation to check the saved result.")
        case .invalidRequest:
            return LText(ar: "تعذّر تجهيز طلب الملف. حاول إرساله مرة أخرى.",
                         en: "The document request could not be prepared. Try sending it again.")
        }
    }

    var errorDescription: String? { message.en }
}

/// The cloud returns a canonical metadata fence followed by its complete Markdown body.
/// Keep `content` byte-for-byte: it carries design metadata the current writer may not yet use.
struct OfficeDocumentResult: Sendable {
    let format: OfficeDocumentFormat
    let meta: FileMeta
    let content: String
    let body: String
}
