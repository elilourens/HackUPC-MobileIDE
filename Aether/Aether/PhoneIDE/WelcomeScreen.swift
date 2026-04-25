import SwiftUI

/// JetBrains-style "Welcome to ArcReact" screen — modeled on IntelliJ /
/// WebStorm's launchpad (left rail with Projects / Customize / Plugins, right
/// pane with recent projects + New Project / Open / Get from VCS). Shown the
/// first time the app opens; tapping "Open ArcReact" enters the IDE.
struct WelcomeScreen: View {
    @ObservedObject var session: ProjectSession
    var onOpen: () -> Void

    @State private var section: Section = .projects
    enum Section: String, CaseIterable { case projects = "Projects", customize = "Customize", plugins = "Plugins", learn = "Learn" }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
                .background(IJ.bgSidebar)
                .overlay(Rectangle().fill(IJ.border).frame(width: 1), alignment: .trailing)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(IJ.bgEditor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IJ.bgEditor)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand row — WebStorm logo + JetBrains wordmark + product name
            HStack(spacing: 10) {
                Image("JB-webstorm-logo")
                    .resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ArcReact")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(IJ.textPrimary)
                    Text("by JetBrains · 2026.1")
                        .font(.system(size: 10))
                        .foregroundColor(IJ.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 32)
            .padding(.bottom, 28)

            ForEach(Section.allCases, id: \.self) { s in
                sidebarRow(s)
            }
            Spacer()

            // Bottom: settings link
            HStack(spacing: 8) {
                JBIcon(.tool("settings"), size: 12)
                Text("Settings")
                    .font(.system(size: 12))
                    .foregroundColor(IJ.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func sidebarRow(_ s: Section) -> some View {
        let active = section == s
        Button(action: { section = s }) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(active ? IJ.accentBlue : Color.clear)
                    .frame(width: 2)
                Text(s.rawValue)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? IJ.textPrimary : IJ.textSecondary)
                    .padding(.leading, 16)
                    .padding(.vertical, 10)
                Spacer()
            }
            .background(active ? IJ.bgSelected : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content pane

    @ViewBuilder
    private var content: some View {
        switch section {
        case .projects:   projectsContent
        case .customize:  placeholder("Customize")
        case .plugins:    placeholder("Plugins · Marketplace")
        case .learn:      placeholder("Learn ArcReact")
        }
    }

    private var projectsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top action row — exact New Project / Open / Get from VCS
            HStack(spacing: 8) {
                Spacer()
                actionButton("New Project", icon: "JB-tool-add", primary: true) {
                    onOpen()
                }
                actionButton("Open", icon: "JB-tool-folder", primary: false) {
                    onOpen()
                }
                actionButton("Get from VCS", icon: "JB-tool-branch", primary: false) {
                    onOpen()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)

            // Search row
            HStack(spacing: 6) {
                JBIcon(.tool("search"), size: 12)
                Text("Search projects")
                    .font(.system(size: 12))
                    .foregroundColor(IJ.textDisabled)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(IJ.bgInput))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(IJ.border, lineWidth: 1))
            .padding(.horizontal, 28)
            .padding(.top, 24)

            // Recent projects list
            VStack(alignment: .leading, spacing: 0) {
                ForEach(recentProjects, id: \.path) { proj in
                    projectRow(proj)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)

            Spacer()

            // Footer: tip
            HStack(spacing: 6) {
                Image("JunieIcon")
                    .resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
                Text("Junie can scaffold a project from a single sentence — try \"a coffee subscription landing page\".")
                    .font(.system(size: 11))
                    .foregroundColor(IJ.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
    }

    @ViewBuilder
    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(IJ.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func actionButton(_ label: String, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(icon)
                    .resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
                    .frame(width: 11, height: 11)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(primary ? .white : IJ.textPrimary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(primary ? IJ.accentBlue : IJ.bgEditor)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(primary ? Color.clear : IJ.border, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private struct Recent {
        let name: String
        let path: String
        let modified: String
        let sticker: Sticker
        enum Sticker { case arcReact, webStorm, junie }
    }

    private var recentProjects: [Recent] {
        var list = [
            Recent(name: "ArcReact Demo", path: "~/Projects/arcreact-demo",
                   modified: "Just now", sticker: .arcReact),
            Recent(name: "junie-playground", path: "~/Projects/junie-playground",
                   modified: "2 hours ago", sticker: .junie),
            Recent(name: "starter-react-tailwind", path: "~/Projects/starter-react-tailwind",
                   modified: "Yesterday", sticker: .webStorm),
        ]
        if session.isGitHubConnected, !session.gitHubRepo.isEmpty {
            list.insert(
                Recent(name: session.gitHubRepo,
                       path: "github.com/\(session.gitHubRepo)",
                       modified: "Linked", sticker: .arcReact),
                at: 0
            )
        }
        return list
    }

    @ViewBuilder
    private func projectRow(_ proj: Recent) -> some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                projectSticker(proj.sticker)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(proj.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(IJ.textPrimary)
                    Text(proj.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(IJ.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(proj.modified)
                    .font(.system(size: 11))
                    .foregroundColor(IJ.textDisabled)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Color.clear)
        )
    }

    @ViewBuilder
    private func projectSticker(_ kind: Recent.Sticker) -> some View {
        switch kind {
        case .arcReact:
            ZStack {
                LinearGradient(colors: [
                    Color(red:  28/255, green: 196/255, blue: 184/255),
                    Color(red:  79/255, green: 124/255, blue: 255/255),
                    Color(red: 124/255, green:  92/255, blue: 255/255)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text("AR")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .webStorm:
            Image("JB-webstorm-logo")
                .resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
        case .junie:
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(red: 95/255, green: 184/255, blue: 101/255))
                Image("JunieIcon")
                    .resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            }
        }
    }
}
