import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

/// A fresh folder per test, removed afterwards.
final class TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("gupfit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var database: URL { url.appendingPathComponent("gupfit.sqlite") }
    var backups: URL { url.appendingPathComponent("Backups") }
}

final class SQLiteStoreTests: XCTestCase {
    private var temp: TempFolder!

    override func setUpWithError() throws { temp = try TempFolder() }
    override func tearDown() { temp = nil }

    private func open() throws -> SQLiteStore { try SQLiteStore(url: temp.database) }

    func testContract() throws {
        var n = 0
        try StoreContract.all {
            n += 1
            return try SQLiteStore(url: temp.url.appendingPathComponent("contract-\(n).sqlite"))
        }
    }

    /// Demo data plus the awkward cases (unknown vs zero nutrients, empty optionals, an unfinished workout).
    private func fill(_ store: SQLiteStore) throws -> InMemoryStore {
        let demo = Demo.store(day: Sample.day)
        let all = Demo.foods + [Sample.apple, Sample.bar, Sample.milk]
        for f in all { try store.saveFood(f); try demo.saveFood(f) }
        for e in demo.exercises() { try store.saveExercise(e) }
        for e in demo.entries(in: Sample.day.adding(days: -7)...Sample.day) { try store.saveEntry(e) }
        let extraEntry = try MealEntry(id: "x1", food: Sample.bar, portion: Sample.bar.portion(0.5, serving: "bar"),
                                       day: Sample.day.adding(days: -1), slot: .snack,
                                       loggedAt: Date(timeIntervalSinceReferenceDate: 815_000_000.123456), note: "half")
        try store.saveEntry(extraEntry)
        try demo.saveEntry(extraEntry)
        let week = DateInterval(start: Sample.day.adding(days: -7).start(), end: Sample.day.adding(days: 2).start())
        var sessions = demo.sessions(in: week)
        sessions.append(WorkoutSession(id: "open", title: "Run + core", startedAt: Sample.day.start().addingTimeInterval(3600.5),
                                       exercises: [
                                           SessionExercise(exercise: Demo.run, sets: [
                                               WorkoutSet(duration: 1800, distanceMeters: 5000, rpe: 7.5),
                                           ], notes: "easy"),
                                           SessionExercise(exercise: Exercise(id: "plank", name: "Plank", kind: .timed), sets: [
                                               WorkoutSet(duration: 60, isCompleted: false), WorkoutSet(duration: 45),
                                           ]),
                                       ], notes: nil))
        for s in sessions { try store.saveSession(s); try demo.saveSession(s) }
        for r in demo.searchRecipes("") { try store.saveRecipe(r) }
        let soup = Recipe(id: "soup", name: "Soup", servings: 2.5, ingredients: [
            RecipeIngredient(food: Sample.milk, portion: try Sample.milk.portion(2, serving: "glass"), note: "warm"),
        ], notes: "freezes well", cookedWeightGrams: 700, tags: [])
        try store.saveRecipe(soup)
        try demo.saveRecipe(soup)
        try store.saveGoals(NutritionGoals(energy: 2000, protein: 140))
        try demo.saveGoals(NutritionGoals(energy: 2000, protein: 140))
        return demo
    }

    private func assertSame(_ store: SQLiteStore, _ expected: InMemoryStore, file: StaticString = #filePath,
                            line: UInt = #line) throws {
        XCTAssertEqual(try store.searchFoods("", limit: 100), expected.searchFoods("", limit: 100), file: file, line: line)
        let days = Sample.day.adding(days: -7)...Sample.day
        XCTAssertEqual(try store.entries(in: days), expected.entries(in: days), file: file, line: line)
        XCTAssertEqual(try store.exercises(), expected.exercises(), file: file, line: line)
        let all = DateInterval(start: .distantPast, end: .distantFuture)
        XCTAssertEqual(try store.sessions(in: all), expected.sessions(in: all), file: file, line: line)
        XCTAssertEqual(try store.searchRecipes(""), expected.searchRecipes(""), file: file, line: line)
        XCTAssertEqual(try store.goals(or: .init()), try expected.goals(or: .init()), file: file, line: line)
    }

    func testEverythingSurvivesARestart() throws {
        var store: SQLiteStore? = try open()
        let expected = try fill(store!)
        try assertSame(store!, expected)
        store?.close()
        store = nil

        let reopened = try open()
        try assertSame(reopened, expected)
        XCTAssertEqual(reopened.schemaVersion, PhoneSchema.version)
        let soup = try XCTUnwrap(reopened.recipe(id: "soup"))
        assertClose(soup.perServing[.energy], 500 * 0.5 / 2.5)
        XCTAssertNil(soup.perServing[.fiber], "unknown stays unknown")
        XCTAssertEqual(try reopened.food(id: "demo-chicken")?.nutrients[.fiber], 0, "a real zero stays zero")
        XCTAssertNil(try reopened.session(id: "open")?.endedAt)
        XCTAssertEqual(try reopened.session(id: "open")?.exercises.map { $0.sets.count }, [1, 2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.backups.path), "a new database needs no backup")
    }

