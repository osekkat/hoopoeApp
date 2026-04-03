#if canImport(AppKit)
import AppKit
import XCTest
@testable import HoopoeUI

/// Tests for MarkdownTheme, including the Sendable conformance fix (e359070).
///
/// NSColor and NSFont are not formally Sendable in Swift 6.
/// MarkdownTheme is marked @unchecked Sendable because its properties are
/// effectively immutable after construction.
final class MarkdownThemeTests: XCTestCase {

    // MARK: - Sendable Conformance

    /// Verifies that MarkdownTheme can be sent across actor boundaries.
    /// This test would fail to compile if the Sendable conformance were missing.
    func testThemeIsSendableAcrossActorBoundary() async {
        let theme = MarkdownTheme.default

        let result = await ThemeConsumer().useTheme(theme)

        XCTAssertTrue(result, "Theme should be usable across actor boundaries")
    }

    // MARK: - Heading Fonts

    func testHeadingFontLevelClamping() {
        let theme = MarkdownTheme.default

        // Valid levels
        let h1 = theme.headingFont(level: 1)
        let h6 = theme.headingFont(level: 6)
        XCTAssertNotNil(h1)
        XCTAssertNotNil(h6)

        // Level 0 should clamp to first font (index 0)
        let h0 = theme.headingFont(level: 0)
        XCTAssertEqual(h0, theme.headingFonts[0])

        // Level 7+ should clamp to last font
        let h7 = theme.headingFont(level: 7)
        XCTAssertEqual(h7, theme.headingFonts.last)

        // Negative level should clamp to first
        let hNeg = theme.headingFont(level: -1)
        XCTAssertEqual(hNeg, theme.headingFonts[0])
    }

    func testHeadingColorLevelClamping() {
        let theme = MarkdownTheme.default

        // Valid levels
        let c1 = theme.headingColor(level: 1)
        let c6 = theme.headingColor(level: 6)
        XCTAssertNotNil(c1)
        XCTAssertNotNil(c6)

        // Out-of-range levels should clamp
        let c0 = theme.headingColor(level: 0)
        XCTAssertEqual(c0, theme.headingColors[0])

        let c99 = theme.headingColor(level: 99)
        XCTAssertEqual(c99, theme.headingColors.last)
    }

    func testHeadingFontSizesAreDecreasing() {
        let theme = MarkdownTheme.default

        for i in 0..<(theme.headingFonts.count - 1) {
            XCTAssertGreaterThanOrEqual(
                theme.headingFonts[i].pointSize,
                theme.headingFonts[i + 1].pointSize,
                "H\(i + 1) font should be >= H\(i + 2) font size"
            )
        }
    }

    // MARK: - Default Theme

    func testDefaultThemeHasSixHeadingLevels() {
        let theme = MarkdownTheme.default

        XCTAssertEqual(theme.headingFonts.count, 6)
        XCTAssertEqual(theme.headingColors.count, 6)
    }

    func testDefaultThemeCodeFontIsMonospaced() {
        let theme = MarkdownTheme.default
        let traits = NSFontManager.shared.traits(of: theme.codeFont)

        XCTAssertTrue(
            traits.contains(.fixedPitchFontMask),
            "Code font should be monospaced"
        )
    }
}

/// Actor used to verify Sendable conformance at compile time.
private actor ThemeConsumer {
    func useTheme(_ theme: MarkdownTheme) -> Bool {
        // If this compiles, MarkdownTheme is Sendable
        _ = theme.headingFont(level: 1)
        return true
    }
}
#endif
