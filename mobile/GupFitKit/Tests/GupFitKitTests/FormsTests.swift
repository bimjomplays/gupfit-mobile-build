import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

final class FormsTests: XCTestCase {
    func testNumberInput() {
        XCTAssertEqual(NumberInput.parse("1.5"), 1.5)
        XCTAssertEqual(NumberInput.parse(" 1,5 "), 1.5, "a comma decimal works too")
        XCTAssertNil(NumberInput.parse(""))
        XCTAssertNil(NumberInput.parse("abc"))
        XCTAssertNil(NumberInput.parse("inf"))
        XCTAssertTrue(NumberInput.isValid(" "))
        XCTAssertFalse(NumberInput.isValid("1.2.3"))
        XCTAssertEqual(NumberInput.text(2.50), "2.5")
        XCTAssertEqual(NumberInput.text(nil), "")
    }

    func testFoodDraftMakesAFood() throws {
        var draft = FoodDraft()
        draft.name = " Granola "
        draft.brand = ""
        draft.nutrients = [.energy: "450", .protein: "10", .fat: "", .fiber: "0"]
        draft.servings = [ServingDraft(label: "½ cup", amount: "55"), ServingDraft()]
        let food = try draft.makeFood()
        XCTAssertEqual(food.name, "Granola")
        XCTAssertNil(food.brand)
        XCTAssertEqual(food.source, .user)
        XCTAssertEqual(food.referenceAmount, 100)
        XCTAssertEqual(food.nutrients[.energy], 450)
        XCTAssertNil(food.nutrients[.fat], "left empty: unknown")
        XCTAssertEqual(food.nutrients[.fiber], 0, "typed 0: zero")
        XCTAssertEqual(food.servings, [Serving("½ cup", amount: 55)], "the empty row is ignored")

        // editing keeps the id and reproduces the same food
        XCTAssertEqual(try FoodDraft(food: food).makeFood(), food)
    }

    func testFoodDraftNamesEveryProblem() {
        var draft = FoodDraft()
        draft.nutrients = [.protein: "lots", .fat: "-1"]
        draft.referenceAmount = "0"
        draft.servings = [ServingDraft(label: "slice", amount: "")]
        XCTAssertThrowsError(try draft.makeFood()) { error in
            let fields = Set((error as? ValidationError)?.issues.map(\.field) ?? [])
            XCTAssertEqual(fields, ["name", "nutrients.energy", "nutrients.protein", "nutrients.fat", "referenceAmount",
                                    "servings[0].amount"])
        }
    }

    func testPerServingFoods() throws {
        var draft = FoodDraft()
        draft.name = "Protein bar"
        draft.setBaseUnit(.serving)
        XCTAssertEqual(draft.referenceAmount, "1")
        draft.nutrients[.energy] = "200"
        let bar = try draft.makeFood()
        XCTAssertEqual(bar.baseUnit, .serving)
        let entry = try MealEntry(food: bar, portion: bar.portion(2, serving: "serving"), day: Sample.day, slot: .snack)
        assertClose(entry.nutrients[.energy], 400)
        draft.setBaseUnit(.gram)
        XCTAssertEqual(draft.referenceAmount, "100")
    }

    func testRecipeTextAndHelpers() {
        XCTAssertEqual(RecipeText.steps(from: "Cook rice.\n\n  Slice chicken. \n"), ["Cook rice.", "Slice chicken."])
        XCTAssertEqual(RecipeText.tags(from: "meal prep, ,quick"), ["meal prep", "quick"])
        XCTAssertEqual(Recipe.recipeID(fromFoodID: "recipe:abc"), "abc")
        XCTAssertNil(Recipe.recipeID(fromFoodID: "usda:1"))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(MealSlot.suggested(at: Sample.date("2026-11-17T07:30:00Z"), calendar: cal), .breakfast)
        XCTAssertEqual(MealSlot.suggested(at: Sample.date("2026-11-17T12:30:00Z"), calendar: cal), .lunch)
        XCTAssertEqual(MealSlot.suggested(at: Sample.date("2026-11-17T19:00:00Z"), calendar: cal), .dinner)
        XCTAssertEqual(MealSlot.suggested(at: Sample.date("2026-11-17T23:30:00Z"), calendar: cal), .snack)

        let set = WorkoutSet(reps: 5, weightKg: 100, rpe: 8, isWarmup: true)
        let next = set.next()
        XCTAssertNotEqual(next.id, set.id)
        XCTAssertEqual(next.reps, 5)
        XCTAssertFalse(next.isWarmup)
        XCTAssertFalse(next.isCompleted)

        let grams = Portion(150, .standard(.gram))
        assertClose(grams.converted(to: Serving("1 cup", amount: 120)).count, 1.25)

        let snapshot = Sample.apple.snapshot
        XCTAssertEqual(snapshot.asFood.snapshot, snapshot)
    }
}
