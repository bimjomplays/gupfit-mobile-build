import Foundation

/// Runs the AI chat's tool calls (pc/tools-v1.json) on the phone, against the same store the screens use.
///
/// Every call is checked first: the tool and version, every argument (types, bounds, units, dates; unknown arguments
/// are refused), and every id it names must exist. A write then runs in one transaction together with its receipt, so
/// either the whole change and its receipt are saved or nothing is. Before anything runs, the receipt of the same
/// (turn, call) is looked up: a replayed call (a reconnect, a retried turn) gets the stored answer and changes nothing.
/// The same change asked twice within one turn (a model repeating itself) is answered from the first one too.
/// Answers carry only what the call asked for.
final class ToolRunner: @unchecked Sendable {
    let store: any GupFitStore
    let catalog: FoodCatalog?
    let calendar: Calendar
    var now: @Sendable () -> Date
    /// the person's today (the app: the phone's date)
    var today: @Sendable () -> LocalDay

    static let searchLimit = 10
    /// how far back and ahead a day may be (a typo like 2062 is refused rather than logged)
    static let daysBack = 3650
    static let daysAhead = 7

    init(store: any GupFitStore, catalog: FoodCatalog?, calendar: Calendar = .current,
         now: @escaping @Sendable () -> Date = { Date() }, today: (@Sendable () -> LocalDay)? = nil) {
        self.store = store
        self.catalog = catalog
        self.calendar = calendar
        self.now = now
        let cal = calendar
        self.today = today ?? { LocalDay(now(), calendar: cal) }
    }

    // MARK: - Running a call

    func run(_ call: ToolCall, turn: String) -> ToolOutcome {
        let fingerprint = Fingerprint.of(call.name + " " + call.arguments.canonicalText)
        if let earlier = try? store.receipt(turn: turn, call: call.call) { return replay(earlier, of: call, fingerprint) }
        do {
            guard let name = ToolName(rawValue: call.name) else {
                throw ToolError("There is no tool called \(call.name) in this version of GupFit.")
            }
            guard call.version == ToolSet.version else {
                throw ToolError("This phone runs tool version \(ToolSet.version), not \(call.version).")
            }
            return try store.transaction {
                if let earlier = try store.receipt(turn: turn, call: call.call) { return replay(earlier, of: call, fingerprint) }
                if name.writes, let earlier = try store.receipts(turn: turn, fingerprint: fingerprint)
                    .first(where: { try stillInPlace($0) }) {
                    // the model asked for the same change again in this reply: answer from the first, change nothing
                    var result = earlier.result?.object ?? [:]
                    result["note"] = "This exact change was already made earlier in this reply (no second copy was saved)."
                    let r = ToolReceipt(turn: turn, call: call.call, name: call.name, fingerprint: fingerprint, ok: true,
                                        result: .object(result), error: nil, changes: [], at: now())
                    try store.saveReceipt(r)
                    return r.outcome
                }
                var changes: [ToolChange] = []
                let result = try perform(name, call.arguments, &changes).droppingNulls
                try store.saveReceipt(ToolReceipt(turn: turn, call: call.call, name: call.name, fingerprint: fingerprint,
                                                  ok: true, result: result, error: nil, changes: changes, at: now()))
                return ToolOutcome(ok: true, result: result, changes: changes)
            }
        } catch {
            // nothing of the call stayed (the transaction rolled back); keep the answer so a replay gets the same one,
            // but never over an existing receipt (its changes are what Undo needs)
            let message = Self.message(for: error)
            if case .some(.none) = try? store.receipt(turn: turn, call: call.call) {
                try? store.saveReceipt(ToolReceipt(turn: turn, call: call.call, name: call.name, fingerprint: fingerprint,
                                                   ok: false, result: nil, error: message, changes: [], at: now()))
            }
            return .failed(message)
        }
    }

    /// The stored answer for a call id seen before, when it is the same call. A different call under a used id (a PC
    /// that restarted and counts c-1, c-2 … again for the same turn) is refused, never answered with another call's
    /// result.
    private func replay(_ earlier: ToolReceipt, of call: ToolCall, _ fingerprint: String) -> ToolOutcome {
        guard earlier.fingerprint == fingerprint else {
            return .failed("This call id was already used for a different call in this reply, so nothing was done. "
                           + "Ask again in a new message.")
        }
        return earlier.outcome
    }

    /// An earlier write's changes are all still there exactly as it left them (none undone, edited or deleted since):
    /// only then does the same call again mean "the model repeated itself".
    private func stillInPlace(_ r: ToolReceipt) throws -> Bool {
        guard !r.changes.isEmpty else { return false }
        for c in r.changes {
            if c.undone { return false }
            if let after = c.after {
                guard try current(after) == after else { return false }
            } else if let before = c.before, try current(before) != nil {
                return false
            }
        }
        return true
    }

    static func message(for error: Error) -> String {
        switch error {
        case let e as ToolError: return e.message
        case let e as ValidationError: return "Not saved: \(e.description)."
        case RepositoryError.notFound(let id): return "Nothing with id \(id) is on the phone."
        default: return "The phone couldn't do this: \(error)"
        }
    }

