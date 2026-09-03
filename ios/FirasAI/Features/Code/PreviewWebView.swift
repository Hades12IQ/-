import SwiftUI
import UIKit
import WebKit

/// The preview pane: chrome strip, device frame, the sandboxed `WKWebView`, and the run status
/// strip underneath (`web-code-ux.md §5.4`, `design-brief.md §7.9`).
///
/// The web view is deliberately caged (`audit-ios-agent-code.md §B.3 C7`): a non-persistent data
/// store, no link preview, no navigation away from the assembled document, external links handed
/// to Safari, project files served by a `firas-proj://` scheme handler, and the `__fcw` console
/// hook injected before any author script.
struct PreviewWebView: View {

    enum DevicePreset: String, CaseIterable, Identifiable, Sendable {
        case mobile, tablet, fluid

        var id: String { rawValue }

        var title: LText {
            switch self {
            case .mobile: return Strings.CodeUI.deviceMobile
            case .tablet: return Strings.CodeUI.deviceTablet
            case .fluid: return Strings.CodeUI.deviceDesktop
            }
        }

        func size(landscape: Bool) -> CGSize? {
            switch self {
            case .mobile: return landscape ? CGSize(width: 844, height: 390) : CGSize(width: 390, height: 844)
            case .tablet: return landscape ? CGSize(width: 1112, height: 834) : CGSize(width: 834, height: 1112)
            case .fluid: return nil
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .mobile: return 11
            case .tablet: return 15
            case .fluid: return 8
            }
        }
    }

    enum RunState: String, Sendable {
        case idle, running, ok, warn, fail

        var title: LText {
            switch self {
            case .idle: return Strings.CodeUI.runIdle
            case .running: return Strings.CodeUI.runRunning
            case .ok: return Strings.CodeUI.runOk
            case .warn: return Strings.CodeUI.runWarn
            case .fail: return Strings.CodeUI.runFail
            }
        }
    }

    private let env: AppEnvironment
    private let externalReload: Int
    private let onCreateIndex: (() -> Void)?
    private let onAskAI: (() -> Void)?
    private let onOpenConsole: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var link = PreviewWebLink()
    @State private var device: DevicePreset = .fluid
    @State private var landscape = false
    @State private var autoReload = true
    @State private var document: PreviewDocument?
    @State private var isAssembling = false
    @State private var reloadToken = 0
    @State private var rebuildToken = 0
    @State private var runState: RunState = .idle
    @State private var runErrors = 0
    @State private var runWarnings = 0
    @State private var runStartedAt: Date?
    @State private var runMilliseconds: Int?

    init(
        env: AppEnvironment,
        reloadToken: Int = 0,
        onCreateIndex: (() -> Void)? = nil,
        onAskAI: (() -> Void)? = nil,
        onOpenConsole: (() -> Void)? = nil
    ) {
        self.env = env
        self.externalReload = reloadToken
        self.onCreateIndex = onCreateIndex
        self.onAskAI = onAskAI
        self.onOpenConsole = onOpenConsole
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var isCompact: Bool { sizeClass == .compact }

    /// Cheap enough to recompute per body pass: file count plus every path and byte length.
    private var signature: String {
        guard let project = env.code.project else { return "none" }
        var value = String(project.files.count)
        for file in project.files {
            value += "|" + file.path + ":" + String(file.content.utf8.count)
        }
        return value
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            stage
            runStrip
        }
        .background(palette.background)
        .onAppear { rebuild() }
        .onChange(of: signature) { _, _ in scheduleRebuild() }
        .onChange(of: externalReload) { _, _ in rebuild() }
        .onChange(of: device) { _, _ in reloadToken += 1 }
        .onChange(of: landscape) { _, _ in reloadToken += 1 }
    }

    // MARK: - Chrome

