import Foundation

// What gupfit-pc sends and takes (pc/PROTOCOL.md, API 1). The PC runs the chat on Claude or GPT through the
// owner's existing plans; the phone has no model keys and owns the chat history.

/// GET /v1/hello, and the fields of the pairing answer that describe the PC.
struct PCHello: Codable, Equatable, Sendable {
    var app: String
    var version: String
    var api: Int
    var pc: String
    var features: [String]
}

/// POST /v1/pair's answer.
struct PCPairReply: Codable, Equatable, Sendable {
    var token: String
    var device: String
    var app: String
    var api: Int
    var pc: String
}

/// One model of the PC's picker: Claude or GPT, the efforts it takes, and whether its route runs right now.
struct ModelChoice: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var provider: String  // "claude" | "openai"
    var efforts: [String]
    var available: Bool
    var reason: String?

    var providerName: String { provider == "claude" ? "Claude" : provider == "openai" ? "GPT" : provider }
}

struct RouteState: Codable, Equatable, Sendable {
    var ok: Bool
    var reason: String?
}

/// The model and effort a turn runs on.
struct ModelPick: Codable, Equatable, Hashable, Sendable {
    var model: String
    var effort: String
}

/// GET /v1/models
struct ModelsReply: Codable, Equatable, Sendable {
    var models: [ModelChoice]
    var routes: [String: RouteState]
    var `default`: ModelPick?

    /// `saved` when the picker still has it (with an effort it takes), else the PC's default. Never quietly moves
    /// a saved pick to another provider: a saved model that is listed but unavailable stays picked, and the turn
    /// then fails with the PC's reason.
    func pick(keeping saved: ModelPick?) -> ModelPick? {
        if let saved, let m = models.first(where: { $0.id == saved.model }) {
            let effort = m.efforts.contains(saved.effort) ? saved.effort : Self.defaultEffort(m)
            return ModelPick(model: m.id, effort: effort)
        }
        return `default` ?? models.first(where: \.available).map { ModelPick(model: $0.id, effort: Self.defaultEffort($0)) }
    }

    static func defaultEffort(_ m: ModelChoice) -> String {
        ["low", "medium"].first(where: m.efforts.contains) ?? m.efforts.first ?? ""
    }
}

/// One message as the PC takes it.
struct WireMessage: Codable, Equatable, Sendable {
    var role: String  // "user" | "assistant"
    var text: String
}

/// POST /v1/turns
struct TurnRequest: Codable, Equatable, Sendable {
    var turn: String
    var chat: String
    var model: String
    var effort: String
    var messages: [WireMessage]
}

/// Limits the PC enforces on a turn (pc/gupfit_pc.py); the phone trims to fit before sending.
enum TurnLimits {
    static let messages = 200
    static let messageChars = 16_000
    static let totalChars = 120_000
}

/// The first event of a turn: what runs it.
struct TurnInfo: Codable, Equatable, Sendable {
    var turn: String
    var chat: String
    var model: String
    var provider: String
    var effort: String
}

/// One event of a turn's stream, decoded.
enum TurnEvent: Equatable, Sendable {
    case started(TurnInfo)
    case delta(String)
    /// the whole reply (replaces what the deltas built); `stop` is "end" or "cancelled"
    case done(text: String, stop: String)
    /// `text` is what streamed before the failure
    case failed(code: String, message: String, text: String)
    /// an event this version doesn't know (tool_call arrives with milestone 5): ignored
    case other(String)

    var isLast: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }

    init(_ e: SSEEvent) {
        let data = Data(e.data.utf8)
        let d = JSONDecoder()
        switch e.name {
        case "turn":
            if let info = try? d.decode(TurnInfo.self, from: data) { self = .started(info); return }
        case "delta":
            if let x = try? d.decode(DeltaBody.self, from: data) { self = .delta(x.text); return }
        case "done":
            if let x = try? d.decode(DoneBody.self, from: data) { self = .done(text: x.text, stop: x.stop ?? "end"); return }
        case "error":
            if let x = try? d.decode(ErrorEventBody.self, from: data) {
                self = .failed(code: x.code ?? "internal", message: x.message ?? "Something went wrong on the PC.",
                               text: x.text ?? "")
                return
            }
        default:
            break
        }
        self = .other(e.name)
    }

    private struct DeltaBody: Decodable { var text: String }
    private struct DoneBody: Decodable { var text: String; var stop: String? }
    private struct ErrorEventBody: Decodable { var code: String?; var message: String?; var text: String? }
}

/// Why the PC couldn't be reached at all. The phone's transport maps its network errors to these.
enum NoAnswer: Error, Equatable, Sendable {
    case noName      // the name lookup failed
    case timeout     // nothing answered in time
    case refused     // something answered and turned the connection down
    case dropped     // the connection broke off partway
    case offline     // this iPhone has no network
    case secure      // the secure connection (its certificate) failed
    case cancelled   // the app stopped the request itself
    case other(Int?) // anything else, with the platform's error code when there is one

    var message: String {
        switch self {
        case .noName:
            return "Can't find your PC's name. In the Tailscale app, turn on Use Tailscale DNS and turn off other VPN or DNS apps."
        case .timeout:
            return "Your PC didn't answer. Check that Tailscale is connected on both and the PC is awake."
        case .refused:
            return "Your PC turned the connection down. Is GupFit's PC service running (pc/install)?"
        case .dropped:
            return "The connection to your PC broke off. Try again."
        case .offline:
            return "This iPhone is offline."
        case .secure:
            return "The secure connection to your PC failed. Check the iPhone's date and time, then try again."
        case .cancelled:
            return "Stopped before your PC answered."
        case .other(let code):
            return "Can't reach your PC" + (code.map { " (error \($0))" } ?? "") + ". Is Tailscale on?"
        }
    }
}

/// A failed request to the PC.
enum PCError: Error, Equatable, Sendable {
    /// 401: the PC doesn't know this phone (anymore): pair again
    case notPaired
    case unreachable(NoAnswer)
    /// the PC answered with an error (`code` from pc/PROTOCOL.md, e.g. route_unavailable, busy, too_large)
    case refused(status: Int, code: String, message: String)
    /// an answer this version can't read
    case badAnswer

    var message: String {
        switch self {
        case .notPaired: return "Your PC doesn't know this phone anymore. Pair again."
        case .unreachable(let why): return why.message
        case .refused(_, _, let message): return message
        case .badAnswer: return "Your PC answered something this version of GupFit can't read. Update the app or the PC service."
        }
    }

    var isCancelled: Bool { self == .unreachable(.cancelled) }

    static func from(_ error: Error) -> PCError {
        if let e = error as? PCError { return e }
        if let e = error as? NoAnswer { return .unreachable(e) }
        if error is CancellationError { return .unreachable(.cancelled) }
        if error is DecodingError { return .badAnswer }
        return .unreachable(.other(nil))
    }

    /// an error answer's body: {"error": "...", "code": "..."}
    static func answer(status: Int, body: Data) -> PCError {
        if status == 401, (try? JSONDecoder().decode(ErrorBody.self, from: body))?.code != "bad_code" { return .notPaired }
        let e = try? JSONDecoder().decode(ErrorBody.self, from: body)
        return .refused(status: status, code: e?.code ?? "http_\(status)", message: e?.error ?? "Your PC answered \(status).")
    }

    private struct ErrorBody: Decodable { var error: String?; var code: String? }
}
