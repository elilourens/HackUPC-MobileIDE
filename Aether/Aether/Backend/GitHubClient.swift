import Foundation

/// Minimal GitHub Contents API client (list / get / put). Token + repo are
/// pulled from `ProjectSession` so the user can rotate them via the settings
/// sheet without restarting.
@MainActor
final class GitHubClient {
    static let shared = GitHubClient()
    private init() {}

    enum GHError: Error {
        case notConfigured
        case badResponse(status: Int, body: String)
        case decoding
    }

    struct RepoEntry: Identifiable, Equatable {
        var id: String { path }
        let name: String
        let path: String
        let type: String   // "file" | "dir"
        let sha: String
        let downloadURL: String?
    }

    // MARK: - List

    /// List the contents of `path` ("" = repo root). Calls `completion` on the main thread.
    func listContents(path: String, session: ProjectSession,
                      completion: @escaping (Result<[RepoEntry], Error>) -> Void) {
        guard !session.gitHubToken.isEmpty, !session.gitHubRepo.isEmpty else {
            completion(.failure(GHError.notConfigured)); return
        }
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlStr = "https://api.github.com/repos/\(session.gitHubRepo)/contents/\(cleanPath)"
        guard let url = URL(string: urlStr) else {
            completion(.failure(URLError(.badURL))); return
        }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(session.gitHubToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

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
                    completion(.failure(GHError.badResponse(status: http.statusCode, body: bodyStr)))
                }
                return
            }
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                DispatchQueue.main.async { completion(.failure(GHError.decoding)) }; return
            }
            let entries: [RepoEntry] = arr.compactMap { d in
                guard let name = d["name"] as? String,
                      let p    = d["path"] as? String,
                      let t    = d["type"] as? String,
                      let sha  = d["sha"] as? String else { return nil }
                return RepoEntry(name: name, path: p, type: t, sha: sha,
                                 downloadURL: d["download_url"] as? String)
            }
            DispatchQueue.main.async { completion(.success(entries)) }
        }.resume()
    }

    // MARK: - Get file (returns text + sha)

    func getFile(path: String, session: ProjectSession,
                 completion: @escaping (Result<(text: String, sha: String), Error>) -> Void) {
        guard !session.gitHubToken.isEmpty, !session.gitHubRepo.isEmpty else {
            completion(.failure(GHError.notConfigured)); return
        }
        let urlStr = "https://api.github.com/repos/\(session.gitHubRepo)/contents/\(path)"
        guard let url = URL(string: urlStr) else {
            completion(.failure(URLError(.badURL))); return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(session.gitHubToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, response, _ in
            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(URLError(.zeroByteResource))) }; return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let bodyStr = String(data: data, encoding: .utf8) ?? "<no body>"
                DispatchQueue.main.async {
                    completion(.failure(GHError.badResponse(status: http.statusCode, body: bodyStr)))
                }
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contentB64 = (json["content"] as? String)?
                    .replacingOccurrences(of: "\n", with: ""),
                  let sha = json["sha"] as? String,
                  let decoded = Data(base64Encoded: contentB64),
                  let text = String(data: decoded, encoding: .utf8) else {
                DispatchQueue.main.async { completion(.failure(GHError.decoding)) }; return
            }
            DispatchQueue.main.async { completion(.success((text, sha))) }
        }.resume()
    }

    // MARK: - Put file (create or update)

    /// Create or update a file. If `sha` is non-nil, it's an update; otherwise a create.
    func putFile(path: String, text: String, sha: String?, message: String,
                 session: ProjectSession,
                 completion: @escaping (Result<String, Error>) -> Void) {
        guard !session.gitHubToken.isEmpty, !session.gitHubRepo.isEmpty else {
            completion(.failure(GHError.notConfigured)); return
        }
        let urlStr = "https://api.github.com/repos/\(session.gitHubRepo)/contents/\(path)"
        guard let url = URL(string: urlStr) else {
            completion(.failure(URLError(.badURL))); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(session.gitHubToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let b64 = Data(text.utf8).base64EncodedString()
        var body: [String: Any] = [
            "message": message,
            "content": b64
        ]
        if let sha = sha { body["sha"] = sha }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, response, _ in
            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(URLError(.zeroByteResource))) }; return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let bodyStr = String(data: data, encoding: .utf8) ?? "<no body>"
                DispatchQueue.main.async {
                    completion(.failure(GHError.badResponse(status: http.statusCode, body: bodyStr)))
                }
                return
            }
            // Pull the new SHA from the response so the next push doesn't 409.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? [String: Any],
               let newSha = content["sha"] as? String {
                DispatchQueue.main.async { completion(.success(newSha)) }
            } else {
                DispatchQueue.main.async { completion(.success("")) }
            }
        }.resume()
    }
}
