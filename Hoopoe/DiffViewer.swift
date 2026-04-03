import AppKit
import SwiftUI

// MARK: - Diff Types

/// Represents a line-level diff result.
struct LineDiff: Sendable {
    let leftLineNumber: Int?
    let rightLineNumber: Int?
    let leftText: String
    let rightText: String
    let kind: DiffLineKind
}

enum DiffLineKind: Sendable {
    case equal
    case added
    case deleted
    case modified
}

/// Statistics for a diff.
struct DiffStats: Sendable {
    let additions: Int
    let deletions: Int
    let modifications: Int

    var summary: String {
        "\(additions) additions, \(deletions) deletions, \(modifications) modifications"
    }
}

// MARK: - Line Diff Engine

/// Computes line-level diffs using Swift's CollectionDifference.
enum LineDiffEngine {
    static func diff(old: String, new: String) -> (lines: [LineDiff], stats: DiffStats) {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

        let difference = newLines.difference(from: oldLines)

        var result: [LineDiff] = []
        var additions = 0
        var deletions = 0
        var modifications = 0

        // Build index sets for removed and inserted lines
        var removedIndices: Set<Int> = []
        var insertedIndices: Set<Int> = []

        for change in difference {
            switch change {
            case .remove(let offset, _, _):
                removedIndices.insert(offset)
            case .insert(let offset, _, _):
                insertedIndices.insert(offset)
            }
        }

        // Walk both arrays to produce diff lines
        var oldIdx = 0
        var newIdx = 0

        while oldIdx < oldLines.count || newIdx < newLines.count {
            let oldRemoved = oldIdx < oldLines.count && removedIndices.contains(oldIdx)
            let newInserted = newIdx < newLines.count && insertedIndices.contains(newIdx)

            if oldRemoved && newInserted {
                // Modified line (deletion + insertion at same position)
                result.append(LineDiff(
                    leftLineNumber: oldIdx + 1,
                    rightLineNumber: newIdx + 1,
                    leftText: oldLines[oldIdx],
                    rightText: newLines[newIdx],
                    kind: .modified
                ))
                modifications += 1
                oldIdx += 1
                newIdx += 1
            } else if oldRemoved {
                result.append(LineDiff(
                    leftLineNumber: oldIdx + 1,
                    rightLineNumber: nil,
                    leftText: oldLines[oldIdx],
                    rightText: "",
                    kind: .deleted
                ))
                deletions += 1
                oldIdx += 1
            } else if newInserted {
                result.append(LineDiff(
                    leftLineNumber: nil,
                    rightLineNumber: newIdx + 1,
                    leftText: "",
                    rightText: newLines[newIdx],
                    kind: .added
                ))
                additions += 1
                newIdx += 1
            } else {
                // Equal line
                if oldIdx < oldLines.count && newIdx < newLines.count {
                    result.append(LineDiff(
                        leftLineNumber: oldIdx + 1,
                        rightLineNumber: newIdx + 1,
                        leftText: oldLines[oldIdx],
                        rightText: newLines[newIdx],
                        kind: .equal
                    ))
                }
                oldIdx += 1
                newIdx += 1
            }
        }

        let stats = DiffStats(additions: additions, deletions: deletions, modifications: modifications)
        return (result, stats)
    }
}

// MARK: - Diff Colors

enum DiffColors {
    static let addition = NSColor.systemGreen.withAlphaComponent(0.15)
    static let deletion = NSColor.systemRed.withAlphaComponent(0.15)
    static let modification = NSColor.systemYellow.withAlphaComponent(0.15)
}

// MARK: - DiffTextView (AppKit)

/// A single pane of the diff viewer — an NSTextView configured for diff display.
final class DiffTextView: NSView {
    let scrollView: NSScrollView
    let textView: NSTextView

    var onScroll: ((NSPoint) -> Void)?

    override init(frame: NSRect) {
        scrollView = NSScrollView(frame: frame)
        textView = NSTextView(frame: frame)

        super.init(frame: frame)

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        addSubview(scrollView)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]

