import SwiftUI

/// The Chat tab: pairing with the PC first, then the chat with Claude or GPT through it.
struct ChatTab: View {
    @State private var chat = ChatModel.shared

    var body: some View {
        Group {
            if chat.state.pc == nil {
                PairPCView()
            } else {
                ChatScreen()
            }
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .environment(chat)
    }
}

extension View {
    /// gupfit://pair links (the iPhone camera app's QR scan) open the Chat tab's pairing screen with the link.
    func chatLinks(_ tab: Binding<AppTab>) -> some View {
        onOpenURL { url in
            if ChatModel.shared.take(url) { tab.wrappedValue = .chat }
        }
    }
}

// MARK: - Pairing

/// On the PC, `gupfit-pc pair` shows a QR code: scan it here (or with the iPhone camera, which opens the app through
/// its gupfit:// link), or paste the link it prints.
struct PairPCView: View {
    @Environment(ChatModel.self) private var chat
    @State private var camera: QRScanner.StartResult?
    @State private var pasted = ""
    @State private var lastTried = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pair with your PC")
                        .font(.title.bold())
                    Text("The chat runs on Claude or GPT through your PC. On the PC, run gupfit-pc pair and scan the code it shows. Your phone and PC both need Tailscale on.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                cameraBox

                VStack(alignment: .leading, spacing: 10) {
                    Text("Or paste the pairing link")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        TextField("gupfit://pair?…", text: $pasted)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .onSubmit { tryCode(pasted) }
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("pairCode")
                        PasteButton(payloadType: String.self) { strings in
                            guard let text = strings.first else { return }
                            Task { @MainActor in
                                pasted = text
                                tryCode(text)
                            }
                        }
                        .labelStyle(.iconOnly)
                    }
                    Button {
                        tryCode(pasted)
                    } label: {
                        Text("Pair").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty || chat.state.pairingBusy)
                    .accessibilityIdentifier("pairButton")
                }

                if chat.state.pairingBusy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Pairing…").foregroundStyle(.secondary)
                    }
                }
                if let problem = chat.state.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("pairProblem")
                }
                Text("Only your messages go to Claude or GPT, through your PC. Your logs, workouts and recipes stay on this phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { takeIncoming() }
        .onChange(of: chat.incomingLink) { _, _ in takeIncoming() }
        .alert("Pair with this PC?", isPresented: confirming, presenting: chat.state.pendingPair) { _ in
            Button("Pair") { Task { _ = await chat.confirmPair() } }
                .accessibilityIdentifier("pairConfirm")
            Button("Cancel", role: .cancel) { chat.cancelPair() }
        } message: { pending in
            Text(confirmText(pending))
        }
    }

    /// The full address, since a link can come from anywhere (a web page, a message, someone else's QR code).
    private func confirmText(_ pending: PendingPair) -> String {
        var text = "Your chats will go to \(pending.address). Pair only if that is your own PC."
        if pending.otherTailnet {
            text += "\n\nWarning: this PC is on a different Tailscale network than the PC you paired with before."
        }
        return text
    }

    private var confirming: Binding<Bool> {
        Binding(get: { chat.state.pendingPair != nil }, set: { if !$0 { chat.cancelPair() } })
    }

    @ViewBuilder
    private var cameraBox: some View {
        ZStack {
            if !chat.demo {
                QRCameraView(onCode: { text in
                    // the camera repeats a code while it stays in view: try each text once
                    if text != lastTried { tryCode(text) }
                }, onState: { camera = $0 })
            }
            switch camera {
            case .denied:
                cameraNote("The camera is off for GupFit. Allow it in Settings, or paste the link below.",
                           icon: "video.slash")
            case .noCamera:
                cameraNote("No camera here. Paste the link below.", icon: "camera")
            case .none:
                if chat.demo { cameraNote("No camera here. Paste the link below.", icon: "camera") } else { ProgressView() }
            case .running:
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.white.opacity(0.8), lineWidth: 2)
                    .frame(width: 200, height: 200)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    private func cameraNote(_ text: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle)
            Text(text).font(.subheadline).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(24)
    }

    private func takeIncoming() {
        guard let link = chat.incomingLink else { return }
        chat.incomingLink = nil
        pasted = link
        tryCode(link)
    }

    /// Checks the link and asks before pairing (the alert above).
    private func tryCode(_ text: String) {
        guard !chat.state.pairingBusy, chat.state.pendingPair == nil else { return }
        lastTried = text
        chat.propose(text)
    }
}

// MARK: - Chat

struct ChatScreen: View {
    @Environment(ChatModel.self) private var chat
    @Environment(\.scenePhase) private var phase
    @State private var draft = ""
    @State private var showChats = false
    @State private var confirmUnpair = false
    @FocusState private var typing: Bool

