import CryptoKit
import Foundation
import UIKit

/// Completed mathematical glyphs survive relaunches. Temporary conversations never write here.
/// Cache files contain only a glyph and its metrics, use iOS file protection and are excluded
/// from backup. The version is part of the address so renderer changes cannot reuse old metrics.
@MainActor
enum MathGlyphDiskCache {
    private struct Entry: Codable {
        let png: Data
        let scale: Double
        let baseline: Double
    }
    private static let limit = 48 * 1024 * 1024
    private static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("FirasMathGlyphs-v1", isDirectory: true)
    private static var misses: Set<String> = []
    private static var writesSinceTrim = 0

    private static func url(_ key: String) -> URL? {
        let hash = SHA256.hash(data: Data(("katex-0.16.11|" + key).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(hash + ".json")
    }

    static func read(_ key: String) -> MathGlyph? {
        guard !misses.contains(key), let url = url(key),
              let data = try? Data(contentsOf: url), data.count < 2_000_000,
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.scale.isFinite, entry.scale >= 1, entry.scale <= 4,
              entry.baseline.isFinite, entry.baseline >= 0,
              let image = UIImage(data: entry.png, scale: entry.scale),
              image.size.width > 0, image.size.height > 0,
              image.size.width <= 3000, image.size.height <= 3000,
              entry.baseline <= image.size.height else {
            if misses.count < 2_000 { misses.insert(key) }
            return nil
        }
        return MathGlyph(image: image, size: image.size, baseline: entry.baseline)
    }

    static func write(_ glyph: MathGlyph, key: String) {
        guard let folder, let url = url(key), !FileManager.default.fileExists(atPath: url.path),
              let png = glyph.image.pngData(), png.count < 1_500_000 else { return }
        let entry = Entry(png: png, scale: Double(glyph.image.scale), baseline: Double(glyph.baseline))
        guard let data = try? JSONEncoder().encode(entry) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var directory = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            misses.remove(key)
            writesSinceTrim += 1
            if writesSinceTrim >= 24 { writesSinceTrim = 0; trim() }
        } catch { /* A cache failure never changes the rendered answer. */ }
    }

    private static func trim() {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let entries = files.filter { $0.pathExtension == "json" }.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var size = entries.reduce(0) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where size > limit {
            try? FileManager.default.removeItem(at: entry.0)
            size -= entry.1
        }
    }

    static func clear() {
        misses.removeAll()
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
