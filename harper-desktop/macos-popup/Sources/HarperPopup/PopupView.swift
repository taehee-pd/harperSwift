// Added in this fork (taehee-pd/harperSwift).

import SwiftUI

/// The popup content. The background (Liquid Glass or the popover material), its rounded corners
/// and the shadow come from the panel (`PopupController`), so this view only draws what sits on
/// top of them.
struct PopupView: View {
    static let width: CGFloat = 320

    let data: PopupData?
    let chrome: PopupChrome
    let onAction: (PopupAction) -> Void

    var body: some View {
        if let data {
            if data.source == .appleIntelligence, let clarity = data.clarity {
                ClarityCard(data: data, context: clarity, chrome: chrome, onAction: onAction)
            } else {
                PopupCard(data: data, chrome: chrome, onAction: onAction)
            }
        }
    }
}

/// Spacing for the cards. Text keeps one inset from every edge; the close button and the footer
/// buttons sit closer to the corners so their rounded shapes stay roughly concentric with the
/// panel's corners.
enum Metrics {
    static let textInset: CGFloat = 14
    static let cornerInset: CGFloat = 7
    static let closeButtonSize: CGFloat = 22
}

private struct PopupCard: View {
    let data: PopupData
    let chrome: PopupChrome
    let onAction: (PopupAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopupHeader(data: data, onClose: { onAction(.close) })

            VStack(alignment: .leading, spacing: 12) {
                Text(PopupText.message(data.message))
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !data.suggestions.isEmpty {
                    suggestions
                }
            }
            .padding(.horizontal, Metrics.textInset)
            .padding(.top, 4)
            .padding(.bottom, Metrics.textInset)

            Divider()

            footer
                .padding(Metrics.cornerInset)
        }
        .popupFrame(chrome: chrome)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(data.kindName) suggestion")
    }

    private var suggestions: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(data.suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button {
                    onAction(.applySuggestion(index))
                } label: {
                    HStack(spacing: 6) {
                        Text(PopupText.suggestion(suggestion, flaggedText: data.flaggedText))
                        if index == 0 {
                            ShortcutHint()
                        }
                    }
                }
                .buttonStyle(SuggestionButtonStyle(isPrimary: index == 0))
                .help(index == 0 ? "\(suggestion.description) (\(AcceptShortcut.symbols))" : suggestion.description)
                .accessibilityLabel(suggestion.description)
                .accessibilityHint(index == 0 ? "Control-Command-Y" : "")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button("Ignore") { onAction(.ignoreLint) }
                .help("Ignore this suggestion")
                .accessibilityLabel("Ignore this suggestion")

            if data.canAddToDictionary {
                Button("Add to Dictionary") { onAction(.addToDictionary) }
                    .help("Add \u{201c}\(data.flaggedText)\u{201d} to your personal dictionary")
                    .accessibilityLabel("Add \u{201c}\(data.flaggedText)\u{201d} to dictionary")
            }

            Spacer(minLength: 8)

            // Changes a setting rather than this one lint, so it sits apart from the others.
            Button("Disable Rule") { onAction(.disableRule) }
                .help("Stop checking \(data.ruleName)")
                .accessibilityLabel("Disable rule \(data.ruleName)")
        }
        .footerButtonStyle()
    }
}

/// Kind dot, kind name, an optional source tag, and the close button.
struct PopupHeader: View {
    let data: PopupData
    var tag: (title: String, systemImage: String)?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // The same color as the underline, so the popup reads as belonging to that word.
            Circle()
                .fill(data.kindColor.color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            Text(data.kindName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .help(data.ruleName)

            if let tag {
                Label(tag.title, systemImage: tag.systemImage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: Metrics.closeButtonSize, height: Metrics.closeButtonSize)
                    .contentShape(Circle())
            }
            .buttonStyle(QuietButtonStyle(horizontalPadding: 0, verticalPadding: 0))
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.leading, Metrics.textInset)
        .padding([.top, .trailing], Metrics.cornerInset)
    }
}

