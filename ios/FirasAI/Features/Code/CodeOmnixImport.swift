import Foundation

enum CodeOmnixImportError: Error, Equatable {
    case unavailable
    case projectChanged
    case capacity
}

/// Imports verified text deliverables into the existing review flow, never directly into a project.
/// The manifest must still identify this job's versions before and after every download batch.
@MainActor
enum CodeOmnixImport {
    struct Inventory: Decodable, Sendable { let files: [OmnixFile] }
    struct PlannedFile: Equatable {
        let file: OmnixFile
        let path: String
    }

    static func load(
        receipt: OmnixReceipt,
        source: CodeProject,
        api: APIClient,
        isCurrent: @MainActor () -> Bool
    ) async throws -> CodeEditPlan {
        try await prepare(receipt: receipt, source: source, isCurrent: isCurrent,
            fetchJob: { try await OmnixService.job(receipt, api: api) },
            fetchInventory: {
                try await api.json(.get, "/api/omnix/files", budget: .poll, as: Inventory.self).files
            },
            fetchBytes: { file in
                let url = try await OmnixService.download(file, api: api)
                defer { try? FileManager.default.removeItem(at: url) }
                return try Data(contentsOf: url, options: .mappedIfSafe)
            })
    }

    /// These transport seams also exercise actual stale-owner and changed-manifest behavior in CI.
    static func prepare(
        receipt: OmnixReceipt,
        source: CodeProject,
        isCurrent: @MainActor () -> Bool,
        fetchJob: @MainActor () async throws -> OmnixJob,
        fetchInventory: @MainActor () async throws -> [OmnixFile],
        fetchBytes: @MainActor (OmnixFile) async throws -> Data
    ) async throws -> CodeEditPlan {
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw CodeOmnixImportError.projectChanged }
        }
        try checkCurrent()
        try validateProject(source)
        let job = try await fetchJob()
        try checkCurrent()
        guard receipt.accepts(job) else { throw CodeOmnixImportError.unavailable }
        let planned = try planFiles(job)

        func verifyInventory() async throws {
            try checkCurrent()
            let inventory = try await fetchInventory()
            try checkCurrent()
            guard manifestMatches(planned, inventory: inventory) else {
                throw CodeOmnixImportError.unavailable
            }
        }

        try await verifyInventory()
        var writes: [CodeFileBlock] = []
        var totalBytes = 0
        for item in planned {
            try checkCurrent()
            let bytes = try await fetchBytes(item.file)
            try checkCurrent()
            totalBytes += bytes.count
            guard bytes.count == item.file.size, totalBytes <= 720_000 else {
                throw CodeOmnixImportError.capacity
            }
            let content = try text(bytes)
            writes.append(CodeFileBlock(path: item.path, content: content))
        }
        try await verifyInventory()
        try checkCurrent()

        var files = source.files
        for write in writes {
            if let index = files.firstIndex(where: { $0.path == write.path }) {
                files[index] = CodeFile(path: write.path, content: write.content)
            } else {
                files.append(CodeFile(path: write.path, content: write.content))
            }
        }
        try validateProject(CodeProject(name: source.name, files: files))
        return CodeEditPlan(writes: writes)
    }

    static func planFiles(_ job: OmnixJob) throws -> [PlannedFile] {
        guard job.state == "completed", job.result?.filesStatus == "ready",
              let files = job.result?.files else { throw CodeOmnixImportError.unavailable }
        let supported = files.filter { file in
            file.downloadPath != nil && safePath(file.name, limit: 1_000, allowHidden: false)
            && supportedExtensions.contains((file.name as NSString).pathExtension.lowercased())
        }
        guard !supported.isEmpty, supported.count <= 30 else { throw CodeOmnixImportError.capacity }
        var totalBytes = 0
        for file in supported {
            guard let size = file.size, (0...240_000).contains(size),
                  let stamp = file.modifiedAt, stamp.isFinite, stamp >= 0 else {
                throw CodeOmnixImportError.unavailable
            }
            totalBytes += size
        }
        guard totalBytes <= 720_000 else { throw CodeOmnixImportError.capacity }

        var prefix = Array(supported[0].name.split(separator: "/").dropLast())
        for file in supported {
            let parts = Array(file.name.split(separator: "/").dropLast())
            while !parts.starts(with: prefix) { prefix.removeLast() }
        }
        var seenPaths = Set<String>()
        var seenIDs = Set<String>()
        return try supported.map { file in
            let path = file.name.split(separator: "/").dropFirst(prefix.count).joined(separator: "/")
            guard safePath(path, limit: 120, allowHidden: false),
                  seenPaths.insert(path.lowercased()).inserted,
                  seenIDs.insert(file.id).inserted else { throw CodeOmnixImportError.capacity }
            return PlannedFile(file: file, path: path)
        }
    }

    static func manifestMatches(_ planned: [PlannedFile], inventory: [OmnixFile]) -> Bool {
        guard inventory.count <= 2_000, Set(inventory.map(\.id)).count == inventory.count else { return false }
        return planned.allSatisfy { item in
            inventory.contains { file in
                file.id == item.file.id && file.name == item.file.name && file.size == item.file.size
                && file.modifiedAt == item.file.modifiedAt
            }
        }
    }

    static func text(_ bytes: Data) throws -> String {
        guard let content = String(data: bytes, encoding: .utf8),
              !content.contains("\0"), content.utf16.count <= 60_000 else {
            throw CodeOmnixImportError.capacity
        }
        return content
    }

    static func validateProject(_ project: CodeProject) throws {
        guard project.name.utf16.count <= 80, project.files.count <= 30 else { throw CodeOmnixImportError.capacity }
        var paths = Set<String>()
        for file in project.files {
            guard safePath(file.path, limit: 120, allowHidden: true),
                  paths.insert(file.path.lowercased()).inserted,
                  file.content.utf16.count <= 60_000, !file.content.contains("\0") else {
                throw CodeOmnixImportError.capacity
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let bytes = try encoder.encode(project)
        guard let json = String(data: bytes, encoding: .utf8), json.utf16.count <= 180_000 else {
            throw CodeOmnixImportError.capacity
        }
    }

    private static func safePath(_ path: String, limit: Int, allowHidden: Bool) -> Bool {
        guard !path.isEmpty, path.utf16.count <= limit,
              path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              path.range(of: #"[\x00-\x1f\x7f\\:?*"<>|\u202a-\u202e\u2066-\u2069]"#, options: .regularExpression) == nil else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && (allowHidden || !$0.hasPrefix("."))
        }
    }

    private static let supportedExtensions: Set<String> = [
        "htm", "html", "css", "scss", "less", "js", "mjs", "cjs", "jsx", "ts", "tsx",
        "json", "md", "txt", "svg", "xml", "yaml", "yml", "toml", "py", "java", "c", "h",
        "cpp", "cc", "hpp", "cs", "go", "rs", "rb", "php", "swift", "kt", "kts", "sql",
        "sh", "bash", "zsh", "csv", "tsv"
    ]
}
