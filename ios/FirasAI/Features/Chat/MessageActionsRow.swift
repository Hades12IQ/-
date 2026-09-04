import SwiftUI
import UIKit

/// The quiet row under an answer: copy, regenerate, listen, export, more.
///
/// It is furniture, not content. Ghost glyphs in `textMuted` with no chip, no ring and no ground —
/// the row should be findable when you look for it and invisible when you are reading, which is what
/// "a row that does not shout" means. On a pointer device it sits at 78 % and comes to full strength
/// on hover; on touch there is no hover to reveal it with, so it simply stays legible.
///
/// Copy says `تم النسخ` in place for 1.4 s — never a toast for the happy path, always one for the
/// failure (`design-brief.md §7.7`).
struct MessageActionsRow: View {

    private let env: AppEnvironment
    private let message: ChatMessage
    private let conversationID: String
    private let product: ProductKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var copied = false
    @State private var hovering = false
    @State private var translation: String?
    @State private var translationLanguage: TranslationLanguage?
    @State private var showsLanguagePicker = false
    @State private var isTranslating = false
    @State private var translationRequestID: UUID?
    @State private var isExporting = false
    /// The picker and the file it produced share one route, because they share one `.sheet`.
    @State private var exportSheet: ChatExportRoute?

    /// Wide enough to hit, small enough to disappear into the page.
    private static let buttonWidth: CGFloat = 38
    private static let buttonHeight: CGFloat = 34

    init(
        env: AppEnvironment,
        message: ChatMessage,
        conversationID: String,
        product: ProductKind
    ) {
        self.env = env
        self.message = message
        self.conversationID = conversationID
        self.product = product
    }

