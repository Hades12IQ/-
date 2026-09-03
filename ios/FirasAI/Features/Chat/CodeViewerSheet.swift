import SwiftUI
import UIKit
import WebKit

/// The full-screen artifact viewer for a ```` ```firas-code ```` deliverable: a `معاينة / الكود`
/// segmented control over a sandboxed, non-persistent `WKWebView` and the opaque `CodeBlockView`
/// (`web-chat-ux.md §8.6`, `design-brief.md §7.9`).
///
/// The web view is the only one in the chat product. It is deliberately crippled: a private data
/// store, a `firas-preview://` base URL, and a navigation delegate that cancels every navigation
/// that is not the artifact itself — a generated page can never reach the network or the session
/// cookie (`server-code-brainask.md §2.9`).
struct CodeViewerSheet: View {

    private let env: AppEnvironment
    private let messageID: String?
    private let providedCode: String?
    private let providedLanguage: String?
    private let providedName: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var artifact: CodeArtifact?
    @State private var resolved = false
    @State private var tab: CodeViewerTab = .preview
    @State private var copied = false

    /// The router's entry point: `AppSheet.codeViewer(messageID:)`. The code is resolved out of the
    /// message the id names, wherever that conversation currently lives in `ChatStore`.
    init(env: AppEnvironment, messageID: String) {
        self.env = env
        self.messageID = messageID
        self.providedCode = nil
        self.providedLanguage = nil
        self.providedName = nil
    }

    /// The direct entry point used by `CodeBlockView`'s Preview button, which already holds the
    /// code and never needs a store lookup.
    init(env: AppEnvironment, code: String, language: String?, filename: String?) {
        self.env = env
        self.messageID = nil
        self.providedCode = code
        self.providedLanguage = language
        self.providedName = filename
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle(Text(navigationTitleText))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .firasSheetBackground(palette)
        .onAppear { resolve() }
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    private var navigationTitleText: String {
        if let name = artifact?.filename, !name.isEmpty { return name }
        return CodeViewerCopy.title(lang)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Text(Strings.Common.close(lang))
            }
            .foregroundStyle(palette.accent)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if let artifact {
                Button {
                    copy(artifact.code)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(copied ? palette.success : palette.accent)
                .accessibilityLabel(Text(Strings.Common.copy(lang)))
            }
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if !resolved {
            loadingState
        } else if let artifact {
            readyState(artifact)
        } else {
            missingState
        }
    }

    private var loadingState: some View {
        SkeletonView(kind: .transcript, palette: palette, motionOn: motionOn)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .accessibilityLabel(Text(CodeViewerCopy.loading(lang)))
    }

    private var missingState: some View {
        EmptyStateView(
            title: CodeViewerCopy.missingTitle(lang),
            subtitle: CodeViewerCopy.missingBody(lang),
            buttonTitle: Strings.Common.close(lang),
            palette: palette,
            action: { dismiss() }
        )
        .frame(maxHeight: .infinity)
    }

    private func readyState(_ artifact: CodeArtifact) -> some View {
        VStack(spacing: 12) {
            if artifact.isPreviewable {
                segmented
            }
            if artifact.isPreviewable, tab == .preview {
                previewPane(artifact)
            } else {
                codePane(artifact)
            }
        }
        .padding(.top, 10)
    }

    private var segmented: some View {
        Picker(selection: $tab) {
            Text(CodeViewerCopy.preview(lang)).tag(CodeViewerTab.preview)
            Text(CodeViewerCopy.code(lang)).tag(CodeViewerTab.code)
        } label: {
            Text(CodeViewerCopy.title(lang))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
    }

    private func previewPane(_ artifact: CodeArtifact) -> some View {
        CodeArtifactWebView(html: artifact.previewHTML)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity)
    }

    private func codePane(_ artifact: CodeArtifact) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                if let name = artifact.filename, !name.isEmpty {
                    Text(name)
                        .font(FirasType.mono)
                        .foregroundStyle(palette.textMuted)
                        .forceLTR()
                }
                CodeBlockView(
                    code: artifact.code,
                    language: artifact.language,
                    palette: palette,
                    collapsible: false,
                    lang: lang,
                    // This sheet already owns the معاينة / الكود picker above; without this the
                    // Code tab would nest a second preview card inside it.
                    allowsInlinePreview: false
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 28)
        }
    }

    private var motionOn: Bool {
        FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion)
    }

    // MARK: - Actions

    private func resolve() {
        guard !resolved else { return }
        if let providedCode {
            let trimmed = providedCode.trimmingCharacters(in: .whitespacesAndNewlines)
            artifact = trimmed.isEmpty
                ? nil
                : CodeArtifact(code: providedCode, language: providedLanguage, filename: providedName)
        } else if let messageID {
            artifact = CodeViewerSheet.artifact(forMessageID: messageID, in: env.chat.conversations)
        } else {
            artifact = nil
        }
        if let artifact, !artifact.isPreviewable {
            tab = .code
        }
        resolved = true
    }

    private static func artifact(
        forMessageID messageID: String,
        in conversations: [String: ChatConversation]
    ) -> CodeArtifact? {
        for conversation in conversations.values {
            for message in conversation.messages where message.id == messageID {
                return CodeArtifact.parse(message.content)
            }
        }
        return nil
    }

    private func copy(_ code: String) {
        UIPasteboard.general.string = code
        Haptics.select()
        copied = true
        let flag = $copied
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            flag.wrappedValue = false
        }
    }
}

