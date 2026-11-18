import Foundation

/// One ingredient: a portion of a food, with the food's nutrition copied in when it was added (so the recipe stays
/// whole on its own, for the AI chat and offline; `Recipe.refreshed(with:)` takes newer numbers on purpose).
struct RecipeIngredient: Identifiable, Hashable, Codable, Sendable, Validatable {
    var id: RecipeIngredientID
    var food: FoodSnapshot
    var portion: Portion
    var note: String?

    init(id: RecipeIngredientID = .new(), food: Food, portion: Portion, note: String? = nil) {
        self.id = id
        self.food = food.snapshot
        self.portion = portion
        self.note = note
    }

    /// an ingredient as it was stored
    init(id: RecipeIngredientID, snapshot: FoodSnapshot, portion: Portion, note: String? = nil) {
        self.id = id
        food = snapshot
        self.portion = portion
        self.note = note
    }

    var nutrients: NutrientProfile { food.nutrients(for: portion) }

    func validationIssues() -> [ValidationIssue] {
        var check = Checker()
        check.nested(food, "food")
        check.nested(portion, "portion")
        return check.issues
    }
}

struct Recipe: Identifiable, Hashable, Codable, Sendable, Validatable {
    var id: RecipeID
    var name: String
    /// how many servings the whole recipe makes
    var servings: Double
    var ingredients: [RecipeIngredient]
    var steps: [String]
    var notes: String?
    /// the finished dish's weight, when known, so it can be logged by the gram
    var cookedWeightGrams: Double?
    var tags: [String]

    init(id: RecipeID = .new(), name: String, servings: Double, ingredients: [RecipeIngredient] = [],
         steps: [String] = [], notes: String? = nil, cookedWeightGrams: Double? = nil, tags: [String] = []) {
        self.id = id
        self.name = name
        self.servings = servings
        self.ingredients = ingredients
        self.steps = steps
        self.notes = notes
        self.cookedWeightGrams = cookedWeightGrams
        self.tags = tags
    }

    /// the whole recipe
    var totals: NutrientTotals { NutrientTotals(ingredients.map(\.nutrients)) }

    /// one serving (zero servings gives an empty total; validation rejects that recipe anyway)
    var perServing: NutrientTotals { servings > 0 ? totals.divided(by: servings) : .zero }

    /// This recipe as a food to log. With a cooked weight it's measured in grams (with a "serving" of weight ÷
    /// servings); without, in servings. The snapshot a meal entry takes of it then keeps that day's numbers.
    /// Partial totals become plain values here: the food records what's known.
    func asFood() -> Food {
        if let weight = cookedWeightGrams, weight > 0, servings > 0 {
            return Food(id: FoodID("recipe:\(id.rawValue)"), name: name, source: .recipe(id), baseUnit: .gram,
                        referenceAmount: weight, nutrients: totals.profile,
                        servings: [Serving("serving", amount: weight / servings)])
        }
        return Food(id: FoodID("recipe:\(id.rawValue)"), name: name, source: .recipe(id), baseUnit: .serving,
                    referenceAmount: 1, nutrients: perServing.profile, servings: [Serving.base(.serving)])
    }

    /// the same recipe with every ingredient's nutrition taken again from `foods` (ingredients whose food is gone
    /// keep their copy)
    func refreshed(with foods: [FoodID: Food]) -> Recipe {
        var copy = self
        for i in copy.ingredients.indices {
            if let food = foods[copy.ingredients[i].food.foodID] { copy.ingredients[i].food = food.snapshot }
        }
        return copy
    }

    func validationIssues() -> [ValidationIssue] {
        var check = Checker()
        check.nonEmpty(name, "name")
        check.positive(servings, "servings")
        check.positive(cookedWeightGrams, "cookedWeightGrams")
        for (i, ing) in ingredients.enumerated() { check.nested(ing, "ingredients[\(i)]") }
        return check.issues
    }
}
