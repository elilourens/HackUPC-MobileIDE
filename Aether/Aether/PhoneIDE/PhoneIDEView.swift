import SwiftUI
import WebKit

/// Phone-mode IDE shell. JetBrains Islands look: toolbar, editor tabs, Monaco
/// editor, drag handle, agent chat, status bar. AR button in the toolbar
/// switches to the AR workspace; ProjectSession is shared so code persists
/// across modes.
struct PhoneIDEView: View {
    @ObservedObject var session: ProjectSession
    let onEnterAR: () -> Void

    @State private var sidebarShown = false
    @State private var showSettings = false
    @State private var showGitHubConnect = false
    @State private var showPreview = false
    @State private var editorRatio: CGFloat = 0.62   // editor takes ~62% by default
    @State private var dragStartRatio: CGFloat = 0.62

    @State private var repoEntries: [GitHubClient.RepoEntry] = []
    @State private var statusMessage: String = ""

    @State private var previewWebView: WKWebView?
    @State private var previewDebounce: DispatchWorkItem?

    private let toolbarHeight: CGFloat = 44
    private let tabsHeight: CGFloat = 34
    private let statusHeight: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            ZStack {
                IJ.bgMain.ignoresSafeArea()

                VStack(spacing: 0) {
                    toolbar
                    tabs
                    splitArea(totalHeight: geo.size.height - toolbarHeight - tabsHeight - statusHeight)
                    statusBar
                }
                .ignoresSafeArea(edges: .bottom)

                FileTreeSidebar(
                    session: session,
                    isShown: $sidebarShown,
                    showSettings: $showSettings,
                    showGitHubConnect: $showGitHubConnect,
                    repoEntries: repoEntries,
                    onSelectFile: { file in session.switchTo(file: file) },
                    onSelectRepoFile: openRepoFile,
                    onNewFile: newFile,
                    onRefreshRepo: refreshRepo
                )
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(session: session, isShown: $showSettings)
        }
        .sheet(isPresented: $showGitHubConnect) {
            GitHubConnectSheet(session: session, isShown: $showGitHubConnect, onConnect: {
                refreshRepo()
            })
        }
        .onAppear {
            if session.openTabs.isEmpty {
                if session.projectFiles[session.currentFile] == nil {
                    session.createFile(session.currentFile.isEmpty ? "index.html" : session.currentFile)
                }
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button(action: { withAnimation(.easeOut(duration: 0.22)) { sidebarShown.toggle() } }) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(IJ.textPrimary)
                    .frame(width: 28, height: 28)
            }

            Text(projectLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(IJ.textPrimary)

            Spacer()

            HStack(spacing: 6) {
                Circle().fill(IJ.accentGreen).frame(width: 6, height: 6)
                Text("main")
                    .font(.system(size: 12))
                    .foregroundColor(IJ.accentGreen)
            }

            Button(action: pushOrPull) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(session.isGitHubConnected ? IJ.textPrimary : IJ.textDisabled)
                    .frame(width: 28, height: 28)
            }
            .disabled(!session.isGitHubConnected)

            Button(action: { withAnimation(.easeOut(duration: 0.18)) { showPreview.toggle() } }) {
                Image(systemName: showPreview ? "eye.fill" : "eye")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(showPreview ? IJ.accentBlue : IJ.textPrimary)
                    .frame(width: 28, height: 28)
            }

            Button(action: onEnterAR) {
                Text("AR")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(IJ.accentBlue))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, safeTopInset())
        .frame(height: toolbarHeight + safeTopInset())
        .background(IJ.bgMain)
        .overlay(Rectangle().fill(IJ.border).frame(height: 1), alignment: .bottom)
    }

    private var projectLabel: String {
        if session.isGitHubConnected, !session.gitHubRepo.isEmpty {
            return session.gitHubRepo.split(separator: "/").last.map(String.init) ?? "my-app"
        }
        return "my-app"
    }

    // MARK: - Tabs

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(session.openTabs, id: \.self) { file in
                    tabRow(file)
                }
                if session.openTabs.isEmpty {
                    Text("no files")
                        .font(.system(size: 12))
                        .foregroundColor(IJ.textDisabled)
                        .padding(.horizontal, 14)
                }
            }
        }
        .frame(height: tabsHeight)
        .background(IJ.bgTabs)
        .overlay(Rectangle().fill(IJ.border).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder
    private func tabRow(_ file: String) -> some View {
        let active = file == session.currentFile
        Button(action: { session.switchTo(file: file) }) {
            HStack(spacing: 6) {
                Circle().fill(IJ.iconColor(for: file)).frame(width: 6, height: 6)
                Text(file)
                    .font(.system(size: 12))
                    .foregroundColor(active ? IJ.textPrimary : IJ.textSecondary)
                Button(action: { session.closeTab(file) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(IJ.textSecondary)
                        .padding(2)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: tabsHeight)
            .overlay(
                Rectangle()
                    .fill(active ? IJ.accentBlue : Color.clear)
                    .frame(height: 2),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Split (editor / agent OR editor / preview)

    private func splitArea(totalHeight: CGFloat) -> some View {
        let editorH = max(120, totalHeight * editorRatio)
        let restH = max(120, totalHeight - editorH - 6)

        return VStack(spacing: 0) {
            MonacoEditorView(
                filename: session.currentFile,
                code: session.currentCode,
                onChange: { newCode in
                    if newCode != session.currentCode {
                        session.setCode(newCode, forFile: session.currentFile, pushHistory: false)
                        scheduleLivePreviewRefresh()
                    }
                }
            )
            .frame(height: editorH)
            .background(IJ.bgEditor)

            // Drag handle (resize editor vs agent/preview)
            ZStack {
                IJ.bgMain
                Rectangle()
                    .fill(IJ.border)
                    .frame(width: 40, height: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
            }
            .frame(maxWidth: .infinity, minHeight: 6, maxHeight: 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartRatio == editorRatio { dragStartRatio = editorRatio }
                        let delta = value.translation.height / max(totalHeight, 1)
                        editorRatio = min(0.85, max(0.20, dragStartRatio + delta))
                    }
                    .onEnded { _ in dragStartRatio = editorRatio }
            )

            if showPreview {
                PreviewPane(html: session.currentCode, onWebViewReady: { wv in previewWebView = wv })
                    .frame(height: restH)
                    .background(Color.white)
            } else {
                AgentPanel(session: session)
                    .frame(height: restH)
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(session.currentFile)
            Text("UTF-8")
            Text(IJ.languageLabel(for: session.currentFile))
            Spacer()
            if !statusMessage.isEmpty {
                Text(statusMessage).foregroundColor(IJ.textPrimary)
            }
            Text(session.isGenerating ? "generating…" : "ready")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(IJ.textSecondary)
        .padding(.horizontal, 14)
        .frame(height: statusHeight)
        .background(IJ.bgMain)
        .overlay(Rectangle().fill(IJ.border).frame(height: 1), alignment: .top)
    }

    // MARK: - GitHub helpers

    private func refreshRepo() {
        guard !session.gitHubToken.isEmpty, !session.gitHubRepo.isEmpty else { return }
        statusMessage = "loading repo…"
        GitHubClient.shared.listContents(path: "", session: session) { result in
            switch result {
            case .success(let entries):
                self.repoEntries = entries
                self.session.isGitHubConnected = true
                self.statusMessage = "connected"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.statusMessage = "" }
            case .failure(let err):
                self.statusMessage = "github failed: \(err.localizedDescription)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.statusMessage = "" }
            }
        }
    }

    private func openRepoFile(_ entry: GitHubClient.RepoEntry) {
        statusMessage = "fetching \(entry.name)…"
        GitHubClient.shared.getFile(path: entry.path, session: session) { result in
            switch result {
            case .success(let payload):
                self.session.gitHubFileShas[entry.path] = payload.sha
                self.session.setCode(payload.text, forFile: entry.name, pushHistory: false)
                self.statusMessage = "opened"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.statusMessage = "" }
            case .failure(let err):
                self.statusMessage = "fetch failed: \(err.localizedDescription)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.statusMessage = "" }
            }
        }
    }

    private func pushOrPull() {
        // Single button does push for now. Pull lives behind a long-press.
        guard session.isGitHubConnected, !session.currentCode.isEmpty else { return }
        let path = session.currentFile
        let sha = session.gitHubFileShas[path]
        statusMessage = "pushing…"
        GitHubClient.shared.putFile(path: path, text: session.currentCode, sha: sha,
                                    message: "Updated via Aether",
                                    session: session) { result in
            switch result {
            case .success(let newSha):
                if !newSha.isEmpty { self.session.gitHubFileShas[path] = newSha }
                self.statusMessage = "pushed"
                self.session.appendChat(.assistant, "Pushed \(path) to GitHub.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.statusMessage = "" }
            case .failure(let err):
                self.statusMessage = "push failed"
                self.session.appendChat(.assistant, "Push failed: \(err.localizedDescription)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.statusMessage = "" }
            }
        }
    }

    private func newFile() {
        // Simple inline naming — the spec defers a proper modal to phase 3b.
        var n = 1
        while session.projectFiles["untitled\(n).html"] != nil { n += 1 }
        let name = "untitled\(n).html"
        session.createFile(name)
        session.switchTo(file: name)
    }

    // MARK: - Preview live-refresh debounce

    private func scheduleLivePreviewRefresh() {
        guard showPreview else { return }
        previewDebounce?.cancel()
        let work = DispatchWorkItem { [weak previewWebView] in
            guard let wv = previewWebView else { return }
            wv.loadHTMLString(session.currentCode, baseURL: nil)
        }
        previewDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func safeTopInset() -> CGFloat {
        // SwiftUI's safeAreaInsets isn't reachable from a plain view; pull from the
        // active scene's keyWindow so the toolbar pushes below the notch.
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let win = scene.windows.first else { return 0 }
        return win.safeAreaInsets.top
    }
}

/// Live preview pane — a WKWebView fed by ProjectSession.currentCode. Held in
/// the parent view so we can re-load it on edit (debounced).
private struct PreviewPane: UIViewRepresentable {
    let html: String
    let onWebViewReady: (WKWebView) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.scrollView.bounces = false
        wv.loadHTMLString(html, baseURL: nil)
        DispatchQueue.main.async { onWebViewReady(wv) }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Initial load happens in makeUIView; subsequent reloads come from the
        // debounce in PhoneIDEView. Keep updateUIView a no-op so a parent state
        // tick doesn't trash the WebView mid-render.
    }
}
