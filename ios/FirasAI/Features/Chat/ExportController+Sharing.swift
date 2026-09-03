import LinkPresentation
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// How a finished export leaves the app: the share sheet, the system preview, and "Save to Files".
///
/// The owner's note on this was «تصدير كملفات او كصورة مو حلو، ما مرتب نفس الموقع» — the file goes
/// out untidily next to the website's. On the web a download *is* the file: it lands in Downloads
/// under the document's own name and the browser shows that name. On iOS the share sheet is the
/// download, and a bare `URL` handed to `UIActivityViewController` gives it nothing to say: the
/// header reads the raw temp filename with a generic page icon, Mail composes with an empty subject,
/// and the sheet offers to add a Word document to a reading list.
///
/// `FirasShareItem` is the fix. It is what the sheet asks for and answers properly: the document's
/// title in the header and in a mail subject, the real uniform type so each destination knows what
/// it is receiving, and a picture's own thumbnail when the export is a picture.
///
/// Nothing here writes the file — `ExportController` does that, into a temp directory — and nothing
/// here decides where it goes. The system does, which is the whole point.
struct FirasActivitySheet: UIViewControllerRepresentable {

    private let items: [Any]

    /// A file. `title` overrides the name shown in the sheet's header; by default it is the file's
    /// own name without its extension, which is what the export already made readable.
    init(url: URL, title: String? = nil) {
        self.items = [FirasShareItem(url: url, title: title)]
    }

    /// Several files at once — a picture export of a long thread, which comes out as one PNG per
    /// page rather than as one with its foot cut off.
    ///
    /// The sheet takes a list happily: Messages sends them as a run of pictures, Files saves them
    /// all, Mail attaches all of them. Handing it only the first was the bug — the other pages
    /// were written and then never left the app. Only page one carries the header metadata; a
    /// preview per page would make the sheet think for a second before it opens.
    init(urls: [URL], title: String? = nil) {
        guard let first = urls.first else {
            self.items = []
            return
        }
        var items: [Any] = [FirasShareItem(url: first, title: title)]
        for url in urls.dropFirst() {
            items.append(FirasShareItem(url: url, title: title, describes: false))
        }
        self.items = items
    }

    /// A finished export, with every page it produced. This is the initialiser a caller holding an
    /// `ExportController.Export` wants: `init(url: export.url)` shares page one and silently
    /// leaves the rest of a long picture behind.
    init(export: ExportController.Export, title: String? = nil) {
        self.init(urls: export.pages, title: title)
    }

    init(text: String) {
        self.items = [text]
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // `UIActivityViewController` raises on an empty item list, and nothing here is worth a
        // crash: an export always has at least one page, so this is the shape of a caller bug.
        let controller = UIActivityViewController(
            activityItems: items.isEmpty ? [""] : items,
            applicationActivities: nil
        )
        controller.excludedActivityTypes = FirasActivitySheet.excluded
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    /// Destinations a document or a picture from a chat has no business being offered. Everything
    /// that can genuinely receive a file — Files, Mail, Messages, Notes, Books, AirDrop, print,
    /// copy, markup, every installed app's share extension — stays.
    private static let excluded: [UIActivity.ActivityType] = [
        .assignToContact,
        .addToReadingList,
        .postToFlickr,
        .postToVimeo,
        .postToWeibo,
        .postToTencentWeibo
    ]
}

/// The share sheet's own questions, answered.
///
/// A plain `URL` in `activityItems` makes the sheet guess. This says instead: here is the file, here
/// is what it is called, here is its uniform type, and here is a preview. `NSObject` and no actor
/// isolation, like every other UIKit delegate in the app — the callbacks arrive on the main thread
/// because UIKit calls them there, not because Swift was told to insist.
///
/// It carries **links** too, because `ShareController` shares one: a share link must stay a link,
/// so it keeps `public.url` as its type and leaves the metadata to the system, which fetches the
/// page's own title and picture. Declaring a link to be `public.data` is how a tidy share turns
/// into an attachment nobody can open.
final class FirasShareItem: NSObject, UIActivityItemSource {

