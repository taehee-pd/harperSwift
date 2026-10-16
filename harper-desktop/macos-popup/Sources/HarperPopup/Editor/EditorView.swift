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

/// The editor window: the text, the problems beside it, and a status bar. There is no visible
/// title bar; the window controls sit over a band at the top of the page.
struct EditorView: View {
    @StateObject private var model: EditorModel

    init(model: EditorModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        GeometryReader { proxy in
            layout(titleBarHeight: proxy.safeAreaInsets.top)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 620, minHeight: 400)
        .alert(
            "Harper couldn\u{2019}t check this text",
            isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
            presenting: model.failure
        ) { _ in
            Button("OK") {}
        } message: { Text($0) }
    }

    private func layout(titleBarHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // The window controls sit here; the text scrolls below them, not under them.
                    Color.clear.frame(height: titleBarHeight)
                    EditorTextView(model: model)
                        .overlay(alignment: .topLeading) {
                            if model.text.isEmpty {
                                Text("Start writing\u{2026}")
                                    .font(Font(model.font.font(size: model.fontSize)))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, EditorTextView.inset.width + 5)
                                    .padding(.top, EditorTextView.inset.height)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .background(Color(nsColor: .textBackgroundColor))
                if model.showsProblems {
                    Divider()
                    ProblemsSidebar(model: model, headerHeight: max(titleBarHeight, 28))
                        .frame(width: 300)
                }
            }
            Divider()
            EditorStatusBar(model: model)
        }
    }
}

// MARK: - Text view

/// Adds Control-Command-Y (accept the first suggestion) and Escape (close the popover).
final class HarperTextView: NSTextView {
    var onAccept: (() -> Void)?
    var onEscape: (() -> Bool)?

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

struct ProblemsSidebar: View {
    @ObservedObject var model: EditorModel
    /// The header shares the title bar's row, level with the window controls.
    var headerHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Problems")
                    .font(.headline)
                Text("\(model.lints.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Menu {
                    Button("Ignore All", action: model.ignoreAll)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.lints.isEmpty)
                .help("More actions")
                .accessibilityLabel("More actions")
            }
            .padding(.horizontal, 14)
            .frame(height: headerHeight)
            .padding(.bottom, 6)

            if !model.kinds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        KindChip(title: "All", count: model.lints.count, color: nil, isSelected: model.kindFilter == nil) {
                            model.kindFilter = nil
                        }
                        ForEach(model.kinds, id: \.name) { kind in
                            KindChip(title: kind.name, count: kind.count, color: kind.color.color, isSelected: model.kindFilter == kind.name) {
                                model.kindFilter = model.kindFilter == kind.name ? nil : kind.name
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 10)
            }

            Divider()

            if model.lints.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(model.text.isEmpty ? "Nothing to check yet" : "No problems found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.visibleLints) { lint in
                    ProblemRow(lint: lint, model: model)
                        .contentShape(Rectangle())
                        .onTapGesture { model.reveal(lint) }
                        .accessibilityAction(named: "Show in Text") { model.reveal(lint) }
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct KindChip: View {
    let title: String
    let count: Int
    let color: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(title)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ProblemRow: View {
    let lint: EditorLint
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(lint.popup.kindColor.color).frame(width: 7, height: 7)
                Text(lint.popup.kindName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\u{201c}\(lint.popup.flaggedText)\u{201d}")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(PopupText.message(lint.popup.message))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
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
            Picker("Font", selection: $model.font) {
                ForEach(EditorFont.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 0) {
                Button { model.fontSize = max(11, model.fontSize - 1) } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help("Smaller text")
                .accessibilityLabel("Smaller text")
                Button { model.fontSize = min(32, model.fontSize + 1) } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help("Larger text")
                .accessibilityLabel("Larger text")
            }
            .buttonStyle(.borderless)
            Button {
                model.showsProblems.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help(model.showsProblems ? "Hide Problems" : "Show Problems")
            .accessibilityLabel(model.showsProblems ? "Hide Problems" : "Show Problems")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .controlSize(.small)
        .padding(.horizontal, 12)
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
