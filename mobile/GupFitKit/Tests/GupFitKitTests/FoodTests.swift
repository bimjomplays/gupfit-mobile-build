import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

final class FoodTests: XCTestCase {
    func testPortionsScaleFromTheReferenceAmount() throws {
        let apple = Sample.apple
        let medium = try apple.portion(1, serving: "1 Medium")
        assertClose(medium.baseAmount, 182)
        assertClose(apple.nutrients(for: medium)[.energy], 52 * 1.82)

        let ounces = try apple.portion(4, .ounce)
        assertClose(ounces.baseAmount, 113.3980925)
        assertClose(apple.nutrients(for: ounces)[.energy], 52 * 1.133980925)
        XCTAssertEqual(ounces.description, "4 oz")
        XCTAssertEqual(medium.description, "1 × 1 medium")
    }

    func testVolumeAndServingFoods() throws {
        let glass = try Sample.milk.portion(1, serving: "glass")
        assertClose(Sample.milk.nutrients(for: glass)[.protein], 3.3 * 2.5)
        let cup = try Sample.milk.portion(1, .cup)
        assertClose(Sample.milk.nutrients(for: cup)[.energy], 50 * 2.365882365)

        let bars = try Sample.bar.portion(2, serving: "bar")
        assertClose(Sample.bar.nutrients(for: bars)[.protein], 40)
    }

    func testMassAndVolumeDontMix() {
        XCTAssertThrowsError(try Sample.chicken.portion(1, .cup)) { error in
            XCTAssertEqual(error as? ValidationError, ValidationError(issues: [
                ValidationIssue(field: "unit", problem: .unitMismatch(expected: .gram, got: .milliliter)),
            ]))
        }
        XCTAssertThrowsError(try Sample.bar.portion(30, .gram))
        XCTAssertThrowsError(try Sample.apple.portion(1, serving: "slice")) { error in
            XCTAssertEqual((error as? ValidationError)?.issues.first?.problem, .unknownServing("slice"))
        }
    }

    func testServingOptions() {
        let labels = Sample.apple.servingOptions.map(\.label)
        XCTAssertEqual(labels.first, "1 medium", "the food's own servings come first")
        XCTAssertTrue(labels.contains("oz"))
        XCTAssertFalse(labels.contains("cup"), "no volume units for a food measured in grams")
        XCTAssertEqual(Sample.bar.servingOptions.map(\.label), ["bar", "serving"])
    }

    func testNoNegativeOrZeroAmounts() {
        XCTAssertThrowsError(try Sample.apple.portion(-1, .gram))
        XCTAssertThrowsError(try Sample.apple.portion(0, .gram))
        XCTAssertEqual(Portion(.infinity, .standard(.gram)).validationIssues(),
                       [ValidationIssue(field: "count", problem: .notFinite)])

        var food = Sample.apple
        food.name = "  "
        food.referenceAmount = 0
        food.nutrients[.protein] = -3
        food.servings.append(Serving("spoon", amount: -5))
        XCTAssertEqual(food.validationIssues().map(\.description), [
            "name can't be empty",
            "referenceAmount must be more than zero",
            "nutrients.protein can't be negative",
            "servings[1].amount can't be negative",
        ])
        XCTAssertThrowsError(try food.validate())
        XCTAssertTrue(Sample.apple.isValid)
    }

    func testUnitFactors() {
        assertClose(MeasureUnit.pound.factor / MeasureUnit.ounce.factor, 16)
        assertClose(MeasureUnit.cup.factor / MeasureUnit.tablespoon.factor, 16)
        assertClose(MeasureUnit.tablespoon.factor / MeasureUnit.teaspoon.factor, 3)
        assertClose(MeasureUnit.cup.factor / MeasureUnit.fluidOunce.factor, 8)
        assertClose(WeightUnit.pound.toKilograms(225), 102.05828325)
        assertClose(WeightUnit.pound.fromKilograms(WeightUnit.pound.toKilograms(135)), 135)
    }

    func testSearch() {
        XCTAssertEqual(FoodSearch.normalize("Crème  Brûlée, Vanilla"), "creme brulee vanilla")
        XCTAssertTrue(FoodSearch.matches("chick bre", name: "Chicken breast, cooked"))
        XCTAssertTrue(FoodSearch.matches("acme prot", name: "Protein bar", brand: "Acme"))
        XCTAssertFalse(FoodSearch.matches("hicken", name: "Chicken breast"), "word prefixes, not substrings")
        XCTAssertTrue(FoodSearch.matches("", name: "anything"))
    }

    func testFormat() {
        XCTAssertEqual(Format.number(12), "12")
        XCTAssertEqual(Format.number(12.5), "12.5")
        XCTAssertEqual(Format.number(1 / 3), "0.33")
        XCTAssertEqual(Format.number(2.999), "3")
        XCTAssertEqual(Format.number(-0.5, digits: 0), "-1")
        XCTAssertEqual(Format.number(.nan), "—")
    }

    func testFoodRoundTripsThroughJSON() throws {
        for food in [Sample.apple, Sample.milk, Sample.bar] {
            let back = try JSONDecoder().decode(Food.self, from: JSONEncoder().encode(food))
            XCTAssertEqual(back, food)
        }
        let recipeFood = Recipe(id: "r1", name: "Stew", servings: 2).asFood()
        XCTAssertEqual(try JSONDecoder().decode(Food.self, from: JSONEncoder().encode(recipeFood)).source, .recipe("r1"))
    }
}
