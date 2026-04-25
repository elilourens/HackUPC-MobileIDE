import SwiftUI

/// Slide-in file tree sidebar. Triggered by the hamburger button in the toolbar.
/// Shows the project files (or repo files when GitHub-connected) and provides
/// shortcuts to "New File", "GitHub", and "Settings".
struct FileTreeSidebar: View {
    @ObservedObject var session: ProjectSession
    @Binding var isShown: Bool
    @Binding var showSettings: Bool
    @Binding var showGitHubConnect: Bool

    /// File-tree entries to render. When GitHub is connected and we've loaded a
    /// listing, this is the repo's contents; otherwise it's the in-memory project.
    let repoEntries: [GitHubClient.RepoEntry]
    let onSelectFile: (String) -> Void
    let onSelectRepoFile: (GitHubClient.RepoEntry) -> Void
    let onNewFile: () -> Void
    let onRefreshRepo: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            if isShown {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.22)) { isShown = false } }
            }
            HStack(spacing: 0) {
                if isShown {
                    panel
                        .frame(width: UIScreen.main.bounds.width * 0.72)
                        .background(IJ.bgSidebar)
                        .transition(.move(edge: .leading))
                }
                Spacer(minLength: 0)
            }
            .ignoresSafeArea(edges: .vertical)
        }
        .animation(.easeOut(duration: 0.22), value: isShown)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("PROJECT")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.3)
                    .foregroundColor(IJ.textSecondary)
                Spacer()
                if session.isGitHubConnected {
                    Circle().fill(IJ.accentGreen).frame(width: 6, height: 6)
                    Text("GITHUB")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.2)
                        .foregroundColor(IJ.accentGreen)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 56)
            .padding(.bottom, 10)

            // Project name row
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundColor(IJ.textSecondary)
                Text(projectLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(IJ.textPrimary)
                Spacer()
                if session.isGitHubConnected {
                    Button(action: onRefreshRepo) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(IJ.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            Divider().background(IJ.borderSubtle)

            // File list
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if session.isGitHubConnected && !repoEntries.isEmpty {
                        ForEach(repoEntries) { entry in
                            repoRow(entry)
                        }
                    } else {
                        ForEach(localFiles, id: \.self) { file in
                            localRow(file)
                        }
                        if localFiles.isEmpty {
                            Text("No files yet")
                                .font(.system(size: 12))
                                .foregroundColor(IJ.textDisabled)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            Spacer(minLength: 0)

            // Footer actions
            VStack(spacing: 0) {
                Divider().background(IJ.borderSubtle)
                actionRow(icon: "plus.square", label: "New File", action: {
                    isShown = false
                    onNewFile()
                })
                actionRow(icon: "chevron.left.forwardslash.chevron.right",
                          label: session.isGitHubConnected ? "Switch Repo" : "Connect GitHub",
                          action: {
                              isShown = false
                              showGitHubConnect = true
                          })
                actionRow(icon: "gearshape", label: "Settings", action: {
                    isShown = false
                    showSettings = true
                })
            }
            .padding(.bottom, 28)
        }
    }

    private var projectLabel: String {
        if session.isGitHubConnected, !session.gitHubRepo.isEmpty {
            return session.gitHubRepo.split(separator: "/").last.map(String.init) ?? session.gitHubRepo
        }
        return "my-app"
    }

    private var localFiles: [String] {
        session.projectFiles.keys.sorted()
    }

    @ViewBuilder
    private func localRow(_ file: String) -> some View {
        let active = file == session.currentFile
        Button(action: {
            onSelectFile(file)
            isShown = false
        }) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(active ? IJ.accentBlue : Color.clear)
                    .frame(width: 2)
                Circle().fill(IJ.iconColor(for: file)).frame(width: 7, height: 7)
                Text(file)
                    .font(.system(size: 13))
                    .foregroundColor(IJ.textPrimary)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.trailing, 12)
            .background(active ? IJ.bgSelected : Color.clear)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func repoRow(_ entry: GitHubClient.RepoEntry) -> some View {
        let isDir = entry.type == "dir"
        Button(action: {
            if isDir { return }   // dir-drilldown isn't wired in this pass
            onSelectRepoFile(entry)
            isShown = false
        }) {
            HStack(spacing: 8) {
                Rectangle().fill(Color.clear).frame(width: 2)
                if isDir {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundColor(IJ.textSecondary)
                } else {
                    Circle().fill(IJ.iconColor(for: entry.name)).frame(width: 7, height: 7)
                }
                Text(entry.name)
                    .font(.system(size: 13))
                    .foregroundColor(isDir ? IJ.textSecondary : IJ.textPrimary)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.trailing, 12)
            .opacity(isDir ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func actionRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundColor(IJ.textSecondary)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(IJ.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}
