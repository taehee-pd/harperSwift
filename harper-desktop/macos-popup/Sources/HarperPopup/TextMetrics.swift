// Added in this fork (taehee-pd/harperSwift).

import AppKit

/// The width of `text` in the system font at `size` points. Rust uses it to estimate where a word
/// sits when an app reports only the frame of the text run around it
/// (`src-tauri/src/mac_broker/estimated_bounds.rs`).
@_cdecl("harper_text_width")
public func harperTextWidth(_ text: UnsafePointer<CChar>?, _ size: Double) -> Double {
    guard let text else { return 0 }
    let font = NSFont.systemFont(ofSize: size)
    return Double((String(cString: text) as NSString).size(withAttributes: [.font: font]).width)
}