    private func perform(_ name: ToolName, _ args: JSONValue, _ changes: inout [ToolChange]) throws -> JSONValue {
        var r = try ToolArgs(args)
        let out: JSONValue
        switch name {
        case .searchFoods: out = try searchFoods(&r)
        case .getDay: out = try getDay(&r)
        case .logMeal: out = try logMeal(&r, &changes)
        case .editMealEntry: out = try editMealEntry(&r, &changes)
        case .deleteMealEntry: out = try deleteMealEntry(&r, &changes)
        case .getWorkouts: out = try getWorkouts(&r)
        case .listExercises: out = try listExercises(&r)
        case .logWorkout: out = try logWorkout(&r, &changes)
        case .editWorkout: out = try editWorkout(&r, &changes)
        case .searchRecipes: out = try searchRecipes(&r)
        case .getRecipe: out = try getRecipe(&r)
        case .createRecipe: out = try createRecipe(&r, &changes)
        case .editRecipe: out = try editRecipe(&r, &changes)
        case .logRecipe: out = try logRecipe(&r, &changes)
        }
        return out
    }

    // MARK: - Undo

    /// Puts back what change `index` of a call replaced, when the record is still as that change left it; otherwise
    /// leaves everything alone and says so.
    func undo(turn: String, call: String, index: Int) -> UndoResult {
        do {
            return try store.transaction {
                guard var r = try store.receipt(turn: turn, call: call), r.changes.indices.contains(index) else {
                    return .failed("This change isn't on the phone anymore.")
                }
                let c = r.changes[index]
                if c.undone { return .already }
                if let after = c.after {
                    guard try current(after) == after else {
                        return .changedSince("It was changed again after this, so Undo left it as it is.")
                    }
                } else if let before = c.before, try current(before) != nil {
                    return .changedSince("It's back already, so Undo left it as it is.")
                }
                if case .exercise(let x)? = c.after, c.before == nil,
                   try store.sessions(in: DateInterval(start: .distantPast, end: .distantFuture))
                       .contains(where: { s in s.exercises.contains { $0.exerciseID == x.id } }) {
                    return .changedSince("A workout still uses \(x.name); undo that workout first.")
                }
                if let before = c.before { try save(before) } else if let after = c.after { try delete(after) }
                r.changes[index].undone = true
                try store.saveReceipt(r)
                return .undone
            }
        } catch {
            return .failed("Undo didn't work: \(Self.message(for: error))")
        }
    }

    private func current(_ record: ToolRecord) throws -> ToolRecord? {
        switch record {
        case .meal(let e): try store.entry(id: e.id).map(ToolRecord.meal)
        case .workout(let s): try store.session(id: s.id).map(ToolRecord.workout)
        case .recipe(let x): try store.recipe(id: x.id).map(ToolRecord.recipe)
        case .exercise(let x): try store.exercises().first { $0.id == x.id }.map(ToolRecord.exercise)
        }
    }

    private func save(_ record: ToolRecord) throws {
        switch record {
        case .meal(let e): try store.saveEntry(e)
        case .workout(let s): try store.saveSession(s)
        case .recipe(let x): try store.saveRecipe(x)
        case .exercise(let x): try store.saveExercise(x)
        }
    }

    private func delete(_ record: ToolRecord) throws {
        switch record {
        case .meal(let e): try store.deleteEntry(id: e.id)
        case .workout(let s): try store.deleteSession(id: s.id)
        case .recipe(let x): try store.deleteRecipe(id: x.id)
        case .exercise(let x): try store.deleteExercise(id: x.id)
        }
    }

    // MARK: - Foods

    private func searchFoods(_ r: inout ToolArgs) throws -> JSONValue {
        let query = try r.string("query", max: 80, required: true)!
        let limit = try r.int("limit", min: 1, max: 15) ?? Self.searchLimit
        try r.done()
        var out: [JSONValue] = []
        var seen: Set<FoodID> = []
        func add(_ food: Food, _ source: String) {
            guard out.count < limit, seen.insert(food.id).inserted else { return }
            out.append(foodJSON(food, source: source))
        }
        // what the person logged before first, so "eggs" means the same food as last time
        for snap in try store.recentFoods(limit: 100) where FoodSearch.matches(query, name: snap.name, brand: snap.brand) {
            if let f = try? findFood(snap.foodID.rawValue, field: ""), f.baseUnit == snap.baseUnit {
                add(f, "logged before")
            }
        }
        for f in try store.searchFoods(query, limit: limit) { add(f, "my food") }
        for x in try store.searchRecipes(query).prefix(limit) { add(x.asFood(), "my recipe") }
        if let catalog, out.count < limit {
            // plain foods first: unusual forms (dried, powder, mixes, baby food) last unless the query asks for them,
            // then names with the fewest words beyond the query ("Eggs, Grade A, Large, egg whole" before
            // "Egg, whole, cooked, scrambled" for "egg")
            let words = Set(FoodCatalog.words(query))
            let hits = try catalog.search(query, limit: 60).enumerated().map { i, hit in
                (key: (Self.unusual(hit.name, asked: words), Self.extraWords(hit.name, asked: words), i), hit: hit)
            }.sorted { $0.key < $1.key }.map { ($0.key.2, $0.hit) }
            for (_, hit) in hits where out.count < limit {
                if let f = try catalog.food(id: hit.id) { add(f, "USDA") }
            }
        }
        return ["query": .string(query), "foods": .array(out),
                "hint": out.isEmpty ? "Nothing found. Try one simpler word, or log it with a name and calories." : .null]
    }

