import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

/// What every GupFitStore must do, run against InMemoryStore and SQLiteStore alike (free functions rather than a
/// shared base class, so Linux's test discovery finds every test).
enum StoreContract {
    static func all(_ make: () throws -> any GupFitStore) throws {
        try foods(make())
        try invalidRecordsAreNotStored(make())
        try mealLog(make())
        try workoutsAndRecipes(make())
        try settings(make())
        try transactions(make())
    }

    static func foods(_ store: any GupFitStore) throws {
        for food in [Sample.apple, Sample.chicken, Sample.bar, Sample.rice, Sample.milk] { try store.saveFood(food) }
        XCTAssertEqual(try store.searchFoods("ch", limit: 10).map(\.id), ["chicken"])
        XCTAssertEqual(try store.searchFoods("", limit: 2).map(\.id), ["apple", "chicken"], "by name, limited")
        XCTAssertEqual(try store.searchFoods("acme", limit: 10).map(\.id), ["bar"], "brand matches too")
        XCTAssertEqual(try store.searchFoods("RICE, wh", limit: 10).map(\.id), ["rice"], "case and commas ignored")
        XCTAssertEqual(try store.searchFoods("100%_", limit: 10).map(\.id), [], "LIKE wildcards are plain text")
        XCTAssertEqual(try store.food(id: "milk"), Sample.milk, "reads back exactly")

        var apple = Sample.apple
        apple.name = "Apple, Fuji"
        try store.saveFood(apple)
        XCTAssertEqual(try store.food(id: "apple")?.name, "Apple, Fuji", "same id replaces")
        XCTAssertEqual(try store.searchFoods("fuji", limit: 10).map(\.id), ["apple"], "search follows the new name")

        try store.deleteFood(id: "apple")
        XCTAssertNil(try store.food(id: "apple"))
        XCTAssertThrowsError(try store.deleteFood(id: "apple")) { error in
            XCTAssertEqual(error as? RepositoryError, .notFound("apple"))
        }
    }

    static func invalidRecordsAreNotStored(_ store: any GupFitStore) throws {
        var bad = Sample.apple
        bad.nutrients[.energy] = -52
        XCTAssertThrowsError(try store.saveFood(bad))
        XCTAssertNil(try store.food(id: "apple"))
        XCTAssertThrowsError(try store.saveRecipe(Recipe(name: "x", servings: -1)))
        XCTAssertTrue(try store.searchRecipes("").isEmpty)
        let now = Date()
        XCTAssertThrowsError(try store.saveSession(WorkoutSession(startedAt: now, endedAt: now.addingTimeInterval(-1))))
        XCTAssertThrowsError(try store.saveExercise(Exercise(name: "")))
        XCTAssertThrowsError(try store.saveGoals(NutritionGoals(energy: -1)))

        // a failed save leaves the record that was there
        try store.saveFood(Sample.chicken)
        var worse = Sample.chicken
        worse.name = " "
        XCTAssertThrowsError(try store.saveFood(worse))
        XCTAssertEqual(try store.food(id: "chicken"), Sample.chicken)
    }

    static func mealLog(_ store: any GupFitStore) throws {
        try store.saveFood(Sample.chicken)
        let today = Sample.day, yesterday = Sample.day.adding(days: -1)
        try store.saveEntry(MealEntry(id: "a", food: Sample.chicken, portion: Sample.chicken.portion(100, .gram),
                                      day: today, slot: .lunch, loggedAt: Sample.date("2026-11-17T18:00:00Z")))
        try store.saveEntry(MealEntry(id: "b", food: Sample.apple, portion: Sample.apple.portion(1, serving: "1 medium"),
                                      day: yesterday, slot: .snack, loggedAt: Sample.date("2026-11-16T18:00:00Z"),
                                      note: "with peanut butter"))
        try store.saveEntry(MealEntry(id: "c", food: Sample.rice, portion: Sample.rice.portion(100, .gram),
                                      day: today, slot: .lunch, loggedAt: Sample.date("2026-11-17T12:00:00Z")))

        XCTAssertEqual(try store.entries(on: today).map(\.id), ["c", "a"])
        XCTAssertEqual(try store.entries(in: yesterday...today).map(\.id), ["b", "c", "a"])
        XCTAssertEqual(try store.entry(id: "b")?.note, "with peanut butter")
        XCTAssertEqual(try store.recentFoods(limit: 2).map(\.foodID), ["chicken", "rice"])

        try store.deleteFood(id: "chicken")
        assertClose(try store.summary(of: today).totals[.energy], 165 + 130, "logged snapshots stay")

        // editing an entry: another portion and meal, same snapshot
        var entry = try XCTUnwrap(store.entry(id: "c"))
        entry.portion = Portion(entry.portion.count * 1.5, entry.portion.serving)
        entry.slot = .dinner
        try store.saveEntry(entry)
        XCTAssertEqual(try store.entry(id: "c"), entry)
        assertClose(try store.summary(of: today).totals(for: .dinner)[.energy], 195)

        try store.deleteEntry(id: "c")
        assertClose(try store.summary(of: today).totals[.energy], 165)
        XCTAssertThrowsError(try store.deleteEntry(id: "c"))
        XCTAssertEqual(try store.summary(of: today.adding(days: 1)).totals, .zero)
    }

