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
/// The phone's chat logic against the real PC service (pc/gupfit_pc.py) with its fake provider, over HTTP on
/// loopback: pairing with a code the PC made, the picker, a streamed turn, revocation from the PC and from the phone.
/// No model is called. Linux only (`swift test`); the app's own URLSession transport is checked on macOS CI.
@MainActor
final class PCEndToEndTests: XCTestCase {
    var server: Process?
    var dir: URL!
    var port = 0
    var env: [String: String] = [:]

    static var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    override func setUp() async throws {
        let script = Self.repo.appendingPathComponent("pc/gupfit_pc.py")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("needs python3 and pc/gupfit_pc.py")
        }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gupfit-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let catalog = dir.appendingPathComponent("models.json")
        try Data(#"{"models":[{"id":"claude-haiku-5-5","label":"Haiku 5.5","provider":"claude","efforts":["low","high"]},{"id":"gpt-6.1-terra","label":"GPT 6.1 Terra","provider":"openai","efforts":["low"]}]}"#.utf8)
            .write(to: catalog)
        env = ProcessInfo.processInfo.environment
        env["GUPFIT_PC_CONFIG"] = dir.appendingPathComponent("config").path
        env["GUPFIT_PC_STATE"] = dir.appendingPathComponent("state").path
        env["GUPFIT_PC_RUN"] = dir.appendingPathComponent("run").path
        env["GUPFIT_PC_MODELS"] = catalog.path
        port = Int.random(in: 18400...18999)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path, "serve", "--port", String(port), "--provider", "fake"]
        p.environment = env
        p.standardError = FileHandle.nullDevice
        try p.run()
        server = p
        // wait until it answers
        let transport = LoopbackTransport(port: port)
        for _ in 0..<100 {
            if let (status, _) = try? await transport.send(PCRequest(method: "GET", url: URL(string: "https://desktop.example.ts.net/v1/hello")!,
                                                                     headers: [:], body: nil)), status == 401 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("gupfit-pc didn't start")
    }

