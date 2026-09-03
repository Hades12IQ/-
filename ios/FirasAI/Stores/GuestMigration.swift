import Foundation

/// The one-shot handover that runs when a guest becomes a member.
///
/// A guest's conversations live only on the device (`web-auth-account-settings.md §5.6`). The
/// moment the same person signs in, every one of those conversations is POSTed to `/api/chats`
/// under the new account, the guest cookie is dropped, and the sidebar is reloaded from the server.
///
/// Three properties make this safe to run at a bad moment (mid-flight, offline, on a second
/// device): `POST /api/chats` is idempotent per `clientId`, so a repeat is a no-op that returns the
/// existing record; a conversation is deleted locally only after its upload succeeded, so a failure
/// loses nothing; and the guest session is ended fire-and-forget, because a failed `DELETE
/// /api/guest` must never be the reason the user's chats appear to be missing.
@MainActor
final class GuestMigration {

    /// Three at a time: enough to make a dozen chats feel instant, few enough that a cold account
    /// does not meet its own rate limit.
    private static let concurrency = 3

    private let api: APIClient
    private let guestChats: GuestChatStore
    private let chat: ChatStore
    private let toasts: ToastCenter

    private var isRunning = false

    init(api: APIClient, guestChats: GuestChatStore, chat: ChatStore, toasts: ToastCenter) {
        self.api = api
        self.guestChats = guestChats
        self.chat = chat
        self.toasts = toasts
    }

    func run(previousGuestID: String) async {
        let owner = previousGuestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let chats = await guestChats.load(owner: owner)
        let worth = chats.filter { conversation in
            conversation.messages.contains { message in
                !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        var migrated = 0
        if !worth.isEmpty {
            var pending = worth
            while !pending.isEmpty {
                let batch = Array(pending.prefix(Self.concurrency))
                pending.removeFirst(batch.count)
                let done = await upload(batch)
                migrated += done.count
                for id in done {
                    await guestChats.delete(id, owner: owner)
                }
            }
        }

        // Fire-and-forget by contract: the account already exists, and a guest record that outlives
        // this call expires by itself in seven days.
        Task { [api] in
            try? await api.guestEnd()
        }
        await guestChats.purgeExpired()

        if migrated > 0 {
            toasts.show(Strings.ChatStoreCopy.guestMigrated(chat.lang))
        }
        await chat.loadConversations()
    }

    // MARK: - Private

    /// Uploads one batch and answers with the local ids that reached the server.
    private func upload(_ batch: [ChatConversation]) async -> [String] {
        let client = api
        return await withTaskGroup(of: String?.self) { group in
            for conversation in batch {
                let request = CreateChatRequest(
                    title: conversation.title,
                    messages: MessageSerializer.persisted(conversation),
                    agent: conversation.agent ? true : nil,
                    codeProj: conversation.codeProj ? true : nil,
                    brainNb: conversation.brainNb ? true : nil,
                    // `clientId` makes the server id deterministic (`c_<clientId>`), which is what
                    // makes a retried upload return the same record instead of a duplicate.
                    id: GuestMigration.clientID(for: conversation.id)
                )
                let localID = conversation.id
                group.addTask {
                    do {
                        _ = try await client.createChat(request)
                        return localID
                    } catch {
                        // Per-chat failures are tolerated: the file stays, and the next sign-in on
                        // this device tries again.
                        return nil
                    }
                }
            }
            var done: [String] = []
            for await result in group {
                if let result { done.append(result) }
            }
            return done
        }
    }

    /// The server accepts `^[A-Za-z0-9_-]{8,120}$`; a local id is already in that alphabet but a
    /// short or foreign one is padded rather than rejected silently.
    private static func clientID(for conversationID: String) -> String? {
        let filtered = conversationID.filter { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }
        var value = String(filtered.prefix(120))
        guard !value.isEmpty else { return nil }
        while value.count < 8 { value += "0" }
        return value
    }
}
