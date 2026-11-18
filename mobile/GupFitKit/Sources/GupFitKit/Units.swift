import Foundation

/// What a food's amounts are counted in. Every quantity of a food (a serving, "6 oz", "1 cup") turns into an amount
/// in its base unit, and its nutrients scale with that amount. Mass and volume never convert into each other (that
/// needs the food's density); a food with no weight (a protein bar, a recipe without a cooked weight) counts servings.
enum BaseUnit: String, Codable, CaseIterable, Sendable {
    case gram, milliliter, serving
}

/// The standard units a portion can be entered in, with their size in the base unit.
enum MeasureUnit: String, Codable, CaseIterable, Sendable {
    case gram, kilogram, ounce, pound
    case milliliter, liter, teaspoon, tablespoon, fluidOunce, cup

    var base: BaseUnit {
        switch self {
        case .gram, .kilogram, .ounce, .pound: .gram
        case .milliliter, .liter, .teaspoon, .tablespoon, .fluidOunce, .cup: .milliliter
        }
    }

    /// how many base units (grams or milliliters) one of these is; US customary for the kitchen measures
    var factor: Double {
        switch self {
        case .gram, .milliliter: 1
        case .kilogram, .liter: 1000
        case .ounce: 28.349523125
        case .pound: 453.59237
        case .teaspoon: 4.92892159375
        case .tablespoon: 14.78676478125
        case .fluidOunce: 29.5735295625
        case .cup: 236.5882365
        }
    }

    var symbol: String {
        switch self {
        case .gram: "g"
        case .kilogram: "kg"
        case .ounce: "oz"
        case .pound: "lb"
        case .milliliter: "ml"
        case .liter: "l"
        case .teaspoon: "tsp"
        case .tablespoon: "tbsp"
        case .fluidOunce: "fl oz"
        case .cup: "cup"
        }
    }

    static func units(for base: BaseUnit) -> [MeasureUnit] { allCases.filter { $0.base == base } }
}

/// Lifted weights are stored in kilograms; this converts for display and entry.
enum WeightUnit: String, Codable, CaseIterable, Sendable {
    case kilogram, pound

    static let poundInKilograms = 0.45359237

    func toKilograms(_ value: Double) -> Double { self == .kilogram ? value : value * Self.poundInKilograms }
    func fromKilograms(_ kilograms: Double) -> Double { self == .kilogram ? kilograms : kilograms / Self.poundInKilograms }

    var symbol: String { self == .kilogram ? "kg" : "lb" }
}

enum Format {
    /// a number with at most `digits` decimals and no trailing zeros, the same on every locale: 12, 12.5, 0.33
    static func number(_ value: Double, digits: Int = 2) -> String {
        guard value.isFinite else { return "—" }
        let scale = pow(10, Double(digits))
        let rounded = (value * scale).rounded() / scale
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var text = String(format: "%.\(digits)f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
