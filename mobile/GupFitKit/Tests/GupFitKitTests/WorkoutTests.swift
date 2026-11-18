import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

final class WorkoutTests: XCTestCase {
    let bench = Exercise(id: "bench", name: "Bench press", muscles: ["chest", "triceps"])
    let run = Exercise(id: "run", name: "Run", kind: .cardio)

    func session(_ start: String, bench sets: [WorkoutSet], id: WorkoutSessionID = .new()) -> WorkoutSession {
        let begin = Sample.date(start)
        return WorkoutSession(id: id, title: "Push", startedAt: begin, endedAt: begin.addingTimeInterval(3600),
                              exercises: [SessionExercise(exercise: bench, sets: sets)])
    }

    func testVolumeCountsOnlyCompletedWorkingSets() {
        let e = SessionExercise(exercise: bench, sets: [
            WorkoutSet(reps: 10, weightKg: 40, isWarmup: true),
            WorkoutSet(reps: 8, weightKg: 80),
            WorkoutSet(reps: 6, weightKg: 85),
            WorkoutSet(reps: 6, weightKg: 85, isCompleted: false),
        ])
        assertClose(e.volumeKg, 8 * 80 + 6 * 85)
        XCTAssertEqual(e.totalReps, 14)
        XCTAssertEqual(e.workingSets.count, 2)
    }

    func testEstimatedOneRepMax() {
        assertClose(WorkoutSet(reps: 1, weightKg: 100).estimatedOneRepMaxKg, 100)
        assertClose(WorkoutSet(reps: 5, weightKg: 90).estimatedOneRepMaxKg, 105)
        XCTAssertNil(WorkoutSet(reps: 20, weightKg: 40).estimatedOneRepMaxKg, "too many reps to estimate")
        XCTAssertNil(WorkoutSet(reps: 5, weightKg: 90, isWarmup: true).estimatedOneRepMaxKg)
        XCTAssertNil(WorkoutSet(reps: 0, weightKg: 90).estimatedOneRepMaxKg)
        let e = SessionExercise(exercise: bench, sets: [WorkoutSet(reps: 8, weightKg: 80), WorkoutSet(reps: 3, weightKg: 92)])
        assertClose(e.bestSet?.weightKg, 80, "80 × 8 (e1RM 101.33) beats 92 × 3 (101.2)")
    }

    func testSessionTotals() {
        let begin = Sample.date("2026-11-17T17:00:00Z")
        let s = WorkoutSession(startedAt: begin, endedAt: begin.addingTimeInterval(75 * 60), exercises: [
            SessionExercise(exercise: bench, sets: [WorkoutSet(reps: 5, weightKg: 100), WorkoutSet(reps: 5, weightKg: 100)]),
            SessionExercise(exercise: run, sets: [WorkoutSet(duration: 1200, distanceMeters: 4000)]),
        ])
        assertClose(s.duration, 4500)
        assertClose(s.volumeKg, 1000)
        XCTAssertEqual(s.workingSetCount, 3)
        XCTAssertEqual(s.totalReps, 10)
        assertClose(s.exercises[1].totalDistanceMeters, 4000)
        assertClose(s.exercises[1].totalDuration, 1200)
        XCTAssertFalse(s.isActive)
        XCTAssertNil(WorkoutSession(startedAt: begin).duration)
        var denver = Calendar(identifier: .gregorian)
        denver.timeZone = TimeZone(identifier: "America/Denver")!
        XCTAssertEqual(s.day(in: denver), Sample.day)
    }

    func testValidation() {
        let begin = Sample.date("2026-11-17T17:00:00Z")
        let s = WorkoutSession(title: "", startedAt: begin, endedAt: begin.addingTimeInterval(-60), exercises: [
            SessionExercise(exercise: bench, sets: [
                WorkoutSet(reps: -3, weightKg: -20),
                WorkoutSet(duration: -1, distanceMeters: -5, rpe: 11),
            ]),
        ])
        XCTAssertEqual(s.validationIssues().map(\.description), [
            "title can't be empty",
            "endedAt is before the start",
            "exercises[0].sets[0].reps can't be negative",
            "exercises[0].sets[0].weightKg can't be negative",
            "exercises[0].sets[1].duration can't be negative",
            "exercises[0].sets[1].distanceMeters can't be negative",
            "exercises[0].sets[1].rpe must be between 0 and 10",
        ])
        XCTAssertTrue(WorkoutSet(reps: 0, weightKg: 0).isValid, "zero is allowed, negative isn't")
        XCTAssertFalse(Exercise(name: " ").isValid)
    }

    func testPersonalBests() {
        let first = session("2026-11-01T17:00:00Z", bench: [WorkoutSet(reps: 5, weightKg: 85)], id: "a")  // 99.2
        let second = session("2026-11-08T17:00:00Z", bench: [WorkoutSet(reps: 3, weightKg: 95)], id: "b")  // 104.5
        let third = session("2026-11-15T17:00:00Z", bench: [WorkoutSet(reps: 1, weightKg: 105)], id: "c")
        let tie = session("2026-11-16T17:00:00Z", bench: [WorkoutSet(reps: 1, weightKg: 105)], id: "d")
        let pb = WorkoutStats.personalBests([tie, second, first, third])["bench"]
        XCTAssertEqual(pb?.sessionID, "c", "the first time the best was reached")
        assertClose(pb?.estimatedOneRepMaxKg, 105)
        XCTAssertEqual(pb?.name, "Bench press")
        XCTAssertEqual(WorkoutStats.personalBests([first])["bench"]?.sessionID, "a")
        XCTAssertTrue(WorkoutStats.personalBests([]).isEmpty)
    }

    func testSessionKeepsTheExerciseNameFromThatDay() throws {
        var renamed = bench
        renamed.name = "Flat bench"
        let s = session("2026-11-01T17:00:00Z", bench: [])
        XCTAssertEqual(s.exercises[0].name, "Bench press")
        XCTAssertEqual(s.exercises[0].exerciseID, renamed.id)
        let enc = JSONEncoder()
        XCTAssertEqual(try JSONDecoder().decode(WorkoutSession.self, from: enc.encode(s)), s)
    }
}
