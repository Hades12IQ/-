import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

private struct MathGlyphDiskEntry: Codable, Sendable {
    let png: Data
    let scale: Double
    let baseline: Double
}

/// CGImage is an immutable snapshot: the serial encoder only reads its pixels,
/// and no mutable UIImage crosses the queue boundary. Remove this wrapper's
/// unchecked conformance when the SDK exposes CGImage as Sendable directly.
private struct MathGlyphDiskPixels: @unchecked Sendable {
    let image: CGImage
    let scale: Double
    let baseline: Double
}

private final class MathGlyphMemoryEntry {
    let glyph: MathGlyph
    init(_ glyph: MathGlyph) { self.glyph = glyph }
}

/// Filesystem work and PNG encoding belong to one serial utility queue. A clear
/// is queued after all preceding writes and before every subsequent write.
// Mutable bookkeeping is confined to `queue`; the only entry points enqueue
// their work. This bridge can become an actor with a serial executor if the
// synchronous public cache API is later replaced with an async API.
private final class MathGlyphDiskIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.firasai.math-glyph-cache", qos: .utility)
    private var writesSinceTrim = 0

    func enqueueWrite(_ pixels: MathGlyphDiskPixels, to url: URL, folder: URL,
                      completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in completion(write(pixels, to: url, folder: folder)) }
    }

    func enqueueClear(folder: URL, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            writesSinceTrim = 0
            completion(clear(folder: folder))
        }
    }

    func whenDrained(_ completion: @escaping @Sendable () -> Void) {
        queue.async(execute: completion)
    }

    private func write(_ pixels: MathGlyphDiskPixels, to url: URL, folder: URL) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        if FileManager.default.fileExists(atPath: url.path) { return true }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData,
            UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, pixels.image, nil)
        guard CGImageDestinationFinalize(destination), output.length < 1_500_000 else { return false }
        let entry = MathGlyphDiskEntry(png: Data(referencing: output), scale: pixels.scale, baseline: pixels.baseline)
        guard let data = try? JSONEncoder().encode(entry) else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var directory = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            writesSinceTrim += 1
            if writesSinceTrim >= 24 { writesSinceTrim = 0; trim(folder: folder) }
            return true
        } catch { return false }
    }

    private func trim(folder: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let entries = files.filter { $0.pathExtension == "json" }.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var size = entries.reduce(0) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where size > 48 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: entry.0)
            size -= entry.1
        }
    }

    private func clear(folder: URL) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard FileManager.default.fileExists(atPath: folder.path) else { return true }
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil) else { return false }
        var removedAll = true
        for file in files where file.pathExtension == "json" {
            do { try FileManager.default.removeItem(at: file) }
            catch { removedAll = false }
        }
        return removedAll
    }
}

