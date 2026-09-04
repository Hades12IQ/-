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
    typealias RequestGuard = @Sendable () async -> Bool

    // MARK: - Result shapes

    /// Where the sung words came from. The caller needs this because the three cases are three
    /// different things to say to the reader, and one of them used to be said by ending the turn.
    enum LyricSource: String, Sendable, Equatable {
        /// The user typed the words; the author model was never called.
        case supplied
        /// The lyric author wrote them.
        case authored
        /// Nobody could write them, so the take is instrumental. This is still a song.
        case instrumental
    }

    /// What a song turn sends: English production tags in `prompt`, the sung words in `lyrics`.
    struct SongPlan: Sendable, Equatable {
        var style: String
        var lyrics: String
        var title: String
        var source: LyricSource
        /// A sentence to show the reader when the plan is not quite what they asked for — today,
        /// only the instrumental fallback. `nil` when nothing needs saying.
        var notice: LText?

        /// True only when there is nothing the music engine could be asked for: no style line and
        /// no words, which `/api/music/job` answers with `400 bad_request`.
        ///
        /// It is deliberately **not** true when the lyric author fails. Ending the turn there is
        /// the bug the owner reported: the reader is handed a lyric sheet, no music is ever
        /// requested, and nothing explains why — so the feature reads as broken. A failed author
        /// now produces an instrumental take and a sentence, and the music job runs, which means
        /// the job's own outcome (a song, or a failure the card explains) is what the reader sees.
        var lyricsFailed: Bool { style.isEmpty && lyrics.isEmpty }
    }

    // MARK: - Images

    /// One `pro` call that turns the request into a single rich English prompt, then the same
    /// cleaning the web does: quotes and backticks off the ends, whitespace collapsed, 1000 chars.
    /// The raw text (≤1000) is the fallback, because a missing rewrite must never cancel a render.
    static func imagePrompt(api: APIClient, rawText: String, lang: AppLanguage, isCurrent: @escaping RequestGuard) async -> String {
        let seed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seed.isEmpty else { return "" }
        let fallback = String(seed.prefix(1_000))
        guard let answer = await modelText(
            api: api,
            system: PromptCatalog.imagePromptEnhancerSystem,
            user: String(seed.prefix(1_000)),
            deadlineSeconds: 30,
            characterCap: 4_000,
            isCurrent: isCurrent
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
        hasPhoto: Bool,
        isCurrent: @escaping RequestGuard
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
            characterCap: 4_000,
            isCurrent: isCurrent
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
    ///
    /// **The author may not end the turn.** It gets a second, terser attempt, and if that is empty
    /// too the plan becomes an instrumental take with a sentence explaining the change. A song turn
    /// therefore always reaches `/api/music/job`, and what the reader ends up with is always either
    /// audio or a failure the song card can name — never a lyric sheet and silence.
    static func songPlan(
        api: APIClient,
        rawText: String,
        userLyrics: String?,
        genreHint: String?,
        lang: AppLanguage,
        isCurrent: @escaping RequestGuard
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
                source: .supplied,
                notice: nil
            )
        }

        let title = String(
            RequestClassifier.replacingMatches("\\s+", in: ask, with: " ").prefix(60)
        )
        var parsed = splitStyleLine(
            await modelText(
                api: api,
                system: lyricAuthorSystem,
                user: ask,
                deadlineSeconds: 60,
                characterCap: 8_000,
                isCurrent: isCurrent
            ) ?? ""
        )
        if parsed.lyrics.isEmpty {
            parsed = splitStyleLine(
                await modelText(
                    api: api,
                    system: lyricAuthorRetrySystem,
                    user: ask,
                    deadlineSeconds: 45,
                    characterCap: 8_000,
                    isCurrent: isCurrent
                ) ?? ""
            )
        }

        guard !parsed.lyrics.isEmpty else {
            let base = genreHint ?? musicStyleFor(lang: lang, ask: ask)
            return SongPlan(
                style: instrumentalStyle(base),
                lyrics: "",
                title: title,
                source: .instrumental,
                notice: instrumentalNotice
            )
        }
        let style = genreHint
            ?? (parsed.style.isEmpty ? musicStyleFor(lang: lang, ask: ask) : parsed.style)
        return SongPlan(style: style, lyrics: parsed.lyrics, title: title, source: .authored, notice: nil)
    }

    /// The second ask. The long prompt is a craft brief; when it comes back empty the likeliest
    /// causes are length and the number of constraints, so this one keeps the two rules that make
    /// the result usable — the `STYLE:` line and the section tags — and drops everything else.
    static let lyricAuthorRetrySystem: String = """
    Write the lyrics for the song the user describes, in the SAME LANGUAGE they wrote in.
    FIRST LINE: `STYLE: ` followed by English production tags for the music engine (genre, tempo, \
    instruments, voice); include `clear arabic vocals` when the lyrics are Arabic. Then a blank \
    line, then the lyrics. Use [verse] and [chorus] tags, short lines, two or three verses. \
    Output the style line and the lyrics only — no title, no commentary.
    """

    /// A take with no vocal. The engine reads `prompt` as production tags, so the vocal tags are
    /// taken out rather than contradicted — asking for `clear arabic vocals, instrumental` gets a
    /// mumbled vocal, not silence.
    static func instrumentalStyle(_ style: String) -> String {
        let stripped = RequestClassifier.replacingMatches(
            "[^,]*\\bvocals?\\b[^,]*,?\\s*",
            in: style,
            with: ""
        )
        let cleaned = tidy(stripped, cap: 1_900)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        let joined = cleaned.isEmpty
            ? "instrumental, no vocals, professional studio mixing"
            : cleaned + ", instrumental, no vocals"
        return String(joined.prefix(2_000))
    }

    /// Shown with the song, not instead of it.
    static let instrumentalNotice = LText(
        ar: "ما قدرت أكتب كلمات لهذه الأغنية، فلحّنتها موسيقى بلا غناء. صف الأغنية بشكل أوضح لتأتي بكلمات.",
        en: "I could not write words for this one, so it was composed as music without vocals. Describe the song more clearly to get lyrics."
    )

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
        characterCap: Int,
        isCurrent: @escaping RequestGuard
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
                guard await isCurrent() else { throw CancellationError() }
                let stream = await api.chatStream(request)
                for try await frame in stream {
                    guard await isCurrent() else { throw CancellationError() }
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
}
