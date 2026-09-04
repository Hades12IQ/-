import AppKit
import PDFKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
for url in urls where url.pathExtension == "pdf" {
    guard let document = PDFDocument(url: url), document.pageCount > 0 else {
        fatalError("Smoke PDF is unreadable: \(url.lastPathComponent)")
    }
    for index in 0..<document.pageCount {
        guard let page = document.page(at: index) else { fatalError("Missing page") }
        let bitmap = page.thumbnail(of: NSSize(width: 900, height: 1300), for: .mediaBox)
        guard let tiff = bitmap.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            fatalError("Could not render PDF page")
        }
        let name = url.deletingPathExtension().lastPathComponent + "-page-\(index + 1).png"
        try data.write(to: directory.appendingPathComponent(name))
    }
}
