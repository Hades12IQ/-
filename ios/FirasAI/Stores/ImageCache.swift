import Foundation
import ImageIO
import UIKit

/// Thumbnails, decoded once.
///
/// `audit-ios-chat.md §Critical C5` measured the cost of the obvious approach: a computed property
/// that base64-decodes and `UIImage(data:)`-decodes every attached thumbnail, on the main thread,
/// on every re-render of a streaming row. This actor decodes off the main thread, downsamples with
/// ImageIO (so a 48 MP original never becomes a 200 MB bitmap), keeps the result in an `NSCache`
/// the system can evict under pressure, and writes a small JPEG under `thumbs/` so the second
/// launch does no decoding at all.
///
/// Full-resolution images are never stored here and never persisted anywhere.
actor ImageCache {

    static let shared = ImageCache()

    /// Thumbnails are shown at ≤ 160 pt; 512 px covers 3× and leaves room for the image viewer's
    /// first frame.
    private static let maximumPixelSize: CGFloat = 512
    private static let directory = "thumbs"

    private let memory: NSCache<NSString, UIImage>

    init() {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 24 * 1024 * 1024
        self.memory = cache
    }

    // MARK: - API

    /// A `data:image/…;base64,…` URL, as stored in `imageThumbs`.
    func image(forDataURL dataURL: String) async -> UIImage? {
        let trimmed = dataURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = Self.fingerprint(trimmed)
        if let hit = memory.object(forKey: key as NSString) { return hit }

        let fileURL = await DiskStore.shared.fileURL(Self.directory + "/" + key + ".jpg")
        if FileManager.default.fileExists(atPath: fileURL.path),
           let cached = Self.downsample(url: fileURL) {
            memory.setObject(cached, forKey: key as NSString, cost: Self.cost(of: cached))
            return cached
        }

        guard let payload = Self.payload(ofDataURL: trimmed) else { return nil }
        guard let decoded = Self.downsample(data: payload) else { return nil }
        memory.setObject(decoded, forKey: key as NSString, cost: Self.cost(of: decoded))
        if let jpeg = decoded.jpegData(compressionQuality: 0.8) {
            try? jpeg.write(to: fileURL, options: [.atomic, .completeFileProtection])
        }
        return decoded
    }

    /// A file already on disk (a downloaded creation, a picked photo written to a temp file).
    func image(forFile url: URL) async -> UIImage? {
        let key = Self.fingerprint(url.path)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard let decoded = Self.downsample(url: url) else { return nil }
        memory.setObject(decoded, forKey: key as NSString, cost: Self.cost(of: decoded))
        return decoded
    }

    /// Puts an image the caller already decoded into the memory cache under its own key.
    func store(_ image: UIImage, key: String) {
        let identifier = Self.fingerprint(key)
        memory.setObject(image, forKey: identifier as NSString, cost: Self.cost(of: image))
    }

    /// Drops everything the app is holding; the disk copies stay.
    func purgeMemory() {
        memory.removeAllObjects()
    }

    // MARK: - Decoding (all of it off the main actor, by construction)

    private static func downsample(data: Data) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
        return thumbnail(from: source)
    }

    private static func downsample(url: URL) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        return thumbnail(from: source)
    }

    private static func thumbnail(from source: CGImageSource) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// The base64 payload of a data URL, or the string itself when it is already bare base64.
    private static func payload(ofDataURL raw: String) -> Data? {
        var body = raw
        if raw.hasPrefix("data:") {
            guard let comma = raw.firstIndex(of: ",") else { return nil }
            body = String(raw[raw.index(after: comma)...])
        }
        let cleaned = body.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters])
    }

    private static func cost(of image: UIImage) -> Int {
        let scale = image.scale
        return Int(image.size.width * scale * image.size.height * scale * 4)
    }

    /// A stable 64-bit fingerprint (FNV-1a) rendered as hex.
    ///
    /// `hashValue` is deliberately not used: it is seeded per process, so a disk file written under
    /// it could never be found again after a relaunch.
    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
