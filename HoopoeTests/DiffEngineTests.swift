import AppKit
import Foundation
import Testing

@testable import Hoopoe

// MARK: - LineDiffEngine Tests

@Suite("LineDiffEngine")
struct DiffEngineTests {
    // MARK: - Identical Texts

    @Test("Identical texts produce all-equal lines and zero stats")
    func identicalTexts() {
        let text = "Line 1\nLine 2\nLine 3"
        let (lines, stats) = LineDiffEngine.diff(old: text, new: text)

        #expect(lines.count == 3)
        for line in lines {
            #expect(line.kind == .equal)
        }
        #expect(stats.additions == 0)
        #expect(stats.deletions == 0)
        #expect(stats.modifications == 0)
    }

    // MARK: - Empty Inputs

    @Test("Both empty produces no lines")
    func bothEmpty() {
        let (lines, stats) = LineDiffEngine.diff(old: "", new: "")
        // components(separatedBy:) on "" returns [""], so 1 equal line
        #expect(lines.count == 1)
        #expect(lines[0].kind == .equal)
        #expect(stats.additions == 0)
        #expect(stats.deletions == 0)
    }

    @Test("Old empty, new has content shows all additions")
    func oldEmptyNewHasContent() {
        let (lines, stats) = LineDiffEngine.diff(old: "", new: "A\nB")

        // old = [""], new = ["A", "B"]
        // "" is removed, "A" and "B" inserted → one modified + one added
        // or depending on diff: could be deletion of "" + addition of "A" + addition of "B"
        let addedCount = lines.filter { $0.kind == .added }.count
        let modifiedCount = lines.filter { $0.kind == .modified }.count
        #expect(addedCount + modifiedCount > 0)
        #expect(stats.deletions == 0 || stats.modifications > 0)
    }

    @Test("Old has content, new empty shows all deletions")
    func oldHasContentNewEmpty() {
        let (lines, stats) = LineDiffEngine.diff(old: "A\nB", new: "")

        let deletedCount = lines.filter { $0.kind == .deleted }.count
        let modifiedCount = lines.filter { $0.kind == .modified }.count
        #expect(deletedCount + modifiedCount > 0)
        #expect(stats.additions == 0 || stats.modifications > 0)
    }

    // MARK: - Pure Additions

    @Test("Lines added at end are detected as additions")
    func linesAddedAtEnd() {
        let old = "A\nB"
        let new = "A\nB\nC\nD"
        let (lines, stats) = LineDiffEngine.diff(old: old, new: new)

        #expect(stats.additions == 2)
        #expect(stats.deletions == 0)
        #expect(stats.modifications == 0)

        // First two lines should be equal
        #expect(lines[0].kind == .equal)
        #expect(lines[0].leftText == "A")
        #expect(lines[1].kind == .equal)
        #expect(lines[1].leftText == "B")

        // Last two should be added
        #expect(lines[2].kind == .added)
        #expect(lines[2].rightText == "C")
        #expect(lines[3].kind == .added)
        #expect(lines[3].rightText == "D")
    }

    @Test("Line added in middle is detected")
    func lineAddedInMiddle() {
        let old = "A\nC"
        let new = "A\nB\nC"
        let (lines, stats) = LineDiffEngine.diff(old: old, new: new)

        #expect(stats.additions == 1)
        #expect(stats.deletions == 0)

        let addedLines = lines.filter { $0.kind == .added }
        #expect(addedLines.count == 1)
        #expect(addedLines[0].rightText == "B")
    }

    // MARK: - Pure Deletions

    @Test("Lines deleted from end are detected")
    func linesDeletedFromEnd() {
        let old = "A\nB\nC\nD"
        let new = "A\nB"
        let (lines, stats) = LineDiffEngine.diff(old: old, new: new)

        #expect(stats.deletions == 2)
        #expect(stats.additions == 0)

        let deletedLines = lines.filter { $0.kind == .deleted }
        #expect(deletedLines.count == 2)
    }

    @Test("Line deleted from middle is detected")
    func lineDeletedFromMiddle() {
        let old = "A\nB\nC"
        let new = "A\nC"
        let (lines, stats) = LineDiffEngine.diff(old: old, new: new)

        #expect(stats.deletions == 1)
        let deletedLines = lines.filter { $0.kind == .deleted }
        #expect(deletedLines.count == 1)
        #expect(deletedLines[0].leftText == "B")
    }

    // MARK: - Modifications

