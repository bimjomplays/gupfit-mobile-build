import Foundation

/// The paired PC: its address, the token it gave this phone and what it said about itself. The app keeps it in the
/// Keychain only (this device only, readable while unlocked, never synced), never in files or UserDefaults.
struct PCPairing: Codable, Equatable, Sendable {
    var baseURL: URL
    var token: String
    var device: String
    var pcName: String
    var pairedAt: Date

    /// The full address (host and port), for the UI: the machine name alone could be any tailnet's.
    var address: String { PairLink.address(of: baseURL) }
}

/// Where the pairing lives: the Keychain in the app (KeychainPairingStore), memory in tests.
protocol PairingStore: AnyObject, Sendable {
    func load() -> PCPairing?
    @discardableResult func save(_ pairing: PCPairing) -> Bool
    func clear()
}

final class MemoryPairingStore: PairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: PCPairing?

    init(_ pairing: PCPairing? = nil) { kept = pairing }

    func load() -> PCPairing? { lock.withLock { kept } }
    @discardableResult func save(_ pairing: PCPairing) -> Bool { lock.withLock { kept = pairing }; return true }
    func clear() { lock.withLock { kept = nil } }
}

/// The pairing link `gupfit-pc pair` shows as a QR code and prints:
///     gupfit://pair?v=1&url=<percent-encoded https://<pc>.<tailnet>.ts.net:10009>&code=<one-use code>
/// The address must be a Tailscale HTTPS name, so a crafted code can't point the app at an ordinary internet host.
struct PairLink: Equatable, Sendable {
    let baseURL: URL
    let code: String

    enum Problem: Error, Equatable, Sendable {
        case notOurs, newerVersion, badAddress, badCode

        var message: String {
            switch self {
            case .notOurs: return "That isn't a GupFit pairing code. On the PC, run gupfit-pc pair."
            case .newerVersion: return "The PC made a code this app doesn't know yet. Update the app, then try again."
            case .badAddress: return "The code's PC address isn't a Tailscale HTTPS name, so the app won't use it."
            case .badCode: return "The code is cut off or damaged. Make a new one on the PC."
            }
        }
    }

    static func parse(_ text: String) -> Result<PairLink, Problem> {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "gupfit", c.host?.lowercased() == "pair",
              c.path.isEmpty || c.path == "/", let items = c.queryItems else { return .failure(.notOurs) }
        var q: [String: String] = [:]
        for it in items {
            guard q[it.name] == nil else { return .failure(.notOurs) }  // a field twice: crafted, not from the PC
            q[it.name] = it.value ?? ""
        }
        guard let v = q["v"].flatMap(Int.init) else { return .failure(.notOurs) }
        guard v == 1 else { return .failure(v > 1 ? .newerVersion : .notOurs) }
        guard let raw = q["url"], let url = tailnetBaseURL(raw) else { return .failure(.badAddress) }
        guard let code = q["code"], isCode(code) else { return .failure(.badCode) }
        return .success(PairLink(baseURL: url, code: code))
    }

    /// https://<machine>.<tailnet>.ts.net[:port][/] with nothing else (no user, path, query or fragment)
    static func tailnetBaseURL(_ raw: String) -> URL? {
        guard let c = URLComponents(string: raw), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", let host = c.host?.lowercased() else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let ok = { (c: Character) in c.isASCII && (c.isLowercase || c.isNumber || c == "-") }
        guard labels.count >= 4, labels.suffix(2) == ["ts", "net"],
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.allSatisfy(ok) })
        else { return nil }
        var out = URLComponents()
        out.scheme = "https"
        out.host = host
        out.port = c.port
        return out.url
    }

    /// The full PC address the link points at, `<pc>.<tailnet>.ts.net[:port]`, to show before pairing.
    var address: String { Self.address(of: baseURL) }

    /// The tailnet part of the address, `<tailnet>.ts.net`: a link from another tailnet is someone else's PC.
    var tailnet: String { (baseURL.host ?? "").split(separator: ".").dropFirst().joined(separator: ".") }

    static func address(of url: URL) -> String {
        let host = url.host ?? ""
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// base64url without padding; the PC makes 43 characters (32 bytes)
    static func isCode(_ s: String) -> Bool {
        (43...128).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// One server-sent event: its `id:`, `event:` name and `data:` lines.
struct SSEEvent: Equatable, Sendable {
    var id: Int?
    var name: String
    var data: String
}

/// Reads an event stream byte by byte (\n or \r\n line ends; `:` lines are keepalives).
struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var id: Int?
    private var name = ""
    private var data: [String] = []

    mutating func feed(_ byte: UInt8) -> SSEEvent? {
        if byte == 13 { return nil }
        guard byte == 10 else { line.append(byte); return nil }
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            defer { id = nil; name = ""; data = [] }
            return data.isEmpty ? nil : SSEEvent(id: id, name: name.isEmpty ? "message" : name,
                                                 data: data.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }
        let field = text.prefix { $0 != ":" }
        var value = text.dropFirst(field.count).dropFirst()
        if value.hasPrefix(" ") { value = value.dropFirst() }
        switch field {
        case "event": name = String(value)
        case "data": data.append(String(value))
        case "id": id = Int(value)
        default: break
        }
        return nil
    }

    mutating func feed(_ bytes: Data) -> [SSEEvent] {
        bytes.compactMap { feed($0) }
    }
}
