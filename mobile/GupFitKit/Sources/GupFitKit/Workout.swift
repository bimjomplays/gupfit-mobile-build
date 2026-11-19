import Foundation

enum ExerciseKind: String, Codable, CaseIterable, Sendable {
    /// sets of reps with a weight (bench press)
    case strength
    /// reps, maybe with added weight (pull-ups)
    case bodyweight
    /// time and distance (running, rowing)
    case cardio
    /// held for time (plank)
    case timed
}

/// An exercise in the person's library.
struct Exercise: Identifiable, Hashable, Codable, Sendable, Validatable {
    var id: ExerciseID
    var name: String
    var kind: ExerciseKind
    var muscles: [String]
    var notes: String?

    init(id: ExerciseID = .new(), name: String, kind: ExerciseKind = .strength, muscles: [String] = [],
         notes: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.muscles = muscles
        self.notes = notes
    }

    func validationIssues() -> [ValidationIssue] {
        var check = Checker()
        check.nonEmpty(name, "name")
        return check.issues
    }
}

/// One set. Every measurement is optional because exercises measure different things; whatever is there can't be
/// negative. Weight is in kilograms (WeightUnit converts), duration in seconds, distance in meters.
struct WorkoutSet: Identifiable, Hashable, Codable, Sendable, Validatable {
    var id: WorkoutSetID
    var reps: Int?
    var weightKg: Double?
    var duration: Double?
    var distanceMeters: Double?
    /// rate of perceived exertion, 0–10
    var rpe: Double?
    var isWarmup: Bool
    var isCompleted: Bool

    init(id: WorkoutSetID = .new(), reps: Int? = nil, weightKg: Double? = nil, duration: Double? = nil,
         distanceMeters: Double? = nil, rpe: Double? = nil, isWarmup: Bool = false, isCompleted: Bool = true) {
        self.id = id
        self.reps = reps
        self.weightKg = weightKg
        self.duration = duration
        self.distanceMeters = distanceMeters
        self.rpe = rpe
        self.isWarmup = isWarmup
        self.isCompleted = isCompleted
    }

    /// a completed working set (not a warm-up): what volume, PRs and set counts are made of
    var counts: Bool { isCompleted && !isWarmup }

    /// reps × weight, for a counting set with both
    var volumeKg: Double {
        guard counts, let reps, let weightKg else { return 0 }
        return Double(reps) * weightKg
    }

    /// estimated one-rep max (Epley: weight × (1 + reps / 30); a single is its own weight), for sets of 1–12 reps;
    /// beyond that the estimate means little
    var estimatedOneRepMaxKg: Double? {
        guard counts, let reps, let weightKg, weightKg > 0, (1...12).contains(reps) else { return nil }
        return reps == 1 ? weightKg : weightKg * (1 + Double(reps) / 30)
    }

    func validationIssues() -> [ValidationIssue] {
        var check = Checker()
        check.nonNegative(reps, "reps")
        check.nonNegative(weightKg, "weightKg")
        check.nonNegative(duration, "duration")
        check.nonNegative(distanceMeters, "distanceMeters")
        check.inRange(rpe, 0...10, "rpe")
        return check.issues
    }
}

/// An exercise as done in one session, with its sets. Keeps the exercise's name and kind from that day, so renaming
/// or deleting the exercise later doesn't rewrite history.
struct SessionExercise: Identifiable, Hashable, Codable, Sendable, Validatable {
    var id: SessionExerciseID
    var exerciseID: ExerciseID
    var name: String
    var kind: ExerciseKind
    var sets: [WorkoutSet]
    var notes: String?

    init(id: SessionExerciseID = .new(), exercise: Exercise, sets: [WorkoutSet] = [], notes: String? = nil) {
        self.id = id
        exerciseID = exercise.id
        name = exercise.name
        kind = exercise.kind
        self.sets = sets
        self.notes = notes
    }

    var workingSets: [WorkoutSet] { sets.filter(\.counts) }
    var volumeKg: Double { sets.reduce(0) { $0 + $1.volumeKg } }
    var totalReps: Int { workingSets.reduce(0) { $0 + ($1.reps ?? 0) } }
    var totalDistanceMeters: Double { workingSets.reduce(0) { $0 + ($1.distanceMeters ?? 0) } }
    var totalDuration: Double { workingSets.reduce(0) { $0 + ($1.duration ?? 0) } }
    /// the working set with the highest estimated one-rep max
    var bestSet: WorkoutSet? {
        workingSets.filter { $0.estimatedOneRepMaxKg != nil }.max { $0.estimatedOneRepMaxKg! < $1.estimatedOneRepMaxKg! }
    }

    func validationIssues() -> [ValidationIssue] {
        var check = Checker()
        check.nonEmpty(name, "name")
        for (i, s) in sets.enumerated() { check.nested(s, "sets[\(i)]") }
        return check.issues
    }
}

/// One workout. `endedAt` is nil while it's going.
struct WorkoutSession: Identifiable, Hashable, Codable, Sendable, Validatable {
    var id: WorkoutSessionID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var exercises: [SessionExercise]
    var notes: String?

    init(id: WorkoutSessionID = .new(), title: String = "Workout", startedAt: Date, endedAt: Date? = nil,
         exercises: [SessionExercise] = [], notes: String? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exercises = exercises
        self.notes = notes
    }

    var isActive: Bool { endedAt == nil }
    /// seconds from start to end (nil while it's going)
    var duration: Double? { endedAt.map { $0.timeIntervalSince(startedAt) } }
    var volumeKg: Double { exercises.reduce(0) { $0 + $1.volumeKg } }
    var workingSetCount: Int { exercises.reduce(0) { $0 + $1.workingSets.count } }
    var totalReps: Int { exercises.reduce(0) { $0 + $1.totalReps } }

    func day(in calendar: Calendar = .current) -> LocalDay { LocalDay(startedAt, calendar: calendar) }

    func validationIssues() -> [ValidationIssue] {
        var check = Checker()
        check.nonEmpty(title, "title")
        if let endedAt, endedAt < startedAt { check.add("endedAt", .endsBeforeStart) }
        for (i, e) in exercises.enumerated() { check.nested(e, "exercises[\(i)]") }
        return check.issues
    }
}

/// A personal best for one exercise across sessions.
struct PersonalBest: Hashable, Sendable {
    let exerciseID: ExerciseID
    let name: String
    let estimatedOneRepMaxKg: Double
    let set: WorkoutSet
    let sessionID: WorkoutSessionID
    let date: Date
}

enum WorkoutStats {
    /// each exercise's best estimated one-rep max over `sessions` (the earliest session wins a tie), by exercise
    static func personalBests(_ sessions: [WorkoutSession]) -> [ExerciseID: PersonalBest] {
        var best: [ExerciseID: PersonalBest] = [:]
        for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            for e in session.exercises {
                guard let set = e.bestSet, let e1rm = set.estimatedOneRepMaxKg else { continue }
                if let old = best[e.exerciseID], old.estimatedOneRepMaxKg >= e1rm { continue }
                best[e.exerciseID] = PersonalBest(exerciseID: e.exerciseID, name: e.name, estimatedOneRepMaxKg: e1rm,
                                                  set: set, sessionID: session.id, date: session.startedAt)
            }
        }
        return best
    }
}
