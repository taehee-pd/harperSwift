// Added in this fork (taehee-pd/harperSwift).

import Foundation
import Testing

@testable import HarperPopup

struct ClarityTests {
    /// Must stay in sync with `decode_issues` in `src-tauri/src/clarity/apple.rs`.
    @Test func encodesIssuesForRust() throws {
        let json = try JSONEncoder().encode([
            ClarityIssueWire(original: "in order to", replacement: "to", reason: "Shorter.")
        ])
        let decoded = try JSONSerialization.jsonObject(with: json) as? [[String: String]]

        #expect(decoded == [["original": "in order to", "replacement": "to", "reason": "Shorter."]])
    }

    /// Must stay in sync with `availability_from_code` in `src-tauri/src/clarity/apple.rs`.
    @Test func keepsAvailabilityCodesStable() {
        #expect(ClarityAvailability.available.rawValue == 0)
        #expect(ClarityAvailability.lowPowerMode.rawValue == 1)
        #expect(ClarityAvailability.lowBattery.rawValue == 2)
        #expect(ClarityAvailability.deviceNotEligible.rawValue == 3)
        #expect(ClarityAvailability.appleIntelligenceNotEnabled.rawValue == 4)
        #expect(ClarityAvailability.modelNotReady.rawValue == 5)
        #expect(ClarityAvailability.unsupportedOperatingSystem.rawValue == 6)
    }

    @Test func decodesAClaritySuggestion() throws {
        let json = """
            {"id": 3, "kind_name": "Clarity", "kind_color": {"r": 163, "g": 25, "b": 255},
             "rule_name": "AppleIntelligence::Clarity", "message": "Shorter.",
             "suggestions": [{"kind": "replace", "label": "to", "description": "Replace “in order to” with “to”"}],
             "flagged_text": "in order to", "can_add_to_dictionary": false, "source": "apple_intelligence",
             "clarity": {"before": "We met ", "original": "in order to", "replacement": "to", "after": " to plan."},
             "anchor": {"x": 0, "y": 0, "width": 10, "height": 10}}
            """
        let data = try PopupData.decode(Data(json.utf8))

        #expect(data.source == .appleIntelligence)
        #expect(data.clarity == PopupData.ClarityContext(before: "We met ", original: "in order to", replacement: "to", after: " to plan."))
        #expect(PopupText.announcement(for: data)
            == "Clarity suggestion from Apple Intelligence. Shorter. Replace “in order to” with “to”.")
    }

    @Test func showsTheChangeInsideItsSentence() {
        let context = PopupData.ClarityContext(before: "We met ", original: "in order to", replacement: "to", after: " plan.")
        let change = ClarityText.change(context, highlight: .purple)

        #expect(String(change.characters) == "We met in order to to plan.")
        let struck = change.runs.filter { $0.strikethroughStyle != nil }.map { String(change[$0.range].characters) }
        let highlighted = change.runs.filter { $0.backgroundColor != nil }.map { String(change[$0.range].characters) }
        #expect(struck == ["in order to"])
        #expect(highlighted == ["to"])
    }

    @Test func trimsLongContextAtWordBoundaries() {
        let long = String(repeating: "word ", count: 20)

        #expect(ClarityText.trimmingStart(long).hasPrefix("\u{2026}"))
        #expect(ClarityText.trimmingStart(long).count <= ClarityText.contextLength + 1)
        #expect(ClarityText.trimmingEnd(long).hasSuffix("\u{2026}"))
        #expect(ClarityText.trimmingStart("short") == "short")
    }

    @Test func promptQuotesOnlyTheSentence() {
        #expect(ClarityPrompt.prompt(for: "We met in order to plan.") == "Sentence: We met in order to plan.")
    }
}
