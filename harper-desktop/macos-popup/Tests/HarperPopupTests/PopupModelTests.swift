// Added in this fork (taehee-pd/harperSwift).

import Foundation
import Testing

@testable import HarperPopup

struct PopupModelTests {
    @Test func decodesThePayloadRustSends() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/popup.json")
        let data = try PopupData.decode(Data(contentsOf: fixture))

        #expect(data.id == 7)
        #expect(data.kindName == "Spelling")
        #expect(data.kindColor == PopupData.RGB(r: 238, g: 66, b: 102))
        #expect(data.ruleName == "SpellCheck")
        #expect(data.suggestions.map(\.label) == ["This", "e", "Remove"])
        #expect(data.suggestions.map(\.kind) == [.replace, .insert, .remove])
        #expect(data.suggestions[0].description == "Replace “Ths” with “This”")
        #expect(data.flaggedText == "Ths")
        #expect(data.canAddToDictionary)
        #expect(data.source == .harper)
        #expect(data.clarity == nil)
        #expect(data.anchor.cgRect == CGRect(x: 120, y: 340.5, width: 24, height: 17))
    }

    @Test func showsSuggestionsAsTheResultingText() {
        func title(_ kind: PopupData.Suggestion.Kind, _ label: String, flagged: String) -> AttributedString {
            PopupText.suggestion(.init(kind: kind, label: label, description: ""), flaggedText: flagged)
        }

        #expect(String(title(.replace, "This", flagged: "Ths").characters) == "This")
        #expect(String(title(.insert, ",", flagged: "However").characters) == "However,")

        let removal = title(.remove, "Remove", flagged: "the")
        #expect(String(removal.characters) == "the")
        #expect(removal.runs.allSatisfy { $0.strikethroughStyle == .single })

        // Spans can briefly point past the end of the text while the user types.
        #expect(String(title(.remove, "Remove", flagged: "").characters) == "Remove")
        // Spaces would leave the button blank.
        #expect(String(title(.remove, "Remove", flagged: "  ").characters) == "Remove")
        let space = PopupText.suggestion(
            .init(kind: .replace, label: " ", description: "Replace with a single space"),
            flaggedText: "  "
        )
        #expect(String(space.characters) == "Replace with a single space")
    }

    @Test func rendersQuotedWordsAsBoldInsteadOfCode() {
        let message = PopupText.message("Did you mean `This`?")
        let quoted = message.runs.first { String(message[$0.range].characters) == "This" }

        #expect(String(message.characters) == "Did you mean This?")
        #expect(quoted?.inlinePresentationIntent == .stronglyEmphasized)

        let two = PopupText.message("Use `affect` or `effect`, not **both**.")
        let bold = two.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(two[$0.range].characters) }
        #expect(String(two.characters) == "Use affect or effect, not both.")
        #expect(bold == ["affect", "effect", "both"])
    }

    /// Must stay in sync with `NativeAction::from_raw` in `native_popup/action.rs`.
    @Test func encodesActionsForRust() {
        #expect(PopupAction.close.raw == (0, -1))
        #expect(PopupAction.applySuggestion(2).raw == (1, 2))
        #expect(PopupAction.ignoreLint.raw == (2, -1))
        #expect(PopupAction.addToDictionary.raw == (3, -1))
        #expect(PopupAction.disableRule.raw == (4, -1))
        #expect(PopupAction.dismissClarity.raw == (5, -1))
        #expect(PopupAction.turnOffClarity.raw == (6, -1))
    }
}
