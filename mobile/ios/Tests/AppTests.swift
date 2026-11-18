import XCTest
@testable import GupFit

/// The app's own logic around the screens (GupFitKit's tests run in this bundle too).
@MainActor
final class AppModelTests: XCTestCase {
    private let day = LocalDay(year: 2026, month: 11, day: 17)

    private func demoModel() -> AppModel {
        AppModel(store: Demo.store(day: day), catalog: nil, today: day)
    }

    func testTodayReadsTheDemoDay() {
        let model = demoModel()
        XCTAssertEqual(model.tab, .today)
        XCTAssertEqual(model.todaySummary.entries.count, 4)
        XCTAssertEqual(model.todaySummary.totals[.energy] ?? 0, 715.5, accuracy: 1e-9)
        XCTAssertEqual(model.recentWorkouts.map(\.title), ["Legs", "Push"], "newest first")
        XCTAssertEqual(model.recipes.map(\.name), ["Chicken rice bowl"])
        XCTAssertEqual(model.goals, Demo.goals)
    }

    func testLogEditAndDeleteChangeTheDay() throws {
        let model = demoModel()
        let before = model.revision
        XCTAssertTrue(model.log(Demo.yogurt, portion: try Demo.yogurt.portion(1, serving: "1 cup"), slot: .dinner))
        XCTAssertGreaterThan(model.revision, before, "the screens redraw")
        let dinner = model.daySummary.entries(in: .dinner)
        XCTAssertEqual(dinner.map(\.food.name), ["Greek yogurt, plain"])
        XCTAssertEqual(model.daySummary.totals(for: .dinner)[.energy] ?? 0, 135, accuracy: 1e-9)

        var entry = try XCTUnwrap(dinner.first)
        entry.portion = Portion(2, entry.portion.serving)
        XCTAssertTrue(model.saveEntry(entry))
        XCTAssertEqual(model.daySummary.totals(for: .dinner)[.energy] ?? 0, 270, accuracy: 1e-9)
        XCTAssertTrue(model.deleteEntry(entry.id))
        XCTAssertTrue(model.daySummary.entries(in: .dinner).isEmpty)

        // logging on another day puts it there, at the meal's usual time
        model.day = day.adding(days: -1)
        XCTAssertTrue(model.log(Demo.banana, portion: try Demo.banana.portion(1, serving: "1 medium"), slot: .breakfast))
        XCTAssertEqual(model.summary(of: day.adding(days: -1)).entries.count, 1)
        XCTAssertEqual(model.todaySummary.entries.count, 4)
    }

    func testAFailedSaveSaysWhyAndChangesNothing() {
        let model = demoModel()
        XCTAssertFalse(model.saveRecipe(Recipe(name: " ", servings: 0)))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.recipes.count, 1)
        model.errorMessage = nil
        XCTAssertFalse(model.deleteEntry("no-such-entry"))
        XCTAssertNotNil(model.errorMessage)
    }

    func testGoalsAreSaved() {
        let model = demoModel()
        XCTAssertTrue(model.saveGoals(NutritionGoals(energy: 1800, protein: 140)))
        XCTAssertEqual(model.goals, NutritionGoals(energy: 1800, protein: 140))
    }

    func testCurrentFoodPrefersTheLiveFood() throws {
        let model = demoModel()
        let entry = try XCTUnwrap(model.todaySummary.entries.first { $0.food.foodID == Demo.oats.id })
        XCTAssertEqual(model.currentFood(for: entry.food).servings, Demo.oats.servings)
        XCTAssertTrue(model.deleteFood(Demo.oats.id))
        let gone = model.currentFood(for: entry.food)
        XCTAssertEqual(gone.snapshot, entry.food, "a deleted food falls back to the snapshot")
        XCTAssertTrue(model.servingOptions(for: entry.food, current: entry.portion.serving).contains(entry.portion.serving))
    }

    func testLaunchOptions() {
        XCTAssertEqual(LaunchOptions(arguments: ["GupFit"]).storeName, nil)
        let demo = LaunchOptions(arguments: ["GupFit", "-store-name", "ui-demo", "-reset-store", "-demo-data"])
        XCTAssertEqual(demo.storeName, "ui-demo")
        XCTAssertTrue(demo.reset)
        XCTAssertTrue(demo.demoData)
        let real = LaunchOptions(arguments: ["GupFit", "-reset-store", "-demo-data"])
        XCTAssertFalse(real.reset, "the real database is never reset")
        XCTAssertFalse(real.demoData)
        XCTAssertEqual(LaunchOptions(arguments: ["-store-name", "../../Documents"]).storeName, "Documents")
    }

    func testADemoLaunchOpensItsOwnSeededDatabase() throws {
        guard case .ready(let model) = AppLaunch.start(arguments: ["-store-name", "unit-demo", "-reset-store", "-demo-data"]) else {
            return XCTFail("didn't open")
        }
        let store = try XCTUnwrap(model.store as? SQLiteStore)
        XCTAssertTrue(store.url.path.contains("/Caches/unit-demo/"), store.url.path)
        XCTAssertEqual(model.recipes.map(\.name), ["Chicken rice bowl"])
        XCTAssertEqual(model.todaySummary.entries.count, 4)
        store.close()
    }

    func testTheAppBundlesTheFoodCatalog() throws {
        let catalog = try XCTUnwrap(FoodCatalog.bundled(), "catalog.sqlite missing from the app bundle")
        XCTAssertFalse(try catalog.search("banana", limit: 1).isEmpty)
    }
}