    private static let unusualWords: Set<String> = [
        "dried", "dehydrated", "powder", "powdered", "mix", "frozen", "babyfood", "infant", "imitation", "substitute",
        "alaska", "navajo", "hopi", "apache", "shoshone", "custard", "custards", "pastries", "shakes", "unenriched",
        "formula", "toddler", "concentrate", "dry", "freeze",
    ]

    private static let plainWords: Set<String> = [
        "raw", "whole", "fresh", "plain", "large", "medium", "small", "grade", "a", "regular", "boneless", "skinless",
        "ripe", "and", "slightly", "with", "added", "vitamin", "d", "fluid", "meat", "only", "cooked", "boiled",
        "enriched", "commercially", "prepared", "unsalted", "without", "salt", "skin", "peeled", "all", "varieties",
    ]

    private static func singular(_ w: String) -> String { w.count > 3 && w.hasSuffix("s") ? String(w.dropLast()) : w }

    /// how many words of a catalog name are neither asked for nor plain descriptions (numbers don't count)
    static func extraWords(_ name: String, asked: Set<String>) -> Int {
        let wanted = Set(asked.map(singular))
        return FoodCatalog.words(name).filter { w in
            !wanted.contains(singular(w)) && !plainWords.contains(w) && !w.allSatisfy(\.isNumber)
        }.count
    }

    /// 1 when a catalog name is an unusual form of the food the query didn't ask for
    static func unusual(_ name: String, asked: Set<String>) -> Int {
        FoodCatalog.words(name).contains { unusualWords.contains($0) && !asked.contains($0) } ? 1 : 0
    }

    private func foodJSON(_ food: Food, source: String) -> JSONValue {
        let per = food.baseUnit == .serving ? "serving" : "\(Format.number(food.referenceAmount)) \(food.baseUnit == .gram ? "g" : "ml")"
        return ["food_id": .string(food.id.rawValue), "name": .string(food.name), "brand": food.brand.map(JSONValue.string) ?? .null,
                "source": .string(source), "nutrition_per": .string(per), "nutrition": macros(food.nutrients),
                "units": .array(units(of: food).map(JSONValue.string))]
    }

    /// what a food can be logged in, as the model should name it: "1 large (50 g)", "g", "oz", …
    private func units(of food: Food) -> [String] {
        let base = food.baseUnit == .gram ? "g" : food.baseUnit == .milliliter ? "ml" : nil
        return food.servingOptions.map { s in
            if MeasureUnit.allCases.contains(where: { $0.symbol == s.label }) || base == nil { return s.label }
            return "\(s.label) (\(Format.number(s.amount, digits: 1)) \(base!))"
        }
    }

    /// The food behind an id: the person's own food, a catalog food (`usda:…`) or a recipe (`recipe:…`).
    private func findFood(_ id: String, field: String) throws -> Food {
        let fid = FoodID(id)
        if let f = try store.food(id: fid) { return f }
        if let f = try catalog?.food(id: fid) { return f }
        if let rid = Recipe.recipeID(fromFoodID: fid), let x = try store.recipe(id: rid) { return x.asFood() }
        throw ToolError("\(field): no food with id \(id) (use a food_id that search_foods returned)")
    }

    private static let unitAliases: [String: String] = [
        "gram": "g", "grams": "g", "gr": "g", "kilogram": "kg", "kilograms": "kg", "kgs": "kg",
        "ounce": "oz", "ounces": "oz", "pound": "lb", "pounds": "lb", "lbs": "lb",
        "milliliter": "ml", "milliliters": "ml", "millilitre": "ml", "millilitres": "ml", "liter": "l", "liters": "l",
        "litre": "l", "litres": "l", "teaspoon": "tsp", "teaspoons": "tsp", "tablespoon": "tbsp", "tablespoons": "tbsp",
        "cups": "cup", "fluid ounce": "fl oz", "fluid ounces": "fl oz", "floz": "fl oz", "servings": "serving",
    ]

    /// `amount` of `unit` of `food`, with the unit matched leniently ("1 large (50 g)", "large", "grams") and the
    /// amount in sane bounds
    private func portion(of food: Food, amount: Double, unit: String?, field: String) throws -> Portion {
        let options = food.servingOptions
        var serving: Serving?
        if let unit {
            var u = unit.lowercased().trimmingCharacters(in: .whitespaces)
            if u.hasSuffix(")"), let open = u.lastIndex(of: "(") {  // "1 large (50 g)" as search_foods listed it
                u = u[..<open].trimmingCharacters(in: .whitespaces)
            }
            u = Self.unitAliases[u] ?? u
            serving = options.first { $0.label.lowercased() == u }
                ?? options.first { $0.label.lowercased() == "1 " + u }
                ?? options.first { u.hasSuffix("s") && $0.label.lowercased() == String(u.dropLast()) }
                ?? options.first { u.hasSuffix("s") && $0.label.lowercased() == "1 " + String(u.dropLast()) }
            if serving == nil {
                throw ToolError("\(field).unit: \"\(unit)\" isn't a unit of \(food.name); use one of: \(units(of: food).joined(separator: ", "))")
            }
        } else if food.baseUnit == .serving {
            serving = options.first
        } else {
            throw ToolError("\(field).unit is required for \(food.name): one of \(units(of: food).joined(separator: ", "))")
        }
        let p = Portion(amount, serving!)
        try checkSize(p, base: food.baseUnit, field: field)
        return p
    }

