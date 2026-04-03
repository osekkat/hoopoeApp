import AppKit
import Foundation
import SwiftUI

/// Configuration for the AppKit-backed markdown editor.
public struct PlanEditorConfiguration {
    public let fontSize: CGFloat
    public let usesMonospacedFont: Bool
    public let wrapsLines: Bool
    public let showsLineNumbers: Bool
    public let themeID: String
    public let markdownTheme: MarkdownTheme

    public init(
        fontSize: CGFloat = 14,
        usesMonospacedFont: Bool = true,
        wrapsLines: Bool = true,
        showsLineNumbers: Bool = true,
        themeID: String = "system",
        markdownTheme: MarkdownTheme = .default
    ) {
        self.fontSize = fontSize
        self.usesMonospacedFont = usesMonospacedFont
        self.wrapsLines = wrapsLines
        self.showsLineNumbers = showsLineNumbers
        self.themeID = themeID
        self.markdownTheme = markdownTheme
    }

    var baseFont: NSFont {
        if usesMonospacedFont {
            .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        } else {
            .systemFont(ofSize: fontSize)
        }
    }

    var resolvedMarkdownTheme: MarkdownTheme {
        markdownTheme.adapted(
            fontSize: fontSize,
            usesMonospacedFont: usesMonospacedFont
        )
    }

    func isEquivalent(to other: Self) -> Bool {
        fontSize == other.fontSize
            && usesMonospacedFont == other.usesMonospacedFont
            && wrapsLines == other.wrapsLines
            && showsLineNumbers == other.showsLineNumbers
            && themeID == other.themeID
    }
}

@MainActor
public final class PlanEditorView: NSView {
    public var text: String {
        get { textView.string }
        set {
            guard textView.string != newValue else { return }
            applyText(newValue, rehighlightIncrementally: false)
        }
    }

    public var configuration: PlanEditorConfiguration {
        didSet {
            highlighter = MarkdownHighlighter(theme: configuration.resolvedMarkdownTheme)
            applyConfiguration()
            rehighlightText(fullParse: true)
        }
    }

    public var textBinding: Binding<String>? {
        didSet {
            syncBindingIntoView()
        }
    }

    public var onTextChange: ((String) -> Void)?
    public var onSelectionChange: ((NSRange) -> Void)?

    private let scrollView: NSScrollView
    private let textView: EditorTextView
    private let lineNumberRuler: LineNumberRulerView
    private var highlighter: MarkdownHighlighter
    private var pendingEdit: PendingEdit?
    private var isApplyingProgrammaticChange = false
    private var pendingCallback: DispatchWorkItem?
    private var textStorageObserver: NSObjectProtocol?

    public init(
        text: String = "",
        configuration: PlanEditorConfiguration = PlanEditorConfiguration(),
        onTextChange: ((String) -> Void)? = nil
    ) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        let scrollView = NSScrollView(frame: .zero)
        let textView = EditorTextView(frame: .zero, textContainer: textContainer)
        let lineNumberRuler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        layoutManager.allowsNonContiguousLayout = true
        textContainer.lineFragmentPadding = 0
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        self.configuration = configuration
        self.onTextChange = onTextChange
        self.highlighter = MarkdownHighlighter(theme: configuration.resolvedMarkdownTheme)
        self.scrollView = scrollView
        self.textView = textView
        self.lineNumberRuler = lineNumberRuler

        super.init(frame: .zero)

