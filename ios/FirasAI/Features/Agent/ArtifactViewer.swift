import SwiftUI
import QuickLook
import UIKit
import WebKit

/// Opens one mission artifact inside the app.
///
/// The bytes are fetched by `AgentStore.artifactURL` — `URLSession` with the session cookie, never
/// a web view pointed at the endpoint — and land in our own temp folder. PDFs, images and Office
/// documents go to QuickLook; Markdown renders natively; JSON, text and code render as code; HTML
/// and SVG load into a non-persistent `WKWebView` restricted to that one folder.
struct ArtifactViewer: View {

    private let env: AppEnvironment
    private let jobID: String
    private let index: Int
    private let name: String
    private let type: String

    @State private var state: LoadState = .loading

    @Environment(\.dismiss) private var dismiss

    init(env: AppEnvironment, jobID: String, index: Int, name: String, type: String) {
        self.env = env
        self.jobID = jobID
        self.index = index
        self.name = name
        self.type = type
    }

    private enum LoadState: Equatable {
        case loading
        case failed(LText)
        case preview(URL)
        case web(URL)
        case markdown(URL, String)
        case code(URL, String, String?)
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.background)
                .navigationTitle(name.isEmpty ? Strings.Agent.openFile(lang) : name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Text(Strings.Common.close(lang))
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if let url = fileURL {
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                                    .accessibilityLabel(Text(Strings.Common.share(lang)))
                            }
                        }
                    }
                }
        }
        .firasSheetBackground(palette)
        .task(id: taskKey) { await load() }
    }

    private var taskKey: String { jobID + "#" + String(index) }

    private var fileURL: URL? {
        switch state {
        case .preview(let url), .web(let url):
            return url
        case .markdown(let url, _):
            return url
        case .code(let url, _, _):
            return url
        case .loading, .failed:
            return nil
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView().tint(palette.accent)
                Text(Strings.Agent.viewerLoading(lang))
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            EmptyStateView(
                title: message(lang),
                subtitle: name.isEmpty ? nil : name,
                buttonTitle: Strings.Common.retry(lang),
                palette: palette,
                action: {
                    state = .loading
                    Task { await load() }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .preview(let url):
            ArtifactQuickLook(url: url)
                .ignoresSafeArea(edges: .bottom)

        case .web(let url):
            ArtifactWebView(url: url)
                .ignoresSafeArea(edges: .bottom)

        case .markdown(_, let text):
            ScrollView {
                MarkdownView(
                    markdown: text,
                    messageID: "artifact-" + taskKey,
                    streaming: false,
                    lang: lang,
                    palette: palette,
                    prefs: env.prefs,
                    onFence: { _ in nil }
                )
                .padding(16)
                .readingColumn(env.prefs.contentWidth)
            }

        case .code(_, let text, let language):
            ScrollView {
                CodeBlockView(
                    code: text,
                    language: language,
                    palette: palette,
                    collapsible: false,
                    lang: lang
                )
                .padding(16)
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        guard case .loading = state else { return }
        guard let url = await env.agent.artifactURL(jobID: jobID, index: index, download: false) else {
            state = .failed(Strings.Agent.viewerFailed)
            return
        }
        let size = await ArtifactViewer.byteCount(of: url)
        let ext = ArtifactViewer.fileExtension(name: name, url: url)
        if size > 20 * 1024 * 1024 && ArtifactViewer.rendersAsText(ext) {
            state = .failed(Strings.Agent.viewerTooLarge)
            return
        }

        switch ext {
        case "md", "markdown":
            if let text = await ArtifactViewer.readText(at: url) {
                state = .markdown(url, text)
            } else {
                state = .preview(url)
            }
        case "json", "txt", "log", "csv", "tsv", "xml", "yml", "yaml", "js", "ts", "css", "py", "swift", "sh":
            if let text = await ArtifactViewer.readText(at: url) {
                state = .code(url, text, ArtifactViewer.codeLanguage(for: ext))
            } else {
                state = .preview(url)
            }
        case "html", "htm", "svg":
            state = .web(url)
        default:
            state = .preview(url)
        }
    }

    // MARK: - Off-main file work

    nonisolated static func byteCount(of url: URL) async -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    nonisolated static func readText(at url: URL) async -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return String(text.prefix(400_000))
    }

    nonisolated static func fileExtension(name: String, url: URL) -> String {
        let fromName = (name as NSString).pathExtension.lowercased()
        if !fromName.isEmpty { return fromName }
        return url.pathExtension.lowercased()
    }

    nonisolated static func rendersAsText(_ ext: String) -> Bool {
        ["md", "markdown", "json", "txt", "log", "csv", "tsv", "xml", "yml", "yaml",
         "js", "ts", "css", "py", "swift", "sh", "html", "htm", "svg"].contains(ext)
    }

    nonisolated static func codeLanguage(for ext: String) -> String? {
        switch ext {
        case "json": return "json"
        case "js": return "js"
        case "ts": return "ts"
        case "css": return "css"
        case "py": return "py"
        case "swift": return "swift"
        case "sh": return "bash"
        default: return nil
        }
    }
}

// MARK: - QuickLook

/// PDFs, images, Office documents and anything else the system can preview.
private struct ArtifactQuickLook: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - Sandboxed web view

/// HTML and SVG. Scripts are off, storage is non-persistent, and the read scope is the artifact's
/// own folder — nothing else on disk is reachable.
private struct ArtifactWebView: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard uiView.url != url else { return }
        uiView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}