    private var chrome: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(palette.borderStrong)
                        .frame(width: 8, height: 8)
                        .opacity(1 - Double(index) * 0.15)
                }
            }
            .accessibilityHidden(true)

            Text(verbatim: addressText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .forceLTR()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    Capsule(style: .continuous).fill(palette.surfaceSunken)
                }

            controls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 2) {
            if !isCompact {
                devicePicker
                if device != .fluid {
                    FirasIconButton(
                        symbol: "arrow.2.squarepath",
                        label: (landscape ? Strings.CodeUI.rotateToPortrait : Strings.CodeUI.rotateToLandscape)(lang),
                        palette: palette
                    ) {
                        Haptics.select()
                        landscape.toggle()
                    }
                }
            }

            FirasIconButton(
                symbol: autoReload ? "repeat" : "pause.circle",
                label: (autoReload ? Strings.CodeUI.autoReloadOn : Strings.CodeUI.autoReloadOff)(lang),
                palette: palette
            ) {
                Haptics.select()
                autoReload.toggle()
            }
            .opacity(autoReload ? 1 : 0.55)

            FirasIconButton(
                symbol: "arrow.clockwise",
                label: Strings.CodeUI.reloadPreview(lang),
                palette: palette
            ) {
                Haptics.select()
                clearConsole()
                rebuild()
            }
        }
    }

    private var devicePicker: some View {
        Menu {
            ForEach(DevicePreset.allCases) { preset in
                Button {
                    device = preset
                } label: {
                    Text(verbatim: preset.title(lang))
                }
            }
        } label: {
            Text(verbatim: device.title(lang))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }
        }
        .accessibilityLabel(Text(verbatim: device.title(lang)))
    }

    private var addressText: String {
        let geometry: String
        if let size = device.size(landscape: landscape) {
            geometry = String(Int(size.width)) + " × " + String(Int(size.height))
        } else {
            geometry = "localhost"
        }
        return geometry + " · " + (document?.entry ?? "—")
    }

    // MARK: - Stage

    @ViewBuilder
    private var stage: some View {
        Group {
            if env.code.project == nil {
                EmptyStateView(
                    title: Strings.CodeUI.previewNoProject(lang),
                    subtitle: nil,
                    buttonTitle: nil,
                    palette: palette,
                    action: nil
                )
            } else if isAssembling && document == nil {
                loading
            } else if let document {
                canvas(document)
            } else {
                emptyPreview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.backgroundSubtle)
    }

    private var loading: some View {
        VStack(spacing: 12) {
            FirasActivityLabel(
                text: Strings.CodeUI.previewBuilding(lang),
                palette: palette,
                motionOn: FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyPreview: some View {
        VStack(spacing: 12) {
            EmptyStateView(
                title: Strings.CodeUI.previewEmptyTitle(lang),
                subtitle: Strings.CodeUI.previewEmptyBody(lang),
                buttonTitle: Strings.CodeUI.previewCreateIndex(lang),
                palette: palette,
                action: { createIndex() }
            )
            if let onAskAI {
                Button {
                    onAskAI()
                } label: {
                    Text(verbatim: Strings.CodeUI.previewAskFiras(lang))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func canvas(_ document: PreviewDocument) -> some View {
        GeometryReader { proxy in
            let frameSize = device.size(landscape: landscape)
            if let frameSize, proxy.size.width > 1, proxy.size.height > 1 {
                let scale = min(
                    1,
                    min(proxy.size.width / frameSize.width, proxy.size.height / frameSize.height)
                )
                web(document)
                    .frame(width: frameSize.width, height: frameSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous)
                            .strokeBorder(palette.borderStrong, lineWidth: 1)
                    }
                    .scaleEffect(scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                web(document)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private func web(_ document: PreviewDocument) -> some View {
        PreviewCanvas(
            document: document,
            reloadToken: reloadToken,
            link: link,
            onConsole: { line in receive(line) },
            onFinish: { finishRun() },
            onFail: { failRun() }
        )
        .accessibilityLabel(Text(verbatim: Strings.CodeUI.previewTab(lang)))
    }

    // MARK: - Run strip

    private var runStrip: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(runColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(verbatim: runState.title(lang))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)

            if runErrors > 0 {
                Text(verbatim: Strings.CodeUI.errorCount(runErrors, lang))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.error)
            }
            if runWarnings > 0 {
                Text(verbatim: Strings.CodeUI.warningCount(runWarnings, lang))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.codeWarn)
            }

            Spacer(minLength: 0)

            if let runMilliseconds {
                Text(verbatim: Self.durationText(runMilliseconds))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.textMuted)
                    .forceLTR()
            }

            if runErrors > 0, let onOpenConsole {
                Button {
                    onOpenConsole()
                } label: {
                    Text(verbatim: Strings.CodeUI.openConsole(lang))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.border).frame(height: 0.5)
        }
    }

    private var runColor: Color {
        switch runState {
        case .idle: return palette.textMuted
        case .running: return palette.accent
        case .ok: return palette.codeOk
        case .warn: return palette.codeWarn
        case .fail: return palette.error
        }
    }

    /// `cwRunBarMs`: `412ms`, `2.3s`, `12s`.
    static func durationText(_ milliseconds: Int) -> String {
        if milliseconds < 1000 { return String(milliseconds) + "ms" }
        if milliseconds < 10_000 {
            return String(format: "%.1fs", locale: nil, Double(milliseconds) / 1000)
        }
        return String(milliseconds / 1000) + "s"
    }

    // MARK: - Building

    @State private var lastStylesheetPush = Date.distantPast

    private func scheduleRebuild() {
        guard autoReload else { return }
        let editingCSS = PreviewAssembler.fileExtension(of: env.code.selectedPath ?? "") == "css"
        /* THROTTLED, because this is not only a person typing. The rebuild below is properly
           token-debounced, but the stylesheet push was not — and during a LIVE Firas Code build a
           .css file changes about eight times a second, so every sheet in the project was
           re-serialised and re-injected on each of them. Twice a second is faster than an eye
           can follow and an order of magnitude less work. */
        if editingCSS {
            let now = Date()
            if now.timeIntervalSince(lastStylesheetPush) >= 0.5 {
                lastStylesheetPush = now
                pushLiveStylesheets()
            }
        }
        rebuildToken += 1
        let token = rebuildToken
        let current = $rebuildToken
        DispatchQueue.main.asyncAfter(deadline: .now() + (editingCSS ? 2.5 : 0.7)) {
            MainActor.assumeIsolated {
                guard current.wrappedValue == token else { return }
                rebuild()
            }
        }
    }

    private func rebuild() {
        guard let project = env.code.project else {
            document = nil
            return
        }
        let entry = preferredEntry(in: project)
        isAssembling = true
        Task {
            let assembled = await Self.assemble(project: project, entry: entry)
            document = assembled
            isAssembling = false
            if assembled != nil {
                runErrors = 0
                runWarnings = 0
                runState = .running
                runStartedAt = Date()
                runMilliseconds = nil
                reloadToken += 1
            } else {
                runState = .idle
            }
        }
    }

    /// Nonisolated and `async`, so a 180 000-character project is assembled off the main actor.
    private nonisolated static func assemble(project: CodeProject, entry: String?) async -> PreviewDocument? {
        PreviewAssembler.assemble(project: project, entryPath: entry)
    }

    /// The page the reader is looking at wins, exactly like the web's page selector.
    private func preferredEntry(in project: CodeProject) -> String? {
        guard let selected = env.code.selectedPath, PreviewAssembler.isHTML(selected) else { return nil }
        let normalized = PreviewAssembler.normalize(selected)
        return project.files.contains { PreviewAssembler.normalize($0.path) == normalized } ? normalized : nil
    }

    private func pushLiveStylesheets() {
        guard let project = env.code.project, let webView = link.webView else { return }
        for file in project.files where PreviewAssembler.fileExtension(of: file.path) == "css" {
            let payload: [String] = [PreviewAssembler.normalize(file.path), file.content]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                  let json = String(data: data, encoding: .utf8) else { continue }
            webView.evaluateJavaScript(
                "window.__fcwCss && window.__fcwCss.apply(null, " + json + ");",
                completionHandler: nil
            )
        }
    }

    // MARK: - Console and verdict

    private func receive(_ line: ConsoleLine) {
        var lines = env.code.consoleLines
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        env.code.consoleLines = lines

        switch line.level {
        case "error": runErrors += 1
        case "warn": runWarnings += 1
        default: break
        }
    }

    private func clearConsole() {
        env.code.consoleLines = []
        runErrors = 0
        runWarnings = 0
    }

    private func finishRun() {
        if let started = runStartedAt {
            runMilliseconds = max(0, Int(Date().timeIntervalSince(started) * 1000))
        }
        if runErrors > 0 {
            runState = .fail
        } else if runWarnings > 0 {
            runState = .warn
        } else {
            runState = .ok
        }
    }

    private func failRun() {
        runState = .fail
        if let started = runStartedAt {
            runMilliseconds = max(0, Int(Date().timeIntervalSince(started) * 1000))
        }
    }

    // MARK: - Starter page

    private func createIndex() {
        if let onCreateIndex {
            onCreateIndex()
            return
        }
        let path = "index.html"
        env.code.addFile(path: path)
        env.code.updateFile(path: path, content: lang == .arabic ? Self.starterArabic : Self.starterEnglish)
        env.code.selectedPath = path
        Haptics.select()
    }

    private static let starterArabic = """
    <!DOCTYPE html>
    <html lang="ar" dir="rtl">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>صفحتي</title>
      <style>
        body{font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0}
      </style>
    </head>
    <body>
      <h1>مرحبًا</h1>
    </body>
    </html>

    """

    private static let starterEnglish = """
    <!DOCTYPE html>
    <html lang="en" dir="ltr">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>My page</title>
      <style>
        body{font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0}
      </style>
    </head>
    <body>
      <h1>Hello</h1>
    </body>
    </html>

    """
}

// MARK: - Link

/// Lets the pane reach the live web view for the CSS live push without owning it.
final class PreviewWebLink {
    weak var webView: WKWebView?
    init() {}
}

// MARK: - The web view

private struct PreviewCanvas: UIViewRepresentable {

    let document: PreviewDocument
    let reloadToken: Int
    let link: PreviewWebLink
    let onConsole: @MainActor (ConsoleLine) -> Void
    let onFinish: @MainActor () -> Void
    let onFail: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: PreviewAssembler.scheme)
        /* AND THE ISLAND'S SCHEME, so a page carrying equations can load KaTeX from the
           bundle. Registered whether or not this particular page has any: a handler that
           is never asked costs nothing, and registering it conditionally would mean
           rebuilding the configuration when the project changes. */
        configuration.setURLSchemeHandler(MathIslandAssets.shared, forURLScheme: MathIslandAssets.scheme)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: PreviewAssembler.consoleHook,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.add(coordinator, name: "fcw")

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.backgroundColor = .clear
        view.isOpaque = false
        #if DEBUG
        view.isInspectable = true
        #endif
        link.webView = view
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onConsole = onConsole
        coordinator.onFinish = onFinish
        coordinator.onFail = onFail
        link.webView = view

        guard coordinator.loadedToken != reloadToken || coordinator.loadedEntry != document.entry else {
            return
        }
        coordinator.loadedToken = reloadToken
        coordinator.loadedEntry = document.entry
        coordinator.schemeHandler.update(document: document)

        let encoded = document.entry.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? document.entry
        guard let url = URL(string: PreviewAssembler.scheme + "://" + PreviewAssembler.host + "/" + encoded) else {
            return
        }
        view.load(URLRequest(url: url))
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeAllUserScripts()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "fcw")
        view.stopLoading()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, @preconcurrency WKNavigationDelegate, @preconcurrency WKScriptMessageHandler {

        let schemeHandler = PreviewSchemeHandler()
        var loadedToken = -1
        var loadedEntry = ""
        var onConsole: @MainActor (ConsoleLine) -> Void = { _ in }
        var onFinish: @MainActor () -> Void = {}
        var onFail: @MainActor () -> Void = {}

        // MARK: Navigation

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let scheme = (url.scheme ?? "").lowercased()
            // The island's scheme has to be admitted here too, or every KaTeX asset is
            // refused and the page renders its own source - silently, which is precisely
            // the failure this change exists to end.
            if scheme == PreviewAssembler.scheme || scheme == MathIslandAssets.scheme || scheme == "about" {
                decisionHandler(.allow)
                return
            }
            if scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            onFinish()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            onFail()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            onFail()
        }

        // MARK: Console

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "fcw", let payload = message.body as? [String: Any] else { return }
            let level = (payload["t"] as? String) ?? "log"
            var text = (payload["m"] as? String) ?? ""
            if let file = payload["file"] as? String, !file.isEmpty {
                text += "  (" + file + ")"
            }
            guard !text.isEmpty else { return }
            onConsole(ConsoleLine(id: UUID(), level: level, text: text, at: Date()))
        }
    }
}

// MARK: - Scheme handler

/// Serves the project over `firas-proj://project/<path>` so relative assets, `fetch()` and module
/// imports resolve the way they do in a real page.
@MainActor
final class PreviewSchemeHandler: NSObject, @preconcurrency WKURLSchemeHandler {

    private var document: PreviewDocument?

    func update(document: PreviewDocument) {
        self.document = document
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        let rawPath = url?.path ?? ""
        let path = PreviewAssembler.normalize(rawPath.removingPercentEncoding ?? rawPath)

        guard let document else {
            respond(urlSchemeTask, url: url, body: Data(), mime: "text/plain")
            return
        }

        if path.isEmpty || path == document.entry {
            respond(
                urlSchemeTask,
                url: url,
                body: Data(document.html.utf8),
                mime: "text/html"
            )
            return
        }

        if let content = document.files[path] {
            respond(
                urlSchemeTask,
                url: url,
                body: Data(content.utf8),
                mime: PreviewAssembler.mimeType(forPath: path)
            )
            return
        }

        respond(urlSchemeTask, url: url, body: Data(), mime: "text/plain")
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Every response is delivered synchronously inside `start`, so there is nothing to cancel.
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL?, body: Data, mime: String) {
        guard let url else { return }
        let response = URLResponse(
            url: url,
            mimeType: mime,
            expectedContentLength: body.count,
            textEncodingName: "utf-8"
        )
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}
