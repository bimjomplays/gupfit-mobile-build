import Foundation

/// Any JSON value: a tool call's arguments and its result travel as these (pc/PROTOCOL.md, tools-v1.json).
enum JSONValue: Hashable, Sendable, Codable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // whole numbers as integers ("2", not "2.0"), so results read naturally
            if n.isFinite, n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    var string: String? { if case .string(let s) = self { s } else { nil } }
    var number: Double? { if case .number(let n) = self { n } else { nil } }
    var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }

    subscript(_ key: String) -> JSONValue? { object?[key] }

    /// compact JSON with sorted keys: the same value always gives the same text (receipts, fingerprints)
    var canonicalText: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    static func parse(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// a number rounded to `digits` decimals, or null for nil (unknown stays unknown)
    static func rounded(_ value: Double?, _ digits: Int = 1) -> JSONValue {
        guard let value, value.isFinite else { return .null }
        let scale = pow(10, Double(digits))
        return .number((value * scale).rounded() / scale)
    }

    /// the object without its null members (results leave unknowns out instead of listing nulls)
    var droppingNulls: JSONValue {
        switch self {
        case .object(let o): .object(o.filter { $0.value != .null }.mapValues(\.droppingNulls))
        case .array(let a): .array(a.map(\.droppingNulls))
        default: self
        }
    }
}
