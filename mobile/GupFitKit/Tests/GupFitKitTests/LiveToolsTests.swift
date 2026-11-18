import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(GupFitKit)
@testable import GupFitKit
#else
@testable import GupFit
#endif

#if SWIFT_PACKAGE && os(Linux)
/// The live check of the AI actions, on this PC: the phone's own chat and tool code (ChatController + ToolRunner on a
/// fresh SQLite database with the bundled USDA catalog) against the real gupfit-pc with real models on the PC's plans.
/// For each model it says "log 2 eggs for breakfast" and checks that exactly one correct entry was made.
///
/// Off unless asked for, since it calls real models:
///   GUPFIT_LIVE=1 swift test --package-path mobile/GupFitKit --filter LiveToolsTests
///   GUPFIT_LIVE_MODELS="claude-haiku-5-5:low,gpt-6.1-terra:low"   (the default)
/// The service runs on a spare loopback port with throwaway tokens; paired phones are untouched. Only the demo
/// sentence and what the tools return about this empty test database go to the providers.
@MainActor
final class LiveToolsTests: XCTestCase {
    func testLogTwoEggsForBreakfastOnRealModels() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GUPFIT_LIVE"] == "1" else { throw XCTSkip("set GUPFIT_LIVE=1 to call real models") }
        let repo = PCEndToEndTests.repo
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gupfit-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var penv = env
        penv["GUPFIT_PC_CONFIG"] = dir.appendingPathComponent("config").path
        penv["GUPFIT_PC_STATE"] = dir.appendingPathComponent("state").path
        penv["GUPFIT_PC_RUN"] = dir.appendingPathComponent("run").path
        penv["GUPFIT_PC_LOG_INIT"] = "1"
        let port = Int.random(in: 18400...18999)
        let script = repo.appendingPathComponent("pc/gupfit_pc.py").path
        let log = dir.appendingPathComponent("service.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script, "serve", "--port", String(port)]
        server.environment = penv
        server.standardError = try FileHandle(forWritingTo: log)
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }

        let transport = LoopbackTransport(port: port)
        for _ in 0..<100 {
            if let (status, _) = try? await transport.send(PCRequest(method: "GET", url: URL(string: "https://desktop.example.ts.net/v1/hello")!,
                                                                     headers: [:], body: nil)), status == 401 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        /// a fresh one-use pairing link from `gupfit-pc pair`
        func newLink() throws -> String {
            let pair = Process()
            pair.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            pair.arguments = [script, "pair", "--url", "https://desktop.example.ts.net:10009", "--no-open"]
            pair.environment = penv
            let out = Pipe()
            pair.standardOutput = out
            try pair.run()
            let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            pair.waitUntilExit()
            return try XCTUnwrap(printed.split(separator: "\n").map(String.init).first { $0.hasPrefix("gupfit://pair?") })
        }

        let catalogPath = repo.appendingPathComponent("data/catalog.sqlite").path
        let catalog = try FoodCatalog(path: catalogPath)
        let picks = (env["GUPFIT_LIVE_MODELS"] ?? "claude-haiku-5-5:low,gpt-6.1-terra:low").split(separator: ",").map {
            let p = $0.split(separator: ":").map(String.init)
            return ModelPick(model: p[0], effort: p.count > 1 ? p[1] : "low")
        }
        var report: [String] = []
        for pick in picks {
            // a fresh phone database each time: nothing logged, no foods of its own, the catalog only
            let store = try SQLiteStore(url: dir.appendingPathComponent("phone-\(pick.model)/gupfit.sqlite"))
            defer { store.close() }
            let c = ChatController(client: PCClient(transport: transport), pairings: MemoryPairingStore(),
                                   history: MemoryChatHistoryStore(), deviceName: "Live check")
            c.tools = ToolRunner(store: store, catalog: catalog)
            let paired = await c.pair(try newLink())
            XCTAssertTrue(paired, c.state.problem ?? "")
            c.choose(pick)
            let started = Date()
            XCTAssertTrue(c.send("log 2 eggs for breakfast"))
            await c.waitForReply()
            let reply = try XCTUnwrap(c.state.current.messages.last)
            let today = LocalDay(Date())
            let entries = try store.entries(on: today)
            let receipts = try (1...30).compactMap { try store.receipt(turn: reply.turn ?? "", call: "c-\($0)") }
            report.append("""
                \(pick.model) (\(pick.effort)): \(String(format: "%.1f", Date().timeIntervalSince(started))) s, state \(reply.state)
                  calls: \(receipts.map { "\($0.name) \($0.ok ? "ok" : "failed: \($0.error ?? "")")" }.joined(separator: "; "))
                  entries: \(entries.map { "\($0.slot.rawValue) \($0.day) \($0.portion.description) \($0.food.name) \(Format.number($0.portion.baseAmount)) g \(Format.number($0.nutrients[.energy] ?? -1)) kcal" })
                  cards: \(reply.cards.map { "\($0.title) | \($0.detail)" })
                  reply: \(reply.text.replacingOccurrences(of: "\n", with: " "))
                """)
            XCTAssertEqual(reply.state, .complete, "\(pick.model): \(reply.state)")
            XCTAssertEqual(entries.count, 1, "\(pick.model): exactly one entry, got \(entries.count)")
            if let e = entries.first {
                XCTAssertEqual(e.slot, .breakfast, pick.model)
                XCTAssertEqual(e.day, today, pick.model)
                XCTAssertTrue(e.food.name.lowercased().contains("egg"), "\(pick.model): \(e.food.name)")
                XCTAssertFalse(["dried", "powder", "yolk", "white", "duck", "goose", "quail", "scrambled", "omelet", "fried"].contains { e.food.name.lowercased().contains($0) },
                               "\(pick.model): a plain whole egg, got \(e.food.name)")
                XCTAssertEqual(e.portion.baseAmount, 100, accuracy: 15, "\(pick.model): two eggs weigh about 100 g")
            }
            XCTAssertEqual(reply.cards.filter { $0.state == .done }.count, 1, pick.model)
        }
        let service = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let text = report.joined(separator: "\n") + "\n\nservice log:\n" + service
        print(text)
        if let path = env["GUPFIT_LIVE_REPORT"] { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
#endif
