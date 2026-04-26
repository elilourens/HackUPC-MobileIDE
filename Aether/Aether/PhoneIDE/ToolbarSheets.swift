import SwiftUI

/// "Find in Project" sheet — toolbar magnifying-glass action. Scans every
/// file in `session.projectFiles` for the query string and surfaces matches
/// as `path:line — snippet` rows. Tapping a row opens that file in the
/// editor and dismisses the sheet.
struct FindInProjectSheet: View {
    @ObservedObject var session: ProjectSession
    @Binding var isShown: Bool

    @State private var query: String = ""
    @State private var matches: [Match] = []
    @FocusState private var queryFocused: Bool

    struct Match: Identifiable {
        let id = UUID()
        let file: String
        let line: Int
        let snippet: String
    }

    var body: some View {
        NavigationView {
            ZStack {
                IJ.bgMain.ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundColor(IJ.textSecondary)
                        TextField("Find in project…", text: $query)
                            .focused($queryFocused)
                            .foregroundColor(IJ.textPrimary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: query) { _ in runSearch() }
                            .onSubmit { runSearch() }
                        if !query.isEmpty {
                            Button(action: { query = ""; matches = [] }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(IJ.textDisabled)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(IJ.bgEditor)
                    .overlay(Rectangle().fill(IJ.border).frame(height: 1), alignment: .bottom)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(matches) { m in
                                Button(action: { open(m) }) {
                                    matchRow(m)
                                }
                                .buttonStyle(.plain)
                            }
                            if matches.isEmpty && !query.isEmpty {
                                Text("No matches in \(session.projectFiles.count) files.")
                                    .font(.system(size: 12))
                                    .foregroundColor(IJ.textSecondary)
                                    .padding(20)
                            }
                            if query.isEmpty {
                                Text("Type to search across every file in the project.")
                                    .font(.system(size: 12))
                                    .foregroundColor(IJ.textSecondary)
                                    .padding(20)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Find in Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isShown = false }
                        .foregroundColor(IJ.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    if !matches.isEmpty {
                        Text("\(matches.count) hits")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(IJ.textSecondary)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { queryFocused = true }
    }

    @ViewBuilder
    private func matchRow(_ m: Match) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(JBIconLoader.fileTypeAsset(for: m.file))
                    .resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
                    .frame(width: 11, height: 11)
                Text(m.file)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(IJ.textPrimary)
                Text(":\(m.line)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(IJ.accentBlue)
                Spacer()
            }
            Text(m.snippet)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(IJ.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(IJ.borderSubtle).frame(height: 1), alignment: .bottom)
    }

    /// Walk every file line-by-line. Capped at 200 hits so a "of"-style query
    /// in a fat project doesn't lock up the sheet.
    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { matches = []; return }
        let needle = q.lowercased()
        var results: [Match] = []
        for file in session.projectFiles.keys.sorted() {
            guard let content = session.projectFiles[file] else { continue }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() {
                if line.lowercased().contains(needle) {
                    let snippet = String(line).trimmingCharacters(in: .whitespaces)
                    results.append(Match(file: file, line: i + 1, snippet: snippet))
                    if results.count >= 200 { break }
                }
            }
            if results.count >= 200 { break }
        }
        matches = results
    }

    private func open(_ m: Match) {
        session.switchTo(file: m.file)
        isShown = false
    }
}

/// "Debug Console" sheet — toolbar bug-icon action. Tails
/// `session.consoleEntries`, which is fed by the JS shim injected into the
/// preview WKWebView. Renders one row per entry with a colored level chip
/// (LOG / INFO / WARN / ERROR / DEBUG) and the captured message.
struct DebugConsoleSheet: View {
    @ObservedObject var session: ProjectSession
    @Binding var isShown: Bool

    @State private var levelFilter: ConsoleEntry.Level? = nil

    var body: some View {
        NavigationView {
            ZStack {
                IJ.bgMain.ignoresSafeArea()
                VStack(spacing: 0) {
                    filterStrip
                    Divider().background(IJ.border)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(filteredEntries) { entry in
                                    consoleRow(entry)
                                        .id(entry.id)
                                }
                                if filteredEntries.isEmpty {
                                    Text(session.consoleEntries.isEmpty
                                         ? "No console output yet — Run the preview to see logs and errors here."
                                         : "No \(levelFilter?.rawValue ?? "") messages.")
                                        .font(.system(size: 12))
                                        .foregroundColor(IJ.textSecondary)
                                        .padding(20)
                                }
                            }
                        }
                        .onChange(of: session.consoleEntries.count) { _ in
                            // Auto-scroll to the latest line when new output arrives.
                            if let lastID = session.consoleEntries.last?.id {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    proxy.scrollTo(lastID, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Debug Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isShown = false }
                        .foregroundColor(IJ.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clear") { session.clearConsole() }
                        .foregroundColor(IJ.accentRed)
                        .disabled(session.consoleEntries.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var filterStrip: some View {
        HStack(spacing: 8) {
            filterChip(label: "ALL", level: nil)
            filterChip(label: "LOG", level: .log)
            filterChip(label: "WARN", level: .warn)
            filterChip(label: "ERROR", level: .error)
            Spacer()
            Text(countLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(IJ.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(IJ.bgEditor)
    }

    private func filterChip(label: String, level: ConsoleEntry.Level?) -> some View {
        let active = (levelFilter == level)
        return Button(action: { levelFilter = level }) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(active ? .white : IJ.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(active ? IJ.accentBlue : IJ.bgSelected)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func consoleRow(_ entry: ConsoleEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.level.shortLabel)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(entry.level.color)
                .frame(width: 36, alignment: .leading)
                .padding(.top, 1)
            Text(entry.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(IJ.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(entry.level == .error ? Color.red.opacity(0.07) : Color.clear)
        .overlay(Rectangle().fill(IJ.borderSubtle).frame(height: 1), alignment: .bottom)
    }

    private var filteredEntries: [ConsoleEntry] {
        guard let f = levelFilter else { return session.consoleEntries }
        return session.consoleEntries.filter { $0.level == f }
    }

    private var countLabel: String {
        let total = session.consoleEntries.count
        let errors = session.consoleEntries.filter { $0.level == .error }.count
        let warns = session.consoleEntries.filter { $0.level == .warn }.count
        return "\(total) · \(errors) err · \(warns) warn"
    }
}

private extension ConsoleEntry.Level {
    var shortLabel: String {
        switch self {
        case .log:   return "LOG"
        case .info:  return "INFO"
        case .warn:  return "WARN"
        case .error: return "ERROR"
        case .debug: return "DEBUG"
        }
    }

    var color: Color {
        switch self {
        case .log:   return IJ.textSecondary
        case .info:  return IJ.accentBlue
        case .warn:  return IJ.accentOrange
        case .error: return IJ.accentRed
        case .debug: return IJ.textDisabled
        }
    }
}

// MARK: - Structure / Git / Bookmarks tool windows

/// "Structure" tool window — outline of the symbols (functions, components,
/// React hooks, classes, JSX top-level tags) defined in the active file.
/// Tapping a row jumps the editor cursor to that line.
struct StructureSheet: View {
    @ObservedObject var session: ProjectSession
    @Binding var isShown: Bool

    struct Symbol: Identifiable {
        let id = UUID()
        let kind: Kind
        let name: String
        let line: Int
        enum Kind { case function, component, hookCall, klass, constant, jsxTag }
    }

    var body: some View {
        NavigationView {
            ZStack {
                IJ.bgMain.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerBar
                    Divider().background(IJ.border)
                    if symbols.isEmpty {
                        Spacer()
                        Text("No symbols detected in \(session.currentFile).")
                            .font(.system(size: 12))
                            .foregroundColor(IJ.textSecondary)
                            .padding(24)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(symbols) { sym in symbolRow(sym) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Structure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isShown = false }.foregroundColor(IJ.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 11)).foregroundColor(IJ.textSecondary)
            Text(session.currentFile)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(IJ.textPrimary)
            Spacer()
            Text("\(symbols.count) symbol\(symbols.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundColor(IJ.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(IJ.bgSidebar)
    }

    private func symbolRow(_ sym: Symbol) -> some View {
        Button(action: { isShown = false }) {
            HStack(spacing: 10) {
                kindGlyph(sym.kind)
                Text(sym.name)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(IJ.textPrimary)
                Spacer()
                Text(":\(sym.line)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(IJ.textSecondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().fill(IJ.borderSubtle).frame(height: 1), alignment: .bottom)
        }
    }

    private func kindGlyph(_ kind: Symbol.Kind) -> some View {
        let (label, color): (String, Color) = {
            switch kind {
            case .function:  return ("ƒ", IJ.accentBlue)
            case .component: return ("⬡", IJ.accentGreen)
            case .hookCall:  return ("∾", IJ.accentOrange)
            case .klass:     return ("C", IJ.accentRed)
            case .constant:  return ("π", IJ.textSecondary)
            case .jsxTag:    return ("<>", IJ.accentBlue)
            }
        }()
        return Text(label)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.12)))
    }

    /// Cheap regex-free scan: walks each line of the active file and pulls
    /// out anything that looks like a top-level declaration. Good enough for
    /// the demo IDE — not a real AST, but reads the way a structure tool
    /// window should.
    private var symbols: [Symbol] {
        let code = session.currentCode
        guard !code.isEmpty else { return [] }
        var out: [Symbol] = []
        for (idx, raw) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineNo = idx + 1

            // function Foo(...) { ... }
            if let name = capture(after: "function ", in: trimmed,
                                  stopAt: ["(", " ", "<"]) {
                let kind: Symbol.Kind =
                    name.first?.isUppercase == true ? .component : .function
                out.append(Symbol(kind: kind, name: name, line: lineNo))
                continue
            }
            // const Foo = (...) => / const foo = ...
            if trimmed.hasPrefix("const ") || trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") {
                let body = trimmed
                    .replacingOccurrences(of: "const ", with: "")
                    .replacingOccurrences(of: "let ", with: "")
                    .replacingOccurrences(of: "var ", with: "")
                if let eq = body.firstIndex(of: "=") {
                    let name = body[..<eq].trimmingCharacters(in: .whitespaces)
                    let rhs = body[body.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    let isComponent = rhs.contains("=>") &&
                        (rhs.contains("<") || name.first?.isUppercase == true)
                    let isHook = name.hasPrefix("use") && name.count > 3
                    let nm = String(name.split(separator: ":").first ?? Substring(name))
                        .trimmingCharacters(in: .whitespaces)
                    if !nm.isEmpty {
                        let kind: Symbol.Kind = isComponent ? .component
                            : isHook ? .hookCall : .constant
                        out.append(Symbol(kind: kind, name: nm, line: lineNo))
                    }
                    continue
                }
            }
            // class Foo
            if let name = capture(after: "class ", in: trimmed,
                                  stopAt: [" ", "{", "<"]) {
                out.append(Symbol(kind: .klass, name: name, line: lineNo))
                continue
            }
            // export default function Foo
            if trimmed.hasPrefix("export default function "),
               let name = capture(after: "export default function ", in: trimmed,
                                  stopAt: ["(", " ", "<"]) {
                out.append(Symbol(kind: .component, name: name, line: lineNo))
                continue
            }
        }
        return out
    }

    private func capture(after prefix: String, in text: String,
                         stopAt stops: [Character]) -> String? {
        guard let r = text.range(of: prefix), r.lowerBound == text.startIndex else {
            return nil
        }
        let rest = text[r.upperBound...]
        var name = ""
        for ch in rest {
            if stops.contains(ch) { break }
            name.append(ch)
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// "Git" tool window — recent commit-shaped list backed by the project's
/// modifiedFiles + chat history. Stub for the hackathon demo: shows the
/// connected repo, modified files (uncommitted), and a mock commit log.
struct GitToolSheet: View {
    @ObservedObject var session: ProjectSession
    @Binding var isShown: Bool

    var body: some View {
        NavigationView {
            ZStack {
                IJ.bgMain.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("REPOSITORY")
                        repoCard
                        sectionHeader("UNCOMMITTED · \(session.modifiedFiles.count)")
                        if session.modifiedFiles.isEmpty {
                            Text("Working tree is clean.")
                                .font(.system(size: 12))
                                .foregroundColor(IJ.textSecondary)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                        } else {
                            ForEach(Array(session.modifiedFiles).sorted(), id: \.self) { file in
                                modifiedFileRow(file)
                            }
                        }
                        sectionHeader("RECENT COMMITS")
                        ForEach(mockCommits) { commit in commitRow(commit) }
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Git")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isShown = false }.foregroundColor(IJ.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.2)
            .foregroundColor(IJ.textSecondary)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
    }

    private var repoCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "tag")
                .font(.system(size: 11))
                .foregroundColor(IJ.accentGreen)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.gitHubRepo.isEmpty ? "No repo connected" : session.gitHubRepo)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(IJ.textPrimary)
                Text(session.gitHubRepo.isEmpty
                     ? "Connect a GitHub repo from Settings to enable push/pull."
                     : "branch · main")
                    .font(.system(size: 11))
                    .foregroundColor(IJ.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(IJ.bgSidebar)
        .overlay(Rectangle().fill(IJ.borderSubtle).frame(height: 1), alignment: .bottom)
    }

    private func modifiedFileRow(_ file: String) -> some View {
        HStack(spacing: 10) {
            Text("M")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(IJ.accentOrange)
                .frame(width: 18)
            Text(file)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(IJ.textPrimary)
            Spacer()
            Text("uncommitted")
                .font(.system(size: 11))
                .foregroundColor(IJ.textSecondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(Rectangle().fill(IJ.borderSubtle).frame(height: 1), alignment: .bottom)
    }

    private struct Commit: Identifiable {
        let id = UUID()
        let sha: String
        let message: String
        let author: String
        let when: String
    }

    private var mockCommits: [Commit] {
        [
            Commit(sha: "30e1b44", message: "feat(ar): daddy's home Iron-Man easter egg", author: "Akshat",   when: "just now"),
            Commit(sha: "3b01db9", message: "feat(ar): live error detection + AI code review", author: "Akshat", when: "2h"),
            Commit(sha: "25c7468", message: "chore(vercel): switch to main.py FastAPI entrypoint", author: "Akshat", when: "3h"),
            Commit(sha: "d476c6a", message: "feat: implement git diff view + collab cursor", author: "Akshat",  when: "5h"),
            Commit(sha: "c7a40f7", message: "fix(preview): suppress 'Script error' in WKWebView",  author: "Akshat", when: "6h"),
            Commit(sha: "81b8145", message: "feat(ar): architecture diagram + connection lines",   author: "Akshat", when: "8h"),
        ]
    }

    private func commitRow(_ c: Commit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(IJ.accentGreen).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.message)
                    .font(.system(size: 13))
                    .foregroundColor(IJ.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(c.sha).font(.system(size: 11, design: .monospaced))
                        .foregroundColor(IJ.accentBlue)
                    Text("·").foregroundColor(IJ.textSecondary)
                    Text(c.author).font(.system(size: 11)).foregroundColor(IJ.textSecondary)
                    Text("·").foregroundColor(IJ.textSecondary)
                    Text(c.when).font(.system(size: 11)).foregroundColor(IJ.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(Rectangle().fill(IJ.borderSubtle).frame(height: 1), alignment: .bottom)
    }
}

/// "Bookmarks" tool window — pinned files. Backed by a small UserDefaults
/// list so pins survive across launches. Tap to jump to the file; long-press
/// or tap the trash to remove.
struct BookmarksSheet: View {
    @ObservedObject var session: ProjectSession
    @Binding var isShown: Bool

    @State private var pinned: [String] = BookmarksSheet.loadPins()
    private static let kKey = "aether.bookmarks.pins"

    var body: some View {
        NavigationView {
            ZStack {
                IJ.bgMain.ignoresSafeArea()
                VStack(spacing: 0) {
                    addCurrentBar
                    Divider().background(IJ.border)
                    if pinned.isEmpty {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "bookmark")
                                .font(.system(size: 36))
                                .foregroundColor(IJ.textDisabled)
                            Text("No bookmarks yet.")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(IJ.textPrimary)
                            Text("Pin the current file with the button above to keep it one tap away.")
                                .font(.system(size: 12))
                                .foregroundColor(IJ.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(pinned, id: \.self) { file in pinRow(file) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isShown = false }.foregroundColor(IJ.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var addCurrentBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 12))
                .foregroundColor(IJ.accentBlue)
            Text(session.currentFile)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(IJ.textPrimary)
            Spacer()
            Button(action: pinCurrent) {
                Text(pinned.contains(session.currentFile) ? "PINNED" : "PIN")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(pinned.contains(session.currentFile)
                                              ? IJ.scrollbar : IJ.accentBlue))
            }
            .disabled(pinned.contains(session.currentFile) || session.currentFile.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(IJ.bgSidebar)
    }

    private func pinRow(_ file: String) -> some View {
        Button(action: {
            session.switchTo(file: file)
            isShown = false
        }) {
            HStack(spacing: 10) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 11))
                    .foregroundColor(IJ.accentBlue)
                Text(file)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(IJ.textPrimary)
                Spacer()
                Button(action: { unpin(file) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(IJ.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().fill(IJ.borderSubtle).frame(height: 1), alignment: .bottom)
        }
    }

    private func pinCurrent() {
        let file = session.currentFile
        guard !file.isEmpty, !pinned.contains(file) else { return }
        pinned.append(file)
        save()
    }

    private func unpin(_ file: String) {
        pinned.removeAll { $0 == file }
        save()
    }

    private func save() {
        UserDefaults.standard.set(pinned, forKey: BookmarksSheet.kKey)
    }

    private static func loadPins() -> [String] {
        UserDefaults.standard.stringArray(forKey: BookmarksSheet.kKey) ?? []
    }
}
