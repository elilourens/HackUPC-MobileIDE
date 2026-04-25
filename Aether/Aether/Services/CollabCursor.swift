import Foundation
import Combine

/// RemoteCursor represents a cursor position from a collaborator (e.g., Eli in the plugin).
struct RemoteCursor: Equatable {
    let file: String
    let line: Int
    let column: Int
    let name: String
}

/// CollabCursor manages real-time cursor synchronization over WebSocket.
///
/// ARCHITECTURE NOTES:
/// - This service connects to the backend's `/ws/sync` endpoint as an "ios" client.
/// - The backend relays messages bidirectionally between iOS and plugin clients.
/// - Message format: `{type: "cursor", file: <path>, line: <int>, column: <int>, name: <string>}`
///
/// VERCEL LIMITATION:
/// The WebSocket works well on local (localhost:8000 or ngrok), but NOT reliably on Vercel.
/// Vercel uses Fluid Compute where each instance has its own in-memory `connected_clients` dict —
/// iOS and plugin may route to different instances, breaking the relay. For production Vercel,
/// this needs either:
/// 1. A shared Redis/cache layer (not in scope here)
/// 2. Polling fallback via `GET /code-edits?source=cursor&since=<timestamp>` every 1s
///
/// This implementation ships the WS approach as primary. The polling fallback is a TODO.
/// For demo + local laptop run, the WS works perfectly.
///
/// USAGE:
/// ```swift
/// let collabCursor = CollabCursor(session: session, backendURL: backendURL)
/// collabCursor.connect()
/// // Subscribe to cursor updates
/// session.$remoteCursor.sink { cursor in
///     if let cursor = cursor, cursor.file == currentFile {
///         renderCursorLine(at: cursor.line)
///     }
/// }.store(in: &cancellables)
/// ```
@MainActor
final class CollabCursor: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published var remoteCursor: RemoteCursor? = nil

    private weak var session: ProjectSession?
    private let backendURL: String
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private let cursorDebounceInterval: TimeInterval = 0.15

    init(session: ProjectSession, backendURL: String) {
        self.session = session
        self.backendURL = backendURL
        super.init()
    }

    /// Connect to the backend WebSocket. Determines protocol (ws:// vs wss://)
    /// based on backend URL scheme.
    func connect() {
        // Only enable WS on local backends (localhost:8000, ngrok) or explicit ws:// URLs.
        // For Vercel-hosted backends (https://...), skip WS and document the limitation.
        guard shouldEnableWebSocket() else {
            print("CollabCursor: WS disabled on Vercel; polling fallback TODO")
            return
        }

        // Transform backend URL to WebSocket URL
        let wsURL = transformToWebSocketURL(backendURL)
        guard let url = URL(string: wsURL) else {
            print("CollabCursor: Invalid WebSocket URL: \(wsURL)")
            return
        }

        print("CollabCursor: Connecting to \(url)")
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600

        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let ws = session.webSocketTask(with: url)
        self.webSocket = ws
        ws.resume()

        // Send initial handshake — backend.py expects `client_type` to route
        // ios/plugin relays correctly.
        Task { @MainActor in
            do {
                let handshake: [String: String] = ["client_type": "ios"]
                let data = try JSONSerialization.data(withJSONObject: handshake)
                let jsonString = String(data: data, encoding: .utf8) ?? "{}"
                try await ws.send(URLSessionWebSocketTask.Message.string(jsonString))
            } catch {
                print("CollabCursor: Handshake failed: \(error)")
            }
        }

        // Begin receiving messages
        beginReceivingMessages()
    }

    /// Disconnect the WebSocket cleanly.
    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        webSocket?.cancel(with: URLSessionWebSocketTask.CloseCode.goingAway, reason: nil)
        webSocket = nil
    }

    /// Called by AR/phone IDE when the local cursor moves. Debounced to avoid flooding.
    func updateLocalCursor(file: String, line: Int, column: Int) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(cursorDebounceInterval * 1_000_000_000))
            if !Task.isCancelled {
                await sendCursorMessage(file: file, line: line, column: column)
            }
        }
    }

    // MARK: - Private

    private func shouldEnableWebSocket() -> Bool {
        // Enable on localhost or ngrok URLs, disable on Vercel
        return backendURL.contains(":8000")
            || backendURL.contains("ngrok")
            || backendURL.contains("localhost")
            || backendURL.hasPrefix("ws://")
            || backendURL.hasPrefix("wss://")
    }

    private func transformToWebSocketURL(_ backendURL: String) -> String {
        var wsURL = backendURL
        if wsURL.hasPrefix("https://") {
            wsURL = "wss://" + wsURL.dropFirst(8)
        } else if wsURL.hasPrefix("http://") {
            wsURL = "ws://" + wsURL.dropFirst(7)
        }
        // Ensure path ends with /ws/sync
        if !wsURL.hasSuffix("/ws/sync") {
            if wsURL.hasSuffix("/") {
                wsURL += "ws/sync"
            } else {
                wsURL += "/ws/sync"
            }
        }
        return wsURL
    }

    private func beginReceivingMessages() {
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    let message = try await webSocket?.receive()
                    switch message {
                    case .string(let jsonString):
                        guard let data = jsonString.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        await handleIncomingMessage(json)
                    case .data(let data):
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            await handleIncomingMessage(json)
                        }
                    default:
                        break
                    }
                } catch {
                    print("CollabCursor: Receive error: \(error)")
                    // Attempt reconnect after brief delay
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !Task.isCancelled {
                        await MainActor.run { [weak self] in
                            self?.connect()
                        }
                    }
                    break
                }
            }
        }
    }

    private func handleIncomingMessage(_ json: [String: Any]) async {
        guard let messageType = json["type"] as? String else { return }

        if messageType == "cursor" {
            guard let file = json["file"] as? String,
                  let line = json["line"] as? Int,
                  let column = json["column"] as? Int,
                  let name = json["name"] as? String else {
                return
            }

            let cursor = RemoteCursor(file: file, line: line, column: column, name: name)
            await MainActor.run { [weak self] in
                self?.remoteCursor = cursor
            }
        }
    }

    private func sendCursorMessage(file: String, line: Int, column: Int) async {
        guard let ws = webSocket else { return }

        let message: [String: Any] = [
            "type": "cursor",
            "file": file,
            "line": line,
            "column": column,
            "name": "Akshat"
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        do {
            try await ws.send(URLSessionWebSocketTask.Message.string(jsonString))
        } catch {
            print("CollabCursor: Send failed: \(error)")
        }
    }

    // URLSessionWebSocketDelegate
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("CollabCursor: WebSocket connected")
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("CollabCursor: WebSocket disconnected")
    }
}