    private func checkSize(_ p: Portion, base: BaseUnit, field: String) throws {
        if base == .serving ? p.baseAmount > 100 : p.baseAmount > 10_000 {
            throw ToolError("\(field): \(p.description) is more than \(base == .serving ? "100 servings" : base == .gram ? "10 kg" : "10 l"); check the amount")
        }
    }

    /// one item of log_meal or a recipe's ingredient: a food by id, or a food that isn't in the database by name
    private func item(_ r: inout ToolArgs, withNote: Bool) throws -> (food: Food, portion: Portion, note: String?) {
        let foodID = try r.string("food_id", max: 120)
        let amount = try r.number("amount", max: 10_000, above: true, required: true)!
        let unit = try r.string("unit", max: 80)
        let name = try r.string("name", max: 120)
        let kcal = try r.number("calories", max: 5000)
        let protein = try r.number("protein_g", max: 1000)
        let carbs = try r.number("carbs_g", max: 1000)
        let fat = try r.number("fat_g", max: 1000)
        let note = withNote ? try r.string("note", max: 120) : nil
        if let foodID {
            if name != nil || kcal != nil || protein != nil || carbs != nil || fat != nil {
                throw ToolError("\(r.path): give either a food_id, or a name with calories, not both")
            }
            let food = try findFood(foodID, field: "\(r.path).food_id")
            return (food, try portion(of: food, amount: amount, unit: unit, field: r.path), note)
        }
        guard let name, let kcal else {
            throw ToolError("\(r.path) needs a food_id from search_foods, or a name and calories for a food that isn't in the database")
        }
        let label = unit ?? "serving"
        let food = Food(id: FoodID("quick:\(UUID().uuidString.lowercased())"), name: name, source: .user,
                        baseUnit: .serving, referenceAmount: 1,
                        nutrients: NutrientProfile([.energy: kcal, .protein: protein, .carbohydrate: carbs, .fat: fat]
                            .compactMapValues { $0 }),
                        servings: [Serving(label, amount: 1)])
        let p = Portion(amount, Serving(label, amount: 1))
        try checkSize(p, base: .serving, field: r.path)
        return (food, p, note)
    }

    // MARK: - Meals

    private func checkDay(_ day: LocalDay, _ field: String) throws {
        let t = today()
        if day < t.adding(days: -Self.daysBack) || day > t.adding(days: Self.daysAhead) {
            throw ToolError("\(field) \(day) is too far from today (\(t)): at most 10 years back and a week ahead")
        }
    }

    /// now on today; on another day, at the meal's usual time so the day's order makes sense
    private func loggedAt(_ day: LocalDay, _ slot: MealSlot) -> Date {
        day == today() ? now() : day.start(in: calendar).addingTimeInterval(slot.usualHour * 3600)
    }

    private func dayLabel(_ day: LocalDay) -> String {
        let t = today()
        if day == t { return "today" }
        if day == t.adding(days: -1) { return "yesterday" }
        if day == t.adding(days: 1) { return "tomorrow" }
        return day.description
    }

    private func macros(_ n: NutrientProfile) -> JSONValue {
        ["kcal": .rounded(n[.energy], 0), "protein_g": .rounded(n[.protein]), "carbs_g": .rounded(n[.carbohydrate]),
         "fat_g": .rounded(n[.fat])]
    }

    private func totals(_ t: NutrientTotals) -> JSONValue {
        var o = macros(t.profile).object ?? [:]
        if t.itemCount == 0 { o = ["kcal": 0, "protein_g": 0, "carbs_g": 0, "fat_g": 0] }
        let partial = [Nutrient.energy, .protein, .carbohydrate, .fat].filter(t.isPartial)
        if !partial.isEmpty { o["some_unknown"] = .array(partial.map { .string($0.rawValue) }) }
        return .object(o)
    }

    private func entryJSON(_ e: MealEntry) -> JSONValue {
        var o = ["entry_id": JSONValue.string(e.id.rawValue), "date": .string(e.day.description),
                 "meal": .string(e.slot.rawValue), "food": .string(e.food.name), "amount": .string(e.portion.description),
                 "note": e.note.map(JSONValue.string) ?? .null]
        for (k, v) in macros(e.nutrients).object ?? [:] { o[k] = v }
        return .object(o)
    }

    private func kcalText(_ n: NutrientProfile) -> String {
        n[.energy].map { " · \(Format.number($0, digits: 0)) kcal" } ?? ""
    }

    private func entryDetail(_ e: MealEntry) -> String { "\(e.food.name) · \(e.portion.description)\(kcalText(e.nutrients))" }

