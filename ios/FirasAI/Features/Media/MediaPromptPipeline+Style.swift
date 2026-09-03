import Foundation

/// The music half of `MediaPromptPipeline`: the keyword→tags table the web calls `musicStyleFor`,
/// and the genre chips the create form offers.
///
/// Split out of `MediaPromptPipeline.swift` for length only — every member here belongs to that
/// enum. The table is deliberately English: these tags are read by the ACE-Step engine and are
/// never sung, so translating them would change the sound rather than the language
/// (`web-media-ux.md §6.3`).
extension MediaPromptPipeline {

    /// `musicStyleFor` (`app.js:4402-4460`) — first match wins, and the tags stay English on
    /// purpose: they are read by the engine, never sung.
    static func musicStyleFor(lang: AppLanguage, ask: String) -> String {
        let arabic = lang == .arabic
        let voice = arabic ? "clear arabic vocals, " : "clear vocals, "
        let eastern = arabic ? "oud, darbuka, ney, middle eastern melody, " : ""
        let mix = "professional studio mixing"

        for rule in styleTable {
            guard RequestClassifier.matches(rule.pattern, ask) else { continue }
            return rule.build(voice, eastern, mix)
        }
        return arabic
            ? "modern arabic song, clear arabic vocals, catchy memorable chorus, oud, darbuka, middle eastern melody, warm, " + mix
            : "clear vocals, catchy memorable melody, warm, " + mix
    }

    /// One genre chip. A struct rather than a tuple because `ForEach` needs a real key path.
    struct GenrePreset: Identifiable, Sendable, Equatable {
        let id: String
        let label: LText
        let style: String
    }

    /// The genre chips the create form offers. Picking one replaces the keyword lookup entirely.
    static func genrePresets(lang: AppLanguage) -> [GenrePreset] {
        let mix = "professional studio mixing"
        let arabic = lang == .arabic
        let voice = arabic ? "clear arabic vocals, " : "clear vocals, "
        return [
            GenrePreset(
                id: "nasheed",
                label: LText(ar: "نشيد", en: "Nasheed"),
                style: "arabic nasheed, clear arabic vocals, simple memorable chorus, daf, ney, middle eastern melody, warm, " + mix
            ),
            GenrePreset(
                id: "anthem",
                label: LText(ar: "حماسي", en: "Anthem"),
                style: "epic anthem, driving percussion, powerful " + voice + "big chorus, cinematic, " + mix
            ),
            GenrePreset(
                id: "iraqi",
                label: LText(ar: "عراقي", en: "Iraqi"),
                style: "iraqi arabic song, iraqi arabic vocals, maqam-coloured melody, joza, oud, iraqi percussion, choubi rhythm, " + mix
            ),
            GenrePreset(
                id: "latmiya",
                label: LText(ar: "لطمية", en: "Latmiya"),
                style: "husseini latmiya, radoud lead male vocal with male group response, chest percussion, frame drum, daf, no melodic instruments, mournful, dignified, building intensity, clear arabic vocals, " + mix
            ),
            GenrePreset(
                id: "khaleeji",
                label: LText(ar: "خليجي", en: "Khaleeji"),
                style: "khaleeji arabic song, gulf arabic vocals, oud, tabl, khaleeji rhythm, " + mix
            ),
            GenrePreset(
                id: "rap",
                label: LText(ar: "راب", en: "Rap"),
                style: "hip hop, rap, hard drums, confident " + voice + "bass heavy, " + mix
            ),
            GenrePreset(
                id: "romantic",
                label: LText(ar: "رومانسي", en: "Romantic"),
                style: "romantic ballad, warm " + voice + "soft strings, intimate, " + mix
            ),
            GenrePreset(
                id: "children",
                label: LText(ar: "أطفال", en: "Children"),
                style: "children's song, playful, simple memorable chorus, " + voice + mix
            )
        ]
    }

    private struct StyleRule {
        let pattern: String
        let build: (_ voice: String, _ eastern: String, _ mix: String) -> String
    }

