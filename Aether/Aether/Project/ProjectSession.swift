import Foundation
import Combine

/// Information about the HTML element the user has currently selected by pointing at the
/// preview panel. Used to scope the next code modification to a single element.
struct ElementInfo: Equatable {
    let tag: String
    let id: String
    let className: String
    let text: String

    var humanLabel: String {
        let lower = tag.lowercased()
        if !id.isEmpty { return "<\(lower)#\(id)>" }
        if !className.isEmpty {
            let first = className.split(separator: " ").first.map(String.init) ?? className
            return "<\(lower).\(first)>"
        }
        return "<\(lower)>"
    }
}

/// One terminal line in the AR Junie panel. Color is decided at draw time from the kind.
struct TerminalLine: Equatable {
    enum Kind { case command, output, success, error, info }
    let kind: Kind
    let text: String
}

/// One entry in the Debug Console — captured from the preview WKWebView via
/// an injected JS shim that overrides `console.log/info/warn/error/debug` and
/// listens for `error` / `unhandledrejection`. Surfaced to the toolbar Debug
/// sheet so users can actually see runtime errors from their JSX.
struct ConsoleEntry: Identifiable, Equatable {
    enum Level: String { case log, info, warn, error, debug }
    let id = UUID()
    let level: Level
    let text: String
    let timestamp: Date
}

/// One agent-chat message rendered in the phone-IDE agent panel.
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, system }
    let id = UUID()
    let role: Role
    var text: String
    let timestamp: Date

    init(role: Role, text: String, timestamp: Date = Date()) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

/// Single source of truth for everything the phone IDE and the AR workspace render.
/// Owned at the App level (`AetherApp`) and injected into both `ARSessionManager` and
/// the `PhoneIDEView` so edits in either mode show up in the other.
@MainActor
final class ProjectSession: ObservableObject {
    // MARK: - Code state
    @Published private(set) var currentFile: String = "index.html"
    @Published private(set) var projectFiles: [String: String] = [:]
    /// Open editor tabs in display order. Mirrors what JetBrains shows along the
    /// top of the editor — files the user has opened, not every file in the project.
    @Published private(set) var openTabs: [String] = []
    @Published var selectedElement: ElementInfo?
    @Published var isGenerating: Bool = false
    /// True while `index.html` still holds the JetBrains-style demo splash. Codegen
    /// dispatch (phone IDE + AR voice) treats this as "no real code yet" so the
    /// first user prompt is a fresh generation, not a modify-the-splash call.
    @Published private(set) var isSeededDemoContent: Bool = false

    /// Self-contained HTML bundle the live preview pane should render. For a
    /// React/Vite project this is the model-supplied Babel-standalone wrap of
    /// the components (since WKWebView can't run `vite dev`). For a plain
    /// `html` project this matches `currentCode`. nil → fall back to whatever
    /// `currentCode` is.
    @Published private(set) var previewHtml: String?
    /// What kind of project the user has open ("react-vite", "express",
    /// "fastapi", "html"). Used by the file tree + preview pane to render
    /// stack-aware affordances.
    @Published private(set) var stack: String = "html"

    /// In-flight Junie execution plan awaiting user confirmation. Surfaced to
    /// both the AR HUD overlay and the phone agent panel. Set by the codegen
    /// pipeline after `/api/plan`; cleared by `confirmPlan` / `cancelPlan`.
    @Published var pendingPlan: BackendClient.PlanPayload?
    /// True while `/api/plan` is in flight (used to show a HUD spinner).
    @Published var isPlanning: Bool = false
    /// Whether the latest plan was for a modification (vs a fresh generation).
    /// Determines which endpoint runs once the user confirms.
    @Published var pendingPlanIsModification: Bool = false

    /// Stack of (file, code) pairs pushed before each modification so undo can restore.
    private var history: [(file: String, code: String)] = []

