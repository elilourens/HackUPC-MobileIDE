import SwiftUI

enum AppPhase {
    case phoneIDE
    case placement
    case workspace
}

struct ContentView: View {
    @ObservedObject var session: ProjectSession
    @State private var phase: AppPhase = .phoneIDE
    @StateObject private var sessionManager: ARSessionManager
    @StateObject private var voiceManager = VoiceManager()
    @State private var arPlacedOnce = false

    init(session: ProjectSession) {
        self.session = session
        // Wrap the AR session manager in a StateObject so it survives mode switches
        // for the whole lifetime of the app.
        _sessionManager = StateObject(wrappedValue: ARSessionManager(session: session))
    }

    var body: some View {
        ZStack {
            // AR is mounted whenever we've ever entered AR — keeps the AR session,
            // anchor, and panel state alive across mode switches.
            if arPlacedOnce || phase != .phoneIDE {
                ARWorkspaceView(sessionManager: sessionManager)
                    .ignoresSafeArea()
                    .opacity(phase == .phoneIDE ? 0 : 1)
                    .allowsHitTesting(phase != .phoneIDE)
            }

            switch phase {
            case .phoneIDE:
                PhoneIDEView(session: session, onEnterAR: enterAR)
                    .transition(.opacity)
            case .placement:
                PlacementView(sessionManager: sessionManager) {
                    if sessionManager.placeWorkspace() {
                        arPlacedOnce = true
                        withAnimation(.easeInOut(duration: 0.5)) {
                            phase = .workspace
                        }
                        startVoicePipeline()
                    }
                }
                .transition(.opacity)
            case .workspace:
                WorkspaceHUD(sessionManager: sessionManager,
                             voiceManager: voiceManager,
                             onRequestPhoneMode: { exitAR() })
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: phase)
        .onAppear {
            sessionManager.onRequestPhoneMode = { exitAR() }
        }
    }

    private func enterAR() {
        // First time: go through placement. After that, jump straight back to workspace.
        if arPlacedOnce {
            withAnimation(.easeInOut(duration: 0.35)) { phase = .workspace }
        } else {
            withAnimation(.easeInOut(duration: 0.35)) { phase = .placement }
        }
    }

    private func exitAR() {
        withAnimation(.easeInOut(duration: 0.35)) { phase = .phoneIDE }
    }

    private func startVoicePipeline() {
        voiceManager.startListening { transcript in
            sessionManager.updateAIBubble(text: transcript, isUser: true)
        } onIdle: {
            // Intentionally no-op: JARVIS only speaks for explicit commands.
        } onCommand: { command in
            sessionManager.handleVoiceCommand(command)
        }
        sessionManager.onPushToTalkChange = { active in
            if active { voiceManager.beginPushToTalk() }
            else      { voiceManager.endPushToTalk() }
        }
        JarvisVoice.shared.preload([
            "Done.", "On it.", "Workspace cleared.",
            "Pulling up the preview now.", "Here are the docs.",
            "Terminal is up.", "Here's your commit history.",
            "I found 2 issues.", "Running diagnostics.",
            "Mapping the architecture.", "Pulling dependencies.",
            "Focus mode.", "Back to normal.",
            "Switching to dark mode.", "Going light.",
            "Bringing up Terry. The legend."
        ])
    }
}
