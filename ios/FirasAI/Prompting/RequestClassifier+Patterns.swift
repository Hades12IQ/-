//
//  RequestClassifier+Patterns.swift
//  FirasAI
//
//  The regular-expression vocabulary ported from the web client (app.js, commit b1ae4fb).
//  Patterns are stored as STRINGS and compiled on demand: an `NSRegularExpression` stored in a
//  `static let` is a non-Sendable global, and classification runs once per user turn, so the
//  compile cost is irrelevant next to the safety.
//
//  PORTING RULE (ARCHITECTURE.md §3.14): never `\b` next to an Arabic token — ICU, like
//  JavaScript, defines `\b` on ASCII word characters only, so `\bابدأ\b` can never match.
//  Every Arabic alternative below is therefore unanchored, exactly as the web has it.
//

import Foundation

extension RequestClassifier {

    // MARK: - Regex plumbing

    /// `true` when `pattern` matches anywhere in `text`. A malformed pattern never throws: it
    /// simply does not match, so one bad constant can never take the router down.
    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }

    /// The first capture group of the first match, or `nil`.
    static func firstCapture(_ pattern: String, _ text: String, group: Int = 1) -> String? {
        guard !text.isEmpty else { return nil }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges > group else { return nil }
        guard let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    /// Arabic-Indic (U+0660…) and Extended Arabic-Indic (U+06F0…) digits folded to ASCII.
    static func latinDigits(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { out.append(ch); continue }
            let v = scalar.value
            if v >= 0x0660 && v <= 0x0669 {
                out.append(Character(UnicodeScalar(v - 0x0660 + 48) ?? scalar))
            } else if v >= 0x06F0 && v <= 0x06F9 {
                out.append(Character(UnicodeScalar(v - 0x06F0 + 48) ?? scalar))
            } else {
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Maths figures (app.js:4070) — a plotted function is never media

    static let mathFigurePattern =
        "y\\s*=|f\\s*\\(\\s*x\\s*\\)|رسم\\s*بياني|الكراف|الغراف|\\bgraph\\b|\\bplot\\b|دال[ةه]|منحن[يى]|\\bfunction\\b|معادلة"
        + "|\\b(?:sin|cos|tan|cot|sec|csc|exp|log|ln|lg|sqrt|cbrt|arctan|arcsin|arccos|sinh|cosh|tanh)\\s*\\("
        // The web writes `\bمربع\b` / `\bدائرة\b`; in JavaScript those can never match (ASCII-only
        // `\b`) while ICU's `\b` is Unicode-aware and would. Dropping the boundary gives ICU the
        // same result it reaches with it, and keeps the file free of the forbidden shape.
        + "|مثلث|مربع|مستطيل|دائرة|قطع\\s*مكافئ|\\bparabola\\b|متجه|\\bvector\\b|إحداثي|احداثي"

    // MARK: - Image generation (app.js:4960-4975)

    /* THE VERB HALF IS THE WEB'S `MEDIA_MAYBE` LIST, NOT `detectImageRequest`'S. The two live
       eleven lines apart in app.js and disagree: the pre-gate admits «ابي», «محتاج», «عايز»,
       «ودي», «جيب», «هات», «طلّع» — and then hands the sentence to a model, which is what
       actually decides. `detectImageRequest` knows six verbs because it never had to decide
       anything on its own. Here it does, so it gets the wider list; «ابي صورة لغروب الشمس» was
       being answered with a paragraph about sunsets. `أريد` with the hamza is in the same
       category — a plain porting gap, since the web only ever wrote the bare `اريد`. */
    static let imageArabicPattern =
        "(اصنع|أصنع|تصنع|اعمل|أعمل|تعمل|سوّ?ي?(?:لي)?|تسوّ?ي|ارسم|إرسم|ترسم|ولّ?د|صم[مّ]"
        + "|اعطني|اعطيني|عطني|انطيني|جيب|هات|جهّ?ز|طلّ?ع|دزّ?لي"
        + "|[أا]ريد|[أا]بي\\s|بدي|بغيت|عايز|عاوز|ودي|محتاج|[أا]حتاج|[أا]بغى)"
        + "\\s*[^؟?]{0,24}?"
        + "(صورة|صوره|رسمة|رسمه|لوحة|بوستر|بوسترات|تصميم|خلفية|لوغو|لوجو|شعار|بورتريه"
        + "|أيقونة|ايقونة|بانر|ملصق|غلاف|أفاتار|افاتار|إنفوجرافيك|انفوجرافيك)"
    static let imageArabicDrawPattern = "(^|\\s)(ارسم|إرسم)(\\s|$)"
    static let imageEnglishPattern =
        "\\b(generate|create|make|draw|paint|design|render)\\b[^.?!\\n]{0,48}?\\b(image|picture|photo|drawing|illustration|artwork|logo|logotype|poster|wallpaper|background|portrait|banner|icon|avatar|emblem|mockup|sticker|thumbnail)\\b"
    /* A HALF OF EVERY IRAQI REQUEST ENDS IN A QUESTION MARK. «ممكن تصنع لي صورة لبغداد؟» is not a
       question about pictures, and the web's rule — a trailing «؟» with none of five creation
       verbs is chat — throws it away. Politeness alone is not enough to rescue it, though: the
       word has to be followed by a verb that MAKES something, or «ممكن تعطيني معلومات عن صورة
       القمر؟» comes back as a render. Shared with the song gate, which has the same problem. */
    static let politeMakeAskPattern =
        "(?:ممكن|تكدر|تگدر|تقدر|لو\\s*سمحت|بلا\\s*زحمة|رجاءً?|رجاء)"
        + "\\s*[^؟?\\n]{0,16}?(?:تصنع|تسوّ?ي|تعمل|ترسم|تصمّ?م|تولّ?د|تطلّ?ع|تكتب|تلحّ?ن|تغنّ?ي)"
    /// A question with none of these verbs is a question ABOUT pictures, not a request for one.
    static let imageQuestionEscapePattern =
        "اصنع|ارسم|ولّد|ولد|generate|draw|create|make|design|" + politeMakeAskPattern

    // MARK: - Image editing (app.js:4825-4831) — no `\b` around the Arabic half

    static let imageEditArabicPattern =
        "عدّل|عدل|غيّر|غير|بدّل|بدل|حوّل|حول|اجعل|خلّي|خلي|اضف|أضف|ضيف|احذف|امسح|شيل|أزل|ازل|لوّن|لون|اقصص|قصّ|كبّر|صغّر|دوّر|اقلب|نظّف|حسّن|طوّر|استبدل|ابدل|اضبط|صحّح|رتّب|زيّن|موّه|فتّح|غمّق"
    static let imageEditEnglishPattern =
        "\\b(?:edit|change|modify|alter|make (?:it|the|this)|turn (?:it|the|this)|add|remove|delete|erase|replace|swap|recolou?r|colou?r|crop|rotate|flip|resize|upscale|enhance|retouch|fix|clean up|blur|brighten|darken|convert)\\b"

    // MARK: - Video (fallback gate, app.js:4058-4066 MEDIA_MAYBE split in two)

    static let mediaMakeVerbPattern =
        "(اصنع|اعمل|سوّ?ي|ولّ?د|ولد|صم[مّ]|اعطني|اعطيني|عطني|انطيني|ابي|أبي|اريد|أريد|بدي|عايز|عاوز|ودي|محتاج|جهّ?ز|طلّ?ع|هات|جيب|ارسم|حرّ?ك|خلي|خلّي"
        + "|انشئ|أنشئ|تصنع|تعمل|تسوّ?ي"
        + "|\\b(?:make|create|generate|render|animate|produce|draw|design|give\\s*me|i\\s*want|can\\s*you)\\b)"
    /* `يتحرك`/`تتحرك` are deliberately NOT here. They are verbs, not nouns, and adding them let
       «خلي النص يتحرك بالموقع» satisfy noun+verb and be answered with a rendered clip instead of
       a page. Motion belongs to `videoMotionPattern` below, which is asked separately and only
       when the message names no software. */
    static let videoNounPattern =
        "(فيديو|فديو|ڤيديو|مقطع|كليب|انيميشن|أنيميشن|موشن|رسوم\\s*متحركة|متحرك|مشهد|لقطة|ريلز"
        + "|\\b(?:video|clip|animation|animate|movie|reel|reels|footage|scene|shot|shorts?|trailer|gif)\\b)"
    /* MOTION WITHOUT THE WORD "VIDEO". The web's own comment above `MEDIA_MAYBE` lists the
       phrasings a verb+noun pattern cannot reach — «خلي الصورة تتحرك», «حرّكلي هالمشهد»,
       "animate this", "can you make it move", "bring the scene to life" — and its answer was to
       stop pattern-matching and ask a model. There is no model here, so the phrases themselves
       are the rule: each one carries its verb and its object together, which is why they need no
       noun beside them. */
    static let videoMotionPattern =
        "(?:خلّ?ي|اجعل|سوّ?ي|صيّ?ر)\\s*[^؟?\\n]{0,24}?(?:يتحرك|تتحرك|متحرك)"
        + "|حرّ?ك(?:لي|ها|هم|هن|هذي|هاي|هذه)"
        + "|\\bmake\\s+(?:it|this|them|the\\s+\\w+)\\s+move\\b"
        + "|\\bbring\\s+[^.?!\\n]{0,32}?\\bto\\s+life\\b"
        + "|\\banimate\\s+(?:it|this|the|them)\\b"
    /// «حوّل هالصورة لفيديو» — the classifier's own worked example, and it answers *video, not
    /// edit-image*: the picture is the input and the clip is the deliverable. Only consulted when
    /// a picture is actually in play, so «حوّل هذا الفيديو إلى نص» never reaches it.
    static let imageToClipPattern =
        "(?:حوّ?ل|خلّ?ي|سوّ?ي|اجعل|\\bturn\\b|\\bconvert\\b|\\bmake\\b|\\banimate\\b)"
        + "[^\\n]{0,40}?(?:فيديو|فديو|مقطع|كليب|\\bvideo\\b|\\bclip\\b|\\banimation\\b)"
    /// "لخص لي هالفيديو" / "what is the best video about…" — words ABOUT a clip, not a request for one.
    static let mediaAboutPattern =
        "لخّ?ص|اشرح|شرح|وضّ?ح|فسّ?ر|ترجم|ما\\s*معنى|شنو\\s*معنى|أفضل|افضل|\\b(?:summari[sz]e|explain|translate|describe|review|best|which|meaning)\\b"

    // MARK: - Music (app.js:41820-41830 songAskedPlainly)

    /* THE WEB'S SONG PATTERNS ARE A FALLBACK. HERE THEY ARE THE WHOLE LAYER.
       app.js says so in its own words above `songAskedPlainly`: "NARROW ON PURPOSE. It runs only
       after the classifier has already failed, so it catches the unmistakable asks and nothing
       else." That trade is right when a "pro" model has already read the sentence and only a
       network failure got you here. It is wrong when the regex IS the decision — narrow then
       means the feature is invisible for most of the ways an Iraqi actually asks, and «سويلي
       اغنيه عن امي», «ابي اغنية عراقية», «بدي اغنية», «اريدها كأغنية», «سوي لي لطمية», «انطيني
       اغنية» all fell through to an ordinary chat turn, which answered by WRITING a song. That
       is «مرات يالف ما يصنع» exactly: the app composed lyrics where it was asked to make music.

       So the ask side is wide, and the safety the web bought with narrowness is bought back
       explicitly instead, by `songAskedPlainly`'s five vetoes. Two of the web's own alternatives
       had to go to make that possible:

         `غنّ?ِ?ي\s` — «غني» followed by a space. It is also the adjective RICH, so «شنو الفرق بين
         الغني والفقير؟» asked the music engine for an anthem. Singing takes an object, so the
         object is now required.

         `نشيد|أنشودة|انشودة` standing alone. «النشيد الوطني» is a subject far more often than a
         request; «اكتب لي مقال عن النشيد الوطني» was a song. They are nouns, so they moved to
         the noun list, where a make verb has to stand beside them. */
    /* **[fix]** The dative alternative needed the same boundary `غنّ?يها` below already carries,
       and for the same reason one alternative earlier: «الغني» ENDS in «غني», and «الي» is the
       Iraqi relative pronoun far more often than it is the dative «إلي». «الغني الي عنده فلوس ما
       يعرف قيمة الفقير» therefore satisfied «غني» + «الي», and a sentence about a rich man was
       answered by composing a song — the exact failure the note above says the removal of the
       bare `غنّي\s` was meant to end. A sung verb starts a word; only the conjunction prefixes
       may stand in front of it. */
    static let songSingPattern =
        "((?:^|[\\s،,.:؛!?؟])[وف]?غنّ?ي\\s*(?:لي|لنا|إلي|الي|إلنا|النا)|غنيلي|غنيلنا"
        + "|(?:^|[\\s،,.:؛!?؟])غنّ?يها"
        + "|غنّ?ي\\s*(?:هاي|هذي|هذه|الكلمات|كلمات|أغنية|اغنية|قصيدة|القصيدة)"
        + "|لحّ?ن\\s*(?:لي|لنا|هاي|هذي|هذه|الكلمات|كلمات)|لحّ?نها|لحّ?نهم"
        + "|(?:حط|حطّ|خلّ?ي|سوّ?ي|اجعل|ضع|رتّ?ب)\\s*[^؟?\\n]{0,24}?(?:بلحن|بموسيقى|على\\s*لحن)"
        + "|\\bsing\\b|set\\s+(?:it|this|them|the\\s+words)\\s+to\\s+music)"
    static let songNounPattern =
        "(أغنية|اغنية|أغنيه|اغنيه|أغاني|اغاني|أغنيتين|اغنيتين|أغنيات|اغنيات"
        + "|نشيد|أنشودة|انشودة|أناشيد|اناشيد|لطمية|لطميه|لطميات"
        + "|موسيقى|موسيقا|\\bsong\\b|\\bsongs\\b|\\bnasheed\\b|\\banthem\\b|\\blullaby\\b|\\bjingle\\b|\\bmusic\\b|\\brap\\b)"
    /// «اغنيه» with a final ha and «لطمية» are the two spellings the web's list never learned, and
    /// between them they cover a large share of what this app is actually asked for.
    static let songMakePattern =
        "(اعمل|أعمل|تعمل|اعملي|اصنع|أصنع|تصنع|سوّ?ي|تسوّ?ي|صم[مّ]|ألّ?ف|الف\\s|تؤلف|ولّ?د|جهّ?ز"
        + "|اكتب|أكتب|تكتب|عطني|أعطني|اعطني|اعطيني|انطيني|هات|جيب|طلّ?ع|دزّ?لي|خلّ?ي"
        + "|[أا]ريد|[أا]بي\\s|بدي|بغيت|عايز|عاوز|ودي|محتاج|[أا]حتاج|[أا]بغى"
        + "|\\bmake\\b|\\bwrite\\b|\\bcreate\\b|\\bgenerate\\b|\\bcompose\\b|\\bproduce\\b|\\bgive\\s*me\\b"
        /* `حوّل` carries its shadda on purpose. The English half already reads "turn … into" as a
           make verb, and the note under `songProsePattern` counts «حوّل هذه القصيدة إلى أغنية» as
           a song it must not veto — but no Arabic transform verb was ever on this list, so that
           sentence reached no gate at all and a poem handed over to be sung came back as chat.
           The bare `حول` cannot join it: unshadda'd it is the preposition ABOUT, and «معلومات
           حول الأغاني العراقية» would then be a make verb standing next to a song noun. */
        + "|حوّل"
        + "|\\bi\\s*(?:want|need)\\b|\\bcan\\s*you\\b|\\bturn\\b[^\\n]{0,40}?\\binto\\b)"

    /* PROXIMITY IS WHAT SEPARATES A SONG FROM A SITE ABOUT SONGS. The web tests its make list and
       its noun list independently, anywhere in the message — and «اعمل لي موقع يعرض الاغاني»
       contains both, which is why the classifier's worked-example list has to carry it as a
       correction ("a website ABOUT songs is software"). Sixteen characters is the whole fix:
       «اصنع لي أغنية» is three, «اعمل لي موقع يعرض الاغاني» is sixteen with the make verb bound
       to «موقع» and not to «الاغاني». `[^؟?\n]` keeps the window inside one line, so a verb in
       the request cannot reach a noun five lines down in a pasted block. */
    static let songMakeNounPattern = songMakePattern + "\\s*[^؟?\\n]{0,16}?" + songNounPattern
    /// The Iraqi word order that puts the noun first — «اغنية عن الشتاء سويها الي». Only the
    /// pronoun-suffixed imperatives are allowed to close it: «سويها» can only mean "make it".
    static let songNounMakePattern =
        songNounPattern
        + "\\s*[^؟?\\n]{0,20}?(?:سوّ?يها|سوّ?يلي|اصنعها|اعملها|ولّ?دها|ألّ?فها|الفها|غنّ?يها|لحّ?نها)"

    /// The song word is the SUBJECT of a piece of software, not the deliverable.
    static let songAsSoftwarePattern =
        "موقع|\\bwebsite\\b|web\\s*site|web\\s*app|webapp|صفحة\\s*ويب|landing\\s*page"
        + "|(?:مشغّ?ل|تطبيق|برنامج|منص[ةه])\\s*[^؟?\\n]{0,16}?(?:أغاني|اغاني|أغنية|اغنية|موسيقى|موسيقا)"
        + "|(?:songs?|music)\\s*(?:player|app|application|site|website|library|streaming)"
        + "|(?:player|app|application|website|site)\\s*(?:for|that\\s+plays)\\s*(?:songs?|music)"
    /// The classifier's own boundary, as a veto: "It is CHAT when the thing they will end up with
    /// is words on the screen." «غنيلي شنو معناها» — same opening word as a request, and a
    /// question about meaning.
    static let songAboutPattern =
        "معنى|معناها|معناه|شنو\\s*تعني|وش\\s*تعني|شنو\\s*يعني"
        + "|مين\\s*غنّ?ى|من\\s*غنّ?ى|مين\\s*كتب|من\\s*كتب|مين\\s*لحّ?ن|من\\s*لحّ?ن|مؤلف\\s*ال|ملحّ?ن\\s*ال|صاحب\\s*ال?أ?غني"
        + "|قصة\\s*ال?أ?غني|تاريخ\\s*ال?أ?غني|متى\\s*صدرت|متى\\s*نزلت"
        + "|أفضل\\s*ال?أ?غني|افضل\\s*ال?ا?غني|أحسن\\s*ال?أ?غني|احسن\\s*ال?ا?غني|أشهر\\s*ال?أ?غني|اشهر\\s*ال?ا?غني"
        + "|\\bwho\\s+(?:sang|sings|wrote|composed)\\b|\\bmeaning\\s+of\\b|\\bbest\\s+songs?\\b|\\bfamous\\s+songs?\\b"
        + "|\\brecommend\\b|\\bplaylist\\b|قائمة\\s*تشغيل|رشّ?حلي|رشّ?ح\\s*لي"
    /* **[fix]** A WANT AIMED AT KNOWING IS NOT A WANT AIMED AT HAVING. Widening the make list to
       «اريد|ابي|بدي|محتاج|i want» and the noun list to a bare «موسيقى|music» put the two within
       sixteen characters of each other in every sentence of the commonest shape there is:
       «ابي اعرف تاريخ الموسيقى العراقية», «اريد معلومات عن الموسيقى الكلاسيكية», «اريد دراسة
       الموسيقى في الجامعة», "i want to learn about music theory". Each one is a question, and
       each one was answered by spending the user's credits composing a song. The knowledge word
       must sit immediately after the want — four characters is «ان » and "to ", and no more — so
       «اريد اغنية اعرفها» is still a song. */
    static let songKnowledgeAskPattern =
        // `[أا]بي` keeps the trailing space the make list gives it: without one it is the opening
        // of «أبيض» and «بابي» as readily as it is "I want".
        "(?:[أا]ريد|[أا]بي\\s|بدي|بغيت|عايز|عاوز|ودي|محتاج|[أا]حتاج|[أا]بغى"
        + "|\\bi\\s*(?:want|need)\\b|\\bi'?d\\s+like\\b)"
        + "\\s*[^؟?\\n]{0,4}?"
        + "(?:[أا]عرف|تعرف|نعرف|[أا]تعلم|[أا]فهم|[أا]درس|دراسة|معلومات|معرفة|قائمة"
        + "|\\blearn\\b|\\bknow\\b|\\bunderstand\\b|\\bstudy\\b|\\blist\\b|\\binfo(?:rmation)?\\b)"
    /// A written deliverable that merely has music as its topic. «اكتب لي مقال عن النشيد الوطني».
    /// `قصيدة` and `قصة` are deliberately absent: a poem handed over to be set to music is a song,
    /// and vetoing on them would cost «حوّل هذه القصيدة إلى أغنية».
    static let songProsePattern =
        "مقال|تقرير|(?:^|[\\s،,.:؛!?؟])بحث|موضوع\\s*تعبير|خاطرة|منشور|تغريدة|بوست|فقرة|مراجعة"
        + "|\\b(?:essay|article|report|paper|blog\\s*post|paragraph|review)\\b"
    /// "'Write me lyrics' with no music asked for is chat" — the classifier's own sentence. The
    /// write verb is required, so «خلي هاي الكلمات اغنية» (make these words INTO a song) is not
    /// caught by it.
    static let songLyricsOnlyPattern =
        "(?:اكتب|أكتب|اكتبلي|ألّ?ف|جهّ?ز|عطني|اعطني|اعطيني|\\bwrite\\b|\\bgive\\s*me\\b)"
        + "\\s*[^؟?\\n]{0,20}?(?:كلمات\\s*(?:ال)?(?:أغنية|اغنية|أغنيه|اغنيه|نشيد|أنشودة|انشودة)|\\blyrics\\b)"
    /// …unless the same sentence also says what to DO with the words.
    static let songLyricsEscapePattern =
        "خلّ?ي|حوّ?ل|اجعل|صيّ?رها|بلحن|بموسيقى|set\\s+[^\\n]{0,20}?to\\s+music|\\bturn\\b[^\\n]{0,40}?\\binto\\b"
    /// A trailing question mark is a question about music — «شنو افضل اغنية عراقية؟» — unless the
    /// sentence carries an imperative, or the politeness an Iraqi request ends with.
    static let songQuestionEscapePattern =
        "غنيلي|غنّ?ي\\s*لي|اصنعلي|اصنع\\s*لي|سوّ?يلي|سوّ?ي\\s*لي|اعملي|اعمل\\s*لي|اكتبلي|اكتب\\s*لي"
        + "|\\bmake\\b|\\bcreate\\b|\\bgenerate\\b|\\bcompose\\b|\\bsing\\b|\\bcan\\s+you\\b|\\bplease\\b"
        + "|" + politeMakeAskPattern

    // MARK: - Long documents (app.js:41514)

    static let longDocPattern =
        "موسوعة|كتاب\\s*(ضخم|كامل|شامل)|مرجع\\s*شامل|\\d{3,4}\\s*صفح|مئات\\s*الصفح|آلاف\\s*الصفح"
        + "|encyclopedia|mega\\s*book|comprehensive\\s*(book|reference)|\\d{3,4}\\s*pages?|hundreds\\s*of\\s*pages"
    static let longDocPagesPattern = "(\\d{2,4})\\s*(?:صفح|pages?)"

    // MARK: - Explicit page counts (app.js:30219)

    static let pageNumberGroup = "([0-9](?:[0-9,\u{066C}\u{060C}_ \u{00A0}\u{202F}]*[0-9])?)"
    static let pageUnitGroup = "(?:pages?|صفح(?:ة|ات)?|صفحه)"
    static let pageCountMax = 10_000

    // MARK: - Code (app.js:2733-2871)

    static let codeAsksToLearnPattern =
        "(?:[أا]ريد|[أا]بي|بدي|عايز|عاوز|ودي|محتاج|[أا]حتاج|[أا]بغى)\\s*(?:[أا]ن\\s*)?(?:[أا]عرف|[أا]فهم|[أا]تعلم|تعلم|معرف[ةه]|فهم)"
        + "|كيف\\s*(?:[أا])?(?:سوي|عمل|بني|صنع|كتب|اسوي|اعمل|ابني)|يعني\\s*[إا]يه|شنو\\s*يعني"
        + "|\\bhow\\s+(?:do|can|to|would)\\b|\\bi\\s+want\\s+to\\s+(?:know|learn|understand)\\b"
        + "|\\bi\\s+need\\s+to\\s+(?:know|learn|understand)\\b|\\bwhat\\s+(?:is|are|does)\\b|\\bteach\\s+me\\b|\\blearn\\s+(?:about|how)\\b"
    static let codeBuildVerbsPattern =
        "(اصنع|إصنع|اعمل|إعمل|سو[يّ]?ي?|سويي|ابن[يي]|أبني|اكتب|أكتب|انشئ|أنشئ|صم[مّ]|[أا]ريد|[أا]بي|بدي|عايز|عاوز|بغيت|ودي|محتاج|[أا]حتاج|ابغى|أبغى"
        + "|generate|create|make|build|write|develop|design|implement|code\\s+me|build\\s+me|i\\s+want|i\\s+need)"
    static let codeHardPattern =
        "\\bhtml\\b|\\bcss\\b|\\bjavascript\\b|vanilla\\s*js|كود|\\bcode\\b|سكربت|سكريبت|\\bscript\\b|<!doctype|\\bc\\+\\+|\\bcpp\\b|\\bjava\\b|\\bc#|csharp"
        + "|\\brust\\b|\\bgolang\\b|\\bkotlin\\b|\\bswift\\b|\\bphp\\b|\\btypescript\\b|\\bpython\\b|بايثون|برنامج|برمجة|سي\\s*بلس\\s*بلس|جافا"
    static let codeSoftPattern = "موقع|\\bwebsite\\b|web\\s*site|web\\s*page|webpage|صفحة\\s*ويب|landing\\s*page|single[-\\s]?file"
    static let codeSpecPattern =
        "single[-\\s]?file\\s*(html|website|web\\s*site|site|page|web\\s*page)|<!doctype\\s*html|(ملف|صفحة|موقع|كود)\\s*html|html\\s*(file|website|site|page)|سنكل\\s*فايل|single\\s*html"
    static let codeDocOverridePattern =
        "powerpoint|pptx|بوربوينت|باوربوينت|عرض\\s*تقديمي|شرائح|سلايد|\\bpdf\\b|بي\\s*دي\\s*اف|excel|xlsx|اكسل|[إاأ]ي?كس[يى]?ل|\\bword\\b|docx|وورد"
        + "|(?:ملف|مستند|بصيغة|صيغة)\\s*ورد|\\bcsv\\b"
    static let codeGenericPattern =
        "\\bprogram\\b|\\bapp(?:lication)?\\b|\\bfunction\\b|\\bclass\\b|\\balgorithm\\b|\\bsnippet\\b|\\bgame\\b|\\bCLI\\b|\\bAPI\\b|\\bendpoint\\b|\\bregex\\b"
        + "|\\bquery\\b|\\b(?:bash|shell)\\b|\\bdashboard\\b|\\bplatform\\b|\\bportfolio\\b|\\blanding\\s*page\\b|\\bstore\\b|\\bstorefront\\b|\\be-?commerce\\b|\\bblog\\b"
        + "|تطبيق|دالة|خوارزمية|لعبة|متجر|منص[ةه]|لوح[ةه]\\s*تحكم|داشبورد|بورتفوليو|صفح[ةه]\\s*هبوط|مدون[ةه]"
    static let codeDocNounPattern =
        "\\b(report|summary|essay|book|ebook|guide|manual|paper|article|letter|cv|resume|story|outline|notes?|memo|thesis|brochure|worksheet)\\b"
        + "|تقرير|ملخّ?ص|مقال|كتاب|دليل|بحث|رسالة|سيرة\\s*ذاتية|قصة|مذكرة|أطروحة|كرّاس|ورقة\\s*عمل"
    static let codeDocEscapePattern = "\\bcode\\b|كود|\\bscript\\b|سكر[يى]?بت|سكريبت|<!doctype"
    static let codeDrawRequestPattern =
        "\\b(draw|sketch)\\b|ارسم|إرسم|ارسملي|ارسم\\s*لي|رسم\\s*بياني|رسم\\s*دالة|رسم\\s*شكل|رسم\\s*مثلث|رسم\\s*دائرة|رسمة|رسمه|مخطّط|مخطط"
    static let codeDrawAsAppPattern =
        "website|web\\s*app|web\\s*page|\\bpage\\b|\\bsite\\b|interactive|canvas|\\bhtml\\b|\\bcss\\b|javascript|\\bjs\\b|\\bgame\\b|موقع|صفحة|تطبيق|تفاعل|لعبة"

    // MARK: - Files (app.js:2718, 2886-3030)

    static let fileRequestVerbsPattern =
        "\\b(make|create|generate|build|produce|export|give\\s*me|turn\\s*(?:it|this)?\\s*into|convert|save|download|send\\s*me|write(?:\\s*me)?|draft|compose|author|prepare"
        + "|put\\s*(?:it|this)?\\s*(?:in|into)|i\\s+(?:want|need|would\\s+like))\\b"
        + "|اصنع|إصنع|أنشئ|انشئ|سوّ?ي|اعمل|إعمل|اعملي|حوّ?ل|صدّ?ر|أعطني|اعطني|أعطيني|اعطيني|انطيني|نزّ?ل|ابعت|إبعت|جهّ?ز|اكتب(?:\\s*لي)?|خرّ?ج|طلّ?علي"
        + "|طلّ?ع\\s*لي|دزّ?\\s*لي|دزلي|طبعلي|طبع\\s*لي|اطبع|إطبع|جيب\\s*لي|جبلي|هات\\s*لي|هاتلي|صمّ?م|أريد|اريد|أبغى|ابغى|أبي\\s|ابي\\s|بدي|بغيت|أحتاج|احتاج|محتاج|عايز|عاوز"

    static let fileNegationEnglishPattern =
        "\\b(?:no|without|don'?t\\s+(?:make|create|want|need|give)|not\\s+(?:a|an|as))\\s+(?:a\\s+|an\\s+|any\\s+)?(?:pdf|file|document|word|excel|powerpoint|ppt|csv|slides?|deck)\\b"
    static let fileNegationArabicPattern =
        "(?:بدون|بلا|من\\s*دون|مو|مش|ليس|بغير|لا)\\s*(?:ملف|مستند|وثيقة|pdf|بي\\s*دي\\s*اف|بدف|وورد|ورد|اكسل|إكسل|بوربوينت|عرض\\s*تقديمي)"
    static let fileNegationArabicVerbPattern =
        "(?:لا\\s*(?:تسوي|تعمل|تصنع|تنشئ|تحول|تحوّل)|ما\\s*(?:اريد|أريد|ابي|أبي|بدي|بغيت))\\s*[^.؟?!\\n]{0,22}?(?:ملف|pdf|بي\\s*دي\\s*اف|بدف|مستند|وثيقة|بوربوينت|اكسل|وورد)"

    static let fileStrongPPTX = "powerpoint|pptx|بوربوينت|باوربوينت|عرض\\s*تقديمي|عرض\\s*بوربوينت|شرائح|سلايد"
    /* «اعمل لي عرض عن الثورة الصناعية» is the classifier's own worked example — "عرض means slides
       here, not a moving picture" — and neither list could see it: the strong one wants «عرض
       تقديمي», the weak one is English-only. A bare «عرض» is too dangerous to add (it is also the
       verb "show" in «اعرض», a width, and a price quote), so the topic preposition carries it:
       a presentation is always ABOUT something. The leading boundary keeps «اعرض عن» out, since
       the character before «عرض» is then a letter. */
    static let fileWeakPPTX =
        "\\bppt\\b|presentation|slides?|برزنتيشن|بريزنتيشن"
        // The same class as `fileLeadBoundary`, written out because that constant is declared
        // further down the file and this one must not depend on the order.
        + "|(?:^|[\\s،,.:؛!?؟\\-–—()\"'])عرض\\s*(?:عن|حول|بخصوص)"
    static let fileStrongCSV = "\\bcsv\\b|سي\\s*في\\s*اس|سي\\s*في\\s*أس|ملف\\s*csv|csv\\s*ملف"
    static let fileStrongXLSX = "excel|xlsx|spreadsheet|[إاأ]ي?كس[يى]?ل|اكسل|جدول\\s*بيانات"
    static let fileWeakXLSX = "\\bsheet\\b"
    /* «اكتبلي تقرير ورد» — the owner's own phrasing, and the web answers it with prose.
       The web only reads a bare "ورد" as Word when a FILE cue precedes it (ملف/مستند/صيغة),
       because "ورد" is also roses and the verb "was mentioned". A DELIVERABLE noun is just as
       unambiguous a cue as "ملف" is — nobody writes «تقرير ورد» meaning a report about roses —
       so the document nouns join that list, guarded twice: the word must END there (no
       "وردة"/"وردية") and must not be followed by the prepositions that make it the verb
       («تقرير ورد من الوزارة»). */
    static let fileDocNounBeforeWordPattern =
        "(?:تقرير|بحث|مقال|كتاب|رسالة|مذكرة|خطاب|ملخّ?ص|سيرة\\s*ذاتية|عقد|ورقة\\s*عمل|واجب|دليل)"
        + "\\s*(?:بصيغة\\s*|صيغة\\s*)?(?:وورد|ورد|word)"
        + "(?![\\p{L}\\p{N}_])(?!\\s*(?:من|في|فى|على|عن|إلى|الى|إليه|اليه|ذكره|اسمه|ذكرها))"
    static let fileStrongDOCX = "docx|(?:ملف|مستند|بصيغة|صيغة|بصبغة)\\s*(?:word|ورد|وورد)|مستند\\s*word|وورد"
        + "|" + fileDocNounBeforeWordPattern
    static let fileWeakDOCX = "\\bms\\s*word\\b|\\bword\\s+(?:doc|document|file|format)\\b"
    static let fileStrongPDF = "\\bpdf\\b|بي\\s*دي\\s*اف|بدف|ملف\\s*pdf"
    /* **[new]** — plain text. The web has no txt deliverable; the app's own exporter does, and a
       request for one used to fall through to the generic "file → pdf" rule, which handed a
       reader who asked for a .txt a PDF. Deliberately narrow: only an explicit text-FILE phrase,
       never the bare word "نص". */
    static let fileStrongTXT =
        "\\btxt\\b|\\.txt|ملف\\s*نصي?(?![\\p{L}\\p{N}_])|ملف\\s*تكست|مستند\\s*نصي(?![\\p{L}\\p{N}_])"
        + "|نص\\s*عادي|نص\\s*صرف|plain\\s*text|text\\s*file"
    static let fileGenericPattern = "\\bfile\\b|\\bdocument\\b|ملف|مستند|وثيقة"
    static let filePdfDestinationPattern =
        "\\bpdf\\s+(?:book|file|document|workbook|format|report)\\b|\\b(?:as|in|to|into)\\s+(?:an?\\s+)?pdf\\b|بصيغة\\s*pdf|كملف\\s*pdf|ملف\\s*pdf|بي\\s*دي\\s*اف"
    /// Fixed compounds stripped before the WEAK pass so "cheat sheet" is never a spreadsheet.
    static let fileWeakStripPattern =
        "microscope\\s+slides?|glass\\s+slides?|culture\\s+slides?|presentation\\s+letter|cheat\\s+sheet|balance\\s+sheet|spec\\s+sheet|sheet\\s+music|on\\s+deck|card\\s+deck"

    static let fileQuestionMarkPattern = "[?؟]"
    static let fileQuestionArabicLeadPattern = "^\\s*(ما|ماذا|كيف|لماذا|ليش|وش|شنو|شو|هل|متى|اين|أين|كم|أي)(\\s|$)"
    static let fileQuestionArabicWordPattern = "(معنى|تعريف|الفرق\\s*بين|اشرح|وضّح|فسّر)"
    static let fileQuestionEnglishPattern =
        "\\b(what|how|why|who|when|where|which|whose|meaning|explain|describe|difference\\s+between)\\b"

    static let comprehendVerbPattern =
        "\\b(?:explain|summari[sz]e|analy[sz]e|review|describe|read|extract|walk\\s+me\\s+through|go\\s+through|tell\\s+me\\s+about|what\\s+(?:does|is)\\s+(?:this|it|the))\\b"
        + "|[إا]شرح|شرحلي|شرح|وضّ?ح|فسّ?ر|لخّ?ص|لخصلي|تلخيص|ملخّ?ص|حلّ?ل|تحليل|راجع|مراجعة|[إا]قرأ|[إا]ستخرج|محتوى|ما\\s*(?:هو|فيه|يقول)"
        + "|ماذا\\s*(?:يقول|يحتوي|فيه)|شنو\\s*(?:مكتوب|فيه|يحتوي)|عن\\s*ماذا|عن\\s*شنو|ترجم"
    static let refersExistingPattern =
        "\\b(?:this|that|the|it|attached|uploaded|above|my)\\b|هذا|هذه|هاي|هاذ|هالـ?|ديك|المرفق|المرفقة|المُرفق|أرفقت|ارفقت|رفعت|الملف|الملفات|المستند|الوثيقة|الكتاب"
        + "|اللي\\s*(?:رفعت|أرسلت)|الي\\s*رفعت"

    /// A token boundary that is safe in Arabic: a bare `ل`/`ك` prefix is part of the next word.
    static let fileLeadBoundary = "(?:^|[\\s،,.:؛!?؟\\-–—()\"'])"
    static let fileLeadPattern =
        "(?:as|into|to|in)\\s+(?:an?\\s+)?(?:new\\s+)?(?:file\\s+|document\\s+)?"
        + "|(?:[إا]لى|بصيغة|بصبغة|كملف|كمستند|بصورة|على\\s*شكل|بشكل)\\s*(?:ملف\\s*|مستند\\s*|صيغة\\s*)?"
        + "|(?:make|create|generate|produce|export|convert|turn|save|download|write|prepare)\\s+(?:me\\s+)?(?:an?\\s+)?(?:new\\s+)?(?:file\\s+|document\\s+)?"
        + "|(?:اعمل|إعمل|سوّ?ي|انشئ|أنشئ|اصنع|إصنع|حوّ?ل|صدّ?ر|جهّ?ز|اكتب|اطبع|نزّ?ل|أعطني|اعطني|اعطيني|جيب|هات)\\s*(?:لي\\s*)?(?:ملف\\s*|مستند\\s*)?"

    /// Destination format words, in the web's own resolution order.
    static let fileFormatWords: [(format: String, pattern: String)] = [
        ("pptx", "powerpoint|pptx|\\bppt\\b|بوربوينت|باوربوينت|عرض\\s*تقديمي|شرائح|سلايد"),
        ("xlsx", "excel|xlsx|spreadsheet|اكسل|[إاأ]كسل|جدول\\s*بيانات"),
        ("csv", "csv"),
        ("docx", "word|docx|وورد|(?:ملف|مستند|صيغة)\\s*ورد"),
        ("pdf", "pdf|بي\\s*دي\\s*اف|بدف"),
        /* **[new]** — last, so "as a pdf" is never read as "as text". The bare English word
           "text" is NOT here: "write me a text about the war" is prose, not a .txt file. And the
           Arabic «نصي» carries an end boundary, or the lead «اكتب لي » + «نصيحة» would be one. */
        ("txt", "txt|تكست|نص\\s*عادي|plain\\s*text|نصي(?:ة)?(?![\\p{L}\\p{N}_])"),
    ]

    /// The formats that are a DELIVERABLE document (`turnIntentIsDocument`, app.js:4341), plus the
    /// app's own `txt`. Used to read a stored `ChatMessage.intent` back.
    static let documentFormats: Set<String> = ["pdf", "docx", "pptx", "xlsx", "csv", "txt"]

    // MARK: - I'rab (app.js:4980-4984)

    static let irabPattern =
        "إعراب|اعراب|أعرب|اعرب|أعربها|اعربها|ما\\s*(?:هو\\s*)?إعراب|حلّل(?:ها)?\\s*نحوي|تحليل\\s*نحو|نحويًا|نحويا|اعرابي|إعرابي"

    // MARK: - Image follow-up (app.js:35913 refersToPriorImage / 39340 isImageTransformRequest)

    static let priorImagePattern =
        "الصور|صورة|الملف|المرفق|المرفقة|منها|فيها|الأسئلة|نفس(ها)?|بنفس|image|file|attachment|extract|estract|the questions|them|it"
    static let imageTransformArabicPattern =
        "(اعمل|اصنع|سوّ?ي|ولّ?د|ولد|انشئ|أنشئ|اكتب\\s*لي|اكتبلي|صمّ?م|حلّ?|حل\\s|جاوب|أجب|اشرح|لخّ?ص|لخص|أعد\\s*صياغة|اعد\\s*صياغة|مشاب|مماثل|نفس\\s*النمط|بنمط"
        + "|أصعب|اصعب|أسهل|اسهل|نسخة|أسئلة|اسئلة|مسائل|مسأل|امتحان|اختبار|تمارين|تمرين|سؤال|مثل\\s*هذ|زيد|أكثر|اكثر|طوّ?ر|ضاعف)"
    static let imageTransformEnglishPattern =
        "\\b(make|create|generate|produce|build|design|write|compose|solve|answer|rewrite|paraphrase|summari[sz]e|explain|similar|harder|tougher|easier|more|another"
        + "|additional|new|version|worksheet|exam|quiz|test|problems?|questions?|exercises?)\\b"
}
