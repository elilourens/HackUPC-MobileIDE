import Foundation
import AVFoundation

/// ElevenLabs text-to-speech wrapper for the JARVIS voice. Caches rendered audio per
/// canonical phrase so repeated lines (e.g. "Done.", "On it.") don't re-hit the API.
/// Speech is **queued** — back-to-back `speak()` calls play sequentially instead of
/// stomping on each other. Earlier the plan-summary line was getting cut off after
/// one or two words because `speak("Shall I proceed?")` arrived while the summary
/// was still playing and the player slot was simply reassigned.
final class JarvisVoice: NSObject {
    static let shared = JarvisVoice()

    private let apiKey = Secrets.elevenLabsKey
    private let voiceId = Secrets.elevenLabsVoiceId

    private let lock = NSLock()
    private var cache: [String: Data] = [:]
    private var player: AVAudioPlayer?
    /// Pending audio waiting for the current player to finish. FIFO.
    private var queue: [Data] = []
    private var isPlaying: Bool = false

    private override init() { super.init() }

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
    /// Requests are SERIALIZED (not parallel) with a small inter-request delay so
    /// we stay under ElevenLabs' rate limit. Earlier we fired all 16 phrases in
    /// parallel and got blanket-429'd by the API.
    func preload(_ phrases: [String]) {
        let normalized = phrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let toFetch = normalized.filter { key in
            lock.lock()
            let already = cache[key] != nil
            lock.unlock()
            return !already
        }
        guard !toFetch.isEmpty else { return }

        // Recursive serial worker: fetch phrase[i], then schedule phrase[i+1]
        // 400ms after the response lands. Stays under the rate limit and keeps
        // total preload time bounded (16 phrases × ~0.6s ≈ 10s, fully background).
        let interRequestDelay: TimeInterval = 0.4
        var index = 0
        func next() {
            guard index < toFetch.count else { return }
            let key = toFetch[index]
            index += 1
            self.fetch(text: key) { [weak self] data in
                guard let self = self else { return }
                if let data = data {
                    self.lock.lock()
                    self.cache[key] = data
                    self.lock.unlock()
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interRequestDelay) {
                    next()
                }
            }
        }
        next()
    }

    private func playOnMain(_ data: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // If something is currently playing, queue this clip so it plays
            // after the active one finishes — never interrupt mid-line.
            if self.isPlaying {
                self.queue.append(data)
                return
            }
            self.startPlayback(data)
        }
    }

    /// Spin up an AVAudioPlayer for `data`, set ourselves as the delegate so
    /// we can chain to the next queued clip when it finishes, and play.
    private func startPlayback(_ data: Data) {
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            self.player = p
            self.isPlaying = true
        } catch {
            print("JARVIS playback error: \(error.localizedDescription)")
            self.isPlaying = false
            self.drainQueue()
        }
    }

    /// Pop the next queued clip (if any) and play it.
    private func drainQueue() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        startPlayback(next)
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

extension JarvisVoice: AVAudioPlayerDelegate {
    /// Called when one queued clip finishes — pop the next from the queue
    /// and play it, so back-to-back `speak()` calls flow as one continuous
    /// monologue instead of interrupting each other.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isPlaying = false
            self.drainQueue()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isPlaying = false
            self.drainQueue()
        }
    }
}
