import SwiftUI

/// Placeholder: this week's sessions from the demo store. Logging workouts comes with the local data thread.
struct WorkoutsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sessions = model.recentWorkouts
        Group {
            if sessions.isEmpty {
                ContentUnavailableView("No workouts yet", systemImage: "dumbbell")
            } else {
                List(sessions) { s in
                    VStack(alignment: .leading) {
                        Text(s.title).font(.headline)
                        Text("\(s.workingSetCount) sets · \(Format.number(s.volumeKg, digits: 0)) kg volume")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Workouts")
        .accessibilityIdentifier("screen-workouts")
    }
}

/// Placeholder: the demo recipes with calories per serving.
struct RecipesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recipes = model.recipes
        Group {
            if recipes.isEmpty {
                ContentUnavailableView("No recipes yet", systemImage: "book.closed")
            } else {
                List(recipes) { r in
                    VStack(alignment: .leading) {
                        Text(r.name).font(.headline)
                        Text("\(r.perServing.formatted(.energy)) per serving · \(Format.number(r.servings)) servings")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Recipes")
        .accessibilityIdentifier("screen-recipes")
    }
}

/// Placeholder: the AI chat talks to Claude or GPT through the PC (the PC bridge thread).
struct ChatPlaceholderView: View {
    var body: some View {
        ContentUnavailableView("Chat", systemImage: "bubble.left.and.text.bubble.right",
                               description: Text("Log food, workouts and recipes by just saying it. Coming soon."))
            .navigationTitle("Chat")
            .accessibilityIdentifier("screen-chat")
    }
}
