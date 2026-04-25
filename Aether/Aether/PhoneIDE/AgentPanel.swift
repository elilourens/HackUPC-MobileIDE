import SwiftUI
import Speech

/// Agent chat panel under the editor. Header + scrollable message list + input bar
/// with send + push-to-talk mic. Talks to BackendClient (with CodeGenerator fallback)
/// for build/modify, and applies the resulting HTML straight back into ProjectSession.
struct AgentPanel: View {
    @ObservedObject var session: ProjectSession
    @State private var draft: String = ""
    @State private var collapsed: Bool = false
    @State private var sttRecognizer = AgentSpeechRecognizer()
    @State private var sttActive: Bool = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                chatScroll
                if let plan = session.pendingPlan {
                    PlanHUDOverlay(
                        plan: plan,
                        onConfirm: confirmPlan,
                        onCancel: cancelPlan,
                        style: .compact
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .transition(.opacity)
                }
                inputBar
            }
        }
        .background(IJ.bgSidebar)
        .animation(.easeOut(duration: 0.18), value: session.pendingPlan != nil)
    }

    // MARK: Header — Junie tool window header (mode dropdown + kebab menu)

    @State private var junieMode: JunieMode = .code
    enum JunieMode: String, CaseIterable { case code = "Code", ask = "Ask", review = "Review" }

    private var header: some View {
        HStack(spacing: 8) {
            Image("JunieIcon")
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
            Text("Junie")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(IJ.textPrimary)

            // Mode dropdown — Code / Ask / Review
            Menu {
                ForEach(JunieMode.allCases, id: \.self) { mode in
                    Button(mode.rawValue) { junieMode = mode }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(junieMode.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(IJ.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(IJ.textSecondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(IJ.bgEditor))
            }

            Spacer()

            Text("gpt-4o")
                .font(.system(size: 10))
                .foregroundColor(IJ.textSecondary)

            // Kebab — clear chat / settings (stub for now)
            Menu {
                Button("Clear conversation") {
                    // No public reset on session yet — append a separator instead.
                    session.appendChat(.system, "— new conversation —")
                }
                Button("Cancel pending plan", role: .destructive) {
                    session.pendingPlan = nil
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(IJ.textSecondary)
                    .frame(width: 24, height: 24)
            }

            Button(action: { withAnimation(.easeOut(duration: 0.2)) { collapsed.toggle() } }) {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(IJ.textSecondary)
                    .frame(width: 24, height: 24)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(IJ.bgSidebar)
        .overlay(Rectangle().fill(IJ.border).frame(height: 1), alignment: .bottom)
    }

    // MARK: Chat list

    private var chatScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if session.chatMessages.isEmpty {
                        Text("Ask ArcReact to build something. Try: \"a landing page for a coffee subscription startup\".")
                            .font(.system(size: 12))
                            .foregroundColor(IJ.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                    }
                    ForEach(session.chatMessages) { msg in
                        ChatMessageRow(msg: msg)
                            .id(msg.id)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.vertical, 8)
            }
            .onChange(of: session.chatMessages.count) { _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .background(IJ.bgSidebar)
    }

    // MARK: Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(IJ.border).frame(height: 1)
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if draft.isEmpty {
                        Text("Ask ArcReact…")
                            .font(.system(size: 13))
                            .foregroundColor(IJ.textDisabled)
                            .padding(.leading, 12)
                    }
                    TextField("", text: $draft, axis: .vertical)
                        .focused($inputFocused)
                        .font(.system(size: 13))
                        .foregroundColor(IJ.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .lineLimit(1...4)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(IJ.border, lineWidth: 1)
                        .background(RoundedRectangle(cornerRadius: 8).fill(IJ.bgInput))
                )

                // Mic — push to talk
                Button {
                    // Tap toggles dictation rather than press-and-hold; iOS gesture
                    // recognition for hold inside SwiftUI button is fiddly enough
                    // that tap-on / tap-off is more reliable for a hackathon demo.
                    if sttActive {
                        sttRecognizer.stop { final in
                            sttActive = false
                            if !final.isEmpty { draft = (draft.isEmpty ? final : draft + " " + final) }
                        }
                    } else {
                        sttRecognizer.start { partial in
                            draft = partial
                        }
                        sttActive = true
                    }
                } label: {
                    Image(systemName: sttActive ? "mic.fill" : "mic")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(sttActive ? IJ.accentRed : IJ.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(IJ.bgInput))
                        .overlay(Circle().stroke(IJ.border, lineWidth: 1))
                }

                // Send
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canSend ? IJ.accentBlue : IJ.scrollbar))
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(IJ.bgSidebar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isGenerating
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard session.pendingPlan == nil else { return }
        draft = ""
        inputFocused = false
        if sttActive { sttRecognizer.stop { _ in }; sttActive = false }

        session.appendChat(.user, prompt)

        switch junieMode {
        case .code:   sendCodeMode(prompt: prompt)
        case .ask:    sendAskMode(prompt: prompt)
        case .review: sendReviewMode(prompt: prompt)
        }
    }

    /// Code mode = the existing plan→confirm→build pipeline.
    private func sendCodeMode(prompt: String) {
        let placeholderId = session.appendChat(.assistant, "planning…")
        session.isPlanning = true
        let isModification = session.hasUserCode
        session.pendingPlanIsModification = isModification

        BackendClient.shared.plan(prompt: prompt,
                                  currentCode: isModification ? session.currentCode : nil,
                                  session: session) { result in
            DispatchQueue.main.async {
                session.isPlanning = false
                switch result {
                case .success(let plan):
                    session.pendingPlan = plan
                    session.replaceMessage(id: placeholderId, with: plan.summary)
                case .failure(let err):
                    session.pendingPlanIsModification = false
                    session.replaceMessage(id: placeholderId,
                                           with: "Planning failed: \(err.localizedDescription)")
                }
            }
        }
    }

    /// Ask mode = quick Q&A, no code generation. Routes through GeminiClient.
    private func sendAskMode(prompt: String) {
        let placeholderId = session.appendChat(.assistant, "thinking…")
        GeminiClient.shared.ask(prompt) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let answer):
                    session.replaceMessage(id: placeholderId, with: answer)
                case .failure(let err):
                    session.replaceMessage(id: placeholderId,
                                           with: "Couldn't reach Junie: \(err.localizedDescription)")
                }
            }
        }
    }

    /// Review mode = critique current code. Uses GeminiClient with the file as
    /// context — returns plain markdown, never HTML, so we don't accidentally
    /// rewrite the editor.
    private func sendReviewMode(prompt: String) {
        let placeholderId = session.appendChat(.assistant, "reviewing \(session.currentFile)…")
        let code = session.currentCode
        guard !code.isEmpty else {
            session.replaceMessage(id: placeholderId,
                                   with: "Nothing to review yet — generate code first.")
            return
        }
        let clip = code.count > 6000 ? String(code.prefix(6000)) + "\n... [truncated]" : code
        let q = """
        Review the following \(session.currentFile) and the user's note. \
        Be concise — bullet the top 3 issues + one quick win. \
        Plain text. No code blocks unless absolutely necessary. \
        Never return raw HTML.

        User note: \(prompt)

        --- code ---
        \(clip)
        """
        GeminiClient.shared.ask(q) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let critique):
                    session.replaceMessage(id: placeholderId, with: critique)
                case .failure(let err):
                    session.replaceMessage(id: placeholderId,
                                           with: "Review failed: \(err.localizedDescription)")
                }
            }
        }
    }

    private func confirmPlan() {
        guard let plan = session.pendingPlan else { return }
        let isModification = session.pendingPlanIsModification
        session.pendingPlan = nil
        session.pendingPlanIsModification = false
        session.isGenerating = true
        let placeholderId = session.appendChat(.assistant, "building…")

        let onResult: (Result<String, Error>) -> Void = { result in
            DispatchQueue.main.async {
                session.isGenerating = false
                switch result {
                case .success(let html):
                    session.setCode(html,
                                    forFile: session.currentFile.isEmpty ? "index.html" : session.currentFile,
                                    pushHistory: isModification)
                    session.replaceMessage(id: placeholderId,
                        with: isModification
                            ? "Updated \(session.currentFile)."
                            : "Created \(session.currentFile). Tap Preview to see it.")
                case .failure(let err):
                    session.replaceMessage(id: placeholderId,
                                           with: "Build failed: \(err.localizedDescription)")
                }
            }
        }

        if isModification {
            BackendClient.shared.modify(prompt: plan.expandedPrompt,
                                        currentCode: session.currentCode,
                                        session: session, completion: onResult)
        } else {
            BackendClient.shared.generate(prompt: plan.expandedPrompt,
                                          session: session, completion: onResult)
        }
    }

    private func cancelPlan() {
        session.pendingPlan = nil
        session.pendingPlanIsModification = false
        session.appendChat(.assistant, "Cancelled.")
    }
}

