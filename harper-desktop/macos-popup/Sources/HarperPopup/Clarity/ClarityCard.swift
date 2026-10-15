// Added in this fork (taehee-pd/harperSwift).

import SwiftUI

/// The popup for a Clarity suggestion from Apple Intelligence: why it helps, how the sentence
/// changes, and Accept. It never applies anything on its own.
///
/// The layout follows the Harper card so the same actions sit in the same places: the primary
/// action in the body, the "not this one" action at the left of the footer, the setting change at
/// the right.
struct ClarityCard: View {
    let data: PopupData
    let context: PopupData.ClarityContext
    let chrome: PopupChrome
    let onAction: (PopupAction) -> Void

    private var changeDescription: String {
        data.suggestions.first?.description ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopupHeader(
                data: data,
                tag: (title: "Apple Intelligence", systemImage: "apple.intelligence"),
                onClose: { onAction(.close) }
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(PopupText.message(data.message))
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(ClarityText.change(context, highlight: data.kindColor.color))
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .accessibilityLabel(changeDescription)

                Button("Accept") { onAction(.applySuggestion(0)) }
                    .buttonStyle(SuggestionButtonStyle(isPrimary: true))
                    .help(changeDescription)
                    .accessibilityLabel("Accept: \(changeDescription)")
                    .padding(.top, 2)
            }
            .padding(.horizontal, Metrics.textInset)
            .padding(.top, 4)
            .padding(.bottom, Metrics.textInset)

            Divider()

            HStack(spacing: 0) {
                Button("Dismiss") { onAction(.dismissClarity) }
                    .help("Don\u{2019}t suggest this again for this sentence")

                Spacer(minLength: 8)

                // Changes a setting rather than this one suggestion, so it sits apart.
                Button("Turn off Clarity suggestions") { onAction(.turnOffClarity) }
                    .help("You can turn them back on in Harper\u{2019}s settings")
            }
            .footerButtonStyle()
            .padding(Metrics.cornerInset)
        }
        .popupFrame(chrome: chrome)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(data.kindName) suggestion from Apple Intelligence")
    }
}

enum ClarityText {
    /// How many characters of the sentence to keep on each side of the change.
    static let contextLength = 48

    /// The sentence with the removed words struck through and the added words highlighted.
    /// Strikethrough and highlight carry the meaning, so it does not rely on color alone.
    static func change(_ context: PopupData.ClarityContext, highlight: Color) -> AttributedString {
        var before = AttributedString(trimmingStart(context.before))
        before.foregroundColor = .secondary

        var removed = AttributedString(context.original)
        removed.foregroundColor = .secondary
        removed.strikethroughStyle = .single

        var added = AttributedString(context.replacement)
        added.foregroundColor = .primary
        added.backgroundColor = highlight.opacity(0.22)
        added.font = .system(size: 13, weight: .semibold)

        var after = AttributedString(trimmingEnd(context.after))
        after.foregroundColor = .secondary

        // A plain space keeps the struck and the added words from running together.
        let gap = context.original.isEmpty || context.replacement.isEmpty
            ? AttributedString()
            : AttributedString(" ")

        return before + removed + gap + added + after
    }

    /// The end of `text`, cut at a word boundary with a leading ellipsis when it is long.
    static func trimmingStart(_ text: String) -> String {
        guard text.count > contextLength else { return text }

        let tail = text.suffix(contextLength)
        let start = tail.firstIndex(of: " ").map { tail.index(after: $0) } ?? tail.startIndex
        return "\u{2026}" + tail[start...]
    }

    /// The start of `text`, cut at a word boundary with a trailing ellipsis when it is long.
    static func trimmingEnd(_ text: String) -> String {
        guard text.count > contextLength else { return text }

        let head = text.prefix(contextLength)
        let end = head.lastIndex(of: " ") ?? head.endIndex
        return head[..<end] + "\u{2026}"
    }
}
