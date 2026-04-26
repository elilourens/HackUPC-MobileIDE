import SwiftUI

enum AppPhase {
    case welcome
    case phoneIDE
    case placement
    case workspace
}

struct ContentView: View {
    @ObservedObject var session: ProjectSession
    @State private var phase: AppPhase = (UserDefaults.standard.bool(forKey: "aether.welcome.seen") ? .phoneIDE : .welcome)
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
            let arVisible: Bool = phase == .placement || phase == .workspace
            let hideARFor2DDesk = phase == .workspace && sessionManager.deskModeEnabled && sessionManager.workspaceStarted
            if arPlacedOnce || arVisible {
                ARWorkspaceView(sessionManager: sessionManager)
                    .ignoresSafeArea()
                    .opacity(arVisible && !hideARFor2DDesk ? 1 : 0)
                    .allowsHitTesting(arVisible && !hideARFor2DDesk)
            }

            if phase == .workspace, sessionManager.deskModeEnabled, sessionManager.workspaceStarted {
                Desk2DWorkspaceView(sessionManager: sessionManager, projectSession: session)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            switch phase {
            case .welcome:
                WelcomeScreen(session: session, onOpen: dismissWelcome)
                    .transition(.opacity)
                    .ignoresSafeArea()
            case .phoneIDE:
                PhoneIDEView(session: session, onEnterAR: enterAR)
                    .ignoresSafeArea()
                    .transition(.opacity)
            case .placement:
                PlacementView(
                    sessionManager: sessionManager,
                    onPlace: {
                        if sessionManager.placeWorkspace() {
                            arPlacedOnce = true
                            withAnimation(.easeInOut(duration: 0.5)) {
                                phase = .workspace
                            }
                            startVoicePipeline()
                        }
                    },
                    onUseFlatWorkspace: {
                        if sessionManager.placeWorkspaceFlatAtOrigin() {
                            arPlacedOnce = true
                            withAnimation(.easeInOut(duration: 0.5)) {
                                phase = .workspace
                            }
                            startVoicePipeline()
                        }
                    }
                )
                .transition(.opacity)
            case .workspace:
                WorkspaceHUD(sessionManager: sessionManager,
                             voiceManager: voiceManager,
                             onRequestPhoneMode: { exitAR() })
                    .transition(.opacity)
            }
        }
        .overlay(
            // Any shake toggles between phone IDE and AR. Decorative — sits on top
            // but never absorbs touches.
            ShakeDetectorView { toggleMode() }
                .allowsHitTesting(false)
        )
        .animation(.easeInOut(duration: 0.35), value: phase)
        .onAppear {
            sessionManager.onRequestPhoneMode = { exitAR() }
            sessionManager.onRequestPlacement = {
                withAnimation(.easeInOut(duration: 0.35)) { phase = .placement }
            }
        }
    }

    private func toggleMode() {
        switch phase {
        case .phoneIDE:
            enterAR()
        case .placement, .workspace:
            exitAR()
        case .welcome:
            break
        }
    }

    private func dismissWelcome() {
        UserDefaults.standard.set(true, forKey: "aether.welcome.seen")
        withAnimation(.easeInOut(duration: 0.3)) { phase = .phoneIDE }
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
        sessionManager.setDeskModeEnabled(false)
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
