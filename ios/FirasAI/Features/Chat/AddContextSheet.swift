import Photos
import PhotosUI
import SwiftUI
import UIKit

/// What the `+` sheet hands back to the composer. The sheet never processes anything itself: it is
/// dismissed the moment a file is picked, and a dismissed view's tasks die with it.
enum ComposerAttachmentPick: Sendable, Equatable {
    case images([Data])
    case files([URL])
}

/// The composer's `+` sheet (`design-brief.md §7.3.2`).
///
/// Two groups: **attach** (camera, photos, files — the web has no camera button, the OS picker
/// decides there) and **tools** (web search, thinking — hidden on Mini, dictation language, and the
/// Brain vision switch inside Firas Brain). Toggling a tool keeps the sheet open; picking a file
/// closes it. No forced layout direction and no opaque background over the system glass
/// (`audit-ios-chat.md §M18, §V2`).
struct AddContextSheet: View {

    private let env: AppEnvironment
    private let product: ProductKind
    private let onPick: (ComposerAttachmentPick) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var isLoadingPhotos = false

    init(
        env: AppEnvironment,
        product: ProductKind = .ai,
        onPick: @escaping (ComposerAttachmentPick) -> Void = { _ in }
    ) {
        self.env = env
        self.product = product
        self.onPick = onPick
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    var body: some View {
        NavigationStack {
            List {
                attachSection
                toolsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(Text(Strings.Composer.addTitle(lang)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.Common.close(lang)) { dismiss() }
                        .tint(palette.accent)
                }
            }
        }
        .firasSheetBackground(palette)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $showCamera) {
            ComposerCameraPicker { image in
                deliverCamera(image)
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFiles,
            allowedContentTypes: ChatAttachmentProcessor.acceptedFileTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFiles(result)
        }
        .onChange(of: photoItems) { _, items in
            loadPhotos(items)
        }
    }

    // MARK: - Attach

    private var attachSection: some View {
        Section {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showCamera = true
                } label: {
                    ContextRow(
                        symbol: "camera",
                        title: Strings.Composer.camera(lang),
                        subtitle: nil,
                        palette: palette
                    )
                }
                .buttonStyle(.plain)
            }

            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: ChatAttachmentProcessor.maxImages,
                matching: .images,
                photoLibrary: .shared()
            ) {
                ContextRow(
                    symbol: "photo.on.rectangle",
                    title: Strings.Composer.photos(lang),
                    subtitle: isLoadingPhotos ? Strings.Composer.chipReading(lang) : nil,
                    palette: palette
                )
            }

            Button {
                showFiles = true
            } label: {
                ContextRow(
                    symbol: "folder",
                    title: Strings.Composer.files(lang),
                    subtitle: nil,
                    palette: palette
                )
            }
            .buttonStyle(.plain)
        } header: {
            sectionHeader(
                product == .agent
                    ? Strings.Composer.agentAttachHint(lang)
                    : Strings.Composer.attachSection(lang)
            )
        }
        .listRowBackground(palette.surface.opacity(0.55))
    }

    // MARK: - Tools

    private var toolsSection: some View {
        Section {
            Toggle(isOn: searchBinding) {
                ContextRow(
                    symbol: "globe",
                    title: Strings.Composer.webSearch(lang),
                    subtitle: env.prefs.webSearchEnabled
                        ? Strings.Composer.searchOn(lang)
                        : Strings.Composer.searchOff(lang),
                    palette: palette
                )
            }
            .tint(palette.accent)

            if env.prefs.tier.showThinking {
                Toggle(isOn: thinkingBinding) {
                    ContextRow(
                        symbol: "sparkles",
                        title: Strings.Composer.thinking(lang),
                        subtitle: env.prefs.thinkingEnabled
                            ? Strings.Composer.thinkOn(lang)
                            : Strings.Composer.thinkOff(lang),
                        palette: palette
                    )
                }
                .tint(palette.accent)
            }

            if product == .brain {
                Toggle(isOn: visionBinding) {
                    ContextRow(
                        symbol: "eye",
                        title: Strings.Composer.brainVision(lang),
                        subtitle: nil,
                        palette: palette
                    )
                }
                .tint(palette.accent)
            }

            Button {
                dismiss()
                env.router.sheet = .dialectPicker
            } label: {
                HStack {
                    ContextRow(
                        symbol: "waveform",
                        title: Strings.Composer.dictationLanguage(lang),
                        subtitle: env.prefs.dictationDialect.label(lang),
                        palette: palette
                    )
                    Spacer(minLength: 8)
                    Text(verbatim: env.prefs.dictationDialect.flag)
                        .font(.system(size: 15))
                }
            }
            .buttonStyle(.plain)
        } header: {
            sectionHeader(Strings.Composer.toolsSection(lang))
        }
        .listRowBackground(palette.surface.opacity(0.55))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.textMuted)
    }

    // MARK: - Bindings

    private var searchBinding: Binding<Bool> {
        Binding(
            get: { env.prefs.webSearchEnabled },
            set: { newValue in
                env.prefs.webSearchEnabled = newValue
                Haptics.select()
            }
        )
    }

    private var thinkingBinding: Binding<Bool> {
        Binding(
            get: { env.prefs.thinkingEnabled },
            set: { newValue in
                env.prefs.thinkingEnabled = newValue
                Haptics.select()
            }
        )
    }

    private var visionBinding: Binding<Bool> {
        Binding(
            get: { env.brain.forceOCR },
            set: { newValue in
                env.brain.forceOCR = newValue
                Haptics.select()
            }
        )
    }

    // MARK: - Picking

    private func deliverCamera(_ image: UIImage?) {
        showCamera = false
        guard let image, let data = image.jpegData(compressionQuality: 0.92) else {
            dismiss()
            return
        }
        onPick(.images([data]))
        dismiss()
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            onPick(.files(urls))
            dismiss()
        case .failure:
            env.toasts.show(Strings.Composer.unreadableFile(lang), isError: true)
            dismiss()
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isLoadingPhotos = true
        Task {
            var payloads: [Data] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty {
                    payloads.append(data)
                }
            }
            isLoadingPhotos = false
            photoItems = []
            if payloads.isEmpty {
                env.toasts.show(Strings.Composer.unreadableImage(lang), isError: true)
            } else {
                onPick(.images(payloads))
            }
            dismiss()
        }
    }
}

// MARK: - Row

private struct ContextRow: View {

    let symbol: String
    let title: String
    let subtitle: String?
    let palette: FirasPalette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .multilineTextAlignment(.leading)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Camera

/// A plain camera sheet. `UIImagePickerController` is still the only one-tap still-capture surface
/// that needs no capture session of our own — and the app's audio graph must never share one.
private struct ComposerCameraPicker: UIViewControllerRepresentable {

    let onCapture: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {

        private let onCapture: (UIImage?) -> Void

        init(onCapture: @escaping (UIImage?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onCapture(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
