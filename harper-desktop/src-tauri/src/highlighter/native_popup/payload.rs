//! Added in this fork (taehee-pd/harperSwift).
//!
//! JSON sent to Swift. Field names must match `PopupData` in `PopupModel.swift` (snake_case here,
//! camelCase there).

use serde::Serialize;

use crate::rect::Rect;

#[derive(Debug, Clone, Serialize)]
pub struct PopupPayload {
    pub id: u64,
    pub anchor: AnchorRect,
}

/// The flagged word in Accessibility coordinates (global, top-left origin, points).
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct AnchorRect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

impl From<Rect> for AnchorRect {
    fn from(rect: Rect) -> Self {
        Self {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
        }
    }
}
