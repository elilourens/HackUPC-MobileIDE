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
