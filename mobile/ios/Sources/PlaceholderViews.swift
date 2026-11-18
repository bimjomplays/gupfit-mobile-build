import SwiftUI

/// Placeholder: the AI chat talks to Claude or GPT through the PC (the PC bridge thread).
struct ChatPlaceholderView: View {
    var body: some View {
        ContentUnavailableView("Chat", systemImage: "bubble.left.and.text.bubble.right",
                               description: Text("Log food, workouts and recipes by just saying it. Coming soon."))
            .navigationTitle("Chat")
            .accessibilityIdentifier("screen-chat")
    }
}