    /// Per-file debounce timers so manual editor keystrokes don't flood the
    /// `/code-edits` collection — we only push a snapshot when the user pauses
    /// typing for `editRecordDebounce` seconds. Structural changes (apply,
    /// create, rename, delete) bypass this and push immediately.
    private var editRecordWorkItems: [String: DispatchWorkItem] = [:]
    /// Last content we POSTed for each file, so the next push can attach
    /// `previous_content` (lets a teammate diff against the prior snapshot).
    private var lastRecordedContent: [String: String] = [:]
    private let editRecordDebounce: TimeInterval = 1.2

    // MARK: - Terminal log (AR Junie panel)
    @Published private(set) var terminalLines: [TerminalLine] = []
    private let terminalCap: Int = 60

    // MARK: - Debug console (preview WebView output)
    @Published private(set) var consoleEntries: [ConsoleEntry] = []
    private let consoleCap: Int = 200

    // MARK: - Agent chat (phone-IDE Aether panel)
    @Published private(set) var chatMessages: [ChatMessage] = []

    // MARK: - GitHub
    @Published var gitHubToken: String {
        didSet { UserDefaults.standard.set(gitHubToken, forKey: Self.kGitHubToken) }
    }
    @Published var gitHubRepo: String {
        didSet { UserDefaults.standard.set(gitHubRepo, forKey: Self.kGitHubRepo) }
    }
    @Published var isGitHubConnected: Bool = false
    /// Cached blob SHAs per file path — needed for `PUT contents` to update a file.
    var gitHubFileShas: [String: String] = [:]
    /// Files that have unsaved/uncommitted changes since last GitHub pull or
    /// since first edit. Used to render the JetBrains modified-tab dot.
    @Published var modifiedFiles: Set<String> = []

    // MARK: - Backend
    @Published var backendURL: String {
        didSet {
            let d = UserDefaults.standard
            d.set(backendURL, forKey: Self.kBackendURL)
            // Lockstep the version so subsequent launches treat this as the
            // user's intentional override, not a stale pre-migration value.
            d.set(Self.currentBackendURLVersion, forKey: Self.kBackendURLVersion)
        }
    }
    /// When true, voice toggle is on so JARVIS speaks confirmations in AR mode.
    @Published var jarvisVoiceEnabled: Bool {
        didSet { UserDefaults.standard.set(jarvisVoiceEnabled, forKey: Self.kJarvisOn) }
    }
    @Published var isShowingArchitecture: Bool = false
    @Published var isShowingConnections: Bool = false
    @Published var isShowingReview: Bool = false
    @Published var isShowingDiff: Bool = false

    private static let kGitHubToken = "aether.github.token"
    private static let kGitHubRepo  = "aether.github.repo"
    private static let kBackendURL  = "aether.backend.url"
    private static let kJarvisOn    = "aether.jarvis.on"
    /// Bumped whenever `kDefaultBackendURL` changes. On launch, if the saved
    /// version doesn't match the current one, we drop any stale saved
    /// backend URL and re-adopt the new default so existing installs don't
    /// stay stuck on a previous host (localhost, ngrok) after a switch.
    private static let kBackendURLVersion = "aether.backend.url.version"
    private static let currentBackendURLVersion = 3

    /// Vercel-hosted FastAPI deploy. Permanent URL — no ngrok, no laptop on
    /// the network. Update this and bump `currentBackendURLVersion` if the
    /// production hostname ever changes; the version-bump forces existing
    /// installs to drop their stale UserDefaults override and re-adopt the
    /// new default.
    private static let kDefaultBackendURL = "https://backend-sepia-xi-43.vercel.app"