    /// `musicStyleFor`, in the web's order. The first match wins, which is why the dialect rows sit
    /// above the mood rows.
    private static let styleTable: [StyleRule] = [
        StyleRule(pattern: "حماسي|حماسية|قوي|قوية|طاقة|رياضي|نشيط|energetic|hype|anthem|epic|powerful") { voice, eastern, mix in
            "epic anthem, driving percussion, powerful " + voice + "big chorus, cinematic, " + eastern + mix
        },
        StyleRule(pattern: "لطمية|لطميات|لطميه|رادود|رواديد|مجلس\\s*عزاء|عاشوراء|حسيني[ةه]?|\\b(?:latmiya|latmiyat|radoud|husseini|ashura)\\b") { _, _, mix in
            "husseini latmiya, radoud lead male vocal with male group response, chest percussion, frame drum, daf, no melodic instruments, mournful, dignified, building intensity, clear arabic vocals, " + mix
        },
        StyleRule(pattern: "عراقي|عراقية|بغدادي|جوبي|چوبي|مقام\\s*عراقي|\\b(?:iraqi|choubi|maqam)\\b") { _, _, mix in
            "iraqi arabic song, iraqi arabic vocals, maqam-coloured melody, joza, oud, iraqi percussion, choubi rhythm, " + mix
        },
        StyleRule(pattern: "خليجي|خليجية|سعودي|كويتي|إماراتي|اماراتي|\\b(?:khaleeji|gulf)\\b") { _, _, mix in
            "khaleeji arabic song, gulf arabic vocals, oud, tabl, khaleeji rhythm, " + mix
        },
        StyleRule(pattern: "مصري|مصرية|شعبي|مهرجان|\\b(?:egyptian|masri|shaabi|mahraganat)\\b") { _, _, mix in
            "egyptian arabic song, egyptian arabic vocals, shaabi rhythm, accordion, tabla, " + mix
        },
        StyleRule(pattern: "شامي|شامية|لبناني|سوري|دبكة|\\b(?:levantine|shami|lebanese|syrian|dabke)\\b") { _, _, mix in
            "levantine arabic song, levantine arabic vocals, dabke rhythm, mijwiz, derbake, " + mix
        },
        StyleRule(pattern: "مغربي|مغربية|جزائري|تونسي|\\b(?:maghrebi|moroccan|algerian|rai)\\b") { _, _, mix in
            "maghrebi arabic song, maghrebi arabic vocals, gnawa percussion, rai influence, " + mix
        },
        StyleRule(pattern: "حزين|حزينة|شجن|فراق|بكاء|sad|melancholy|heartbreak|emotional") { voice, eastern, mix in
            "sad emotional ballad, slow tempo, expressive " + voice + "strings, " + eastern + mix
        },
        StyleRule(pattern: "رومانسي|رومانسية|حب|غرام|عشق|romantic|love") { voice, eastern, mix in
            "romantic ballad, warm " + voice + "soft strings, intimate, " + eastern + mix
        },
        StyleRule(pattern: "راب|هيب\\s*هوب|rap|hip\\s*hop|trap") { voice, _, mix in
            "hip hop, rap, hard drums, confident " + voice + "bass heavy, " + mix
        },
        StyleRule(pattern: "روك|rock|metal|guitar") { voice, _, mix in
            "rock, electric guitars, live drums, strong " + voice + mix
        },
        StyleRule(pattern: "بوب|pop|dance|رقص|حفلة|party") { voice, eastern, mix in
            "modern pop, catchy hook, upbeat, " + voice + eastern + mix
        },
        StyleRule(pattern: "طرب|كلاسيك|فصحى|قصيدة|موشح|tarab|classical|qasida") { _, _, mix in
            "tarab, classical arabic, oud, qanun, ney, warm dynamic arabic vocals, middle eastern melody, " + mix
        },
        StyleRule(pattern: "هادئ|هادئة|نوم|تأمل|calm|lullaby|sleep|ambient") { voice, eastern, mix in
            "calm lullaby, gentle, soft " + voice + "sparse arrangement, " + eastern + mix
        },
        StyleRule(pattern: "أطفال|اطفال|طفل|children|kids|nursery") { voice, eastern, mix in
            "children's song, playful, simple memorable chorus, " + voice + eastern + mix
        },
        StyleRule(pattern: "نشيد|أنشودة|انشودة|ديني|إسلامي|اسلامي|nasheed|anasheed") { _, _, mix in
            "arabic nasheed, clear arabic vocals, simple memorable chorus, daf, ney, middle eastern melody, warm, " + mix
        }
    ]
}
