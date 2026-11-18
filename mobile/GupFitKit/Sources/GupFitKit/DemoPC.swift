import Foundation

/// A pretend PC for the app's demo mode (`-chatDemo`, the UI tests and screenshots): pairs with any well-formed
/// link, lists one Claude and one GPT model, and streams a canned reply word by word. Nothing leaves the phone.
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
        let words = "(\(name), demo) Cooked chicken breast has about 31 g of protein and 165 kcal per 100 g."
            .split(separator: " ").map(String.init)
        let delay = self.delay
        return (200, AsyncThrowingStream { c in
            let task = Task {
                var text = ""
                for (i, w) in words.enumerated() {
                    let piece = (i == 0 ? "" : " ") + w
                    text += piece
                    let data = (try? JSONEncoder().encode(["text": piece])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    c.yield(Data("id: \(i + 1)\nevent: delta\ndata: \(data)\n\n".utf8))
                    try? await Task.sleep(for: delay)
                }
                let done = (try? JSONEncoder().encode(["text": text, "stop": "end"])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                c.yield(Data("id: \(words.count + 1)\nevent: done\ndata: \(done)\n\n".utf8))
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        })
    }
}
