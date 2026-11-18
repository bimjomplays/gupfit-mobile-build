import SwiftUI

/// Your recipes with calories per serving. + creates one; tap one for its macros, ingredients and steps.
struct RecipesView: View {
    @Environment(AppModel.self) private var model
    @State private var creating: Recipe?

    var body: some View {
        let recipes = model.recipes
        Group {
            if recipes.isEmpty {
                ContentUnavailableView {
                    Label("No recipes yet", systemImage: "book.closed")
                } description: {
                    Text("Tap + to make one from your foods.")
                }
            } else {
                List {
                    ForEach(recipes) { r in
                        NavigationLink(value: r.id) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.name).font(.headline)
                                MacroLine(totals: r.perServing)
                                Text("per serving · makes \(Format.number(r.servings))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.deleteRecipe(r.id) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Recipes")
        .navigationDestination(for: RecipeID.self) { id in RecipeDetailView(id: id) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = Recipe(name: "", servings: 4) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New recipe")
                    .accessibilityIdentifier("new-recipe")
            }
        }
        .sheet(item: $creating) { recipe in RecipeEditor(recipe: recipe, isNew: true) }
        .accessibilityIdentifier("screen-recipes")
    }
}

/// A recipe's macros per serving, ingredients and steps; log a serving or edit it from here.
struct RecipeDetailView: View {
    let id: RecipeID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Recipe?
    @State private var logging = false
    @State private var logged = false

    var body: some View {
        if let recipe = model.recipe(id: id) {
            List {
                Section {
                    MacroGrid(totals: recipe.perServing)
                    Button { logging = true } label: { Label("Log a serving", systemImage: "fork.knife") }
                        .accessibilityIdentifier("log-serving")
                    if logged {
                        Label("Logged to today", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } header: {
                    Text("Per serving · makes \(Format.number(recipe.servings))")
                }
                Section("Ingredients") {
                    if recipe.ingredients.isEmpty { Text("No ingredients yet").foregroundStyle(.secondary) }
                    ForEach(recipe.ingredients) { ing in IngredientRow(ingredient: ing) }
                }
                if !recipe.steps.isEmpty {
                    Section("Steps") {
                        ForEach(Array(recipe.steps.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                                Text(step)
                            }
                        }
                    }
                }
                if let notes = recipe.notes, !notes.isEmpty {
                    Section("Notes") { Text(notes) }
                }
                Section("Whole recipe") {
                    MacroLine(totals: recipe.totals)
                    if let w = recipe.cookedWeightGrams {
                        LabeledContent("Cooked weight", value: "\(Format.number(w, digits: 0)) g")
                    }
                    if !recipe.tags.isEmpty {
                        LabeledContent("Tags", value: recipe.tags.joined(separator: ", "))
                    }
                }
            }
            .navigationTitle(recipe.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = recipe } }
            }
            .sheet(item: $editing) { r in RecipeEditor(recipe: r, isNew: false) }
            .sheet(isPresented: $logging) {
                let food = recipe.asFood()
                NavigationStack {
                    PortionEditor(snapshot: food.snapshot, servings: food.servingOptions,
                                  initial: Portion(1, food.servings.first ?? .base(.serving)),
                                  slot: MealSlot.suggested(at: Date()), confirmTitle: "Log",
                                  onConfirm: { portion, slot in
                                      if model.log(food, portion: portion, slot: slot, on: model.today) {
                                          logging = false
                                          logged = true
                                      }
                                  })
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { logging = false } }
                        }
                }
            }
        } else {
            ContentUnavailableView("Recipe deleted", systemImage: "book.closed")
        }
    }
}

struct IngredientRow: View {
    let ingredient: RecipeIngredient

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(ingredient.food.name).lineLimit(2)
                Text(ingredient.portion.description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(NutrientTotals([ingredient.nutrients]).formatted(.energy)).monospacedDigit()
        }
    }
}

/// Name, servings, ingredients (from your foods or the catalog), steps and notes, with live macros per serving.
struct RecipeEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var recipe: Recipe
    @State private var stepsText: String
    @State private var tagsText: String
    @State private var addingIngredient = false
    @State private var editingIngredient: RecipeIngredient?
    let isNew: Bool

    init(recipe: Recipe, isNew: Bool) {
        _recipe = State(initialValue: recipe)
        _stepsText = State(initialValue: RecipeText.text(from: recipe.steps))
        _tagsText = State(initialValue: recipe.tags.joined(separator: ", "))
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $recipe.name).accessibilityIdentifier("recipe-name")
                    HStack {
                        Text("Servings")
                        NumberField(title: "servings", value: Binding(required: $recipe.servings))
                            .accessibilityIdentifier("recipe-servings")
                    }
                    HStack {
                        Text("Cooked weight")
                        NumberField(title: "optional", value: $recipe.cookedWeightGrams, digits: 0)
                        Text("g").foregroundStyle(.secondary)
                    }
                }
                Section("Per serving") {
                    MacroGrid(totals: recipe.perServing)
                }
                Section("Ingredients") {
                    ForEach(recipe.ingredients) { ing in
                        Button { editingIngredient = ing } label: { IngredientRow(ingredient: ing) }
                            .foregroundStyle(.primary)
                    }
                    .onDelete { recipe.ingredients.remove(atOffsets: $0) }
                    .onMove { recipe.ingredients.move(fromOffsets: $0, toOffset: $1) }
                    Button { addingIngredient = true } label: { Label("Add ingredient", systemImage: "plus") }
                        .accessibilityIdentifier("add-ingredient")
                }
                Section {
                    TextEditor(text: $stepsText).frame(minHeight: 100)
                } header: {
                    Text("Steps")
                } footer: {
                    Text("One step per line.")
                }
                Section("Tags and notes") {
                    TextField("Tags, comma separated", text: $tagsText)
                    TextField("Notes", text: Binding(get: { recipe.notes ?? "" },
                                                     set: { recipe.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                }
                if !isNew {
                    Section {
                        Button("Delete recipe", role: .destructive) {
                            if model.deleteRecipe(recipe.id) { dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New recipe" : "Edit recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var r = recipe
                        r.name = r.name.trimmingCharacters(in: .whitespaces)
                        r.steps = RecipeText.steps(from: stepsText)
                        r.tags = RecipeText.tags(from: tagsText)
                        if model.saveRecipe(r) { dismiss() }
                    }
                    .accessibilityIdentifier("recipe-save")
                }
            }
            .sheet(isPresented: $addingIngredient) {
                FoodPickerView(purpose: .ingredient) { food, portion, _ in
                    recipe.ingredients.append(RecipeIngredient(food: food, portion: portion))
                }
            }
            .sheet(item: $editingIngredient) { ing in
                NavigationStack {
                    PortionEditor(snapshot: ing.food, servings: model.servingOptions(for: ing.food, current: ing.portion.serving),
                                  initial: ing.portion, slot: nil, confirmTitle: "Save",
                                  onConfirm: { portion, _ in
                                      if let i = recipe.ingredients.firstIndex(where: { $0.id == ing.id }) {
                                          recipe.ingredients[i].portion = portion
                                      }
                                      editingIngredient = nil
                                  },
                                  onDelete: {
                                      recipe.ingredients.removeAll { $0.id == ing.id }
                                      editingIngredient = nil
                                  })
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingIngredient = nil } }
                        }
                }
            }
        }
    }
}