    private func getDay(_ r: inout ToolArgs) throws -> JSONValue {
        let day = try r.day("date", required: true)!
        try r.done()
        try checkDay(day, "date")
        let s = try store.summary(of: day)
        let goals = try store.setting(.nutritionGoals, as: NutritionGoals.self)
        return ["date": .string(day.description), "entries": .array(s.entries.map(entryJSON)),
                "totals": totals(s.totals), "goals": goals.map { macros($0.targets) } ?? .null]
    }

    private func logMeal(_ r: inout ToolArgs, _ changes: inout [ToolChange]) throws -> JSONValue {
        let day = try r.day("date") ?? today()
        let slot = try r.choice("meal", MealSlot.self, required: true)!
        let note = try r.string("note", max: 200)
        let items = try r.objects("items", min: 1, max: 20, required: true) { try item(&$0, withNote: false) }!
        try r.done()
        try checkDay(day, "date")
        let at = loggedAt(day, slot)
        var logged: [JSONValue] = []
        for (i, it) in items.enumerated() {
            let e = try MealEntry(food: it.food, portion: it.portion, day: day, slot: slot,
                                  loggedAt: at.addingTimeInterval(Double(i)), note: note)
            try store.saveEntry(e)
            let saved = try store.entry(id: e.id) ?? e
            changes.append(ToolChange(kind: .mealLogged, title: "Logged to \(slot.rawValue) · \(dayLabel(day))",
                                      detail: entryDetail(saved), before: nil, after: .meal(saved)))
            logged.append(entryJSON(saved))
        }
        return ["logged": .array(logged), "day_totals": totals(try store.summary(of: day).totals)]
    }

    /// the food an entry was logged from as it is now (for its units), else the entry's own snapshot; the unit it
    /// was logged in always counts
    private func currentFood(for e: MealEntry) throws -> Food {
        let id = e.food.foodID
        var food = (try? findFood(id.rawValue, field: "")).flatMap { $0.baseUnit == e.food.baseUnit ? $0 : nil }
            ?? e.food.asFood
        if !food.servingOptions.contains(where: { $0.label.lowercased() == e.portion.serving.label.lowercased() }) {
            food.servings.insert(e.portion.serving, at: 0)
        }
        return food
    }

    private func editMealEntry(_ r: inout ToolArgs, _ changes: inout [ToolChange]) throws -> JSONValue {
        let id = try r.string("entry_id", max: 120, required: true)!
        let amount = try r.number("amount", max: 10_000, above: true)
        let unit = try r.string("unit", max: 80)
        let slot = try r.choice("meal", MealSlot.self)
        let day = try r.day("date")
        let note = try r.string("note", max: 200, allowEmpty: true)
        try r.done()
        guard let old = try store.entry(id: MealEntryID(id)) else {
            throw ToolError("entry_id: no meal entry \(id) (get_day lists the entries with their ids)")
        }
        guard amount != nil || unit != nil || slot != nil || day != nil || note != nil else {
            throw ToolError("Nothing to change: give amount, unit, meal, date or note.")
        }
        var e = old
        if amount != nil || unit != nil {
            let food = try currentFood(for: old)
            e.portion = try portion(of: food, amount: amount ?? old.portion.count,
                                    unit: unit ?? old.portion.serving.label, field: "entry")
            if unit == nil { e.portion.serving = old.portion.serving }  // exactly the serving it had
        }
        if let slot { e.slot = slot }
        if let day {
            try checkDay(day, "date")
            e.day = day
        }
        if day != nil || slot != nil, e.day != old.day { e.loggedAt = loggedAt(e.day, e.slot) }
        if let note { e.note = note.isEmpty ? nil : note }
        guard e != old else { throw ToolError("That's already how this entry is; nothing to change.") }
        try store.saveEntry(e)
        let saved = try store.entry(id: e.id) ?? e
        changes.append(ToolChange(kind: .mealEdited, title: "Changed \(saved.slot.rawValue) · \(dayLabel(saved.day))",
                                  detail: old.portion != saved.portion
                                      ? "\(saved.food.name) · \(old.portion.description) → \(saved.portion.description)\(kcalText(saved.nutrients))"
                                      : entryDetail(saved),
                                  before: .meal(old), after: .meal(saved)))
        return ["entry": entryJSON(saved), "day_totals": totals(try store.summary(of: saved.day).totals)]
    }

    private func deleteMealEntry(_ r: inout ToolArgs, _ changes: inout [ToolChange]) throws -> JSONValue {
        let id = try r.string("entry_id", max: 120, required: true)!
        try r.done()
        guard let old = try store.entry(id: MealEntryID(id)) else {
            throw ToolError("entry_id: no meal entry \(id) (get_day lists the entries with their ids)")
        }
        try store.deleteEntry(id: old.id)
        changes.append(ToolChange(kind: .mealDeleted, title: "Removed from \(old.slot.rawValue) · \(dayLabel(old.day))",
                                  detail: entryDetail(old), before: .meal(old), after: nil))
        return ["deleted": entryJSON(old), "day_totals": totals(try store.summary(of: old.day).totals)]
    }

    // MARK: - Workouts

