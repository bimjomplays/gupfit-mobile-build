import Foundation

/// What the Chat tab shows.
struct ChatState: Equatable, Sendable {
    /// the paired PC (nil: show the pairing screen)
    var pc: PairedPC?
    /// the PC's picker; empty until it answered
    var models: [ModelChoice] = []
    /// why the picker couldn't be loaded
    var modelsProblem: String?
    var pick: ModelPick?
    /// every chat, newest first; empty chats only while open
    var conversations: [Conversation] = []
    var openID: String
    /// the turn id of the reply coming now
    var running: String?
    var stopping = false
    /// a problem to show once (pairing failed, nothing to send with)
    var problem: String?
    var pairingBusy = false
    /// a scanned, pasted or opened pairing link waiting for the user's OK (a link can come from anywhere)
    var pendingPair: PendingPair?

    var current: Conversation {
        conversations.first { $0.id == openID } ?? Conversation(id: openID, created: Date(timeIntervalSince1970: 0))
    }

    var pickedModel: ModelChoice? { models.first { $0.id == pick?.model } }

    /// the chats worth listing: the ones with messages
    var listed: [Conversation] { conversations.filter { !$0.messages.isEmpty } }
}

/// The paired PC as the UI shows it (no token).
struct PairedPC: Equatable, Sendable {
    var name: String
    /// the full address, `<pc>.<tailnet>.ts.net:port`
    var host: String
    var pairedAt: Date

    init(_ p: PCPairing) {
        name = p.pcName
        host = p.address
        pairedAt = p.pairedAt
    }
}

/// A pairing link the user still has to OK: the app shows the PC's full address first, since a link from a web page,
/// message or someone else's QR code could point at another person's machine.
struct PendingPair: Equatable, Sendable {
    var link: PairLink
    /// `<pc>.<tailnet>.ts.net:port`
    var address: String { link.address }
    /// this phone paired with a PC on another tailnet before: likely not your PC
    var otherTailnet: Bool
}

