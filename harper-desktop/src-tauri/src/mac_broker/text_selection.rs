//! Added in this fork (taehee-pd/harperSwift).
//!
//! Reads and edits a text field through its selection, the way typing does. Replacing the whole
//! `AXValue` with a plain string drops rich text formatting (bold, links, headings, the styling of
//! Markdown editors) and moves the caret; replacing only the selected range keeps both, and the
//! app records the edit for Undo.
//!
//! Chromium (Chrome, Edge, and Electron apps such as Claude and Slack) selects through
//! Accessibility but ignores text written through it, so there the fix is typed into the
//! selection as key events instead.
//!
//! Accessibility ranges count UTF-16 code units, while Harper spans count `char`s, so every range
//! goes through [`utf16_offset`] and [`char_index`].

use accessibility::attribute::AXUIElementAttributes;
use accessibility::ui_element::AXUIElement;
use accessibility_sys::{
    AXUIElementCopyAttributeValue, AXUIElementGetPid, AXUIElementSetAttributeValue, AXValueCreate,
    AXValueGetType, AXValueGetValue, AXValueRef, kAXErrorSuccess, kAXSelectedTextAttribute,
    kAXSelectedTextRangeAttribute, kAXValueTypeCFRange,
};
use core::{ffi::c_void, mem::MaybeUninit, ptr};
use core_foundation::base::{CFRange, CFType, TCFType};
use core_foundation::string::CFString;
use core_graphics::event::{CGEvent, CGEventFlags, CGKeyCode};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use harper_core::Span;
use std::thread;
use std::time::{Duration, Instant};

use super::accessibility_text::cf_type_to_string;

/// A selection in UTF-16 code units, as Accessibility reports it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Utf16Range {
    pub location: usize,
    pub length: usize,
}

/// The number of UTF-16 code units in the first `char_index` characters of `text`.
pub fn utf16_offset(text: &str, char_index: usize) -> usize {
    text.chars().take(char_index).map(char::len_utf16).sum()
}

/// The character index at UTF-16 offset `offset` in `text`. An offset inside a surrogate pair
/// rounds down to the start of that character.
pub fn char_index(text: &str, offset: usize) -> usize {
    let mut units = 0;

    for (index, character) in text.chars().enumerate() {
        units += character.len_utf16();
        if units > offset {
            return index;
        }
    }

    text.chars().count()
}

/// The element's selection, or `None` when the app does not report one.
pub fn selected_range(element: &AXUIElement) -> Option<Utf16Range> {
    let attribute = CFString::from_static_string(kAXSelectedTextRangeAttribute);
    let mut value = ptr::null();

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

    if unsafe { AXValueGetType(ax_value) } != kAXValueTypeCFRange {
        return None;
    }

    let mut range = MaybeUninit::<CFRange>::uninit();
    let ok = unsafe {
        AXValueGetValue(
            ax_value,
            kAXValueTypeCFRange,
            range.as_mut_ptr() as *mut c_void,
        )
    };

    if !ok {
        return None;
    }

    let range = unsafe { range.assume_init() };
    Some(Utf16Range {
        location: usize::try_from(range.location).ok()?,
        length: usize::try_from(range.length).ok()?,
    })
}

/// The caret as a character index, when the selection is a plain insertion point.
pub fn caret_char_index(element: &AXUIElement, text: &str) -> Option<usize> {
    selected_range(element)
        .filter(|range| range.length == 0)
        .map(|range| char_index(text, range.location))
}

fn set_selected_range(element: &AXUIElement, range: Utf16Range) -> bool {
    let range = CFRange {
        location: range.location as isize,
        length: range.length as isize,
    };
    let value = unsafe { AXValueCreate(kAXValueTypeCFRange, &range as *const CFRange as _) };

    if value.is_null() {
        return false;
    }

    let value = unsafe { CFType::wrap_under_create_rule(value as _) };
    let attribute = CFString::from_static_string(kAXSelectedTextRangeAttribute);

    unsafe {
        AXUIElementSetAttributeValue(
            element.as_concrete_TypeRef(),
            attribute.as_concrete_TypeRef(),
            value.as_CFTypeRef(),
        ) == kAXErrorSuccess
    }
}

fn set_selected_text(element: &AXUIElement, text: &str) -> bool {
    let value = CFString::new(text);
    let attribute = CFString::from_static_string(kAXSelectedTextAttribute);

    unsafe {
        AXUIElementSetAttributeValue(
            element.as_concrete_TypeRef(),
            attribute.as_concrete_TypeRef(),
            value.as_CFTypeRef(),
        ) == kAXErrorSuccess
    }
}