    override func tearDown() async throws {
        server?.terminate()
        server?.waitUntilExit()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// `gupfit-pc <args>` with the test's folders; its standard output
    func pcCommand(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [Self.repo.appendingPathComponent("pc/gupfit_pc.py").path] + args
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testPairChatAndRevoke() async throws {
        let printed = try pcCommand(["pair", "--url", "https://desktop.example.ts.net:10009", "--no-open"])
        let link = try XCTUnwrap(printed.split(separator: "\n").map(String.init).first { $0.hasPrefix("gupfit://pair?") })
        let pairings = MemoryPairingStore()
        let history = MemoryChatHistoryStore()
        let c = ChatController(client: PCClient(transport: LoopbackTransport(port: port)), pairings: pairings,
                               history: history, deviceName: "E2E iPhone")
        let paired = await c.pair(link)
        XCTAssertTrue(paired, c.state.problem ?? "")
        XCTAssertTrue(try pcCommand(["devices"]).contains("E2E iPhone"))
        // the code works once
        let again = ChatController(client: PCClient(transport: LoopbackTransport(port: port)), pairings: MemoryPairingStore(),
                                   history: MemoryChatHistoryStore(), deviceName: "Second")
        let pairedAgain = await again.pair(link)
        XCTAssertFalse(pairedAgain)
        XCTAssertEqual(again.state.problem?.hasPrefix("This pairing code is wrong, used or expired."), true)

        XCTAssertEqual(c.state.models.map(\.id), ["claude-haiku-5-5", "gpt-6.1-terra"])
        XCTAssertEqual(c.state.pick, ModelPick(model: "claude-haiku-5-5", effort: "low"))

        var pieces = 0
        var last = ""
        c.onChange = {
            let t = c.state.current.messages.last?.text ?? ""
            if t != last { pieces += 1; last = t }
        }
        XCTAssertTrue(c.send("How much protein is in an egg?"))
        await c.waitForReply()
        let reply = try XCTUnwrap(c.state.current.messages.last)
        XCTAssertEqual(reply.state, .complete)
        XCTAssertEqual(reply.text, "Fake claude-haiku-5-5: How much protein is in an egg?")
        XCTAssertGreaterThan(pieces, 3, "streamed word by word")

        c.choose(ModelPick(model: "gpt-6.1-terra", effort: "low"))
        c.send("And toast?")
        await c.waitForReply()
        XCTAssertEqual(c.state.current.messages.last?.text, "Fake gpt-6.1-terra: And toast?")
        XCTAssertEqual(c.state.current.messages.count, 4)

        // revoked on the PC: the phone finds out and shows pairing again
        XCTAssertTrue(try pcCommand(["revoke", "--all"]).contains("ended 1 phone token"))
        await c.refreshModels()
        XCTAssertNil(c.state.pc)
        XCTAssertNil(pairings.load())
    }

    func testUnpairFromThePhoneEndsItsToken() async throws {
        let printed = try pcCommand(["pair", "--url", "https://desktop.example.ts.net:10009", "--no-open"])
        let link = try XCTUnwrap(printed.split(separator: "\n").map(String.init).first { $0.hasPrefix("gupfit://pair?") })
        let pairings = MemoryPairingStore()
        let c = ChatController(client: PCClient(transport: LoopbackTransport(port: port)), pairings: pairings,
                               history: MemoryChatHistoryStore(), deviceName: "E2E iPhone")
        let paired = await c.pair(link)
        XCTAssertTrue(paired)
        let token = try XCTUnwrap(pairings.load())
        await c.unpair()
        XCTAssertTrue(try pcCommand(["devices"]).hasPrefix("0 paired phones"))
        do {
            _ = try await PCClient(transport: LoopbackTransport(port: port)).hello(token)
            XCTFail("the old token still works")
        } catch {
            XCTAssertEqual(error as? PCError, .notPaired)
        }
    }
}

/// HTTP to 127.0.0.1:<port> whatever host the request names (as tailscale serve does for the phone), streaming the
/// body through a delegate. Test-only: the app's transport is mobile/ios/Sources/PCTransport.swift.
final class LoopbackTransport: PCTransport, @unchecked Sendable {
    let port: Int

    init(port: Int) { self.port = port }

    private func urlRequest(_ r: PCRequest) -> URLRequest {
        var c = URLComponents(url: r.url, resolvingAgainstBaseURL: false)!
        c.scheme = "http"
        c.host = "127.0.0.1"
        c.port = port
        var req = URLRequest(url: c.url!)
        req.httpMethod = r.method
        req.httpBody = r.body
        for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    func send(_ r: PCRequest) async throws -> (status: Int, body: Data) {
        let (status, body) = try await open(r)
        var data = Data()
        for try await piece in body { data.append(piece) }
        return (status, data)
    }

    func open(_ r: PCRequest) async throws -> (status: Int, body: AsyncThrowingStream<Data, Error>) {
        let delegate = StreamDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let status: Int = try await withCheckedThrowingContinuation { cont in
            delegate.start(cont)
            session.dataTask(with: urlRequest(r)).resume()
        }
        return (status, delegate.stream(finally: { session.finishTasksAndInvalidate() }))
    }
}

private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var started: CheckedContinuation<Int, Error>?
    private var pending: [Data] = []
    private var ended: Error??
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    func start(_ c: CheckedContinuation<Int, Error>) { lock.withLock { started = c } }

    func stream(finally: @escaping @Sendable () -> Void) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { c in
            lock.withLock {
                for d in pending { c.yield(d) }
                pending = []
                if let ended { c.finish(throwing: ended); finally() } else { continuation = c }
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.withLock { started?.resume(returning: status); started = nil }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { if let continuation { continuation.yield(data) } else { pending.append(data) } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            if let started { started.resume(throwing: error ?? NoAnswer.dropped); self.started = nil }
            let err: Error? = error.map { _ in NoAnswer.dropped }
            if let continuation { continuation.finish(throwing: err) } else { ended = .some(err) }
        }
        session.finishTasksAndInvalidate()
    }
}
#endif
