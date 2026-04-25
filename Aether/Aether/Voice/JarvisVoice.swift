import Foundation
import AVFoundation

/// ElevenLabs text-to-speech wrapper for the JARVIS voice. Caches rendered audio per
/// canonical phrase so repeated lines (e.g. "Done.", "On it.") don't re-hit the API.
final class JarvisVoice {
    static let shared = JarvisVoice()

    // Provided by the user — embedded for hackathon demo only. Don't ship this in prod.
    private let apiKey = "sk_c21daf75fcda4ae607d4d2eb015f35ea8148bc6de1f3de51"
    private let voiceId = "lUTamkMw7gOzZbFIwmq4"

    private let lock = NSLock()
    private var cache: [String: Data] = [:]
    private var player: AVAudioPlayer?

    private init() {}

    /// Speak a phrase. Cached audio plays immediately; uncached audio fetches first.
    func speak(_ text: String) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        lock.lock()
        let cached = cache[key]
        lock.unlock()

        if let cached = cached {
            playOnMain(cached)
            return
        }
        fetch(text: key) { [weak self] data in
            guard let self = self, let data = data else { return }
            self.lock.lock()
            self.cache[key] = data
            self.lock.unlock()
            self.playOnMain(data)
        }
    }

    /// Pre-cache phrases without playing them. Useful at app start for canned lines.
    func preload(_ phrases: [String]) {
        for phrase in phrases {
            let key = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            lock.lock()
            let already = cache[key] != nil
            lock.unlock()
            guard !already else { continue }
            fetch(text: key) { [weak self] data in
                guard let self = self, let data = data else { return }
                self.lock.lock()
                self.cache[key] = data
                self.lock.unlock()
            }
        }
    }

    private func playOnMain(_ data: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            do {
                let p = try AVAudioPlayer(data: data)
                p.prepareToPlay()
                p.play()
                self.player = p  // strong ref so it isn't deallocated mid-playback
            } catch {
                print("JARVIS playback error: \(error.localizedDescription)")
            }
        }
    }

    private func fetch(text: String, completion: @escaping (Data?) -> Void) {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)") else {
            completion(nil); return
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2",
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                print("JARVIS network error: \(error.localizedDescription)")
                completion(nil); return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                print("JARVIS HTTP \(http.statusCode)")
                completion(nil); return
            }
            completion(data)
        }.resume()
    }
}