    func testSnapshotsSurviveFoodEditsDeletesAndRestarts() throws {
        var store: SQLiteStore? = try open()
        try store!.saveFood(Sample.chicken)
        try store!.saveEntry(MealEntry(id: "lunch", food: Sample.chicken, portion: Sample.chicken.portion(200, .gram),
                                       day: Sample.day, slot: .lunch))
        try store!.saveRecipe(Recipe(id: "bowl", name: "Bowl", servings: 2, ingredients: [
            RecipeIngredient(food: Sample.chicken, portion: try Sample.chicken.portion(400, .gram)),
        ]))
        var changed = Sample.chicken
        changed.name = "Chicken thigh"
        changed.nutrients[.energy] = 209
        try store!.saveFood(changed)
        store?.close()
        store = nil

        var reopened: SQLiteStore? = try open()
        assertClose(try reopened!.summary(of: Sample.day).totals[.energy], 330, "the day keeps the logged numbers")
        XCTAssertEqual(try reopened!.entry(id: "lunch")?.food.name, "Chicken breast, cooked")
        assertClose(try reopened!.recipe(id: "bowl")?.perServing[.energy], 330)
        XCTAssertEqual(try reopened!.food(id: "chicken")?.nutrients[.energy], 209, "the food itself changed")
        try reopened!.deleteFood(id: "chicken")
        reopened?.close()
        reopened = nil

        let again = try open()
        assertClose(try again.summary(of: Sample.day).totals[.energy], 330)
        XCTAssertEqual(try again.recipe(id: "bowl")?.ingredients.first?.food, Sample.chicken.snapshot)
        let refreshed = try XCTUnwrap(again.recipe(id: "bowl")).refreshed(with: [changed.id: changed])
        assertClose(refreshed.perServing[.energy], 418, "refreshing takes newer numbers only when asked")
    }

    func testResavingASessionReplacesItsExercisesAndSets() throws {
        let store = try open()
        var session = WorkoutSession(id: "s", startedAt: Sample.date("2026-11-17T17:00:00Z"), exercises: [
            SessionExercise(exercise: Demo.squat, sets: [WorkoutSet(reps: 5, weightKg: 100), WorkoutSet(reps: 5, weightKg: 100)]),
            SessionExercise(exercise: Demo.bench, sets: [WorkoutSet(reps: 8, weightKg: 60)]),
        ])
        try store.saveSession(session)
        session.exercises.remove(at: 0)
        session.exercises[0].sets.append(WorkoutSet(reps: 6, weightKg: 62.5))
        session.endedAt = session.startedAt.addingTimeInterval(3000)
        try store.saveSession(session)
        XCTAssertEqual(try store.session(id: "s"), session)
        try store.deleteSession(id: "s")
        store.close()

        let raw = try SQLiteDatabase(path: temp.database.path)
        for table in ["workout_sessions", "session_exercises", "workout_sets"] {
            XCTAssertEqual(try raw.scalar("SELECT count(*) FROM \(table)"), .integer(0), "\(table) left rows behind")
        }
    }

    func testDatabaseSettings() throws {
        let store = try open()
        try store.saveFood(Sample.apple)
        store.close()
        let raw = try SQLiteDatabase(path: temp.database.path)
        XCTAssertEqual(try raw.scalar("PRAGMA journal_mode"), .text("wal"), "WAL stays set on the file")
        XCTAssertEqual(try raw.userVersion, PhoneSchema.version)
        XCTAssertEqual(try raw.scalar("PRAGMA integrity_check"), .text("ok"))
    }

    func testAnUnreadableRowIsAnErrorNotASilentGap() throws {
        let store = try open()
        try store.saveFood(Sample.apple)
        store.close()
        let raw = try SQLiteDatabase(path: temp.database.path)
        try raw.run("UPDATE foods SET nutrients = 'not json' WHERE id = 'apple'")
        raw.close()
        let reopened = try open()
        XCTAssertThrowsError(try reopened.searchFoods("", limit: 10)) { error in
            guard case .unreadable(let table, let id, _)? = error as? StoreError else { return XCTFail("\(error)") }
            XCTAssertEqual(table, "foods")
            XCTAssertEqual(id, "apple")
        }
    }

    func testConcurrentWritersAllLand() throws {
        let store = try open()
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            let food = Food(id: FoodID("f\(i)"), name: "Food \(i)", nutrients: NutrientProfile([.energy: Double(i)]))
            do { try store.saveFood(food) } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(try store.searchFoods("food", limit: 100).count, 40)
    }
}
