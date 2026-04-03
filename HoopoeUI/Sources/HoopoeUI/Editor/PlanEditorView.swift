import AppKit
import Foundation
import SwiftTreeSitter
import SwiftUI
import TreeSitterMarkdown

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
            && markdownTheme.isEquivalent(to: other.markdownTheme)
    }
}

struct MarkdownSection: Equatable {
    let identifier: String
    let title: String
    let level: Int
    let headingRange: NSRange
    let bodyRange: NSRange

    var isFoldable: Bool {
        bodyRange.length > 0
    }
}

private struct DisplayedSection {
    let identifier: String
    let headingDisplayLocation: Int
    let isFolded: Bool
    let isFoldable: Bool
}

struct FoldedDisplayModel {
    fileprivate struct Segment {
        enum Kind {
            case visible
            case placeholder(sectionID: String)
        }

        let kind: Kind
        let documentRange: NSRange
        let displayRange: NSRange
    }

    let text: String
    let segments: [Segment]
    let placeholderRanges: [String: NSRange]
    fileprivate let displayedSections: [DisplayedSection]
    let documentLength: Int

    var hasActiveFolds: Bool {
        !placeholderRanges.isEmpty
    }

    static func make(
        documentText: String,
        sections: [MarkdownSection],
        collapsedSectionIDs: Set<String>
    ) -> Self {
        let nsText = documentText as NSString
        let visibleCollapsedSections = visibleCollapsedSections(
            in: sections,
            collapsedSectionIDs: collapsedSectionIDs
        )

        guard !visibleCollapsedSections.isEmpty else {
            let length = nsText.length
            return Self(
                text: documentText,
                segments: [
                    Segment(
                        kind: .visible,
                        documentRange: NSRange(location: 0, length: length),
                        displayRange: NSRange(location: 0, length: length)
                    ),
                ],
                placeholderRanges: [:],
                displayedSections: sections.map {
                    DisplayedSection(
                        identifier: $0.identifier,
                        headingDisplayLocation: $0.headingRange.location,
                        isFolded: false,
                        isFoldable: $0.isFoldable
                    )
                },
                documentLength: length
            )
        }

        var display = ""
        var segments: [Segment] = []
        var placeholderRanges: [String: NSRange] = [:]
        var documentCursor = 0
        var displayCursor = 0

        for section in visibleCollapsedSections {
            let hiddenRange = section.bodyRange
            guard documentCursor <= hiddenRange.location else {
                continue
            }

            if documentCursor < hiddenRange.location {
                let visibleRange = NSRange(location: documentCursor, length: hiddenRange.location - documentCursor)
                let visibleText = nsText.substring(with: visibleRange)
                display.append(visibleText)
                let displayRange = NSRange(location: displayCursor, length: visibleRange.length)
                segments.append(
                    Segment(
                        kind: .visible,
                        documentRange: visibleRange,
                        displayRange: displayRange
                    )
                )
                displayCursor = NSMaxRange(displayRange)
            }

            let placeholder = placeholderText(
                for: section,
                in: documentText,
                endsBeforeDocumentEnd: NSMaxRange(hiddenRange) < nsText.length
            )
            let placeholderLength = (placeholder as NSString).length
            display.append(placeholder)
            let displayRange = NSRange(location: displayCursor, length: placeholderLength)
            segments.append(
                Segment(
                    kind: .placeholder(sectionID: section.identifier),
                    documentRange: hiddenRange,
                    displayRange: displayRange
                )
            )
            placeholderRanges[section.identifier] = displayRange
            displayCursor = NSMaxRange(displayRange)
            documentCursor = NSMaxRange(hiddenRange)
        }

        if documentCursor < nsText.length {
            let visibleRange = NSRange(location: documentCursor, length: nsText.length - documentCursor)
            let visibleText = nsText.substring(with: visibleRange)
            display.append(visibleText)
            let displayRange = NSRange(location: displayCursor, length: visibleRange.length)
            segments.append(
                Segment(
                    kind: .visible,
                    documentRange: visibleRange,
                    displayRange: displayRange
                )
            )
        }

        let provisionalModel = Self(
            text: display,
            segments: segments,
            placeholderRanges: placeholderRanges,
            displayedSections: [],
            documentLength: nsText.length
        )

        let displayedSections = sections.compactMap { section -> DisplayedSection? in
            guard let displayLocation = provisionalModel.displayLocation(forDocumentLocation: section.headingRange.location) else {
                return nil
            }
            return DisplayedSection(
                identifier: section.identifier,
                headingDisplayLocation: displayLocation,
                isFolded: collapsedSectionIDs.contains(section.identifier),
                isFoldable: section.isFoldable
            )
        }

        return Self(
            text: display,
            segments: segments,
            placeholderRanges: placeholderRanges,
            displayedSections: displayedSections,
            documentLength: nsText.length
        )
    }

