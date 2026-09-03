import Foundation

/// One site update. The record is bilingual by storage: `titleEn`/`bodyEn` may be empty, in which
/// case an English reader sees the Arabic original.
///
/// There is no audience, expiry or platform field — every record is for everyone, forever.
struct Announcement: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var title: String
    var body: String
    var pinned: Bool
    /// Epoch milliseconds (`ts` on the wire).
    var at: Double
    /// `/media/<name>.(mp4|webm)` — same origin, so prefix the API base — or an https URL.
    var video: String?
    /// A `data:image/…;base64,…` URL or an http(s) URL.
    var image: String?
    /// The language the original `title`/`body` are written in.
    var lang: String?
    var titleEn: String?
    var bodyEn: String?
    var by: String?
    var editedAt: Double?

    init(
        id: String,
        title: String,
        body: String,
        pinned: Bool = false,
        at: Double,
        video: String? = nil,
        image: String? = nil,
        lang: String? = "ar",
        titleEn: String? = nil,
        bodyEn: String? = nil,
        by: String? = nil,
        editedAt: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.pinned = pinned
        self.at = at
        self.video = video
        self.image = image
        self.lang = lang
        self.titleEn = titleEn
        self.bodyEn = bodyEn
        self.by = by
        self.editedAt = editedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = LenientJSON.string(container, "id") ?? ""
        title = LenientJSON.string(container, "title") ?? ""
        body = LenientJSON.string(container, "body") ?? ""
        pinned = LenientJSON.bool(container, "pinned") ?? false
        at = LenientJSON.double(container, "ts") ?? LenientJSON.double(container, "at") ?? 0
        video = LenientJSON.string(container, "video")
        image = LenientJSON.string(container, "image")
        lang = LenientJSON.string(container, "lang")
        titleEn = LenientJSON.string(container, "titleEn")
        bodyEn = LenientJSON.string(container, "bodyEn")
        by = LenientJSON.string(container, "by")
        editedAt = LenientJSON.double(container, "editedTs") ?? LenientJSON.double(container, "editedAt")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(title, forKey: AnyCodingKey("title"))
        try container.encode(body, forKey: AnyCodingKey("body"))
        try container.encodeIfPresent(titleEn, forKey: AnyCodingKey("titleEn"))
        try container.encodeIfPresent(bodyEn, forKey: AnyCodingKey("bodyEn"))
        try container.encode(pinned, forKey: AnyCodingKey("pinned"))
        try container.encode(at, forKey: AnyCodingKey("ts"))
        try container.encodeIfPresent(video, forKey: AnyCodingKey("video"))
        try container.encodeIfPresent(image, forKey: AnyCodingKey("image"))
        try container.encodeIfPresent(lang, forKey: AnyCodingKey("lang"))
        try container.encodeIfPresent(by, forKey: AnyCodingKey("by"))
        try container.encodeIfPresent(editedAt, forKey: AnyCodingKey("editedTs"))
    }

    var date: Date { Date(timeIntervalSince1970: at / 1000) }

    /// The record ships in the app and is never editable or deletable.
    var isBuiltin: Bool { id.hasPrefix("builtin_") }

    /// The title in the reader's language, falling back to the Arabic original.
    func localizedTitle(_ language: AppLanguage) -> String {
        guard language == .english, let titleEn, !titleEn.isEmpty else { return title }
        return titleEn
    }

    /// The body in the reader's language, falling back to the Arabic original.
    func localizedBody(_ language: AppLanguage) -> String {
        guard language == .english, let bodyEn, !bodyEn.isEmpty else { return body }
        return bodyEn
    }

    /// `BUILTIN_ANNOUNCEMENTS` — the launch post, verbatim from
    /// `brand/announcement-launch.json`. It ships in the app so it survives a database reset; it
    /// must never be POSTed, or the panel would show two copies.
    static let builtinLaunch = Announcement(
        id: "builtin_launch",
        title: "فِراس AI — منصة عربية واحدة، أربعة منتجات",
        body: """
        فِراس AI منصة ذكاء اصطناعي عربية أولاً: تكتب لها بالعربية فتفهمك بالعربية، وتردّ بلغة سؤالك.

        أربعة منتجات في مكان واحد:

        فِراس AI — المحادثة. أسئلة الدراسة والعمل والحياة، مع دعم كامل للرياضيات والمعادلات، وقراءة الصور، والإملاء الصوتي، ومكالمة صوتية مباشرة.

        فِراس Agent — الوكيل. تعطيه مهمة كبيرة فيخطّط لها، وينفّذها خطوة بخطوة، ويراجع عمله بنفسه، ثم يسلّمك النتيجة كاملة: ملفات، مستندات، أو مشاريع جاهزة.

        فِراس Code — البناء. تصف ما تريده فيبنيه لك مشروعاً كاملاً يعمل، مع معاينة حيّة داخل الموقع وتحميل الملفات دفعة واحدة.

        فِراس Brain — ملفاتك. ارفع كتبك ومستنداتك واسأل عنها، وكل معلومة في الجواب موثّقة بالصفحة التي جاءت منها.

        وأربعة مستويات للنموذج تختار بينها حسب صعوبة السؤال: ميني، برو، أولترا، وماكس.

        يصدّر أعماله بصيغ PDF وWord وExcel وPowerPoint، ويعمل بالفاتح والداكن، وبالعربية والإنجليزية.

        الموقع مجاني بالكامل. لا اشتراك ولا كود شراء — كل المزايا متاحة للجميع.
        """,
        pinned: true,
        at: 1_785_888_000_000,
        video: "/media/firas-trailer.mp4",
        image: nil,
        lang: "ar",
        titleEn: "Firas AI — one Arabic-first platform, four products",
        bodyEn: """
        Firas AI is an Arabic-first AI platform: write to it in Arabic and it understands you in Arabic, and answers in the language you asked in.

        Four products in one place:

        Firas AI — chat. Questions for study, work and everyday life, with full mathematics and equation support, image reading, voice dictation, and a live voice call.

        Firas Agent — the agent. Give it a large task and it plans, executes step by step, reviews its own work, then hands you the finished result: files, documents, or ready projects.

        Firas Code — building. Describe what you want and it builds a complete working project, with a live preview inside the site and a one-click download of every file.

        Firas Brain — your files. Upload your books and documents and ask about them, and every fact in the answer is cited to the page it came from.

        And four model tiers to choose from depending on how hard the question is: Mini, Pro, Ultra and Max.

        It exports its work as PDF, Word, Excel and PowerPoint, works in light and dark, and in Arabic and English.

        The site is completely free. No subscription and no purchase code — every feature is available to everyone.
        """,
        by: "Firas",
        editedAt: nil
    )
}

/// One remembered fact. `GET /api/memory` answers a bare array of strings, so the id is the
/// position — which is also what `DELETE /api/memory?i=` expects.
struct MemoryEntry: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var text: String
    /// Epoch milliseconds when the server sends one; it usually does not.
    var at: Double?

    init(id: String, text: String, at: Double? = nil) {
        self.id = id
        self.text = text
        self.at = at
    }

    /// The nth entry of the plain string array the server returns.
    init(index: Int, text: String) {
        id = String(index)
        self.text = text
        at = nil
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let bare = try? container.decode(String.self) {
            id = bare
            text = bare
            at = nil
            return
        }
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = LenientJSON.string(container, "id") ?? UUID().uuidString
        text = LenientJSON.string(container, "text") ?? ""
        at = LenientJSON.double(container, "at") ?? LenientJSON.double(container, "ts")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(text, forKey: AnyCodingKey("text"))
        try container.encodeIfPresent(at, forKey: AnyCodingKey("at"))
    }

    /// The index `DELETE /api/memory?i=` wants, when this entry came from the array form.
    var serverIndex: Int? { Int(id) }
}
