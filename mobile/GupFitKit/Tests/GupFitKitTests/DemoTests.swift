import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

final class DemoTests: XCTestCase {
    func testDemoStoreIsValidAndAddsUp() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Denver")!
        let store = Demo.store(day: Sample.day, calendar: cal)
        let today = try store.summary(of: Sample.day)
        XCTAssertEqual(today.entries.map(\.id), ["demo-e1", "demo-e2", "demo-e3", "demo-e4"])
        // oats 40 g 152 + banana 120 g 108 + chicken 150 g 247.5 + rice 160 g 208
        assertClose(today.totals[.energy], 715.5)
        XCTAssertEqual(today.totals(for: .dinner), .zero)
        XCTAssertTrue(today.totals.isPartial(.sodium), "banana and rice have no sodium value")

        let day = DateInterval(start: Sample.day.start(in: cal), duration: 86_400)
        let workout = try XCTUnwrap(store.sessions(in: day).first)
        assertClose(workout.volumeKg, 1500, "warm-up left out")
        XCTAssertEqual(workout.day(in: cal), Sample.day)

        let bowl = try XCTUnwrap(store.recipe(id: "demo-r1"))
        assertClose(bowl.perServing[.energy], (990 + 832) / 4)
        XCTAssertEqual(store.exercises().count, 3)
        XCTAssertTrue(Demo.goals.isValid)
    }

    func testTabs() {
        XCTAssertEqual(AppTab.allCases.map(\.title), ["Today", "Workouts", "Recipes", "Chat"])
        XCTAssertEqual(Set(AppTab.allCases.map(\.systemImage)).count, 4)
    }
}