    init() {
        let d = UserDefaults.standard
        self.gitHubToken = d.string(forKey: Self.kGitHubToken) ?? ""
        self.gitHubRepo  = d.string(forKey: Self.kGitHubRepo) ?? ""
        // Backend URL: prefer saved value, but only if its version matches
        // the current default — otherwise migrate to the new default. This
        // catches installs that saved `http://localhost:8000` back when that
        // was the default and would otherwise stay stuck on it after we
        // switched the default to the ngrok tunnel.
        let savedVersion = d.integer(forKey: Self.kBackendURLVersion)
        if savedVersion == Self.currentBackendURLVersion,
           let saved = d.string(forKey: Self.kBackendURL), !saved.isEmpty {
            self.backendURL = saved
        } else {
            self.backendURL = Self.kDefaultBackendURL
            d.set(Self.kDefaultBackendURL, forKey: Self.kBackendURL)
            d.set(Self.currentBackendURLVersion, forKey: Self.kBackendURLVersion)
        }
        self.jarvisVoiceEnabled = d.object(forKey: Self.kJarvisOn) as? Bool ?? true
        seedStarterPageIfNeeded()
    }

    /// First-launch seed: drop the JetBrains-style ArcReact splash into
    /// `index.html` so the editor + preview have something to render. No-op if
    /// the user already has any code.
    func seedStarterPageIfNeeded() {
        guard !hasAnyCode else { return }
        // recordEdit:false — the splash is local-only demo scaffolding, no
        // value in syncing it to teammates.
        setCode(StarterPage.html, forFile: "index.html",
                pushHistory: false, recordEdit: false)
        // Mark AFTER setCode (which would clear it) so codegen routing knows
        // this buffer is the demo splash, not real user content.
        isSeededDemoContent = true
    }

    /// True iff the editor genuinely contains user code (not just the splash).
    /// Used by codegen dispatchers to pick generate vs modify.
    var hasUserCode: Bool {
        !currentCode.isEmpty && !isSeededDemoContent
    }

    // MARK: - Derived

    var currentCode: String {
        projectFiles[currentFile] ?? ""
    }

    var hasAnyCode: Bool {
        !projectFiles.values.allSatisfy { $0.isEmpty }
    }

    // MARK: - Files

    /// Push the current state onto history then write `code` for `file`. Use
    /// `pushHistory: false` for the first generation so undo doesn't restore an
    /// empty file. `recordEdit` controls whether the change gets pushed to the
    /// `/code-edits` mongo collection (false for the splash seed so the demo
    /// content doesn't pollute teammate sync).
    func setCode(_ code: String,
                 forFile file: String,
                 pushHistory: Bool,
                 recordEdit: Bool = true,
                 editType: String = "manual") {
        let previous = projectFiles[file]
        if pushHistory, let existing = projectFiles[currentFile] {
            history.append((currentFile, existing))
            if history.count > 30 { history.removeFirst(history.count - 30) }
        }
        projectFiles[file] = code
        currentFile = file
        ensureTabOpen(file)
        // Any setCode that isn't the splash seed itself promotes the buffer to
        // "real code", so codegen routing should treat further prompts as modify.
        if isSeededDemoContent {
            isSeededDemoContent = false
        }
        // Mark this file as modified for the tab dot (cleared by GitHub push).
        modifiedFiles.insert(file)

        if recordEdit && code != previous {
            scheduleRecordEdit(filename: file,
                               content: code,
                               previousContent: previous,
                               editType: editType,
                               description: nil,
                               debounce: editType == "manual")
        }
    }

    /// Clear the modified marker — call after a successful GitHub push of `file`.
    func markFileSynced(_ file: String) {
        modifiedFiles.remove(file)
    }

