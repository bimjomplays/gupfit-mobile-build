import Foundation

enum StoreError: Error, Equatable, CustomStringConvertible {
    /// a stored row that can't be read back (never skipped silently: the caller sees it)
    case unreadable(table: String, id: String, reason: String)

    var description: String {
        switch self {
        case .unreadable(let table, let id, let reason): "a saved \(table) row (\(id)) can't be read: \(reason)"
        }
    }
}

/// The phone's database: everything the person logs, in one SQLite file in the app's private Application Support
/// folder, protected with the device key. Implements every repository; each save or delete is one transaction, and
/// `transaction` groups several. Opening it runs the schema migrations (PhoneSchema), copying the file aside first
/// when an existing database gets upgraded. Thread-safe: one connection, one lock.
final class SQLiteStore: GupFitStore, @unchecked Sendable {
    /// Device backups (Finder/PC, and iCloud Backup when the phone has it on) include the database by default, so a
    /// lost phone doesn't lose the log. Set this to true to keep it out of every backup.
    static let excludeFromDeviceBackup = false

    let url: URL
    private let db: SQLiteDatabase
    private let lock = NSRecursiveLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    /// Opens (or creates) the database at `url` and migrates it. `backupDirectory` receives a copy of the file
    /// before an upgrade (default: a Backups folder next to it; nil skips the copy).
    init(url: URL, migrations: [Migration] = PhoneSchema.migrations, backupDirectory: URL? = nil,
         makeBackups: Bool = true) throws {
        self.url = url
        let folder = url.deletingLastPathComponent()
        try Self.prepareFolder(folder)
        db = try SQLiteDatabase(path: url.path)
        // WAL: a crash mid-write never damages what was committed; FULL: a commit is on disk before it returns
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA foreign_keys = ON")
        try Migrator.migrate(db, migrations,
                             backupDirectory: makeBackups ? backupDirectory ?? folder.appendingPathComponent("Backups") : nil)
    }

