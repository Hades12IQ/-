import Foundation

/// A single user-visible string in both app languages.
///
/// The app ships no string catalogs and no SwiftUI localization keys: every piece of copy is an
/// `LText` resolved against `AppLanguage` at the call site. Arabic is always first because Arabic
/// is the product's first language.
///
/// Formatted copy keeps `%@` / `%ld` placeholders in both literals and is rendered through `fmt`,
/// never through `\(…)` interpolation inside the literal.
struct LText: Sendable, Hashable {
    let ar: String
    let en: String

    init(ar: String, en: String) {
        self.ar = ar
        self.en = en
    }

    /// `Strings.Common.ok(lang)` — the ordinary way to read a string.
    func callAsFunction(_ lang: AppLanguage) -> String {
        switch lang {
        case .arabic: return ar
        case .english: return en
        }
    }

    /// Same as `callAsFunction`, for call sites where the parentheses read badly.
    func text(_ lang: AppLanguage) -> String {
        callAsFunction(lang)
    }

    /// `String(format:)` with a `nil` locale so `%ld` always renders Latin digits.
    /// Arabic-Indic numbers are produced by `ArabicText.count` and passed in as `%@`.
    func fmt(_ lang: AppLanguage, _ args: CVarArg...) -> String {
        String(format: callAsFunction(lang), locale: nil, arguments: args)
    }

    /// Array form, for call sites that build their arguments dynamically.
    func fmt(_ lang: AppLanguage, arguments: [CVarArg]) -> String {
        String(format: callAsFunction(lang), locale: nil, arguments: arguments)
    }

    /// A copy of this string with `suffix` appended to both languages.
    func appending(_ suffix: LText) -> LText {
        LText(ar: ar + suffix.ar, en: en + suffix.en)
    }
}

/// Root namespace for every user-visible string in the app.
///
/// Each feature adds its own file as `extension Strings { enum <Feature> { … } }`; nothing here
/// depends on a feature, so `Strings.Common` is safe to use from any layer above `Models`.
enum Strings {

    /// Verbs and nouns that appear on more than one screen.
    enum Common {
        static let ok = LText(ar: "حسنًا", en: "OK")
        static let cancel = LText(ar: "إلغاء", en: "Cancel")
        static let retry = LText(ar: "إعادة المحاولة", en: "Retry")
        static let done = LText(ar: "تم", en: "Done")
        static let copy = LText(ar: "نسخ", en: "Copy")
        static let copied = LText(ar: "تم النسخ", en: "Copied")
        static let copyFailed = LText(ar: "تعذّر النسخ — جرّب مرة أخرى", en: "Copy failed — try again")
        static let share = LText(ar: "مشاركة", en: "Share")
        static let delete = LText(ar: "حذف", en: "Delete")
        static let undo = LText(ar: "تراجع", en: "Undo")
        static let later = LText(ar: "لاحقًا", en: "Later")
        static let close = LText(ar: "إغلاق", en: "Close")
        static let save = LText(ar: "حفظ", en: "Save")
        static let back = LText(ar: "رجوع", en: "Back")
        static let new = LText(ar: "جديد", en: "New")
        static let search = LText(ar: "بحث", en: "Search")
        static let settings = LText(ar: "الإعدادات", en: "Settings")
        static let stop = LText(ar: "إيقاف", en: "Stop")
        static let send = LText(ar: "إرسال", en: "Send")
        static let rename = LText(ar: "إعادة تسمية", en: "Rename")
        static let download = LText(ar: "تحميل", en: "Download")
        static let open = LText(ar: "افتحه", en: "Open it")
        static let noResults = LText(ar: "لا توجد نتائج.", en: "No results.")
    }
}
