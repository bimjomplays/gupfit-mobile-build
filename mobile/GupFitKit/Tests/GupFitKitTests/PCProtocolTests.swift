import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

final class SSEParserTests: XCTestCase {
    func testEventsIdsKeepalivesAndSplitPieces() {
        var p = SSEParser()
        let raw = "id: 1\nevent: turn\ndata: {\"a\":1}\n\n: keepalive\n\nid: 2\r\nevent: delta\r\ndata: one\r\ndata: two\r\n\r\ndata: x\n\n"
        var out: [SSEEvent] = []
        // fed in odd-sized pieces, as the network delivers them
        let bytes = Array(raw.utf8)
        var i = 0
        while i < bytes.count {
            let end = min(i + 7, bytes.count)
            out += p.feed(Data(bytes[i..<end]))
            i = end
        }
        XCTAssertEqual(out, [SSEEvent(id: 1, name: "turn", data: "{\"a\":1}"),
                             SSEEvent(id: 2, name: "delta", data: "one\ntwo"),
                             SSEEvent(id: nil, name: "message", data: "x")])
    }

    func testTurnEventsDecode() {
        XCTAssertEqual(TurnEvent(SSEEvent(id: 1, name: "turn", data: #"{"turn":"t","chat":"c","model":"m","provider":"claude","effort":"low"}"#)),
                       .started(TurnInfo(turn: "t", chat: "c", model: "m", provider: "claude", effort: "low")))
        XCTAssertEqual(TurnEvent(SSEEvent(id: 2, name: "delta", data: #"{"text":"Hi"}"#)), .delta("Hi"))
        XCTAssertEqual(TurnEvent(SSEEvent(id: 3, name: "done", data: #"{"text":"Hi.","stop":"end"}"#)),
                       .done(text: "Hi.", stop: "end"))
        XCTAssertEqual(TurnEvent(SSEEvent(id: 3, name: "error", data: #"{"code":"timeout","message":"Too long.","text":"Hi"}"#)),
                       .failed(code: "timeout", message: "Too long.", text: "Hi"))
        XCTAssertEqual(TurnEvent(SSEEvent(id: 4, name: "tool_call", data: "{}")), .other("tool_call"))
        XCTAssertEqual(TurnEvent(SSEEvent(id: 4, name: "delta", data: "not json")), .other("delta"))
        XCTAssertTrue(TurnEvent.done(text: "", stop: "end").isLast)
        XCTAssertFalse(TurnEvent.delta("x").isLast)
    }
}

final class PairLinkTests: XCTestCase {
    let code = String(repeating: "aB3-_", count: 9)  // 45 characters

    func testParsesThePCsLink() throws {
        let text = "  gupfit://pair?v=1&url=https%3A%2F%2Fdesktop.example.ts.net%3A10009&code=\(code)\n"
        let link = try PairLink.parse(text).get()
        XCTAssertEqual(link.baseURL.absoluteString, "https://desktop.example.ts.net:10009")
        XCTAssertEqual(link.code, code)
    }

    func testRefusesOtherLinks() {
        func problem(_ s: String) -> PairLink.Problem? {
            if case .failure(let p) = PairLink.parse(s) { return p }
            return nil
        }
        let ok = "https%3A%2F%2Fdesktop.example.ts.net%3A10009"
        XCTAssertEqual(problem("gupworks3://pair?v=1&url=\(ok)&code=\(code)"), .notOurs)
        XCTAssertEqual(problem("https://example.com"), .notOurs)
        XCTAssertEqual(problem("gupfit://pair?v=1&v=1&url=\(ok)&code=\(code)"), .notOurs)
        XCTAssertEqual(problem("gupfit://pair?v=2&url=\(ok)&code=\(code)"), .newerVersion)
        XCTAssertEqual(problem("gupfit://pair?v=1&url=http%3A%2F%2Fdesktop.example.ts.net&code=\(code)"), .badAddress)
        XCTAssertEqual(problem("gupfit://pair?v=1&url=https%3A%2F%2Fevil.example.com&code=\(code)"), .badAddress)
        XCTAssertEqual(problem("gupfit://pair?v=1&url=https%3A%2F%2Fts.net&code=\(code)"), .badAddress)
        XCTAssertEqual(problem("gupfit://pair?v=1&url=https%3A%2F%2Fdesktop.example.ts.net%2Fpath&code=\(code)"), .badAddress)
        XCTAssertEqual(problem("gupfit://pair?v=1&url=https%3A%2F%2Fu%3Ap%40desktop.example.ts.net&code=\(code)"), .badAddress)
        XCTAssertEqual(problem("gupfit://pair?v=1&url=\(ok)&code=short"), .badCode)
        XCTAssertEqual(problem("gupfit://pair?v=1&url=\(ok)&code=\(code)%20"), .badCode)
    }
}

final class ModelPickTests: XCTestCase {
    let reply = ModelsReply(
        models: [ModelChoice(id: "claude-haiku-5-5", label: "Haiku 5.5", provider: "claude", efforts: ["low", "high"],
                             available: true),
                 ModelChoice(id: "gpt-6.1-terra", label: "Terra", provider: "openai", efforts: ["medium", "high"],
                             available: false, reason: "router down")],
        routes: ["claude": RouteState(ok: true), "openai": RouteState(ok: false, reason: "router down")],
        default: ModelPick(model: "claude-haiku-5-5", effort: "low"))

    func testKeepsTheSavedPickEvenWhenItsRouteIsDown() {
        XCTAssertEqual(reply.pick(keeping: ModelPick(model: "gpt-6.1-terra", effort: "high")),
                       ModelPick(model: "gpt-6.1-terra", effort: "high"), "never moved to Claude quietly")
        XCTAssertEqual(reply.pick(keeping: ModelPick(model: "gpt-6.1-terra", effort: "max")),
                       ModelPick(model: "gpt-6.1-terra", effort: "medium"), "an effort it lacks becomes its own default")
    }

    func testFallsBackToTheDefaultOnlyForAGoneModel() {
        XCTAssertEqual(reply.pick(keeping: ModelPick(model: "claude-old", effort: "low")), reply.default)
        XCTAssertEqual(reply.pick(keeping: nil), reply.default)
    }

    func testErrorAnswers() {
        XCTAssertEqual(PCError.answer(status: 401, body: Data(#"{"error":"Not paired.","code":"not_paired"}"#.utf8)),
                       .notPaired)
        XCTAssertEqual(PCError.answer(status: 401, body: Data(#"{"error":"Wrong code.","code":"bad_code"}"#.utf8)),
                       .refused(status: 401, code: "bad_code", message: "Wrong code."))
        XCTAssertEqual(PCError.answer(status: 503, body: Data("<html>".utf8)),
                       .refused(status: 503, code: "http_503", message: "Your PC answered 503."))
        XCTAssertEqual(PCError.from(NoAnswer.timeout), .unreachable(.timeout))
        XCTAssertEqual(PCError.from(CancellationError()), .unreachable(.cancelled))
    }
}

final class ConversationTests: XCTestCase {
    func message(_ role: ChatMessage.Role, _ text: String, _ state: ChatMessage.State = .complete) -> ChatMessage {
        ChatMessage(role: role, text: text, at: Date(timeIntervalSince1970: 0), state: state)
    }

    func testMessagesToSendTrimOldestAndStartWithTheUser() {
        var c = Conversation(created: Date(timeIntervalSince1970: 0))
        c.messages = [message(.user, "one"), message(.assistant, "uno"), message(.user, "two"),
                      message(.assistant, "", .failed("x")), message(.assistant, "dos"), message(.user, "three")]
        XCTAssertEqual(c.messagesToSend().map(\.text), ["one", "uno", "two", "dos", "three"])
        XCTAssertEqual(c.messagesToSend(maxMessages: 4).map(\.text), ["two", "dos", "three"],
                       "an assistant message left first is dropped")
        XCTAssertEqual(c.messagesToSend(maxChars: 13).map(\.text), ["two", "dos", "three"])
        c.messages = [message(.user, String(repeating: "a", count: 50))]
        XCTAssertEqual(c.messagesToSend(messageChars: 10).map(\.text), [String(repeating: "a", count: 10)])
    }

    func testTitle() {
        var c = Conversation(created: Date())
        XCTAssertEqual(c.title, "New chat")
        c.messages = [message(.user, "Log my breakfast\nplease")]
        XCTAssertEqual(c.title, "Log my breakfast")
        c.messages = [message(.user, String(repeating: "word ", count: 20))]
        XCTAssertEqual(c.title.count, 48)
        XCTAssertTrue(c.title.hasSuffix("…"))
    }

    func testFileStoreKeepsChatsAndSettlesInterruptedReplies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gupfit-chat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileChatHistoryStore(folder: dir)
        var a = Conversation(created: Date(timeIntervalSince1970: 100), pick: ModelPick(model: "m", effort: "low"))
        a.messages = [message(.user, "hi"), message(.assistant, "half a rep", .streaming)]
        var b = Conversation(created: Date(timeIntervalSince1970: 200))
        b.messages = [message(.user, "later")]
        try store.save(a)
        try store.save(b)
        try store.savePrefs(ChatPrefs(pick: ModelPick(model: "m", effort: "low"), open: a.id))

        let again = FileChatHistoryStore(folder: dir)
        let all = again.conversations()
        XCTAssertEqual(all.map(\.id), [b.id, a.id], "newest first")
        XCTAssertEqual(all[1].messages[1].text, "half a rep")
        XCTAssertEqual(all[1].messages[1].state, .failed("The app closed before the reply finished."))
        XCTAssertEqual(all[1].pick, ModelPick(model: "m", effort: "low"))
        XCTAssertEqual(again.loadPrefs().open, a.id)

        try again.delete(id: a.id)
        XCTAssertEqual(again.conversations().map(\.id), [b.id])
        XCTAssertThrowsError(try again.delete(id: a.id))
        XCTAssertThrowsError(try again.delete(id: "../escape"))
    }
}
