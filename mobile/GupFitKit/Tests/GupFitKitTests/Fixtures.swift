import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

// Invented foods for the tests, with round numbers so the expected totals are easy to check by hand.
enum Sample {
    /// per 100 g; fiber known, cholesterol unknown
    static let apple = Food(id: "apple", name: "Apple, raw", source: .usda(fdcID: 1), nutrients: NutrientProfile([
        .energy: 52, .protein: 0.3, .carbohydrate: 14, .fat: 0.2, .fiber: 2.4, .sugars: 10, .sodium: 1,
    ]), servings: [Serving("1 medium", amount: 182)])

    /// per 100 g; fiber genuinely zero
    static let chicken = Food(id: "chicken", name: "Chicken breast, cooked", nutrients: NutrientProfile([
        .energy: 165, .protein: 31, .carbohydrate: 0, .fat: 3.6, .fiber: 0, .sodium: 74, .cholesterol: 85,
    ]))

    /// per 100 ml; no fiber value
    static let milk = Food(id: "milk", name: "Milk, 2%", baseUnit: .milliliter, nutrients: NutrientProfile([
        .energy: 50, .protein: 3.3, .carbohydrate: 4.8, .fat: 2,
    ]), servings: [Serving("glass", amount: 250)])

    /// per bar, no weight known
    static let bar = Food(id: "bar", name: "Protein bar", brand: "Acme", baseUnit: .serving, referenceAmount: 1,
                          nutrients: NutrientProfile([.energy: 200, .protein: 20, .carbohydrate: 22, .fat: 7]),
                          servings: [Serving("bar", amount: 1)])

    static let rice = Food(id: "rice", name: "Rice, white, cooked", nutrients: NutrientProfile([
        .energy: 130, .protein: 2.7, .carbohydrate: 28, .fat: 0.3, .fiber: 0.4,
    ]))

    static let day = LocalDay(year: 2026, month: 11, day: 17)

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
}

func assertClose(_ a: Double?, _ b: Double, accuracy: Double = 1e-9, _ message: String = "",
                 file: StaticString = #filePath, line: UInt = #line) {
    guard let a else { return XCTFail("nil, expected \(b) \(message)", file: file, line: line) }
    XCTAssertEqual(a, b, accuracy: accuracy, message, file: file, line: line)
}

