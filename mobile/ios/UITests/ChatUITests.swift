import XCTest

// ci-covers: ChatViews.swift ChatModel.swift QRScanner.swift PCTransport.swift KeychainPairingStore.swift GupFitApp.swift
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

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot())
        s.name = name
        s.lifetime = .keepAlways
        add(s)
    }
}
