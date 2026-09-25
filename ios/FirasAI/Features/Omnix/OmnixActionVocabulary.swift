import Foundation

// Action vocabulary extracted from the shipping website, 2026-09-25.
enum OmnixActionVocabulary {
    struct Rule { let kind: String; let match: String; let input: String?; let file: String?; let ar: [String]; let en: [String] }
    static let rules: [Rule] = [
        Rule(kind: #"verify"#, match: #"^(execute_code|run_python|python|code_interpreter|shell|bash|run_command|terminal|execute_command)$"#, input: #"documents\.py\s+verify\b|deliverable-audit\.py|(?:^|[;&|(]\s*|\$\(\s*)(?:pdfinfo|pdftotext)\s"#, file: #"output"#, ar: [#"يفحص {}"#, #"فحص {}"#, #"فشل فحص {}"#], en: [#"Checking {}"#, #"Checked {}"#, #"Check failed for {}"#]),
        Rule(kind: #"code"#, match: #"^(execute_code|run_python|python|code_interpreter|shell|bash|run_command|terminal|execute_command)$"#, input: #"documents\.py\s+create\b"#, file: #"output"#, ar: [#"ينشئ {}"#, #"أنشأ {}"#, #"تعذّر إنشاء {}"#], en: [#"Creating {}"#, #"Created {}"#, #"Could not create {}"#]),
        Rule(kind: #"readFile"#, match: #"^(execute_code|run_python|python|code_interpreter|shell|bash|run_command|terminal|execute_command)$"#, input: #"documents\.py\s+inspect\b|(?:^|[;&|(]\s*|\$\(\s*)(?:pdfinfo|pdftotext)\s"#, file: #"any"#, ar: [#"يقرأ {}"#, #"قرأ {}"#, #"تعذّرت قراءة {}"#], en: [#"Reading {}"#, #"Read {}"#, #"Could not read {}"#]),
        Rule(kind: #"run"#, match: #"^(execute_code|run_python|python|code_interpreter|shell|bash|run_command|terminal|execute_command)$"#, input: nil, file: nil, ar: [#"يشغّل {}"#, #"شغّل {}"#, #"فشل تشغيل {}"#], en: [#"Running {}"#, #"Ran {}"#, #"Failed running {}"#]),
        Rule(kind: #"readFile"#, match: #"(^|_)(read|open|cat|view|fetch_file)($|_)|read_file|file_read"#, input: nil, file: nil, ar: [#"يقرأ {}"#, #"قرأ {}"#, #"تعذّرت قراءة {}"#], en: [#"Reading {}"#, #"Read {}"#, #"Could not read {}"#]),
        Rule(kind: #"code"#, match: #"(^|_)(write|create|save)($|_)|write_file|file_write|save_file"#, input: nil, file: nil, ar: [#"يكتب {}"#, #"كتب {}"#, #"تعذّرت كتابة {}"#], en: [#"Writing {}"#, #"Wrote {}"#, #"Could not write {}"#]),
        Rule(kind: #"code"#, match: #"edit|patch|replace|update_file|str_replace"#, input: nil, file: nil, ar: [#"يعدّل {}"#, #"عدّل {}"#, #"تعذّر تعديل {}"#], en: [#"Editing {}"#, #"Edited {}"#, #"Could not edit {}"#]),
        Rule(kind: #"search"#, match: #"search|grep|find|lookup|query"#, input: nil, file: nil, ar: [#"يبحث عن {}"#, #"بحث عن {}"#, #"فشل البحث عن {}"#], en: [#"Searching {}"#, #"Searched {}"#, #"Search failed for {}"#]),
        Rule(kind: #"page"#, match: #"browser|navigate|page|screenshot|visit"#, input: nil, file: nil, ar: [#"يفتح {}"#, #"فتح {}"#, #"تعذّر فتح {}"#], en: [#"Opening {}"#, #"Opened {}"#, #"Could not open {}"#]),
        Rule(kind: #"page"#, match: #"download|http|curl|request|scrape"#, input: nil, file: nil, ar: [#"يجلب {}"#, #"جلب {}"#, #"تعذّر جلب {}"#], en: [#"Fetching {}"#, #"Fetched {}"#, #"Could not fetch {}"#]),
        Rule(kind: #"share"#, match: #"upload|send_file|deliver|attach"#, input: nil, file: nil, ar: [#"يسلّم {}"#, #"سلّم {}"#, #"تعذّر تسليم {}"#], en: [#"Delivering {}"#, #"Delivered {}"#, #"Could not deliver {}"#]),
        Rule(kind: #"speak"#, match: #"speech|transcribe|speak|voice|tts|stt"#, input: nil, file: nil, ar: [#"يفرّغ {}"#, #"فرّغ {}"#, #"تعذّر تفريغ {}"#], en: [#"Transcribing {}"#, #"Transcribed {}"#, #"Could not transcribe {}"#]),
        Rule(kind: #"imageGen"#, match: #"image|photo|render|draw|video|audio"#, input: nil, file: nil, ar: [#"ينتج {}"#, #"أنتج {}"#, #"تعذّر إنتاج {}"#], en: [#"Producing {}"#, #"Produced {}"#, #"Could not produce {}"#]),
        Rule(kind: #"plan"#, match: #"plan|todo|task_list"#, input: nil, file: nil, ar: [#"يخطّط الخطوات"#, #"خطّط الخطوات"#, #"تعذّر التخطيط"#], en: [#"Planning the steps"#, #"Planned the steps"#, #"Could not plan"#]),
        Rule(kind: #"memSave"#, match: #"memory|remember|note"#, input: nil, file: nil, ar: [#"يحفظ ملاحظة"#, #"حفظ ملاحظة"#, #"تعذّر حفظ الملاحظة"#], en: [#"Saving a note"#, #"Saved a note"#, #"Could not save the note"#]),
        Rule(kind: #"deleteFile"#, match: #"delete|remove|rm_|unlink"#, input: nil, file: nil, ar: [#"يحذف {}"#, #"حذف {}"#, #"تعذّر حذف {}"#], en: [#"Deleting {}"#, #"Deleted {}"#, #"Could not delete {}"#]),
    ]
}
