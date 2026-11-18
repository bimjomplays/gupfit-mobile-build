import XCTest

// ci-covers: FoodPicker.swift TodayView.swift WorkoutsView.swift RecipesView.swift AppModel.swift
/// Logging by hand end to end, on databases of their own: a catalog food that survives a restart, a workout, and a
/// recipe made from foods and logged.
final class LoggingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func first(_ query: XCUIElementQuery, beginningWith prefix: String) -> XCUIElement {
        query.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    func testLogACatalogFoodAndItSurvivesARestart() {
        var app = launchApp(store: "ui-log", demo: false)
        XCTAssertTrue(app.buttons["add-lunch"].waitForExistence(timeout: 10))
        app.buttons["add-lunch"].tap()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("banana raw")
        let banana = first(app.staticTexts, beginningWith: "Bananas")
        XCTAssertTrue(banana.waitForExistence(timeout: 5), "the USDA catalog finds it")
        attachShot(app, named: "food-search")
        banana.tap()

        XCTAssertTrue(app.buttons["portion-confirm"].waitForExistence(timeout: 5))
        attachShot(app, named: "portion")
        app.buttons["portion-confirm"].tap()
        XCTAssertTrue(first(app.staticTexts, beginningWith: "Bananas").waitForExistence(timeout: 5), "logged to lunch")

        app.terminate()
        app = launchApp(store: "ui-log", reset: false, demo: false)
        XCTAssertTrue(first(app.staticTexts, beginningWith: "Bananas").waitForExistence(timeout: 10),
                      "still there after a restart")
        attachShot(app, named: "after-restart")
    }

    @MainActor
    func testLogAWorkout() {
        let app = launchApp(store: "ui-workout")
        app.tabBars.buttons["Workouts"].tap()
        app.buttons["new-workout"].tap()
        let title = app.textFields["workout-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.buttons["add-exercise"].tap()
        let squat = app.buttons["pick-exercise-Back squat"]
        XCTAssertTrue(squat.waitForExistence(timeout: 5))
        squat.tap()

        let reps = app.textFields["reps"].firstMatch
        XCTAssertTrue(reps.waitForExistence(timeout: 5))
        reps.tap()
        reps.typeText("5")
        let weight = app.textFields["lb"].firstMatch
        weight.tap()
        weight.typeText("225")
        app.buttons["Add set"].tap()
        attachShot(app, named: "workout-editor")
        app.buttons["workout-save"].tap()

        XCTAssertTrue(app.staticTexts["Workout"].waitForExistence(timeout: 5), "the new workout is listed")
        XCTAssertTrue(first(app.staticTexts, beginningWith: "Back squat").exists)
    }

    @MainActor
    func testCreateARecipeAndLogAServing() {
        let app = launchApp(store: "ui-recipe")
        app.tabBars.buttons["Recipes"].tap()
        app.buttons["new-recipe"].tap()
        let name = app.textFields["recipe-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Oat bowl")

        app.buttons["add-ingredient"].tap()
        // listed under Recent and My foods: either is the same food
        let oats = app.staticTexts["Rolled oats"].firstMatch
        XCTAssertTrue(oats.waitForExistence(timeout: 5), "my foods are listed")
        oats.tap()
        XCTAssertTrue(app.buttons["portion-confirm"].waitForExistence(timeout: 5))
        app.buttons["portion-confirm"].tap()
        XCTAssertTrue(app.staticTexts["Rolled oats"].firstMatch.waitForExistence(timeout: 5), "added as an ingredient")
        attachShot(app, named: "recipe-editor")
        app.buttons["recipe-save"].tap()

        let bowl = app.staticTexts["Oat bowl"]
        XCTAssertTrue(bowl.waitForExistence(timeout: 5))
        bowl.tap()
        app.buttons["log-serving"].tap()
        XCTAssertTrue(app.buttons["portion-confirm"].waitForExistence(timeout: 5))
        app.buttons["portion-confirm"].tap()
        XCTAssertTrue(app.staticTexts["Logged to today"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.staticTexts["Oat bowl"].firstMatch.waitForExistence(timeout: 5), "the serving is on today")
    }
}
