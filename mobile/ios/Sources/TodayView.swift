import SwiftUI

/// Today's calories and macros against the goals, then each meal's entries.
struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.todaySummary
        List {
            Section {
                MacroSummary(totals: summary.totals, goals: model.goals)
            }
            ForEach(MealSlot.allCases, id: \.self) { slot in
                let entries = summary.entries(in: slot)
                Section {
                    if entries.isEmpty {
                        Text("Nothing logged").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.food.name)
                                Text(entry.portion.description).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(NutrientTotals([entry.nutrients]).formatted(.energy))
                                .monospacedDigit()
                        }
                    }
                } header: {
                    HStack {
                        Text(slot.name)
                        Spacer()
                        Text(summary.totals(for: slot).formatted(.energy))
                    }
                }
            }
        }
        .navigationTitle("Today")
        .accessibilityIdentifier("screen-today")
    }
}

struct MacroSummary: View {
    let totals: NutrientTotals
    let goals: NutritionGoals

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(.energy)
            ForEach(Nutrient.macros, id: \.self) { row($0) }
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
