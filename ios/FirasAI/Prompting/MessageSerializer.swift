//
//  MessageSerializer.swift
//  FirasAI
//
//  Three shapes of one message, and the rule for putting a local copy back together with the
//  server's.
//
//  · WIRE      `OutgoingMessage {role, content, images?}` — the server reads nothing else
//              (server-chat-jobs-chats.md §1.2), and `images` are RAW base64 with no `data:` prefix.
//  · PERSISTED `PersistedMessage` — exactly the `sanitizeMessages` whitelist (§5.2). `images`,
//              `fileText`, `intent` and `status` are client-only and never leave the device.
//  · MERGE     PUT replaces the whole array, and the job worker upserts the assistant turn by
//              `cid` (§3.6). A blind PUT of a snapshot taken at job start clobbers a rename, an
//              auto-title, or a turn added on another device (audit-ios-chat.md §Major M2), so a
//              finishing job re-reads the chat and merges by `cid` before writing.
//

import Foundation

enum MessageSerializer {

    // MARK: - Wire

    /// The request shape. `reattachImages` is the silent re-attachment of the chat's last photos
    /// on a follow-up that `RequestClassifier.refersToPreviousImage` recognises; it applies only
    /// when the message carries none of its own.
    static func outgoing(_ m: ChatMessage, reattachImages: [String]?) -> OutgoingMessage {
        let role = wireRole(m.role)
        var content = m.content
        if m.role == .user, let fileText = m.fileText, !fileText.isEmpty {
            content = PromptCatalog.userTurnContent(userText: m.content, fileText: fileText)
        }
        var images: [String]? = nil
        if m.role == .user {
            let own = m.images ?? []
            let source = own.isEmpty ? (reattachImages ?? []) : own
            let cleaned = source.compactMap { rawBase64($0) }
            if !cleaned.isEmpty { images = cleaned }
        }
        return OutgoingMessage(role: role, content: content, images: images)
    }

    // MARK: - Persisted

    static func persisted(_ m: ChatMessage) -> PersistedMessage {
        return PersistedMessage(
            role: wireRole(m.role),
            content: m.content,
            tier: m.tier,
            lang: m.lang,
            reasoning: emptyToNil(m.reasoning),
            cid: emptyToNil(m.cid),
            files: (m.files?.isEmpty ?? true) ? nil : m.files,
            imageThumbs: (m.imageThumbs?.isEmpty ?? true) ? nil : m.imageThumbs,
            mode: m.mode,
            askAnswered: (m.askAnswered == true) ? true : nil,
            retryOf: m.retryOf,
            retried: (m.retried == true) ? true : nil,
            mergedFrom: emptyToNil(m.mergedFrom),
            alts: (m.alts?.count ?? 0) >= 2 ? m.alts : nil,
            altAt: (m.alts?.count ?? 0) >= 2 ? m.altAt : nil
        )
    }

    /// Every row of a conversation, in order. Rows that never belonged on the server (an empty
    /// placeholder answer, a local system note) are dropped rather than written.
    static func persisted(_ c: ChatConversation) -> [PersistedMessage] {
        var out: [PersistedMessage] = []
        out.reserveCapacity(c.messages.count)
        for m in c.messages {
            if m.role == .system { continue }
            if m.role == .assistant && m.content.isEmpty && (m.reasoning?.isEmpty ?? true) { continue }
            out.append(persisted(m))
        }
        return out
    }

    // MARK: - Merge