        // Scroll sync notification
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        onScroll?(scrollView.contentView.bounds.origin)
    }

    func setScrollPosition(_ origin: NSPoint) {
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func applyDiff(lines: [LineDiff], side: DiffSide) {
        let storage = textView.textStorage!
        storage.beginEditing()
        storage.deleteCharacters(in: NSRange(location: 0, length: storage.length))

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2

        for (index, line) in lines.enumerated() {
            let text = side == .left ? line.leftText : line.rightText
            let lineNum = side == .left ? line.leftLineNumber : line.rightLineNumber

            let prefix = lineNum.map { String(format: "%4d  ", $0) } ?? "      "
            let fullLine = prefix + text + (index < lines.count - 1 ? "\n" : "")

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .backgroundColor: backgroundColor(for: line.kind, side: side),
            ]

            storage.append(NSAttributedString(string: fullLine, attributes: attrs))
        }

        storage.endEditing()
    }

    private func backgroundColor(for kind: DiffLineKind, side: DiffSide) -> NSColor {
        switch kind {
        case .equal:
            return .clear
        case .added:
            return side == .right ? DiffColors.addition : .clear
        case .deleted:
            return side == .left ? DiffColors.deletion : .clear
        case .modified:
            return DiffColors.modification
        }
    }
}

enum DiffSide {
    case left
    case right
}

// MARK: - DiffViewerAppKit

/// The complete diff viewer — two synchronized text panes with a summary bar.
final class DiffViewerAppKit: NSView {
    private let leftPane = DiffTextView(frame: .zero)
    private let rightPane = DiffTextView(frame: .zero)
    private let summaryLabel = NSTextField(labelWithString: "")
    private let splitView = NSSplitView()

    private var isSyncingScroll = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupUI() {
        // Summary bar at top
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summaryLabel)

        // Split view for side-by-side panes
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)

        splitView.addSubview(leftPane)
        splitView.addSubview(rightPane)

        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            splitView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Scroll sync
        leftPane.onScroll = { [weak self] origin in
            guard let self, !self.isSyncingScroll else { return }
            self.isSyncingScroll = true
            self.rightPane.setScrollPosition(origin)
            self.isSyncingScroll = false
        }

        rightPane.onScroll = { [weak self] origin in
            guard let self, !self.isSyncingScroll else { return }
            self.isSyncingScroll = true
            self.leftPane.setScrollPosition(origin)
            self.isSyncingScroll = false
        }
    }

    func update(oldText: String, newText: String) {
        let (lines, stats) = LineDiffEngine.diff(old: oldText, new: newText)

        leftPane.applyDiff(lines: lines, side: .left)
        rightPane.applyDiff(lines: lines, side: .right)

        summaryLabel.stringValue = stats.summary
    }
}

// MARK: - SwiftUI Bridge

/// NSViewRepresentable wrapper for embedding DiffViewerAppKit in SwiftUI.
struct DiffViewerRepresentable: NSViewRepresentable {
    let oldText: String
    let newText: String

    func makeNSView(context: Context) -> DiffViewerAppKit {
        let view = DiffViewerAppKit(frame: .zero)
        view.update(oldText: oldText, newText: newText)
        return view
    }

    func updateNSView(_ nsView: DiffViewerAppKit, context: Context) {
        nsView.update(oldText: oldText, newText: newText)
    }
}

// MARK: - SwiftUI Wrapper View

/// A SwiftUI view that displays a diff between two text versions.
///
/// Generic over the input: pass any two strings. The plan version context
/// is provided by the caller, making this reusable for markdown, code, and config diffs.
struct DiffView: View {
    let oldText: String
    let newText: String
    let oldLabel: String
    let newLabel: String

    init(oldText: String, newText: String, oldLabel: String = "Before", newLabel: String = "After") {
        self.oldText = oldText
        self.newText = newText
        self.oldLabel = oldLabel
        self.newLabel = newLabel
    }

    var body: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 0) {
                Text(oldLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(DiffColors.deletion.swiftUIColor.opacity(0.3))

                Text(newLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(DiffColors.addition.swiftUIColor.opacity(0.3))
            }

            DiffViewerRepresentable(oldText: oldText, newText: newText)
        }
    }
}

// MARK: - NSColor SwiftUI Bridge

private extension NSColor {
    var swiftUIColor: Color {
        Color(nsColor: self)
    }
}

// MARK: - Preview

#Preview {
    DiffView(
        oldText: """
        # My Plan

        This is the original plan.
        It has some content here.

        ## Section A

        Details about section A.
        """,
        newText: """
        # My Plan

        This is the improved plan.
        It has some content here.
        And a new line was added.

        ## Section A

        Updated details about section A.

        ## Section B (New)

        A completely new section.
        """,
        oldLabel: "Round 1",
        newLabel: "Round 2"
    )
    .frame(width: 800, height: 500)
}
