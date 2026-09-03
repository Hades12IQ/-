import Foundation
import SwiftUI

/// Exporting and importing the chat backup file.
///
/// Split from `DataSettingsView.swift` for length. The export walks the conversation list through
/// `ChatStore` and tolerates a chat it cannot load; the import creates conversations one at a time
/// and counts what landed, because the server refuses a single oversized chat and caps how many a
/// user may hold (`audit-ios-shell-settings-design.md F21`).
extension DataSettingsView {

    func prepareExport() {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        notice = nil
        Task {
            let entries = await collectBackupEntries()
            isPreparingExport = false
            guard !entries.isEmpty else {
                notice = Notice(text: Strings.Settings.Storage.nothingToExport(lang), kind: .info)
                return
            }
            exportDocument = FirasChatBackupDocument(
                backup: FirasChatBackup(
                    chats: entries,
                    exportedAt: ChatBackupFileReader.timestamp(for: Date())
                )
            )
            showsExporter = true
        }
    }

    /// Walks the conversation list, loading any body that is not in memory yet. A chat the server
    /// refuses is skipped, not fatal: a backup of nine chats out of ten beats no backup at all.
    func collectBackupEntries() async -> [FirasChatBackupEntry] {
        if env.chat.summaries.isEmpty {
            await env.chat.loadConversations()
        }
        var entries: [FirasChatBackupEntry] = []
        for summary in env.chat.summaries.prefix(FirasChatBackup.maximumChats) {
            if env.chat.conversations[summary.id] == nil {
                await env.chat.open(summary.id)
            }
            guard let conversation = env.chat.conversations[summary.id] else { continue }
            let messages = MessageSerializer.persisted(conversation)
            guard !messages.isEmpty else { continue }
            entries.append(
                FirasChatBackupEntry(summary: summary, messages: messages).sanitizedForImport
            )
        }
        return entries
    }

    // MARK: - Import

    func handlePickedFile(_ result: Result<[URL], Error>) {
        notice = nil
        switch result {
        case .failure:
            notice = Notice(text: Strings.Errors.generic(lang), kind: .error)
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    pendingImport = try await ChatBackupFileReader.read(from: url)
                    confirmsImport = true
                } catch ChatBackupValidationError.fileTooLarge {
                    notice = Notice(text: Strings.Settings.Storage.backupTooLarge(lang), kind: .error)
                } catch {
                    notice = Notice(text: Strings.Settings.Storage.invalidBackup(lang), kind: .error)
                }
            }
        }
    }

    func runImport() {
        guard let backup = pendingImport, !isImporting else { return }
        pendingImport = nil
        isImporting = true
        notice = nil
        Task {
            let landed = await performImport(backup)
            isImporting = false
            await env.chat.loadConversations()
            if landed == 0 {
                notice = Notice(text: Strings.Settings.Storage.importFailed(lang), kind: .error)
            } else if landed == backup.chats.count {
                notice = Notice(text: Strings.Settings.Storage.imported(lang), kind: .success)
                Haptics.undo()
            } else {
                notice = Notice(
                    text: Strings.Settings.Storage.importedPartial.fmt(
                        lang,
                        ArabicText.count(landed, lang),
                        ArabicText.count(backup.chats.count, lang)
                    ),
                    kind: .info
                )
            }
        }
    }

    /// Members get one `POST /api/chats` per conversation — the same call the web makes — and a
    /// per-chat failure is counted, never thrown: the server refuses a single oversized chat and
    /// caps the number of chats per user (`audit F21`).
    ///
    /// Guests have no server storage at all, so their import is built through `ChatStore`, which
    /// files it in the on-device guest library.
    func performImport(_ backup: FirasChatBackup) async -> Int {
        var landed = 0
        for entry in backup.chats.prefix(FirasChatBackup.maximumChats) {
            if env.session.isMember {
                let request = CreateChatRequest(
                    title: entry.title,
                    messages: entry.messages,
                    agent: entry.agent,
                    codeProj: entry.codeProj,
                    brainNb: entry.brainNb
                )
                if (try? await env.api.createChat(request)) != nil {
                    landed += 1
                }
            } else if await importLocally(entry) {
                landed += 1
            }
        }
        return landed
    }

    func importLocally(_ entry: FirasChatBackupEntry) async -> Bool {
        let flags = (
            agent: entry.agent == true,
            codeProj: entry.codeProj == true,
            brainNb: entry.brainNb == true
        )
        let id = env.chat.newConversation(product: Self.product(for: entry), flags: flags)
        for persisted in entry.messages {
            let message = Self.message(from: persisted)
            if message.role == .assistant {
                await env.chat.appendAssistantTurn(message, in: id)
            } else {
                await env.chat.appendUserTurn(message, in: id)
            }
        }
        await env.chat.rename(id, title: entry.title)
        return true
    }

    static func product(for entry: FirasChatBackupEntry) -> ProductKind {
        if entry.agent == true { return .agent }
        if entry.codeProj == true { return .code }
        if entry.brainNb == true { return .brain }
        return .ai
    }

    static func message(from persisted: PersistedMessage) -> ChatMessage {
        ChatMessage(
            role: ChatRole(rawValue: persisted.role) ?? .user,
            content: persisted.content,
            tier: persisted.tier,
            lang: persisted.lang,
            reasoning: persisted.reasoning,
            cid: persisted.cid,
            files: persisted.files,
            imageThumbs: persisted.imageThumbs,
            mode: persisted.mode,
            askAnswered: persisted.askAnswered,
            retryOf: persisted.retryOf,
            retried: persisted.retried,
            mergedFrom: persisted.mergedFrom,
            alts: persisted.alts,
            altAt: persisted.altAt
        )
    }
}
