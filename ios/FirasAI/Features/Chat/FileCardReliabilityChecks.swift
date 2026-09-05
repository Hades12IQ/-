#if DEBUG
import SwiftUI
import UIKit
import PDFKit

/// Mounted production controls register their actual closures here. No alternate export path.
@MainActor
final class FileCardReliabilityProbe {
    var open: (() -> Void)?
    var blockedReason: String?
    var buttonSize: CGSize = .zero
    var exportStarted: (() -> Void)?
    var sourceReceived: String?
    var buildCompleted = false
    var export: ExportController.Export?
    var previewAppeared = false
    var diagnostics: [String: Any] = [:]
}

private struct FileCardReliabilityKey: EnvironmentKey {
    static let defaultValue: FileCardReliabilityProbe? = nil
}

extension EnvironmentValues {
    var fileCardReliabilityProbe: FileCardReliabilityProbe? {
        get { self[FileCardReliabilityKey.self] }
        set { self[FileCardReliabilityKey.self] = newValue }
    }
}

@MainActor
enum FileCardReliabilityChecks {
    struct Result {
        var failures: [String] = []
        var metrics: [String: Double] = [:]
        var diagnostics: [String: Any] = [:]
    }

    /// Includes the actual card parser, selected-version source, button callback, file writer,
    /// and native preview sheet. This invokes a real mounted action; it is not a physical tap.
    static func run(env: AppEnvironment, request: String, markdown: String,
                    expectedMarkers: [String], expectedMathCount: Int? = nil) async -> Result {
        var result = modelChecks()
        guard ProcessInfo.processInfo.arguments.contains("--reliability-smoke") else {
            result.failures.append("File-card fixture requires the isolated smoke launch")
            return result
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController,
              presenter.presentedViewController == nil else {
            result.failures.append("File-card fixture has no free foreground presenter")
            return result
        }
        let key = "file-card-smoke-" + UUID().uuidString
        let question = ChatMessage(role: .user, content: request, cid: key)
        let prior = sampleDocument(marker: "WRONG_VERSION_SENTINEL")
        var answer = ChatMessage(role: .assistant, content: prior, cid: key,
            alts: [AnswerVersion(content: prior), AnswerVersion(content: markdown)], altAt: 1,
            status: .failed("Fixture transport failure"))
        env.chat.setConversation(ChatConversation(id: key, title: "File card reliability",
            messages: [question, answer], ephemeral: true), forKey: key)
        defer { env.chat.setConversation(nil, forKey: key) }

        let probe = FileCardReliabilityProbe()
        let host = UIHostingController(rootView: FixtureView(env: env, conversationID: key)
            .environment(\.fileCardReliabilityProbe, probe)
            .environment(\.firasMathPersistenceAllowed, false))
        host.modalPresentationStyle = .fullScreen
        presenter.present(host, animated: false)
        let mountedAt = Date()
        while probe.blockedReason == nil && Date().timeIntervalSince(mountedAt) < 5 {
            await JobClock.rest(0.03)
        }
        let blocked = probe.blockedReason != nil && probe.open == nil
        result.metrics["failedCardActionsBlocked"] = blocked ? 1 : 0
        if !blocked { result.failures.append("Mounted failed file card exposed actions or omitted its failure") }
        answer.status = .delivered
        env.chat.mutate(key) { $0.messages = [question, answer] }
        let readyAt = Date()
        while probe.open == nil && Date().timeIntervalSince(readyAt) < 5 {
            await JobClock.rest(0.03)
        }
        result.metrics["openWidth"] = Double(probe.buttonSize.width)
        result.metrics["openHeight"] = Double(probe.buttonSize.height)
        if probe.open == nil { result.failures.append("The actual PDF card did not expose its Open action") }
        if probe.buttonSize.width < 44 || probe.buttonSize.height < 44 {
            result.failures.append("File-card Open target is smaller than 44 points")
        }
        guard probe.open != nil else {
            host.dismiss(animated: false)
            await JobClock.rest(0.1)
            return result
        }
        let openedAt = Date()
        probe.open?()
        while !probe.buildCompleted && Date().timeIntervalSince(openedAt) < 90 {
            await JobClock.rest(0.05)
        }
        let previewAt = Date()
        while !probe.previewAppeared && Date().timeIntervalSince(previewAt) < 3 {
            await JobClock.rest(0.03)
        }
        result.metrics["openToExportMilliseconds"] = Date().timeIntervalSince(openedAt) * 1000
        result.metrics["fullSelectedSourcePassed"] = probe.sourceReceived == markdown ? 1 : 0
        result.metrics["nativePreviewPresented"] = probe.previewAppeared && host.presentedViewController != nil ? 1 : 0
        result.diagnostics = probe.diagnostics
        if let expectedMathCount {
            let page = (probe.diagnostics["page"] as? [String: Any]) ?? [:]
            let layout = (probe.diagnostics["layout"] as? [String: Any]) ?? [:]
            let mathCount = (page["mathCount"] as? NSNumber)?.intValue
            let mathErrors = (page["mathErrors"] as? NSNumber)?.intValue
            let overflow = (layout["mathOverflow"] as? NSNumber)?.intValue
            let bodyOverflow = (layout["bodyOverflow"] as? NSNumber)?.doubleValue
            let brokenImages = (layout["brokenImages"] as? NSNumber)?.intValue
            result.metrics["mathCount"] = Double(mathCount ?? -1)
            result.metrics["mathErrors"] = Double(mathErrors ?? -1)
            result.metrics["mathOverflow"] = Double(overflow ?? -1)
            result.metrics["bodyOverflow"] = bodyOverflow ?? -1
            result.metrics["brokenImages"] = Double(brokenImages ?? -1)
            if mathCount != expectedMathCount || mathErrors != 0 {
                result.failures.append("Card PDF did not typeset every expected formula without errors")
            }
            if overflow != 0 || brokenImages != 0 || bodyOverflow == nil || (bodyOverflow ?? 0) > 2 {
                result.failures.append("Card PDF failed its real layout/image overflow checks")
            }
            if probe.diagnostics["stage"] as? String != "completed" {
                result.failures.append("Card PDF printer did not reach its completed stage")
            }
        }
        if probe.sourceReceived != markdown { result.failures.append("File card passed truncated or unselected source to ExportController") }
        if !probe.previewAppeared || host.presentedViewController == nil {
            result.failures.append("File-card Open did not present its native PDF preview")
        }
        if let export = probe.export, export.format == .pdf,
           let document = PDFDocument(url: export.url) {
            if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let destination = directory.appendingPathComponent("reliability-100-integrals.pdf")
                do { try Data(contentsOf: export.url).write(to: destination, options: .atomic) }
                catch { result.failures.append("Could not save the card-exported PDF for visual inspection") }
            }
            let text = document.string ?? ""
            result.metrics["pageCount"] = Double(document.pageCount)
            result.metrics["bytes"] = Double(export.byteCount)
            result.metrics["matchedMarkers"] = Double(expectedMarkers.filter { text.contains($0) }.count)
            for marker in expectedMarkers where !text.contains(marker) {
                result.failures.append("Card-exported PDF is missing fixture marker: " + marker)
            }
            if text.contains("WRONG_VERSION_SENTINEL") {
                result.failures.append("Card exported a different answer version")
            }
            if document.pageCount < 2 { result.failures.append("Full document card export was not paginated") }
        } else {
            result.failures.append("File-card Open did not deliver a readable PDF")
        }
        let users = env.chat.conversation(key)?.messages.filter { $0.role == .user } ?? []
        result.metrics["unchangedUserRows"] = users == [question] ? 1 : 0
        if users != [question] { result.failures.append("Opening a file changed or duplicated its user question") }
        host.dismiss(animated: false)
        let dismissedAt = Date()
        while presenter.presentedViewController != nil && Date().timeIntervalSince(dismissedAt) < 3 {
            await JobClock.rest(0.03)
        }
        return result
    }

