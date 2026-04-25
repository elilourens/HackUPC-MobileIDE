import Foundation
import Speech
import AVFoundation
import Combine

enum VoiceTarget: Equatable {
    case all, git, errors, stats, preview, docs, terminal, architecture, dependencies, terry
}

enum VoiceCommand: Equatable {
    case showGit
    case showErrors
    case showStats
    case showPreview
    case showDocs
    case showTerminal
    case showArchitecture
    case showDependencies
    case showTerry
    case hide(VoiceTarget)
    case clear
    case focusMode
    case unfocusMode
    case darkMode
    case lightMode
    case createFunction(name: String)
    case ask(String)

    // Phase 2 — live IDE
    /// Generate or modify code from a natural-language utterance. The dispatcher
    /// (ARSessionManager) decides whether this is a fresh generation or a
    /// modification based on whether currentCode is empty.
    case codegen(String)
    /// User said "yes / confirm / go ahead" — proceed with the pending Junie plan.
    case confirm
    /// User said "no / cancel / stop" — discard the pending Junie plan.
    case cancel
    /// Arm element-selection mode — the next preview-pointing tap selects an element.
    case selectElement
    /// Clear the currently selected element.
    case deselectElement
    /// Revert to the previous code state.
    case undo
    /// Create an empty file in the project tree.
    case newFile(String)
    /// Re-render the preview from current code.
    case runPreview
    /// Save (demo no-op — JARVIS just acknowledges).
    case save
}

@MainActor
final class VoiceManager: ObservableObject {
    @Published var transcript: String = ""
    @Published var isAuthorized: Bool = false
    @Published var isListening: Bool = false
    /// True while the user is holding the push-to-talk button. Used by the HUD to
    /// flash a "listening" indicator and by the parser to gate command firing.
    @Published var isPushToTalkActive: Bool = false
    @Published var lastUtterance: String = ""

    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var idleTimer: Timer?

    private var onTranscript: ((String) -> Void)?
    private var onIdle: (() -> Void)?
    private var onCommand: ((VoiceCommand) -> Void)?
    private var lastTranscriptUpdate: Date = .distantPast
    private(set) var commandFiredThisChain: Bool = false

    // Per-session push-to-talk: each press creates a fresh recognition task so the
    // transcript can never carry text from a previous press.
    private var pttBeginAt: TimeInterval = 0
    private var endPttWorkItem: DispatchWorkItem?

