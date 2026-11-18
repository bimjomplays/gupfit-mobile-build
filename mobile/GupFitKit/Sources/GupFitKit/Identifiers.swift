import Foundation

/// A stable, typed id. `Owner` only keeps a food's id from being passed where a recipe's is wanted; the value is a
/// plain string so ids survive storage, export and the AI chat's tool calls unchanged. New records get a UUID;
/// catalog foods use their source's id (`usda:171705`).
struct TypedID<Owner>: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible,
    ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }

    /// a fresh random id
    static func new() -> TypedID { TypedID(UUID().uuidString.lowercased()) }

    var description: String { rawValue }

    static func < (a: TypedID, b: TypedID) -> Bool { a.rawValue < b.rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

typealias FoodID = TypedID<Food>
typealias MealEntryID = TypedID<MealEntry>
typealias ExerciseID = TypedID<Exercise>
typealias WorkoutSessionID = TypedID<WorkoutSession>
typealias SessionExerciseID = TypedID<SessionExercise>
typealias WorkoutSetID = TypedID<WorkoutSet>
typealias RecipeID = TypedID<Recipe>
typealias RecipeIngredientID = TypedID<RecipeIngredient>
