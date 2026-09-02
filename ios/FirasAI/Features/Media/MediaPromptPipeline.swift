import Foundation
import UIKit

/// What the user typed becomes what the render engines actually want.
///
/// This is the half of media creation the old iOS app was missing entirely
/// (`audit-ios-brain-media.md §B.3` finding 34): the raw Arabic went straight to the wire, so
/// images lost their art direction, videos had no shot description, and a typed Arabic *description*
/// arrived as ACE-Step **style tags** — a field the engine cannot read — with no lyrics at all.
///
/// Every model call here is the web's: tier `pro`, `nomem: true`, no `cid`, no `chatId`, and a
/// failure is never fatal — the raw text is always a usable fallback
/// (`web-media-ux.md §3.1, §5.1, §6.1–6.3`).
enum MediaPromptPipeline {

    // MARK: - Result shapes

    /// What a song turn sends: English production tags in `prompt`, the sung words in `lyrics`.
    struct SongPlan: Sendable, Equatable {
        var style: String
        var lyrics: String
        var title: String
        /// True when the lyric author could not produce anything usable.
        var lyricsFailed: Bool
    }

    // MARK: - Images

    /// One `pro` call that turns the request into a single rich English prompt, then the same
    /// cleaning the web does: quotes and backticks off the ends, whitespace collapsed, 1000 chars.
    /// The raw text (≤1000) is the fallback, because a missing rewrite must never cancel a render.
    static func imagePrompt(api: APIClient, rawText: String, lang: AppLanguage) async -> String {
        let seed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seed.isEmpty else { return "" }
        let fallback = String(seed.prefix(1_000))
        guard let answer = await modelText(
            api: api,
            system: PromptCatalog.imagePromptEnhancerSystem,
            user: String(seed.prefix(1_000)),
            deadlineSeconds: 30,
            characterCap: 4_000
        ) else {
            return fallback
        }
        let cleaned = tidy(answer, cap: 1_000)
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// `pickImageShape` (`app.js:5100-5115`) — read from the **raw** text, never the rewrite, and
    /// square is tested first so a logo never becomes a poster.
    static func pickShape(_ rawText: String) -> ImageShape {
        let text = rawText
        if RequestClassifier.matches(squarePattern, text) { return .square }
        if RequestClassifier.matches(tallPattern, text) { return .tall }
        if RequestClassifier.matches(widePattern, text) { return .wide }
        return .square
    }

    // MARK: - Video

    /// The two-branch rewrite. With a photo the engine already owns the subject, the setting and
    /// the light, so describing them again fights the picture and can replace the person in it;
    /// the prompt then describes only what CHANGES.
    static func videoPrompt(
        api: APIClient,
        rawText: String,
        seconds: Int,
        hasPhoto: Bool
    ) async -> String {
        let seed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seed.isEmpty else { return "" }
        let fallback = String(seed.prefix(1_000))
        let system = videoSystemPrompt(seconds: seconds, hasPhoto: hasPhoto)
        guard let answer = await modelText(
            api: api,
            system: system,
            user: String(seed.prefix(1_000)),
            deadlineSeconds: 30,
            characterCap: 4_000
        ) else {
            return fallback
        }
        let cleaned = tidy(answer, cap: 1_000)
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// Verbatim, assembled exactly as `app.js:42063-42093` assembles it.
    static func videoSystemPrompt(seconds: Int, hasPhoto: Bool) -> String {
        let n = String(max(2, min(seconds, 30)))
        var text = "Turn the user's request into ONE vivid ENGLISH prompt for a "
            + n + "-second video clip. Output ONLY the prompt text.\n\n"
        if hasPhoto {
            text += "THE FIRST FRAME IS ALREADY GIVEN as a photograph the user attached, and the video animates forward from it. So do NOT describe the subject's appearance, the setting or the lighting — they are decided, and describing them again fights the photo and can replace the person in it with someone else. Describe ONLY WHAT CHANGES over the "
                + n + " seconds: the motion, the transformation, how the light shifts as it happens, and ONE camera move.\n\n"
        } else {
            text += "Describe a SINGLE continuous shot: the subject, the setting, the lighting, and ONE simple camera or subject motion (a slow push in, a gentle pan, a rising object).\n\n"
        }
        text += "ONE UNBROKEN SHOT: no scene cuts, no jumps in time or place, no dialogue, no on-screen text. A single continuous CHANGE is not a cut and is welcome — a person transforming, ice melting, a structure assembling — so keep any progression the user asked for and pace it across the full "
            + n + " seconds, saying what has happened by the end."
        return text
    }

    /// Re-encodes a picked photo into the only shape `/api/video/job` accepts: a
    /// `data:image/jpeg;base64,…` URI, longest edge ≤ 2048 px, comfortably under the server's
    /// 12 M-character body cap (`server-media.md §6` — the 413 branch is dead code, an oversized
    /// body degrades to `400 bad_request` and the photo is silently dropped).
    ///
    /// `nonisolated` and `async`, so decoding and JPEG encoding never run on the main actor.
    static func firstFrameDataURI(from data: Data) async -> String? {
        guard !data.isEmpty else { return nil }
        guard let image = UIImage(data: data) else { return nil }
        let scaled = downscaled(image, longestEdge: 2_048)
        var quality: CGFloat = 0.86
        var encoded = scaled.jpegData(compressionQuality: quality)
        // ~8 MB of bytes ≈ 11.2 M base64 characters; step down rather than lose the frame.
        while let bytes = encoded, bytes.count > 8_000_000, quality > 0.4 {
            quality -= 0.15
            encoded = scaled.jpegData(compressionQuality: quality)
        }
        guard let bytes = encoded, bytes.count <= 8_800_000 else { return nil }
        return "data:image/jpeg;base64," + bytes.base64EncodedString()
    }

    /// The same downscale, for the bytes that go to `/api/image/edit` (raw base64, ≤ 20 MB decoded).
    static func editSourceBase64(from data: Data) async -> String? {
        guard !data.isEmpty else { return nil }
        if data.count <= 6_000_000, UIImage(data: data) != nil {
            return data.base64EncodedString()
        }
        guard let image = UIImage(data: data) else { return nil }
        let scaled = downscaled(image, longestEdge: 2_048)
        guard let bytes = scaled.jpegData(compressionQuality: 0.9) else { return nil }
        return bytes.base64EncodedString()
    }

    // MARK: - Music

    /// `songIsWrittenOut` (`app.js:41798-41805`): a section tag, or at least four non-empty lines
    /// of which four fifths are short. That is what a lyric sheet looks like, and it means the
    /// author model must not be called at all.
    static func isWrittenOut(_ text: String) -> Bool {
        if RequestClassifier.matches("\\[(?:verse|chorus|bridge|intro|outro|hook)\\]", text) { return true }
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 4 else { return false }
        let short = lines.filter { $0.count <= 60 }.count
        return short >= max(4, Int((Double(lines.count) * 0.8).rounded(.down)))
    }

    /// Builds the whole song turn. Supplied lyrics skip the model entirely; a described song calls
    /// the author, takes its leading `STYLE:` line as the production tags and the rest as the words.
    static func songPlan(
        api: APIClient,
        rawText: String,
        userLyrics: String?,
        genreHint: String?,
        lang: AppLanguage
    ) async -> SongPlan {
        let ask = String(rawText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        let supplied = (userLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !supplied.isEmpty || isWrittenOut(ask) {
            let words = supplied.isEmpty ? ask : supplied
            let tagged = RequestClassifier.matches("\\[(?:verse|chorus)\\]", words) ? words : "[verse]\n" + words
            let style = genreHint ?? musicStyleFor(lang: lang, ask: ask.isEmpty ? words : ask)
            return SongPlan(
                style: style,
                lyrics: tagged,
                title: Strings.Media.songUntitled(lang),
                lyricsFailed: false
            )
        }

        let answer = await modelText(
            api: api,
            system: lyricAuthorSystem,
            user: ask,
            deadlineSeconds: 60,
            characterCap: 8_000
        )
        let parsed = splitStyleLine(answer ?? "")
        let title = String(
            RequestClassifier.replacingMatches("\\s+", in: ask, with: " ").prefix(60)
        )
        guard !parsed.lyrics.isEmpty else {
            return SongPlan(
                style: genreHint ?? musicStyleFor(lang: lang, ask: ask),
                lyrics: "",
                title: title,
                lyricsFailed: true
            )
        }
        let style = genreHint
            ?? (parsed.style.isEmpty ? musicStyleFor(lang: lang, ask: ask) : parsed.style)
        return SongPlan(style: style, lyrics: parsed.lyrics, title: title, lyricsFailed: false)
    }

    /// Strips the author's `STYLE:` line (any line, tolerant of markdown decoration) and returns
    /// the rest as the lyrics; every remaining STYLE line is dropped so none of them get sung.
    static func splitStyleLine(_ raw: String) -> (style: String, lyrics: String) {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A whole answer wrapped in a code fence is common; peel it.
        if body.hasPrefix("```") {
            var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if !lines.isEmpty { lines.removeFirst() }
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            body = lines.joined(separator: "\n")
        }

        var style = ""
        var kept: [String] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let captured = RequestClassifier.firstCapture(stylePattern, line) {
                if style.isEmpty { style = captured.trimmingCharacters(in: .whitespacesAndNewlines) }
                continue
            }
            kept.append(line)
        }
        let lyrics = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (tidy(style, cap: 2_000), String(lyrics.prefix(6_000)))
    }

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

    // MARK: - Regeneration

    /// Identical inputs are the same cache key, so a repeat returns the identical bytes
    /// (`server-media.md §6.8`). A real re-roll has to change the text; this is the smallest change
    /// that reads as an instruction rather than as noise inside the picture.
    static func rerolled(_ prompt: String, attempt: Int) -> String {
        let base = RequestClassifier.replacingMatches(
            "\\s*\\(alternate take \\d+\\)\\s*$",
            in: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            with: ""
        )
        let n = max(2, attempt)
        return String((base + " (alternate take " + String(n) + ")").prefix(2_000))
    }

    /// How many re-rolls a prompt already carries, so the next one is a different key again.
    static func rerollAttempt(in prompt: String) -> Int {
        guard let captured = RequestClassifier.firstCapture("\\(alternate take (\\d+)\\)\\s*$", prompt),
              let value = Int(captured) else { return 1 }
        return value
    }

    // MARK: - Private — model plumbing

    /// One `POST /api/chat` SSE call, collected into a string. Same shape as `AutoTitle.generate`:
    /// `nomem: true`, tier `pro`, thinking off, no conversation. Any failure answers `nil` and the
    /// caller falls back to the raw text.
    private static func modelText(
        api: APIClient,
        system: String,
        user: String,
        deadlineSeconds: Double,
        characterCap: Int
    ) async -> String? {
        let request = ChatStreamRequest(
            messages: [
                OutgoingMessage(role: "system", content: system, images: nil),
                OutgoingMessage(role: "user", content: user, images: nil)
            ],
            tier: "pro",
            think: false,
            cid: "",
            chatId: nil,
            product: ProductKind.ai.wireValue,
            nomem: true,
            nokb: true,
            agent: nil
        )
        do {
            let collected = try await withDeadline(seconds: deadlineSeconds) { () async throws -> String in
                var text = ""
                let stream = await api.chatStream(request)
                for try await frame in stream {
                    let payload = frame.data.trimmingCharacters(in: .whitespacesAndNewlines)
                    if payload.isEmpty { continue }
                    if payload == "[DONE]" { break }
                    if let piece = delta(fromSSEPayload: payload) { text += piece }
                    if text.count > characterCap { break }
                }
                return text
            }
            let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    private static func delta(fromSSEPayload payload: String) -> String? {
        guard let data = payload.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let root = object as? [String: Any] else { return nil }
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else { return nil }
        guard let deltaObject = first["delta"] as? [String: Any] else { return nil }
        guard let text = deltaObject["content"] as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Quotes and backticks off both ends, whitespace collapsed, capped — the web's own cleaning.
    private static func tidy(_ raw: String, cap: Int) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = RequestClassifier.replacingMatches("^[\"'`«»\\s]+", in: text, with: "")
        text = RequestClassifier.replacingMatches("[\"'`«»\\s]+$", in: text, with: "")
        text = RequestClassifier.replacingMatches("\\s+", in: text, with: " ")
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(cap))
    }

    private static func downscaled(_ image: UIImage, longestEdge: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > longestEdge, longest > 0 else { return image }
        let scale = longestEdge / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard target.width >= 1, target.height >= 1 else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: - Private — patterns

    /// `app.js:5100-5115`. No `\b` next to Arabic; the Latin alternatives keep theirs.
    private static let squarePattern =
        "لوغو|لوقو|شعار|أيقونة|ايقونة|رمز|ستيكر|ملصق دائري|أفاتار|افاتار|بروفايل بيك|ختم"
        + "|\\b(?:logo|icon|avatar|emblem|badge|sticker|monogram|favicon|profile pic)\\b"

    private static let tallPattern =
        "بوستر|ملصق|ستوري|قصة|بورتريه|بروفايل|جوال|موبايل|كتاب|غلاف كتاب"
        + "|\\b(?:poster|story|portrait|vertical|phone|mobile|book cover|flyer|reel|tiktok)\\b"

    private static let widePattern =
        "لافتة|لافته|بانر|غلاف|كفر|خلفية|خلفيه|ويلبيبر|مشهد|منظر|بانوراما|شريط علوي|هيدر|واجهة|واجهه"
        + "|\\b(?:banner|cover|header|hero|wallpaper|background|landscape|panorama|scene|thumbnail|widescreen)\\b"

    /// The tolerant `STYLE:` matcher from `app.js` — leading markdown decoration, optional bold,
    /// colon or dash.
    private static let stylePattern = "^[\\s>#*_-]*\\**\\s*STYLE\\s*\\**\\s*[:\\-–]\\s*(.+?)\\s*$"

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
