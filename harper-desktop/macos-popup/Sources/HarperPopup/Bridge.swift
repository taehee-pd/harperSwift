// Added in this fork (taehee-pd/harperSwift).
//
// C entry points called from Rust (`src-tauri/src/highlighter/native_popup/ffi.rs`). The
// highlighter's winit event loop runs on the main thread, so every call arrives there.

import Foundation

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
