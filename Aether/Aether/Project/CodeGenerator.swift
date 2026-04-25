import Foundation

/// OpenAI GPT-4o wrapper for generating and modifying full single-file HTML pages.
/// (`GeminiClient` call sites now also route to OpenAI for "hey jarvis" Q&A.)
/// Always returns raw HTML; markdown fences and stray "html" prefixes are stripped.
final class CodeGenerator {
    static let shared = CodeGenerator()

    private let apiKey = Secrets.openAIKey
    private let endpoint = "https://api.openai.com/v1/chat/completions"
    private let model = "gpt-4o"
    private let timeout: TimeInterval = 60

    private init() {}

    /// React-via-CDN + Tailwind-via-CDN system prompt. No build step — everything
    /// runs straight in the WKWebView preview.
    private let generateSystem = """
    You are a world-class frontend developer. Generate a single HTML file that uses React 18 via CDN and Tailwind CSS via CDN.

    The HTML file must include these script tags in <head>:
    <script src='https://unpkg.com/react@18/umd/react.production.min.js'></script>
    <script src='https://unpkg.com/react-dom@18/umd/react-dom.production.min.js'></script>
    <script src='https://unpkg.com/@babel/standalone/babel.min.js'></script>
    <script src='https://cdn.tailwindcss.com'></script>

    Write React components inside a <script type='text/babel'> tag. Use Tailwind classes for all styling. Render into a div with id='root'.

    DESIGN RULES:
    - Use Google Fonts via <link> in head. Good fonts: DM Sans, Plus Jakarta Sans, Sora, Outfit, Manrope. Pick one.
    - Color: 2-3 colors max. Muted, professional, modern. Good dark palette: bg-neutral-950, cards bg-neutral-900, accent blue-500 or orange-500, text neutral-50
    - NO neon colors. NO hot pink. NO gradients. NO rainbow.
    - Layout: max-w-5xl mx-auto, good padding (p-8, p-12)
    - Components: rounded-2xl, shadow-sm, clean borders
    - Typography: text-4xl font-bold for headings, text-base for body, good line-height (leading-relaxed)
    - Spacing: generous. gap-6, space-y-8, py-20 for sections
    - Make it look like a Vercel or Linear marketing page
    - Use real Unsplash images where appropriate: https://images.unsplash.com/photo-ID?w=800
    - Dark theme by default

    Return ONLY the raw HTML. No markdown. No backticks. No explanation.
    """

    /// Modification system prompt — preserves the existing aesthetic but applies
    /// the user's change. Less prescriptive than the generation prompt because
    /// the page already has a visual identity we don't want to overwrite.
    private let modifySystemPreamble = """
    You are a world-class frontend developer. The user has an existing HTML page that uses React 18 + Tailwind CSS via CDN, with React components inside a <script type='text/babel'> tag rendered into div#root. Preserve that structure, the existing fonts, color palette, and overall layout direction. Apply the requested change cleanly. Return the COMPLETE modified HTML file. Return ONLY raw HTML. No markdown. No backticks. No explanation.
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