        configureTextView()
        configureScrollView()
        layoutEditor()
        applyConfiguration()
        applyText(text, rehighlightIncrementally: false)
        observeTextStorage()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let textStorageObserver {
            NotificationCenter.default.removeObserver(textStorageObserver)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.textView)
        }
    }

    public func insertText(_ insertedText: String) {
        let selectedRange = clampedRange(textView.selectedRange())
        guard textView.shouldChangeText(in: selectedRange, replacementString: insertedText) else {
            return
        }

        textView.textStorage?.replaceCharacters(in: selectedRange, with: insertedText)
        let insertionLocation = selectedRange.location + (insertedText as NSString).length
        textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
        textView.didChangeText()
    }

    public func selectRange(_ range: NSRange) {
        let clamped = clampedRange(range)
        textView.setSelectedRange(clamped)
        textView.scrollRangeToVisible(clamped)
        window?.makeFirstResponder(textView)
    }

    public func scrollToSection(_ heading: String) {
        guard let headingRange = Self.headingLineRange(
            matching: heading,
            in: textView.string
        ) else {
            return
        }
        selectRange(headingRange)
    }

    // Programmatic editor control methods (insertText, selectRange,
    // scrollToSection) are defined above. PlanEditorProxy at the bottom
    // of this file delegates to them.

    private func configureTextView() {
        textView.delegate = self
        textView.pendingEditHandler = { [weak self] range, replacement in
            self?.pendingEdit = self?.makePendingEdit(for: range, replacement: replacement)
        }
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.autoresizingMask = [.width]
    }

    private func configureScrollView() {
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = lineNumberRuler
    }

    private func layoutEditor() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.documentView = textView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func applyConfiguration() {
        let forcedAppearance = resolvedAppearance(for: configuration.themeID)
        appearance = forcedAppearance
        scrollView.appearance = forcedAppearance
        textView.appearance = forcedAppearance
        lineNumberRuler.appearance = forcedAppearance

        textView.font = configuration.baseFont
        textView.typingAttributes = [
            .font: configuration.baseFont,
            .foregroundColor: NSColor.labelColor,
        ]

        textView.isHorizontallyResizable = !configuration.wrapsLines
        textView.autoresizingMask = configuration.wrapsLines ? [.width] : []
        scrollView.hasHorizontalScroller = !configuration.wrapsLines
        scrollView.rulersVisible = configuration.showsLineNumbers
        lineNumberRuler.isHidden = !configuration.showsLineNumbers
        lineNumberRuler.updateAppearance(font: configuration.baseFont)

        guard let textContainer = textView.textContainer else { return }
        textContainer.widthTracksTextView = configuration.wrapsLines
        textContainer.containerSize = NSSize(
            width: configuration.wrapsLines ? 0 : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func resolvedAppearance(for themeID: String) -> NSAppearance? {
        switch themeID {
        case "light":
            NSAppearance(named: .aqua)
        case "dark":
            NSAppearance(named: .darkAqua)
        default:
            nil
        }
    }

    private func applyText(_ newText: String, rehighlightIncrementally: Bool) {
        let selectedRanges = textView.selectedRanges
        pendingCallback?.cancel()
        pendingCallback = nil
        isApplyingProgrammaticChange = true
        textView.string = newText
        textView.selectedRanges = selectedRanges
        pendingEdit = nil
        rehighlightText(fullParse: !rehighlightIncrementally)
        isApplyingProgrammaticChange = false
        lineNumberRuler.invalidateLineNumbers()
    }

    private func rehighlightText(fullParse: Bool) {
        let highlighted: NSAttributedString
        if fullParse {
            highlighted = highlighter.highlight(textView.string)
        } else if let pendingEdit {
            highlighted = highlighter.edit(
                replacingBytesIn: pendingEdit.byteRange,
                newLength: pendingEdit.newByteLength,
                fullText: textView.string
            )
        } else {
            highlighted = highlighter.highlight(textView.string)
        }

        applyAttributes(from: highlighted)
        pendingEdit = nil
    }

    private func applyAttributes(from highlighted: NSAttributedString) {
        guard let textStorage = textView.textStorage else { return }
        let selectedRanges = textView.selectedRanges
        let fullRange = NSRange(location: 0, length: textStorage.length)

        isApplyingProgrammaticChange = true
        textStorage.beginEditing()
        textStorage.setAttributes([
            .font: configuration.baseFont,
            .foregroundColor: NSColor.labelColor,
        ], range: fullRange)
        highlighted.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            textStorage.addAttributes(attributes, range: range)
        }
        textStorage.endEditing()
        textView.selectedRanges = selectedRanges
        textView.typingAttributes = [
            .font: configuration.baseFont,
            .foregroundColor: NSColor.labelColor,
        ]
        isApplyingProgrammaticChange = false
    }

    private func scheduleTextChangeCallback() {
        pendingCallback?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let latestText = self.textView.string
            self.textBinding?.wrappedValue = latestText
            self.onTextChange?(latestText)
            self.pendingCallback = nil
        }
        pendingCallback = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16), execute: workItem)
    }

    static func headingLineRange(matching heading: String, in text: String) -> NSRange? {
        let needle = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return nil
        }

        let nsText = text as NSString
        var match: NSRange?
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byLines]
        ) { line, substringRange, _, stop in
            guard let line,
                  line.hasPrefix("#"),
                  line.localizedCaseInsensitiveContains(needle)
            else {
                return
            }
            match = substringRange
            stop.pointee = true
        }
        return match
    }

    private func observeTextStorage() {
        guard let textStorage = textView.textStorage else {
            return
        }

        textStorageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: textStorage,
            queue: .main
        ) { [weak self] _ in
            self?.lineNumberRuler.invalidateLineNumbers()
        }
    }

    private func syncBindingIntoView() {
        guard let textBinding, textBinding.wrappedValue != textView.string else { return }
        applyText(textBinding.wrappedValue, rehighlightIncrementally: false)
    }

    private func clampedRange(_ range: NSRange) -> NSRange {
        let textLength = (textView.string as NSString).length
        let location = min(max(range.location, 0), textLength)
        let length = min(max(range.length, 0), textLength - location)
        return NSRange(location: location, length: length)
    }

    private func makePendingEdit(for range: NSRange, replacement: String?) -> PendingEdit? {
        guard let stringRange = Range(range, in: textView.string) else { return nil }
        let prefix = textView.string[..<stringRange.lowerBound]
        let replaced = textView.string[stringRange]
        return PendingEdit(
            byteRange: UInt32(prefix.utf8.count)..<UInt32(prefix.utf8.count + replaced.utf8.count),
            newByteLength: UInt32((replacement ?? "").utf8.count)
        )
    }
}

