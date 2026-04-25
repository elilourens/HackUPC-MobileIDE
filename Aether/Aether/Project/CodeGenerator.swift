import Foundation

/// OpenAI GPT-4o wrapper for generating and modifying full single-file HTML pages.
/// (Q&A "hey jarvis" prompts go through `JarvisAssistant`, also OpenAI-backed.)
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

    // MARK: - Project-level (multi-file) JSON-mode codegen

    /// Multi-file project system prompt. The model returns JSON shaped as
    /// `{ files, primary, preview_html, stack }` so we can populate the IDE
    /// project tree with a real React / Express / FastAPI structure AND keep
    /// a self-contained `preview_html` that runs in WKWebView (Babel
    /// standalone for JSX, or a generated docs page for backends).
    private let generateProjectSystem = """
    You are a senior full-stack engineer. The user is building a project on their phone — there is no terminal, no `npm install`, no Docker. They just want a runnable, tasteful, real project that they can also push to GitHub.

    Decide the right stack from the prompt:
    - "landing page", "marketing site", "portfolio", "dashboard", anything UI → react-vite
    - "API", "backend", "server", "REST" → express
    - "FastAPI", "python backend" → fastapi
    - "blog", "static site" → html (single file)

    Return JSON with exactly this shape (no markdown, no prose):
    {
      "stack": "react-vite" | "express" | "fastapi" | "html",
      "primary": "<repo-relative path to open first>",
      "files": { "<repo-relative path>": "<full file content>", ... },
      "preview_html": "<self-contained HTML the WKWebView can render directly>"
    }

    REACT (react-vite) projects MUST include:
      - package.json (with vite, react, react-dom in deps; "scripts": { "dev": "vite", "build": "vite build" })
      - vite.config.js
      - index.html (Vite root with #root and <script type="module" src="/src/main.jsx">)
      - src/main.jsx (createRoot + import App from "./App.jsx")
      - src/App.jsx (the actual UI — beautiful Tailwind-style design via inline classes or CSS modules)
      - src/index.css
      - src/App.css (optional)
      - README.md (one-paragraph project description + how to run)
    primary = "src/App.jsx".
    preview_html = a SELF-CONTAINED page that loads React 18 + ReactDOM 18 + Babel standalone + Tailwind CDN, then INLINES the App component(s) inside <script type="text/babel"> and renders them into #root. The preview must work with NO file system / NO node — it's the only way the user sees the page.

    EXPRESS (express) projects MUST include:
      - package.json (with express, cors)
      - server.js (app.listen(3000), example routes for /api/health and the user's domain)
      - routes/ (one file per resource if applicable)
      - .env.example
      - README.md
    primary = "server.js".
    preview_html = a generated docs page listing the routes (no live server in WKWebView).

    FASTAPI (fastapi) projects MUST include:
      - main.py (FastAPI app + uvicorn entry)
      - requirements.txt
      - routers/ (if applicable)
      - .env.example
      - README.md
    primary = "main.py".
    preview_html = a generated docs page listing the endpoints.

    HTML (html) projects: one index.html. primary = "index.html". preview_html = same as the file.

    DESIGN RULES (UI projects):
    - Use Google Fonts via <link>. DM Sans / Plus Jakarta Sans / Sora / Outfit / Manrope.
    - 2–3 muted, professional colors. Dark theme by default (bg-neutral-950, cards bg-neutral-900). NO neon, NO rainbow.
    - Generous spacing (p-8/p-12, gap-6, space-y-8, py-20).
    - Components: rounded-2xl, soft shadows, clean borders.
    - Real Unsplash photos when relevant: https://images.unsplash.com/photo-ID?w=800
    - Vercel / Linear / Stripe-grade polish.

    Return ONLY the JSON object. No markdown fences. No commentary.
    """

    /// JSON-mode generation that returns a full multi-file `BuildResult`.
    func generateProject(prompt: String,
                         completion: @escaping (Result<BackendClient.BuildResult, Error>) -> Void) {
        postJSON(systemPrompt: generateProjectSystem, userPrompt: prompt,
                 temperature: 0.7, completion: completion)
    }

    /// JSON-mode modification — sends the full project, asks the model for the
    /// updated project. We also send an `element` hint when the user picked a
    /// specific element in the AR preview, so single-element edits are scoped.
    func modifyProject(files: [String: String], primary: String,
                       prompt: String, selected: ElementInfo?,
                       completion: @escaping (Result<BackendClient.BuildResult, Error>) -> Void) {
        var system = generateProjectSystem + """


        CONTEXT: This is a MODIFICATION of an existing project. Preserve the
        existing stack, file layout, design language, and component structure.
        Edit only what's necessary. Return the COMPLETE project (every file)
        in the same JSON shape so the IDE can replace the project atomically.
        """
        if let sel = selected {
            let descriptor = "<\(sel.tag.lowercased()) class=\"\(sel.className)\" id=\"\(sel.id)\">\(sel.text)</\(sel.tag.lowercased())>"
            system += "\n\nThe user has selected this element to scope the change to: \(descriptor)."
        }
        // Embed current files as a serialized blob so the model has the
        // existing source code to diff against.
        let filesPayload = (try? JSONSerialization.data(withJSONObject: files))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let userMessage = """
        CURRENT PROJECT (primary = \(primary)):
        \(filesPayload)

        REQUESTED CHANGE:
        \(prompt)
        """
        postJSON(systemPrompt: system, userPrompt: userMessage,
                 temperature: 0.5, completion: completion)
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

    /// JSON-mode wrapper around OpenAI chat completions for project-level
    /// codegen. Forces `response_format: json_object` so the model can't slip
    /// markdown or prose in front of the structured output.
    private func postJSON(systemPrompt: String, userPrompt: String, temperature: Double,
                          completion: @escaping (Result<BackendClient.BuildResult, Error>) -> Void) {
        guard let url = URL(string: endpoint) else {
            completion(.failure(URLError(.badURL))); return
        }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            "temperature": temperature,
            "response_format": ["type": "json_object"]
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
                let bodyStr = String(data: data, encoding: .utf8) ?? "<no body>"
                print("CodeGenerator(JSON) HTTP \(http.statusCode): \(bodyStr)")
                completion(.failure(URLError(.badServerResponse))); return
            }
            do {
                let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let choices = outer?["choices"] as? [[String: Any]]
                let message = choices?.first?["message"] as? [String: Any]
                guard let content = message?["content"] as? String, !content.isEmpty,
                      let inner = content.data(using: .utf8),
                      let project = try JSONSerialization.jsonObject(with: inner) as? [String: Any]
                else {
                    completion(.failure(URLError(.cannotDecodeContentData))); return
                }
                if let result = BackendClient.decodeBuildResult(project) {
                    DispatchQueue.main.async { completion(.success(result)) }
                } else {
                    completion(.failure(URLError(.cannotDecodeContentData)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

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
