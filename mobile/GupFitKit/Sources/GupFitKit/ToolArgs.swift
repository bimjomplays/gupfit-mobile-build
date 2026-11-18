import Foundation

/// A tool call's arguments that don't fit its schema, or that name something the phone doesn't have. `message` goes
/// back to the model as the call's error, so it says which field and what is wrong in plain words.
struct ToolError: Error, Equatable, Sendable, CustomStringConvertible {
    var message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// Reads one JSON object of a tool call strictly: every key it doesn't know is an error (as the schema's
/// `additionalProperties: false`), types and bounds are checked, and every error names its field path
/// (`items[1].unit`). Call `done()` after reading to refuse leftover keys.
struct ToolArgs {
    let path: String
    private let values: [String: JSONValue]
    private var read: Set<String> = []

    init(_ value: JSONValue?, path: String = "") throws {
        guard case .object(let o)? = value else {
            throw ToolError("\(path.isEmpty ? "arguments" : path) must be an object")
        }
        self.path = path
        values = o
    }

    private func field(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    /// the raw value; null counts as missing
    private mutating func value(_ key: String) -> JSONValue? {
        read.insert(key)
        guard let v = values[key], v != .null else { return nil }
        return v
    }

    /// whether `key` has a value (null counts as missing); the key counts as read
    mutating func has(_ key: String) -> Bool {
        read.insert(key)
        return values[key].map { $0 != .null } ?? false
    }

    mutating func string(_ key: String, max: Int, required: Bool = false, allowEmpty: Bool = false) throws -> String? {
        guard let v = value(key) else {
            if required { throw ToolError("\(field(key)) is required") }
            return nil
        }
        guard case .string(let s) = v else { throw ToolError("\(field(key)) must be text") }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty && !allowEmpty { throw ToolError("\(field(key)) can't be empty") }
        if t.count > max { throw ToolError("\(field(key)) is longer than \(max) characters") }
        if t.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" }) {
            throw ToolError("\(field(key)) has control characters")
        }
        return t
    }

    mutating func number(_ key: String, min: Double = 0, max: Double, above: Bool = false,
                         required: Bool = false) throws -> Double? {
        guard let v = value(key) else {
            if required { throw ToolError("\(field(key)) is required") }
            return nil
        }
        guard case .number(let n) = v, n.isFinite else { throw ToolError("\(field(key)) must be a number") }
        if above ? n <= min : n < min {
            throw ToolError("\(field(key)) must be \(above ? "more than" : "at least") \(Format.number(min))")
        }
        if n > max { throw ToolError("\(field(key)) must be at most \(Format.number(max))") }
        return n
    }

    mutating func int(_ key: String, min: Int = 0, max: Int, required: Bool = false) throws -> Int? {
        guard let n = try number(key, min: Double(min), max: Double(max), required: required) else { return nil }
        guard n == n.rounded() else { throw ToolError("\(field(key)) must be a whole number") }
        return Int(n)
    }

    mutating func bool(_ key: String) throws -> Bool? {
        guard let v = value(key) else { return nil }
        guard case .bool(let b) = v else { throw ToolError("\(field(key)) must be true or false") }
        return b
    }

    mutating func choice<T: RawRepresentable>(_ key: String, _ type: T.Type, required: Bool = false) throws -> T?
    where T.RawValue == String, T: CaseIterable {
        guard let s = try string(key, max: 40, required: required) else { return nil }
        guard let t = T(rawValue: s.lowercased()) else {
            throw ToolError("\(field(key)) must be one of \(T.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return t
    }

    mutating func day(_ key: String, required: Bool = false) throws -> LocalDay? {
        guard let s = try string(key, max: 10, required: required) else { return nil }
        guard let d = LocalDay(s) else { throw ToolError("\(field(key)) must be a date like 2026-01-31") }
        return d
    }

    /// an array of objects, each read by `each` with its own strict reader (`items[2]`)
    mutating func objects<T>(_ key: String, min: Int, max: Int, required: Bool = false,
                             _ each: (inout ToolArgs) throws -> T) throws -> [T]? {
        guard let v = value(key) else {
            if required { throw ToolError("\(field(key)) is required") }
            return nil
        }
        guard case .array(let a) = v else { throw ToolError("\(field(key)) must be a list") }
        if a.count < min { throw ToolError("\(field(key)) needs at least \(min) item\(min == 1 ? "" : "s")") }
        if a.count > max { throw ToolError("\(field(key)) has more than \(max) items") }
        return try a.enumerated().map { i, item in
            var r = try ToolArgs(item, path: "\(field(key))[\(i)]")
            let out = try each(&r)
            try r.done()
            return out
        }
    }

    mutating func strings(_ key: String, maxItems: Int, maxLength: Int) throws -> [String]? {
        guard let v = value(key) else { return nil }
        guard case .array(let a) = v else { throw ToolError("\(field(key)) must be a list of text") }
        if a.count > maxItems { throw ToolError("\(field(key)) has more than \(maxItems) items") }
        return try a.enumerated().map { i, item in
            guard case .string(let s) = item else { throw ToolError("\(field(key))[\(i)] must be text") }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { throw ToolError("\(field(key))[\(i)] can't be empty") }
            if t.count > maxLength { throw ToolError("\(field(key))[\(i)] is longer than \(maxLength) characters") }
            return t
        }
    }

    /// refuses keys nobody read (a misspelled or invented argument is an error, not silently ignored)
    func done() throws {
        let extra = values.keys.filter { !read.contains($0) }.sorted()
        if !extra.isEmpty {
            throw ToolError("\(path.isEmpty ? "" : path + ": ")unknown argument\(extra.count == 1 ? "" : "s") \(extra.joined(separator: ", "))")
        }
    }
}
