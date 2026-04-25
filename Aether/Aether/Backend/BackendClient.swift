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

    /// Output of a generate / modify call. `files` holds every file in the
    /// project keyed by repo-relative path, `primary` is what the editor
    /// should open first, `previewHtml` is a self-contained HTML bundle the
    /// WKWebView can render directly (Babel-standalone wrap of the JSX, or a
    /// generated docs page for backend stacks), and `stack` describes the
    /// project shape ("react-vite", "express", "fastapi", "html").
    struct BuildResult: Equatable {
        var files: [String: String]
        var primary: String
        var previewHtml: String
        var stack: String
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
                // backend is offline. Detects the likely stack from the
                // user's prompt so the plan reads as "scaffolding a real
                // project" instead of the old "single index.html" stub.
                completion(.success(Self.fallbackPlan(prompt: prompt)))
            }
        }
    }

    // MARK: - Public API

    /// Generate a fresh project from a natural-language prompt. Returns a
    /// `BuildResult` containing every file in the project, the primary file
    /// to open, and a self-contained `previewHtml` bundle for the live
    /// preview pane.
    func generate(prompt: String, session: ProjectSession,
                  completion: @escaping (Result<BuildResult, Error>) -> Void) {
        let body: [String: Any] = ["prompt": prompt]
        callBackendBuild(path: "/api/build", body: body, baseURL: session.backendURL) { result in
            switch result {
            case .success(let payload):
                completion(.success(payload))
            case .failure(let err):
                print("BackendClient.generate falling back: \(err)")
                CodeGenerator.shared.generateProject(prompt: prompt, completion: completion)
            }
        }
    }

    /// Modify the current project given the user's prompt. Sends the full
    /// file map so the model can edit any subset of files (e.g. tweak
    /// `src/App.jsx` while leaving `package.json` alone).
    func modify(prompt: String, files: [String: String], primary: String,
                session: ProjectSession,
                completion: @escaping (Result<BuildResult, Error>) -> Void) {
        let body: [String: Any] = [
            "prompt": prompt,
            "files": files,
            "primary": primary
        ]
        callBackendBuild(path: "/api/modify", body: body, baseURL: session.backendURL) { result in
            switch result {
            case .success(let payload):
                completion(.success(payload))
            case .failure(let err):
                print("BackendClient.modify falling back: \(err)")
                CodeGenerator.shared.modifyProject(files: files, primary: primary,
                                                    prompt: prompt, selected: nil,
                                                    completion: completion)
            }
        }
    }

    /// Modify only a specific element (AR mode — element selected by pointing at preview).
    /// Element-targeted edits still come back as a full project result so the
    /// editor / preview / GitHub state stay consistent.
    func modifyElement(prompt: String, files: [String: String], primary: String,
                       element: ElementInfo, session: ProjectSession,
                       completion: @escaping (Result<BuildResult, Error>) -> Void) {
        let body: [String: Any] = [
            "prompt": prompt,
            "files": files,
            "primary": primary,
            "element": [
                "tag": element.tag,
                "class": element.className,
                "id": element.id,
                "text": element.text
            ]
        ]
        callBackendBuild(path: "/api/modify-element", body: body, baseURL: session.backendURL) { result in
            switch result {
            case .success(let payload):
                completion(.success(payload))
            case .failure(let err):
                print("BackendClient.modifyElement falling back: \(err)")
                CodeGenerator.shared.modifyProject(files: files, primary: primary,
                                                    prompt: prompt, selected: element,
                                                    completion: completion)
            }
        }
    }

    /// POST a build/modify request and decode either the new multi-file shape
    /// (`{ files, primary, preview_html, stack }`) or a legacy single-HTML
    /// payload (`{ html }`) which we wrap as a one-file project.
    private func callBackendBuild(path: String, body: [String: Any], baseURL: String,
                                  completion: @escaping (Result<BuildResult, Error>) -> Void) {
        callBackendJSON(path: path, body: body, baseURL: baseURL) { result in
            switch result {
            case .success(let json):
                if let payload = BackendClient.decodeBuildResult(json) {
                    completion(.success(payload))
                } else {
                    completion(.failure(BackendError.decoding))
                }
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    /// Best-effort decoder for `/api/build` and `/api/modify` responses.
    /// Accepts the new multi-file format and falls back to legacy
    /// `{ html | code }` payloads.
    static func decodeBuildResult(_ json: [String: Any]) -> BuildResult? {
        // New format: explicit files map.
        if let rawFiles = json["files"] as? [String: String], !rawFiles.isEmpty {
            let cleaned = rawFiles.mapValues { CodeGenerator.cleanFences($0) }
            let primary = (json["primary"] as? String).flatMap { cleaned[$0] != nil ? $0 : nil }
                ?? Self.pickPrimary(in: cleaned)
            let preview = (json["preview_html"] as? String)
                .map(CodeGenerator.cleanFences)
                ?? cleaned["index.html"]
                ?? Self.fallbackPreviewDocs(files: cleaned, stack: json["stack"] as? String ?? "unknown")
            let stack = (json["stack"] as? String) ?? "react-vite"
            return BuildResult(files: cleaned, primary: primary,
                               previewHtml: preview, stack: stack)
        }
        // Legacy format: single HTML / code string.
        if let html = (json["html"] as? String) ?? (json["code"] as? String), !html.isEmpty {
            let cleaned = CodeGenerator.cleanFences(html)
            return BuildResult(files: ["index.html": cleaned],
                               primary: "index.html",
                               previewHtml: cleaned,
                               stack: "html")
        }
        return nil
    }

    /// Pick a sensible default open-file when the response doesn't specify.
    static func pickPrimary(in files: [String: String]) -> String {
        let preferred = ["src/App.jsx", "src/App.tsx", "src/main.jsx", "src/main.tsx",
                         "App.jsx", "server.js", "main.py", "index.html"]
        for p in preferred where files[p] != nil { return p }
        return files.keys.sorted().first ?? "index.html"
    }

    /// Offline stub plan used when `/api/plan` is unreachable. We can't
    /// actually call an LLM here, so we keyword-sniff the stack from the
    /// prompt and emit a stack-shaped 4-step plan. The build that follows
    /// flows through `CodeGenerator.generateProject` (also offline) which
    /// returns a real multi-file project, so this plan needs to read like
    /// scaffolding, not "single-page index.html".
    static func fallbackPlan(prompt: String) -> PlanPayload {
        let lower = prompt.lowercased()
        let stack: String
        let summary: String
        let steps: [PlanStep]
        if lower.contains("api") || lower.contains("backend") || lower.contains("server")
            || lower.contains("express") || lower.contains("rest") {
            stack = "express"
            summary = "I'll scaffold a Node/Express backend for: \(prompt). Tell me to confirm."
            steps = [
                PlanStep(id: 1, action: "Scaffold project",
                         target: "package.json · server.js", why: "Express + CORS, port 3000"),
                PlanStep(id: 2, action: "Define routes",
                         target: "routes/*.js", why: "Endpoints for the requested domain"),
                PlanStep(id: 3, action: "Wire middleware",
                         target: "server.js", why: "JSON body parser, error handler"),
                PlanStep(id: 4, action: "Document",
                         target: "README.md · .env.example", why: "Usage + required env vars")
            ]
        } else if lower.contains("fastapi") || lower.contains("python") {
            stack = "fastapi"
            summary = "I'll scaffold a FastAPI backend for: \(prompt). Tell me to confirm."
            steps = [
                PlanStep(id: 1, action: "Scaffold app",
                         target: "main.py · requirements.txt", why: "FastAPI + uvicorn entry"),
                PlanStep(id: 2, action: "Define routers",
                         target: "routers/*.py", why: "Endpoints for the requested domain"),
                PlanStep(id: 3, action: "Add config",
                         target: ".env.example", why: "Required environment variables"),
                PlanStep(id: 4, action: "Document",
                         target: "README.md", why: "How to run + deploy")
            ]
        } else {
            stack = "react-vite"
            summary = "I'll scaffold a React + Vite project for: \(prompt). Tell me to confirm."
            steps = [
                PlanStep(id: 1, action: "Scaffold project",
                         target: "package.json · vite.config.js", why: "Vite + React 18 + scripts"),
                PlanStep(id: 2, action: "Compose UI",
                         target: "src/App.jsx", why: "Real components with Tailwind styling"),
                PlanStep(id: 3, action: "Wire entry",
                         target: "src/main.jsx · index.html", why: "createRoot into #root"),
                PlanStep(id: 4, action: "Polish",
                         target: "src/index.css · README.md", why: "Typography, spacing, run docs")
            ]
        }
        return PlanPayload(summary: summary, steps: steps,
                           expandedPrompt: "[stack:\(stack)] \(prompt)")
    }

    /// Render a placeholder preview page when a stack (e.g. an Express
    /// backend) can't actually run inside the WKWebView preview pane.
    static func fallbackPreviewDocs(files: [String: String], stack: String) -> String {
        let entries = files.keys.sorted().prefix(20)
            .map { "<li><code>\($0)</code></li>" }
            .joined()
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(stack) project</title>
        <style>
          body{font-family:-apple-system,BlinkMacSystemFont,Inter,sans-serif;background:#1e1f22;color:#bcbec4;padding:32px;margin:0}
          h1{font-size:18px;color:#fff;margin:0 0 4px}
          p{font-size:13px;color:#9ea1a8}
          ul{font-size:12px;line-height:1.6;color:#d5d7db;list-style:none;padding-left:0;margin-top:16px}
          code{background:#2b2d30;padding:2px 6px;border-radius:4px;color:#5fb865}
        </style></head><body>
          <h1>\(stack) project ready</h1>
          <p>Backend stacks don't run in the preview pane — push to GitHub to deploy.</p>
          <ul>\(entries)</ul>
        </body></html>
        """
    }

    // MARK: - Project analysis

    /// POST every project file + a free-form question to `/api/analyze` and
    /// return the model's plain-text answer. Used by AR voice queries
    /// ("what does Login do?") and AI code review (4-card grid).
    func analyze(files: [String: String],
                 question: String,
                 baseURL: String,
                 completion: @escaping (Result<String, Error>) -> Void) {
        let body: [String: Any] = ["files": files, "question": question]
        callBackendJSON(path: "/api/analyze", body: body, baseURL: baseURL) { result in
            switch result {
            case .success(let json):
                if let text = (json["response"] as? String), !text.isEmpty {
                    completion(.success(text))
                } else {
                    completion(.failure(BackendError.decoding))
                }
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    // MARK: - Code-edit sync (mongo)

    /// Fire-and-forget POST `/code-edits` so a teammate can replay the live
    /// edit stream from MongoDB. Errors are logged but never surface to the UI
    /// — the editor must keep working even if mongo is down.
    func recordCodeEdit(filename: String,
                        content: String,
                        previousContent: String?,
                        editType: String,
                        description: String?,
                        baseURL: String) {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBase.isEmpty,
              let url = URL(string: trimmedBase + "/code-edits") else { return }

        var body: [String: Any] = [
            "filename": filename,
            "content": content,
            "edit_type": editType,
        ]
        if let prev = previousContent { body["previous_content"] = prev }
        if let desc = description { body["description"] = desc }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { _, response, error in
            if let error = error {
                print("BackendClient.recordCodeEdit failed: \(error)")
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                print("BackendClient.recordCodeEdit non-200: \(http.statusCode)")
            }
        }.resume()
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
        // Suppresses ngrok's free-tier HTML interstitial on first hit —
        // without it, the page warning leaks into our JSON decoder.
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
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

}
