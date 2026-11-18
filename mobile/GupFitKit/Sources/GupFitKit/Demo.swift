import Foundation

/// The app's tabs, in order.
enum AppTab: String, CaseIterable, Hashable, Sendable {
    case today, workouts, recipes, chat

    var title: String { rawValue.capitalized }

    /// SF Symbol
    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .workouts: "dumbbell"
        case .recipes: "book.closed"
        case .chat: "bubble.left.and.text.bubble.right"
        }
    }
}

/// Invented demo data for previews, the simulator and screenshot tests until the real store lands. Nothing here is
/// anyone's real log; the numbers are round so a screenshot is easy to check by eye.
enum Demo {
    static let oats = Food(id: "demo-oats", name: "Rolled oats", nutrients: NutrientProfile([
        .energy: 380, .protein: 13, .carbohydrate: 67, .fat: 7, .fiber: 10, .sugars: 1, .sodium: 5,
    ]), servings: [Serving("½ cup", amount: 40)])
    static let banana = Food(id: "demo-banana", name: "Banana", nutrients: NutrientProfile([
        .energy: 90, .protein: 1, .carbohydrate: 23, .fat: 0.3, .fiber: 2.6, .sugars: 12,
    ]), servings: [Serving("1 medium", amount: 120)])
    static let chicken = Food(id: "demo-chicken", name: "Chicken breast, grilled", nutrients: NutrientProfile([
        .energy: 165, .protein: 31, .carbohydrate: 0, .fat: 3.6, .fiber: 0, .sodium: 75,
    ]))
    static let rice = Food(id: "demo-rice", name: "Rice, cooked", nutrients: NutrientProfile([
        .energy: 130, .protein: 2.7, .carbohydrate: 28, .fat: 0.3, .fiber: 0.4,
    ]), servings: [Serving("1 cup", amount: 160)])
    static let yogurt = Food(id: "demo-yogurt", name: "Greek yogurt, plain", baseUnit: .gram, nutrients: NutrientProfile([
        .energy: 60, .protein: 10, .carbohydrate: 3.6, .fat: 0.4,
    ]), servings: [Serving("1 cup", amount: 225)])

    static let foods = [oats, banana, chicken, rice, yogurt]

    static let squat = Exercise(id: "demo-squat", name: "Back squat", muscles: ["legs"])
    static let bench = Exercise(id: "demo-bench", name: "Bench press", muscles: ["chest"])
    static let run = Exercise(id: "demo-run", name: "Run", kind: .cardio)

    /// a store holding the demo foods, a logged `day` (breakfast and lunch), one workout and one recipe
    static func store(day: LocalDay, calendar: Calendar = .current) -> InMemoryStore {
        let store = InMemoryStore()
        let start = day.start(in: calendar)
        func at(_ hour: Double) -> Date { start.addingTimeInterval(hour * 3600) }
        do {
            for food in foods { try store.saveFood(food) }
            for e in [squat, bench, run] { try store.saveExercise(e) }
            let entries = [
                try MealEntry(id: "demo-e1", food: oats, portion: oats.portion(1, serving: "½ cup"), day: day,
                              slot: .breakfast, loggedAt: at(7.5)),
                try MealEntry(id: "demo-e2", food: banana, portion: banana.portion(1, serving: "1 medium"), day: day,
                              slot: .breakfast, loggedAt: at(7.6)),
                try MealEntry(id: "demo-e3", food: chicken, portion: chicken.portion(150, .gram), day: day,
                              slot: .lunch, loggedAt: at(12.5)),
                try MealEntry(id: "demo-e4", food: rice, portion: rice.portion(1, serving: "1 cup"), day: day,
                              slot: .lunch, loggedAt: at(12.6)),
            ]
            for e in entries { try store.saveEntry(e) }
            try store.saveSession(WorkoutSession(id: "demo-w1", title: "Legs", startedAt: at(17), endedAt: at(18), exercises: [
                SessionExercise(exercise: squat, sets: [
                    WorkoutSet(reps: 5, weightKg: 60, isWarmup: true),
                    WorkoutSet(reps: 5, weightKg: 100), WorkoutSet(reps: 5, weightKg: 100), WorkoutSet(reps: 5, weightKg: 100),
                ]),
            ]))
            try store.saveRecipe(Recipe(id: "demo-r1", name: "Chicken rice bowl", servings: 4, ingredients: [
                RecipeIngredient(food: chicken, portion: try chicken.portion(600, .gram)),
                RecipeIngredient(food: rice, portion: try rice.portion(4, serving: "1 cup")),
            ], steps: ["Cook the rice.", "Grill the chicken and slice it.", "Split into four bowls."],
                                        tags: ["meal prep"]))
        } catch {
            preconditionFailure("demo data is invalid: \(error)")
        }
        return store
    }

    static let goals = NutritionGoals(energy: 2200, protein: 160, carbohydrate: 220, fat: 70)
}
