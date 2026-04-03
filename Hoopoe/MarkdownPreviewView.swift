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

/// WKWebView-based live markdown preview that respects light/dark mode.
struct MarkdownPreviewRepresentable: NSViewRepresentable {
    let markdown: String
    /// Fraction (0..1) of the document where the editor cursor is, used for scroll sync.
    let scrollFraction: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: config)
        context.coordinator.webView = webView
        loadContent(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView

        let html = MarkdownHTMLConverter.convert(markdown)
        if html != context.coordinator.lastHTML {
            context.coordinator.lastHTML = html
            let fullHTML = PreviewHTMLTemplate.wrap(body: html)
            webView.loadHTMLString(fullHTML, baseURL: nil)

            // Restore scroll position after content loads
            let fraction = scrollFraction
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                context.coordinator.scrollTo(fraction: fraction)
            }
        } else if abs(scrollFraction - context.coordinator.lastFraction) > 0.01 {
            context.coordinator.scrollTo(fraction: scrollFraction)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func loadContent(into webView: WKWebView) {
        let html = MarkdownHTMLConverter.convert(markdown)
        let fullHTML = PreviewHTMLTemplate.wrap(body: html)
        webView.loadHTMLString(fullHTML, baseURL: nil)
    }

    final class Coordinator {
        weak var webView: WKWebView?
        var lastHTML = ""
        var lastFraction: CGFloat = 0

        func scrollTo(fraction: CGFloat) {
            lastFraction = fraction
            let clamped = max(0, min(1, fraction))
            let js = "window.scrollTo(0, document.body.scrollHeight * \(clamped));"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

// MARK: - Markdown to HTML Converter

enum MarkdownHTMLConverter {
    static func convert(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var html: [String] = []
        var inCodeBlock = false
        var codeBlockContent: [String] = []
        var inList = false
        var listIsOrdered = false
        var inTable = false
        var tableRows: [[String]] = []
        var tableAlignments: [String] = []

        for line in lines {
            // Code blocks
            if line.hasPrefix("```") {
                if inCodeBlock {
                    html.append("<pre><code>\(escapeHTML(codeBlockContent.joined(separator: "\n")))</code></pre>")
                    codeBlockContent = []
                    inCodeBlock = false
                } else {
                    closeList(&html, &inList, listIsOrdered)
                    closeTable(&html, &inTable, &tableRows, tableAlignments)
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeBlockContent.append(line)
                continue
            }

            // Table rows
            if line.contains("|") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let cells = parseTableRow(line)
                if !cells.isEmpty {
                    // Check if this is a separator row (---|---)
                    let isSeparator = cells.allSatisfy { cell in
                        let trimmed = cell.trimmingCharacters(in: .whitespaces)
                        return trimmed.allSatisfy { $0 == "-" || $0 == ":" } && trimmed.count >= 1
                    }

                    if isSeparator {
                        tableAlignments = cells.map { cell in
                            let t = cell.trimmingCharacters(in: .whitespaces)
                            if t.hasPrefix(":") && t.hasSuffix(":") { return "center" }
                            if t.hasSuffix(":") { return "right" }
                            return "left"
                        }
                        if !inTable {
                            inTable = true
                        }
                        continue
                    }

                    if !inTable {
                        closeList(&html, &inList, listIsOrdered)
                        inTable = true
                    }
                    tableRows.append(cells)
                    continue
                }
            } else if inTable {
                closeTable(&html, &inTable, &tableRows, tableAlignments)
            }

            // Blank lines
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                closeList(&html, &inList, listIsOrdered)
                closeTable(&html, &inTable, &tableRows, tableAlignments)
                continue
            }

            // Headings
            if let heading = parseHeading(line) {
                closeList(&html, &inList, listIsOrdered)
                html.append(heading)
                continue
            }

            // Blockquotes
            if line.hasPrefix("> ") || line == ">" {
                closeList(&html, &inList, listIsOrdered)
                let content = line.hasPrefix("> ") ? String(line.dropFirst(2)) : ""
                html.append("<blockquote>\(inlineFormat(escapeHTML(content)))</blockquote>")
                continue
            }

            // Unordered list
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !inList || listIsOrdered {
                    closeList(&html, &inList, listIsOrdered)
                    html.append("<ul>")
                    inList = true
                    listIsOrdered = false
                }
                let content = String(trimmed.dropFirst(2))
                html.append("<li>\(inlineFormat(escapeHTML(content)))</li>")
                continue
            }

            // Ordered list
            if let match = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                if !inList || !listIsOrdered {
                    closeList(&html, &inList, listIsOrdered)
                    html.append("<ol>")
                    inList = true
                    listIsOrdered = true
                }
                let content = String(trimmed[match.upperBound...])
                html.append("<li>\(inlineFormat(escapeHTML(content)))</li>")
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                closeList(&html, &inList, listIsOrdered)
                html.append("<hr>")
                continue
            }

            // Paragraph
            closeList(&html, &inList, listIsOrdered)
            html.append("<p>\(inlineFormat(escapeHTML(line)))</p>")
        }

        // Close any open blocks
        if inCodeBlock {
            html.append("<pre><code>\(escapeHTML(codeBlockContent.joined(separator: "\n")))</code></pre>")
        }
        closeList(&html, &inList, listIsOrdered)
        closeTable(&html, &inTable, &tableRows, tableAlignments)

        return html.joined(separator: "\n")
    }

    private static func parseHeading(_ line: String) -> String? {
        var level = 0
        for char in line {
            if char == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6, line.count > level, line[line.index(line.startIndex, offsetBy: level)] == " " else {
            return nil
        }
        let text = String(line.dropFirst(level + 1))
        let id = text.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "<h\(level) id=\"\(id)\">\(inlineFormat(escapeHTML(text)))</h\(level)>"
    }

    private static func parseTableRow(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") || trimmed.hasSuffix("|") else {
            return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var cells = trimmed.components(separatedBy: "|")
        // Remove empty first/last elements from leading/trailing pipes
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func closeList(_ html: inout [String], _ inList: inout Bool, _ isOrdered: Bool) {
        guard inList else { return }
        html.append(isOrdered ? "</ol>" : "</ul>")
        inList = false
    }

    private static func closeTable(_ html: inout [String], _ inTable: inout Bool, _ rows: inout [[String]], _ alignments: [String]) {
        guard inTable, !rows.isEmpty else {
            inTable = false
            return
        }

        var table = "<table>"
        for (rowIdx, cells) in rows.enumerated() {
            let tag = rowIdx == 0 ? "th" : "td"
            table += "<tr>"
            for (colIdx, cell) in cells.enumerated() {
                let align = colIdx < alignments.count ? " style=\"text-align:\(alignments[colIdx])\"" : ""
                table += "<\(tag)\(align)>\(inlineFormat(escapeHTML(cell)))</\(tag)>"
            }
            table += "</tr>"
        }
        table += "</table>"
        html.append(table)

        rows = []
        inTable = false
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Applies inline formatting: bold, italic, inline code, links.
    private static func inlineFormat(_ html: String) -> String {
        var result = html
        // Inline code (must come first to prevent formatting inside code spans)
        result = result.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: "<code>$1</code>",
            options: .regularExpression
        )
        // Bold
        result = result.replacingOccurrences(
            of: #"\*\*(.+?)\*\*"#,
            with: "<strong>$1</strong>",
            options: .regularExpression
        )
        // Italic
        result = result.replacingOccurrences(
            of: #"\*(.+?)\*"#,
            with: "<em>$1</em>",
            options: .regularExpression
        )
        // Links
        result = result.replacingOccurrences(
            of: #"\[([^\]]+)\]\(([^\)]+)\)"#,
            with: "<a href=\"$2\">$1</a>",
            options: .regularExpression
        )
        return result
    }
}

// MARK: - HTML Template

enum PreviewHTMLTemplate {
    static func wrap(body: String) -> String {
        """
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
        </style>
        </head>
        <body>
        \(body)
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
