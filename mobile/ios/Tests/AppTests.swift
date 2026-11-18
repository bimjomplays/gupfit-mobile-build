import XCTest
@testable import GupFit

/// The app's own logic around the screens (GupFitKit's tests run in this bundle too).
@MainActor
final class AppModelTests: XCTestCase {
    func testTodayReadsTheDemoDay() {
        let day = LocalDay(year: 2026, month: 11, day: 17)
        let model = AppModel(today: day)
        XCTAssertEqual(model.tab, .today)
        XCTAssertEqual(model.todaySummary.entries.count, 4)
        XCTAssertEqual(model.todaySummary.totals[.energy] ?? 0, 715.5, accuracy: 1e-9)
        XCTAssertEqual(model.recentWorkouts.map(\.title), ["Legs"])
        XCTAssertEqual(model.recipes.map(\.name), ["Chicken rice bowl"])
    }
}
