// Added in this fork (taehee-pd/harperSwift).

import Foundation
import Testing

@testable import HarperPopup

struct NativeWindowTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)"))
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    @Test func decodesTheSettingsRustSends() throws {
        let snapshot = try decoder.decode(SettingsSnapshot.self, from: fixture("settings.json"))

        #expect(snapshot.dialect == .british)
        #expect(snapshot.debounceMs == 250)
        #expect(snapshot.launchAtLogin)
        #expect(!snapshot.autoUpdate)
        #expect(snapshot.version == "1.2.0")
        #expect(!snapshot.clarity.available)
        #expect(snapshot.dictionary == ["Harper", "macOS"])
        #expect(snapshot.apps == [.init(bundleId: "com.apple.TextEdit", name: "TextEdit", enabled: true)])
        #expect(snapshot.autoEnableNewApps)
        #expect(!snapshot.onboardingCompleted)
    }

    @Test func decodesAnEditorLintAroundThePopupPayload() throws {
        let popup = try JSONSerialization.jsonObject(with: fixture("popup.json"))
        let lint = try JSONSerialization.data(withJSONObject: ["location": 4, "length": 3, "popup": popup])
        let decoded = try decoder.decode(EditorLint.self, from: lint)

        #expect(decoded.range == NSRange(location: 4, length: 3))
        #expect(decoded.popup.kindName == "Spelling")
        #expect(decoded.contains(caret: 4))
        #expect(decoded.contains(caret: 7))
        #expect(!decoded.contains(caret: 8))
    }

    @Test @MainActor func shiftsProblemsPastAnEditAndDropsTouchedOnes() throws {
        let popup = try JSONSerialization.jsonObject(with: fixture("popup.json"))
        func lint(_ location: Int, _ length: Int) throws -> EditorLint {
            try decoder.decode(EditorLint.self, from: JSONSerialization.data(
                withJSONObject: ["location": location, "length": length, "popup": popup]
            ))
        }

        let model = EditorModel()
        model.replaceLintsForTesting([try lint(0, 3), try lint(10, 3), try lint(20, 3)])
        // Two characters typed at 11, inside the second problem.
        model.textDidChange("text", edited: NSRange(location: 11, length: 2), changeInLength: 2)

        #expect(model.lints.map(\.range) == [NSRange(location: 0, length: 3), NSRange(location: 22, length: 3)])
    }

    @Test @MainActor func keepsAProblemWhenASpaceFollowsItButNotWhenTheWordGrows() throws {
        let popup = try JSONSerialization.jsonObject(with: fixture("popup.json"))
        let teh = try decoder.decode(EditorLint.self, from: JSONSerialization.data(
            withJSONObject: ["location": 0, "length": 3, "popup": popup]
        ))

        let spaced = EditorModel()
        spaced.replaceLintsForTesting([teh])
        spaced.textDidChange("teh ", edited: NSRange(location: 3, length: 1), changeInLength: 1)
        #expect(spaced.lints.map(\.range) == [NSRange(location: 0, length: 3)])

        let grown = EditorModel()
        grown.replaceLintsForTesting([teh])
        grown.textDidChange("tehs", edited: NSRange(location: 3, length: 1), changeInLength: 1)
        #expect(grown.lints.isEmpty)
    }

    @Test func readsTheClarityStatus() {
        func status(_ text: String, enabled: Bool = true, available: Bool = true) -> ClarityStatus {
            ClarityStatus(.init(enabled: enabled, available: available, status: text))
        }

        let ready = status("Ready: suggestions run on this Mac")
        #expect(ready.state == .ready)
        #expect(ready.title == "Ready")
        #expect(ready.detail == "Suggestions run on this Mac")

        #expect(status("Paused: Low Power Mode is on").state == .paused)
        #expect(status("Unavailable: this Mac doesn't support Apple Intelligence", available: false).state == .unavailable)
        #expect(status("Waiting: starts once Harper is checking your writing").state == .waiting)
        // Turned off by the user: say so, whatever the model is doing.
        #expect(status("Ready: suggestions run on this Mac", enabled: false).state == .off)
        // Unavailable stays unavailable even though the switch reads off.
        #expect(status("Unavailable: Clarity needs macOS 27 or later", enabled: false, available: false).state == .unavailable)
        // Text without a state word still shows.
        #expect(status("something new").detail == "Something new")
    }
}