extension PlanEditorView: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        guard !isApplyingProgrammaticChange else { return }
        rehighlightText(fullParse: false)
        scheduleTextChangeCallback()
        lineNumberRuler.invalidateLineNumbers()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChange?(textView.selectedRange())
        lineNumberRuler.invalidateLineNumbers()
    }
}

private final class EditorTextView: NSTextView {
    var pendingEditHandler: ((NSRange, String?) -> Void)?

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        pendingEditHandler?(affectedCharRange, replacementString)
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
}

private struct PendingEdit {
    let byteRange: Range<UInt32>
    let newByteLength: UInt32
}

@MainActor
private final class LineNumberRulerView: NSRulerView {
    private weak var editorTextView: NSTextView?
    private var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private var cachedLineNumbers: [Int: Int] = [0: 1]
    private let gutterPadding: CGFloat = 8

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.editorTextView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        updateAppearance(font: textView.font ?? .monospacedSystemFont(ofSize: 14, weight: .regular))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func updateAppearance(font: NSFont) {
        numberFont = .monospacedDigitSystemFont(ofSize: max(11, font.pointSize - 1), weight: .regular)
        invalidateLineNumbers()
    }

    func invalidateLineNumbers() {
        cachedLineNumbers = Self.makeLineNumberIndex(for: editorTextView?.string ?? "")
        ruleThickness = Self.ruleThickness(for: cachedLineNumbers.count, font: numberFont, padding: gutterPadding)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = editorTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return
        }

        NSColor.windowBackgroundColor.setFill()
        rect.fill()

