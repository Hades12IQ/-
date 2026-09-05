import Foundation

/// Translation between a job pointer and the notification payload, and back from a tapped
/// notification to an `AppRoute`.
///
/// The payload keys are **exactly** the ones the server's APNs payload uses
/// (`server-auth-session-account.md §6.5`) so that a future APNs path needs no client change:
///
/// ```json
/// { "firas": { "type": "job-terminal", "product": "ai", "jobId": "…",
///              "phase": "completed", "chatId": "…", "mediaKind": "image" } }
/// ```
///
/// `route(userInfo:)` additionally accepts the flat `firas_*` fallbacks the old Codex decoder
/// understood (the server never sends them, but a hand-built payload might).
enum NotificationRouter {

    // MARK: - Wire constants

    /// The nested dictionary key that carries every Firas field.
    static let payloadKey = "firas"
    /// `firas.type` for a finished background job.
    static let jobTerminalType = "job-terminal"
    /// `firas.type` for a call that ended while the app was in the background.
    static let callEndedType = "call-ended"
    /// `aps.category` for job-completion notifications (server parity).
    static let categoryIdentifier = "FIRAS_JOB_COMPLETE"
    /// Category for the call-ended notification (never sent by the server).
    static let callCategoryIdentifier = "FIRAS_CALL_ENDED"
    /// Maximum length of an APNs `thread-id`.
    static let threadIdentifierLimit = 64

    // MARK: - Building

    /// The `userInfo` for a local notification about `pointer`.
    ///
    /// - Parameters:
    ///   - pointer: the job whose terminal state is being announced.
    ///   - phase: `"completed"` or `"failed"` (the only two phases the server ever pushes).
    static func userInfo(for pointer: JobPointer, phase: String) -> [String: Any] {
        var fields: [String: Any] = [
            "type": jobTerminalType,
            "product": productWire(for: pointer.kind),
            "jobId": pointer.id,
            "phase": phase
        ]
        if let media = pointer.kind.mediaKind {
            // Media jobs never carry a chat id on the server side; they open the Studio instead.
            fields["mediaKind"] = media.rawValue
            if let creation = pointer.creationID, !creation.isEmpty {
                fields["creationId"] = creation
            }
        } else if let chatID = chatIdentifier(for: pointer) {
            fields["chatId"] = chatID
        }
        return [payloadKey: fields]
    }

    /// `aps.thread-id` — `("firas-" + product + "-" + (chatId || jobId || "job")).slice(0, 64)`.
    static func threadIdentifier(for pointer: JobPointer) -> String {
        let tail: String
        if pointer.kind.mediaKind != nil {
            tail = pointer.id.isEmpty ? "job" : pointer.id
        } else if let chatID = chatIdentifier(for: pointer) {
            tail = chatID
        } else {
            tail = pointer.id.isEmpty ? "job" : pointer.id
        }
        let raw = "firas-" + productWire(for: pointer.kind) + "-" + tail
        return String(raw.prefix(threadIdentifierLimit))
    }

    /// The server's `durableNotificationProduct` mapping, spelled out so it cannot drift:
    /// `agentrun → agent`, `codebuild → code`, `brainask → brain`, everything else (chat, longdoc,
    /// longfile and every media kind) → `ai`.
    static func productWire(for kind: JobKind) -> String {
        switch kind {
        case .agentrun:
            return "agent"
        case .codebuild:
            return "code"
        case .brainask:
            return "brain"
        case .chat, .longdoc, .longfile, .counteddoc, .image, .video, .music:
            return "ai"
        }
    }

    /// The conversation this pointer belongs to: the server chat id when the conversation is
    /// already persisted, otherwise the local (guest) conversation id, which the router can open
    /// just as well. `nil` when the job has no conversation at all.
    static func chatIdentifier(for pointer: JobPointer) -> String? {
        if let serverID = pointer.serverChatID, !serverID.isEmpty {
            return serverID
        }
        return pointer.conversationID.isEmpty ? nil : pointer.conversationID
    }

    // MARK: - Routing

    /// The destination for a tapped notification, including a cold start. `nil` when the payload
    /// is not ours, is not a job terminal, or does not identify anything openable.
    static func route(userInfo: [AnyHashable: Any]) -> AppRoute? {
        let fields = payload(from: userInfo)
        guard !fields.isEmpty else { return nil }

        let type = string(fields["type"]) ?? jobTerminalType
        guard type == jobTerminalType else { return nil }

        let jobID = string(fields["jobId"])
        let chatID = string(fields["chatId"])

        if let mediaRaw = string(fields["mediaKind"]), MediaKind(rawValue: mediaRaw) != nil {
            return .studio(creationID: string(fields["creationId"]) ?? jobID)
        }

        switch string(fields["product"]) ?? "ai" {
        case "agent":
            return .agent(conversationID: chatID)
        case "code":
            return .code(projectID: chatID)
        case "brain":
            return .brain
        default:
            guard let chatID else { return nil }
            return .chat(conversationID: chatID)
        }
    }

    // MARK: - Payload reading

    /// The nested `firas` dictionary, or the flat `firas_*` keys folded into the same shape.
    private static func payload(from userInfo: [AnyHashable: Any]) -> [String: Any] {
        if let nested = userInfo[payloadKey] as? [String: Any] {
            return nested
        }
        if let nested = userInfo[payloadKey] as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            for (key, value) in nested {
                if let name = key as? String {
                    out[camelCased(name)] = value
                }
            }
            return out
        }

        var flat: [String: Any] = [:]
        let prefix = payloadKey + "_"
        for (key, value) in userInfo {
            guard let name = key as? String, name.hasPrefix(prefix) else { continue }
            let stripped = String(name.dropFirst(prefix.count))
            guard !stripped.isEmpty else { continue }
            flat[camelCased(stripped)] = value
        }
        return flat
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String {
            return text.isEmpty ? nil : text
        }
        if let number = value as? NSNumber {
            let text = number.stringValue
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// `job_id` → `jobId`; anything without an underscore is returned untouched.
    private static func camelCased(_ key: String) -> String {
        guard key.contains("_") else { return key }
        let parts = key.split(separator: "_")
        guard let first = parts.first else { return key }
        return parts.dropFirst().reduce(String(first)) { partial, piece in
            partial + piece.prefix(1).uppercased() + String(piece.dropFirst())
        }
    }
}
