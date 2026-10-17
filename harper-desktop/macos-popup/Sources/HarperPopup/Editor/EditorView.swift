// Added in this fork (taehee-pd/harperSwift).

import AppKit
import SwiftUI

/// What the model asks of the text view. Edits go through the text view so Undo works.
@MainActor
protocol EditorTextController: AnyObject {
    func replace(_ range: NSRange, with text: String)
    func reveal(_ lint: EditorLint)
    func closePopover()
}

/// The editor window: the text, the problems beside it, and a status bar. It shares Settings'
/// chrome: the title and the controls sit in a unified toolbar, and the problems use the same
/// grouped rows as the settings panes.
struct EditorView: View {
    @StateObject private var model: EditorModel

    init(model: EditorModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                EditorTextView(model: model)
                if model.showsProblems {
                    Divider()
                    ProblemsPanel(model: model)
                        .frame(width: 300)
                }
            }
            Divider()
            EditorStatusBar(model: model)
        }
        .navigationTitle("Editor")
        .toolbar {
            // One item each, so the text size buttons stay joined like Settings' Back and Forward.
            ToolbarItem(placement: .primaryAction) { FontPicker(model: model) }
            ToolbarItem(placement: .primaryAction) { TextSizeButtons(model: model) }
            ToolbarItem(placement: .primaryAction) { ProblemsToggle(model: model) }
        }
        .frame(minWidth: 620, minHeight: 400)
        .alert(
            "Harper couldn\u{2019}t check this text",
            isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
            presenting: model.failure
        ) { _ in
            Button("OK") {}
        } message: { Text($0) }
    }
}

// Font, text size, and the Problems toggle. They sit in the toolbar; macOS 13 shows no SwiftUI
// toolbar in a window Harper makes itself, so there they sit in the status bar.

private struct FontPicker: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Picker("Font", selection: $model.font) {
            ForEach(EditorFont.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Font")
    }
}

private struct TextSizeButtons: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ControlGroup {
            Button { model.fontSize = max(11, model.fontSize - 1) } label: {
                Label("Smaller Text", systemImage: "textformat.size.smaller")
            }
            .keyboardShortcut("-", modifiers: .command)
            .help("Smaller text (\u{2318}\u{2212})")
            Button { model.fontSize = min(32, model.fontSize + 1) } label: {
                Label("Larger Text", systemImage: "textformat.size.larger")
            }
            .keyboardShortcut("=", modifiers: .command)
            .help("Larger text (\u{2318}+)")
        }
        .controlGroupStyle(.navigation)
    }
}

private struct ProblemsToggle: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Button {
            model.showsProblems.toggle()
        } label: {
            Label(model.showsProblems ? "Hide Problems" : "Show Problems", systemImage: "sidebar.right")
        }
        .help(model.showsProblems ? "Hide Problems" : "Show Problems")
    }
}

// MARK: - Text view

/// Adds Control-Command-Y (accept the first suggestion), Escape (close the popover), and a
/// placeholder drawn where the first line of text starts, so it sits exactly at the caret.
final class HarperTextView: NSTextView {
    var onAccept: (() -> Void)?
    var onEscape: (() -> Bool)?

    var placeholder = "" {
        didSet {
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }

    private var placeholderAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
    }

    private var placeholderRect: NSRect {
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        return NSRect(origin: origin, size: (placeholder as NSString).size(withAttributes: placeholderAttributes))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if textStorage?.length == 0, !placeholder.isEmpty {
            (placeholder as NSString).draw(at: placeholderRect.origin, withAttributes: placeholderAttributes)
        }
    }

    // An edit redraws only the text it touched, which may not cover the placeholder. Text being
    // composed with an input method changes without `didChangeText`.
    override func didChangeText() {
        super.didChangeText()
        setNeedsDisplay(placeholderRect)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        setNeedsDisplay(placeholderRect)
    }

    override func unmarkText() {
        super.unmarkText()
        setNeedsDisplay(placeholderRect)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.control, .command], event.charactersIgnoringModifiers?.lowercased() == "y" {
            onAccept?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() != true {
            super.cancelOperation(sender)
        }
    }
}

