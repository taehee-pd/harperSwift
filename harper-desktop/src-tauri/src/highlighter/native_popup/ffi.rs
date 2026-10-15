//! Added in this fork (taehee-pd/harperSwift).
//!
//! C interface to the Swift package in `harper-desktop/macos-popup` (`Bridge.swift`). All calls
//! happen on the main thread, which owns both the winit event loop and AppKit.

use std::ffi::{CString, c_char};

use serde::Serialize;

unsafe extern "C" {
    fn harper_popup_show(json: *const c_char);
    fn harper_popup_update(json: *const c_char);
    fn harper_popup_hide();
}

/// Shows the popup with an entrance animation.
pub fn show(payload: &impl Serialize) {
    with_json(payload, |json| unsafe { harper_popup_show(json) });
}

/// Replaces the popup content and placement without animating.
pub fn update(payload: &impl Serialize) {
    with_json(payload, |json| unsafe { harper_popup_update(json) });
}

pub fn hide() {
    unsafe { harper_popup_hide() }
}

fn with_json(payload: &impl Serialize, send: impl FnOnce(*const c_char)) {
    match serde_json::to_string(payload).map(CString::new) {
        Ok(Ok(json)) => send(json.as_ptr()),
        Ok(Err(error)) => eprintln!("native popup payload contains a NUL byte: {error}"),
        Err(error) => eprintln!("failed to encode native popup payload: {error}"),
    }
}
