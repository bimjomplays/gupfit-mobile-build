import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

final class InMemoryStoreTests: XCTestCase {
    func testFoodsSaveSearchAndDelete() throws {
        let store = InMemoryStore()
        for food in [Sample.apple, Sample.chicken, Sample.bar, Sample.rice] { try store.saveFood(food) }
        XCTAssertEqual(store.searchFoods("ch", limit: 10).map(\.id), ["chicken"])
        XCTAssertEqual(store.searchFoods("", limit: 2).map(\.id), ["apple", "chicken"], "by name, limited")
        XCTAssertEqual(store.searchFoods("acme", limit: 10).map(\.id), ["bar"], "brand matches too")

        var apple = Sample.apple
        apple.name = "Apple, Fuji"
        try store.saveFood(apple)
        XCTAssertEqual(store.food(id: "apple")?.name, "Apple, Fuji", "same id replaces")

        try store.deleteFood(id: "apple")
        XCTAssertNil(store.food(id: "apple"))
        XCTAssertThrowsError(try store.deleteFood(id: "apple")) { error in
            XCTAssertEqual(error as? RepositoryError, .notFound("apple"))
        }
    }

    func testInvalidRecordsAreNotStored() {
        let store = InMemoryStore()
        var bad = Sample.apple
        bad.nutrients[.energy] = -52
        XCTAssertThrowsError(try store.saveFood(bad))
        XCTAssertNil(store.food(id: "apple"))
        XCTAssertThrowsError(try store.saveRecipe(Recipe(name: "x", servings: -1)))
        XCTAssertTrue(store.searchRecipes("").isEmpty)
        let now = Date()
        XCTAssertThrowsError(try store.saveSession(WorkoutSession(startedAt: now, endedAt: now.addingTimeInterval(-1))))
        XCTAssertThrowsError(try store.saveExercise(Exercise(name: "")))
    }

    func testMealLogByDayOutlivesTheFood() throws {
        let store = InMemoryStore()
        try store.saveFood(Sample.chicken)
        let today = Sample.day, yesterday = Sample.day.adding(days: -1)
        try store.saveEntry(MealEntry(id: "a", food: Sample.chicken, portion: Sample.chicken.portion(100, .gram),
                                      day: today, slot: .lunch, loggedAt: Sample.date("2026-11-17T18:00:00Z")))
        try store.saveEntry(MealEntry(id: "b", food: Sample.apple, portion: Sample.apple.portion(100, .gram),
                                      day: yesterday, slot: .snack, loggedAt: Sample.date("2026-11-16T18:00:00Z")))
        try store.saveEntry(MealEntry(id: "c", food: Sample.rice, portion: Sample.rice.portion(100, .gram),
                                      day: today, slot: .lunch, loggedAt: Sample.date("2026-11-17T12:00:00Z")))

        XCTAssertEqual(try store.entries(on: today).map(\.id), ["c", "a"])
        XCTAssertEqual(store.entries(in: yesterday...today).map(\.id), ["b", "c", "a"])
        try store.deleteFood(id: "chicken")
        assertClose(try store.summary(of: today).totals[.energy], 165 + 130, "logged snapshots stay")
        try store.deleteEntry(id: "c")
        assertClose(try store.summary(of: today).totals[.energy], 165)
        XCTAssertEqual(try store.summary(of: today.adding(days: 1)).totals, .zero)
    }

    func testWorkoutsAndRecipes() throws {
        let store = InMemoryStore()
        let squat = Exercise(id: "squat", name: "Squat")
        try store.saveExercise(Exercise(id: "row", name: "barbell row"))
        try store.saveExercise(squat)
        XCTAssertEqual(store.exercises().map(\.name), ["barbell row", "Squat"])

        let start = Sample.date("2026-11-17T17:00:00Z")
        try store.saveSession(WorkoutSession(id: "late", startedAt: start.addingTimeInterval(86_400 * 3)))
        try store.saveSession(WorkoutSession(id: "s1", startedAt: start, exercises: [
            SessionExercise(exercise: squat, sets: [WorkoutSet(reps: 5, weightKg: 120)]),
        ]))
        let week = DateInterval(start: start.addingTimeInterval(-3600), duration: 86_400)
        XCTAssertEqual(store.sessions(in: week).map(\.id), ["s1"])
        assertClose(store.session(id: "s1")?.volumeKg, 600)
        try store.deleteSession(id: "late")
        XCTAssertThrowsError(try store.deleteSession(id: "late"))

        try store.saveRecipe(Recipe(id: "oats", name: "Overnight oats", servings: 1, tags: ["breakfast"]))
        try store.saveRecipe(Recipe(id: "chili", name: "Chili", servings: 6))
        XCTAssertEqual(store.searchRecipes("").map(\.id), ["chili", "oats"])
        XCTAssertEqual(store.searchRecipes("break").map(\.id), ["oats"], "tags match")
        try store.deleteRecipe(id: "oats")
        XCTAssertNil(store.recipe(id: "oats"))
    }

    func testUsableThroughTheProtocols() throws {
        let store = InMemoryStore()
        let foods: any FoodRepository = store
        let log: any MealLogRepository = store
        try foods.saveFood(Sample.bar)
        let bar = try XCTUnwrap(foods.food(id: "bar"))
        try log.saveEntry(MealEntry(food: bar, portion: bar.portion(2, serving: "bar"), day: Sample.day, slot: .snack))
        assertClose(try log.summary(of: Sample.day).totals[.protein], 40)
    }
}
