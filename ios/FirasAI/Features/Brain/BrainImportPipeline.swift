import Foundation

/// What one finished import produced. `serverOCRPages` is the only OCR number that was ever sent
/// to the server; `deviceOCRPages` is the local badge for pages Vision read on this phone.
struct BrainImportOutcome: Sendable, Equatable {
    let documentID: String
    let title: String
    let kind: BrainDocumentKind
    let unit: BrainDocumentUnit
    let records: Int
    let parts: Int
    let deviceOCRPages: Int
    let serverOCRPages: Int
    /// The already-localized OCR notice (`ocrCap` / `ocrPartial` / `visionOut`), if one applies.
    let notice: String?
}

/// Every reason an import stops that has its own sentence. Anything else — 401, 403, 429 without
/// a `limit`, 5xx — is rethrown as the original `APIError` so `ErrorPresenter` decides.
enum BrainImportError: Error, Sendable, Equatable {
    case unsupportedType
    case unreadable
    case noText
    case engineBusy
    case documentLimit
    case dailyPageLimit
    case tooLarge
    case cancelled

    /// The web's verbatim toast for this failure (`web-brain-ux.md §5.1, §6.2`).
    /// `nil` for a cancel: the reader asked for it, so nothing needs saying.
    var message: LText? {
        switch self {
        case .unsupportedType: return Strings.Brain.unsupported
        case .unreadable: return Strings.Brain.readFail
        case .noText: return Strings.Brain.noText
        case .engineBusy: return Strings.Brain.ocrAllEmpty
        case .documentLimit: return Strings.Brain.limitDocs
        case .dailyPageLimit: return Strings.Brain.limitPages
        case .tooLarge: return Strings.Brain.tooLarge
        case .cancelled: return nil
        }
    }
}

/// One file, from a picked URL to an indexed document.
///
/// Kind detection → on-device extraction (PDFKit, Vision, ZIPFoundation) → the OCR rule → part
/// splitting → sequential `POST /api/brain/doc`. Everything expensive happens inside a detached
/// task, so a 300-page scanned textbook never touches the main thread, and the upload loop holds a
/// `BackgroundHold` so leaving the app mid-upload does not strand a half-written document.
///
/// The store owns progress and toasts: this type reports `BrainImportProgress.Stage` values and
/// either returns an outcome or throws.
@MainActor
final class BrainImportPipeline {

    private let api: APIClient
    private var stopped = false
    private(set) var isRunning = false

    init(api: APIClient) {
        self.api = api
    }

    /// Stops the next step. A part already in flight finishes — the server has no abort route and
    /// a half-written document is deleted from the library, not cancelled mid-POST (`§6.8`).
    func cancel() {
        stopped = true
    }

    // MARK: - Run

    /// - Parameters:
    ///   - visionLeft: `limits.visionLeft` from the last library read. `0` means the site-wide
    ///     vision budget is spent (or no key is configured) and no page leaves the device.
    ///   - onStage: called on the main actor for every phase change.
    func run(
        url: URL,
        forceVision: Bool,
        visionLeft: Int,
        lang: AppLanguage,
        onStage: @escaping @MainActor @Sendable (BrainImportProgress.Stage) -> Void
    ) async throws -> BrainImportOutcome {
        stopped = false
        isRunning = true
        defer { isRunning = false }

        let filename = url.lastPathComponent
        guard let kind = BrainDocumentExtractor.kind(forFilename: filename) else {
            throw BrainImportError.unsupportedType
        }

        let forward: @Sendable (BrainImportProgress.Stage) -> Void = { stage in
            Task { @MainActor in onStage(stage) }
        }
        let client = api
        let budget = max(0, visionLeft)

        let prepared: (document: ExtractedBrainDocument, parts: [[BrainPage]])
        do {
            prepared = try await Task.detached(priority: .userInitiated) {
                try await Self.prepare(
                    url: url,
                    filename: filename,
                    kind: kind,
                    forceVision: forceVision,
                    visionBudget: budget,
                    lang: lang,
                    api: client,
                    forward: forward
                )
            }.value
        } catch is CancellationError {
            throw BrainImportError.cancelled
        }

        try checkStopped()

        let document = prepared.document
        let parts = prepared.parts
        guard !parts.isEmpty else { throw BrainImportError.noText }

        let hold = BackgroundExecutor.hold(name: "brain-upload")
        defer { hold.end() }

        var documentID: String?
        for (index, part) in parts.enumerated() {
            try checkStopped()
            onStage(.uploading(index + 1, parts.count))
            let request = BrainUploadRequest(
                title: document.title,
                kind: document.kind,
                unit: document.unit,
                pages: part,
                docId: documentID,
                ocr: documentID == nil && document.serverOCRPages > 0
                    ? document.serverOCRPages
                    : nil
            )
            do {
                let response = try await api.brainAddDoc(request)
                if documentID == nil, !response.id.isEmpty { documentID = response.id }
            } catch {
                throw Self.mapUpload(error)
            }
        }

        guard let identifier = documentID else { throw BrainImportError.unreadable }
        onStage(.done)

        return BrainImportOutcome(
            documentID: identifier,
            title: document.title,
            kind: document.kind,
            unit: document.unit,
            records: parts.reduce(0) { $0 + $1.count },
            parts: parts.count,
            deviceOCRPages: document.deviceOCRPages,
            serverOCRPages: document.serverOCRPages,
            notice: Self.notice(for: document, lang: lang)
        )
    }

