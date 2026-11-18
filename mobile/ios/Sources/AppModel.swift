import Foundation
import Observation

/// The app's state for the screens. For now it reads the invented demo data from an in-memory store; the SQLite
/// store (the local data thread) replaces `store` without the screens changing.
@MainActor
@Observable
final class AppModel {
    var tab: AppTab = .today
    var goals: NutritionGoals = Demo.goals
    let store: any GupFitStore
    let today: LocalDay

    init(today: LocalDay = LocalDay(Date())) {
        self.today = today
        store = Demo.store(day: today)
    }

    var todaySummary: DaySummary {
        (try? store.summary(of: today)) ?? DaySummary(day: today, entries: [])
    }

    var recentWorkouts: [WorkoutSession] {
        let week = DateInterval(start: today.adding(days: -6).start(), end: today.adding(days: 1).start())
        return ((try? store.sessions(in: week)) ?? []).reversed()
    }

    var recipes: [Recipe] { (try? store.searchRecipes("")) ?? [] }
}
