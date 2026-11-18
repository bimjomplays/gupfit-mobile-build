import Foundation

/// One search result from the bundled catalog.
struct CatalogHit: Identifiable, Hashable, Sendable {
    /// the catalog's id (the USDA FoodData Central id)
    let id: Int
    let name: String
    let category: String?
    /// kcal per 100 g (nil when USDA doesn't say)
    let kcalPer100g: Double?

    /// the id the food gets once it's logged
    var foodID: FoodID { FoodCatalog.foodID(id) }
}

/// The bundled USDA food catalog (data/catalog.sqlite, built by tools/catalog; schema in tools/catalog/README.md),
/// opened read-only. Its foods are logged straight from here: a meal entry keeps its own snapshot, so nothing is
/// copied into the phone database. Thread-safe.
final class FoodCatalog: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let lock = NSLock()
    /// the USDA credit to show wherever the catalog's data appears
    let attribution: String

    init(path: String) throws {
        db = try SQLiteDatabase(path: path, mode: .readOnlyImmutable)
        attribution = (try? db.query("SELECT value FROM catalog_meta WHERE key = 'attribution'").first?.string("value"))
            .flatMap { $0 } ?? "Food data: USDA FoodData Central."
    }

    /// the copy bundled in the app (nil when the bundle has none, e.g. in unit tests on Linux)
    static func bundled(_ bundle: Bundle = .main) -> FoodCatalog? {
        guard let path = bundle.path(forResource: "catalog", ofType: "sqlite") else { return nil }
        return try? FoodCatalog(path: path)
    }

    static let idPrefix = "usda:"
    static func foodID(_ catalogID: Int) -> FoodID { FoodID("\(idPrefix)\(catalogID)") }
    /// the catalog id inside a food id like `usda:171705`
    static func catalogID(_ id: FoodID) -> Int? {
        id.rawValue.hasPrefix(idPrefix) ? Int(id.rawValue.dropFirst(idPrefix.count)) : nil
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// the typed words: letters and digits only, so nothing the person types becomes FTS syntax
    static func words(_ query: String) -> [String] {
        query.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// Foods whose name has every typed word as a word prefix ("chick bre"). The same ranking as the reference in
    /// tools/catalog/catalog_lib.py: names starting with a typed word first ("Bananas, raw" before "Pepper,
    /// banana"), then names starting with a longer word ("Eggnog" for "egg"), then shorter names, then FTS rank.
    func search(_ query: String, limit: Int = 50) throws -> [CatalogHit] {
        let words = Self.words(query)
        guard !words.isEmpty, limit > 0 else { return [] }
        let match = words.map { "\"\($0)\"*" }.joined(separator: " ")
        let rows = try locked {
            try db.query("""
                SELECT f.id, f.name, f.category, n.kcal FROM foods_fts JOIN foods f ON f.id = foods_fts.rowid
                LEFT JOIN nutrients n ON n.food_id = f.id
                WHERE foods_fts MATCH ? ORDER BY bm25(foods_fts), f.id LIMIT 300
                """, [match])
        }
        func singular(_ w: String) -> String { w.hasSuffix("s") ? String(w.dropLast()) : w }
        let typed = Set(words.map(singular))
        let ranked = rows.enumerated().map { position, row -> (key: (Int, Int, Int), hit: CatalogHit) in
            let name = row.string("name") ?? ""
            let first = Self.words(name).first ?? ""
            let tier = typed.contains(singular(first)) ? 0 : words.contains { first.hasPrefix($0) } ? 1 : 2
            let hit = CatalogHit(id: row.int("id") ?? 0, name: name, category: row.string("category"),
                                 kcalPer100g: row.double("kcal"))
            return ((tier, name.unicodeScalars.count, position), hit)
        }
        return ranked.sorted { $0.key < $1.key }.prefix(limit).map(\.hit)
    }

    /// A catalog food ready to log: nutrients per 100 g (unknown stays unknown), measured in grams, with USDA's
    /// household portions as servings ("1 cup, chopped" = 128 g, "2 waffles" = 70 g).
    func food(id: Int) throws -> Food? {
        try locked {
            guard let row = try db.query("""
                SELECT f.id, f.name, f.fdc_id, n.* FROM foods f LEFT JOIN nutrients n ON n.food_id = f.id WHERE f.id = ?
                """, [id]).first else { return nil }
            var nutrients = NutrientProfile()
            for n in Nutrient.allCases {
                if let column = n.catalogColumn, let value = row.double(column) { nutrients[n] = value }
            }
            var servings: [Serving] = []
            let standard = Set(MeasureUnit.allCases.map(\.symbol))
            for p in try db.query("SELECT amount, label, grams FROM portions WHERE food_id = ? ORDER BY seq", [id]) {
                guard let amount = p.double("amount"), amount > 0, let label = p.string("label"),
                      let grams = p.double("grams"), grams > 0 else { continue }
                let name = amount == 1 ? label : "\(Format.number(amount)) \(label)"
                // a plain "oz" is better served by the exact standard unit; a label seen twice keeps its first weight
                if standard.contains(name) || servings.contains(where: { $0.label == name }) { continue }
                servings.append(Serving(name, amount: grams))
            }
            return Food(id: Self.foodID(id), name: row.string("name") ?? "Food \(id)",
                        source: .usda(fdcID: row.int("fdc_id") ?? id), baseUnit: .gram, referenceAmount: 100,
                        nutrients: nutrients, servings: servings)
        }
    }

    /// the catalog food for an id like `usda:171705`
    func food(id: FoodID) throws -> Food? {
        guard let catalogID = Self.catalogID(id) else { return nil }
        return try food(id: catalogID)
    }
}
