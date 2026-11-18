import SwiftUI

/// The last 90 days of workouts, newest first. + starts one; tap one to change it; swipe to delete.
struct WorkoutsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: WorkoutSession?
    @State private var isNew = false

    var body: some View {
        let sessions = model.recentWorkouts
        Group {
            if sessions.isEmpty {
                ContentUnavailableView {
                    Label("No workouts yet", systemImage: "dumbbell")
                } description: {
                    Text("Tap + to log one.")
                }
            } else {
                List {
                    ForEach(sessions) { s in
                        Button { start(s, new: false) } label: { WorkoutRow(session: s) }
                            .foregroundStyle(.primary)
                            .swipeActions {
                                Button("Delete", role: .destructive) { model.deleteSession(s.id) }
                            }
                    }
                }
            }
        }
        .navigationTitle("Workouts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { start(WorkoutSession(startedAt: Date()), new: true) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New workout")
                    .accessibilityIdentifier("new-workout")
            }
        }
        .sheet(item: $editing) { session in
            WorkoutEditor(session: session, isNew: isNew)
        }
        .accessibilityIdentifier("screen-workouts")
    }

    private func start(_ session: WorkoutSession, new: Bool) {
        isNew = new
        editing = session
    }
}

struct WorkoutRow: View {
    let session: WorkoutSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.title).font(.headline)
                Spacer()
                Text(session.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text(session.exercises.map(\.name).joined(separator: ", "))
                .font(.subheadline).lineLimit(1)
            Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var summary: String {
        var parts = ["\(session.workingSetCount) sets"]
        if session.volumeKg > 0 { parts.append(WeightDisplay.current.volume(session.volumeKg)) }
        if let d = session.duration { parts.append(Durations.clock(d)) } else { parts.append("in progress") }
        return parts.joined(separator: " · ")
    }
}

/// Weights are stored in kilograms and shown in the unit picked in the workout editor (pounds by default).
enum WeightDisplay {
    static let key = "weightUnit"

    static var current: WeightUnit {
        UserDefaults.standard.string(forKey: key).flatMap(WeightUnit.init(rawValue:)) ?? .pound
    }
}

extension WeightUnit {
    func volume(_ kilograms: Double) -> String {
        "\(Format.number(fromKilograms(kilograms), digits: 0)) \(symbol) volume"
    }
}

