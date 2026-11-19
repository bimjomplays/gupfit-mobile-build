import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

#if SWIFT_PACKAGE
/// The phone and the PC check the same shapes: pc/tools-v1.json (what the model is shown) against ToolRunner (what
/// the phone accepts). Every tool is in both with the same name and write flag; one example call per tool, using every
/// argument the schema has, is valid by the schema and runs on the phone; calls the schema refuses, the phone refuses.
final class ToolSchemaTests: XCTestCase {
    static var file: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../pc/tools-v1.json")
            .standardizedFileURL
    }

    var root: JSONValue!
    var defs: [String: JSONValue] = [:]

    override func setUpWithError() throws {
        guard let data = FileManager.default.contents(atPath: Self.file.path) else {
            throw XCTSkip("no pc/tools-v1.json at \(Self.file.path)")
        }
        root = try JSONDecoder().decode(JSONValue.self, from: data)
        defs = root["$defs"]?.object ?? [:]
    }

    func schema(_ name: String) throws -> JSONValue {
        try XCTUnwrap(root["tools"]?.array?.first { $0["name"]?.string == name }?["inputSchema"], name)
    }

    /// Example calls against the demo data, together using every argument of every tool.
    static let examples: [(String, JSONValue)] = [
        ("search_foods", ["query": "egg", "limit": 5]),
        ("get_day", ["date": "2026-11-17"]),
        ("log_meal", ["date": "2026-11-16", "meal": "breakfast", "note": "at home", "items": [
            ["food_id": "demo-egg", "amount": 2, "unit": "1 large (50 g)"],
            ["name": "Toast with butter", "calories": 120, "protein_g": 3, "carbs_g": 15, "fat_g": 5, "amount": 1, "unit": "slice"],
        ]]),
        ("edit_meal_entry", ["entry_id": "demo-e3", "amount": 180, "unit": "g", "meal": "dinner", "date": "2026-11-16", "note": "grilled"]),
        ("delete_meal_entry", ["entry_id": "demo-e1"]),
        ("get_workouts", ["from": "2026-11-10", "to": "2026-11-17"]),
        ("list_exercises", [:]),
        ("log_workout", ["date": "2026-11-17", "title": "Legs", "duration_min": 45, "notes": "felt strong", "exercises": [
            ["name": "Back squat", "notes": "belt", "sets": [
                ["reps": 5, "weight": 135, "weight_unit": "lb", "warmup": true],
                ["reps": 5, "weight": 225, "weight_unit": "lb", "rpe": 8],
            ]],
            ["name": "Bike", "kind": "cardio", "sets": [["duration_s": 600, "distance_m": 4000]]],
            ["exercise_id": "demo-bench", "sets": [["reps": 8, "weight": 60, "weight_unit": "kg"]]],
        ]]),
        ("edit_workout", ["workout_id": "demo-w1", "date": "2026-11-16", "title": "Leg day", "duration_min": 50, "notes": "",
                          "exercises": [
            ["exercise_id": "demo-squat", "sets": [["reps": 5, "weight": 100, "weight_unit": "kg", "rpe": 9, "warmup": false]]],
            ["name": "Plank", "kind": "timed", "notes": "to failure", "sets": [["duration_s": 90]]],
            ["name": "Run", "sets": [["duration_s": 900, "distance_m": 2500]]],
        ]]),
        ("search_recipes", ["query": "bowl"]),
        ("get_recipe", ["recipe_id": "demo-r1"]),
        ("create_recipe", ["name": "Overnight oats", "servings": 2, "cooked_weight_g": 500, "notes": "keeps 3 days",
                           "tags": ["breakfast"], "steps": ["Mix.", "Chill overnight."], "ingredients": [
            ["food_id": "demo-oats", "amount": 2, "unit": "½ cup"],
            ["food_id": "demo-yogurt", "amount": 1, "unit": "1 cup", "note": "plain"],
            ["name": "Honey", "calories": 21, "protein_g": 0, "carbs_g": 6, "fat_g": 0, "amount": 2, "unit": "tsp"],
        ]]),
        ("edit_recipe", ["recipe_id": "demo-r1", "name": "Chicken rice bowls", "servings": 5, "cooked_weight_g": 0,
                         "notes": "", "tags": ["meal prep", "lunch"], "steps": ["Cook.", "Split."], "ingredients": [
            ["food_id": "demo-chicken", "amount": 700, "unit": "g"],
            ["food_id": "demo-rice", "amount": 5, "unit": "1 cup", "note": "cooked"],
            ["name": "Teriyaki sauce", "calories": 16, "protein_g": 1, "carbs_g": 3, "fat_g": 0, "amount": 4, "unit": "tbsp"],
        ]]),
        ("log_recipe", ["recipe_id": "demo-r1", "servings": 1.5, "meal": "lunch", "date": "2026-11-17"]),
    ]

    func runner() -> ToolRunner {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Denver")!
        let store = Demo.store(day: Sample.day, calendar: cal)
        return ToolRunner(store: store, catalog: nil, calendar: cal, today: { Sample.day })
    }

    func testTheSameToolsOnBothSides() throws {
        XCTAssertEqual(root["version"]?.number.map(Int.init), ToolSet.version)
        let tools = try XCTUnwrap(root["tools"]?.array)
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, ToolName.allCases.map(\.rawValue))
        for t in tools {
            let name = try XCTUnwrap(ToolName(rawValue: t["name"]?.string ?? ""))
            XCTAssertEqual(t["write"]?.bool, name.writes, name.rawValue)
            XCTAssertFalse((t["description"]?.string ?? "").isEmpty, name.rawValue)
        }
        XCTAssertEqual(Set(Self.examples.map(\.0)), Set(ToolName.allCases.map(\.rawValue)), "an example per tool")
    }

    func testEveryExampleIsValidAndRunsOnThePhone() throws {
        for (name, args) in Self.examples {
            XCTAssertEqual(validate(args, try schema(name)), [], "\(name) by the schema")
            let out = runner().run(ToolCall(call: "c-1", name: name, version: 1, arguments: args), turn: "t")
            XCTAssertTrue(out.ok, "\(name): \(out.error ?? "")")
        }
    }

    func testTheExamplesUseEveryArgument() throws {
        var documented: Set<String> = [], used: Set<String> = []
        for (name, args) in Self.examples {
            paths(of: try schema(name), "\(name)", into: &documented)
            paths(of: args, "\(name)", into: &used)
        }
        XCTAssertEqual(documented.subtracting(used).sorted(), [], "arguments no example uses (the phone may not take them)")
        XCTAssertEqual(used.subtracting(documented).sorted(), [], "arguments the schema doesn't have")
    }

    /// What the schema refuses, the phone refuses too (and says which field).
    func testCallsTheSchemaRefusesThePhoneRefuses() throws {
        let bad: [(String, JSONValue, String)] = [
            ("log_meal", ["meal": "breakfast", "items": [["food_id": "demo-egg", "amount": 2, "unit": "1 large"]], "extra": 1], "extra"),
            ("log_meal", ["meal": "elevenses", "items": [["food_id": "demo-egg", "amount": 2, "unit": "1 large"]]], "meal"),
            ("log_meal", ["meal": "lunch", "items": [["food_id": "demo-egg", "amount": 0, "unit": "1 large"]]], "items[0].amount"),
            ("log_meal", ["meal": "lunch", "items": []], "items"),
            ("get_day", ["date": "17/11/2026"], "date"),
            ("get_day", [:], "date"),
            ("search_foods", ["query": "egg", "limit": 99], "limit"),
            ("search_foods", ["query": ""], "query"),
            ("log_workout", ["exercises": [["name": "Squat", "sets": [["reps": -1]]]]], "exercises[0].sets[0].reps"),
            ("log_workout", ["exercises": [["name": "Squat", "sets": [["reps": 5, "weight": 100, "weight_unit": "stone"]]]]],
             "exercises[0].sets[0].weight_unit"),
            ("log_recipe", ["recipe_id": "demo-r1", "servings": 1], "meal"),
            ("create_recipe", ["name": "X", "servings": 2, "ingredients": [["food_id": "demo-rice", "amount": 1, "unit": "1 cup", "grams": 3]]],
             "ingredients[0]"),
            ("list_exercises", ["all": true], "all"),
        ]
        for (name, args, field) in bad {
            XCTAssertNotEqual(validate(args, try schema(name)), [], "\(name) \(args.canonicalText) passes the schema")
            let out = runner().run(ToolCall(call: "c-1", name: name, version: 1, arguments: args), turn: "t")
            XCTAssertFalse(out.ok, "\(name) \(args.canonicalText) ran on the phone")
            XCTAssertTrue(out.error?.contains(field) == true, "\(name): \(out.error ?? "") should name \(field)")
        }
    }

    // MARK: a small JSON Schema checker (the parts tools-v1.json uses)

    func resolve(_ s: JSONValue) -> JSONValue {
        if let ref = s["$ref"]?.string, ref.hasPrefix("#/$defs/"), let d = defs[String(ref.dropFirst(8))] { return d }
        return s
    }

    func validate(_ v: JSONValue, _ schema: JSONValue, _ at: String = "$") -> [String] {
        let s = resolve(schema)
        var errors: [String] = []
        switch (s["type"]?.string, v) {
        case ("object", .object(let o)):
            let props = s["properties"]?.object ?? [:]
            for r in s["required"]?.array?.compactMap(\.string) ?? [] where o[r] == nil { errors.append("\(at).\(r) missing") }
            for (k, x) in o {
                if let p = props[k] { errors += validate(x, p, "\(at).\(k)") } else if s["additionalProperties"] == false {
                    errors.append("\(at).\(k) not allowed")
                }
            }
        case ("array", .array(let a)):
            if let n = s["minItems"]?.number, Double(a.count) < n { errors.append("\(at) too few") }
            if let n = s["maxItems"]?.number, Double(a.count) > n { errors.append("\(at) too many") }
            if let items = s["items"] { for (i, x) in a.enumerated() { errors += validate(x, items, "\(at)[\(i)]") } }
        case ("string", .string(let t)):
            if let n = s["minLength"]?.number, Double(t.count) < n { errors.append("\(at) too short") }
            if let n = s["maxLength"]?.number, Double(t.count) > n { errors.append("\(at) too long") }
            if let e = s["enum"]?.array, !e.contains(v) { errors.append("\(at) not in enum") }
            if let p = s["pattern"]?.string, t.range(of: p, options: .regularExpression) == nil { errors.append("\(at) pattern") }
        case ("number", .number(let n)), ("integer", .number(let n)):
            if s["type"] == "integer", n != n.rounded() { errors.append("\(at) not an integer") }
            if let m = s["minimum"]?.number, n < m { errors.append("\(at) below minimum") }
            if let m = s["exclusiveMinimum"]?.number, n <= m { errors.append("\(at) not above minimum") }
            if let m = s["maximum"]?.number, n > m { errors.append("\(at) above maximum") }
        case ("boolean", .bool):
            break
        default:
            errors.append("\(at) is not \(s["type"]?.string ?? "?")")
        }
        return errors
    }

    /// every property path in a schema (`log_meal.items[].unit`) or in a value
    func paths(of s: JSONValue, _ prefix: String, into out: inout Set<String>) {
        let s = resolve(s)
        if let props = s["properties"]?.object {
            for (k, p) in props { out.insert("\(prefix).\(k)"); paths(of: p, "\(prefix).\(k)", into: &out) }
        } else if s["type"] == "array", let items = s["items"] {
            paths(of: items, "\(prefix)[]", into: &out)
        } else if s["type"] == nil, s["$ref"] == nil {
            // a value, not a schema
            switch s {
            case .object(let o): for (k, x) in o { out.insert("\(prefix).\(k)"); paths(of: x, "\(prefix).\(k)", into: &out) }
            case .array(let a): for x in a { paths(of: x, "\(prefix)[]", into: &out) }
            default: break
            }
        }
    }
}
#endif
