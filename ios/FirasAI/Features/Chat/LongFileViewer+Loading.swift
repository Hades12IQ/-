import Foundation
import SwiftUI
import CryptoKit

/// Where the reader is.
enum LongFileViewerPhase: Equatable {
    /// Nothing readable yet — the strip says what the server is doing.
    case loading
    /// At least one verified page is on screen; more may still arrive.
    case reading
    case failed(String)
}

/// One page of a long file, after its part was verified and its markers stripped.
struct LongFilePage: Identifiable, Sendable, Equatable {
    let id: Int
    let number: Int
    let title: String
    let markdown: String
}

// MARK: - Loading

extension LongFileViewer {

    /// What one pass over the manifest produced.
    private enum Pass {
        /// The job is over: complete, cancelled, or gone.
        case finished
        /// More parts are still coming.
        case waiting
        case failed(String)
    }

    /// Opens on whatever exists, then keeps the manifest under a gentle poll until the job ends.
    ///
    /// The cadence is deliberately unhurried — a long file takes minutes and the growing page list
    /// is what gives it life, not a faster poll (`server-chat-jobs-chats.md §3.2`). Every part is
    /// fetched exactly once, so returning to this screen resumes instead of starting over.
    @MainActor
    func run() async {
        var strikes = 0
        var wait: Double = 2

        while !Task.isCancelled {
            switch await loadOnce() {
            case .finished:
                return

            case .waiting:
                strikes = 0
                wait = min(8, wait + 1)
                await JobClock.rest(wait)

            case .failed(let message):
                strikes += 1
                // A reader who already has pages keeps them; only an empty screen becomes an error.
                if strikes >= 3 {
                    if pages.isEmpty { phase = .failed(message) }
                    return
                }
                await JobClock.rest(Double(strikes) * 2)
            }
        }
    }

    @MainActor
    private func loadOnce() async -> Pass {
        do {
            let manifest = try await env.api.longFileManifest(jobID: jobID)
            apply(manifest)

            let ready = max(0, manifest.partsDone)
            while loadedParts < ready {
                let index = loadedParts
                let part = try await env.api.longFilePart(jobID: jobID, index: index)
                switch await LongFileAssembly.pages(from: part) {
                case .success(let items):
                    append(items)
                case .failure:
                    return .failed(LongFileViewerCopy.checksum(lang))
                }
                loadedParts = index + 1
                if Task.isCancelled { return .finished }
            }

            if !pages.isEmpty {
                phase = .reading
            }

            if progress?.cancelled == true {
                if pages.isEmpty { phase = .failed(LongFileViewerCopy.cancelled(lang)) }
                return .finished
            }
            if manifest.complete && loadedParts >= ready {
                isComplete = true
                if pages.isEmpty {
                    phase = .failed(LongFileViewerCopy.emptyBody(lang))
                }
                return .finished
            }
            return .waiting
        } catch {
            // `409 artifact_not_ready` is the ordinary answer while the first batch is still being
            // written — it is a wait, not a failure.
            if let apiError = error as? APIError, apiError.status == 409 {
                return .waiting
            }
            if let apiError = error as? APIError, apiError.status == 404 {
                return .failed(LongFileViewerCopy.missing(lang))
            }
            if error is CancellationError { return .finished }
            return .failed(errorMessage(for: error))
        }
    }

    /// Everything the manifest tells the screen apart from the pages themselves.
    @MainActor
    private func apply(_ manifest: LongFileManifest) {
        if let value = manifest.progress { progress = value }
        if let format = manifest.format, !format.isEmpty { documentFormat = format }
        if documentTitle.isEmpty {
            documentTitle = LongFileViewer.firstNonEmpty(
                manifest.title,
                providedTitle,
                manifest.filename
            ) ?? ""
        }
        if manifest.complete { isComplete = true }
    }

    /// Appends verified pages without disturbing the page the reader is on, and without ever
    /// showing the same page twice — a re-read of a part must be idempotent.
    @MainActor
    private func append(_ items: [LongFilePage]) {
        guard !items.isEmpty else { return }
        var known = Set(pages.map(\.number))
        var merged = pages
        for item in items where !known.contains(item.number) {
            known.insert(item.number)
            merged.append(item)
        }
        merged.sort { $0.number < $1.number }
        pages = merged
    }

    private func errorMessage(for error: Error) -> String {
        switch ErrorPresenter.present(
            error,
            feature: nil,
            isGuest: env.session.isGuest,
            lang: lang
        ) {
        case .toast(let copy):
            return copy(lang)
        case .toastText(let text):
            return text
        case .sessionExpired:
            return Strings.Errors.sessionExpired(lang)
        default:
            return Strings.Errors.generic(lang)
        }
    }

    static func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Progress copy

    /// The same three sentences the transcript card shows (`app.js:41348`).
    func stageText(_ progress: LongFileProgress) -> String {
        switch progress.stage.trimmingCharacters(in: .whitespaces).lowercased() {
        case "writing": return FileCardCopy.longWriting(lang)
        case "qa": return FileCardCopy.longReviewing(lang)
        default: return FileCardCopy.longPlanning(lang)
        }
    }

    func fraction(_ progress: LongFileProgress) -> Double? {
        if progress.percent > 0 { return min(1, Double(progress.percent) / 100) }
        let total = progress.pagesTotal > 0 ? progress.pagesTotal : progress.targetPages
        guard total > 0, progress.pagesDone > 0 else { return nil }
        return min(1, Double(progress.pagesDone) / Double(total))
    }

