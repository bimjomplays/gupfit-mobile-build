import SwiftUI

@main
struct GupFitApp: App {
    @State private var launch: AppLaunch? = NSClassFromString("XCTestCase") != nil ? nil : AppLaunch.start()

    var body: some Scene {
        WindowGroup {
            switch launch {
            // as the unit tests' host the app opens nothing and shows nothing
            case nil: Color.clear
            case .ready(let model)?: RootView().environment(model).onAppear { ChatModel.shared.connect(model) }
            case .failed(let message)?: StartupErrorView(message: message)
            }
        }
    }
}

/// The four tabs, each with its own navigation, and the alert for a change that couldn't be saved.
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
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .chatLinks($model.tab)
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .today: TodayView()
        case .workouts: WorkoutsView()
        case .recipes: RecipesView()
        case .chat: ChatTab()
        }
    }
}

/// The database couldn't be opened (for example it was saved by a newer build). Nothing was changed; the app shows
/// why instead of starting empty and losing what would be logged.
struct StartupErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("GupFit can't open its data", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(message)
        }
        .accessibilityIdentifier("startup-error")
    }
}
