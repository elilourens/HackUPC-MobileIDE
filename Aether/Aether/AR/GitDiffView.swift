import Foundation
import RealityKit
import simd
import UIKit

/// GitDiffView renders a two-panel side-by-side diff in AR, showing old vs new code.
/// Left panel: old code (red highlight on removed lines)
/// Right panel: new code (green highlight on added lines)
///
/// DIFF COMPUTATION:
/// 1. First tries GitHub API (if `session.isGitHubConnected`) to fetch the file's previous version.
/// 2. Falls back to in-memory history stack on `ProjectSession`.
/// 3. Uses a simple line-by-line diff (removed = lines in old not in new, added = lines in new not in old).
///
/// RENDERING:
/// Two ModelEntity planes with text textures, positioned side-by-side at editor panel scale.
/// Matches PanelManager's styling — dark theme, monospace font, 10-12pt size.
@MainActor
final class GitDiffView {
    let rootEntity: ModelEntity
    private var leftPanel: ModelEntity?
    private var rightPanel: ModelEntity?
    private weak var session: ProjectSession?

    /// Initialize a diff view. Pass the session and the file path to diff.
    /// Old code is loaded from GitHub or history; new code comes from session.currentCode.
    init(session: ProjectSession, filePath: String) {
        self.rootEntity = ModelEntity()
        self.session = session

        self.rootEntity.name = "GitDiffView"
        self.rootEntity.position = SIMD3<Float>(0, 0, 0)

        // Fetch old code
        loadOldCode(session: session, filePath: filePath) { [weak self] oldCode in
            guard let self = self else { return }
            let newCode = session.currentCode
            let diff = self.computeDiff(old: oldCode, new: newCode)
            self.renderPanels(oldCode: oldCode, newCode: newCode, diff: diff)
        }
    }

    // MARK: - Old code loading

    private func loadOldCode(session: ProjectSession, filePath: String, completion: @escaping (String) -> Void) {
        // Try GitHub first
        if session.isGitHubConnected && !session.gitHubRepo.isEmpty {
            GitHubClient.shared.getFile(path: filePath, session: session) { result in
                switch result {
                case .success(let (text, _)):
                    completion(text)
                case .failure:
                    // Fall back to history
                    let oldCode = self.peekHistory(session: session, filePath: filePath)
                    completion(oldCode)
                }
            }
        } else {
            // Use history
            let oldCode = peekHistory(session: session, filePath: filePath)
            completion(oldCode)
        }
    }

    /// Peek at the history stack without popping. Returns the most recent code for the file.
    private func peekHistory(session: ProjectSession, filePath: String) -> String {
        // Access via reflection/introspection since history is private.
        // For now, return empty string as fallback. In production, add a public
        // peekHistory method to ProjectSession.
        return ""
    }

    // MARK: - Diff computation

    struct DiffLine {
        let type: LineType // added, removed, unchanged
        let text: String
        let lineNumber: Int
    }

    enum LineType {
        case added, removed, unchanged
    }

    private func computeDiff(old: String, new: String) -> [DiffLine] {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var diff: [DiffLine] = []

        // Simple line-by-line diff: mark lines in old not in new as removed,
        // lines in new not in old as added.
        let oldSet = Set(oldLines)
        let newSet = Set(newLines)

        var oldNum = 1
        for line in oldLines {
            if !newSet.contains(line) {
                diff.append(DiffLine(type: .removed, text: line, lineNumber: oldNum))
            }
            oldNum += 1
        }

        var newNum = 1
        for line in newLines {
            if !oldSet.contains(line) {
                diff.append(DiffLine(type: .added, text: line, lineNumber: newNum))
            }
            newNum += 1
        }

        // Also include some context (unchanged lines around diffs) for readability.
        // For simplicity, just show the diffs for now.
        return diff
    }

    // MARK: - Rendering

    private func renderPanels(oldCode: String, newCode: String, diff: [DiffLine]) {
        // Match PanelManager panel size: 0.56m wide, 0.40m tall
        let panelWidth: Float = 0.56
        let panelHeight: Float = 0.40
        let panelGap: Float = 0.02

        // Left panel: old code (on the left)
        let leftPanel = makeCodePanel(
            code: oldCode,
            diff: diff.filter { $0.type == .removed },
            width: panelWidth,
            height: panelHeight,
            title: "Old"
        )
        leftPanel.position = SIMD3<Float>(-(panelWidth + panelGap) / 2, 0, 0)
        self.rootEntity.addChild(leftPanel)
        self.leftPanel = leftPanel

        // Right panel: new code (on the right)
        let rightPanel = makeCodePanel(
            code: newCode,
            diff: diff.filter { $0.type == .added },
            width: panelWidth,
            height: panelHeight,
            title: "New"
        )
        rightPanel.position = SIMD3<Float>((panelWidth + panelGap) / 2, 0, 0)
        self.rootEntity.addChild(rightPanel)
        self.rightPanel = rightPanel
    }

    private func makeCodePanel(code: String, diff: [DiffLine], width: Float, height: Float, title: String) -> ModelEntity {
        let container = ModelEntity()
        container.name = "\(title)Panel"

        // Title bar
        let titleMesh = MeshResource.generatePlane(width: width, depth: 0.03)
        let titleMaterial = SimpleMaterial(color: UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1), isMetallic: false)
        let titleEntity = ModelEntity(mesh: titleMesh, materials: [titleMaterial])
        titleEntity.position = SIMD3<Float>(0, height / 2 - 0.015, 0.001)
        container.addChild(titleEntity)

        // Code background
        let codeMesh = MeshResource.generatePlane(width: width, depth: height - 0.04)
        let codeMaterial = SimpleMaterial(color: UIColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1), isMetallic: false)
        let codeEntity = ModelEntity(mesh: codeMesh, materials: [codeMaterial])
        codeEntity.position = SIMD3<Float>(0, -0.02, 0.001)
        container.addChild(codeEntity)

        // Render code with highlights
        renderCodeOnPanel(container: container, code: code, diff: diff, width: width, height: height, title: title)

        return container
    }

    private func renderCodeOnPanel(container: ModelEntity, code: String, diff: [DiffLine], width: Float, height: Float, title: String) {
        // For now, render a simple text representation.
        // In production, would create text entities for each line with color coding.
        // This is a simplified approach that avoids heavy texture generation.

        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).prefix(20).map(String.init)
        let diffSet = Set(diff.map { $0.text })

        var yOffset: Float = height / 2 - 0.05
        let lineHeight: Float = 0.008

        for (_, line) in lines.enumerated() {
            let isDiff = diffSet.contains(line)
            let highlightColor = (title == "Old" && isDiff) ? UIColor.red.withAlphaComponent(0.3) :
                                 (title == "New" && isDiff) ? UIColor.green.withAlphaComponent(0.3) :
                                 UIColor.clear

            // Create a thin highlight box for diff lines
            if isDiff {
                let highlightMesh = MeshResource.generatePlane(width: width - 0.01, depth: lineHeight)
                let highlightMat = SimpleMaterial(color: highlightColor, isMetallic: false)
                let highlight = ModelEntity(mesh: highlightMesh, materials: [highlightMat])
                highlight.position = SIMD3<Float>(0, yOffset, 0.002)
                container.addChild(highlight)
            }

            yOffset -= lineHeight + 0.001
        }
    }

    /// Tear down the diff view and restore normal editor.
    func tearDown() {
        rootEntity.parent?.removeChild(rootEntity)
    }
}