    func startListening(onTranscript: @escaping (String) -> Void = { _ in },
                        onIdle: @escaping () -> Void = {},
                        onCommand: @escaping (VoiceCommand) -> Void = { _ in }) {
        self.onTranscript = onTranscript
        self.onIdle = onIdle
        self.onCommand = onCommand
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isAuthorized = (status == .authorized)
                guard self.isAuthorized else { return }
                self.requestRecordPermission { granted in
                    if granted { self.beginAudioPipeline() }
                }
            }
        }
    }

    private func requestRecordPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        idleTimer?.invalidate()
        idleTimer = nil
        isListening = false
    }

    /// Configures the audio session + engine + mic tap. The tap appends buffers to
    /// `self.request`, which is nil until a push-to-talk press creates one. So no
    /// recognition happens until the user explicitly initiates it.
    private func beginAudioPipeline() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .default + .defaultToSpeaker so JARVIS TTS plays through the loudspeaker
            // while we keep recording. .measurement mode would route to the receiver
            // and make JARVIS inaudible.
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .mixWithOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("VoiceManager: audio session setup failed: \(error.localizedDescription)")
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Feed whatever request is currently active. nil during idle = drop buffers.
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("VoiceManager: audio engine start failed: \(error.localizedDescription)")
            return
        }
        isListening = true
    }

    /// Boost recognition of our command vocabulary. Same list every PTT session.
    private static let commandHints: [String] = [
        "show", "hide", "close", "open", "dismiss", "clear", "bring up", "pull up",
        "preview", "git", "errors", "stats", "performance", "diagnostics",
        "terminal", "console", "docs", "documentation",
        "architecture", "graph", "dependencies", "packages",
        "terry", "JARVIS",
        "focus mode", "normal mode", "dark mode", "light mode",
        "create a function", "everything"
    ]

    // MARK: - Push-to-talk

    /// Begin a fresh push-to-talk session. Cancels any pending end-of-session timer
    /// and any leftover recognition task, resets the transcript to empty, and creates
    /// a brand-new SFSpeechAudioBufferRecognitionRequest so the next utterance starts
    /// from a clean slate. This is what fixes the "holding onto last saved text" bug.
    func beginPushToTalk() {
        // If a previous endPushToTalk is still pending its 0.5s settle delay,
        // cancel it — the user is starting a new utterance.
        endPttWorkItem?.cancel()
        endPttWorkItem = nil

        // Tear down any leftover task / request from a previous session.
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil

        guard let recognizer = recognizer, recognizer.isAvailable else { return }

        // Fresh request for this session.
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.taskHint = .search
        r.contextualStrings = VoiceManager.commandHints
        request = r

        // Fresh recognition task. Updates `transcript` as audio comes in.
        task = recognizer.recognitionTask(with: r) { [weak self] result, _ in
            guard let self = self, let result = result else { return }
            let text = result.bestTranscription.formattedString
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.transcript = text
                self.lastTranscriptUpdate = Date()
                self.onTranscript?(text)
            }
        }

        // Clear the transcript display now that we have a fresh task.
        transcript = ""
        pttBeginAt = CACurrentMediaTime()
        isPushToTalkActive = true
    }

    /// End the current push-to-talk session: signal endAudio so the recognizer
    /// finalizes trailing words, wait briefly, then parse the resulting transcript
    /// and dispose of the task.
    func endPushToTalk() {
        guard isPushToTalkActive else { return }
        isPushToTalkActive = false

        // Tell the recognizer no more audio is coming; it'll emit a final result.
        request?.endAudio()

        // Schedule the parse after ~0.6s so trailing-word finalization has a chance.
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let final = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                self.lastUtterance = final

                // Tear down task + request — next press starts a brand-new pair.
                self.task?.cancel()
                self.task = nil
                self.request = nil
                // Clear the live transcript so the HUD doesn't keep showing it.
                self.transcript = ""

                if !final.isEmpty, let command = VoiceManager.parse(final) {
                    self.commandFiredThisChain = true
                    self.onCommand?(command)
                }
            }
        }
        endPttWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    /// Cancels an in-progress push-to-talk without firing. Used for explicit
    /// cancellation (none right now, but reserved).
    func cancelPushToTalk() {
        isPushToTalkActive = false
        endPttWorkItem?.cancel()
        endPttWorkItem = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        transcript = ""
    }

    // MARK: - Command parsing

    private enum ActionType { case show, hide }

    /// Action keywords. Includes common mishearings (the recognizer often returns "hides"/"hidden"
    /// for a sharp "hide", or "shows"/"showed" for "show").
    private static let showActions: Set<String> = [
        "show", "shows", "open", "opens", "bring", "pull", "display", "summon", "view"
    ]
    private static let hideActions: Set<String> = [
        "hide", "hides", "hidden", "close", "closes", "dismiss", "remove", "stop", "kill"
    ]

    /// Each entry: keywords that imply this target → which target/show-command to fire.
    private static let targetMap: [(keywords: Set<String>, target: VoiceTarget, show: VoiceCommand)] = [
        (["git", "commit", "commits", "history"],                   .git,           .showGit),
        (["error", "errors", "issue", "issues", "bug", "bugs", "problem", "problems"], .errors, .showErrors),
        (["stat", "stats", "performance", "diagnostic", "diagnostics"], .stats,     .showStats),
        (["preview", "browser"],                                    .preview,       .showPreview),
        (["doc", "docs", "documentation"],                          .docs,          .showDocs),
        (["terminal", "console", "shell"],                          .terminal,      .showTerminal),
        (["architecture", "graph"],                                 .architecture,  .showArchitecture),
        (["dependencies", "dependency", "packages", "deps"],        .dependencies,  .showDependencies),
        (["terry"],                                                 .terry,         .showTerry),
    ]

    /// Token-based parser. Finds the LAST target keyword in the utterance, then walks
    /// backward up to 6 words to find the most recent action keyword. This keeps
    /// "show preview hide preview" resolving to `.hide(.preview)` (the latest action+target
    /// pair wins) instead of always matching `.contains("show")` first.
    static func parse(_ rawText: String) -> VoiceCommand? {
        let lower = rawText.lowercased()
        guard !lower.isEmpty else { return nil }

        // ----- Phase 2 single-purpose commands (must run BEFORE show/hide so e.g.
        //       "save" doesn't fall through to a target lookup that finds nothing).

        // CONFIRM / CANCEL — used to greenlight or kill a pending Junie plan
        // before any code is written. Must run before generic codegen fallback
        // so "yes" / "no" don't get parsed as natural-language prompts.
        if lower == "yes" || lower == "yeah" || lower == "yep"
            || lower == "confirm" || lower == "confirmed"
            || lower == "go" || lower == "go ahead" || lower == "do it"
            || lower == "build it" || lower == "ship it" || lower == "approved" {
            return .confirm
        }
        if lower == "no" || lower == "nope" || lower == "cancel"
            || lower == "stop" || lower == "abort" || lower == "discard"
            || lower == "never mind" || lower == "scratch that" {
            return .cancel
        }

        // SELECT / DESELECT
        if lower == "select" || lower == "selected" || lower.hasSuffix(" select this")
            || lower == "select this" {
            return .selectElement
        }
        if lower == "deselect" || lower == "unselect" || lower == "clear selection" {
            return .deselectElement
        }

        // UNDO
        if lower == "undo" || lower.hasSuffix(" undo") || lower == "go back"
            || lower == "revert" {
            return .undo
        }

        // RUN
        if lower == "run" || lower == "run it" || lower == "run preview"
            || lower == "execute" {
            return .runPreview
        }

        // SAVE
        if lower == "save" || lower == "save it" || lower == "save file"
            || lower == "save the file" {
            return .save
        }

        // NEW FILE
        if let name = extractNewFileName(from: lower) {
            return .newFile(name)
        }

        // ----- Single-purpose patterns first -----

        // CLEAR
        if lower == "clear" || lower.hasSuffix(" clear")
            || lower.contains("clear workspace") || lower.contains("clear everything") {
            return .clear
        }

        // FOCUS / UNFOCUS
        if lower.contains("unfocus") || lower.contains("normal mode")
            || lower.contains("normal view") || lower.contains("exit focus") {
            return .unfocusMode
        }
        if lower.contains("focus mode") || lower.contains("focus on") || lower.hasSuffix(" focus") {
            return .focusMode
        }

        // THEME
        if lower.contains("dark mode") || lower.contains("go dark") { return .darkMode }
        if lower.contains("light mode") || lower.contains("go light") { return .lightMode }

        // CREATE FUNCTION (very loose detection)
        if let name = extractFunctionName(from: lower) {
            return .createFunction(name: name)
        }

        // ----- Token-based show/hide -----

        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return nil }

        // 1) Find the LAST target keyword position (scan from the end).
        var targetIndex: Int?
        var matchedTarget: VoiceTarget?
        var matchedShowCommand: VoiceCommand?
        for i in stride(from: words.count - 1, through: 0, by: -1) {
            let w = words[i]
            for entry in targetMap {
                if entry.keywords.contains(w) {
                    targetIndex = i
                    matchedTarget = entry.target
                    matchedShowCommand = entry.show
                    break
                }
            }
            if targetIndex != nil { break }
        }

        // Special "all/everything" target (only valid for hide)
        var sawAllTarget = false
        if targetIndex == nil {
            for i in stride(from: words.count - 1, through: 0, by: -1) {
                if words[i] == "everything" || words[i] == "all" {
                    targetIndex = i
                    sawAllTarget = true
                    break
                }
            }
        }

        guard let ti = targetIndex else {
            // No target word — try wake-word question, then fall through to codegen.
            if let q = parseWakeWordQuestion(rawText: rawText, lower: lower) { return q }
            return codegenFallback(rawText: rawText, lower: lower)
        }

        // 2) Look back from ti-1 up to 6 words for the most recent action keyword.
        let lookback = max(0, ti - 6)
        var action: ActionType?
        for i in stride(from: ti - 1, through: lookback, by: -1) {
            let w = words[i]
            if showActions.contains(w) { action = .show; break }
            if hideActions.contains(w) { action = .hide; break }
        }

        // Fallback: maybe the action came AFTER the target — uncommon but happens with
        // partials like "preview show". Look forward up to 4 words too.
        if action == nil {
            let forwardLimit = min(words.count - 1, ti + 4)
            if ti + 1 <= forwardLimit {
                for i in (ti + 1)...forwardLimit {
                    let w = words[i]
                    if showActions.contains(w) { action = .show; break }
                    if hideActions.contains(w) { action = .hide; break }
                }
            }
        }

        guard let action = action else {
            if let q = parseWakeWordQuestion(rawText: rawText, lower: lower) { return q }
            return codegenFallback(rawText: rawText, lower: lower)
        }

        switch action {
        case .hide:
            return .hide(matchedTarget ?? .all)
        case .show:
            // Show needs a real target (.all isn't a show target)
            if sawAllTarget { return nil }
            return matchedShowCommand
        }
    }

    private static func parseWakeWordQuestion(rawText: String, lower: String) -> VoiceCommand? {
        let wakePrefixes = ["hey jarvis", "jarvis,", "jarvis "]
        if let stripped = wakePrefixes.first(where: { lower.hasPrefix($0) }) {
            let trimmed = String(rawText.dropFirst(stripped.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return .ask(trimmed) }
        }
        return nil
    }

    /// Phase 2 catch-all. Any utterance with at least 3 letters that didn't match a
    /// known command is treated as a Gemini codegen / modify request. Below 3 letters
    /// is almost always a misfire ("uh", "ok", "no") and we drop it.
    private static func codegenFallback(rawText: String, lower: String) -> VoiceCommand? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 3 else { return nil }
        return .codegen(trimmed)
    }

    /// Detect "new file <name>" / "create a new file called <name>" patterns.
    private static func extractNewFileName(from lower: String) -> String? {
        let triggers = [
            "new file ",
            "create a new file called ",
            "create a new file named ",
            "create a file called ",
            "create a file named ",
            "make a new file called ",
            "add a new file called "
        ]
        for trigger in triggers {
            if let range = lower.range(of: trigger) {
                let suffix = lower[range.upperBound...]
                let name = suffix.split(whereSeparator: { c in
                    !c.isLetter && !c.isNumber && c != "." && c != "_" && c != "-"
                }).first.map(String.init)
                if let name = name, !name.isEmpty { return name }
            }
        }
        return nil
    }

    private static func extractFunctionName(from lower: String) -> String? {
        let triggers = ["create a function called ", "create function called ", "make a function called ",
                        "add a function called ", "create a function named ", "make a function named "]
        for trigger in triggers {
            if let range = lower.range(of: trigger) {
                let suffix = lower[range.upperBound...]
                let firstWord = suffix.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).first
                if let word = firstWord, !word.isEmpty {
                    return String(word)
                }
            }
        }
        return nil
    }

}
