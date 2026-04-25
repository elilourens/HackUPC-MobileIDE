import Foundation

/// Gemini 2.0 Flash wrapper for generating and modifying full single-file HTML pages.
/// Always returns raw HTML (markdown fences and the occasional ```html prefix are
/// stripped).
final class CodeGenerator {
    static let shared = CodeGenerator()

    private let apiKey = "AIzaSyBFCjjIhSflPOVS9jvw1H_60ULtQjI-Q0k"
    private let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
    private let timeout: TimeInterval = 30

    private init() {}

    private let generateSystem = """
    You are AETHER, an AI coding assistant inside an AR IDE. Generate a complete, \
    self-contained single HTML file with all CSS inline in a <style> tag and all \
    JavaScript inline in a <script> tag. Generate beautiful, modern HTML with clean \
    design. Use good padding, rounded corners, subtle shadows, nice typography, and a \
    cohesive color scheme. The page should look like a polished product, not a default \
    HTML form. Dark theme preferred. Return ONLY the raw HTML code. No markdown \
    backticks. No explanation. No comments. Just pure HTML that can be rendered \
    directly in a browser.
    """

    /// Generate a brand-new HTML page from a natural-language prompt.
    func generate(prompt: String, completion: @escaping (Result<String, Error>) -> Void) {
        post(systemPrompt: generateSystem, userPrompt: prompt, completion: completion)
    }

    /// Modify existing HTML. If `selected` is non-nil, scope the change to that element.
    func modify(currentCode: String, prompt: String, selected: ElementInfo?, completion: @escaping (Result<String, Error>) -> Void) {
        let system: String
        if let sel = selected {
            // Element info is interpolated into the system prompt so Gemini knows
            // exactly which element to edit. textContent is truncated upstream.
            let descriptor = "<\(sel.tag.lowercased()) class=\"\(sel.className)\" id=\"\(sel.id)\">\(sel.text)</\(sel.tag.lowercased())>"
            system = """
            You are AETHER. Here is the current HTML code:
            \(currentCode)

            The user has selected this specific element: \(descriptor). They want to: \
            \(prompt). Modify ONLY this element (or its inline styles) and return the \
            COMPLETE modified HTML file. Return ONLY the raw HTML. No markdown. \
            No backticks. No explanation.
            """
        } else {
            system = """
            You are AETHER. Here is the current HTML code:
            \(currentCode)

            The user wants to modify it. Apply their change and return the COMPLETE \
            modified HTML file. Return ONLY the raw HTML. No markdown. No backticks. \
            No explanation.
            """
        }
        post(systemPrompt: system, userPrompt: prompt, completion: completion)
    }

    // MARK: - Internals

    private func post(systemPrompt: String, userPrompt: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "\(endpoint)?key=\(apiKey)") else {
            completion(.failure(URLError(.badURL))); return
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "system_instruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contents": [
                ["parts": [["text": userPrompt]], "role": "user"]
            ],
            "generationConfig": [
                "temperature": 0.4,
                // Generated HTML can be sizable. Bump well over default to avoid
                // truncating mid-tag, which would break the WKWebView render.
                "maxOutputTokens": 4096
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(error)); return
            }
            guard let data = data else {
                completion(.failure(URLError(.zeroByteResource))); return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                print("CodeGenerator HTTP \(http.statusCode): \(body)")
                completion(.failure(URLError(.badServerResponse))); return
            }
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let candidates = json?["candidates"] as? [[String: Any]]
                let content = candidates?.first?["content"] as? [String: Any]
                let parts = content?["parts"] as? [[String: Any]]
                let text = (parts?.first?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let raw = text, !raw.isEmpty else {
                    completion(.failure(URLError(.cannotDecodeContentData))); return
                }
                completion(.success(CodeGenerator.cleanFences(raw)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    /// Even with a "no markdown" instruction, Gemini occasionally wraps output in
    /// ```html ... ``` fences. Strip them so the WKWebView gets clean HTML.
    static func cleanFences(_ text: String) -> String {
        var s = text
        // Drop a leading ``` line (with or without language tag).
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: nl)...])
            } else {
                s = String(s.dropFirst(3))
            }
        }
        // Drop a trailing ``` line.
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        // Some responses prepend "html" alone on a line.
        if s.hasPrefix("html\n") { s = String(s.dropFirst(5)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
