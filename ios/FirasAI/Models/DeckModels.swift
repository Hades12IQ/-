import Foundation
import SwiftUI

/// The ```` ```firas-deck ```` payload: a whole slide deck delivered inside one answer.
///
/// The app did not know this fence existed. Every deck the model produced — and it produces one
/// whenever the reader asks for a presentation — fell through to the plain-code renderer and
/// arrived as a screenful of raw JSON: «هسه ينطي الملفات على شكل داتا فقط». The web has had the
/// block since app.js:34521; this is the same payload, read the same way.
///
/// Parsing is deliberately forgiving in one direction only: a body that does not carry a `slides`
/// array is not a deck and returns `nil`, so a malformed block still renders as code rather than as
/// an empty presentation.
struct DeckMeta: Sendable, Equatable, Decodable {

    var title: String
    var subtitle: String
    var theme: String
    var lang: String
    /// `building` while the agent is still writing slides into it; `done` afterwards.
    var phase: String
    var slides: [DeckSlide]

    var isBuilding: Bool { phase == "building" }

    var isArabic: Bool { lang.lowercased().hasPrefix("ar") }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        title = LenientJSON.string(c, "title") ?? ""
        subtitle = LenientJSON.string(c, "subtitle") ?? ""
        theme = LenientJSON.string(c, "theme") ?? "navy"
        lang = LenientJSON.string(c, "lang") ?? "ar"
        phase = LenientJSON.string(c, "phase") ?? "done"
        slides = (try? c.decode([DeckSlide].self, forKey: AnyCodingKey("slides"))) ?? []
    }

    // MARK: - Parsing

    /// The fence body, or `nil` when it is not a deck.
    ///
    /// Two attempts, exactly as the web makes them: the whole body first, then the first balanced
    /// `{…}` inside it. The second matters while a deck streams — the closing fence has not
    /// arrived yet, so the body often carries a tail of something else.
    static func parse(body: String) -> DeckMeta? {
        if let deck = decode(body), !deck.slides.isEmpty { return deck }
        guard let object = firstObject(in: body) else { return nil }
        guard let deck = decode(object), !deck.slides.isEmpty else { return nil }
        return deck
    }

    private static func decode(_ text: String) -> DeckMeta? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DeckMeta.self, from: data)
    }

    /// The first brace-balanced object, skipping braces that live inside strings.
    private static func firstObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// One slide. Every collection is non-optional and empty by default, so a layout that asks for
/// `stats` on a slide that has none draws nothing instead of crashing on a force-unwrap.
struct DeckSlide: Sendable, Equatable, Decodable {

    var isSection: Bool
    var layout: DeckLayout
    var title: String
    var bullets: [String]
    var image: String
    var imageAlt: String
    var notes: String
    var stats: [DeckStat]
    var columns: [DeckColumn]
    var steps: [DeckStep]
    var cards: [DeckTile]
    var quote: DeckQuote?
    var chart: DeckChart?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let kind = (LenientJSON.string(c, "t") ?? "").lowercased()
        let raw = (LenientJSON.string(c, "layout") ?? "").lowercased()
        isSection = kind == "section" || raw == "section" || (LenientJSON.bool(c, "section") ?? false)
        layout = DeckLayout(raw) ?? (isSection ? .section : .content)
        title = LenientJSON.string(c, "title") ?? ""
        bullets = DeckSlide.strings(c, "bullets")
        image = LenientJSON.string(c, "image") ?? ""
        imageAlt = LenientJSON.string(c, "imageAlt") ?? ""
        notes = LenientJSON.string(c, "notes") ?? ""
        stats = (try? c.decode([DeckStat].self, forKey: AnyCodingKey("stats"))) ?? []
        columns = (try? c.decode([DeckColumn].self, forKey: AnyCodingKey("columns"))) ?? []
        steps = (try? c.decode([DeckStep].self, forKey: AnyCodingKey("steps"))) ?? []
        cards = (try? c.decode([DeckTile].self, forKey: AnyCodingKey("cards"))) ?? []
        quote = try? c.decode(DeckQuote.self, forKey: AnyCodingKey("quote"))
        chart = try? c.decode(DeckChart.self, forKey: AnyCodingKey("chart"))
    }

    static func strings(_ c: KeyedDecodingContainer<AnyCodingKey>, _ key: String) -> [String] {
        guard let list = try? c.decode([String].self, forKey: AnyCodingKey(key)) else { return [] }
        return list.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// The eleven layouts the web writes (`app.js:34126`). An unknown name falls back to `content`,
/// which draws a title and bullets and is never wrong, only plain.
enum DeckLayout: String, Sendable, Equatable, CaseIterable {
    case content
    case hero
    case twocol
    case stats
    case comparison
    case timeline
    case process
    case cards
    case quote
    case imagefull
    case section

    init?(_ raw: String) {
        guard let value = DeckLayout(rawValue: raw) else { return nil }
        self = value
    }
}

struct DeckStat: Sendable, Equatable, Decodable {
    var value: String
    var label: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        value = LenientJSON.string(c, "value") ?? ""
        label = LenientJSON.string(c, "label") ?? ""
    }
}