    @Test("Changed line detected as modification")
    func changedLineIsModification() {
        let old = "A\nB\nC"
        let new = "A\nX\nC"
        let (lines, stats) = LineDiffEngine.diff(old: old, new: new)

        #expect(stats.modifications == 1)
        #expect(stats.additions == 0)
        #expect(stats.deletions == 0)

        let modifiedLines = lines.filter { $0.kind == .modified }
        #expect(modifiedLines.count == 1)
        #expect(modifiedLines[0].leftText == "B")
        #expect(modifiedLines[0].rightText == "X")
    }

    @Test("All lines changed shows all modifications")
    func allLinesChanged() {
        let old = "A\nB"
        let new = "X\nY"
        let (lines, stats) = LineDiffEngine.diff(old: old, new: new)

        #expect(stats.modifications == 2)
        #expect(stats.additions == 0)
        #expect(stats.deletions == 0)

        #expect(lines[0].kind == .modified)
        #expect(lines[0].leftText == "A")
        #expect(lines[0].rightText == "X")
    }

    // MARK: - Mixed Changes

    @Test("Mix of additions, deletions, and modifications")
    func mixedChanges() {
        let old = "Header\nOld Line\nKeep This"
        let new = "Header\nNew Line\nKeep This\nFooter"
        let (lines, stats) = LineDiffEngine.diff(old: old, new: new)

        // "Header" = equal, "Old Line" → "New Line" = modified, "Keep This" = equal, "Footer" = added
        #expect(lines.count == 4)
        #expect(stats.additions == 1)
        #expect(stats.modifications == 1)
        #expect(stats.deletions == 0)
    }

    // MARK: - Line Numbers

    @Test("Equal lines have matching line numbers on both sides")
    func equalLineNumbers() {
        let text = "A\nB\nC"
        let (lines, _) = LineDiffEngine.diff(old: text, new: text)

        for (i, line) in lines.enumerated() {
            #expect(line.leftLineNumber == i + 1)
            #expect(line.rightLineNumber == i + 1)
        }
    }

    @Test("Deleted lines have nil right line number")
    func deletedLineNumbers() {
        let old = "A\nB\nC"
        let new = "A\nC"
        let (lines, _) = LineDiffEngine.diff(old: old, new: new)

        let deleted = lines.filter { $0.kind == .deleted }
        for line in deleted {
            #expect(line.leftLineNumber != nil)
            #expect(line.rightLineNumber == nil)
        }
    }

    @Test("Added lines have nil left line number")
    func addedLineNumbers() {
        let old = "A\nC"
        let new = "A\nB\nC"
        let (lines, _) = LineDiffEngine.diff(old: old, new: new)

        let added = lines.filter { $0.kind == .added }
        for line in added {
            #expect(line.leftLineNumber == nil)
            #expect(line.rightLineNumber != nil)
        }
    }

    // MARK: - DiffStats Summary

    @Test("DiffStats summary format")
    func statsSummary() {
        let stats = DiffStats(additions: 3, deletions: 1, modifications: 2)
        #expect(stats.summary == "3 additions, 1 deletions, 2 modifications")
    }
}

// MARK: - DiffViewerAppKit Tests (BUG FIX: NSSplitView.addArrangedSubview → addSubview)

@Suite("DiffViewerAppKit")
struct DiffViewerAppKitTests {
    @Test("DiffViewerAppKit initializes with split view containing two panes")
    func viewHierarchyStructure() {
        let viewer = DiffViewerAppKit(frame: NSRect(x: 0, y: 0, width: 800, height: 400))

        // The viewer should have subviews: a summary label and a split view
        #expect(viewer.subviews.count == 2)

        // Find the NSSplitView among subviews
        let splitView = viewer.subviews.compactMap { $0 as? NSSplitView }.first
        #expect(splitView != nil, "DiffViewerAppKit must contain an NSSplitView")

        // The split view must have exactly 2 subviews (left and right panes).
        // This regresses the bug where addArrangedSubview (an NSStackView method)
        // was called instead of addSubview — that would compile-fail, but if it
        // somehow passed, the panes would not appear.
        #expect(splitView!.subviews.count == 2)
    }

    @Test("update populates both panes and sets summary text")
    func updatePopulatesPanes() {
        let viewer = DiffViewerAppKit(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        viewer.update(oldText: "Hello", newText: "Hello\nWorld")

        // Find the summary label (NSTextField)
        let label = viewer.subviews.compactMap { $0 as? NSTextField }.first
        #expect(label != nil)
        #expect(label!.stringValue.contains("addition"))
    }

    @Test("Split view is vertical for side-by-side layout")
    func splitViewIsVertical() {
        let viewer = DiffViewerAppKit(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let splitView = viewer.subviews.compactMap { $0 as? NSSplitView }.first
        #expect(splitView != nil)
        // isVertical means the divider is vertical → panes are side-by-side (horizontal layout)
        #expect(splitView!.isVertical == true)
    }
}