/// Where the user's selection should end up after `edited` (UTF-16) became `inserted_len` units
/// long: before the edit it stays, after it it shifts by the change in length, and a selection
/// that overlapped the edit collapses to the end of the inserted text. A caret right at the start
/// of the edit counts as inside it, since that caret is what opened the suggestion.
fn selection_after_edit(
    selection: Utf16Range,
    edited: Utf16Range,
    inserted_len: usize,
) -> Utf16Range {
    let edited_end = edited.location + edited.length;
    let selection_end = selection.location + selection.length;

    let is_before = selection_end < edited.location
        || (selection.length > 0 && selection_end == edited.location);
    if is_before {
        selection
    } else if selection.location >= edited_end {
        Utf16Range {
            location: selection.location + inserted_len - edited.length,
            length: selection.length,
        }
    } else {
        Utf16Range {
            location: edited.location + inserted_len,
            length: 0,
        }
    }
}

/// What [`replace_span`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Replacement {
    Replaced,
    /// The field no longer holds the expected text (the user kept typing), so the span would
    /// point at the wrong characters. Nothing was changed.
    TextChanged,
    /// The app does not let Accessibility edit through the selection. Nothing was changed.
    Unsupported,
}

/// Replaces the characters in `span` of `expected_text` with `replacement`, through the selection.
/// The user's selection is put back where it was, shifted for the edit.
pub fn replace_span(
    element: &AXUIElement,
    expected_text: &str,
    span: Span<char>,
    replacement: &str,
) -> Replacement {
    let current = element
        .value()
        .ok()
        .and_then(|value| cf_type_to_string(&value));
    if current.as_deref() != Some(expected_text) {
        return Replacement::TextChanged;
    }

    let start = utf16_offset(expected_text, span.start);
    let edited = Utf16Range {
        location: start,
        length: utf16_offset(expected_text, span.end) - start,
    };
    let previous_selection = selected_range(element);

    if !set_selected_range(element, edited) {
        return Replacement::Unsupported;
    }
    if is_chromium(element) {
        // Chromium (Chrome, Edge, and Electron apps such as Claude and Slack) selects through
        // Accessibility but ignores text written through it, so the fix is typed into the
        // selection. The caret ends after the fix, as after typing; putting the old selection
        // back could land before the typed text, which arrives later.
        if wait_for_selection(element, edited) && type_text(element, replacement) {
            return Replacement::Replaced;
        }
        if let Some(previous) = previous_selection {
            set_selected_range(element, previous);
        }
        return Replacement::Unsupported;
    }
    if !set_selected_text(element, replacement) {
        if let Some(previous) = previous_selection {
            set_selected_range(element, previous);
        }
        return Replacement::Unsupported;
    }

    let inserted_len = replacement.encode_utf16().count();
    let selection = previous_selection.map_or(
        Utf16Range {
            location: edited.location + inserted_len,
            length: 0,
        },
        |previous| selection_after_edit(previous, edited, inserted_len),
    );
    set_selected_range(element, selection);

    Replacement::Replaced
}

/// Whether `element` is Chromium web content, which marks its elements with this attribute.
fn is_chromium(element: &AXUIElement) -> bool {
    element.attribute_names().is_ok_and(|names| {
        names
            .iter()
            .any(|name| name.to_string() == "ChromeAXNodeId")
    })
}

/// Waits for Chromium to apply a selection, which it does a moment after accepting it.
fn wait_for_selection(element: &AXUIElement, range: Utf16Range) -> bool {
    let deadline = Instant::now() + Duration::from_millis(300);
    loop {
        if selected_range(element) == Some(range) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(10));
    }
}

const DELETE_KEY: CGKeyCode = 0x33;

/// Types `text` into the app that owns `element`, replacing its selection; no text deletes the
/// selection. The events carry no modifier keys, so Control and Command held down for
/// Control-Command-Y do not turn the typing into shortcuts.
fn type_text(element: &AXUIElement, text: &str) -> bool {
    let Some(chunks) = typing_chunks(text) else {
        return false;
    };
    let mut pid = 0;
    if unsafe { AXUIElementGetPid(element.as_concrete_TypeRef(), &mut pid) } != kAXErrorSuccess {
        return false;
    }

    let key = |keycode: CGKeyCode, chunk: Option<&[u16]>| {
        [true, false].into_iter().all(|down| {
            let Ok(source) = CGEventSource::new(CGEventSourceStateID::Private) else {
                return false;
            };
            let Ok(event) = CGEvent::new_keyboard_event(source, keycode, down) else {
                return false;
            };
            event.set_flags(CGEventFlags::empty());
            if let Some(chunk) = chunk {
                event.set_string_from_utf16_unchecked(chunk);
            }
            event.post_to_pid(pid);
            true
        })
    };

    if chunks.is_empty() {
        return key(DELETE_KEY, None);
    }
    chunks.iter().all(|chunk| key(0, Some(chunk)))
}

