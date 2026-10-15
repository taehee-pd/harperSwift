//! Native SwiftUI suggestion popup for macOS. Added in this fork (taehee-pd/harperSwift).
//!
//! `RenderState` stays the owner of popup state (`highlighted_lint`). Every frame,
//! [`NativePopup::sync`] mirrors that state into the Swift panel in `harper-desktop/macos-popup`.

mod ffi;
mod payload;

use payload::{AnchorRect, PopupPayload};

use super::render_state::RenderState;

/// What the Swift panel currently displays.
struct ShownPopup {
    id: u64,
    index: usize,
    anchor: AnchorRect,
}

#[derive(Default)]
pub struct NativePopup {
    shown: Option<ShownPopup>,
    next_id: u64,
}

impl NativePopup {
    pub fn sync(&mut self, render_state: &RenderState) {
        let current = render_state
            .highlighted()
            .map(|(index, lint)| (index, AnchorRect::from(lint.rect)));

        match (current, &mut self.shown) {
            (None, None) => {}
            (None, Some(_)) => {
                ffi::hide();
                self.shown = None;
            }
            (Some((index, anchor)), Some(shown)) if shown.index == index => {
                if shown.anchor != anchor {
                    shown.anchor = anchor;
                    ffi::update(&PopupPayload {
                        id: shown.id,
                        anchor,
                    });
                }
            }
            (Some((index, anchor)), _) => {
                self.next_id += 1;
                ffi::show(&PopupPayload {
                    id: self.next_id,
                    anchor,
                });
                self.shown = Some(ShownPopup {
                    id: self.next_id,
                    index,
                    anchor,
                });
            }
        }
    }
}
