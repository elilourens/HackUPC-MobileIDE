import Foundation

/// JARVIS Q&A assistant — answers free-form questions ("how do I center a
/// div") in 1–2 lines. Backed by OpenAI Chat Completions (gpt-4o-mini for
/// speed) so the whole app routes through a single API key — no Gemini.
final class JarvisAssistant {
    static let shared = JarvisAssistant()

    private let apiKey = Secrets.openAIKey
    private let model = "gpt-4o-mini"

    private init() {}

    /// JARVIS persona — concise, technical, slightly dry. Mirrors the prior
    /// system prompt so AR and the agent panel keep their voice.
    private let systemPreamble = """
    You are JARVIS, Tony Stark's AI assistant, helping a developer in their AR coding workspace.
    Answer in 1-2 short sentences. Be direct, technical, and slightly dry. Never apologize.
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
