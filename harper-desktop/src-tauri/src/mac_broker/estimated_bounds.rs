//! Added in this fork (taehee-pd/harperSwift).
//!
//! Some Chromium browsers (Dia, for one) never build the text layout data that word positions come
//! from: for any range of text they report a rectangle with no size, yet they still give the frame
//! of each text run. For a run on one line, a range's position is estimated from that frame and
//! the widths of the text before and in the range, measured in the system font, which most web
//! pages use or resemble. It is only a fallback: apps that report real positions keep them.

use accessibility::ui_element::AXUIElement;
use accessibility_sys::{
    AXUIElementCopyAttributeValue, AXValueGetType, AXValueGetValue, AXValueRef, kAXErrorSuccess,
    kAXValueTypeCGRect,
};
use core::{ffi::c_void, mem::MaybeUninit};
use core_foundation::base::{CFType, TCFType};
use core_foundation::string::CFString;
use objc2_foundation::NSRect;
use std::ffi::{CString, c_char};

use crate::rect::Rect;

unsafe extern "C" {
    /// `macos-popup/Sources/HarperPopup/TextMetrics.swift`.
    fn harper_text_width(text: *const c_char, size: f64) -> f64;
}

/// The size text is measured at. Only the ratio of widths matters, so any size works.
const MEASURE_SIZE: f64 = 16.0;

/// Where characters `start..start + length` of `run_text` sit inside the text run `run`.
pub fn estimated_rect(
    run: &AXUIElement,
    run_text: &str,
    start: usize,
    length: usize,
) -> Option<Rect> {
    estimate(frame(run)?, run_text, start, length, text_width)
}

fn text_width(text: &str) -> f64 {
    CString::new(text).map_or(0.0, |text| unsafe {
        harper_text_width(text.as_ptr(), MEASURE_SIZE)
    })
}

/// `width` measures text at `MEASURE_SIZE`.
fn estimate(
    frame: Rect,
    text: &str,
    start: usize,
    length: usize,
    width: impl Fn(&str) -> f64,
) -> Option<Rect> {
    let chars = text.chars().collect::<Vec<_>>();
    if length == 0 || start + length > chars.len() || frame.width <= 0.0 || frame.height <= 0.0 {
        return None;
    }

    let full = width(text);
    if full <= 0.0 {
        return None;
    }
    let scale = frame.width / full;
    // A run that wraps is as wide as its column and several lines tall, which makes its text
    // look tiny for its height.
    if frame.height > MEASURE_SIZE * scale * 2.0 {
        return None;
    }

    let before = chars[..start].iter().collect::<String>();
    let range = chars[start..start + length].iter().collect::<String>();
    let range_width = width(&range) * scale;

    (range_width > 0.0).then(|| Rect {
        x: frame.x + width(&before) * scale,
        y: frame.y,
        width: range_width,
        height: frame.height,
    })
}

/// The element's frame in screen coordinates, as Chromium reports it.
fn frame(element: &AXUIElement) -> Option<Rect> {
    let attribute = CFString::from_static_string("AXFrame");
    let mut value = core::ptr::null();
    let error = unsafe {
        AXUIElementCopyAttributeValue(
            element.as_concrete_TypeRef(),
            attribute.as_concrete_TypeRef(),
            &mut value,
        )
    };
    if error != kAXErrorSuccess || value.is_null() {
        return None;
    }

    let value = unsafe { CFType::wrap_under_create_rule(value) };
    let ax_value = value.as_CFTypeRef() as AXValueRef;
    if unsafe { AXValueGetType(ax_value) } != kAXValueTypeCGRect {
        return None;
    }
    let mut rect = MaybeUninit::<NSRect>::uninit();
    if !unsafe {
        AXValueGetValue(
            ax_value,
            kAXValueTypeCGRect,
            rect.as_mut_ptr() as *mut c_void,
        )
    } {
        return None;
    }
    let rect = unsafe { rect.assume_init() };

    Some(Rect {
        x: rect.origin.x,
        y: rect.origin.y,
        width: rect.size.width,
        height: rect.size.height,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every character is 8 points wide at the measuring size.
    fn monospace(text: &str) -> f64 {
        text.chars().count() as f64 * 8.0
    }

    fn rect(x: f64, y: f64, width: f64, height: f64) -> Rect {
        Rect {
            x,
            y,
            width,
            height,
        }
    }

    #[test]
    fn places_a_word_inside_its_run() {
        // 23 characters drawn 184 points wide: the measuring size exactly.
        let text = "This is a line with teh";
        let estimate = estimate(rect(587.0, 315.0, 184.0, 19.0), text, 20, 3, monospace).unwrap();

        assert_eq!(estimate.x, 587.0 + 160.0);
        assert_eq!(estimate.width, 24.0);
        assert_eq!(estimate.y, 315.0);
        assert_eq!(estimate.height, 19.0);
    }

    #[test]
    fn scales_to_the_size_the_page_draws_at() {
        // The page draws the same text at half the measuring size.
        let estimate = estimate(rect(0.0, 0.0, 40.0, 10.0), "abcdefghij", 5, 2, monospace).unwrap();

        assert_eq!(estimate.x, 20.0);
        assert_eq!(estimate.width, 8.0);
    }

    #[test]
    fn gives_up_on_a_run_that_wraps() {
        // Two lines: as wide as the column, twice as tall as one line.
        let text = "a".repeat(80);
        assert!(estimate(rect(0.0, 0.0, 300.0, 48.0), &text, 10, 3, monospace).is_none());
    }

    #[test]
    fn rejects_ranges_outside_the_run() {
        assert!(estimate(rect(0.0, 0.0, 80.0, 19.0), "abcdefghij", 8, 5, monospace).is_none());
        assert!(estimate(rect(0.0, 0.0, 80.0, 19.0), "abcdefghij", 2, 0, monospace).is_none());
        assert!(estimate(rect(0.0, 0.0, 0.0, 19.0), "abcdefghij", 2, 1, monospace).is_none());
    }
}
