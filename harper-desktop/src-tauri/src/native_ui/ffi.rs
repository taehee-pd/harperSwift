//! Added in this fork (taehee-pd/harperSwift).
//!
//! C interface to the native windows in `harper-desktop/macos-popup` (`App/NativeBridge.swift`).
//! Swift sends requests as JSON with an id; Rust answers each one later, on the main thread, with
//! the same id.

use std::ffi::{CStr, CString, c_char};

unsafe extern "C" {
    fn harper_native_set_request_handler(handler: extern "C" fn(u64, *const c_char));
    fn harper_native_respond(id: u64, json: *const c_char);
    fn harper_native_show_settings();
    fn harper_native_show_editor();
}

/// Called by Swift on the main thread. Copies the request and hands it to [`super::dispatch`].
extern "C" fn receive_request(id: u64, json: *const c_char) {
    if json.is_null() {
        return;
    }
    let request = unsafe { CStr::from_ptr(json) }
        .to_string_lossy()
        .into_owned();
    super::dispatch(id, request);
}

pub fn install_request_handler() {
    unsafe { harper_native_set_request_handler(receive_request) }
}

/// Must run on the main thread.
pub fn respond(id: u64, json: &str) {
    match CString::new(json) {
        Ok(json) => unsafe { harper_native_respond(id, json.as_ptr()) },
        Err(error) => eprintln!("native response contains a NUL byte: {error}"),
    }
}

/// Must run on the main thread.
pub fn show_settings() {
    unsafe { harper_native_show_settings() }
}

/// Must run on the main thread.
pub fn show_editor() {
    unsafe { harper_native_show_editor() }
}
