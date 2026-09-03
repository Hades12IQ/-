import Foundation
import OSLog

/// Every JSON document the app persists lives here: `Application Support/FirasAI/<relativePath>`.
///
/// - writes are atomic and protected with `.completeFileProtection`
/// - the root folder is excluded from iCloud/iTunes backup
/// - `read` never throws: a missing or undecodable file is `nil` (and logged)
/// - the encoder/decoder use no date strategy (timestamps travel as numbers or strings)
actor DiskStore {

    static let shared = DiskStore()

    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var rootPrepared = false

    init() {
        self.root = DiskStore.defaultRoot()
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - API

    func read<T: Decodable & Sendable>(_ type: T.Type, at relativePath: String) async -> T? {
        let url = fileURL(relativePath)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Log.ui.error("DiskStore decode failed at \(relativePath, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func write<T: Encodable & Sendable>(_ value: T, at relativePath: String) async throws {
        let url = fileURL(relativePath)
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    func delete(at relativePath: String) async {
        let url = resolved(relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    /// Absolute URL for a relative path; the parent directories are created on demand.
    func fileURL(_ relativePath: String) -> URL {
        prepareRootIfNeeded()
        let url = resolved(relativePath)
        let parent = url.deletingLastPathComponent()
        if parent.path != root.path {
            createDirectory(at: parent)
        }
        return url
    }

    /// File and directory names directly inside `relativePath` (empty string = the root), sorted.
    func list(directory relativePath: String) async -> [String] {
        prepareRootIfNeeded()
        let directory = relativePath.isEmpty ? root : resolved(relativePath)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted()
    }

    // MARK: - Private

    private static func defaultRoot() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("FirasAI", isDirectory: true)
    }

    /// Joins the sanitised components of `relativePath` onto the root. Empty, `.` and
    /// `..` components are dropped so a caller can never escape the container.
    private func resolved(_ relativePath: String) -> URL {
        var url = root
        for component in relativePath.split(separator: "/") {
            let name = String(component)
            if name.isEmpty || name == "." || name == ".." { continue }
            url = url.appendingPathComponent(name)
        }
        return url
    }

    private func prepareRootIfNeeded() {
        guard !rootPrepared else { return }
        rootPrepared = true
        createDirectory(at: root)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func createDirectory(at url: URL) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path) else { return }
        try? manager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [FileAttributeKey.protectionKey: FileProtectionType.complete]
        )
    }
}
