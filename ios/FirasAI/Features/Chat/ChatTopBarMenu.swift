import SwiftUI

/// The «…» that sits beside New chat once a conversation has a turn in it.
///
/// The owner's rule for the top-right corner is two controls and no more: a compose glyph and this
/// one, the way Claude's app draws them. So everything a conversation can have done to it lives
/// here — rename, pin, share, export, delete — and every item is wired to the method `ChatStore`
/// already exposes for it rather than to a re-implementation. Nothing in this file talks to the
/// network; `ChatStore` owns the round trips, its own optimistic update and its own undo toast.
///
/// A **temporary** conversation gets a different list. Pin, rename and share each promise a record
/// that outlives the session, and this one has none: offering them would be the one lie the mode
/// cannot afford. What it gets instead is the way out — and the way out is the only item, because
/// ending is irreversible by construction (`ChatStore.discardTemporary`), which is why the
/// confirmation lives with the caller that performs it.
struct ChatTopBarMenu: View {

    private let env: AppEnvironment
    private let conversationID: String
    private let product: ProductKind
    private let isExporting: Bool
    private let onExport: (ExportController.Format) -> Void
    private let onEndTemporary: () -> Void

    /// The rename field is an alert rather than an inline field: the title being edited is the
    /// navigation title of the screen the menu is attached to, so there is no row to edit in place.
    @State private var isRenaming = false
    @State private var renameDraft = ""

    init(
        env: AppEnvironment,
        conversationID: String,
        product: ProductKind,
        isExporting: Bool,
        onExport: @escaping (ExportController.Format) -> Void,
        onEndTemporary: @escaping () -> Void
    ) {
        self.env = env
        self.conversationID = conversationID
        self.product = product
        self.isExporting = isExporting
        self.onExport = onExport
        self.onEndTemporary = onEndTemporary
    }

    var body: some View {
        let lang = env.prefs.lang

        return Menu {
            items
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Text(Strings.Chat.conversationActions(lang)))
        .alert(Strings.Common.rename(lang), isPresented: $isRenaming) {
            TextField(Strings.Shell.renamePrompt(lang), text: $renameDraft)
            Button(Strings.Common.cancel(lang), role: .cancel) {
                renameDraft = ""
            }
            Button(Strings.Common.save(lang)) {
                commitRename()
            }
        }
    }

    // MARK: - Items

    @ViewBuilder
    private var items: some View {
        let lang = env.prefs.lang

        if let conversation = conversation {
            if conversation.ephemeral {
                exportSection(conversation)
                Divider()
                Button(role: .destructive) {
                    onEndTemporary()
                } label: {
                    Label {
                        Text(Strings.Chat.temporaryEnd(lang))
                    } icon: {
                        Image(systemName: "xmark.shield")
                    }
                }
            } else {
                renameItem(conversation)
                pinItem(conversation)
                shareItem
                exportSection(conversation)
                Divider()
                deleteItem
            }
        } else {
            // The conversation was deleted (or its undo window closed) while the menu was open.
            Text(Strings.Chat.emptyConversation(lang))
        }
    }

    private func renameItem(_ conversation: ChatConversation) -> some View {
        Button {
            beginRename(conversation)
        } label: {
            Label {
                Text(Strings.Common.rename(env.prefs.lang))
            } icon: {
                Image(systemName: "pencil")
            }
        }
    }

    private func pinItem(_ conversation: ChatConversation) -> some View {
        let lang = env.prefs.lang
        let pinned = conversation.pinned
        return Button {
            Haptics.select()
            let chat = env.chat
            let id = conversationID
            Task { await chat.pin(id, !pinned) }
        } label: {
            Label {
                Text(pinned ? Strings.Shell.unpin.text(lang) : Strings.Shell.pin.text(lang))
            } icon: {
                Image(systemName: pinned ? "pin.slash" : "pin")
            }
        }
    }

    /// The share sheet is a routed destination (`AppSheet.share`), exactly as the sidebar's row
    /// menu opens it: `ShareSheetView` owns the link, the guest sign-up prompt and the 20-share cap.
    private var shareItem: some View {
        Button {
            Haptics.select()
            env.router.sheet = .share(conversationID: conversationID, messageCID: nil)
        } label: {
            Label {
                Text(Strings.Common.share(env.prefs.lang))
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    /// Deleting the conversation that is on screen has to leave somewhere to stand, so the screen
    /// is sent to a fresh page in the same movement. `ChatStore.delete` keeps its seven-second undo.
    private var deleteItem: some View {
        Button(role: .destructive) {
            Haptics.select()
            let chat = env.chat
            let id = conversationID
            Task { await chat.delete(id) }
            env.router.newConversation(in: product)
        } label: {
            Label {
                Text(Strings.Common.delete(env.prefs.lang))
            } icon: {
                Image(systemName: "trash")
            }
        }
    }

    /// Hidden entirely when there is nothing to export — a thread of nothing but questions is not
    /// a transcript, and a permanently grey row is noise.
    @ViewBuilder
    private func exportSection(_ conversation: ChatConversation) -> some View {
        let lang = env.prefs.lang

        if ExportTranscript.isExportable(conversation) {
            Menu {
                ForEach(ExportController.Format.allCases) { format in
                    Button {
                        onExport(format)
                    } label: {
                        Label {
                            Text(format.label(lang))
                        } icon: {
                            Image(systemName: format.symbol)
                        }
                    }
                }
            } label: {
                Label {
                    Text(isExporting ? Strings.Chat.exportWorking(lang) : Strings.Chat.exportAs(lang))
                } icon: {
                    Image(systemName: isExporting ? "hourglass" : "square.and.arrow.down")
                }
            }
            .disabled(isExporting)
        }
    }

    // MARK: - Rename

    private var conversation: ChatConversation? {
        env.chat.conversation(conversationID)
    }

    private func beginRename(_ conversation: ChatConversation) {
        Haptics.select()
        renameDraft = conversation.title
        isRenaming = true
    }

    private func commitRename() {
        let wanted = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renameDraft = ""
        guard !wanted.isEmpty, wanted != conversation?.title else { return }
        let chat = env.chat
        let id = conversationID
        Task { await chat.rename(id, title: wanted) }
    }
}