    /// Reconcile the local copy with the server's. Rules:
    ///   1. rows are keyed by ROLE **and** `cid` — the two halves of one turn share a cid, so the
    ///      cid alone is not an identity (see `turnKey`); the server copy wins when its content is
    ///      longer (the worker wrote the whole answer while this device only saw part of the stream);
    ///   2. client-only fields (`images`, `fileText`, `intent`, `status`) and the plan-cycle
    ///      fields the durable save drops (`mode`, `askAnswered`) survive from the local row;
    ///   3. a local row the server has never seen is kept, in place — a local user turn is never
    ///      dropped;
    ///   4. a server row this device has never seen is appended in server order.
    static func merge(local: [ChatMessage], server: [ChatMessage]) -> [ChatMessage] {
        var serverByTurn: [String: ChatMessage] = [:]
        for m in server {
            if let key = turnKey(m) { serverByTurn[key] = m }
        }
        var localKeys = Set<String>()
        for m in local { localKeys.insert(contentKey(m)) }

        var consumed = Set<String>()
        var out: [ChatMessage] = []
        out.reserveCapacity(max(local.count, server.count))

        for m in local {
            if let key = turnKey(m), let s = serverByTurn[key] {
                consumed.insert(key)
                out.append(reconcile(local: m, server: s))
            } else {
                out.append(m)
            }
        }

        for m in server {
            /* AN EMPTY ANSWER IS NOT AN ANSWER. The worker files a row for a turn before it has
               written into it, and a turn that failed, was stopped, or exceeded the server's
               content cap stays that way. Appending one gives the reader a turn with a name, a
               badge and an action row wrapped around nothing at all - which is the lone mark and
               empty row the owner photographed. A row with no content and no reasoning carries
               no information by definition, so there is nothing to lose by refusing it, and the
               local copy of that turn (if there is one) has already been reconciled above. */
            if m.role == .assistant,
               m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (m.reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            if let key = turnKey(m) {
                if consumed.contains(key) { continue }
                consumed.insert(key)
                out.append(m)
            } else {
                // A row written before cids existed: match it by shape so it is not duplicated.
                if localKeys.contains(contentKey(m)) { continue }
                localKeys.insert(contentKey(m))
                out.append(m)
            }
        }
        return out
    }

    // MARK: - Private

    private static func reconcile(local: ChatMessage, server: ChatMessage) -> ChatMessage {
        var merged = local
        if server.content.count > local.content.count { merged.content = server.content }
        if (server.reasoning?.count ?? 0) > (merged.reasoning?.count ?? 0) { merged.reasoning = server.reasoning }
        if merged.tier == nil { merged.tier = server.tier }
        if merged.lang == nil { merged.lang = server.lang }
        if merged.mode == nil { merged.mode = server.mode }
        if merged.askAnswered == nil { merged.askAnswered = server.askAnswered }
        if merged.retryOf == nil { merged.retryOf = server.retryOf }
        if merged.retried == nil { merged.retried = server.retried }
        if merged.mergedFrom == nil { merged.mergedFrom = server.mergedFrom }
        if merged.files == nil { merged.files = server.files }
        if merged.imageThumbs == nil { merged.imageThumbs = server.imageThumbs }
        if (merged.alts?.count ?? 0) < (server.alts?.count ?? 0) {
            merged.alts = server.alts
            merged.altAt = server.altAt
        }
        // The server holding the row means it landed, whatever this device still thinks.
        if !server.content.isEmpty {
            switch merged.status {
            case .sending, .streaming, .queuedOffline:
                merged.status = .delivered
            default:
                break
            }
        }
        return merged
    }

    private static func wireRole(_ role: ChatRole) -> String {
        switch role {
        case .system: return "system"
        case .assistant: return "assistant"
        case .user: return "user"
        case .unknown: return "user"
        }
    }

    /// Server-side `normalizeImage` strips a `data:<mime>;base64,` prefix; the client sends the
    /// raw payload so nothing has to be re-encoded on the way in.
    private static func rawBase64(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("data:") else { return trimmed }
        guard let comma = trimmed.firstIndex(of: ",") else { return nil }
        let payload = String(trimmed[trimmed.index(after: comma)...])
        return payload.isEmpty ? nil : payload
    }

    private static func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Identity for a row that HAS a `cid` — the role and the cid together, never the cid alone.
    ///
    /// A turn's question and its answer share one `cid` (`ChatMessage.user(_:cid:lang:)` and
    /// `ChatMessage.assistant(cid:…)` are minted with the same value, and `cid` is on the server's
    /// persist whitelist). Keying a merge by the cid alone therefore made the assistant row win the
    /// lookup for BOTH local rows, and `reconcile` keeps the longer text — so the finished answer
    /// was written into the user's own bubble and appeared twice: once as the question, once as the
    /// answer below it. `ChatMessage.identity(role:cid:)` qualifies ids by role for the same reason.
    private static func turnKey(_ m: ChatMessage) -> String? {
        guard let cid = m.cid, !cid.isEmpty else { return nil }
        return wireRole(m.role) + "\u{1F}" + cid
    }

    /// Identity for a row that carries no `cid`.
    private static func contentKey(_ m: ChatMessage) -> String {
        return wireRole(m.role) + "\u{1F}" + String(m.content.prefix(400)) + "\u{1F}" + String(m.content.count)
    }
}
