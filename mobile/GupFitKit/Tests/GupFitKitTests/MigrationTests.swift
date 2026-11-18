import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

final class MigrationTests: XCTestCase {
    private var temp: TempFolder!

    override func setUpWithError() throws { temp = try TempFolder() }
    override func tearDown() { temp = nil }

    /// a made-up next version: a new column filled from existing data
    private static let v2 = Migration(2, "favorite foods", sql: """
        ALTER TABLE foods ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0;
        UPDATE foods SET favorite = 1 WHERE id IN (SELECT DISTINCT food_id FROM meal_entries);
        """)

    private func columns(_ db: SQLiteDatabase, _ table: String) throws -> [String] {
        try db.query("PRAGMA table_info(\(table))").compactMap { $0.string("name") }
    }

    func testUpgradeKeepsEveryRecordAndBacksUpFirst() throws {
        var store: SQLiteStore? = try SQLiteStore(url: temp.database)
        try store!.saveFood(Sample.chicken)
        try store!.saveFood(Sample.apple)
        let entry = try MealEntry(id: "e", food: Sample.chicken, portion: Sample.chicken.portion(150, .gram),
                                  day: Sample.day, slot: .dinner)
        try store!.saveEntry(entry)
        store?.close()
        store = nil

        let upgraded = try SQLiteStore(url: temp.database, migrations: PhoneSchema.migrations + [Self.v2])
        XCTAssertEqual(upgraded.schemaVersion, 2)
        XCTAssertEqual(try upgraded.food(id: "chicken"), Sample.chicken)
        XCTAssertEqual(try upgraded.entry(id: "e"), entry)
        upgraded.close()

        let raw = try SQLiteDatabase(path: temp.database.path)
        XCTAssertEqual(try raw.query("SELECT id FROM foods WHERE favorite = 1").compactMap { $0.string("id") }, ["chicken"])

        let backup = try SQLiteDatabase(path: temp.backups.appendingPathComponent("gupfit-v1.sqlite").path)
        XCTAssertEqual(try backup.userVersion, 1, "the copy is the database as it was")
        XCTAssertEqual(try backup.scalar("SELECT count(*) FROM foods"), .integer(2))
        XCTAssertFalse(try columns(backup, "foods").contains("favorite"))
    }

    func testAFailedMigrationChangesNothing() throws {
        var store: SQLiteStore? = try SQLiteStore(url: temp.database)
        try store!.saveFood(Sample.apple)
        store?.close()
        store = nil

        struct Broken: Error {}
        let bad = Migration(2, "half done") { db in
            try db.execute("ALTER TABLE foods ADD COLUMN half INTEGER; DELETE FROM foods;")
            throw Broken()
        }
        XCTAssertThrowsError(try SQLiteStore(url: temp.database, migrations: PhoneSchema.migrations + [bad])) { error in
            guard case .failed(let version, _, _)? = error as? MigrationError else { return XCTFail("\(error)") }
            XCTAssertEqual(version, 2)
        }

        let raw = try SQLiteDatabase(path: temp.database.path)
        XCTAssertEqual(try raw.userVersion, 1)
        XCTAssertFalse(try columns(raw, "foods").contains("half"))
        raw.close()
        let reopened = try SQLiteStore(url: temp.database)
        XCTAssertEqual(try reopened.food(id: "apple"), Sample.apple, "the data is all there")
    }

    func testANewerDatabaseIsRefusedAndLeftAlone() throws {
        let store = try SQLiteStore(url: temp.database)
        try store.saveFood(Sample.apple)
        store.close()
        let raw = try SQLiteDatabase(path: temp.database.path)
        try raw.setUserVersion(7)
        try raw.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        raw.close()
        let before = try Data(contentsOf: temp.database)

        XCTAssertThrowsError(try SQLiteStore(url: temp.database)) { error in
            XCTAssertEqual(error as? MigrationError, .newerSchema(found: 7, supported: PhoneSchema.version))
        }
        XCTAssertEqual(try Data(contentsOf: temp.database), before)
    }

    func testTheListMustCountUpFromOne() throws {
        let db = try SQLiteDatabase(path: temp.database.path)
        let gap = [PhoneSchema.migrations[0], Migration(3, "skips two", sql: "")]
        XCTAssertThrowsError(try Migrator.migrate(db, gap, backupDirectory: nil)) { error in
            guard case .badList? = error as? MigrationError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try db.userVersion, 0)
        XCTAssertEqual(try Migrator.migrate(db, PhoneSchema.migrations, backupDirectory: nil), [1])
        XCTAssertEqual(try Migrator.migrate(db, PhoneSchema.migrations, backupDirectory: nil), [], "already there")
    }