    func documentRange(forDisplayRange range: NSRange) -> NSRange? {
        guard range.location >= 0, range.length >= 0 else {
            return nil
        }

        if range.length == 0 {
            guard let documentLocation = documentLocation(forDisplayLocation: range.location) else {
                return nil
            }
            return NSRange(location: documentLocation, length: 0)
        }

        let endLocation = NSMaxRange(range)
        guard let start = documentLocation(forDisplayLocation: range.location),
              let end = documentLocation(forDisplayLocation: endLocation)
        else {
            return nil
        }

        for segment in segments {
            switch segment.kind {
            case .visible:
                if range.location >= segment.displayRange.location,
                   endLocation <= NSMaxRange(segment.displayRange)
                {
                    return NSRange(location: start, length: end - start)
                }
            case .placeholder:
                if rangesIntersect(range, segment.displayRange) {
                    return nil
                }
            }
        }

        return NSRange(location: start, length: end - start)
    }

    func displayRange(forDocumentRange range: NSRange) -> NSRange? {
        guard range.location >= 0, range.length >= 0 else {
            return nil
        }

        if range.length == 0 {
            guard let displayLocation = displayLocation(forDocumentLocation: range.location) else {
                return nil
            }
            return NSRange(location: displayLocation, length: 0)
        }

        let endLocation = NSMaxRange(range)
        guard let start = displayLocation(forDocumentLocation: range.location),
              let end = displayLocation(forDocumentLocation: endLocation)
        else {
            return nil
        }

        for segment in segments {
            switch segment.kind {
            case .visible:
                if range.location >= segment.documentRange.location,
                   endLocation <= NSMaxRange(segment.documentRange)
                {
                    return NSRange(location: start, length: end - start)
                }
            case .placeholder:
                if rangesIntersect(range, segment.documentRange) {
                    return nil
                }
            }
        }

        return NSRange(location: start, length: end - start)
    }

    func documentLocation(forDisplayLocation location: Int) -> Int? {
        guard location >= 0 else {
            return nil
        }

        if location == 0 {
            return 0
        }

        if location == (text as NSString).length {
            return documentLength
        }

        for segment in segments {
            let displayStart = segment.displayRange.location
            let displayEnd = NSMaxRange(segment.displayRange)

            switch segment.kind {
            case .visible:
                if location >= displayStart, location <= displayEnd {
                    return segment.documentRange.location + (location - displayStart)
                }
            case .placeholder:
                if location >= displayStart, location < displayEnd {
                    return nil
                }
            }
        }

        return nil
    }

    func displayLocation(forDocumentLocation location: Int) -> Int? {
        guard location >= 0 else {
            return nil
        }

        if location == 0 {
            return 0
        }

        if location == documentLength {
            return (text as NSString).length
        }

        for segment in segments {
            let documentStart = segment.documentRange.location
            let documentEnd = NSMaxRange(segment.documentRange)

            switch segment.kind {
            case .visible:
                if location >= documentStart, location <= documentEnd {
                    return segment.displayRange.location + (location - documentStart)
                }
            case .placeholder:
                if location >= documentStart, location < documentEnd {
                    return nil
                }
            }
        }

        return nil
    }

