import Foundation

/// One step of the phone database's schema. Versions count up from 1 with no gaps; `PRAGMA user_version` records the
/// last one applied. A migration that shipped is never edited: a change is a new migration.
struct Migration: Sendable {
    let version: Int
    let name: String
    let apply: @Sendable (SQLiteDatabase) throws -> Void

    init(_ version: Int, _ name: String, apply: @escaping @Sendable (SQLiteDatabase) throws -> Void) {
        self.version = version
        self.name = name
        self.apply = apply
    }

    init(_ version: Int, _ name: String, sql: String) {
        self.init(version, name) { try $0.execute(sql) }
    }
}

enum MigrationError: Error, Equatable, CustomStringConvertible {
    /// the file was written by a newer GupFit; it is left exactly as it is
    case newerSchema(found: Int, supported: Int)
    /// a migration failed and was rolled back; the database is still at `version - 1` with all its data
    case failed(version: Int, name: String, reason: String)
    /// the migrations list itself is wrong (a programming error caught by the tests)
    case badList(String)

    var description: String {
        switch self {
        case .newerSchema(let found, let supported):
            "This data was saved by a newer version of GupFit (schema \(found), this build knows \(supported)). Update the app; nothing was changed."
        case .failed(let version, let name, let reason): "Updating the database to version \(version) (\(name)) failed: \(reason). Nothing was changed."
        case .badList(let why): "bad migration list: \(why)"
        }
    }
}

enum Migrator {
    /// Brings `db` up to the last migration's version. Each migration runs in its own transaction with its version
    /// bump, so a failure leaves the database exactly at the previous version. Before changing a database that already
    /// has data, a copy of it is written to `backupDirectory` (`gupfit-v<old>.sqlite`) first.
    /// Returns the versions applied.
    @discardableResult
    static func migrate(_ db: SQLiteDatabase, _ migrations: [Migration], backupDirectory: URL?) throws -> [Int] {
        for (i, m) in migrations.enumerated() where m.version != i + 1 {
            throw MigrationError.badList("migration \(m.name) has version \(m.version), expected \(i + 1)")
        }
        let latest = migrations.count
        let current = try db.userVersion
        if current > latest { throw MigrationError.newerSchema(found: current, supported: latest) }
        if current == latest { return [] }

        if current > 0, let backupDirectory { try backup(db, version: current, to: backupDirectory) }

        // foreign keys can't be switched inside a transaction; a migration that rebuilds a table needs them off,
        // and foreign_key_check below makes sure it left no dangling reference
        try db.execute("PRAGMA foreign_keys = OFF")
        defer { try? db.execute("PRAGMA foreign_keys = ON") }
        var applied: [Int] = []
        for m in migrations.dropFirst(current) {
            do {
                try db.transaction {
                    try m.apply(db)
                    let broken = try db.query("PRAGMA foreign_key_check")
                    if !broken.isEmpty {
                        throw SQLiteError(code: 787, message: "\(broken.count) rows point at missing rows", sql: nil)
                    }
                    try db.setUserVersion(m.version)
                }
            } catch {
                throw MigrationError.failed(version: m.version, name: m.name, reason: "\(error)")
            }
            applied.append(m.version)
        }
        return applied
    }

    /// a consistent copy of the whole database (VACUUM INTO works on a live WAL database)
    static func backup(_ db: SQLiteDatabase, version: Int, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("gupfit-v\(version).sqlite")
        try? FileManager.default.removeItem(at: file)
        try db.run("VACUUM INTO ?", file.path)
    }
}

