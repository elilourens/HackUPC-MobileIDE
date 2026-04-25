import Foundation

/// Information about the HTML element the user has currently selected by pointing at the
/// preview panel. Used to scope the next Gemini modification to a single element.
struct ElementInfo: Equatable {
    let tag: String
    let id: String
    let className: String
    let text: String

    var humanLabel: String {
        // For the floating AR text label above the preview panel.
        let lower = tag.lowercased()
        if !id.isEmpty { return "<\(lower)#\(id)>" }
        if !className.isEmpty {
            // Show only the first class so the label stays short.
            let first = className.split(separator: " ").first.map(String.init) ?? className
            return "<\(lower).\(first)>"
        }
        return "<\(lower)>"
    }
}

/// One terminal line. Color is decided at draw time from the kind.
struct TerminalLine: Equatable {
    enum Kind { case command, output, success, error, info }
    let kind: Kind
    let text: String
}

/// Holds the live IDE state — current code, files, undo history, selected element,
/// and a rolling terminal log. Single source of truth for everything Phase 2 renders.
@MainActor
final class ProjectSession {
    private(set) var currentFile: String = "index.html"
    private(set) var projectFiles: [String: String] = [:]
    private(set) var selectedElement: ElementInfo?
    var isGenerating: Bool = false

    /// Stack of (file, code) pairs pushed before each modification so undo can restore.
    private var history: [(file: String, code: String)] = []

    /// Rolling terminal log (most recent at the end). Capped to 60 entries to keep
    /// texture regen cheap.
    private(set) var terminalLines: [TerminalLine] = []
    private let terminalCap: Int = 60

    /// Code for the currently active file, or "" if it doesn't exist yet.
    var currentCode: String {
        projectFiles[currentFile] ?? ""
    }

    var hasAnyCode: Bool {
        !projectFiles.values.allSatisfy { $0.isEmpty }
    }

    /// Push the current state onto history then write `code` for `file`. Use
    /// `pushHistory: false` for the very first generation so undo doesn't restore an
    /// empty file.
    func setCode(_ code: String, forFile file: String, pushHistory: Bool) {
        if pushHistory, let existing = projectFiles[currentFile] {
            history.append((currentFile, existing))
            if history.count > 30 { history.removeFirst(history.count - 30) }
        }
        projectFiles[file] = code
        currentFile = file
    }

    /// Pop the latest history entry into projectFiles. Returns the (file, code) restored,
    /// or nil if history is empty.
    @discardableResult
    func undo() -> (file: String, code: String)? {
        guard let entry = history.popLast() else { return nil }
        projectFiles[entry.file] = entry.code
        currentFile = entry.file
        return entry
    }

    /// Create an empty file. If it already exists, do nothing.
    func createFile(_ name: String) {
        if projectFiles[name] == nil {
            projectFiles[name] = ""
        }
    }

    /// Switch the active file. No-op if the file doesn't exist.
    func switchTo(file: String) {
        guard projectFiles[file] != nil else { return }
        currentFile = file
    }

    func setSelectedElement(_ info: ElementInfo?) {
        selectedElement = info
    }

    // MARK: - Terminal

    func appendTerminal(_ kind: TerminalLine.Kind, _ text: String) {
        terminalLines.append(TerminalLine(kind: kind, text: text))
        if terminalLines.count > terminalCap {
            terminalLines.removeFirst(terminalLines.count - terminalCap)
        }
    }

    /// Convenience: prefix-aware constructors for the four common kinds the spec
    /// describes ("$ ...", "✓ ...", "✗ ...", plain output).
    func termCommand(_ text: String) { appendTerminal(.command, "$ " + text) }
    func termOutput(_ text: String) { appendTerminal(.output, "  " + text) }
    func termSuccess(_ text: String) { appendTerminal(.success, "✓ " + text) }
    func termError(_ text: String) { appendTerminal(.error, "✗ " + text) }
    func termInfo(_ text: String) { appendTerminal(.info, text) }
}
