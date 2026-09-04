import SwiftUI

/// Firas Brain (`design-brief.md §7.10`, `web-brain-ux.md §5`).
///
/// iPhone: the ask thread, the source chips above the composer, and the library as a large sheet.
/// iPad: three columns — the library (280 pt), the thread, and the passage reader on the trailing
/// edge. Guests are allowed everywhere here; only the whole-document read is members-only.
struct BrainScreen: View {

    private let env: AppEnvironment

    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var conversationID: String?
    @State private var draft = ""
    @State private var showLibrary = false
    @State private var citedSource: BrainSource?
    @State private var textSelection = FirasTextSelection()
    @State private var quotedText: String?

    init(env: AppEnvironment, conversationID: String?) {
        self.env = env
        _conversationID = State(initialValue: conversationID)
    }

    var body: some View {
        layout
            .environment(\.firasTextSelection, textSelection)
            .onChange(of: textSelection.request) { _, request in
                guard let request else { return }
                quotedText = String(request.text.prefix(8_000))
            }
            .background {
                FirasBackground(palette: palette, showHalo: true).ignoresSafeArea()
            }
            .navigationTitle(ProductKind.brain.title(lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !isRegular {
                        FirasIconButton(
                            symbol: "doc.text",
                            label: Strings.Brain.sourcesHead(lang),
                            palette: palette,
                            action: { showLibrary = true }
                        )
                    }
                }
            }
            .task {
                if let id = conversationID, !id.isEmpty {
                    await env.chat.open(id)
                }
                await store.loadLibrary()
            }
            .onChange(of: conversationID) { _, id in
                quotedText = nil
                guard let id, !id.isEmpty else { return }
                Task { await env.chat.open(id) }
            }
            .sheet(isPresented: $showLibrary) {
                BrainLibrarySheet(env: env)
            }
            .sheet(item: passageSheet) { source in
                PassageReaderSheet(env: env, source: source, question: lastQuestion)
            }
    }

    // MARK: - Layout

    @ViewBuilder
    private var layout: some View {
        if isRegular {
            HStack(spacing: 0) {
                BrainLibrarySheet(env: env, embedded: true)
                    .frame(width: 280)
                    .background(palette.sidebar)
                Divider().overlay(palette.border)
                thread
                if let source = citedSource {
                    Divider().overlay(palette.border)
                    passageColumn(source)
                }
            }
        } else {
            thread
        }
    }

    private var thread: some View {
        VStack(spacing: 0) {
            BrainThreadView(env: env, conversationID: conversationID) { source in
                Haptics.select()
                citedSource = source
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            BrainComposer(
                env: env,
                draft: $draft,
                quotedText: $quotedText,
                onSend: { send(outline: false) },
                onStop: { store.stopAsk() },
                onSummarize: { send(outline: true) },
                onOpenLibrary: { showLibrary = true }
            )
        }
    }

    /// The reader as the trailing inspector column; the sheet's own close button belongs to its
    /// navigation chrome, so the column carries one of its own.
    private func passageColumn(_ source: BrainSource) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(Strings.Brain.passageTitle(lang))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 0)
                Button {
                    citedSource = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Strings.Common.close(lang)))
            }
            .padding(.horizontal, 12)

            PassageReaderSheet(env: env, source: source, question: lastQuestion, embedded: true)
        }
        .frame(width: 340)
    }

    // MARK: - Environment shortcuts

    private var store: BrainStore { env.brain }
    private var prefs: PreferencesStore { env.prefs }
    private var palette: FirasPalette { prefs.palette }
    private var lang: AppLanguage { prefs.lang }
    private var isRegular: Bool { sizeClass == .regular }

    /// The question the reader marks the closest sentences against (`web-brain-ux.md §11.4`).
    /// Without it `BrainPassageHighlighter` has nothing to score and marks nothing.
    private var lastQuestion: String? {
        guard let conversationID, !conversationID.isEmpty else { return nil }
        let messages = env.chat.conversation(conversationID)?.messages ?? []
        return messages.last(where: { $0.role == .user })?.visibleContent
    }

    /// On iPad the passage is a column, so the sheet binding is deliberately empty there.
    private var passageSheet: Binding<BrainSource?> {
        Binding(
            get: { isRegular ? nil : citedSource },
            set: { citedSource = $0 }
        )
    }

    // MARK: - Sending

    private func send(outline: Bool) {
        guard !store.isAsking else { return }
        var text: String = outline
            ? Strings.Brain.summarizeAsk(store.activeDocIDs.count, lang)
            : draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !outline, let quote = quotedText, !quote.isEmpty {
            text = PromptCatalog.quotePrefix(passages: [(quote, lang.rawValue)]) + "\n" + text
        }

        let conversation = ensureConversation()
        if !outline { draft = ""; quotedText = nil }
        Keyboard.dismiss()
        Haptics.send()
        Task { await store.ask(text, outline: outline, in: conversation) }
    }

    private func ensureConversation() -> String {
        if let conversationID, !conversationID.isEmpty { return conversationID }
        let created = env.chat.newConversation(
            product: .brain,
            flags: (agent: false, codeProj: false, brainNb: true)
        )
        conversationID = created
        env.router.select(conversationID: created, product: .brain)
        return created
    }
}

