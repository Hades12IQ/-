#if DEBUG
import Foundation
import SwiftUI
import UIKit
import Perception

@MainActor
enum SkillsReliabilityChecks {
    static let samples: [AccountSkill] = [
        AccountSkill(id: "usk-1111111111111111", name: "تقاريري الدراسية", cues: ["تقرير دراسي", "بحث جامعي", "تنسـيق ملف"], rules: [
            "ابدأ بتحديد موضوع التقرير والجمهور الذي سيقرأه قبل ترتيب الأقسام.",
            "استخدم عناوين واضحة وفقرات قصيرة مع الحفاظ على التفاصيل المطلوبة.",
            "ضع شرحاً مختصراً تحت كل جدول أو صورة حتى يفهم القارئ محتواها.",
            "راجع تناسق العناوين والأرقام والمراجع قبل تسليم النسخة النهائية."
        ]),
        AccountSkill(id: "usk-2222222222222222", name: "مراجعة الرياضيات", cues: ["مسائل رياضيات", "تكامل", "حل المعادلات"], rules: [
            "تحقق من تعريف الرموز والمجال الذي تعمل فيه المسألة قبل البدء بالحل.",
            "رتب خطوات الحل بحيث تظهر الفكرة الرياضية وراء كل انتقال بوضوح.",
            "اكتب المعادلات باستخدام لاتكس كامل مع ضبط الأقواس وحدود التكامل.",
            "اختبر النتيجة النهائية بطريقة مستقلة عندما تكون المقارنة ممكنة."
        ]),
        AccountSkill(id: "usk-3333333333333333", name: "Code review", cues: ["code review", "debugging", "quality"], rules: [
            "Check the intended behavior against the changed implementation before recommending edits.",
            "Explain concrete bugs with a reproducible example and the impact on the user.",
            "Preserve existing behavior unless the user has specifically asked to change it.",
            "Run relevant checks and report precisely what could and could not be verified."
        ])
    ]

    static func environment() -> AppEnvironment {
        let host = UUID().uuidString.lowercased() + ".skills-fixture.invalid"
        SkillsFixtureProtocol.seed(host, skills: samples)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.protocolClasses = [SkillsFixtureProtocol.self]
        let config = AppConfiguration(apiBaseURL: URL(string: "https://" + host)!)
        let api = APIClient(configuration: config, testingSession: URLSession(configuration: configuration))
        let defaults = UserDefaults(suiteName: host)!
        let env = AppEnvironment(config: config, defaults: defaults, apiOverride: api)
        env.prefs.language = .arabic; env.prefs.theme = .dark; env.prefs.motionPreference = .reduced
        env.session.applyMember(User(id: "skills-fixture-owner", sub: SubInfo(plan: .free)))
        return env
    }

