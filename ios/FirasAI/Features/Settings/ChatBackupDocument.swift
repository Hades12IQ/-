import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The `.json` file `fileExporter` writes and `fileImporter` reads: the web's
/// `{app, format, exportedAt, chats}` shape, byte-compatible with a backup taken in the browser
/// (`web-auth-account-settings.md §6.5`).
///
/// `FileDocument` requirements are called off the main actor by SwiftUI, which is exactly why the
/// type owns nothing but a value: no store, no environment, no isolation.
struct FirasChatBackupDocument: FileDocument {

    static var readableContentTypes: [UTType] { [.json] }

    let backup: FirasChatBackup

    init(backup: FirasChatBackup) {
        self.backup = backup
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw ChatBackupValidationError.unsupportedFormat
        }
        backup = try FirasChatBackup.decodeValidated(from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return FileWrapper(regularFileWithContents: try encoder.encode(backup))
    }
}

/// Reading a picked file. Separate from the document type because `fileImporter` hands back a
/// security-scoped URL, not a `ReadConfiguration`, and because the size has to be refused **before**
/// the bytes are mapped: a 400 MB file must not become 400 MB of memory on the way to a validation
/// error.
///
/// The concurrency attribute the Codex build had here is a Swift 6.2 opt-out of a feature this
/// target does not enable (`audit-ios-shell-settings-design.md F16`); in Swift 5 mode a
/// `nonisolated` async function already runs off the caller's actor.
enum ChatBackupFileReader {

    static func read(from url: URL) async throws -> FirasChatBackup {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try readSynchronously(url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func readSynchronously(_ url: URL) throws -> FirasChatBackup {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false else {
            throw ChatBackupValidationError.unsupportedFormat
        }
        if let fileSize = values.fileSize, fileSize > FirasChatBackup.maximumFileBytes {
            throw ChatBackupValidationError.fileTooLarge
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try FirasChatBackup.decodeValidated(from: data)
    }

    /// `firas-chats-YYYYMMDD` — the web's name, without the extension `fileExporter` appends.
    static func defaultFilename(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 2026
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        return String(format: "firas-chats-%04ld%02ld%02ld", year, month, day)
    }

    /// The ISO stamp written into the file body.
    static func timestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
