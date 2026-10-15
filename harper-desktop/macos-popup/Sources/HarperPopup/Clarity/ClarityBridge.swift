// Added in this fork (taehee-pd/harperSwift).
//
// C entry points for Clarity checks, called from Rust (`src-tauri/src/clarity/apple.rs`) on the
// main thread, which also runs the highlighter's event loop.

import Foundation

/// Receives a request id and its issues as a JSON array of `{original, replacement, reason}`.
public typealias HarperClarityResultHandler = @convention(c) (UInt64, UnsafePointer<CChar>?) -> Void

@_cdecl("harper_clarity_set_result_handler")
public func harperClaritySetResultHandler(_ handler: HarperClarityResultHandler?) {
    MainActor.assumeIsolated { ClarityChecker.resultHandler = handler }
}

/// A `ClarityAvailability` code.
@_cdecl("harper_clarity_availability")
public func harperClarityAvailability() -> Int32 {
    MainActor.assumeIsolated { ClarityChecker.shared.availability().rawValue }
}

@_cdecl("harper_clarity_prewarm")
public func harperClarityPrewarm() {
    MainActor.assumeIsolated { ClarityChecker.shared.prewarm() }
}

@_cdecl("harper_clarity_submit")
public func harperClaritySubmit(_ id: UInt64, _ sentence: UnsafePointer<CChar>?) {
    guard let sentence else { return }
    let text = String(cString: sentence)
    MainActor.assumeIsolated { ClarityChecker.shared.submit(id: id, sentence: text) }
}

@_cdecl("harper_clarity_cancel")
public func harperClarityCancel(_ id: UInt64) {
    MainActor.assumeIsolated { ClarityChecker.shared.cancel(id: id) }
}
