import SwiftUI
import WebKit

// MARK: - Preview Mode

enum PreviewMode: String, CaseIterable {
    case editorOnly = "Editor"
    case split = "Split"
    case previewOnly = "Preview"

    var icon: String {
        switch self {
        case .editorOnly: "doc.plaintext"
        case .split: "rectangle.split.2x1"
        case .previewOnly: "eye"
        }
    }
}

// MARK: - Markdown Preview (NSViewRepresentable)

/// WKWebView-based live markdown preview powered by markdown-it, highlight.js, and morphdom.
/// Markdown is parsed in JavaScript; DOM updates are incremental via morphdom (no full reloads).
struct MarkdownPreviewRepresentable: NSViewRepresentable {
    let markdown: String
    /// Fraction (0..1) of the document where the editor cursor is, used for scroll sync.
    let scrollFraction: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        config.userContentController.add(context.coordinator, name: "pageReady")

        let webView = WKWebView(frame: .zero, configuration: config)
        context.coordinator.webView = webView

        let html = PreviewHTMLTemplate.page()
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView

        if markdown != context.coordinator.lastMarkdown {
            context.coordinator.lastMarkdown = markdown
            context.coordinator.sendMarkdown(markdown, scrollFraction: scrollFraction)
        } else if abs(scrollFraction - context.coordinator.lastFraction) > 0.01 {
            context.coordinator.scrollTo(fraction: scrollFraction)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var lastMarkdown = ""
        var lastFraction: CGFloat = 0
        var pageLoaded = false
        var pendingMarkdown: String?
        var pendingFraction: CGFloat = 0

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "pageReady" else { return }
            pageLoaded = true
            if let pending = pendingMarkdown {
                pendingMarkdown = nil
                sendMarkdown(pending, scrollFraction: pendingFraction)
            }
        }

        func sendMarkdown(_ text: String, scrollFraction: CGFloat) {
            guard pageLoaded else {
                pendingMarkdown = text
                pendingFraction = scrollFraction
                return
            }
            let escaped = escapeForJS(text)
            webView?.evaluateJavaScript("updatePreview(\(escaped))") { [weak self] _, _ in
                self?.scrollTo(fraction: scrollFraction)
            }
        }

        func scrollTo(fraction: CGFloat) {
            lastFraction = fraction
            let clamped = max(0, min(1, fraction))
            webView?.evaluateJavaScript("scrollToFraction(\(clamped))", completionHandler: nil)
        }

        private func escapeForJS(_ text: String) -> String {
            guard let data = try? JSONSerialization.data(
                withJSONObject: text, options: .fragmentsAllowed
            ) else { return "\"\"" }
            return String(data: data, encoding: .utf8) ?? "\"\""
        }
    }
}

// MARK: - HTML Template (markdown-it + highlight.js + morphdom)