    /// Both switches, never just the in-app one (`FirasMotion.isOn`).
    private var motionOn: Bool {
        FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion)
    }

    var body: some View {
        let palette = env.prefs.palette
        let lang = env.prefs.lang

        return VStack(alignment: .leading, spacing: 10) {
            row(palette: palette, lang: lang)
            translationBlock(palette: palette, lang: lang)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: env.session.identityID) { _, _ in
            translationRequestID = nil
            isTranslating = false
            translation = nil
            translationLanguage = nil
            showsLanguagePicker = false
        }
        .sheet(item: $exportSheet) { route in
            exportSheetBody(route)
        }
        .sheet(isPresented: $showsLanguagePicker) {
            TranslationLanguagePicker(lang: lang, palette: palette) { target in
                translate(to: target, lang: lang)
            }
        }
    }

    /// One sheet, two stops: choose the format, then hand over the file. `ExportFormatPicker`
    /// dismisses itself as it passes the format on, and writing the document takes long enough that
    /// the sheet is empty again well before there is a file to put in it.
    ///
    /// The paint and the language are read here rather than captured from `body`, so a theme or a
    /// language changed while the picker is open reaches the picker too.
    @ViewBuilder
    private func exportSheetBody(_ route: ChatExportRoute) -> some View {
        switch route {
        case .picker:
            ExportFormatPicker(
                lang: env.prefs.lang,
                palette: env.prefs.palette,
                isWorking: isExporting
            ) { format in
                export(format, lang: env.prefs.lang)
            }
        case .file(let finished):
            // `export:` and not `url:`. A picture export is one PNG per page, and `url` names
            // only the first — the others were written and then silently left behind.
            FirasActivitySheet(export: finished)
        }
    }

    // MARK: - The row

    private func row(palette: FirasPalette, lang: AppLanguage) -> some View {
        HStack(spacing: 0) {
            copyButton(palette: palette, lang: lang)
            if product == .ai {
                regenerateMenu(palette: palette, lang: lang)
            }
            listenButton(palette: palette, lang: lang)
            exportButton(palette: palette, lang: lang)
            moreMenu(palette: palette, lang: lang)
            Spacer(minLength: 0)
        }
        // The whole row is inset by the glyph's own optical padding so the first icon lines up with
        // the first letter of the answer above it instead of floating a few points to its side.
        .padding(.leading, -10)
        .opacity(hovering ? 1 : 0.78)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private func copyButton(palette: FirasPalette, lang: AppLanguage) -> some View {
        ghost(
            symbol: copied ? "checkmark" : "doc.on.doc",
            title: copied ? Strings.Common.copied(lang) : Strings.Common.copy(lang),
            tint: copied ? palette.success : palette.textMuted
        ) {
            performCopy(lang: lang)
        }
    }

    private func listenButton(palette: FirasPalette, lang: AppLanguage) -> some View {
        let speaking = env.tts.speakingMessageID == message.id
        return ghost(
            symbol: speaking ? "stop.fill" : "speaker.wave.2",
            title: speaking ? Strings.Chat.listenStop(lang) : Strings.Chat.listen(lang),
            tint: speaking ? palette.accent : palette.textMuted
        ) {
            ChatTurnActions.listen(message: message, env: env)
        }
    }

    private func regenerateMenu(palette: FirasPalette, lang: AppLanguage) -> some View {
        Menu {
            Button {
                ChatTurnActions.regenerate(
                    messageID: message.id,
                    conversationID: conversationID,
                    tier: nil,
                    env: env
                )
            } label: {
                Text(Strings.Chat.regenSame(lang))
                Image(systemName: "arrow.clockwise")
            }

            if message.tier != ModelTier.max.rawValue {
                Button {
                    ChatTurnActions.regenerate(
                        messageID: message.id,
                        conversationID: conversationID,
                        tier: .max,
                        env: env
                    )
                } label: {
                    Text(Strings.Chat.regenMax(lang))
                    Image(systemName: "crown")
                }
            }
        } label: {
            ghostLabel(symbol: "arrow.clockwise", tint: palette.textMuted)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Text(Strings.Chat.regenerate(lang)))
    }

    /// A SHEET, NOT A STRIP OF NINE EXTENSIONS. The glyph used to open a `Menu` listing `.docx`,
    /// `.xlsx`, `.pptx` and six more with nothing but their names — a list that only helps a reader
    /// who already knows the answer. `ExportFormatPicker` groups the same nine by what the file is
    /// for and gives each one its own sentence, which needs more room than a menu strip has.
    private func exportButton(palette: FirasPalette, lang: AppLanguage) -> some View {
        ghost(
            symbol: isExporting ? "hourglass" : "square.and.arrow.down",
            title: Strings.Chat.download(lang),
            tint: palette.textMuted
        ) {
            Haptics.select()
            exportSheet = .picker
        }
        .disabled(isExporting)
    }

    /* THE WHOLE CONVERSATION, NOT THE LAST REPLY. This took its title from the first message and
       its body from the one answer the button sits under, and dropped everything between — «من
       اصدر شي بالاخير ما ياخذ اول رسالة الي يحطها عنوان وياخذ رد اخر شي يحطه لا لازم كلشي بالسرة».
       A file made of a title and a tail is not an export of anything. The conversation overload
       walks every turn in order; the per-answer form stays for the surfaces that genuinely carry
       one document.

       AND THROUGH `conversation(_:)`, NOT THE DICTIONARY. The lookup below decides which of those
       two documents gets written, and the raw subscript misses a conversation filed under its
       local `ios_…` key whenever this screen was opened by server id — a notification tap, a
       shared link. It missed silently, took the per-answer branch, and handed back exactly the
       title-and-tail file the paragraph above exists to prevent. `ChatStore.conversation(_:)`
       resolves either id onto the one record. */
    /// The answer, and the question that earned it.
    ///
    /// Ordered question-then-answer whatever order they were found in, because that is how the
    /// exchange reads and how every writer downstream expects to receive it.
    static func exchange(for answer: ChatMessage, in messages: [ChatMessage]) -> [ChatMessage] {
        guard let index = messages.firstIndex(where: { $0.id == answer.id }) else { return [answer] }
        let cid = (answer.cid ?? "").trimmingCharacters(in: .whitespaces)
        if !cid.isEmpty,
           let question = messages.first(where: { $0.role == .user && $0.cid == answer.cid }) {
            return [question, answer]
        }
        // No cid to pair on: the nearest question above this answer is the one it belongs to.
        for candidate in messages[..<index].reversed() where candidate.role == .user {
            return [candidate, answer]
        }
        return [answer]
    }

    private func export(_ format: ExportController.Format, lang: AppLanguage) {
        guard !isExporting else { return }
        isExporting = true
        let controller = ExportController(env: env)
        let conversation = env.chat.conversation(conversationID)
        let source = ChatTurnActions.markdown(message)
        let title = conversation?.title ?? Strings.Chat.newChat(lang)
        let picked = Date()
        /* THIS EXCHANGE, NOT THE WHOLE THREAD. The button belongs to one answer, so it exports
           that answer and the question that earned it — «مو ب سوالي وردي الي عليها
           الزر». Exporting the entire conversation is a different action and lives in the
           top-bar menu, which belongs to the conversation rather than to a message.
           The two halves of a turn share a cid, which is how the question is found; a turn from
           an older build that has none falls back to the nearest question above it. Building a
           trimmed copy of the conversation rather than pasting two strings together is what
           keeps the file identical in shape to a full export — same heading style, same meta
           line, same per-block direction — only shorter. */
        let slice = conversation.map { whole -> ChatConversation in
            var trimmed = whole
            trimmed.messages = MessageActionsRow.exchange(for: message, in: whole.messages)
            return trimmed
        }
        Task {
            if let slice, slice.messages.count > 1 {
                await controller.export(format, conversation: slice)
            } else {
                await controller.export(format, markdown: source, title: title)
            }
            isExporting = false
            if let finished = controller.result {
                await ChatExportRoute.settle(since: picked)
                exportSheet = .file(finished)
            }
        }
    }

    private func moreMenu(palette: FirasPalette, lang: AppLanguage) -> some View {
        Menu {
            if ChatTurnActions.looksTruncated(message), !ChatTurnActions.isCardTurn(message) {
                Button {
                    ChatTurnActions.continueAnswer(
                        messageID: message.id,
                        conversationID: conversationID,
                        env: env
                    )
                } label: {
                    Text(Strings.Chat.continueAnswer(lang))
                    Image(systemName: "text.append")
                }
            }

            Button {
                ChatTurnActions.share(message: message, conversationID: conversationID, env: env)
            } label: {
                Text(Strings.Chat.shareOne(lang))
                Image(systemName: "link")
            }

            if env.session.isMember {
                Button {
                    showsLanguagePicker = true
                } label: {
                    Text(Strings.Chat.translateAction(lang))
                    Image(systemName: "character.book.closed")
                }
                .disabled(isTranslating)
                if translation != nil {
                    Button(Strings.Chat.translateHide(lang)) { translation = nil }
                }
            }
        } label: {
            ghostLabel(symbol: "ellipsis", tint: palette.textMuted)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Text(Strings.Chat.more(lang)))
    }

    // MARK: - Translation

    @ViewBuilder
    private func translationBlock(palette: FirasPalette, lang: AppLanguage) -> some View {
        if isTranslating {
            FirasActivityLabel(
                text: Strings.Chat.translateWorking(lang),
                palette: palette,
                motionOn: motionOn
            )
        } else if let translation {
            VStack(alignment: .leading, spacing: 6) {
                Text(translationLanguage?.name ?? Strings.Chat.translateTitle(lang))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textMuted)
                MarkdownView(
                    markdown: translation,
                    messageID: message.id + ".translation." + (translationLanguage?.id ?? ""),
                    streaming: false,
                    lang: lang,
                    palette: palette,
                    prefs: env.prefs,
                    onFence: { _ in nil }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.surfaceSunken)
            }
        }
    }

    private func translate(to target: TranslationLanguage, lang: AppLanguage) {
        guard !isTranslating else { return }
        guard let owner = env.session.identityID, env.session.isMember else { return }
        let source = ChatTurnActions.markdown(message).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            env.toasts.show(Strings.Chat.exportEmpty(lang), isError: true)
            return
        }
        isTranslating = true
        let requestID = UUID()
        translationRequestID = requestID
        let api = env.api
        let session = env.session
        Task {
            defer {
                if translationRequestID == requestID {
                    isTranslating = false
                    translationRequestID = nil
                }
            }
            do {
                let result = try await TranslationService.translate(source, to: target, api: api) {
                    await MainActor.run { session.isMember && session.identityID == owner }
                }
                guard session.isMember, session.identityID == owner, translationRequestID == requestID else { return }
                translationLanguage = target
                translation = result
            } catch {
                guard session.isMember, session.identityID == owner, translationRequestID == requestID else { return }
                env.toasts.show(Strings.Chat.translateFailed(lang), isError: true)
            }
        }
    }

    // MARK: - Copy

    private func performCopy(lang: AppLanguage) {
        guard ChatTurnActions.copy(ChatTurnActions.markdown(message), env: env) else {
            env.toasts.show(Strings.Common.copyFailed(lang), isError: true)
            return
        }
        withAnimation(FirasMotion.gated(FirasMotion.fade, motionOn: motionOn)) { copied = true }
        let flag = $copied
        let animate = motionOn
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(FirasMotion.gated(FirasMotion.fade, motionOn: animate)) {
                flag.wrappedValue = false
            }
        }
    }

    // MARK: - Chrome

    private func ghost(
        symbol: String,
        title: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ghostLabel(symbol: symbol, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private func ghostLabel(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: MessageActionsRow.buttonWidth, height: MessageActionsRow.buttonHeight)
            .contentShape(Rectangle())
    }
}
