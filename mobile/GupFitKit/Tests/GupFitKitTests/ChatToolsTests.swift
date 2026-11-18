import Foundation
import XCTest
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

/// The Chat tab running a fake model's tool calls on the phone's data: exactly one change for "log 2 eggs for
/// breakfast", replays after a reconnect, retries of the answer, a model repeating itself, invalid calls, a PC that
/// stopped waiting, and Undo from the change card.
@MainActor
final class ChatToolsTests: XCTestCase {
    let link = "gupfit://pair?v=1&url=https%3A%2F%2Fdesktop.example.ts.net%3A10009&code=" + String(repeating: "c", count: 43)
    var pc: FakePC!
    var history: MemoryChatHistoryStore!
    var store: InMemoryStore!
    var dataChanges = 0
    let day = Sample.day

    override func setUp() async throws {
        pc = FakePC()
        history = MemoryChatHistoryStore()
        store = Demo.store(day: day)
        dataChanges = 0
    }

    func controller(tools: Bool = true) async -> ChatController {
        let c = ChatController(client: PCClient(transport: pc), pairings: MemoryPairingStore(), history: history,
                               deviceName: "Test iPhone")
        c.reconnectDelay = .milliseconds(1)
        if tools {
            c.tools = ToolRunner(store: store, catalog: nil, today: { [day] in day })
        }
        c.onDataChange = { [weak self] in self?.dataChanges += 1 }
        let ok = await c.pair(link)
        XCTAssertTrue(ok)
        return c
    }

    static func event(_ name: String, _ data: JSONValue) -> (String, String) { (name, data.canonicalText) }

    static func toolCall(_ call: String, _ name: String, _ args: JSONValue) -> (String, String) {
        event("tool_call", ["call": .string(call), "name": .string(name), "version": 1, "arguments": args])
    }

    static let twoEggs: JSONValue = ["meal": "breakfast", "items": [["food_id": "demo-egg", "amount": 2, "unit": "1 large (50 g)"]]]

    /// a model that searches, logs the eggs once and says so
    static var eggTurn: [(String, String)] {
        [event("turn", ["turn": "t", "chat": "c", "model": "claude-haiku-5-5", "provider": "claude", "effort": "low"]),
         toolCall("c-1", "search_foods", ["query": "egg"]),
         toolCall("c-2", "log_meal", twoEggs),
         event("delta", ["text": "Logged 2 large eggs to breakfast: 140 kcal."]),
         event("done", ["text": "Logged 2 large eggs to breakfast: 140 kcal.", "stop": "end"])]
    }

    func breakfast() throws -> [MealEntry] { try store.entries(on: day).filter { $0.slot == .breakfast } }

    func testLogTwoEggsForBreakfastMakesExactlyOneEntryAndACard() async throws {
        let c = await controller()
        let before = try breakfast()
        pc.turn = .init(events: Self.eggTurn)
        XCTAssertTrue(c.send("log 2 eggs for breakfast"))
        await c.waitForReply()

        let after = try breakfast()
        XCTAssertEqual(after.count, before.count + 1, "exactly one new entry")
        let egg = try XCTUnwrap(after.first { $0.food.foodID == "demo-egg" })
        XCTAssertEqual(egg.portion, Portion(2, Serving("1 large", amount: 50)))
        XCTAssertEqual(egg.day, day)
        assertClose(egg.nutrients[.energy], 140)
        XCTAssertEqual(dataChanges, 1)

        let reply = try XCTUnwrap(c.state.current.messages.last)
        XCTAssertEqual(reply.text, "Logged 2 large eggs to breakfast: 140 kcal.")
        XCTAssertEqual(reply.cards.map(\.title), ["Logged to breakfast · today"])
        XCTAssertEqual(reply.cards.first?.detail, "Egg, large · 2 × 1 large · 140 kcal")
        XCTAssertEqual(reply.cards.first?.state, .done)
        XCTAssertNil(reply.cards.first?.note)
        XCTAssertEqual(history.conversations().first?.messages.last?.cards, reply.cards, "the cards are kept with the chat")

        // the PC got both answers, the search's foods and the logged entry
        XCTAssertEqual(pc.toolResults.map(\.call), ["c-1", "c-2"])
        XCTAssertTrue(pc.toolResults.allSatisfy(\.ok))
        XCTAssertEqual(pc.toolResults[0].result?["foods"]?.array?.first?["food_id"], "demo-egg")
        XCTAssertEqual(pc.toolResults[1].result?["logged"]?.array?.first?["entry_id"]?.string, egg.id.rawValue)
        let req = try JSONDecoder().decode(TurnRequest.self, from: XCTUnwrap(pc.requests.first { $0.url.path == "/v1/turns" }?.body))
        XCTAssertEqual(req.tools, 1)
        XCTAssertEqual(req.today, "2026-11-17")
    }

