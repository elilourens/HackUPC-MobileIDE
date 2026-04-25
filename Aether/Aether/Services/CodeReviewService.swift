import Foundation
import Combine

/// Grade enum for code review results (A=best, F=worst)
enum Grade: String, Equatable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case f = "F"

    var color: String {
        switch self {
        case .a, .b: return "#59A869"  // green
        case .c: return "#FFA500"       // yellow/orange
        case .d, .f: return "#FF4D6D"  // red
        }
    }
}

/// Result of a code review
struct CodeReviewResult: Equatable {
    enum Category: String {
        case quality = "Quality"
        case security = "Security"
        case performance = "Performance"
        case accessibility = "Accessibility"
    }

    let quality: Grade
    let security: Grade
    let performance: Grade
    let accessibility: Grade
    let details: [Category: String]

    var worstGrade: Grade {
        let grades = [quality, security, performance, accessibility]
        let order: [Grade] = [.f, .d, .c, .b, .a]
        for grade in order {
            if grades.contains(grade) {
                return grade
            }
        }
        return .c
    }

    var worstSummary: String {
        let order: [Grade] = [.f, .d, .c, .b, .a]
        let gradeToIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })

        let details = [
            (quality, details[.quality]),
            (security, details[.security]),
            (performance, details[.performance]),
            (accessibility, details[.accessibility])
        ]
        .sorted { (gradeToIndex[$0.0] ?? 10) < (gradeToIndex[$1.0] ?? 10) }
        return details.first?.1 ?? "No issues found."
    }
}

/// Service for reviewing code via the AI backend
@MainActor
final class CodeReviewService {
    static let shared = CodeReviewService()

    private init() {}

    /// Review code files for quality, security, performance, and accessibility
    func review(files: [String: String],
                session: ProjectSession,
                completion: @escaping (Result<CodeReviewResult, Error>) -> Void) {
        // Format files into a single context for analysis
        let filesContext = files
            .sorted { $0.key < $1.key }
            .map { "=== \($0.key) ===\n\($0.value)" }
            .joined(separator: "\n\n")

        let question = """
        Review this code. For each of the four categories — Code Quality, Security, Performance, Accessibility — give a single letter grade A-F and a one-line summary of the most important issue (with line number when possible). Output STRICTLY as four lines in this exact format:
        Quality: A | <summary>
        Security: B | <summary>
        Performance: C | <summary>
        Accessibility: D | <summary>
        Nothing else.
        """

        BackendClient.shared.analyze(
            files: files,
            question: question,
            baseURL: session.backendURL
        ) { [weak self] result in
            switch result {
            case .success(let response):
                let parsed = self?.parseReviewResponse(response) ?? CodeReviewResult(
                    quality: .c, security: .c, performance: .c, accessibility: .c,
                    details: [:]
                )
                completion(.success(parsed))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Ask a code-aware question using the project context
    func askAboutCode(_ question: String,
                      session: ProjectSession,
                      completion: @escaping (Result<String, Error>) -> Void) {
        let filesContext = session.projectFiles
            .sorted { $0.key < $1.key }
            .map { "=== \($0.key) ===\n\($0.value)" }
            .joined(separator: "\n\n")

        let augmentedQuestion = "\(question)\n\nProject files:\n\(filesContext)"

        BackendClient.shared.analyze(
            files: session.projectFiles,
            question: question,
            baseURL: session.backendURL
        ) { result in
            switch result {
            case .success(let response):
                completion(.success(response))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Parse a four-line review response
    private func parseReviewResponse(_ response: String) -> CodeReviewResult {
        let lines = response.split(separator: "\n").map(String.init)

        var quality: Grade = .c
        var security: Grade = .c
        var performance: Grade = .c
        var accessibility: Grade = .c
        var details: [CodeReviewResult.Category: String] = [:]

        for line in lines {
            if let (category, grade, summary) = parseLine(line) {
                switch category {
                case "Quality", "quality":
                    quality = grade
                    details[.quality] = summary
                case "Security", "security":
                    security = grade
                    details[.security] = summary
                case "Performance", "performance":
                    performance = grade
                    details[.performance] = summary
                case "Accessibility", "accessibility":
                    accessibility = grade
                    details[.accessibility] = summary
                default:
                    break
                }
            }
        }

        return CodeReviewResult(
            quality: quality,
            security: security,
            performance: performance,
            accessibility: accessibility,
            details: details
        )
    }

    /// Parse a single line like "Quality: A | summary text"
    private func parseLine(_ line: String) -> (category: String, grade: Grade, summary: String)? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let category = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)

        let rest = String(line[line.index(after: colonIdx)...])
        guard let pipeIdx = rest.firstIndex(of: "|") else { return nil }

        let gradeStr = String(rest[..<pipeIdx]).trimmingCharacters(in: .whitespaces)
        guard let grade = Grade(rawValue: gradeStr.uppercased()) else { return nil }

        let summary = String(rest[rest.index(after: pipeIdx)...]).trimmingCharacters(in: .whitespaces)

        return (category, grade, summary)
    }
}
