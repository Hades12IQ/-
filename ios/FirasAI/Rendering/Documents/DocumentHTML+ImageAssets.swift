import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension DocumentHTML {
    /// The model places stable IDs; the app supplies the corresponding real image bytes locally.
    /// The original authored source keeps those IDs, so a later revision can reuse the same asset.
    static func embeddingImages(in html: String, assets: [String: Data]) -> String {
        guard html.contains("firas-asset:"), !assets.isEmpty else { return html }
        var out = html
        var budget = 24 * 1_024 * 1_024
        for (id, bytes) in assets.sorted(by: { $0.key < $1.key }) {
            guard !id.isEmpty, id.count <= 180,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }),
                  out.contains("firas-asset:" + id), bytes.count <= 30 * 1_024 * 1_024,
                  let image = imageDataURI(bytes) else { continue }
            let occurrences = ["\"", "'"].reduce(0) { count, quote in
                count + out.components(separatedBy: quote + "firas-asset:" + id + quote).count - 1
            }
            guard occurrences > 0, image.utf8.count <= budget / occurrences else { continue }
            // Quote boundaries prevent asset-1 from changing asset-10 and preserve surrounding HTML.
            var replaced = false
            for quote in ["\"", "'"] {
                let token = quote + "firas-asset:" + id + quote
                if out.contains(token) {
                    out = out.replacingOccurrences(of: token, with: quote + image + quote)
                    replaced = true
                }
            }
            if replaced { budget -= image.utf8.count * occurrences }
        }
        return out
    }

    private static func imageDataURI(_ bytes: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3_000,
                kCGImageSourceShouldCacheImmediately: false
              ] as CFDictionary) else { return nil }
        let alpha = image.alphaInfo
        let hasAlpha = alpha == .premultipliedFirst || alpha == .premultipliedLast || alpha == .first || alpha == .last
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 8 * 1_024 * 1_024 else { return nil }
        return "data:" + (hasAlpha ? "image/png" : "image/jpeg") + ";base64," + (data as Data).base64EncodedString()
    }
}
