import Foundation

/// A coding key built from any string. Every hand-written `init(from:)` in the app keys its
/// container on this so a missing or renamed server field is a `nil`, never a thrown error.
struct AnyCodingKey: CodingKey, Sendable {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    init(_ s: String) {
        self.stringValue = s
        self.intValue = nil
    }
}

/// Decoding helpers for a server that is not type-stable: counters arrive as `12` or `"12"`,
/// flags as `true`, `"true"` or `1`, and any field may simply be absent.
///
/// Every helper returns `nil` instead of throwing, so a single unexpected value can never lose a
/// whole response.
enum LenientJSON {
    static func int(_ c: KeyedDecodingContainer<AnyCodingKey>, _ key: String) -> Int? {
        let k = AnyCodingKey(key)
        guard c.contains(k) else { return nil }
        if let value = try? c.decodeIfPresent(Int.self, forKey: k) { return value }
        if let value = try? c.decodeIfPresent(Double.self, forKey: k), let narrowed = narrowedToInt(value) {
            return narrowed
        }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: k) { return value ? 1 : 0 }
        if let text = try? c.decodeIfPresent(String.self, forKey: k) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(trimmed) { return value }
            if let value = Double(trimmed), let narrowed = narrowedToInt(value) { return narrowed }
        }
        return nil
    }

    /// `Int(_:)` traps on a finite double outside `Int`'s range, so a server counter that arrives
    /// as `1e300` would crash the decode instead of being ignored.
    private static func narrowedToInt(_ value: Double) -> Int? {
        guard value.isFinite, value >= -9.2e18, value <= 9.2e18 else { return nil }
        return Int(value.rounded())
    }

    static func double(_ c: KeyedDecodingContainer<AnyCodingKey>, _ key: String) -> Double? {
        let k = AnyCodingKey(key)
        guard c.contains(k) else { return nil }
        if let value = try? c.decodeIfPresent(Double.self, forKey: k) { return value }
        if let value = try? c.decodeIfPresent(Int.self, forKey: k) { return Double(value) }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: k) { return value ? 1 : 0 }
        if let text = try? c.decodeIfPresent(String.self, forKey: k) {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func bool(_ c: KeyedDecodingContainer<AnyCodingKey>, _ key: String) -> Bool? {
        let k = AnyCodingKey(key)
        guard c.contains(k) else { return nil }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: k) { return value }
        if let value = try? c.decodeIfPresent(Int.self, forKey: k) { return value != 0 }
        if let value = try? c.decodeIfPresent(Double.self, forKey: k) { return value != 0 }
        if let text = try? c.decodeIfPresent(String.self, forKey: k) {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1", "on": return true
            case "false", "no", "0", "off", "": return false
            default: return nil
            }
        }
        return nil
    }

    static func string(_ c: KeyedDecodingContainer<AnyCodingKey>, _ key: String) -> String? {
        let k = AnyCodingKey(key)
        guard c.contains(k) else { return nil }
        if let value = try? c.decodeIfPresent(String.self, forKey: k) { return value }
        if let value = try? c.decodeIfPresent(Int.self, forKey: k) { return String(value) }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: k) { return value ? "true" : "false" }
        if let value = try? c.decodeIfPresent(Double.self, forKey: k), value.isFinite {
            if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        }
        return nil
    }

    /// A nested object decoded with `try?`: a malformed sub-object never fails the parent.
    static func nested<T: Decodable>(
        _ c: KeyedDecodingContainer<AnyCodingKey>,
        _ key: String,
        as type: T.Type
    ) -> T? {
        let k = AnyCodingKey(key)
        guard c.contains(k) else { return nil }
        return try? c.decodeIfPresent(type, forKey: k)
    }

    /// An array decoded element by element; malformed entries are dropped instead of thrown.
    static func array<T: Decodable>(
        _ c: KeyedDecodingContainer<AnyCodingKey>,
        _ key: String,
        of type: T.Type
    ) -> [T]? {
        let k = AnyCodingKey(key)
        guard c.contains(k) else { return nil }
        if let whole = try? c.decodeIfPresent([T].self, forKey: k) { return whole }
        guard var unkeyed = try? c.nestedUnkeyedContainer(forKey: k) else { return nil }
        var result: [T] = []
        while !unkeyed.isAtEnd {
            if let element = try? unkeyed.decode(type) {
                result.append(element)
            } else if (try? unkeyed.decodeNil()) == true {
                continue
            } else {
                break
            }
        }
        return result
    }
}
