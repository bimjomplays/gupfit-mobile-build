import XCTest
@testable import GupFit

/// The Chat tab's model in demo mode (a pretend PC in memory): pairing, the picker and a streamed reply.
@MainActor
final class ChatModelTests: XCTestCase {
    func testDemoPairsAndStreamsAReply() async throws {
        let chat = ChatModel(arguments: ["-chatDemo"])
        XCTAssertNil(chat.state.pc)
        XCTAssertFalse(chat.take(URL(string: "https://example.com")!))
        XCTAssertTrue(chat.take(URL(string: DemoPC.link)!))
        XCTAssertEqual(chat.incomingLink, DemoPC.link)
        let paired = await chat.pair(DemoPC.link)
        XCTAssertTrue(paired)
        XCTAssertEqual(chat.state.pc?.name, "desk")
        XCTAssertEqual(chat.state.models.map(\.provider), ["claude", "openai"])
        chat.choose(ModelPick(model: "gpt-6.1-terra", effort: "medium"))
        XCTAssertTrue(chat.send("Protein in chicken?"))
        for _ in 0..<200 where chat.state.running != nil { try await Task.sleep(for: .milliseconds(20)) }
        let reply = try XCTUnwrap(chat.state.current.messages.last)
        XCTAssertEqual(reply.state, .complete)
        XCTAssertTrue(reply.text.hasPrefix("(GPT, demo)"))
        XCTAssertEqual(reply.model, "gpt-6.1-terra")
    }

    func testDemoLogsFromChatOnTheAppsStoreAndUndoes() async throws {
        let today = LocalDay(Date())
        let app = AppModel(store: Demo.store(day: today), catalog: nil, today: today)
        let chat = ChatModel(arguments: ["-chatDemo"])
        chat.connect(app)
        XCTAssertTrue(chat.hasTools)
        let paired = await chat.pair(DemoPC.link)
        XCTAssertTrue(paired)
        let before = app.todaySummary.entries.count
        let revision = app.revision
        XCTAssertTrue(chat.send("Log 2 eggs for breakfast"))
        for _ in 0..<200 where chat.state.running != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(app.todaySummary.entries.count, before + 1)
        XCTAssertGreaterThan(app.revision, revision, "the screens redraw")
        let card = try XCTUnwrap(chat.state.current.messages.last?.cards.first)
        XCTAssertEqual(card.detail, "Egg, large · 2 × 1 large · 140 kcal")
        chat.undo(card)
        XCTAssertEqual(app.todaySummary.entries.count, before)
        XCTAssertEqual(chat.state.current.messages.last?.cards.first?.state, .undone)
    }

    func testTransportErrorsSayWhichStepFailed() {
        XCTAssertEqual(URLSessionPCTransport.noAnswer(URLError(.cannotFindHost)), .noName)
        XCTAssertEqual(URLSessionPCTransport.noAnswer(URLError(.timedOut)), .timeout)
        XCTAssertEqual(URLSessionPCTransport.noAnswer(URLError(.serverCertificateUntrusted)), .secure)
        XCTAssertEqual(URLSessionPCTransport.noAnswer(URLError(.badServerResponse)), .other(URLError.badServerResponse.rawValue))
        XCTAssertEqual(URLSessionPCTransport.noAnswer(CancellationError()), .cancelled)
    }
}
