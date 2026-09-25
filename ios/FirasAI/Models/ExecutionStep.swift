import Foundation

/// Public, bounded activity records. These are tool observations, never private reasoning.
struct ExecutionStep: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var kind: String
    var state: String
    var text: String?
    var fact: String?
    var detail: String?
    var args: [String]?
    var at: Int?
    var say: String?

    static func decodeFrame(_ data: String, offset: Int) -> Self? {
        struct Frame: Decodable { var firas_step: ExecutionStep? }
        guard let bytes = data.data(using: .utf8),
              var step = try? JSONDecoder().decode(Frame.self, from: bytes).firas_step,
              !step.kind.isEmpty, !step.id.isEmpty else { return nil }
        step.at = max(0, step.at ?? offset)
        return step
    }

    static func merge(_ old: [Self]?, _ incoming: [Self]) -> [Self]? {
        var result = old ?? []
        for var row in incoming where !row.kind.isEmpty && !row.id.isEmpty {
            row.id = String(row.id.prefix(40)); row.kind = String(row.kind.prefix(24))
            row.text = row.text.map { String($0.prefix(300)) }
            row.detail = row.detail.map { String($0.prefix(1200)) }
            row.fact = row.fact.map { String($0.prefix(80)) }
            row.say = row.say.map { String($0.prefix(400)) }
            row.args = row.args.map { Array($0.prefix(6)).map { String($0.prefix(80)) } }
            if let index = result.firstIndex(where: { $0.id == row.id }) {
                row.at = min(result[index].at ?? row.at ?? 0, row.at ?? result[index].at ?? 0)
                row.say = result[index].say ?? row.say
                result[index] = row
            } else if result.count < 40 { result.append(row) }
        }
        return result.isEmpty ? nil : result
    }

    var symbol: String {
        switch kind {
        case "search": return "magnifyingglass"
        case "page": return "globe"
        case "readFile", "scanPaper": return "doc.text.magnifyingglass"
        case "code", "run": return "terminal"
        case "skill": return "sparkles"
        case "verify", "solve": return "checkmark.seal"
        case "plan": return "list.bullet"
        case "image", "imageGen": return "photo"
        case "share": return "arrow.up.right.square"
        default: return "circle.grid.2x2"
        }
    }

    func title(_ lang: AppLanguage) -> String {
        if let text, !text.isEmpty { return text }
        let ar = lang == .arabic
        let base: String
        switch kind {
        case "search": base = ar ? "البحث" : "Search"
        case "page": base = ar ? "قراءة صفحة" : "Read page"
        case "readFile", "scanPaper": base = ar ? "قراءة الملف" : "Read file"
        case "code": base = ar ? "كتابة الكود" : "Write code"
        case "run": base = ar ? "تشغيل" : "Run"
        case "skill": base = ar ? "استخدام مهارة" : "Use skill"
        case "verify": base = ar ? "التحقق" : "Verify"
        case "solve": base = ar ? "حل المسألة" : "Solve"
        case "plan": base = ar ? "التخطيط" : "Plan"
        case "image", "imageGen": base = ar ? "معالجة الصورة" : "Image"
        case "share": base = ar ? "تسليم النتيجة" : "Deliver"
        default: base = kind
        }
        let targets = (args ?? []).joined(separator: "، ")
        return targets.isEmpty ? base : base + " · " + targets
    }
}
