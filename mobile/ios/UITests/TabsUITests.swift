import XCTest

/// The app on a fresh database of its own filled with the invented demo data (never the real one).
func launchApp(store: String, reset: Bool = true, demo: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-store-name", store] + (reset ? ["-reset-store"] : []) + (demo ? ["-demo-data"] : [])
    app.launch()
    return app
}

extension XCTestCase {
    func attachShot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

// ci-covers: GupFitApp.swift TodayView.swift WorkoutsView.swift RecipesView.swift Components.swift
final class TabsUITests: XCTestCase {
    @MainActor
    func testEveryTabOpensItsScreen() {
        let app = launchApp(store: "ui-tabs")
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Rolled oats"].waitForExistence(timeout: 5), "the demo day is shown")
        attachShot(app, named: "today")
        for title in ["Workouts", "Recipes", "Chat", "Today"] {
            app.tabBars.buttons[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), title)
            if title != "Today" { attachShot(app, named: title.lowercased()) }
        }
        app.tabBars.buttons["Workouts"].tap()
        XCTAssertTrue(app.staticTexts["Legs"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Recipes"].tap()
        app.staticTexts["Chicken rice bowl"].tap()
        XCTAssertTrue(app.buttons["log-serving"].waitForExistence(timeout: 5))
        attachShot(app, named: "recipe")
    }
}
