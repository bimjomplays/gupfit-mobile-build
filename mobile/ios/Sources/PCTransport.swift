import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The app's way to the PC: an ephemeral URLSession (no cookies, cache or stored credentials) that follows no
/// redirects. Network failures become NoAnswer; HTTP answers, error statuses included, are returned.
final class URLSessionPCTransport: PCTransport, @unchecked Sendable {
    private let session: URLSession
    /// streams stay open while a reply comes; the PC sends a keepalive every 15 s, so a quiet 45 s is a dead line
    private let streamSession: URLSession

    init() {
        session = Self.makeSession(request: 15, resource: 60)
        streamSession = Self.makeSession(request: 45, resource: 15 * 60)
    }

    private static func makeSession(request: TimeInterval, resource: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = request
        c.timeoutIntervalForResource = resource
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        #if canImport(Darwin)
        c.waitsForConnectivity = false
        #endif
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }

    private static func urlRequest(_ r: PCRequest) -> URLRequest {
        var req = URLRequest(url: r.url)
        req.httpMethod = r.method
        req.httpBody = r.body
        for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    func send(_ r: PCRequest) async throws -> (status: Int, body: Data) {
        do {
            let (data, response) = try await session.data(for: Self.urlRequest(r))
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            throw Self.noAnswer(error)
        }
    }

    func open(_ r: PCRequest) async throws -> (status: Int, body: AsyncThrowingStream<Data, Error>) {
        #if canImport(Darwin)
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do {
            (bytes, response) = try await streamSession.bytes(for: Self.urlRequest(r))
        } catch {
            throw Self.noAnswer(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, AsyncThrowingStream { c in
            let task = Task {
                var line = Data()
                do {
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == 10 {  // a line at a time: the SSE parser takes pieces
                            c.yield(line)
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    if !line.isEmpty { c.yield(line) }
                    c.finish()
                } catch {
                    c.finish(throwing: Self.noAnswer(error))
                }
            }
            c.onTermination = { _ in task.cancel() }
        })
        #else
        throw NoAnswer.other(nil)  // Linux type-checks this file; GupFitKit's tests stream with their own transport
        #endif
    }

    static func noAnswer(_ error: Error) -> NoAnswer {
        if error is CancellationError { return .cancelled }
        guard let e = error as? URLError else { return .other(nil) }
        switch e.code {
        case .cannotFindHost, .dnsLookupFailed: return .noName
        case .timedOut: return .timeout
        case .cannotConnectToHost: return .refused
        case .networkConnectionLost: return .dropped
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return .secure
        case .cancelled: return .cancelled
        default: return .other(e.code.rawValue)
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
