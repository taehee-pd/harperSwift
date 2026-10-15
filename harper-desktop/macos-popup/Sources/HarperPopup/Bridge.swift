// Added in this fork (taehee-pd/harperSwift).
//
// C entry points called from Rust (`src-tauri/src/highlighter/native_popup/ffi.rs`). The
// highlighter's winit event loop runs on the main thread, so every call arrives there.

import Foundation

/// Receives the popup id, the action kind, and the suggestion index (see `PopupAction.raw`).
public typealias HarperPopupActionHandler = @convention(c) (UInt64, UInt32, Int64) -> Void

@_cdecl("harper_popup_set_action_handler")
public func harperPopupSetActionHandler(_ handler: HarperPopupActionHandler?) {
    MainActor.assumeIsolated { PopupController.actionHandler = handler }
}

@_cdecl("harper_popup_show")
public func harperPopupShow(_ json: UnsafePointer<CChar>?) {
    guard let data = PopupData.decode(json) else { return }
    MainActor.assumeIsolated { PopupController.shared.show(data) }
}

@_cdecl("harper_popup_update")
public func harperPopupUpdate(_ json: UnsafePointer<CChar>?) {
    guard let data = PopupData.decode(json) else { return }
    MainActor.assumeIsolated { PopupController.shared.update(data) }
}

@_cdecl("harper_popup_hide")
public func harperPopupHide() {
    MainActor.assumeIsolated { PopupController.shared.hide() }
}
