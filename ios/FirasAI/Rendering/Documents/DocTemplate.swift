import Foundation

/// The five looks a document can wear — the website's own, not an imitation of them.
///
/// The owner's instruction was explicit: «بدل ما تربطه بالموقع، جيب قوالب الموقع نفسها و حطها
/// بالتصدير الي بالهاتف». So the *resolver* below is a port of `docTemplateFor(task)`
/// (`app.js:30588`), regex for regex, because those patterns are tuned to Arabic and to Iraqi
/// dialect and were written against real student requests — «ورقة أسئلة», «بنك اسئلة», «دراسة
/// جدوى» — and paraphrasing them would quietly stop matching the things they were built for.
///
/// The stylesheets live beside this file in `Resources/DocTemplates/` and are read from the bundle
/// the same tolerant way `MathIslandAssets.bundled(_:)` reads KaTeX: the target uses a synchronized
/// group, so a folder's files land flat in the bundle root as well as under the folder name, and
/// neither placement is worth a build-setting argument.
enum DocTemplate: String, Sendable, CaseIterable {

    /// An official exam or worksheet — the وزاري look. No contents page: a paper of questions does
    /// not open with a table of them.
    case ministry
    /// A thesis or research paper.
    case academic
    /// A business report or feasibility study.
    case corporate
    /// An article or newsletter.
    case magazine
    /// Everything else: a clean, quiet document.
    case plain

    var slug: String { rawValue }

    /// The web omits the contents page for `ministry` (`app.js:31119`) and prints it everywhere
    /// else. The rule lives here so the composer does not repeat it.
    var showsTableOfContents: Bool { self != .ministry }

    // MARK: - Choosing one

    /// Which look a request asks for, or `plain` when it asks for none.
    ///
    /// Ported from `docTemplateFor(task)`. The order matters and is the web's: an exam paper is
    /// recognised before a research paper, and the bare «١٠ أسئلة» form is checked last so a
    /// request that named its own kind wins over one that only counted its questions.
    static func resolve(from task: String) -> DocTemplate {
        let text = task
        if matches(examPattern, text) { return .ministry }
        if matches(academicPattern, text) { return .academic }
        if matches(corporatePattern, text) { return .corporate }
        if matches(magazinePattern, text) { return .magazine }
        if matches(countedQuestionsPattern, text) { return .ministry }
        return .plain
    }

    /// A name the model wrote into its metadata, when it named one at all.
    static func named(_ raw: String?) -> DocTemplate? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return DocTemplate(rawValue: key)
    }

    // MARK: - The stylesheet

    /// The template's CSS, with the shared base in front of it.
    ///
    /// A missing file is not a failure worth refusing a document for: the base alone still prints a
    /// legible page, and a legible page beats no page. It is logged so a resource that failed to
    /// copy into the bundle is discoverable rather than silent.
    var css: String {
        var out = DocTemplate.stylesheet(named: "doc-base") ?? DocTemplate.fallbackBase
        if let own = DocTemplate.stylesheet(named: "doc-" + rawValue) {
            out += "\n" + own
        } else if self != .plain {
            Log.ui.error("document stylesheet missing: doc-\(self.rawValue, privacy: .public)")
        }
        return out
    }

    private static func stylesheet(named name: String) -> String? {
        let folders = ["DocTemplates", nil] as [String?]
        for folder in folders {
            guard let url = Bundle.main.url(forResource: name, withExtension: "css", subdirectory: folder) else {
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { continue }
            return text
        }
        return nil
    }

    /// Enough to print a readable A4 page if every stylesheet went missing. Deliberately plain: it
    /// is a safety net, not a design.
    private static let fallbackBase = """
    @page { size: A4; margin: 20mm 18mm; }
    html { -webkit-text-size-adjust: 100%; }
    body { margin: 0; font: 400 11.5pt/1.75 -apple-system, "SF Pro Text", system-ui, sans-serif; color: #16181d; }
    h1, h2, h3, h4 { line-height: 1.3; break-after: avoid; }
    p { margin: 0 0 0.85em; }
    table { width: 100%; border-collapse: collapse; break-inside: auto; }
    th, td { border: 1px solid #c9ccd4; padding: 6pt 8pt; text-align: start; }
    thead { display: table-header-group; }
    tr, img, figure, blockquote { break-inside: avoid; }
    pre { white-space: pre-wrap; word-wrap: break-word; }
    """

    // MARK: - Patterns
    //
    // Verbatim from app.js:30590-30595. Kept as separate constants so a future change can be
    // diffed against the web line by line.

    private static let examPattern =
        "امتحان|اختبار|كويز|ورقة\\s*(امتحان|أسئلة|عمل)|نموذج\\s*امتحان|بنك\\s*(?:ال)?[أا]سئلة"
        + "|\\bexam\\b|\\bquiz\\b|\\btest\\s*paper\\b|worksheet|question\\s*bank"

    private static let academicPattern =
        "بحث|أطروحة|اطروحة|رسالة\\s*(ماجستير|دكتوراه)|أكاديم|اكاديم"
        + "|thesis|dissertation|research\\s*paper|academic"

    private static let corporatePattern =
        "تقرير\\s*(عمل|شركة|أعمال|إداري)|خطة\\s*عمل|دراسة\\s*جدوى"
        + "|business\\s*(report|plan)|corporate|executive\\s*(summary|report)|\\bkpi\\b"

    private static let magazinePattern =
        "مقال|article|magazine|مجلة|editorial|blog\\s*post|نشرة"

    /// A plain "N questions/problems" request is an exam paper too.
    private static let countedQuestionsPattern =
        "[\\d\u{0660}-\u{0669}]{1,4}\\s*(?:[A-Za-z\u{0600}-\u{06FF}'\u{2019},-]+\\s+){0,4}?"
        + "(?:سؤال|أسئلة|اسئلة|مسأل[ةه]|فقر[ةه]|questions?|problems?)"

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        RequestClassifier.matches(pattern, text)
    }
}
