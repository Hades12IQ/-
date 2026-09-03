import Foundation
import ImageIO
import UIKit

/// What went wrong while putting a finished render on disk.
///
/// Downloading is not generating, and it must not report as if it were: the owner watched a picture
/// that had rendered perfectly announce «تعذّر توليد الصورة» because the only error anyone raised
/// was the generation one. These three cases are the whole vocabulary of the storage step, and each
/// one is a different sentence upstream.
enum MediaAssetError: Error, Sendable, Equatable {
    /// The download promised a temp file and there is nothing at that path.
    case missingBytes
    /// The media folder does not exist and could not be created.
    case storeUnavailable
    /// The bytes exist and could not be put where they belong.
    case writeFailed
}

/// Where finished renders live on the device: `Application Support/FirasAI/media/<key>.<ext>`.
///
/// Four rules, each of them a bug that was already paid for once
/// (`audit-ios-brain-media.md §B.3` findings 32, 38, 39):
///
/// 1. **Relative filenames only.** The container UUID changes on every TestFlight/App Store update,
///    so an absolute path persisted today addresses nothing tomorrow — every completed creation
///    would silently re-download and the old bytes would be unreachable to delete.
/// 2. **Never a `Data` round trip.** `APIClient.download` hands over a temp file; a 200 MB clip is
///    moved, never loaded. Only the caller that actually needs pixels reads bytes.
/// 3. **Excluded from backup, trimmed by age.** Renders are reproducible from their key, so they
///    are a cache: iCloud must not carry them, and the newest 200 are all the device keeps.
/// 4. **The folder is proven to exist on every write.** `prepareIfNeeded` used to publish
///    `prepared = true` *before* it awaited `DiskStore`, so a second `store` racing the first sailed
///    past the guard and moved a file into a directory that did not exist yet — a download failure
///    with no cause a reader could see. Creating the directory is a synchronous `FileManager` call
///    with no suspension point in it, so it now happens inline before every move, and the flag only
///    guards the one thing that genuinely needs the actor's disk: the root's backup exclusion.
actor MediaAssetRepository {

    private let disk: DiskStore
    private let directory: URL
    private var rootPrepared = false

    init(disk: DiskStore) {
        self.disk = disk
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.directory = base
            .appendingPathComponent("FirasAI", isDirectory: true)
            .appendingPathComponent("media", isDirectory: true)
    }

    // MARK: - Reading

    /// The absolute URL of a stored file. It is actor-isolated like everything else here, so a
    /// caller outside the actor still writes `await` — but the body touches no file system at all,
    /// which is why the hop costs nothing and `AVPlayer` and the image loader can ask for it on
    /// every page turn.
    func url(forFilename filename: String) -> URL {
        directory.appendingPathComponent(Self.sanitized(filename), isDirectory: false)
    }

    /// True when the bytes are actually on disk under that name.
    func exists(filename: String) -> Bool {
        let target = url(forFilename: filename)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    // MARK: - Writing

    /// Moves a downloaded temp file in and answers the **relative** filename to persist.
    ///
    /// An existing file with the same name is replaced rather than merged: the key is a content
    /// hash, so two files under one name are always the same bytes. That is also why a move that
    /// loses a race is not an error — if the destination is there when we look, the bytes we were
    /// asked to store are there, whoever put them there.
    func store(temp: URL, key: String, ext: String) async throws -> String {
        await prepareRootIfNeeded()
        ensureDirectory()

        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { throw MediaAssetError.storeUnavailable }
        guard manager.fileExists(atPath: temp.path) else { throw MediaAssetError.missingBytes }

        let filename = Self.sanitizedKey(key) + "." + Self.sanitizedExtension(ext)
        let destination = directory.appendingPathComponent(filename, isDirectory: false)

        if manager.fileExists(atPath: destination.path) {
            try? manager.removeItem(at: destination)
        }
        do {
            try manager.moveItem(at: temp, to: destination)
        } catch {
            // A cross-volume move fails, and so does a move that lost a race to an identical file.
            do {
                try manager.copyItem(at: temp, to: destination)
                try? manager.removeItem(at: temp)
            } catch {
                guard manager.fileExists(atPath: destination.path) else {
                    throw MediaAssetError.writeFailed
                }
            }
        }
        guard manager.fileExists(atPath: destination.path) else { throw MediaAssetError.writeFailed }

        // Readable while the phone is locked: a job that lands in the background, and a clip that
        // keeps playing after the screen sleeps, both need this.
        try? manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
        return filename
    }

    func delete(filename: String) async {
        let target = url(forFilename: filename)
        // Belt and braces: a name that walked out of the directory is not ours to remove.
        guard target.deletingLastPathComponent().standardizedFileURL.path
            == directory.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: target)
    }

    /// Keeps the newest `keepingNewest` files and deletes the rest, so a year of renders cannot
    /// quietly fill the device.
    func trim(keepingNewest limit: Int) async {
        guard limit > 0 else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return }
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }

        var dated: [(name: String, at: Date)] = []
        dated.reserveCapacity(names.count)
        for name in names where !name.hasPrefix(".") {
            let file = directory.appendingPathComponent(name, isDirectory: false)
            let attributes = try? manager.attributesOfItem(atPath: file.path)
            let modified = (attributes?[.modificationDate] as? Date)
                ?? (attributes?[.creationDate] as? Date)
                ?? Date(timeIntervalSince1970: 0)
            dated.append((name, modified))
        }
        // Counted after the hidden files are dropped: `.keep` used to push the real total over the
        // limit and take a render with it.
        guard dated.count > limit else { return }
        dated.sort { $0.at > $1.at }
        for entry in dated[limit...] {
            try? manager.removeItem(at: directory.appendingPathComponent(entry.name, isDirectory: false))
        }
    }

    /// Removes every stored file (Settings → clear local data).
    func removeAll() async {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            try? manager.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
        }
    }

    // MARK: - Private

    /// Creates `media/` and marks it as no business of iCloud's. Synchronous on purpose: there is
    /// no suspension point in it, so no second caller can slip between the check and the create.
    private func ensureDirectory() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [
                    FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ]
            )
        }
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// One hop through `DiskStore`, which owns the app's root folder and its backup exclusion. The
    /// flag is set **after** the await, so a racing caller waits for the real thing rather than for
    /// a promise.
    private func prepareRootIfNeeded() async {
        guard !rootPrepared else { return }
        _ = await disk.fileURL("media/.keep")
        rootPrepared = true
    }

    private static func sanitized(_ raw: String) -> String {
        let allowed = raw.filter { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-" || character == "_")
        }
        let trimmed = allowed.replacingOccurrences(of: "..", with: "")
        return trimmed.isEmpty ? "unnamed" : String(trimmed.prefix(96))
    }

    private static func sanitizedKey(_ raw: String) -> String {
        let hex = IDs.sanitizedMediaKey(raw)
        if !hex.isEmpty { return hex }
        return String(sanitized(raw).prefix(64))
    }

    private static func sanitizedExtension(_ raw: String) -> String {
        let allowed = raw.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return allowed.isEmpty ? "bin" : String(allowed.prefix(6))
    }
}

