import XCTest

// ci-covers: GupFitApp.swift TodayView.swift PlaceholderViews.swift
final class TabsUITests: XCTestCase {
    @MainActor
    func testEveryTabOpensItsScreen() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        for title in ["Workouts", "Recipes", "Chat", "Today"] {
            app.tabBars.buttons[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), title)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "today"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