    static func run() async -> [String] {
        var failures: [String] = []
        func check(_ valid: Bool, _ message: String) { if !valid { failures.append("Skills: " + message) } }
        for sample in samples { check(SkillValidation.problems(sample).isEmpty, "valid skill rejected") }
        check(SendPipeline.omnixPollInterval(readerIsPresent: true) == 1 && SendPipeline.omnixPollInterval(readerIsPresent: false) == 10, "Omnix visible/background cadence changed")
        let pastedSource = String(repeating: "معادلة 😀 \\int_0^1 x dx\n", count: 300)
        let pasted = PastedTextItem(text: pastedSource, number: 1)
        check(PastedTextItem.shouldCollapse(pastedSource) && !PastedTextItem.shouldCollapse("short text"), "long paste threshold")
        check(pasted.attachment.text == pastedSource && pasted.attachment.originalData == Data(pastedSource.utf8) && !pasted.attachment.truncated, "pasted document lost original content")
        let draft = SkillDraft()
        var text = "اشرح 😀 /"
        draft.synchronize(text); draft.selection = NSRange(location: text.utf16.count, length: 0)
        if let token = draft.token(text), let added = draft.insert(samples[0], token: token, into: text) { text = added }
        else { failures.append("Skills: Arabic/emoji slash failed") }
        text += "/"; draft.synchronize(text); draft.selection = NSRange(location: text.utf16.count, length: 0)
        if let token = draft.token(text), let added = draft.insert(samples[1], token: token, into: text) { text = added }
        check(draft.mentions.map(\.id) == Array(samples.prefix(2)).map(\.id), "multiple selections lost IDs")
        check(draft.mentions.allSatisfy { (text as NSString).substring(with: $0.range).hasPrefix("/") }, "green ranges do not match visible names")
        let before = draft.mentions
        draft.synchronize("Now " + text)
        check(draft.mentions.count == 2 && draft.mentions[0].range.location == before[0].range.location + 4, "edit before skill did not shift ranges")
        if let first = draft.mentions.first {
            let modified = (draft.previous as NSString).replacingCharacters(in: NSRange(location: first.range.location + 1, length: 1), with: "X")
            draft.synchronize(modified)
        }
        check(draft.mentions.count == 1 && draft.mentions[0].id == samples[1].id, "editing one name kept stale skill or erased sibling")
        draft.synchronize("")
        check(draft.mentions.isEmpty, "clearing composer retained skills")
        var multiple = ""
        for skill in samples {
            multiple += "/"; draft.synchronize(multiple); draft.selection = NSRange(location: multiple.utf16.count, length: 0)
            if let token = draft.token(multiple), let value = draft.insert(skill, token: token, into: multiple) { multiple = value }
        }
        check(draft.mentions.count == 3, "third skill was not selectable")
        multiple += "/"; draft.synchronize(multiple); draft.selection = NSRange(location: multiple.utf16.count, length: 0)
        if let token = draft.token(multiple) { check(draft.insert(samples[0], token: token, into: multiple) == nil, "selection exceeded three or duplicated a skill") }
        draft.retainValid(skills: [samples[0]], text: multiple)
        check(draft.mentions.count == 1, "deleted/disabled skills stayed active")
        for invalid in ["https://example.com/x", "a/b", "`/math", "```swift\n/math", "~~~\n/math", "hello /a/b"] {
            check(SkillSlashToken.scan(invalid, selection: NSRange(location: invalid.utf16.count, length: 0)) == nil, "slash inside URL/path/code")
        }
        for valid in ["/", "مرحبا /ريا", "```swift\nx\n```\n/", "first line\n/explain"] {
            check(SkillSlashToken.scan(valid, selection: NSRange(location: valid.utf16.count, length: 0)) != nil, "valid slash token missing")
        }
        let middle = "before /review after"
        check(SkillSlashToken.scan(middle, selection: NSRange(location: 14, length: 0))?.query == "review", "middle-caret slash range")
        check(SkillSlashToken.scan("/math", selection: NSRange(location: 0, length: 2)) == nil, "selection mistaken for caret")
        for (query, name) in [("تقارير", "تَقَارِير"), ("احمد", "أحمد"), ("مراجعه", "مراجعة"), ("كتاب", "کتاب"), ("firas", "Firas")] {
            check(SkillSearch.fold(query) == SkillSearch.fold(name), "Arabic/Latin search fold")
        }
        do {
            let env = environment()
            await env.skills.load(force: true)
            check(env.skills.skills.count == 3 && env.skills.failure == nil, "account skills GET contract")
            let library = try await env.skills.library()
            check(library.sections?.count == 1 && library.total == 3, "library sections contract")
            let search = try await env.skills.library(query: "رياضيات")
            check(search.library?.count == 1, "library search contract")
            var created = samples[0]; created.id = ""; created.name = "A new skill"
            let saved = try await env.skills.save(created)
            check(!saved.id.isEmpty && env.skills.skills.count == 4, "create / server-assigned ID")
            var edited = saved; edited.name = "Edited skill"
            _ = try await env.skills.save(edited)
            check(env.skills.skills.first(where: { $0.id == saved.id })?.name == "Edited skill", "edit in place")
            await env.skills.toggle(edited)
            check(env.skills.selected([saved.id]).isEmpty, "disabled skill selectable")
            await env.skills.delete(edited)
            check(env.skills.skills.count == 3, "delete contract")

            let payload: [String: Any] = ["messages": [["role": "user", "content": "Explain it"]], "task": "Explain it", "text": "Explain it"]
            let bytes = try JSONSerialization.data(withJSONObject: payload)
            for product in ["ai", "code", "agent", "brain"] {
                let req = ChatStreamRequest(messages: [OutgoingMessage(role: "user", content: "Explain it")], tier: "pro", think: false, cid: "fixture-" + product, product: product)
                await SkillRequestContext.$selection.withValue(Array(samples.prefix(2))) {
                    do { _ = try await env.api.raw(.post, "/api/chat", body: req) }
                    catch { failures.append("Skills: \(product) scoped API request failed") }
                }
            }
            let calls = SkillsFixtureProtocol.calls(env.config.apiBaseURL.host!)
            let sends = calls.filter { $0.path == "/api/chat" }
            check(sends.count == 4 && sends.allSatisfy { ($0.body["skillIds"] as? [String]) == Array(samples.prefix(2)).map(\.id) }, "four products omitted scoped IDs")
            for path in ["/api/chat/job", "/api/omnix/runs"] {
                let augmented = try SkillRequestContext.$selection.withValue(samples) { try SkillRequestContext.encode(bytes, path: path) }
                let json = try JSONSerialization.jsonObject(with: augmented) as! [String: Any]
                let field = path == "/api/omnix/runs" ? "text" : "task"
                check((json[field] as? String)?.contains("Selected skills") == true, "durable/Omnix runner lost selected guidance")
            }
            let helper = try JSONSerialization.data(withJSONObject: ["messages": [], "nomem": true])
            let unchanged = try SkillRequestContext.$selection.withValue(samples) { try SkillRequestContext.encode(helper, path: "/api/chat") }
            check(unchanged == helper, "internal helper inherited skills")
            check(try SkillRequestContext.encode(bytes, path: "/api/chat") == bytes, "task-local scope leaked into next turn")
            env.session.applyMember(User(id: "different-fixture-owner", sub: SubInfo(plan: .free)))
            env.skills.identityDidChange()
            check(env.skills.skills.isEmpty && env.skills.selected(samples.map(\.id)).isEmpty, "account change retained other owner's skills")
        } catch { failures.append("Skills: API fixture failed: " + String(describing: type(of: error))) }
        failures += await nativeTextChecks()
        return failures
    }

