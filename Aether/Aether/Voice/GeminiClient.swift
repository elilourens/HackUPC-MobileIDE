import Foundation

/// Q&A client for free-form questions ("how do I center a div").
/// Kept as `GeminiClient` for compatibility with existing call sites, but now uses OpenAI.
final class GeminiClient {
    static let shared = GeminiClient()

    private let apiKey = Secrets.openAIKey

    private init() {}

    /// System guidance — JARVIS is concise and efficient.
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
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": systemPreamble],
                ["role": "user", "content": question],
            ],
            "temperature": 0.6,
            "max_tokens": 120
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
                print("AskClient(OpenAI) HTTP \(http.statusCode): \(body)")
                completion(.failure(URLError(.badServerResponse))); return
            }
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let choices = json?["choices"] as? [[String: Any]]
                let message = choices?.first?["message"] as? [String: Any]
                let text = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
