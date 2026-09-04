#if DEBUG
import Foundation
import QuartzCore
import UIKit

/// Real cache checks, invoked before the simulator's main persistence fixture.
/// No production account or model request is involved.
@MainActor
enum MathCachePerformanceChecks {
    struct Result {
        let failures: [String]
        let metrics: [String: Double]
    }

    static func run() async -> Result {
        var failures: [String] = []
        var metrics: [String: Double] = [:]
        guard let context = CGContext(data: nil, width: 160, height: 48,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Result(failures: ["Math cache: could not create test pixels"], metrics: [:])
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 48))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 18, width: 130, height: 3))
        context.fill(CGRect(x: 75, y: 4, width: 3, height: 40))
        guard let pixels = context.makeImage() else {
            return Result(failures: ["Math cache: test pixels were empty"], metrics: [:])
        }
        let image = UIImage(cgImage: pixels, scale: 2, orientation: .up)
        let glyph = MathGlyph(image: image, size: image.size, baseline: 18)
        let prefix = "smoke-cache-" + UUID().uuidString
        let old = prefix + "-old"
        let middle = prefix + "-middle"
        let current = prefix + "-current"

        await MathGlyphDiskCache.flushPendingWrites()
        // Every call below is synchronous on the main actor; completions have
        // no chance to hide an ordering bug by running between these requests.
        MathGlyphDiskCache.write(glyph, key: old)
        MathGlyphDiskCache.clear()
        MathGlyphDiskCache.write(glyph, key: middle)
        MathGlyphDiskCache.clear()
        MathGlyphDiskCache.write(glyph, key: current)
        if MathGlyphDiskCache.read(old) != nil || MathGlyphDiskCache.read(middle) != nil {
            failures.append("Math cache: clear did not immediately hide previous generations")
        }
        await MathGlyphDiskCache.flushPendingWrites()

        let oldFile = MathGlyphDiskCache.readPersisted(old)
        let middleFile = MathGlyphDiskCache.readPersisted(middle)
        let currentFile = MathGlyphDiskCache.readPersisted(current)
        let racePassed = oldFile == nil && middleFile == nil && currentFile != nil
        metrics["clearWriteRacePassed"] = racePassed ? 1 : 0
        if !racePassed { failures.append("Math cache: queued writes survived clear or erased the new generation") }
        if let currentFile {
            let preserved = currentFile.size == glyph.size && currentFile.baseline == glyph.baseline
                && currentFile.image.scale == image.scale && currentFile.image.cgImage?.width == pixels.width
            if !preserved { failures.append("Math cache: background PNG write changed glyph dimensions or baseline") }
        }

        MathGlyphDiskCache.evictPositiveCacheForTesting()
        MathGlyphDiskCache.resetReadMetrics()
        let restoreStart = CACurrentMediaTime()
        let restored = MathGlyphDiskCache.read(current)
        metrics["diskRestoreMilliseconds"] = (CACurrentMediaTime() - restoreStart) * 1_000
        var reusedIdentity = restored != nil
        let warmStart = CACurrentMediaTime()
        for _ in 0..<200 {
            guard let next = MathGlyphDiskCache.read(current), let restored else {
                reusedIdentity = false
                continue
            }
            if next.image !== restored.image { reusedIdentity = false }
        }
        metrics["warm200ReadsMilliseconds"] = (CACurrentMediaTime() - warmStart) * 1_000
        let readMetrics = MathGlyphDiskCache.readMetrics()
        metrics["diskReadAttemptsFor201Reads"] = Double(readMetrics.diskReadAttempts)
        metrics["diskDecodesFor201Reads"] = Double(readMetrics.successfulDiskDecodes)
        metrics["memoryHitsFor201Reads"] = Double(readMetrics.memoryHits)
        if !reusedIdentity || readMetrics.diskReadAttempts != 1
            || readMetrics.successfulDiskDecodes != 1 || readMetrics.memoryHits != 200 {
            failures.append("Math cache: repeated reads decoded or replaced an unchanged image")
        }
        // Deliberately leave the cache alone from here onward: the main fixture
        // will now prove persistence of its actual mathematical expressions.
        return Result(failures: failures, metrics: metrics)
    }
}
#endif