    private func sessionJSON(_ s: WorkoutSession) -> JSONValue {
        let ex: [JSONValue] = s.exercises.map { e in
            ["name": .string(e.name), "exercise_id": .string(e.exerciseID.rawValue), "kind": .string(e.kind.rawValue),
             "notes": e.notes.map(JSONValue.string) ?? .null,
             "sets": .array(e.sets.map { set in
                 ["reps": set.reps.map { .number(Double($0)) } ?? .null,
                  "kg": .rounded(set.weightKg, 1), "lb": .rounded(set.weightKg.map(WeightUnit.pound.fromKilograms), 1),
                  "duration_s": .rounded(set.duration, 0), "distance_m": .rounded(set.distanceMeters, 0),
                  "rpe": .rounded(set.rpe, 1), "warmup": set.isWarmup ? true : .null]
             })]
        }
        return ["workout_id": .string(s.id.rawValue), "date": .string(s.day(in: calendar).description),
                "title": .string(s.title), "duration_min": .rounded(s.duration.map { $0 / 60 }, 0),
                "notes": s.notes.map(JSONValue.string) ?? .null, "exercises": .array(ex)]
    }

    private func getWorkouts(_ r: inout ToolArgs) throws -> JSONValue {
        let from = try r.day("from", required: true)!
        let to = try r.day("to") ?? from
        try r.done()
        try checkDay(from, "from")
        try checkDay(to, "to")
        guard from <= to else { throw ToolError("from must be on or before to") }
        guard to <= from.adding(days: 30) else { throw ToolError("Ask for at most 31 days at a time.") }
        let interval = DateInterval(start: from.start(in: calendar),
                                    end: to.adding(days: 1).start(in: calendar).addingTimeInterval(-0.001))
        let sessions = try store.sessions(in: interval)
        return ["from": .string(from.description), "to": .string(to.description),
                "workouts": .array(sessions.map(sessionJSON))]
    }

    private func listExercises(_ r: inout ToolArgs) throws -> JSONValue {
        try r.done()
        return ["exercises": .array(try store.exercises().prefix(300).map {
            ["exercise_id": .string($0.id.rawValue), "name": .string($0.name), "kind": .string($0.kind.rawValue)]
        })]
    }

    /// the exercises of log_workout/edit_workout: library exercises by id or name, new names added to the library
    private func exercises(_ r: inout ToolArgs, _ changes: inout [ToolChange],
                           unitSeen: inout WeightUnit?) throws -> [SessionExercise] {
        var library = try store.exercises()
        var seenUnit = unitSeen
        let list = try r.objects("exercises", min: 1, max: 30, required: true) { e -> SessionExercise in
            let id = try e.string("exercise_id", max: 120)
            let name = try e.string("name", max: 80)
            let kind = try e.choice("kind", ExerciseKind.self)
            let notes = try e.string("notes", max: 200)
            let sets = try e.objects("sets", min: 1, max: 50, required: true) { s -> WorkoutSet in
                let reps = try s.int("reps", max: 1000)
                let weight = try s.number("weight", max: 2000)
                let unit = try s.choice("weight_unit", WeightUnitName.self)
                let duration = try s.number("duration_s", max: 86_400)
                let distance = try s.number("distance_m", max: 1_000_000)
                let rpe = try s.number("rpe", max: 10)
                let warmup = try s.bool("warmup") ?? false
                if weight != nil && unit == nil {
                    throw ToolError("\(s.path).weight_unit is required with a weight (lb or kg, as the user said)")
                }
                if reps == nil && weight == nil && duration == nil && distance == nil {
                    throw ToolError("\(s.path) has nothing in it: give reps, weight, duration_s or distance_m")
                }
                if let unit, weight != nil, seenUnit == nil { seenUnit = unit.unit }
                return WorkoutSet(reps: reps, weightKg: weight.map { (unit?.unit ?? .kilogram).toKilograms($0) },
                                  duration: duration, distanceMeters: distance, rpe: rpe, isWarmup: warmup)
            }!
            let exercise: Exercise
            if let id {
                guard let x = library.first(where: { $0.id.rawValue == id }) else {
                    throw ToolError("\(e.path).exercise_id: no exercise \(id) (list_exercises has them)")
                }
                exercise = x
            } else if let name {
                if let x = library.first(where: { $0.name.lowercased() == name.lowercased() }) {
                    exercise = x
                } else {
                    let x = Exercise(name: name, kind: kind ?? .strength)
                    try store.saveExercise(x)
                    library.append(x)
                    changes.append(ToolChange(kind: .exerciseAdded, title: "Added an exercise", detail: x.name,
                                              before: nil, after: .exercise(x)))
                    exercise = x
                }
            } else {
                throw ToolError("\(e.path) needs an exercise_id or a name")
            }
            return SessionExercise(exercise: exercise, sets: sets, notes: notes)
        }!
        unitSeen = seenUnit
        return list
    }

    private enum WeightUnitName: String, CaseIterable {
        case lb, kg
        var unit: WeightUnit { self == .lb ? .pound : .kilogram }
    }

