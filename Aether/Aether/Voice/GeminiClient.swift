import Foundation

/// Gemini text-generation client for free-form questions ("how do I center a div").
final class GeminiClient {
    static let shared = GeminiClient()

    // Provided by the user — embedded for hackathon demo only.
    private let apiKey = "AIzaSyBFCjjIhSflPOVS9jvw1H_60ULtQjI-Q0k"

    private init() {}

    /// System guidance — JARVIS is concise and efficient.
    private let systemPreamble = """
    You are JARVIS, Tony Stark's AI assistant, helping a developer in their AR coding workspace.
    Answer in 1-2 short sentences. Be direct, technical, and slightly dry. Never apologize.
    """

    func ask(_ question: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)") else {
            completion(.failure(URLError(.badURL))); return
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "system_instruction": [
                "parts": [["text": systemPreamble]]
            ],
            "contents": [
                ["parts": [["text": question]], "role": "user"]
            ],
            "generationConfig": [
                "temperature": 0.6,
                "maxOutputTokens": 120
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
                print("Gemini HTTP \(http.statusCode): \(body)")
                completion(.failure(URLError(.badServerResponse))); return
            }
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let candidates = json?["candidates"] as? [[String: Any]]
                let content = candidates?.first?["content"] as? [String: Any]
                let parts = content?["parts"] as? [[String: Any]]
                let text = (parts?.first?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
