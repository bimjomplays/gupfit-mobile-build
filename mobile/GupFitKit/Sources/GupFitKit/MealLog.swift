import Foundation

/// A calendar day as the person lived it, independent of time zone: dinner logged at 11 pm in Denver stays on that
/// day after flying to New York. Stored as "2026-11-17".
struct LocalDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// the day `date` falls on in `calendar` (its time zone decides)
    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    /// "2026-11-17"; nil for anything else or a day that doesn't exist
    init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)),
              LocalDay(date, calendar: cal) == LocalDay(year: y, month: m, day: d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// the day `count` days later (earlier when negative)
    func adding(days count: Int) -> LocalDay {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: year, month: month, day: day + count))!
        return LocalDay(date, calendar: cal)
    }

    /// midnight at the start of this day in `calendar`
    func start(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    static func < (a: LocalDay, b: LocalDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let day = LocalDay(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a day: \(text)"))
        }
        self = day
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

enum MealSlot: String, Codable, CaseIterable, Sendable {
    case breakfast, lunch, dinner, snack

    var name: String { rawValue.capitalized }

    /// when this meal usually happens, for entries logged on another day
    var usualHour: Double {
        switch self {
        case .breakfast: 8
        case .lunch: 12.5
        case .dinner: 19
        case .snack: 15.5
        }
    }
}

/// One logged food. It keeps a snapshot of the food's nutrition from when it was logged, so the day's totals never
/// change when the food is edited or deleted later; changing the portion rescales that same snapshot.
struct MealEntry: Identifiable, Hashable, Codable, Sendable, Validatable {
    var id: MealEntryID
    var day: LocalDay
    var slot: MealSlot
    var loggedAt: Date
    var food: FoodSnapshot
    var portion: Portion
    var note: String?

    /// a new entry for `portion` of `food` as it is now; throws if the food or portion isn't valid
    init(id: MealEntryID = .new(), food: Food, portion: Portion, day: LocalDay, slot: MealSlot,
         loggedAt: Date = Date(), note: String? = nil) throws {
        self.id = id
        self.food = food.snapshot
        self.portion = portion
        self.day = day
        self.slot = slot
        self.loggedAt = loggedAt
        self.note = note
        try validate()
    }

    /// an entry as it was stored (no validation: what was saved is read back as it is)
    init(id: MealEntryID, snapshot: FoodSnapshot, portion: Portion, day: LocalDay, slot: MealSlot, loggedAt: Date,
         note: String? = nil) {
        self.id = id
        food = snapshot
        self.portion = portion
        self.day = day
        self.slot = slot
        self.loggedAt = loggedAt
        self.note = note
    }

    /// what this entry adds to the day
    var nutrients: NutrientProfile { food.nutrients(for: portion) }

    func validationIssues() -> [ValidationIssue] {
        var check = Checker()
        check.nested(food, "food")
        check.nested(portion, "portion")
        return check.issues
    }
}

/// Daily targets; any can be left unset.
struct NutritionGoals: Hashable, Codable, Sendable, Validatable {
    var targets: NutrientProfile

    init(energy: Double? = nil, protein: Double? = nil, carbohydrate: Double? = nil, fat: Double? = nil) {
        targets = NutrientProfile([.energy: energy, .protein: protein, .carbohydrate: carbohydrate, .fat: fat]
            .compactMapValues { $0 })
    }

    /// target minus eaten for each set target (negative when over); a nutrient whose total is unknown is left out
    func remaining(after totals: NutrientTotals) -> [Nutrient: Double] {
        var out: [Nutrient: Double] = [:]
        for (n, target) in targets.values {
            if let eaten = totals.value(n) { out[n] = target - eaten }
        }
        return out
    }

    /// eaten over target (1 = on target), for rings and bars
    func progress(_ nutrient: Nutrient, totals: NutrientTotals) -> Double? {
        guard let target = targets[nutrient], target > 0, let eaten = totals.value(nutrient) else { return nil }
        return eaten / target
    }

    func validationIssues() -> [ValidationIssue] {
        var check = Checker()
        check.nested(targets, "targets")
        return check.issues
    }
}

/// One day's log added up: the whole day and each meal.
struct DaySummary: Hashable, Sendable {
    let day: LocalDay
    /// the day's entries in the order they were logged
    let entries: [MealEntry]
    let totals: NutrientTotals

    init(day: LocalDay, entries: [MealEntry]) {
        self.day = day
        self.entries = entries.filter { $0.day == day }.sorted { ($0.loggedAt, $0.id) < ($1.loggedAt, $1.id) }
        totals = NutrientTotals(self.entries.map(\.nutrients))
    }

    func entries(in slot: MealSlot) -> [MealEntry] { entries.filter { $0.slot == slot } }

    /// one meal's totals (zero when nothing was logged in it)
    func totals(for slot: MealSlot) -> NutrientTotals { NutrientTotals(entries(in: slot).map(\.nutrients)) }
}