    func testAReplayedToolCallAfterAReconnectLogsNothingTwice() async throws {
        let c = await controller()
        let before = try breakfast().count
        pc.turn = .init(events: Self.eggTurn, dropAfter: 4)
        pc.dropsLeft = 2
        pc.replayAll = true  // each reconnect streams the whole turn again, tool calls included
        c.send("log 2 eggs for breakfast")
        await c.waitForReply()
        XCTAssertEqual(pc.requests.filter { $0.url.path == "/v1/turns" }.count, 3)
        XCTAssertEqual(try breakfast().count, before + 1, "three runs of the same call, one entry")
        XCTAssertEqual(c.state.current.messages.last?.cards.count, 1, "and one card")
        XCTAssertEqual(c.state.current.messages.last?.state, .complete)
        XCTAssertEqual(dataChanges, 1)
        XCTAssertEqual(pc.toolResults.count, 2, "the PC kept each call's first answer; the replays got 409 answered")
        XCTAssertNil(c.state.current.messages.last?.cards.first?.note)
    }

    func testTheAnswerIsSentAgainWhenTheConnectionDrops() async throws {
        let c = await controller()
        pc.turn = .init(events: Self.eggTurn)
        pc.toolDropsLeft = 2
        c.send("log 2 eggs for breakfast")
        await c.waitForReply()
        XCTAssertEqual(pc.toolPosts, 4, "two drops, then search_foods and log_meal")
        XCTAssertEqual(pc.toolResults.map(\.call), ["c-1", "c-2"])
        XCTAssertEqual(try breakfast().filter { $0.food.foodID == "demo-egg" }.count, 1)
    }

    func testAnAnswerWhoseReplyWasLostCountsAsDelivered() async throws {
        let c = await controller()
        pc.turn = .init(events: Self.eggTurn)
        pc.toolLostRepliesLeft = 2  // both arrive, but the phone doesn't hear back: the retries get 409 answered
        c.send("log 2 eggs for breakfast")
        await c.waitForReply()
        XCTAssertEqual(pc.toolPosts, 4)
        XCTAssertEqual(pc.toolResults.count, 2)
        XCTAssertNil(c.state.current.messages.last?.cards.first?.note)
    }

    func testAPCThatStoppedWaitingIsNotedOnTheCard() async throws {
        let c = await controller()
        pc.turn = .init(events: Self.eggTurn)
        pc.expiredCalls = ["c-2"]
        c.send("log 2 eggs for breakfast")
        await c.waitForReply()
        let card = try XCTUnwrap(c.state.current.messages.last?.cards.first)
        XCTAssertEqual(card.note, "Saved on the phone, but the reply didn't hear about it.")
        XCTAssertEqual(card.state, .done, "it was saved: Undo is still there")
        XCTAssertEqual(try breakfast().filter { $0.food.foodID == "demo-egg" }.count, 1)
    }

    func testTheSameCallTwiceInOneReplyLogsOnce() async throws {
        let c = await controller()
        let before = try breakfast().count
        var events = Self.eggTurn
        events.insert(Self.toolCall("c-3", "log_meal", Self.twoEggs), at: 3)  // the model logs it again
        pc.turn = .init(events: events)
        c.send("log 2 eggs for breakfast")
        await c.waitForReply()
        XCTAssertEqual(try breakfast().count, before + 1)
        XCTAssertEqual(c.state.current.messages.last?.cards.count, 1)
        XCTAssertEqual(pc.toolResults.map(\.call), ["c-1", "c-2", "c-3"])
        XCTAssertEqual(pc.toolResults[2].result?["note"]?.string?.hasPrefix("This exact change was already made"), true)
    }

    func testAnInvalidCallChangesNothingAndSaysSo() async throws {
        let c = await controller()
        let before = try store.entries(on: day)
        pc.turn = .init(events: [
            Self.toolCall("c-1", "log_meal", ["meal": "breakfast", "items": [["food_id": "demo-egg", "amount": 2, "unit": "slice"]]]),
            Self.toolCall("c-2", "drop_everything", [:]),
            Self.toolCall("c-3", "get_day", ["date": "yesterday"]),
            Self.event("done", ["text": "I couldn't log that.", "stop": "end"]),
        ])
        c.send("log 2 slices of egg")
        await c.waitForReply()
        XCTAssertEqual(try store.entries(on: day), before)
        XCTAssertEqual(dataChanges, 0)
        XCTAssertEqual(pc.toolResults.map(\.ok), [false, false, false])
        XCTAssertEqual(pc.toolResults[0].error, "items[0].unit: \"slice\" isn't a unit of Egg, large; use one of: 1 large (50 g), g, kg, oz, lb")
        XCTAssertNil(pc.toolResults[0].result)
        let cards = try XCTUnwrap(c.state.current.messages.last?.cards)
        XCTAssertEqual(cards.map(\.state), [.failed, .failed], "the failed changes show as Not saved; the failed read doesn't")
        XCTAssertEqual(cards.map(\.title), ["Not saved", "Not saved"])
        XCTAssertFalse(cards[0].canUndo)
    }