        let text = textView.string as NSString
        let currentLineStart = text.lineRange(
            for: NSRange(location: min(textView.selectedRange().location, text.length), length: 0)
        ).location
        let visibleRect = scrollView?.contentView.bounds ?? rect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right

        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var lineGlyphRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange,
                withoutAdditionalLayout: true
            )
            defer { glyphIndex = NSMaxRange(lineGlyphRange) }

            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
            let firstGlyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            guard glyphIndex == firstGlyphIndex else {
                continue
            }

            let labelY = lineRect.minY + textView.textContainerOrigin.y
            let labelRect = NSRect(
                x: gutterPadding,
                y: labelY,
                width: max(0, ruleThickness - gutterPadding * 2),
                height: lineRect.height
            )

            if lineRange.location == currentLineStart {
                let highlightRect = labelRect.insetBy(dx: -4, dy: 1)
                NSColor.selectedTextBackgroundColor.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: highlightRect, xRadius: 4, yRadius: 4).fill()
            }

            let lineNumber = cachedLineNumbers[lineRange.location] ?? 1
            let attributes: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraphStyle,
            ]
            NSString(string: "\(lineNumber)").draw(in: labelRect, withAttributes: attributes)
        }

        NSColor.separatorColor.setStroke()
        NSBezierPath.strokeLine(
            from: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY),
            to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY)
        )
    }

    private static func makeLineNumberIndex(for text: String) -> [Int: Int] {
        let nsText = text as NSString
        var lineNumbers: [Int: Int] = [0: 1]
        guard nsText.length > 0 else {
            return lineNumbers
        }

        var nextLineNumber = 2
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byLines, .substringNotRequired]
        ) { _, _, enclosingRange, _ in
            let nextStart = NSMaxRange(enclosingRange)
            guard nextStart < nsText.length else {
                return
            }
            lineNumbers[nextStart] = nextLineNumber
            nextLineNumber += 1
        }

        return lineNumbers
    }

    private static func ruleThickness(for lineCount: Int, font: NSFont, padding: CGFloat) -> CGFloat {
        let digitCount = max(2, String(max(1, lineCount)).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        return padding * 2 + digitWidth * CGFloat(digitCount)
    }
}

@MainActor
public final class PlanEditorProxy {
    private weak var editorView: PlanEditorView?

    public init() {}

    public func insertText(_ text: String) {
        editorView?.insertText(text)
    }

    public func selectRange(_ range: NSRange) {
        editorView?.selectRange(range)
    }

    public func scrollToSection(_ heading: String) {
        editorView?.scrollToSection(heading)
    }

    fileprivate func connect(to editorView: PlanEditorView) {
        self.editorView = editorView
    }
}

public struct PlanEditorRepresentable: NSViewRepresentable {
    @Binding private var text: String
    private let configuration: PlanEditorConfiguration
    private let proxy: PlanEditorProxy?
    private let onSelectionChange: ((NSRange) -> Void)?

    public init(
        text: Binding<String>,
        configuration: PlanEditorConfiguration = PlanEditorConfiguration(),
        proxy: PlanEditorProxy? = nil,
        onSelectionChange: ((NSRange) -> Void)? = nil
    ) {
        _text = text
        self.configuration = configuration
        self.proxy = proxy
        self.onSelectionChange = onSelectionChange
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSelectionChange: onSelectionChange)
    }

    public func makeNSView(context: Context) -> PlanEditorView {
        let editorView = PlanEditorView(text: text, configuration: configuration)
        editorView.textBinding = nil
        context.coordinator.attach(to: editorView)
        proxy?.connect(to: editorView)
        return editorView
    }

    public func updateNSView(_ nsView: PlanEditorView, context: Context) {
        context.coordinator.attach(to: nsView)
        proxy?.connect(to: nsView)

        if nsView.text != text {
            context.coordinator.isApplyingSwiftUIUpdate = true
            nsView.text = text
            context.coordinator.lastKnownText = text
            context.coordinator.isApplyingSwiftUIUpdate = false
        }

        if !nsView.configuration.isEquivalent(to: configuration) {
            nsView.configuration = configuration
        }
    }

    public final class Coordinator: NSObject {
        private let text: Binding<String>
        private let onSelectionChange: ((NSRange) -> Void)?
        fileprivate var isApplyingSwiftUIUpdate = false
        fileprivate var lastKnownText: String

        init(
            text: Binding<String>,
            onSelectionChange: ((NSRange) -> Void)?
        ) {
            self.text = text
            self.onSelectionChange = onSelectionChange
            self.lastKnownText = text.wrappedValue
        }

        fileprivate func attach(to editorView: PlanEditorView) {
            editorView.onTextChange = { [weak self] updatedText in
                guard let self else {
                    return
                }
                self.lastKnownText = updatedText
                guard !self.isApplyingSwiftUIUpdate, self.text.wrappedValue != updatedText else {
                    return
                }
                self.text.wrappedValue = updatedText
            }

            editorView.onSelectionChange = { [weak self] range in
                self?.onSelectionChange?(range)
            }
        }
    }
}
