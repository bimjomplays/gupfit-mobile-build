import Foundation

/// One message of a chat, as the phone keeps it.
struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }

    /// where an assistant reply stands
    enum State: Codable, Equatable, Sendable {
        case complete
        case streaming
        case cancelled
        /// the PC or the model failed; the text is what came before
        case failed(String)
    }

    var id: String
    var role: Role
    var text: String
    var at: Date
    var state: State = .complete
    /// assistant replies: the model that wrote it and its turn id
    var model: String?
    var turn: String?
    /// assistant replies: what the reply's tool calls changed on the phone, one card each (nil in older chats)
    var changes: [ChangeCard]?

    init(id: String = UUID().uuidString.lowercased(), role: Role, text: String, at: Date, state: State = .complete,
         model: String? = nil, turn: String? = nil, changes: [ChangeCard]? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
        self.state = state
        self.model = model
        self.turn = turn
        self.changes = changes
    }

    var cards: [ChangeCard] { changes ?? [] }
}

/// One change a reply made on the phone, as the chat shows it (a small card with Undo). The record itself stays in
/// the phone's database (the call's receipt); the card only points at it by (turn, call, index).
struct ChangeCard: Codable, Equatable, Identifiable, Sendable {
    enum State: Codable, Equatable, Sendable {
        case done
        case undone
        /// the call failed: nothing was changed (`detail` says why)
        case failed
    }

    var turn: String
    var call: String
    /// which change of the call
    var index: Int
    /// nil for a failed call
    var kind: ToolChange.Kind?
    var title: String
    var detail: String
    var state: State = .done
    /// something to know about it ("the reply didn't hear about it", "Undo left it alone")
    var note: String?

    var id: String { "\(turn)/\(call)/\(index)" }

    var canUndo: Bool { state == .done && kind != nil }
}

/// One chat: its messages, oldest first, and the model it last used.
struct Conversation: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var created: Date
    var updated: Date
    var messages: [ChatMessage]
    var pick: ModelPick?

    init(id: String = UUID().uuidString.lowercased(), created: Date, messages: [ChatMessage] = [], pick: ModelPick? = nil) {
        self.id = id
        self.created = created
        self.updated = created
        self.messages = messages
        self.pick = pick
    }

    /// The first words of the first message, for the list.
    var title: String {
        guard let first = messages.first(where: { $0.role == .user }) else { return "New chat" }
        let line = first.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? first.text
        let words = line.trimmingCharacters(in: .whitespaces)
        return words.count > 48 ? String(words.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" : words
    }

    /// What the next turn sends: the user's messages and the replies that have text (failed ones too, as far as they
    /// got), newest kept, oldest dropped to fit the PC's limits. Long messages are cut to the per-message limit.
    func messagesToSend(maxMessages: Int = TurnLimits.messages, maxChars: Int = TurnLimits.totalChars,
                        messageChars: Int = TurnLimits.messageChars) -> [WireMessage] {
        var out: [WireMessage] = []
        var total = 0
        for m in messages.reversed() {
            var text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // the model should know what the person took back in the app since
            let undone = m.cards.filter { $0.state == .undone }
            if !undone.isEmpty, !text.isEmpty {
                text += "\n\n[In the app, the user then undid: " + undone.map { "\($0.title): \($0.detail)" }
                    .joined(separator: "; ") + "]"
            }
            if text.isEmpty { continue }
            let cut = text.count > messageChars ? String(text.prefix(messageChars)) : text
            if out.count >= maxMessages || total + cut.count > maxChars { break }
            total += cut.count
            out.append(WireMessage(role: m.role.rawValue, text: cut))
        }
        out.reverse()
        while let first = out.first, first.role != "user" { out.removeFirst() }  // start with the user's words
        return out
    }

    /// On load: a reply that was still streaming when the app stopped is kept as far as it got.
    mutating func settleInterrupted() {
        for i in messages.indices where messages[i].state == .streaming {
            messages[i].state = .failed("The app closed before the reply finished.")
        }
    }
}

/// The phone's chat history, on the phone only. The app keeps it in its private Application Support folder with iOS
/// file protection; tests use a temporary folder.
protocol ChatHistoryStore: AnyObject, Sendable {
    /// every chat, newest first
    func conversations() -> [Conversation]
    func save(_ conversation: Conversation) throws
    func delete(id: String) throws
    func loadPrefs() -> ChatPrefs
    func savePrefs(_ prefs: ChatPrefs) throws
}

/// The chat tab's remembered choices.
struct ChatPrefs: Codable, Equatable, Sendable {
    var pick: ModelPick?
    var open: String?
    /// the tailnet (`<tailnet>.ts.net`) of the last PC this phone paired with; a link from another one gets a warning
    var tailnet: String?
}

/// One JSON file per chat under `folder` (chats/<id>.json) and chat-prefs.json; written atomically.
final class FileChatHistoryStore: ChatHistoryStore, @unchecked Sendable {
    let folder: URL
    private let options: Data.WritingOptions
    private let lock = NSLock()

    /// `options`: the app adds iOS file protection to `.atomic`
    init(folder: URL, options: Data.WritingOptions = .atomic) {
        self.folder = folder
        self.options = options
    }

    private var chats: URL { folder.appendingPathComponent("chats", isDirectory: true) }
    private var prefsFile: URL { folder.appendingPathComponent("chat-prefs.json") }

    private static func safe(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    func conversations() -> [Conversation] {
        lock.withLock {
            let files = (try? FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)) ?? []
            let d = Self.decoder
            return files.filter { $0.pathExtension == "json" }
                .compactMap { try? d.decode(Conversation.self, from: Data(contentsOf: $0)) }
                .map { var c = $0; c.settleInterrupted(); return c }
                .sorted { $0.updated > $1.updated }
        }
    }

    func save(_ conversation: Conversation) throws {
        guard Self.safe(conversation.id) else { throw RepositoryError.notFound(conversation.id) }
        try lock.withLock {
            try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
            try Self.encoder.encode(conversation).write(to: chats.appendingPathComponent(conversation.id + ".json"),
                                                        options: options)
        }
    }

    func delete(id: String) throws {
        guard Self.safe(id) else { throw RepositoryError.notFound(id) }
        try lock.withLock {
            let f = chats.appendingPathComponent(id + ".json")
            guard FileManager.default.fileExists(atPath: f.path) else { throw RepositoryError.notFound(id) }
            try FileManager.default.removeItem(at: f)
        }
    }

    func loadPrefs() -> ChatPrefs {
        lock.withLock { (try? Self.decoder.decode(ChatPrefs.self, from: Data(contentsOf: prefsFile))) ?? ChatPrefs() }
    }

    func savePrefs(_ prefs: ChatPrefs) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.encoder.encode(prefs).write(to: prefsFile, options: options)
        }
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}

/// In memory, for tests and previews.
final class MemoryChatHistoryStore: ChatHistoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String: Conversation] = [:]
    private var prefs = ChatPrefs()
    private(set) var saves = 0

    func conversations() -> [Conversation] { lock.withLock { kept.values.sorted { $0.updated > $1.updated } } }
    func save(_ c: Conversation) throws { lock.withLock { kept[c.id] = c; saves += 1 } }
    func delete(id: String) throws {
        try lock.withLock {
            guard kept.removeValue(forKey: id) != nil else { throw RepositoryError.notFound(id) }
        }
    }
    func loadPrefs() -> ChatPrefs { lock.withLock { prefs } }
    func savePrefs(_ p: ChatPrefs) throws { lock.withLock { prefs = p } }
}
