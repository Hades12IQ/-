import Foundation

enum SkillsCopy {
    static let title = LText(ar: "المهارات", en: "Skills")
    static let subtitle = LText(ar: "طريقتك الخاصة، بكل أدوات فراس", en: "Your way of working, across Firas")
    static let mine = LText(ar: "مهاراتي", en: "My skills")
    static let library = LText(ar: "المكتبة", en: "Library")
    static let add = LText(ar: "مهارة جديدة", en: "New skill")
    static let edit = LText(ar: "تعديل المهارة", en: "Edit skill")
    static let search = LText(ar: "ابحث عن مهارة…", en: "Search skills…")
    static let empty = LText(ar: "خلّي فراس يشتغل بطريقتك", en: "Make Firas work your way")
    static let emptyHint = LText(ar: "اكتب تعليماتك الخاصة أو أضف مهارة من المكتبة. تبقى مرتبطة بحسابك في التطبيق والموقع.", en: "Write your instructions or add a skill from the library. Your skills stay with your account in the app and on the website.")
    static let slashHint = LText(ar: "اكتب / بأي محادثة لاختيار حتى 3 مهارات معاً.", en: "Type / in any conversation to use up to 3 skills together.")
    static let auto = LText(ar: "حسب الطلب", en: "When relevant")
    static let always = LText(ar: "دائماً", en: "Always")
    static let enabled = LText(ar: "مفعّلة", en: "Enabled")
    static let disabled = LText(ar: "متوقفة", en: "Disabled")
    static let use = LText(ar: "استخدم المهارة", en: "Use skill")
    static let addFromLibrary = LText(ar: "إضافة إلى مهاراتي", en: "Add to my skills")
    static let browse = LText(ar: "تصفّح المكتبة", en: "Browse library")
    static let signIn = LText(ar: "سجّل دخولك حتى تضيف مهاراتك وتستخدم مكتبة الموقع.", en: "Sign in to add your skills and browse the website library.")
    static let noResults = LText(ar: "ماكو مهارات مطابقة", en: "No matching skills")
    static let limit = LText(ar: "تگدر تستخدم حتى 3 مهارات بنفس الرسالة.", en: "You can use up to 3 skills in one message.")
    static func problem(_ code: String, _ lang: AppLanguage) -> String {
        let parts = code.split(separator: ":")
        let index = (parts.count > 1 ? Int(parts[1]) : nil).map { $0 + 1 } ?? 1
        let text: LText
        switch String(parts.first ?? "") {
        case "name_too_short", "name_too_long": text = LText(ar: "اسم المهارة لازم يكون من 3 إلى 80 حرف.", en: "Use a skill name between 3 and 80 characters.")
        case "cues_too_few", "cues_too_many": text = LText(ar: "أضف من 3 إلى 24 عبارة توضّح متى تستخدم المهارة.", en: "Add 3–24 phrases describing when to use this skill.")
        case "cue_length": text = LText(ar: "العبارة \(index) لازم تكون من 2 إلى 60 حرف.", en: "Phrase \(index) must be 2–60 characters.")
        case "rules_too_few", "rules_too_many": text = LText(ar: "أضف من 4 إلى 24 تعليمة، كل تعليمة بسطر.", en: "Add 4–24 instructions, one per line.")
        case "rule_too_short", "rule_too_long": text = LText(ar: "التعليمة \(index) لازم تكون من 28 إلى 300 حرف.", en: "Instruction \(index) must be 28–300 characters.")
        case "rules_too_long_total": text = LText(ar: "اختصر التعليمات حتى يكون مجموعها أقل من 2600 حرف، مع علامات القائمة.", en: "Shorten the instructions to 2,600 characters total, including list markers.")
        case "forbidden_phrase", "rejected": text = LText(ar: "عدّل التعليمات: المهارة تشرح طريقة العمل، وما تغيّر الصلاحيات أو تطلب أسرار الحساب.", en: "Revise the instructions: skills describe a method, and cannot change permissions or request account secrets.")
        case "account_full": text = LText(ar: "وصلت إلى 40 مهارة. احذف مهارة حتى تضيف غيرها.", en: "You have 40 skills. Remove one before adding another.")
        case "skill_not_found": text = LText(ar: "المهارة انحذفت من الحساب. حدّث القائمة.", en: "This skill was removed. Refresh the list.")
        case "signin": text = signIn
        default: text = LText(ar: "تعذّر تحميل أو حفظ المهارات. جرّب مرة ثانية.", en: "Could not load or save skills. Please try again.")
        }
        return text(lang)
    }
}