/// One workout: title and times, then each exercise with its sets. Nothing is saved until Save.
struct WorkoutEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WeightDisplay.key) private var weightUnit: WeightUnit = .pound
    @State private var session: WorkoutSession
    @State private var pickingExercise = false
    let isNew: Bool

    init(session: WorkoutSession, isNew: Bool) {
        _session = State(initialValue: session)
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $session.title).accessibilityIdentifier("workout-title")
                    DatePicker("Started", selection: $session.startedAt)
                    Toggle("Finished", isOn: Binding(
                        get: { session.endedAt != nil },
                        set: { session.endedAt = $0 ? max(Date(), session.startedAt) : nil }))
                    if let ended = session.endedAt {
                        DatePicker("Ended", selection: Binding(get: { ended }, set: { session.endedAt = $0 }),
                                   in: session.startedAt...)
                    }
                }
                ForEach($session.exercises) { $exercise in
                    Section {
                        ForEach($exercise.sets) { $set in
                            SetRow(set: $set, number: (exercise.sets.firstIndex { $0.id == set.id } ?? 0) + 1,
                                   kind: exercise.kind, unit: weightUnit)
                                .id("\(set.id.rawValue)-\(weightUnit.rawValue)")  // refills the fields in the new unit
                        }
                        .onDelete { exercise.sets.remove(atOffsets: $0) }
                        Button {
                            exercise.sets.append(exercise.sets.last?.next() ?? WorkoutSet(isCompleted: false))
                        } label: {
                            Label("Add set", systemImage: "plus")
                        }
                    } header: {
                        HStack {
                            Text(exercise.name)
                            Spacer()
                            Menu {
                                Button("Remove exercise", role: .destructive) {
                                    let id = exercise.id
                                    session.exercises.removeAll { $0.id == id }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
                Section {
                    Button { pickingExercise = true } label: { Label("Add exercise", systemImage: "plus.circle") }
                        .accessibilityIdentifier("add-exercise")
                    Picker("Weights in", selection: $weightUnit) {
                        Text("lb").tag(WeightUnit.pound)
                        Text("kg").tag(WeightUnit.kilogram)
                    }
                    .pickerStyle(.segmented)
                }
                if session.workingSetCount > 0 {
                    Section {
                        LabeledContent("Working sets", value: "\(session.workingSetCount)")
                        if session.volumeKg > 0 {
                            LabeledContent("Volume", value: weightUnit.volume(session.volumeKg))
                        }
                    }
                }
                if !isNew {
                    Section {
                        Button("Delete workout", role: .destructive) {
                            if model.deleteSession(session.id) { dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New workout" : session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if model.saveSession(session) { dismiss() } }
                        .accessibilityIdentifier("workout-save")
                }
            }
            .sheet(isPresented: $pickingExercise) {
                ExercisePicker { exercise in
                    session.exercises.append(SessionExercise(exercise: exercise, sets: [WorkoutSet(isCompleted: false)]))
                }
            }
        }
    }
}

/// One set: reps × weight (strength, bodyweight), time and distance (cardio) or time (timed), and done.
struct SetRow: View {
    @Binding var set: WorkoutSet
    let number: Int
    let kind: ExerciseKind
    let unit: WeightUnit

    var body: some View {
        HStack(spacing: 8) {
            Text(set.isWarmup ? "W" : "\(number)")
                .font(.subheadline.bold()).foregroundStyle(.secondary).frame(width: 22)
            switch kind {
            case .strength, .bodyweight:
                NumberField(title: "reps", value: Binding(int: $set.reps), digits: 0)
                Text("reps").font(.caption).foregroundStyle(.secondary)
                NumberField(title: kind == .bodyweight ? "+" : unit.symbol,
                            value: Binding($set.weightKg, scale: unit.fromKilograms(1)), digits: 2)
                Text(unit.symbol).font(.caption).foregroundStyle(.secondary)
            case .cardio:
                NumberField(title: "min", value: Binding($set.duration, scale: 1.0 / 60), digits: 1)
                Text("min").font(.caption).foregroundStyle(.secondary)
                NumberField(title: unit == .pound ? "mi" : "km",
                            value: Binding($set.distanceMeters, scale: unit == .pound ? 1 / 1609.344 : 1 / 1000.0),
                            digits: 2)
                Text(unit == .pound ? "mi" : "km").font(.caption).foregroundStyle(.secondary)
            case .timed:
                NumberField(title: "sec", value: $set.duration, digits: 0)
                Text("sec").font(.caption).foregroundStyle(.secondary)
            }
            Button { set.isCompleted.toggle() } label: {
                Image(systemName: set.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(set.isCompleted ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(set.isCompleted ? "Done" : "Not done")
        }
        .swipeActions(edge: .leading) {
            Button(set.isWarmup ? "Working" : "Warm-up") { set.isWarmup.toggle() }.tint(.orange)
        }
    }
}

/// Pick an exercise from the library or add a new one to it.
struct ExercisePicker: View {
    let onPick: (Exercise) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var newKind: ExerciseKind = .strength

    var body: some View {
        NavigationStack {
            List {
                let name = query.trimmingCharacters(in: .whitespaces)
                let matches = model.exercises.filter { name.isEmpty || FoodSearch.matches(name, name: $0.name) }
                ForEach(matches) { e in
                    Button {
                        onPick(e)
                        dismiss()
                    } label: {
                        LabeledContent(e.name, value: e.kind.rawValue.capitalized)
                    }
                    .foregroundStyle(.primary)
                }
                if !name.isEmpty && !matches.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                    Section("New exercise") {
                        Picker("Kind", selection: $newKind) {
                            ForEach(ExerciseKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        Button("Add \u{201C}\(name)\u{201D}") {
                            let exercise = Exercise(name: name, kind: newKind)
                            if model.saveExercise(exercise) {
                                onPick(exercise)
                                dismiss()
                            }
                        }
                        .accessibilityIdentifier("add-new-exercise")
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find or name an exercise")
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