    /// the database in Application Support/GupFit/gupfit.sqlite
    static var defaultURL: URL {
        get throws {
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                        create: true)
                .appendingPathComponent("GupFit", isDirectory: true)
                .appendingPathComponent("gupfit.sqlite")
        }
    }

    private static func prepareFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: folder.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = excludeFromDeviceBackup
        var folderURL = folder
        try folderURL.setResourceValues(values)
        #endif
    }

    /// the schema version the file is at
    var schemaVersion: Int { (try? locked { try db.userVersion }) ?? 0 }

    /// closes the connection; the store can't be used afterwards
    func close() { locked { db.close() } }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked { try db.transaction(body) }
    }

    /// one write in its own transaction (or inside the caller's)
    private func write(_ body: () throws -> Void) throws {
        try locked { try db.transaction(body) }
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String?, table: String, id: String) throws -> T {
        guard let text else { throw StoreError.unreadable(table: table, id: id, reason: "missing value") }
        do {
            return try decoder.decode(T.self, from: Data(text.utf8))
        } catch {
            throw StoreError.unreadable(table: table, id: id, reason: "\(error)")
        }
    }

    private func required<T>(_ value: T?, _ table: String, _ id: String, _ column: String) throws -> T {
        guard let value else { throw StoreError.unreadable(table: table, id: id, reason: "no \(column)") }
        return value
    }

    /// INSERT, or UPDATE the row with the same key keeping its created_at
    private func upsert(_ table: String, key: String = "id", _ columns: KeyValuePairs<String, SQLConvertible>,
                        timestamps: Bool = true) throws {
        var names = columns.map(\.key)
        var values = columns.map(\.value)
        if timestamps {
            let now = Date()
            names += ["created_at", "updated_at"]
            values += [now, now]
        }
        let updates = names.filter { $0 != key && $0 != "created_at" }.map { "\($0) = excluded.\($0)" }
        try db.query("""
            INSERT INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))
            ON CONFLICT(\(key)) DO UPDATE SET \(updates.joined(separator: ", "))
            """, values)
    }

    private func delete(_ table: String, id: String) throws {
        try db.run("DELETE FROM \(table) WHERE id = ?", id)
        if db.changes == 0 { throw RepositoryError.notFound(id) }
    }

    // MARK: foods

    func food(id: FoodID) throws -> Food? {
        try locked { try db.query("SELECT * FROM foods WHERE id = ?", [id.rawValue]).first.map(food(from:)) }
    }

    private func food(from row: SQLRow) throws -> Food {
        let id = row.string("id") ?? "?"
        return Food(
            id: FoodID(id), name: try required(row.string("name"), "foods", id, "name"), brand: row.string("brand"),
            source: try decode(FoodSource.self, row.string("source"), table: "foods", id: id),
            baseUnit: try required(row.string("base_unit").flatMap(BaseUnit.init(rawValue:)), "foods", id, "base_unit"),
            referenceAmount: try required(row.double("reference_amount"), "foods", id, "reference_amount"),
            nutrients: try decode(NutrientProfile.self, row.string("nutrients"), table: "foods", id: id),
            servings: try decode([Serving].self, row.string("servings"), table: "foods", id: id))
    }

    func searchFoods(_ query: String, limit: Int) throws -> [Food] {
        let words = FoodSearch.normalize(query).split(separator: " ").map(String.init)
        let rows: [SQLRow] = try locked {
            if let longest = words.max(by: { $0.count < $1.count }) {
                let pattern = "%" + longest.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
                return try db.query("SELECT * FROM foods WHERE search_text LIKE ? ESCAPE '\\'", [pattern])
            }
            return try db.query("SELECT * FROM foods")
        }
        return Array(try rows.map(food(from:))
            .filter { FoodSearch.matches(query, name: $0.name, brand: $0.brand) }
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
            .prefix(max(0, limit)))
    }

    func saveFood(_ food: Food) throws {
        try food.validate()
        let search = FoodSearch.normalize([food.name, food.brand ?? ""].joined(separator: " "))
        let source = try json(food.source), nutrients = try json(food.nutrients), servings = try json(food.servings)
        try write {
            try upsert("foods", [
                "id": food.id.rawValue, "name": food.name, "brand": food.brand, "source": source,
                "base_unit": food.baseUnit.rawValue, "reference_amount": food.referenceAmount,
                "nutrients": nutrients, "servings": servings, "search_text": search,
            ])
        }
    }

    func deleteFood(id: FoodID) throws { try write { try delete("foods", id: id.rawValue) } }

    // MARK: meal log

    func entry(id: MealEntryID) throws -> MealEntry? {
        try locked { try db.query("SELECT * FROM meal_entries WHERE id = ?", [id.rawValue]).first.map(entry(from:)) }
    }

    private func portion(from row: SQLRow, _ table: String, _ id: String) throws -> Portion {
        Portion(try required(row.double("portion_count"), table, id, "portion_count"),
                Serving(try required(row.string("serving_label"), table, id, "serving_label"),
                        amount: try required(row.double("serving_amount"), table, id, "serving_amount")))
    }

    private func entry(from row: SQLRow) throws -> MealEntry {
        let id = row.string("id") ?? "?"
        let t = "meal_entries"
        return MealEntry(
            id: MealEntryID(id), snapshot: try decode(FoodSnapshot.self, row.string("food"), table: t, id: id),
            portion: try portion(from: row, t, id),
            day: try required(row.string("day").flatMap { LocalDay($0) }, t, id, "day"),
            slot: try required(row.string("slot").flatMap(MealSlot.init(rawValue:)), t, id, "slot"),
            loggedAt: try required(row.date("logged_at"), t, id, "logged_at"), note: row.string("note"))
    }

    func entries(in days: ClosedRange<LocalDay>) throws -> [MealEntry] {
        try locked {
            try db.query("SELECT * FROM meal_entries WHERE day BETWEEN ? AND ? ORDER BY day, logged_at, id",
                         [days.lowerBound.description, days.upperBound.description]).map(entry(from:))
        }
    }

    func saveEntry(_ entry: MealEntry) throws {
        try entry.validate()
        let food = try json(entry.food)
        try write {
            try upsert("meal_entries", [
                "id": entry.id.rawValue, "day": entry.day.description, "slot": entry.slot.rawValue,
                "logged_at": entry.loggedAt, "food_id": entry.food.foodID.rawValue, "food": food,
                "portion_count": entry.portion.count, "serving_label": entry.portion.serving.label,
                "serving_amount": entry.portion.serving.amount, "note": entry.note,
            ])
        }
    }

    func deleteEntry(id: MealEntryID) throws { try write { try delete("meal_entries", id: id.rawValue) } }

    func recentFoods(limit: Int) throws -> [FoodSnapshot] {
        try locked {
            // SQLite returns the bare columns from the row holding the MAX
            try db.query("""
                SELECT food_id, food, MAX(logged_at) AS last FROM meal_entries GROUP BY food_id
                ORDER BY last DESC, food_id LIMIT ?
                """, [max(0, limit)]).map {
                try decode(FoodSnapshot.self, $0.string("food"), table: "meal_entries", id: $0.string("food_id") ?? "?")
            }
        }
    }

    // MARK: workouts

    private func exercise(from row: SQLRow) throws -> Exercise {
        let id = row.string("id") ?? "?"
        return Exercise(
            id: ExerciseID(id), name: try required(row.string("name"), "exercises", id, "name"),
            kind: try required(row.string("kind").flatMap(ExerciseKind.init(rawValue:)), "exercises", id, "kind"),
            muscles: try decode([String].self, row.string("muscles"), table: "exercises", id: id),
            notes: row.string("notes"))
    }

    func exercises() throws -> [Exercise] {
        try locked { try db.query("SELECT * FROM exercises").map(exercise(from:)) }
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    func saveExercise(_ exercise: Exercise) throws {
        try exercise.validate()
        let muscles = try json(exercise.muscles)
        try write {
            try upsert("exercises", [
                "id": exercise.id.rawValue, "name": exercise.name, "kind": exercise.kind.rawValue,
                "muscles": muscles, "notes": exercise.notes,
            ])
        }
    }

    func deleteExercise(id: ExerciseID) throws { try write { try delete("exercises", id: id.rawValue) } }

    private func session(from row: SQLRow) throws -> WorkoutSession {
        let id = row.string("id") ?? "?"
        let sets = Dictionary(grouping: try db.query(
            "SELECT * FROM workout_sets WHERE session_id = ? ORDER BY exercise_pos, position", [id])) {
            $0.int("exercise_pos") ?? -1
        }
        let exercises = try db.query("SELECT * FROM session_exercises WHERE session_id = ? ORDER BY position", [id])
            .map { e -> SessionExercise in
                let eid = e.string("id") ?? "?"
                var se = SessionExercise(
                    id: SessionExerciseID(eid),
                    exercise: Exercise(
                        id: ExerciseID(try required(e.string("exercise_id"), "session_exercises", eid, "exercise_id")),
                        name: try required(e.string("name"), "session_exercises", eid, "name"),
                        kind: try required(e.string("kind").flatMap(ExerciseKind.init(rawValue:)), "session_exercises",
                                           eid, "kind")),
                    notes: e.string("notes"))
                se.sets = try (sets[e.int("position") ?? -2] ?? []).map { s in
                    let sid = s.string("id") ?? "?"
                    return WorkoutSet(
                        id: WorkoutSetID(sid), reps: s.int("reps"), weightKg: s.double("weight_kg"),
                        duration: s.double("duration"), distanceMeters: s.double("distance_m"), rpe: s.double("rpe"),
                        isWarmup: try required(s.bool("is_warmup"), "workout_sets", sid, "is_warmup"),
                        isCompleted: try required(s.bool("is_completed"), "workout_sets", sid, "is_completed"))
                }
                return se
            }
        return WorkoutSession(
            id: WorkoutSessionID(id), title: try required(row.string("title"), "workout_sessions", id, "title"),
            startedAt: try required(row.date("started_at"), "workout_sessions", id, "started_at"),
            endedAt: row.date("ended_at"), exercises: exercises, notes: row.string("notes"))
    }

    func session(id: WorkoutSessionID) throws -> WorkoutSession? {
        try locked { try db.query("SELECT * FROM workout_sessions WHERE id = ?", [id.rawValue]).first.map(session(from:)) }
    }

    func sessions(in interval: DateInterval) throws -> [WorkoutSession] {
        try locked {
            try db.query("""
                SELECT * FROM workout_sessions WHERE started_at >= ? AND started_at <= ? ORDER BY started_at, id
                """, [interval.start, interval.end]).map(session(from:))
        }
    }

    func saveSession(_ session: WorkoutSession) throws {
        try session.validate()
        try write {
            try upsert("workout_sessions", [
                "id": session.id.rawValue, "title": session.title, "started_at": session.startedAt,
                "ended_at": session.endedAt, "notes": session.notes,
            ])
            try deleteSessionChildren(session.id)
            for (i, e) in session.exercises.enumerated() {
                try db.run("""
                    INSERT INTO session_exercises (session_id, position, id, exercise_id, name, kind, notes)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, session.id.rawValue, i, e.id.rawValue, e.exerciseID.rawValue, e.name, e.kind.rawValue, e.notes)
                for (j, s) in e.sets.enumerated() {
                    try db.run("""
                        INSERT INTO workout_sets (session_id, exercise_pos, position, id, reps, weight_kg, duration,
                            distance_m, rpe, is_warmup, is_completed) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, session.id.rawValue, i, j, s.id.rawValue, s.reps, s.weightKg, s.duration,
                               s.distanceMeters, s.rpe, s.isWarmup, s.isCompleted)
                }
            }
        }
    }

    private func deleteSessionChildren(_ id: WorkoutSessionID) throws {
        try db.run("DELETE FROM workout_sets WHERE session_id = ?", id.rawValue)
        try db.run("DELETE FROM session_exercises WHERE session_id = ?", id.rawValue)
    }

    func deleteSession(id: WorkoutSessionID) throws {
        try write {
            try deleteSessionChildren(id)
            try delete("workout_sessions", id: id.rawValue)
        }
    }

    // MARK: recipes

    private func recipe(from row: SQLRow) throws -> Recipe {
        let id = row.string("id") ?? "?"
        let t = "recipes"
        let ingredients = try db.query("SELECT * FROM recipe_ingredients WHERE recipe_id = ? ORDER BY position", [id])
            .map { r -> RecipeIngredient in
                let iid = r.string("id") ?? "?"
                return RecipeIngredient(
                    id: RecipeIngredientID(iid),
                    snapshot: try decode(FoodSnapshot.self, r.string("food"), table: "recipe_ingredients", id: iid),
                    portion: try portion(from: r, "recipe_ingredients", iid), note: r.string("note"))
            }
        return Recipe(
            id: RecipeID(id), name: try required(row.string("name"), t, id, "name"),
            servings: try required(row.double("servings"), t, id, "servings"), ingredients: ingredients,
            steps: try decode([String].self, row.string("steps"), table: t, id: id), notes: row.string("notes"),
            cookedWeightGrams: row.double("cooked_weight_g"),
            tags: try decode([String].self, row.string("tags"), table: t, id: id))
    }

    func recipe(id: RecipeID) throws -> Recipe? {
        try locked { try db.query("SELECT * FROM recipes WHERE id = ?", [id.rawValue]).first.map(recipe(from:)) }
    }

    func searchRecipes(_ query: String) throws -> [Recipe] {
        try locked { try db.query("SELECT * FROM recipes").map(recipe(from:)) }
            .filter { FoodSearch.matches(query, name: $0.name, brand: $0.tags.joined(separator: " ")) }
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    func saveRecipe(_ recipe: Recipe) throws {
        try recipe.validate()
        let steps = try json(recipe.steps), tags = try json(recipe.tags)
        let foods = try recipe.ingredients.map { try json($0.food) }
        try write {
            try upsert("recipes", [
                "id": recipe.id.rawValue, "name": recipe.name, "servings": recipe.servings, "steps": steps,
                "notes": recipe.notes, "cooked_weight_g": recipe.cookedWeightGrams, "tags": tags,
            ])
            try db.run("DELETE FROM recipe_ingredients WHERE recipe_id = ?", recipe.id.rawValue)
            for (i, ing) in recipe.ingredients.enumerated() {
                try db.run("""
                    INSERT INTO recipe_ingredients (recipe_id, position, id, food_id, food, portion_count, serving_label,
                        serving_amount, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, recipe.id.rawValue, i, ing.id.rawValue, ing.food.foodID.rawValue, foods[i], ing.portion.count,
                           ing.portion.serving.label, ing.portion.serving.amount, ing.note)
            }
        }
    }

    func deleteRecipe(id: RecipeID) throws {
        try write {
            try db.run("DELETE FROM recipe_ingredients WHERE recipe_id = ?", id.rawValue)
            try delete("recipes", id: id.rawValue)
        }
    }

    // MARK: settings

    func setting<T: Decodable>(_ key: SettingKey, as type: T.Type) throws -> T? {
        guard let text = try locked({ try db.query("SELECT value FROM settings WHERE key = ?", [key.rawValue]).first?
            .string("value") }) else { return nil }
        return try decode(T.self, text, table: "settings", id: key.rawValue)
    }

    func saveSetting<T: Encodable>(_ key: SettingKey, _ value: T) throws {
        let text = try json(value)
        try write { try upsert("settings", key: "key", ["key": key.rawValue, "value": text], timestamps: false) }
    }

    // MARK: tool receipts

    private func receipt(from row: SQLRow) throws -> ToolReceipt {
        let t = "tool_receipts"
        let id = "\(row.string("turn") ?? "?")/\(row.string("call") ?? "?")"
        return ToolReceipt(
            turn: try required(row.string("turn"), t, id, "turn"), call: try required(row.string("call"), t, id, "call"),
            name: try required(row.string("name"), t, id, "name"),
            fingerprint: try required(row.string("fingerprint"), t, id, "fingerprint"),
            ok: try required(row.bool("ok"), t, id, "ok"),
            result: try row.string("result").map { try decode(JSONValue.self, $0, table: t, id: id) },
            error: row.string("error"), changes: try decode([ToolChange].self, row.string("changes"), table: t, id: id),
            at: try required(row.date("at"), t, id, "at"))
    }

    func receipt(turn: String, call: String) throws -> ToolReceipt? {
        try locked {
            try db.query("SELECT * FROM tool_receipts WHERE turn = ? AND call = ?", [turn, call]).first.map(receipt(from:))
        }
    }

    func receipt(turn: String, fingerprint: String) throws -> ToolReceipt? {
        try locked {
            try db.query("SELECT * FROM tool_receipts WHERE turn = ? AND fingerprint = ? AND ok = 1 ORDER BY at LIMIT 1",
                         [turn, fingerprint]).first.map(receipt(from:))
        }
    }

    func saveReceipt(_ r: ToolReceipt) throws {
        let result = try r.result.map { try json($0) }, changes = try json(r.changes)
        try write {
            try db.run("""
                INSERT INTO tool_receipts (turn, call, name, fingerprint, ok, result, error, changes, at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(turn, call) DO UPDATE SET changes = excluded.changes
                """, r.turn, r.call, r.name, r.fingerprint, r.ok, result, r.error, changes, r.at)
        }
    }
}