    // MARK: - Splitting

    /// `brainSplitPages` (app.js:85373): records sharing a `p` are one group and are never cut
    /// apart — otherwise a spreadsheet sheet is charged once per part. A group larger than the
    /// budget simply becomes its own part; nothing ever throws here.
    nonisolated static func splitParts(_ pages: [BrainPage]) -> [[BrainPage]] {
        var parts: [[BrainPage]] = []
        var current: [BrainPage] = []
        var characters = 0
        var index = 0

        while index < pages.count {
            let page = pages[index].p
            var group: [BrainPage] = []
            var groupCharacters = 0
            while index < pages.count, pages[index].p == page {
                group.append(pages[index])
                groupCharacters += pages[index].text.count
                index += 1
            }
            if !current.isEmpty,
               characters + groupCharacters > BrainImportLimits.partCharacters
                || current.count + group.count > BrainImportLimits.partRecords {
                parts.append(current)
                current = []
                characters = 0
            }
            current.append(contentsOf: group)
            characters += groupCharacters
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: - Private

    private func checkStopped() throws {
        if stopped || Task.isCancelled { throw BrainImportError.cancelled }
    }

    /// Everything that must not run on the main thread: reading the bytes, extraction, the readers
    /// and the split.
    private nonisolated static func prepare(
        url: URL,
        filename: String,
        kind: BrainDocumentKind,
        forceVision: Bool,
        visionBudget: Int,
        lang: AppLanguage,
        api: APIClient,
        forward: @escaping @Sendable (BrainImportProgress.Stage) -> Void
    ) async throws -> (document: ExtractedBrainDocument, parts: [[BrainPage]]) {
        forward(.reading(0, 1))

        let data: Data
        do {
            data = try BrainDocumentExtractor.read(url: url)
        } catch {
            throw BrainImportError.unreadable
        }

        var document: ExtractedBrainDocument
        do {
            switch kind {
            case .pdf:
                document = try await BrainDocumentExtractor.extractPDF(
                    data: data,
                    title: BrainDocumentExtractor.title(fromFilename: filename),
                    forceVision: forceVision,
                    serverVisionBudget: visionBudget,
                    onReading: { done, total in forward(.reading(done, total)) },
                    onVision: { done, total in forward(.ocr(done, total)) },
                    serverVision: { base64, page in
                        await serverRead(api: api, base64: base64, page: page, lang: lang)
                    }
                )
            case .image:
                forward(.ocr(0, 1))
                document = try BrainDocumentExtractor.extractImage(
                    data: data,
                    title: BrainDocumentExtractor.title(fromFilename: filename)
                )
                if document.pages.isEmpty, visionBudget > 0,
                   let base64 = BrainDocumentExtractor.imageJPEGBase64(data: data) {
                    let text = await serverRead(api: api, base64: base64, page: 1, lang: lang)
                    if let text, text.count >= BrainDocumentExtractor.recognisedTextFloor {
                        document = ExtractedBrainDocument(
                            title: document.title,
                            kind: .image,
                            unit: .page,
                            pages: [BrainPage(page: 1, text: text)],
                            deviceOCRPages: 0,
                            serverOCRPages: 1,
                            visionWanted: 1,
                            visionAttempted: 1
                        )
                    }
                }
                forward(.ocr(1, 1))
            case .text:
                document = try BrainDocumentExtractor.extractText(
                    data: data,
                    title: BrainDocumentExtractor.title(fromFilename: filename)
                )
                forward(.reading(1, 1))
            case .docx, .pptx, .xlsx:
                document = try BrainDocumentExtractor.extractOffice(
                    data: data,
                    filename: filename,
                    kind: kind
                )
                forward(.reading(1, 1))
            }
        } catch let error as BrainExtractionError {
            throw map(error)
        } catch is CancellationError {
            throw BrainImportError.cancelled
        } catch {
            throw BrainImportError.unreadable
        }

        // `useful` (app.js:85423): an empty record still costs a page against the daily quota.
        let useful = document.pages.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !useful.isEmpty else { throw BrainImportError.noText }
        return (document, splitParts(useful))
    }

    private nonisolated static func map(_ error: BrainExtractionError) -> BrainImportError {
        switch error {
        case .unsupportedType: return .unsupportedType
        case .unreadableDocument: return .unreadable
        case .emptyDocument: return .noText
        case .visionEngineBusy: return .engineBusy
        }
    }

    /// `web-brain-ux.md §6.4` and `server-brain.md §6.4`: only the two `limit` refusals and the
    /// size refusals have their own copy; everything else keeps its `APIError` so the presenter
    /// can open the sign-up sheet or say "session expired".
    private nonisolated static func mapUpload(_ error: Error) -> Error {
        guard let apiError = error as? APIError,
              case let APIError.http(status, server, raw) = apiError
        else { return error }
        if status == 429, server.code == "limit" || raw.contains("\"limit\"") {
            if raw.contains("pages") { return BrainImportError.dailyPageLimit }
            if raw.contains("docs") { return BrainImportError.documentLimit }
        }
        if status == 413 { return BrainImportError.tooLarge }
        return error
    }

    private nonisolated static func notice(for document: ExtractedBrainDocument, lang: AppLanguage) -> String? {
        guard document.visionWanted > 0 else { return nil }
        if document.visionAttempted == 0 {
            return Strings.Brain.visionOut(lang)
        }
        if document.visionAttempted < document.visionWanted {
            return Strings.Brain.ocrCap.fmt(
                lang,
                ArabicText.count(document.visionAttempted, lang),
                ArabicText.count(document.visionWanted, lang)
            )
        }
        if document.serverOCRPages < document.visionAttempted {
            return Strings.Brain.ocrPartial.fmt(
                lang,
                ArabicText.count(document.serverOCRPages, lang),
                ArabicText.count(document.visionAttempted, lang)
            )
        }
        return nil
    }

    // MARK: - Server vision

    /// One page image through `/api/chat` with the web's verbatim OCR prompt
    /// (`server-brain.md §6.9`): tier `pro`, `nomem`, one image per request, no `cid`. Every
    /// failure collapses to `nil` — the page then keeps whatever the text layer gave it.
    private nonisolated static func serverRead(
        api: APIClient,
        base64: String,
        page: Int,
        lang: AppLanguage
    ) async -> String? {
        let system = lang == .arabic
            ? BrainImportLimits.ocrSystemArabic
            : BrainImportLimits.ocrSystemEnglish
        let userLine = lang == .arabic
            ? "انسخ نص هذه الصفحة (رقم " + String(page) + ")."
            : "Transcribe the text of this page (page " + String(page) + ")."
        let request = ChatStreamRequest(
            messages: [
                OutgoingMessage(role: "system", content: system, images: nil),
                OutgoingMessage(role: "user", content: userLine, images: [base64]),
            ],
            tier: "pro",
            think: false,
            cid: "",
            chatId: nil,
            product: ProductKind.ai.wireValue,
            nomem: true,
            nokb: nil,
            agent: nil
        )
        do {
            let text = try await withDeadline(seconds: 120) { () async throws -> String in
                var collected = ""
                let stream = await api.chatStream(request)
                for try await frame in stream {
                    let payload = frame.data.trimmingCharacters(in: .whitespacesAndNewlines)
                    if payload.isEmpty { continue }
                    if payload == "[DONE]" { break }
                    if let piece = content(fromSSEPayload: payload) { collected += piece }
                    if collected.count > 120_000 { break }
                }
                return collected
            }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        } catch {
            return nil
        }
    }

    private nonisolated static func content(fromSSEPayload payload: String) -> String? {
        guard let data = payload.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let root = object as? [String: Any] else { return nil }
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else {
            return nil
        }
        guard let delta = first["delta"] as? [String: Any] else { return nil }
        guard let text = delta["content"] as? String, !text.isEmpty else { return nil }
        return text
    }

}

/// Numbers and prompts the pipeline's `nonisolated` halves read. Kept at file scope so a
/// main-actor-isolated static never has to be reached from a detached task.
private enum BrainImportLimits {

    /// `BRAIN_MAX_UPLOAD_CHARS` (app.js:80836).
    static let partCharacters = 700_000
    /// `BRAIN_MAX_RECORDS_PER_POST` (app.js:85372), under the server's 1 200.
    static let partRecords = 1_000

    /// The web's OCR system prompt, verbatim (`server-brain.md §6.9`).
    static let ocrSystemArabic = "أنت محرّك OCR دقيق. انسخ كل ما في صورة الصفحة نسخًا حرفيًّا كاملًا — كل عنوان وفقرة وجدول ومعادلة (الرياضيات بـ LaTeX) وكل رقم، بالترتيب نفسه. لا تلخّص ولا تشرح ولا تترجم ولا تضف شيئًا من عندك. إن كانت الصفحة فارغة فلا تُخرج شيئًا. أعطِ النص المستخرَج فقط."

    static let ocrSystemEnglish = "You are a precise OCR engine. Transcribe EVERYTHING on this page image completely and verbatim — every heading, paragraph, table, equation (math in LaTeX) and number, in the original order. Do not summarize, explain, translate or add anything. If the page is blank, output nothing. Output ONLY the transcribed text."
}
