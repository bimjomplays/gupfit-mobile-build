import Foundation

enum NutrientUnit: String, Codable, Sendable {
    case kcal, g, mg
}

/// The nutrients GupFit tracks. The raw values are the stored keys (JSON, SQLite), so don't rename them.
enum Nutrient: String, Codable, CaseIterable, Sendable {
    case energy
    case protein, carbohydrate, fat
    case fiber, sugars, saturatedFat, alcohol
    case cholesterol, sodium, potassium, calcium, iron

    var unit: NutrientUnit {
        switch self {
        case .energy: .kcal
        case .protein, .carbohydrate, .fat, .fiber, .sugars, .saturatedFat, .alcohol: .g
        case .cholesterol, .sodium, .potassium, .calcium, .iron: .mg
        }
    }

    /// the column in the bundled USDA catalog's `nutrients` table (data/catalog.sqlite, tools/catalog/README.md),
    /// whose values are per 100 g with NULL for unknown; alcohol isn't in the catalog
    var catalogColumn: String? {
        switch self {
        case .energy: "kcal"
        case .protein: "protein_g"
        case .carbohydrate: "carbs_g"
        case .fat: "fat_g"
        case .fiber: "fiber_g"
        case .sugars: "sugar_g"
        case .saturatedFat: "sat_fat_g"
        case .alcohol: nil
        case .cholesterol: "cholesterol_mg"
        case .sodium: "sodium_mg"
        case .potassium: "potassium_mg"
        case .calcium: "calcium_mg"
        case .iron: "iron_mg"
        }
    }

    var name: String {
        switch self {
        case .energy: "Calories"
        case .protein: "Protein"
        case .carbohydrate: "Carbs"
        case .fat: "Fat"
        case .fiber: "Fiber"
        case .sugars: "Sugars"
        case .saturatedFat: "Saturated fat"
        case .alcohol: "Alcohol"
        case .cholesterol: "Cholesterol"
        case .sodium: "Sodium"
        case .potassium: "Potassium"
        case .calcium: "Calcium"
        case .iron: "Iron"
        }
    }

    static let macros: [Nutrient] = [.protein, .carbohydrate, .fat]
}

/// Nutrient amounts for some quantity of food. A nutrient that isn't there is *unknown* (the source didn't say), which
/// is not the same as zero: `profile[.fiber] == nil` means unknown, `== 0` means the food has none.
///
/// Stored as a flat JSON object keyed by the nutrients' raw values (`{"energy": 52, "protein": 0.3}`); keys a newer
/// version added are skipped when reading, so old builds can still read new data.
struct NutrientProfile: Hashable, Codable, Sendable, Validatable {
    private(set) var values: [Nutrient: Double]

    init(_ values: [Nutrient: Double] = [:]) { self.values = values }

    /// nil when unknown; setting nil forgets the value
    subscript(_ nutrient: Nutrient) -> Double? {
        get { values[nutrient] }
        set { values[nutrient] = newValue }
    }

    var isEmpty: Bool { values.isEmpty }
    var known: Set<Nutrient> { Set(values.keys) }

    /// every known amount times `factor` (a portion of a reference amount); unknown stays unknown
    func scaled(by factor: Double) -> NutrientProfile {
        NutrientProfile(values.mapValues { $0 * factor })
    }

    /// Calories from the macros (Atwater 4/4/9, alcohol 7), when protein, carbs and fat are all known. For checking a
    /// label or estimating when a source has no energy value; GupFit never fills `.energy` in on its own.
    var caloriesFromMacros: Double? {
        guard let p = values[.protein], let c = values[.carbohydrate], let f = values[.fat] else { return nil }
        return p * 4 + c * 4 + f * 9 + (values[.alcohol] ?? 0) * 7
    }

    func validationIssues() -> [ValidationIssue] {
        var check = Checker()
        for n in Nutrient.allCases { check.nonNegative(values[n], n.rawValue) }
        return check.issues
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Double].self)
        var values: [Nutrient: Double] = [:]
        for (key, value) in raw {
            if let n = Nutrient(rawValue: key) { values[n] = value }
        }
        self.values = values
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }))
    }
}

/// The sum of several items' nutrients (a meal, a day, a recipe), keeping track of what was unknown:
/// - a nutrient no item knows is unknown in the total (`value` nil), not zero;
/// - a nutrient only some items know is *partial*: the total is at least `value` (shown as "12 g+");
/// - nothing at all sums to zero for every nutrient (an empty day really has 0 calories).
struct NutrientTotals: Hashable, Sendable {
    /// the sum of the known amounts
    private(set) var profile: NutrientProfile
    /// nutrients some items didn't know, so the sum is a lower bound
    private(set) var partial: Set<Nutrient>
    private(set) var itemCount: Int

    static let zero = NutrientTotals(profile: NutrientProfile(), partial: [], itemCount: 0)

    init<S: Sequence>(_ items: S) where S.Element == NutrientProfile {
        let items = Array(items)
        var values: [Nutrient: Double] = [:]
        var partial: Set<Nutrient> = []
        for n in Nutrient.allCases {
            let known = items.compactMap { $0[n] }
            if !known.isEmpty { values[n] = known.reduce(0, +) }
            if !known.isEmpty && known.count < items.count { partial.insert(n) }
        }
        self.init(profile: NutrientProfile(values), partial: partial, itemCount: items.count)
    }

    private init(profile: NutrientProfile, partial: Set<Nutrient>, itemCount: Int) {
        self.profile = profile
        self.partial = partial
        self.itemCount = itemCount
    }

    /// the total, nil when no item knows it (and 0 when there are no items)
    func value(_ nutrient: Nutrient) -> Double? {
        itemCount == 0 ? 0 : profile[nutrient]
    }

    subscript(_ nutrient: Nutrient) -> Double? { value(nutrient) }

    func isPartial(_ nutrient: Nutrient) -> Bool { partial.contains(nutrient) }

    /// every amount divided evenly (a recipe's total per serving); what was partial stays partial
    func divided(by count: Double) -> NutrientTotals {
        NutrientTotals(profile: profile.scaled(by: 1 / count), partial: partial, itemCount: itemCount)
    }

    /// "52 kcal", "12 g+" (partial), "—" (unknown)
    func formatted(_ nutrient: Nutrient, digits: Int = 0) -> String {
        guard let v = value(nutrient) else { return "—" }
        return "\(Format.number(v, digits: digits)) \(nutrient.unit.rawValue)\(isPartial(nutrient) ? "+" : "")"
    }
}
