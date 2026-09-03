import Foundation

/// Wraps raw little-endian PCM16 in the 44-byte canonical RIFF/WAVE header the transcription
/// endpoint expects, and base64s it with the alphabet the server's validator accepts.
///
/// `server-voice.md §4.1`: after the optional `data:` prefix is stripped the payload must match
/// `^[A-Za-z0-9+/=]+$` — **standard** alphabet, no URL-safe `-`/`_`, and **no line breaks**.
/// `Data.base64EncodedString()` with no options produces exactly that; passing any
/// `.lineLength…` option would produce a body the server rejects with `bad audio`.
enum WAVEncoder {

    /// Bytes per sample for PCM16.
    private static let bytesPerSample = 2

    /// The canonical header length: `RIFF` + `fmt ` (16-byte PCM chunk) + `data`.
    private static let headerLength = 44

    /// A complete `.wav` file: 44-byte header followed by `pcm16` untouched.
    ///
    /// - Parameters:
    ///   - pcm16: interleaved little-endian signed 16-bit samples.
    ///   - sampleRate: frames per second (16 000 for dictation).
    ///   - channels: 1 for mono. Values below 1 are clamped to 1.
    static func wav(pcm16: Data, sampleRate: Int, channels: Int) -> Data {
        let channelCount = max(1, channels)
        let rate = max(1, sampleRate)
        let bitsPerSample = bytesPerSample * 8
        let blockAlign = channelCount * bytesPerSample
        let byteRate = rate * blockAlign
        let dataSize = pcm16.count
        let riffSize = headerLength - 8 + dataSize

        var out = Data(capacity: headerLength + dataSize)

        // "RIFF" <size> "WAVE"
        out.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(&out, UInt32(clamping: riffSize))
        out.append(contentsOf: Array("WAVE".utf8))

        // "fmt " chunk — 16 bytes, format 1 (PCM integer).
        out.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(&out, 16)
        appendUInt16(&out, 1)
        appendUInt16(&out, UInt16(clamping: channelCount))
        appendUInt32(&out, UInt32(clamping: rate))
        appendUInt32(&out, UInt32(clamping: byteRate))
        appendUInt16(&out, UInt16(clamping: blockAlign))
        appendUInt16(&out, UInt16(clamping: bitsPerSample))

        // "data" chunk.
        out.append(contentsOf: Array("data".utf8))
        appendUInt32(&out, UInt32(clamping: dataSize))
        out.append(pcm16)

        return out
    }

    /// Standard-alphabet base64, one single line, no `data:` prefix.
    static func base64(_ wav: Data) -> String {
        wav.base64EncodedString()
    }

    // MARK: - Little-endian writers

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }
}
