import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

final class MealEntryTests: XCTestCase {
    func testEntryKeepsItsSnapshotWhenTheFoodChanges() throws {
        var apple = Sample.apple
        let entry = try MealEntry(food: apple, portion: apple.portion(200, .gram), day: Sample.day, slot: .snack)
        assertClose(entry.nutrients[.energy], 104)

        apple.nutrients[.energy] = 999
        apple.name = "Renamed"
        XCTAssertEqual(entry.food.name, "Apple, raw")
        assertClose(entry.nutrients[.energy], 104, "the logged day doesn't change")

        // a new portion rescales the logged snapshot, not today's food
        var edited = entry
        edited.portion = try Sample.apple.portion(100, .gram)
        assertClose(edited.nutrients[.energy], 52)
    }

    func testInvalidEntriesThrow() {
        XCTAssertThrowsError(try MealEntry(food: Sample.apple, portion: Portion(-2, .standard(.gram)), day: Sample.day,
                                           slot: .lunch)) { error in
            XCTAssertEqual((error as? ValidationError)?.issues, [ValidationIssue(field: "portion.count", problem: .negative)])
        }
        var broken = Sample.apple
        broken.nutrients[.fat] = -1
        XCTAssertThrowsError(try MealEntry(food: broken, portion: Portion(1, .standard(.gram)), day: Sample.day,
                                           slot: .lunch))
    }

    func testEntryJSONRoundTrip() throws {
        let entry = try MealEntry(id: "e1", food: Sample.milk, portion: Sample.milk.portion(1, serving: "glass"),
                                  day: Sample.day, slot: .breakfast, loggedAt: Sample.date("2026-11-17T07:30:00Z"),
                                  note: "with coffee")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let data = try enc.encode(entry)
        XCTAssertEqual(try dec.decode(MealEntry.self, from: data), entry)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["day"] as? String, "2026-11-17")
        XCTAssertEqual(object["id"] as? String, "e1")
    }
}

final class DaySummaryTests: XCTestCase {
    func entries() throws -> [MealEntry] {
        [
            try MealEntry(id: "1", food: Sample.milk, portion: Sample.milk.portion(1, serving: "glass"), day: Sample.day,
                          slot: .breakfast, loggedAt: Sample.date("2026-11-17T07:00:00Z")),
            try MealEntry(id: "2", food: Sample.chicken, portion: Sample.chicken.portion(150, .gram), day: Sample.day,
                          slot: .lunch, loggedAt: Sample.date("2026-11-17T12:00:00Z")),
            try MealEntry(id: "3", food: Sample.rice, portion: Sample.rice.portion(200, .gram), day: Sample.day,
                          slot: .lunch, loggedAt: Sample.date("2026-11-17T12:01:00Z")),
            try MealEntry(id: "4", food: Sample.apple, portion: Sample.apple.portion(1, serving: "1 medium"),
                          day: Sample.day, slot: .snack, loggedAt: Sample.date("2026-11-17T09:00:00Z")),
            // another day: left out
            try MealEntry(id: "5", food: Sample.bar, portion: Sample.bar.portion(1, serving: "bar"),
                          day: Sample.day.adding(days: 1), slot: .snack),
        ]
    }

    func testDayAndMealTotals() throws {
        let s = DaySummary(day: Sample.day, entries: try entries())
        XCTAssertEqual(s.entries.map(\.id), ["1", "4", "2", "3"], "in the order they were logged")
        // milk 250 ml: 125 kcal; chicken 150 g: 247.5; rice 200 g: 260; apple 182 g: 94.64
        assertClose(s.totals[.energy], 125 + 247.5 + 260 + 94.64)
        assertClose(s.totals[.protein], 8.25 + 46.5 + 5.4 + 0.546)
        assertClose(s.totals[.fiber], 0 + 0.8 + 2.4 * 1.82)
        XCTAssertTrue(s.totals.isPartial(.fiber), "milk has no fiber value")
        XCTAssertFalse(s.totals.isPartial(.protein))

        let lunch = s.totals(for: .lunch)
        assertClose(lunch[.energy], 507.5)
        assertClose(lunch[.carbohydrate], 56)
        XCTAssertFalse(lunch.isPartial(.fiber), "chicken's zero and rice's 0.4 are both known")
        XCTAssertEqual(s.totals(for: .dinner), .zero)
        XCTAssertEqual(s.entries(in: .lunch).count, 2)
    }

    func testGoals() throws {
        let s = DaySummary(day: Sample.day, entries: try entries())
        let goals = NutritionGoals(energy: 2000, protein: 150)
        let left = goals.remaining(after: s.totals)
        assertClose(left[.energy], 2000 - 727.14)
        assertClose(left[.protein], 150 - 60.696)
        XCTAssertNil(left[.fat], "no fat target set")
        assertClose(goals.progress(.energy, totals: s.totals), 727.14 / 2000)
        XCTAssertTrue(goals.isValid)
        XCTAssertFalse(NutritionGoals(energy: -5).isValid)
    }
}

final class LocalDayTests: XCTestCase {
    func testDayDependsOnTheTimeZone() {
        let late = Sample.date("2026-11-18T05:30:00Z")  // 10:30 pm on the 17th in Denver
        var denver = Calendar(identifier: .gregorian)
        denver.timeZone = TimeZone(identifier: "America/Denver")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(LocalDay(late, calendar: denver), Sample.day)
        XCTAssertEqual(LocalDay(late, calendar: utc), LocalDay(year: 2026, month: 11, day: 18))
        XCTAssertEqual(LocalDay(Sample.day.start(in: denver), calendar: denver), Sample.day)
    }

    func testParsingAndArithmetic() {
        XCTAssertEqual(LocalDay("2026-11-17"), Sample.day)
        XCTAssertEqual(Sample.day.description, "2026-11-17")
        XCTAssertNil(LocalDay("2026-02-30"), "no such day")
        XCTAssertNil(LocalDay("2026-1-17"))
        XCTAssertNil(LocalDay("yesterday"))
        XCTAssertEqual(LocalDay(year: 2026, month: 12, day: 31).adding(days: 1), LocalDay(year: 2027, month: 1, day: 1))
        XCTAssertEqual(LocalDay(year: 2028, month: 3, day: 1).adding(days: -1), LocalDay(year: 2028, month: 2, day: 29))
        XCTAssertLessThan(LocalDay(year: 2026, month: 9, day: 30), LocalDay(year: 2026, month: 10, day: 1))
        XCTAssertThrowsError(try JSONDecoder().decode([LocalDay].self, from: Data(#"["2026-13-01"]"#.utf8)))
    }
}
