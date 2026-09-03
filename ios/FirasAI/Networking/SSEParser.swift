import Foundation

/// One dispatched server-sent event.
///
/// `/api/chat` sends only `data:` lines (`{"choices":[{"delta":{"content":"…"}}]}` and a final
/// `[DONE]`). `/api/agent/job-stream` sends `id:` + `event:` + `data:` triples plus `: keepalive`
/// comments and an opening `retry: 3000`. Both land here.
struct SSEFrame: Sendable, Equatable {
    let event: String?
    let id: String?
    let data: String

    /// The sentinel `/api/chat` writes as its last line.
    var isDone: Bool { data == "[DONE]" }
}

/// Byte stream → frames, per the EventSource line protocol.
///
/// The loop reads raw bytes rather than `AsyncBytes.lines` on purpose: `AsyncLineSequence` drops
/// empty lines, and in SSE the empty line *is* the dispatch signal.
///
/// - partial lines are buffered across chunks; `\n`, `\r\n` and a lone `\r` all terminate a line;
/// - a line starting with `:` is a comment and is dropped (the agent stream's `: keepalive`);
/// - `retry:` is dropped — the app owns its own reconnect policy;
/// - repeated `data:` lines in one event are joined with `\n`;
/// - a blank line dispatches; an event with no `data:` line dispatches nothing;
/// - a trailing event with no closing blank line is dispatched at end of stream;
/// - `data: [DONE]` is delivered as an ordinary frame (`SSEFrame.isDone`), never swallowed.
enum SSEParser {
    static func frames(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<SSEFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                var accumulator = SSEAccumulator()
                var lineBytes: [UInt8] = []
                var pendingCarriageReturn = false

                do {
                    for try await byte in bytes {
                        switch byte {
                        case 0x0D: // CR
                            try Task.checkCancellation()
                            if let frame = accumulator.consume(
                                line: String(decoding: lineBytes, as: UTF8.self)
                            ) {
                                continuation.yield(frame)
                            }
                            lineBytes.removeAll(keepingCapacity: true)
                            pendingCarriageReturn = true

                        case 0x0A: // LF
                            if pendingCarriageReturn {
                                pendingCarriageReturn = false
                                continue
                            }
                            try Task.checkCancellation()
                            if let frame = accumulator.consume(
                                line: String(decoding: lineBytes, as: UTF8.self)
                            ) {
                                continuation.yield(frame)
                            }
                            lineBytes.removeAll(keepingCapacity: true)

                        default:
                            pendingCarriageReturn = false
                            lineBytes.append(byte)
                        }
                    }

                    if !lineBytes.isEmpty,
                       let frame = accumulator.consume(
                           line: String(decoding: lineBytes, as: UTF8.self)
                       ) {
                        continuation.yield(frame)
                    }
                    if let frame = accumulator.flush() {
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Line-by-line SSE state. Kept separate so the byte loop above stays readable.
private struct SSEAccumulator {
    private var event: String?
    private var id: String?
    private var dataLines: [String] = []

    /// Feeds one line (without its terminator). Returns a frame when the line dispatched one.
    mutating func consume(line: String) -> SSEFrame? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }

        let parsed = Self.split(line)
        switch parsed.field {
        case "data":
            dataLines.append(parsed.value)
        case "event":
            event = parsed.value.isEmpty ? nil : parsed.value
        case "id":
            id = parsed.value.isEmpty ? nil : parsed.value
        default:
            // "retry" and any field the server adds later.
            break
        }
        return nil
    }

    /// Dispatches whatever has accumulated, if anything.
    mutating func flush() -> SSEFrame? {
        defer {
            event = nil
            id = nil
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEFrame(event: event, id: id, data: dataLines.joined(separator: "\n"))
    }

    /// `field: value`, with at most one leading space stripped from the value. A line with no
    /// colon is a field name whose value is empty.
    private static func split(_ line: String) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else {
            return (line, "")
        }
        let field = String(line[line.startIndex..<colon])
        var valueStart = line.index(after: colon)
        if valueStart < line.endIndex, line[valueStart] == " " {
            valueStart = line.index(after: valueStart)
        }
        return (field, String(line[valueStart..<line.endIndex]))
    }
}
