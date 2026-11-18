import XCTest

// ci-covers: ChatViews.swift ChatModel.swift QRScanner.swift PCTransport.swift KeychainPairingStore.swift GupFitApp.swift AppModel.swift
/// The Chat tab against the app's pretend PC (-chatDemo): pair by pasting the link, pick a model, send, and watch the
/// reply stream in. No PC or network is involved.
final class ChatUITests: XCTestCase {
    static let link = "gupfit://pair?v=1&url=https%3A%2F%2Fdesk.example.ts.net%3A10009&code="
        + String(repeating: "d", count: 43)

    @MainActor
    func testPairPickAndChat() {
        let app = XCUIApplication()
        app.launchArguments += ["-chatDemo"]
        app.launch()
        app.tabBars.buttons["Chat"].tap()
        XCTAssertTrue(app.navigationBars["Chat"].waitForExistence(timeout: 10))
        let field = app.textFields["pairCode"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(Self.link)
        app.buttons["pairButton"].tap()
        let ask = app.alerts["Pair with this PC?"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "pairing asks first, with the full address")
        XCTAssertTrue(ask.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "desk.example.ts.net:10009"))
            .firstMatch.exists)
        shot(app, "chat-pair-confirm")
        ask.buttons["pairConfirm"].firstMatch.tap()  // iOS 26 nests the alert button in a second one

        let menu = app.buttons["modelMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "paired: the chat with its model picker")
        XCTAssertTrue(menu.label.contains("Haiku 5.5"), menu.label)
        shot(app, "chat-empty")

        menu.tap()
        app.buttons["GPT 6.1 Terra"].tap()
        app.buttons["Medium"].tap()
        XCTAssertTrue(menu.label.contains("GPT 6.1 Terra"), menu.label)

        let input = app.textViews["chatInput"].exists ? app.textViews["chatInput"] : app.textFields["chatInput"]
        input.tap()
        input.typeText("How much protein is in chicken?")
        app.buttons["chatSend"].tap()
        let reply = app.staticTexts.matching(identifier: "replyText").firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        let done = NSPredicate(format: "label CONTAINS %@", "per 100 g.")
        expectation(for: done, evaluatedWith: reply)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(reply.label.hasPrefix("(GPT, demo)"))
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 5), "Stop turns back into Send")
        shot(app, "chat-reply")
    }

    /// "Log 2 eggs for breakfast" against the pretend PC, whose model makes the tool calls a real one would: the
    /// phone logs exactly one entry on its own (demo) database, shows a card for it, Today has it, and Undo takes it
    /// back.
    @MainActor
    func testLogFromChatShowsACardAndUndoes() {
        let app = XCUIApplication()
        app.launchArguments += ["-chatDemo", "-store-name", "chat-ui", "-reset-store", "-demo-data"]
        app.launch()
        app.tabBars.buttons["Chat"].tap()
        let field = app.textFields["pairCode"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(Self.link)
        app.buttons["pairButton"].tap()
        let ask = app.alerts["Pair with this PC?"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5))
        ask.buttons["pairConfirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["modelMenu"].waitForExistence(timeout: 10))

        let input = app.textViews["chatInput"].exists ? app.textViews["chatInput"] : app.textFields["chatInput"]
        input.tap()
        input.typeText("Log 2 eggs for breakfast")
        app.buttons["chatSend"].tap()
        let undo = app.buttons["changeUndo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 15), "a card for the logged eggs, with Undo")
        let detail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Egg, large · 2 × 1 large · 140 kcal")).firstMatch
        XCTAssertTrue(detail.exists)
        XCTAssertEqual(app.buttons.matching(identifier: "changeUndo").count, 1, "exactly one change")
        let reply = app.staticTexts.matching(identifier: "replyText").firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS %@", "10 g fat."), evaluatedWith: reply)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.buttons["chatSend"].waitForExistence(timeout: 5))
        hideKeyboard(app)  // for the picture, and the tab bar is under it
        shot(app, "chat-log-card")

        app.tabBars.buttons["Today"].tap()
        let eggs = app.staticTexts["Egg, large"]
        XCTAssertTrue(eggs.waitForExistence(timeout: 5), "Today shows the entry the chat logged")
        app.tabBars.buttons["Chat"].tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(app.staticTexts["changeUndone"].waitForExistence(timeout: 5))
        shot(app, "chat-log-undone")
        app.tabBars.buttons["Today"].tap()
        XCTAssertFalse(app.staticTexts["Egg, large"].waitForExistence(timeout: 2), "Undo took it back")
    }

    /// A tap on the conversation puts the keyboard away.
    private func hideKeyboard(_ app: XCUIApplication) {
        for _ in 0..<2 where app.keyboards.firstMatch.exists {
            app.staticTexts.matching(identifier: "userMessage").firstMatch.tap()
            _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        }
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard went away")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot())
        s.name = name
        s.lifetime = .keepAlways
        add(s)
    }
}
