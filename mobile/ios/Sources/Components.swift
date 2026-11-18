import SwiftUI

/// A text field for a number that may be empty (nil). Shows the value with up to `digits` decimals; what's typed is
/// written back only when it differs from what's shown, so opening a form never changes the data.
struct NumberField: View {
    let title: String
    @Binding var value: Double?
    var digits = 2

    @State private var text = ""

    var body: some View {
        TextField(title, text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .onAppear { text = NumberInput.text(value, digits: digits) }
            .onChange(of: text) { _, new in
                if new != NumberInput.text(value, digits: digits) { value = NumberInput.parse(new) }
            }
    }
}

extension Binding where Value == Double? {
    /// an optional Int (reps) as an optional Double for a NumberField
    init(int source: Binding<Int?>) {
        self.init(get: { source.wrappedValue.map(Double.init) },
                  set: { source.wrappedValue = $0.map { Int($0.rounded()) } })
    }

    /// a required Double (servings) as an optional one; clearing the field keeps 0, which validation rejects
    init(required source: Binding<Double>) {
        self.init(get: { source.wrappedValue }, set: { source.wrappedValue = $0 ?? 0 })
    }

    /// an amount stored in one unit shown in another (`scale` = shown per stored)
    init(_ source: Binding<Double?>, scale: Double) {
        self.init(get: { source.wrappedValue.map { $0 * scale } },
                  set: { source.wrappedValue = $0.map { $0 / scale } })
    }
}

/// "450 kcal · P 30 g · C 40 g · F 12 g"
struct MacroLine: View {
    let totals: NutrientTotals

    var body: some View {
        Text(([Nutrient.energy] + Nutrient.macros).map { n in
            n == .energy ? totals.formatted(n) : "\(n.name.prefix(1)) \(totals.formatted(n))"
        }.joined(separator: " · "))
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

/// Calories and the three macros as four big numbers.
struct MacroGrid: View {
    let totals: NutrientTotals

    var body: some View {
        HStack {
            ForEach([Nutrient.energy] + Nutrient.macros, id: \.self) { n in
                VStack(spacing: 2) {
                    Text(totals.formatted(n)).font(.headline).monospacedDigit()
                    Text(n.name).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }
}

extension LocalDay {
    /// "Mon, Nov 17"
    var title: String {
        start().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

enum Durations {
    /// "1:05:00", "25:00"
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
