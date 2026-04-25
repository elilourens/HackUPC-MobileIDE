import SwiftUI

/// Backend URL + JARVIS toggle. Theme is dark-only for now.
struct SettingsSheet: View {
    @ObservedObject var session: ProjectSession
    @Binding var isShown: Bool

    @State private var backendDraft: String = ""
    @State private var saved = false

    var body: some View {
        NavigationView {
            ZStack {
                IJ.bgMain.ignoresSafeArea()
                Form {
                    Section(header: Text("BACKEND").foregroundColor(IJ.textSecondary)) {
                        TextField("http://192.168.1.X:8000", text: $backendDraft)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .foregroundColor(IJ.textPrimary)
                            .listRowBackground(IJ.bgEditor)
                        Text("Falls back to OpenAI gpt-4o on-device if the backend is unreachable.")
                            .font(.system(size: 11))
                            .foregroundColor(IJ.textSecondary)
                            .listRowBackground(IJ.bgMain)
                    }

                    Section(header: Text("VOICE").foregroundColor(IJ.textSecondary)) {
                        Toggle(isOn: $session.jarvisVoiceEnabled) {
                            Text("JARVIS voice (AR mode)").foregroundColor(IJ.textPrimary)
                        }
                        .tint(IJ.accentBlue)
                        .listRowBackground(IJ.bgEditor)
                    }

                    Section(header: Text("THEME").foregroundColor(IJ.textSecondary)) {
                        HStack {
                            Text("Dark (IntelliJ Islands)")
                                .foregroundColor(IJ.textPrimary)
                            Spacer()
                            Image(systemName: "checkmark")
                                .foregroundColor(IJ.accentBlue)
                        }
                        .listRowBackground(IJ.bgEditor)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(IJ.bgMain)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isShown = false }
                        .foregroundColor(IJ.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saved ? "Saved" : "Save") {
                        session.backendURL = backendDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { isShown = false }
                    }
                    .foregroundColor(IJ.accentBlue)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { backendDraft = session.backendURL }
    }
}

/// Quick GitHub connect sheet — token + repo. Stores in ProjectSession (UserDefaults).
struct GitHubConnectSheet: View {
    @ObservedObject var session: ProjectSession
    @Binding var isShown: Bool
    let onConnect: () -> Void

    @State private var tokenDraft: String = ""
    @State private var repoDraft: String = ""
    @State private var status: String = ""

    var body: some View {
        NavigationView {
            ZStack {
                IJ.bgMain.ignoresSafeArea()
                Form {
                    Section(header: Text("PERSONAL ACCESS TOKEN").foregroundColor(IJ.textSecondary)) {
                        SecureField("ghp_…", text: $tokenDraft)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .foregroundColor(IJ.textPrimary)
                            .listRowBackground(IJ.bgEditor)
                    }
                    Section(header: Text("REPO (owner/name)").foregroundColor(IJ.textSecondary),
                            footer: Text(status).foregroundColor(IJ.accentRed)) {
                        TextField("octocat/hello-world", text: $repoDraft)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .foregroundColor(IJ.textPrimary)
                            .listRowBackground(IJ.bgEditor)
                    }
                    Section {
                        Button("Connect") {
                            let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            let repo  = repoDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            if token.isEmpty || !repo.contains("/") {
                                status = "Token and owner/repo are both required."
                                return
                            }
                            session.gitHubToken = token
                            session.gitHubRepo = repo
                            session.isGitHubConnected = false   // will flip true after first listing
                            onConnect()
                            isShown = false
                        }
                        .foregroundColor(IJ.accentBlue)
                        .listRowBackground(IJ.bgEditor)

                        if session.isGitHubConnected {
                            Button(role: .destructive) {
                                session.isGitHubConnected = false
                                session.gitHubToken = ""
                                session.gitHubRepo = ""
                                isShown = false
                            } label: {
                                Text("Disconnect").foregroundColor(IJ.accentRed)
                            }
                            .listRowBackground(IJ.bgEditor)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(IJ.bgMain)
            }
            .navigationTitle("Connect GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isShown = false }
                        .foregroundColor(IJ.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            tokenDraft = session.gitHubToken
            repoDraft  = session.gitHubRepo
        }
    }
}
