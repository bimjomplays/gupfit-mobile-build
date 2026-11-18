import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

/// Against the real bundled catalog: data/catalog.sqlite in the repo (Linux) or the app's copy (the iOS test host).
final class FoodCatalogTests: XCTestCase {
    private func catalog() throws -> FoodCatalog {
        if let bundled = FoodCatalog.bundled() { return bundled }
        let repoCopy = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // GupFitKitTests
            .appendingPathComponent("../../../../data/catalog.sqlite").standardizedFileURL
        guard FileManager.default.fileExists(atPath: repoCopy.path) else {
            throw XCTSkip("no catalog.sqlite at \(repoCopy.path) or in the bundle")
        }
        return try FoodCatalog(path: repoCopy.path)
    }

    func testSearchRanksTheFoodItselfFirst() throws {
        let c = try catalog()
        let bananas = try c.search("banana", limit: 5)
        XCTAssertTrue(bananas.first?.name.hasPrefix("Bananas") == true, "\(bananas.map(\.name))")
        XCTAssertTrue(bananas.allSatisfy { $0.kcalPer100g != nil })

        let chicken = try c.search("chick bre", limit: 10)
        XCTAssertFalse(chicken.isEmpty)
        XCTAssertTrue(chicken.allSatisfy { $0.name.lowercased().contains("chick") && $0.name.lowercased().contains("bre") })

        let eggs = try c.search("egg", limit: 3).map(\.name)
        XCTAssertTrue(eggs.allSatisfy { $0.hasPrefix("Egg,") || $0.hasPrefix("Eggs,") }, "\(eggs)")
        XCTAssertEqual(try c.search("banana", limit: 3), try c.search("  BANANA!! ", limit: 3), "case and punctuation")
    }

    func testTypedTextNeverBecomesQuerySyntax() throws {
        let c = try catalog()
        for q in ["\"", "*", "a OR b", "NEAR(x y)", "') DROP TABLE foods; --", "", "   ", "-", "^milk"] {
            XCTAssertNoThrow(try c.search(q), q)
        }
        XCTAssertTrue(try c.search("").isEmpty)
        XCTAssertFalse(try c.search("^milk").isEmpty, "punctuation is dropped, the word stays")
        XCTAssertTrue(try c.search("zzqxj").isEmpty)
    }

    func testAFoodHasNutrientsPerHundredGramsAndPortions() throws {
        let c = try catalog()
        let hit = try XCTUnwrap(c.search("bananas raw", limit: 1).first)
        let banana = try XCTUnwrap(c.food(id: hit.id))
        XCTAssertEqual(banana.id, hit.foodID)
        XCTAssertEqual(FoodCatalog.catalogID(banana.id), hit.id)
        XCTAssertEqual(try c.food(id: banana.id), banana)
        XCTAssertEqual(banana.baseUnit, .gram)
        XCTAssertEqual(banana.referenceAmount, 100)
        XCTAssertEqual(banana.nutrients[.energy], hit.kcalPer100g)
        XCTAssertNil(banana.nutrients[.alcohol], "not in the catalog: unknown, not zero")
        XCTAssertFalse(banana.servings.isEmpty, "USDA portions")
        XCTAssertTrue(banana.isValid)

        // a portion's nutrients follow its gram weight
        let serving = banana.servings[0]
        let entry = try MealEntry(food: banana, portion: banana.portion(2, serving: serving.label), day: Sample.day,
                                  slot: .snack)
        assertClose(entry.nutrients[.energy], (hit.kcalPer100g ?? 0) * serving.amount * 2 / 100, accuracy: 1e-6)
        let byWeight = try MealEntry(food: banana, portion: banana.portion(150, .gram), day: Sample.day, slot: .snack)
        assertClose(byWeight.nutrients[.energy], (hit.kcalPer100g ?? 0) * 1.5, accuracy: 1e-6)
        XCTAssertNil(try c.food(id: -1))
        XCTAssertNil(try c.food(id: FoodID("demo-oats")))
    }

    func testMissingValuesStayUnknown() throws {
        let c = try catalog()
        // salt: USDA reports 0 kcal (a real zero)
        let salt = try XCTUnwrap(c.search("salt table", limit: 1).first)
        XCTAssertEqual(try c.food(id: salt.id)?.nutrients[.energy], 0)
        // any food with no fiber value reads back as unknown
        let foods = try c.search("beverages", limit: 50).compactMap { try c.food(id: $0.id) }
        XCTAssertTrue(foods.contains { $0.nutrients[.fiber] == nil }, "some drinks have no fiber value in USDA")
        XCTAssertTrue(c.attribution.contains("U.S. Department of Agriculture"))
    }
}
