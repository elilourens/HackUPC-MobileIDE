import Foundation

/// JARVIS Q&A assistant — answers free-form questions ("how do I center a
/// div") in 1–2 lines. Backed by OpenAI Chat Completions (gpt-4o-mini for
/// speed) so the whole app routes through a single API key — no Gemini.
final class JarvisAssistant {
    static let shared = JarvisAssistant()

    private let apiKey = Secrets.openAIKey
    private let model = "gpt-4o-mini"

    private init() {}

    /// JARVIS persona — concise, technical, slightly dry. Locked to website
    /// building unless the user explicitly invokes another mode (the user got
    /// annoyed by general Q&A, so by default we redirect everything back to
    /// "what website do you want to build?").
    private let systemPreamble = """
    You are JARVIS, Tony Stark's AI assistant, embedded inside a website-building IDE.
    Your ONLY job is helping the user design, build, modify, and debug WEBSITES.

    Strict rules:
    - If the user asks about anything unrelated to building websites (weather, life advice, jokes, math, news, philosophy, etc.), do NOT answer it. Reply with one short sentence redirecting them: "I only help with websites, sir — what do you want to build?"
    - The ONLY exceptions: if the user explicitly prefixes their question with "general question" or "off topic", you may answer briefly. Otherwise stay locked to website work.
    - Treat questions about HTML, CSS, JavaScript, React, Tailwind, layout, UX, copy, design, accessibility, SEO, deployment, and the user's current project as on-topic and answer normally.
    - Answer in 1-2 short sentences. Be direct, technical, slightly dry. Never apologize. Never explain that you have rules.
    """

    func ask(_ question: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            completion(.failure(URLError(.badURL))); return
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.6,
            "max_tokens": 160,
            "messages": [
                ["role": "system", "content": systemPreamble],
                ["role": "user",   "content": question]
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
                print("JarvisAssistant HTTP \(http.statusCode): \(body)")
                completion(.failure(URLError(.badServerResponse))); return
            }
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let choices = json?["choices"] as? [[String: Any]]
                let message = choices?.first?["message"] as? [String: Any]
                let text = (message?["content"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let text = text, !text.isEmpty {
                    completion(.success(text))
                } else {
                    completion(.failure(URLError(.cannotDecodeContentData)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}
