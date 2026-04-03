#if canImport(AppKit)
import AppKit
import XCTest
@testable import HoopoeUI

/// Tests for MarkdownHighlighter, focusing on the byte-to-character offset
/// conversion fix (e359070).
///
/// TreeSitter reports byte offsets (UTF-8), but NSAttributedString uses
/// UTF-16 code unit offsets. The original code used byte offsets directly
/// as NSRange locations, which corrupted ranges for non-ASCII text.
@MainActor
final class MarkdownHighlighterTests: XCTestCase {

    // MARK: - ASCII Text (baseline)

    func testHighlightASCIIHeading() {
        let highlighter = MarkdownHighlighter()
        let text = "# Hello World"

        let result = highlighter.highlight(text)

        // The entire text should be highlighted as a heading
        XCTAssertEqual(result.string, text)
        XCTAssertGreaterThan(result.length, 0)

        // Check that the heading range covers the full text
        var range = NSRange(location: 0, length: 0)
        let font = result.attribute(.font, at: 0, effectiveRange: &range) as? NSFont
        XCTAssertNotNil(font, "Heading should have a font attribute")
        XCTAssertEqual(range.length, text.utf16.count, "Font should span entire heading")
    }

    func testHighlightASCIICodeBlock() {
        let highlighter = MarkdownHighlighter()
        let text = "```\nlet x = 1\n```"

        let result = highlighter.highlight(text)

        XCTAssertEqual(result.string, text)

        // Code block should have a background color somewhere in the range
        var foundCodeBackground = false
        result.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: result.length)) { value, _, _ in
            if value != nil {
                foundCodeBackground = true
            }
        }
        XCTAssertTrue(foundCodeBackground, "Code block should have background color")
    }

    // MARK: - Non-ASCII Text (regression tests for byte/character offset bug)

    func testHighlightHeadingWithEmoji() {
        let highlighter = MarkdownHighlighter()
        // "🎯" is 4 bytes in UTF-8 but 2 code units in UTF-16
        let text = "# 🎯 Goals"

        let result = highlighter.highlight(text)

        // Should not crash and should produce valid attributed string
        XCTAssertEqual(result.string, text)
        XCTAssertEqual(result.length, text.utf16.count)

        // Verify the font attribute covers the heading
        var range = NSRange(location: 0, length: 0)
        let font = result.attribute(.font, at: 0, effectiveRange: &range) as? NSFont
        XCTAssertNotNil(font, "Heading with emoji should have a font attribute")
    }

    func testHighlightTextAfterEmoji() {
        let highlighter = MarkdownHighlighter()
        // The bug: after emoji (4 UTF-8 bytes, 2 UTF-16 units), all subsequent
        // byte-based ranges would be shifted by +2, causing wrong highlighting
        // or out-of-bounds crashes.
        let text = "🎯\n\n# Heading After Emoji"

        let result = highlighter.highlight(text)

        XCTAssertEqual(result.string, text)
        XCTAssertEqual(result.length, text.utf16.count)

        // The heading should still get heading attributes even after emoji
        // Find the position of "# Heading" in UTF-16 units
        let headingStart = text.utf16.count - "# Heading After Emoji".utf16.count
        var range = NSRange(location: 0, length: 0)
        if headingStart < result.length {
            let font = result.attribute(.font, at: headingStart, effectiveRange: &range) as? NSFont
            XCTAssertNotNil(font, "Text after emoji should still be highlighted correctly")
        }
    }

    func testHighlightWithAccentedCharacters() {
        let highlighter = MarkdownHighlighter()
        // "é" is 2 bytes in UTF-8 but 1 code unit in UTF-16
        let text = "# Résumé\n\nSome text"

        let result = highlighter.highlight(text)

        XCTAssertEqual(result.string, text)
        XCTAssertEqual(result.length, text.utf16.count)
    }

    func testHighlightWithCJKCharacters() {
        let highlighter = MarkdownHighlighter()
        // CJK characters are 3 bytes in UTF-8 but 1 code unit in UTF-16
        let text = "# 计划概述\n\n这是一个测试"

        let result = highlighter.highlight(text)

        XCTAssertEqual(result.string, text)
        XCTAssertEqual(result.length, text.utf16.count)
    }

    func testHighlightCodeBlockAfterMultibyteText() {
        let highlighter = MarkdownHighlighter()
        let text = "café ☕\n\n```\ncode here\n```\n\nMore text"

        let result = highlighter.highlight(text)

        XCTAssertEqual(result.string, text)
        XCTAssertEqual(result.length, text.utf16.count)

        // Code block should still get background color even after multibyte chars
        var foundCodeBackground = false
        let codeStart = (text as NSString).range(of: "```\ncode").location
        if codeStart != NSNotFound {
            result.enumerateAttribute(
                .backgroundColor,
                in: NSRange(location: codeStart, length: "```\ncode here\n```".utf16.count)
            ) { value, _, _ in
                guard value != nil else { return }
                foundCodeBackground = true
            }
            XCTAssertTrue(foundCodeBackground, "Code block after multibyte text should have background")
        }
    }

    // MARK: - Incremental Edit

    func testIncrementalEditPreservesCorrectHighlighting() {
        let highlighter = MarkdownHighlighter()

        // Initial parse
        let initial = "# Hello"
        _ = highlighter.highlight(initial)

        // Edit: append text (simulating typing after the heading)
        let edited = "# Hello World"
        let oldByteLen = UInt32(initial.utf8.count)
        let newByteLen = UInt32(edited.utf8.count)

        let result = highlighter.edit(
            replacingBytesIn: oldByteLen..<oldByteLen,
            newLength: newByteLen - oldByteLen,
            fullText: edited
        )

        XCTAssertEqual(result.string, edited)
        XCTAssertEqual(result.length, edited.utf16.count)
    }

    // MARK: - Empty Input

    func testHighlightEmptyString() {
        let highlighter = MarkdownHighlighter()
        let result = highlighter.highlight("")

        XCTAssertEqual(result.string, "")
        XCTAssertEqual(result.length, 0)
    }

    func testHighlightPlainTextNoMarkdown() {
        let highlighter = MarkdownHighlighter()
        let text = "Just plain text with no markdown syntax."

        let result = highlighter.highlight(text)

        XCTAssertEqual(result.string, text)
        XCTAssertEqual(result.length, text.utf16.count)
    }

    // MARK: - Theme Application

    func testHighlightUsesThemeEmphasisAndStrongColors() {
        let theme = MarkdownTheme.light.adapted(fontSize: 16, usesMonospacedFont: false)
        let highlighter = MarkdownHighlighter(theme: theme)
        let text = "*italic* and **bold**"

        let result = highlighter.highlight(text)
        let nsText = text as NSString
        let italicRange = nsText.range(of: "italic")
        let boldRange = nsText.range(of: "bold")
        let italicColor = result.attribute(.foregroundColor, at: italicRange.location, effectiveRange: nil) as? NSColor
        let boldColor = result.attribute(.foregroundColor, at: boldRange.location, effectiveRange: nil) as? NSColor
        let italicFont = result.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
        let boldFont = result.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont

        XCTAssertTrue(italicColor?.isEqual(theme.emphasisColor) ?? false)
        XCTAssertTrue(boldColor?.isEqual(theme.strongColor) ?? false)
        XCTAssertNotNil(italicFont)
        XCTAssertNotNil(boldFont)
        XCTAssertEqual(italicFont?.pointSize ?? 0, theme.bodyFont.pointSize, accuracy: 0.01)
        XCTAssertEqual(boldFont?.pointSize ?? 0, theme.bodyFont.pointSize, accuracy: 0.01)
    }

    // MARK: - Editor Integration Helpers

    func testHeadingLineRangeHandlesCRLFLineEndings() {
        let text = "# Intro\r\n\r\n## Goals\r\nBody\r\n## Architecture\r\nMore"
        let range = PlanEditorView.headingLineRange(matching: "Architecture", in: text)

        XCTAssertNotNil(range)
        XCTAssertEqual((text as NSString).substring(with: range!), "## Architecture")
    }
}
#endif
