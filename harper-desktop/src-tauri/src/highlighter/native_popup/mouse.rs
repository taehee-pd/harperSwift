//! Added in this fork (taehee-pd/harperSwift).
//!
//! Notices mouse presses anywhere on screen without receiving them. This lets the underline
//! overlay stay click-through on macOS, so clicking an underline never activates Harper and the
//! app the user is typing in keeps focus.

/// `kCGEventSourceStateCombinedSessionState`.
const COMBINED_SESSION_STATE: i32 = 0;
/// `kCGEventLeftMouseDown`.
const LEFT_MOUSE_DOWN: u32 = 1;
/// `kCGEventRightMouseDown`.
const RIGHT_MOUSE_DOWN: u32 = 3;

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGEventSourceCounterForEventType(state_id: i32, event_type: u32) -> u32;
}

/// Mouse buttons pressed since the previous frame.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Presses {
    pub left: bool,
    pub right: bool,
}

impl Presses {
    pub fn any(self) -> bool {
        self.left || self.right
    }
}

/// Compares the system's press counters between frames. Unlike polling the button state, this
/// never misses a click that starts and ends between two frames, such as a quick trackpad tap.
pub struct PressCounter {
    left: u32,
    right: u32,
}

impl PressCounter {
    pub fn new() -> Self {
        Self {
            left: count(LEFT_MOUSE_DOWN),
            right: count(RIGHT_MOUSE_DOWN),
        }
    }

    pub fn take(&mut self) -> Presses {
        let (left, right) = (count(LEFT_MOUSE_DOWN), count(RIGHT_MOUSE_DOWN));
        let presses = Presses {
            left: left != self.left,
            right: right != self.right,
        };

        self.left = left;
        self.right = right;
        presses
    }
}

fn count(event_type: u32) -> u32 {
    unsafe { CGEventSourceCounterForEventType(COMBINED_SESSION_STATE, event_type) }
}