    private func workoutDetail(_ s: WorkoutSession, unit: WeightUnit) -> String {
        let parts = s.exercises.map { e -> String in
            let working = e.workingSets
            if let first = working.first, working.count > 1, working.allSatisfy({ $0.reps == first.reps && $0.weightKg == first.weightKg }),
               let reps = first.reps {
                let load = first.weightKg.map { " @ \(Format.number(unit.fromKilograms($0), digits: 1)) \(unit.symbol)" } ?? ""
                return "\(e.name) \(working.count)×\(reps)\(load)"
            }
            return "\(e.name) \(e.sets.count) set\(e.sets.count == 1 ? "" : "s")"
        }
        return "\(s.title): \(parts.joined(separator: ", "))"
    }

    private func logWorkout(_ r: inout ToolArgs, _ changes: inout [ToolChange]) throws -> JSONValue {
        let day = try r.day("date") ?? today()
        let title = try r.string("title", max: 80) ?? "Workout"
        let minutes = try r.number("duration_min", max: 1440)
        let notes = try r.string("notes", max: 500)
        try checkDay(day, "date")
        var unit: WeightUnit?
        let list = try exercises(&r, &changes, unitSeen: &unit)
        try r.done()
        let length = (minutes ?? 0) * 60
        let start = day == today() ? now().addingTimeInterval(-length)
            : day.start(in: calendar).addingTimeInterval(17 * 3600)
        let s = WorkoutSession(title: title, startedAt: start, endedAt: start.addingTimeInterval(length),
                               exercises: list, notes: notes)
        try store.saveSession(s)
        let saved = try store.session(id: s.id) ?? s
        changes.append(ToolChange(kind: .workoutLogged, title: "Logged a workout · \(dayLabel(day))",
                                  detail: workoutDetail(saved, unit: unit ?? .kilogram), before: nil,
                                  after: .workout(saved)))
        return ["workout": sessionJSON(saved)]
    }

    private func editWorkout(_ r: inout ToolArgs, _ changes: inout [ToolChange]) throws -> JSONValue {
        let id = try r.string("workout_id", max: 120, required: true)!
        let day = try r.day("date")
        let title = try r.string("title", max: 80)
        let minutes = try r.number("duration_min", max: 1440)
        let notes = try r.string("notes", max: 500, allowEmpty: true)
        guard let old = try store.session(id: WorkoutSessionID(id)) else {
            throw ToolError("workout_id: no workout \(id) (get_workouts lists them with their ids)")
        }
        var unit: WeightUnit?
        let list = r.has("exercises") ? try exercises(&r, &changes, unitSeen: &unit) : nil
        try r.done()
        guard day != nil || title != nil || minutes != nil || notes != nil || list != nil else {
            throw ToolError("Nothing to change: give date, title, duration_min, notes or exercises.")
        }
        var s = old
        if let day {
            try checkDay(day, "date")
            let into = s.startedAt.timeIntervalSince(old.day(in: calendar).start(in: calendar))
            let length = s.duration ?? 0
            s.startedAt = day.start(in: calendar).addingTimeInterval(into)
            s.endedAt = s.endedAt.map { _ in s.startedAt.addingTimeInterval(length) }
        }
        if let title { s.title = title }
        if let minutes { s.endedAt = s.startedAt.addingTimeInterval(minutes * 60) }
        if let notes { s.notes = notes.isEmpty ? nil : notes }
        if let list { s.exercises = list }
        guard s != old else { throw ToolError("That's already how this workout is; nothing to change.") }
        try store.saveSession(s)
        let saved = try store.session(id: s.id) ?? s
        changes.append(ToolChange(kind: .workoutEdited, title: "Changed a workout · \(dayLabel(saved.day(in: calendar)))",
                                  detail: workoutDetail(saved, unit: unit ?? .kilogram), before: .workout(old),
                                  after: .workout(saved)))
        return ["workout": sessionJSON(saved)]
    }

    // MARK: - Recipes

    private func recipeSummary(_ x: Recipe) -> JSONValue {
        var o = ["recipe_id": JSONValue.string(x.id.rawValue), "name": .string(x.name), "servings": .rounded(x.servings, 2),
                 "per_serving": totals(x.perServing)]
        if !x.tags.isEmpty { o["tags"] = .array(x.tags.map(JSONValue.string)) }
        return .object(o)
    }

    private func recipeJSON(_ x: Recipe) -> JSONValue {
        var o = recipeSummary(x).object ?? [:]
        o["ingredients"] = .array(x.ingredients.map { i in
            ["food": .string(i.food.name), "food_id": .string(i.food.foodID.rawValue),
             "amount": .string(i.portion.description), "kcal": .rounded(i.nutrients[.energy], 0),
             "note": i.note.map(JSONValue.string) ?? .null]
        })
        o["steps"] = .array(x.steps.map(JSONValue.string))
        o["notes"] = x.notes.map(JSONValue.string) ?? .null
        o["cooked_weight_g"] = .rounded(x.cookedWeightGrams, 0)
        o["total"] = totals(x.totals)
        return .object(o)
    }

    private func recipeDetail(_ x: Recipe) -> String {
        let kcal = x.perServing.value(.energy).map { " · \(Format.number($0, digits: 0)) kcal a serving" } ?? ""
        return "\(x.name): \(x.ingredients.count) ingredient\(x.ingredients.count == 1 ? "" : "s"), \(Format.number(x.servings)) serving\(x.servings == 1 ? "" : "s")\(kcal)"
    }