    func testUndoFromTheCardAndTheModelHearsAboutIt() async throws {
        let c = await controller()
        let before = try store.entries(on: day)
        pc.turn = .init(events: Self.eggTurn)
        c.send("log 2 eggs for breakfast")
        await c.waitForReply()
        let card = try XCTUnwrap(c.state.current.messages.last?.cards.first)
        XCTAssertTrue(card.canUndo)
        c.undo(card)
        XCTAssertEqual(try store.entries(on: day), before)
        XCTAssertEqual(c.state.current.messages.last?.cards.first?.state, .undone)
        XCTAssertEqual(dataChanges, 2)
        XCTAssertEqual(history.conversations().first?.messages.last?.cards.first?.state, .undone)
        c.undo(card)  // a second tap does nothing
        XCTAssertEqual(dataChanges, 2)

        pc.turn = .init(events: FakePC.reply(["OK."]))
        c.send("thanks")
        await c.waitForReply()
        let next = try JSONDecoder().decode(TurnRequest.self, from: XCTUnwrap(pc.requests.last { $0.url.path == "/v1/turns" }?.body))
        XCTAssertEqual(next.messages[1].text, "Logged 2 large eggs to breakfast: 140 kcal.\n\n[In the app, the user then undid: "
            + "Logged to breakfast · today: Egg, large · 2 × 1 large · 140 kcal]")
    }

    func testUndoOfSomethingChangedSinceSaysWhy() async throws {
        let c = await controller()
        pc.turn = .init(events: Self.eggTurn)
        c.send("log 2 eggs for breakfast")
        await c.waitForReply()
        var egg = try XCTUnwrap(try breakfast().first { $0.food.foodID == "demo-egg" })
        egg.portion.count = 3
        try store.saveEntry(egg)
        let card = try XCTUnwrap(c.state.current.messages.last?.cards.first)
        c.undo(card)
        XCTAssertEqual(c.state.current.messages.last?.cards.first?.state, .done)
        XCTAssertEqual(c.state.current.messages.last?.cards.first?.note, "It was changed again after this, so Undo left it as it is.")
        XCTAssertEqual(try store.entry(id: egg.id)?.portion.count, 3)
    }

    func testAChatWithoutToolsAsksForNoneAndRefusesStrayCalls() async throws {
        let c = await controller(tools: false)
        let before = try store.entries(on: day)
        pc.turn = .init(events: [Self.toolCall("c-1", "log_meal", Self.twoEggs), Self.event("done", ["text": "x", "stop": "end"])])
        c.send("log 2 eggs")
        await c.waitForReply()
        let req = try JSONDecoder().decode(TurnRequest.self, from: XCTUnwrap(pc.requests.first { $0.url.path == "/v1/turns" }?.body))
        XCTAssertNil(req.tools)
        XCTAssertNil(req.today)
        XCTAssertEqual(pc.toolResults.first?.ok, false)
        XCTAssertEqual(try store.entries(on: day), before)
    }

    func testWorkoutAndRecipeChangesFromChat() async throws {
        let c = await controller()
        pc.turn = .init(events: [
            Self.toolCall("c-1", "list_exercises", [:]),
            Self.toolCall("c-2", "log_workout", ["exercises": [["exercise_id": "demo-squat", "sets": [
                ["reps": 5, "weight": 225, "weight_unit": "lb"], ["reps": 5, "weight": 225, "weight_unit": "lb"],
                ["reps": 5, "weight": 225, "weight_unit": "lb"]]]]]),
            Self.toolCall("c-3", "log_recipe", ["recipe_id": "demo-r1", "servings": 1, "meal": "dinner"]),
            Self.event("done", ["text": "Done.", "stop": "end"]),
        ])
        c.send("add my squat workout: 3x5 at 225, and a bowl for dinner")
        await c.waitForReply()
        let cards = try XCTUnwrap(c.state.current.messages.last?.cards)
        XCTAssertEqual(cards.map(\.kind), [.workoutLogged, .mealLogged])
        XCTAssertEqual(cards[0].detail, "Workout: Back squat 3×5 @ 225 lb")
        XCTAssertEqual(cards[1].detail, "Chicken rice bowl · 1 × serving · 456 kcal")
        XCTAssertEqual(try store.entries(on: day).filter { $0.slot == .dinner }.count, 1)
    }

    /// the app's demo PC (UI tests, screenshots) makes the same calls a model would
    func testTheDemoPCLogsTwoEggsThroughTheTools() async throws {
        let c = ChatController(client: PCClient(transport: DemoPC(delay: .milliseconds(1))), pairings: MemoryPairingStore(),
                               history: history, deviceName: "Demo")
        c.tools = ToolRunner(store: store, catalog: nil, today: { [day] in day })
        let ok = await c.pair(DemoPC.link)
        XCTAssertTrue(ok)
        let before = try breakfast().count
        c.send("Log 2 eggs for breakfast")
        await c.waitForReply()
        XCTAssertEqual(try breakfast().count, before + 1)
        XCTAssertEqual(c.state.current.messages.last?.cards.map(\.detail), ["Egg, large · 2 × 1 large · 140 kcal"])
        XCTAssertTrue(c.state.current.messages.last?.text.hasPrefix("(Claude, demo) Logged 2 large eggs to breakfast") == true)
    }
}
