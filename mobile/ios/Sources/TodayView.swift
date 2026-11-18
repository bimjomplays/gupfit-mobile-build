import SwiftUI

/// A day's calories and macros against the goals, then each meal's entries. Add to a meal with its + button, tap an
/// entry to change it, swipe to delete. The arrows move between days.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: TodaySheet?

    enum TodaySheet: Identifiable {
        case add(MealSlot)
        case edit(MealEntry)
        case goals

        var id: String {
            switch self {
            case .add(let slot): "add-\(slot.rawValue)"
            case .edit(let entry): "edit-\(entry.id)"
            case .goals: "goals"
            }
        }
    }

    var body: some View {
        let summary = model.daySummary
        let goals = model.goals
        List {
            Section {
                MacroSummary(totals: summary.totals, goals: goals)
            }
            ForEach(MealSlot.allCases, id: \.self) { slot in
                let entries = summary.entries(in: slot)
                Section {
                    ForEach(entries) { entry in
                        Button { sheet = .edit(entry) } label: { EntryRow(entry: entry) }
                            .foregroundStyle(.primary)
                            .swipeActions {
                                Button("Delete", role: .destructive) { model.deleteEntry(entry.id) }
                            }
                    }
                    Button { sheet = .add(slot) } label: {
                        Label("Add food", systemImage: "plus")
                    }
                    .accessibilityIdentifier("add-\(slot.rawValue)")
                } header: {
                    HStack {
                        Text(slot.name)
                        Spacer()
                        Text(summary.totals(for: slot).formatted(.energy)).monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle(model.day == model.today ? "Today" : model.day.title)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button { model.day = model.day.adding(days: -1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous day")
                if model.day != model.today {
                    Button { model.day = model.day.adding(days: 1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next day")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.day != model.today {
                    Button("Today") { model.day = model.today }
                }
                Button { sheet = .goals } label: { Image(systemName: "target") }
                    .accessibilityLabel("Daily goals")
                    .accessibilityIdentifier("goals")
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add(let slot):
                FoodPickerView(purpose: .log(slot)) { food, portion, slot in
                    model.log(food, portion: portion, slot: slot)
                }
            case .edit(let entry):
                EditEntryView(entry: entry)
            case .goals:
                GoalsView(goals: goals)
            }
        }
        .accessibilityIdentifier("screen-today")
    }
}

struct EntryRow: View {
    let entry: MealEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(entry.food.name).lineLimit(2)
                Text(entry.portion.description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(NutrientTotals([entry.nutrients]).formatted(.energy)).monospacedDigit()
        }
    }
}

/// Change a logged entry's amount or meal, or delete it. Its numbers stay those from when it was logged.
struct EditEntryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: MealEntry

    var body: some View {
        NavigationStack {
            PortionEditor(snapshot: entry.food,
                          servings: model.servingOptions(for: entry.food, current: entry.portion.serving),
                          initial: entry.portion, slot: entry.slot, confirmTitle: "Save",
                          onConfirm: { portion, slot in
                              var changed = entry
                              changed.portion = portion
                              changed.slot = slot
                              if model.saveEntry(changed) { dismiss() }
                          },
                          onDelete: {
                              if model.deleteEntry(entry.id) { dismiss() }
                          })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
    }
}

/// Today's calories and macros against the goals.
struct MacroSummary: View {
    let totals: NutrientTotals
    let goals: NutritionGoals

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(.energy)
            ForEach(Nutrient.macros, id: \.self) { row($0) }
            if let left = goals.remaining(after: totals)[.energy] {
                Text(left >= 0 ? "\(Format.number(left, digits: 0)) kcal left" : "\(Format.number(-left, digits: 0)) kcal over")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ n: Nutrient) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(n.name).font(n == .energy ? .headline : .subheadline)
                Spacer()
                Text(totals.formatted(n)).monospacedDigit()
                if let target = goals.targets[n] {
                    Text("/ \(Format.number(target, digits: 0))").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let p = goals.progress(n, totals: totals) {
                ProgressView(value: min(p, 1)).tint(p > 1 ? Color.orange : Color.accentColor)
            }
        }
    }
}

/// The daily goals: calories and the three macros, any left empty.
struct GoalsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var energy: Double?
    @State private var protein: Double?
    @State private var carbs: Double?
    @State private var fat: Double?

    init(goals: NutritionGoals) {
        _energy = State(initialValue: goals.targets[.energy])
        _protein = State(initialValue: goals.targets[.protein])
        _carbs = State(initialValue: goals.targets[.carbohydrate])
        _fat = State(initialValue: goals.targets[.fat])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    goalRow("Calories", "kcal", $energy)
                    goalRow("Protein", "g", $protein)
                    goalRow("Carbs", "g", $carbs)
                    goalRow("Fat", "g", $fat)
                } footer: {
                    Text("Leave one empty to not track it.")
                }
                if let p = protein, let c = carbs, let f = fat {
                    Section {
                        LabeledContent("Calories from macros", value: "\(Format.number(p * 4 + c * 4 + f * 9, digits: 0)) kcal")
                    }
                }
            }
            .navigationTitle("Daily goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if model.saveGoals(NutritionGoals(energy: energy, protein: protein, carbohydrate: carbs, fat: fat)) {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func goalRow(_ title: String, _ unit: String, _ value: Binding<Double?>) -> some View {
        HStack {
            Text(title)
            NumberField(title: unit, value: value, digits: 0)
            Text(unit).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
        }
    }
}