extension View {
    /// The card width, plus the hairline border the material background needs.
    func popupFrame(chrome: PopupChrome) -> some View {
        frame(width: PopupView.width, alignment: .leading)
            .overlay {
                if chrome.drawsBorder {
                    RoundedRectangle(cornerRadius: chrome.cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
            }
    }

    /// Footer buttons. Text inset = corner inset + horizontal padding, so labels line up with the
    /// message above.
    func footerButtonStyle() -> some View {
        buttonStyle(QuietButtonStyle(horizontalPadding: Metrics.textInset - Metrics.cornerInset, verticalPadding: 4))
            .font(.system(size: 12))
    }
}

extension PopupData.RGB {
    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

/// Text helpers shared by the view and the VoiceOver announcement.
enum PopupText {
    /// Renders Harper's inline markdown. Harper quotes words in code spans (`Did you mean `This`?`);
    /// those read as bold here, like the other emphasized words in its messages, instead of
    /// switching to a monospaced font mid-sentence. Falls back to the raw text.
    static func message(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return AttributedString(markdown)
        }

        // Rebuilt in one pass: changing attributes in place would invalidate the run ranges.
        var text = AttributedString()
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                piece.inlinePresentationIntent = intent.subtracting(.code).union(.stronglyEmphasized)
            }
            text.append(piece)
        }
        return text
    }

    /// What a suggestion button shows: the flagged text as it will read after the change. An
    /// insertion shows the word with its addition ("However,"), a removal shows the word struck
    /// through. Text that would be invisible (spaces) falls back to words.
    static func suggestion(_ suggestion: PopupData.Suggestion, flaggedText: String) -> AttributedString {
        switch suggestion.kind {
        case .replace:
            return isVisible(suggestion.label)
                ? AttributedString(suggestion.label)
                : AttributedString(suggestion.description)
        case .insert:
            return isVisible(suggestion.label)
                ? AttributedString(flaggedText + suggestion.label)
                : AttributedString(suggestion.description)
        case .remove:
            guard isVisible(flaggedText) else { return AttributedString(suggestion.label) }
            var text = AttributedString(flaggedText)
            text.strikethroughStyle = .single
            return text
        }
    }

    private static func isVisible(_ text: String) -> Bool {
        !text.allSatisfy(\.isWhitespace)
    }

    /// What VoiceOver reads when the popup appears: kind (and source for Clarity), message, then
    /// suggestions.
    static func announcement(for data: PopupData) -> String {
        let message = String(message(data.message).characters)
        if data.source == .appleIntelligence {
            let change = data.suggestions.first.map { " \($0.description)." } ?? ""
            return "\(data.kindName) suggestion from Apple Intelligence. \(message)\(change)"
        }

        let suggestions = data.suggestions.map(\.description).joined(separator: ", ")

        return suggestions.isEmpty
            ? "\(data.kindName). \(message)"
            : "\(data.kindName). \(message) Suggestions: \(suggestions)."
    }
}

/// Capsule button for suggestions. The first one is filled with the system accent color, the way
/// macOS marks a default button; the rest are tinted. Drawn by hand instead of using
/// `.borderedProminent`, because the panel is never key and system button styles would render in
/// their inactive (gray) look.
struct SuggestionButtonStyle: ButtonStyle {
    /// Keeps one-letter suggestions ("a") a comfortable size to click.
    static let minimumWidth: CGFloat = 40

    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        SuggestionLabel(configuration: configuration, isPrimary: isPrimary)
    }

    private struct SuggestionLabel: View {
        let configuration: ButtonStyleConfiguration
        let isPrimary: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: isPrimary ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isPrimary ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(minWidth: SuggestionButtonStyle.minimumWidth)
                .background(Capsule().fill(fill))
                // Pressing darkens the button at once (on mouse-down), the way AppKit buttons do.
                .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.14 : 0)))
                .contentShape(Capsule())
                .onHover { isHovered = $0 }
        }

        private var fill: Color {
            if isPrimary {
                let accent = Color(nsColor: .controlAccentColor)
                return isHovered ? accent.opacity(0.9) : accent
            }
            return Color.primary.opacity(isHovered ? 0.12 : 0.08)
        }
    }
}

/// The accept shortcut, drawn the way menus show shortcuts: lighter than the label beside it.
struct ShortcutHint: View {
    var body: some View {
        Text(AcceptShortcut.symbols)
            .font(.system(size: 11, weight: .medium))
            .opacity(0.65)
            .accessibilityHidden(true)
    }
}

/// Quiet text or icon button: secondary text, with a capsule highlight on hover and press.
struct QuietButtonStyle: ButtonStyle {
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        QuietLabel(configuration: configuration, horizontalPadding: horizontalPadding, verticalPadding: verticalPadding)
    }

    private struct QuietLabel: View {
        let configuration: ButtonStyleConfiguration
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : isHovered ? 0.08 : 0)))
                .contentShape(Capsule())
                .onHover { isHovered = $0 }
        }
    }
}

/// Lays out children left to right and wraps to a new row when the width runs out.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(maxWidth: bounds.width, subviews: subviews)

        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0

        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, maxWidth), height: ideal.height)

            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }

            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }

        return (frames, CGSize(width: width, height: y + rowHeight))
    }
}
