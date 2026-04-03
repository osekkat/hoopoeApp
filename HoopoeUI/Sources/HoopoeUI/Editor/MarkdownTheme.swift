import AppKit
import Foundation

/// Color and font theme for markdown syntax highlighting.
///
/// Uses semantic NSColor values so the theme adapts to light/dark mode automatically.
/// - Note: Marked `@unchecked Sendable` because `NSColor` and `NSFont` are
///   not formally `Sendable`, but instances are effectively immutable after
///   construction and safe to share across isolation boundaries.
public struct MarkdownTheme: @unchecked Sendable {
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

    /// Fixed light appearance for users who explicitly disable system-following behavior.
    public static let light = MarkdownTheme(
        headingColors: [
            NSColor(calibratedWhite: 0.08, alpha: 1),
            NSColor(calibratedWhite: 0.08, alpha: 1),
            NSColor(calibratedWhite: 0.2, alpha: 1),
            NSColor(calibratedWhite: 0.2, alpha: 1),
            NSColor(calibratedWhite: 0.35, alpha: 1),
            NSColor(calibratedWhite: 0.35, alpha: 1),
        ],
        bodyFont: .systemFont(ofSize: 14),
        headingFonts: default.headingFonts,
        codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
        codeBackground: NSColor(calibratedWhite: 0.93, alpha: 1),
        emphasisColor: NSColor(calibratedWhite: 0.08, alpha: 1),
        strongColor: NSColor(calibratedWhite: 0.08, alpha: 1),
        linkColor: NSColor.systemBlue,
        listMarkerColor: NSColor(calibratedWhite: 0.45, alpha: 1),
        blockquoteColor: NSColor(calibratedWhite: 0.35, alpha: 1)
    )

    /// Fixed dark appearance for users who explicitly force dark editor styling.
    public static let dark = MarkdownTheme(
        headingColors: [
            NSColor(calibratedWhite: 0.95, alpha: 1),
            NSColor(calibratedWhite: 0.95, alpha: 1),
            NSColor(calibratedWhite: 0.82, alpha: 1),
            NSColor(calibratedWhite: 0.82, alpha: 1),
            NSColor(calibratedWhite: 0.68, alpha: 1),
            NSColor(calibratedWhite: 0.68, alpha: 1),
        ],
        bodyFont: .systemFont(ofSize: 14),
        headingFonts: default.headingFonts,
        codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
        codeBackground: NSColor(calibratedWhite: 0.17, alpha: 1),
        emphasisColor: NSColor(calibratedWhite: 0.95, alpha: 1),
        strongColor: NSColor(calibratedWhite: 0.95, alpha: 1),
        linkColor: NSColor(calibratedRed: 0.47, green: 0.74, blue: 1, alpha: 1),
        listMarkerColor: NSColor(calibratedWhite: 0.58, alpha: 1),
        blockquoteColor: NSColor(calibratedWhite: 0.68, alpha: 1)
    )

    /// Returns a theme variant whose fonts track the active editor font settings.
    public func adapted(fontSize: CGFloat, usesMonospacedFont: Bool) -> MarkdownTheme {
        let resolvedFontSize = max(1, fontSize)
        let referenceBodySize = max(bodyFont.pointSize, 1)
        let scale = resolvedFontSize / referenceBodySize
        let resolvedBodyFont = usesMonospacedFont
            ? NSFont.monospacedSystemFont(ofSize: resolvedFontSize, weight: .regular)
            : NSFont.systemFont(ofSize: resolvedFontSize)
        let headingWeight: NSFont.Weight = .bold
        let resolvedHeadingFonts = headingFonts.map { template in
            let scaledSize = max(11, template.pointSize * scale)
            return usesMonospacedFont
                ? NSFont.monospacedSystemFont(ofSize: scaledSize, weight: headingWeight)
                : NSFont.systemFont(ofSize: scaledSize, weight: headingWeight)
        }

        return MarkdownTheme(
            headingColors: headingColors,
            bodyFont: resolvedBodyFont,
            headingFonts: resolvedHeadingFonts,
            codeFont: NSFont.monospacedSystemFont(
                ofSize: max(11, resolvedFontSize - 1),
                weight: .regular
            ),
            codeBackground: codeBackground,
            emphasisColor: emphasisColor,
            strongColor: strongColor,
            linkColor: linkColor,
            listMarkerColor: listMarkerColor,
            blockquoteColor: blockquoteColor
        )
    }

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
