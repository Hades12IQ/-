import SwiftUI
import UIKit

struct ChatMessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            UserMessageRow(message: message)
        case .assistant:
            AssistantMessageRow(message: message)
        case .system, .unknown:
            SystemMessageRow(message: message)
        }
    }
}

private struct UserMessageRow: View {
    let message: ChatMessage

    @Environment(PreferencesStore.self) private var preferences
    @State private var selectedImage: ChatPreviewImage?

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            if let thumbnails = message.imageThumbs, !thumbnails.isEmpty {
                ChatImageGrid(thumbnails: thumbnails) { image in
                    selectedImage = image
                }
            }

            if !message.content.isEmpty {
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(preferences.palette.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(
                        preferences.palette.surface,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(preferences.palette.border, lineWidth: 1)
                    }
            }

            if let files = message.files, !files.isEmpty {
                AttachmentChips(files: files)
            }
        }
        .frame(maxWidth: 620, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(ChatStrings.you))
        .sheet(item: $selectedImage) { preview in
            ChatImagePreview(image: preview.image)
        }
    }
}

private struct ChatPreviewImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ChatImageGrid: View {
    let thumbnails: [String]
    let onOpen: (ChatPreviewImage) -> Void

    @Environment(PreferencesStore.self) private var preferences

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 7)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .trailing, spacing: 7) {
            ForEach(Array(decodedImages.enumerated()), id: \.offset) { index, image in
                Button {
                    onOpen(ChatPreviewImage(image: image))
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 104, idealWidth: 138, maxWidth: 180, minHeight: 112, maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke(preferences.palette.border, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ChatStrings.contextRecentPhoto))
                .accessibilityValue(Text(verbatim: "\(index + 1)"))
            }
        }
        .frame(maxWidth: 440, alignment: .trailing)
    }

    private var decodedImages: [UIImage] {
        thumbnails.compactMap { source in
            let encoded = source.split(separator: ",", maxSplits: 1).last.map(String.init) ?? source
            guard let data = Data(base64Encoded: encoded) else { return nil }
            return UIImage(data: data)
        }
    }
}

private struct ChatImagePreview: View {
    let image: UIImage

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                preferences.palette.background.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Text("common.close"))
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .presentationBackground(preferences.palette.background)
    }
}

private struct AssistantMessageRow: View {
    let message: ChatMessage

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FirasBrandMark(size: 27)
                .frame(width: 28, height: 30, alignment: .top)

            VStack(alignment: .leading, spacing: 10) {
                if message.content.isEmpty, message.state == .sending {
                    FirasActivityLabel(kind: activityKind, isActive: true)
                } else {
                    Text(message.content)
                        .font(.body)
                        .foregroundStyle(preferences.palette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup {
                        Text(reasoning)
                            .font(.subheadline)
                            .foregroundStyle(preferences.palette.textSecondary)
                            .textSelection(.enabled)
                            .padding(.top, 6)
                    } label: {
                        Label("chat.reasoning", systemImage: "brain")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(preferences.palette.textSecondary)
                            .frame(minHeight: 44)
                    }
                    .tint(preferences.palette.accent)
                }

                if message.state == .failed {
                    Label {
                        Text(ChatStrings.failed)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .accessibilityHidden(true)
                    }
                    .font(.caption)
                    .foregroundStyle(preferences.palette.error)
                } else if message.state == .stopped {
                    Label {
                        Text(ChatStrings.stopped)
                    } icon: {
                        Image(systemName: "stop.circle")
                            .accessibilityHidden(true)
                    }
                    .font(.caption)
                    .foregroundStyle(preferences.palette.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("chat.assistant")
    }

    private var activityKind: FirasActivityKind {
        let mode = message.mode?.lowercased() ?? ""
        if mode.contains("search") || mode.contains("web") || mode.contains("brain") {
            return .searching
        }
        if mode.contains("code") || mode.contains("build") || mode.contains("agent") {
            return .building
        }
        if message.reasoning?.isEmpty == false || mode.contains("think") {
            return .thinking
        }
        return .writing
    }
}

private struct SystemMessageRow: View {
    let message: ChatMessage

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        if !message.content.isEmpty {
            Text(message.content)
                .font(.caption)
                .foregroundStyle(preferences.palette.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    preferences.palette.surfaceSunken.opacity(0.75),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
    }
}

private struct AttachmentChips: View {
    let files: [ChatAttachment]

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(files, id: \.name) { file in
                    Label {
                        Text(file.name)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "paperclip")
                            .accessibilityHidden(true)
                    }
                    .font(.caption)
                    .foregroundStyle(preferences.palette.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 32)
                    .background(
                        preferences.palette.surfaceSunken,
                        in: Capsule()
                    )
                    .accessibilityLabel(Text(ChatStrings.attachment))
                    .accessibilityValue(Text(verbatim: file.name))
                }
            }
        }
    }
}
