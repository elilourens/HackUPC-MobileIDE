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
