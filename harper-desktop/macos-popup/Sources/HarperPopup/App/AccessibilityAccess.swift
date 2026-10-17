// Added in this fork (taehee-pd/harperSwift).

import AppKit
import ApplicationServices

/// Asking macOS for Accessibility access, from the first-run setup and from Settings.
enum AccessibilityAccess {
    /// The first time, shows the system alert, which adds Harper to the Accessibility list and
    /// offers to open System Settings; opening System Settings as well would put two windows in
    /// front of the user. Later calls go straight to the list. Returns whether access is granted.
    @MainActor
    @discardableResult
    static func request(alreadyAsked: Bool) -> Bool {
        if alreadyAsked {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return AXIsProcessTrusted()
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