    /// A version-1 database as the first release writes it, from plain SQL. If migration 1 or the reading code ever
    /// changes in a way that can't read existing phones' data, this fails.
    func testReadsAVersion1DatabaseWrittenByTheFirstRelease() throws {
        let db = try SQLiteDatabase(path: temp.database.path)
        try db.execute("PRAGMA journal_mode = WAL")
        try Migrator.migrate(db, Array(PhoneSchema.migrations.prefix(1)), backupDirectory: nil)
        try db.execute("""
            INSERT INTO foods VALUES ('f1', 'Oat milk', 'Oatly', '{"user":{}}', 'milliliter', 100,
                '{"carbohydrate":6.7,"energy":46,"fat":1.5,"protein":1,"sugars":0}', '[{"amount":240,"label":"cup"}]',
                'oat milk oatly', 815000000, 815000000);
            INSERT INTO meal_entries VALUES ('m1', '2026-11-17', 'breakfast', 816600000.5, 'usda:123',
                '{"baseUnit":"gram","foodID":"usda:123","name":"Bananas, raw","nutrients":{"energy":89,"fiber":2.6,"protein":1.1},"referenceAmount":100,"source":{"usda":{"fdcID":123}}}',
                1.5, '1 medium', 118, 'ripe', 816600000, 816600000);
            INSERT INTO exercises VALUES ('x1', 'Deadlift', 'strength', '["back","legs"]', NULL, 815000000, 815000000);
            INSERT INTO workout_sessions VALUES ('w1', 'Pull', 816620000, 816623600, 'felt good', 816620000, 816623600);
            INSERT INTO session_exercises VALUES ('w1', 0, 'se1', 'x1', 'Deadlift', 'strength', NULL);
            INSERT INTO workout_sets VALUES ('w1', 0, 0, 'set1', 5, 140, NULL, NULL, 8, 0, 1);
            INSERT INTO workout_sets VALUES ('w1', 0, 1, 'set2', 3, 150, NULL, NULL, NULL, 0, 0);
            INSERT INTO recipes VALUES ('r1', 'Smoothie', 2, '["Blend."]', NULL, NULL, '["breakfast"]', 1, 1);
            INSERT INTO recipe_ingredients VALUES ('r1', 0, 'i1', 'f1',
                '{"baseUnit":"milliliter","brand":"Oatly","foodID":"f1","name":"Oat milk","nutrients":{"energy":46},"referenceAmount":100,"source":{"user":{}}}',
                2, 'cup', 240, NULL);
            INSERT INTO settings VALUES ('nutritionGoals', '{"targets":{"energy":2100}}');
            """)
        db.close()

        let store = try SQLiteStore(url: temp.database)
        let milk = try XCTUnwrap(store.food(id: "f1"))
        XCTAssertEqual(milk.brand, "Oatly")
        XCTAssertEqual(milk.baseUnit, .milliliter)
        XCTAssertEqual(milk.servings, [Serving("cup", amount: 240)])
        XCTAssertEqual(milk.nutrients[.sugars], 0)
        XCTAssertNil(milk.nutrients[.fiber])

        let entry = try XCTUnwrap(store.entry(id: "m1"))
        XCTAssertEqual(entry.food.source, .usda(fdcID: 123))
        XCTAssertEqual(entry.loggedAt, Date(timeIntervalSinceReferenceDate: 816600000.5))
        assertClose(entry.nutrients[.energy], 89 * 1.77)
        XCTAssertEqual(entry.note, "ripe")

        let session = try XCTUnwrap(store.session(id: "w1"))
        XCTAssertEqual(session.duration, 3600)
        XCTAssertEqual(session.exercises.first?.sets.map(\.reps), [5, 3])
        assertClose(session.volumeKg, 700, "the incomplete set doesn't count")
        XCTAssertEqual(session.exercises.first?.sets.first?.rpe, 8)
        XCTAssertEqual(try store.exercises().first?.muscles, ["back", "legs"])

        let smoothie = try XCTUnwrap(store.recipe(id: "r1"))
        assertClose(smoothie.perServing[.energy], 46 * 4.8 / 2)
        XCTAssertEqual(try store.goals(or: .init()), NutritionGoals(energy: 2100))
    }
}
