import Foundation
import OSLog

/// The third rung: record until the caller stops → `/api/transcribe` → an ordinary chat turn with
/// the call system prompt → `/api/tts`, played through the same graph
/// (`web-voice-call-mic.md §6`). It is slower than a live engine and it is announced, never silent —
/// `diagnostics` names it so a signed-in caller knows which engine answered.
///
/// Two engines never answer one question: this loop only ever runs when both live rungs have been
/// torn down, and a single `for await` over the microphone stream is the only consumer, so nothing
/// is recorded while Firas is speaking.
extension CallEngine {

    func startThreeHop() async {
        rung = .threeHop
        record(engine: CallRung.threeHop.rawValue, model: "", reason: lastCloseReason.isEmpty ? "fallback" : lastCloseReason)
        if hardDeadline == nil {
            hardDeadline = Date().addingTimeInterval(600 - 1.5)
        }
        guard let frames = await prepareGraph(targetRate: 16_000) else {
            await finish(reason: "audio", failed: true)
            return
        }
        guard !isEnding else { return }

        isConnected = true
        lastVoiceAt = Date()
        setPhase(.listening)
        Haptics.callConnected()
        threeHopTask = Task { [weak self] in
            await self?.runThreeHopLoop(frames)
        }
    }

    /// Voice activity over 100 ms frames: speech at ≥ 0.047 full-scale RMS, a turn closes after
    /// ~1.05 s of quiet, and no take runs past 15 s. Takes below 1 500 bytes are discarded and the
    /// loop keeps listening, exactly like the web.
    private func runThreeHopLoop(_ frames: AsyncStream<Data>) async {
        let hop = ThreeHopCall(api: api)

        // The web speaks `callHello` before it starts listening; a silent line after "Connecting…"
        // reads as a dropped call.
        await speak(Strings.Voice.callHello(prefs.language))
        guard !isEnding else { return }
        setPhase(.listening)

        var recorded = Data()
        var hadSpeech = false
        var quietFrames = 0
        var frameCount = 0
        var skip = 0

        for await frame in frames {
            guard !isEnding, !Task.isCancelled else { return }

            // The stream buffers the newest frames while a turn is in flight; the first few after a
            // reply are the tail of Firas's own voice, so they are dropped.
            if skip > 0 {
                skip -= 1
                continue
            }
            if isMuted {
                recorded.removeAll(keepingCapacity: true)
                hadSpeech = false
                quietFrames = 0
                frameCount = 0
                continue
            }

            frameCount += 1
            let level = Self.rms(of: frame)
            if level >= 0.047 {
                hadSpeech = true
                quietFrames = 0
                lastVoiceAt = Date()
            } else if hadSpeech {
                quietFrames += 1
            }
            if hadSpeech {
                recorded.append(frame)
            }

            let settled = hadSpeech && quietFrames >= 11
            let tooLong = frameCount >= 150
            guard settled || tooLong else { continue }

            let take = recorded
            recorded.removeAll(keepingCapacity: true)
            hadSpeech = false
            quietFrames = 0
            frameCount = 0
            guard take.count >= 1_500 else { continue }

            await takeTurn(take, hop: hop)
            guard !isEnding, !Task.isCancelled else { return }
            skip = 5
            setCaption("")
            setPhase(.listening)
        }
    }

    private func takeTurn(_ pcm: Data, hop: ThreeHopCall) async {
        setPhase(.thinking)
        let wav = WAVEncoder.wav(pcm16: pcm, sampleRate: 16_000, channels: 1)
        let encoded = WAVEncoder.base64(wav)
        // The server refuses anything under 4 000 base64 characters.
        guard encoded.count >= 4_000 else { return }

        // The call never runs the slow tiers: the web caps a call at `pro` and restores the user's
        // pick on hang-up. Nothing is written back to preferences, so there is nothing to restore.
        let tier: ModelTier = (prefs.tier == .ultra || prefs.tier == .max) ? .pro : prefs.tier

        do {
            let result = try await hop.answer(
                wavBase64: encoded,
                dialect: prefs.dictationDialect,
                history: threeHopHistory,
                lang: prefs.language,
                tier: tier
            )
            guard !isEnding else { return }

            lastVoiceAt = Date()
            threeHopHistory.append(OutgoingMessage(role: "user", content: result.transcript))
            threeHopHistory.append(OutgoingMessage(role: "assistant", content: result.reply))
            if threeHopHistory.count > 12 {
                threeHopHistory.removeFirst(threeHopHistory.count - 12)
            }
            setPhase(.speaking)
            setCaption(String(result.reply.prefix(240)))
            await play(audio: result.audio, mime: result.mime)
        } catch {
            guard !isEnding else { return }
            let key = Self.reason(for: error)
            if key == "offline" || key == "network" {
                await end(reason: "disconnected")
                return
            }
            // "Nothing clear was heard" and one-off engine failures keep the call alive: the caller
            // simply speaks again.
            setCaption("")
        }
        lastVoiceAt = Date()
    }

    /// Decodes off the main actor and plays through the call graph — a call never opens a second
    /// audio player against its own session.
    private func play(audio: Data, mime: String?) async {
        guard let graph, !isEnding else { return }
        let rate: Double = 24_000
        let payload = audio
        let type = mime
        let decoded = await Task.detached(priority: .userInitiated) {
            CallEngine.decode(audio: payload, mime: type, rate: rate)
        }.value
        guard let pcm = decoded, !pcm.isEmpty, !isEnding else { return }

        graph.schedule(pcm16: pcm, sampleRate: rate)
        let seconds = Double(pcm.count / MemoryLayout<Int16>.size) / rate
        await JobClock.rest(seconds + 0.16)
    }

    private func speak(_ text: String) async {
        guard !isEnding, graph != nil else { return }
        setPhase(.speaking)
        setCaption(String(text.prefix(240)))
        let client = api
        let spoken = String(text.prefix(1_300))
        let language = Self.speechLanguage(for: text)
        do {
            let response = try await client.tts(text: spoken, lang: language)
            guard !isEnding else { return }
            await play(audio: response.data, mime: response.mime)
        } catch {
            Log.call.error("the call could not speak a line")
        }
        setCaption("")
    }

    /// The web's `detectLang`: one Arabic code point anywhere makes the whole line Arabic.
    nonisolated static func speechLanguage(for text: String) -> String {
        for scalar in text.unicodeScalars where (0x0600...0x06FF).contains(scalar.value) {
            return "ar"
        }
        return "en"
    }
}