    /// Atomically install a multi-file project — the result of a Junie build
    /// or modify call. `replace: true` wipes the existing project (fresh
    /// generation), `replace: false` merges the returned files on top of the
    /// current ones (modification). Always sets `previewHtml` + `stack` so
    /// the preview pane and file tree can render stack-aware affordances.
    func applyProject(_ result: BackendClient.BuildResult,
                      replace: Bool, pushHistory: Bool) {
        if pushHistory {
            // Stash every file so undo can restore the prior project state.
            for (file, code) in projectFiles {
                history.append((file, code))
            }
            if history.count > 30 { history.removeFirst(history.count - 30) }
        }
        // Capture prior state per path so each /code-edits row can carry the
        // previous_content (lets the teammate diff against last snapshot).
        let prior = projectFiles
        let editType = replace ? "ai_generate" : "ai_modify"
        if replace {
            projectFiles.removeAll(keepingCapacity: true)
            openTabs.removeAll(keepingCapacity: true)
            modifiedFiles.removeAll(keepingCapacity: true)
            gitHubFileShas.removeAll(keepingCapacity: true)
        }
        for (path, content) in result.files {
            projectFiles[path] = content
            modifiedFiles.insert(path)
            if prior[path] != content {
                scheduleRecordEdit(filename: path,
                                   content: content,
                                   previousContent: prior[path],
                                   editType: editType,
                                   description: "stack=\(result.stack)",
                                   debounce: false)
            }
        }
        let primary = projectFiles[result.primary] != nil
            ? result.primary
            : (projectFiles.keys.sorted().first ?? "index.html")
        currentFile = primary
        ensureTabOpen(primary)
        previewHtml = result.previewHtml
        stack = result.stack
        if isSeededDemoContent { isSeededDemoContent = false }
    }

    /// Pop the latest history entry into projectFiles. Returns the (file, code) restored,
    /// or nil if history is empty.
    @discardableResult
    func undo() -> (file: String, code: String)? {
        guard let entry = history.popLast() else { return nil }
        projectFiles[entry.file] = entry.code
        currentFile = entry.file
        ensureTabOpen(entry.file)
        return entry
    }

    /// Create an empty file. If it already exists, do nothing.
    func createFile(_ name: String) {
        if projectFiles[name] == nil {
            projectFiles[name] = ""
            scheduleRecordEdit(filename: name,
                               content: "",
                               previousContent: nil,
                               editType: "create",
                               description: nil,
                               debounce: false)
        }
        ensureTabOpen(name)
    }

    /// Switch the active file. Adds it to openTabs if not already there.
    func switchTo(file: String) {
        guard projectFiles[file] != nil else { return }
        currentFile = file
        ensureTabOpen(file)
    }

    /// Rename a project file. No-op if `from` doesn't exist or `to` already does.
    func renameFile(from: String, to: String) {
        guard let code = projectFiles[from], projectFiles[to] == nil else { return }
        projectFiles.removeValue(forKey: from)
        projectFiles[to] = code
        if let idx = openTabs.firstIndex(of: from) { openTabs[idx] = to }
        if currentFile == from { currentFile = to }
        if modifiedFiles.contains(from) {
            modifiedFiles.remove(from)
            modifiedFiles.insert(to)
        }
        if let sha = gitHubFileShas[from] {
            gitHubFileShas.removeValue(forKey: from)
            gitHubFileShas[to] = sha
        }
        // Tombstone the old path + write the new path so a teammate replaying
        // edits ends up with the same file tree.
        scheduleRecordEdit(filename: from,
                           content: "",
                           previousContent: code,
                           editType: "rename",
                           description: "renamed to \(to)",
                           debounce: false)
        scheduleRecordEdit(filename: to,
                           content: code,
                           previousContent: nil,
                           editType: "rename",
                           description: "renamed from \(from)",
                           debounce: false)
    }

    /// Delete a project file and clean up tabs / shas / modified-set.
    func deleteFile(_ name: String) {
        let prior = projectFiles[name]
        projectFiles.removeValue(forKey: name)
        modifiedFiles.remove(name)
        gitHubFileShas.removeValue(forKey: name)
        if let idx = openTabs.firstIndex(of: name) {
            openTabs.remove(at: idx)
        }
        if currentFile == name {
            currentFile = openTabs.last ?? (projectFiles.keys.sorted().first ?? "index.html")
        }
        scheduleRecordEdit(filename: name,
                           content: "",
                           previousContent: prior,
                           editType: "delete",
                           description: nil,
                           debounce: false)
    }

    /// Close an editor tab. If it was the active tab, switch to the previous one.
    func closeTab(_ file: String) {
        guard let idx = openTabs.firstIndex(of: file) else { return }
        openTabs.remove(at: idx)
        if currentFile == file {
            currentFile = openTabs.last ?? (projectFiles.keys.sorted().first ?? "index.html")
        }
    }

