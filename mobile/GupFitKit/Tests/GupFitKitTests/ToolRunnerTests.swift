import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

/// The AI chat's tools on the phone (ToolRunner): every tool against the demo data, invalid calls changing nothing,
/// receipts making replays and repeats harmless, transactions, and Undo.
final class ToolRunnerTests: XCTestCase {
    var store: InMemoryStore!
    var runner: ToolRunner!
    var cal = Calendar(identifier: .gregorian)
    let day = Sample.day  // 2026-11-17, "today" in these tests
    var calls = 0

    override func setUp() {
        cal.timeZone = TimeZone(identifier: "America/Denver")!
        store = Demo.store(day: day, calendar: cal)
        let noon = day.start(in: cal).addingTimeInterval(12 * 3600)
        runner = ToolRunner(store: store, catalog: nil, calendar: cal, now: { noon }, today: { [day] in day })
    }

    /// runs `name` with `args` as the next call of `turn`
    @discardableResult
    func run(_ name: String, _ args: JSONValue, turn: String = "turn-1", call: String? = nil, version: Int = 1) -> ToolOutcome {
        calls += 1
        return runner.run(ToolCall(call: call ?? "c-\(calls)", name: name, version: version, arguments: args), turn: turn)
    }

    func entries(_ d: LocalDay? = nil) throws -> [MealEntry] { try store.entries(on: d ?? day) }

    // MARK: meals

    func testLogTwoEggsAndOatsIsOneCallTwoEntries() throws {
        let before = try entries().count
        let out = run("log_meal", ["meal": "breakfast", "items": [
            ["food_id": "demo-egg", "amount": 2, "unit": "1 large (50 g)"],
            ["food_id": "demo-oats", "amount": 1, "unit": "½ cup"],
        ]])
        XCTAssertTrue(out.ok, out.error ?? "")
        let now = try entries()
        XCTAssertEqual(now.count, before + 2)
        let eggs = try XCTUnwrap(now.first { $0.food.foodID == "demo-egg" })
        XCTAssertEqual(eggs.slot, .breakfast)
        XCTAssertEqual(eggs.portion, Portion(2, Serving("1 large", amount: 50)))
        assertClose(eggs.nutrients[.energy], 140)
        XCTAssertEqual(out.changes.map(\.kind), [.mealLogged, .mealLogged])
        XCTAssertEqual(out.changes[0].detail, "Egg, large · 2 × 1 large · 140 kcal")
        XCTAssertEqual(out.changes[0].title, "Logged to breakfast · today")
        let logged = try XCTUnwrap(out.result?["logged"]?.array)
        XCTAssertEqual(logged.first?["entry_id"]?.string, eggs.id.rawValue)
        XCTAssertEqual(logged.first?["kcal"], 140)
        XCTAssertEqual(out.result?["day_totals"]?["kcal"]?.number, 715.5.rounded() + 140 + 152)
    }

