import Foundation
import SwiftUI

/// The ```` ```firas-music ```` card (`web-media-ux.md §6.4`, `design-brief.md §7.12`).
///
/// A song is presented the way a song is presented anywhere: a cover, the title, a transport with a
/// scrubber that actually moves, `elapsed / total` in Latin digits left to right, download, and the
/// words behind a disclosure. Quiet throughout — one accent, on the play button, and nothing else
/// tinted. Nothing the app wrote for the engine appears anywhere on it.
///
/// The card draws the transport but never owns the audio. Only one song may be audible at a time and
/// a song has to stop the read-aloud voice and get out of a call's way — decisions that belong to the
/// app's single audio owner — so playback state arrives in `Playback` and every control is a callback.
///
/// The state this card exists to make honest is `pending`: a fence that carries lyrics and no cache
/// key. That is a turn where the words were written and the music never was, and showing only the
/// lyrics is exactly the failure the owner reported — the reader is handed a poem and concludes the
/// feature is broken. It says so instead, and offers the way forward.
///
/// Two device reports are answered by `FileState` below, and both are the same fact told twice:
///
/// * «حفظ الاغنية ماكو» — there was no way to keep a song. The web has always had one
///   (`app.js:4684-4689`: an `<a download>` straight at `/api/music/file?id=`), and the app drew its
///   equivalent — a `ShareLink` at the file on disk — **only if `shareURL` happened to be non-nil**.
///   It almost never was: `resolveShareFile` was asked exactly once, on the frame the card first
///   appeared, and on that frame the store is still fetching the bytes itself and answers `nil` to
///   everybody. One `nil` and the button was gone for the life of the card. The save is now a
///   permanent part of the ready state with three faces — preparing, save, retry — and the fetch
///   behind it retries on a backoff instead of giving up on the first ask.
/// * «ما يمشي المؤقت و الشريط» — the timer and the scrubber sit at zero. Everything that moves them
///   is `playback`, which the host builds from the app's one audio owner; a card that cannot reach
///   its own file cannot be playing, so a still bar is the *correct* reading of that state and the
///   defect is that the card said nothing about it. It says it now, and the play button stops
///   inviting a tap that could not do anything.
struct SongCard: View {

    /// What the host's player is doing right now.
    struct Playback: Sendable, Equatable {
        var isPlaying: Bool
        var isLoading: Bool
        var elapsed: Double
        var duration: Double

        init(isPlaying: Bool = false, isLoading: Bool = false, elapsed: Double = 0, duration: Double = 0) {
            self.isPlaying = isPlaying
            self.isLoading = isLoading
            self.elapsed = elapsed
            self.duration = duration
        }
    }

    /// `auto` reads the fence. `pending` is lyrics with no render behind them; `rendering` is a job
    /// still in flight; `failed` carries the server's error code, never its sentence.
    enum Phase: Sendable, Equatable {
        case auto
        case pending
        case rendering
        case ready
        case failed(code: String)
    }

    /// What the card knows about the audio **file**, which is a different question from what the
    /// render did. A song can be finished, cached on the server and charged for, and still be
    /// unreachable on this device — and that is neither a composing failure nor a reason to draw a
    /// transport that cannot move.
    enum FileState: Equatable {
        /// No host resolver was wired. The card claims nothing and hides nothing.
        case unknown
        case fetching
        case ready
        case failed
    }

    // Deliberately `internal`, not `private`: the transport, the two actions and the lyric sheet
    // live in `SongCard+Transport.swift`, and a `private` member is visible to extensions in the
    // same file only, so a split that relied on one would not compile (the note `MediaStore`
    // carries — COMPILE-RISK RULE 17).
    let meta: MediaMeta
    let palette: FirasPalette
    let lang: AppLanguage
    let phase: Phase
    let motionOn: Bool
    let startedAt: Date?
    let playback: Playback
    let resolveShareFile: ((MediaMeta) async -> URL?)?
    let onPlayPause: (() -> Void)?
    let onSeek: ((Double) -> Void)?
    let onDownload: (() -> Void)?
    let onGenerate: (() -> Void)?
    let onRegenerate: (() -> Void)?

