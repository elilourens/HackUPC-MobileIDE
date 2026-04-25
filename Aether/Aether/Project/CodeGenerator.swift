import Foundation

/// OpenAI GPT-4o wrapper for generating and modifying full single-file HTML pages.
/// (Gemini still handles "hey jarvis" Q&A — see GeminiClient.swift.)
/// Always returns raw HTML; markdown fences and stray "html" prefixes are stripped.
final class CodeGenerator {
    static let shared = CodeGenerator()

    private let apiKey = Secrets.openAIKey
    private let endpoint = "https://api.openai.com/v1/chat/completions"
    private let model = "gpt-4o"
    private let timeout: TimeInterval = 60

    private init() {}

    /// Big aesthetic-direction system prompt for fresh page generation. Tells
    /// GPT-4o to commit to a bold visual identity rather than generic AI slop.
    private let generateSystem = """
    You are AETHER, an AI coding assistant inside an AR IDE. Generate a complete, self-contained single HTML file with all CSS in a <style> tag and all JS in a <script> tag. Return ONLY raw HTML. No markdown. No backticks. No explanation. No comments.

    Design rules:
    - Create distinctive, production-grade frontend interfaces that avoid generic AI slop aesthetics.
    - Choose a BOLD aesthetic direction for each page: brutally minimal, maximalist, retro-futuristic, organic, luxury, editorial, brutalist, art deco, soft/pastel, industrial. Pick one and commit.
    - Typography: Choose fonts that are beautiful and unique. NEVER use Inter, Roboto, Arial, or system fonts. Use Google Fonts. Pick distinctive display fonts paired with refined body fonts. Import them via <link> in the <head>.
    - Color: Commit to a cohesive palette. Dominant colors with sharp accents. NO GRADIENTS. No purple gradients on white. Use solid colors, high contrast, intentional color blocking.
    - Layout: Unexpected layouts. Asymmetry. Generous negative space OR controlled density. Grid-breaking elements. Not cookie-cutter.
    - Details: Subtle shadows, rounded corners where appropriate, micro-interactions via CSS transitions, hover states that surprise. Textures, patterns, decorative borders if they fit the aesthetic.
    - Dark theme by default unless the request implies otherwise.
    - Make it look like a real product designed by a top design agency, not a tutorial demo.
    - Every page should feel UNFORGETTABLE. What is the one thing someone will remember about this design?
    """

    /// Modification system prompt — preserves the existing aesthetic but applies
    /// the user's change. Less prescriptive than the generation prompt because
    /// the page already has a visual identity we don't want to overwrite.
    private let modifySystemPreamble = """
    You are AETHER. The user has an existing HTML page and wants a targeted change. Preserve the existing aesthetic, fonts, color palette, and layout direction. Apply the requested change cleanly. Return the COMPLETE modified HTML file. Return ONLY raw HTML. No markdown. No backticks. No explanation.
    """

    /// Generate a brand-new HTML page from a natural-language prompt.
    func generate(prompt: String, completion: @escaping (Result<String, Error>) -> Void) {
        post(systemPrompt: generateSystem, userPrompt: prompt, temperature: 0.7, completion: completion)
    }

    /// Modify existing HTML. If `selected` is non-nil, scope the change to that element.
    func modify(currentCode: String, prompt: String, selected: ElementInfo?, completion: @escaping (Result<String, Error>) -> Void) {
        let system: String
        if let sel = selected {
            let descriptor = "<\(sel.tag.lowercased()) class=\"\(sel.className)\" id=\"\(sel.id)\">\(sel.text)</\(sel.tag.lowercased())>"
            system = """
            \(modifySystemPreamble)

            CURRENT HTML:
            \(currentCode)

            The user has selected this specific element: \(descriptor). They want to: \
            \(prompt). Modify ONLY this element (or its inline styles).
            """
        } else {
            system = """
            \(modifySystemPreamble)

            CURRENT HTML:
            \(currentCode)

            The user wants to modify the page. Apply their change.
            """
        }
        // Lower temperature for modifications so iterations stay coherent with
        // the existing design rather than re-rolling a new aesthetic each turn.
        post(systemPrompt: system, userPrompt: prompt, temperature: 0.5, completion: completion)
    }

    // MARK: - Internals

    private func post(systemPrompt: String, userPrompt: String, temperature: Double, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: endpoint) else {
            completion(.failure(URLError(.badURL))); return
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            "temperature": temperature
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
                let choices = json?["choices"] as? [[String: Any]]
                let message = choices?.first?["message"] as? [String: Any]
                let text = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let raw = text, !raw.isEmpty else {
                    completion(.failure(URLError(.cannotDecodeContentData))); return
                }
                completion(.success(CodeGenerator.cleanFences(raw)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    /// Even with a "no markdown" instruction, models occasionally wrap output in
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
        if s.hasPrefix("html\n") { s = String(s.dropFirst(5)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