    func placeholderSectionID(atDisplayLocation location: Int) -> String? {
        for segment in segments {
            guard case let .placeholder(sectionID) = segment.kind else {
                continue
            }
            if location >= segment.displayRange.location, location < NSMaxRange(segment.displayRange) {
                return sectionID
            }
        }
        return nil
    }

    func intersectsPlaceholder(_ range: NSRange) -> Bool {
        if range.length == 0 {
            return placeholderSectionID(atDisplayLocation: range.location) != nil
        }

        return segments.contains { segment in
            guard case .placeholder = segment.kind else {
                return false
            }
            return rangesIntersect(range, segment.displayRange)
        }
    }

    private static func placeholderText(
        for section: MarkdownSection,
        in documentText: String,
        endsBeforeDocumentEnd: Bool
    ) -> String {
        let nsText = documentText as NSString
        let hiddenText = nsText.substring(with: section.bodyRange)
        let lineCount = max(1, hiddenText.split(whereSeparator: \.isNewline).count)
        let suffix = endsBeforeDocumentEnd ? "\n" : ""
        let noun = lineCount == 1 ? "line" : "lines"
        return "… \(lineCount) \(noun) folded …\(suffix)"
    }

    private static func visibleCollapsedSections(
        in sections: [MarkdownSection],
        collapsedSectionIDs: Set<String>
    ) -> [MarkdownSection] {
        var result: [MarkdownSection] = []
        var hiddenUntil = 0

        for section in sections
        where section.isFoldable && collapsedSectionIDs.contains(section.identifier) {
            let bodyStart = section.bodyRange.location
            guard bodyStart >= hiddenUntil else {
                continue
            }
            result.append(section)
            hiddenUntil = NSMaxRange(section.bodyRange)
        }

        return result
    }

    private func rangesIntersect(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        lhs.location < NSMaxRange(rhs) && rhs.location < NSMaxRange(lhs)
    }
}

@MainActor
final class MarkdownSectionParser {
    private let parser: Parser
    private let isConfigured: Bool

    init() {
        parser = Parser()

        do {
            let language = Language(language: tree_sitter_markdown())
            try parser.setLanguage(language)
            isConfigured = true
        } catch {
            isConfigured = false
        }
    }

    func sections(in text: String) -> [MarkdownSection] {
        guard isConfigured, !text.isEmpty, let rootNode = parser.parse(text)?.rootNode else {
            return []
        }

        let nsText = text as NSString
        var headings: [(level: Int, title: String, lineRange: NSRange)] = []
        collectHeadings(from: rootNode, text: text, nsText: nsText, into: &headings)
        guard !headings.isEmpty else {
            return []
        }

        var occurrenceIndex: [String: Int] = [:]
        return headings.enumerated().map { index, heading in
            let nextBoundary = headings[(index + 1)...]
                .first(where: { $0.level <= heading.level })?
                .lineRange.location ?? nsText.length
            let bodyStart = min(NSMaxRange(heading.lineRange), nsText.length)
            let bodyEnd = max(bodyStart, nextBoundary)
            let normalizedTitle = heading.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = normalizedTitle.isEmpty ? "Untitled Section" : normalizedTitle
            let baseIdentifier = "\(heading.level)|\(title.lowercased())"
            let occurrence = occurrenceIndex[baseIdentifier, default: 0] + 1
            occurrenceIndex[baseIdentifier] = occurrence

            return MarkdownSection(
                identifier: "\(baseIdentifier)|\(occurrence)",
                title: title,
                level: heading.level,
                headingRange: heading.lineRange,
                bodyRange: NSRange(location: bodyStart, length: bodyEnd - bodyStart)
            )
        }
    }

