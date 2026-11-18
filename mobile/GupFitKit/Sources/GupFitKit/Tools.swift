import Foundation

// The AI chat's tools (pc/tools-v1.json, pc/PROTOCOL.md). The model asks for a call through the PC; the phone checks
// it, runs it against the same store the screens use, in one transaction together with a receipt, and answers with
// only the records the call asked for. ToolRunner.swift does the work.

enum ToolSet {
    /// the tool set's version (tools-v1.json); a call for another version is refused
    static let version = 1
}

/// Every tool of version 1, by its wire name.
enum ToolName: String, CaseIterable, Sendable, Codable {
    case searchFoods = "search_foods"
    case getDay = "get_day"
    case logMeal = "log_meal"
    case editMealEntry = "edit_meal_entry"
    case deleteMealEntry = "delete_meal_entry"
    case getWorkouts = "get_workouts"
    case listExercises = "list_exercises"
    case logWorkout = "log_workout"
    case editWorkout = "edit_workout"
    case searchRecipes = "search_recipes"
    case getRecipe = "get_recipe"
    case createRecipe = "create_recipe"
    case editRecipe = "edit_recipe"
    case logRecipe = "log_recipe"

    /// changes data (so it gets a receipt check against repeats and its changes get cards with Undo)
    var writes: Bool {
        switch self {
        case .searchFoods, .getDay, .getWorkouts, .listExercises, .searchRecipes, .getRecipe: false
        case .logMeal, .editMealEntry, .deleteMealEntry, .logWorkout, .editWorkout, .createRecipe, .editRecipe,
             .logRecipe: true
        }
    }
}

/// One `tool_call` event: what the model asked for.
struct ToolCall: Codable, Equatable, Sendable {
    /// unique within its turn ("c-1")
    var call: String
    var name: String
    var version: Int
    var arguments: JSONValue
}

/// A record as it was before or after a change (what Undo puts back).
enum ToolRecord: Codable, Equatable, Sendable {
    case meal(MealEntry)
    case workout(WorkoutSession)
    case recipe(Recipe)
    case exercise(Exercise)
}

/// One change a call made: what the chat's card shows, and the record before and after for Undo.
struct ToolChange: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case mealLogged, mealEdited, mealDeleted, workoutLogged, workoutEdited, exerciseAdded, recipeCreated,
             recipeEdited
    }

    var kind: Kind
    /// "Logged to breakfast"
    var title: String
    /// "2 × 1 large Egg, whole, raw · 143 kcal"
    var detail: String
    var before: ToolRecord?
    var after: ToolRecord?
    var undone = false
}

/// What a call came to: its answer for the model and the changes it made.
struct ToolOutcome: Equatable, Sendable {
    var ok: Bool
    /// the answer for the model when ok
    var result: JSONValue?
    /// why it failed, for the model (nothing was changed)
    var error: String?
    var changes: [ToolChange]
    /// the same call (or the same change earlier in this turn) was answered before: this is its stored outcome
    var replayed = false

    static func failed(_ message: String) -> ToolOutcome { ToolOutcome(ok: false, error: message, changes: []) }
}

/// Kept with the change in the same transaction, so a replayed or repeated call is answered from here instead of
/// changing anything twice (exactly once per (turn, call), and per identical change within a turn).
struct ToolReceipt: Codable, Equatable, Sendable {
    var turn: String
    var call: String
    var name: String
    /// the name and canonical arguments' hash: the same change asked twice in one turn
    var fingerprint: String
    var ok: Bool
    var result: JSONValue?
    var error: String?
    var changes: [ToolChange]
    var at: Date

    var outcome: ToolOutcome { ToolOutcome(ok: ok, result: result, error: error, changes: changes, replayed: true) }
}

/// Where receipts are kept: the same database as the data they describe.
protocol ToolReceiptRepository: AnyObject {
    func receipt(turn: String, call: String) throws -> ToolReceipt?
    /// the successful writes in `turn` with this fingerprint
    func receipts(turn: String, fingerprint: String) throws -> [ToolReceipt]
    /// inserts, or replaces the receipt of the same (turn, call) (Undo marks its changes)
    func saveReceipt(_ receipt: ToolReceipt) throws
}

/// What Undo of one change came to.
enum UndoResult: Equatable, Sendable {
    case undone
    /// it was undone before
    case already
    /// the record changed since (in the app or by a later call): nothing was touched
    case changedSince(String)
    case failed(String)

    var message: String? {
        switch self {
        case .undone, .already: nil
        case .changedSince(let m), .failed(let m): m
        }
    }
}

enum Fingerprint {
    /// FNV-1a 64 over the text: stable across launches and platforms (Swift's Hasher is seeded per process)
    static func of(_ text: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }
}
