import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

final class RecipeTests: XCTestCase {
    /// chicken 600 g + rice 800 g + milk 250 ml, 4 servings
    func bowl(cookedWeight: Double? = nil) throws -> Recipe {
        Recipe(id: "bowl", name: "Chicken rice bowl", servings: 4, ingredients: [
            RecipeIngredient(food: Sample.chicken, portion: try Sample.chicken.portion(600, .gram)),
            RecipeIngredient(food: Sample.rice, portion: try Sample.rice.portion(800, .gram)),
            RecipeIngredient(food: Sample.milk, portion: try Sample.milk.portion(1, .cup), note: "for the sauce"),
        ], steps: ["Cook rice", "Grill chicken"], cookedWeightGrams: cookedWeight, tags: ["meal prep"])
    }

    func testTotalsAndPerServing() throws {
        let r = try bowl()
        let milkCup = 2.365882365
        assertClose(r.totals[.energy], 990 + 1040 + 50 * milkCup)
        assertClose(r.totals[.protein], 186 + 21.6 + 3.3 * milkCup)
        assertClose(r.perServing[.energy], (990 + 1040 + 50 * milkCup) / 4)
        assertClose(r.perServing[.fat], (21.6 + 2.4 + 2 * milkCup) / 4)
        XCTAssertTrue(r.perServing.isPartial(.fiber), "milk's fiber is unknown")
        XCTAssertEqual(Recipe(name: "Empty", servings: 2).perServing, .zero)
    }

    func testLoggingAServingWithoutCookedWeight() throws {
        let r = try bowl()
        let food = r.asFood()
        XCTAssertEqual(food.baseUnit, .serving)
        XCTAssertEqual(food.source, .recipe("bowl"))
        let entry = try MealEntry(food: food, portion: food.portion(1.5, serving: "serving"), day: Sample.day,
                                  slot: .dinner)
        assertClose(entry.nutrients[.energy], r.perServing[.energy]! * 1.5)
    }

    func testLoggingByGramsWithCookedWeight() throws {
        let r = try bowl(cookedWeight: 1400)
        let food = r.asFood()
        XCTAssertEqual(food.baseUnit, .gram)
        assertClose(try food.portion(1, serving: "serving").baseAmount, 350)
        assertClose(food.nutrients(for: try food.portion(350, .gram))[.energy], r.perServing[.energy]!)
        assertClose(food.nutrients(for: try food.portion(700, .gram))[.protein], r.perServing[.protein]! * 2)
    }

    func testIngredientsKeepTheirCopyUntilRefreshed() throws {
        var r = try bowl()
        var leaner = Sample.chicken
        leaner.nutrients[.fat] = 1
        assertClose(r.ingredients[0].nutrients[.fat], 21.6)
        r = r.refreshed(with: [leaner.id: leaner])
        assertClose(r.ingredients[0].nutrients[.fat], 6)
        XCTAssertEqual(r.ingredients[1].food, Sample.rice.snapshot, "foods not given keep their copy")
    }

    func testValidation() throws {
        var r = try bowl()
        XCTAssertTrue(r.isValid)
        r.name = ""
        r.servings = 0
        r.cookedWeightGrams = -10
        r.ingredients[2].portion.count = -1
        XCTAssertEqual(r.validationIssues(), [
            ValidationIssue(field: "name", problem: .empty),
            ValidationIssue(field: "servings", problem: .notPositive),
            ValidationIssue(field: "cookedWeightGrams", problem: .negative),
            ValidationIssue(field: "ingredients[2].portion.count", problem: .negative),
        ])
    }
}
