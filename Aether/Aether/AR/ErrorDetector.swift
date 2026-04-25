import Foundation
import RealityKit
import Combine
import simd
import UIKit

/// Live JS error detection in AR. Subscribes to console errors and spawns
/// visual error markers (red diamonds) at the corresponding line numbers in
/// the editor panel.
@MainActor
final class ErrorDetector {
    private weak var anchor: AnchorEntity?
    private var errorMarkers: [Int: ModelEntity] = [:]  // lineNo -> entity
    private var subscription: AnyCancellable?
    private weak var session: ProjectSession?
    private weak var panelManager: PanelManager?

    init(anchor: AnchorEntity, session: ProjectSession, panelManager: PanelManager) {
        self.anchor = anchor
        self.session = session
        self.panelManager = panelManager

        // Subscribe to console entries and filter for errors
        subscription = session.$consoleEntries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                self?.updateErrorMarkers(from: entries)
            }
    }

    deinit {
        subscription?.cancel()
        // Clean up markers
        for (_, marker) in errorMarkers {
            marker.removeFromParent()
        }
        errorMarkers.removeAll()
    }

    /// Parse error messages for line numbers and spawn/update markers
    private func updateErrorMarkers(from entries: [ConsoleEntry]) {
        let errorEntries = entries.filter { $0.level == .error }

        // Extract line numbers from error messages using regex patterns
        var lineNumbers: Set<Int> = []
        for entry in errorEntries {
            if let lineNo = parseLineNumber(from: entry.text) {
                lineNumbers.insert(lineNo)
            }
        }

        // Remove markers for lines that no longer have errors
        let currentLines = Set(errorMarkers.keys)
        for lineNo in currentLines.subtracting(lineNumbers) {
            if let marker = errorMarkers.removeValue(forKey: lineNo) {
                marker.removeFromParent()
            }
        }

        // Add new markers for lines with errors
        for lineNo in lineNumbers.subtracting(currentLines) {
            spawnErrorMarker(at: lineNo)
        }
    }

    /// Extract line number from error text using regex patterns like ":123:" or "line 123"
    private func parseLineNumber(from text: String) -> Int? {
        // Try pattern ":line_number:"
        if let range = text.range(of: ":(\\d+):", options: .regularExpression) {
            let numStr = String(text[range]).dropFirst().dropLast()
            return Int(numStr)
        }

        // Try pattern "line number"
        if let range = text.range(of: "line (\\d+)", options: .regularExpression) {
            let line = String(text[range])
            let numStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            return Int(numStr)
        }

        return nil
    }

    /// Spawn a red diamond error marker at the given line number
    private func spawnErrorMarker(at lineNo: Int) {
        guard let anchor = anchor, let panelManager = panelManager else { return }

        // Create a small red diamond (rotated cube, emissive red)
        let markerSize: Float = 0.012
        let marker = Holo.diamond(size: markerSize, color: Holo.red)

        // Position relative to editor panel
        // Each line is roughly 0.008m tall in the editor rendering.
        // Y offset: higher line numbers go lower on the panel
        let lineHeight: Float = 0.008
        let topY: Float = 0.18  // top of editor content area
        let yOffset = topY - Float(lineNo) * lineHeight

        // X position: right side of editor panel (outside the text)
        let xOffset: Float = 0.25

        marker.position = SIMD3<Float>(xOffset, yOffset, 0.005)

        anchor.addChild(marker)
        errorMarkers[lineNo] = marker

        // Append to terminal log
        let lastError = session?.consoleEntries.last(where: { $0.level == .error })?.text ?? "Unknown error"
        session?.appendTerminal(.error, "Error on line \(lineNo): \(lastError)")

        // Speak the error
        JarvisVoice.shared.speak("Error detected on line \(lineNo).")
    }

    /// Despawn all error markers (called when errors are cleared or user says "clear errors")
    func acknowledgeAll() {
        for (_, marker) in errorMarkers {
            marker.removeFromParent()
        }
        errorMarkers.removeAll()
    }
}
