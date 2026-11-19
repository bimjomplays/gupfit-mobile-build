import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

final class NutrientProfileTests: XCTestCase {
    func testMissingIsNotZero() {
        let p = Sample.chicken.nutrients
        XCTAssertEqual(p[.fiber], 0, "chicken has no fiber: a real zero")
        XCTAssertNil(p[.sugars], "unknown stays nil")
        XCTAssertTrue(p.known.contains(.fiber))
        XCTAssertFalse(p.known.contains(.sugars))
    }

    func testScalingKeepsUnknownUnknown() {
        let half = Sample.apple.nutrients.scaled(by: 0.5)
        assertClose(half[.energy], 26)
        assertClose(half[.fiber], 1.2)
        XCTAssertNil(half[.cholesterol])
    }

    func testCaloriesFromMacros() {
        assertClose(Sample.bar.nutrients.caloriesFromMacros, 20 * 4 + 22 * 4 + 7 * 9)
        var beer = NutrientProfile([.protein: 0.5, .carbohydrate: 3.6, .fat: 0, .alcohol: 3.9])
        assertClose(beer.caloriesFromMacros, 0.5 * 4 + 3.6 * 4 + 3.9 * 7)
        beer[.fat] = nil
        XCTAssertNil(beer.caloriesFromMacros, "needs all three macros")
    }

    func testJSONIsFlatAndSkipsUnknownKeys() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let json = String(decoding: try enc.encode(NutrientProfile([.energy: 52, .fiber: 0])), as: UTF8.self)
        XCTAssertEqual(json, #"{"energy":52,"fiber":0}"#)
        // a newer build's nutrient is dropped, not a decoding failure
        let read = try JSONDecoder().decode(NutrientProfile.self, from: Data(#"{"energy":10,"vitaminZ":3}"#.utf8))
        XCTAssertEqual(read, NutrientProfile([.energy: 10]))
    }

    func testCatalogColumnsMatchTheirUnits() {
        // the USDA catalog's columns (tools/catalog/README.md): every one has a nutrient, named with its unit
        let columns = ["kcal", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g", "sodium_mg", "sat_fat_g",
                       "cholesterol_mg", "potassium_mg", "calcium_mg", "iron_mg"]
        XCTAssertEqual(Set(Nutrient.allCases.compactMap(\.catalogColumn)), Set(columns))
        for n in Nutrient.allCases {
            guard let column = n.catalogColumn else { continue }
            XCTAssertTrue(column.hasSuffix(n.unit.rawValue), "\(n) is in \(n.unit.rawValue), its column is \(column)")
        }
    }

    func testNegativeAndNaNNutrientsAreInvalid() {
        let p = NutrientProfile([.energy: -1, .protein: .nan, .fat: 0])
        XCTAssertEqual(Set(p.validationIssues()), [
            ValidationIssue(field: "energy", problem: .negative),
            ValidationIssue(field: "protein", problem: .notFinite),
        ])
    }
}

final class NutrientTotalsTests: XCTestCase {
    func testSumsKnownAndMarksPartial() {
        // apple knows fiber, milk doesn't, chicken knows fiber = 0
        let t = NutrientTotals([Sample.apple.nutrients, Sample.milk.nutrients, Sample.chicken.nutrients])
        assertClose(t[.energy], 52 + 50 + 165)
        XCTAssertFalse(t.isPartial(.energy))
        assertClose(t[.fiber], 2.4)
        XCTAssertTrue(t.isPartial(.fiber), "milk's fiber is unknown, so 2.4 g is a lower bound")
        XCTAssertEqual(t.formatted(.fiber, digits: 1), "2.4 g+")
        XCTAssertNil(NutrientTotals([Sample.milk.nutrients, Sample.bar.nutrients])[.fiber], "nobody knows: unknown")
        XCTAssertEqual(NutrientTotals([Sample.milk.nutrients]).formatted(.fiber), "—")
    }

    func testNothingSumsToZero() {
        let t = NutrientTotals([NutrientProfile]())
        for n in Nutrient.allCases { XCTAssertEqual(t[n], 0) }
        XCTAssertEqual(t.formatted(.energy), "0 kcal")
        XCTAssertEqual(t, .zero)
    }

    func testDividedKeepsPartial() {
        let t = NutrientTotals([Sample.apple.nutrients, Sample.milk.nutrients]).divided(by: 2)
        assertClose(t[.energy], 51)
        assertClose(t[.fiber], 1.2)
        XCTAssertTrue(t.isPartial(.fiber))
    }
}
