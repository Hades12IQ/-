import Foundation

/// Fast media intent routing for explicit requests in multiple languages. Vocabulary alone never
/// starts a paid render: the requested deliverable, action and its negation must agree. Ambiguous
/// wording stays with the normal assistant; the full original brief still reaches the media model.
enum MediaRequestIntent {
    enum Decision: Equatable {
        case media(RequestKind)
        case nonMedia
        case unresolved
    }

    static func resolve(_ text: String, hasImages: Bool) -> Decision {
        let text = normalized(String(text.prefix(8_000)))
        guard !text.isEmpty else { return .unresolved }
        let firstNoun = mediaNouns.compactMap { first($0.regex, in: text)?.location }.min()
        guard firstNoun != nil || first(drawing, in: text) != nil || first(singing, in: text) != nil
            || first(animating, in: text) != nil || (hasImages && first(editing, in: text) != nil)
        else { return .unresolved }
        if first(trailingDiscussion, in: text) != nil { return .nonMedia }
        // A request to translate/explain quoted instructions does not execute those instructions.
        if let read = first(reading, in: text), read.location < (firstNoun ?? 160) {
            return .nonMedia
        }
        var rejected = false
        var requested: RequestKind?
        // A later affirmative clause can replace a negated one: "not an image; make a song".
        for clause in text.components(separatedBy: clauseSeparators).prefix(12) where !clause.isEmpty {
            let decision = resolveClause(clause, hasImages: hasImages)
            switch decision {
            case .media(let kind): requested = kind
            case .nonMedia: rejected = true
            case .unresolved: break
            }
        }
        if let requested { return .media(requested) }
        return rejected ? .nonMedia : .unresolved
    }

    static func refersToPreviousImage(_ text: String) -> Bool {
        let text = normalized(String(text.prefix(2_000)))
        guard first(images, in: text) != nil,
              first(editing, in: text) != nil || first(transforming, in: text) != nil || first(animating, in: text) != nil
        else { return false }
        if case .nonMedia = resolve(text, hasImages: true) { return false }
        return true
    }

    private static func resolveClause(_ clause: String, hasImages: Bool) -> Decision {
        let candidates = mediaNouns.compactMap { entry -> (kind: RequestKind, range: NSRange)? in
            first(entry.regex, in: clause).map { (entry.kind, $0) }
        }.sorted { $0.range.location < $1.range.location }
        let action = first(creating, in: clause) ?? first(composingAudio, in: clause)
        let edit = first(editing, in: clause)
        let transform = first(transforming, in: clause)
        let drawing = first(drawing, in: clause)
        let singing = first(singing, in: clause)
        let motion = first(animating, in: clause)
        let firstAction = [action, edit, transform, drawing, singing, motion].compactMap { $0 }.map(\.location).min()
        let nounPosition = candidates.first?.range.location ?? 160
        if let read = first(reading, in: clause), read.location < nounPosition { return .nonMedia }
        if let negation = first(negative, in: clause),
           negation.location <= max(nounPosition, (firstAction ?? -12) + 12) {
            return .nonMedia
        }
        guard let firstAction, firstAction <= 160 else { return .unresolved }
        // Software/documents about media retain their own routes. A logo FOR an app remains an
        // image because its image noun comes first.
        if let other = first(otherDeliverables, in: clause), other.location < nounPosition { return .nonMedia }
        if let math = first(mathematicalDiagram, in: clause), math.location < nounPosition { return .nonMedia }
        if let words = first(lyrics, in: clause), words.location < nounPosition,
           transform == nil, singing == nil, first(composingAudio, in: clause) == nil {
            return .nonMedia
        }

        if motion != nil { return .media(.video) }
        if candidates.first?.kind == .music, first(musicVideo, in: clause) != nil { return .media(.video) }
        // For transformations, the destination comes after the source: image -> video, poem -> song.
        if transform != nil, let target = candidates.last,
           target.kind == .video || target.kind == .music { return .media(target.kind) }
        if hasImages, edit != nil { return .media(.imageEdit) }
        if let target = candidates.first, action != nil || transform != nil || singing != nil || drawing != nil {
            if target.kind == .image, hasImages { return .unresolved }
            return .media(target.kind)
        }
        if singing != nil { return .media(.music) }
        if drawing != nil, !hasImages { return .media(.image) }
        return .unresolved
    }