    private struct FixtureView: View {
        let env: AppEnvironment
        let conversationID: String
        var body: some View {
            ScrollView {
                if let message = env.chat.conversation(conversationID)?.messages.last {
                    AssistantTurnView(env: env, message: message, conversationID: conversationID,
                        product: .ai, palette: env.prefs.palette, lang: env.prefs.lang,
                        scale: env.prefs.fontScale, motionOn: false, isStreaming: false,
                        liveText: "", liveReasoning: "", phaseLabel: nil, isLatest: false,
                        showsPlanPill: false, expectsAsk: false)
                    .padding(20)
                }
            }.background(env.prefs.palette.background)
        }
    }

    private static func modelChecks() -> Result {
        var result = Result()
        let source = sampleDocument(marker: "COMPLETE")
        guard let fence = FirasFence.firstFence(in: source),
              case .file(let meta) = FirasFence.parse(name: fence.name, body: fence.body) else {
            return .init(failures: ["File metadata fixture could not be parsed"])
        }
        let message = ChatMessage(role: .assistant, content: source, cid: "readiness")
        var assertions = 0
        func check(_ condition: Bool, _ failure: String) {
            assertions += 1
            if !condition { result.failures.append(failure) }
        }
        func readiness(_ row: ChatMessage, streaming: Bool = false) -> DocumentCardReadiness {
            .evaluate(message: row, meta: meta, request: "Create a PDF", isStreaming: streaming, lang: .english)
        }
        check(readiness(message).canOpen, "Complete authored document was blocked")
        check(!readiness(message, streaming: true).canOpen, "Streaming document offered Open")
        var changed = message
        changed.status = .failed("server failure")
        check(readiness(changed).errorText != nil && !readiness(changed).canOpen, "Failed turn appeared ready")
        changed.status = .stopped
        check(readiness(changed).canOpen, "Complete stopped document was discarded")
        changed.content = String(source.prefix(upTo: source.range(of: "</body>")!.lowerBound))
        check(!readiness(changed).canOpen, "Stopped partial HTML appeared ready")
        changed.status = .delivered
        check(!readiness(changed).canOpen, "Reloaded partial HTML appeared ready")
        changed.content = String(source[fence.range])
        check(!readiness(changed).canOpen, "Metadata-only document appeared ready")
        let snapshot = DocumentCardSnapshot(message: message, ownerID: "owner-a")
        check(snapshot.matches(message, ownerID: "owner-a"), "Matching export snapshot was rejected")
        check(!snapshot.matches(message, ownerID: "owner-b"), "Export survived an account change")
        check(!snapshot.matches(nil, ownerID: "owner-a"), "Removed message accepted a stale export")
        changed = message
        changed.alts = [AnswerVersion(content: source), AnswerVersion(content: sampleDocument(marker: "NEW"))]
        changed.altAt = 1
        check(!snapshot.matches(changed, ownerID: "owner-a"), "Changed answer version accepted a stale export")
        check(ChatTurnActions.markdown(changed) == changed.visibleContent, "Card source did not follow selected version")
        check(!AssistantTurnView.hidingDesign(in: source).contains("<html>"), "File card exposed its hidden HTML source")
        let bare = String(source.replacingOccurrences(of: "```html\n", with: "").dropLast(3))
        check(!AssistantTurnView.hidingDesign(in: bare).contains("<html>"), "Bare HTML after file metadata was exposed")
        let incompleteBare = String(bare.prefix(upTo: bare.range(of: "</body>")!.lowerBound))
        check(!AssistantTurnView.hidingDesign(in: incompleteBare).contains("<html>"), "Growing bare HTML after file metadata was exposed")
        check(!AssistantTurnView.hidingDesign(in: bare.replacingOccurrences(of: "\n", with: "\r\n")).contains("<html>"),
              "CRLF bare HTML after file metadata was exposed")
        check(!AssistantTurnView.hidingDesign(in: bare.replacingOccurrences(of: "```", with: "~~~")).contains("<html>"),
              "Tilde-fenced file metadata exposed bare HTML")
        check(FirasFence.firstFence(in: source.replacingOccurrences(of: "```", with: "~~~~"))?.name == "firas-file",
              "Long tilde file fence did not parse")
        check(FirasFence.firstFence(in: "````firas-file\n{}\n```\n") == nil,
              "Shorter closing fence incorrectly ended file metadata")
        result.metrics["modelAssertions"] = Double(assertions)
        return result
    }

    private static func sampleDocument(marker: String) -> String {
        """
        ```firas-file
        {"filename":"card_reliability.pdf","title":"Card reliability"}
        ```
        ```html
        <!doctype html><html><head><title>Card reliability</title></head><body><p>\(marker)</p></body></html>
        ```
        """
    }
}
#endif
