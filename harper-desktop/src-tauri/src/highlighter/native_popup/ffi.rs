//! Added in this fork (taehee-pd/harperSwift).
//!
//! C interface to the Swift package in `harper-desktop/macos-popup` (`Bridge.swift`). All calls
//! happen on the main thread, which owns both the winit event loop and AppKit.

use std::cell::RefCell;
use std::ffi::{CString, c_char};

use serde::Serialize;

unsafe extern "C" {
    fn harper_popup_set_action_handler(handler: extern "C" fn(u64, u32, i64));
    fn harper_popup_show(json: *const c_char);
    fn harper_popup_update(json: *const c_char);
    fn harper_popup_hide();
}

/// An action reported by Swift, before it is decoded by [`super::action::NativeAction`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawAction {
    pub popup_id: u64,
    pub kind: u32,
    pub index: i64,
}

thread_local! {
    /// Actions reported by Swift, drained once per frame by `NativePopup::sync`.
    static PENDING_ACTIONS: RefCell<Vec<RawAction>> = const { RefCell::new(Vec::new()) };
}

/// Called by Swift from a button handler. It only queues the action, because the Rust state it
/// acts on is owned by the event loop and is not borrowable from here.
extern "C" fn queue_action(popup_id: u64, kind: u32, index: i64) {
    PENDING_ACTIONS.with(|pending| {
        if let Ok(mut pending) = pending.try_borrow_mut() {
            pending.push(RawAction {
                popup_id,
                kind,
                index,
            });
        }
    });
}

pub fn install_action_handler() {
    unsafe { harper_popup_set_action_handler(queue_action) }
}

pub fn take_actions() -> Vec<RawAction> {
    PENDING_ACTIONS.with(RefCell::take)
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
