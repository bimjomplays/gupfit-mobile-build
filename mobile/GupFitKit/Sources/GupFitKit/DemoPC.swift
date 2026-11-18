import Foundation

/// A pretend PC for the app's demo mode (`-chatDemo`, the UI tests and screenshots): pairs with any well-formed
/// link, lists one Claude and one GPT model, and streams a canned reply word by word. "Log 2 eggs …" (in a chat with
/// tools) makes the tool calls a model would, which the phone runs on its own data. Nothing leaves the phone.
final class DemoPC: PCTransport, @unchecked Sendable {
    static let link = "gupfit://pair?v=1&url=https%3A%2F%2Fdesk.example.ts.net%3A10009&code="
        + String(repeating: "d", count: 43)
    let delay: Duration

    init(delay: Duration = .milliseconds(40)) { self.delay = delay }

    private static let models = #"""
    {"models":[{"id":"claude-haiku-5-5","label":"Haiku 5.5","provider":"claude","efforts":["low","medium","high"],"available":true},
               {"id":"gpt-6.1-terra","label":"GPT 6.1 Terra","provider":"openai","efforts":["low","medium","high"],"available":true}],
     "routes":{"claude":{"ok":true},"openai":{"ok":true}},"default":{"model":"claude-haiku-5-5","effort":"low"}}
    """#

    func send(_ r: PCRequest) async throws -> (status: Int, body: Data) {
        switch (r.method, r.url.path) {
        case ("POST", "/v1/pair"):
            return (200, Data(#"{"token":"demo","device":"demo","app":"gupfit-pc","api":1,"pc":"desk"}"#.utf8))
        case ("GET", "/v1/models"):
            return (200, Data(Self.models.utf8))
        case ("GET", "/v1/hello"):
            return (200, Data(#"{"app":"gupfit-pc","version":"demo","api":1,"pc":"desk","features":[]}"#.utf8))
        default:
            return (200, Data(#"{"ok":true}"#.utf8))
        }
    }

    func open(_ r: PCRequest) async throws -> (status: Int, body: AsyncThrowingStream<Data, Error>) {
        let req = r.body.flatMap { try? JSONDecoder().decode(TurnRequest.self, from: $0) }
        let name = req?.model.hasPrefix("gpt-") == true ? "GPT" : "Claude"
        let said = req?.messages.last?.text.lowercased() ?? ""
        var events: [(String, JSONValue)] = []
        let text: String
        if req?.tools != nil, said.contains("log"), said.contains("egg") {
            // "log 2 eggs for breakfast": the calls a model makes, run for real on the phone's (demo) data
            let meal = MealSlot.allCases.first { said.contains($0.rawValue) } ?? .breakfast
            events.append(("tool_call", ["call": "c-1", "name": "search_foods", "version": 1, "arguments": ["query": "egg"]]))
            events.append(("tool_call", ["call": "c-2", "name": "log_meal", "version": 1, "arguments": [
                "meal": .string(meal.rawValue), "items": [["food_id": "demo-egg", "amount": 2, "unit": "1 large (50 g)"]]]]))
            text = "(\(name), demo) Logged 2 large eggs to \(meal.rawValue): 140 kcal, 12 g protein, 1 g carbs, 10 g fat."
        } else {
            text = "(\(name), demo) Cooked chicken breast has about 31 g of protein and 165 kcal per 100 g."
        }
        let words = text.split(separator: " ").map(String.init)
        var built = ""
        for (i, w) in words.enumerated() {
            let piece = (i == 0 ? "" : " ") + w
            built += piece
            events.append(("delta", ["text": .string(piece)]))
        }
        events.append(("done", ["text": .string(built), "stop": "end"]))
        let delay = self.delay
        let script = events.enumerated().map { i, e in "id: \(i + 1)\nevent: \(e.0)\ndata: \(e.1.canonicalText)\n\n" }
        return (200, AsyncThrowingStream { c in
            let task = Task {
                for chunk in script {
                    c.yield(Data(chunk.utf8))
                    try? await Task.sleep(for: delay)
                }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        })
    }
}
