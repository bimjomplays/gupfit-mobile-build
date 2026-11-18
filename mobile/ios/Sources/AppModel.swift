import Foundation
import Observation

/// Where the app's data lives for this launch. A normal launch has no arguments and opens the phone's database
/// (SQLiteStore.defaultURL). The UI tests and screenshot runs pass:
///   -store-name NAME   a separate database in Caches/NAME/ instead of the real one
///   -reset-store       start that database empty
///   -demo-data         fill it with the invented demo data when it's empty
struct LaunchOptions: Equatable {
    var storeName: String?
    var reset = false
    var demoData = false

    init(arguments: [String]) {
        if let i = arguments.firstIndex(of: "-store-name"), i + 1 < arguments.count {
            // a plain file name only, so an argument can never point outside Caches
            let name = arguments[i + 1].filter { $0.isLetter || $0.isNumber || $0 == "-" }
            storeName = name.isEmpty ? nil : name
        }
        // the real database is never reset or seeded
        reset = storeName != nil && arguments.contains("-reset-store")
        demoData = storeName != nil && arguments.contains("-demo-data")
    }

    func databaseURL() throws -> URL {
        guard let storeName else { return try SQLiteStore.defaultURL }
        return try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(storeName, isDirectory: true)
            .appendingPathComponent("gupfit.sqlite")
    }
}

/// The app opened its data, or couldn't (then it says why and touches nothing; it never falls back to an empty
/// store that would silently lose what gets logged).
enum AppLaunch {
    case ready(AppModel)
    case failed(String)

