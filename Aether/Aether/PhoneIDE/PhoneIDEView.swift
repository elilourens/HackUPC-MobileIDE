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
    @State private var showJunie = true       // right slide-in Junie tool window
    @State private var showNewFilePrompt = false
    @State private var newFileDraft: String = ""
    @State private var currentBranch: String = "main"
    @State private var showNotifications = false
    @State private var showFindInProject = false
    @State private var showDebugConsole = false
    @State private var editorRatio: CGFloat = 0.62   // editor takes ~62% by default when preview is split
    @State private var dragStartRatio: CGFloat = 0.62

    @State private var repoEntries: [GitHubClient.RepoEntry] = []
    @State private var statusMessage: String = ""

    @State private var previewWebView: WKWebView?
    @State private var previewDebounce: DispatchWorkItem?

    private let toolbarHeight: CGFloat = 40
    private let tabsHeight: CGFloat = 32
    private let statusHeight: CGFloat = 24
    private let iconStripWidth: CGFloat = 28
    /// Real origin for the preview WebView so cross-origin script errors
    /// expose their actual line/file in `window.onerror` instead of being
    /// sanitized to the useless string "Script error.". `aether.preview`
    /// is a dummy domain — it only needs to be a valid URL so WKWebView
    /// stops treating the page as opaque-origin.
    fileprivate static let previewBaseURL = URL(string: "https://aether.preview/")!
    @State private var selectedToolWindow: ToolWindow = .project

    enum ToolWindow: String, CaseIterable {
        case project, structure, git, bookmarks, junie
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                IJ.bgMain.ignoresSafeArea()

                VStack(spacing: 0) {
                    brandBar
                    toolbar
                    HStack(alignment: .top, spacing: 0) {
                        leftIconStrip
                        Rectangle().fill(IJ.border).frame(width: 1)
                        VStack(spacing: 0) {
                            tabs
                            splitAreaView
                        }
                        // Without an explicit max width, SwiftUI lets the
                        // editor / Junie subtree overflow past the right
                        // edge on phones with notches, clipping the send
                        // button etc. Constrain it to whatever the HStack
                        // has left after the icon strip and divider.
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    statusBar
                }
                // Ignore the *container* vertical safe areas so the brand
                // bar / toolbar / status bar paint their backgrounds to the
                // screen edges. We deliberately do NOT pass the .keyboard
                // region, otherwise the system stops nudging the layout up
                // when the iOS keyboard rises and Junie's input gets buried
                // under the keys.
                .ignoresSafeArea(.container, edges: [.top, .bottom])

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
        .sheet(isPresented: $showFindInProject) {
            FindInProjectSheet(session: session, isShown: $showFindInProject)
        }
        .sheet(isPresented: $showDebugConsole) {
            DebugConsoleSheet(session: session, isShown: $showDebugConsole)
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
        // Tight spacing + padding so the AR pill on the far right doesn't
        // get clipped on a stock 393pt-wide iPhone — every extra pt of
        // padding costs us on the trailing edge.
        HStack(spacing: 5) {
            // Hamburger
            Button(action: { withAnimation(.easeOut(duration: 0.22)) { sidebarShown.toggle() } }) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(IJ.textPrimary)
                    .frame(width: 24, height: 24)
            }

            // (Project pill removed — the brand bar above already names the
            // project, and this row was getting horizontally compressed and
            // wrapping "my-app" into a 1-char-wide column.)

            // Branch widget — dropdown of stub branches
            Menu {
                ForEach(["main", "develop", "feature/junie-rework", "hotfix/voice-bug"], id: \.self) { b in
                    Button(b) { currentBranch = b }
                }
            } label: {
                HStack(spacing: 4) {
                    JBIcon(.tool("branch"), size: 11)
                    Text(currentBranch)
                        .font(.system(size: 11))
                        .foregroundColor(IJ.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(IJ.textSecondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(IJ.bgEditor))
            }

            // Run — toggles the live preview pane below the editor.
            Button(action: {
                withAnimation(.easeOut(duration: 0.18)) {
                    showPreview.toggle()
                    if showPreview { showJunie = false }
                }
            }) {
                JBIcon(.tool("run"), size: 13)
                    .frame(width: 22, height: 22)
            }

            // Debug — opens the Debug Console sheet showing every console.log /
            // warn / error captured from the preview WebView via injected JS.
            Button(action: { showDebugConsole = true }) {
                ZStack(alignment: .topTrailing) {
                    JBIcon(.tool("debug"), size: 13)
                        .frame(width: 22, height: 22)
                    if hasErrorsInConsole {
                        Circle().fill(IJ.accentRed)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }

            // GitHub sync — tap = push, long-press = pull (JetBrains UX)
            Button(action: pushToGitHub) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(session.isGitHubConnected ? IJ.textPrimary : IJ.textDisabled)
                    .frame(width: 22, height: 22)
            }
            .disabled(!session.isGitHubConnected)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in pullFromGitHub() }
            )

            Spacer()

            // Search — opens "Find in Project" sheet that scans every file in
            // session.projectFiles and jumps to the matching file on tap.
            Button(action: { showFindInProject = true }) {
                JBIcon(.tool("search"), size: 13)
                    .frame(width: 22, height: 22)
            }

            // AI assistant — Junie sparkle. Toggles the bottom Junie tool
            // window so the toolbar mirrors the icon-strip behaviour.
            Button(action: {
                selectedToolWindow = .junie
                withAnimation(.easeOut(duration: 0.22)) { showJunie.toggle() }
            }) {
                Image("JunieIcon")
                    .resizable()
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .frame(width: 22, height: 22)
            }
            // Notifications bell — JetBrains New UI right-side notification center
            Menu {
                Section("Notifications") {
                    Button { } label: {
                        Label("Junie suggested 3 changes", systemImage: "sparkles")
                    }
                    Button { } label: {
                        Label("Updates available · ArcReact 2026.1.1", systemImage: "arrow.down.circle")
                    }
                    Button { } label: {
                        Label("Welcome to ArcReact", systemImage: "sparkle")
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(IJ.textPrimary)
                        .frame(width: 22, height: 22)
                    Circle().fill(IJ.accentRed)
                        .frame(width: 6, height: 6)
                        .offset(x: -2, y: 2)
                }
            }

            // Account menu — JetBrains-style avatar dropdown. Shows GitHub
            // status (connected repo or "Connect GitHub"), a settings shortcut,
            // and a sign-out option that disconnects GitHub.
            Menu {
                Section("Account") {
                    Text("Akshat · ArcReact")
                }
                Section("GitHub") {
                    if session.isGitHubConnected {
                        Text(session.gitHubRepo.isEmpty ? "Connected" : session.gitHubRepo)
                        Button(role: .destructive) {
                            session.isGitHubConnected = false
                            session.gitHubToken = ""
                            session.gitHubRepo = ""
                        } label: {
                            Label("Disconnect GitHub", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } else {
                        Button { showGitHubConnect = true } label: {
                            Label("Connect GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                }
                Section {
                    Button { showSettings = true } label: {
                        Label("Settings…", systemImage: "gearshape")
                    }
                }
            } label: {
                ZStack {
                    Circle().fill(IJ.bgEditor)
                    Circle().stroke(IJ.border, lineWidth: 1)
                    Text("A").font(.system(size: 10, weight: .semibold)).foregroundColor(IJ.textPrimary)
                    if session.isGitHubConnected {
                        Circle().fill(IJ.accentGreen)
                            .frame(width: 6, height: 6)
                            .offset(x: 8, y: -8)
                    }
                }
                .frame(width: 22, height: 22)
            }

            // (Settings button removed from toolbar — it's reachable from
            // the avatar account menu, and dropping it here gives the AR
            // pill room to breathe on a 393pt-wide iPhone.)

            // AR pill (kept — not in stock WebStorm but this is ArcReact)
            Button(action: onEnterAR) {
                Text("AR")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(IJ.accentBlue))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: toolbarHeight)
        .background(IJ.bgEditor)
        .overlay(Rectangle().fill(IJ.border).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Brand bar (ArcReact wordmark above the toolbar)

    /// Slim WebStorm-style title strip pinned above the toolbar. Carries the
    /// `safeTopInset()` padding so the IJ.bgEditor background paints all the
    /// way to the screen edge — and frames the product as "ArcReact, the
    /// JetBrains AR-native IDE".
    private var brandBar: some View {
        HStack(spacing: 10) {
            Image("ArcReactLogo")
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("ArcReact")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(IJ.textPrimary)
                Text("by JetBrains · 2026.1")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.6)
                    .foregroundColor(IJ.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, safeTopInset() + 4)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        let isCurrentlyActive: Bool = {
            switch window {
            case .project: return sidebarShown
            case .junie:   return showJunie
            default:       return selectedToolWindow == window
            }
        }()
        let active = isCurrentlyActive
        Button(action: {
            selectedToolWindow = window
            switch window {
            case .project:
                withAnimation(.easeOut(duration: 0.22)) { sidebarShown.toggle() }
            case .junie:
                withAnimation(.easeOut(duration: 0.22)) { showJunie.toggle() }
            default:
                break
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
        HStack(spacing: 0) {
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
            // Trailing "+" — JetBrains-style new-file affordance at the end of
            // the tab strip. Tapping prompts for a name then opens the new file.
            Button(action: { showNewFilePrompt = true }) {
                Image("JB-tool-add")
                    .resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
                    .frame(width: 11, height: 11)
                    .frame(width: 26, height: tabsHeight)
            }
            .buttonStyle(.plain)
        }
        .frame(height: tabsHeight)
        .background(IJ.bgTabs)
        .overlay(Rectangle().fill(IJ.border).frame(height: 1), alignment: .bottom)
        .alert("New file", isPresented: $showNewFilePrompt) {
            TextField("filename.html", text: $newFileDraft)
            Button("Create", action: confirmNewFile)
            Button("Cancel", role: .cancel) { newFileDraft = "" }
        } message: {
            Text("Name the new file (e.g. styles.css, app.js).")
        }
    }

    private func confirmNewFile() {
        var name = newFileDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        newFileDraft = ""
        if name.isEmpty {
            newFile()
            return
        }
        if !name.contains(".") { name += ".html" }
        session.createFile(name)
        session.switchTo(file: name)
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
                    if session.modifiedFiles.contains(file) {
                        // JetBrains modified-tab marker: blue dot replaces the
                        // close glyph until you hover/tap (we use tap on phone).
                        Circle()
                            .fill(IJ.accentBlue)
                            .frame(width: 7, height: 7)
                            .padding(3)
                    } else {
                        Image("JB-tool-close")
                            .resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
                            .foregroundColor(IJ.textSecondary)
                            .frame(width: 9, height: 9)
                            .padding(2)
                    }
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
        .contextMenu {
            Button("Close") { session.closeTab(file) }
            Button("Close Others") {
                for f in session.openTabs where f != file { session.closeTab(f) }
            }
            Button("Close All") {
                for f in session.openTabs { session.closeTab(f) }
            }
            Divider()
            Button("Reveal in Project") {
                withAnimation(.easeOut(duration: 0.22)) { sidebarShown = true }
            }
            Button("Copy Path") {
                UIPasteboard.general.string = file
            }
        }
    }

    // MARK: - Split (editor / agent OR editor / preview)

    /// Editor with an optional bottom pane (Junie tool window OR live preview).
    /// Mutually exclusive — Junie wins when both flags are on. Sized by SwiftUI
    /// to fill whatever vertical space the tabs left behind, so the bottom
    /// pane is always bounded above the status bar (no more cut-off input
    /// fields under the home indicator).
    @ViewBuilder
    private var splitAreaView: some View {
        let kind = bottomPaneKind
        if kind == .none {
            editorView.frame(maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                let h = geo.size.height
                let editorH = max(120, h * editorRatio)
                let restH = max(140, h - editorH - 6)
                VStack(spacing: 0) {
                    editorView.frame(height: editorH)
                    dragHandle(totalHeight: h)
                    bottomPane(kind: kind, height: restH)
                }
            }
        }
    }

    private enum BottomPaneKind { case none, junie, preview }

    private var bottomPaneKind: BottomPaneKind {
        // Junie wins over preview when both are toggled — preview is a
        // run-on-demand thing, Junie is the active conversation.
        if showJunie { return .junie }
        if showPreview { return .preview }
        return .none
    }

    @ViewBuilder
    private func bottomPane(kind: BottomPaneKind, height: CGFloat) -> some View {
        switch kind {
        case .junie:
            VStack(spacing: 0) {
                // Tool-window active stripe (green) — same accent as the
                // Junie icon-strip slot, so it reads as "Junie tool window
                // is the active bottom pane".
                Rectangle().fill(IJ.accentGreen).frame(height: 2)
                AgentPanel(session: session)
            }
            .frame(height: height)
            .background(IJ.bgSidebar)
        case .preview:
            ZStack {
                PreviewPane(html: session.previewHtml ?? session.currentCode,
                            session: session,
                            onWebViewReady: { wv in previewWebView = wv })
                if session.isGenerating {
                    BuildingShimmer()
                        .transition(.opacity)
                }
            }
            .frame(height: height)
            .background(Color.white)
        case .none:
            EmptyView()
        }
    }

    private var editorView: some View {
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
        .background(IJ.bgEditor)
    }

    @ViewBuilder
    private func dragHandle(totalHeight: CGFloat) -> some View {
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
        // Mirror the toolbar's safe-area trick: extend the bg into the bottom
        // safe area (home-indicator zone) so LF · UTF-8 · branch · memory
        // never sit underneath the iOS home bar. Content keeps its statusHeight
        // — only the bg grows downward.
        .padding(.bottom, safeBottomInset())
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

    private func pushToGitHub() {
        guard session.isGitHubConnected, !session.currentCode.isEmpty else { return }
        let path = session.currentFile
        let sha = session.gitHubFileShas[path]
        statusMessage = "pushing…"
        GitHubClient.shared.putFile(path: path, text: session.currentCode, sha: sha,
                                    message: "Updated via ArcReact",
                                    session: session) { result in
            switch result {
            case .success(let newSha):
                if !newSha.isEmpty { self.session.gitHubFileShas[path] = newSha }
                self.session.markFileSynced(path)
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

    private func pullFromGitHub() {
        guard session.isGitHubConnected else { return }
        let path = session.currentFile
        statusMessage = "pulling…"
        GitHubClient.shared.getFile(path: path, session: session) { result in
            switch result {
            case .success(let payload):
                self.session.gitHubFileShas[path] = payload.sha
                self.session.setCode(payload.text, forFile: path, pushHistory: false)
                self.session.markFileSynced(path)
                self.statusMessage = "pulled"
                self.session.appendChat(.assistant, "Pulled \(path) from GitHub.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.statusMessage = "" }
            case .failure(let err):
                self.statusMessage = "pull failed"
                self.session.appendChat(.assistant, "Pull failed: \(err.localizedDescription)")
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
            // Prefer the model-supplied bundled preview (Babel-standalone JSX
            // wrap, etc.) — only fall through to currentCode for plain html
            // projects where the active file IS the preview.
            let html = session.previewHtml ?? session.currentCode
            // baseURL gives the page a real origin so cross-origin script
            // errors aren't sanitized to "Script error." in the console.
            wv.loadHTMLString(html, baseURL: PhoneIDEView.previewBaseURL)
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

    private func safeBottomInset() -> CGFloat {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let win = scene.windows.first else { return 0 }
        return win.safeAreaInsets.bottom
    }

    /// True iff the captured preview console contains an error since the last
    /// time the user opened the Debug sheet — drives the red dot on the
    /// toolbar Debug icon.
    private var hasErrorsInConsole: Bool {
        session.consoleEntries.contains(where: { $0.level == .error })
    }
}

/// Live preview pane — a WKWebView fed by either `session.previewHtml` (the
/// bundled Babel-standalone JSX wrapper) or the current file's contents. Holds
/// a ScriptMessageHandler that funnels console.log / errors back into
/// `session.consoleEntries` so the toolbar Debug button can show them.
private struct PreviewPane: UIViewRepresentable {
    let html: String
    let session: ProjectSession
    let onWebViewReady: (WKWebView) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true

        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "console")
        userController.addUserScript(
            WKUserScript(source: PreviewPane.consoleShim,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        config.userContentController = userController

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.scrollView.bounces = false
        wv.loadHTMLString(html, baseURL: PhoneIDEView.previewBaseURL)
        DispatchQueue.main.async { onWebViewReady(wv) }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Initial load happens in makeUIView; subsequent reloads come from the
        // debounce in PhoneIDEView. Keep updateUIView a no-op so a parent state
        // tick doesn't trash the WebView mid-render.
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    /// JS injected at document-start so we capture the FIRST console call —
    /// otherwise React's render-time errors fire before our shim is in place.
    /// Wraps console.log/info/warn/error/debug, plus listens for `error` and
    /// `unhandledrejection`. All payloads get forwarded to the Swift side via
    /// `webkit.messageHandlers.console.postMessage`.
    private static let consoleShim: String = """
    (function(){
      var levels = ['log','info','warn','error','debug'];
      levels.forEach(function(level){
        var orig = console[level] ? console[level].bind(console) : function(){};
        console[level] = function(){
          try {
            var args = Array.prototype.slice.call(arguments).map(function(a){
              if (a === null || a === undefined) return String(a);
              if (typeof a === 'string') return a;
              if (a instanceof Error) return (a.message || String(a));
              try { return JSON.stringify(a); } catch (e) { return String(a); }
            });
            window.webkit.messageHandlers.console.postMessage({level: level, msg: args.join(' ')});
          } catch (e) {}
          orig.apply(null, arguments);
        };
      });
      window.addEventListener('error', function(e){
        try {
          var loc = (e.filename || 'preview') + ':' + (e.lineno || '?');
          window.webkit.messageHandlers.console.postMessage({level: 'error', msg: (e.message || 'error') + ' @ ' + loc});
        } catch (err) {}
      });
      window.addEventListener('unhandledrejection', function(e){
        try {
          var reason = e.reason && e.reason.message ? e.reason.message : String(e.reason);
          window.webkit.messageHandlers.console.postMessage({level: 'error', msg: 'Unhandled promise: ' + reason});
        } catch (err) {}
      });
    })();
    """

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let session: ProjectSession
        init(session: ProjectSession) { self.session = session }

        nonisolated func userContentController(_ ucc: WKUserContentController,
                                               didReceive message: WKScriptMessage) {
            guard message.name == "console",
                  let dict = message.body as? [String: Any],
                  let levelStr = dict["level"] as? String,
                  let msg = dict["msg"] as? String else { return }
            let level = ConsoleEntry.Level(rawValue: levelStr) ?? .log
            Task { @MainActor in
                self.session.appendConsole(level, msg)
            }
        }
    }
}

/// Skeleton scaffolding shown over the preview pane during a build. Mimics
/// "the page being assembled bit by bit" — header bar fades in, hero block,
/// then 3 card rows — with a sweeping shimmer gradient running across them.
/// Disappears the moment `session.isGenerating` flips back to false.
private struct BuildingShimmer: View {
    @State private var phase: CGFloat = 0
    @State private var stage: Int = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .top) {
                Color(red: 10/255, green: 10/255, blue: 10/255).opacity(0.96)

                VStack(spacing: 18) {
                    // Top nav row
                    skeletonRow(width: w * 0.92, height: 36, cornerRadius: 8, delay: 0)
                        .padding(.top, 28)
                    // Hero block
                    skeletonRow(width: w * 0.92, height: 180, cornerRadius: 18, delay: 1)
                    // Body card grid
                    HStack(spacing: 12) {
                        skeletonRow(width: w * 0.30, height: 96, cornerRadius: 12, delay: 2)
                        skeletonRow(width: w * 0.30, height: 96, cornerRadius: 12, delay: 2)
                        skeletonRow(width: w * 0.30, height: 96, cornerRadius: 12, delay: 2)
                    }
                    skeletonRow(width: w * 0.92, height: 60, cornerRadius: 12, delay: 3)
                    skeletonRow(width: w * 0.78, height: 22, cornerRadius: 6, delay: 4)
                    skeletonRow(width: w * 0.62, height: 18, cornerRadius: 6, delay: 4)
                    Spacer()
                }
                .frame(width: w, height: h, alignment: .top)

                // Status pill
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7).tint(.white.opacity(0.9))
                        Text(stageLabel)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundColor(.white.opacity(0.92))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .padding(.bottom, 22)
                }
                .frame(width: w, height: h)
            }
            .clipped()
        }
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1
            }
            // Step the status label so users see progress through phases.
            let labels = stageLabels.count
            for i in 1..<labels {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.8) {
                    stage = i
                }
            }
        }
    }

    private let stageLabels = [
        "SCAFFOLDING PROJECT",
        "WRITING package.json",
        "BUILDING src/App.jsx",
        "STYLING COMPONENTS",
        "WIRING ENTRY POINT",
        "RENDERING PREVIEW",
    ]

    private var stageLabel: String { stageLabels[min(stage, stageLabels.count - 1)] }

    @ViewBuilder
    private func skeletonRow(width: CGFloat, height: CGFloat,
                             cornerRadius: CGFloat, delay: Int) -> some View {
        // Each row's shimmer is offset by `delay * 0.18` so the build feels
        // staggered — header reveals first, hero second, etc.
        let local = max(0, phase - CGFloat(delay) * 0.12)
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(red: 0.16, green: 0.16, blue: 0.18))
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.10), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: -geo.size.width * 0.5
                            + (geo.size.width + geo.size.width * 0.5) * local)
                }
            )
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
