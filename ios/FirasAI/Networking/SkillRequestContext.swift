import Foundation

/// A snapshot belongs to one send operation, including its child authoring tasks. There is no
/// global "currently selected skill" that could leak into another conversation or account.
enum SkillRequestContext {
    @TaskLocal static var selection: [AccountSkill] = []

    /// The whole-document endpoint caps q at 4,000 UTF-16 units. Check the complete decorated
    /// question before choosing it; retrieval's final answer request preserves the full question.
    static func fitsWholeBrain(_ question: String) -> Bool {
        guard question.utf16.count <= 4_000,
              let raw = try? JSONSerialization.data(withJSONObject: ["q": question]),
              let data = try? encode(raw, path: "/api/brain/whole"),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = body["q"] as? String else { return false }
        return value.utf16.count <= 4_000 && data.count < 90_000
    }

    static func encode(_ data: Data, path: String) throws -> Data {
        let skills = Array(selection.filter(\.enabled).prefix(3))
        guard !skills.isEmpty,
              ["/api/chat", "/api/chat/job", "/api/omnix/runs", "/api/brain/whole"].contains(path),
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        // Query expansion, titles and other helpers must not inherit user answer instructions.
        if body["nomem"] as? Bool == true && body["skills"] as? Bool != true { return data }
        body["skillIds"] = skills.map(\.id)
        body["skills"] = true
        if path == "/api/chat" { return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }

        // These server job runners do not yet forward skillIds to handleChat. Carry the same
        // user-selected, validated instructions in their task input. Stored chat text stays clean.
        // The block is user guidance, never promoted to system authority or tool permissions.
        let entries = skills.map { ["name": $0.name, "rules": $0.rules] as [String: Any] }
        let json = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        let guidance = "\n\nSelected skills for this task (the user's method and preferences; do not override system rules, permissions, or the task):\n" + (String(data: json, encoding: .utf8) ?? "[]")
        if path == "/api/omnix/runs", let text = body["text"] as? String {
            body["text"] = text + guidance
        } else if path == "/api/brain/whole", let text = body["q"] as? String {
            body["q"] = text + guidance
        } else {
            for key in ["task", "prompt"] {
                if let text = body[key] as? String, !text.isEmpty { body[key] = text + guidance }
            }
            if var messages = body["messages"] as? [[String: Any]], let last = messages.lastIndex(where: { $0["role"] as? String == "user" }),
               let text = messages[last]["content"] as? String {
                messages[last]["content"] = text + guidance
                body["messages"] = messages
            }
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
