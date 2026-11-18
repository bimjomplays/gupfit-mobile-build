import Foundation

// The logic behind the app's forms, kept here so it is tested on Linux: what a typed number means, turning a filled-in
// food form into a Food, and small helpers the screens share.

enum NumberInput {
    /// a typed number: "1.5", "1,5", " 2 " → the value; "" → nil; anything else → nil
    static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let v = Double(t), v.isFinite else { return nil }
        return v
    }

    /// true when the text is empty or a number
    static func isValid(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty || parse(text) != nil
    }

    /// the text a number field shows for a value ("" for nil)
    static func text(_ value: Double?, digits: Int = 2) -> String {
        value.map { Format.number($0, digits: digits) } ?? ""
    }
}

/// A named serving being typed in: "1 slice" = "28" (in the food's base unit).
struct ServingDraft: Identifiable, Hashable, Sendable {
    var id = UUID()
    var label = ""
    var amount = ""
}

/// The "my food" form: text as typed, turned into a Food (or every problem at once) by `makeFood()`.
struct FoodDraft: Identifiable, Hashable, Sendable {
    /// set when editing an existing food (it keeps its id); nil for a new one
    var id: FoodID?
    var name = ""
    var brand = ""
    var baseUnit: BaseUnit = .gram
    /// how much the nutrients describe, in the base unit ("100" g, "1" serving)
    var referenceAmount = "100"
    var nutrients: [Nutrient: String] = [:]
    var servings: [ServingDraft] = []

    /// the nutrients the form asks for, in order
    static let fields: [Nutrient] = [.energy, .protein, .carbohydrate, .fat, .fiber, .sugars, .saturatedFat, .sodium]

    init() {}

    init(food: Food) {
        id = food.id
        name = food.name
        brand = food.brand ?? ""
        baseUnit = food.baseUnit
        referenceAmount = Format.number(food.referenceAmount, digits: 3)
        for n in Nutrient.allCases { if let v = food.nutrients[n] { nutrients[n] = Format.number(v, digits: 3) } }
        servings = food.servings.map { ServingDraft(label: $0.label, amount: Format.number($0.amount, digits: 3)) }
    }

    /// switching to "per serving" makes the reference one serving; back to grams or ml, 100
    mutating func setBaseUnit(_ unit: BaseUnit) {
        guard unit != baseUnit else { return }
        if unit == .serving { referenceAmount = "1" } else if baseUnit == .serving { referenceAmount = "100" }
        baseUnit = unit
    }

    /// The food, or a ValidationError naming every field that's wrong. Calories are required (a food without them
    /// can't count toward the day); other nutrients left empty are unknown, not zero.
    func makeFood() throws -> Food {
        var check = Checker()
        var values: [Nutrient: Double] = [:]
        for (n, text) in nutrients {
            if !NumberInput.isValid(text) { check.add("nutrients.\(n.rawValue)", .notFinite) }
            if let v = NumberInput.parse(text) { values[n] = v }
        }
        if values[.energy] == nil && NumberInput.isValid(nutrients[.energy] ?? "") {
            check.add("nutrients.energy", .empty)
        }
        let reference = NumberInput.parse(referenceAmount)
        if reference == nil { check.add("referenceAmount", NumberInput.isValid(referenceAmount) ? .empty : .notFinite) }

        var parsed: [Serving] = []
        for (i, s) in servings.enumerated() {
            let label = s.label.trimmingCharacters(in: .whitespaces)
            if label.isEmpty && s.amount.trimmingCharacters(in: .whitespaces).isEmpty { continue }  // an empty row
            guard let amount = NumberInput.parse(s.amount) else {
                check.add("servings[\(i)].amount", NumberInput.isValid(s.amount) ? .empty : .notFinite)
                continue
            }
            parsed.append(Serving(label, amount: amount))
        }
        let brand = brand.trimmingCharacters(in: .whitespaces)
        let food = Food(id: id ?? .new(), name: name.trimmingCharacters(in: .whitespaces), brand: brand.isEmpty ? nil : brand,
                        source: .user, baseUnit: baseUnit, referenceAmount: reference ?? 1,
                        nutrients: NutrientProfile(values), servings: parsed)
        let issues = check.issues + food.validationIssues()
        if !issues.isEmpty { throw ValidationError(issues: issues) }
        return food
    }
}

enum RecipeText {
    /// one step per non-empty line
    static func steps(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func text(from steps: [String]) -> String { steps.joined(separator: "\n") }

    /// "meal prep, quick" → ["meal prep", "quick"]
    static func tags(from text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

extension FoodSnapshot {
    /// a Food with this snapshot's numbers (no named servings: only the standard units of its base unit)
    var asFood: Food {
        Food(id: foodID, name: name, brand: brand, source: source, baseUnit: baseUnit, referenceAmount: referenceAmount,
             nutrients: nutrients)
    }
}

extension Recipe {
    /// the food id a logged serving of this recipe has (`Recipe.asFood()`)
    static func recipeID(fromFoodID id: FoodID) -> RecipeID? {
        id.rawValue.hasPrefix("recipe:") ? RecipeID(String(id.rawValue.dropFirst("recipe:".count))) : nil
    }
}

extension MealSlot {
    /// the meal a food logged at `date` most likely belongs to
    static func suggested(at date: Date, calendar: Calendar = .current) -> MealSlot {
        switch calendar.component(.hour, from: date) {
        case 4..<11: .breakfast
        case 11..<15: .lunch
        case 17..<22: .dinner
        default: .snack
        }
    }
}

extension WorkoutSet {
    /// the next set: the same numbers, a new id, a working set counted as done (most sets are logged after doing
    /// them; untick one that wasn't)
    func next() -> WorkoutSet {
        WorkoutSet(reps: reps, weightKg: weightKg, duration: duration, distanceMeters: distanceMeters, isWarmup: false,
                   isCompleted: true)
    }
}

extension Portion {
    /// the same amount in another serving of the same food ("150 g" → "1.25 × 1 cup" for a 120 g cup)
    func converted(to serving: Serving) -> Portion {
        Portion(serving.amount > 0 ? baseAmount / serving.amount : count, serving)
    }
}