// MARK: - Composer

/// The Brain composer: the source chips, the field, Summarize, dictation and send/stop.
///
/// With no sources at all the field is disabled and the send button is gone — the placeholder is
/// the instruction (`design-brief.md §7.10`). While a durable job is answering, Stop is replaced by
/// a live dot: the server keeps going whether we watch or not.
private struct BrainComposer: View {

    let env: AppEnvironment
    @Binding var draft: String
    @Binding var quotedText: String?
    let onSend: () -> Void
    let onStop: () -> Void
    let onSummarize: () -> Void
    let onOpenLibrary: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let quotedText {
                QuotedTextContext(text: quotedText, palette: palette, lang: lang) { self.quotedText = nil }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            SourceChipsRow(store: store, prefs: prefs, onOpenLibrary: onOpenLibrary)
            HStack(alignment: .bottom, spacing: 6) {
                field
                summarizeButton
                dictationButton
                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .firasGlass(
            .floating,
            palette: palette,
            in: AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .onChange(of: quotedText) { _, value in
            if value != nil { focused = true }
        }
    }

    private var store: BrainStore { env.brain }
    private var prefs: PreferencesStore { env.prefs }
    private var palette: FirasPalette { prefs.palette }
    private var lang: AppLanguage { prefs.lang }
    private var isEmptyDraft: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        store.hasDocuments ? Strings.Brain.askPlaceholder(lang) : Strings.Brain.askNoSources(lang)
    }

    private var field: some View {
        TextField(placeholder, text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .font(FirasType.scaled(16, scale: prefs.fontScale))
            .foregroundStyle(palette.textPrimary)
            .focused($focused)
            .disabled(!store.hasDocuments)
            .padding(.vertical, 10)
            .bidiIsland(for: draft, fallback: lang)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var summarizeButton: some View {
        if !store.activeDocIDs.isEmpty && !store.isAsking {
            FirasIconButton(
                symbol: "list.bullet.rectangle",
                label: Strings.Brain.summarize(lang),
                palette: palette,
                action: onSummarize
            )
        }
    }

    @ViewBuilder
    private var dictationButton: some View {
        if !store.isAsking && store.hasDocuments {
            FirasIconButton(
                symbol: env.dictation.state == .recording ? "stop.circle" : "mic",
                label: Strings.Brain.micLabel(lang),
                palette: palette,
                action: { toggleDictation() }
            )
        }
    }

    /* THE WORDS ARRIVE AS THEY ARE SPOKEN. `start(into:)` hands the controller the draft binding, so
       the recogniser writes into this field live and replaces its own run as it refines — the same
       behaviour as the chat composer, from the same controller. The append below stays for the
       fallback path: a live take makes `finish()` return nil, because the text is already in the
       field, so nothing is written twice. */
    private func toggleDictation() {
        if env.dictation.state == .recording {
            Task {
                if let text = await env.dictation.finish(), !text.isEmpty {
                    draft = draft.isEmpty ? text : draft + " " + text
                }
            }
        } else {
            Task { _ = await env.dictation.start(into: $draft) }
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if store.isAsking {
            if store.isDurableAsk {
                LiveDot(
                    palette: palette,
                    motionOn: FirasMotion.isOn(prefs: prefs, reduceMotion: reduceMotion)
                )
                .frame(width: 44, height: 44)
                .accessibilityLabel(Text(Strings.Brain.queued(lang)))
            } else {
                FirasIconButton(
                    symbol: "stop.fill",
                    label: Strings.Common.stop(lang),
                    palette: palette,
                    prominent: true,
                    action: onStop
                )
            }
        } else if store.hasDocuments {
            FirasIconButton(
                symbol: "arrow.up",
                label: Strings.Common.send(lang),
                palette: palette,
                prominent: true,
                action: onSend
            )
            .disabled(isEmptyDraft)
            .opacity(isEmptyDraft ? 0.4 : 1)
        }
    }
}