    private static let clauseSeparators = CharacterSet(charactersIn: "\n\r;；؛،,")

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ـ", with: "")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "أ", with: "ا").replacingOccurrences(of: "إ", with: "ا")
            .replacingOccurrences(of: "آ", with: "ا").replacingOccurrences(of: "ٱ", with: "ا")
            .replacingOccurrences(of: "ک", with: "ك").replacingOccurrences(of: "ی", with: "ي")
    }

    private static func matcher(_ words: [String], joined: [String] = []) -> NSRegularExpression {
        let words = words.map { NSRegularExpression.escapedPattern(for: normalized($0)) }.joined(separator: "|")
        let joined = joined.map { NSRegularExpression.escapedPattern(for: normalized($0)) }.joined(separator: "|")
        let bounded = "(?<![\\p{L}\\p{N}_])(?:" + words + ")(?![\\p{L}\\p{N}_])"
        // These are escaped, fixed application strings. No user text becomes regex syntax.
        let pattern = words.isEmpty ? "(?:" + joined + ")" : (joined.isEmpty ? bounded : bounded + "|(?:" + joined + ")")
        return try! NSRegularExpression(pattern: pattern)
    }

    private static func first(_ regex: NSRegularExpression, in text: String) -> NSRange? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.range
    }

    private static let images = matcher([
        "image", "images", "picture", "pictures", "photo", "photos", "illustration", "poster", "logo", "portrait", "wallpaper", "thumbnail",
        "صورة", "صوره", "الصورة", "الصوره", "هالصورة", "صور", "رسمة", "رسمه", "شعار", "بوستر", "خلفية", "لوحة",
        "imagen", "imágenes", "foto", "dibujo", "affiche", "dessin", "photographie", "immagine", "disegno", "imagem", "desenho",
        "bild", "bilder", "zeichnung", "resim", "görsel", "fotoğraf", "изображение", "картинку", "картинка", "фото", "рисунок",
        "عکس", "تصویر", "وێنە", "وێنه", "وێنەیەک", "وێنه‌یه‌ک", "تصویر", "تصویریں", "चित्र", "तस्वीर", "gambar", "picha", "afbeelding", "zdjęcie"
    ], joined: ["图片", "圖像", "照片", "画像", "イラスト", "이미지", "그림", "รูปภาพ"])
    private static let videos = matcher([
        "video", "clip", "movie", "animation", "reel", "trailer", "فيديو", "فديو", "الفيديو", "ڤيديو", "مقطع", "كليب", "انيميشن",
        "vídeo", "vidéo", "film", "película", "videoclip", "видео", "ролик", "видеоролик", "ویدیو", "ویدئو", "ڤیدیۆ", "ویڈیو",
        "वीडियो", "चलचित्र", "wideo", "filmpje", "videon"
    ], joined: ["视频", "影片", "動畫", "動画", "ビデオ", "동영상", "비디오", "วิดีโอ"])
    private static let songs = matcher([
        "song", "music", "anthem", "lullaby", "rap", "jingle", "اغنية", "اغنيه", "الاغنية", "اغاني", "موسيقى", "موسيقا", "لطمية", "نشيد", "انشودة",
        "canción", "música", "chanson", "musique", "canzone", "musica", "canção", "lied", "musik", "şarkı", "müzik",
        "песню", "песня", "музыку", "музыка", "آهنگ", "موسیقی", "گۆرانی", "گورانی", "گۆرانییەک", "گۆرانیەک", "گانا", "گیت", "गाना", "गीत", "संगीत",
        "lagu", "musik", "wimbo", "liedje", "piosenkę", "muzykę"
    ], joined: ["歌曲", "首歌", "音乐", "音樂", "歌を", "曲を", "歌って", "노래", "음악", "เพลง"])
    private static let mediaNouns: [(kind: RequestKind, regex: NSRegularExpression)] = [
        (.image, images), (.video, videos), (.music, songs)
    ]
    private static let creating = matcher([
        "make", "create", "generate", "produce", "render", "design", "write", "compose", "want", "need", "give me",
        "اصنع", "اصنعلي", "انشئ", "سوي", "سويلي", "سوّيلي", "تسوي", "تسويلي", "تصنع", "اعمل", "اعملي", "اريد", "ابي", "بدي", "اكتب", "اكتبلي", "ولد", "صمم", "صمملي", "انطيني", "هات", "جهز",
        "crea", "crear", "genera", "generar", "haz", "quiero", "dame", "escribe", "crée", "créer", "génère", "générer", "fais", "écris", "veux", "souhaite",
        "creare", "genera", "scrivi", "voglio", "crie", "gere", "faça", "quero", "escreva", "erstelle", "erzeuge", "generiere", "schreibe", "möchte",
        "oluştur", "üret", "yap", "yaz", "istiyorum", "сделай", "создай", "сгенерируй", "напиши", "хочу",
        "بساز", "بسازید", "بکش", "میخواهم", "بنویس", "بکە", "بکەوە", "دروست", "دەوێت", "بناؤ", "بنائیں", "چاہیے", "لکھو", "बनाओ", "बनाइए", "लिखो", "चाहिए",
        "buat", "buatkan", "bikin", "ingin", "tengeneza", "nataka", "maak", "genereer", "stwórz", "wygeneruj", "napisz"
    ], joined: ["生成", "制作", "製作", "创建", "創建", "画", "畫", "写一", "寫一", "作って", "作成", "生成して", "描いて", "만들어", "생성해", "그려", "สร้าง", "ทำให้"])
    private static let drawing = matcher(["draw", "paint", "ارسم", "ارسملي", "dibuja", "dessine", "dessinez", "disegna", "desenhe", "zeichne", "çiz", "нарисуй", "بکش"], joined: ["描いて", "画一", "畫一", "그려줘", "วาด"])
    private static let singing = matcher(["sing", "غنيلي", "غنيلنا", "غني", "لحّن", "لحن", "canta", "chante", "singe", "bestele", "спой", "بخوان", "بخون", "گاؤ", "गाओ", "nyanyikan"], joined: ["歌って", "唱一", "불러줘"])
    private static let composingAudio = matcher(["compose", "componer", "compose", "componi", "componha", "komponiere", "bestele", "لحن", "لحّن", "آهنگسازی"], joined: ["作曲", "谱曲", "譜曲", "작곡"])
    private static let animating = matcher(["animate", "حرّك", "حرك", "حركلي", "حركها", "anima", "anime", "animez", "animiere", "canlandır", "анимируй", "оживи"], joined: ["動かして", "动起来", "動起來", "움직이게"])
    private static let transforming = matcher(["convert", "turn", "transform", "حول", "حوّل", "حوّلها", "اجعل", "خلي", "convierte", "transforma", "convertis", "transforme", "trasforma", "transforme", "wandle", "verwandle", "dönüştür", "преврати", "تبدیل", "بگۆڕە", "بدل", "बदलो", "ubah"], joined: ["变成", "變成", "にして", "로 바꿔"])
    private static let editing = matcher(["edit", "modify", "change", "remove", "crop", "resize", "retouch", "upscale", "عدّل", "عدل", "غيّر", "غير", "ضيف", "اضف", "احذف", "شيل", "قص", "حسن", "edita", "modifica", "cambia", "modifie", "retouche", "supprime", "ritocca", "bearbeite", "ändere", "düzenle", "değiştir", "измени", "отредактируй", "ویرایش", "دەستکاری", "ترمیم", "संपादित", "perbaiki"], joined: ["修改", "编辑", "編輯", "編集して", "수정해", "แก้ไข"])
    private static let negative = matcher(["not", "don't", "do not", "never", "no", "لا", "ما", "لاتسوي", "لاتسويلي", "لاتصنع", "لاتصنعلي", "لااريد", "مو", "بدون", "ne", "pas", "aucun", "non", "não", "nicht", "kein", "keine", "не", "нет", "نه", "نساز", "نەکە", "مەکە", "مت", "نہیں", "नहीं", "मत", "jangan", "bukan", "niet", "geen", "nie", "oluşturma", "yapma"], joined: ["不要", "别生成", "別生成", "作らない", "生成しない", "만들지", "생성하지", "อย่า"])
    private static let reading = matcher([
        "translate", "explain", "summarize", "summarise", "describe", "meaning", "who", "what", "why", "how", "which", "recommend", "learn", "understand", "tell me about",
        "ترجم", "اشرح", "اشرحلي", "وضح", "لخص", "شنو", "شلون", "كيف", "لماذا", "معنى", "معناها", "اعرف", "افهم", "معلومات",
        "traduce", "traducir", "explica", "cómo", "qué", "significa", "traduis", "traduire", "explique", "comment", "pourquoi", "signifie", "traduci", "spiega", "übersetze", "erkläre", "warum", "wie", "çevir", "açıkla", "nasıl", "nedir",
        "переведи", "объясни", "как", "почему", "ترجمه", "توضیح", "چگونه", "وەرگێڕە", "ترجمہ", "سمجھاؤ", "कैसे", "अनुवाद", "समझाओ", "jelaskan", "terjemahkan", "bagaimana", "eleza", "tafsiri"
    ], joined: ["翻译", "翻譯", "解释", "解釋", "如何", "怎么", "怎麼", "翻訳", "説明して", "どうやって", "번역", "설명", "어떻게", "แปล", "อธิบาย"])
    private static let otherDeliverables = matcher([
        "code", "website", "app", "application", "program", "script", "css", "javascript", "html", "api", "prompt", "description", "instructions", "tutorial", "article", "essay", "report", "pdf", "docx", "pptx", "xlsx", "csv", "presentation", "booklet", "brochure", "workbook",
        "كود", "موقع", "تطبيق", "برنامج", "ملف", "مستند", "تقرير", "مقال", "برومبت", "وصف", "تعليمات", "شرح",
        "código", "sitio", "aplicación", "artículo", "informe", "site", "application", "article", "rapport", "anleitung", "webseite", "programm", "artikel", "bericht", "uygulama", "kod", "makale", "сайт", "приложение", "код", "статью", "промпт", "برنامه", "مقاله", "کوڈ", "कोड", "ऐप", "लेख", "aplikasi", "kode"
    ], joined: ["代码", "代碼", "网站", "網站", "提示词", "提示詞", "文章", "コード", "アプリ", "웹사이트", "코드", "앱"])
    private static let lyrics = matcher(["lyrics", "كلمات", "letra", "letras", "paroles", "testo", "liedtext", "şarkı sözleri", "текст песни", "متن", "بول", "बोल", "lirik"], joined: ["歌词", "歌詞", "가사"])
    private static let mathematicalDiagram = matcher(["graph", "plot", "equation", "معادلة", "دالة", "gráfica", "ecuación", "équation", "funktionsgraph", "denklem", "уравнение"], joined: ["函数图", "函數圖", "関数グラフ", "함수 그래프"])
    private static let musicVideo = matcher(["music video", "music clip", "clip musical", "vidéo musicale", "video musical", "فيديو موسيقي", "كليب موسيقي"])
    private static let trailingDiscussion = matcher([], joined: [
        "生成的方法", "生成方法", "如何生成", "翻译成", "翻譯成", "的文章", "的代码", "的代碼", "歌词而不是", "只要歌词", "只要歌詞",
        "方法を教えて", "作り方を", "やり方を", "とは何", "翻訳して", "説明して", "についての記事", "についてレポート",
        "만드는 법", "생성하는 법", "설명해", "번역해", "가사만", "에 대한 글"
    ])
}
