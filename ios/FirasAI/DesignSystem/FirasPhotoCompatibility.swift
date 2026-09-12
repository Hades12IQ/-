import PhotosUI
import SwiftUI
import Perception
import UniformTypeIdentifiers

struct FirasPhotoSelection: Equatable, @unchecked Sendable {
    let id = UUID()
    fileprivate let provider: NSItemProvider
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    func loadData() async throws -> Data {
        let type = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        } ?? UTType.image.identifier
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: CocoaError(.fileReadCorruptFile)) }
            }
        }
    }
}

/// PHPicker keeps the system's private photo selection flow on every supported OS.
struct FirasPhotosPicker<Label: View>: View {
    private let selected: ([FirasPhotoSelection]) -> Void
    private let limit: Int
    private let label: () -> Label
    @State private var presented = false

    init(selection: Binding<[FirasPhotoSelection]>, maxSelectionCount: Int, @ViewBuilder label: @escaping () -> Label) {
        selected = { selection.wrappedValue = $0 }
        limit = maxSelectionCount
        self.label = label
    }

    init(selection: Binding<FirasPhotoSelection?>, @ViewBuilder label: @escaping () -> Label) {
        selected = { selection.wrappedValue = $0.first }
        limit = 1
        self.label = label
    }

    var body: some View {
        WithPerceptionTracking {
        Button { presented = true } label: { WithPerceptionTracking {
        label()
        } }
            .sheet(isPresented: $presented) {
                WithPerceptionTracking {
                PickerController(limit: limit) { values in
                    presented = false
                    if !values.isEmpty { selected(values) }
                }.ignoresSafeArea()

                }}

        }}

    private struct PickerController: UIViewControllerRepresentable {
        let limit: Int
        let finished: ([FirasPhotoSelection]) -> Void
        func makeCoordinator() -> Coordinator { Coordinator(finished) }
        func makeUIViewController(context: Context) -> PHPickerViewController {
            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.filter = .images
            config.selectionLimit = max(1, limit)
            config.preferredAssetRepresentationMode = .current
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = context.coordinator
            return picker
        }
        func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
            context.coordinator.finished = finished
        }
        final class Coordinator: NSObject, PHPickerViewControllerDelegate {
            var finished: ([FirasPhotoSelection]) -> Void
            init(_ finished: @escaping ([FirasPhotoSelection]) -> Void) { self.finished = finished }
            func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
                finished(results.map { FirasPhotoSelection(provider: $0.itemProvider) })
            }
        }
    }
}
