import AVFoundation
import Foundation
import OSLog

/// Permission, signal maths, diagnostics and the two small pieces of state a call has to remember
/// between attempts (`server-voice.md §7.3`). Split out of `CallEngine.swift` so the state machine
/// itself stays readable; every member is internal because the two files share them.
extension CallEngine {

    // MARK: - Microphone permission

    /// Asked in its own step, before the session is configured and before anything is minted — a
    /// refused call must not have cut the caller's music first.
    nonisolated static func requestMicrophonePermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission(completionHandler: { granted in
                continuation.resume(returning: granted)
            })
        }
    }

    // MARK: - Signal

    /// Full-scale RMS of an interleaved mono `Int16` frame. `loadUnaligned` because a `Data` slice
    /// carries no alignment guarantee.
    nonisolated static func rms(of frame: Data) -> Float {
        let count = frame.count / MemoryLayout<Int16>.size
        guard count > 0 else { return 0 }
        var sum = 0.0
        frame.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = raw.loadUnaligned(fromByteOffset: index * MemoryLayout<Int16>.size, as: Int16.self)
                let value = Double(Int16(littleEndian: sample)) / 32_768.0
                sum += value * value
            }
        }
        return Float((sum / Double(count)).squareRoot())
    }

    // MARK: - Diagnostics

    /// A short machine key for the diagnostics line. Never a server sentence: Arabic UI must never
    /// show an English refusal and vice versa, so only these keys ever reach the screen.
    nonisolated static func reason(for error: Error) -> String {
        if error is DeadlineError { return "timeout" }
        guard let api = error as? APIError else { return "failed" }
        switch api {
        case .offline: return "offline"
        case .transport: return "network"
        case .cancelled: return "cancelled"
        case .deadline: return "timeout"
        case .decoding: return "bad response"
        case .invalidURL: return "bad request"
        case .http(let status, let server, _):
            if let code = server.code, !code.isEmpty { return code }
            return "http \(status)"
        }
    }

    // MARK: - Gemini cooldown and the per-model no-search list

    /// A 1008/1011 close means the key's project is out of quota (or denied). Skip the Gemini rung
    /// for ten minutes — but never the OpenAI rung, which has nothing to do with it.
    nonisolated static func isGeminiCoolingDown() -> Bool {
        let until = UserDefaults.standard.double(forKey: "firas.live.geminiCooldownUntil")
        return until > Date().timeIntervalSince1970
    }

    nonisolated static func startGeminiCooldown() {
        UserDefaults.standard.set(Date().timeIntervalSince1970 + 600, forKey: "firas.live.geminiCooldownUntil")
    }

    /// The same close code, when the setup asked for `googleSearch`, means "this model has no search
    /// entitlement". Remember the model (last ten) and reconnect without the tool.
    nonisolated static func noSearchModels() -> [String] {
        UserDefaults.standard.stringArray(forKey: "firas.live.noSearchModels") ?? []
    }

    nonisolated static func rememberNoSearch(model: String) {
        guard !model.isEmpty else { return }
        var list = noSearchModels().filter { $0 != model }
        list.append(model)
        if list.count > 10 {
            list.removeFirst(list.count - 10)
        }
        UserDefaults.standard.set(list, forKey: "firas.live.noSearchModels")
    }

    // MARK: - Audio file sniffing

    /// `/api/tts` answers with either `audio/wav` (Gemini) or `audio/mpeg` (OpenAI/Edge) for the
    /// same text, so the bytes decide — never the previous reply's type.
    nonisolated static func fileExtension(for mime: String?, data: Data) -> String {
        if data.count >= 4 {
            let header = [UInt8](data.prefix(4))
            if header[0] == 0x52, header[1] == 0x49, header[2] == 0x46, header[3] == 0x46 {
                return "wav"
            }
        }
        let type = (mime ?? "").lowercased()
        if type.contains("wav") || type.contains("x-wav") { return "wav" }
        return "mp3"
    }

    /// Decodes one complete TTS body to 24 kHz `Int16` mono so it can be played through the call
    /// graph. Runs off the main actor; never opens a second audio player.
    nonisolated static func decode(audio: Data, mime: String?, rate: Double) -> Data? {
        guard !audio.isEmpty else { return nil }
        let name = "firas-call-\(UUID().uuidString).\(fileExtension(for: mime, data: audio))"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try audio.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            return try CallAudioGraph.pcm16(fromAudioFileAt: url, sampleRate: rate)
        } catch {
            Log.call.error("call could not decode a speech reply")
            return nil
        }
    }
}
