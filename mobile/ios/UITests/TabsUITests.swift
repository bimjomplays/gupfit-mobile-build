import XCTest

// ci-covers: GupFitApp.swift TodayView.swift PlaceholderViews.swift
final class TabsUITests: XCTestCase {
    @MainActor
    func testEveryTabOpensItsScreen() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        attachShot(app, named: "today")
        for title in ["Workouts", "Recipes", "Chat", "Today"] {
            app.tabBars.buttons[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), title)
            if title != "Today" { attachShot(app, named: title.lowercased()) }
        }
    }

    private func attachShot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
