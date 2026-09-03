import SwiftUI
import UIKit

/// One item in the composer's tray: a picked image or document, from the moment it is picked to the
/// moment it is sent. `reading` is the web's `is-loading` skeleton / `...قراءة` chip.
struct ComposerAttachmentItem: Identifiable, Equatable, Sendable {

    enum Status: Equatable, Sendable {
        case reading
        case ready(PreparedAttachment)
    }

    let id: UUID
    let name: String
    /// `image` · `pdf` · `docx` · `pptx` · `xlsx` · `code`
    let kind: String
    var status: Status
    /// 100 unless the document was cut to fit the turn budget.
    var percentSent: Int

    init(id: UUID = UUID(), name: String, kind: String, status: Status = .reading, percentSent: Int = 100) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.percentSent = percentSent
    }

    var isImage: Bool { kind == "image" }
    var isReading: Bool { status == .reading }
    var truncated: Bool { percentSent < 100 }

    var prepared: PreparedAttachment? {
        if case .ready(let attachment) = status { return attachment }
        return nil
    }

    /// What this item costs against the 300 000-character document budget.
    var textCost: Int { prepared?.text?.count ?? 0 }
}

/// The row of thumbnails and file chips that sits above the composer's field
/// (`web-chat-ux.md §7.3`, `design-brief.md §7.3`).
///
/// It is not a glass surface: it lives *inside* the composer's glass so two translucent layers never
/// stack (`design-brief.md §2.5`).
struct AttachmentTray: View {

    private let items: [ComposerAttachmentItem]
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let motionOn: Bool
    private let onRemove: (UUID) -> Void
    private let onTruncatedTap: (ComposerAttachmentItem) -> Void

    init(
        items: [ComposerAttachmentItem],
        palette: FirasPalette,
        lang: AppLanguage,
        motionOn: Bool,
        onRemove: @escaping (UUID) -> Void,
        onTruncatedTap: @escaping (ComposerAttachmentItem) -> Void
    ) {
        self.items = items
        self.palette = palette
        self.lang = lang
        self.motionOn = motionOn
        self.onRemove = onRemove
        self.onTruncatedTap = onTruncatedTap
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(items) { item in
                    cell(for: item)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .frame(height: 78)
        .accessibilityLabel(Text(Strings.Composer.attachHint(lang)))
    }

    @ViewBuilder
    private func cell(for item: ComposerAttachmentItem) -> some View {
        if item.isImage {
            AttachmentThumbCell(
                item: item,
                palette: palette,
                lang: lang,
                motionOn: motionOn,
                onRemove: { onRemove(item.id) }
            )
        } else {
            AttachmentFileChip(
                item: item,
                palette: palette,
                lang: lang,
                onRemove: { onRemove(item.id) },
                onTruncatedTap: { onTruncatedTap(item) }
            )
        }
    }
}

// MARK: - Image cell

private struct AttachmentThumbCell: View {

    let item: ComposerAttachmentItem
    let palette: FirasPalette
    let lang: AppLanguage
    let motionOn: Bool
    let onRemove: () -> Void

    @State private var image: UIImage?

    var body: some View {
        thumb
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                RemoveBadge(palette: palette, lang: lang, action: onRemove)
                    .offset(x: 5, y: -5)
            }
            .padding(.top, 5)
            .padding(.trailing, 5)
            .task(id: item.prepared?.thumbnailDataURL) { await load() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(item.name))
    }

    @ViewBuilder
    private var thumb: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if item.isReading {
            SkeletonView(kind: .tiles, palette: palette, motionOn: motionOn)
                .frame(width: 64, height: 64)
                .clipped()
        } else {
            ZStack {
                palette.surfaceSunken
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(palette.textMuted)
            }
        }
    }

    private func load() async {
        guard let dataURL = item.prepared?.thumbnailDataURL else { return }
        let loaded = await ImageCache.shared.image(forDataURL: dataURL)
        image = loaded
    }
}

// MARK: - File chip

private struct AttachmentFileChip: View {

    let item: ComposerAttachmentItem
    let palette: FirasPalette
    let lang: AppLanguage
    let onRemove: () -> Void
    let onTruncatedTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: ChatAttachmentProcessor.kindTag(for: item.kind))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(item.truncated ? palette.onAccent : palette.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(item.truncated ? palette.codeWarn : palette.surfaceSunken)
                }
                .forceLTR()

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.isReading {
                    Text(Strings.Composer.chipReading(lang))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textMuted)
                } else if item.truncated {
                    Text(percentLine)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.codeWarn)
                        .lineLimit(1)
                }
            }
            .bidiIsland(for: item.name, fallback: lang)

            RemoveBadge(palette: palette, lang: lang, action: onRemove)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 240)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.surfaceSunken)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(item.truncated ? palette.codeWarn.opacity(0.55) : palette.border, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture {
            if item.truncated { onTruncatedTap() }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(item.name))
    }

    /// The chip only has room for the number; the full sentence is the toast behind the tap.
    private var percentLine: String {
        ArabicText.count(item.percentSent, lang) + "٪"
    }
}

// MARK: - Remove badge

private struct RemoveBadge: View {

    let palette: FirasPalette
    let lang: AppLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(palette.onAccent)
                .frame(width: 18, height: 18)
                .background { Circle().fill(palette.textSecondary) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Strings.Composer.removeAttachment(lang)))
    }
}
