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

        // Level 7+ should clamp to last font (index 5)
        let h7 = theme.headingFont(level: 7)
        XCTAssertEqual(h7, theme.headingFonts[theme.headingFonts.count - 1])

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
        XCTAssertEqual(c99, theme.headingColors[theme.headingColors.count - 1])
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

    func testAdaptedThemeTracksRequestedFontSize() {
        let theme = MarkdownTheme.dark.adapted(fontSize: 18, usesMonospacedFont: true)

        XCTAssertEqual(theme.bodyFont.pointSize, 18, accuracy: 0.01)
        XCTAssertGreaterThan(theme.headingFonts[0].pointSize, theme.bodyFont.pointSize)
        XCTAssertEqual(theme.codeFont.pointSize, 17, accuracy: 0.01)

        let bodyTraits = NSFontManager.shared.traits(of: theme.bodyFont)
        XCTAssertTrue(
            bodyTraits.contains(.fixedPitchFontMask),
            "Adapted body font should honor monospaced configuration"
        )
    }

    func testThemeEquivalenceDetectsSemanticDifferences() {
        let baseline = MarkdownTheme.light
        let modified = MarkdownTheme(
            headingColors: baseline.headingColors,
            bodyFont: baseline.bodyFont,
            headingFonts: baseline.headingFonts,
            codeFont: baseline.codeFont,
            codeBackground: baseline.codeBackground,
            emphasisColor: .systemRed,
            strongColor: baseline.strongColor,
            linkColor: baseline.linkColor,
            listMarkerColor: baseline.listMarkerColor,
            blockquoteColor: baseline.blockquoteColor
        )

        XCTAssertFalse(baseline.isEquivalent(to: modified))
        XCTAssertTrue(baseline.isEquivalent(to: .light))
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
