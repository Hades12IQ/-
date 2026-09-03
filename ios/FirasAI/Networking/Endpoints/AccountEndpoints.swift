import Foundation

// Announcements, the memory list and the build stamp.
// Wire shapes: server-misc.md §9 and server-auth-session-account.md §5.4–5.6 (verified against
// server.mjs 6538-6546, 7462-7527, 7690-7698).

// MARK: - Request bodies

private struct AccountMemoryLearnBody: Encodable, Sendable {
    let user: String
}

// MARK: - Response envelopes

private struct AccountAnnouncementsEnvelope: Decodable, Sendable {
    let announcements: [Announcement]?
    let admin: Bool?
}

private struct AccountVersionEnvelope: Decodable, Sendable {
    let version: String

    private enum CodingKeys: String, CodingKey {
        case version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .version) {
            version = text
        } else if let number = try? container.decode(Double.self, forKey: .version),
                  number.isFinite,
                  abs(number) < 9_000_000_000_000_000 {
            version = String(Int(number))
        } else {
            version = ""
        }
    }
}

// MARK: - Memory decoding

// `GET /api/memory` answers `{ "memory": ["Name: Ali", "From Iraq", …] }` — bare strings in order,
// with no ids of their own. The **position** is the handle `DELETE /api/memory?i=` expects, so each
// row is first rebuilt as `{"id": "<index>", "text": …}`; that keeps `MemoryEntry.id` usable as the
// delete key. Only if that shape will not decode are the rows handed to the model as they came.
private enum MemoryJSON {

    static func entries(from data: Data) -> [MemoryEntry] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let root = parsed as? [String: Any],
              let rows = root["memory"] as? [Any]
        else { return [] }

        let decoder = JSONDecoder()
        var objects: [[String: Any]] = []
        for (index, row) in rows.enumerated() {
            if let text = row as? String {
                objects.append(["id": String(index), "text": text])
            } else if var object = row as? [String: Any] {
                if object["id"] == nil { object["id"] = String(index) }
                if object["text"] == nil { object["text"] = "" }
                objects.append(object)
            }
        }
        if let objectData = try? JSONSerialization.data(withJSONObject: objects),
           let rebuilt = try? decoder.decode([MemoryEntry].self, from: objectData) {
            return rebuilt
        }

        guard let rowData = try? JSONSerialization.data(withJSONObject: rows),
              let direct = try? decoder.decode([MemoryEntry].self, from: rowData)
        else { return [] }
        return direct
    }
}

// MARK: - Endpoints

extension APIClient {

    /// `GET /api/announcements` — member or guest; at most 50 records, pinned first then newest.
    /// Every record is bilingual by storage (`titleEn`/`bodyEn` may be empty). The built-in launch
    /// post ships with the app and is merged locally — it is never posted to the server.
    func announcements() async throws -> [Announcement] {
        let envelope = try await json(
            .get,
            "/api/announcements",
            budget: .interactive,
            as: AccountAnnouncementsEnvelope.self
        )
        return envelope.announcements ?? []
    }

    /// `GET /api/memory` — member only; at most 60 facts of ≤ 140 characters each.
    func memory() async throws -> [MemoryEntry] {
        let (data, _) = try await raw(
            .get,
            "/api/memory",
            budget: .interactive
        )
        return MemoryJSON.entries(from: data)
    }

    /// `DELETE /api/memory` clears the list; `?i=<index>` removes one entry. An out-of-range index
    /// is a silent no-op, and the reply carries the remaining list.
    func deleteMemory(id: String?) async throws {
        var query: [String: String] = [:]
        if let id, !id.isEmpty { query["i"] = id }
        _ = try await raw(
            .delete,
            "/api/memory",
            query: query,
            budget: .interactive
        )
    }

    /// `POST /api/memory/learn` — runs three LLM extractions server-side and takes several
    /// seconds, so callers fire and forget it after a turn and never block the UI on it.
    func memoryLearn(text: String) async throws {
        let body = AccountMemoryLearnBody(user: text)
        _ = try await raw(
            .post,
            "/api/memory/learn",
            body: body,
            budget: .upload
        )
    }

    /// `GET /api/version` — the newest mtime of the web assets, as a string. No auth.
    func version() async throws -> String {
        let envelope = try await json(
            .get,
            "/api/version",
            budget: .interactive,
            as: AccountVersionEnvelope.self
        )
        return envelope.version
    }
}
