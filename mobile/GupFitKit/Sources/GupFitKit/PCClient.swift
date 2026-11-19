import Foundation

/// One HTTP request to the PC.
struct PCRequest: Equatable, Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?
}

/// How requests reach the PC: URLSession in the app (PCTransport.swift there), fakes in tests. Network failures are
/// thrown as NoAnswer; any HTTP answer, error statuses included, is returned.
protocol PCTransport: Sendable {
    /// the whole answer
    func send(_ request: PCRequest) async throws -> (status: Int, body: Data)
    /// the status, then the body in pieces as they arrive (an event stream)
    func open(_ request: PCRequest) async throws -> (status: Int, body: AsyncThrowingStream<Data, Error>)
}

/// Talks to gupfit-pc (pc/PROTOCOL.md).
struct PCClient: Sendable {
    let transport: any PCTransport

    func pair(_ link: PairLink, device: String, now: Date = Date()) async throws -> PCPairing {
        let reply: PCPairReply = try await call(link.baseURL, "POST", "/v1/pair", token: nil,
                                                body: ["code": link.code, "device": device])
        guard reply.app == "gupfit-pc" else { throw PCError.badAnswer }
        return PCPairing(baseURL: link.baseURL, token: reply.token, device: reply.device, pcName: reply.pc,
                         pairedAt: now)
    }

    func hello(_ p: PCPairing) async throws -> PCHello {
        try await call(p.baseURL, "GET", "/v1/hello", token: p.token)
    }

    func models(_ p: PCPairing) async throws -> ModelsReply {
        try await call(p.baseURL, "GET", "/v1/models", token: p.token)
    }

    /// Ends this phone's token on the PC.
    func unpair(_ p: PCPairing) async throws {
        let _: OK = try await call(p.baseURL, "POST", "/v1/unpair", token: p.token, body: [String: String]())
    }

    func cancel(_ p: PCPairing, turn: String) async throws {
        let _: OK = try await call(p.baseURL, "POST", "/v1/turns/\(turn)/cancel", token: p.token,
                                   body: [String: String]())
    }

    /// Answers one tool call of a running turn. 409 means the PC already had an answer for it (`answered`: an earlier
    /// try got through) or stopped waiting (`expired`).
    func toolResult(_ p: PCPairing, turn: String, _ body: ToolResultBody) async throws -> ToolDelivery {
        let req = try Self.request(p.baseURL, "POST", "/v1/turns/\(turn)/tool-results", token: p.token, body: body)
        let status: Int, data: Data
        do {
            (status, data) = try await transport.send(req)
        } catch {
            throw PCError.from(error)
        }
        switch status {
        case 200: return .delivered
        case 409, 404:
            let e = PCError.answer(status: status, body: data)
            if case .refused(_, "answered", _) = e { return .delivered }
            return .expired
        default: throw PCError.answer(status: status, body: data)
        }
    }

    /// Starts the turn, or (the same turn id again, after a dropped connection) attaches to it and continues after
    /// event `after`: the PC never runs a turn id twice. Yields (event id, event) until the last event.
    func turn(_ p: PCPairing, _ request: TurnRequest, after: Int = 0) -> AsyncThrowingStream<(Int?, TurnEvent), Error> {
        let transport = self.transport
        let req: PCRequest
        do {
            var r = try Self.request(p.baseURL, "POST", "/v1/turns", token: p.token, body: request)
            r.headers["Accept"] = "text/event-stream"
            if after > 0 { r.headers["Last-Event-ID"] = String(after) }
            req = r
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: PCError.badAnswer) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (status, body) = try await transport.open(req)
                    guard status == 200 else {
                        var data = Data()
                        for try await piece in body where data.count < 64_000 { data.append(piece) }
                        throw PCError.answer(status: status, body: data)
                    }
                    var parser = SSEParser()
                    for try await piece in body {
                        for e in parser.feed(piece) {
                            let ev = TurnEvent(e)
                            continuation.yield((e.id, ev))
                            if ev.isLast { continuation.finish(); return }
                        }
                    }
                    continuation.finish(throwing: PCError.unreachable(.dropped))  // ended before its last event
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? PCError.unreachable(.cancelled) : PCError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Plumbing

    private struct OK: Decodable { var ok: Bool }

    private func call<T: Decodable>(_ base: URL, _ method: String, _ path: String, token: String?) async throws -> T {
        try await perform(try Self.request(base, method, path, token: token, body: Optional<[String: String]>.none))
    }

    private func call<T: Decodable, B: Encodable>(_ base: URL, _ method: String, _ path: String, token: String?,
                                                  body: B) async throws -> T {
        try await perform(try Self.request(base, method, path, token: token, body: body))
    }

    private func perform<T: Decodable>(_ req: PCRequest) async throws -> T {
        let status: Int, data: Data
        do {
            (status, data) = try await transport.send(req)
        } catch {
            throw PCError.from(error)
        }
        guard status == 200 else { throw PCError.answer(status: status, body: data) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PCError.badAnswer
        }
    }

    static func request<B: Encodable>(_ base: URL, _ method: String, _ path: String, token: String?,
                                      body: B?) throws -> PCRequest {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.path = path
        c.query = nil
        guard let url = c.url else { throw PCError.badAnswer }
        var headers = ["Accept": "application/json"]
        if let token { headers["Authorization"] = "Bearer " + token }
        var data: Data?
        if let body {
            data = try JSONEncoder().encode(body)
            headers["Content-Type"] = "application/json"
        }
        return PCRequest(method: method, url: url, headers: headers, body: data)
    }
}
