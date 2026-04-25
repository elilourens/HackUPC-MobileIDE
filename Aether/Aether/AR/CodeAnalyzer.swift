import Foundation

/// Represents a cross-file reference: a symbol defined in one file and used in another.
struct Connection: Equatable {
    let fromFile: String
    let toFile: String
    let symbol: String
    let lineNumber: Int
}

/// Pure data layer for analyzing cross-file references in a project.
/// Extracts function definitions, class definitions, component definitions, and import statements
/// from project files, then maps imports to their definitions.
@MainActor
final class CodeAnalyzer {
    /// Analyzes project files and returns all cross-file connections.
    /// - Parameter projectFiles: Dictionary mapping filename to file content
    /// - Returns: Array of connections between files
    static func analyzeConnections(projectFiles: [String: String]) -> [Connection] {
        var connections: [Connection] = []

        // First pass: collect all definitions (symbol -> file mapping)
        var definitions: [String: String] = [:]
        for (file, content) in projectFiles {
            let defs = extractDefinitions(from: content, file: file)
            for def in defs {
                definitions[def.symbol] = def.file
            }
        }

        // Second pass: find imports and connect them to definitions
        for (file, content) in projectFiles {
            let imports = extractImports(from: content)
            for (importedSymbol, lineNum) in imports {
                if let sourceFile = definitions[importedSymbol], sourceFile != file {
                    connections.append(Connection(
                        fromFile: file,
                        toFile: sourceFile,
                        symbol: importedSymbol,
                        lineNumber: lineNum
                    ))
                }
            }
        }

        return connections
    }

    /// Extracts symbol definitions from a code file.
    private struct Definition {
        let symbol: String
        let file: String
        let lineNumber: Int
    }

    /// Finds all function, class, and component definitions in code.
    private static func extractDefinitions(from content: String, file: String) -> [Definition] {
        var defs: [Definition] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineNum = index + 1

            // JavaScript/TypeScript function definitions: function NAME or const NAME = (...) =>
            if trimmed.hasPrefix("function ") {
                if let name = extractFunctionName(from: String(trimmed)) {
                    defs.append(Definition(symbol: name, file: file, lineNumber: lineNum))
                }
            }

            // Arrow function: const NAME = (...) =>
            if trimmed.hasPrefix("const ") || trimmed.hasPrefix("export const ") {
                if let name = extractConstName(from: String(trimmed)) {
                    defs.append(Definition(symbol: name, file: file, lineNumber: lineNum))
                }
            }

            // Class definitions: class NAME or export class NAME
            if trimmed.hasPrefix("class ") || trimmed.hasPrefix("export class ") {
                if let name = extractClassName(from: String(trimmed)) {
                    defs.append(Definition(symbol: name, file: file, lineNumber: lineNum))
                }
            }

            // React component: function ComponentName or const ComponentName =
            // (components conventionally start with uppercase)
            if (trimmed.hasPrefix("function ") || trimmed.hasPrefix("export function ")) {
                if let name = extractFunctionName(from: String(trimmed)), isComponent(name) {
                    defs.append(Definition(symbol: name, file: file, lineNumber: lineNum))
                }
            }

            if trimmed.hasPrefix("export default function") {
                if let name = extractDefaultFunction(from: String(trimmed)) {
                    defs.append(Definition(symbol: name, file: file, lineNumber: lineNum))
                }
            }
        }

        return defs
    }

    /// Finds all imports in code and returns (symbol, lineNumber) pairs.
    private static func extractImports(from content: String, file: String = "") -> [(String, Int)] {
        var imports: [(String, Int)] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineNum = index + 1

            // ES6 import: import { Name } from "file"
            if trimmed.hasPrefix("import ") && trimmed.contains(" from ") {
                let symbols = extractImportedSymbols(from: String(trimmed))
                for symbol in symbols {
                    imports.append((symbol, lineNum))
                }
            }

            // CommonJS require: const { Name } = require("file") or const Name = require("file")
            if trimmed.contains("require(") {
                let symbols = extractRequireSymbols(from: String(trimmed))
                for symbol in symbols {
                    imports.append((symbol, lineNum))
                }
            }
        }

        return imports
    }

    private static func extractFunctionName(from line: String) -> String? {
        let patterns = [
            "function\\s+([a-zA-Z_$][a-zA-Z0-9_$]*)",
            "export\\s+function\\s+([a-zA-Z_$][a-zA-Z0-9_$]*)"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                if let range = Range(match.range(at: 1), in: line) {
                    return String(line[range])
                }
            }
        }
        return nil
    }

    private static func extractConstName(from line: String) -> String? {
        let pattern = "(?:export\\s+)?const\\s+([a-zA-Z_$][a-zA-Z0-9_$]*)\\s*="

        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let range = Range(match.range(at: 1), in: line) {
                return String(line[range])
            }
        }
        return nil
    }

    private static func extractClassName(from line: String) -> String? {
        let pattern = "(?:export\\s+)?class\\s+([a-zA-Z_$][a-zA-Z0-9_$]*)"

        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let range = Range(match.range(at: 1), in: line) {
                return String(line[range])
            }
        }
        return nil
    }

    private static func extractDefaultFunction(from line: String) -> String? {
        let pattern = "export\\s+default\\s+function\\s+([a-zA-Z_$][a-zA-Z0-9_$]*)"

        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let range = Range(match.range(at: 1), in: line) {
                return String(line[range])
            }
        }
        return nil
    }

    private static func extractImportedSymbols(from line: String) -> [String] {
        var symbols: [String] = []

        // import { A, B } from "module"
        if let start = line.range(of: "{"), let end = line.range(of: "}", range: start.upperBound..<line.endIndex) {
            let content = String(line[start.upperBound..<end.lowerBound])
            let items = content.split(separator: ",")
            for item in items {
                let trimmed = item.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first // Handle "import X as Y"
                    .map(String.init) ?? ""
                if !trimmed.isEmpty {
                    symbols.append(trimmed)
                }
            }
        }

        // import Name from "module" (default import)
        let pattern = "import\\s+([a-zA-Z_$][a-zA-Z0-9_$]*)\\s+from"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let range = Range(match.range(at: 1), in: line) {
                symbols.append(String(line[range]))
            }
        }

        return symbols
    }

    private static func extractRequireSymbols(from line: String) -> [String] {
        var symbols: [String] = []

        // const { A, B } = require(...)
        if let start = line.range(of: "{"), let end = line.range(of: "}", range: start.upperBound..<line.endIndex) {
            let content = String(line[start.upperBound..<end.lowerBound])
            let items = content.split(separator: ",")
            for item in items {
                let trimmed = item.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    symbols.append(trimmed)
                }
            }
        }

        // const Name = require(...)
        let pattern = "const\\s+([a-zA-Z_$][a-zA-Z0-9_$]*)\\s*=\\s*require"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let range = Range(match.range(at: 1), in: line) {
                symbols.append(String(line[range]))
            }
        }

        return symbols
    }

    /// Check if a name looks like a React component (starts with uppercase).
    private static func isComponent(_ name: String) -> Bool {
        return name.first?.isUppercase ?? false
    }
}
