//
//  SearchContext.swift
//  FirasAI
//
//  The web-search decision and the fenced block that carries the results into the request.
//
//  Two budgets, two meanings (web-prompt-builder.md §11, server-chat-jobs-chats.md §1.6):
//    · EXPLICIT — the toggle is on, or the message says "ابحث"/"latest news". 8 s, a visible
//      badge, and every tier but `max` is downgraded to `pro` for that turn.
//    · SILENT   — the message merely benefits from fresh facts. 1.5 s, no badge, no tier change;
//      a false positive costs milliseconds nobody sees, so the predicate is deliberately wide.
//
//  Retrieved text is injected as a `user` message, never `system`, inside a per-request nonce
//  fence — page text is DATA and must never be able to issue instructions.
//

import Foundation

enum SearchContext {

    enum Trigger: Equatable, Sendable {
        case none
        case silent
        case explicit
    }

    // MARK: - Decision

    /// Search is skipped entirely on a turn that carries images (the vision path never searches).
    static func trigger(for text: String, toggleOn: Bool, hasImages: Bool) -> Trigger {
        if hasImages { return .none }
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .none }
        if toggleOn { return .explicit }
        if needsWebSearch(s) { return .explicit }
        if benefitsFromSilentSearch(s) { return .silent }
        return .none
    }

    /// `GET /api/search?q=` accepts ≤ 300 chars; the web slices to 280 before sending.
    static func query(from text: String) -> String {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(s.prefix(280))
    }

    // MARK: - Formatting

    /// `formatSearchContext` (app.js:41141) via the catalog: head + untrusted-data rule + a
    /// nonce-fenced body of at most six rows. Empty results produce an empty string.
    static func format(_ results: [WebSearchResult], lang: AppLanguage) -> String {
        let rows = results.prefix(6).compactMap { row -> PromptCatalog.SearchResult? in
            let title = (row.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (row.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = (row.snippet ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty && url.isEmpty { return nil }
            return PromptCatalog.SearchResult(title: title, url: url, snippet: snippet)
        }
        if rows.isEmpty { return "" }
        return PromptCatalog.searchInjection(results: Array(rows), lang: lang.rawValue)
    }

    // MARK: - Running it

    /// Fetch and format in one step. Never throws and never outlives its budget: a search the
    /// user did not ask for must not be the reason a reply feels slow.
    /// `wasEmpty` is true only for an EXPLICIT search that came back with nothing — that is the
    /// case the prompt has to admit to the user ("no live web results were available").
    static func run(api: APIClient, text: String, trigger: Trigger, lang: AppLanguage) async -> (context: String?, wasEmpty: Bool) {
        guard trigger != .none else { return (nil, false) }
        let seconds: Double = (trigger == .explicit) ? 8.0 : 1.5
        let q = query(from: text)
        guard !q.isEmpty else { return (nil, false) }

        var rows: [WebSearchResult] = []
        do {
            rows = try await withDeadline(seconds: seconds) {
                try await api.webSearch(query: q, count: 6)
            }
        } catch {
            rows = []
        }

        let context = format(rows, lang: lang)
        if context.isEmpty {
            return (nil, trigger == .explicit)
        }
        return (context, false)
    }

    // MARK: - Predicates (app.js:41015-41135)

    /// `needsWebSearch` — deliberately NARROW: it drives a visible badge and a tier change.
    /// Bare temporal adverbs ("today", "اليوم") are intentionally absent; a greeting is not a
    /// research topic.
    static func needsWebSearch(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return RequestClassifier.matches(explicitEnglishPattern, text)
            || RequestClassifier.matches(explicitArabicPattern, text)
    }

    /// `benefitsFromSilentSearch` — the opposite shape: everything the web cannot help with is
    /// excluded first, and what remains is, by elimination, a request for information.
    static func benefitsFromSilentSearch(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count < 8 || s.count > 2000 { return false }

        // Short phatic openers are vetoed by shape.
        if s.count <= 60, RequestClassifier.matches(greetingLeadPattern, s) { return false }

        // Turns the web cannot help.
        if RequestClassifier.detectCodeRequest(s) { return false }
        if RequestClassifier.detectImageRequest(s) { return false }
        if RequestClassifier.detectFileRequest(s, hasAttachment: false) != nil { return false }
        if RequestClassifier.matches(RequestClassifier.irabPattern, s) { return false }

        for pattern in silentVetoPatterns where RequestClassifier.matches(pattern, s) { return false }

        // Inclusion: either signal is enough.
        let asks = RequestClassifier.matches(asksQuestionPattern, s)
            || RequestClassifier.matches(asksArabicPattern, s)
            || RequestClassifier.matches(asksEnglishPattern, s)
        let worldly = matchesCaseSensitive(worldlyProperNounPattern, s)
            || RequestClassifier.matches(worldlyYearPattern, s)
            || RequestClassifier.matches(worldlyArabicPattern, s)
            || RequestClassifier.matches(worldlyEnglishPattern, s)
        return asks || worldly
    }

    // MARK: - Patterns

    /// A capitalised proper noun only counts when the capital is real, so this one match must be
    /// case-SENSITIVE — `RequestClassifier.matches` is not.
    private static func matchesCaseSensitive(_ pattern: String, _ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }

    private static let explicitEnglishPattern =
        "\\b(google|search\\s+(?:for|the\\s+web|online)|look\\s+up|latest|newest|recent news|breaking|\\bnews\\b|stock\\s+(?:price|market)"
        + "|exchange rate|weather|forecast|who won|winner|standings?|fixtures?|release date)\\b"
    private static let explicitArabicPattern =
        "(ابحث|إبحث|ابحثلي|ابحث لي|دوّر|دور لي|جيب لي معلوم|كوكل|قوقل|جوجل|بالانترنت|بالإنترنت|على النت|بالنت|انترنت|إنترنت"
        + "|(آخر|اخر|أحدث|احدث)\\s*\\S|الأخبار|الاخبار|أخبار|اخبار|سعر|أسعار|اسعار|الطقس|درجة الحرارة|من فاز|من ربح|الفائز"
        + "|مباراة|مباريات|الدوري|بطولة|كأس|متى يقام|متى تبدأ|أين يقام)"

    private static let greetingLeadPattern =
        "^(مرحبا|مرحبًا|هلو|هلا|اهلا|أهلا|السلام عليكم|صباح الخير|مساء الخير|تحية|شلونك|شلونج|كيف حالك|كيفك|شكو ماكو|شخبارك|هاي"
        + "|hi|hello|hey|good (morning|evening|afternoon)|how are you)"

    /// Maths, work performed on the user's own text, debugging, build-a-thing, small talk.
    private static let silentVetoPatterns: [String] = [
        "^[\\s\\d+\\-*/^=().,%√π]+$",
        "(?:^|[^\u{0600}-\u{06FF}])(?:احسب|بسّط|بسط|اشتق|كامل|حلّ المعادلة|حل المعادلة|أوجد قيمة)(?![\u{0600}-\u{06FF}])",
        "\\b(?:solve|simplify|differentiate|integrate|factor(?:ise|ize)?|compute)\\b",
        "(?:^|[^\u{0600}-\u{06FF}])(?:ترجم|لخّص|لخص|أعد صياغة|اعد صياغة|صحّح|صحح|رتّب|رتب|اكتب قصة|اكتب قصيدة|اكتب رسالة|اكتب إيميل)(?![\u{0600}-\u{06FF}])",
        "\\b(?:translate|summari[sz]e|rephrase|rewrite|proofread|write (?:a|an|me) (?:story|poem|essay|email|letter))\\b",
        "\\b(?:my|our|this)\\s+(?:code|function|script|program|app|component|query|api|server|build|test|loop|class|method)\\b",
        "\\b(?:returns?|throws?|prints?|gives?)\\s+(?:undefined|null|nan|an?\\s+error|the\\s+wrong)\\b",
        "\\b(?:stack\\s*trace|compile\\s*error|syntax\\s*error|type\\s*error|null\\s*pointer|segfault|not\\s+working|doesn'?t\\s+work|won'?t\\s+(?:run|compile|build))\\b",
        "(?:^|[^\u{0600}-\u{06FF}])(?:كودي|الكود مالتي|ما يشتغل|ماكو نتيجة|يطلع خطأ|خطأ بالكود|ليش ما يشتغل)(?![\u{0600}-\u{06FF}])",
        "\\b(?:write|build|create|make|implement|refactor|generate|scaffold|code)\\b[^.?!]{0,60}\\b(?:component|function|class|script|app|website|page|api|endpoint|query|hook|module|library|test|css|html|react|vue|angular|svelte|node|python|javascript|typescript|sql|regex)\\b",
        "(?:^|[^\u{0600}-\u{06FF}])(?:اكتب|سوّي|سوي|اعمل|أنشئ|انشئ|صمّم|صمم|برمج)(?![\u{0600}-\u{06FF}])[^.؟!]{0,60}(?:كود|دالة|سكربت|تطبيق|موقع|صفحة|واجهة|مكوّن|مكون|استعلام)",
        "^(?:\\s*(?:مرحبا|أهلا|اهلا|السلام عليكم|صباح الخير|مساء الخير|شلونك|شكرا|شكرًا|تمام|اوكي|hi|hello|hey|thanks|thank you|ok|okay|good morning|good evening|how are you)[\\s!؟?.،,]*)+$",
    ]

    private static let asksQuestionPattern = "[?؟]"
    private static let asksArabicPattern =
        "(?:^|[^\u{0600}-\u{06FF}])(?:من هو|من هي|ما هو|ما هي|ما معنى|شنو|شكو|متى|أين|وين|كيف|شلون|ليش|لماذا|كم|هل|اشرح|إشرح|وضّح|وضح|فسّر|فسر"
        + "|عرّف|عرف|نبذة|تكلم عن|تحدث عن|احكيلي عن|أخبرني عن|معلومات عن|قارن|أفضل|افضل|رشّح|رشح|اذكر|عدد)(?![\u{0600}-\u{06FF}])"
    private static let asksEnglishPattern =
        "\\b(?:who|what|when|where|why|how|which|is|are|does|do|did|can|tell me about|explain|describe|define|overview|compare|recommend|suggest|list|best|top)\\b"

    private static let worldlyProperNounPattern = "[A-Z][a-z]{2,}"
    private static let worldlyYearPattern = "\\b(?:19|20)\\d{2}\\b"
    private static let worldlyArabicPattern =
        "(?:^|[^\u{0600}-\u{06FF}])(?:شركة|رئيس|سعر|أسعار|أخبار|نسخة|إصدار|بطولة|مباراة|فيلم|مسلسل|جامعة|دولة|مدينة|عملة|دولار|دينار|نظرية|تاريخ|كتاب|عالم|اختراع|ظاهرة|مرض|علاج)(?![\u{0600}-\u{06FF}])"
    private static let worldlyEnglishPattern =
        "\\b(?:price|version|release|news|company|president|championship|movie|series|university|currency|theory|history|disease|treatment|versus|vs)\\b"
}
