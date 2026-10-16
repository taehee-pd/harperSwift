// Added in this fork (taehee-pd/harperSwift).

import AppKit
import Foundation

/// One problem in the editor's text, as Rust sends it (`native_ui/editor.rs`).
struct EditorLint: Decodable, Identifiable, Equatable {
    /// UTF-16 range in the current text, for `NSTextView`.
    var location: Int
    var length: Int
    var popup: PopupData

    var id: UInt64 { popup.id }
    var range: NSRange { NSRange(location: location, length: length) }

    func contains(caret: Int) -> Bool {
        location <= caret && caret <= location + length
    }
}

enum EditorFont: String, CaseIterable, Identifiable {
    case sans
    case serif
    case mono

    var id: Self { self }

    var title: String {
        switch self {
        case .sans: "Sans"
        case .serif: "Serif"
        case .mono: "Mono"
        }
    }

    func font(size: CGFloat) -> NSFont {
        switch self {
        case .sans:
            return .systemFont(ofSize: size)
        case .serif:
            let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
        case .mono:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

/// The editor's text and problems. Text is checked a moment after typing stops, with the same
/// rules and dictionary as everywhere else, and is kept between launches.
@MainActor
final class EditorModel: ObservableObject {
    private static let draftKey = "HarperEditorDraft"
    private static let fontKey = "HarperEditorFont"
    private static let fontSizeKey = "HarperEditorFontSize"
    private static let sidebarKey = "HarperEditorShowsProblems"

    @Published private(set) var text: String
    @Published private(set) var lints: [EditorLint] = []
    @Published var kindFilter: String?
    @Published var failure: String?

    @Published var showsProblems: Bool {
        didSet { UserDefaults.standard.set(showsProblems, forKey: Self.sidebarKey) }
    }
    @Published var font: EditorFont {
        didSet { UserDefaults.standard.set(font.rawValue, forKey: Self.fontKey) }
    }
    @Published var fontSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: Self.fontSizeKey) }
    }

    /// Set by the text view, which applies edits so they can be undone.
    weak var editor: EditorTextController?

    private var lintTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        text = defaults.string(forKey: Self.draftKey) ?? ""
        showsProblems = defaults.object(forKey: Self.sidebarKey) as? Bool ?? true
        font = EditorFont(rawValue: defaults.string(forKey: Self.fontKey) ?? "") ?? .sans
        let size = defaults.double(forKey: Self.fontSizeKey)
        fontSize = size > 0 ? CGFloat(size) : 15
        scheduleLint(after: 0)
    }

    var visibleLints: [EditorLint] {
        guard let kindFilter else { return lints }
        return lints.filter { $0.popup.kindName == kindFilter }
    }

    /// Kinds present in the text, with counts, in order of appearance.
    var kinds: [(name: String, color: PopupData.RGB, count: Int)] {
        var order: [String] = []
        var counts: [String: (PopupData.RGB, Int)] = [:]
        for lint in lints {
            let name = lint.popup.kindName
            if counts[name] == nil { order.append(name) }
            counts[name, default: (lint.popup.kindColor, 0)].1 += 1
        }
        return order.map { (name: $0, color: counts[$0]!.0, count: counts[$0]!.1) }
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Called after every edit. Problems before or after the edit keep their underline (shifted
    /// past it) until the next check, so nothing blinks; problems the edit touched are dropped.
    func textDidChange(_ text: String, edited: NSRange, changeInLength: Int) {
        self.text = text
        let oldEnd = edited.location + edited.length - changeInLength
        lints = lints.compactMap { lint in
            if lint.location + lint.length <= edited.location {
                return lint
            }
            if lint.location >= oldEnd {
                var shifted = lint
                shifted.location += changeInLength
                return shifted
            }
            return nil
        }
        scheduleLint(after: 0.35)

        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(text, forKey: Self.draftKey)
        }
    }

    func scheduleLint(after delay: Double) {
        lintTask?.cancel()
        let text = text
        lintTask = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            do {
                let lints = try await NativeBridge.request("editor.lint", ["text": text], as: [EditorLint].self)
                guard !Task.isCancelled, text == self.text else { return }
                self.lints = lints
                if let kindFilter, !lints.contains(where: { $0.popup.kindName == kindFilter }) {
                    self.kindFilter = nil
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    func replaceLintsForTesting(_ lints: [EditorLint]) {
        self.lints = lints
    }

    // MARK: Actions

    /// Applies suggestion `index` of `lint` in the text view, so Undo can take it back.
    func apply(_ lint: EditorLint, suggestion index: Int) {
        guard lint.popup.suggestions.indices.contains(index) else { return }
        let suggestion = lint.popup.suggestions[index]
        let range: NSRange
        let replacement: String
        switch suggestion.kind {
        case .replace:
            range = lint.range
            replacement = suggestion.label
        case .insert:
            range = NSRange(location: lint.location + lint.length, length: 0)
            replacement = suggestion.label
        case .remove:
            range = lint.range
            replacement = ""
        }
        editor?.replace(range, with: replacement)
    }

    func ignore(_ lint: EditorLint) {
        perform("editor.ignore", [
            "text": text,
            "location": lint.location,
            "length": lint.length,
            "ruleName": lint.popup.ruleName,
        ])
    }

    func ignoreAll() {
        perform("editor.ignoreAll", ["text": text])
    }

    func addToDictionary(_ lint: EditorLint) {
        perform("dictionary.add", ["word": lint.popup.flaggedText])
    }

    func disableRule(_ lint: EditorLint) {
        perform("editor.disableRule", ["ruleName": lint.popup.ruleName])
    }

    func reveal(_ lint: EditorLint) {
        editor?.reveal(lint)
    }

    func handle(_ action: PopupAction, for lint: EditorLint) {
        switch action {
        case .close, .dismissClarity, .turnOffClarity: break
        case .applySuggestion(let index): apply(lint, suggestion: index)
        case .ignoreLint: ignore(lint)
        case .addToDictionary: addToDictionary(lint)
        case .disableRule: disableRule(lint)
        }
        editor?.closePopover()
    }

    /// Sends a change, then checks the text again so the change shows.
    private func perform(_ method: String, _ params: [String: Any]) {
        Task {
            do {
                try await NativeBridge.perform(method, params)
                scheduleLint(after: 0)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