enum PreviewHTMLTemplate {
    /// Reads a bundled JS vendor file and returns its contents, or an empty string on failure.
    private static func vendorScript(named name: String, ext: String = "js") -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return contents
    }

    /// Returns a self-contained HTML page with markdown-it, highlight.js, and morphdom
    /// loaded inline. Call `updatePreview(text)` via evaluateJavaScript to render markdown.
    static func page() -> String {
        let markdownItJS = vendorScript(named: "markdown-it.min")
        let highlightJS = vendorScript(named: "highlight.min")
        let morphdomJS = vendorScript(named: "morphdom-umd.min")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root {
            --bg: #ffffff;
            --fg: #1d1d1f;
            --fg-secondary: #6e6e73;
            --border: #d2d2d7;
            --code-bg: #f5f5f7;
            --blockquote-border: #d2d2d7;
            --link: #0066cc;
            --table-header-bg: #f5f5f7;
            --table-border: #d2d2d7;
            --hljs-keyword: #ad3da4;
            --hljs-string: #272ad8;
            --hljs-comment: #707f8c;
            --hljs-number: #272ad8;
            --hljs-title: #703daa;
            --hljs-attr: #4b21b0;
            --hljs-built-in: #6c36b5;
            --hljs-literal: #272ad8;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg: #1d1d1f;
                --fg: #f5f5f7;
                --fg-secondary: #a1a1a6;
                --border: #424245;
                --code-bg: #2c2c2e;
                --blockquote-border: #48484a;
                --link: #2997ff;
                --table-header-bg: #2c2c2e;
                --table-border: #48484a;
                --hljs-keyword: #fc5fa3;
                --hljs-string: #fc6a5d;
                --hljs-comment: #7f8c98;
                --hljs-number: #d0bf69;
                --hljs-title: #b281eb;
                --hljs-attr: #a167e6;
                --hljs-built-in: #dabaff;
                --hljs-literal: #fc6a5d;
            }
        }
        * { box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
            font-size: 14px;
            line-height: 1.6;
            color: var(--fg);
            background: var(--bg);
            padding: 16px 20px;
            margin: 0;
            -webkit-font-smoothing: antialiased;
        }
        h1, h2, h3, h4, h5, h6 {
            margin: 1.2em 0 0.4em;
            line-height: 1.3;
        }
        h1 { font-size: 1.8em; border-bottom: 1px solid var(--border); padding-bottom: 0.3em; }
        h2 { font-size: 1.4em; border-bottom: 1px solid var(--border); padding-bottom: 0.2em; }
        h3 { font-size: 1.2em; }
        h4 { font-size: 1.05em; }
        p { margin: 0.6em 0; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code {
            font-family: 'SF Mono', Menlo, monospace;
            font-size: 0.9em;
            background: var(--code-bg);
            padding: 0.15em 0.4em;
            border-radius: 4px;
        }
        pre {
            background: var(--code-bg);
            padding: 12px 16px;
            border-radius: 8px;
            overflow-x: auto;
            margin: 0.8em 0;
        }
        pre code {
            background: none;
            padding: 0;
            font-size: 0.85em;
        }
        blockquote {
            margin: 0.8em 0;
            padding: 0.4em 1em;
            border-left: 3px solid var(--blockquote-border);
            color: var(--fg-secondary);
        }
        ul, ol { margin: 0.5em 0; padding-left: 1.5em; }
        li { margin: 0.2em 0; }
        hr { border: none; border-top: 1px solid var(--border); margin: 1.5em 0; }
        table {
            border-collapse: collapse;
            width: 100%;
            margin: 0.8em 0;
        }
        th, td {
            border: 1px solid var(--table-border);
            padding: 6px 12px;
            text-align: left;
        }
        th {
            background: var(--table-header-bg);
            font-weight: 600;
        }
        /* highlight.js token colors */
        .hljs { color: var(--fg); }
        .hljs-keyword, .hljs-selector-tag { color: var(--hljs-keyword); }
        .hljs-built_in { color: var(--hljs-built-in); }
        .hljs-string, .hljs-addition { color: var(--hljs-string); }
        .hljs-literal { color: var(--hljs-literal); }
        .hljs-comment, .hljs-quote { color: var(--hljs-comment); font-style: italic; }
        .hljs-number { color: var(--hljs-number); }
        .hljs-title, .hljs-section, .hljs-title.function_ { color: var(--hljs-title); }
        .hljs-attr, .hljs-attribute, .hljs-variable, .hljs-template-variable { color: var(--hljs-attr); }
        .hljs-deletion { color: var(--hljs-string); text-decoration: line-through; }
        .hljs-type, .hljs-class .hljs-title { color: var(--hljs-built-in); }
        .hljs-emphasis { font-style: italic; }
        .hljs-strong { font-weight: bold; }
        </style>
        </head>
        <body>
        <div id="content"></div>
        <script>\(markdownItJS)</script>
        <script>\(highlightJS)</script>
        <script>\(morphdomJS)</script>
        <script>
        var md = window.markdownit({
            html: false,
            linkify: true,
            typographer: false,
            highlight: function(str, lang) {
                if (lang && hljs.getLanguage(lang)) {
                    try { return hljs.highlight(str, { language: lang, ignoreIllegals: true }).value; }
                    catch (e) {}
                }
                return '';
            }
        });

        function updatePreview(text) {
            var el = document.getElementById('content');
            var next = document.createElement('div');
            next.id = 'content';
            next.innerHTML = md.render(text);
            morphdom(el, next);
        }

        function scrollToFraction(f) {
            var clamped = Math.max(0, Math.min(1, f));
            window.scrollTo(0, document.body.scrollHeight * clamped);
        }

        window.webkit.messageHandlers.pageReady.postMessage('ready');
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - Preview

#Preview("Markdown Preview") {
    MarkdownPreviewRepresentable(
        markdown: """
        # Sample Plan

        ## Goals
        - Capture the project vision
        - Keep the editor **responsive**
        - Make section-level navigation *easy*

        ## Architecture

        The system uses `PlanEditorRepresentable` to bridge SwiftUI into AppKit.

        | Component | Role |
        |-----------|------|
        | Editor | Text editing |
        | Preview | Live rendering |

        ```swift
        struct ContentView: View {
            var body: some View {
                Text("Hello")
            }
        }
        ```

        > Plans should survive multiple refinement rounds.

        1. First step
        2. Second step
        3. Third step
        """,
        scrollFraction: 0
    )
    .frame(width: 500, height: 600)
}