struct DeckColumn: Sendable, Equatable, Decodable {
    var heading: String
    var points: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        heading = LenientJSON.string(c, "heading") ?? ""
        points = DeckSlide.strings(c, "points")
    }
}

struct DeckStep: Sendable, Equatable, Decodable {
    var title: String
    var desc: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        title = LenientJSON.string(c, "title") ?? ""
        desc = LenientJSON.string(c, "desc") ?? ""
    }
}

struct DeckTile: Sendable, Equatable, Decodable {
    var icon: String
    var title: String
    var desc: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        icon = LenientJSON.string(c, "icon") ?? ""
        title = LenientJSON.string(c, "title") ?? ""
        desc = LenientJSON.string(c, "desc") ?? ""
    }
}

struct DeckQuote: Sendable, Equatable, Decodable {
    var text: String
    var author: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        text = LenientJSON.string(c, "text") ?? ""
        author = LenientJSON.string(c, "author") ?? ""
    }
}

/// `normalizeDeckChart` (`app.js:34431`): a bar, a line, or a doughnut, with up to four series.
struct DeckChart: Sendable, Equatable, Decodable {

    enum Kind: String, Sendable, Equatable {
        case bar
        case line
        case doughnut
    }

    var kind: Kind
    var title: String
    var labels: [String]
    var series: [Series]

    struct Series: Sendable, Equatable, Decodable {
        var name: String
        var data: [Double]

        init(name: String, data: [Double]) {
            self.name = name
            self.data = data
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            name = LenientJSON.string(c, "name") ?? ""
            data = (try? c.decode([Double].self, forKey: AnyCodingKey("data"))) ?? []
        }
    }

    /// A chart with no labels or no numbers is not a chart; the slide simply omits it.
    var isDrawable: Bool { !labels.isEmpty && series.contains { !$0.data.isEmpty } }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let raw = (LenientJSON.string(c, "type") ?? "").lowercased()
        switch raw {
        case "line": kind = .line
        case "pie", "donut", "doughnut": kind = .doughnut
        default: kind = .bar
        }
        title = LenientJSON.string(c, "title") ?? ""
        labels = ((try? c.decode([String].self, forKey: AnyCodingKey("labels"))) ?? []).map {
            String($0.prefix(28))
        }
        var found = (try? c.decode([Series].self, forKey: AnyCodingKey("series"))) ?? []
        if found.isEmpty, let flat = try? c.decode([Double].self, forKey: AnyCodingKey("data")) {
            found = [Series(name: LenientJSON.string(c, "name") ?? "", data: flat)]
        }
        found = found.filter { !$0.data.isEmpty }
        // Every series is padded and clipped to the label count, so a bar never reads against the
        // wrong label and a line never runs off the end of the axis.
        let width = labels.count
        found = found.map { series in
            var padded = series.data
            if padded.count < width { padded.append(contentsOf: Array(repeating: 0, count: width - padded.count)) }
            return Series(name: series.name, data: Array(padded.prefix(width)))
        }
        // A doughnut has one series by definition.
        series = kind == .doughnut ? Array(found.prefix(1)) : Array(found.prefix(4))
    }
}

/// A deck paints itself, not the app: it is a document, and a document that changed colour with the
/// reader's theme would look different every time it was reopened and different again once shared.
/// The six names the model may write, and a neutral fallback for anything else.
struct DeckPalette: Sendable, Equatable {

    let ground: Color
    let deep: Color
    let accent: Color
    let ink: Color
    let inkMuted: Color
    let isLight: Bool

    static func named(_ raw: String) -> DeckPalette {
        switch raw.lowercased() {
        case "teal", "green", "emerald":
            return DeckPalette(ground: "0C201E", deep: "123330", accent: "4FB3A4", ink: "EEF7F5", isLight: false)
        case "plum", "purple", "violet":
            return DeckPalette(ground: "1B1226", deep: "2A1C3B", accent: "A277D8", ink: "F5F0FB", isLight: false)
        case "sand", "paper", "light", "cream":
            return DeckPalette(ground: "FAF7F0", deep: "EDE5D6", accent: "8A6B2F", ink: "1F1B14", isLight: true)
        case "slate", "grey", "gray", "graphite":
            return DeckPalette(ground: "15181C", deep: "22272E", accent: "7C93AD", ink: "EEF1F5", isLight: false)
        case "ink", "black", "noir":
            return DeckPalette(ground: "08080A", deep: "141418", accent: "C9A227", ink: "F5F3EC", isLight: false)
        default:
            return DeckPalette(ground: "0E1B2E", deep: "16294A", accent: "5B8FD6", ink: "F2F6FC", isLight: false)
        }
    }

    private init(ground: String, deep: String, accent: String, ink: String, isLight: Bool) {
        self.ground = Color(hex: ground)
        self.deep = Color(hex: deep)
        self.accent = Color(hex: accent)
        self.ink = Color(hex: ink)
        self.inkMuted = Color(hex: ink).opacity(isLight ? 0.62 : 0.68)
        self.isLight = isLight
    }
}
