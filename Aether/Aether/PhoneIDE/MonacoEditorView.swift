import SwiftUI
import WebKit

/// Monaco editor in a WKWebView, themed to JetBrains Darcula. Two-way bridge:
/// - Swift -> JS: `setCode(code, language)` via evaluateJavaScript
/// - JS -> Swift: `codeChange` script-message-handler with the new buffer
///
/// Re-mounts only when `filename` changes; `code` updates flow through the
/// bridge so we don't lose scroll/cursor on every keystroke.
struct MonacoEditorView: UIViewRepresentable {
    /// Filename used to set the Monaco language. Triggers a remount when it changes
    /// (to swap the document) — code updates do not.
    let filename: String
    /// Current code. Pushed into Monaco when the buffer differs from what the editor reports.
    let code: String
    /// Called when the user edits the buffer in Monaco. Always on the main thread.
    let onChange: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "codeChange")
        userContent.add(context.coordinator, name: "ready")
        config.userContentController = userContent
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 43/255, green: 45/255, blue: 48/255, alpha: 1)
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.keyboardDismissMode = .interactive
        webView.navigationDelegate = context.coordinator

        context.coordinator.webView = webView
        webView.loadHTMLString(Self.bootstrapHTML, baseURL: URL(string: "https://cdn.jsdelivr.net"))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.pushCodeIfNeeded()
        context.coordinator.pushLanguageIfNeeded()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MonacoEditorView
        weak var webView: WKWebView?
        private var ready = false
        private var lastPushedCode: String = ""
        private var lastPushedLang: String = ""

        init(parent: MonacoEditorView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "ready":
                ready = true
                pushCodeIfNeeded(force: true)
                pushLanguageIfNeeded(force: true)
            case "codeChange":
                if let s = message.body as? String {
                    lastPushedCode = s
                    parent.onChange(s)
                }
            default: break
            }
        }

        func pushCodeIfNeeded(force: Bool = false) {
            guard ready, let webView = webView else { return }
            if !force && parent.code == lastPushedCode { return }
            lastPushedCode = parent.code
            let escaped = Self.jsString(parent.code)
            webView.evaluateJavaScript("window._setCode(\(escaped));", completionHandler: nil)
        }

        func pushLanguageIfNeeded(force: Bool = false) {
            guard ready, let webView = webView else { return }
            let lang = IJ.monacoLanguage(for: parent.filename)
            if !force && lang == lastPushedLang { return }
            lastPushedLang = lang
            let escaped = Self.jsString(lang)
            webView.evaluateJavaScript("window._setLanguage(\(escaped));", completionHandler: nil)
        }

        /// JSON-encode a string so it can be embedded as a JS literal.
        private static func jsString(_ s: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [s], options: []))
                ?? Data("[\"\"]".utf8)
            let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
            // Strip the brackets — we want just the quoted scalar.
            let trimmed = arr.dropFirst().dropLast()
            return String(trimmed)
        }
    }

    // MARK: - Bootstrap HTML

    /// Self-contained Monaco loader with the JetBrains Darcula theme. JS-side
    /// hooks: `_setCode`, `_setLanguage`. Posts `codeChange` and `ready` to Swift.
    private static let bootstrapHTML: String = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/monaco-editor@0.45.0/min/vs/editor/editor.main.min.css">
    <style>
      * { margin:0; padding:0; box-sizing:border-box; }
      html, body { background:#2b2d30; overflow:hidden; height:100%; }
      #editor { width:100vw; height:100vh; }
    </style>
    </head>
    <body>
    <div id="editor"></div>
    <script src="https://cdn.jsdelivr.net/npm/monaco-editor@0.45.0/min/vs/loader.min.js"></script>
    <script>
    require.config({paths:{vs:'https://cdn.jsdelivr.net/npm/monaco-editor@0.45.0/min/vs'}});
    require(['vs/editor/editor.main'], function() {
      monaco.editor.defineTheme('jetbrains-dark', {
        base: 'vs-dark',
        inherit: true,
        rules: [
          { token: 'keyword',         foreground: 'CC7832' },
          { token: 'string',          foreground: '6A8759' },
          { token: 'number',          foreground: '6897BB' },
          { token: 'comment',         foreground: '808080' },
          { token: 'type',            foreground: 'A9B7C6' },
          { token: 'identifier',      foreground: 'A9B7C6' },
          { token: 'delimiter',       foreground: 'A9B7C6' },
          { token: 'tag',             foreground: 'E8BF6A' },
          { token: 'attribute.name',  foreground: 'BABABA' },
          { token: 'attribute.value', foreground: '6A8759' },
          { token: 'delimiter.html',  foreground: 'A9B7C6' },
          { token: 'metatag',         foreground: 'A9B7C6' },
          { token: 'variable',        foreground: 'A9B7C6' },
          { token: 'predefined',      foreground: 'FFC66D' }
        ],
        colors: {
          'editor.background': '#2b2d30',
          'editor.foreground': '#a9b7c6',
          'editor.lineHighlightBackground': '#2d2f33',
          'editor.selectionBackground': '#214283',
          'editorLineNumber.foreground': '#4e5157',
          'editorLineNumber.activeForeground': '#a4a3a3',
          'editorCursor.foreground': '#bcbec4',
          'editor.inactiveSelectionBackground': '#2d3239',
          'editorIndentGuide.background1': '#393b40',
          'editorGutter.background': '#2b2d30',
          'scrollbar.shadow': '#00000000',
          'scrollbarSlider.background': '#3e404580',
          'scrollbarSlider.hoverBackground': '#575a5f80',
          'scrollbarSlider.activeBackground': '#6e737880'
        }
      });

      const editor = monaco.editor.create(document.getElementById('editor'), {
        value: '',
        language: 'html',
        theme: 'jetbrains-dark',
        fontSize: 13,
        fontFamily: "'JetBrains Mono','Fira Code','SF Mono','Menlo',monospace",
        fontLigatures: true,
        minimap: { enabled: false },
        wordWrap: 'on',
        lineNumbers: 'on',
        scrollBeyondLastLine: false,
        automaticLayout: true,
        padding: { top: 8, bottom: 8 },
        lineHeight: 22,
        letterSpacing: 0.3,
        cursorBlinking: 'smooth',
        cursorSmoothCaretAnimation: 'on',
        smoothScrolling: true,
        renderLineHighlight: 'line',
        renderWhitespace: 'none',
        overviewRulerBorder: false,
        hideCursorInOverviewRuler: true,
        contextmenu: false,
        quickSuggestions: false,
        suggestOnTriggerCharacters: false,
        parameterHints: { enabled: false },
        tabSize: 2,
        scrollbar: {
          verticalScrollbarSize: 8,
          horizontalScrollbarSize: 8,
          useShadows: false
        },
        glyphMargin: false,
        folding: true,
        foldingHighlight: false,
        lineDecorationsWidth: 8,
        lineNumbersMinChars: 3
      });

      let suppressNextChange = false;

      window._setCode = function(code) {
        const cur = editor.getValue();
        if (cur === code) return;
        suppressNextChange = true;
        editor.setValue(code);
      };

      window._setLanguage = function(lang) {
        monaco.editor.setModelLanguage(editor.getModel(), lang || 'plaintext');
      };

      editor.onDidChangeModelContent(function() {
        if (suppressNextChange) { suppressNextChange = false; return; }
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.codeChange) {
          window.webkit.messageHandlers.codeChange.postMessage(editor.getValue());
        }
      });

      window._aetherEditor = editor;
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ready) {
        window.webkit.messageHandlers.ready.postMessage(true);
      }
    });
    </script>
    </body>
    </html>
    """
}