struct EditorTextView: NSViewRepresentable {
    static let inset = NSSize(width: 28, height: 24)

    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        // The layout already keeps the text below the title bar; an automatic inset would add
        // the title bar's height a second time.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero

        // TextKit 1: underlines are layout manager temporary attributes, which do not touch the
        // text or its Undo history.
        let textView = HarperTextView(usingTextLayoutManager: false)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // Harper does the checking; the system spelling underline would double up.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = Self.inset
        textView.font = model.font.font(size: model.fontSize)
        textView.string = model.text
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.setAccessibilityLabel("Document")
        textView.placeholder = "Start writing\u{2026}"
        textView.onAccept = { [weak coordinator = context.coordinator] in coordinator?.acceptAtCaret() }
        textView.onEscape = { [weak coordinator = context.coordinator] in coordinator?.closePopoverIfShown() ?? false }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        model.editor = context.coordinator

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let font = model.font.font(size: model.fontSize)
        if textView.font != font {
            textView.font = font
            textView.typingAttributes[.font] = font
            textView.needsDisplay = true
        }
        context.coordinator.followLints()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, NSPopoverDelegate, EditorTextController {
        let model: EditorModel
        weak var textView: HarperTextView?

        private var popover: NSPopover?
        private var popoverLint: EditorLint?
        /// True while an edit is being processed, so the caret move that follows it counts as
        /// typing, not navigation.
        private var isEditing = false
        /// Set by typing and cleared by moving the caret. While set, problems at the caret stay
        /// hidden, so the word being typed does not blink.
        private var typedSinceCaretMoved = false

        init(model: EditorModel) {
            self.model = model
        }

        // MARK: Editing

        nonisolated func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            let text = textStorage.string
            MainActor.assumeIsolated {
                isEditing = true
                typedSinceCaretMoved = true
                closePopover()
                // Publishing during text storage processing would re-enter the text view.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.model.textDidChange(text, edited: editedRange, changeInLength: delta)
                    self.isEditing = false
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isEditing, let textView else { return }
            typedSinceCaretMoved = false
            drawUnderlines()

            let selection = textView.selectedRange()
            if selection.length == 0, let lint = lint(at: selection.location) {
                showPopover(for: lint)
            } else {
                closePopover()
            }
        }

        private func lint(at caret: Int) -> EditorLint? {
            model.lints.first { $0.contains(caret: caret) }
        }

        // MARK: Underlines

        func drawUnderlines() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let length = (textView.string as NSString).length
            let all = NSRange(location: 0, length: length)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: all)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)

            let caret = textView.selectedRange().length == 0 ? textView.selectedRange().location : nil
            for lint in model.lints where NSMaxRange(lint.range) <= length {
                if typedSinceCaretMoved, let caret, lint.contains(caret: caret) {
                    continue
                }
                let color = NSColor(lint.popup.kindColor.color)
                var attributes: [NSAttributedString.Key: Any] = [
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: color,
                ]
                if let popoverLint, lint.isSame(as: popoverLint), popover?.isShown == true {
                    attributes[.backgroundColor] = color.withAlphaComponent(0.16)
                }
                layoutManager.addTemporaryAttributes(attributes, forCharacterRange: lint.range)
            }
        }

        // MARK: Popover

        private func showPopover(for lint: EditorLint) {
            guard let textView, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            if popover?.isShown == true, let popoverLint, popoverLint.isSame(as: lint) { return }
            closePopover()

            let glyphs = layoutManager.glyphRange(forCharacterRange: lint.range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y

            let host = NSHostingController(
                rootView: PopupView(data: lint.popup, chrome: .glass) { [weak self] action in
                    self?.model.handle(action, for: lint)
                }
            )
            host.sizingOptions = .preferredContentSize

            let popover = NSPopover()
            popover.contentViewController = host
            popover.behavior = .semitransient
            popover.delegate = self
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)

            self.popover = popover
            popoverLint = lint
            drawUnderlines()
        }

        func closePopover() {
            guard let popover else { return }
            popover.close()
            forgetPopover()
        }

        /// AppKit closes a semitransient popover on its own when the user clicks elsewhere.
        nonisolated func popoverDidClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let closed = notification.object as? NSPopover, closed === popover else { return }
                forgetPopover()
            }
        }

        private func forgetPopover() {
            popover = nil
            popoverLint = nil
            drawUnderlines()
        }

        /// After a check, keeps the popover on its problem, or closes it when the problem is gone
        /// (fixed, ignored, or its rule turned off).
        func followLints() {
            if let popoverLint {
                if let current = model.lints.first(where: { $0.isSame(as: popoverLint) }) {
                    self.popoverLint = current
                } else {
                    closePopover()
                    return
                }
            }
            drawUnderlines()
        }

        func closePopoverIfShown() -> Bool {
            guard popover?.isShown == true else { return false }
            closePopover()
            return true
        }

        /// Control-Command-Y: the first suggestion for the problem at the caret.
        func acceptAtCaret() {
            guard let textView else { return }
            let shown = popover?.isShown == true ? popoverLint : nil
            let target = shown ?? lint(at: textView.selectedRange().location)
            guard let target, !target.popup.suggestions.isEmpty else {
                NSSound.beep()
                return
            }
            model.apply(target, suggestion: 0)
        }

        // MARK: EditorTextController

        func replace(_ range: NSRange, with text: String) {
            guard let textView, NSMaxRange(range) <= (textView.string as NSString).length else { return }
            closePopover()
            if textView.shouldChangeText(in: range, replacementString: text) {
                textView.textStorage?.replaceCharacters(in: range, with: text)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
            }
        }

        func reveal(_ lint: EditorLint) {
            guard let textView, NSMaxRange(lint.range) <= (textView.string as NSString).length else { return }
            textView.window?.makeFirstResponder(textView)
            textView.scrollRangeToVisible(lint.range)
            textView.setSelectedRange(NSRange(location: lint.location, length: 0))
            showPopover(for: lint)
        }
    }
}

