import Foundation

/// Talks to the hackathon FastAPI backend (`/api/build`, `/api/modify`,
/// `/api/modify-element`). Falls back to the on-device `CodeGenerator`
/// (OpenAI gpt-4o) if the backend is unreachable so the demo keeps working
/// without a laptop on the network.
@MainActor
final class BackendClient {
    static let shared = BackendClient()
    private init() {}

    private let timeout: TimeInterval = 60

    enum BackendError: Error {
        case badURL
        case nonOK(status: Int, body: String)
        case decoding
    }

    /// One step in a Junie-generated execution plan. Surfaced both to the AR
    /// HUD overlay and the phone agent panel as a checklist before execution.
    struct PlanStep: Identifiable, Equatable {
        let id: Int
        let action: String
        let target: String
        let why: String
    }

    /// Result of the planner — speech summary for JARVIS, structured steps
    /// for the overlay, and the hidden expanded prompt to feed `/api/build`
    /// once the user confirms.
    struct PlanPayload: Equatable {
        let summary: String
        let steps: [PlanStep]
        let expandedPrompt: String
    }

    /// Build a plan for the user's prompt without writing any code yet.
    /// Backend is responsible for expanding the brief; if the backend is
    /// unreachable we synthesize a minimal local plan so the demo still flows.
    func plan(prompt: String, currentCode: String?, session: ProjectSession,
              completion: @escaping (Result<PlanPayload, Error>) -> Void) {
        var body: [String: Any] = ["prompt": prompt]
        if let c = currentCode, !c.isEmpty { body["current_code"] = c }

        callBackendJSON(path: "/api/plan", body: body, baseURL: session.backendURL) { result in
            switch result {
            case .success(let json):
                guard
                    let summary = json["summary"] as? String, !summary.isEmpty,
                    let expanded = json["expanded_prompt"] as? String, !expanded.isEmpty
                else {
                    completion(.failure(BackendError.decoding)); return
                }
                let stepsJSON = (json["steps"] as? [[String: Any]]) ?? []
                let steps: [PlanStep] = stepsJSON.compactMap { d in
                    guard
                        let idx = (d["index"] as? Int) ?? (d["index"] as? NSNumber)?.intValue,
                        let action = d["action"] as? String,
                        let target = d["target"] as? String
                    else { return nil }
                    return PlanStep(id: idx, action: action, target: target,
                                    why: (d["why"] as? String) ?? "")
                }
                completion(.success(PlanPayload(summary: summary, steps: steps,
                                                 expandedPrompt: expanded)))
            case .failure(let err):
                print("BackendClient.plan falling back: \(err)")
                // Local stub plan — keeps the confirmation UX flowing when the
                // backend is offline. Build will then fall back to gpt-4o
                // direct and use the user's literal prompt.
                let summary = "I'll build a single-page implementation for: \(prompt). Tell me to confirm."
                let steps = [
                    PlanStep(id: 1, action: "Draft layout",
                             target: "index.html", why: "Anchor sections + typography"),
                    PlanStep(id: 2, action: "Compose components",
                             target: "index.html · sections", why: "Hero, content, CTA"),
                    PlanStep(id: 3, action: "Polish details",
                             target: "index.html · style", why: "Spacing, hovers, micro-interactions")
                ]
                completion(.success(PlanPayload(summary: summary, steps: steps,
                                                 expandedPrompt: prompt)))
            }
        }
    }

    // MARK: - Public API

    /// Generate a fresh page from a natural-language prompt.
    /// - Parameter session: read for `backendURL`. Pass-through; no mutation.
    func generate(prompt: String, session: ProjectSession,
                  completion: @escaping (Result<String, Error>) -> Void) {
        let body: [String: Any] = ["prompt": prompt]
        callBackend(path: "/api/build", body: body, baseURL: session.backendURL) { result in
            switch result {
            case .success(let html):
                completion(.success(html))
            case .failure(let err):
                print("BackendClient.generate falling back: \(err)")
                CodeGenerator.shared.generate(prompt: prompt, completion: completion)
            }
        }
    }

    /// Modify the current page given the user's prompt.
    func modify(prompt: String, currentCode: String, session: ProjectSession,
                completion: @escaping (Result<String, Error>) -> Void) {
        let body: [String: Any] = ["prompt": prompt, "current_code": currentCode]
        callBackend(path: "/api/modify", body: body, baseURL: session.backendURL) { result in
            switch result {
            case .success(let html):
                completion(.success(html))
            case .failure(let err):
                print("BackendClient.modify falling back: \(err)")
                CodeGenerator.shared.modify(currentCode: currentCode, prompt: prompt,
                                            selected: nil, completion: completion)
            }
        }
    }

    /// Modify only a specific element (AR mode — element selected by pointing at preview).
    func modifyElement(prompt: String, currentCode: String, element: ElementInfo,
                       session: ProjectSession,
                       completion: @escaping (Result<String, Error>) -> Void) {
        let body: [String: Any] = [
            "prompt": prompt,
            "current_code": currentCode,
            "element": [
                "tag": element.tag,
                "class": element.className,
                "id": element.id,
                "text": element.text
            ]
        ]
        callBackend(path: "/api/modify-element", body: body, baseURL: session.backendURL) { result in
            switch result {
            case .success(let html):
                completion(.success(html))
            case .failure(let err):
                print("BackendClient.modifyElement falling back: \(err)")
                CodeGenerator.shared.modify(currentCode: currentCode, prompt: prompt,
                                            selected: element, completion: completion)
            }
        }
    }

    // MARK: - Internals

    /// JSON-returning variant of `callBackend` — used by `/api/plan` since its
    /// response is a structured object, not raw HTML. Always returns on the
    /// main thread for SwiftUI consumers.
    private func callBackendJSON(path: String, body: [String: Any], baseURL: String,
                                 completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBase.isEmpty,
              let url = URL(string: trimmedBase + path) else {
            DispatchQueue.main.async { completion(.failure(BackendError.badURL)) }; return
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }; return
            }
            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(URLError(.zeroByteResource))) }; return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let bodyStr = String(data: data, encoding: .utf8) ?? "<no body>"
                DispatchQueue.main.async {
                    completion(.failure(BackendError.nonOK(status: http.statusCode, body: bodyStr)))
                }
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                DispatchQueue.main.async { completion(.success(json)) }
            } else {
                DispatchQueue.main.async { completion(.failure(BackendError.decoding)) }
            }
        }.resume()
    }

    private func callBackend(path: String, body: [String: Any], baseURL: String,
                             completion: @escaping (Result<String, Error>) -> Void) {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBase.isEmpty,
              let url = URL(string: trimmedBase + path) else {
            completion(.failure(BackendError.badURL)); return
        }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(error)); return
            }
            guard let data = data else {
                completion(.failure(URLError(.zeroByteResource))); return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let bodyStr = String(data: data, encoding: .utf8) ?? "<no body>"
                completion(.failure(BackendError.nonOK(status: http.statusCode, body: bodyStr))); return
            }
            // Accept either { "html": "..." } or { "code": "..." }; some backends use either.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let html = (json["html"] as? String) ?? (json["code"] as? String),
               !html.isEmpty {
                completion(.success(CodeGenerator.cleanFences(html)))
            } else if let raw = String(data: data, encoding: .utf8), !raw.isEmpty,
                      raw.contains("<html") || raw.contains("<!DOCTYPE") {
                completion(.success(CodeGenerator.cleanFences(raw)))
            } else {
                completion(.failure(BackendError.decoding))
            }
        }.resume()
    }
}