/// The Chat tab's logic: pairing, the model picker, sending a turn and streaming its reply into the open chat,
/// reconnecting after a dropped connection, stopping, and keeping the history on the phone. The app's ChatModel
/// mirrors `state` for SwiftUI; tests drive it with a fake transport on Linux.
@MainActor
final class ChatController {
    private(set) var state: ChatState {
        didSet { if state != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?

    let client: PCClient
    let pairings: any PairingStore
    let history: any ChatHistoryStore
    let deviceName: String
    var now: @Sendable () -> Date
    /// tries after a dropped connection before the reply counts as failed
    var reconnects = 3
    var reconnectDelay: Duration = .seconds(1)
    /// how often a streaming reply is saved (so a closed app keeps most of it)
    var saveEvery: TimeInterval = 2
    /// how long Stop waits for the PC before it gives up on the reply locally
    var stopGrace: Duration = .seconds(5)
    /// Runs the model's tool calls on the phone's data (nil: a plain chat, the PC attaches no tools).
    var tools: ToolRunner?
    /// called after a tool call or an Undo changed the phone's data (the app redraws its screens)
    var onDataChange: (() -> Void)?
    /// tries to hand a tool call's answer to the PC before giving up on it
    var resultTries = 4

    private var pairing: PCPairing?
    private var turnTask: Task<Void, Never>?
    private var lastSave = Date.distantPast

    init(client: PCClient, pairings: any PairingStore, history: any ChatHistoryStore, deviceName: String,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.pairings = pairings
        self.history = history
        self.deviceName = deviceName
        self.now = now
        let p = pairings.load()
        pairing = p
        let prefs = history.loadPrefs()
        var all = history.conversations()
        let open: String
        if let id = prefs.open, all.contains(where: { $0.id == id }) {
            open = id
        } else {
            let fresh = Conversation(created: now())
            all.insert(fresh, at: 0)
            open = fresh.id
        }
        state = ChatState(pc: p.map(PairedPC.init), pick: prefs.pick, conversations: all, openID: open)
    }

    var isPaired: Bool { pairing != nil }

    // MARK: - Pairing

    /// A scanned, pasted or opened link: checks it and asks for the user's OK (`state.pendingPair`) before anything is
    /// sent. False (with `state.problem`) when it isn't a usable pairing link.
    @discardableResult
    func propose(_ text: String) -> Bool {
        guard !state.pairingBusy else { return false }
        switch PairLink.parse(text) {
        case .failure(let p):
            state.problem = p.message
            return false
        case .success(let link):
            let last = history.loadPrefs().tailnet
            state.problem = nil
            state.pendingPair = PendingPair(link: link, otherTailnet: last != nil && last != link.tailnet)
            return true
        }
    }

    /// The user OK'd the pending link: pairs with that PC.
    @discardableResult
    func confirmPair() async -> Bool {
        guard let pending = state.pendingPair else { return false }
        return await confirmPair(pending)
    }

    /// The same for the link the question showed (SwiftUI clears the alert's binding before its button runs, so the
    /// app passes along what it presented).
    @discardableResult
    func confirmPair(_ pending: PendingPair) async -> Bool {
        state.pendingPair = nil
        return await pair(pending.link)
    }

    func cancelPair() { state.pendingPair = nil }

    /// Pairs with the PC in a link the user already OK'd (tests and confirmPair). True when it worked; else
    /// `state.problem` says why.
    @discardableResult
    func pair(_ text: String) async -> Bool {
        switch PairLink.parse(text) {
        case .failure(let p):
            state.problem = p.message
            return false
        case .success(let link):
            return await pair(link)
        }
    }

    private func pair(_ link: PairLink) async -> Bool {
        guard !state.pairingBusy else { return false }
        state.pairingBusy = true
        defer { state.pairingBusy = false }
        do {
            let p = try await client.pair(link, device: deviceName, now: now())
            guard pairings.save(p) else {
                state.problem = "The pairing couldn't be kept in the Keychain. Try again."
                return false
            }
            pairing = p
            state.pc = PairedPC(p)
            state.problem = nil
            savePrefs(tailnet: link.tailnet)
            await refreshModels()
            return true
        } catch {
            state.problem = PCError.from(error).message
            return false
        }
    }

    /// Ends this phone's token on the PC (when it can be reached) and forgets the pairing here either way.
    func unpair() async {
        if let p = pairing { try? await client.unpair(p) }
        forgetPairing()
    }

    private func forgetPairing() {
        pairings.clear()
        pairing = nil
        state.pc = nil
        state.models = []
        state.modelsProblem = nil
    }

    // MARK: - Models

    func refreshModels() async {
        guard let p = pairing else { return }
        do {
            let reply = try await client.models(p)
            state.models = reply.models
            state.modelsProblem = reply.models.isEmpty ? "Your PC has no Claude or GPT models in its picker." : nil
            state.pick = reply.pick(keeping: state.current.pick ?? state.pick)
        } catch {
            let e = PCError.from(error)
            if e == .notPaired { forgetPairing() }
            if !e.isCancelled { state.modelsProblem = e.message }
        }
    }

    /// The picker's choice: for this chat and as the default for new ones.
    func choose(_ pick: ModelPick) {
        state.pick = pick
        if let i = index(of: state.openID) { state.conversations[i].pick = pick }
        savePrefs()
    }

    // MARK: - Chats

    func newChat() {
        if state.current.messages.isEmpty { return }
        let fresh = Conversation(created: now(), pick: state.pick)
        state.conversations.insert(fresh, at: 0)
        open(fresh.id)
    }

    func open(_ id: String) {
        guard index(of: id) != nil else { return }
        state.conversations.removeAll { $0.messages.isEmpty && $0.id != id }
        state.openID = id
        if let p = state.current.pick, state.models.isEmpty || state.models.contains(where: { $0.id == p.model }) {
            state.pick = p
        }
        savePrefs()
    }

    func delete(_ id: String) {
        guard id != runningChat else { return }
        try? history.delete(id: id)
        state.conversations.removeAll { $0.id == id }
        if state.openID == id {
            let fresh = Conversation(created: now(), pick: state.pick)
            state.conversations.insert(fresh, at: 0)
            state.openID = fresh.id
        }
        savePrefs()
    }

    func clearProblem() { state.problem = nil }

    // MARK: - Turns

    private var runningChat: String?

    /// Sends `text` in the open chat and streams the reply. False (with `state.problem`) when it can't be sent.
    @discardableResult
    func send(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return false }
        guard state.running == nil else {
            state.problem = "Wait for the reply, or stop it."
            return false
        }
        guard let p = pairing else {
            state.problem = "Pair with your PC first."
            return false
        }
        guard let pick = state.pick else {
            state.problem = state.modelsProblem ?? "Pick a model first."
            return false
        }
        guard words.count <= TurnLimits.messageChars else {
            state.problem = "That message is too long (up to \(TurnLimits.messageChars) characters)."
            return false
        }
        guard let i = index(of: state.openID) else { return false }
        let t = now()
        let turn = UUID().uuidString.lowercased()
        state.conversations[i].messages.append(ChatMessage(role: .user, text: words, at: t))
        let request = TurnRequest(turn: turn, chat: state.openID, model: pick.model, effort: pick.effort,
                                  messages: state.conversations[i].messagesToSend(),
                                  tools: tools == nil ? nil : ToolSet.version, today: tools?.today().description)
        let reply = ChatMessage(role: .assistant, text: "", at: t, state: .streaming, model: pick.model, turn: turn)
        state.conversations[i].messages.append(reply)
        state.conversations[i].pick = pick
        state.conversations[i].updated = t
        moveToTop(i)
        state.running = turn
        state.problem = nil
        runningChat = state.openID
        save(state.openID)
        let chat = state.openID
        turnTask = Task { [weak self] in
            await self?.run(p, request, chat: chat, reply: reply.id)
        }
        return true
    }

    /// Asks the PC to stop the reply; if the PC doesn't answer soon, the reply stops here anyway.
    func stop() async {
        guard let turn = state.running, let p = pairing, !state.stopping else { return }
        state.stopping = true
        try? await client.cancel(p, turn: turn)
        try? await Task.sleep(for: stopGrace)
        if state.running == turn {
            turnTask?.cancel()
        }
    }

    /// Waits for the reply coming now (tests).
    func waitForReply() async {
        await turnTask?.value
    }

    private func run(_ p: PCPairing, _ request: TurnRequest, chat: String, reply: String) async {
        var lastID = 0
        var tries = 0
        while true {
            do {
                for try await (id, event) in client.turn(p, request, after: lastID) {
                    if let id { lastID = id }
                    if case .toolCall(let call) = event {
                        await runTool(call, p, turn: request.turn, chat: chat, reply: reply)
                        continue
                    }
                    apply(event, chat: chat, reply: reply)
                    if event.isLast { return finish(chat) }
                }
                return finish(chat)
            } catch {
                let e = PCError.from(error)
                if Task.isCancelled || e.isCancelled {
                    update(chat, reply) { m in m.state = .cancelled }
                    return finish(chat)
                }
                // a dropped or unanswered connection: the same turn id again continues it (the PC never runs it twice)
                if case .unreachable = e, tries < reconnects {
                    tries += 1
                    try? await Task.sleep(for: reconnectDelay * tries)
                    if !Task.isCancelled { continue }
                }
                if e == .notPaired { forgetPairing() }
                update(chat, reply) { m in m.state = .failed(e.message) }
                return finish(chat)
            }
        }
    }

    /// Runs one tool call on the phone (a replayed call is answered from its receipt and changes nothing), shows a
    /// card per change, and hands the answer to the PC, trying again when the connection drops.
    private func runTool(_ call: ToolCall, _ p: PCPairing, turn: String, chat: String, reply: String) async {
        let outcome: ToolOutcome
        if let tools {
            outcome = tools.run(call, turn: turn)
        } else {
            outcome = .failed("This phone isn't running tools in this chat.")
        }
        if !outcome.replayed, !outcome.changes.isEmpty { onDataChange?() }
        var cards = outcome.changes.enumerated().map { i, c in
            ChangeCard(turn: turn, call: call.call, index: i, kind: c.kind, title: c.title, detail: c.detail,
                       state: c.undone ? .undone : .done)
        }
        if !outcome.ok, ToolName(rawValue: call.name)?.writes ?? true {
            cards = [ChangeCard(turn: turn, call: call.call, index: 0, kind: nil, title: "Not saved",
                                detail: outcome.error ?? "It didn't work.", state: .failed)]
        }
        update(chat, reply) { m in
            var all = m.cards
            for c in cards where !all.contains(where: { $0.id == c.id }) { all.append(c) }
            m.changes = all.isEmpty ? nil : all
        }
        if !cards.isEmpty { save(chat) }

        let body = ToolResultBody(call: call.call, outcome: outcome)
        for attempt in 1...max(1, resultTries) {
            do {
                if try await client.toolResult(p, turn: turn, body) == .expired, !cards.isEmpty, outcome.ok {
                    note(chat, reply, call: call.call, "Saved on the phone, but the reply didn't hear about it.")
                }
                return
            } catch {
                let e = PCError.from(error)
                guard case .unreachable = e, !e.isCancelled, attempt < resultTries, !Task.isCancelled else {
                    if outcome.ok, !cards.isEmpty {
                        note(chat, reply, call: call.call, "Saved on the phone, but the reply may not have heard about it.")
                    }
                    return
                }
                try? await Task.sleep(for: reconnectDelay * attempt)
            }
        }
    }

    private func note(_ chat: String, _ reply: String, call: String, _ text: String) {
        update(chat, reply) { m in
            m.changes = m.changes?.map { c in var c = c; if c.call == call { c.note = text }; return c }
        }
        save(chat)
    }

    /// Undoes one change card's change, when the record is still as that change left it.
    func undo(_ card: ChangeCard, in chat: String? = nil) {
        guard let tools, card.canUndo else { return }
        let chat = chat ?? state.openID
        let result = tools.undo(turn: card.turn, call: card.call, index: card.index)
        guard let i = index(of: chat) else { return }
        for j in state.conversations[i].messages.indices {
            guard var changes = state.conversations[i].messages[j].changes,
                  let k = changes.firstIndex(where: { $0.id == card.id }) else { continue }
            switch result {
            case .undone, .already:
                changes[k].state = .undone
                changes[k].note = nil
            case .changedSince(let m), .failed(let m):
                changes[k].note = m
            }
            state.conversations[i].messages[j].changes = changes
        }
        if result == .undone { onDataChange?() }
        save(chat)
    }

    private func apply(_ event: TurnEvent, chat: String, reply: String) {
        switch event {
        case .started, .other, .toolCall:
            break
        case .delta(let text):
            update(chat, reply) { m in m.text += text }
            if now().timeIntervalSince(lastSave) >= saveEvery { save(chat) }
        case .done(let text, let stop):
            update(chat, reply) { m in
                if !text.isEmpty || stop == "end" { m.text = text }
                m.state = stop == "cancelled" ? .cancelled : .complete
            }
        case .failed(_, let message, let text):
            update(chat, reply) { m in
                if !text.isEmpty { m.text = text }
                m.state = .failed(message)
            }
        }
    }

    private func finish(_ chat: String) {
        update(chat, nil) { _ in }
        state.running = nil
        state.stopping = false
        runningChat = nil
        save(chat)
    }

    // MARK: - Helpers

    private func index(of id: String) -> Int? { state.conversations.firstIndex { $0.id == id } }

    private func moveToTop(_ i: Int) {
        guard i != 0 else { return }
        let c = state.conversations.remove(at: i)
        state.conversations.insert(c, at: 0)
    }

    /// changes one message (`reply`) of chat `chat`; nil changes none but still marks the chat updated
    private func update(_ chat: String, _ reply: String?, _ change: (inout ChatMessage) -> Void) {
        guard let i = index(of: chat) else { return }
        if let reply, let j = state.conversations[i].messages.firstIndex(where: { $0.id == reply }) {
            change(&state.conversations[i].messages[j])
        }
        state.conversations[i].updated = max(state.conversations[i].updated, now())
    }

    private func save(_ chat: String) {
        guard let i = index(of: chat), !state.conversations[i].messages.isEmpty else { return }
        lastSave = now()
        do {
            try history.save(state.conversations[i])
        } catch {
            state.problem = "This chat couldn't be saved on the phone."
        }
        savePrefs()
    }

    private func savePrefs(tailnet: String? = nil) {
        let keep = tailnet ?? history.loadPrefs().tailnet
        try? history.savePrefs(ChatPrefs(pick: state.pick, open: state.openID, tailnet: keep))
    }
}
