import Foundation

/// One thing wrong with a record, named by its field path (`servings[1].amount`), so a form can point at the field
/// and the AI chat can say exactly what it couldn't save.
struct ValidationIssue: Hashable, Sendable, CustomStringConvertible {
    enum Problem: Hashable, Sendable {
        /// below zero (amounts, nutrients, reps, weights)
        case negative
        /// zero where only a positive amount makes sense (a portion, a recipe's servings)
        case notPositive
        /// NaN or infinity
        case notFinite
        /// a name or label that is empty or only spaces
        case empty
        case outOfRange(ClosedRange<Double>)
        /// a workout that ends before it starts
        case endsBeforeStart
        /// a unit of another kind than the food's base unit (cups of a food measured in grams)
        case unitMismatch(expected: BaseUnit, got: BaseUnit)
        /// a serving name the food doesn't have
        case unknownServing(String)
    }

    var field: String
    var problem: Problem

    var description: String {
        switch problem {
        case .negative: "\(field) can't be negative"
        case .notPositive: "\(field) must be more than zero"
        case .notFinite: "\(field) must be a number"
        case .empty: "\(field) can't be empty"
        case .outOfRange(let r): "\(field) must be between \(Format.number(r.lowerBound)) and \(Format.number(r.upperBound))"
        case .endsBeforeStart: "\(field) is before the start"
        case .unitMismatch(let expected, let got): "\(field) is in \(got.rawValue)s, but this food is measured in \(expected.rawValue)s"
        case .unknownServing(let name): "\(field): this food has no serving called \"\(name)\""
        }
    }
}

struct ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    var issues: [ValidationIssue]
    var description: String { issues.map(\.description).joined(separator: "; ") }
}

/// A record that can say what is wrong with it. `validate()` throws all its issues at once.
protocol Validatable {
    func validationIssues() -> [ValidationIssue]
}

extension Validatable {
    func validate() throws {
        let issues = validationIssues()
        if !issues.isEmpty { throw ValidationError(issues: issues) }
    }

    var isValid: Bool { validationIssues().isEmpty }
}

/// Collects issues while a record checks its fields.
struct Checker {
    private(set) var issues: [ValidationIssue] = []

    mutating func add(_ field: String, _ problem: ValidationIssue.Problem) {
        issues.append(ValidationIssue(field: field, problem: problem))
    }

    /// `value` is a finite number of zero or more (nil passes: a missing value isn't a wrong one)
    mutating func nonNegative(_ value: Double?, _ field: String) {
        guard let value else { return }
        if !value.isFinite { add(field, .notFinite) } else if value < 0 { add(field, .negative) }
    }

    mutating func nonNegative(_ value: Int?, _ field: String) {
        if let value, value < 0 { add(field, .negative) }
    }

    mutating func positive(_ value: Double?, _ field: String) {
        guard let value else { return }
        if !value.isFinite { add(field, .notFinite) } else if value < 0 { add(field, .negative) } else if value == 0 {
            add(field, .notPositive)
        }
    }

    mutating func inRange(_ value: Double?, _ range: ClosedRange<Double>, _ field: String) {
        guard let value else { return }
        if !value.isFinite { add(field, .notFinite) } else if !range.contains(value) { add(field, .outOfRange(range)) }
    }

    mutating func nonEmpty(_ text: String, _ field: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(field, .empty) }
    }

    /// a nested record's issues, with their fields under `prefix` (`ingredients[2].portion.count`)
    mutating func nested(_ child: Validatable, _ prefix: String) {
        issues += child.validationIssues().map { ValidationIssue(field: "\(prefix).\($0.field)", problem: $0.problem) }
    }
}
