import SwiftUI
import Perception

struct PastedTextItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let name: String
    let attachment: PreparedAttachment
    init(text: String, number: Int) {
        id = UUID(); self.text = text; name = "pasted-text-\(number)-\(id.uuidString.prefix(8)).txt"
        let bytes = Data(text.utf8)
        attachment = PreparedAttachment(name: name, kind: "text", text: text, byteCount: bytes.count,
            originalData: bytes, originalMime: "text/plain")
    }
    static func shouldCollapse(_ text: String) -> Bool {
        text.utf16.count >= 1600 || text.reduce(0, { $0 + ($1 == "\n" ? 1 : 0) }) >= 20
    }
}

struct PastedTextCard: View {
    let item: PastedTextItem
    let palette: FirasPalette
    let lang: AppLanguage
    let open: () -> Void
    let remove: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(item.text.prefix(140))).font(.system(size: 9)).lineLimit(5)
                        .foregroundStyle(palette.textMuted).frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    Text(LText(ar: "نص ملصوق", en: "PASTED")(lang))
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.accent)
                    Text("\(item.text.count)").font(.system(size: 9).monospacedDigit()).foregroundStyle(palette.textMuted)
                }.padding(12).frame(width: 104, height: 132)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette.border, lineWidth: 1))
                    .bidiIsland(for: item.text, fallback: lang)
            }.buttonStyle(.plain).accessibilityLabel(LText(ar: "افتح النص الملصوق", en: "Open pasted text")(lang))
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(palette.textSecondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).offset(x: 8, y: -8)
                .accessibilityLabel(LText(ar: "إزالة النص الملصوق", en: "Remove pasted text")(lang))
        }.padding(.top, 6).padding(.trailing, 6)
    }
}

struct PastedTextPreview: View {
    let item: PastedTextItem
    let palette: FirasPalette
    let lang: AppLanguage
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        FirasNavigationStack {
            ScrollView {
                Text(item.text).font(.body).textSelection(.enabled).foregroundStyle(palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20).bidiIsland(for: item.text, fallback: lang)
            }.background(palette.background)
                .navigationTitle(LText(ar: "النص الملصوق", en: "Pasted text")(lang))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(Strings.Common.done(lang)) { dismiss() } } }
        }.tint(palette.accent).firasSheetBackground(palette)
    }
}