// MARK: - Tabs

private enum CodeViewerTab: Hashable {
    case preview
    case code
}

// MARK: - The artifact

/// The code the sheet shows, however it was found: the `firas-code` fence of a message, the first
/// plain fenced block in it, or a body handed in directly.
private struct CodeArtifact: Equatable {

    let code: String
    let language: String?
    let filename: String?

    var isPreviewable: Bool {
        switch (language ?? "").lowercased() {
        case "html", "htm", "svg", "xml+svg":
            return true
        default:
            break
        }
        let head = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.hasPrefix("<svg")
    }

    /// A complete document for the web view. An SVG fragment and a bare body are wrapped; a full
    /// page is used as it stands.
    var previewHTML: String {
        let head = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if head.hasPrefix("<!doctype") || head.hasPrefix("<html") {
            return code
        }
        let meta = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        if (language ?? "").lowercased() == "svg" || head.hasPrefix("<svg") {
            let style = "<style>html,body{margin:0;padding:12px;background:#ffffff;}"
                + "svg{max-width:100%;height:auto;display:block;margin:0 auto;}</style>"
            return "<!DOCTYPE html><html><head>" + meta + style + "</head><body>" + code + "</body></html>"
        }
        let style = "<style>html,body{margin:0;padding:12px;background:#ffffff;"
            + "font-family:-apple-system,system-ui,sans-serif;}</style>"
        return "<!DOCTYPE html><html><head>" + meta + style + "</head><body>" + code + "</body></html>"
    }

    static func parse(_ markdown: String) -> CodeArtifact? {
        if let fence = FirasFence.firstFence(in: markdown), fence.name == "firas-code",
           let parsed = FirasFence.parse(name: fence.name, body: fence.body) {
            switch parsed {
            case .code(let meta, let body):
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return CodeArtifact(
                        code: body,
                        language: meta.lang ?? meta.ext,
                        filename: meta.name
                    )
                }
            default:
                break
            }
        }
        guard let plain = firstPlainBlock(in: markdown) else { return nil }
        return CodeArtifact(code: plain.code, language: plain.language, filename: nil)
    }

    /// The first ```` ``` ```` block whose info string is not a Firas fence name.
    private static func firstPlainBlock(in markdown: String) -> (language: String?, code: String)? {
        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") else {
                index += 1
                continue
            }
            let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let name = String(info.prefix(while: { !$0.isWhitespace })).lowercased()
            if FirasFence.recognisedNames.contains(name) {
                index += 1
                continue
            }
            var body: [String] = []
            var cursor = index + 1
            var closed = false
            while cursor < lines.count {
                if lines[cursor].trimmingCharacters(in: .whitespaces) == "```" {
                    closed = true
                    break
                }
                body.append(lines[cursor])
                cursor += 1
            }
            let code = body.joined(separator: "\n")
            if closed, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (language: name.isEmpty ? nil : name, code: code)
            }
            index = cursor + 1
        }
        return nil
    }
}

// MARK: - The sandboxed web view

/// A `WKWebView` with a non-persistent data store and no way out: every navigation whose scheme is
/// not the artifact's own is cancelled, so a generated page cannot follow a link, submit a form or
/// load a remote frame.
private struct CodeArtifactWebView: UIViewRepresentable {

    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.suppressesIncrementalRendering = false

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.isOpaque = false
        view.backgroundColor = UIColor.clear
        view.scrollView.backgroundColor = UIColor.clear
        view.scrollView.contentInsetAdjustmentBehavior = .always
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        uiView.loadHTMLString(html, baseURL: URL(string: "firas-preview://artifact/"))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {

        var loadedHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            if scheme == nil || scheme == "firas-preview" || scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

// MARK: - Copy

/// Verbatim from the web's STR table (`web-chat-ux.md` Appendix A) where it exists.
private enum CodeViewerCopy {
    static let title = LText(ar: "الكود", en: "Code")
    static let preview = LText(ar: "معاينة", en: "Preview")
    static let code = LText(ar: "الكود", en: "Code")
    static let loading = LText(ar: "جارٍ التحضير…", en: "Preparing…")
    static let missingTitle = LText(ar: "لا يوجد كود هنا", en: "There is no code here")
    static let missingBody = LText(
        ar: "لم نعثر على ملف الكود في هذه الرسالة — قد تكون حُذفت أو أُعيد توليدها.",
        en: "The code for this message could not be found — it may have been deleted or regenerated."
    )
}