    private let url: URL
    private let providedTitle: String?
    /// Whether this item is the one that describes the share. Only the first of a set is: a sheet
    /// with five items builds its header from one of them, and five competing titles and five
    /// thumbnails to fetch is how a share sheet ends up thinking about nothing.
    private let describes: Bool

    init(url: URL, title: String? = nil, describes: Bool = true) {
        self.url = url
        let given = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.providedTitle = given.isEmpty ? nil : given
        self.describes = describes
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    /// Mail's subject line. Without it a shared document arrives as an untitled message.
    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        displayTitle
    }

    /// The real type, so Files stores it with the right icon and Mail attaches it with the right
    /// MIME instead of `application/octet-stream`.
    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        guard url.isFileURL else { return UTType.url.identifier }
        return UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
    }

    /// The header: the document's name, and its own picture when it is one. A link with nothing to
    /// add answers `nil`, which is what lets the sheet build its own preview for it.
    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        guard describes else { return nil }
        guard url.isFileURL || providedTitle != nil else { return nil }
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        if !displayTitle.isEmpty { metadata.title = displayTitle }
        if isPicture, let provider = NSItemProvider(contentsOf: url) {
            metadata.iconProvider = provider
        }
        return metadata
    }

    /// The given title, else the file's own name without its extension — which is already readable,
    /// because the export names its temp file from the document's heading.
    private var displayTitle: String {
        if let providedTitle { return providedTitle }
        guard url.isFileURL else { return "" }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Only a picture gets a picture for an icon: handing a 300-page PDF to `NSItemProvider` as an
    /// icon source makes the sheet think, and the reader wait, for nothing.
    private var isPicture: Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

/// The real document, previewed by the system.
///
/// `QLPreviewController` handles every format this app can produce — PDF, Word, Excel, PowerPoint,
/// CSV, HTML, images and plain text — with the platform's own renderer, its own zoom, its own text
/// selection and its own share button. Opening a generated file must show the *document*, never a
/// dump of the markdown it came from.
struct FirasDocumentPreview: UIViewControllerRepresentable {

    private let urls: [URL]

    init(url: URL) {
        self.urls = [url]
    }

    /// Every page of a multi-page export, which QuickLook already knows how to page through.
    init(urls: [URL]) {
        self.urls = urls
    }

    init(export: ExportController.Export) {
        self.init(urls: export.pages)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.urls = urls
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(urls: urls)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var urls: [URL]

        init(urls: [URL]) {
            self.urls = urls
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            // `reloadData` and the controller's own index can cross while a sheet is being
            // dismissed; a preview item is never worth a crash.
            guard urls.indices.contains(index) else {
                return URL(fileURLWithPath: NSTemporaryDirectory()) as NSURL
            }
            return urls[index] as NSURL
        }
    }
}

/// "Save to Files". The share sheet can reach iCloud Drive too, but the owner asked for the file to
/// land somewhere he can find it again, and the Files picker is the one control that says so.
///
/// `asCopy: true` — the exported file lives in a temp directory that the system may reclaim, so the
/// picker must copy the bytes rather than move the original out from under a preview that is still
/// on screen. The extension is shown, so the name in the picker is the name on disk.
struct FirasFileSaver: UIViewControllerRepresentable {

    private let urls: [URL]
    private let onFinish: (Bool) -> Void

    init(url: URL, onFinish: @escaping (Bool) -> Void) {
        self.urls = [url]
        self.onFinish = onFinish
    }

    /// Every page of a multi-page export. The picker exports a list in one go, so a thread that
    /// came out as four pictures is saved as four files under one gesture.
    init(urls: [URL], onFinish: @escaping (Bool) -> Void) {
        self.urls = urls
        self.onFinish = onFinish
    }

    init(export: ExportController.Export, onFinish: @escaping (Bool) -> Void) {
        self.init(urls: export.pages, onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
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
