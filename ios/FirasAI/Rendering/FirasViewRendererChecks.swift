#if DEBUG
import SwiftUI
import UIKit

@MainActor
enum FirasViewRendererChecks {
    static func run(directory: URL) -> [String] {
        let page = VStack(alignment: .leading, spacing: 12) {
            Text("Native document export").font(.system(size: 22, weight: .bold))
            Text("العربية والرياضيات · x² + y² = 25").font(.system(size: 18))
            // A distinct last line detects a nonblank image that nevertheless lost its ending.
            Text("Every line remains inside the page margins.")
                .font(.system(size: 16)).foregroundColor(.blue)
        }
        .foregroundColor(.black).padding(20).frame(width: 360, alignment: .leading)
        let renderer = FirasViewRenderer(content: page)
        renderer.proposedSize = FirasProposedSize(width: 360, height: nil)
        var measured = CGSize.zero
        var output: UIImage?
        renderer.renderLegacyForReliability { size, draw in
            measured = size
            guard size.width > 0, size.height > 0, size.height < 1000 else { return }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            output = UIGraphicsImageRenderer(size: size, format: format).image { target in
                UIColor.white.setFill()
                target.fill(CGRect(origin: .zero, size: size))
                target.cgContext.translateBy(x: 0, y: size.height)
                target.cgContext.scaleBy(x: 1, y: -1)
                draw(target.cgContext)
            }
        }
        guard measured.width == 360, measured.height >= 90, measured.height < 1000,
              let output, let image = output.cgImage else { return ["legacy-export-layout-size"] }
        try? output.pngData()?.write(to: directory.appendingPathComponent("legacy-native-export.png"), options: .atomic)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ["legacy-export-pixel-context"] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var ink = 0
        var minimumX = width, maximumX = -1, minimumY = height, maximumY = -1
        var endingMinimumY = height, endingMaximumY = -1
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = pixels[offset], green = pixels[offset + 1], blue = pixels[offset + 2]
            let darkInk = red < 160 && green < 160 && blue < 160
            let endingInk = red < 100 && green < 100 && blue > 160
            guard darkInk || endingInk else { continue }
            ink += 1
            let x = (offset / 4) % width, y = (offset / 4) / width
            minimumX = min(minimumX, x); maximumX = max(maximumX, x)
            minimumY = min(minimumY, y); maximumY = max(maximumY, y)
            if endingInk { endingMinimumY = min(endingMinimumY, y); endingMaximumY = max(endingMaximumY, y) }
        }
        var failures: [String] = []
        if ink <= 300 { failures.append("legacy-export-blank-render") }
        if endingMaximumY - endingMinimumY < 10 { failures.append("legacy-export-final-line-missing-or-clipped") }
        // The authored 20pt padding must survive rasterization on every edge. Two pixels allow
        // normal glyph antialiasing; testing both vertical edges is independent of bitmap origin.
        if minimumX < 18 || minimumY < 18 || width - 1 - maximumX < 18 || height - 1 - maximumY < 18 {
            failures.append("legacy-export-ink-crosses-authored-page-margins")
        }
        return failures
    }
}
#endif
