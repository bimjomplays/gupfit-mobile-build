import SwiftUI

/// A food chosen in the picker, resolved into a Food only when it's opened (catalog rows are just ids until then).
enum FoodChoice: Hashable {
    case food(Food)
    case catalog(Int)
    case recipe(RecipeID)
    case recent(FoodSnapshot)
}

/// Find a food (recent, your own, your recipes, the USDA catalog), then choose how much. Used to log to a meal and
/// to add a recipe ingredient. `onPick` gets the food, the portion and the meal; the sheet closes itself.
struct FoodPickerView: View {
    enum Purpose {
        case log(MealSlot)
        case ingredient
    }

    let purpose: Purpose
    let onPick: (Food, Portion, MealSlot) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var foodForm: FoodDraft?

    private var logging: Bool {
        if case .log = purpose { return true }
        return false
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    let recent = model.recentFoods
                    if !recent.isEmpty {
                        Section("Recent") {
                            ForEach(recent, id: \.foodID) { s in
                                NavigationLink(value: FoodChoice.recent(s)) {
                                    FoodRow(name: s.name, detail: s.brand)
                                }
                            }
                        }
                    }
                }
                let mine = model.myFoods(matching: trimmed)
                if !mine.isEmpty {
                    Section("My foods") {
                        ForEach(mine) { food in
                            NavigationLink(value: FoodChoice.food(food)) {
                                FoodRow(name: food.name, detail: food.brand,
                                        kcal: NutrientTotals([food.nutrients]).formatted(.energy),
                                        per: "\(Format.number(food.referenceAmount)) \(food.baseUnit.symbol)")
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { model.deleteFood(food.id) }
                                Button("Edit") { foodForm = FoodDraft(food: food) }.tint(.blue)
                            }
                        }
                    }
                }
                if logging {
                    let recipes = model.recipes(matching: trimmed)
                    if !recipes.isEmpty {
                        Section("Recipes") {
                            ForEach(recipes) { r in
                                NavigationLink(value: FoodChoice.recipe(r.id)) {
                                    FoodRow(name: r.name, detail: nil, kcal: r.perServing.formatted(.energy), per: "serving")
                                }
                            }
                        }
                    }
                }
                if !trimmed.isEmpty {
                    let hits = model.catalogHits(trimmed)
                    Section {
                        if hits.isEmpty {
                            Text("No match in the food catalog").foregroundStyle(.secondary)
                        }
                        ForEach(hits) { hit in
                            NavigationLink(value: FoodChoice.catalog(hit.id)) {
                                FoodRow(name: hit.name, detail: hit.category,
                                        kcal: hit.kcalPer100g.map { "\(Format.number($0, digits: 0)) kcal" } ?? "—",
                                        per: "100 g")
                            }
                        }
                    } header: {
                        Text("USDA food catalog")
                    } footer: {
                        if let attribution = model.catalog?.attribution { Text(attribution) }
                    }
                }
                Section {
                    Button { foodForm = FoodDraft() } label: { Label("Create a food", systemImage: "square.and.pencil") }
                        .accessibilityIdentifier("create-food")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
            .autocorrectionDisabled()
            .navigationTitle(logging ? "Add food" : "Add ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(for: FoodChoice.self) { choice in
                if let food = resolve(choice) {
                    PortionEditor(snapshot: food.snapshot, servings: food.servingOptions, initial: Self.firstPortion(food),
                                  slot: slot, confirmTitle: logging ? "Log" : "Add",
                                  onConfirm: { portion, slot in
                                      onPick(food, portion, slot)
                                      dismiss()
                                  })
                } else {
                    ContentUnavailableView("This food is gone", systemImage: "questionmark.circle")
                }
            }
            .sheet(item: $foodForm) { draft in
                FoodFormView(draft: draft) { food in
                    if model.saveFood(food) {
                        foodForm = nil
                        if draft.id == nil { path.append(FoodChoice.food(food)) }
                    }
                }
            }
        }
    }

    private var slot: MealSlot? {
        if case .log(let slot) = purpose { return slot }
        return nil
    }

    private func resolve(_ choice: FoodChoice) -> Food? {
        switch choice {
        case .food(let food): food
        case .catalog(let id): model.catalog.flatMap { try? $0.food(id: id) }
        case .recipe(let id): model.recipe(id: id)?.asFood()
        case .recent(let snapshot): model.currentFood(for: snapshot)
        }
    }

    /// one of the food's own servings when it has one, else 100 g / 100 ml / 1 serving
    static func firstPortion(_ food: Food) -> Portion {
        if let first = food.servings.first { return Portion(1, first) }
        switch food.baseUnit {
        case .gram: return Portion(100, .standard(.gram))
        case .milliliter: return Portion(100, .standard(.milliliter))
        case .serving: return Portion(1, .base(.serving))
        }
    }
}

extension BaseUnit {
    var symbol: String {
        switch self {
        case .gram: "g"
        case .milliliter: "ml"
        case .serving: "serving"
        }
    }
}

