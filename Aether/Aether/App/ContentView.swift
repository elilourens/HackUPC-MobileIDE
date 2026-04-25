import SwiftUI

enum AppPhase {
    case launch
    case placement
    case workspace
}

struct ContentView: View {
    @State private var phase: AppPhase = .launch
    @StateObject private var sessionManager = ARSessionManager()
    @StateObject private var voiceManager = VoiceManager()

    var body: some View {
        ZStack {
            // Keep a single ARWorkspaceView mounted for the entire AR lifecycle so the
            // session and panel anchor survive the placement -> workspace transition.
            if phase != .launch {
                ARWorkspaceView(sessionManager: sessionManager)
                    .ignoresSafeArea()
            }

            switch phase {
            case .launch:
                LaunchView {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        phase = .placement
                    }
                }
                .transition(.opacity)
            case .placement:
                PlacementView(sessionManager: sessionManager) {
                    if sessionManager.placeWorkspace() {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            phase = .workspace
                        }
                        voiceManager.startListening { transcript in
                            sessionManager.updateAIBubble(text: transcript, isUser: true)
                        } onIdle: {
                            // Intentionally no-op: JARVIS only speaks for explicit commands.
                        } onCommand: { command in
                            sessionManager.handleVoiceCommand(command)
                        }
                        // Wire the open-palm hand gesture as a second push-to-talk trigger
                        // (in addition to the on-screen mic button). Both flip the same
                        // VoiceManager state, so visual feedback works either way.
                        sessionManager.onPushToTalkChange = { active in
                            if active {
                                voiceManager.beginPushToTalk()
                            } else {
                                voiceManager.endPushToTalk()
                            }
                        }
                        // Pre-cache common JARVIS lines so the first command plays without a network wait.
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
                .transition(.opacity)
            case .workspace:
                WorkspaceHUD(sessionManager: sessionManager, voiceManager: voiceManager)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: phase)
    }
}

private struct LaunchView: View {
    let onBegin: () -> Void
    @State private var appear = false

    var body: some View {
        ZStack {
            Color(white: 0.97).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                Text("AETHER")
                    .font(.system(size: 56, weight: .medium, design: .default))
                    .tracking(8)
                    .foregroundColor(Color.black.opacity(0.88))
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 8)
                Text("your desk is your IDE")
                    .font(.system(size: 16, weight: .light))
                    .tracking(1.2)
                    .foregroundColor(Color(white: 0.55))
                    .padding(.top, 18)
                    .opacity(appear ? 1 : 0)
                Spacer()
                Button(action: onBegin) {
                    Text("Begin")
                        .font(.system(size: 16, weight: .regular))
                        .tracking(2)
                        .foregroundColor(Color.black.opacity(0.85))
                        .padding(.horizontal, 44)
                        .padding(.vertical, 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.black.opacity(0.45), lineWidth: 0.5)
                        )
                }
                .opacity(appear ? 1 : 0)
                .padding(.bottom, 96)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { appear = true }
        }
    }
}
