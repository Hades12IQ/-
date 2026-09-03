import AVFoundation
import Observation
import SwiftUI

/// One song at a time, on the right audio session.
///
/// The old player was a bare `AVPlayer` with no category, so a song was silent under the ring
/// switch, died on lock, had no scrubber, and two cards could sing over each other
/// (`audit-ios-brain-media.md §B.3` finding 40). This one takes `.playback` through
/// `AudioSessionArbiter` — the only object in the app allowed to touch `AVAudioSession` — stops the
/// read-aloud voice before it starts, and gets out of the way when a call takes the session.
@MainActor
@Observable
final class SongPlayer {

    static let shared = SongPlayer()

    /// The creation id currently loaded; nil when nothing is loaded.
    private(set) var currentID: String?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isLoading = false

    /// Set when a call starts. A live call outranks a song, so the song ends rather than ducks.
    ///
    /// Computed over an ignored stored flag rather than a stored property with a `didSet`: the
    /// `@Observable` macro rewrites every eligible stored property into a computed one, and a
    /// property observer cannot survive that rewrite (same pattern as `TTSPlayer.callActive` and
    /// `PreferencesStore`).
    var callActive: Bool {
        get { storedCallActive }
        set {
            storedCallActive = newValue
            if newValue && currentID != nil { stop() }
        }
    }

    @ObservationIgnored private var storedCallActive = false

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    private init() {
        observeInterruptions()
    }

    // MARK: - Transport

    /// Starts, or resumes, the song at `url`. Loading a different song replaces the current one —
    /// this is the whole of the "only one song audible" rule.
    func play(id: String, url: URL, tts: TTSPlayer?) async {
        guard !callActive else { return }
        tts?.stop()

        if currentID == id, let player {
            guard await acquireSession() else { return }
            player.play()
            isPlaying = true
            return
        }

        teardown()
        isLoading = true
        currentID = id
        currentTime = 0
        duration = 0

        guard await acquireSession() else {
            isLoading = false
            currentID = nil
            return
        }

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .pause
        player = newPlayer
        installObservers(for: newPlayer, item: item)
        newPlayer.play()
        isPlaying = true
        isLoading = false
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// One play/pause button's whole behaviour.
    func toggle(id: String, url: URL, tts: TTSPlayer?) async {
        if currentID == id && isPlaying {
            pause()
        } else {
            await play(id: id, url: url, tts: tts)
        }
    }

    func stop() {
        teardown()
        currentID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        Task { await AudioSessionArbiter.release(.playback) }
    }

    /// Seeks to `seconds`. Called when the slider is released, never while it is dragged.
    func seek(to seconds: Double) {
        guard let player, duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func isCurrent(_ id: String) -> Bool { currentID == id }

    // MARK: - Private

    private func acquireSession() async -> Bool {
        do {
            try await AudioSessionArbiter.acquire(.playback)
            return true
        } catch {
            return false
        }
    }

    private func installObservers(for player: AVPlayer, item: AVPlayerItem) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // The callback is delivered on the main queue, but the compiler cannot know that, so
            // the hop onto the actor is written out.
            let seconds = time.seconds
            let total = item.duration.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = (seconds.isFinite && seconds > 0) ? seconds : 0
                if total.isFinite, total > 0 { self.duration = total }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.player?.seek(to: .zero)
                self.currentTime = 0
            }
        }
    }

    /// A phone call, a voice note, or the app's own call engine taking the session: pause rather
    /// than keep a silent player running. Nothing here touches `setActive` — that is the arbiter's.
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in
                self?.pause()
            }
        }
    }

    private func teardown() {
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
    }
}

// MARK: - The bar

/// The song card's transport: a 44 pt accent play button, a scrubber, and elapsed / total in Latin
/// digits, left to right — a timer is never Arabic-Indic (`design-brief.md §4.2`).
@MainActor
struct SongPlayerBar: View {

    private let creationID: String
    private let url: URL?
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let tts: TTSPlayer?

    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    init(creationID: String, url: URL?, palette: FirasPalette, lang: AppLanguage, tts: TTSPlayer?) {
        self.creationID = creationID
        self.url = url
        self.palette = palette
        self.lang = lang
        self.tts = tts
    }

    var body: some View {
        HStack(spacing: 12) {
            transportButton
            VStack(spacing: 4) {
                slider
                times
            }
        }
    }

    private var player: SongPlayer { SongPlayer.shared }
    private var isCurrent: Bool { player.isCurrent(creationID) }
    private var isPlaying: Bool { isCurrent && player.isPlaying }
    private var total: Double { isCurrent ? player.duration : 0 }
    private var elapsed: Double { scrubbing ? scrubValue : (isCurrent ? player.currentTime : 0) }

    private var transportButton: some View {
        Button {
            guard let url else { return }
            let id = creationID
            let voice = tts
            Task { await SongPlayer.shared.toggle(id: id, url: url, tts: voice) }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.onAccent)
                .frame(width: 44, height: 44)
                .background { Circle().fill(url == nil ? palette.textMuted : palette.accent) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .accessibilityLabel(Text(isPlaying ? Strings.Media.pause(lang) : Strings.Media.play(lang)))
    }

    private var slider: some View {
        Slider(
            value: Binding(
                get: { elapsed },
                set: { scrubValue = $0 }
            ),
            in: 0...max(total, 1),
            onEditingChanged: { editing in
                if editing {
                    scrubbing = true
                    scrubValue = elapsed
                } else {
                    scrubbing = false
                    player.seek(to: scrubValue)
                }
            }
        )
        .tint(palette.accent)
        .disabled(!isCurrent || total <= 0)
        .accessibilityLabel(Text(Strings.Media.seek(lang)))
    }

    private var times: some View {
        HStack(spacing: 8) {
            Text(ArabicText.timer(Int(elapsed)))
            Spacer(minLength: 8)
            Text(total > 0 ? ArabicText.timer(Int(total)) : "--:--")
        }
        .font(FirasType.mono)
        .foregroundStyle(palette.textMuted)
        .forceLTR()
    }
}