/// `text` as UTF-16 pieces of at most 20 units, the most one key event reliably carries, never
/// splitting a character. `None` for text with control characters: a typed line break would send
/// a chat message, and a tab would move focus.
fn typing_chunks(text: &str) -> Option<Vec<Vec<u16>>> {
    if text.chars().any(char::is_control) {
        return None;
    }
    let mut chunks: Vec<Vec<u16>> = Vec::new();
    for character in text.chars() {
        let mut units = [0; 2];
        let units = character.encode_utf16(&mut units);
        match chunks.last_mut() {
            Some(chunk) if chunk.len() + units.len() <= 20 => chunk.extend_from_slice(units),
            _ => chunks.push(units.to_vec()),
        }
    }
    Some(chunks)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn types_text_in_pieces_without_splitting_characters() {
        assert_eq!(typing_chunks(""), Some(vec![]));
        assert_eq!(
            typing_chunks("the"),
            Some(vec!["the".encode_utf16().collect()])
        );

        let long = "a".repeat(19) + "😀" + "b";
        let chunks = typing_chunks(&long).unwrap();
        // The emoji's two units would make 21, so it starts the next piece.
        assert_eq!(chunks[0].len(), 19);
        assert_eq!(chunks[1], "😀b".encode_utf16().collect::<Vec<_>>());
        assert_eq!(chunks.concat(), long.encode_utf16().collect::<Vec<_>>());
    }

    #[test]
    fn never_types_line_breaks_or_tabs() {
        assert_eq!(typing_chunks("one\ntwo"), None);
        assert_eq!(typing_chunks("one\ttwo"), None);
    }

    #[test]
    fn counts_utf16_units_for_characters_outside_the_bmp() {
        let text = "a😀b";
        assert_eq!(utf16_offset(text, 0), 0);
        assert_eq!(utf16_offset(text, 1), 1);
        assert_eq!(utf16_offset(text, 2), 3);
        assert_eq!(utf16_offset(text, 3), 4);
    }

    #[test]
    fn maps_utf16_offsets_back_to_characters() {
        let text = "a😀b";
        assert_eq!(char_index(text, 0), 0);
        assert_eq!(char_index(text, 1), 1);
        assert_eq!(char_index(text, 2), 1);
        assert_eq!(char_index(text, 3), 2);
        assert_eq!(char_index(text, 4), 3);
    }

    fn range(location: usize, length: usize) -> Utf16Range {
        Utf16Range { location, length }
    }

    #[test]
    fn keeps_a_caret_before_the_edit() {
        assert_eq!(
            selection_after_edit(range(2, 0), range(5, 3), 4),
            range(2, 0)
        );
    }

    #[test]
    fn shifts_a_caret_after_the_edit() {
        assert_eq!(
            selection_after_edit(range(10, 0), range(5, 3), 4),
            range(11, 0)
        );
        assert_eq!(
            selection_after_edit(range(10, 2), range(5, 3), 1),
            range(8, 2)
        );
    }

    #[test]
    fn moves_a_caret_inside_the_edit_to_its_end() {
        assert_eq!(
            selection_after_edit(range(6, 0), range(5, 3), 4),
            range(9, 0)
        );
    }

    #[test]
    fn moves_a_caret_at_the_start_of_the_edit_to_its_end() {
        assert_eq!(
            selection_after_edit(range(5, 0), range(5, 3), 4),
            range(9, 0)
        );
        // An insertion: the caret ends up after the inserted text, as if it had been typed.
        assert_eq!(
            selection_after_edit(range(5, 0), range(5, 0), 1),
            range(6, 0)
        );
    }

    #[test]
    fn keeps_a_selection_that_ends_where_the_edit_starts() {
        assert_eq!(
            selection_after_edit(range(1, 4), range(5, 3), 4),
            range(1, 4)
        );
    }

    #[test]
    fn keeps_a_caret_right_at_the_end_of_the_edit_after_it() {
        assert_eq!(
            selection_after_edit(range(8, 0), range(5, 3), 4),
            range(9, 0)
        );
    }
}
