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

    @Test func promptQuotesOnlyTheSentence() {
        #expect(ClarityPrompt.prompt(for: "We met in order to plan.") == "Sentence: We met in order to plan.")
    }
}
