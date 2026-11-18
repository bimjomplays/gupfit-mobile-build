import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

/// A pretend gupfit-pc: answers like pc/gupfit_pc.py (with the turns it is told to stream) and records requests.
final class FakePC: PCTransport, @unchecked Sendable {
    struct Turn { var events: [(String, String)]; var dropAfter: Int? = nil; var slow = false }

    private let lock = NSLock()
    private var _requests: [PCRequest] = []
    var requests: [PCRequest] { lock.withLock { _requests } }
    var accepted = "tok-" + String(repeating: "x", count: 40)
    var modelsStatus = 200
    var pairStatus = 200
    var turnStatus = 200
    var turnError = #"{"error":"GupWorks' model router isn't answering on the PC, so GPT models can't run.","code":"route_unavailable"}"#
    /// what the next opened turn streams; a reconnect (Last-Event-ID) gets the same turn's events after that id
    var turn = Turn(events: [])
    var dropsLeft = 0
    var cancelled = false

    static let models = #"""
    {"models":[{"id":"claude-haiku-5-5","label":"Haiku 5.5","provider":"claude","efforts":["low","high"],"available":true},
               {"id":"gpt-6.1-terra","label":"GPT 6.1 Terra","provider":"openai","efforts":["low"],"available":false,
                "reason":"router down"}],
     "routes":{"claude":{"ok":true},"openai":{"ok":false,"reason":"router down"}},
     "default":{"model":"claude-haiku-5-5","effort":"low"}}
    """#

    static func reply(_ words: [String], stop: String = "end") -> [(String, String)] {
        var out: [(String, String)] = [("turn", #"{"turn":"t","chat":"c","model":"claude-haiku-5-5","provider":"claude","effort":"low"}"#)]
        out += words.map { ("delta", try! String(data: JSONEncoder().encode(["text": $0]), encoding: .utf8)!) }
        out.append(("done", try! String(data: JSONEncoder().encode(["text": words.joined(), "stop": stop]), encoding: .utf8)!))
        return out
    }

    func send(_ r: PCRequest) async throws -> (status: Int, body: Data) {
        lock.withLock { _requests.append(r) }
        let authed = r.headers["Authorization"] == "Bearer " + accepted
        switch (r.method, r.url.path) {
        case ("POST", "/v1/pair"):
            if pairStatus != 200 { return (pairStatus, Data(#"{"error":"This pairing code is wrong, used or expired.","code":"bad_code"}"#.utf8)) }
            let reply: [String: String] = ["token": accepted, "device": "d1", "app": "gupfit-pc", "pc": "desk"]
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as! [String: Any]
            json["api"] = 1
            return (200, try JSONSerialization.data(withJSONObject: json))
        case _ where !authed:
            return (401, Data(#"{"error":"Not paired.","code":"not_paired"}"#.utf8))
        case ("GET", "/v1/models"):
            return modelsStatus == 200 ? (200, Data(Self.models.utf8)) : (modelsStatus, Data(#"{"error":"Not paired.","code":"not_paired"}"#.utf8))
        case ("POST", "/v1/unpair"):
            return (200, Data(#"{"ok":true}"#.utf8))
        case ("POST", let path) where path.hasSuffix("/cancel"):
            lock.withLock { cancelled = true }
            return (200, Data(#"{"ok":true}"#.utf8))
        default:
            return (404, Data(#"{"error":"No such route.","code":"not_found"}"#.utf8))
        }
    }

    func open(_ r: PCRequest) async throws -> (status: Int, body: AsyncThrowingStream<Data, Error>) {
        lock.withLock { _requests.append(r) }
        if r.headers["Authorization"] != "Bearer " + accepted {
            return (401, AsyncThrowingStream { c in c.yield(Data(#"{"error":"Not paired.","code":"not_paired"}"#.utf8)); c.finish() })
        }
        if turnStatus != 200 {
            let body = Data(turnError.utf8)
            return (turnStatus, AsyncThrowingStream { c in c.yield(body); c.finish() })
        }
        let after = Int(r.headers["Last-Event-ID"] ?? "") ?? 0
        let t = turn
        let drop: Int? = lock.withLock {
            guard dropsLeft > 0 else { return nil }
            dropsLeft -= 1
            return t.dropAfter
        }
        return (200, AsyncThrowingStream { c in
            Task {
                for (i, (name, data)) in t.events.enumerated() where i + 1 > after {
                    if let drop, i + 1 > drop { c.finish(throwing: NoAnswer.dropped); return }
                    if t.slow {
                        try? await Task.sleep(for: .milliseconds(50))
                        if self.lock.withLock({ self.cancelled }) {
                            c.yield(Data("id: \(i + 1)\nevent: done\ndata: {\"text\":\"partial\",\"stop\":\"cancelled\"}\n\n".utf8))
                            c.finish()
                            return
                        }
                    }
                    c.yield(Data("id: \(i + 1)\nevent: \(name)\ndata: \(data)\n\n".utf8))
                }
                c.finish()
            }
        })
    }
}

@MainActor
final class ChatControllerTests: XCTestCase {
    let link = "gupfit://pair?v=1&url=https%3A%2F%2Fdesktop.example.ts.net%3A10009&code=" + String(repeating: "c", count: 43)
    var pc: FakePC!
    var pairings: MemoryPairingStore!
    var history: MemoryChatHistoryStore!

    override func setUp() async throws {
        pc = FakePC()
        pairings = MemoryPairingStore()
        history = MemoryChatHistoryStore()
    }

    func controller() -> ChatController {
        let c = ChatController(client: PCClient(transport: pc), pairings: pairings, history: history,
                               deviceName: "Test iPhone")
        c.reconnectDelay = .milliseconds(1)
        c.stopGrace = .milliseconds(300)
        return c
    }

    func paired() async -> ChatController {
        let c = controller()
        let ok = await c.pair(link)
        XCTAssertTrue(ok)
        return c
    }

    func testPairingKeepsTheTokenAndLoadsThePicker() async throws {
        let c = controller()
        XCTAssertNil(c.state.pc)
        let ok = await c.pair(link)
        XCTAssertTrue(ok)
        XCTAssertEqual(pairings.load()?.token, pc.accepted)
        XCTAssertEqual(pairings.load()?.baseURL.absoluteString, "https://desktop.example.ts.net:10009")
        XCTAssertEqual(c.state.pc?.name, "desk")
        XCTAssertEqual(c.state.models.map(\.id), ["claude-haiku-5-5", "gpt-6.1-terra"])
        XCTAssertEqual(c.state.pick, ModelPick(model: "claude-haiku-5-5", effort: "low"))
        let pair = try XCTUnwrap(pc.requests.first)
        XCTAssertEqual(pair.url.absoluteString, "https://desktop.example.ts.net:10009/v1/pair")
        let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(pair.body))
        XCTAssertEqual(body, ["code": String(repeating: "c", count: 43), "device": "Test iPhone"])
    }

    func testALinkAsksFirstWithTheFullAddress() async throws {
        let c = controller()
        XCTAssertTrue(c.propose(link))
        let pending = try XCTUnwrap(c.state.pendingPair)
        XCTAssertEqual(pending.address, "desktop.example.ts.net:10009")
        XCTAssertFalse(pending.otherTailnet)
        XCTAssertTrue(pc.requests.isEmpty, "nothing is sent before the OK")
        c.cancelPair()
        XCTAssertNil(c.state.pendingPair)
        let none = await c.confirmPair()
        XCTAssertFalse(none)
        XCTAssertTrue(pc.requests.isEmpty)

        XCTAssertTrue(c.propose(link))
        let ok = await c.confirmPair()
        XCTAssertTrue(ok)
        XCTAssertNil(c.state.pendingPair)
        XCTAssertEqual(c.state.pc?.host, "desktop.example.ts.net:10009")
        XCTAssertEqual(history.loadPrefs().tailnet, "example.ts.net")
    }

    func testALinkFromAnotherTailnetIsFlagged() async throws {
        let c = await paired()
        c.choose(ModelPick(model: "gpt-6.1-terra", effort: "low"))  // saving prefs keeps the tailnet
        XCTAssertEqual(history.loadPrefs().tailnet, "example.ts.net")
        await c.unpair()
        let other = "gupfit://pair?v=1&url=https%3A%2F%2Fevil.desktop.ts.net%3A10009&code="
            + String(repeating: "e", count: 43)
        XCTAssertTrue(c.propose(other))
        XCTAssertEqual(c.state.pendingPair?.otherTailnet, true)
        XCTAssertEqual(c.state.pendingPair?.address, "evil.desktop.ts.net:10009")
        c.cancelPair()
        XCTAssertTrue(c.propose(link))
        XCTAssertEqual(c.state.pendingPair?.otherTailnet, false)
    }

    func testConfirmingWhatWasShownWorksAfterTheAlertClearedIt() async throws {
        let c = controller()
        XCTAssertTrue(c.propose(link))
        let shown = try XCTUnwrap(c.state.pendingPair)
        c.cancelPair()  // what SwiftUI's alert binding does before the button's action runs
        let ok = await c.confirmPair(shown)
        XCTAssertTrue(ok)
        XCTAssertNotNil(c.state.pc)
    }

    func testABadLinkIsRefusedBeforeAsking() {
        let c = controller()
        XCTAssertFalse(c.propose("gupfit://pair?v=1&url=https%3A%2F%2Fevil.example.com&code=" + String(repeating: "c", count: 43)))
        XCTAssertNil(c.state.pendingPair)
        XCTAssertEqual(c.state.problem, PairLink.Problem.badAddress.message)
    }

    func testBadLinksAndCodesSayWhy() async {
        let c = controller()
        var ok = await c.pair("hello")
        XCTAssertFalse(ok)
        XCTAssertEqual(c.state.problem, PairLink.Problem.notOurs.message)
        XCTAssertTrue(pc.requests.isEmpty)
        pc.pairStatus = 401
        ok = await c.pair(link)
        XCTAssertFalse(ok)
        XCTAssertEqual(c.state.problem, "This pairing code is wrong, used or expired.")
        XCTAssertNil(pairings.load())
    }

    func testSendStreamsTheReplyAndSavesTheChat() async throws {
        let c = await paired()
        pc.turn = .init(events: FakePC.reply(["About ", "31 g ", "of protein."]))
        var changes = 0
        c.onChange = { changes += 1 }
        XCTAssertTrue(c.send("  Protein in 100 g chicken?  "))
        XCTAssertNotNil(c.state.running)
        await c.waitForReply()
        XCTAssertNil(c.state.running)
        let msgs = c.state.current.messages
        XCTAssertEqual(msgs.map(\.role), [.user, .assistant])
        XCTAssertEqual(msgs[0].text, "Protein in 100 g chicken?")
        XCTAssertEqual(msgs[1].text, "About 31 g of protein.")
        XCTAssertEqual(msgs[1].state, .complete)
        XCTAssertEqual(msgs[1].model, "claude-haiku-5-5")
        XCTAssertGreaterThan(changes, 3, "the reply streamed in pieces")
        XCTAssertEqual(history.conversations().first?.messages, msgs, "kept on the phone")
        XCTAssertEqual(c.state.current.title, "Protein in 100 g chicken?")

        let turn = try XCTUnwrap(pc.requests.last)
        XCTAssertEqual(turn.url.path, "/v1/turns")
        XCTAssertEqual(turn.headers["Accept"], "text/event-stream")
        let req = try JSONDecoder().decode(TurnRequest.self, from: XCTUnwrap(turn.body))
        XCTAssertEqual(req.model, "claude-haiku-5-5")
        XCTAssertEqual(req.effort, "low")
        XCTAssertEqual(req.chat, c.state.openID)
        XCTAssertEqual(req.messages, [WireMessage(role: "user", text: "Protein in 100 g chicken?")])

        // the next turn carries the history
        pc.turn = .init(events: FakePC.reply(["Sure."]))
        c.send("And 200 g?")
        await c.waitForReply()
        let next = try JSONDecoder().decode(TurnRequest.self, from: XCTUnwrap(pc.requests.last?.body))
        XCTAssertEqual(next.messages.map(\.text), ["Protein in 100 g chicken?", "About 31 g of protein.", "And 200 g?"])
        XCTAssertNotEqual(next.turn, req.turn)
    }

    func testADroppedConnectionContinuesTheSameTurn() async throws {
        let c = await paired()
        pc.turn = .init(events: FakePC.reply(["one ", "two ", "three ", "four"]), dropAfter: 2)
        pc.dropsLeft = 2
        c.send("count")
        await c.waitForReply()
        let reply = try XCTUnwrap(c.state.current.messages.last)
        XCTAssertEqual(reply.text, "one two three four")
        XCTAssertEqual(reply.state, .complete)
        let turns = pc.requests.filter { $0.url.path == "/v1/turns" }
        XCTAssertEqual(turns.count, 3)
        let ids = Set(try turns.map { try JSONDecoder().decode(TurnRequest.self, from: XCTUnwrap($0.body)).turn })
        XCTAssertEqual(ids.count, 1, "the same turn id: the PC never runs it twice")
        XCTAssertEqual(turns.map { $0.headers["Last-Event-ID"] }, [nil, "2", "2"])
    }

    func testGivesUpAfterTheReconnects() async throws {
        let c = await paired()
        pc.turn = .init(events: FakePC.reply(["one ", "two ", "three"]), dropAfter: 2)
        pc.dropsLeft = 10
        c.send("count")
        await c.waitForReply()
        let reply = try XCTUnwrap(c.state.current.messages.last)
        XCTAssertEqual(reply.text, "one ", "what came is kept")
        XCTAssertEqual(reply.state, .failed(NoAnswer.dropped.message))
        XCTAssertEqual(pc.requests.filter { $0.url.path == "/v1/turns" }.count, 4)
    }

    func testAnUnavailableRouteFailsWithoutSwitchingModels() async throws {
        let c = await paired()
        c.choose(ModelPick(model: "gpt-6.1-terra", effort: "low"))
        pc.turnStatus = 503
        c.send("hi")
        await c.waitForReply()
        let reply = try XCTUnwrap(c.state.current.messages.last)
        XCTAssertEqual(reply.state, .failed("GupWorks' model router isn't answering on the PC, so GPT models can't run."))
        XCTAssertEqual(c.state.pick?.model, "gpt-6.1-terra", "still GPT: never moved to Claude")
        XCTAssertEqual(pc.requests.filter { $0.url.path == "/v1/turns" }.count, 1, "a refusal is not retried")
        XCTAssertEqual(history.loadPrefs().pick?.model, "gpt-6.1-terra")
    }

    func testModelErrorsShowInTheReply() async throws {
        let c = await paired()
        pc.turn = .init(events: [("delta", #"{"text":"Half"}"#),
                                 ("error", #"{"code":"provider_failed","message":"GPT answered with an error: plan limit","text":"Half"}"#)])
        c.send("hi")
        await c.waitForReply()
        let reply = try XCTUnwrap(c.state.current.messages.last)
        XCTAssertEqual(reply.text, "Half")
        XCTAssertEqual(reply.state, .failed("GPT answered with an error: plan limit"))
    }

    func testStopCancelsOnThePC() async throws {
        let c = await paired()
        pc.turn = .init(events: FakePC.reply(Array(repeating: "word ", count: 40)), slow: true)
        c.send("long")
        try await Task.sleep(for: .milliseconds(120))
        await c.stop()
        await c.waitForReply()
        XCTAssertTrue(pc.cancelled)
        let reply = try XCTUnwrap(c.state.current.messages.last)
        XCTAssertEqual(reply.state, .cancelled)
        XCTAssertEqual(reply.text, "partial")
        XCTAssertNil(c.state.running)
    }

    func testOneReplyAtATime() async {
        let c = await paired()
        pc.turn = .init(events: FakePC.reply(Array(repeating: "x ", count: 10)), slow: true)
        XCTAssertTrue(c.send("first"))
        XCTAssertFalse(c.send("second"))
        XCTAssertEqual(c.state.problem, "Wait for the reply, or stop it.")
        await c.stop()
        await c.waitForReply()
    }

    func testARevokedTokenUnpairs() async throws {
        let c = await paired()
        pc.accepted = "revoked-on-the-pc-" + String(repeating: "y", count: 30)
        await c.refreshModels()
        XCTAssertNil(c.state.pc)
        XCTAssertNil(pairings.load())
        XCTAssertFalse(c.send("hi"))
        XCTAssertEqual(c.state.problem, "Pair with your PC first.")
    }

    func testUnpairEndsTheTokenOnThePC() async throws {
        let c = await paired()
        await c.unpair()
        XCTAssertEqual(pc.requests.last?.url.path, "/v1/unpair")
        XCTAssertEqual(pc.requests.last?.headers["Authorization"], "Bearer " + pc.accepted)
        XCTAssertNil(pairings.load())
        XCTAssertNil(c.state.pc)
        XCTAssertTrue(c.state.models.isEmpty)
    }

    func testTheDemoPCPairsAndAnswers() async throws {
        let c = ChatController(client: PCClient(transport: DemoPC(delay: .milliseconds(1))), pairings: pairings,
                               history: history, deviceName: "Demo")
        let ok = await c.pair(DemoPC.link)
        XCTAssertTrue(ok)
        XCTAssertEqual(c.state.models.count, 2)
        c.send("protein?")
        await c.waitForReply()
        XCTAssertEqual(c.state.current.messages.last?.text,
                       "(Claude, demo) Cooked chicken breast has about 31 g of protein and 165 kcal per 100 g.")
    }

    func testChatsListOpenAndDelete() async throws {
        let c = await paired()
        pc.turn = .init(events: FakePC.reply(["ok"]))
        c.send("first chat")
        await c.waitForReply()
        let first = c.state.openID
        c.newChat()
        c.newChat()  // an empty chat isn't stacked
        XCTAssertEqual(c.state.conversations.count, 2)
        c.send("second chat")
        await c.waitForReply()
        XCTAssertEqual(c.state.listed.map(\.title), ["second chat", "first chat"])

        // a new controller (the app started again) opens the same chat with the same history
        let again = controller()
        XCTAssertEqual(again.state.openID, c.state.openID)
        XCTAssertEqual(again.state.listed.map(\.title), ["second chat", "first chat"])
        XCTAssertNotNil(again.state.pc)

        again.open(first)
        XCTAssertEqual(again.state.current.title, "first chat")
        again.delete(first)
        XCTAssertEqual(again.state.listed.map(\.title), ["second chat"])
        XCTAssertTrue(again.state.current.messages.isEmpty, "deleting the open chat opens a new one")
        XCTAssertEqual(history.conversations().count, 1)
    }
}
