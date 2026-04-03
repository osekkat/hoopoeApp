import AppKit
import Foundation

/// Configuration for the AppKit-backed markdown editor.
public struct PlanEditorConfiguration {
    public let fontSize: CGFloat
    public let usesMonospacedFont: Bool
    public let wrapsLines: Bool
    public let markdownTheme: MarkdownTheme

    public init(
        fontSize: CGFloat = 14,
        usesMonospacedFont: Bool = true,
        wrapsLines: Bool = true,
        markdownTheme: MarkdownTheme = .default
    ) {
        self.fontSize = fontSize
        self.usesMonospacedFont = usesMonospacedFont
        self.wrapsLines = wrapsLines
        self.markdownTheme = markdownTheme
    }

    var baseFont: NSFont {
        if usesMonospacedFont {
            .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        } else {
            .systemFont(ofSize: fontSize)
        }
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
            highlighter = MarkdownHighlighter(theme: configuration.markdownTheme)
            applyConfiguration()
            rehighlightText(fullParse: true)
        }
    }

    public var onTextChange: ((String) -> Void)?
    public var onSelectionChange: ((NSRange) -> Void)?

    private let scrollView: NSScrollView
    private let textView: EditorTextView
    private var highlighter: MarkdownHighlighter
    private var pendingEdit: PendingEdit?
    private var isApplyingProgrammaticChange = false
    private var pendingCallback: DispatchWorkItem?

    public init(
        text: String = "",
        configuration: PlanEditorConfiguration = PlanEditorConfiguration(),
        onTextChange: ((String) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.onTextChange = onTextChange
        self.highlighter = MarkdownHighlighter(theme: configuration.markdownTheme)
        self.scrollView = NSScrollView(frame: .zero)
        self.textView = EditorTextView(frame: .zero)

        super.init(frame: .zero)

        configureTextView()
        configureScrollView()
        layoutEditor()
        applyConfiguration()
        applyText(text, rehighlightIncrementally: false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.textView)
        }
    }

    private func configureTextView() {
        textView.delegate = self
        textView.pendingEditHandler = { [weak self] range, replacement in
            self?.pendingEdit = self?.makePendingEdit(for: range, replacement: replacement)
        }
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
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
    }

    private func layoutEditor() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
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
        textView.font = configuration.baseFont
        textView.typingAttributes = [
            .font: configuration.baseFont,
            .foregroundColor: NSColor.labelColor,
        ]

        textView.isHorizontallyResizable = !configuration.wrapsLines
        textView.autoresizingMask = configuration.wrapsLines ? [.width] : []
        scrollView.hasHorizontalScroller = !configuration.wrapsLines

        guard let textContainer = textView.textContainer else { return }
        textContainer.widthTracksTextView = configuration.wrapsLines
        textContainer.containerSize = NSSize(
            width: configuration.wrapsLines ? 0 : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func applyText(_ newText: String, rehighlightIncrementally: Bool) {
        let selectedRanges = textView.selectedRanges
        isApplyingProgrammaticChange = true
        textView.string = newText
        textView.selectedRanges = selectedRanges
        pendingEdit = nil
        rehighlightText(fullParse: !rehighlightIncrementally)
        isApplyingProgrammaticChange = false
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
        let latestText = textView.string
        let workItem = DispatchWorkItem { [weak self] in
            self?.onTextChange?(latestText)
        }
        pendingCallback = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16), execute: workItem)
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
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChange?(textView.selectedRange())
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