    var body: some View {
        let state = chat.state
        VStack(spacing: 0) {
            if let problem = state.modelsProblem ?? state.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.08))
                    .onTapGesture { chat.clearProblem() }
                    .accessibilityIdentifier("chatProblem")
            }
            messages(state.current)
            composer(state)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showChats = true } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("Chats")
                    .accessibilityIdentifier("chatsButton")
            }
            ToolbarItem(placement: .principal) { ModelMenu() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { chat.newChat() } label: { Label("New chat", systemImage: "square.and.pencil") }
                        .disabled(state.current.messages.isEmpty)
                    if let pc = state.pc {
                        Section("Paired with \(pc.name) (\(pc.host))") {
                            Button(role: .destructive) { confirmUnpair = true } label: {
                                Label("Unpair this phone", systemImage: "link.badge.minus")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("chatMenu")
            }
        }
        .sheet(isPresented: $showChats) { ChatsSheet() }
        .confirmationDialog("Unpair this phone?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { Task { await chat.unpair() } }
        } message: {
            Text("The PC forgets this phone's key. Your chats stay on the phone. To chat again, pair again.")
        }
        .task { await chat.refreshModels() }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await chat.refreshModels() } }
        }
    }

    private func messages(_ c: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if c.messages.isEmpty {
                        EmptyChat()
                    }
                    ForEach(c.messages) { m in
                        MessageBubble(message: m, modelLabel: label(of: m.model)).id(m.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: c.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: c.id) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func composer(_ state: ChatState) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($typing)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("chatInput")
            if state.running != nil {
                Button {
                    Task { await chat.stop() }
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title)
                }
                .disabled(state.stopping)
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("chatStop")
            } else {
                Button {
                    if chat.send(draft) { draft = "" }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.pick == nil)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("chatSend")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func label(of model: String?) -> String? {
        guard let model else { return nil }
        return chat.state.models.first { $0.id == model }?.label ?? model
    }
}

struct EmptyChat: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about food, macros or training.")
                .font(.headline)
            Text("For example: How much protein is in 150 g of Greek yogurt? Logging food and workouts from chat is coming next.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let modelLabel: String?

    var body: some View {
        let mine = message.role == .user
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                if message.text.isEmpty && message.state == .streaming {
                    ProgressView().accessibilityIdentifier("replyWaiting")
                } else if !message.text.isEmpty {
                    Text(Self.markdown(message.text))
                        .textSelection(.enabled)
                        .accessibilityIdentifier(mine ? "userMessage" : "replyText")
                }
                footer
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(mine ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18))
            if !mine { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch message.state {
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("replyError")
        case .cancelled:
            Text("Stopped").font(.caption).foregroundStyle(.secondary)
        case .streaming, .complete:
            if message.role == .assistant, let modelLabel {
                Text(modelLabel).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// The model picker: the PC's Claude and GPT models with their efforts. An unavailable route shows why and can't
/// be picked; nothing ever switches models on its own.
struct ModelMenu: View {
    @Environment(ChatModel.self) private var chat

    var body: some View {
        let state = chat.state
        Menu {
            ForEach(["claude", "openai"], id: \.self) { provider in
                let models = state.models.filter { $0.provider == provider }
                if !models.isEmpty {
                    Section(provider == "claude" ? "Claude" : "GPT") {
                        ForEach(models) { m in
                            if m.available {
                                Menu {
                                    ForEach(m.efforts, id: \.self) { effort in
                                        Button {
                                            chat.choose(ModelPick(model: m.id, effort: effort))
                                        } label: {
                                            if state.pick == ModelPick(model: m.id, effort: effort) {
                                                Label(effort.capitalized, systemImage: "checkmark")
                                            } else {
                                                Text(effort.capitalized)
                                            }
                                        }
                                    }
                                } label: {
                                    if state.pick?.model == m.id {
                                        Label(m.label, systemImage: "checkmark")
                                    } else {
                                        Text(m.label)
                                    }
                                }
                            } else {
                                Button {} label: {
                                    Text(m.label)
                                    Text(m.reason ?? "Unavailable on the PC")
                                }
                                .disabled(true)
                            }
                        }
                    }
                }
            }
            if state.models.isEmpty {
                Text(state.modelsProblem ?? "Loading the PC's models…")
            }
        } label: {
            HStack(spacing: 4) {
                Text(title(state)).font(.headline)
                Image(systemName: "chevron.down").font(.caption.bold())
            }
            .foregroundStyle(.primary)
        }
        .accessibilityIdentifier("modelMenu")
    }

    private func title(_ state: ChatState) -> String {
        guard let pick = state.pick else { return "Chat" }
        let label = state.pickedModel?.label ?? pick.model
        return pick.effort.isEmpty ? label : "\(label) · \(pick.effort)"
    }
}

/// Every chat on this phone, newest first.
struct ChatsSheet: View {
    @Environment(ChatModel.self) private var chat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    chat.newChat()
                    dismiss()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                ForEach(chat.state.listed) { c in
                    Button {
                        chat.open(c.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).foregroundStyle(.primary).lineLimit(1)
                            Text(c.updated, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if c.id != chat.state.openID || chat.state.running == nil {
                            Button(role: .destructive) { chat.delete(c.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
