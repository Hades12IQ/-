import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// A private, immutable copy of a workspace project. No session, API URL or cookie enters WebKit.
struct OmnixPreviewPacket: Sendable {
    let entry: String
    let files: [String: Data]
    static func relative(_ name: String, root: String) -> String? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              root.isEmpty || name.hasPrefix(root + "/") else { return nil }
        return root.isEmpty ? name : String(name.dropFirst(root.count + 1))
    }
    @MainActor static func load(file: OmnixFile, owner: String, env: AppEnvironment) async throws -> Self {
        struct Inventory: Decodable { let files: [OmnixFile] }
        guard env.session.identityID == owner, file.downloadPath != nil else { throw APIError.cancelled }
        let inventory = try await env.api.json(.get, "/api/omnix/files", budget: .poll, as: Inventory.self)
        guard env.session.identityID == owner, inventory.files.count <= 2000,
              let entry = inventory.files.first(where: { $0.id == file.id && $0.name == file.name }),
              file.modifiedAt == nil || file.modifiedAt == entry.modifiedAt,
              file.sha256 == nil || file.sha256 == entry.sha256 else { throw APIError.decoding("preview_file_changed") }
        let root = file.name.split(separator: "/").dropLast().joined(separator: "/")
        let extensions = Set(["html", "htm", "css", "js", "mjs", "json", "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "woff", "woff2", "ttf", "otf", "mp3", "mp4", "wav", "ogg", "webm"])
        var bytes: [String: Data] = [:], total = 0
        let candidates = inventory.files.filter { row in
            relative(row.name, root: root) != nil && extensions.contains(URL(fileURLWithPath: row.name).pathExtension.lowercased())
        }
        guard candidates.count <= 64 else { throw APIError.decoding("preview_too_large") }
        for row in candidates {
            try Task.checkCancellation()
            guard env.session.identityID == owner, let path = relative(row.name, root: root), bytes[path] == nil,
                  let size = row.size, size >= 0, total + size <= 20 * 1024 * 1024 else { throw APIError.decoding("preview_too_large") }
            var downloadable = row
            if downloadable.url == nil { downloadable.url = "/api/omnix/files/" + row.id }
            let url = try await OmnixService.download(downloadable, api: env.api)
            defer { try? FileManager.default.removeItem(at: url) }
            guard env.session.identityID == owner else { throw APIError.cancelled }
            let data = try Data(contentsOf: url)
            total += data.count
            guard total <= 20 * 1024 * 1024 else { throw APIError.decoding("preview_too_large") }
            bytes[path] = data
        }
        let refreshed = try await env.api.json(.get, "/api/omnix/files", budget: .poll, as: Inventory.self)
        guard env.session.identityID == owner, candidates.allSatisfy({ candidate in
            refreshed.files.contains { $0.id == candidate.id && $0.name == candidate.name && $0.size == candidate.size && $0.modifiedAt == candidate.modifiedAt && $0.sha256 == candidate.sha256 }
        }) else { throw APIError.decoding("preview_file_changed") }
        guard let path = relative(file.name, root: root), bytes[path] != nil else { throw APIError.decoding("preview_entry_missing") }
        return Self(entry: path, files: bytes)
    }
}

struct OmnixProjectPreview: UIViewRepresentable {
    let packet: OmnixPreviewPacket
    func makeCoordinator() -> Coordinator { Coordinator(packet: packet) }
    func makeUIView(context: Context) -> WKWebView {
        Self.makeWebView(packet: packet, coordinator: context.coordinator)
    }
    static func makeWebView(packet: OmnixPreviewPacket, coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator, forURLScheme: "firas-private")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.allowsLinkPreview = false
        var url = URLComponents(); url.scheme = "firas-private"; url.host = "project"; url.path = "/" + packet.entry
        if let url = url.url { view.load(URLRequest(url: url)) }
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
        coordinator.files = [:]
        view.loadHTMLString("", baseURL: nil)
    }
    final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
        var files: [String: Data]
        init(packet: OmnixPreviewPacket) { files = packet.files }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, url.scheme == "firas-private", url.host == "project",
                  url.user == nil, url.password == nil,
                  let path = OmnixPreviewPacket.relative(String(url.path.dropFirst()), root: ""),
                  var data = files[path] else {
                urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return
            }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            if ext == "html" || ext == "htm" {
                let policy = """
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' firas-private:; style-src 'unsafe-inline' firas-private:; img-src data: firas-private:; font-src data: firas-private:; media-src firas-private:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><meta name="referrer" content="no-referrer">
                """
                data = Data(policy.utf8) + data
            }
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: ext == "mjs" ? "text/javascript" : mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
            urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, url.scheme == "firas-private", url.host == "project", action.targetFrame != nil else {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
    }
}
