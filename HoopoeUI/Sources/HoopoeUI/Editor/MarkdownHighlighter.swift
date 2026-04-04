import AppKit
import Foundation
import SwiftTreeSitter
import TreeSitterMarkdown

/// Incrementally highlights markdown text using TreeSitter.
///
/// Maintains a TreeSitter parser and tree so that edits only re-parse the
/// changed region. Produces `NSAttributedString` styling via a `MarkdownTheme`.
@MainActor
public final class MarkdownHighlighter {
    private let parser: Parser
    private var tree: MutableTree?
    private let theme: MarkdownTheme

    public init(theme: MarkdownTheme = .default) {
        self.theme = theme
        self.parser = Parser()

        do {
            let language = Language(language: tree_sitter_markdown())
            try parser.setLanguage(language)
        } catch {
            assertionFailure("Failed to set TreeSitter markdown language: \(error)")
        }
    }

    // MARK: - Full Parse

    /// Parse the full document and return a highlighted attributed string.
    public func highlight(_ text: String) -> NSAttributedString {
        tree = parser.parse(text)
        return applyHighlighting(to: text)
    }

    // MARK: - Incremental Edit

    /// Notify the highlighter of a text edit for incremental re-parsing.
    ///
    /// - Parameters:
    ///   - range: The byte range in the old text that was replaced.
    ///   - newText: The replacement text.
    ///   - fullText: The full document text after the edit.
    /// - Returns: The re-highlighted attributed string.
    public func edit(
        replacingBytesIn range: Range<UInt32>,
        newLength: UInt32,
        fullText: String
    ) -> NSAttributedString {
        if let existingTree = tree {
            let edit = InputEdit(
                startByte: range.lowerBound,
                oldEndByte: range.upperBound,
                newEndByte: range.lowerBound + newLength,
                startPoint: .zero,
                oldEndPoint: .zero,
                newEndPoint: .zero
            )
            existingTree.edit(edit)
            tree = parser.parse(tree: existingTree, string: fullText)
        } else {
            tree = parser.parse(fullText)
        }
        return applyHighlighting(to: fullText)
    }

    // MARK: - Highlighting

    private func applyHighlighting(to text: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: theme.bodyFont,
                .foregroundColor: NSColor.labelColor,
            ]
        )

        guard let rootNode = tree?.rootNode else { return attributed }

        applyStyles(node: rootNode, to: attributed, text: text)

        return attributed
    }

    private func applyStyles(
        node: Node,
        to attributed: NSMutableAttributedString,
        text: String
    ) {
        let nodeType = node.nodeType ?? ""

        // Convert byte offsets to String.Index, then to NSRange (UTF-16 units).
        // TreeSitter reports byte offsets (UTF-8), but NSAttributedString uses
        // UTF-16 code unit offsets. Mixing them up corrupts ranges for non-ASCII text.
        let utf8 = text.utf8
        let startByte = Int(node.byteRange.lowerBound)
        let endByte = Int(node.byteRange.upperBound)

        guard startByte <= utf8.count, endByte <= utf8.count, startByte < endByte else { return }

        // Use UTF-8 byte offsets to find String.Index
        guard let startStringIdx = text.utf8.index(text.utf8.startIndex, offsetBy: startByte, limitedBy: text.utf8.endIndex),
              let endStringIdx = text.utf8.index(text.utf8.startIndex, offsetBy: endByte, limitedBy: text.utf8.endIndex)
        else { return }

        let swiftRange = startStringIdx..<endStringIdx
        let safeRange = NSRange(swiftRange, in: text)
        guard safeRange.length > 0, safeRange.location + safeRange.length <= attributed.length else { return }

        switch nodeType {
        case "atx_heading":
            let level = headingLevel(for: node)
            attributed.addAttributes([
                .font: theme.headingFont(level: level),
                .foregroundColor: theme.headingColor(level: level),
            ], range: safeRange)

        case "fenced_code_block", "indented_code_block", "code_span":
            attributed.addAttributes([
                .font: theme.codeFont,
                .backgroundColor: theme.codeBackground,
            ], range: safeRange)

        case "emphasis":
            attributed.addAttributes([
                .font: NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .italicFontMask),
                .foregroundColor: theme.emphasisColor,
            ], range: safeRange)

        case "strong_emphasis":
            attributed.addAttributes([
                .font: NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .boldFontMask),
                .foregroundColor: theme.strongColor,
            ], range: safeRange)

        case "link", "uri_autolink":
            attributed.addAttribute(.foregroundColor, value: theme.linkColor, range: safeRange)

        case "list_marker_minus", "list_marker_plus", "list_marker_star", "list_marker_dot":
            attributed.addAttribute(.foregroundColor, value: theme.listMarkerColor, range: safeRange)

        case "block_quote":
            attributed.addAttribute(.foregroundColor, value: theme.blockquoteColor, range: safeRange)

        default:
            break
        }

        // Recurse into children
        for i in 0..<node.childCount {
            if let child = node.child(at: i) {
                applyStyles(node: child, to: attributed, text: text)
            }
        }
    }

    private func headingLevel(for node: Node) -> Int {
        // Count '#' characters in the heading marker child
        if let marker = node.child(at: 0), marker.nodeType == "atx_h1_marker" { return 1 }
        if let marker = node.child(at: 0), marker.nodeType == "atx_h2_marker" { return 2 }
        if let marker = node.child(at: 0), marker.nodeType == "atx_h3_marker" { return 3 }
        if let marker = node.child(at: 0), marker.nodeType == "atx_h4_marker" { return 4 }
        if let marker = node.child(at: 0), marker.nodeType == "atx_h5_marker" { return 5 }
        if let marker = node.child(at: 0), marker.nodeType == "atx_h6_marker" { return 6 }
        return 1
    }
}
