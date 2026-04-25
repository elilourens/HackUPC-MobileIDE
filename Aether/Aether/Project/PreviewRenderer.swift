import Foundation
import UIKit
import WebKit

/// Off-screen WKWebView that renders the live HTML, snapshots it for use as a panel
/// texture, and supports element-level selection via JavaScript injection.
///
/// All public methods are MainActor — WKWebView and snapshotting are main-thread only.
@MainActor
final class PreviewRenderer: NSObject, WKNavigationDelegate {
    /// Logical content size used both for the WKWebView frame and for UV→pixel
    /// mapping when the user points at the panel. Kept in sync with the JS
    /// `document.elementFromPoint` coordinate space.
    static let contentSize = CGSize(width: 375, height: 667)

    /// CSS injected on every load so selected elements get a cyan outline.
    private static let selectionStyle = """
    .aether-selected { outline: 2px solid cyan !important; outline-offset: 2px !important; }
    """

    private let webView: WKWebView
    /// Off-screen host so the web view actually lays out (a WKWebView in zero
    /// hierarchy can stall layout on some iOS versions). Added to a hidden
    /// UIWindow at app start.
    private let host: UIView

    private var loadCompletion: ((UIImage?) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        let style = WKUserScript(
            source: "var s=document.createElement('style');s.innerHTML=\(PreviewRenderer.escapeForJS(PreviewRenderer.selectionStyle));document.head.appendChild(s);",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        userContent.addUserScript(style)
        config.userContentController = userContent

        webView = WKWebView(frame: CGRect(origin: .zero, size: PreviewRenderer.contentSize), configuration: config)
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false

        host = UIView(frame: CGRect(origin: .zero, size: PreviewRenderer.contentSize))
        host.isHidden = true
        host.addSubview(webView)

        super.init()
        webView.navigationDelegate = self

        // Attach the host to the key window so layout actually runs.
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first {
            window.addSubview(host)
        }
    }

    // MARK: - Public API

    /// Load HTML, wait for didFinish + a small settling delay, then snapshot.
    /// `delay` lets callers ask for a longer wait on the very first generation
    /// (web fonts / images settle in) vs. subsequent edits.
    func loadHTML(_ html: String, settleDelay: TimeInterval = 0.5, completion: @escaping (UIImage?) -> Void) {
        // Replace any pending callback — only the latest snapshot is meaningful.
        loadCompletion = { [weak self] image in
            guard self != nil else { completion(nil); return }
            completion(image)
        }
        // Stash the settle delay so didFinish picks it up.
        self.pendingSettleDelay = settleDelay
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// Take an immediate snapshot of whatever's currently rendered.
    func snapshot(completion: @escaping (UIImage?) -> Void) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(origin: .zero, size: PreviewRenderer.contentSize)
        webView.takeSnapshot(with: cfg) { image, _ in
            completion(image)
        }
    }

    /// Inject JS to find and outline the element at the given point in the
    /// WKWebView's coordinate space (origin top-left, in CSS pixels). Calls back
    /// on the main thread with element info + a fresh snapshot showing the
    /// outline.
    func selectElement(at pointInWeb: CGPoint, completion: @escaping (ElementInfo?, UIImage?) -> Void) {
        let js = """
        (function() {
          document.querySelectorAll('.aether-selected').forEach(function(el){ el.classList.remove('aether-selected'); });
          var el = document.elementFromPoint(\(pointInWeb.x), \(pointInWeb.y));
          if (!el || el === document.body || el === document.documentElement) { return null; }
          el.classList.add('aether-selected');
          return JSON.stringify({
            tag: el.tagName || '',
            id: el.id || '',
            className: (typeof el.className === 'string') ? el.className : '',
            text: (el.textContent || '').slice(0, 50)
          });
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { completion(nil, nil); return }
            var info: ElementInfo?
            if let raw = result as? String,
               let data = raw.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                info = ElementInfo(
                    tag: (json["tag"] as? String) ?? "",
                    id: (json["id"] as? String) ?? "",
                    className: (json["className"] as? String) ?? "",
                    text: (json["text"] as? String) ?? ""
                )
            }
            // Wait briefly for the outline to paint before snapshotting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.snapshot { image in
                    completion(info, image)
                }
            }
        }
    }

    /// Remove any selection outline. Calls back with a fresh snapshot.
    func clearSelection(completion: @escaping (UIImage?) -> Void) {
        let js = "document.querySelectorAll('.aether-selected').forEach(function(el){ el.classList.remove('aether-selected'); });"
        webView.evaluateJavaScript(js) { [weak self] _, _ in
            guard let self = self else { completion(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                self.snapshot { image in completion(image) }
            }
        }
    }

    // MARK: - WKNavigationDelegate

    private var pendingSettleDelay: TimeInterval = 0.5

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // WKWebView calls didFinish on the main thread, but the protocol method is
        // nonisolated, so we hop to MainActor explicitly for type safety.
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let settle = self.pendingSettleDelay
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            self.snapshot { image in
                self.loadCompletion?(image)
                self.loadCompletion = nil
            }
        }
    }

    // MARK: - JS escape

    private static func escapeForJS(_ raw: String) -> String {
        // Wrap in single quotes; escape backslashes, single quotes, newlines.
        var s = raw
        s = s.replacingOccurrences(of: "\\", with: "\\\\")
        s = s.replacingOccurrences(of: "'", with: "\\'")
        s = s.replacingOccurrences(of: "\n", with: "\\n")
        return "'\(s)'"
    }
}