// MARK: - Problems

/// The problems in the text, one section per kind, in the grouped rows Settings uses.
struct ProblemsPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if !model.lints.isEmpty {
                        Button("Ignore All", action: model.ignoreAll)
                    }
                } label: {
                    Label {
                        Text(summary)
                    } icon: {
                        if model.lints.isEmpty && !model.text.isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }

            ForEach(model.kindGroups) { group in
                Section {
                    ForEach(group.lints) { lint in
                        ProblemRow(lint: lint, model: model)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle().fill(group.color.color).frame(width: 7, height: 7)
                        Text(group.name)
                        Text("\(group.lints.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var summary: String {
        switch model.lints.count {
        case 0: model.text.isEmpty ? "Nothing to check yet" : "No problems found"
        case 1: "1 problem"
        case let count: "\(count) problems"
        }
    }
}

/// A problem as a settings row: what is wrong, the text it is about, then the fixes. Clicking it
/// shows the problem in the text.
private struct ProblemRow: View {
    let lint: EditorLint
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PopupText.message(lint.popup.message))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\u{201c}\(lint.popup.flaggedText)\u{201d}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 6) {
                ForEach(Array(lint.popup.suggestions.prefix(3).enumerated()), id: \.offset) { index, suggestion in
                    Button {
                        model.apply(lint, suggestion: index)
                    } label: {
                        Text(PopupText.suggestion(suggestion, flaggedText: lint.popup.flaggedText))
                    }
                    .buttonStyle(SuggestionButtonStyle(isPrimary: index == 0))
                    .controlSize(.small)
                    .help(suggestion.description)
                }
                Spacer(minLength: 0)
                Button("Ignore") { model.ignore(lint) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.reveal(lint) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show in Text") { model.reveal(lint) }
    }
}

// MARK: - Status bar

struct EditorStatusBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.lints.isEmpty ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(problemSummary)
            }
            Text(model.wordCount == 1 ? "1 word" : "\(model.wordCount) words")
            Text("\(model.text.count) characters")
            Spacer()
            if #unavailable(macOS 14) {
                FontPicker(model: model)
                Group {
                    TextSizeButtons(model: model)
                    ProblemsToggle(model: model)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .controlSize(.small)
        .padding(.horizontal, 20)
        .frame(height: 30)
        .background(.bar)
    }

    private var problemSummary: String {
        switch model.lints.count {
        case 0: model.text.isEmpty ? "Ready" : "No problems"
        case 1: "1 problem"
        case let count: "\(count) problems"
        }
    }
}