private struct ChatMessageRow: View {
    let msg: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if msg.role == .user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 4) {
                Text(msg.text)
                    .font(.system(size: 13))
                    .foregroundColor(IJ.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(msg.role == .user ? IJ.bgSelected : IJ.bgEditor)
            )
            if msg.role == .assistant { Spacer(minLength: 32) }
        }
        .padding(.horizontal, 10)
    }
}

/// Tiny SFSpeechRecognizer wrapper so the agent mic button doesn't have to
/// reach into the AR-mode `VoiceManager` (which holds different state).
@MainActor
final class AgentSpeechRecognizer {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastTranscript: String = ""
    private var requestedAuth = false

    func start(onPartial: @escaping (String) -> Void) {
        ensureAuth { [weak self] ok in
            guard ok, let self = self else { return }
            self.startInternal(onPartial: onPartial)
        }
    }

    func stop(completion: @escaping (String) -> Void) {
        let final = lastTranscript
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        completion(final)
    }

    private func ensureAuth(_ done: @escaping (Bool) -> Void) {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { done(true); return }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    private func startInternal(onPartial: @escaping (String) -> Void) {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .measurement,
                                      options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        lastTranscript = ""

        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audio.prepare()
        try? audio.start()

        task = recognizer?.recognitionTask(with: req) { [weak self] result, _ in
            guard let self = self, let result = result else { return }
            let s = result.bestTranscription.formattedString
            self.lastTranscript = s
            DispatchQueue.main.async { onPartial(s) }
        }
    }
}