    static func workoutsAndRecipes(_ store: any GupFitStore) throws {
        let squat = Exercise(id: "squat", name: "Squat")
        try store.saveExercise(Exercise(id: "row", name: "barbell row"))
        try store.saveExercise(squat)
        XCTAssertEqual(try store.exercises().map(\.name), ["barbell row", "Squat"])

        let start = Sample.date("2026-11-17T17:00:00Z")
        try store.saveSession(WorkoutSession(id: "late", startedAt: start.addingTimeInterval(86_400 * 3)))
        try store.saveSession(WorkoutSession(id: "s1", startedAt: start, exercises: [
            SessionExercise(exercise: squat, sets: [WorkoutSet(reps: 5, weightKg: 120)]),
        ]))
        let week = DateInterval(start: start.addingTimeInterval(-3600), duration: 86_400)
        XCTAssertEqual(try store.sessions(in: week).map(\.id), ["s1"])
        assertClose(try store.session(id: "s1")?.volumeKg, 600)
        XCTAssertEqual(try store.sessions(in: DateInterval(start: start, duration: 0)).map(\.id), ["s1"],
                       "an interval includes its start")

        // the library entry can go; the session keeps the exercise as it was
        try store.deleteExercise(id: "squat")
        XCTAssertEqual(try store.session(id: "s1")?.exercises.first?.name, "Squat")
        try store.deleteSession(id: "late")
        XCTAssertThrowsError(try store.deleteSession(id: "late"))

        try store.saveRecipe(Recipe(id: "oats", name: "Overnight oats", servings: 1, tags: ["breakfast"]))
        try store.saveRecipe(Recipe(id: "chili", name: "Chili", servings: 6))
        XCTAssertEqual(try store.searchRecipes("").map(\.id), ["chili", "oats"])
        XCTAssertEqual(try store.searchRecipes("break").map(\.id), ["oats"], "tags match")
        try store.deleteRecipe(id: "oats")
        XCTAssertNil(try store.recipe(id: "oats"))
        XCTAssertThrowsError(try store.deleteRecipe(id: "oats"))
    }

    static func settings(_ store: any GupFitStore) throws {
        XCTAssertEqual(try store.goals(or: Demo.goals), Demo.goals, "nothing saved yet")
        let goals = NutritionGoals(energy: 1900, protein: 150)
        try store.saveGoals(goals)
        XCTAssertEqual(try store.goals(or: Demo.goals), goals)
        try store.saveGoals(Demo.goals)
        XCTAssertEqual(try store.goals(or: goals), Demo.goals, "replaced")
    }

    struct Boom: Error {}

    static func transactions(_ store: any GupFitStore) throws {
        XCTAssertThrowsError(try store.transaction {
            try store.saveFood(Sample.apple)
            try store.saveEntry(MealEntry(id: "t1", food: Sample.apple, portion: Sample.apple.portion(100, .gram),
                                          day: Sample.day, slot: .snack))
            throw Boom()
        })
        XCTAssertNil(try store.food(id: "apple"), "rolled back")
        XCTAssertNil(try store.entry(id: "t1"), "rolled back")

        try store.transaction {
            try store.saveFood(Sample.apple)
            // an inner part that fails and is caught undoes only itself
            try? store.transaction {
                try store.saveFood(Sample.rice)
                throw Boom()
            }
            try store.saveFood(Sample.milk)
        }
        XCTAssertNotNil(try store.food(id: "apple"))
        XCTAssertNil(try store.food(id: "rice"))
        XCTAssertNotNil(try store.food(id: "milk"))
        XCTAssertEqual(try store.transaction { try store.searchFoods("", limit: 10).count }, 2, "returns its value")
    }
}

final class InMemoryStoreContractTests: XCTestCase {
    func testContract() throws { try StoreContract.all { InMemoryStore() } }
}
