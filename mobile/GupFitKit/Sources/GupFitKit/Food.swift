import Foundation

/// Where a food's numbers came from.
enum FoodSource: Hashable, Codable, Sendable {
    /// typed in on the phone (or by the AI chat)
    case user
    /// the bundled USDA FoodData Central catalog
    case usda(fdcID: Int)
    /// made from a recipe (`Recipe.asFood()`)
    case recipe(RecipeID)
}

/// A named amount of a food in its base unit: "1 cup, chopped" = 128 g, "1 bar" = 1 serving.
struct Serving: Hashable, Codable, Sendable, Validatable {
    var label: String
    /// in the food's base unit
    var amount: Double

    init(_ label: String, amount: Double) {
        self.label = label
        self.amount = amount
    }

    /// one gram, one ounce, one cup …; only valid for a food whose base unit is `unit.base`
    static func standard(_ unit: MeasureUnit) -> Serving { Serving(unit.symbol, amount: unit.factor) }

    /// one base unit ("g", "ml", "serving")
    static func base(_ unit: BaseUnit) -> Serving {
        switch unit {
        case .gram: .standard(.gram)
        case .milliliter: .standard(.milliliter)
        case .serving: Serving("serving", amount: 1)
        }
    }

    func validationIssues() -> [ValidationIssue] {
        var check = Checker()
        check.nonEmpty(label, "label")
        check.positive(amount, "amount")
        return check.issues
    }
}

/// How much was eaten or used: `count` of a serving. "150 g" is 150 × the 1 g serving, "1.5 cups" 1.5 × "cup".
struct Portion: Hashable, Codable, Sendable, Validatable {
    var count: Double
    var serving: Serving

    init(_ count: Double, _ serving: Serving) {
        self.count = count
        self.serving = serving
    }

    /// the amount in the food's base unit
    var baseAmount: Double { count * serving.amount }

    /// "150 g", "1.5 × cup"
    var description: String {
        let n = Format.number(count)
        return MeasureUnit.allCases.contains { $0.symbol == serving.label } ? "\(n) \(serving.label)" : "\(n) × \(serving.label)"
    }

    func validationIssues() -> [ValidationIssue] {
        var check = Checker()
        check.positive(count, "count")
        check.nested(serving, "serving")
        return check.issues
    }
}

/// A food: nutrients per reference amount (USDA: per 100 g), plus its named servings.
struct Food: Identifiable, Hashable, Codable, Sendable, Validatable {
    var id: FoodID
    var name: String
    var brand: String?
    var source: FoodSource
    var baseUnit: BaseUnit
    /// how much of the base unit `nutrients` describe (100 for per-100 g, 1 for per serving)
    var referenceAmount: Double
    var nutrients: NutrientProfile
    /// named servings besides the standard units ("1 medium", "1 cup, sliced")
    var servings: [Serving]

    init(id: FoodID = .new(), name: String, brand: String? = nil, source: FoodSource = .user,
         baseUnit: BaseUnit = .gram, referenceAmount: Double = 100, nutrients: NutrientProfile,
         servings: [Serving] = []) {
        self.id = id
        self.name = name
        self.brand = brand
        self.source = source
        self.baseUnit = baseUnit
        self.referenceAmount = referenceAmount
        self.nutrients = nutrients
        self.servings = servings
    }

    /// the copy kept with a meal entry or recipe ingredient
    var snapshot: FoodSnapshot {
        FoodSnapshot(foodID: id, name: name, brand: brand, source: source, baseUnit: baseUnit,
                     referenceAmount: referenceAmount, nutrients: nutrients)
    }

    func nutrients(for portion: Portion) -> NutrientProfile { snapshot.nutrients(for: portion) }

    /// every serving a portion can be in: the food's own, then the standard units of its base unit
    var servingOptions: [Serving] {
        let standard = baseUnit == .serving ? [Serving.base(.serving)] : MeasureUnit.units(for: baseUnit).map(Serving.standard)
        return servings + standard.filter { s in !servings.contains { $0.label == s.label } }
    }

    /// `count` of a standard unit; throws when the unit is the wrong kind for this food (cups of a food in grams)
    func portion(_ count: Double, _ unit: MeasureUnit) throws -> Portion {
        guard unit.base == baseUnit else {
            throw ValidationError(issues: [ValidationIssue(field: "unit", problem: .unitMismatch(expected: baseUnit, got: unit.base))])
        }
        let portion = Portion(count, .standard(unit))
        try portion.validate()
        return portion
    }

    /// `count` of a serving by its label (case-insensitive): one of the food's own or a standard unit's symbol
    func portion(_ count: Double, serving label: String) throws -> Portion {
        let wanted = label.trimmingCharacters(in: .whitespaces).lowercased()
        guard let serving = servingOptions.first(where: { $0.label.lowercased() == wanted }) else {
            throw ValidationError(issues: [ValidationIssue(field: "serving", problem: .unknownServing(label))])
        }
        let portion = Portion(count, serving)
        try portion.validate()
        return portion
    }

    func validationIssues() -> [ValidationIssue] {
        var check = Checker()
        check.nonEmpty(name, "name")
        check.positive(referenceAmount, "referenceAmount")
        check.nested(nutrients, "nutrients")
        for (i, s) in servings.enumerated() { check.nested(s, "servings[\(i)]") }
        return check.issues
    }
}

/// A food's name and nutrition as they were when it was logged or added to a recipe. Meal entries keep this, so
/// editing or deleting the food later never changes what a past day added up to.
struct FoodSnapshot: Hashable, Codable, Sendable, Validatable {
    var foodID: FoodID
    var name: String
    var brand: String?
    var source: FoodSource
    var baseUnit: BaseUnit
    var referenceAmount: Double
    var nutrients: NutrientProfile

    /// the nutrients in `portion` (its base amount over the reference amount)
    func nutrients(for portion: Portion) -> NutrientProfile {
        nutrients.scaled(by: portion.baseAmount / referenceAmount)
    }

    func validationIssues() -> [ValidationIssue] {
        var check = Checker()
        check.nonEmpty(name, "name")
        check.positive(referenceAmount, "referenceAmount")
        check.nested(nutrients, "nutrients")
        return check.issues
    }
}

enum FoodSearch {
    /// lowercased, accents and extra spaces dropped: "Crème  Brûlée" → "creme brulee"
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .joined(separator: " ")
    }

    /// every word of the query starts a word of the name or brand ("chick bre" finds "Chicken, breast")
    static func matches(_ query: String, name: String, brand: String? = nil) -> Bool {
        let words = normalize([name, brand ?? ""].joined(separator: " ")).split(separator: " ")
        let wanted = normalize(query).split(separator: " ")
        return wanted.allSatisfy { q in words.contains { $0.hasPrefix(q) } }
    }
}
