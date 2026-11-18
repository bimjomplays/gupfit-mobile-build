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

    func testTransportErrorsSayWhichStepFailed() {
        XCTAssertEqual(URLSessionPCTransport.noAnswer(URLError(.cannotFindHost)), .noName)
        XCTAssertEqual(URLSessionPCTransport.noAnswer(URLError(.timedOut)), .timeout)
        XCTAssertEqual(URLSessionPCTransport.noAnswer(URLError(.serverCertificateUntrusted)), .secure)
        XCTAssertEqual(URLSessionPCTransport.noAnswer(URLError(.badServerResponse)), .other(URLError.badServerResponse.rawValue))
        XCTAssertEqual(URLSessionPCTransport.noAnswer(CancellationError()), .cancelled)
    }
}