    private static func nativeTextChecks() async -> [String] {
        let env = environment()
        await env.skills.load()
        let model = SkillsComposerGalleryModel()
        let host = UIHostingController(rootView: SkillsComposerGalleryView(env: env, model: model))
        guard let parent = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: \.isKeyWindow)?.rootViewController else {
            return ["Skills: native composer fixture has no foreground host"]
        }
        // SwiftUI's lazy Perception body is evaluated only once the controller is mounted.
        parent.addChild(host)
        host.view.frame = CGRect(x: parent.view.bounds.maxX + 100, y: 0, width: 390, height: 850)
        parent.view.addSubview(host.view)
        host.didMove(toParent: parent)
        defer {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await JobClock.rest(0.3)
        func textViews(_ view: UIView) -> [UITextView] { (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
        guard let field = textViews(host.view).first else { return ["Skills: native composer text view missing"] }
        var failures: [String] = []
        if field.text != model.text { failures.append("Skills: native editor lost visible skill names") }
        field.selectedRange = NSRange(location: 1, length: 0)
        field.delegate?.textViewDidChangeSelection?(field)
        await JobClock.rest(0.15)
        for mention in model.draft.mentions {
            let color = field.attributedText.attribute(.foregroundColor, at: mention.range.location, effectiveRange: nil) as? UIColor
            if color != UIColor(env.prefs.palette.accent) { failures.append("Skills: selected name is not green text") }
            if field.attributedText.attribute(.attachment, at: mention.range.location, effectiveRange: nil) != nil {
                failures.append("Skills: name became an attachment instead of editable text")
            }
        }
        return failures
    }
}

final class SkillsFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Call { let path: String; let method: String; let body: [String: Any] }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var rows: [String: [AccountSkill]] = [:]
        var calls: [String: [Call]] = [:]
    }
    private static let state = State()
    static func seed(_ host: String, skills: [AccountSkill]) {
        state.lock.lock(); defer { state.lock.unlock() }; state.rows[host] = skills; state.calls[host] = []
    }
    static func calls(_ host: String) -> [Call] { state.lock.lock(); defer { state.lock.unlock() }; return state.calls[host] ?? [] }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".skills-fixture.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while bytes.count < 100_000 { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
        }
        let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String { parameters.first { $0.name == name }?.value ?? "" }
        func object(_ skill: AccountSkill) -> [String: Any] { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(skill))) as? [String: Any] ?? [:] }
        Self.state.lock.lock()
        var rows = Self.state.rows[host] ?? []
        Self.state.calls[host, default: []].append(Call(path: url.path, method: request.httpMethod ?? "", body: body))
        var result: [String: Any] = ["ok": true]
        if url.path == "/api/skills" {
            if request.httpMethod == "POST", var skill = try? JSONDecoder().decode(AccountSkill.self, from: JSONSerialization.data(withJSONObject: body.merging(["id": body["id"] ?? ""]) { first, _ in first })) {
                if skill.id.isEmpty { skill.id = "usk-4444444444444444" }
                rows.removeAll { $0.id == skill.id }; rows.append(skill); result["skill"] = object(skill)
            } else if request.httpMethod == "PATCH", let id = body["id"] as? String, let index = rows.firstIndex(where: { $0.id == id }) {
                rows[index].enabled = body["enabled"] as? Bool ?? true; result["skill"] = object(rows[index])
            } else if request.httpMethod == "DELETE" { rows.removeAll { $0.id == query("id") } }
            else if query("scope") == "library" {
                result = ["total": 3, "origin": "Mentronx"]
                if query("q").isEmpty && query("domain").isEmpty { result["sections"] = [["id": "learning", "title": "Learning & research", "count": 3]] }
                else {
                    let filtered = query("q").isEmpty ? rows : rows.filter { SkillSearch.fold($0.name).contains(SkillSearch.fold(query("q"))) }
                    result["library"] = filtered.map { skill -> [String: Any] in
                        var entry = object(skill); entry["domain"] = "learning"; entry["section"] = "Learning & research"; entry["origin"] = "Mentronx"; return entry
                    }
                }
            } else { result["skills"] = rows.map(object) }
        }
        Self.state.rows[host] = rows
        Self.state.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class SkillsComposerGalleryModel: ObservableObject {
    @Published var text = ""
    let draft = SkillDraft()
    init() {
        for skill in SkillsReliabilityChecks.samples.prefix(2) {
            text += "/"; draft.synchronize(text); draft.selection = NSRange(location: text.utf16.count, length: 0)
            if let token = draft.token(text), let value = draft.insert(skill, token: token, into: text) { text = value }
        }
        text += "اصنع لي ملفاً مرتباً /"; draft.synchronize(text); draft.selection = NSRange(location: text.utf16.count, length: 0)
        draft.pastes = [PastedTextItem(text: String(repeating: "ملاحظات الدراسة\nقواعد التكامل والتحقق من الحلول\n", count: 50), number: 1)]
    }
}
@MainActor struct SkillsComposerGalleryView: View {
    let env: AppEnvironment
    @ObservedObject var model: SkillsComposerGalleryModel
    @FocusState private var focused: Bool
    var body: some View {
        WithPerceptionTracking {
        VStack(spacing: 20) {
            Text("فراس · المهارات").font(.title2.weight(.semibold)).foregroundStyle(env.prefs.palette.textPrimary)
            Spacer()
            SkillComposerField(env: env, text: $model.text, draft: model.draft,
                placeholder: "اسأل فراس…", focused: $focused, pasteCharacterBudget: 300_000)
                .padding(16).firasGlass(.floating, palette: env.prefs.palette, in: FirasAnyShape(RoundedRectangle(cornerRadius: 24)))
            Spacer().frame(height: 24)
        }.padding(16).background(env.prefs.palette.background)
        }
    }
}
#endif
