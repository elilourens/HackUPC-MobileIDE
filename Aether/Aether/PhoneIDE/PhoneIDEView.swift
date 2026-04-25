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

    private let toolbarHeight: CGFloat = 40
    private let tabsHeight: CGFloat = 32
    private let statusHeight: CGFloat = 24
    private let iconStripWidth: CGFloat = 28
    @State private var selectedToolWindow: ToolWindow = .project

    enum ToolWindow: String, CaseIterable {
        case project, structure, git, bookmarks, junie
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                IJ.bgMain.ignoresSafeArea()

                VStack(spacing: 0) {
                    toolbar
                    HStack(spacing: 0) {
                        leftIconStrip
                        Rectangle().fill(IJ.border).frame(width: 1)
                        VStack(spacing: 0) {
                            tabs
                            splitArea(totalHeight: geo.size.height - toolbarHeight - tabsHeight - statusHeight - safeTopInset())
                        }
                    }
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

    // MARK: - Toolbar (WebStorm window header)

    private var toolbar: some View {
        HStack(spacing: 8) {
            // Hamburger
            Button(action: { withAnimation(.easeOut(duration: 0.22)) { sidebarShown.toggle() } }) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(IJ.textPrimary)
                    .frame(width: 24, height: 24)
            }

            // Project pill
            HStack(spacing: 6) {
                JBIcon(.tool("project"), size: 12)
                Text(projectLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(IJ.textPrimary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(IJ.bgEditor))

            // Branch widget
            HStack(spacing: 4) {
                JBIcon(.tool("branch"), size: 11)
                Text("main")
                    .font(.system(size: 11))
                    .foregroundColor(IJ.textPrimary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(IJ.bgEditor))

            // Run + debug widgets
            Button(action: { /* run preview */ withAnimation(.easeOut(duration: 0.18)) { showPreview = true } }) {
                JBIcon(.tool("run"), size: 13)
                    .frame(width: 22, height: 22)
            }
            Button(action: { /* debug — no-op for hackathon */ }) {
                JBIcon(.tool("debug"), size: 13)
                    .frame(width: 22, height: 22)
            }

            Spacer()

            // Search
            Button(action: {}) {
                JBIcon(.tool("search"), size: 13)
                    .frame(width: 22, height: 22)
            }
            // AI assistant — Junie sparkle
            Button(action: { selectedToolWindow = .junie }) {
                Image("JunieIcon")
                    .resizable()
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            }
            // Avatar
            ZStack {
                Circle().fill(IJ.bgEditor)
                Circle().stroke(IJ.border, lineWidth: 1)
                Text("A").font(.system(size: 10, weight: .semibold)).foregroundColor(IJ.textPrimary)
            }
            .frame(width: 22, height: 22)

            // Settings
            Button(action: { showSettings = true }) {
                JBIcon(.tool("settings"), size: 13)
                    .frame(width: 22, height: 22)
            }

            // AR pill (kept — not in stock WebStorm but this is ArcReact)
            Button(action: onEnterAR) {
                Text("AR")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(IJ.accentBlue))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, safeTopInset())
        .frame(height: toolbarHeight + safeTopInset())
        .background(IJ.bgEditor)
        .overlay(Rectangle().fill(IJ.border).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Vertical icon strip (WebStorm tool-window rail)

    private var leftIconStrip: some View {
        VStack(spacing: 4) {
            stripButton(.project, icon: "JB-tool-project")
            stripButton(.structure, sfSymbol: "list.bullet.indent")
            stripButton(.git, icon: "JB-tool-branch")
            stripButton(.bookmarks, sfSymbol: "bookmark")
            stripButton(.junie, junie: true)
            Spacer()
            // Bottom slot: terminal / problems
            Button(action: {}) {
                Image(systemName: "terminal")
                    .font(.system(size: 12))
                    .foregroundColor(IJ.textSecondary)
                    .frame(width: iconStripWidth, height: 30)
            }
        }
        .padding(.top, 6)
        .frame(width: iconStripWidth)
        .background(IJ.bgSidebar)
    }

    @ViewBuilder
    private func stripButton(_ window: ToolWindow,
                             icon: String? = nil,
                             sfSymbol: String? = nil,
                             junie: Bool = false) -> some View {
        let active = selectedToolWindow == window
        Button(action: {
            selectedToolWindow = window
            if window == .project {
                withAnimation(.easeOut(duration: 0.22)) { sidebarShown.toggle() }
            }
        }) {
            ZStack {
                if active {
                    Rectangle().fill(IJ.bgSelected).frame(width: iconStripWidth, height: 30)
                    Rectangle().fill(IJ.accentBlue)
                        .frame(width: 2, height: 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if junie {
                    Image("JunieIcon")
                        .resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else if let icon = icon {
                    Image(icon).resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else if let sf = sfSymbol {
                    Image(systemName: sf)
                        .font(.system(size: 12))
                        .foregroundColor(active ? IJ.textPrimary : IJ.textSecondary)
                }
            }
            .frame(width: iconStripWidth, height: 30)
        }
        .buttonStyle(.plain)
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
                Image(JBIconLoader.fileTypeAsset(for: file))
                    .resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
                Text(file)
                    .font(.system(size: 12))
                    .foregroundColor(active ? IJ.textPrimary : IJ.textSecondary)
                Button(action: { session.closeTab(file) }) {
                    Image("JB-tool-close")
                        .resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
                        .foregroundColor(IJ.textSecondary)
                        .frame(width: 9, height: 9)
                        .padding(2)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: tabsHeight)
            .background(active ? IJ.bgEditor : Color.clear)
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
        HStack(spacing: 0) {
            // Left: breadcrumb path
            HStack(spacing: 4) {
                JBIcon(.tool("folder"), size: 10)
                Text(projectLabel)
                    .foregroundColor(IJ.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundColor(IJ.textDisabled)
                Text(session.currentFile)
                    .foregroundColor(IJ.textPrimary)
            }
            .padding(.horizontal, 10)

            Spacer()

            // Inline status / generating indicator
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .foregroundColor(IJ.textPrimary)
                    .padding(.horizontal, 8)
            } else if session.isGenerating {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).tint(IJ.textSecondary)
                    Text("building…").foregroundColor(IJ.textSecondary)
                }
                .padding(.horizontal, 8)
            }

            // Right: WebStorm segments
            HStack(spacing: 12) {
                statusSegment("LF")
                statusSegment("UTF-8")
                statusSegment(IJ.languageLabel(for: session.currentFile))
                statusSegment("main", icon: "JB-tool-branch")
                statusSegment("2 spaces")
                memoryIndicator
            }
            .padding(.horizontal, 10)
        }
        .font(.system(size: 11))
        .foregroundColor(IJ.textSecondary)
        .frame(height: statusHeight)
        .background(IJ.bgEditor)
        .overlay(Rectangle().fill(IJ.border).frame(height: 1), alignment: .top)
    }

    @ViewBuilder
    private func statusSegment(_ label: String, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(icon).resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
                    .frame(width: 10, height: 10)
            }
            Text(label).foregroundColor(IJ.textSecondary)
        }
    }

    /// Faux memory indicator — JetBrains shows "X / Y MB" and a green progress
    /// bar in the status bar. We can't read JVM memory (we're not on the JVM),
    /// so we render a static bar that looks the part for the demo.
    private var memoryIndicator: some View {
        HStack(spacing: 6) {
            Text("128M / 512M")
            ZStack(alignment: .leading) {
                Capsule().fill(IJ.bgSelected).frame(width: 36, height: 6)
                Capsule().fill(IJ.accentGreen).frame(width: 10, height: 6)
            }
        }
        .foregroundColor(IJ.textSecondary)
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