    func testUnitsAreMatchedLenientlyButNeverGuessed() throws {
        XCTAssertTrue(run("log_meal", ["meal": "lunch", "items": [["food_id": "demo-egg", "amount": 2, "unit": "large"]]]).ok)
        XCTAssertTrue(run("log_meal", ["meal": "lunch", "items": [["food_id": "demo-chicken", "amount": 6, "unit": "ounces"]]]).ok)
        let chicken = try XCTUnwrap(try entries().last { $0.food.foodID == "demo-chicken" && $0.id != "demo-e3" })
        assertClose(chicken.portion.baseAmount, 6 * 28.349523125)
        let bad = run("log_meal", ["meal": "lunch", "items": [["food_id": "demo-egg", "amount": 2, "unit": "slice"]]])
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.error, "items[0].unit: \"slice\" isn't a unit of Egg, large; use one of: 1 large (50 g), g, kg, oz, lb")
        let noUnit = run("log_meal", ["meal": "lunch", "items": [["food_id": "demo-egg", "amount": 2]]])
        XCTAssertEqual(noUnit.error, "items[0].unit is required for Egg, large: one of 1 large (50 g), g, kg, oz, lb")
    }

    func testAFoodNotInTheDatabaseIsLoggedByNameAndCalories() throws {
        let out = run("log_meal", ["meal": "snack", "items": [
            ["name": "Protein shake", "calories": 160, "protein_g": 30, "amount": 1, "unit": "bottle"],
        ]])
        XCTAssertTrue(out.ok, out.error ?? "")
        let shake = try XCTUnwrap(try entries().first { $0.food.name == "Protein shake" })
        assertClose(shake.nutrients[.energy], 160)
        assertClose(shake.nutrients[.protein], 30)
        XCTAssertNil(shake.nutrients[.fat], "unknown stays unknown")
        XCTAssertEqual(shake.portion.description, "1 × bottle")
        XCTAssertNil(try store.food(id: shake.food.foodID), "the snapshot only; nothing added to My foods")
    }

    func testEditAndDeleteAnEntry() throws {
        let out = run("edit_meal_entry", ["entry_id": "demo-e3", "amount": 200, "meal": "dinner"])
        XCTAssertTrue(out.ok, out.error ?? "")
        let e = try XCTUnwrap(store.entry(id: "demo-e3"))
        XCTAssertEqual(e.slot, .dinner)
        XCTAssertEqual(e.portion.count, 200)
        XCTAssertEqual(e.portion.serving, .standard(.gram), "the unit it had")
        XCTAssertEqual(out.changes.first?.detail, "Chicken breast, grilled · 150 g → 200 g · 330 kcal")

        let moved = run("edit_meal_entry", ["entry_id": "demo-e3", "date": "2026-11-16"])
        XCTAssertTrue(moved.ok)
        XCTAssertEqual(try store.entry(id: "demo-e3")?.day, day.adding(days: -1))
        XCTAssertEqual(moved.changes.first?.title, "Changed dinner · yesterday")

        let del = run("delete_meal_entry", ["entry_id": "demo-e1"])
        XCTAssertTrue(del.ok)
        XCTAssertNil(try store.entry(id: "demo-e1"))
        XCTAssertEqual(del.result?["deleted"]?["food"], "Rolled oats")

        XCTAssertEqual(run("delete_meal_entry", ["entry_id": "demo-e1"], turn: "turn-2").error,
                       "entry_id: no meal entry demo-e1 (get_day lists the entries with their ids)")
        XCTAssertEqual(run("edit_meal_entry", ["entry_id": "demo-e2"]).error,
                       "Nothing to change: give amount, unit, meal, date or note.")
    }

    func testGetDayReturnsOnlyThatDay() throws {
        let out = run("get_day", ["date": "2026-11-17"])
        XCTAssertTrue(out.ok)
        let list = try XCTUnwrap(out.result?["entries"]?.array)
        XCTAssertEqual(list.map { $0["entry_id"]?.string }, ["demo-e1", "demo-e2", "demo-e3", "demo-e4"])
        XCTAssertEqual(list[2]["amount"], "150 g")
        XCTAssertEqual(out.result?["goals"]?["kcal"], 2200)
        XCTAssertEqual(out.result?["totals"]?["some_unknown"], nil, "kcal and macros are known for every demo food")
        let empty = run("get_day", ["date": "2026-11-15"])
        XCTAssertEqual(empty.result?["entries"], [])
        XCTAssertEqual(empty.result?["totals"]?["kcal"], 0)
        XCTAssertTrue(out.changes.isEmpty)
    }

    // MARK: exactly once

    func testAReplayedCallIsAnsweredFromItsReceipt() throws {
        let args: JSONValue = ["meal": "breakfast", "items": [["food_id": "demo-egg", "amount": 2, "unit": "1 large"]]]
        let first = run("log_meal", args, call: "c-9")
        let count = try entries().count
        let again = run("log_meal", args, call: "c-9")
        XCTAssertTrue(again.replayed)
        XCTAssertEqual(again.result, first.result)
        XCTAssertEqual(again.changes, first.changes)
        XCTAssertEqual(try entries().count, count, "nothing logged twice")
        // even with other arguments: a call id is answered once
        let changed = run("log_meal", ["meal": "dinner", "items": [["food_id": "demo-egg", "amount": 9, "unit": "1 large"]]], call: "c-9")
        XCTAssertEqual(changed.result, first.result)
        XCTAssertEqual(try entries().count, count)
    }

    func testTheSameChangeTwiceInOneTurnIsMadeOnce() throws {
        let args: JSONValue = ["meal": "breakfast", "items": [["food_id": "demo-egg", "amount": 2, "unit": "1 large"]]]
        let before = try entries().count
        XCTAssertTrue(run("log_meal", args).ok)
        let repeat_ = run("log_meal", args)
        XCTAssertTrue(repeat_.ok)
        XCTAssertTrue(repeat_.changes.isEmpty)
        XCTAssertEqual(repeat_.result?["note"]?.string?.hasPrefix("This exact change was already made"), true)
        XCTAssertEqual(try entries().count, before + 1)
        // a read may repeat freely; another turn is another request
        XCTAssertFalse(run("get_day", ["date": "2026-11-17"]).replayed)
        XCTAssertFalse(run("get_day", ["date": "2026-11-17"]).replayed)
        XCTAssertTrue(run("log_meal", args, turn: "turn-2").ok)
        XCTAssertEqual(try entries().count, before + 2)
    }

    func testAFailedRepeatIsNotTakenForTheChange() throws {
        let bad: JSONValue = ["meal": "breakfast", "items": [["food_id": "nope", "amount": 2, "unit": "g"]]]
        XCTAssertFalse(run("log_meal", bad).ok)
        let replay = runner.run(ToolCall(call: "c-\(calls)", name: "log_meal", version: 1, arguments: bad), turn: "turn-1")
        XCTAssertFalse(replay.ok)
        XCTAssertTrue(replay.replayed)
        XCTAssertFalse(run("log_meal", bad).replayed, "only successful writes are deduplicated")
    }

    // MARK: invalid calls change nothing

    func testInvalidCallsAreRefusedWithReasonsAndChangeNothing() throws {
        let before = try entries()
        let cases: [(String, JSONValue, String)] = [
            ("drop_tables", [:], "There is no tool called drop_tables in this version of GupFit."),
            ("log_meal", ["meal": "brunch", "items": [["food_id": "demo-egg", "amount": 1, "unit": "1 large"]]],
             "meal must be one of breakfast, lunch, dinner, snack"),
            ("log_meal", ["items": [["food_id": "demo-egg", "amount": 1, "unit": "1 large"]]], "meal is required"),
            ("log_meal", ["meal": "lunch", "items": []], "items needs at least 1 item"),
            ("log_meal", ["meal": "lunch", "items": [["food_id": "demo-egg", "amount": -2, "unit": "1 large"]]],
             "items[0].amount must be more than 0"),
            ("log_meal", ["meal": "lunch", "items": [["food_id": "demo-egg", "amount": "two", "unit": "1 large"]]],
             "items[0].amount must be a number"),
            ("log_meal", ["meal": "lunch", "items": [["food_id": "demo-egg", "amount": 1, "unit": "1 large", "kcal": 5]]],
             "items[0]: unknown argument kcal"),
            ("log_meal", ["meal": "lunch", "items": [["food_id": "demo-egg", "amount": 1, "unit": "1 large"]], "user": "x"],
             "unknown argument user"),
            ("log_meal", ["meal": "lunch", "items": [["food_id": "usda:999999999", "amount": 1, "unit": "g"]]],
             "items[0].food_id: no food with id usda:999999999 (use a food_id that search_foods returned)"),
            ("log_meal", ["meal": "lunch", "items": [["food_id": "demo-egg", "amount": 300, "unit": "1 large"]]],
             "items[0]: 300 × 1 large is more than 10 kg; check the amount"),
            ("log_meal", ["meal": "lunch", "date": "2026-02-30", "items": [["food_id": "demo-egg", "amount": 1, "unit": "1 large"]]],
             "date must be a date like 2026-01-31"),
            ("log_meal", ["meal": "lunch", "date": "2062-11-17", "items": [["food_id": "demo-egg", "amount": 1, "unit": "1 large"]]],
             "date 2062-11-17 is too far from today (2026-11-17): at most 10 years back and a week ahead"),
            ("log_meal", ["meal": "lunch", "items": [["food_id": "demo-egg", "name": "Egg", "calories": 70, "amount": 1]]],
             "items[0]: give either a food_id, or a name with calories, not both"),
            ("log_meal", ["meal": "lunch", "items": [["name": "Mystery", "amount": 1]]],
             "items[0] needs a food_id from search_foods, or a name and calories for a food that isn't in the database"),
            ("log_meal", "log 2 eggs", "arguments must be an object"),
            ("get_day", ["date": 20261117], "date must be text"),
            ("log_workout", ["exercises": [["name": "Squat", "sets": [["reps": 5, "weight": 225]]]]],
             "exercises[0].sets[0].weight_unit is required with a weight (lb or kg, as the user said)"),
            ("log_workout", ["exercises": [["name": "Squat", "sets": [["reps": 5.5]]]]],
             "exercises[0].sets[0].reps must be a whole number"),
            ("log_workout", ["exercises": [["name": "Squat", "sets": [[:]]]]],
             "exercises[0].sets[0] has nothing in it: give reps, weight, duration_s or distance_m"),
            ("log_workout", ["exercises": [["exercise_id": "nope", "sets": [["reps": 5]]]]],
             "exercises[0].exercise_id: no exercise nope (list_exercises has them)"),
            ("get_workouts", ["from": "2026-10-01", "to": "2026-11-17"], "Ask for at most 31 days at a time."),
            ("log_recipe", ["recipe_id": "demo-r1", "servings": 0, "meal": "dinner"], "servings must be more than 0"),
            ("create_recipe", ["name": "  ", "servings": 2, "ingredients": [["food_id": "demo-rice", "amount": 1, "unit": "1 cup"]]],
             "name can't be empty"),
        ]
        let sessions = try store.sessions(in: DateInterval(start: .distantPast, end: .distantFuture))
        for (name, args, message) in cases {
            let out = run(name, args)
            XCTAssertFalse(out.ok, name)
            XCTAssertEqual(out.error, message, "\(name) \(args.canonicalText)")
            XCTAssertTrue(out.changes.isEmpty)
        }
        XCTAssertEqual(try entries(), before)
        XCTAssertEqual(try store.sessions(in: DateInterval(start: .distantPast, end: .distantFuture)), sessions)
        XCTAssertEqual(store.exercises().count, 3, "a refused workout added no exercise")
        XCTAssertEqual(run("get_day", ["date": "2026-11-17"], version: 2).error, "This phone runs tool version 1, not 2.")
    }

    func testOneBadItemSavesNoneOfTheCall() throws {
        let before = try entries()
        let out = run("log_meal", ["meal": "dinner", "items": [
            ["food_id": "demo-egg", "amount": 2, "unit": "1 large"],
            ["food_id": "demo-rice", "amount": 1, "unit": "bowl"],
        ]])
        XCTAssertFalse(out.ok)
        XCTAssertEqual(try entries(), before, "the first item was rolled back with the second")
        // the same for a workout whose second exercise is wrong after the first added a new exercise
        let w = run("log_workout", ["exercises": [["name": "Lunges", "sets": [["reps": 10]]],
                                                  ["exercise_id": "nope", "sets": [["reps": 5]]]]])
        XCTAssertFalse(w.ok)
        XCTAssertFalse(store.exercises().contains { $0.name == "Lunges" })
    }

    // MARK: workouts

    func testSquat3x5At225() throws {
        let out = run("log_workout", ["title": "Legs", "exercises": [
            ["name": "back squat", "sets": [["reps": 5, "weight": 225, "weight_unit": "lb"],
                                            ["reps": 5, "weight": 225, "weight_unit": "lb"],
                                            ["reps": 5, "weight": 225, "weight_unit": "lb"]]],
        ]])
        XCTAssertTrue(out.ok, out.error ?? "")
        XCTAssertEqual(out.changes.map(\.kind), [.workoutLogged], "Back squat was in the library: reused")
        XCTAssertEqual(out.changes[0].detail, "Legs: Back squat 3×5 @ 225 lb")
        guard case .workout(let w)? = out.changes[0].after else { return XCTFail() }
        XCTAssertEqual(w.exercises.first?.exerciseID, Demo.squat.id)
        assertClose(w.exercises.first?.sets.first?.weightKg, 225 * 0.45359237)
        XCTAssertEqual(w.workingSetCount, 3)
        XCTAssertEqual(w.day(in: cal), day)
        XCTAssertFalse(w.isActive)
        XCTAssertEqual(out.result?["workout"]?["exercises"]?.array?.first?["sets"]?.array?.first?["lb"], 225)
    }

    func testANewExerciseNameIsAddedToTheLibrary() throws {
        let out = run("log_workout", ["date": "2026-11-16", "duration_min": 30, "exercises": [
            ["name": "Rowing", "kind": "cardio", "sets": [["duration_s": 1200, "distance_m": 5000]]],
        ]])
        XCTAssertTrue(out.ok, out.error ?? "")
        XCTAssertEqual(out.changes.map(\.kind), [.exerciseAdded, .workoutLogged])
        let row = try XCTUnwrap(store.exercises().first { $0.name == "Rowing" })
        XCTAssertEqual(row.kind, .cardio)
        guard case .workout(let w)? = out.changes[1].after else { return XCTFail() }
        XCTAssertEqual(w.day(in: cal), day.adding(days: -1))
        XCTAssertEqual(w.duration, 1800)
        let read = run("get_workouts", ["from": "2026-11-16"])
        XCTAssertEqual(read.result?["workouts"]?.array?.count, 1)
        XCTAssertEqual(read.result?["workouts"]?.array?.first?["workout_id"]?.string, w.id.rawValue)
        XCTAssertEqual(run("list_exercises", [:]).result?["exercises"]?.array?.count, 4)
    }

    func testEditAWorkout() throws {
        let out = run("edit_workout", ["workout_id": "demo-w1", "title": "Leg day", "exercises": [
            ["exercise_id": "demo-squat", "sets": [["reps": 5, "weight": 105, "weight_unit": "kg"]]],
        ]])
        XCTAssertTrue(out.ok, out.error ?? "")
        let w = try XCTUnwrap(store.session(id: "demo-w1"))
        XCTAssertEqual(w.title, "Leg day")
        XCTAssertEqual(w.exercises.first?.sets.map(\.weightKg), [105])
        let moved = run("edit_workout", ["workout_id": "demo-w1", "date": "2026-11-15"])
        XCTAssertTrue(moved.ok)
        let m = try XCTUnwrap(store.session(id: "demo-w1"))
        XCTAssertEqual(m.day(in: cal), day.adding(days: -2))
        XCTAssertEqual(m.duration, 3600, "same length, same time of day")
    }

    // MARK: recipes

    func testCreateEditAndLogARecipe() throws {
        let out = run("create_recipe", ["name": "Egg fried rice", "servings": 2, "tags": ["quick"],
                                        "steps": ["Fry.", "Eat."], "ingredients": [
            ["food_id": "demo-rice", "amount": 2, "unit": "1 cup"],
            ["food_id": "demo-egg", "amount": 2, "unit": "1 large", "note": "beaten"],
            ["name": "Soy sauce", "calories": 10, "amount": 1, "unit": "tbsp"],
        ]])
        XCTAssertTrue(out.ok, out.error ?? "")
        guard case .recipe(let x)? = out.changes.first?.after else { return XCTFail() }
        // rice 320 g 416 + eggs 100 g 140 + soy 10 = 566, 283 a serving
        assertClose(x.perServing[.energy], 283)
        XCTAssertEqual(x.ingredients[1].note, "beaten")
        XCTAssertEqual(out.changes.first?.detail, "Egg fried rice: 3 ingredients, 2 servings · 283 kcal a serving")

        let found = run("search_recipes", ["query": "fried"])
        XCTAssertEqual(found.result?["recipes"]?.array?.first?["recipe_id"]?.string, x.id.rawValue)
        XCTAssertEqual(run("search_recipes", ["query": ""]).result?["recipes"]?.array?.count, 2)
        XCTAssertEqual(run("get_recipe", ["recipe_id": .string(x.id.rawValue)]).result?["recipe"]?["ingredients"]?.array?.count, 3)

        XCTAssertTrue(run("edit_recipe", ["recipe_id": .string(x.id.rawValue), "servings": 4]).ok)
        assertClose(try store.recipe(id: x.id)?.perServing[.energy], 141.5)
        XCTAssertEqual(run("edit_recipe", ["recipe_id": .string(x.id.rawValue), "ingredients": [
            ["food_id": .string("recipe:\(x.id.rawValue)"), "amount": 1, "unit": "serving"]]]).error,
                       "ingredients[0]: a recipe can't be its own ingredient")

        let logged = run("log_recipe", ["recipe_id": .string(x.id.rawValue), "servings": 1.5, "meal": "dinner"])
        XCTAssertTrue(logged.ok, logged.error ?? "")
        let e = try XCTUnwrap(try entries().first { $0.food.name == "Egg fried rice" })
        assertClose(e.nutrients[.energy], 141.5 * 1.5)
        XCTAssertEqual(e.slot, .dinner)
    }

    func testLogARecipeWithACookedWeight() throws {
        let bowl = try XCTUnwrap(store.recipe(id: "demo-r1"))
        var weighed = bowl
        weighed.cookedWeightGrams = 1200
        try store.saveRecipe(weighed)
        XCTAssertTrue(run("log_recipe", ["recipe_id": "demo-r1", "servings": 1, "meal": "lunch", "date": "2026-11-16"]).ok)
        let e = try XCTUnwrap(try entries(day.adding(days: -1)).first)
        XCTAssertEqual(e.portion.baseAmount, 300, "a quarter of 1200 g")
        assertClose(e.nutrients[.energy], (990 + 832) / 4)
    }

    // MARK: undo

    func testUndoPutsBackWhatAChangeReplaced() throws {
        let before = try entries()
        let log = run("log_meal", ["meal": "snack", "items": [["food_id": "demo-banana", "amount": 1, "unit": "1 medium"]]])
        XCTAssertEqual(runner.undo(turn: "turn-1", call: "c-\(calls)", index: 0), .undone)
        XCTAssertEqual(try entries(), before)
        XCTAssertEqual(runner.undo(turn: "turn-1", call: "c-\(calls)", index: 0), .already)
        XCTAssertEqual(try store.receipt(turn: "turn-1", call: "c-\(calls)")?.changes.first?.undone, true)
        _ = log

        let edit = run("edit_meal_entry", ["entry_id": "demo-e4", "amount": 2])
        XCTAssertTrue(edit.ok)
        XCTAssertEqual(runner.undo(turn: "turn-1", call: "c-\(calls)", index: 0), .undone)
        XCTAssertEqual(try store.entry(id: "demo-e4")?.portion.count, 1)

        XCTAssertTrue(run("delete_meal_entry", ["entry_id": "demo-e2"]).ok)
        XCTAssertEqual(runner.undo(turn: "turn-1", call: "c-\(calls)", index: 0), .undone)
        XCTAssertEqual(try entries(), before)

        XCTAssertTrue(run("log_workout", ["exercises": [["name": "Dips", "sets": [["reps": 12]]]]]).ok)
        XCTAssertEqual(runner.undo(turn: "turn-1", call: "c-\(calls)", index: 1), .undone)
        XCTAssertEqual(runner.undo(turn: "turn-1", call: "c-\(calls)", index: 0), .undone)
        XCTAssertEqual(store.exercises().count, 3)
        XCTAssertEqual(try store.sessions(in: DateInterval(start: .distantPast, end: .distantFuture)).count, 2)
        XCTAssertEqual(runner.undo(turn: "turn-1", call: "c-404", index: 0), .failed("This change isn't on the phone anymore."))
    }

    func testUndoLeavesARecordChangedSinceAlone() throws {
        XCTAssertTrue(run("edit_meal_entry", ["entry_id": "demo-e4", "amount": 2]).ok)
        let call = "c-\(calls)"
        var e = try XCTUnwrap(store.entry(id: "demo-e4"))
        e.portion.count = 3  // edited in the app afterwards
        try store.saveEntry(e)
        XCTAssertEqual(runner.undo(turn: "turn-1", call: call, index: 0),
                       .changedSince("It was changed again after this, so Undo left it as it is."))
        XCTAssertEqual(try store.entry(id: "demo-e4")?.portion.count, 3)
    }

    // MARK: SQLite

    func testReceiptsAndUndoOnThePhoneDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gupfit-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("gupfit.sqlite")
        var db: SQLiteStore? = try SQLiteStore(url: url)
        Demo.seed(db!, day: day, calendar: cal)
        let noon = day.start(in: cal).addingTimeInterval(12 * 3600)
        func tools(_ s: SQLiteStore) -> ToolRunner {
            ToolRunner(store: s, catalog: nil, calendar: cal, now: { noon }, today: { [day] in day })
        }
        let call = ToolCall(call: "c-1", name: "log_meal", version: 1,
                            arguments: ["meal": "breakfast", "items": [["food_id": "demo-egg", "amount": 2, "unit": "1 large"]]])
        let first = tools(db!).run(call, turn: "t-sql")
        XCTAssertTrue(first.ok, first.error ?? "")
        XCTAssertEqual(try db!.entries(on: day).count, 5)
        db!.close()

        // the app restarted; the PC replays the call after a reconnect
        db = try SQLiteStore(url: url)
        XCTAssertEqual(db!.schemaVersion, 2)
        let replay = tools(db!).run(call, turn: "t-sql")
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.result, first.result)
        XCTAssertEqual(try db!.entries(on: day).count, 5, "logged exactly once")

        // undo after a restart: the record read back equals what the change saved
        XCTAssertEqual(tools(db!).undo(turn: "t-sql", call: "c-1", index: 0), .undone)
        XCTAssertEqual(try db!.entries(on: day).count, 4)
        let w = tools(db!).run(ToolCall(call: "c-2", name: "log_workout", version: 1, arguments: [
            "exercises": [["name": "Back squat", "sets": [["reps": 5, "weight": 100, "weight_unit": "kg", "rpe": 8]]]]]),
                               turn: "t-sql")
        XCTAssertTrue(w.ok, w.error ?? "")
        XCTAssertEqual(tools(db!).undo(turn: "t-sql", call: "c-2", index: 0), .undone)
        let r = tools(db!).run(ToolCall(call: "c-3", name: "create_recipe", version: 1, arguments: [
            "name": "Oats bowl", "servings": 1, "ingredients": [["food_id": "demo-oats", "amount": 1, "unit": "½ cup"]]]),
                               turn: "t-sql")
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(tools(db!).undo(turn: "t-sql", call: "c-3", index: 0), .undone)
        XCTAssertEqual(try db!.searchRecipes("oats"), [])
        db!.close()
    }

    func testAFailedCallWritesOnlyItsReceipt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gupfit-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteStore(url: dir.appendingPathComponent("gupfit.sqlite"))
        Demo.seed(db, day: day, calendar: cal)
        let t = ToolRunner(store: db, catalog: nil, calendar: cal, today: { [day] in day })
        let bad = t.run(ToolCall(call: "c-1", name: "log_meal", version: 1, arguments: ["meal": "dinner", "items": [
            ["food_id": "demo-egg", "amount": 1, "unit": "1 large"], ["food_id": "gone", "amount": 1, "unit": "g"]]]),
                        turn: "t")
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(try db.entries(on: day).count, 4)
        XCTAssertEqual(try db.receipt(turn: "t", call: "c-1")?.ok, false)
        db.close()
    }

    // MARK: the real catalog

    func testSearchFoodsListsTheCatalogsEggWithItsUnits() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../data/catalog.sqlite").standardizedFileURL.path
        guard let catalog = FoodCatalog.bundled() ?? (try? FoodCatalog(path: path)) else { throw XCTSkip("no catalog") }
        runner = ToolRunner(store: store, catalog: catalog, calendar: cal, today: { [day] in day })
        let out = run("search_foods", ["query": "eggs"])
        XCTAssertTrue(out.ok, out.error ?? "")
        let foods = try XCTUnwrap(out.result?["foods"]?.array)
        XCTAssertLessThanOrEqual(foods.count, ToolRunner.searchLimit)
        let names = foods.compactMap { $0["name"]?.string }
        let plain = try XCTUnwrap(names.firstIndex(of: "Eggs, Grade A, Large, egg whole"), "\(names)")
        let frozen = names.firstIndex(of: "Eggs, scrambled, frozen mixture") ?? names.count
        XCTAssertLessThan(plain, frozen, "unusual forms come after plain ones: \(names)")
        let egg = try XCTUnwrap(foods.first { $0["name"] == "Eggs, Grade A, Large, egg whole" }, "\(names)")
        XCTAssertEqual(egg["source"], "USDA")
        XCTAssertEqual(egg["nutrition_per"], "100 g")
        XCTAssertNotNil(egg["nutrition"]?["kcal"]?.number)
        let units = egg["units"]?.array?.compactMap(\.string) ?? []
        XCTAssertEqual(units.first, "egg, whole without shell (50.3 g)")
        XCTAssertTrue(units.contains("g"))
        // logged by the unit exactly as listed, then found first next time
        let id = try XCTUnwrap(egg["food_id"]?.string)
        let logged = run("log_meal", ["meal": "breakfast", "items": [["food_id": .string(id), "amount": 2, "unit": .string(units[0])]]])
        XCTAssertTrue(logged.ok, logged.error ?? "")
        XCTAssertEqual(logged.changes.count, 1)
        guard case .meal(let e)? = logged.changes.first?.after else { return XCTFail() }
        assertClose(e.portion.baseAmount, 100.6)
        let next = run("search_foods", ["query": "egg"])
        XCTAssertEqual(next.result?["foods"]?.array?.first?["food_id"]?.string, id)
        XCTAssertEqual(next.result?["foods"]?.array?.first?["source"], "logged before")
        XCTAssertEqual(run("search_foods", ["query": "zzqqxx"]).result?["foods"], [])
    }
}