    private func searchRecipes(_ r: inout ToolArgs) throws -> JSONValue {
        let query = try r.string("query", max: 80, required: true, allowEmpty: true)!
        try r.done()
        let all = try store.searchRecipes(query)
        return ["recipes": .array(all.prefix(20).map(recipeSummary)), "more": all.count > 20 ? .number(Double(all.count - 20)) : .null]
    }

    private func recipe(_ r: inout ToolArgs) throws -> Recipe {
        let id = try r.string("recipe_id", max: 120, required: true)!
        guard let x = try store.recipe(id: RecipeID(id)) else {
            throw ToolError("recipe_id: no recipe \(id) (search_recipes lists them with their ids)")
        }
        return x
    }

    private func getRecipe(_ r: inout ToolArgs) throws -> JSONValue {
        let x = try recipe(&r)
        try r.done()
        return ["recipe": recipeJSON(x)]
    }

    private func ingredients(_ r: inout ToolArgs, required: Bool, recipe: RecipeID?) throws -> [RecipeIngredient]? {
        try r.objects("ingredients", min: 1, max: 60, required: required) { i -> RecipeIngredient in
            let it = try item(&i, withNote: true)
            if let recipe, it.food.id == FoodID("recipe:\(recipe.rawValue)") {
                throw ToolError("\(i.path): a recipe can't be its own ingredient")
            }
            return RecipeIngredient(food: it.food, portion: it.portion, note: it.note)
        }
    }

    private func createRecipe(_ r: inout ToolArgs, _ changes: inout [ToolChange]) throws -> JSONValue {
        let name = try r.string("name", max: 120, required: true)!
        let servings = try r.number("servings", max: 1000, above: true, required: true)!
        let list = try ingredients(&r, required: true, recipe: nil)!
        let steps = try r.strings("steps", maxItems: 50, maxLength: 1000) ?? []
        let tags = try r.strings("tags", maxItems: 10, maxLength: 40) ?? []
        let notes = try r.string("notes", max: 1000)
        let weight = try r.number("cooked_weight_g", max: 100_000, above: true)
        try r.done()
        let x = Recipe(name: name, servings: servings, ingredients: list, steps: steps, notes: notes,
                       cookedWeightGrams: weight, tags: tags)
        try store.saveRecipe(x)
        let saved = try store.recipe(id: x.id) ?? x
        changes.append(ToolChange(kind: .recipeCreated, title: "Saved a recipe", detail: recipeDetail(saved),
                                  before: nil, after: .recipe(saved)))
        return ["recipe": recipeJSON(saved)]
    }

    private func editRecipe(_ r: inout ToolArgs, _ changes: inout [ToolChange]) throws -> JSONValue {
        let old = try recipe(&r)
        let name = try r.string("name", max: 120)
        let servings = try r.number("servings", max: 1000, above: true)
        let list = try ingredients(&r, required: false, recipe: old.id)
        let steps = try r.strings("steps", maxItems: 50, maxLength: 1000)
        let tags = try r.strings("tags", maxItems: 10, maxLength: 40)
        let notes = try r.string("notes", max: 1000, allowEmpty: true)
        let weight = try r.number("cooked_weight_g", max: 100_000)
        try r.done()
        var x = old
        if let name { x.name = name }
        if let servings { x.servings = servings }
        if let list { x.ingredients = list }
        if let steps { x.steps = steps }
        if let tags { x.tags = tags }
        if let notes { x.notes = notes.isEmpty ? nil : notes }
        if let weight { x.cookedWeightGrams = weight > 0 ? weight : nil }
        guard x != old else { throw ToolError("Nothing to change (give what should be different).") }
        try store.saveRecipe(x)
        let saved = try store.recipe(id: x.id) ?? x
        changes.append(ToolChange(kind: .recipeEdited, title: "Changed a recipe", detail: recipeDetail(saved),
                                  before: .recipe(old), after: .recipe(saved)))
        return ["recipe": recipeJSON(saved)]
    }

    private func logRecipe(_ r: inout ToolArgs, _ changes: inout [ToolChange]) throws -> JSONValue {
        let x = try recipe(&r)
        let servings = try r.number("servings", max: 50, above: true, required: true)!
        let slot = try r.choice("meal", MealSlot.self, required: true)!
        let day = try r.day("date") ?? today()
        try r.done()
        try checkDay(day, "date")
        let food = x.asFood()
        let p = food.baseUnit == .serving ? Portion(servings, .base(.serving)) : try food.portion(servings, serving: "serving")
        let e = try MealEntry(food: food, portion: p, day: day, slot: slot, loggedAt: loggedAt(day, slot))
        try store.saveEntry(e)
        let saved = try store.entry(id: e.id) ?? e
        changes.append(ToolChange(kind: .mealLogged, title: "Logged to \(slot.rawValue) · \(dayLabel(day))",
                                  detail: entryDetail(saved), before: nil, after: .meal(saved)))
        return ["logged": entryJSON(saved), "day_totals": totals(try store.summary(of: day).totals)]
    }
}
