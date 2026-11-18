import Foundation
import Observation

/// The Chat tab's state for SwiftUI: a mirror of ChatController's (GupFitKit), which does the work. The history
/// lives in the app's private Application Support folder with iOS file protection; the pairing in the Keychain.
/// `-chatDemo` (UI tests, screenshots) pairs with a pretend PC in memory instead.
@MainActor
@Observable
final class ChatModel {
    private(set) var state: ChatState
    /// a gupfit://pair link the app was opened with (the camera app's QR scan), for the pairing screen
    var incomingLink: String?
    let demo: Bool
    @ObservationIgnored private let controller: ChatController

    /// The one the Chat tab and the app's link handler share (made when first used: never in the unit tests' host).
    static let shared = ChatModel()

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        demo = arguments.contains("-chatDemo")
        let c: ChatController
        if demo {
            c = ChatController(client: PCClient(transport: DemoPC()), pairings: MemoryPairingStore(),
                               history: MemoryChatHistoryStore(), deviceName: "Demo iPhone")
        } else {
            c = ChatController(client: PCClient(transport: URLSessionPCTransport()), pairings: Self.pairingStore(),
                               history: FileChatHistoryStore(folder: Self.folder, options: Self.writeOptions),
                               deviceName: "GupFit on iPhone")
        }
        controller = c
        state = c.state
        c.onChange = { [weak self] in
            guard let self else { return }
            self.state = self.controller.state
        }
    }

    private static func pairingStore() -> any PairingStore {
        #if canImport(Security)
        KeychainPairingStore()
        #else
        MemoryPairingStore()
        #endif
    }

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Chat", isDirectory: true)
    }

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        .atomic
        #endif
    }

    /// A gupfit://pair link the app was opened with: kept for the pairing screen. True when it was one.
    func take(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "gupfit" else { return false }
        incomingLink = url.absoluteString
        return true
    }

    func pair(_ text: String) async -> Bool { await controller.pair(text) }
    @discardableResult func propose(_ text: String) -> Bool { controller.propose(text) }
    func confirmPair() async -> Bool { await controller.confirmPair() }
    func cancelPair() { controller.cancelPair() }
    func unpair() async { await controller.unpair() }
    func refreshModels() async { await controller.refreshModels() }
    func choose(_ pick: ModelPick) { controller.choose(pick) }
    func newChat() { controller.newChat() }
    func open(_ id: String) { controller.open(id) }
    func delete(_ id: String) { controller.delete(id) }
    @discardableResult func send(_ text: String) -> Bool { controller.send(text) }
    func stop() async { await controller.stop() }
    func clearProblem() { controller.clearProblem() }
}
