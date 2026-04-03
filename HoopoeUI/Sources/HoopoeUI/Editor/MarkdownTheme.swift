import AppKit
import Foundation

/// Color and font theme for markdown syntax highlighting.
///
/// Uses semantic NSColor values so the theme adapts to light/dark mode automatically.
public struct MarkdownTheme: Sendable {
    public let headingColors: [NSColor]
    public let bodyFont: NSFont
    public let headingFonts: [NSFont]
    public let codeFont: NSFont
    public let codeBackground: NSColor
    public let emphasisColor: NSColor
    public let strongColor: NSColor
    public let linkColor: NSColor
    public let listMarkerColor: NSColor
    public let blockquoteColor: NSColor

    /// The default Hoopoe markdown theme.
    public static let `default` = MarkdownTheme(
        headingColors: [
            .labelColor,                    // H1
            .labelColor,                    // H2
            .secondaryLabelColor,           // H3
            .secondaryLabelColor,           // H4
            .tertiaryLabelColor,            // H5
            .tertiaryLabelColor,            // H6
        ],
        bodyFont: .systemFont(ofSize: 14),
        headingFonts: [
            .boldSystemFont(ofSize: 24),    // H1
            .boldSystemFont(ofSize: 20),    // H2
            .boldSystemFont(ofSize: 17),    // H3
            .boldSystemFont(ofSize: 15),    // H4
            .boldSystemFont(ofSize: 14),    // H5
            .boldSystemFont(ofSize: 13),    // H6
        ],
        codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
        codeBackground: NSColor.quaternaryLabelColor.withAlphaComponent(0.1),
        emphasisColor: .labelColor,
        strongColor: .labelColor,
        linkColor: .linkColor,
        listMarkerColor: .tertiaryLabelColor,
        blockquoteColor: .secondaryLabelColor
    )

    /// Returns the font for a heading at the given level (1-based).
    public func headingFont(level: Int) -> NSFont {
        let index = max(0, min(level - 1, headingFonts.count - 1))
        return headingFonts[index]
    }

    /// Returns the color for a heading at the given level (1-based).
    public func headingColor(level: Int) -> NSColor {
        let index = max(0, min(level - 1, headingColors.count - 1))
        return headingColors[index]
    }
}