struct FoodRow: View {
    let name: String
    let detail: String?
    var kcal: String?
    var per: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(2)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let kcal {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(kcal).monospacedDigit()
                    if let per { Text("per \(per)").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

/// How much of a food (a count of one of its servings) and, when logging, which meal; with its nutrition as typed.
struct PortionEditor: View {
    let snapshot: FoodSnapshot
    let servings: [Serving]
    let confirmTitle: String
    let onConfirm: (Portion, MealSlot) -> Void
    var onDelete: (() -> Void)?
    private let showsSlot: Bool

    @State private var count: Double?
    @State private var serving: Serving
    @State private var slot: MealSlot

    init(snapshot: FoodSnapshot, servings: [Serving], initial: Portion, slot: MealSlot?, confirmTitle: String,
         onConfirm: @escaping (Portion, MealSlot) -> Void, onDelete: (() -> Void)? = nil) {
        self.snapshot = snapshot
        self.servings = servings.contains(initial.serving) ? servings : [initial.serving] + servings
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onDelete = onDelete
        showsSlot = slot != nil
        _count = State(initialValue: initial.count)
        _serving = State(initialValue: initial.serving)
        _slot = State(initialValue: slot ?? .snack)
    }

    private var portion: Portion? {
        guard let count, count > 0 else { return nil }
        return Portion(count, serving)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Amount")
                    NumberField(title: "Amount", value: $count)
                        .accessibilityIdentifier("portion-count")
                }
                Picker("Serving", selection: $serving) {
                    ForEach(servings, id: \.self) { s in
                        Text(Self.label(s)).tag(s)
                    }
                }
                if showsSlot {
                    Picker("Meal", selection: $slot) {
                        ForEach(MealSlot.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                }
            } header: {
                Text(snapshot.name)
            }
            Section("Nutrition") {
                let totals = NutrientTotals([portion.map(snapshot.nutrients(for:)) ?? NutrientProfile()])
                MacroGrid(totals: totals)
                ForEach([Nutrient.fiber, .sugars, .saturatedFat, .sodium], id: \.self) { n in
                    if snapshot.nutrients[n] != nil {
                        LabeledContent(n.name, value: totals.formatted(n, digits: n.unit == .mg ? 0 : 1))
                    }
                }
                if let portion, snapshot.baseUnit != .serving {
                    LabeledContent("Weighs", value: "\(Format.number(portion.baseAmount, digits: 1)) \(snapshot.baseUnit.symbol)")
                }
            }
            Section {
                Button(confirmTitle) {
                    if let portion { onConfirm(portion, slot) }
                }
                .disabled(portion == nil)
                .accessibilityIdentifier("portion-confirm")
                if let onDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                }
            }
        }
        .navigationTitle(snapshot.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: serving) { old, new in
            // keep the same amount of food in the new serving ("150 g" → "1.25 × 1 cup")
            if let count { self.count = (Portion(count, old).converted(to: new).count * 100).rounded() / 100 }
        }
    }

    private static func label(_ s: Serving) -> String {
        MeasureUnit.allCases.contains { $0.symbol == s.label } || s.label == "serving"
            ? s.label : "\(s.label) (\(Format.number(s.amount, digits: 1)))"
    }
}

/// Your own food: name, what the numbers are per, calories (required) and the rest (empty = unknown), named servings.
struct FoodFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FoodDraft
    @State private var problems: [String] = []
    let onSave: (Food) -> Void

    init(draft: FoodDraft, onSave: @escaping (Food) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name).accessibilityIdentifier("food-name")
                    TextField("Brand (optional)", text: $draft.brand)
                }
                Section {
                    Picker("Measured in", selection: Binding(get: { draft.baseUnit }, set: { draft.setBaseUnit($0) })) {
                        Text("Grams").tag(BaseUnit.gram)
                        Text("Milliliters").tag(BaseUnit.milliliter)
                        Text("Servings").tag(BaseUnit.serving)
                    }
                    HStack {
                        Text("Nutrition per")
                        TextField("100", text: $draft.referenceAmount)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        Text(draft.baseUnit.symbol).foregroundStyle(.secondary)
                    }
                }
                Section("Nutrition") {
                    ForEach(FoodDraft.fields, id: \.self) { n in
                        HStack {
                            Text(n == .energy ? "Calories" : n.name)
                            TextField(n == .energy ? "required" : "unknown", text: Binding(get: { draft.nutrients[n] ?? "" }, set: { draft.nutrients[n] = $0 }))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("nutrient-\(n.rawValue)")
                            Text(n.unit.rawValue).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                        }
                    }
                }
                if draft.baseUnit != .serving {
                    Section {
                        ForEach($draft.servings) { $s in
                            HStack {
                                TextField("Name, e.g. 1 slice", text: $s.label)
                                TextField("weight", text: $s.amount)
                                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                                Text(draft.baseUnit.symbol).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { draft.servings.remove(atOffsets: $0) }
                        Button("Add a serving") { draft.servings.append(ServingDraft()) }
                    } header: {
                        Text("Servings")
                    } footer: {
                        Text("Optional: named amounts like \"1 slice\" = 28 g, to log without weighing.")
                    }
                }
                if !problems.isEmpty {
                    Section {
                        ForEach(problems, id: \.self) { Text($0).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle(draft.id == nil ? "New food" : "Edit food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            onSave(try draft.makeFood())
                        } catch let error as ValidationError {
                            problems = error.issues.map(Self.message)
                        } catch {
                            problems = ["\(error)"]
                        }
                    }
                    .accessibilityIdentifier("food-save")
                }
            }
        }
    }

    /// "nutrients.energy can't be empty" → "Calories can't be empty"
    private static func message(_ issue: ValidationIssue) -> String {
        var field = issue.field
        if field.hasPrefix("nutrients."), let n = Nutrient(rawValue: String(field.dropFirst("nutrients.".count))) {
            field = n == .energy ? "Calories" : n.name
        } else if field == "referenceAmount" {
            field = "Nutrition per"
        } else if field == "name" {
            field = "Name"
        }
        return ValidationIssue(field: field, problem: issue.problem).description
    }
}
