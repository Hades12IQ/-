import AVFoundation
import SwiftUI
import UIKit

/// The full-screen call surface (`design-brief.md §7.13`).
///
/// It owns no audio and no sockets: `CallEngine` drives every phase and this view renders it.
/// Four real states live here — the consent card before the microphone has ever been asked for,
/// the connecting state, the live call, and the failure with a working Retry (the Codex screen
/// offered only End, `audit-ios-voice.md V4`).
struct CallScreen: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let call: CallEngine
    private let prefs: PreferencesStore

    @State private var consentVisible = false
    @State private var didStart = false
    @State private var didHaptic = false
    @State private var closeGeneration = 0

    init(env: AppEnvironment) {
        self.call = env.call
        self.prefs = env.prefs
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                callBackground(side: min(proxy.size.width, proxy.size.height))
                content(in: proxy.size)
            }
        }
        .task { await begin() }
        .onChange(of: call.phase) { _, phase in reactTo(phase) }
        .onDisappear { closeGeneration &+= 1 }
    }

    // MARK: - Layout

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        let orbSide = orbSize(in: size)
        if horizontalSizeClass == .regular, size.width > size.height, size.width >= 700 {
            HStack(spacing: 48) {
                orb(orbSide)
                VStack(spacing: 22) {
                    header
                    statusBlock
                    controls
                }
                .frame(maxWidth: 420)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                orb(orbSide)
                Spacer(minLength: 12)
                statusBlock
                Spacer(minLength: 20)
                controls
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func orbSize(in size: CGSize) -> CGFloat {
        let side = min(size.width, size.height)
        return min(max(176, side * 0.36), 320)
    }

    private func orb(_ side: CGFloat) -> some View {
        OrbView(
            level: call.level,
            mode: orbMode,
            palette: palette,
            motionOn: motionOn,
            size: side
        )
    }

    private func callBackground(side: CGFloat) -> some View {
        ZStack {
            palette.callGround
            RadialGradient(
                colors: [palette.accent.opacity(palette.isLightFamily ? 0.26 : 0.30), .clear],
                center: .center,
                startRadius: 0,
                endRadius: max(120, side * 0.82)
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text(Strings.Voice.callName(lang))
                .font(FirasType.scaled(20, scale: prefs.fontScale, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            Text(ArabicText.timer(call.elapsed))
                .font(FirasType.mono)
                .foregroundStyle(palette.textSecondary)
                .forceLTR()
                .accessibilityLabel(Text(Strings.Voice.callTimerLabel(lang)))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusBlock: some View {
        VStack(spacing: 12) {
            if consentVisible {
                consentCard
            } else {
                statusLine
                captionLine
                guestCapLine
                retryButton
            }
            diagnosticsLine
        }
        .frame(maxWidth: .infinity)
        .animation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn), value: consentVisible)
    }

    @ViewBuilder
    private var statusLine: some View {
        let text = statusText
        if isBusyPhase {
            FirasActivityLabel(text: text, palette: palette, motionOn: motionOn)
                .bidiIsland(for: text, fallback: lang)
        } else {
            Text(text)
                .font(FirasType.label)
                .foregroundStyle(isFailed ? palette.error : palette.textSecondary)
                .multilineTextAlignment(.center)
                .bidiIsland(for: text, fallback: lang)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    @ViewBuilder
    private var captionLine: some View {
        let caption = String(call.caption.prefix(240))
        if !caption.isEmpty {
            Text(caption)
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .bidiIsland(for: caption, fallback: lang)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var guestCapLine: some View {
        if isEnded, let seconds = call.guestCapSeconds {
            let sentence = Strings.Voice.callGuestCap.fmt(lang, ArabicText.count(seconds, lang))
            Text(sentence)
                .font(FirasType.caption)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .bidiIsland(for: sentence, fallback: lang)
                .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private var diagnosticsLine: some View {
        if AppConfiguration.isDebug, let diagnostics = call.diagnostics {
            Text("Live: " + diagnostics.engine + " — " + diagnostics.reason)
                .font(FirasType.mono)
                .foregroundStyle(palette.textMuted)
                .lineLimit(2)
                .forceLTR()
        }
    }

    // MARK: - Consent

    private var consentCard: some View {
        VStack(spacing: 14) {
            Text(Strings.Voice.callConsentText(lang))
                .font(FirasType.label)
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.center)
                .bidiIsland(for: Strings.Voice.callConsentText(lang), fallback: lang)

            Button {
                consentVisible = false
                Task { await call.start() }
            } label: {
                Text(Strings.Voice.callConsentBtn(lang))
                    .font(FirasType.label)
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background { Capsule(style: .continuous).fill(palette.accent) }
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .surfaceCard(palette)
        .padding(.horizontal, 8)
    }

    // MARK: - Retry

    @ViewBuilder
    private var retryButton: some View {
        if isFailed {
            Button {
                didHaptic = false
                Task { await call.retry() }
            } label: {
                Text(Strings.Voice.callRetry(lang))
                    .font(FirasType.label)
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .overlay { Capsule(style: .continuous).stroke(palette.accentRing, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 20) { controlsStack }
        } else {
            controlsStack
        }
    }

    private var controlsStack: some View {
        HStack(spacing: 20) {
            muteButton
            endButton
            if call.speakerToggleAvailable { speakerButton }
        }
        .opacity(consentVisible ? 0.5 : 1)
        .disabled(consentVisible)
    }

    private var muteButton: some View {
        CallControlButton(
            symbol: call.isMuted ? "mic.slash.fill" : "mic.fill",
            label: call.isMuted ? Strings.Voice.callUnmute(lang) : Strings.Voice.callMute(lang),
            value: call.isMuted ? Strings.Voice.callOn(lang) : Strings.Voice.callOff(lang),
            palette: palette,
            tint: call.isMuted ? palette.accent : palette.textPrimary,
            filled: nil
        ) {
            call.toggleMute()
        }
        .keyboardShortcut(.space, modifiers: [])
    }

    private var endButton: some View {
        CallControlButton(
            symbol: "phone.down.fill",
            label: Strings.Voice.callEnd(lang),
            value: nil,
            palette: palette,
            tint: Color.white,
            filled: palette.error
        ) {
            hangUp()
        }
        .keyboardShortcut(.escape, modifiers: [])
    }

    private var speakerButton: some View {
        CallControlButton(
            symbol: call.speakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
            label: Strings.Voice.callSpeaker(lang),
            value: call.speakerOn ? Strings.Voice.callOn(lang) : Strings.Voice.callOff(lang),
            palette: palette,
            tint: call.speakerOn ? palette.accent : palette.textPrimary,
            filled: nil
        ) {
            Task { await call.toggleSpeaker() }
        }
    }

    // MARK: - Behaviour

    private func begin() async {
        guard !didStart else { return }
        didStart = true
        if Self.microphoneUndecided {
            consentVisible = true
            return
        }
        await call.start()
    }

    private func hangUp() {
        Task {
            await call.end(reason: "user")
            dismiss()
        }
    }

    private func reactTo(_ phase: CallEngine.Phase) {
        switch phase {
        case .listening, .speaking, .thinking:
            if !didHaptic {
                didHaptic = true
                Haptics.callConnected()
            }
        case .ended:
            Haptics.callEnded()
            announce(Strings.Voice.callEnded(lang))
            scheduleClose()
        case .failed:
            Haptics.error()
            announce(Strings.Voice.callError(lang))
        case .idle, .preparing, .minting, .connecting, .ending:
            break
        }
    }

    /// The ended state is readable for a beat, then the cover closes itself. A user who taps End
    /// never waits for it — `hangUp()` dismisses immediately.
    private func scheduleClose() {
        closeGeneration &+= 1
        let generation = closeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            MainActor.assumeIsolated {
                guard generation == self.closeGeneration else { return }
                self.dismiss()
            }
        }
    }

    private func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// `true` only before the user has ever answered the system prompt, which is the one moment
    /// the consent card exists for.
    private static var microphoneUndecided: Bool {
        AVAudioApplication.shared.recordPermission == .undetermined
    }

    // MARK: - Derived

    private var palette: FirasPalette { prefs.palette }

    private var lang: AppLanguage { prefs.lang }

    private var motionOn: Bool { FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion) }

    private var isFailed: Bool {
        if case .failed = call.phase { return true }
        return false
    }

    private var isEnded: Bool {
        if case .ended = call.phase { return true }
        return false
    }

    private var isBusyPhase: Bool {
        switch call.phase {
        case .preparing, .minting, .connecting, .thinking, .ending: return true
        default: return false
        }
    }

    private var orbMode: OrbView.Mode {
        switch call.phase {
        case .idle, .ended, .failed: return .idle
        case .preparing, .minting, .connecting, .ending: return .connecting
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        }
    }

    private var statusText: String {
        switch call.phase {
        case .idle:
            return consentVisible
                ? Strings.Voice.callConsentText(lang)
                : Strings.Voice.callConnecting(lang)
        case .preparing, .minting, .connecting:
            return Strings.Voice.callConnecting(lang)
        case .listening:
            return call.isMuted
                ? Strings.Voice.callMuted(lang)
                : Strings.Voice.callListening(lang)
        case .thinking:
            return Strings.Voice.callThinking(lang)
        case .speaking:
            return Strings.Voice.callSpeaking(lang)
        case .ending:
            return Strings.Voice.callEnding(lang)
        case .ended:
            return Strings.Voice.callEnded(lang)
        case .failed:
            return Strings.Voice.callError(lang)
        }
    }
}

// MARK: - Control button

/// One 56 pt circle. `filled` paints a solid disc (the End button); otherwise the circle is
/// `.floating` glass, which is the only glass on this screen.
private struct CallControlButton: View {

    let symbol: String
    let label: String
    let value: String?
    let palette: FirasPalette
    let tint: Color
    let filled: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value ?? ""))
    }

    @ViewBuilder
    private var icon: some View {
        let glyph = Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 56, height: 56)

        if let filled {
            glyph
                .background { Circle().fill(filled) }
                .contentShape(Circle())
                .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)
        } else {
            glyph
                .firasGlass(.floating, palette: palette, in: AnyShape(Circle()))
                .contentShape(Circle())
        }
    }
}