    private func ensureTabOpen(_ file: String) {
        if !openTabs.contains(file) {
            openTabs.append(file)
        }
    }

    func setSelectedElement(_ info: ElementInfo?) {
        selectedElement = info
    }

    // MARK: - Terminal (AR)

    func appendTerminal(_ kind: TerminalLine.Kind, _ text: String) {
        terminalLines.append(TerminalLine(kind: kind, text: text))
        if terminalLines.count > terminalCap {
            terminalLines.removeFirst(terminalLines.count - terminalCap)
        }
    }

    /// Junie-style prefixes. Commands (user prompts) get a chevron; status
    /// lines get a sparkle; success/error stay as check/cross.
    func termCommand(_ text: String) { appendTerminal(.command, "> " + text) }
    func termOutput(_ text: String)  { appendTerminal(.output,  "  " + text) }
    func termSuccess(_ text: String) { appendTerminal(.success, "✓ " + text) }
    func termError(_ text: String)   { appendTerminal(.error,   "✗ " + text) }
    func termInfo(_ text: String)    { appendTerminal(.info,    "✦ " + text) }

    // MARK: - Debug console

    func appendConsole(_ level: ConsoleEntry.Level, _ text: String) {
        consoleEntries.append(ConsoleEntry(level: level, text: text, timestamp: Date()))
        if consoleEntries.count > consoleCap {
            consoleEntries.removeFirst(consoleEntries.count - consoleCap)
        }
    }

    func clearConsole() {
        consoleEntries.removeAll()
    }

    // MARK: - Chat (phone IDE)

    /// Append a new chat message and return its id so callers can later replace
    /// it (used for "thinking…" placeholders that get swapped with the real
    /// reply once the backend responds — replace-by-id avoids a race where
    /// concurrent prompts overwrite each other's placeholders).
    @discardableResult
    func appendChat(_ role: ChatMessage.Role, _ text: String) -> UUID {
        let msg = ChatMessage(role: role, text: text)
        chatMessages.append(msg)
        if chatMessages.count > 200 { chatMessages.removeFirst(chatMessages.count - 200) }
        return msg.id
    }

    /// Replace a specific message's text by id. No-op if the id isn't found.
    func replaceMessage(id: UUID, with text: String) {
        guard let idx = chatMessages.firstIndex(where: { $0.id == id }) else { return }
        chatMessages[idx].text = text
    }

    // MARK: - Edit recording (mongo /code-edits sync)

    /// Push an edit snapshot to the backend so a teammate can replay the
    /// stream. `debounce: true` is used for raw editor keystrokes — we wait
    /// `editRecordDebounce` seconds before posting so we don't flood the
    /// collection with one row per character. Structural changes (apply,
    /// create, rename, delete) pass `debounce: false` and post immediately.
    fileprivate func scheduleRecordEdit(filename: String,
                                        content: String,
                                        previousContent: String?,
                                        editType: String,
                                        description: String?,
                                        debounce: Bool) {
        let push = { [weak self] in
            guard let self = self else { return }
            let prevForPost = previousContent ?? self.lastRecordedContent[filename]
            self.lastRecordedContent[filename] = content
            BackendClient.shared.recordCodeEdit(
                filename: filename,
                content: content,
                previousContent: prevForPost,
                editType: editType,
                description: description,
                baseURL: self.backendURL
            )
        }

        if debounce {
            editRecordWorkItems[filename]?.cancel()
            let item = DispatchWorkItem(block: push)
            editRecordWorkItems[filename] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + editRecordDebounce, execute: item)
        } else {
            // Cancel any pending debounced push for this file so we don't
            // double-post a slightly-older snapshot right after a structural
            // change has already gone out.
            editRecordWorkItems[filename]?.cancel()
            editRecordWorkItems[filename] = nil
            push()
        }
    }
}
