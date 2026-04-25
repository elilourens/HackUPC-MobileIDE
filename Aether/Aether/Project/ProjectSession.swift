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

    // MARK: - Terminal log (AR Junie panel)
    @Published private(set) var terminalLines: [TerminalLine] = []
    private let terminalCap: Int = 60

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
        didSet { UserDefaults.standard.set(backendURL, forKey: Self.kBackendURL) }
    }
    /// When true, voice toggle is on so JARVIS speaks confirmations in AR mode.
    @Published var jarvisVoiceEnabled: Bool {
        didSet { UserDefaults.standard.set(jarvisVoiceEnabled, forKey: Self.kJarvisOn) }
    }

    private static let kGitHubToken = "aether.github.token"
    private static let kGitHubRepo  = "aether.github.repo"
    private static let kBackendURL  = "aether.backend.url"
    private static let kJarvisOn    = "aether.jarvis.on"

    init() {
        let d = UserDefaults.standard
        self.gitHubToken = d.string(forKey: Self.kGitHubToken) ?? ""
        self.gitHubRepo  = d.string(forKey: Self.kGitHubRepo) ?? ""
        self.backendURL  = d.string(forKey: Self.kBackendURL) ?? "http://localhost:8000"
        self.jarvisVoiceEnabled = d.object(forKey: Self.kJarvisOn) as? Bool ?? true
        seedStarterPageIfNeeded()
    }

    /// First-launch seed: drop the JetBrains-style ArcReact splash into
    /// `index.html` so the editor + preview have something to render. No-op if
    /// the user already has any code.
    func seedStarterPageIfNeeded() {
        guard !hasAnyCode else { return }
        setCode(StarterPage.html, forFile: "index.html", pushHistory: false)
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
    /// empty file.
    func setCode(_ code: String, forFile file: String, pushHistory: Bool) {
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
    }

    /// Clear the modified marker — call after a successful GitHub push of `file`.
    func markFileSynced(_ file: String) {
        modifiedFiles.remove(file)
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
    }

    /// Delete a project file and clean up tabs / shas / modified-set.
    func deleteFile(_ name: String) {
        projectFiles.removeValue(forKey: name)
        modifiedFiles.remove(name)
        gitHubFileShas.removeValue(forKey: name)
        if let idx = openTabs.firstIndex(of: name) {
            openTabs.remove(at: idx)
        }
        if currentFile == name {
            currentFile = openTabs.last ?? (projectFiles.keys.sorted().first ?? "index.html")
        }
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
}