// MARK: - Decoding pictures off the main thread

/// A 2K PNG is 3–5 MB and `UIImage(data:)` decodes it lazily — on the main thread, at first draw,
/// in the middle of a scroll (`audit-ios-brain-media.md §B.3` finding 42). ImageIO does the whole
/// job here instead: it reads only what the requested size needs and hands back a bitmap that is
/// already decoded.
///
/// Free functions on an enum, so nothing is actor-isolated and every call runs off the main actor.
enum MediaImageLoader {

    /// A downsampled, fully decoded image for a grid tile or a full-screen page.
    static func image(at url: URL, maxPixel: CGFloat) async -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(64, maxPixel))
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: thumbnail)
    }

    /// The picture's real pixel size, for the frame's aspect ratio before the bytes are drawn.
    static func pixelSize(at url: URL) async -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        guard let width = raw[kCGImagePropertyPixelWidth] as? Int,
              let height = raw[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }
}

// MARK: - File extensions per kind

extension MediaKind {

    /// The extension a finished render is stored under when the response carries no usable MIME.
    var defaultFileExtension: String {
        switch self {
        case .image: return "png"
        case .video: return "mp4"
        case .music: return "mp3"
        }
    }

    /// Maps the response MIME onto a file extension, falling back to the kind's default.
    ///
    /// The kind decides first, and that ordering is the whole point. `/api/music/file` hands back
    /// whatever `content-type` the upstream engine set (`server.mjs:4954`), and a song delivered as
    /// `audio/mp4` used to be filed — and shared — as a **`.mp4`**, because the video branch was
    /// tested before the music one and `"audio/mp4".contains("mp4")` is true. The reader saw a video
    /// file in the share sheet for a song. A song is `.m4a` or `.mp3`, never `.mp4`.
    func fileExtension(forMIME mime: String?) -> String {
        let raw = (mime ?? "").lowercased()
        switch self {
        case .image:
            if raw.contains("jpeg") || raw.contains("jpg") { return "jpg" }
            if raw.contains("webp") { return "webp" }
            if raw.contains("png") { return "png" }
            return defaultFileExtension
        case .video:
            if raw.contains("quicktime") { return "mov" }
            if raw.contains("webm") { return "webm" }
            return defaultFileExtension
        case .music:
            if raw.contains("wav") { return "wav" }
            if raw.contains("flac") { return "flac" }
            if raw.contains("ogg") || raw.contains("opus") { return "ogg" }
            // `audio/mp4`, `audio/x-m4a` and `audio/aac` are all the same container to iOS.
            if raw.contains("mp4") || raw.contains("m4a") || raw.contains("aac") { return "m4a" }
            return defaultFileExtension
        }
    }
}