/// The phone database's schema. Every user record has a stable text id (the models' ids). Dates are seconds since
/// 2001-01-01 (REAL), days are "2026-11-17" text. Nutrients are JSON objects keyed by `Nutrient` raw values: a key
/// that isn't there is unknown, a 0 is a real zero. Meal entries and recipe ingredients keep the food as it was
/// (`food` = a FoodSnapshot as JSON) and have no foreign key to `foods`, so deleting a food never touches history.
enum PhoneSchema {
    static let migrations: [Migration] = [
        Migration(1, "foods, meal log, workouts, recipes, settings", sql: """
            CREATE TABLE foods (
                id               TEXT PRIMARY KEY NOT NULL,
                name             TEXT NOT NULL,
                brand            TEXT,
                source           TEXT NOT NULL,      -- FoodSource as JSON
                base_unit        TEXT NOT NULL,      -- gram | milliliter | serving
                reference_amount REAL NOT NULL,      -- nutrients describe this much of base_unit
                nutrients        TEXT NOT NULL,      -- NutrientProfile JSON
                servings         TEXT NOT NULL,      -- [Serving] JSON
                search_text      TEXT NOT NULL,      -- FoodSearch.normalize(name brand)
                created_at       REAL NOT NULL,
                updated_at       REAL NOT NULL
            );

            CREATE TABLE meal_entries (
                id             TEXT PRIMARY KEY NOT NULL,
                day            TEXT NOT NULL,
                slot           TEXT NOT NULL,        -- breakfast | lunch | dinner | snack
                logged_at      REAL NOT NULL,
                food_id        TEXT NOT NULL,
                food           TEXT NOT NULL,        -- FoodSnapshot JSON, taken when logged
                portion_count  REAL NOT NULL,
                serving_label  TEXT NOT NULL,
                serving_amount REAL NOT NULL,        -- in the snapshot's base unit
                note           TEXT,
                created_at     REAL NOT NULL,
                updated_at     REAL NOT NULL
            );
            CREATE INDEX meal_entries_by_day ON meal_entries(day, logged_at, id);
            CREATE INDEX meal_entries_by_food ON meal_entries(food_id, logged_at);

            CREATE TABLE exercises (
                id         TEXT PRIMARY KEY NOT NULL,
                name       TEXT NOT NULL,
                kind       TEXT NOT NULL,
                muscles    TEXT NOT NULL,            -- [String] JSON
                notes      TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE workout_sessions (
                id         TEXT PRIMARY KEY NOT NULL,
                title      TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at   REAL,
                notes      TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX workout_sessions_by_start ON workout_sessions(started_at, id);

            CREATE TABLE session_exercises (
                session_id  TEXT NOT NULL REFERENCES workout_sessions(id) ON DELETE CASCADE,
                position    INTEGER NOT NULL,
                id          TEXT NOT NULL,
                exercise_id TEXT NOT NULL,           -- no foreign key: the session keeps its name and kind
                name        TEXT NOT NULL,
                kind        TEXT NOT NULL,
                notes       TEXT,
                PRIMARY KEY (session_id, position)
            ) WITHOUT ROWID;
            CREATE INDEX session_exercises_by_exercise ON session_exercises(exercise_id);

            CREATE TABLE workout_sets (
                session_id      TEXT NOT NULL,
                exercise_pos    INTEGER NOT NULL,
                position        INTEGER NOT NULL,
                id              TEXT NOT NULL,
                reps            INTEGER,
                weight_kg       REAL,
                duration        REAL,                -- seconds
                distance_m      REAL,
                rpe             REAL,
                is_warmup       INTEGER NOT NULL,
                is_completed    INTEGER NOT NULL,
                PRIMARY KEY (session_id, exercise_pos, position),
                FOREIGN KEY (session_id, exercise_pos) REFERENCES session_exercises(session_id, position)
                    ON DELETE CASCADE
            ) WITHOUT ROWID;

            CREATE TABLE recipes (
                id              TEXT PRIMARY KEY NOT NULL,
                name            TEXT NOT NULL,
                servings        REAL NOT NULL,
                steps           TEXT NOT NULL,       -- [String] JSON
                notes           TEXT,
                cooked_weight_g REAL,
                tags            TEXT NOT NULL,       -- [String] JSON
                created_at      REAL NOT NULL,
                updated_at      REAL NOT NULL
            );

            CREATE TABLE recipe_ingredients (
                recipe_id      TEXT NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
                position       INTEGER NOT NULL,
                id             TEXT NOT NULL,
                food_id        TEXT NOT NULL,
                food           TEXT NOT NULL,        -- FoodSnapshot JSON, taken when added
                portion_count  REAL NOT NULL,
                serving_label  TEXT NOT NULL,
                serving_amount REAL NOT NULL,
                note           TEXT,
                PRIMARY KEY (recipe_id, position)
            ) WITHOUT ROWID;

            CREATE TABLE settings (
                key   TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL                  -- JSON
            ) WITHOUT ROWID;
            """),
    ]

    static var version: Int { migrations.count }
}
