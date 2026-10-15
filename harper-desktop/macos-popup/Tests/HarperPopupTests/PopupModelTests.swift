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
        #expect(!data.kindColorIsLight)
        #expect(data.ruleName == "SpellCheck")
        #expect(data.suggestions.map(\.label) == ["This", "e", "Remove"])
        #expect(data.suggestions[0].description == "Replace “Ths” with “This”")
        #expect(data.flaggedText == "Ths")
        #expect(data.canAddToDictionary)
        #expect(data.anchor.cgRect == CGRect(x: 120, y: 340.5, width: 24, height: 17))
    }

    /// Must stay in sync with `NativeAction::from_raw` in `native_popup/action.rs`.
    @Test func encodesActionsForRust() {
        #expect(PopupAction.close.raw == (0, -1))
        #expect(PopupAction.applySuggestion(2).raw == (1, 2))
        #expect(PopupAction.ignoreLint.raw == (2, -1))
        #expect(PopupAction.addToDictionary.raw == (3, -1))
        #expect(PopupAction.disableRule.raw == (4, -1))
    }
}
