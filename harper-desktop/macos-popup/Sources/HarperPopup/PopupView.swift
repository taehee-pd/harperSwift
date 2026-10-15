// Added in this fork (taehee-pd/harperSwift).

import SwiftUI

/// The popup content. The material background, rounded corners and shadow come from the panel
/// (`PopupController`), so this view only draws what sits on top of them.
struct PopupView: View {
    static let width: CGFloat = 320

    let data: PopupData?
    let onAction: (PopupAction) -> Void

    var body: some View {
        if let data {
            PopupCard(data: data, onAction: onAction)
        }
    }
}

private struct PopupCard: View {
    let data: PopupData
    let onAction: (PopupAction) -> Void

    private var kindColor: Color {
        Color(
            .sRGB,
            red: Double(data.kindColor.r) / 255,
            green: Double(data.kindColor.g) / 255,
            blue: Double(data.kindColor.b) / 255
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                header

                Text(PopupText.message(data.message))
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !data.suggestions.isEmpty {
                    suggestions
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)

            Divider()

            footer
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .frame(width: PopupView.width, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(data.kindName) suggestion")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(kindColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            Text(data.kindName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .help(data.ruleName)

            Spacer(minLength: 8)

            Button {
                onAction(.close)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(shape: Circle(), padding: 0))
            .help("Close")
            .accessibilityLabel("Close")
        }
    }

    private var suggestions: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(data.suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button(suggestion.label) {
                    onAction(.applySuggestion(index))
                }
                .buttonStyle(
                    SuggestionButtonStyle(
                        isPrimary: index == 0,
                        color: kindColor,
                        colorIsLight: data.kindColorIsLight
                    )
                )
                .help(suggestion.description)
                .accessibilityLabel(suggestion.description)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button("Ignore") { onAction(.ignoreLint) }
                .help("Ignore this suggestion")
                .accessibilityLabel("Ignore this suggestion")

            if data.canAddToDictionary {
                Button("Add to dictionary") { onAction(.addToDictionary) }
                    .help("Add \u{201c}\(data.flaggedText)\u{201d} to your personal dictionary")
                    .accessibilityLabel("Add \u{201c}\(data.flaggedText)\u{201d} to dictionary")
            }

            Spacer(minLength: 8)

            Button("Disable rule") { onAction(.disableRule) }
                .help("Stop checking \(data.ruleName)")
                .accessibilityLabel("Disable rule \(data.ruleName)")
        }
        .buttonStyle(HoverButtonStyle(shape: RoundedRectangle(cornerRadius: 6, style: .continuous), padding: 6))
        .font(.system(size: 12))
    }
}

/// Text helpers shared by the view and the VoiceOver announcement.
enum PopupText {
    /// Renders Harper's inline markdown (code spans, emphasis); falls back to the raw text.
    static func message(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    /// What VoiceOver reads when the popup appears: kind, message, then suggestions.
    static func announcement(for data: PopupData) -> String {
        let message = String(message(data.message).characters)
        let suggestions = data.suggestions.map(\.label).joined(separator: ", ")

        return suggestions.isEmpty
            ? "\(data.kindName). \(message)"
            : "\(data.kindName). \(message) Suggestions: \(suggestions)."
    }
}

/// Filled chip for suggestions. Drawn by hand instead of using `.borderedProminent`, because the
/// panel is never key and system button styles would render in their inactive (gray) look.
private struct SuggestionButtonStyle: ButtonStyle {
    let isPrimary: Bool
    let color: Color
    let colorIsLight: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

        configuration.label
            .font(.system(size: 13, weight: isPrimary ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(isPrimary ? (colorIsLight ? Color.black : Color.white) : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(shape.fill(isPrimary ? color : Color.primary.opacity(0.07)))
            .overlay(shape.strokeBorder(isPrimary ? Color.clear : Color.primary.opacity(0.12), lineWidth: 0.5))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Quiet text or icon button with a hover highlight.
private struct HoverButtonStyle<S: Shape>: ButtonStyle {
    let shape: S
    /// Horizontal padding around the label; vertical padding is two thirds of it.
    let padding: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, shape: shape, padding: padding)
    }

    private struct HoverLabel: View {
        let configuration: ButtonStyleConfiguration
        let shape: S
        let padding: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .padding(.horizontal, padding)
                .padding(.vertical, padding * 2 / 3)
                .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.12 : isHovered ? 0.07 : 0)))
                .contentShape(shape)
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
