import SwiftUI
import UIKit
import QuickLook

/// `UIActivityViewController` as a sheet body. Used by every screen that produces a temp file —
/// the export menu, the file card, the long-file reader, the share-link sheet.
struct FirasActivitySheet: UIViewControllerRepresentable {

    private let items: [Any]

    init(url: URL) {
        self.items = [url]
    }

    init(text: String) {
        self.items = [text]
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// The real document, previewed by the system.
///
/// `QLPreviewController` handles every format this app can produce — PDF, Word, Excel, PowerPoint,
/// CSV, HTML, images and plain text — with the platform's own renderer, its own zoom, its own text
/// selection and its own share button. Opening a generated file must show the *document*, never a
/// dump of the markdown it came from.
struct FirasDocumentPreview: UIViewControllerRepresentable {

    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// "Save to Files". The share sheet can reach iCloud Drive too, but the owner asked for the file to
/// land somewhere he can find it again, and the Files picker is the one control that says so.
///
/// `asCopy: true` — the exported file lives in a temp directory that the system may reclaim, so the
/// picker must copy the bytes rather than move the original out from under a preview that is still
/// on screen.
struct FirasFileSaver: UIViewControllerRepresentable {

    private let url: URL
    private let onFinish: (Bool) -> Void

    init(url: URL, onFinish: @escaping (Bool) -> Void) {
        self.url = url
        self.onFinish = onFinish
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.delegate = context.coordinator
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            onFinish(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
        }
    }
}