/// Completed glyphs survive relaunches. Callers continue to control persistence
/// for temporary conversations. A bounded, unobserved positive cache prevents
/// repeated file reads and image decoding during SwiftUI body evaluation.
@MainActor
enum MathGlyphDiskCache {
    private static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("FirasMathGlyphs-v1", isDirectory: true)
    private static let io = MathGlyphDiskIO()
    private static let positive: NSCache<NSString, MathGlyphMemoryEntry> = {
        let cache = NSCache<NSString, MathGlyphMemoryEntry>()
        cache.countLimit = 256
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()
    private static var misses: Set<String> = []
    private static var pendingWrites: Set<String> = []
    private static var generation: UInt64 = 0
    private static var diskReadsAllowed = true

    #if DEBUG
    struct ReadMetrics {
        let diskReadAttempts: Int
        let successfulDiskDecodes: Int
        let memoryHits: Int
    }
    private static var debugDiskReadAttempts = 0
    private static var debugSuccessfulDiskDecodes = 0
    private static var debugMemoryHits = 0

    static func readMetrics() -> ReadMetrics {
        ReadMetrics(diskReadAttempts: debugDiskReadAttempts,
                    successfulDiskDecodes: debugSuccessfulDiskDecodes, memoryHits: debugMemoryHits)
    }

    static func resetReadMetrics() {
        debugDiskReadAttempts = 0
        debugSuccessfulDiskDecodes = 0
        debugMemoryHits = 0
    }

    static func evictPositiveCacheForTesting() { positive.removeAllObjects() }
    #endif

    private static func url(_ key: String) -> URL? {
        let hash = SHA256.hash(data: Data(("katex-0.16.11|" + key).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(hash + ".json")
    }

    static func read(_ key: String) -> MathGlyph? {
        if let hit = positive.object(forKey: key as NSString) {
            #if DEBUG
            debugMemoryHits += 1
            #endif
            return hit.glyph
        }
        guard diskReadsAllowed, !misses.contains(key) else { return nil }
        guard let glyph = readPersisted(key) else {
            if misses.count < 2_000 { misses.insert(key) }
            return nil
        }
        remember(glyph, key: key)
        return glyph
    }

    /// Always reads the actual file, bypassing positive and negative memory
    /// caches. Smoke checks must use this after flushPendingWrites().
    static func readPersisted(_ key: String) -> MathGlyph? {
        guard diskReadsAllowed, let url = url(key) else { return nil }
        #if DEBUG
        debugDiskReadAttempts += 1
        #endif
        guard let data = try? Data(contentsOf: url), data.count < 2_000_000,
              let entry = try? JSONDecoder().decode(MathGlyphDiskEntry.self, from: data),
              entry.scale.isFinite, entry.scale >= 1, entry.scale <= 4,
              entry.baseline.isFinite, entry.baseline >= 0,
              let image = UIImage(data: entry.png, scale: entry.scale),
              image.size.width > 0, image.size.height > 0,
              image.size.width <= 3000, image.size.height <= 3000,
              entry.baseline <= image.size.height else { return nil }
        #if DEBUG
        debugSuccessfulDiskDecodes += 1
        #endif
        return MathGlyph(image: image, size: image.size, baseline: entry.baseline)
    }

    static func write(_ glyph: MathGlyph, key: String) {
        remember(glyph, key: key)
        misses.remove(key)
        guard !pendingWrites.contains(key),
              let folder, let url = url(key), let image = glyph.image.cgImage else { return }
        let pixels = MathGlyphDiskPixels(image: image, scale: Double(glyph.image.scale), baseline: Double(glyph.baseline))
        let era = generation
        pendingWrites.insert(key)
        io.enqueueWrite(pixels, to: url, folder: folder) { saved in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A sign-out/clear makes every preceding callback obsolete.
                    guard era == generation else { return }
                    pendingWrites.remove(key)
                    if saved { misses.remove(key) }
                }
            }
        }
    }

    private static func remember(_ glyph: MathGlyph, key: String) {
        let area = glyph.size.width * glyph.size.height * 4
        let fallback = area.isFinite ? Int(min(max(1, area), 64_000_000)) : 1
        let cost = glyph.image.cgImage.map { $0.bytesPerRow * $0.height } ?? fallback
        positive.setObject(MathGlyphMemoryEntry(glyph), forKey: key as NSString, cost: cost)
    }

    /// Returns after all preceding I/O and main-actor completion bookkeeping.
    /// This is an async barrier, never a synchronous dispatch onto the I/O queue.
    static func flushPendingWrites() async {
        let worker = io
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            worker.whenDrained {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    static func clear() {
        generation &+= 1
        let era = generation
        positive.removeAllObjects()
        misses.removeAll()
        pendingWrites.removeAll()
        // Synchronous readers cannot see the old account's file while the
        // queued clear is waiting for earlier PNG encoders to finish.
        diskReadsAllowed = false
        guard let folder else { return }
        io.enqueueClear(folder: folder) { removedAll in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard era == generation else { return }
                    diskReadsAllowed = removedAll
                }
            }
        }
    }
}