    @MainActor
    static func start(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppLaunch {
        let options = LaunchOptions(arguments: arguments)
        do {
            let url = try options.databaseURL()
            if options.reset { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = try SQLiteStore(url: url)
            if options.demoData, try store.searchFoods("", limit: 1).isEmpty {
                Demo.seed(store, day: LocalDay(Date()))
            }
            return .ready(AppModel(store: store))
        } catch {
            return .failed("\(error)")
        }
    }
}

/// The app's state for the screens, over one store (the phone's SQLite database; tests use an InMemoryStore) and the
/// bundled food catalog. Reads go straight to the store; every change bumps `revision`, which the reads depend on, so
/// the screens redraw after it. A failed change sets `errorMessage` (shown as an alert) and changes nothing.
@MainActor
@Observable
final class AppModel {
    var tab: AppTab = .today
    /// the day the Today tab shows
    var day: LocalDay
    var errorMessage: String?
    private(set) var revision = 0

    let store: any GupFitStore
    let catalog: FoodCatalog?
    private let fixedToday: LocalDay?

    init(store: any GupFitStore, catalog: FoodCatalog? = FoodCatalog.bundled(), today: LocalDay? = nil) {
        self.store = store
        self.catalog = catalog
        fixedToday = today
        day = today ?? LocalDay(Date())
    }

    var today: LocalDay { fixedToday ?? LocalDay(Date()) }

    /// what's shown when nothing is saved yet
    static let defaultGoals = NutritionGoals(energy: 2000, protein: 150, carbohydrate: 200, fat: 65)

    // MARK: reading

    private func read<T>(_ fallback: T, _ body: () throws -> T) -> T {
        _ = revision
        do {
            return try body()
        } catch {
            let message = "Couldn't read your data: \(error)"
            // not during the view update that called this
            Task { @MainActor in if self.errorMessage == nil { self.errorMessage = message } }
            return fallback
        }
    }

    var goals: NutritionGoals { read(Self.defaultGoals) { try store.goals(or: Self.defaultGoals) } }

    func summary(of day: LocalDay) -> DaySummary {
        read(DaySummary(day: day, entries: [])) { try store.summary(of: day) }
    }

    var daySummary: DaySummary { summary(of: day) }
    var todaySummary: DaySummary { summary(of: today) }

    /// the last 90 days of workouts, newest first
    var recentWorkouts: [WorkoutSession] {
        let range = DateInterval(start: today.adding(days: -89).start(), end: today.adding(days: 1).start())
        return read([WorkoutSession]()) { Array(try store.sessions(in: range).reversed()) }
    }

    var recipes: [Recipe] { read([]) { try store.searchRecipes("") } }
    func recipe(id: RecipeID) -> Recipe? { read(nil) { try store.recipe(id: id) } }
    func session(id: WorkoutSessionID) -> WorkoutSession? { read(nil) { try store.session(id: id) } }
    var exercises: [Exercise] { read([]) { try store.exercises() } }
    func entry(id: MealEntryID) -> MealEntry? { read(nil) { try store.entry(id: id) } }

    func myFoods(matching query: String, limit: Int = 50) -> [Food] {
        read([]) { try store.searchFoods(query, limit: limit) }
    }

    func recipes(matching query: String) -> [Recipe] { read([]) { try store.searchRecipes(query) } }

    func catalogHits(_ query: String, limit: Int = 50) -> [CatalogHit] {
        guard let catalog else { return [] }
        return read([]) { try catalog.search(query, limit: limit) }
    }

    func catalogFood(_ hit: CatalogHit) -> Food? {
        guard let catalog else { return nil }
        return read(nil) { try catalog.food(id: hit.id) }
    }

    var recentFoods: [FoodSnapshot] { read([]) { try store.recentFoods(limit: 15) } }

    /// The food behind a snapshot as it is now, for its servings: the person's own food, the catalog's, the recipe's,
    /// or (when it's gone) the snapshot itself.
    func currentFood(for snapshot: FoodSnapshot) -> Food {
        read(snapshot.asFood) {
            if let food = try store.food(id: snapshot.foodID) { return food }
            if let food = try catalog?.food(id: snapshot.foodID) { return food }
            if let id = Recipe.recipeID(fromFoodID: snapshot.foodID), let recipe = try store.recipe(id: id) {
                return recipe.asFood()
            }
            return snapshot.asFood
        }
    }

    /// every serving an entry can be changed to: the food's current ones plus the one it was logged with
    func servingOptions(for snapshot: FoodSnapshot, current: Serving? = nil) -> [Serving] {
        let food = currentFood(for: snapshot)
        var options = food.baseUnit == snapshot.baseUnit ? food.servingOptions : snapshot.asFood.servingOptions
        if let current, !options.contains(current) { options.insert(current, at: 0) }
        return options
    }

    // MARK: changing

    /// runs a change; on failure shows why and returns false
    @discardableResult
    private func change(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            revision += 1
            return true
        } catch let error as ValidationError {
            errorMessage = error.issues.map(\.description).joined(separator: "\n")
        } catch {
            errorMessage = "Couldn't save: \(error)"
        }
        revision += 1
        return false
    }

    @discardableResult
    func log(_ food: Food, portion: Portion, slot: MealSlot, on day: LocalDay? = nil) -> Bool {
        let day = day ?? self.day
        // logged "now" on today; on another day, at the meal's usual time so the order makes sense
        let loggedAt = day == today ? Date() : day.start().addingTimeInterval(slot.usualHour * 3600)
        return change {
            try store.saveEntry(MealEntry(food: food, portion: portion, day: day, slot: slot, loggedAt: loggedAt))
        }
    }

    @discardableResult func saveEntry(_ entry: MealEntry) -> Bool { change { try store.saveEntry(entry) } }
    @discardableResult func deleteEntry(_ id: MealEntryID) -> Bool { change { try store.deleteEntry(id: id) } }
    @discardableResult func saveFood(_ food: Food) -> Bool { change { try store.saveFood(food) } }
    @discardableResult func deleteFood(_ id: FoodID) -> Bool { change { try store.deleteFood(id: id) } }
    @discardableResult func saveGoals(_ goals: NutritionGoals) -> Bool { change { try store.saveGoals(goals) } }
    @discardableResult func saveExercise(_ e: Exercise) -> Bool { change { try store.saveExercise(e) } }
    @discardableResult func saveSession(_ s: WorkoutSession) -> Bool { change { try store.saveSession(s) } }
    @discardableResult func deleteSession(_ id: WorkoutSessionID) -> Bool { change { try store.deleteSession(id: id) } }
    @discardableResult func saveRecipe(_ r: Recipe) -> Bool { change { try store.saveRecipe(r) } }
    @discardableResult func deleteRecipe(_ id: RecipeID) -> Bool { change { try store.deleteRecipe(id: id) } }
}

extension MealSlot {
    /// when this meal usually happens, for entries logged on another day
    var usualHour: Double {
        switch self {
        case .breakfast: 8
        case .lunch: 12.5
        case .dinner: 19
        case .snack: 15.5
        }
    }
}