    @State var lyricsShown = false
    @State var scrubbing = false
    @State var scrubValue: Double = 0
    @State var shareURL: URL?
    /// The file could not be reached inside the card's whole budget. Deliberately not the same flag
    /// as a composing failure: the song exists, the bytes did not come down.
    @State var downloadFailed = false
    /// The first ask for the file came back empty, so the wait is real and worth naming. A song
    /// already on disk resolves on the first ask in under a frame, and a card must not flash
    /// «أجهّز الأغنية…» at a reader who was never going to wait for anything.
    @State var fetchIsSlow = false
    /// Bumped by the retry button, so the fetch can be asked for again without a second render.
    @State var reloadToken = 0
    /// Set the instant Compose is pressed. The phase below is DERIVED from the fence, and the
    /// fence does not change when a render starts — the words are still there and the music
    /// still is not — so without this the card answered a tap by looking exactly as it did
    /// before it, for the whole two minutes. «من اضغط تلحين خلي يقول يتم تلحين الاغنية هو
    /// بداخل المربع نفسه».
    @State var composeAsked = false
    @State var since: Date

    init(
        meta: MediaMeta,
        palette: FirasPalette,
        lang: AppLanguage,
        phase: Phase = .auto,
        motionOn: Bool = true,
        startedAt: Date? = nil,
        playback: Playback = Playback(),
        resolveShareFile: ((MediaMeta) async -> URL?)? = nil,
        onPlayPause: (() -> Void)? = nil,
        onSeek: ((Double) -> Void)? = nil,
        onDownload: (() -> Void)? = nil,
        onGenerate: (() -> Void)? = nil,
        onRegenerate: (() -> Void)? = nil
    ) {
        self.meta = meta
        self.palette = palette
        self.lang = lang
        self.phase = phase
        self.motionOn = motionOn
        self.startedAt = startedAt
        self.playback = playback
        self.resolveShareFile = resolveShareFile
        self.onPlayPause = onPlayPause
        self.onSeek = onSeek
        self.onDownload = onDownload
        self.onGenerate = onGenerate
        self.onRegenerate = onRegenerate
        _since = State(initialValue: startedAt ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            stateBody
            lyricsDisclosure
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(palette)
        .task(id: taskKey) { await load() }
        .onChange(of: startedAt) { _, updated in
            if let updated { since = updated }
        }
    }

    // MARK: - Header

    var header: some View {
        HStack(alignment: .top, spacing: 12) {
            cover
            /* THE TITLE AND NOTHING ELSE. There used to be a second line here carrying
               `meta.style` — «acoustic pop, 90 bpm, warm nylon guitar, clear arabic vocals» — and
               that is not a subtitle, it is the instruction the app wrote for the music engine.
               The owner keeps finding machine text on his screen and this was the largest piece of
               it on a finished card: English production tags under an Arabic title, in a card he
               reached by asking for a song in Arabic. The genre is still written into the fence for
               the web; it is simply not something to hand a reader. */
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bidiIsland(for: title, fallback: lang)
    }

    /// The cover. There is no artwork from the engine, so the card draws one: the card's own sunken
    /// ground with a single soft accent wash and the note glyph. Deliberately one tone — a generated
    /// gradient per song would be the "vegetables" the owner asked to be taken out.
    @ViewBuilder
    var cover: some View {
        if resolvedPhase == .rendering {
            MediaCoverPlate(
                palette: palette,
                lang: lang,
                motionOn: motionOn,
                ratio: 1,
                cornerRadius: 12,
                startedAt: since
            )
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
        } else {
            restingCover
        }
    }

    var restingCover: some View {
        ZStack {
            LinearGradient(
                colors: [palette.accentSoft, palette.surfaceSunken],
                startPoint: .top,
                endPoint: .bottom
            )
            Image(systemName: "music.note")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(palette.accent)
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    // MARK: - States

    @ViewBuilder
    var stateBody: some View {
        switch resolvedPhase {
        case .rendering:
            renderingBody
        case .pending:
            pendingBody
        case .failed(let code):
            failedBody(code: code)
        case .auto, .ready:
            readyBody
        }
    }

    /// Honest progress: the web's sentence, the seconds actually spent, and — past the server's own
    /// ten-minute music budget — the sentence that says the wait is over rather than a spinner that
    /// never stops.
    var renderingBody: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            renderingRow(elapsed: SongCard.seconds(from: since, to: context.date))
        }
    }

    @ViewBuilder
    func renderingRow(elapsed: Int) -> some View {
        if Double(elapsed) > renderCeiling {
            noticeBody(
                text: SongCardCopy.stalled(lang),
                action: onRegenerate,
                title: SongCardCopy.regenerate(lang),
                symbol: "arrow.clockwise"
            )
        } else {
            VStack(alignment: .leading, spacing: 6) {
                FirasActivityLabel(text: SongCardCopy.working(lang), palette: palette, motionOn: motionOn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .bidiIsland(for: SongCardCopy.working(lang), fallback: lang)

                HStack(spacing: 8) {
                    Text(ArabicText.timer(elapsed))
                        .font(FirasType.mono)
                        .foregroundStyle(palette.textMuted)
                        .forceLTR()
                    Text(SongCardCopy.keepsWorking(lang))
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .bidiIsland(for: SongCardCopy.keepsWorking(lang), fallback: lang)
            }
        }
    }

    /// Words, no music. The one state the owner named.
    var pendingBody: some View {
        noticeBody(
            text: pendingAction == nil ? SongCardCopy.lyricsOnlyIdle(lang) : SongCardCopy.lyricsOnly(lang),
            action: pendingAction,
            title: onGenerate == nil ? SongCardCopy.regenerate(lang) : SongCardCopy.compose(lang),
            symbol: onGenerate == nil ? "arrow.clockwise" : "music.note"
        )
    }

    /// Composing is the right verb when the host offers it, regenerating when it only offers that.
    ///
    /// Wrapped rather than handed over bare: the card has to record that it was asked before the
    /// host is told, or the tap leaves no trace on screen.
    var pendingAction: (() -> Void)? {
        guard let action = onGenerate ?? onRegenerate else { return nil }
        return {
            composeAsked = true
            since = Date()
            action()
        }
    }

    func failedBody(code: String) -> some View {
        noticeBody(
            text: reason(for: code),
            action: onRegenerate,
            title: SongCardCopy.regenerate(lang),
            symbol: "arrow.clockwise"
        )
    }

    /// One sentence and, when the host wired a way forward, one 44 pt button under it.
    func noticeBody(
        text: String,
        action: (() -> Void)?,
        title: String,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: text, fallback: lang)

            if let action {
                capsuleButton(title: title, symbol: symbol, prominent: true, action: action)
            }
        }
    }

    @ViewBuilder
    var readyBody: some View {
        if onPlayPause == nil && onSeek == nil && onDownload == nil && fileState == .unknown {
            Text(SongCardCopy.unavailable(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: SongCardCopy.unavailable(lang), fallback: lang)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                transport
                fileStateLine
                actionRow
            }
        }
    }

    /// One line under the transport, and only when there is something true to say. A bar that
    /// cannot move must explain itself — that is the whole difference between "still getting the
    /// file" and "this app is broken".
    @ViewBuilder
    var fileStateLine: some View {
        if fileState == .failed {
            Text(Strings.Media.songDownloadFailed(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.error)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: Strings.Media.songDownloadFailed(lang), fallback: lang)
        } else if fileState == .fetching, fetchIsSlow {
            Text(Strings.Media.fetchingSong(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bidiIsland(for: Strings.Media.fetchingSong(lang), fallback: lang)
        }
    }

    // MARK: - Loading

    var taskKey: String {
        meta.key + "|" + String(describing: resolvedPhase) + "|" + String(reloadToken)
    }

    /// Ninety seconds of asking before the card calls the fetch failed. A song is the largest of the
    /// three files after a clip, and the very first ask almost always comes back empty because the
    /// store is fetching the same bytes itself at that moment.
    static let fetchBudget: TimeInterval = 90

    /// `nil` from the resolver means "not yet", not "no". It is the ordinary answer while the store
    /// warms the file, and it was the reason the download button vanished: one `nil` and nothing
    /// ever asked again. Now it asks again on a backoff, and only a whole budget of `nil` is a
    /// failure — with a retry that re-asks for the file rather than paying for a second song.
    func load() async {
        guard resolvedPhase == .ready, let resolveShareFile else {
            shareURL = nil
            downloadFailed = false
            fetchIsSlow = false
            return
        }
        downloadFailed = false
        fetchIsSlow = false

        var backoff = Backoff(initial: 0.4, max: 4)
        let deadline = Date().addingTimeInterval(SongCard.fetchBudget)

        while !Task.isCancelled {
            if let url = await resolveShareFile(meta) {
                shareURL = url
                downloadFailed = false
                fetchIsSlow = false
                return
            }
            guard Date() < deadline else { break }
            // The first empty answer is what turns a silent wait into a stated one.
            fetchIsSlow = true
            await JobClock.rest(backoff.next())
        }

        // A scrolled-away row is not a failed download and must not leave an error behind.
        guard !Task.isCancelled else { return }
        shareURL = nil
        fetchIsSlow = false
        downloadFailed = true
    }

    // MARK: - Derived

    /// Ten minutes — the web's `MUSIC_JOB_MAX_MS` — when a job is genuinely live. Ninety seconds
    /// when nobody claims one is, so a fence restored from another device settles quickly instead
    /// of pretending to compose for ten minutes.
    var renderCeiling: TimeInterval { startedAt == nil ? 90 : 10 * 60 }

    /// Bytes ⇒ ready. A live render the host told us about ⇒ progress. Anything else is a fence
    /// carrying words and no music, and that is `pending` — the state this card exists to name.
    var resolvedPhase: Phase {
        switch phase {
        case .auto:
            if !meta.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .ready }
            // The reader has asked for it and the answer has not landed yet. Checked AFTER the
            // key, so the arriving song always wins over the flag that was waiting for it.
            if composeAsked { return .rendering }
            // Words already written and no music ⇒ the composing step is the one that never ran.
            // Nothing written at all ⇒ this is a request on its way, and it gets a cover.
            return lyricsText.isEmpty ? .rendering : .pending
        case .pending, .rendering, .ready:
            return phase
        case .failed:
            return phase
        }
    }

    static func seconds(from start: Date, to now: Date) -> Int {
        let elapsed = now.timeIntervalSince(start)
        return elapsed > 0 ? Int(elapsed) : 0
    }

    /// **Never `meta.prompt`.** On a music fence that field is the English style line the app wrote
    /// for the engine, so the old fallback put «cinematic arabic ballad, 72 bpm, oud, strings» in
    /// the title slot of any song whose title was missing — a fence from the web, a re-roll, a
    /// creation restored from another device. A song with no name has a name of its own.
    var title: String {
        let candidate = (meta.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty { return String(candidate.prefix(90)) }
        return SongCardCopy.untitled(lang)
    }

    var lyricsText: String {
        (meta.lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the audio file stands. `unknown` when no host resolver was wired at all — a preview,
    /// the share page — in which case the card says nothing about a file it was never offered.
    var fileState: FileState {
        guard resolveShareFile != nil else { return .unknown }
        if shareURL != nil { return .ready }
        return downloadFailed ? .failed : .fetching
    }

    /// True while there is genuinely nothing to press: the file has not arrived, so the host's
    /// play handler would reach for bytes that are not there and nothing at all would happen. An
    /// inert-looking button is the honest drawing of that; a lively one that ignores taps is not.
    var transportBlocked: Bool {
        switch fileState {
        case .fetching, .failed: return true
        case .unknown, .ready: return false
        }
    }

    var playSymbol: String {
        if playback.isLoading || fileState == .fetching { return "hourglass" }
        return playback.isPlaying ? "pause.fill" : "play.fill"
    }

    var upperBound: Double {
        if playback.duration > 0 { return playback.duration }
        let declared = meta.seconds ?? 0
        return declared > 0 ? Double(declared) : 0
    }

    var displayedElapsed: Double {
        if scrubbing { return min(max(scrubValue, 0), max(upperBound, 1)) }
        return min(max(playback.elapsed, 0), max(upperBound, 1))
    }

    var elapsedText: String { ArabicText.timer(Int(displayedElapsed)) }

    var durationText: String {
        upperBound > 0 ? ArabicText.timer(Int(upperBound)) : "--:--"
    }

    /// `web-media-ux.md §6.4`, chosen by code.
    func reason(for code: String) -> String {
        switch code.lowercased() {
        case "not_configured":
            return Strings.Errors.musicNotConfigured(lang)
        case "rate_window", "daily_limit", "site_media_ceiling":
            return Strings.Errors.musicRateWindow(lang)
        case "rate_limited":
            return Strings.Errors.tooFast(lang)
        case "timeout", "expired":
            return SongCardCopy.stalled(lang)
        case "network", "offline", "unreachable":
            return SongCardCopy.whyNetwork(lang)
        case "signin_required", "account_required", "unauthorized":
            return SongCardCopy.signIn(lang)
        default:
            return Strings.Errors.musicFailed(lang)
        }
    }
}

// MARK: - Copy

/// `web-media-ux.md §6.4`, Arabic verbatim where the web has a sentence. The progress, stall and
/// "words without music" lines are new — the web has no honest wording for any of them.
enum SongCardCopy {
    static let working = LText(ar: "يلحّن الأغنية… حوالي دقيقة", en: "Composing… about a minute")

    static let keepsWorking = LText(
        ar: "يكمل التلحين حتى لو غادرت الشاشة.",
        en: "It keeps composing if you leave the screen."
    )

    static let stalled = LText(
        ar: "طال الانتظار أكثر من اللازم ولم تصل الأغنية. أعد التلحين.",
        en: "That took far too long and no song arrived. Compose it again."
    )

    /// The turn that hands over words and no music, with a way forward…
    static let lyricsOnly = LText(
        ar: "الكلمات جاهزة، لكن التلحين لم يتم بعد. اضغط لتلحينها.",
        en: "The words are written, but nothing was composed yet. Tap to compose it."
    )

    /// …and without one. Never tell a reader to press a button that is not on the card.
    static let lyricsOnlyIdle = LText(
        ar: "الكلمات جاهزة، لكن الأغنية لم تصل إلى هذا الجهاز. اطلبها مرّة أخرى في المحادثة.",
        en: "The words are written, but the song never reached this device. Ask for it again in the chat."
    )

    static let compose = LText(ar: "لحّن الأغنية", en: "Compose the song")
    static let play = LText(ar: "تشغيل", en: "Play")
    static let pause = LText(ar: "إيقاف مؤقّت", en: "Pause")
    static let seek = LText(ar: "موضع التشغيل", en: "Seek")
    static let regenerate = LText(ar: "أعد التلحين", en: "Regenerate")
    static let signIn = LText(ar: "سجّل دخولك حتى تصنع أغنية", en: "Sign in to make a song")
    static let lyrics = LText(ar: "الكلمات", en: "Lyrics")
    static let untitled = LText(ar: "أغنية فِراس", en: "Firas song")

    static let whyNetwork = LText(
        ar: "تعذّر الوصول إلى الأغنية — تحقّق من اتّصالك.",
        en: "The song could not be fetched — check your connection."
    )

    static let unavailable = LText(
        ar: "الأغنية غير متاحة للتشغيل هنا.",
        en: "This song cannot be played here."
    )
}