    func counterText(_ progress: LongFileProgress) -> String {
        let done = max(0, progress.pagesDone)
        let total = progress.pagesTotal > 0 ? progress.pagesTotal : progress.targetPages
        guard total > 0 else { return ArabicText.count(done, lang) }
        return ArabicText.count(done, lang) + " / " + ArabicText.count(total, lang)
    }
}

// MARK: - Verification and assembly

enum LongFileAssemblyError: Error, Sendable {
    case checksum
}

/// Part verification and document assembly. Everything here is pure and runs off the main actor: a
/// 12-page part is a few hundred kilobytes of Arabic text to hash.
enum LongFileAssembly {

    static func pages(from part: LongFilePart) async -> Result<[LongFilePage], LongFileAssemblyError> {
        await Task.detached(priority: .userInitiated) { () -> Result<[LongFilePage], LongFileAssemblyError> in
            if let expected = part.sha256, !expected.isEmpty {
                let actual = LongFileAssembly.sha256Hex(part.records)
                guard actual == expected.lowercased() else { return .failure(.checksum) }
            }
            let built = part.records.map { record in
                LongFilePage(
                    id: record.pageNumber,
                    number: record.pageNumber,
                    title: LongFileAssembly.stripMarkers(record.title)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    markdown: LongFileAssembly.stripMarkers(record.markdown)
                )
            }
            return .success(built)
        }.value
    }

    /// `SHA-256(JSON.stringify(records.map(r => [pageNumber, title, markdown])))`, lowercase hex
    /// (`server-chat-jobs-chats.md §4.4`). The JSON is written by hand because Foundation's writer
    /// escapes `/` and JavaScript's does not — one escaped slash and every checksum fails.
    static func sha256Hex(_ records: [LongFilePart.Record]) -> String {
        var canonical = "["
        for (index, record) in records.enumerated() {
            if index > 0 { canonical += "," }
            canonical += "["
            canonical += String(record.pageNumber)
            canonical += ","
            canonical += jsonString(record.title)
            canonical += ","
            canonical += jsonString(record.markdown)
            canonical += "]"
        }
        canonical += "]"

        let digest = SHA256.hash(data: Data(canonical.utf8))
        var hex = ""
        hex.reserveCapacity(64)
        for byte in digest {
            hex += String(format: "%02x", Int(byte))
        }
        return hex
    }

    /// `JSON.stringify` semantics for a string: only the seven mandatory escapes plus `\u00xx`
    /// for the remaining control characters. Everything else stays as raw UTF-8.
    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\u{08}":
                out += "\\b"
            case "\u{0C}":
                out += "\\f"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", Int(scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    /// Drops every `<!-- FIRAS_… -->` comment (question-bank markers, page markers) and keeps any
    /// ordinary HTML comment the author wrote.
    static func stripMarkers(_ markdown: String) -> String {
        guard markdown.contains("<!--") else { return markdown }
        var output = ""
        var rest = Substring(markdown)

        while let open = rest.range(of: "<!--") {
            output += String(rest[rest.startIndex..<open.lowerBound])
            guard let close = rest.range(of: "-->", range: open.upperBound..<rest.endIndex) else {
                output += String(rest[open.lowerBound...])
                return output
            }
            let inner = String(rest[open.upperBound..<close.lowerBound])
            if !inner.contains("FIRAS_") {
                output += "<!--" + inner + "-->"
            }
            rest = rest[close.upperBound...]
        }

        output += String(rest)
        return output
    }

    /// The whole file as one markdown document, for export.
    static func document(title: String, pages: [LongFilePage]) -> String {
        var parts: [String] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            parts.append("# " + trimmedTitle)
        }
        for page in pages {
            if !page.title.isEmpty {
                parts.append("## " + page.title)
            }
            let body = page.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                parts.append(body)
            }
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Copy

/// Progress wording is `app.js:41348` verbatim (`server-chat-jobs-chats.md §4.2`), reused from
/// `FileCardCopy`; the rest is new copy in the same voice, because the web has no long-file reader
/// to borrow it from.
enum LongFileViewerCopy {
    static let untitled = LText(ar: "ملف فِراس", en: "Firas document")
    static let export = LText(ar: "تصدير", en: "Export")
    static let exportSection = LText(ar: "صدّر بصيغة", en: "Export as")
    static let preview = LText(ar: "افتح المستند", en: "Open the document")
    static let saveToFiles = LText(ar: "حفظ في الملفات", en: "Save to Files")
    static let saved = LText(ar: "حُفظ الملف.", en: "Saved.")
    static let assembling = LText(ar: "يجمع صفحات الملف…", en: "Assembling the file's pages…")
    static let cancelled = LText(ar: "أُوقف إنشاء الملف.", en: "The file was stopped.")

    static let failedTitle = LText(ar: "تعذّر فتح الملف", en: "Couldn't open the file")
    static let checksum = LText(
        ar: "وصل جزء من الملف تالفًا ولم يُعرض. أعد المحاولة.",
        en: "One part of the file arrived corrupted and was not shown. Try again."
    )
    static let missing = LText(
        ar: "لم يعد هذا الملف موجودًا على الخادم.",
        en: "This file is no longer on the server."
    )
    static let emptyBody = LText(
        ar: "لم يصل أي محتوى من هذا الملف.",
        en: "No content came back for this file."
    )

    static let previousPage = LText(ar: "الصفحة السابقة", en: "Previous page")
    static let nextPage = LText(ar: "الصفحة التالية", en: "Next page")
    /// `%@ / %@` — both numbers arrive already in Arabic-Indic digits when the UI is Arabic.
    static let pageCounter = LText(ar: "%@ / %@", en: "%@ / %@")
}
