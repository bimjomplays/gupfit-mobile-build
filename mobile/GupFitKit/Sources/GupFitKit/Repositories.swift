import Foundation

// Storage behind the screens and the AI chat's tool calls. Both use the same repository, so a meal the chat logs is
// the same row the Today tab shows. The phone's SQLite store implements these (a later thread); InMemoryStore below
// is for tests and previews. Calls are synchronous: the store is local, and a tool call's change and its receipt must
// commit together, which is simpler without suspension points in between.
//
// Every `save` validates first and throws ValidationError without storing anything; it inserts a new id or replaces
// the record with the same id. `delete` throws RepositoryError.notFound for an id that isn't there.

enum RepositoryError: Error, Equatable, Sendable {
    case notFound(String)
}

/// The person's own foods (the bundled catalog is a separate read-only source).
protocol FoodRepository: AnyObject {
    func food(id: FoodID) throws -> Food?
    /// foods whose name or brand match every word of `query` (word prefixes, accents and case ignored), by name
    func searchFoods(_ query: String, limit: Int) throws -> [Food]
    func saveFood(_ food: Food) throws
    func deleteFood(id: FoodID) throws
}

protocol MealLogRepository: AnyObject {
    func entry(id: MealEntryID) throws -> MealEntry?
    /// entries of the days in `days`, oldest first
    func entries(in days: ClosedRange<LocalDay>) throws -> [MealEntry]
    func saveEntry(_ entry: MealEntry) throws
    func deleteEntry(id: MealEntryID) throws
}

extension MealLogRepository {
    func entries(on day: LocalDay) throws -> [MealEntry] { try entries(in: day...day) }
    func summary(of day: LocalDay) throws -> DaySummary { DaySummary(day: day, entries: try entries(on: day)) }
}

protocol WorkoutRepository: AnyObject {
    /// the exercise library, by name
    func exercises() throws -> [Exercise]
    func saveExercise(_ exercise: Exercise) throws
    func deleteExercise(id: ExerciseID) throws

    func session(id: WorkoutSessionID) throws -> WorkoutSession?
    /// sessions that started inside `interval`, oldest first
    func sessions(in interval: DateInterval) throws -> [WorkoutSession]
    func saveSession(_ session: WorkoutSession) throws
    func deleteSession(id: WorkoutSessionID) throws
}

protocol RecipeRepository: AnyObject {
    func recipe(id: RecipeID) throws -> Recipe?
    /// every recipe whose name or tags match `query` (all of them for an empty query), by name
    func searchRecipes(_ query: String) throws -> [Recipe]
    func saveRecipe(_ recipe: Recipe) throws
    func deleteRecipe(id: RecipeID) throws
}

/// All four together: what the app and the AI chat's tool calls work against.
typealias GupFitStore = FoodRepository & MealLogRepository & WorkoutRepository & RecipeRepository

/// Everything in memory, for tests and SwiftUI previews. Thread-safe.
final class InMemoryStore: GupFitStore, @unchecked Sendable {
    private let lock = NSLock()
    private var foods: [FoodID: Food] = [:]
    private var mealEntries: [MealEntryID: MealEntry] = [:]
    private var exerciseLibrary: [ExerciseID: Exercise] = [:]
    private var workoutSessions: [WorkoutSessionID: WorkoutSession] = [:]
    private var recipes: [RecipeID: Recipe] = [:]

    init() {}

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func remove<K: Hashable & CustomStringConvertible, V>(_ id: K, from dict: inout [K: V]) throws {
        guard dict.removeValue(forKey: id) != nil else { throw RepositoryError.notFound(id.description) }
    }

    // MARK: foods

    func food(id: FoodID) -> Food? { locked { foods[id] } }

    func searchFoods(_ query: String, limit: Int) -> [Food] {
        locked {
            Array(foods.values.filter { FoodSearch.matches(query, name: $0.name, brand: $0.brand) }
                .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
                .prefix(max(0, limit)))
        }
    }

    func saveFood(_ food: Food) throws {
        try food.validate()
        locked { foods[food.id] = food }
    }

    func deleteFood(id: FoodID) throws { try locked { try Self.remove(id, from: &foods) } }

    // MARK: meal log

    func entry(id: MealEntryID) -> MealEntry? { locked { mealEntries[id] } }

    func entries(in days: ClosedRange<LocalDay>) -> [MealEntry] {
        locked {
            mealEntries.values.filter { days.contains($0.day) }
                .sorted { ($0.day, $0.loggedAt, $0.id) < ($1.day, $1.loggedAt, $1.id) }
        }
    }

    func saveEntry(_ entry: MealEntry) throws {
        try entry.validate()
        locked { mealEntries[entry.id] = entry }
    }

    func deleteEntry(id: MealEntryID) throws { try locked { try Self.remove(id, from: &mealEntries) } }

    // MARK: workouts

    func exercises() -> [Exercise] {
        locked { exerciseLibrary.values.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) } }
    }

    func saveExercise(_ exercise: Exercise) throws {
        try exercise.validate()
        locked { exerciseLibrary[exercise.id] = exercise }
    }

    func deleteExercise(id: ExerciseID) throws { try locked { try Self.remove(id, from: &exerciseLibrary) } }

    func session(id: WorkoutSessionID) -> WorkoutSession? { locked { workoutSessions[id] } }

    func sessions(in interval: DateInterval) -> [WorkoutSession] {
        locked {
            workoutSessions.values.filter { interval.contains($0.startedAt) }
                .sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        }
    }

    func saveSession(_ session: WorkoutSession) throws {
        try session.validate()
        locked { workoutSessions[session.id] = session }
    }

    func deleteSession(id: WorkoutSessionID) throws { try locked { try Self.remove(id, from: &workoutSessions) } }

    // MARK: recipes

    func recipe(id: RecipeID) -> Recipe? { locked { recipes[id] } }

    func searchRecipes(_ query: String) -> [Recipe] {
        locked {
            recipes.values.filter { FoodSearch.matches(query, name: $0.name, brand: $0.tags.joined(separator: " ")) }
                .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        }
    }

    func saveRecipe(_ recipe: Recipe) throws {
        try recipe.validate()
        locked { recipes[recipe.id] = recipe }
    }

    func deleteRecipe(id: RecipeID) throws { try locked { try Self.remove(id, from: &recipes) } }
}
