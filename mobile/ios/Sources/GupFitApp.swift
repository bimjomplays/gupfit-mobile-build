import SwiftUI

@main
struct GupFitApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                // as the unit tests' host the app shows nothing
                if NSClassFromString("XCTestCase") != nil { Color.clear } else { RootView() }
            }
            .environment(model)
        }
    }
}

/// The four tabs. Today shows the (demo) day's log; the others are placeholders until their threads land.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    NavigationStack { screen(for: tab) }
                }
            }
        }
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .today: TodayView()
        case .workouts: WorkoutsView()
        case .recipes: RecipesView()
        case .chat: ChatPlaceholderView()
        }
    }
}