    private func collectHeadings(
        from node: Node,
        text: String,
        nsText: NSString,
        into headings: inout [(level: Int, title: String, lineRange: NSRange)]
    ) {
        if node.nodeType == "atx_heading",
           let lineRange = nsRange(for: node, in: text).map({ nsText.lineRange(for: $0) })
        {
            let line = nsText.substring(with: lineRange)
            headings.append((
                level: headingLevel(for: node),
                title: sanitizedHeadingTitle(from: line),
                lineRange: lineRange
            ))
        }

        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }
            collectHeadings(from: child, text: text, nsText: nsText, into: &headings)
        }
    }

    private func nsRange(for node: Node, in text: String) -> NSRange? {
        let utf8 = text.utf8
        let startByte = Int(node.startByte)
        let endByte = Int(node.endByte)

        guard startByte <= utf8.count, endByte <= utf8.count, startByte < endByte,
              let start = text.utf8.index(text.utf8.startIndex, offsetBy: startByte, limitedBy: text.utf8.endIndex),
              let end = text.utf8.index(text.utf8.startIndex, offsetBy: endByte, limitedBy: text.utf8.endIndex)
        else {
            return nil
        }

        return NSRange(start..<end, in: text)
    }

    private func headingLevel(for node: Node) -> Int {
        switch node.child(at: 0)?.nodeType {
        case "atx_h1_marker": 1
        case "atx_h2_marker": 2
        case "atx_h3_marker": 3
        case "atx_h4_marker": 4
        case "atx_h5_marker": 5
        case "atx_h6_marker": 6
        default: 1
        }
    }

    private func sanitizedHeadingTitle(from rawLine: String) -> String {
        var title = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasPrefix("#") {
            title.removeFirst()
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        while title.hasSuffix("#") {
            title.removeLast()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return title
    }
}

@MainActor
public final class PlanEditorView: NSView {
    public var text: String {
        get { documentText }
        set {
            guard documentText != newValue else { return }
            applyDocumentText(newValue, rehighlightIncrementally: false)
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
    private let sectionParser: MarkdownSectionParser
    private var highlighter: MarkdownHighlighter
    private var documentText: String
    private var sections: [MarkdownSection]
    private var collapsedSectionIDs: Set<String>
    private var displayModel: FoldedDisplayModel
    private var pendingEdit: PendingEdit?
    private var isApplyingProgrammaticChange = false
    private var pendingCallback: DispatchWorkItem?
    private var textStorageObserver: NSObjectProtocol?
    private var lastSelectedDocumentRange = NSRange(location: 0, length: 0)

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
        self.sectionParser = MarkdownSectionParser()
        self.documentText = text
        self.sections = []
        self.collapsedSectionIDs = []
        self.displayModel = FoldedDisplayModel.make(
            documentText: text,
            sections: [],
            collapsedSectionIDs: []
        )

        super.init(frame: .zero)

        configureTextView()
        configureScrollView()
        layoutEditor()
        applyConfiguration()
        applyDocumentText(text, rehighlightIncrementally: false)
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
        replaceDocumentRange(currentDocumentSelectionRange(), with: insertedText)
    }

    public func selectRange(_ range: NSRange) {
        let clamped = clampedDocumentRange(range)
        ensureRangeVisible(clamped)
        guard let displayRange = displayModel.displayRange(forDocumentRange: clamped) else {
            return
        }
        lastSelectedDocumentRange = clamped
        textView.setSelectedRange(displayRange)
        textView.scrollRangeToVisible(displayRange)
        window?.makeFirstResponder(textView)
    }

    public func scrollToSection(_ heading: String) {
        guard let headingRange = Self.headingLineRange(
            matching: heading,
            in: documentText
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
        textView.editInterceptor = { [weak self] range, replacement in
            self?.interceptEditIfNeeded(in: range, replacement: replacement) ?? false
        }
        textView.foldCurrentSectionHandler = { [weak self] in
            self?.foldCurrentSection()
        }
        textView.unfoldCurrentSectionHandler = { [weak self] in
            self?.unfoldCurrentSection()
        }
        textView.foldAllSectionsHandler = { [weak self] in
            self?.foldAllSections()
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
        lineNumberRuler.updateSections(displayModel.displayedSections)
        lineNumberRuler.toggleSectionHandler = { [weak self] sectionID in
            self?.toggleSection(withID: sectionID)
        }

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

    private func applyDocumentText(
        _ newText: String,
        rehighlightIncrementally: Bool,
        preferredSelection: NSRange? = nil
    ) {
        pendingCallback?.cancel()
        pendingCallback = nil
        documentText = newText
        rebuildSections()
        refreshDisplay(
            fullParse: displayModel.hasActiveFolds || !rehighlightIncrementally,
            preferredSelection: preferredSelection
        )
    }

    private func refreshDisplay(fullParse: Bool, preferredSelection: NSRange? = nil) {
        let desiredSelection = preferredSelection ?? currentDocumentSelectionRange()
        let nextDisplayModel = FoldedDisplayModel.make(
            documentText: documentText,
            sections: sections,
            collapsedSectionIDs: collapsedSectionIDs
        )

        displayModel = nextDisplayModel
        let displaySelection = nextDisplayModel.displayRange(
            forDocumentRange: clampedDocumentRange(desiredSelection)
        ) ?? NSRange(location: 0, length: 0)

        isApplyingProgrammaticChange = true
        textView.string = nextDisplayModel.text
        textView.setSelectedRange(displaySelection)
        lineNumberRuler.updateSections(nextDisplayModel.displayedSections)
        rehighlightText(fullParse: fullParse || nextDisplayModel.hasActiveFolds)
        isApplyingProgrammaticChange = false

        lastSelectedDocumentRange = clampedDocumentRange(desiredSelection)
        lineNumberRuler.invalidateLineNumbers()
    }

    private func rebuildSections() {
        sections = sectionParser.sections(in: documentText)
        let validSectionIDs = Set(sections.map(\.identifier))
        collapsedSectionIDs.formIntersection(validSectionIDs)
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
        applyPlaceholderAttributes(to: textStorage)
        textStorage.endEditing()
        textView.selectedRanges = selectedRanges
        textView.typingAttributes = [
            .font: configuration.baseFont,
            .foregroundColor: NSColor.labelColor,
        ]
        isApplyingProgrammaticChange = false
    }

    private func applyPlaceholderAttributes(to textStorage: NSTextStorage) {
        for range in displayModel.placeholderRanges.values {
            guard range.location + range.length <= textStorage.length else {
                continue
            }
            textStorage.addAttributes([
                .font: NSFont.systemFont(ofSize: max(12, configuration.fontSize - 1), weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ], range: range)
        }
    }

    private func scheduleTextChangeCallback() {
        pendingCallback?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let latestText = self.documentText
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
        guard let textBinding, textBinding.wrappedValue != documentText else { return }
        applyDocumentText(textBinding.wrappedValue, rehighlightIncrementally: false)
    }

    private func clampedDisplayRange(_ range: NSRange) -> NSRange {
        let textLength = (textView.string as NSString).length
        let location = min(max(range.location, 0), textLength)
        let length = min(max(range.length, 0), textLength - location)
        return NSRange(location: location, length: length)
    }

    private func clampedDocumentRange(_ range: NSRange) -> NSRange {
        let textLength = (documentText as NSString).length
        let location = min(max(range.location, 0), textLength)
        let length = min(max(range.length, 0), textLength - location)
        return NSRange(location: location, length: length)
    }

    private func currentDocumentSelectionRange() -> NSRange {
        let displaySelection = clampedDisplayRange(textView.selectedRange())

        if let documentRange = displayModel.documentRange(forDisplayRange: displaySelection) {
            return clampedDocumentRange(documentRange)
        }

        if let sectionID = displayModel.placeholderSectionID(atDisplayLocation: displaySelection.location),
           let section = sections.first(where: { $0.identifier == sectionID })
        {
            return NSRange(location: section.bodyRange.location, length: 0)
        }

        return lastSelectedDocumentRange
    }

    private func replaceDocumentRange(_ range: NSRange, with replacement: String) {
        let clamped = clampedDocumentRange(range)
        ensureRangeVisible(clamped)
        guard let stringRange = Range(clamped, in: documentText) else {
            return
        }

        let updatedText = documentText.replacingCharacters(in: stringRange, with: replacement)
        let updatedSelection = NSRange(
            location: clamped.location + (replacement as NSString).length,
            length: 0
        )
        pendingEdit = nil
        applyDocumentText(updatedText, rehighlightIncrementally: false, preferredSelection: updatedSelection)
        scheduleTextChangeCallback()
        onSelectionChange?(updatedSelection)
    }

    private func interceptEditIfNeeded(in range: NSRange, replacement: String?) -> Bool {
        guard displayModel.hasActiveFolds else {
            return false
        }

        let displayRange = clampedDisplayRange(range)
        if displayModel.intersectsPlaceholder(displayRange) {
            if let sectionID = displayModel.placeholderSectionID(atDisplayLocation: displayRange.location) {
                toggleSection(withID: sectionID, forceExpanded: true)
            }
            return true
        }

        guard let documentRange = displayModel.documentRange(forDisplayRange: displayRange) else {
            return true
        }

        replaceDocumentRange(documentRange, with: replacement ?? "")
        return true
    }

    private func ensureRangeVisible(_ range: NSRange) {
        guard displayModel.displayRange(forDocumentRange: range) == nil else {
            return
        }

        var changed = false
        while let hiddenSection = collapsedSection(containing: range) {
            collapsedSectionIDs.remove(hiddenSection.identifier)
            changed = true
        }

        if changed {
            refreshDisplay(fullParse: true, preferredSelection: range)
        }
    }

    private func collapsedSection(containing range: NSRange) -> MarkdownSection? {
        sections.last { section in
            collapsedSectionIDs.contains(section.identifier)
                && section.bodyRange.length > 0
                && range.location >= section.bodyRange.location
                && NSMaxRange(range) <= NSMaxRange(section.bodyRange)
        }
    }

    private func currentFoldableSection() -> MarkdownSection? {
        let selection = currentDocumentSelectionRange()
        let location = selection.location
        return sections.last { section in
            section.isFoldable
                && location >= section.headingRange.location
                && location < max(NSMaxRange(section.headingRange), NSMaxRange(section.bodyRange))
        }
    }

    private func toggleSection(withID sectionID: String, forceExpanded: Bool? = nil) {
        guard let section = sections.first(where: { $0.identifier == sectionID }) else {
            return
        }

        if forceExpanded == true {
            collapsedSectionIDs.remove(sectionID)
        } else if forceExpanded == false {
            collapsedSectionIDs.insert(sectionID)
        } else if collapsedSectionIDs.contains(sectionID) {
            collapsedSectionIDs.remove(sectionID)
        } else if section.isFoldable {
            collapsedSectionIDs.insert(sectionID)
        }

        refreshDisplay(fullParse: true, preferredSelection: section.headingRange)
    }

    private func foldCurrentSection() {
        guard let section = currentFoldableSection(), section.isFoldable else {
            return
        }
        toggleSection(withID: section.identifier, forceExpanded: false)
    }

    private func unfoldCurrentSection() {
        let selection = clampedDisplayRange(textView.selectedRange())
        if let sectionID = displayModel.placeholderSectionID(atDisplayLocation: selection.location) {
            toggleSection(withID: sectionID, forceExpanded: true)
            return
        }

        guard let section = currentFoldableSection(),
              collapsedSectionIDs.contains(section.identifier)
        else {
            return
        }
        toggleSection(withID: section.identifier, forceExpanded: true)
    }

    private func foldAllSections() {
        let nextCollapsedIDs = Set(sections.filter(\.isFoldable).map(\.identifier))
        guard nextCollapsedIDs != collapsedSectionIDs else {
            return
        }
        collapsedSectionIDs = nextCollapsedIDs
        refreshDisplay(fullParse: true, preferredSelection: currentDocumentSelectionRange())
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

        documentText = textView.string
        rebuildSections()
        displayModel = FoldedDisplayModel.make(
            documentText: documentText,
            sections: sections,
            collapsedSectionIDs: collapsedSectionIDs
        )
        lineNumberRuler.updateSections(displayModel.displayedSections)
        rehighlightText(fullParse: false)
        lastSelectedDocumentRange = currentDocumentSelectionRange()
        scheduleTextChangeCallback()
        lineNumberRuler.invalidateLineNumbers()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        let selection = currentDocumentSelectionRange()
        lastSelectedDocumentRange = selection
        onSelectionChange?(selection)
        lineNumberRuler.invalidateLineNumbers()
    }
}

private final class EditorTextView: NSTextView {
    var pendingEditHandler: ((NSRange, String?) -> Void)?
    var editInterceptor: ((NSRange, String?) -> Bool)?
    var foldCurrentSectionHandler: (() -> Void)?
    var unfoldCurrentSectionHandler: (() -> Void)?
    var foldAllSectionsHandler: (() -> Void)?

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if editInterceptor?(affectedCharRange, replacementString) == true {
            return false
        }
        pendingEditHandler?(affectedCharRange, replacementString)
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, modifiers) {
        case (123, [.command, .option, .shift]):
            foldAllSectionsHandler?()
        case (123, [.command, .option]):
            foldCurrentSectionHandler?()
        case (124, [.command, .option]):
            unfoldCurrentSectionHandler?()
        default:
            super.keyDown(with: event)
        }
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
    private var displayedSectionsByLocation: [Int: DisplayedSection] = [:]
    private var disclosureFrames: [String: NSRect] = [:]
    private let gutterPadding: CGFloat = 8
    private let disclosureAreaWidth: CGFloat = 12

    var toggleSectionHandler: ((String) -> Void)?

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

    func updateSections(_ sections: [DisplayedSection]) {
        displayedSectionsByLocation = Dictionary(
            uniqueKeysWithValues: sections.map { ($0.headingDisplayLocation, $0) }
        )
        invalidateLineNumbers()
    }

    func invalidateLineNumbers() {
        cachedLineNumbers = Self.makeLineNumberIndex(for: editorTextView?.string ?? "")
        disclosureFrames = [:]
        ruleThickness = Self.ruleThickness(
            for: cachedLineNumbers.count,
            font: numberFont,
            padding: gutterPadding,
            disclosureWidth: disclosureAreaWidth
        )
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
            let section = displayedSectionsByLocation[lineRange.location]
            let disclosureRect = NSRect(
                x: gutterPadding,
                y: labelY + max(0, (lineRect.height - disclosureAreaWidth) / 2),
                width: disclosureAreaWidth,
                height: disclosureAreaWidth
            )
            let labelRect = NSRect(
                x: gutterPadding + disclosureAreaWidth + 4,
                y: labelY,
                width: max(0, ruleThickness - gutterPadding * 2 - disclosureAreaWidth - 4),
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

            if let section, section.isFoldable {
                disclosureFrames[section.identifier] = disclosureRect
                drawDisclosureTriangle(
                    in: disclosureRect,
                    isFolded: section.isFolded,
                    color: lineRange.location == currentLineStart
                        ? NSColor.labelColor
                        : NSColor.secondaryLabelColor
                )
            }
        }

        NSColor.separatorColor.setStroke()
        NSBezierPath.strokeLine(
            from: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY),
            to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY)
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = disclosureFrames.first(where: { $0.value.contains(point) }) {
            toggleSectionHandler?(hit.key)
            return
        }
        super.mouseDown(with: event)
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

    private func drawDisclosureTriangle(in rect: NSRect, isFolded: Bool, color: NSColor) {
        let path = NSBezierPath()
        let insetRect = rect.insetBy(dx: 2, dy: 2)

        if isFolded {
            path.move(to: NSPoint(x: insetRect.minX, y: insetRect.maxY))
            path.line(to: NSPoint(x: insetRect.maxX, y: insetRect.midY))
            path.line(to: NSPoint(x: insetRect.minX, y: insetRect.minY))
        } else {
            path.move(to: NSPoint(x: insetRect.minX, y: insetRect.maxY))
            path.line(to: NSPoint(x: insetRect.maxX, y: insetRect.maxY))
            path.line(to: NSPoint(x: insetRect.midX, y: insetRect.minY))
        }

        path.close()
        color.setFill()
        path.fill()
    }

    private static func ruleThickness(
        for lineCount: Int,
        font: NSFont,
        padding: CGFloat,
        disclosureWidth: CGFloat
    ) -> CGFloat {
        let digitCount = max(2, String(max(1, lineCount)).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        return padding * 2 + disclosureWidth + 4 + digitWidth * CGFloat(digitCount)
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
